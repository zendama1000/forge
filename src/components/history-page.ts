/**
 * HistoryPage ロジック
 *
 * GET /api/fortune/history から履歴データを取得し、
 * 時系列降順リスト・カテゴリ別サマリーアイコン・
 * ローディング状態・空状態メッセージを管理する
 * JSX に依存しない純粋な TypeScript モジュール。
 *
 * Next.js の React コンポーネントからはこのモジュールの関数を呼び出す。
 */

// ─── 型定義 ───────────────────────────────────────────────────────────────────

/**
 * API レスポンスの各カテゴリ概要
 */
export interface HistoryCategorySummary {
  /** カテゴリ表示名 (例: '恋愛運', '仕事運', '金運', '健康運') */
  name?: string;
  /** 合計スコア (0〜100) */
  totalScore: number;
  /** テンプレートテキスト */
  templateText: string;
}

/**
 * API レスポンスの履歴エントリ
 */
export interface HistoryEntry {
  /** UUID */
  id: string;
  /** ISO 8601 タイムスタンプ */
  createdAt: string;
  /** カテゴリ概要の配列 */
  categories: HistoryCategorySummary[];
}

/**
 * 表示用のカテゴリサマリーアイコン情報
 */
export interface CategoryIcon {
  /** カテゴリ表示名 */
  name: string;
  /** カテゴリを表す絵文字アイコン */
  icon: string;
  /** 合計スコア */
  totalScore: number;
}

/**
 * 表示用の履歴エントリ（フォーマット済み）
 */
export interface HistoryEntryDisplay {
  /** UUID */
  id: string;
  /** ISO 8601 タイムスタンプ（ソート用） */
  createdAt: string;
  /** ロケール形式でフォーマットされた日時文字列 */
  formattedDate: string;
  /** カテゴリ別サマリーアイコンの配列 */
  categorySummaryIcons: CategoryIcon[];
}

/**
 * ページネーション状態
 */
export interface PaginationState {
  /** 現在のページ番号（1-indexed） */
  currentPage: number;
  /** 総ページ数 */
  totalPages: number;
  /** 1ページあたりの表示件数 */
  pageSize: number;
  /** 総アイテム数 */
  totalItems: number;
}

/**
 * 履歴ページの全状態。
 * createInitialHistoryState() で生成し、各 setter 関数で不変更新する。
 */
export interface HistoryPageState {
  /** 表示用エントリ一覧（createdAt 降順ソート済み、全件） */
  entries: HistoryEntryDisplay[];
  /** API通信中フラグ */
  isLoading: boolean;
  /** データ0件かどうか */
  isEmpty: boolean;
  /** 空状態メッセージ */
  emptyMessage: string;
  /** APIエラーメッセージ（null=正常） */
  error: string | null;
  /** ページネーション状態 */
  pagination: PaginationState;
}

// ─── カテゴリアイコンマップ ────────────────────────────────────────────────────

/**
 * カテゴリ名 → 絵文字アイコンのマッピング
 */
export const CATEGORY_ICON_MAP: Readonly<Record<string, string>> = {
  恋愛運: '💕',
  仕事運: '💼',
  金運: '💰',
  健康運: '🌿',
} as const;

/** デフォルトアイコン（未定義カテゴリ用） */
export const DEFAULT_CATEGORY_ICON = '🔮';

/** 空状態メッセージ */
export const EMPTY_HISTORY_MESSAGE = '占い履歴がありません';

/** 1ページあたりのデフォルト表示件数 */
export const DEFAULT_PAGE_SIZE = 10;

/** ネットワークエラー時のユーザーフレンドリーメッセージ */
export const NETWORK_ERROR_MESSAGE =
  'ネットワークエラーが発生しました。接続を確認してください。';

// ─── ユーティリティ関数 ───────────────────────────────────────────────────────

/**
 * カテゴリ名に対応する絵文字アイコンを返す。
 * 未定義のカテゴリ名には DEFAULT_CATEGORY_ICON を返す。
 *
 * @param name カテゴリ表示名
 * @returns 絵文字アイコン文字列
 */
export function getCategoryIcon(name: string): string {
  return CATEGORY_ICON_MAP[name] ?? DEFAULT_CATEGORY_ICON;
}

/**
 * ISO 8601 タイムスタンプを日本語ロケールの日時文字列にフォーマットする。
 *
 * @param isoString ISO 8601 形式の日時文字列
 * @returns フォーマット済み日時文字列 (例: '2024/01/15 14:30')
 */
