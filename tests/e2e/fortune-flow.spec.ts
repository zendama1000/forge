/**
 * 占いフロー E2E テスト (Layer 2 - L2-001)
 *
 * フォーム送信 → API呼び出し → 結果カード表示の統合フロー
 *
 * 前提条件:
 * - サーバーは起動済み (http://localhost:3000)
 * - /api/fortune は page.route() でモック
 * - テストは冪等（前後でデータ変更なし）
 *
 * コマンド: npx playwright test tests/e2e/fortune-flow.spec.ts
 */

import { test, expect } from '@playwright/test';

// ─── モックレスポンス ──────────────────────────────────────────────────────────

const MOCK_FORTUNE_RESPONSE = {
  categories: [
    {
      name: '恋愛運',
      totalScore: 75,
      templateText: '恋愛運は良好です。積極的に行動することで新たな出会いが期待できます。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 70 + i })),
    },
    {
      name: '仕事運',
      totalScore: 60,
      templateText: '仕事運は普通です。着実にコツコツと取り組みましょう。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 55 + i })),
    },
    {
      name: '金運',
      totalScore: 50,
      templateText: '金運は安定しています。無駄遣いに気をつけましょう。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 45 + i })),
    },
    {
      name: '健康運',
      totalScore: 80,
      templateText: '健康運は優れています。体を動かす絶好の機会です。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 75 + i })),
    },
  ],
};

// ─── L2-001: 占いフロー統合テスト ────────────────────────────────────────────

test.describe('L2-001: 占いフロー統合テスト', () => {
  // behavior: 7次元パラメータ入力フィールドが全て表示され、0-100の値を設定できる
  test('7つの次元入力フィールド（range input）が表示され、min=0・max=100の属性を持つ', async ({
    page,
  }) => {
    await page.goto('/fortune');

    // 7つの range input が存在する
    const rangeInputs = page.locator('input[type="range"]');
    await expect(rangeInputs).toHaveCount(7);

    // 各スライダーが min=0, max=100 を持つ
    for (let i = 0; i < 7; i++) {
      await expect(rangeInputs.nth(i)).toHaveAttribute('min', '0');
      await expect(rangeInputs.nth(i)).toHaveAttribute('max', '100');
    }
  });

  // behavior: 占い実行ボタンクリック → POST /api/fortune にリクエスト送信
  // behavior: APIレスポンス受信後 → FortuneCardコンポーネントで結果カード（カテゴリ名・プログレスバー・スコア値）が表示される
  test('フォーム送信→POST /api/fortune→結果カード表示の統合フロー', async ({ page }) => {
    let capturedRequestBody: { dimensions?: number[] } | null = null;

    // POST /api/fortune をモック
    await page.route('**/api/fortune', async (route) => {
      const request = route.request();
      expect(request.method()).toBe('POST');
      capturedRequestBody = request.postDataJSON() as { dimensions?: number[] };

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(MOCK_FORTUNE_RESPONSE),
      });
    });

    await page.goto('/fortune');

    // 次元スライダーに値を設定（0-100 の範囲内）
    const rangeInputs = page.locator('input[type="range"]');
    for (let i = 0; i < 7; i++) {
      await rangeInputs.nth(i).fill('50');
    }

    // 占い実行ボタンをクリック
    const submitButton = page.locator('[data-testid="fortune-submit"]');
    await expect(submitButton).toBeVisible();
    await submitButton.click();

    // 結果カードが4件表示されることを確認
    const resultCards = page.locator('[data-testid="fortune-card"]');
    await expect(resultCards).toHaveCount(4);

    // リクエストボディに7次元が含まれることを確認
    expect(capturedRequestBody).not.toBeNull();
    expect(capturedRequestBody?.dimensions).toHaveLength(7);
    capturedRequestBody?.dimensions?.forEach((v) => {
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThanOrEqual(100);
    });
  });

  // behavior: API通信中 → ローディング状態が表示される
  test('API通信中にローディング状態が表示され、完了後に消える', async ({ page }) => {
    // 遅延レスポンスでローディング確認
    let resolveRoute: (() => void) | null = null;

    await page.route('**/api/fortune', async (route) => {
      // 外部から resolve できるように Promise を保持
      await new Promise<void>((resolve) => {
        resolveRoute = resolve;
      });
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(MOCK_FORTUNE_RESPONSE),
      });
    });

    await page.goto('/fortune');

    const submitButton = page.locator('[data-testid="fortune-submit"]');
    await submitButton.click();

    // ローディング表示の確認
    const loading = page.locator('[data-testid="fortune-loading"]');
    await expect(loading).toBeVisible({ timeout: 3000 });

    // レスポンスを解放
    resolveRoute?.();

    // ローディングが消えることを確認
    await expect(loading).not.toBeVisible({ timeout: 5000 });
  });

  // behavior: APIレスポンス受信後 → FortuneCardコンポーネントで結果カード（カテゴリ名・プログレスバー・スコア値）が表示される
  test('結果カードにカテゴリ名・スコア値・プログレスバーが表示される', async ({ page }) => {
    await page.route('**/api/fortune', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(MOCK_FORTUNE_RESPONSE),
      });
    });

    await page.goto('/fortune');

    const submitButton = page.locator('[data-testid="fortune-submit"]');
    await submitButton.click();

    // カテゴリ名の確認
    const cardNames = page.locator('[data-testid="fortune-card-name"]');
    await expect(cardNames).toHaveCount(4);
    await expect(cardNames.first()).toHaveText('恋愛運');

    // スコア値の確認（75が含まれる）
    const cardScores = page.locator('[data-testid="fortune-card-score"]');
    await expect(cardScores).toHaveCount(4);
    await expect(cardScores.first()).toContainText('75');

    // プログレスバーの確認
    const progressBars = page.locator('[data-testid="fortune-card-progress"]');
    await expect(progressBars).toHaveCount(4);
  });

  // behavior: [追加] 7次元スライダーの値変更がリクエストに反映される
  test('[追加] スライダー値を変更するとリクエストボディの dimensions に反映される', async ({
    page,
  }) => {
    let capturedDimensions: number[] | null = null;

    await page.route('**/api/fortune', async (route) => {
      const body = route.request().postDataJSON() as { dimensions: number[] };
      capturedDimensions = body.dimensions;
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(MOCK_FORTUNE_RESPONSE),
      });
    });

    await page.goto('/fortune');

    // 最初のスライダーを30に設定
    const firstInput = page.locator('input[type="range"]').first();
    await firstInput.fill('30');

    const submitButton = page.locator('[data-testid="fortune-submit"]');
    await submitButton.click();

    // 結果表示を待つ
    await expect(page.locator('[data-testid="fortune-card"]').first()).toBeVisible({
      timeout: 5000,
    });

    // リクエストに値が反映されている
    expect(capturedDimensions).not.toBeNull();
    expect(capturedDimensions).toHaveLength(7);
    expect(capturedDimensions?.[0]).toBe(30);
  });
});
