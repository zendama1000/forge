/**
 * RadarChart コンポーネントロジック Layer 1 テスト
 *
 * - createRadarChartConfig() の7次元データ変換を検証
 * - createDynamicImportConfig() の ssr:false 設定を検証
 * - createTooltipContent() のツールチップ生成を検証
 * - createDefaultDimensions() のデフォルト次元名生成を検証
 * - 全次元スコア0のデータ処理を検証
 * - null/undefined フォールバックを検証
 * - 全 required_behaviors をカバー
 *
 * vitest + node 環境（DOM レンダリングなし）
 */

import { describe, it, expect } from 'vitest';
import {
  createRadarChartConfig,
  createDynamicImportConfig,
  createTooltipContent,
  createDefaultDimensions,
  DEFAULT_DIMENSION_NAMES,
} from '../../components/radar-chart';
import type { DimensionScore } from '../../components/radar-chart';

// ─── テスト用フィクスチャ ──────────────────────────────────────────────────────

const SEVEN_DIMENSIONS: DimensionScore[] = [
  { name: '直感力', score: 85 },
  { name: '感受性', score: 70 },
  { name: '行動力', score: 60 },
  { name: '洞察力', score: 75 },
  { name: '共感力', score: 90 },
  { name: '創造力', score: 55 },
  { name: '意志力', score: 80 },
];

const ALL_ZERO_DIMENSIONS: DimensionScore[] = [
  { name: '直感力', score: 0 },
  { name: '感受性', score: 0 },
  { name: '行動力', score: 0 },
  { name: '洞察力', score: 0 },
  { name: '共感力', score: 0 },
  { name: '創造力', score: 0 },
  { name: '意志力', score: 0 },
];

// ─── createRadarChartConfig() ─────────────────────────────────────────────────

describe('createRadarChartConfig()', () => {
  // behavior: 7次元スコアデータをRadarChartコンポーネントに渡す → SVG要素内にレーダー描画
  it('7次元スコアデータを渡すとrecharts RadarChart用データが生成される（7軸分のdataが含まれる）', () => {
    const config = createRadarChartConfig(SEVEN_DIMENSIONS);

    expect(config.isValid).toBe(true);
    expect(config.showFallback).toBe(false);
    expect(config.axisCount).toBe(7);
    expect(config.data).toHaveLength(7);
  });

  // behavior: 7次元スコアデータをRadarChartコンポーネントに渡す → SVG要素内にレーダー描画
  it('dataの各要素がsubject（次元名）とvalue（スコア）を持つ（recharts RadarChart dataKey対応）', () => {
    const config = createRadarChartConfig(SEVEN_DIMENSIONS);

    expect(config.data[0].subject).toBe('直感力');
    expect(config.data[0].value).toBe(85);
    expect(config.data[1].subject).toBe('感受性');
    expect(config.data[1].value).toBe(70);
    expect(config.data[6].subject).toBe('意志力');
    expect(config.data[6].value).toBe(80);
  });

  // behavior: 7次元スコアデータをRadarChartコンポーネントに渡す → SVG要素内にレーダー描画
  it('maxValueが100でaxisCountが次元数と一致する（recharts PolarRadiusAxis domain設定用）', () => {
    const config = createRadarChartConfig(SEVEN_DIMENSIONS);

    expect(config.maxValue).toBe(100);
    expect(config.axisCount).toBe(7);
    expect(config.fallbackMessage).toBeNull();
  });

  // behavior: 全次元スコア0のデータ → 中心点に縮小したレーダー描画、エラーなし
  it('全次元スコア0でもエラーにならず有効な設定を返す（isValid=true、data.length=7）', () => {
    expect(() => createRadarChartConfig(ALL_ZERO_DIMENSIONS)).not.toThrow();

    const config = createRadarChartConfig(ALL_ZERO_DIMENSIONS);

    expect(config.isValid).toBe(true);
    expect(config.showFallback).toBe(false);
    expect(config.axisCount).toBe(7);
    expect(config.data).toHaveLength(7);
    expect(config.fallbackMessage).toBeNull();
  });

  // behavior: 全次元スコア0のデータ → 中心点に縮小したレーダー描画、エラーなし
  it('全スコア0のdataは各value=0を持つ（中心点に縮小したレーダーのデータ）', () => {
    const config = createRadarChartConfig(ALL_ZERO_DIMENSIONS);

    config.data.forEach((point) => {
      expect(point.value).toBe(0);
    });
  });

  // behavior: 次元データがnull/undefinedの場合 → フォールバック表示またはエラーメッセージ
  it('nullを渡すとフォールバック設定を返す（isValid=false、showFallback=true、fallbackMessage非null）', () => {
    expect(() => createRadarChartConfig(null)).not.toThrow();

    const config = createRadarChartConfig(null);

    expect(config.isValid).toBe(false);
    expect(config.showFallback).toBe(true);
    expect(config.fallbackMessage).not.toBeNull();
    expect(typeof config.fallbackMessage).toBe('string');
    expect(config.data).toHaveLength(0);
    expect(config.axisCount).toBe(0);
  });

  // behavior: 次元データがnull/undefinedの場合 → フォールバック表示またはエラーメッセージ
  it('undefinedを渡すとフォールバック設定を返す（isValid=false、showFallback=true）', () => {
    expect(() => createRadarChartConfig(undefined)).not.toThrow();

    const config = createRadarChartConfig(undefined);

    expect(config.isValid).toBe(false);
    expect(config.showFallback).toBe(true);
    expect(config.fallbackMessage).not.toBeNull();
    expect(config.data).toHaveLength(0);
  });

  // behavior: [追加] 空配列エッジケース
  it('空配列を渡すとフォールバック設定を返す（isValid=false）', () => {
    expect(() => createRadarChartConfig([])).not.toThrow();

    const config = createRadarChartConfig([]);

    expect(config.isValid).toBe(false);
    expect(config.showFallback).toBe(true);
    expect(config.fallbackMessage).not.toBeNull();
    expect(config.data).toHaveLength(0);
  });

  // behavior: [追加] 7次元未満のデータも処理できる
  it('7次元未満（例:3次元）でも正常に変換される（axisCount=3）', () => {
    const threeDimensions: DimensionScore[] = [
      { name: '直感力', score: 50 },
      { name: '感受性', score: 60 },
      { name: '行動力', score: 70 },
    ];

    const config = createRadarChartConfig(threeDimensions);

    expect(config.isValid).toBe(true);
    expect(config.axisCount).toBe(3);
    expect(config.data).toHaveLength(3);
  });
});