export function formatDate(isoString: string): string {
  const date = new Date(isoString);
  return date.toLocaleString('ja-JP', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

// ─── エントリ変換 ─────────────────────────────────────────────────────────────

/**
 * API レスポンスの HistoryEntry を表示用 HistoryEntryDisplay に変換する。
 * - formattedDate: 日本語ロケール形式
 * - categorySummaryIcons: カテゴリ名からアイコンを解決
 *
 * @param entry API レスポンスの履歴エントリ
 * @returns 表示用の履歴エントリ
 */
export function buildEntryDisplay(entry: HistoryEntry): HistoryEntryDisplay {
  return {
    id: entry.id,
    createdAt: entry.createdAt,
    formattedDate: formatDate(entry.createdAt),
    categorySummaryIcons: entry.categories.map((cat) => ({
      name: cat.name ?? '',
      icon: getCategoryIcon(cat.name ?? ''),
      totalScore: cat.totalScore,
    })),
  };
}

// ─── ページネーション ──────────────────────────────────────────────────────────

/**
 * ページネーション状態を生成する。
 *
 * @param totalItems 総アイテム数
 * @param pageSize 1ページあたりの件数（デフォルト: DEFAULT_PAGE_SIZE）
 * @returns 初期化済み PaginationState（currentPage=1）
 */
export function createPaginationState(
  totalItems: number,
  pageSize: number = DEFAULT_PAGE_SIZE,
): PaginationState {
  const totalPages = totalItems === 0 ? 0 : Math.ceil(totalItems / pageSize);
  return {
    currentPage: 1,
    totalPages,
    pageSize,
    totalItems,
  };
}

/**
 * 現在ページのエントリ一覧を返す（ページネーション適用済みスライス）。
 *
 * @param state 現在の HistoryPageState
 * @returns 現在ページのエントリ配列
 */
export function getPagedEntries(state: HistoryPageState): HistoryEntryDisplay[] {
  const { currentPage, pageSize } = state.pagination;
  const startIndex = (currentPage - 1) * pageSize;
  const endIndex = startIndex + pageSize;
  return state.entries.slice(startIndex, endIndex);
}

/**
 * ページを切り替えた新しい状態を返す。
 * 範囲外のページ番号はクランプする（1〜totalPages）。
 *
 * @param state 現在の HistoryPageState
 * @param page 移動先ページ番号（1-indexed）
 * @returns 更新後の新しい HistoryPageState（不変更新）
 */
export function setPage(state: HistoryPageState, page: number): HistoryPageState {
  const { totalPages } = state.pagination;
  const clampedPage = Math.max(1, Math.min(page, totalPages || 1));
  return {
    ...state,
    pagination: {
      ...state.pagination,
      currentPage: clampedPage,
    },
  };
}

/**
 * ページネーションコントロールを表示すべきかどうかを返す。
 * 総ページ数が 2 以上の場合に true。
 *
 * @param state 現在の HistoryPageState
 * @returns ページネーション表示が必要なら true
 */
export function hasPagination(state: HistoryPageState): boolean {
  return state.pagination.totalPages >= 2;
}

// ─── ページ状態生成 ───────────────────────────────────────────────────────────

/**
 * 履歴ページの初期状態を生成する（ローディング前の初期状態）。
 *
 * @returns 初期化済み HistoryPageState
 */
export function createInitialHistoryState(): HistoryPageState {
  return {
    entries: [],
    isLoading: false,
    isEmpty: true,
    emptyMessage: EMPTY_HISTORY_MESSAGE,
    error: null,
    pagination: createPaginationState(0),
  };
}

// ─── 状態更新関数 ─────────────────────────────────────────────────────────────

/**
 * ローディング状態を開始した新しい状態を返す（isLoading=true）。
 *
 * @param state 現在の HistoryPageState
 * @returns 更新後の新しい HistoryPageState（不変更新）
 */
export function setHistoryLoading(state: HistoryPageState): HistoryPageState {
  return { ...state, isLoading: true, error: null };
}

/**
 * API レスポンスの履歴エントリ配列で状態を更新した新しい状態を返す。
 * - entries を createdAt 降順（最新順）にソートして表示用に変換する
 * - isEmpty は entries が 0 件のとき true
 *
 * @param state 現在の HistoryPageState
 * @param entries API レスポンスの履歴エントリ配列
 * @returns 更新後の新しい HistoryPageState（不変更新）
 */
export function setHistoryEntries(
  state: HistoryPageState,
  entries: HistoryEntry[],
): HistoryPageState {
  // createdAt 降順ソート（API が降順を保証するが、念のためクライアント側でも保証）
  const sorted = [...entries].sort(
    (a, b) =>
      new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime(),
  );
  const displayEntries = sorted.map(buildEntryDisplay);

  return {
    ...state,
    isLoading: false,
    entries: displayEntries,
    isEmpty: displayEntries.length === 0,
    error: null,
    pagination: createPaginationState(displayEntries.length, state.pagination.pageSize),
  };
}

/**
 * エラー状態を設定した新しい状態を返す（isLoading=false）。
 *
 * @param state 現在の HistoryPageState
 * @param error ユーザー向けエラーメッセージ
 * @returns 更新後の新しい HistoryPageState（不変更新）
 */
export function setHistoryError(
  state: HistoryPageState,
  error: string,
): HistoryPageState {
  return { ...state, isLoading: false, error };
}

// ─── API 呼び出し ─────────────────────────────────────────────────────────────

export type FetchHistoryResult =
  | { entries: HistoryEntry[]; status: number }
  | { error: string; status: number };

/**
 * GET /api/fortune/history を呼び出して履歴データを取得する。
 *
 * @param fetchFn fetch の実装（テスト時に差し替え可能、デフォルトはグローバル fetch）
 * @returns 成功時: { entries, status } / 失敗時: { error, status }
 */
export async function fetchHistory(
  fetchFn: (url: string) => Promise<Response> = fetch,
): Promise<FetchHistoryResult> {
  try {
    const response = await fetchFn('/api/fortune/history');

    if (!response.ok) {
      let errorMessage = '履歴の取得に失敗しました';
      try {
        const body = (await response.json()) as { error?: string };
        errorMessage = body.error ?? errorMessage;
      } catch {
        // JSON パース失敗時はデフォルトメッセージを使用
      }
      return { error: errorMessage, status: response.status };
    }

    const entries = (await response.json()) as HistoryEntry[];
    return { entries, status: response.status };
  } catch {
    // ネットワークエラー（fetch 自体が throw する場合）
    return { error: NETWORK_ERROR_MESSAGE, status: 0 };
  }
}
