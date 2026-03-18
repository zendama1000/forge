/**
 * WeightMatrix - カテゴリ別重みマトリクスのスコア計算ロジック ユニットテスト
 */

import { describe, it, expect } from 'vitest';
import {
  type WeightVector,
  type WeightMatrix,
  calculateWeightedScore,
  calculateAllCategoryScores,
  validateWeightVector,
} from '../../logic/weight-matrix';

describe('WeightMatrix - カテゴリ別重みマトリクスのスコア計算', () => {
  // ─── 正規化スコアの基本動作 ────────────────────────────────────────────────

  // behavior: 全次元スコア50、均等重み[1/7×7] → totalScore=50.0（正規化済み）
  it('均等重みで全次元スコア50の場合、totalScoreが50.0になる（正規化済み）', () => {
    const rawScores = [50, 50, 50, 50, 50, 50, 50];
    const weights: WeightVector = [
      1 / 7,
      1 / 7,
      1 / 7,
      1 / 7,
      1 / 7,
      1 / 7,
      1 / 7,
    ];
    const result = calculateWeightedScore(rawScores, weights);
    // Σ(50 × 1/7) × 7 = 50
    expect(result.totalScore).toBeCloseTo(50.0, 5);
  });

  // behavior: 全次元スコア0 → totalScore=0、全weightedScore=0
  it('全次元スコアが0の場合、totalScoreも全weightedScoreも0になる', () => {
    const rawScores = [0, 0, 0, 0, 0, 0, 0];
    const weights: WeightVector = [0.2, 0.2, 0.15, 0.15, 0.1, 0.1, 0.1];
    const result = calculateWeightedScore(rawScores, weights);
    expect(result.totalScore).toBe(0);
    expect(result.dimensions).toHaveLength(7);
    result.dimensions.forEach((d) => {
      expect(d.weightedScore).toBe(0);
    });
  });

  // behavior: 全次元スコア100 → totalScore=100、weightedScore=各weight×100
  it('全次元スコアが100の場合、totalScoreが100で各weightedScoreがweight×100になる', () => {
    const rawScores = [100, 100, 100, 100, 100, 100, 100];
    // 合計が1になる重みベクトル
    const weights: WeightVector = [0.2, 0.2, 0.15, 0.15, 0.1, 0.1, 0.1];
    const result = calculateWeightedScore(rawScores, weights);
    // Σweight = 1.0 なので totalScore = 100
    expect(result.totalScore).toBeCloseTo(100, 5);
    result.dimensions.forEach((d, i) => {
      expect(d.weightedScore).toBeCloseTo(weights[i] * 100, 10);
    });
  });

  // behavior: 偏り重み[0.5,0.2,0.1,0.1,0.05,0.03,0.02]で次元1=100他=0 → totalScore=50
  it('偏り重みで次元0のみ100、他は0の場合、totalScoreが50になる', () => {
    const rawScores = [100, 0, 0, 0, 0, 0, 0];
    const weights: WeightVector = [0.5, 0.2, 0.1, 0.1, 0.05, 0.03, 0.02];
    const result = calculateWeightedScore(rawScores, weights);
    // 100 × 0.5 = 50, 他は0
    expect(result.totalScore).toBeCloseTo(50, 10);
  });

  // ─── 個別計算の正確性 ──────────────────────────────────────────────────────

  // behavior: weightedScore = rawScore × categoryWeight[dimensionIndex] の個別計算が正確
  it('各次元のweightedScoreがrawScore×weight[dimensionIndex]の正確な積になる', () => {
    const rawScores = [80, 60, 40, 20, 100, 0, 50];
    const weights: WeightVector = [0.3, 0.25, 0.15, 0.1, 0.1, 0.05, 0.05];
    const result = calculateWeightedScore(rawScores, weights);

    expect(result.dimensions).toHaveLength(7);
    result.dimensions.forEach((d, i) => {
      // 個別の積が正確であることを検証
      expect(d.weightedScore).toBeCloseTo(rawScores[i] * weights[i], 10);
      // メタデータも正確に記録されていること
      expect(d.rawScore).toBe(rawScores[i]);
      expect(d.weight).toBe(weights[i]);
      expect(d.dimensionIndex).toBe(i);
    });

    // totalScore = Σ weightedScore
    const expectedTotal = rawScores.reduce(
      (sum, s, i) => sum + s * weights[i],
      0,
    );
    expect(result.totalScore).toBeCloseTo(expectedTotal, 10);
  });

  // ─── 複数カテゴリへの適用 ──────────────────────────────────────────────────

  // behavior: 4カテゴリに異なる重みベクトル適用 → カテゴリ毎に異なるtotalScore算出
  it('4カテゴリに異なる重みベクトルを適用するとカテゴリ毎に異なるtotalScoreが算出される', () => {
    const rawScores = [100, 50, 25, 75, 60, 30, 80];
    const weightMatrix: WeightMatrix = {
      love:   [0.3,  0.25, 0.15, 0.1,  0.1,  0.05, 0.05],
      work:   [0.1,  0.1,  0.3,  0.25, 0.1,  0.1,  0.05],
      health: [0.05, 0.1,  0.1,  0.1,  0.3,  0.25, 0.1 ],
      money:  [0.15, 0.1,  0.05, 0.1,  0.1,  0.3,  0.2 ],
    };

    const results = calculateAllCategoryScores(rawScores, weightMatrix);

    // 4カテゴリすべての結果が存在すること
    expect(results).toHaveProperty('love');
    expect(results).toHaveProperty('work');
    expect(results).toHaveProperty('health');
    expect(results).toHaveProperty('money');

    // 各カテゴリのtotalScoreが算出されていること
    const scores = Object.values(results).map((r) => r.totalScore);
    expect(scores).toHaveLength(4);
    scores.forEach((s) => {
      expect(typeof s).toBe('number');
      expect(isFinite(s)).toBe(true);
    });

    // 異なる重みベクトルで異なるtotalScoreが算出されること
    // (重みを変えると少なくとも1つは値が異なるはず)
    const uniqueScores = new Set(scores.map((s) => Math.round(s * 1000)));
    expect(uniqueScores.size).toBeGreaterThan(1);

    // 手動計算で love カテゴリのスコアを検証
    const expectedLoveScore =
      100 * 0.3 +
      50 * 0.25 +
      25 * 0.15 +
      75 * 0.1 +
      60 * 0.1 +
      30 * 0.05 +
      80 * 0.05;
    expect(results.love.totalScore).toBeCloseTo(expectedLoveScore, 10);
  });

  // ─── バリデーション（エラースロー） ───────────────────────────────────────

  // behavior: 重みベクトルの要素数が7以外 → エラースロー
  it('重みベクトルが6要素の場合、エラーをスローする', () => {
    const rawScores = [50, 50, 50, 50, 50, 50, 50];
    const invalidWeights = [0.2, 0.2, 0.2, 0.2, 0.1, 0.1]; // 6要素
    expect(() =>
      calculateWeightedScore(rawScores, invalidWeights),
    ).toThrow(/7要素/);
  });

  it('重みベクトルが8要素の場合、エラーをスローする', () => {
    const rawScores = [50, 50, 50, 50, 50, 50, 50];
    const invalidWeights = [0.15, 0.15, 0.15, 0.15, 0.1, 0.1, 0.1, 0.1]; // 8要素
    expect(() =>
      calculateWeightedScore(rawScores, invalidWeights),
    ).toThrow(/7要素/);
  });

  it('空の重みベクトルの場合、エラーをスローする', () => {
    const rawScores = [50, 50, 50, 50, 50, 50, 50];
    expect(() => calculateWeightedScore(rawScores, [])).toThrow(/7要素/);
  });

  it('重みベクトルが1要素の場合、エラーをスローする', () => {
    const rawScores = [50, 50, 50, 50, 50, 50, 50];
    expect(() => calculateWeightedScore(rawScores, [1.0])).toThrow(/7要素/);
  });

  // validateWeightVector の直接テスト
  it('validateWeightVectorは7要素の配列に対してエラーをスローしない', () => {
    const weights = [0.2, 0.2, 0.15, 0.15, 0.1, 0.1, 0.1];
    expect(() => validateWeightVector(weights)).not.toThrow();
  });

  it('validateWeightVectorは6要素の配列に対してエラーをスローする', () => {
    const weights = [0.2, 0.2, 0.2, 0.2, 0.1, 0.1];
    expect(() => validateWeightVector(weights)).toThrow();
  });

  // ─── TypeScript 型安全性（コンパイル時型エラー検出） ─────────────────────

  // behavior: WeightMatrix型に次元数不一致（6要素や8要素）の配列を代入 → 型エラー検出
  it('WeightVector型に6要素配列を代入するとTypeScript型エラーが発生する（コンパイル時検出）', () => {
    // @ts-expect-error: WeightVector は7要素のTuple型。6要素はコンパイル時型エラー
    const invalidVector: WeightVector = [0.2, 0.2, 0.2, 0.2, 0.1, 0.1];
    // ランタイムでもエラーになることを確認
    expect(() =>
      calculateWeightedScore([50, 50, 50, 50, 50, 50, 50], invalidVector),
    ).toThrow();
  });

  it('WeightVector型に8要素配列を代入するとTypeScript型エラーが発生する（コンパイル時検出）', () => {
    // @ts-expect-error: WeightVector は7要素のTuple型。8要素はコンパイル時型エラー
    const invalidVector: WeightVector = [
      0.15, 0.15, 0.15, 0.15, 0.1, 0.1, 0.1, 0.1,
    ];
    // ランタイムでもエラーになることを確認
    expect(() =>
      calculateWeightedScore([50, 50, 50, 50, 50, 50, 50], invalidVector),
    ).toThrow();
  });

  it('WeightMatrix型の値に6要素配列を代入するとTypeScript型エラーが発生する（コンパイル時検出）', () => {
    // @ts-expect-error: WeightMatrix の値はWeightVector（7要素）。6要素はコンパイル時型エラー
    const invalidMatrix: WeightMatrix = {
      love: [0.2, 0.2, 0.2, 0.2, 0.1, 0.1],
    };
    // ランタイムでもエラーになることを確認
    expect(() =>
      calculateAllCategoryScores([50, 50, 50, 50, 50, 50, 50], invalidMatrix),
    ).toThrow();
  });

  // ─── エッジケース ──────────────────────────────────────────────────────────

  // behavior: [追加] rawScoresが全て0でかつweightsが偏っていても totalScore=0 を維持
  it('全rawScoresが0の場合、どんな重みベクトルでもtotalScoreは0になる', () => {
    const rawScores = [0, 0, 0, 0, 0, 0, 0];
    const biasedWeights: WeightVector = [0.9, 0.05, 0.01, 0.01, 0.01, 0.01, 0.01];
    const result = calculateWeightedScore(rawScores, biasedWeights);
    expect(result.totalScore).toBe(0);
  });

  // behavior: [追加] 1次元だけ高スコアで他は0の場合、totalScoreはその次元のweight×100
  it('次元6のみ100で他は0の場合、totalScoreはweights[6]×100になる', () => {
    const rawScores = [0, 0, 0, 0, 0, 0, 100];
    const weights: WeightVector = [0.5, 0.2, 0.1, 0.1, 0.05, 0.03, 0.02];
    const result = calculateWeightedScore(rawScores, weights);
    // 100 × 0.02 = 2
    expect(result.totalScore).toBeCloseTo(2, 10);
  });
});
