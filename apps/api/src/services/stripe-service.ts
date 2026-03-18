/**
 * Stripe Service
 *
 * Stripe決済統合サービス
 * - サブスクリプション作成・更新・キャンセル
 * - Webhookハンドリング (subscription.*, invoice.*)
 * - DB更新のトランザクション整合性保証
 */

import Stripe from 'stripe';
import { getDb, withTransaction } from '../db/index.js';
import { subscriptions, usageLogs } from '../db/schema.js';
import { eq } from 'drizzle-orm';

// ===========================
// Types
// ===========================

export interface CreateSubscriptionParams {
  userId: string;
  planId: string;
  paymentMethodId?: string;
}

export interface SubscriptionStatus {
  userId: string;
  plan: string;
  status: string;
  currentPeriodStart: Date;
  currentPeriodEnd: Date;
  cancelAt?: Date | null;
  stripeCustomerId?: string;
  stripeSubscriptionId?: string;
}

export interface WebhookEvent {
  id: string;
  type: string;
  data: {
    object: any;
  };
}

// ===========================
// Stripe Client
// ===========================

let stripeClient: Stripe | null = null;

/**
 * Stripeクライアントを初期化
 */
export function initStripe(apiKey?: string): Stripe {
  const key = apiKey || process.env.STRIPE_SECRET_KEY;
  if (!key) {
    throw new Error('STRIPE_SECRET_KEY environment variable is required');
  }

  stripeClient = new Stripe(key, {
    apiVersion: '2024-12-18.acacia',
    typescript: true,
  });

  return stripeClient;
}

/**
 * Stripeクライアントを取得（未初期化の場合は自動初期化）
 */
export function getStripe(): Stripe {
  if (!stripeClient) {
    return initStripe();
  }
  return stripeClient;
}

// ===========================
// Price ID Mapping (プラン → Stripe Price ID)
// ===========================

const PLAN_PRICE_MAP: Record<string, string> = {
  free: '', // Freeプランは決済不要
  pro: process.env.STRIPE_PRICE_PRO || 'price_pro_default',
  enterprise: process.env.STRIPE_PRICE_ENTERPRISE || 'price_enterprise_default',
};

/**
 * プランIDからStripe Price IDを取得
 */
function getPriceId(planId: string): string {
  const priceId = PLAN_PRICE_MAP[planId];
  if (!priceId) {
    throw new Error(`Invalid plan ID: ${planId}`);
  }
  return priceId;
}

// ===========================
// Subscription Management
// ===========================

/**
 * サブスクリプションを作成
 *
 * 1. Stripe Customerを作成（存在しない場合）
 * 2. Stripe Subscriptionを作成
 * 3. DB subscriptionsテーブルを更新
 *
 * @param params - userId, planId, paymentMethodId (optional)
 * @returns Stripe Subscription ID
 */
export async function createSubscription(params: CreateSubscriptionParams): Promise<string> {
  const { userId, planId, paymentMethodId } = params;
  const stripe = getStripe();
  const db = getDb();

  return withTransaction(async (tx) => {
    // 1. 既存subscriptionレコードを取得
    const existingSub = await tx
      .select()
      .from(subscriptions)
      .where(eq(subscriptions.userId, userId))
      .limit(1);

    let stripeCustomerId: string;

    if (existingSub.length > 0 && existingSub[0].metadata?.stripeCustomerId) {
      // 既存CustomerIDを再利用
      stripeCustomerId = existingSub[0].metadata.stripeCustomerId;
    } else {
      // 新規Customer作成
      const customer = await stripe.customers.create({
        metadata: { userId },
      });
      stripeCustomerId = customer.id;
    }

    // 2. Payment Methodをアタッチ（指定されている場合）
    if (paymentMethodId) {
      await stripe.paymentMethods.attach(paymentMethodId, {
        customer: stripeCustomerId,
      });

      await stripe.customers.update(stripeCustomerId, {
        invoice_settings: {
          default_payment_method: paymentMethodId,
        },
      });
    }

    // 3. Subscriptionを作成
    const priceId = getPriceId(planId);
    const subscription = await stripe.subscriptions.create({
      customer: stripeCustomerId,
      items: [{ price: priceId }],
      metadata: { userId, planId },
      expand: ['latest_invoice.payment_intent'],
    });

    // 4. DBを更新
    const now = new Date();
    const currentPeriodStart = new Date(subscription.current_period_start * 1000);
    const currentPeriodEnd = new Date(subscription.current_period_end * 1000);

    if (existingSub.length > 0) {
      // 既存レコード更新
      await tx
        .update(subscriptions)
        .set({
          plan: planId,
          status: subscription.status,
          currentPeriodStart,
          currentPeriodEnd,
          metadata: {
            ...existingSub[0].metadata,
            stripeCustomerId,
            stripeSubscriptionId: subscription.id,
          },
          updatedAt: now,
        })
        .where(eq(subscriptions.userId, userId));
    } else {
      // 新規レコード作成
      await tx.insert(subscriptions).values({
        userId,
        plan: planId,
        status: subscription.status,
        currentPeriodStart,
        currentPeriodEnd,
        metadata: {
          stripeCustomerId,
          stripeSubscriptionId: subscription.id,
        },
        createdAt: now,
        updatedAt: now,
      });
    }

    // 5. Usage Logを記録
    await tx.insert(usageLogs).values({
      userId,
      action: 'subscription_created',
      resourceType: 'subscription',
      resourceId: userId,
      metadata: {
        planId,
        stripeSubscriptionId: subscription.id,
      },
      timestamp: now,
    });

    return subscription.id;
  });
}

