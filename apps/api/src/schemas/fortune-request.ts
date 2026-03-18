import { z } from 'zod';

/**
 * 占いリクエストの7次元パラメータスキーマ
 *
 * 各次元は 0〜100 の整数値で表される。
 * - 配列の長さ: ちょうど7要素
 * - 各要素: 0以上100以下の整数
 */
const DimensionValue = z
  .number()
  .int('各次元パラメータは整数でなければなりません')
  .min(0, '各次元パラメータは0以上でなければなりません')
  .max(100, '各次元パラメータは100以下でなければなりません');

export const FortuneRequestSchema = z.object({
  dimensions: z
    .array(DimensionValue)
    .length(7, '次元パラメータはちょうど7要素必要です'),
});

/**
 * FortuneRequestSchema から推論される TypeScript 型
 */
export type FortuneRequest = z.infer<typeof FortuneRequestSchema>;
