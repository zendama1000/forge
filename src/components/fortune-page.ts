/**
 * FortunePage ロジック
 *
 * 7次元パラメータ入力フォームと占い結果表示のための
 * JSX に依存しない純粋な TypeScript モジュール。
 * Next.js の React コンポーネントからはこのモジュールの関数を呼び出す。
 */

import {
  createFortuneCard,
  type FortuneCardState,
  type FortuneCardCategory,
} from './fortune-card';

// ─── 7次元パラメータ定義 ───────────────────────────────────────────────────────

export interface DimensionDefinition {
  /** 次元の表示名 */
  name: string;
  /** 次元アイコン（絵文字） */
  icon: string;
}

/**
 * 7次元パラメータの定義。
 * 各次元には表示名とアイコンがある。
 */
export const DIMENSIONS: readonly DimensionDefinition[] = [
  { name: '運気', icon: '⭐' },
  { name: '活力', icon: '⚡' },
  { name: '知性', icon: '💡' },
  { name: '感情', icon: '💖' },
  { name: '財運', icon: '💰' },
  { name: '健康', icon: '🌿' },
  { name: '社交', icon: '👥' },
] as const;

// ─── ページ状態管理 ────────────────────────────────────────────────────────────

export interface DimensionInput extends DimensionDefinition {
  /** 入力値（0〜100 整数） */
  value: number;
}

export interface FortunePageState {
  /** 7次元パラメータ入力値 */
  dimensions: DimensionInput[];
  /** API通信中フラグ */
  isLoading: boolean;
  /** 占い結果カード（APIレスポンス後に設定、未取得時は null） */
  resultCards: FortuneCardState[] | null;
  /** エラーメッセージ（エラー時に設定、正常時は null） */
  error: string | null;
}

/**
 * FortunePageの初期状態を生成する。
 * 全次元は50で初期化される。
 */
export function createInitialPageState(): FortunePageState {
  return {
    dimensions: DIMENSIONS.map((d) => ({ ...d, value: 50 })),
    isLoading: false,
    resultCards: null,
    error: null,
  };
}

/**
 * 指定インデックスの次元値を更新した新しい状態を返す。
 * 値は 0〜100 にクランプし、整数に丸める。
 *
 * @param state 現在のページ状態
 * @param index 更新する次元のインデックス（0〜6）
 * @param value 新しい値
 * @returns 更新後の新しい状態（イミュータブル）
 */
export function updateDimensionValue(
  state: FortunePageState,
  index: number,
  value: number,
): FortunePageState {
  if (index < 0 || index >= state.dimensions.length) return state;
  const clamped = Math.max(0, Math.min(100, Math.round(value)));
  const dimensions = state.dimensions.map((d, i) =>
    i === index ? { ...d, value: clamped } : d,
  );
  return { ...state, dimensions };
}

/**
 * ローディング状態を開始した新しい状態を返す（isLoading=true）。
 */
export function setLoadingState(state: FortunePageState): FortunePageState {
  return { ...state, isLoading: true, error: null };
}

/**
 * APIレスポンスのカテゴリ配列から FortuneCardState の配列を生成する。
 * 各カテゴリの name・totalScore・templateText を FortuneCard 形式に変換する。
 *
 * @param categories APIレスポンスのカテゴリ配列
 * @returns FortuneCardState の配列（カテゴリ名・スコア・プログレスバースタイルを含む）
 */
export function buildResultCards(
  categories: FortuneCardCategory[],
): FortuneCardState[] {
  return categories.map((cat) => createFortuneCard({ category: cat }));
}

/**
 * APIレスポンス受信後の状態を設定した新しい状態を返す。
 * isLoading=false にし、resultCards に変換済みカードをセットする。
 *
 * @param state 現在のページ状態
 * @param categories APIレスポンスのカテゴリ配列
 * @returns 更新後の新しい状態
 */
export function setResultState(
  state: FortunePageState,
  categories: FortuneCardCategory[],
): FortunePageState {
  return {
    ...state,
    isLoading: false,
    resultCards: buildResultCards(categories),
    error: null,
  };
}

/**
 * エラー状態を設定した新しい状態を返す（isLoading=false、error更新）。
 *
 * @param state 現在のページ状態
 * @param error エラーメッセージ
 * @returns 更新後の新しい状態
 */
export function setErrorState(
  state: FortunePageState,
  error: string,
): FortunePageState {
  return { ...state, isLoading: false, error };
}

// ─── API呼び出し ───────────────────────────────────────────────────────────────

export interface FortuneRequestInfo {
  url: string;
  method: 'POST';
  headers: { 'Content-Type': string };
  body: string;
}

/**
 * POST /api/fortune のリクエスト情報を生成する。
 * state の dimensions 値を配列化してボディに含める。
 *
 * @param state 現在のページ状態
 * @returns リクエスト情報オブジェクト
 */
export function buildFortuneRequest(
  state: FortunePageState,
): FortuneRequestInfo {
  return {
    url: '/api/fortune',
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ dimensions: state.dimensions.map((d) => d.value) }),
  };
}

export type SubmitFortuneResult =
  | { categories: FortuneCardCategory[]; status: number }
  | { error: string; status: number };

/**
 * POST /api/fortune を呼び出して占い結果を取得する。
 *
 * @param state 現在のページ状態
 * @param fetchFn fetch の実装（テスト時に差し替え可能、デフォルトはグローバル fetch）
 * @returns 成功時: { categories, status } / 失敗時: { error, status }
 */
export async function submitFortune(
  state: FortunePageState,
  fetchFn: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<SubmitFortuneResult> {
  const req = buildFortuneRequest(state);
  const response = await fetchFn(req.url, {
    method: req.method,
    headers: req.headers,
    body: req.body,
  });

  if (!response.ok) {
    let errorMessage = 'エラーが発生しました';
    try {
      const errorBody = (await response.json()) as { error?: string };
      errorMessage = errorBody.error ?? errorMessage;
    } catch {
      // JSON パース失敗時はデフォルトメッセージを使用
    }
    return { error: errorMessage, status: response.status };
  }

  const data = (await response.json()) as { categories: FortuneCardCategory[] };
  return { categories: data.categories, status: response.status };
}
