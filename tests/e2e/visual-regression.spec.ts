/**
 * ビジュアルリグレッションテスト (Layer 2 - L2-007)
 *
 * 主要画面のスクリーンショットを撮影し、ベースラインとの差異を検出する。
 * animations: 'disabled' (playwright.config.ts) により安定したスクリーンショットを保証。
 *
 * 前提条件:
 * - サーバーは起動済み (http://localhost:3000)
 * - /api/fortune, /api/fortune/history は page.route() でモック
 * - テストは冪等（スナップショット更新は --update-snapshots フラグで行う）
 *
 * コマンド:
 *   初回ベースライン生成: npx playwright test tests/e2e/visual-regression.spec.ts --update-snapshots
 *   回帰チェック:         npx playwright test tests/e2e/visual-regression.spec.ts
 */

import { test, expect } from '@playwright/test';

// ─── モックレスポンス ──────────────────────────────────────────────────────────

const MOCK_FORTUNE_RESPONSE = {
  categories: [
    {
      id: 'love',
      name: '恋愛運',
      totalScore: 75,
      weightedScore: 75,
      templateText: '恋愛運は良好です。積極的に行動することで新たな出会いが期待できます。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({
        name: ['運気', '活力', '知性', '感情', '財運', '健康', '社交'][i],
        rawScore: 70 + i,
      })),
    },
    {
      id: 'work',
      name: '仕事運',
      totalScore: 60,
      weightedScore: 60,
      templateText: '仕事運は普通です。着実にコツコツと取り組みましょう。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({
        name: ['運気', '活力', '知性', '感情', '財運', '健康', '社交'][i],
        rawScore: 55 + i,
      })),
    },
    {
      id: 'money',
      name: '金運',
      totalScore: 50,
      weightedScore: 50,
      templateText: '金運は安定しています。無駄遣いに気をつけましょう。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({
        name: ['運気', '活力', '知性', '感情', '財運', '健康', '社交'][i],
        rawScore: 45 + i,
      })),
    },
    {
      id: 'health',
      name: '健康運',
      totalScore: 80,
      weightedScore: 80,
      templateText: '健康運は優れています。体を動かす絶好の機会です。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({
        name: ['運気', '活力', '知性', '感情', '財運', '健康', '社交'][i],
        rawScore: 75 + i,
      })),
    },
  ],
};

const MOCK_HISTORY_ENTRIES = [
  {
    id: 'uuid-001',
    createdAt: '2024-01-16T10:00:00.000Z',
    categories: [
      { name: '恋愛運', totalScore: 40, templateText: '恋愛運は低調です。' },
      { name: '仕事運', totalScore: 90, templateText: '仕事運は絶好調です。' },
      { name: '金運', totalScore: 70, templateText: '金運は良好です。' },
      { name: '健康運', totalScore: 55, templateText: '健康運は普通です。' },
    ],
  },
  {
    id: 'uuid-002',
    createdAt: '2024-01-15T14:30:00.000Z',
    categories: [
      { name: '恋愛運', totalScore: 75, templateText: '恋愛運は良好です。' },
      { name: '仕事運', totalScore: 60, templateText: '仕事運は普通です。' },
      { name: '金運', totalScore: 50, templateText: '金運は安定しています。' },
      { name: '健康運', totalScore: 80, templateText: '健康運は優れています。' },
    ],
  },
];

// ─── ヘルパー ─────────────────────────────────────────────────────────────────

async function setupFortuneMock(page: import('@playwright/test').Page): Promise<void> {
  await page.route('**/api/fortune', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(MOCK_FORTUNE_RESPONSE),
    });
  });
}

async function setupHistoryMock(
  page: import('@playwright/test').Page,
  entries: typeof MOCK_HISTORY_ENTRIES | never[] = MOCK_HISTORY_ENTRIES,
): Promise<void> {
  await page.route('**/api/fortune/history', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(entries),
    });
  });
}

// ─── L2-007: ビジュアルリグレッションテスト ──────────────────────────────────

