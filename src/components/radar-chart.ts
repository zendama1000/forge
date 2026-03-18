/**
 * RadarChart コンポーネントロジック
 *
 * 7次元スコアデータを recharts RadarChart 用データ形式に変換する。
 * JSX に依存しない純粋な TypeScript モジュール。
 *
 * Next.js の React コンポーネントからは next/dynamic（ssr:false）で
 * recharts をインポートし、これらの関数で生成したデータを渡す。
 *
 * UIプライマリ表示はアイコン/カラー+CSSプログレスバー。
 * RadarChart は詳細ビューのセカンダリ表示として使用（shadcn/ui charts 統合）。
 */

/** 7次元スコアの単一次元データ */
export interface DimensionScore {
  /** 次元名 */
  name: string;
  /** スコア（0〜100の整数） */
  score: number;
}

/** recharts RadarChart が期待するデータポイント形式 */
export interface RadarDataPoint {
  /** 軸ラベル（次元名） — PolarAngleAxis の dataKey */
  subject: string;
  /** スコア値（0〜100） — Radar の dataKey */
  value: number;
  /** ツールチップ表示用テキスト */
  tooltip: string;
  /** 元の次元名（ツールチップ参照用） */
  dimensionName: string;
}

/** RadarChart の描画設定 */
export interface RadarChartConfig {
  /** RadarChart に渡すデータ配列（recharts data prop） */
  data: RadarDataPoint[];
  /** 値の最大値（PolarRadiusAxis domain 設定用） */
  maxValue: number;
  /** 軸の数（次元数） */
  axisCount: number;
  /** データが有効かどうか */
  isValid: boolean;
  /** フォールバック表示フラグ（isValid=false のとき true） */
  showFallback: boolean;
  /** フォールバックメッセージ（showFallback=false のとき null） */
  fallbackMessage: string | null;
}

/** next/dynamic 用の動的インポート設定 */
export interface DynamicImportConfig {
  /** SSR を無効化（サーバーサイドレンダリング時のエラーを防ぐ） */
  ssr: false;
  /** ローディング中のフォールバック表示フラグ */
  loading: boolean;
}

/** RadarChart に渡す入力データ */
export type RadarChartInput = DimensionScore[] | null | undefined;

/** デフォルトの7次元ラベル */
export const DEFAULT_DIMENSION_NAMES = [
  '直感力',
  '感受性',
  '行動力',
  '洞察力',
  '共感力',
  '創造力',
  '意志力',
] as const;

/**
 * 7次元スコアデータを recharts RadarChart 用の描画設定に変換する。
 *
 * - null/undefined を渡すとフォールバック設定（showFallback=true）を返す
 * - 空配列を渡すとフォールバック設定を返す
 * - 全スコア0でも有効な設定を返す（中心点に縮小したレーダーを描画）
 *
 * @param dimensions 7次元スコアデータ（null/undefined の場合はフォールバック）
 * @returns RadarChartConfig
 */
export function createRadarChartConfig(dimensions: RadarChartInput): RadarChartConfig {
  // null/undefined → フォールバック
  if (dimensions == null) {
    return {
      data: [],
      maxValue: 100,
      axisCount: 0,
      isValid: false,
      showFallback: true,
      fallbackMessage: 'データを読み込めませんでした',
    };
  }

  // 空配列 → フォールバック
  if (dimensions.length === 0) {
    return {
      data: [],
      maxValue: 100,
      axisCount: 0,
      isValid: false,
      showFallback: true,
      fallbackMessage: 'データを読み込めませんでした',
    };
  }

  // 正常変換（全スコア0も有効）
  const data: RadarDataPoint[] = dimensions.map((dim) => ({
    subject: dim.name,
    value: dim.score,
    tooltip: createTooltipContent(dim.name, dim.score),
    dimensionName: dim.name,
  }));

  return {
    data,
    maxValue: 100,
    axisCount: data.length,
    isValid: true,
    showFallback: false,
    fallbackMessage: null,
  };
}

/**
 * next/dynamic の設定オブジェクトを返す。
 * ssr:false にすることでサーバーサイドレンダリング時のエラーを防ぐ。
 *
 * 使用例:
 * ```ts
 * const config = createDynamicImportConfig();
 * const RadarChart = dynamic(() => import('./RadarChartComponent'), config);
 * ```
 *
 * @returns DynamicImportConfig（ssr: false）
 */
export function createDynamicImportConfig(): DynamicImportConfig {
  return {
    ssr: false,
    loading: false,
  };
}

/**
 * ツールチップコンテンツを生成する。
 * マウスホバー時に次元名とスコア値を "次元名: スコア" 形式で返す。
 *
 * @param dimensionName 次元名
 * @param score スコア値（0〜100）
 * @returns ツールチップ表示テキスト
 */
export function createTooltipContent(dimensionName: string, score: number): string {
  return `${dimensionName}: ${score}`;
}

/**
 * 7次元スコアからデフォルト次元名付きのデータを生成する。
 * 次元名が未設定の場合のフォールバックとして使用する。
 *
 * @param scores 7つのスコア値（0〜100の配列）
 * @returns DimensionScore[]
 */
export function createDefaultDimensions(scores: number[]): DimensionScore[] {
  return scores.map((score, index) => ({
    name: DEFAULT_DIMENSION_NAMES[index] ?? `次元${index + 1}`,
    score,
  }));
}
