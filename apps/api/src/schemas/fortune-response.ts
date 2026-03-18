import { z } from 'zod';

/**
 * 占い結果の次元スキーマ
 *
 * 各次元は 0〜100 の整数の rawScore を持つ。
 */
export const DimensionResultSchema = z.object({
  name: z.string().optional(),
  rawScore: z
    .number()
    .int('rawScoreは整数でなければなりません')
    .min(0, 'rawScoreは0以上でなければなりません')
    .max(100, 'rawScoreは100以下でなければなりません'),
});

/**
 * 占い結果のカテゴリスキーマ
 *
 * - totalScore: 0〜100 の数値（合計スコア）
 * - templateText: スコアバケット（高/中/低）に基づく選択済みテキスト（1文字以上）
 * - dimensions: ちょうど7次元の配列
 */
export const CategoryResultSchema = z.object({
  name: z.string().optional(),
  totalScore: z
    .number()
    .min(0, 'totalScoreは0以上でなければなりません')
    .max(100, 'totalScoreは100以下でなければなりません'),
  templateText: z
    .string()
    .min(1, 'templateTextは1文字以上でなければなりません'),
  dimensions: z
    .array(DimensionResultSchema)
    .length(7, '各カテゴリには7次元が必要です'),
});

/**
 * 占いレスポンス全体のスキーマ
 *
 * - categories: 最低1カテゴリ以上の配列（通常4カテゴリ）
 */
export const FortuneResponseSchema = z.object({
  categories: z
    .array(CategoryResultSchema)
    .min(1, 'カテゴリは最低1つ必要です'),
});

/**
 * 各スキーマから推論される TypeScript 型
 */
export type DimensionResult = z.infer<typeof DimensionResultSchema>;
export type CategoryResult = z.infer<typeof CategoryResultSchema>;
export type FortuneResponse = z.infer<typeof FortuneResponseSchema>;
