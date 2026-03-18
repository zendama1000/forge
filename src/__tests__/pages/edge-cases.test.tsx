/**
 * エッジケース・ページネーション Layer 1 テスト
 *
 * 対象振る舞い:
 * - 全次元スコア0のAPI応答 → 全カテゴリtotalScore=0で正常表示
 * - 全次元スコア100のAPI応答 → 全カテゴリtotalScore=100で正常表示
 * - ネットワークエラー発生時 → ユーザーフレンドリーなエラーメッセージ表示
 * - 履歴リストにページネーションコントロールが表示される
 * - ページネーション操作 → 対応するページの履歴エントリが表示される
 *
 * テストフレームワーク: vitest
 */

import { describe, it, expect, vi } from 'vitest';
import {
  createResultPage,
  buildResultFortuneCard,
  setApiError,
  createEmptyResultPage,
  setResultFromApi,
  type ResultCategory,
} from '../../components/result-page';
import { createFortuneCard } from '../../components/fortune-card';
import {
  createInitialHistoryState,
  setHistoryEntries,
  setPage,
  getPagedEntries,
  hasPagination,
  fetchHistory,
  DEFAULT_PAGE_SIZE,
  NETWORK_ERROR_MESSAGE,
  type HistoryEntry,
} from '../../components/history-page';

// ─── テスト用ヘルパー ─────────────────────────────────────────────────────────

/** 指定スコアで4カテゴリのResultCategoryを生成 */
function createCategoriesWithScore(score: number): ResultCategory[] {
  return [
    {
      id: 'love',
      name: '恋愛運',
      totalScore: score,
      weightedScore: score,
      templateText: score === 0 ? '慎重に過ごす時期です。' : '絶好調です。',
      dimensions: Array.from({ length: 7 }, () => ({ name: '次元', rawScore: score })),
    },
    {
      id: 'work',
      name: '仕事運',
      totalScore: score,
      weightedScore: score,
      templateText: score === 0 ? '休息を取りましょう。' : '全力で取り組みましょう。',
      dimensions: Array.from({ length: 7 }, () => ({ name: '次元', rawScore: score })),
    },
    {
      id: 'money',
      name: '金運',
      totalScore: score,
      weightedScore: score,
      templateText: score === 0 ? '節約が必要です。' : '財運に恵まれています。',
      dimensions: Array.from({ length: 7 }, () => ({ name: '次元', rawScore: score })),
    },
    {
      id: 'health',
      name: '健康運',
      totalScore: score,
      weightedScore: score,
      templateText: score === 0 ? '体調管理に注意。' : '健康そのものです。',
      dimensions: Array.from({ length: 7 }, () => ({ name: '次元', rawScore: score })),
    },
  ];
}

/** 指定件数の履歴エントリを生成 */
function createMockEntries(count: number): HistoryEntry[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `uuid-${String(i + 1).padStart(3, '0')}`,
    // 新しい順に並べるため降順タイムスタンプを生成
    createdAt: new Date(2024, 0, count - i, 12, 0, 0).toISOString(),
    categories: [
      { name: '恋愛運', totalScore: 70, templateText: 'テキスト' },
      { name: '仕事運', totalScore: 60, templateText: 'テキスト' },
      { name: '金運', totalScore: 50, templateText: 'テキスト' },
      { name: '健康運', totalScore: 80, templateText: 'テキスト' },
    ],
  }));
}

// ─── 全次元スコア0のAPI応答 → 全カテゴリtotalScore=0で正常表示 ────────────────

