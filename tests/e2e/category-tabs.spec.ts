/**
 * カテゴリタブ切替 E2E テスト (Layer 2 - L2-002)
 *
 * TabNavigation コンポーネントの E2E レベルの振る舞いを検証する。
 *
 * 前提条件:
 * - サーバーは起動済み (http://localhost:3000)
 * - /api/fortune は page.route() でモック
 * - テストは冪等（前後でデータ変更なし）
 *
 * コマンド: npx playwright test tests/e2e/category-tabs.spec.ts
 */

import { test, expect } from '@playwright/test';

// ─── モックレスポンス ──────────────────────────────────────────────────────────

const MOCK_FORTUNE_RESPONSE = {
  categories: [
    {
      id: 'love',
      name: '恋愛運',
      totalScore: 75,
      templateText: '恋愛運は良好です。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 70 + i })),
    },
    {
      id: 'work',
      name: '仕事運',
      totalScore: 60,
      templateText: '仕事運は普通です。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 55 + i })),
    },
    {
      id: 'money',
      name: '金運',
      totalScore: 50,
      templateText: '金運は安定しています。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 45 + i })),
    },
    {
      id: 'health',
      name: '健康運',
      totalScore: 80,
      templateText: '健康運は優れています。',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 75 + i })),
    },
  ],
};

/** POST /api/fortune をモックするヘルパー */
async function mockFortuneApi(page: import('@playwright/test').Page) {
  await page.route('**/api/fortune', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(MOCK_FORTUNE_RESPONSE),
    });
  });
}

/** 占いフォームを送信して結果を表示状態にするヘルパー */
async function submitFortuneForm(page: import('@playwright/test').Page) {
  const submitButton = page.locator('[data-testid="fortune-submit"]');
  await expect(submitButton).toBeVisible({ timeout: 5000 });
  await submitButton.click();
  // タブコンポーネントが表示されるまで待機
  await page.waitForSelector('[data-testid^="tab-"]', { timeout: 8000 });
}

// ─── L2-002: カテゴリタブ切替テスト ──────────────────────────────────────────

test.describe('L2-002: カテゴリタブ切替', () => {
  // behavior: 4カテゴリデータを渡す → 4つのタブボタンがレンダリング
  test('占い結果表示後、4つのタブボタンが表示される', async ({ page }) => {
    await mockFortuneApi(page);
    await page.goto('/fortune');
    await submitFortuneForm(page);

    // data-testid="tab-*" で始まる要素が 4 件存在する
    const tabs = page.locator('[data-testid^="tab-"]');
    await expect(tabs).toHaveCount(4);
  });

  // behavior: 各タブにdata-testid='tab-{categoryId}'属性が存在
  test('各タブに data-testid="tab-{categoryId}" 属性が存在する', async ({ page }) => {
    await mockFortuneApi(page);
    await page.goto('/fortune');
    await submitFortuneForm(page);

    // 各カテゴリの data-testid を確認
    await expect(page.locator('[data-testid="tab-love"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-work"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-money"]')).toBeVisible();
    await expect(page.locator('[data-testid="tab-health"]')).toBeVisible();
  });

  // behavior: activeTab propで指定したタブ → aria-selected='true'、他タブはaria-selected='false'
  test('初期表示でアクティブなタブが aria-selected="true"、他は aria-selected="false"', async ({
    page,
  }) => {
    await mockFortuneApi(page);
    await page.goto('/fortune');
    await submitFortuneForm(page);

    // 最初のタブ（恋愛運）がアクティブである想定
    const activeTab = page.locator('[data-testid^="tab-"][aria-selected="true"]');
    await expect(activeTab).toHaveCount(1);

    // 非アクティブなタブは3件
    const inactiveTabs = page.locator('[data-testid^="tab-"][aria-selected="false"]');
    await expect(inactiveTabs).toHaveCount(3);
  });

  // behavior: タブクリック → onChangeコールバックがクリックされたカテゴリIDで発火
  test('タブをクリックすると aria-selected が切り替わる', async ({ page }) => {
    await mockFortuneApi(page);
    await page.goto('/fortune');
    await submitFortuneForm(page);

    // '仕事運' タブをクリック
    const workTab = page.locator('[data-testid="tab-work"]');
    await workTab.click();

    // クリックしたタブが aria-selected="true" になる
    await expect(page.locator('[data-testid="tab-work"]')).toHaveAttribute('aria-selected', 'true');

    // 他のタブは aria-selected="false"
    await expect(page.locator('[data-testid="tab-love"]')).toHaveAttribute('aria-selected', 'false');
    await expect(page.locator('[data-testid="tab-money"]')).toHaveAttribute('aria-selected', 'false');
    await expect(page.locator('[data-testid="tab-health"]')).toHaveAttribute('aria-selected', 'false');
  });

  test('複数タブを順番にクリックすると aria-selected が正しく切り替わる', async ({ page }) => {
    await mockFortuneApi(page);
    await page.goto('/fortune');
    await submitFortuneForm(page);

    const categoryIds = ['love', 'work', 'money', 'health'];

    for (const categoryId of categoryIds) {
      const tab = page.locator(`[data-testid="tab-${categoryId}"]`);
      await tab.click();

      // クリックしたタブのみ aria-selected="true"
      await expect(tab).toHaveAttribute('aria-selected', 'true');

      // 他のタブは aria-selected="false"
      for (const otherId of categoryIds.filter((id) => id !== categoryId)) {
        await expect(page.locator(`[data-testid="tab-${otherId}"]`)).toHaveAttribute(
          'aria-selected',
          'false'
        );
      }
    }
  });

  // behavior: [追加] タブ切替後、対応するカテゴリの内容が表示される
  test('[追加] タブ切替後、対応するカテゴリの内容（カード）が表示される', async ({ page }) => {
    await mockFortuneApi(page);
    await page.goto('/fortune');
    await submitFortuneForm(page);

    // '金運' タブをクリック
    const moneyTab = page.locator('[data-testid="tab-money"]');
    await moneyTab.click();

    // '金運' に対応するカードが表示される（data-testid="fortune-card-money" またはアクティブカード）
    // カード内に '金運' テキストが含まれることを確認
    const activeCard = page.locator('[data-testid="fortune-card"][data-category="money"]');
    // フォールバック: fortune-card-name に '金運' テキストが表示される
    const cardName = page.locator('[data-testid="fortune-card-name"]').filter({ hasText: '金運' });
    // いずれかが可視状態であれば OK
    const isActiveCardVisible = await activeCard.isVisible().catch(() => false);
    const isCardNameVisible = await cardName.isVisible().catch(() => false);
    expect(isActiveCardVisible || isCardNameVisible).toBe(true);
  });
});
