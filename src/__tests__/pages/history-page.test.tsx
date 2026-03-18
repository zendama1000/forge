/**
 * HistoryPage ロジック Layer 1 テスト
 *
 * 対象振る舞い:
 * - 履歴データ取得 → 時系列降順でエントリ一覧が表示される
 * - 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
 * - 履歴データ0件 → 空状態メッセージが表示される
 * - 履歴データ読み込み中 → ローディング状態が表示される
 *
 * テストフレームワーク: vitest
 */

import { describe, it, expect, vi } from 'vitest';
import {
  createInitialHistoryState,
  setHistoryLoading,
  setHistoryEntries,
  setHistoryError,
  buildEntryDisplay,
  getCategoryIcon,
  formatDate,
  fetchHistory,
  CATEGORY_ICON_MAP,
  DEFAULT_CATEGORY_ICON,
  EMPTY_HISTORY_MESSAGE,
  type HistoryEntry,
} from '../../components/history-page';

// ─── テスト用モックデータ ──────────────────────────────────────────────────────

const MOCK_ENTRY_1: HistoryEntry = {
  id: 'uuid-001',
  createdAt: '2024-01-15T14:30:00.000Z',
  categories: [
    { name: '恋愛運', totalScore: 75, templateText: '恋愛運は良好です。' },
    { name: '仕事運', totalScore: 60, templateText: '仕事運は普通です。' },
    { name: '金運', totalScore: 50, templateText: '金運は安定しています。' },
    { name: '健康運', totalScore: 80, templateText: '健康運は優れています。' },
  ],
};

const MOCK_ENTRY_2: HistoryEntry = {
  id: 'uuid-002',
  createdAt: '2024-01-16T10:00:00.000Z', // ENTRY_1より新しい
  categories: [
    { name: '恋愛運', totalScore: 40, templateText: '恋愛運は低調です。' },
    { name: '仕事運', totalScore: 90, templateText: '仕事運は絶好調です。' },
    { name: '金運', totalScore: 70, templateText: '金運は良好です。' },
    { name: '健康運', totalScore: 55, templateText: '健康運は普通です。' },
  ],
};

const MOCK_ENTRY_3: HistoryEntry = {
  id: 'uuid-003',
  createdAt: '2024-01-14T08:00:00.000Z', // 最も古い
  categories: [
    { name: '恋愛運', totalScore: 85, templateText: '恋愛運は絶好調です。' },
    { name: '仕事運', totalScore: 45, templateText: '仕事運は低調です。' },
    { name: '金運', totalScore: 30, templateText: '金運は低調です。' },
    { name: '健康運', totalScore: 65, templateText: '健康運は良好です。' },
  ],
};

// ─── カテゴリアイコン ──────────────────────────────────────────────────────────

describe('HistoryPage: カテゴリアイコン', () => {
  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('既知カテゴリ名（恋愛運・仕事運・金運・健康運）に正しいアイコンが返される', () => {
    expect(getCategoryIcon('恋愛運')).toBe('💕');
    expect(getCategoryIcon('仕事運')).toBe('💼');
    expect(getCategoryIcon('金運')).toBe('💰');
    expect(getCategoryIcon('健康運')).toBe('🌿');
  });

  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('CATEGORY_ICON_MAPに4カテゴリのアイコンが定義されている', () => {
    expect(Object.keys(CATEGORY_ICON_MAP)).toHaveLength(4);
    expect(CATEGORY_ICON_MAP['恋愛運']).toBeDefined();
    expect(CATEGORY_ICON_MAP['仕事運']).toBeDefined();
    expect(CATEGORY_ICON_MAP['金運']).toBeDefined();
    expect(CATEGORY_ICON_MAP['健康運']).toBeDefined();
  });

  // behavior: [追加] 未定義カテゴリにはデフォルトアイコンが返される
  it('[追加] エッジケース: 未知カテゴリ名にはDEFAULT_CATEGORY_ICONが返される', () => {
    expect(getCategoryIcon('未知の運')).toBe(DEFAULT_CATEGORY_ICON);
    expect(getCategoryIcon('')).toBe(DEFAULT_CATEGORY_ICON);
  });
});

