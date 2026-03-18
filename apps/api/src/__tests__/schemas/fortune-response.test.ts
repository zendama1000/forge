import { describe, it, expect } from 'vitest';
import { ZodError } from 'zod';
import {
  FortuneResponseSchema,
  type FortuneResponse,
} from '../../schemas/fortune-response';

// ─── テストフィクスチャ ────────────────────────────────────────────────────

/** 有効な次元オブジェクト（rawScore のみ必須） */
const makeDimension = (rawScore = 50) => ({ rawScore });

/** 有効な7次元配列 */
const makeSevenDimensions = (scores = [60, 70, 80, 50, 40, 90, 55]) =>
  scores.map((s) => makeDimension(s));

/** 有効なカテゴリオブジェクト */
const makeCategory = (
  totalScore = 75,
  templateText = '運勢は良好です。前向きな気持ちで取り組みましょう。',
) => ({
  totalScore,
  templateText,
  dimensions: makeSevenDimensions(),
});

/** 4カテゴリ×7次元の完全な有効オブジェクト */
const VALID_4CATEGORIES_7DIMENSIONS: FortuneResponse = {
  categories: [
    {
      name: '恋愛運',
      totalScore: 80,
      templateText: '恋愛運は絶好調！新しい出会いを求めてみて。',
      dimensions: makeSevenDimensions([80, 75, 85, 70, 90, 65, 78]),
    },
    {
      name: '仕事運',
      totalScore: 60,
      templateText: '仕事運は普通。着実にコツコツ取り組もう。',
      dimensions: makeSevenDimensions([55, 60, 65, 58, 62, 57, 63]),
    },
    {
      name: '金運',
      totalScore: 45,
      templateText: '金運はやや低め。無駄遣いに注意して。',
      dimensions: makeSevenDimensions([40, 45, 50, 42, 48, 44, 46]),
    },
    {
      name: '健康運',
      totalScore: 90,
      templateText: '健康運は最高！体を動かす絶好の機会。',
      dimensions: makeSevenDimensions([90, 88, 92, 85, 95, 87, 91]),
    },
  ],
};

// ─── テストスイート ──────────────────────────────────────────────────────────