// ─── createDynamicImportConfig() ─────────────────────────────────────────────

describe('createDynamicImportConfig()', () => {
  // behavior: next/dynamicでssr:false指定でimport → サーバーサイドレンダリング時にエラーなし
  it('ssr:falseを持つ設定オブジェクトを返す（SSRエラー防止）', () => {
    const config = createDynamicImportConfig();

    expect(config.ssr).toBe(false);
  });

  // behavior: next/dynamicでssr:false指定でimport → サーバーサイドレンダリング時にエラーなし
  it('node環境（SSR相当）でcreateRadarChartConfigを呼び出してもエラーにならない', () => {
    // next/dynamic ssr:false のモジュールはSSR時にはレンダリングされないが、
    // ロジック関数自体はサーバー環境でも安全に実行できることを検証する
    expect(() => createDynamicImportConfig()).not.toThrow();
    expect(() => createRadarChartConfig(SEVEN_DIMENSIONS)).not.toThrow();
  });

  // behavior: [追加] loading フィールドが含まれる
  it('loading=falseが含まれる（動的ローディング設定）', () => {
    const config = createDynamicImportConfig();

    expect(config.loading).toBe(false);
  });
});

// ─── createTooltipContent() ──────────────────────────────────────────────────

describe('createTooltipContent()', () => {
  // behavior: 各データポイントにマウスホバー → ツールチップに次元名とスコア値を表示
  it('次元名とスコア値を含むツールチップ文字列を返す（"次元名: スコア"形式）', () => {
    const tooltip = createTooltipContent('直感力', 85);

    expect(tooltip).toContain('直感力');
    expect(tooltip).toContain('85');
  });

  // behavior: 各データポイントにマウスホバー → ツールチップに次元名とスコア値を表示
  it('RadarChartConfig.data の各要素の tooltip フィールドが正しい形式になっている', () => {
    const config = createRadarChartConfig(SEVEN_DIMENSIONS);

    config.data.forEach((point) => {
      expect(point.tooltip).toContain(point.dimensionName);
      expect(point.tooltip).toContain(String(point.value));
    });
  });

  // behavior: 各データポイントにマウスホバー → ツールチップに次元名とスコア値を表示
  it('スコア0のデータポイントでもツールチップが正しく生成される', () => {
    const tooltip = createTooltipContent('感受性', 0);

    expect(tooltip).toContain('感受性');
    expect(tooltip).toContain('0');
  });

  // behavior: 各データポイントにマウスホバー → ツールチップに次元名とスコア値を表示
  it('全次元スコア0のdataでもツールチップが全てのdataPointに含まれる', () => {
    const config = createRadarChartConfig(ALL_ZERO_DIMENSIONS);

    config.data.forEach((point) => {
      expect(typeof point.tooltip).toBe('string');
      expect(point.tooltip.length).toBeGreaterThan(0);
      expect(point.tooltip).toContain('0');
    });
  });

  // behavior: [追加] スコア100のエッジケース
  it('スコア100のツールチップも正しく生成される', () => {
    const tooltip = createTooltipContent('意志力', 100);

    expect(tooltip).toContain('意志力');
    expect(tooltip).toContain('100');
  });
});

