/**
 * ProgressiveDisclosure コンポーネントロジック
 *
 * サマリーカード → 詳細展開（CSS Transition）の開閉状態を管理する。
 * JSX に依存しない純粋な TypeScript モジュール。
 * Next.js の React コンポーネントからはこれらの関数を呼び出して状態を取得する。
 *
 * 各カテゴリの開閉状態は互いに独立しており、一つ展開しても他は影響を受けない。
 */

/** 開示コンポーネントに渡すカテゴリデータ */
export interface DisclosureCategory {
  /** カテゴリの一意識別子（例: "love", "work"）*/
  id: string;
  /** カテゴリ表示名 */
  name?: string;
  /** スコア（0〜100） */
  totalScore?: number;
  /** テンプレートテキスト */
  templateText?: string;
  /** 7次元パラメータ一覧。空配列の場合は「データなし」表示 */
  dimensions?: Array<{ name?: string; rawScore: number; label?: string }>;
}

/** 単一カテゴリの開閉状態 */
export interface DisclosureItemState {
  /** カテゴリ ID */
  categoryId: string;
  /** 詳細セクションが展開されているか */
  isExpanded: boolean;
  /**
   * aria-expanded 属性値の文字列表現。
   * isExpanded=true → 'true', isExpanded=false → 'false'
   */
  ariaExpanded: 'true' | 'false';
  /**
   * 詳細セクションの data-testid 属性値。
   * 形式: 'fortune-detail-{categoryId}'
   */
  detailTestId: string;
  /** dimensions が1件以上あるか */
  hasData: boolean;
  /**
   * dimensions が空の場合に表示するメッセージ。
   * データがある場合は null。
   */
  emptyMessage: string | null;
}

/** 複数カテゴリの開閉状態をまとめた集合状態 */
export interface ProgressiveDisclosureState {
  /** 各カテゴリの開閉状態リスト */
  items: DisclosureItemState[];
}

/**
 * 単一カテゴリの初期開閉状態を生成する（初期値: 閉じた状態）。
 *
 * @param category DisclosureCategory
 * @returns DisclosureItemState（isExpanded=false）
 */
export function createDisclosureItem(category: DisclosureCategory): DisclosureItemState {
  const hasData = (category.dimensions?.length ?? 0) > 0;

  return {
    categoryId: category.id,
    isExpanded: false,
    ariaExpanded: 'false',
    detailTestId: `fortune-detail-${category.id}`,
    hasData,
    emptyMessage: hasData ? null : 'データなし',
  };
}

/**
 * 複数カテゴリの初期開閉状態を生成する。
 * 全カテゴリが閉じた状態（isExpanded=false）で初期化される。
 *
 * @param categories DisclosureCategory[]
 * @returns ProgressiveDisclosureState
 */
export function createProgressiveDisclosure(
  categories: DisclosureCategory[]
): ProgressiveDisclosureState {
  return {
    items: categories.map(createDisclosureItem),
  };
}

/**
 * 単一アイテムの開閉状態をトグルする（不変更新）。
 *
 * - isExpanded=false → isExpanded=true, ariaExpanded='true'
 * - isExpanded=true  → isExpanded=false, ariaExpanded='false'
 *
 * @param state DisclosureItemState
 * @returns 新しい DisclosureItemState（元の state は変更しない）
 */
export function toggleDisclosureItem(state: DisclosureItemState): DisclosureItemState {
  const nextExpanded = !state.isExpanded;
  return {
    ...state,
    isExpanded: nextExpanded,
    ariaExpanded: nextExpanded ? 'true' : 'false',
  };
}

/**
 * 指定カテゴリの開閉状態をトグルする。
 * 他のカテゴリの状態は変更されない（独立した状態管理）。
 *
 * @param state ProgressiveDisclosureState
 * @param categoryId トグル対象のカテゴリ ID
 * @returns 新しい ProgressiveDisclosureState（不変更新）
 */
export function toggleCategory(
  state: ProgressiveDisclosureState,
  categoryId: string
): ProgressiveDisclosureState {
  return {
    items: state.items.map((item) =>
      item.categoryId === categoryId ? toggleDisclosureItem(item) : item
    ),
  };
}