describe('FortuneResponseSchema', () => {
  // ─── 正常系 ──────────────────────────────────────────────────────────────

  it('4カテゴリ×7次元の完全なオブジェクトをパースしてFortuneResponse型を返す', () => {
    // behavior: 4カテゴリ×7次元の完全なFortuneResponseオブジェクト → パース成功
    const result = FortuneResponseSchema.parse(VALID_4CATEGORIES_7DIMENSIONS);

    expect(result.categories).toHaveLength(4);
    result.categories.forEach((cat) => {
      expect(cat.dimensions).toHaveLength(7);
    });

    // 型互換性確認
    const typed: FortuneResponse = result;
    expect(typed.categories[0].totalScore).toBe(80);
    expect(typed.categories[0].templateText).toBe(
      '恋愛運は絶好調！新しい出会いを求めてみて。',
    );
  });

  it('safeParse でも4カテゴリ×7次元を success: true で返す', () => {
    // behavior: [追加] safeParse の正常系確認
    const result = FortuneResponseSchema.safeParse(VALID_4CATEGORIES_7DIMENSIONS);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.categories).toHaveLength(4);
    }
  });

  it('1カテゴリ最小構成でもパースに成功する', () => {
    // behavior: [追加] categories最小要素数（1）で通過
    const input = { categories: [makeCategory(50, '普通の運勢です。')] };
    const result = FortuneResponseSchema.parse(input);
    expect(result.categories).toHaveLength(1);
    expect(result.categories[0].totalScore).toBe(50);
    expect(result.categories[0].templateText).toBe('普通の運勢です。');
  });

  it('totalScore が境界値0と100でパースに成功する', () => {
    // behavior: [追加] totalScore 境界値（0, 100）が有効
    const input0 = { categories: [makeCategory(0, '運勢低め')] };
    const input100 = { categories: [makeCategory(100, '最高の運勢！')] };
    expect(FortuneResponseSchema.parse(input0).categories[0].totalScore).toBe(0);
    expect(FortuneResponseSchema.parse(input100).categories[0].totalScore).toBe(100);
  });

  // ─── categories 配列バリデーション ───────────────────────────────────────

  it('categories が空配列のとき ZodError をthrowする', () => {
    // behavior: categories配列が空[] → ZodError（最低1カテゴリ必要）
    const input = { categories: [] };

    expect(() => FortuneResponseSchema.parse(input)).toThrow(ZodError);

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const catError = result.error.issues.find(
        (issue) => issue.path[0] === 'categories',
      );
      expect(catError).toBeDefined();
      expect(catError?.code).toBe('too_small');
    }
  });

  // ─── rawScore 必須フィールドバリデーション ─────────────────────────────────

  it('dimension要素に rawScore フィールドがない場合 ZodError をthrowする', () => {
    // behavior: dimension要素にrawScoreフィールド欠損 → ZodError（必須フィールド欠損）
    const dimWithoutRawScore = { name: 'テスト次元' }; // rawScore なし
    const input = {
      categories: [
        {
          totalScore: 70,
          templateText: '普通の運勢',
          dimensions: [
            dimWithoutRawScore,
            makeDimension(50),
            makeDimension(60),
            makeDimension(70),
            makeDimension(80),
            makeDimension(90),
            makeDimension(40),
          ],
        },
      ],
    };

    expect(() => FortuneResponseSchema.parse(input)).toThrow(ZodError);

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      // rawScore が必須フィールド欠損エラー
      const rawScoreError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path.includes('rawScore'),
      );
      expect(rawScoreError).toBeDefined();
      expect(rawScoreError?.code).toBe('invalid_type');
    }
  });

  // ─── totalScore 範囲バリデーション ───────────────────────────────────────

  it('totalScore が 150 のとき ZodError（最大値100超過）をthrowする', () => {
    // behavior: totalScoreが数値範囲外（150）→ ZodError（最大値100超過）
    const input = {
      categories: [makeCategory(150, 'スコア超過テスト')],
    };

    expect(() => FortuneResponseSchema.parse(input)).toThrow(ZodError);

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const scoreError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path.includes('totalScore'),
      );
      expect(scoreError).toBeDefined();
      expect(scoreError?.code).toBe('too_big');
    }
  });

  it('totalScore が -1 のとき ZodError（最小値0未満）をthrowする', () => {
    // behavior: [追加] totalScore が負値でもエラー
    const input = { categories: [makeCategory(-1, 'マイナステスト')] };

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const scoreError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) && issue.path.includes('totalScore'),
      );
      expect(scoreError).toBeDefined();
      expect(scoreError?.code).toBe('too_small');
    }
  });

  // ─── templateText バリデーション ─────────────────────────────────────────

  it('templateText が空文字列のとき ZodError をthrowする', () => {
    // behavior: templateTextが空文字列 → ZodError（最低1文字必要）
    const input = { categories: [makeCategory(70, '')] };

    expect(() => FortuneResponseSchema.parse(input)).toThrow(ZodError);

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const textError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path.includes('templateText'),
      );
      expect(textError).toBeDefined();
      expect(textError?.code).toBe('too_small');
    }
  });

  it('templateText が1文字（最小境界値）でパースに成功する', () => {
    // behavior: [追加] templateText 最小1文字で通過
    const input = { categories: [makeCategory(70, 'A')] };
    const result = FortuneResponseSchema.parse(input);
    expect(result.categories[0].templateText).toBe('A');
  });

  // ─── dimensions 配列長バリデーション ──────────────────────────────────────

  it('dimensions が6要素のとき ZodError（too_small）をthrowする', () => {
    // behavior: [追加] 次元数不足（7未満）はエラー
    const input = {
      categories: [
        {
          totalScore: 70,
          templateText: '普通',
          dimensions: makeSevenDimensions([50, 60, 70, 80, 90, 40]), // 6要素
        },
      ],
    };

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const dimError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path.includes('dimensions'),
      );
      expect(dimError).toBeDefined();
    }
  });

  it('dimensions が8要素のとき ZodError（too_big）をthrowする', () => {
    // behavior: [追加] 次元数超過（7超）はエラー
    const input = {
      categories: [
        {
          totalScore: 70,
          templateText: '普通',
          dimensions: makeSevenDimensions([50, 60, 70, 80, 90, 40, 55, 65]), // 8要素
        },
      ],
    };

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
  });

  // ─── rawScore 範囲バリデーション ─────────────────────────────────────────

  it('rawScore が 101 のとき ZodError（最大値100超過）をthrowする', () => {
    // behavior: [追加] rawScore が範囲外でエラー
    const input = {
      categories: [
        {
          totalScore: 70,
          templateText: '普通',
          dimensions: [
            { rawScore: 101 }, // 範囲外
            ...makeSevenDimensions([50, 60, 70, 80, 90, 40]).slice(0, 6),
          ],
        },
      ],
    };

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const rawScoreError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path.includes('rawScore'),
      );
      expect(rawScoreError).toBeDefined();
      expect(rawScoreError?.code).toBe('too_big');
    }
  });

  it('rawScore が小数（50.5）のとき ZodError（整数型でない）をthrowする', () => {
    // behavior: [追加] rawScore は整数型必須
    const input = {
      categories: [
        {
          totalScore: 70,
          templateText: '普通',
          dimensions: [
            { rawScore: 50.5 }, // 小数
            ...makeSevenDimensions([50, 60, 70, 80, 90, 40]).slice(0, 6),
          ],
        },
      ],
    };

    const result = FortuneResponseSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const rawScoreError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path.includes('rawScore'),
      );
      expect(rawScoreError).toBeDefined();
    }
  });

  // ─── 型安全性・エッジケース ───────────────────────────────────────────────

  it('categories フィールドが undefined のとき ZodError をthrowする', () => {
    // behavior: [追加] 必須フィールド categories が欠損
    const result = FortuneResponseSchema.safeParse({});
    expect(result.success).toBe(false);
    if (!result.success) {
      const catError = result.error.issues.find(
        (issue) => issue.path[0] === 'categories',
      );
      expect(catError).toBeDefined();
      expect(catError?.code).toBe('invalid_type');
    }
  });

  it('パース後の型が FortuneResponse と構造的に一致する', () => {
    // behavior: [追加] 型推論の正確性確認
    const parsed = FortuneResponseSchema.parse(VALID_4CATEGORIES_7DIMENSIONS);

    expect(Array.isArray(parsed.categories)).toBe(true);
    parsed.categories.forEach((cat) => {
      expect(typeof cat.totalScore).toBe('number');
      expect(typeof cat.templateText).toBe('string');
      expect(Array.isArray(cat.dimensions)).toBe(true);
      expect(cat.dimensions).toHaveLength(7);
      cat.dimensions.forEach((dim) => {
        expect(typeof dim.rawScore).toBe('number');
        expect(Number.isInteger(dim.rawScore)).toBe(true);
      });
    });
  });
});