// ─── createDefaultDimensions() ───────────────────────────────────────────────

describe('createDefaultDimensions()', () => {
  // behavior: [追加] 7つのデフォルト次元名が付与される
  it('7つのスコアを渡すとDEFAULT_DIMENSION_NAMESが付与された7次元データが返される', () => {
    const scores = [85, 70, 60, 75, 90, 55, 80];
    const dimensions = createDefaultDimensions(scores);

    expect(dimensions).toHaveLength(7);
    dimensions.forEach((dim, index) => {
      expect(dim.name).toBe(DEFAULT_DIMENSION_NAMES[index]);
      expect(dim.score).toBe(scores[index]);
    });
  });

  // behavior: [追加] createRadarChartConfigに渡して有効な設定が得られる
  it('createDefaultDimensionsの出力をcreateRadarChartConfigに渡すと有効な設定が返される', () => {
    const scores = [85, 70, 60, 75, 90, 55, 80];
    const dimensions = createDefaultDimensions(scores);
    const config = createRadarChartConfig(dimensions);

    expect(config.isValid).toBe(true);
    expect(config.axisCount).toBe(7);
    expect(config.data).toHaveLength(7);
  });
});

// ─── データ整合性統合テスト ────────────────────────────────────────────────────

describe('RadarChart データ整合性統合テスト', () => {
  // behavior: 7次元スコアデータをRadarChartコンポーネントに渡す → SVG要素内にレーダー描画
  it('dimensionNameがsubjectと一致し、ツールチップで参照できる（全7次元）', () => {
    const config = createRadarChartConfig(SEVEN_DIMENSIONS);

    config.data.forEach((point) => {
      expect(point.dimensionName).toBe(point.subject);
      expect(point.tooltip).toContain(point.dimensionName);
    });
  });

  // behavior: 次元データがnull/undefinedの場合 → フォールバック表示またはエラーメッセージ
  it('nullとundefinedのフォールバックメッセージは同じ文字列', () => {
    const fromNull = createRadarChartConfig(null);
    const fromUndefined = createRadarChartConfig(undefined);

    expect(fromNull.fallbackMessage).toBe(fromUndefined.fallbackMessage);
    expect(fromNull.fallbackMessage).toBe('データを読み込めませんでした');
  });

  // behavior: [追加] isValidとshowFallbackが常に逆の値を持つ
  it('isValidとshowFallbackは常に逆の値を持つ（一方がtrueならもう一方はfalse）', () => {
    const validConfig = createRadarChartConfig(SEVEN_DIMENSIONS);
    expect(validConfig.isValid).toBe(true);
    expect(validConfig.showFallback).toBe(false);

    const invalidConfig = createRadarChartConfig(null);
    expect(invalidConfig.isValid).toBe(false);
    expect(invalidConfig.showFallback).toBe(true);
  });
});
