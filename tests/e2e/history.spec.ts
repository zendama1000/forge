/**
 * 履歴ページ E2E テスト (Layer 2 - L2-004)
 *
 * GET /api/fortune/history からのデータ取得・時系列降順リスト表示・
 * カテゴリサマリーアイコン・空状態・ローディング状態を検証する。
 *
 * 前提条件:
 * - サーバーは起動済み (http://localhost:3000)
 * - /api/fortune/history は page.route() でモック
 * - テストは冪等（前後でデータ変更なし）
 *
 * コマンド: npx playwright test tests/e2e/history.spec.ts
 */

import { test, expect } from '@playwright/test';

// ─── モックレスポンス ──────────────────────────────────────────────────────────

/** 3件の履歴エントリ（createdAt 降順） */
const MOCK_HISTORY_ENTRIES = [
  {
    id: 'uuid-newest',
    createdAt: '2024-01-16T10:00:00.000Z',
    categories: [
      { name: '恋愛運', totalScore: 40, templateText: '恋愛運は低調です。' },
      { name: '仕事運', totalScore: 90, templateText: '仕事運は絶好調です。' },
      { name: '金運', totalScore: 70, templateText: '金運は良好です。' },
      { name: '健康運', totalScore: 55, templateText: '健康運は普通です。' },
    ],
  },
  {
    id: 'uuid-middle',
    createdAt: '2024-01-15T14:30:00.000Z',
    categories: [
      { name: '恋愛運', totalScore: 75, templateText: '恋愛運は良好です。' },
      { name: '仕事運', totalScore: 60, templateText: '仕事運は普通です。' },
      { name: '金運', totalScore: 50, templateText: '金運は安定しています。' },
      { name: '健康運', totalScore: 80, templateText: '健康運は優れています。' },
    ],
  },
  {
    id: 'uuid-oldest',
    createdAt: '2024-01-14T08:00:00.000Z',
    categories: [
      { name: '恋愛運', totalScore: 85, templateText: '恋愛運は絶好調です。' },
      { name: '仕事運', totalScore: 45, templateText: '仕事運は低調です。' },
      { name: '金運', totalScore: 30, templateText: '金運は低調です。' },
      { name: '健康運', totalScore: 65, templateText: '健康運は良好です。' },
    ],
  },
];

/** 空の履歴レスポンス */
const MOCK_EMPTY_HISTORY: never[] = [];

// ─── L2-004: 履歴ページ統合テスト ────────────────────────────────────────────

test.describe('L2-004: 履歴ページ統合テスト', () => {
  // behavior: 履歴データ取得 → 時系列降順でエントリ一覧が表示される
  test('GET /api/fortune/history → 時系列降順でエントリ一覧が表示される', async ({ page }) => {
    // /api/fortune/history をモック（3件、降順）
    await page.route('**/api/fortune/history', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(MOCK_HISTORY_ENTRIES),
      });
    });

    await page.goto('/history');

    // 3件のエントリが表示される
    const historyItems = page.locator('[data-testid="history-entry"]');
    await expect(historyItems).toHaveCount(3);

    // 1番目が最新エントリ（uuid-newest）
    const firstItem = historyItems.first();
    await expect(firstItem).toBeVisible();

    // エントリが存在することを確認（順序の検証）
    // 各エントリの data-testid または id 属性で確認
    await expect(firstItem.locator('[data-testid="history-entry-id"]').first()).toContainText(
      'uuid-newest',
    );
  });

  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  test('各エントリにid・日時・カテゴリ別サマリーアイコンが表示される', async ({ page }) => {
    await page.route('**/api/fortune/history', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([MOCK_HISTORY_ENTRIES[0]]),
      });
    });

    await page.goto('/history');

    const entry = page.locator('[data-testid="history-entry"]').first();
    await expect(entry).toBeVisible();

    // id が表示されている
    const entryId = entry.locator('[data-testid="history-entry-id"]');
    await expect(entryId).toContainText('uuid-newest');

    // 日時が表示されている
    const entryDate = entry.locator('[data-testid="history-entry-date"]');
    await expect(entryDate).toBeVisible();
    // 2024年の日時が含まれる
    await expect(entryDate).toContainText('2024');

    // カテゴリアイコンが表示されている（4件）
    const categoryIcons = entry.locator('[data-testid="history-category-icon"]');
    await expect(categoryIcons).toHaveCount(4);
  });

  // behavior: 履歴データ0件 → 空状態メッセージが表示される
  test('履歴データ0件 → 空状態メッセージが表示される', async ({ page }) => {
    await page.route('**/api/fortune/history', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(MOCK_EMPTY_HISTORY),
      });
    });

    await page.goto('/history');

    // エントリリストは空
    const historyItems = page.locator('[data-testid="history-entry"]');
    await expect(historyItems).toHaveCount(0);

    // 空状態メッセージが表示される
    const emptyMessage = page.locator('[data-testid="history-empty"]');
    await expect(emptyMessage).toBeVisible();
    await expect(emptyMessage).not.toHaveText('');
  });

  // behavior: 履歴データ読み込み中 → ローディング状態が表示される
  test('履歴データ読み込み中 → ローディング状態が表示される', async ({ page }) => {
    let resolveRoute: (() => void) | null = null;

    await page.route('**/api/fortune/history', async (route) => {
      // 外部から resolve できるように Promise を保持
      await new Promise<void>((resolve) => {
        resolveRoute = resolve;
      });
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(MOCK_HISTORY_ENTRIES),
      });
    });

    await page.goto('/history');

    // ローディング表示の確認
    const loading = page.locator('[data-testid="history-loading"]');
    await expect(loading).toBeVisible({ timeout: 3000 });

    // レスポンスを解放
    resolveRoute?.();

    // ローディングが消えることを確認
    await expect(loading).not.toBeVisible({ timeout: 5000 });
  });

  // behavior: [追加] 複数エントリの時系列降順表示
  test('[追加] 3件のエントリが時系列降順で表示される（新しい順）', async ({ page }) => {
    await page.route('**/api/fortune/history', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(MOCK_HISTORY_ENTRIES),
      });
    });

    await page.goto('/history');

    const historyItems = page.locator('[data-testid="history-entry"]');
    await expect(historyItems).toHaveCount(3);

    // 各エントリのid確認（降順順序）
    const entryIds = historyItems.locator('[data-testid="history-entry-id"]');
    await expect(entryIds.nth(0)).toContainText('uuid-newest');
    await expect(entryIds.nth(1)).toContainText('uuid-middle');
    await expect(entryIds.nth(2)).toContainText('uuid-oldest');
  });

  // behavior: [追加] カテゴリアイコンに絵文字アイコンが表示される
  test('[追加] カテゴリ別サマリーアイコンに絵文字が含まれる', async ({ page }) => {
    await page.route('**/api/fortune/history', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([MOCK_HISTORY_ENTRIES[0]]),
      });
    });

    await page.goto('/history');

    const entry = page.locator('[data-testid="history-entry"]').first();
    await expect(entry).toBeVisible();

    // アイコンが存在する
    const icons = entry.locator('[data-testid="history-category-icon"]');
    await expect(icons).toHaveCount(4);

    // 恋愛運のアイコン（💕）が表示されている
    const loveIcon = icons.nth(0);
    await expect(loveIcon).toContainText('💕');
  });
});