describe('エッジケース: 全次元スコア0のAPI応答', () => {
  // behavior: 全次元スコア0のAPI応答 → 全カテゴリtotalScore=0で正常表示
  it('全カテゴリtotalScore=0のときcreateResultPageが正常にページ状態を生成する', () => {
    const categories = createCategoriesWithScore(0);
    const state = createResultPage(categories);

    // ページ状態が正常に生成される
    expect(state.hasResult).toBe(true);
    expect(state.cards).toHaveLength(4);
  });

  // behavior: 全次元スコア0のAPI応答 → 全カテゴリtotalScore=0で正常表示
  it('全カテゴリのtotalScore=0が全カードに反映される', () => {
    const categories = createCategoriesWithScore(0);
    const state = createResultPage(categories);

    state.cards.forEach((card) => {
      expect(card.totalScore).toBe(0);
      expect(card.weightedScore).toBe(0);
    });
  });

  // behavior: 全次元スコア0のAPI応答 → 全カテゴリtotalScore=0で正常表示
  it('スコア0のとき全カードのprogressBarStyle.widthが"0%"になる', () => {
    const categories = createCategoriesWithScore(0);
    const state = createResultPage(categories);

    state.cards.forEach((card) => {
      expect(card.progressBarStyle.width).toBe('0%');
    });
  });

  // behavior: 全次元スコア0のAPI応答 → 全カテゴリtotalScore=0で正常表示
  it('buildResultFortuneCardがtotalScore=0を正確に処理する（4カテゴリ個別確認）', () => {
    const categories = createCategoriesWithScore(0);

    categories.forEach((category) => {
      const card = buildResultFortuneCard(category);
      expect(card.totalScore).toBe(0);
      expect(card.weightedScore).toBe(0);
      expect(card.score).toBe(0);
      expect(card.progressBarStyle.width).toBe('0%');
    });
  });

  // behavior: [追加] スコア0でも score フィールドが数値型である
  it('[追加] スコア0でも各カードのscoreフィールドが数値型で保持される', () => {
    const categories = createCategoriesWithScore(0);
    const state = createResultPage(categories);

    state.cards.forEach((card) => {
      expect(typeof card.score).toBe('number');
      expect(card.score).toBeGreaterThanOrEqual(0);
    });
  });

  // behavior: [追加] スコア0でもタブナビゲーションが正常に生成される
  it('[追加] スコア0でもタブナビゲーション4タブが正常に生成される', () => {
    const categories = createCategoriesWithScore(0);
    const state = createResultPage(categories);

    expect(state.tabNavigation.tabs).toHaveLength(4);
    expect(state.tabNavigation.isVisible).toBe(true);
    expect(state.activeTab).toBe('love');
  });

  // behavior: [強化] M-005対策 — 1カテゴリのみの場合もhasResult=trueになる
  // categories.length > 0 が > 1 に変更されると1カテゴリの場合が検出される
  it('[強化] M-005: 1カテゴリのみのとき createResultPage が hasResult=true を返す', () => {
    const categories = createCategoriesWithScore(0).slice(0, 1); // 1カテゴリ
    const state = createResultPage(categories);

    // categories.length > 0 であれば hasResult=true になるべき
    expect(state.hasResult).toBe(true);
    expect(state.cards).toHaveLength(1);
  });

  // behavior: [強化] M-006対策 — カード表示スコアは totalScore を使用する（weightedScore ではない）
  // score: category.weightedScore に差し替わると totalScore=0 でも weightedScore 値が使われてしまう
  it('[強化] M-006: totalScore=0・weightedScore=25のカテゴリではcard.score=0（totalScore優先）になる', () => {
    const category: ResultCategory = {
      id: 'test-m006',
      name: 'テスト運',
      totalScore: 0,      // 検証値: スコア0のエッジケース
      weightedScore: 25,  // totalScoreと異なる値
      templateText: 'テキスト',
      dimensions: Array.from({ length: 7 }, () => ({ name: '次元', rawScore: 0 })),
    };

    const card = buildResultFortuneCard(category);

    // card.score は totalScore=0 を使うべき（weightedScore=25 ではない）
    expect(card.score).toBe(0);
    expect(card.totalScore).toBe(0);
    expect(card.weightedScore).toBe(25);
    expect(card.progressBarStyle.width).toBe('0%');
  });

  // behavior: [強化] M-010対策 — スコア未定義時のフォールバックは0であるべき
  // ?? 0 が ?? 50 に変更されると score=undefined のカードが 50% で表示される
  it('[強化] M-010: createFortuneCardにscoreもcategory.totalScoreも指定しない場合のフォールバックが0になる', () => {
    // score未指定・category未指定の場合のフォールバック検証
    const card = createFortuneCard({});
    expect(card.score).toBe(0);
    expect(card.progressBarStyle.width).toBe('0%');
  });

  // behavior: [強化] M-010対策追加 — category.totalScoreも未定義の場合フォールバック0
  it('[強化] M-010: category.totalScoreがundefinedの場合もフォールバックが0になる', () => {
    const card = createFortuneCard({ category: { name: 'テスト', templateText: 'テキスト' } });
    expect(card.score).toBe(0);
    expect(card.progressBarStyle.width).toBe('0%');
  });
});

