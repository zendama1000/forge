/**
 * TabNavigation コンポーネントロジック
 *
 * 4カテゴリ間のタブ切替に必要なデータ（aria属性・data-testid・
 * onChangeコールバック）を計算する純粋な TypeScript モジュール。
 * JSX に依存しない。Next.js の React コンポーネントからこの関数を呼び出す。
 */

/** タブに表示するカテゴリのデータ型 */
export interface TabNavigationCategory {
  /** カテゴリの一意識別子（例: "love", "work", "money", "health"） */
  id: string;
  /** カテゴリの表示名（例: "恋愛運", "仕事運"） */
  name: string;
}

/** createTabNavigation() に渡す入力プロパティ */
export interface TabNavigationProps {
  /** 表示するカテゴリ一覧 */
  categories: TabNavigationCategory[];
  /** 現在アクティブなカテゴリ ID */
  activeTab: string;
  /** タブクリック時に呼び出されるコールバック。引数はクリックされたカテゴリ ID */
  onChange: (categoryId: string) => void;
}

/** 個々のタブボタンに対応するデータ */
export interface TabItem {
  /** カテゴリ ID */
  id: string;
  /** カテゴリ表示名 */
  name: string;
  /** data-testid 属性値（例: "tab-love"） */
  dataTestId: string;
  /** aria-selected 属性値。activeTab と一致するタブのみ true */
  ariaSelected: boolean;
  /** ボタンクリック時に呼び出す関数（onChange(id) を発火する） */
  onClick: () => void;
}

/** createTabNavigation() が返す状態 */
export interface TabNavigationState {
  /** レンダリング対象のタブリスト */
  tabs: TabItem[];
  /**
   * コンポーネントを表示するか否か。
   * categories が空（0件）のとき false を返し、コンポーネントを非表示にする。
   */
  isVisible: boolean;
}

/**
 * TabNavigation の表示に必要な状態を計算する。
 *
 * - categories が空の場合 → isVisible=false、tabs=[]
 * - activeTab と一致するタブ → ariaSelected=true
 * - 各タブ → dataTestId="tab-{id}"
 * - onClick → onChange(id) を発火
 *
 * @param props TabNavigationProps
 * @returns TabNavigationState
 */
export function createTabNavigation(props: TabNavigationProps): TabNavigationState {
  const { categories, activeTab, onChange } = props;

  if (categories.length === 0) {
    return {
      tabs: [],
      isVisible: false,
    };
  }

  const tabs: TabItem[] = categories.map((category) => ({
    id: category.id,
    name: category.name,
    dataTestId: `tab-${category.id}`,
    ariaSelected: category.id === activeTab,
    onClick: () => onChange(category.id),
  }));

  return {
    tabs,
    isVisible: true,
  };
}
