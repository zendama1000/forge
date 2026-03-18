/**
 * Responsive design and color-blind accessibility logic
 *
 * レスポンシブデザイン（375px/768px/1280px）と色覚多様性対応の
 * JSX に依存しない純粋な TypeScript モジュール。
 *
 * 主な責務:
 * - ビューポート判定 (mobile / tablet / desktop)
 * - ビューポート別レイアウト設定の計算
 * - 7次元パラメータの冗長表現定義（アイコン + カラー）
 * - 弁別性バリデーション（色のみに依存しないことを保証）
 */

// ─── ビューポートブレークポイント ──────────────────────────────────────────────

/**
 * レスポンシブデザインのブレークポイント定義（ピクセル）。
 * - mobile: 375px（スマートフォン標準幅）
 * - tablet: 768px（タブレット標準幅）
 * - desktop: 1280px（デスクトップ標準幅）
 */
export const BREAKPOINTS = {
  mobile: 375,
  tablet: 768,
  desktop: 1280,
} as const;

export type Viewport = 'mobile' | 'tablet' | 'desktop';

// ─── レイアウト設定型 ─────────────────────────────────────────────────────────

/**
 * カードレイアウトモード:
 * - stack: 縦積み（モバイル）
 * - grid: グリッド配置（タブレット）
 * - full-width: フル幅（デスクトップ）
 */
export type CardLayout = 'stack' | 'grid' | 'full-width';

/**
 * タブレイアウトモード:
 * - stack: 縦積み（モバイル）
 * - row: 横並び（タブレット/デスクトップ）
 */
export type TabLayout = 'stack' | 'row';

/**
 * プログレスバーレイアウトモード:
 * - stack: 縦積み（モバイル）
 * - inline: インライン横並び（タブレット/デスクトップ）
 */
export type ProgressBarLayout = 'stack' | 'inline';

/**
 * ビューポート別のレイアウト設定。
 * getLayoutConfig() / getLayoutConfigForWidth() で取得する。
 */
export interface LayoutConfig {
  /** 現在のビューポートタイプ */
  viewport: Viewport;
  /**
   * カードレイアウト:
   * - mobile → 'stack'（縦積み）
   * - tablet → 'grid'（グリッド）
   * - desktop → 'full-width'（フル幅）
   */
  cardLayout: CardLayout;
  /**
   * タブレイアウト:
   * - mobile → 'stack'（縦積み）
   * - tablet / desktop → 'row'（横並び）
   */
  tabLayout: TabLayout;
  /**
   * プログレスバーレイアウト:
   * - mobile → 'stack'（縦積み）
   * - tablet / desktop → 'inline'
   */
  progressBarLayout: ProgressBarLayout;
  /**
   * コンテンツ最大幅（CSS max-width 値）:
   * - mobile → '100%'
   * - tablet → '768px'
   * - desktop → '1280px'
   */
  contentMaxWidth: string;
}

// ─── ビューポート判定 ──────────────────────────────────────────────────────────

/**
 * ビューポート幅（ピクセル）からビューポートタイプを判定する。
 *
 * 判定ルール:
 * - widthPx < 768  → 'mobile'
 * - widthPx < 1280 → 'tablet'
 * - widthPx >= 1280 → 'desktop'
 *
 * @param widthPx ビューポート幅（ピクセル整数）
 * @returns Viewport タイプ
 */
export function detectViewport(widthPx: number): Viewport {
  if (widthPx < BREAKPOINTS.tablet) return 'mobile';
  if (widthPx < BREAKPOINTS.desktop) return 'tablet';
  return 'desktop';
}

/**
 * ビューポートタイプからレイアウト設定を生成する。
 *
 * - mobile（375px）: カード・タブ・プログレスバーが縦積みレイアウト
 * - tablet（768px）: 中間グリッドレイアウト、コンテンツ幅 768px
 * - desktop（1280px）: フル幅レイアウト、コンテンツ幅 1280px
 *
 * @param viewport ビューポートタイプ
 * @returns LayoutConfig オブジェクト
 */
export function getLayoutConfig(viewport: Viewport): LayoutConfig {
  switch (viewport) {
    case 'mobile':
      return {
        viewport: 'mobile',
        cardLayout: 'stack',
        tabLayout: 'stack',
        progressBarLayout: 'stack',
        contentMaxWidth: '100%',
      };
    case 'tablet':
      return {
        viewport: 'tablet',
        cardLayout: 'grid',
        tabLayout: 'row',
        progressBarLayout: 'inline',
        contentMaxWidth: '768px',
      };
    case 'desktop':
      return {
        viewport: 'desktop',
        cardLayout: 'full-width',
        tabLayout: 'row',
        progressBarLayout: 'inline',
        contentMaxWidth: '1280px',
      };
  }
}

/**
 * ビューポート幅からレイアウト設定を直接生成する。
 * detectViewport() + getLayoutConfig() の組み合わせショートカット。
 *
 * @param widthPx ビューポート幅（ピクセル）
 * @returns LayoutConfig オブジェクト
 */
export function getLayoutConfigForWidth(widthPx: number): LayoutConfig {
  return getLayoutConfig(detectViewport(widthPx));
}

// ─── 色覚多様性対応次元定義 ────────────────────────────────────────────────────

/**
 * 色覚多様性対応の次元表現。
 * アイコン（絵文字）とカラーの両方で各次元を表現することで、
 * 色だけに依存しない弁別（冗長表現）を実現する。
 */