// ─── 全次元スコア100のAPI応答 → 全カテゴリtotalScore=100で正常表示 ─────────────

describe('エッジケース: 全次元スコア100のAPI応答', () => {
  // behavior: 全次元スコア100のAPI応答 → 全カテゴリtotalScore=100で正常表示
  it('全カテゴリtotalScore=100のときcreateResultPageが正常にページ状態を生成する', () => {
    const categories = createCategoriesWithScore(100);
    const state = createResultPage(categories);

    expect(state.hasResult).toBe(true);
    expect(state.cards).toHaveLength(4);
  });

  // behavior: 全次元スコア100のAPI応答 → 全カテゴリtotalScore=100で正常表示
  it('全カテゴリのtotalScore=100が全カードに反映される', () => {
    const categories = createCategoriesWithScore(100);
    const state = createResultPage(categories);

    state.cards.forEach((card) => {
      expect(card.totalScore).toBe(100);
      expect(card.weightedScore).toBe(100);
    });
  });

  // behavior: 全次元スコア100のAPI応答 → 全カテゴリtotalScore=100で正常表示
  it('スコア100のとき全カードのprogressBarStyle.widthが"100%"になる', () => {
    const categories = createCategoriesWithScore(100);
    const state = createResultPage(categories);

    state.cards.forEach((card) => {
      expect(card.progressBarStyle.width).toBe('100%');
    });
  });

  // behavior: 全次元スコア100のAPI応答 → 全カテゴリtotalScore=100で正常表示
  it('buildResultFortuneCardがtotalScore=100を正確に処理する（4カテゴリ個別確認）', () => {
    const categories = createCategoriesWithScore(100);

    categories.forEach((category) => {
      const card = buildResultFortuneCard(category);
      expect(card.totalScore).toBe(100);
      expect(card.weightedScore).toBe(100);
      expect(card.score).toBe(100);
      expect(card.progressBarStyle.width).toBe('100%');
    });
  });

  // behavior: [追加] スコア100でも score フィールドが100を超えない
  it('[追加] スコア100のときscoreフィールドが100であり、上限値を正確に表現する', () => {
    const categories = createCategoriesWithScore(100);
    const state = createResultPage(categories);

    state.cards.forEach((card) => {
      expect(card.score).toBe(100);
      expect(card.score).toBeLessThanOrEqual(100);
    });
  });

  // behavior: [追加] スコア0と100の両端境界値で状態が区別される
  it('[追加] スコア0とスコア100のカードはprogressBarStyleが異なる（境界値対比確認）', () => {
    const card0 = buildResultFortuneCard(createCategoriesWithScore(0)[0]!);
    const card100 = buildResultFortuneCard(createCategoriesWithScore(100)[0]!);

    expect(card0.progressBarStyle.width).toBe('0%');
    expect(card100.progressBarStyle.width).toBe('100%');
    expect(card0.progressBarStyle.width).not.toBe(card100.progressBarStyle.width);
  });

  // behavior: [強化] M-012対策 — setResultFromApiはAPIカテゴリ受信後 hasResult=true を返すべき
  // hasResult: false に変更されると totalScore=100 を含む API レスポンス後も結果カードが描画されない
  it('[強化] M-012: setResultFromApiでtotalScore=100のカテゴリを設定するとhasResult=trueになる', () => {
    const initial = createEmptyResultPage();
    const categories = createCategoriesWithScore(100);
    const newState = setResultFromApi(initial, categories);

    // setResultFromApi は必ず hasResult=true を返すべき
    expect(newState.hasResult).toBe(true);
    expect(newState.cards).toHaveLength(4);
    newState.cards.forEach((card) => {
      expect(card.totalScore).toBe(100);
      expect(card.progressBarStyle.width).toBe('100%');
    });
  });

  // behavior: [強化] M-012対策追加 — setResultFromApiはtotalScore=0でもhasResult=trueを返す
  it('[強化] M-012: setResultFromApiでtotalScore=0のカテゴリを設定してもhasResult=trueになる', () => {
    const initial = createEmptyResultPage();
    const categories = createCategoriesWithScore(0);
    const newState = setResultFromApi(initial, categories);

    expect(newState.hasResult).toBe(true);
    expect(newState.isLoading).toBe(false);
    expect(newState.apiError).toBeNull();
  });
});