// ─── 日時フォーマット ─────────────────────────────────────────────────────────

describe('HistoryPage: 日時フォーマット', () => {
  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('ISO 8601文字列を日本語ロケール形式の日時文字列に変換する', () => {
    const result = formatDate('2024-01-15T14:30:00.000Z');
    // 結果が空でなく、日時情報を含む文字列であることを確認
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
    // 年・月・日のいずれかが含まれること（ロケールにより形式が異なる）
    expect(result).toMatch(/2024/);
  });

  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('異なるタイムスタンプは異なるフォーマット結果になる', () => {
    const result1 = formatDate('2024-01-15T14:30:00.000Z');
    const result2 = formatDate('2024-01-16T10:00:00.000Z');
    expect(result1).not.toBe(result2);
  });

  // behavior: [追加] エッジケース: 境界値タイムスタンプも正常処理
  it('[追加] エッジケース: Unix epoch (1970-01-01) のタイムスタンプも処理できる', () => {
    const result = formatDate('1970-01-01T00:00:00.000Z');
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });
});

// ─── エントリ表示変換 ─────────────────────────────────────────────────────────

describe('HistoryPage: buildEntryDisplay', () => {
  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('HistoryEntryをHistoryEntryDisplayに変換し、id・createdAt・formattedDate・categorySummaryIconsが含まれる', () => {
    const display = buildEntryDisplay(MOCK_ENTRY_1);

    // id フィールド
    expect(display.id).toBe('uuid-001');

    // createdAt フィールド（元のISO文字列が保持される）
    expect(display.createdAt).toBe('2024-01-15T14:30:00.000Z');

    // formattedDate フィールド（フォーマット済み文字列）
    expect(typeof display.formattedDate).toBe('string');
    expect(display.formattedDate.length).toBeGreaterThan(0);
    expect(display.formattedDate).toMatch(/2024/);

    // categorySummaryIcons フィールド（4カテゴリ）
    expect(display.categorySummaryIcons).toHaveLength(4);
  });

  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('各カテゴリアイコンにname・icon・totalScoreが含まれる', () => {
    const display = buildEntryDisplay(MOCK_ENTRY_1);

    // 恋愛運
    const loveIcon = display.categorySummaryIcons[0]!;
    expect(loveIcon.name).toBe('恋愛運');
    expect(loveIcon.icon).toBe('💕');
    expect(loveIcon.totalScore).toBe(75);

    // 仕事運
    const workIcon = display.categorySummaryIcons[1]!;
    expect(workIcon.name).toBe('仕事運');
    expect(workIcon.icon).toBe('💼');
    expect(workIcon.totalScore).toBe(60);

    // 金運
    const moneyIcon = display.categorySummaryIcons[2]!;
    expect(moneyIcon.name).toBe('金運');
    expect(moneyIcon.icon).toBe('💰');
    expect(moneyIcon.totalScore).toBe(50);

    // 健康運
    const healthIcon = display.categorySummaryIcons[3]!;
    expect(healthIcon.name).toBe('健康運');
    expect(healthIcon.icon).toBe('🌿');
    expect(healthIcon.totalScore).toBe(80);
  });

  // behavior: [追加] categoriesが空の場合、categorySummaryIconsも空になる
  it('[追加] エッジケース: categoriesが空の場合、categorySummaryIconsも空配列になる', () => {
    const entry: HistoryEntry = {
      id: 'empty-id',
      createdAt: '2024-01-15T14:30:00.000Z',
      categories: [],
    };
    const display = buildEntryDisplay(entry);
    expect(display.categorySummaryIcons).toHaveLength(0);
    expect(Array.isArray(display.categorySummaryIcons)).toBe(true);
  });

  // behavior: [追加] nameが未定義のカテゴリにはDEFAULT_CATEGORY_ICONが使われる
  it('[追加] categoryのname未定義時はデフォルトアイコンが使われる', () => {
    const entry: HistoryEntry = {
      id: 'test-id',
      createdAt: '2024-01-15T14:30:00.000Z',
      categories: [{ totalScore: 50, templateText: 'テキスト' }],
    };
    const display = buildEntryDisplay(entry);
    expect(display.categorySummaryIcons[0]!.icon).toBe(DEFAULT_CATEGORY_ICON);
    expect(display.categorySummaryIcons[0]!.name).toBe('');
  });
});

