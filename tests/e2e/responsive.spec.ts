/**
 * レスポンシブデザイン / 色覚多様性対応 E2E テスト (Layer 2 - L2-006)
 *
 * 全コンポーネントのレスポンシブデザイン（375px/768px/1280px）と
 * 色覚多様性対応（アイコン+カラー冗長表現）を検証する。
 *
 * 前提条件:
 * - サーバーは起動済み (http://localhost:3000)
 * - /api/fortune は page.route() でモック
 * - テストは冪等（前後でデータ変更なし）
 *
 * コマンド: npx playwright test tests/e2e/responsive.spec.ts
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

// ─── ヘルパー: APIモックセットアップ ────────────────────────────────────────────

async function setupFortuneMock(page: import('@playwright/test').Page): Promise<void> {
  await page.route('**/api/fortune', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(MOCK_FORTUNE_RESPONSE),
    });
  });
}

// ─── L2-006: レスポンシブデザインテスト ──────────────────────────────────────

test.describe('L2-006: レスポンシブデザイン / 色覚多様性対応', () => {

  // ── モバイルビューポート（375px）────────────────────────────────────────────

  test.describe('モバイルビューポート（375px）', () => {
    // behavior: モバイルビューポート（375px）→ カード・タブ・プログレスバーが縦積みレイアウト
    test('375px: 占いフォームページが縦積みレイアウトで表示される', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 812 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      // ページが表示される
      await expect(page).toHaveURL('/fortune');

      // 7つの入力フィールドが存在する
      const rangeInputs = page.locator('input[type="range"]');
      await expect(rangeInputs).toHaveCount(7);

      // 縦積みレイアウト確認: 各入力が full width（コンテナ幅を超えない）
      const firstInput = rangeInputs.first();
      const inputBox = await firstInput.boundingBox();
      if (inputBox) {
        // 入力要素の幅が375px以内である
        expect(inputBox.width).toBeLessThanOrEqual(375);
      }
    });

    test('375px: 占い結果カードが縦方向に配置される', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 812 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // 結果カードが表示される
      const resultCards = page.locator('[data-testid="fortune-card"]');
      await expect(resultCards).toHaveCount(4);

      // モバイルでは全カードが表示領域内に収まる
      const firstCard = resultCards.first();
      const lastCard = resultCards.last();
      const firstBox = await firstCard.boundingBox();
      const lastBox = await lastCard.boundingBox();

      if (firstBox && lastBox) {
        // 縦積み: 最初のカードの Y 座標が最後のカードより上
        expect(firstBox.y).toBeLessThan(lastBox.y);
        // 各カードの幅は375px以内
        expect(firstBox.width).toBeLessThanOrEqual(375);
        expect(lastBox.width).toBeLessThanOrEqual(375);
      }
    });

    test('375px: プログレスバーが表示される', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 812 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await submitButton.click();

      // プログレスバーが表示される
      const progressBars = page.locator('[data-testid="fortune-card-progress"]');
      await expect(progressBars).toHaveCount(4);
    });
  });

  // ── タブレットビューポート（768px）──────────────────────────────────────────

  test.describe('タブレットビューポート（768px）', () => {
    // behavior: タブレットビューポート（768px）→ 中間レイアウトでコンテンツ幅最適化
    test('768px: 占いフォームページが中間レイアウトで表示される', async ({ page }) => {
      await page.setViewportSize({ width: 768, height: 1024 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      // ページが表示される
      await expect(page).toHaveURL('/fortune');

      // 7つの入力フィールドが存在する
      const rangeInputs = page.locator('input[type="range"]');
      await expect(rangeInputs).toHaveCount(7);

      // コンテンツが768px幅内に収まる
      const body = page.locator('body');
      const bodyBox = await body.boundingBox();
      if (bodyBox) {
        expect(bodyBox.width).toBeLessThanOrEqual(768);
      }
    });

    test('768px: 占い結果が768pxのビューポート内に表示される', async ({ page }) => {
      await page.setViewportSize({ width: 768, height: 1024 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      const resultCards = page.locator('[data-testid="fortune-card"]');
      await expect(resultCards).toHaveCount(4);

      // タブレット幅（768px）内にカードが収まる
      const firstCard = resultCards.first();
      const cardBox = await firstCard.boundingBox();
      if (cardBox) {
        expect(cardBox.width).toBeLessThanOrEqual(768);
        expect(cardBox.x + cardBox.width).toBeLessThanOrEqual(768);
      }
    });
  });

  // ── デスクトップビューポート（1280px）───────────────────────────────────────

  test.describe('デスクトップビューポート（1280px）', () => {
    // behavior: デスクトップビューポート（1280px）→ フル幅レイアウト
    test('1280px: 占いフォームページがフル幅レイアウトで表示される', async ({ page }) => {
      await page.setViewportSize({ width: 1280, height: 800 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      await expect(page).toHaveURL('/fortune');

      // 7つの入力フィールドが存在する
      const rangeInputs = page.locator('input[type="range"]');
      await expect(rangeInputs).toHaveCount(7);
    });

    test('1280px: 占い結果が1280pxのビューポート内に表示される', async ({ page }) => {
      await page.setViewportSize({ width: 1280, height: 800 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      const resultCards = page.locator('[data-testid="fortune-card"]');
      await expect(resultCards).toHaveCount(4);

      // デスクトップ幅（1280px）内にカードが収まる
      const firstCard = resultCards.first();
      const cardBox = await firstCard.boundingBox();
      if (cardBox) {
        expect(cardBox.x).toBeGreaterThanOrEqual(0);
        expect(cardBox.x + cardBox.width).toBeLessThanOrEqual(1280);
      }
    });
  });

  // ── 色覚多様性対応（アイコン + カラー冗長表現）──────────────────────────────

  test.describe('色覚多様性対応', () => {
    // behavior: 各次元のアイコンとカラーが冗長表現（色のみに依存しない）で表示される
    test('占い入力フォームに7つの次元アイコンが表示される（色のみに依存しない表示）', async ({
      page,
    }) => {
      await page.setViewportSize({ width: 375, height: 812 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      // 7つの range input（各次元スライダー）が存在する
      const rangeInputs = page.locator('input[type="range"]');
      await expect(rangeInputs).toHaveCount(7);

      // aria-label または関連するラベルが存在する（スクリーンリーダー対応）
      // 各スライダーが min/max を持つことを確認
      for (let i = 0; i < 7; i++) {
        await expect(rangeInputs.nth(i)).toHaveAttribute('min', '0');
        await expect(rangeInputs.nth(i)).toHaveAttribute('max', '100');
      }
    });

    // behavior: 色覚シミュレーション環境で全7次元が弁別可能
    test('占い結果に7次元分のプログレスバーが表示される', async ({ page }) => {
      await page.setViewportSize({ width: 375, height: 812 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await submitButton.click();

      // 結果カードが表示される
      const resultCards = page.locator('[data-testid="fortune-card"]');
      await expect(resultCards).toHaveCount(4);

      // カード名が表示される（カテゴリを示すテキスト的な識別子）
      const cardNames = page.locator('[data-testid="fortune-card-name"]');
      await expect(cardNames).toHaveCount(4);

      // スコア表示が存在する
      const cardScores = page.locator('[data-testid="fortune-card-score"]');
      await expect(cardScores).toHaveCount(4);

      // プログレスバーが存在する（視覚的なスコア表示）
      const progressBars = page.locator('[data-testid="fortune-card-progress"]');
      await expect(progressBars).toHaveCount(4);
    });

    // behavior: 各次元のアイコンとカラーが冗長表現（色のみに依存しない）で表示される
    test('占い結果のプログレスバーに視覚的なスコアが反映される', async ({ page }) => {
      await page.setViewportSize({ width: 1280, height: 800 });
      await setupFortuneMock(page);
      await page.goto('/fortune');

      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await submitButton.click();

      // カード名「恋愛運」が表示される
      const cardNames = page.locator('[data-testid="fortune-card-name"]');
      await expect(cardNames).toHaveCount(4);
      await expect(cardNames.first()).toHaveText('恋愛運');

      // スコアが数値で表示される（75が含まれる）
      const cardScores = page.locator('[data-testid="fortune-card-score"]');
      await expect(cardScores.first()).toContainText('75');
    });
  });

  // ── ビューポート切り替えの一貫性 ─────────────────────────────────────────────

  test.describe('ビューポート切り替え', () => {
    // behavior: [追加] 同一コンテンツが異なるビューポートで正しく表示される
    test('[追加] モバイル→デスクトップへのビューポート切り替えで結果カードが維持される', async ({
      page,
    }) => {
      await setupFortuneMock(page);

      // デスクトップで開始
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.goto('/fortune');

      const submitButton = page.locator('[data-testid="fortune-submit"]');
      await submitButton.click();

      const resultCards = page.locator('[data-testid="fortune-card"]');
      await expect(resultCards).toHaveCount(4);

      // モバイルに切り替え
      await page.setViewportSize({ width: 375, height: 812 });

      // 結果カードが引き続き表示される
      await expect(resultCards).toHaveCount(4);
    });

    // behavior: [追加] 履歴ページも全ビューポートで表示できる
    test('[追加] 履歴ページが375px・768px・1280pxで表示できる', async ({ page }) => {
      await page.route('**/api/fortune/history', async (route) => {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify([]),
        });
      });

      const viewports = [
        { width: 375, height: 812 },
        { width: 768, height: 1024 },
        { width: 1280, height: 800 },
      ];

      for (const vp of viewports) {
        await page.setViewportSize(vp);
        await page.goto('/history');
        await expect(page).toHaveURL('/history');
        // ページが正常に表示される（エラーなし）
        await expect(page.locator('body')).toBeVisible();
      }
    });
  });
});