// ─── ネットワークエラー発生時 → ユーザーフレンドリーなエラーメッセージ表示 ─────

describe('ネットワークエラー: ユーザーフレンドリーなエラーメッセージ表示', () => {
  // behavior: ネットワークエラー発生時 → ユーザーフレンドリーなエラーメッセージ表示
  it('fetchHistoryがネットワークエラー（fetchがthrow）のとき、ユーザーフレンドリーなerrorを返す', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('Network Error'));

    const result = await fetchHistory(mockFetch as unknown as typeof fetch);

    expect('error' in result).toBe(true);
    if ('error' in result) {
      // ユーザーフレンドリーな日本語メッセージ
      expect(result.error).toBe(NETWORK_ERROR_MESSAGE);
      expect(result.error).toContain('ネットワークエラー');
      expect(typeof result.error).toBe('string');
      expect(result.error.length).toBeGreaterThan(0);
    }
  });

  // behavior: ネットワークエラー発生時 → ユーザーフレンドリーなエラーメッセージ表示
  it('fetchHistoryがネットワークエラーのとき status=0 を返す', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new TypeError('Failed to fetch'));

    const result = await fetchHistory(mockFetch as unknown as typeof fetch);

    expect('error' in result).toBe(true);
    if ('error' in result) {
      expect(result.status).toBe(0);
    }
  });

  // behavior: ネットワークエラー発生時 → ユーザーフレンドリーなエラーメッセージ表示
  it('NETWORK_ERROR_MESSAGEが定義されており日本語のメッセージである', () => {
    expect(typeof NETWORK_ERROR_MESSAGE).toBe('string');
    expect(NETWORK_ERROR_MESSAGE.length).toBeGreaterThan(0);
    // 日本語文字が含まれていること
    expect(NETWORK_ERROR_MESSAGE).toMatch(/[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FAF]/);
  });

  // behavior: ネットワークエラー発生時 → ユーザーフレンドリーなエラーメッセージ表示
  it('setApiErrorで結果ページにネットワークエラーメッセージが設定される', () => {
    let state = createEmptyResultPage();
    state = setApiError(state, NETWORK_ERROR_MESSAGE);

    // ユーザーフレンドリーなメッセージが設定される
    expect(state.apiError).toBe(NETWORK_ERROR_MESSAGE);
    expect(state.apiError).not.toBeNull();
    expect(state.apiError).toContain('ネットワークエラー');
    expect(state.isLoading).toBe(false);
  });

  // behavior: ネットワークエラー発生時 → ユーザーフレンドリーなエラーメッセージ表示
  it('HTTP 500エラーのとき fetchHistory がユーザーフレンドリーなメッセージを返す', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
      json: async () => ({ error: 'サーバー内部エラー' }),
    });

    const result = await fetchHistory(mockFetch as unknown as typeof fetch);

    expect('error' in result).toBe(true);
    if ('error' in result) {
      expect(result.status).toBe(500);
      expect(typeof result.error).toBe('string');
      expect(result.error.length).toBeGreaterThan(0);
    }
  });

  // behavior: [追加] エッジケース: タイムアウトエラーでもユーザーフレンドリーメッセージが返る
  it('[追加] エッジケース: AbortError（タイムアウト）でもユーザーフレンドリーなメッセージが返される', async () => {
    const abortError = new DOMException('The operation was aborted', 'AbortError');
    const mockFetch = vi.fn().mockRejectedValue(abortError);

    const result = await fetchHistory(mockFetch as unknown as typeof fetch);

    expect('error' in result).toBe(true);
    if ('error' in result) {
      expect(typeof result.error).toBe('string');
      expect(result.error.length).toBeGreaterThan(0);
    }
  });
});