// ─── 初期状態 ─────────────────────────────────────────────────────────────────

describe('HistoryPage: 初期状態', () => {
  // behavior: 履歴データ0件 → 空状態メッセージが表示される
  it('createInitialHistoryStateがisEmpty=true・emptyMessage付きの状態を返す', () => {
    const state = createInitialHistoryState();

    expect(state.isEmpty).toBe(true);
    expect(state.emptyMessage).toBe(EMPTY_HISTORY_MESSAGE);
    expect(state.emptyMessage.length).toBeGreaterThan(0);
  });

  // behavior: 履歴データ読み込み中 → ローディング状態が表示される
  it('createInitialHistoryStateがisLoading=falseの状態を返す', () => {
    const state = createInitialHistoryState();
    expect(state.isLoading).toBe(false);
  });

  it('createInitialHistoryStateがentries=[]・error=nullの状態を返す', () => {
    const state = createInitialHistoryState();
    expect(state.entries).toHaveLength(0);
    expect(state.error).toBeNull();
  });
});

// ─── ローディング状態 ─────────────────────────────────────────────────────────

describe('HistoryPage: 履歴データ読み込み中 → ローディング状態が表示される', () => {
  // behavior: 履歴データ読み込み中 → ローディング状態が表示される
  it('setHistoryLoadingがisLoading=trueに設定する', () => {
    const state = createInitialHistoryState();
    expect(state.isLoading).toBe(false);

    const loadingState = setHistoryLoading(state);
    expect(loadingState.isLoading).toBe(true);
  });

  // behavior: 履歴データ読み込み中 → ローディング状態が表示される
  it('setHistoryLoading後もentries・isEmpty・emptyMessageは変わらない', () => {
    const state = createInitialHistoryState();
    const loadingState = setHistoryLoading(state);

    expect(loadingState.entries).toHaveLength(0);
    expect(loadingState.isEmpty).toBe(true);
    expect(loadingState.emptyMessage).toBe(EMPTY_HISTORY_MESSAGE);
  });

  // behavior: 履歴データ読み込み中 → ローディング状態が表示される
  it('setHistoryLoadingでerrorがクリアされる', () => {
    let state = createInitialHistoryState();
    state = setHistoryError(state, '前回のエラー');
    expect(state.error).toBe('前回のエラー');

    const loadingState = setHistoryLoading(state);
    expect(loadingState.error).toBeNull();
  });

  // behavior: 履歴データ取得後にisLoading=falseになる
  it('setHistoryEntriesでisLoading=falseに戻る', () => {
    let state = createInitialHistoryState();
    state = setHistoryLoading(state);
    expect(state.isLoading).toBe(true);

    state = setHistoryEntries(state, [MOCK_ENTRY_1]);
    expect(state.isLoading).toBe(false);
  });

  // behavior: [追加] エッジケース: setHistoryLoadingを複数回呼んでもisLoading=trueのまま（べき等）
  it('[追加] エッジケース: setHistoryLoadingを複数回呼んでもisLoading=true（べき等）', () => {
    let state = createInitialHistoryState();
    state = setHistoryLoading(state);
    state = setHistoryLoading(state);
    expect(state.isLoading).toBe(true);
  });
});

// ─── 履歴データ取得 → 時系列降順表示 ─────────────────────────────────────────