test.describe('L2-007: ビジュアルリグレッション', () => {
  // ── 占いフォーム（入力画面）────────────────────────────────────────────────

  test.describe('占いフォーム画面', () => {
    // behavior: [追加] 占いフォーム（デスクトップ）のビジュアルが変化しない
    test('デスクトップ（1280x800）: 占いフォーム入力画面のスクリーンショット', async ({
      page,
    }) => {
      await page.setViewportSize({ width: 1280, height: 800 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      // 7つの range input が全て表示されるまで待機
      const rangeInputs = page.locator('input[type="range"]');
      await expect(rangeInputs).toHaveCount(7);

      await expect(page).toHaveScreenshot('fortune-form-desktop.png', {
        fullPage: true,
        maxDiffPixelRatio: 0.02,
      });
    });

    // behavior: [追加] 占いフォーム（モバイル）のビジュアルが変化しない
    test('モバイル（375x812）: 占いフォーム入力画面のスクリーンショット', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 812 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      // ページが安定するまで待機
      const rangeInputs = page.locator('input[type="range"]');
      await expect(rangeInputs).toHaveCount(7);

      await expect(page).toHaveScreenshot('fortune-form-mobile.png', {
        fullPage: true,
        maxDiffPixelRatio: 0.02,
      });
    });

    // behavior: [追加] 占いフォーム（タブレット）のビジュアルが変化しない
    test('タブレット（768x1024）: 占いフォーム入力画面のスクリーンショット', async ({ page }) => {
      await page.setViewportSize({ width: 768, height: 1024 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      const rangeInputs = page.locator('input[type="range"]');
      await expect(rangeInputs).toHaveCount(7);

      await expect(page).toHaveScreenshot('fortune-form-tablet.png', {
        fullPage: true,
        maxDiffPixelRatio: 0.02,
      });
    });
  });

  // ── 占い結果画面 ───────────────────────────────────────────────────────────

  test.describe('占い結果画面', () => {
    // behavior: [追加] 占い結果カード（デスクトップ）のビジュアルが変化しない
    test('デスクトップ（1280x800）: 占い結果カード表示のスクリーンショット', async ({ page }) => {
      await page.setViewportSize({ width: 1280, height: 800 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      // フォーム送信
      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // 結果カードが全件表示されるまで待機
      const resultCards = page.locator('[data-testid="fortune-card"]');
      await expect(resultCards).toHaveCount(4);

      await expect(page).toHaveScreenshot('fortune-result-desktop.png', {
        fullPage: true,
        maxDiffPixelRatio: 0.02,
      });
    });

    // behavior: [追加] 占い結果カード（モバイル）のビジュアルが変化しない
    test('モバイル（375x812）: 占い結果カード表示のスクリーンショット', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 812 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      const resultCards = page.locator('[data-testid="fortune-card"]');
      await expect(resultCards).toHaveCount(4);

      await expect(page).toHaveScreenshot('fortune-result-mobile.png', {
        fullPage: true,
        maxDiffPixelRatio: 0.02,
      });
    });
  });

  // ── 履歴画面 ───────────────────────────────────────────────────────────────

  test.describe('履歴画面', () => {
    // behavior: [追加] 履歴一覧画面（データあり）のビジュアルが変化しない
    test('デスクトップ（1280x800）: 履歴一覧表示のスクリーンショット', async ({ page }) => {
      await page.setViewportSize({ width: 1280, height: 800 });
      await setupHistoryMock(page);
      await page.goto('/history');

      // ページが安定するまで待機（要素の存在を前提にしない — visual regression が目的）
      await page.waitForLoadState('networkidle');
      await expect(page.locator('body')).toBeVisible();

      await expect(page).toHaveScreenshot('history-list-desktop.png', {
        fullPage: true,
        maxDiffPixelRatio: 0.02,
      });
    });

    // behavior: [追加] 履歴空状態のビジュアルが変化しない
    test('デスクトップ（1280x800）: 履歴空状態のスクリーンショット', async ({ page }) => {
      await page.setViewportSize({ width: 1280, height: 800 });
      await setupHistoryMock(page, []);
      await page.goto('/history');

      // ページが安定するまで待機
      await page.waitForLoadState('networkidle');
      await expect(page.locator('body')).toBeVisible();

      await expect(page).toHaveScreenshot('history-empty-desktop.png', {
        fullPage: true,
        maxDiffPixelRatio: 0.02,
      });
    });

    // behavior: [追加] 履歴一覧画面（モバイル）のビジュアルが変化しない
    test('モバイル（375x812）: 履歴一覧表示のスクリーンショット', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 812 });
      await setupHistoryMock(page);
      await page.goto('/history');

      // ページが安定するまで待機（visual regression が目的）
      await page.waitForLoadState('networkidle');
      await expect(page.locator('body')).toBeVisible();

      await expect(page).toHaveScreenshot('history-list-mobile.png', {
        fullPage: true,
        maxDiffPixelRatio: 0.02,
      });
    });
  });
});
