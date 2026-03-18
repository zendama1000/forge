/**
 * カテゴリ別重みマトリクスによるスコア計算ロジック
 *
 * - WeightVector: 7次元の重みベクトル（Tuple型）
 * - WeightMatrix: カテゴリ名 → WeightVector のマッピング
 * - calculateWeightedScore: rawScores と重みから重み付きスコアを計算
 * - calculateAllCategoryScores: 全カテゴリに対して重み付きスコアを一括計算
 */

/**
 * 7次元の重みベクトル。
 * Tuple 型により、コンパイル時に要素数が正確に 7 であることを強制する。
 * 各重みは 0〜1 の値で、通常は合計が 1 になるよう設定する。
 */
export type WeightVector = [
  number,
  number,
  number,
  number,
  number,
  number,
  number,
];

/**
 * カテゴリ別重みマトリクス。
 * カテゴリ名（string）→ WeightVector のマッピング。
 *
 * WeightVector は Tuple 型なので、6要素や8要素の配列を代入しようとすると
 * TypeScript の型エラーとして検出される。
 */
export type WeightMatrix = Record<string, WeightVector>;

/**
 * 1次元の重み付きスコア計算結果
 */
export interface DimensionWeightedScore {
  /** 次元のインデックス（0〜6） */
  dimensionIndex: number;
  /** 入力されたrawスコア（0〜100） */
  rawScore: number;
  /** この次元に適用された重み */
  weight: number;
  /** 重み付きスコア = rawScore × weight */
  weightedScore: number;
}

/**
 * カテゴリの重み付きスコア計算結果
 */
export interface CategoryWeightedResult {
  /** 各次元の重み付きスコア計算結果 */
  dimensions: DimensionWeightedScore[];
  /** 正規化済み合計スコア = Σ(rawScore[i] × weight[i]) */
  totalScore: number;
}

/**
 * 重みベクトルの要素数を検証する。
 * 7要素でない場合はエラーをスローする。
 *
 * @param weights - 検証する重みの配列
 * @throws {Error} 要素数が 7 でない場合
 */
export function validateWeightVector(
  weights: number[],
): asserts weights is WeightVector {
  if (weights.length !== 7) {
    throw new Error(
      `重みベクトルは7要素が必要です。実際の要素数: ${weights.length}`,
    );
  }
}

/**
 * 7次元の rawScores と重みベクトルから重み付きスコアを計算する。
 *
 * totalScore は重みの合計が 1 である場合に 0〜100 の範囲に正規化される。
 * weightedScore[i] = rawScore[i] × weight[i]
 * totalScore = Σ weightedScore[i]
 *
 * @param rawScores - 7次元のrawスコア配列（各 0〜100）
 * @param weights - 重みベクトル（7要素必須）
 * @returns 重み付きスコアの計算結果
 * @throws {Error} weightsの要素数が7でない場合
 */
export function calculateWeightedScore(
  rawScores: number[],
  weights: number[],
): CategoryWeightedResult {
  validateWeightVector(weights);

  const dimensions: DimensionWeightedScore[] = rawScores.map(
    (rawScore, index) => {
      const weight = weights[index];
      const weightedScore = rawScore * weight;
      return {
        dimensionIndex: index,
        rawScore,
        weight,
        weightedScore,
      };
    },
  );

  const totalScore = dimensions.reduce((sum, d) => sum + d.weightedScore, 0);

  return {
    dimensions,
    totalScore,
  };
}

/**
 * 全カテゴリに対して重みマトリクスを適用してスコアを一括計算する。
 *
 * @param rawScores - 7次元のrawスコア配列（各 0〜100）
 * @param weightMatrix - カテゴリ名 → WeightVector のマッピング
 * @returns カテゴリ名 → CategoryWeightedResult のマッピング
 * @throws {Error} いずれかのWeightVectorの要素数が7でない場合
 */
export function calculateAllCategoryScores(
  rawScores: number[],
  weightMatrix: WeightMatrix,
): Record<string, CategoryWeightedResult> {
  const results: Record<string, CategoryWeightedResult> = {};

  for (const [categoryName, weights] of Object.entries(weightMatrix)) {
    results[categoryName] = calculateWeightedScore(rawScores, weights);
  }

  return results;
}