describe('HistoryPage: 履歴データ取得 → 時系列降順でエントリ一覧が表示される', () => {
  // behavior: 履歴データ取得 → 時系列降順でエントリ一覧が表示される
  it('setHistoryEntriesで複数エントリがcreatedAt降順でソートされる', () => {
    const state = createInitialHistoryState();
    // ENTRY_3(古) → ENTRY_1(中) → ENTRY_2(新) の順序で渡す（ソート前の順序）
    const entries = [MOCK_ENTRY_3, MOCK_ENTRY_1, MOCK_ENTRY_2];
    const resultState = setHistoryEntries(state, entries);

    // 降順: ENTRY_2(新) → ENTRY_1(中) → ENTRY_3(古)
    expect(resultState.entries).toHaveLength(3);
    expect(resultState.entries[0]!.id).toBe('uuid-002'); // 最新
    expect(resultState.entries[1]!.id).toBe('uuid-001'); // 中間
    expect(resultState.entries[2]!.id).toBe('uuid-003'); // 最古
  });

  // behavior: 履歴データ取得 → 時系列降順でエントリ一覧が表示される
  it('setHistoryEntriesでentries間のcreatedAtが降順（新しい順）であることを確認', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, [
      MOCK_ENTRY_1,
      MOCK_ENTRY_2,
      MOCK_ENTRY_3,
    ]);

    // 隣接するエントリのcreatedAtが降順
    for (let i = 0; i < resultState.entries.length - 1; i++) {
      const current = new Date(resultState.entries[i]!.createdAt).getTime();
      const next = new Date(resultState.entries[i + 1]!.createdAt).getTime();
      expect(current).toBeGreaterThanOrEqual(next);
    }
  });

  // behavior: 履歴データ取得 → 時系列降順でエントリ一覧が表示される
  it('setHistoryEntries後にisEmpty=falseになる（エントリあり）', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, [MOCK_ENTRY_1]);

    expect(resultState.isEmpty).toBe(false);
    expect(resultState.entries).toHaveLength(1);
  });

  // behavior: 履歴データ取得 → 時系列降順でエントリ一覧が表示される
  it('1件のエントリでもcreatedAt降順ソートが正常に動作する', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, [MOCK_ENTRY_1]);

    expect(resultState.entries).toHaveLength(1);
    expect(resultState.entries[0]!.id).toBe('uuid-001');
  });

  // behavior: [追加] 元のエントリ配列は変更されない（イミュータブル）
  it('[追加] setHistoryEntriesは元の配列を変更せず新しい状態を返す', () => {
    const state = createInitialHistoryState();
    const original = [MOCK_ENTRY_3, MOCK_ENTRY_1, MOCK_ENTRY_2];
    const originalCopy = [...original];

    setHistoryEntries(state, original);

    // 元配列は変更されていない
    expect(original).toEqual(originalCopy);
    expect(original[0]!.id).toBe('uuid-003'); // 元の順序が保持されている
  });

  // behavior: [追加] エッジケース: 同一createdAtのエントリが複数あっても正常処理
  it('[追加] エッジケース: 同一createdAtのエントリが複数あっても状態が壊れない', () => {
    const sameTimeEntry1: HistoryEntry = {
      id: 'same-1',
      createdAt: '2024-01-15T12:00:00.000Z',
      categories: [{ name: '恋愛運', totalScore: 70, templateText: 'テキスト' }],
    };
    const sameTimeEntry2: HistoryEntry = {
      id: 'same-2',
      createdAt: '2024-01-15T12:00:00.000Z',
      categories: [{ name: '仕事運', totalScore: 60, templateText: 'テキスト' }],
    };

    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, [sameTimeEntry1, sameTimeEntry2]);

    expect(resultState.entries).toHaveLength(2);
  });
});

// ─── 履歴データ0件 → 空状態メッセージ ────────────────────────────────────────

