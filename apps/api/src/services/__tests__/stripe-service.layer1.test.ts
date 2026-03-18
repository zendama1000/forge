/**
 * Layer 1 Test: stripe-service.ts
 *
 * 検証内容:
 * - ファイルの存在確認
 * - 必須関数のエクスポート確認
 * - 基本的な型定義の確認
 */

import { describe, it, expect } from 'vitest';
import * as stripeService from '../stripe-service.js';

describe('stripe-service Layer 1 Test', () => {
  // ファイルが正常にロードできることを確認
  it('ファイルが正常にロードできること', () => {
    expect(stripeService).toBeDefined();
  });

  // 必須関数がエクスポートされていることを確認
  it('createSubscription関数がエクスポートされていること', () => {
    expect(typeof stripeService.createSubscription).toBe('function');
  });

  it('getSubscriptionStatus関数がエクスポートされていること', () => {
    expect(typeof stripeService.getSubscriptionStatus).toBe('function');
  });

  it('cancelSubscription関数がエクスポートされていること', () => {
    expect(typeof stripeService.cancelSubscription).toBe('function');
  });

  it('handleWebhook関数がエクスポートされていること', () => {
    expect(typeof stripeService.handleWebhook).toBe('function');
  });

  it('verifyWebhookSignature関数がエクスポートされていること', () => {
    expect(typeof stripeService.verifyWebhookSignature).toBe('function');
  });

  it('initStripe関数がエクスポートされていること', () => {
    expect(typeof stripeService.initStripe).toBe('function');
  });

  it('getStripe関数がエクスポートされていること', () => {
    expect(typeof stripeService.getStripe).toBe('function');
  });

  // デフォルトエクスポートの確認
  it('デフォルトエクスポートが存在すること', () => {
    expect(stripeService.default).toBeDefined();
    expect(typeof stripeService.default.createSubscription).toBe('function');
    expect(typeof stripeService.default.handleWebhook).toBe('function');
  });
});