/**
 * サブスクリプションステータスを取得
 *
 * @param userId - ユーザーID
 * @returns サブスクリプション情報 or null
 */
export async function getSubscriptionStatus(userId: string): Promise<SubscriptionStatus | null> {
  const db = getDb();

  const result = await db
    .select()
    .from(subscriptions)
    .where(eq(subscriptions.userId, userId))
    .limit(1);

  if (result.length === 0) {
    return null;
  }

  const sub = result[0];

  return {
    userId: sub.userId,
    plan: sub.plan,
    status: sub.status,
    currentPeriodStart: sub.currentPeriodStart,
    currentPeriodEnd: sub.currentPeriodEnd,
    cancelAt: sub.cancelAt || null,
    stripeCustomerId: sub.metadata?.stripeCustomerId,
    stripeSubscriptionId: sub.metadata?.stripeSubscriptionId,
  };
}

/**
 * サブスクリプションをキャンセル
 *
 * - 即座に停止ではなく、期間末にキャンセル (cancel_at_period_end)
 * - DBのcancelAt, cancelledAtを更新
 *
 * @param userId - ユーザーID
 * @returns キャンセル成功フラグ
 */
export async function cancelSubscription(userId: string): Promise<boolean> {
  const stripe = getStripe();
  const db = getDb();

  return withTransaction(async (tx) => {
    // 1. DB subscriptionを取得
    const result = await tx
      .select()
      .from(subscriptions)
      .where(eq(subscriptions.userId, userId))
      .limit(1);

    if (result.length === 0) {
      throw new Error(`Subscription not found for userId: ${userId}`);
    }

    const sub = result[0];
    const stripeSubscriptionId = sub.metadata?.stripeSubscriptionId;

    if (!stripeSubscriptionId) {
      throw new Error('Stripe subscription ID not found in metadata');
    }

    // 2. Stripe APIでキャンセル (期間末)
    const updatedSubscription = await stripe.subscriptions.update(stripeSubscriptionId, {
      cancel_at_period_end: true,
    });

    const cancelAt = updatedSubscription.cancel_at
      ? new Date(updatedSubscription.cancel_at * 1000)
      : null;

    // 3. DBを更新
    const now = new Date();
    await tx
      .update(subscriptions)
      .set({
        status: updatedSubscription.status,
        cancelAt,
        cancelledAt: now,
        updatedAt: now,
      })
      .where(eq(subscriptions.userId, userId));

    // 4. Usage Logを記録
    await tx.insert(usageLogs).values({
      userId,
      action: 'subscription_cancelled',
      resourceType: 'subscription',
      resourceId: userId,
      metadata: {
        stripeSubscriptionId,
        cancelAt: cancelAt?.toISOString(),
      },
      timestamp: now,
    });

    return true;
  });
}

// ===========================
// Webhook Handling
// ===========================

/**
 * Stripe Webhookイベントをハンドリング
 *
 * サポート対象イベント:
 * - customer.subscription.created
 * - customer.subscription.updated
 * - customer.subscription.deleted
 * - invoice.paid
 * - invoice.payment_failed
 *
 * @param event - Webhook Event
 */
export async function handleWebhook(event: WebhookEvent): Promise<void> {
  const eventType = event.type;
  const data = event.data.object;

  switch (eventType) {
    case 'customer.subscription.created':
      await handleSubscriptionCreated(data);
      break;

    case 'customer.subscription.updated':
      await handleSubscriptionUpdated(data);
      break;

    case 'customer.subscription.deleted':
      await handleSubscriptionDeleted(data);
      break;

    case 'invoice.paid':
      await handleInvoicePaid(data);
      break;

    case 'invoice.payment_failed':
      await handleInvoicePaymentFailed(data);
      break;

    default:
      console.warn(`Unhandled webhook event type: ${eventType}`);
  }
}

/**
 * subscription.created イベント
 */