// ─── 履歴リストにページネーションコントロールが表示される ─────────────────────

describe('ページネーション: 履歴リストにページネーションコントロールが表示される', () => {
  // behavior: 履歴リストにページネーションコントロールが表示される
  it('エントリ数がDEFAULT_PAGE_SIZEを超えるとhasPagination=trueになる', () => {
    const entries = createMockEntries(DEFAULT_PAGE_SIZE + 1); // 11件
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    expect(hasPagination(state)).toBe(true);
  });

  // behavior: 履歴リストにページネーションコントロールが表示される
  it('エントリ数がDEFAULT_PAGE_SIZE以下のときhasPagination=falseになる', () => {
    const entries = createMockEntries(DEFAULT_PAGE_SIZE); // 10件
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    expect(hasPagination(state)).toBe(false);
  });

  // behavior: 履歴リストにページネーションコントロールが表示される
  it('21件のエントリでtotalPages=3になる（DEFAULT_PAGE_SIZE=10の場合）', () => {
    const entries = createMockEntries(21);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    expect(state.pagination.totalPages).toBe(3);
    expect(state.pagination.totalItems).toBe(21);
  });

  // behavior: 履歴リストにページネーションコントロールが表示される
  it('DEFAULT_PAGE_SIZEが数値型で定義されており、1以上である', () => {
    expect(typeof DEFAULT_PAGE_SIZE).toBe('number');
    expect(DEFAULT_PAGE_SIZE).toBeGreaterThanOrEqual(1);
  });

  // behavior: 履歴リストにページネーションコントロールが表示される
  it('初期状態ではpagination.currentPage=1・totalPages=0になる', () => {
    const state = createInitialHistoryState();

    expect(state.pagination.currentPage).toBe(1);
    expect(state.pagination.totalPages).toBe(0);
    expect(state.pagination.totalItems).toBe(0);
  });

  // behavior: [追加] エントリ0件のときhasPagination=falseになる
  it('[追加] エントリ0件のときhasPagination=falseになる（空状態ではページネーション不要）', () => {
    const state = createInitialHistoryState();
    expect(hasPagination(state)).toBe(false);
  });

  // behavior: [追加] ちょうどDEFAULT_PAGE_SIZE件のときtotalPages=1になる
  it('[追加] エントリ数がDEFAULT_PAGE_SIZEちょうどのときtotalPages=1でページネーション不要', () => {
    const entries = createMockEntries(DEFAULT_PAGE_SIZE);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    expect(state.pagination.totalPages).toBe(1);
    expect(hasPagination(state)).toBe(false);
  });

  // behavior: [強化] M-011対策 — setHistoryEntriesでエントリ設定後のisEmptyがfalseになる
  // isEmpty: length !== 0 に条件反転されると、空でないときに isEmpty=true が返り空メッセージが表示される
  it('[強化] M-011: setHistoryEntriesでエントリを設定するとisEmpty=falseになる', () => {
    const entries = createMockEntries(5);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    // エントリが存在するとき isEmpty は false でなければならない
    expect(state.isEmpty).toBe(false);
    expect(state.entries).toHaveLength(5);
  });

  // behavior: [強化] M-011対策追加 — 空配列を設定するとisEmpty=trueになる
  it('[強化] M-011: setHistoryEntriesで空配列を設定するとisEmpty=trueになる', () => {
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, []);

    // エントリが0件のとき isEmpty は true でなければならない
    expect(state.isEmpty).toBe(true);
    expect(state.entries).toHaveLength(0);
  });

  // behavior: [強化] M-011対策 — isEmptyの真偽が空/非空で正しく反転する
  it('[強化] M-011: 初期状態でisEmpty=true、エントリ追加後はisEmpty=false（真偽反転の一貫性）', () => {
    const initial = createInitialHistoryState();
    expect(initial.isEmpty).toBe(true);

    const withEntries = setHistoryEntries(initial, createMockEntries(1));
    expect(withEntries.isEmpty).toBe(false);

    // 0件に戻すと再びisEmpty=true
    const backToEmpty = setHistoryEntries(withEntries, []);
    expect(backToEmpty.isEmpty).toBe(true);
  });
});

