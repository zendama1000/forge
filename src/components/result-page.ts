/**
 * ResultPage ロジック
 *
 * 4カテゴリタブナビゲーション・段階的開示・重みマトリクス結果・
 * テンプレートテキスト・バリデーションエラー・APIエラーハンドリングを統合した
 * JSX に依存しない純粋な TypeScript モジュール。
 *
 * 依存:
 * - tab-navigation: タブ切替状態管理
 * - fortune-card: カテゴリカード表示状態管理
 * - progressive-disclosure: 詳細展開/折り畳み状態管理
 */

import {
  createTabNavigation,
  type TabNavigationState,
  type TabNavigationCategory,
} from './tab-navigation';
import {
  createFortuneCard,
  type FortuneCardState,
} from './fortune-card';
import {
  createProgressiveDisclosure,
  toggleCategory,
  type ProgressiveDisclosureState,
  type DisclosureCategory,
} from './progressive-disclosure';

// ─── カテゴリデータ型 ──────────────────────────────────────────────────────────

/**
 * APIレスポンスから受け取るカテゴリ結果データ。
 * 重みマトリクスはサーバー側で計算済み（totalScore, weightedScore を含む）。
 */
export interface ResultCategory {
  /** カテゴリ一意識別子 (例: 'love', 'work', 'money', 'health') */
  id: string;
  /** カテゴリ表示名 (例: '恋愛運', '仕事運', '金運', '健康運') */
  name: string;
  /**
   * 重みマトリクス計算済みの合計スコア。
   * totalScore = Σ(rawScore[i] × weight[i])（サーバー計算）
   */
  totalScore: number;
  /**
   * 重み付きスコア（表示用精度値）。
   * API が個別計算を返す場合はその値、返さない場合は totalScore と同値。
   */
  weightedScore: number;
  /** スコアバケット（高/中/低）に対応するテンプレートテキスト */
  templateText: string;
  /** 7次元パラメータデータ（段階的開示の詳細ビュー用） */
  dimensions: Array<{
    name?: string;
    rawScore: number;
    weightedScore?: number;
  }>;
}

// ─── 結果カードの拡張型 ────────────────────────────────────────────────────────

/**
 * 重みマトリクス情報を含む拡張FortuneCardState。
 * FortuneCardState に id / weightedScore / totalScore を追加する。
 */
export interface ResultFortuneCard extends FortuneCardState {
  /** カテゴリ一意識別子 */
  id: string;
  /**
   * 重みマトリクス計算済みの重み付きスコア。
   * Σ(rawScore[i] × weight[i]) の精度値。
   */
  weightedScore: number;
  /**
   * 最終スコア（= totalScore from API, ≈ weightedScore）。
   * 表示用にサーバーで正規化済み（0-100）。
   */
  totalScore: number;
}

// ─── バリデーションエラー型 ───────────────────────────────────────────────────

/**
 * 次元入力バリデーションエラーの種別コード
 */
export type ValidationErrorCode =
  | 'DIMENSION_COUNT_MISMATCH'
  | 'DIMENSION_OUT_OF_RANGE'
  | 'DIMENSION_NOT_INTEGER';

/**
 * バリデーションエラーの詳細情報
 */
export interface ValidationError {
  /** エラー種別コード */
  code: ValidationErrorCode;
  /** ユーザーフレンドリーなエラーメッセージ（日本語） */
  message: string;
  /** エラーが発生した次元のインデックス（0〜6）。全体エラーの場合は undefined */
  dimensionIndex?: number;
}

// ─── ページ状態型 ─────────────────────────────────────────────────────────────

/**
 * 結果表示ページの全状態。
 * createResultPage() で生成し、各 setter 関数で不変更新する。
 */
export interface ResultPageState {
  /** APIレスポンスのカテゴリ配列（重みマトリクス計算済み） */
  categories: ResultCategory[];
  /** 現在アクティブなタブのカテゴリ ID */
  activeTab: string;
  /** タブナビゲーションの表示状態 */
  tabNavigation: TabNavigationState;
  /** 各カテゴリの結果カード（重みマトリクス情報含む） */
  cards: ResultFortuneCard[];
  /** 段階的開示の開閉状態（カテゴリ別） */
  disclosure: ProgressiveDisclosureState;
  /** バリデーションエラーリスト（フォーム送信前の入力検証） */
  validationErrors: ValidationError[];
  /** APIエラーメッセージ（null=正常） */
  apiError: string | null;
  /** API通信中フラグ */
  isLoading: boolean;
  /** 結果が表示可能かどうか（categories が 1 件以上あれば true） */
  hasResult: boolean;
}