describe('HistoryPage: 履歴データ0件 → 空状態メッセージが表示される', () => {
  // behavior: 履歴データ0件 → 空状態メッセージが表示される
  it('setHistoryEntriesに空配列を渡すとisEmpty=trueになる', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, []);

    expect(resultState.isEmpty).toBe(true);
  });

  // behavior: 履歴データ0件 → 空状態メッセージが表示される
  it('空配列でsetHistoryEntries後もemptyMessageが設定されたまま', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, []);

    expect(resultState.emptyMessage).toBe(EMPTY_HISTORY_MESSAGE);
    expect(resultState.emptyMessage.length).toBeGreaterThan(0);
  });

  // behavior: 履歴データ0件 → 空状態メッセージが表示される
  it('EMPTY_HISTORY_MESSAGEが定義されており空文字列でない', () => {
    expect(typeof EMPTY_HISTORY_MESSAGE).toBe('string');
    expect(EMPTY_HISTORY_MESSAGE.length).toBeGreaterThan(0);
  });

  // behavior: [追加] エッジケース: 一度エントリが設定された後に空配列を渡すとisEmpty=trueになる
  it('[追加] エッジケース: エントリ設定後に空配列を渡すとisEmpty=trueに戻る', () => {
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, [MOCK_ENTRY_1]);
    expect(state.isEmpty).toBe(false);

    state = setHistoryEntries(state, []);
    expect(state.isEmpty).toBe(true);
    expect(state.entries).toHaveLength(0);
  });
});

// ─── 各エントリの表示情報 ─────────────────────────────────────────────────────

describe('HistoryPage: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される', () => {
  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('setHistoryEntries後の各エントリにid・formattedDate・categorySummaryIconsが含まれる', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, [MOCK_ENTRY_1, MOCK_ENTRY_2]);

    resultState.entries.forEach((entry) => {
      // id フィールド
      expect(typeof entry.id).toBe('string');
      expect(entry.id.length).toBeGreaterThan(0);

      // formattedDate フィールド
      expect(typeof entry.formattedDate).toBe('string');
      expect(entry.formattedDate.length).toBeGreaterThan(0);

      // categorySummaryIcons フィールド
      expect(Array.isArray(entry.categorySummaryIcons)).toBe(true);
      expect(entry.categorySummaryIcons.length).toBeGreaterThan(0);
    });
  });

  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('各カテゴリアイコンはname・icon（絵文字）・totalScore（数値）を持つ', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, [MOCK_ENTRY_1]);

    const entry = resultState.entries[0]!;
    entry.categorySummaryIcons.forEach((icon) => {
      expect(typeof icon.name).toBe('string');
      expect(typeof icon.icon).toBe('string');
      expect(icon.icon.length).toBeGreaterThan(0);
      expect(typeof icon.totalScore).toBe('number');
      expect(icon.totalScore).toBeGreaterThanOrEqual(0);
      expect(icon.totalScore).toBeLessThanOrEqual(100);
    });
  });

  // behavior: 各エントリにid・日時・カテゴリ別サマリーアイコンが表示される
  it('各エントリのidがユニークである（MOCK_ENTRY_1 と MOCK_ENTRY_2 のid比較）', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, [MOCK_ENTRY_1, MOCK_ENTRY_2]);

    const ids = resultState.entries.map((e) => e.id);
    const uniqueIds = new Set(ids);
    expect(uniqueIds.size).toBe(ids.length);
  });

  // behavior: [追加] 元のHistoryEntryのcreatedAtがcreatedAtフィールドに保持される
  it('[追加] 変換後のentriesのcreatedAtがISO文字列として保持される', () => {
    const state = createInitialHistoryState();
    const resultState = setHistoryEntries(state, [MOCK_ENTRY_1]);

    const entry = resultState.entries[0]!;
    expect(entry.createdAt).toBe('2024-01-15T14:30:00.000Z');
    // ISO 8601 形式の確認
    expect(new Date(entry.createdAt).toString()).not.toBe('Invalid Date');
  });
});

// ─── API 呼び出し ─────────────────────────────────────────────────────────────