// ─── ページネーション操作 → 対応するページの履歴エントリが表示される ───────────

describe('ページネーション: ページ操作で対応するエントリが表示される', () => {
  // behavior: ページネーション操作 → 対応するページの履歴エントリが表示される
  it('setPageでページ2に移動するとgetPagedEntriesがページ2の件数を返す', () => {
    const entries = createMockEntries(25); // 3ページ分（10+10+5）
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    // ページ1の件数確認
    const page1Entries = getPagedEntries(state);
    expect(page1Entries).toHaveLength(10);

    // ページ2に移動
    state = setPage(state, 2);
    const page2Entries = getPagedEntries(state);
    expect(page2Entries).toHaveLength(10);

    // ページ1とページ2のエントリが異なる
    expect(page1Entries[0]!.id).not.toBe(page2Entries[0]!.id);
  });

  // behavior: ページネーション操作 → 対応するページの履歴エントリが表示される
  it('最終ページのエントリ数が端数（25件の3ページ目は5件）になる', () => {
    const entries = createMockEntries(25);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    state = setPage(state, 3);
    const page3Entries = getPagedEntries(state);
    expect(page3Entries).toHaveLength(5);
  });

  // behavior: ページネーション操作 → 対応するページの履歴エントリが表示される
  it('ページ1のエントリIDとページ2のエントリIDが重複しない', () => {
    const entries = createMockEntries(20);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    const page1Ids = new Set(getPagedEntries(state).map((e) => e.id));

    state = setPage(state, 2);
    const page2Ids = new Set(getPagedEntries(state).map((e) => e.id));

    // 2ページ間でIDの重複がない
    const intersection = [...page1Ids].filter((id) => page2Ids.has(id));
    expect(intersection).toHaveLength(0);
  });

  // behavior: ページネーション操作 → 対応するページの履歴エントリが表示される
  it('setPage後にpagination.currentPageが更新される', () => {
    const entries = createMockEntries(30);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    expect(state.pagination.currentPage).toBe(1);

    state = setPage(state, 2);
    expect(state.pagination.currentPage).toBe(2);

    state = setPage(state, 3);
    expect(state.pagination.currentPage).toBe(3);
  });

  // behavior: ページネーション操作 → 対応するページの履歴エントリが表示される
  it('ページ1のエントリが全体リストの先頭10件と一致する（createdAt降順）', () => {
    const entries = createMockEntries(20);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    const page1Entries = getPagedEntries(state);

    // ページ1はentries[0..9]
    expect(page1Entries).toHaveLength(10);
    page1Entries.forEach((entry, i) => {
      expect(entry.id).toBe(state.entries[i]!.id);
    });
  });

  // behavior: [追加] エッジケース: 上限を超えるページ番号はtotalPagesにクランプされる
  it('[追加] エッジケース: 上限を超えるページ番号setPage(100)はtotalPagesにクランプされる', () => {
    const entries = createMockEntries(25); // totalPages=3
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    state = setPage(state, 100); // 上限超え
    expect(state.pagination.currentPage).toBe(3); // totalPagesにクランプ
  });

  // behavior: [追加] エッジケース: 0以下のページ番号は1にクランプされる
  it('[追加] エッジケース: 0以下のページ番号setPage(0)は1にクランプされる', () => {
    const entries = createMockEntries(25);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    state = setPage(state, 0); // 下限超え
    expect(state.pagination.currentPage).toBe(1); // 1にクランプ

    state = setPage(state, -5);
    expect(state.pagination.currentPage).toBe(1);
  });

  // behavior: [追加] setPageはイミュータブル更新である
  it('[追加] setPageが元のstateを変更せず新しいstateを返す（イミュータブル更新）', () => {
    const entries = createMockEntries(20);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    const originalPage = state.pagination.currentPage;
    const newState = setPage(state, 2);

    // 元のstateは変更されない
    expect(state.pagination.currentPage).toBe(originalPage);
    expect(newState.pagination.currentPage).toBe(2);
    expect(state).not.toBe(newState);
  });

  // behavior: [追加] getPagedEntriesが呼ばれてもstateは変更されない
  it('[追加] getPagedEntriesはstateを変更しない（参照透過性）', () => {
    const entries = createMockEntries(20);
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, entries);

    const before = state.pagination.currentPage;
    getPagedEntries(state); // 呼び出し
    const after = state.pagination.currentPage;

    expect(before).toBe(after);
  });
});