export interface AccessibleDimension {
  /** 次元の表示名 */
  name: string;
  /** 次元を表す絵文字アイコン（色に依存しない視覚的弁別手段） */
  icon: string;
  /** 次元のテーマカラー（CSS color 文字列） */
  color: string;
  /** aria-label 用のラベル（スクリーンリーダー対応） */
  ariaLabel: string;
  /** data-testid 用の識別子 */
  testId: string;
}

/**
 * 7次元パラメータの色覚多様性対応定義。
 *
 * 各次元は以下の2つの視覚的手段で弁別される（冗長表現）:
 * 1. アイコン（絵文字）: 色覚に依存しない形状による弁別
 * 2. カラー: 色覚正常者向けの視覚的区別
 *
 * 色の選択は、第1色覚異常・第2色覚異常シミュレーションでも
 * アイコンによって補完的に弁別できることを前提としている。
 */
export const ACCESSIBLE_DIMENSIONS: readonly AccessibleDimension[] = [
  {
    name: '運気',
    icon: '⭐',
    color: '#f59e0b', // amber-500
    ariaLabel: '運気スコア',
    testId: 'dim-lucky',
  },
  {
    name: '活力',
    icon: '⚡',
    color: '#ef4444', // red-500
    ariaLabel: '活力スコア',
    testId: 'dim-vitality',
  },
  {
    name: '知性',
    icon: '💡',
    color: '#3b82f6', // blue-500
    ariaLabel: '知性スコア',
    testId: 'dim-intellect',
  },
  {
    name: '感情',
    icon: '💖',
    color: '#ec4899', // pink-500
    ariaLabel: '感情スコア',
    testId: 'dim-emotion',
  },
  {
    name: '財運',
    icon: '💰',
    color: '#10b981', // emerald-500
    ariaLabel: '財運スコア',
    testId: 'dim-wealth',
  },
  {
    name: '健康',
    icon: '🌿',
    color: '#8b5cf6', // violet-500
    ariaLabel: '健康スコア',
    testId: 'dim-health',
  },
  {
    name: '社交',
    icon: '👥',
    color: '#f97316', // orange-500
    ariaLabel: '社交スコア',
    testId: 'dim-social',
  },
] as const;

// ─── 弁別性バリデーション ─────────────────────────────────────────────────────

/**
 * 全次元のアイコンが一意（重複なし）であることを検証する。
 * アイコンが全て異なれば、色覚に依存せず形状で弁別できる。
 *
 * @param dimensions 次元定義の配列
 * @returns アイコンが全て一意であれば true
 */
export function hasUniqueIcons(dimensions: readonly AccessibleDimension[]): boolean {
  const icons = dimensions.map((d) => d.icon);
  return new Set(icons).size === icons.length;
}

/**
 * 全次元のカラーが一意（重複なし）であることを検証する。
 *
 * @param dimensions 次元定義の配列
 * @returns カラーが全て一意であれば true
 */
export function hasUniqueColors(dimensions: readonly AccessibleDimension[]): boolean {
  const colors = dimensions.map((d) => d.color);
  return new Set(colors).size === colors.length;
}

/**
 * 全次元の名前が一意（重複なし）であることを検証する。
 *
 * @param dimensions 次元定義の配列
 * @returns 名前が全て一意であれば true
 */
export function hasUniqueNames(dimensions: readonly AccessibleDimension[]): boolean {
  const names = dimensions.map((d) => d.name);
  return new Set(names).size === names.length;
}

/**
 * 全次元のアイコンが空でないことを検証する。
 * 空アイコンはアクセシビリティを損なうため禁止する。
 *
 * @param dimensions 次元定義の配列
 * @returns 全アイコンが空でなければ true
 */
export function hasNonEmptyIcons(dimensions: readonly AccessibleDimension[]): boolean {
  return dimensions.every((d) => d.icon.trim().length > 0);
}

// ─── 冗長表現ユーティリティ ───────────────────────────────────────────────────

/**
 * 次元の冗長表現情報（色覚シミュレーション対応）。
 * アイコンとラベルの組み合わせで色覚に依存しない識別を実現する。
 */
export interface DimensionRedundancy {
  /** 次元の表示名 */
  name: string;
  /** 次元アイコン（絵文字） */
  icon: string;
  /** 次元カラー */
  color: string;
  /** アイコン + ラベルを結合した弁別文字列（色覚非依存の識別子） */
  iconLabel: string;
  /** aria-label（スクリーンリーダー用） */
  ariaLabel: string;
}

/**
 * 次元定義から冗長表現情報を取得する。
 *
 * @param dimension 次元定義
 * @returns 冗長表現情報オブジェクト
 */
export function getDimensionRedundancy(dimension: AccessibleDimension): DimensionRedundancy {
  return {
    name: dimension.name,
    icon: dimension.icon,
    color: dimension.color,
    iconLabel: `${dimension.icon} ${dimension.name}`,
    ariaLabel: dimension.ariaLabel,
  };
}

/**
 * 全7次元の冗長表現リストを返す。
 * 色覚シミュレーション環境でのレンダリング検証に使用する。
 *
 * @returns 全7次元の DimensionRedundancy 配列
 */
export function getAllDimensionRedundancies(): DimensionRedundancy[] {
  return ACCESSIBLE_DIMENSIONS.map(getDimensionRedundancy);
}

/**
 * 指定名の次元定義を取得する（見つからない場合は undefined）。
 *
 * @param name 次元の表示名
 * @returns AccessibleDimension | undefined
 */
export function getDimensionByName(name: string): AccessibleDimension | undefined {
  return ACCESSIBLE_DIMENSIONS.find((d) => d.name === name);
}