// ─── バリデーション ───────────────────────────────────────────────────────────

/**
 * 7次元パラメータ入力値をバリデーションする。
 *
 * エラー条件:
 * 1. 要素数が 7 でない → DIMENSION_COUNT_MISMATCH
 * 2. 値が整数でない   → DIMENSION_NOT_INTEGER
 * 3. 値が 0〜100 外   → DIMENSION_OUT_OF_RANGE
 *
 * @param dimensions バリデーション対象の次元値配列
 * @returns バリデーションエラーの配列（正常時は空配列）
 */
export function validateDimensions(dimensions: number[]): ValidationError[] {
  const errors: ValidationError[] = [];

  if (dimensions.length !== 7) {
    errors.push({
      code: 'DIMENSION_COUNT_MISMATCH',
      message: `7つの次元を入力してください（現在: ${dimensions.length}つ）`,
    });
    // 要素数不一致の場合は以降の検証をスキップ
    return errors;
  }

  for (let i = 0; i < dimensions.length; i++) {
    const value = dimensions[i];
    if (!Number.isInteger(value)) {
      errors.push({
        code: 'DIMENSION_NOT_INTEGER',
        message: `次元${i + 1}の値は整数で入力してください（現在: ${value}）`,
        dimensionIndex: i,
      });
    } else if (value < 0 || value > 100) {
      errors.push({
        code: 'DIMENSION_OUT_OF_RANGE',
        message: `次元${i + 1}の値は0〜100の範囲で入力してください（現在: ${value}）`,
        dimensionIndex: i,
      });
    }
  }

  return errors;
}

/**
 * バリデーションエラーのユーザーフレンドリーメッセージ一覧を返す。
 *
 * @param errors ValidationError の配列
 * @returns メッセージ文字列の配列
 */
export function getValidationErrorMessages(errors: ValidationError[]): string[] {
  return errors.map((e) => e.message);
}

// ─── カード構築 ───────────────────────────────────────────────────────────────

/**
 * ResultCategory から ResultFortuneCard を構築する。
 * FortuneCardState に id / weightedScore / totalScore を追加する。
 *
 * @param category 結果カテゴリデータ
 * @returns 重みマトリクス情報を含む ResultFortuneCard
 */
export function buildResultFortuneCard(category: ResultCategory): ResultFortuneCard {
  const cardState = createFortuneCard({
    score: category.totalScore,
    categoryName: category.name,
    category: {
      name: category.name,
      totalScore: category.totalScore,
      templateText: category.templateText,
      dimensions: category.dimensions,
    },
  });

  return {
    ...cardState,
    id: category.id,
    weightedScore: category.weightedScore,
    totalScore: category.totalScore,
  };
}

// ─── ページ状態生成 ───────────────────────────────────────────────────────────

/**
 * 4カテゴリの結果データから ResultPageState を生成する。
 *
 * - タブナビゲーション: 最初のカテゴリをアクティブタブとして初期化
 * - 結果カード: 各カテゴリの重みマトリクス情報含む FortuneCard
 * - 段階的開示: 全カテゴリ閉じた状態で初期化
 *
 * @param categories APIレスポンスのカテゴリ配列（4件想定）
 * @returns 初期化済み ResultPageState
 */
export function createResultPage(categories: ResultCategory[]): ResultPageState {
  const activeTab = categories[0]?.id ?? '';

  const tabCategories: TabNavigationCategory[] = categories.map((cat) => ({
    id: cat.id,
    name: cat.name,
  }));

  const tabNavigation = createTabNavigation({
    categories: tabCategories,
    activeTab,
    onChange: () => {
      // タブ切替は switchTab() 関数で管理する
    },
  });

  const cards = categories.map(buildResultFortuneCard);

  const disclosureCategories: DisclosureCategory[] = categories.map((cat) => ({
    id: cat.id,
    name: cat.name,
    totalScore: cat.totalScore,
    templateText: cat.templateText,
    dimensions: cat.dimensions,
  }));

  const disclosure = createProgressiveDisclosure(disclosureCategories);

  return {
    categories,
    activeTab,
    tabNavigation,
    cards,
    disclosure,
    validationErrors: [],
    apiError: null,
    isLoading: false,
    hasResult: categories.length > 0,
  };
}

/**
 * カテゴリなしの空の ResultPageState を生成する（初期状態）。
 *
 * @returns 空の ResultPageState（hasResult=false）
 */
export function createEmptyResultPage(): ResultPageState {
  return createResultPage([]);
}

