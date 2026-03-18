/**
 * Layer 2 Test: stripe-service.ts
 *
 * 検証内容:
 * - createSubscription のトランザクション整合性
 * - getSubscriptionStatus の正常系・異常系
 * - cancelSubscription のStripe連携とDB更新
 * - handleWebhook の各イベント処理（subscription.*, invoice.*）
 * - verifyWebhookSignature の署名検証
 *
 * モック:
 * - Stripe API (stripe-mock library または手動モック)
 * - DB (SQLite インメモリ)
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import Stripe from 'stripe';
import {
  initStripe,
  createSubscription,
  getSubscriptionStatus,
  cancelSubscription,
  handleWebhook,
  verifyWebhookSignature,
} from '../stripe-service.js';
import { initDb, closeDb, getDb } from '../../db/index.js';
import { subscriptions, usageLogs, users } from '../../db/schema.js';
import { eq } from 'drizzle-orm';

// ===========================
// Stripe API モック
// ===========================

const mockStripeCustomersCreate = vi.fn();
const mockStripePaymentMethodsAttach = vi.fn();
const mockStripeCustomersUpdate = vi.fn();
const mockStripeSubscriptionsCreate = vi.fn();
const mockStripeSubscriptionsUpdate = vi.fn();
const mockStripeWebhooksConstructEvent = vi.fn();

vi.mock('stripe', () => {
  return {
    default: vi.fn().mockImplementation(() => ({
      customers: {
        create: mockStripeCustomersCreate,
        update: mockStripeCustomersUpdate,
      },
      paymentMethods: {
        attach: mockStripePaymentMethodsAttach,
      },
      subscriptions: {
        create: mockStripeSubscriptionsCreate,
        update: mockStripeSubscriptionsUpdate,
      },
      webhooks: {
        constructEvent: mockStripeWebhooksConstructEvent,
      },
    })),
  };
});

// ===========================
// Test Setup
// ===========================

describe('stripe-service Layer 2 Test', () => {
  let db: ReturnType<typeof getDb>;
  let testUserId: string;

  beforeEach(async () => {
    // SQLiteインメモリDBを初期化
    db = initDb({ type: 'sqlite', filename: ':memory:' });

    // テーブル作成 (手動スキーマ適用)
    const sqlite = db as any;
    sqlite.run(`
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        username TEXT,
        password_hash TEXT NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        last_login_at DATETIME,
        is_active INTEGER DEFAULT 1,
        metadata TEXT
      )
    `);

    sqlite.run(`
      CREATE TABLE subscriptions (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL UNIQUE,
        plan TEXT NOT NULL,
        status TEXT NOT NULL,
        current_period_start DATETIME NOT NULL,
        current_period_end DATETIME NOT NULL,
        cancel_at DATETIME,
        cancelled_at DATETIME,
        trial_start DATETIME,
        trial_end DATETIME,
        metadata TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);

    sqlite.run(`
      CREATE TABLE usage_logs (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        action TEXT NOT NULL,
        resource_type TEXT,
        resource_id TEXT,
        tokens_used INTEGER,
        cost INTEGER,
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        metadata TEXT
      )
    `);

    // テストユーザー作成
    testUserId = 'test-user-' + Date.now();
    await db.insert(users).values({
      id: testUserId,
      email: 'test@example.com',
      passwordHash: 'hashed_password',
      createdAt: new Date(),
      updatedAt: new Date(),
      isActive: true,
    });

    // Stripe初期化（ダミーキー）
    initStripe('sk_test_dummy_key');

    // モック初期化
    vi.clearAllMocks();
  });

  afterEach(async () => {
    await closeDb();
  });

  // ===========================
  // createSubscription Tests
  // ===========================

  describe('createSubscription', () => {
    it('新規サブスクリプションを作成できること（正常系）', async () => {
      // Arrange
      const mockCustomer = { id: 'cus_test123' };
      const mockSubscription = {
        id: 'sub_test123',
        customer: 'cus_test123',
        status: 'active',
        current_period_start: Math.floor(Date.now() / 1000),
        current_period_end: Math.floor((Date.now() + 30 * 24 * 60 * 60 * 1000) / 1000),
        metadata: { userId: testUserId, planId: 'pro' },
      };

      mockStripeCustomersCreate.mockResolvedValue(mockCustomer);
      mockStripeSubscriptionsCreate.mockResolvedValue(mockSubscription);

      // Act
      const subscriptionId = await createSubscription({
        userId: testUserId,
        planId: 'pro',
      });

      // Assert
      expect(subscriptionId).toBe('sub_test123');
      expect(mockStripeCustomersCreate).toHaveBeenCalledWith({
        metadata: { userId: testUserId },
      });
      expect(mockStripeSubscriptionsCreate).toHaveBeenCalled();

      // DBに正しく保存されていること
      const dbSub = await db
        .select()
        .from(subscriptions)
        .where(eq(subscriptions.userId, testUserId))
        .limit(1);

      expect(dbSub.length).toBe(1);
      expect(dbSub[0].plan).toBe('pro');
      expect(dbSub[0].status).toBe('active');
      expect(dbSub[0].metadata?.stripeSubscriptionId).toBe('sub_test123');
    });

    it('Payment Method指定時、Stripe APIが正しく呼ばれること', async () => {
      // Arrange
      const mockCustomer = { id: 'cus_test456' };
      const mockSubscription = {
        id: 'sub_test456',
        customer: 'cus_test456',
        status: 'active',
        current_period_start: Math.floor(Date.now() / 1000),
        current_period_end: Math.floor((Date.now() + 30 * 24 * 60 * 60 * 1000) / 1000),
        metadata: { userId: testUserId, planId: 'pro' },
      };

      mockStripeCustomersCreate.mockResolvedValue(mockCustomer);
      mockStripePaymentMethodsAttach.mockResolvedValue({});
      mockStripeCustomersUpdate.mockResolvedValue({});
      mockStripeSubscriptionsCreate.mockResolvedValue(mockSubscription);

      // Act
      await createSubscription({
        userId: testUserId,
        planId: 'pro',
        paymentMethodId: 'pm_test123',
      });

      // Assert
      expect(mockStripePaymentMethodsAttach).toHaveBeenCalledWith('pm_test123', {
        customer: 'cus_test456',
      });
      expect(mockStripeCustomersUpdate).toHaveBeenCalledWith('cus_test456', {
        invoice_settings: {
          default_payment_method: 'pm_test123',
        },
      });
    });

    it('既存CustomerがDB上にある場合、Customerを再利用すること', async () => {
      // Arrange: 既存サブスクリプションをDB挿入
      await db.insert(subscriptions).values({
        id: 'existing-sub-id',
        userId: testUserId,
        plan: 'free',
        status: 'active',
        currentPeriodStart: new Date(),
        currentPeriodEnd: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
        metadata: {
          stripeCustomerId: 'cus_existing',
        },
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const mockSubscription = {
        id: 'sub_new123',
        customer: 'cus_existing',
        status: 'active',
        current_period_start: Math.floor(Date.now() / 1000),
        current_period_end: Math.floor((Date.now() + 30 * 24 * 60 * 60 * 1000) / 1000),
        metadata: { userId: testUserId, planId: 'pro' },
      };

      mockStripeSubscriptionsCreate.mockResolvedValue(mockSubscription);

      // Act
      await createSubscription({
        userId: testUserId,
        planId: 'pro',
      });

      // Assert: 新規Customer作成が呼ばれないこと
      expect(mockStripeCustomersCreate).not.toHaveBeenCalled();

      // DBが正しく更新されていること
      const dbSub = await db
        .select()
        .from(subscriptions)
        .where(eq(subscriptions.userId, testUserId))
        .limit(1);

      expect(dbSub[0].plan).toBe('pro');
      expect(dbSub[0].metadata?.stripeCustomerId).toBe('cus_existing');
    });

    it('トランザクション内でエラーが発生した場合、ロールバックされること', async () => {
      // Arrange: Stripe APIがエラーをスロー
      mockStripeCustomersCreate.mockRejectedValue(new Error('Stripe API Error'));

      // Act & Assert
      await expect(
        createSubscription({
          userId: testUserId,
          planId: 'pro',
        })
      ).rejects.toThrow('Stripe API Error');

      // DBに何も保存されていないこと
      const dbSub = await db
        .select()
        .from(subscriptions)
        .where(eq(subscriptions.userId, testUserId))
        .limit(1);

      expect(dbSub.length).toBe(0);
    });
  });

  // ===========================
  // getSubscriptionStatus Tests
  // ===========================

  describe('getSubscriptionStatus', () => {
    it('サブスクリプション情報を正しく取得できること', async () => {
      // Arrange
      const now = new Date();
      const periodEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

      await db.insert(subscriptions).values({
        id: 'sub-id-1',
        userId: testUserId,
        plan: 'pro',
        status: 'active',
        currentPeriodStart: now,
        currentPeriodEnd: periodEnd,
        metadata: {
          stripeCustomerId: 'cus_test',
          stripeSubscriptionId: 'sub_test',
        },
        createdAt: now,
        updatedAt: now,
      });

      // Act
      const status = await getSubscriptionStatus(testUserId);

      // Assert
      expect(status).not.toBeNull();
      expect(status?.userId).toBe(testUserId);
      expect(status?.plan).toBe('pro');
      expect(status?.status).toBe('active');
      expect(status?.stripeSubscriptionId).toBe('sub_test');
    });

    it('サブスクリプションが存在しない場合、nullを返すこと', async () => {
      // Act
      const status = await getSubscriptionStatus('non-existent-user');

      // Assert
      expect(status).toBeNull();
    });
  });

  // ===========================
  // cancelSubscription Tests
  // ===========================

  describe('cancelSubscription', () => {
    it('サブスクリプションを期間末にキャンセルできること', async () => {
      // Arrange
      const now = new Date();
      const periodEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

      await db.insert(subscriptions).values({
        id: 'sub-id-cancel',
        userId: testUserId,
        plan: 'pro',
        status: 'active',
        currentPeriodStart: now,
        currentPeriodEnd: periodEnd,
        metadata: {
          stripeSubscriptionId: 'sub_cancel_test',
        },
        createdAt: now,
        updatedAt: now,
      });

      const mockUpdatedSubscription = {
        id: 'sub_cancel_test',
        status: 'active',
        cancel_at: Math.floor(periodEnd.getTime() / 1000),
      };

      mockStripeSubscriptionsUpdate.mockResolvedValue(mockUpdatedSubscription);

      // Act
      const result = await cancelSubscription(testUserId);

      // Assert
      expect(result).toBe(true);
      expect(mockStripeSubscriptionsUpdate).toHaveBeenCalledWith('sub_cancel_test', {
        cancel_at_period_end: true,
      });

      // DBが更新されていること
      const dbSub = await db
        .select()
        .from(subscriptions)
        .where(eq(subscriptions.userId, testUserId))
        .limit(1);

      expect(dbSub[0].cancelAt).not.toBeNull();
      expect(dbSub[0].cancelledAt).not.toBeNull();
    });

    it('サブスクリプションが存在しない場合、エラーをスローすること', async () => {
      // Act & Assert
      await expect(cancelSubscription('non-existent-user')).rejects.toThrow(
        'Subscription not found'
      );
    });
  });

  // ===========================
  // handleWebhook Tests
  // ===========================

  describe('handleWebhook', () => {
    it('subscription.created イベントを正しく処理できること', async () => {
      // Arrange
      const event = {
        id: 'evt_test1',
        type: 'customer.subscription.created',
        data: {
          object: {
            id: 'sub_webhook_test',
            customer: 'cus_webhook_test',
            status: 'active',
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end: Math.floor((Date.now() + 30 * 24 * 60 * 60 * 1000) / 1000),
            metadata: {
              userId: testUserId,
              planId: 'pro',
            },
          },
        },
      };

      // Act
      await handleWebhook(event);

      // Assert
      const dbSub = await db
        .select()
        .from(subscriptions)
        .where(eq(subscriptions.userId, testUserId))
        .limit(1);

      expect(dbSub.length).toBe(1);
      expect(dbSub[0].plan).toBe('pro');
      expect(dbSub[0].status).toBe('active');
    });

    it('subscription.updated イベントを正しく処理できること', async () => {
      // Arrange: 既存サブスクリプション
      await db.insert(subscriptions).values({
        id: 'sub-id-update',
        userId: testUserId,
        plan: 'pro',
        status: 'active',
        currentPeriodStart: new Date(),
        currentPeriodEnd: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const event = {
        id: 'evt_test2',
        type: 'customer.subscription.updated',
        data: {
          object: {
            id: 'sub_webhook_test',
            status: 'past_due',
            current_period_start: Math.floor(Date.now() / 1000),
            current_period_end: Math.floor((Date.now() + 30 * 24 * 60 * 60 * 1000) / 1000),
            cancel_at: Math.floor((Date.now() + 60 * 24 * 60 * 60 * 1000) / 1000),
            metadata: {
              userId: testUserId,
            },
          },
        },
      };

      // Act
      await handleWebhook(event);

      // Assert
      const dbSub = await db
        .select()
        .from(subscriptions)
        .where(eq(subscriptions.userId, testUserId))
        .limit(1);

      expect(dbSub[0].status).toBe('past_due');
      expect(dbSub[0].cancelAt).not.toBeNull();
    });

    it('subscription.deleted イベントを正しく処理できること', async () => {
      // Arrange
      await db.insert(subscriptions).values({
        id: 'sub-id-delete',
        userId: testUserId,
        plan: 'pro',
        status: 'active',
        currentPeriodStart: new Date(),
        currentPeriodEnd: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const event = {
        id: 'evt_test3',
        type: 'customer.subscription.deleted',
        data: {
          object: {
            id: 'sub_webhook_test',
            metadata: {
              userId: testUserId,
            },
          },
        },
      };

      // Act
      await handleWebhook(event);

      // Assert
      const dbSub = await db
        .select()
        .from(subscriptions)
        .where(eq(subscriptions.userId, testUserId))
        .limit(1);

      expect(dbSub[0].status).toBe('cancelled');
      expect(dbSub[0].cancelledAt).not.toBeNull();
    });

    it('未サポートイベントでもエラーをスローしないこと', async () => {
      // Arrange
      const event = {
        id: 'evt_test_unknown',
        type: 'customer.created',
        data: {
          object: {},
        },
      };

      // Act & Assert (エラーが発生しないこと)
      await expect(handleWebhook(event)).resolves.not.toThrow();
    });
  });

  // ===========================
  // verifyWebhookSignature Tests
  // ===========================

  describe('verifyWebhookSignature', () => {
    it('署名検証が正しく実行されること', () => {
      // Arrange
      const payload = JSON.stringify({ type: 'test.event' });
      const signature = 't=123456789,v1=test_signature';
      const mockEvent = { id: 'evt_verified', type: 'test.event', data: { object: {} } };

      mockStripeWebhooksConstructEvent.mockReturnValue(mockEvent);

      // Act
      const event = verifyWebhookSignature(payload, signature, 'whsec_test_secret');

      // Assert
      expect(event).toEqual(mockEvent);
      expect(mockStripeWebhooksConstructEvent).toHaveBeenCalledWith(
        payload,
        signature,
        'whsec_test_secret'
      );
    });

    it('Webhook Secretが未設定の場合、エラーをスローすること', () => {
      // Arrange
      delete process.env.STRIPE_WEBHOOK_SECRET;

      // Act & Assert
      expect(() => verifyWebhookSignature('payload', 'signature')).toThrow(
        'STRIPE_WEBHOOK_SECRET environment variable is required'
      );
    });
  });
});