// ─── 総合エッジケース: スコア境界値 × ページネーション ────────────────────────

describe('複合エッジケース: スコア境界値・異常系統合テスト', () => {
  // behavior: [追加] スコア0のカテゴリがページネーション付き履歴にも正常表示される
  it('[追加] スコア0のカテゴリを含む履歴エントリがページネーション後も正常に取得できる', () => {
    // スコア0のカテゴリを持つ履歴エントリ15件
    const zeroScoreEntries: HistoryEntry[] = Array.from({ length: 15 }, (_, i) => ({
      id: `zero-${i}`,
      createdAt: new Date(2024, 0, 15 - i).toISOString(),
      categories: [
        { name: '恋愛運', totalScore: 0, templateText: 'テキスト' },
        { name: '仕事運', totalScore: 0, templateText: 'テキスト' },
        { name: '金運', totalScore: 0, templateText: 'テキスト' },
        { name: '健康運', totalScore: 0, templateText: 'テキスト' },
      ],
    }));

    let state = createInitialHistoryState();
    state = setHistoryEntries(state, zeroScoreEntries);

    // ページネーション有効
    expect(hasPagination(state)).toBe(true);
    expect(state.pagination.totalPages).toBe(2); // 10+5

    // ページ2に移動してもスコア0のカテゴリが正常に取得できる
    state = setPage(state, 2);
    const page2Entries = getPagedEntries(state);
    expect(page2Entries).toHaveLength(5);
    page2Entries.forEach((entry) => {
      entry.categorySummaryIcons.forEach((icon) => {
        expect(icon.totalScore).toBe(0);
      });
    });
  });

  // behavior: [追加] スコア100のカテゴリを持つ複数ページでもtotalScoreが正確
  it('[追加] スコア100のカテゴリを持つ履歴エントリのtotalScoreがページ移動後も100である', () => {
    const maxScoreEntries: HistoryEntry[] = Array.from({ length: 12 }, (_, i) => ({
      id: `max-${i}`,
      createdAt: new Date(2024, 0, 12 - i).toISOString(),
      categories: [
        { name: '恋愛運', totalScore: 100, templateText: 'テキスト' },
      ],
    }));

    let state = createInitialHistoryState();
    state = setHistoryEntries(state, maxScoreEntries);
    state = setPage(state, 2);

    const page2Entries = getPagedEntries(state);
    expect(page2Entries).toHaveLength(2);
    page2Entries.forEach((entry) => {
      expect(entry.categorySummaryIcons[0]!.totalScore).toBe(100);
    });
  });
});