describe('HistoryPage: fetchHistory API呼び出し', () => {
  // behavior: 履歴データ取得 → 時系列降順でエントリ一覧が表示される
  it('fetchHistoryがGET /api/fortune/historyを呼び出す', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => [MOCK_ENTRY_1, MOCK_ENTRY_2],
    });

    await fetchHistory(mockFetch as unknown as typeof fetch);

    expect(mockFetch).toHaveBeenCalledOnce();
    const [url] = mockFetch.mock.calls[0] as [string];
    expect(url).toBe('/api/fortune/history');
  });

  // behavior: 履歴データ取得 → 時系列降順でエントリ一覧が表示される
  it('fetchHistory成功時に{ entries, status:200 }が返される', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => [MOCK_ENTRY_1, MOCK_ENTRY_2],
    });

    const result = await fetchHistory(mockFetch as unknown as typeof fetch);

    expect('entries' in result).toBe(true);
    if ('entries' in result) {
      expect(result.status).toBe(200);
      expect(result.entries).toHaveLength(2);
      expect(result.entries[0]!.id).toBe('uuid-001');
    }
  });

  // behavior: [追加] fetchHistory失敗時に{ error, status }が返される
  it('[追加] fetchHistory失敗時に{ error, status }が返される', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
      json: async () => ({ error: 'サーバーエラー' }),
    });

    const result = await fetchHistory(mockFetch as unknown as typeof fetch);

    expect('error' in result).toBe(true);
    if ('error' in result) {
      expect(result.status).toBe(500);
      expect(typeof result.error).toBe('string');
      expect(result.error.length).toBeGreaterThan(0);
    }
  });

  // behavior: [追加] fetchHistory成功・エントリ0件の場合は空配列が返される
  it('[追加] fetchHistory成功時にエントリ0件の場合は空配列が返される', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => [],
    });

    const result = await fetchHistory(mockFetch as unknown as typeof fetch);

    expect('entries' in result).toBe(true);
    if ('entries' in result) {
      expect(result.entries).toHaveLength(0);
      expect(Array.isArray(result.entries)).toBe(true);
    }
  });

  // behavior: [追加] fetchHistoryとsetHistoryEntriesを組み合わせた統合テスト
  it('[追加] fetchHistory後にsetHistoryEntriesを使ってページ状態を更新できる', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => [MOCK_ENTRY_3, MOCK_ENTRY_1, MOCK_ENTRY_2],
    });

    let state = createInitialHistoryState();
    state = setHistoryLoading(state);
    expect(state.isLoading).toBe(true);

    const result = await fetchHistory(mockFetch as unknown as typeof fetch);
    if ('entries' in result) {
      state = setHistoryEntries(state, result.entries);
    }

    expect(state.isLoading).toBe(false);
    expect(state.isEmpty).toBe(false);
    expect(state.entries).toHaveLength(3);
    // 降順ソート: ENTRY_2(新) > ENTRY_1(中) > ENTRY_3(古)
    expect(state.entries[0]!.id).toBe('uuid-002');
    expect(state.entries[1]!.id).toBe('uuid-001');
    expect(state.entries[2]!.id).toBe('uuid-003');
  });
});

// ─── エラー状態 ───────────────────────────────────────────────────────────────

describe('HistoryPage: エラー状態', () => {
  // behavior: [追加] setHistoryErrorでerrorが設定されisLoading=falseになる
  it('[追加] setHistoryErrorでerrorが設定されisLoading=falseになる', () => {
    let state = createInitialHistoryState();
    state = setHistoryLoading(state);
    expect(state.isLoading).toBe(true);

    state = setHistoryError(state, 'ネットワークエラーが発生しました');
    expect(state.error).toBe('ネットワークエラーが発生しました');
    expect(state.isLoading).toBe(false);
  });

  // behavior: [追加] エラー後も既存のエントリは維持される
  it('[追加] setHistoryError後も既存のentriesは変更されない', () => {
    let state = createInitialHistoryState();
    state = setHistoryEntries(state, [MOCK_ENTRY_1]);
    expect(state.entries).toHaveLength(1);

    state = setHistoryError(state, 'エラー発生');
    // エラー後もentriesは維持
    expect(state.entries).toHaveLength(1);
    expect(state.error).toBe('エラー発生');
  });
});