// ─── タブ切替 ─────────────────────────────────────────────────────────────────

/**
 * アクティブタブを切り替えた新しい状態を返す。
 *
 * @param state 現在の ResultPageState
 * @param categoryId 切り替え先のカテゴリ ID
 * @returns 更新後の新しい ResultPageState（不変更新）
 */
export function switchTab(
  state: ResultPageState,
  categoryId: string,
): ResultPageState {
  const tabNavigation = createTabNavigation({
    categories: state.categories.map((cat) => ({ id: cat.id, name: cat.name })),
    activeTab: categoryId,
    onChange: () => {
      // タブ切替は switchTab() で管理
    },
  });

  return {
    ...state,
    activeTab: categoryId,
    tabNavigation,
  };
}

// ─── 段階的開示 ───────────────────────────────────────────────────────────────

/**
 * 指定カテゴリの詳細開示状態をトグルした新しい状態を返す。
 *
 * @param state 現在の ResultPageState
 * @param categoryId トグル対象のカテゴリ ID
 * @returns 更新後の新しい ResultPageState（不変更新）
 */
export function toggleCategoryDisclosure(
  state: ResultPageState,
  categoryId: string,
): ResultPageState {
  return {
    ...state,
    disclosure: toggleCategory(state.disclosure, categoryId),
  };
}

// ─── アクティブカード取得 ─────────────────────────────────────────────────────

/**
 * 現在アクティブなタブに対応する ResultFortuneCard を返す。
 * カテゴリが見つからない場合は null を返す。
 *
 * @param state 現在の ResultPageState
 * @returns アクティブカード（null = カテゴリ未設定）
 */
export function getActiveCard(
  state: ResultPageState,
): ResultFortuneCard | null {
  return state.cards.find((card) => card.id === state.activeTab) ?? null;
}

// ─── エラー状態管理 ───────────────────────────────────────────────────────────

/**
 * バリデーションエラーを設定した新しい状態を返す。
 *
 * @param state 現在の ResultPageState
 * @param errors バリデーションエラーの配列
 * @returns 更新後の新しい ResultPageState（不変更新）
 */
export function setValidationErrors(
  state: ResultPageState,
  errors: ValidationError[],
): ResultPageState {
  return {
    ...state,
    validationErrors: errors,
  };
}

/**
 * APIエラー状態を設定した新しい状態を返す（isLoading=false）。
 * エラーメッセージはユーザーフレンドリーな日本語文字列を渡す。
 *
 * @param state 現在の ResultPageState
 * @param error ユーザー向けエラーメッセージ
 * @returns 更新後の新しい ResultPageState（不変更新）
 */
export function setApiError(
  state: ResultPageState,
  error: string,
): ResultPageState {
  return {
    ...state,
    apiError: error,
    isLoading: false,
  };
}

/**
 * APIエラーからのリトライ開始状態を返す。
 * apiError をクリアし、isLoading=true に設定する。
 *
 * @param state 現在の ResultPageState
 * @returns 更新後の新しい ResultPageState（不変更新）
 */
export function retryRequest(state: ResultPageState): ResultPageState {
  return {
    ...state,
    apiError: null,
    isLoading: true,
  };
}

/**
 * リトライが可能な状態かどうかを返す。
 * apiError が設定されており、isLoading=false のとき true。
 *
 * @param state 現在の ResultPageState
 * @returns リトライ可能なら true
 */
export function canRetry(state: ResultPageState): boolean {
  return state.apiError !== null && !state.isLoading;
}

// ─── ローディング状態 ─────────────────────────────────────────────────────────

/**
 * ローディング状態を開始した新しい状態を返す（isLoading=true）。
 * apiError もクリアする。
 *
 * @param state 現在の ResultPageState
 * @returns 更新後の新しい ResultPageState（不変更新）
 */
export function setResultPageLoading(state: ResultPageState): ResultPageState {
  return {
    ...state,
    isLoading: true,
    apiError: null,
    validationErrors: [],
  };
}

/**
 * APIレスポンスのカテゴリ配列で結果状態を更新した新しい状態を返す。
 *
 * @param _state 現在の ResultPageState（バリデーションエラーは引き継がない）
 * @param categories APIレスポンスのカテゴリ配列
 * @returns 結果設定済みの新しい ResultPageState
 */
export function setResultFromApi(
  _state: ResultPageState,
  categories: ResultCategory[],
): ResultPageState {
  return {
    ...createResultPage(categories),
    validationErrors: [],
    apiError: null,
    isLoading: false,
    hasResult: true,
  };
}