async function handleSubscriptionCreated(subscription: any): Promise<void> {
  const db = getDb();
  const userId = subscription.metadata?.userId;

  if (!userId) {
    console.error('userId not found in subscription metadata');
    return;
  }

  const planId = subscription.metadata?.planId || 'pro';
  const now = new Date();

  await withTransaction(async (tx) => {
    await tx.insert(subscriptions).values({
      userId,
      plan: planId,
      status: subscription.status,
      currentPeriodStart: new Date(subscription.current_period_start * 1000),
      currentPeriodEnd: new Date(subscription.current_period_end * 1000),
      metadata: {
        stripeCustomerId: subscription.customer,
        stripeSubscriptionId: subscription.id,
      },
      createdAt: now,
      updatedAt: now,
    });
  });
}

/**
 * subscription.updated イベント
 */
async function handleSubscriptionUpdated(subscription: any): Promise<void> {
  const db = getDb();
  const userId = subscription.metadata?.userId;

  if (!userId) {
    console.error('userId not found in subscription metadata');
    return;
  }

  const now = new Date();

  await withTransaction(async (tx) => {
    await tx
      .update(subscriptions)
      .set({
        status: subscription.status,
        currentPeriodStart: new Date(subscription.current_period_start * 1000),
        currentPeriodEnd: new Date(subscription.current_period_end * 1000),
        cancelAt: subscription.cancel_at ? new Date(subscription.cancel_at * 1000) : null,
        updatedAt: now,
      })
      .where(eq(subscriptions.userId, userId));
  });
}

/**
 * subscription.deleted イベント
 */
async function handleSubscriptionDeleted(subscription: any): Promise<void> {
  const db = getDb();
  const userId = subscription.metadata?.userId;

  if (!userId) {
    console.error('userId not found in subscription metadata');
    return;
  }

  const now = new Date();

  await withTransaction(async (tx) => {
    await tx
      .update(subscriptions)
      .set({
        status: 'cancelled',
        cancelledAt: now,
        updatedAt: now,
      })
      .where(eq(subscriptions.userId, userId));
  });
}

/**
 * invoice.paid イベント
 */
async function handleInvoicePaid(invoice: any): Promise<void> {
  const db = getDb();
  const customerId = invoice.customer;

  // CustomerIDからuserIdを逆引き
  const result = await db
    .select()
    .from(subscriptions)
    .where(eq(subscriptions.metadata, { stripeCustomerId: customerId }))
    .limit(1);

  if (result.length === 0) {
    console.warn(`Subscription not found for customerId: ${customerId}`);
    return;
  }

  const userId = result[0].userId;
  const now = new Date();

  // Usage Logに記録
  await db.insert(usageLogs).values({
    userId,
    action: 'invoice_paid',
    resourceType: 'subscription',
    resourceId: userId,
    cost: invoice.amount_paid, // Stripeは整数（セント）で返す
    metadata: {
      invoiceId: invoice.id,
      amountPaid: invoice.amount_paid,
      currency: invoice.currency,
    },
    timestamp: now,
  });
}

/**
 * invoice.payment_failed イベント
 */
async function handleInvoicePaymentFailed(invoice: any): Promise<void> {
  const db = getDb();
  const customerId = invoice.customer;

  // CustomerIDからuserIdを逆引き
  const result = await db
    .select()
    .from(subscriptions)
    .where(eq(subscriptions.metadata, { stripeCustomerId: customerId }))
    .limit(1);

  if (result.length === 0) {
    console.warn(`Subscription not found for customerId: ${customerId}`);
    return;
  }

  const userId = result[0].userId;
  const now = new Date();

  // ステータスを'past_due'に更新
  await withTransaction(async (tx) => {
    await tx
      .update(subscriptions)
      .set({
        status: 'past_due',
        updatedAt: now,
      })
      .where(eq(subscriptions.userId, userId));

    // Usage Logに記録
    await tx.insert(usageLogs).values({
      userId,
      action: 'invoice_payment_failed',
      resourceType: 'subscription',
      resourceId: userId,
      metadata: {
        invoiceId: invoice.id,
        attemptCount: invoice.attempt_count,
      },
      timestamp: now,
    });
  });
}

// ===========================
// Webhook Signature Verification
// ===========================

/**
 * Webhook署名を検証
 *
 * @param payload - リクエストボディ (raw string)
 * @param signature - Stripe-Signature ヘッダー
 * @param secret - Webhook Secret
 * @returns 検証済みイベント
 */
export function verifyWebhookSignature(
  payload: string | Buffer,
  signature: string,
  secret?: string
): Stripe.Event {
  const stripe = getStripe();
  const webhookSecret = secret || process.env.STRIPE_WEBHOOK_SECRET;

  if (!webhookSecret) {
    throw new Error('STRIPE_WEBHOOK_SECRET environment variable is required');
  }

  return stripe.webhooks.constructEvent(payload, signature, webhookSecret);
}

// ===========================
// Exports
// ===========================

export default {
  initStripe,
  getStripe,
  createSubscription,
  getSubscriptionStatus,
  cancelSubscription,
  handleWebhook,
  verifyWebhookSignature,
};
