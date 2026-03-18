/**
 * TemplateSelector - スコアバケットに基づくテンプレート選択ロジック ユニットテスト
 */

import { describe, it, expect } from 'vitest';
import {
  classifyScoreBucket,
  selectTemplate,
  SCORE_BUCKET_HIGH_THRESHOLD,
  SCORE_BUCKET_MEDIUM_THRESHOLD,
  CATEGORY_TEMPLATES,
} from '../../logic/template-selector';

describe('TemplateSelector - スコアバケットに基づくテンプレート選択', () => {
  // ─── required_behaviors カバレッジ ───────────────────────────────────────

  // behavior: totalScore=85 → 高スコアバケットのテンプレートテキスト選択
  it('totalScore=85の場合、高スコアバケットのテンプレートテキストが選択される', () => {
    // behavior: totalScore=85 → 高スコアバケットのテンプレートテキスト選択
    const result = selectTemplate('love', 85);
    expect(result).toBe(CATEGORY_TEMPLATES['love'].high);
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });

  // behavior: totalScore=50 → 中スコアバケットのテンプレートテキスト選択
  it('totalScore=50の場合、中スコアバケットのテンプレートテキストが選択される', () => {
    // behavior: totalScore=50 → 中スコアバケットのテンプレートテキスト選択
    const result = selectTemplate('work', 50);
    expect(result).toBe(CATEGORY_TEMPLATES['work'].medium);
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });

  // behavior: totalScore=15 → 低スコアバケットのテンプレートテキスト選択
  it('totalScore=15の場合、低スコアバケットのテンプレートテキストが選択される', () => {
    // behavior: totalScore=15 → 低スコアバケットのテンプレートテキスト選択
    const result = selectTemplate('health', 15);
    expect(result).toBe(CATEGORY_TEMPLATES['health'].low);
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });

  // behavior: totalScore=バケット閾値ちょうど（境界値）→ 上位バケット選択
  it('totalScore=高スコア閾値ちょうどの場合、高スコアバケット（上位）が選択される（境界値）', () => {
    // behavior: totalScore=バケット閾値ちょうど（境界値）→ 上位バケット選択
    const result = selectTemplate('money', SCORE_BUCKET_HIGH_THRESHOLD);
    expect(result).toBe(CATEGORY_TEMPLATES['money'].high);
    // 閾値ちょうどは上位バケット（high）であることを明示
    expect(classifyScoreBucket(SCORE_BUCKET_HIGH_THRESHOLD)).toBe('high');
  });

  it('totalScore=中スコア閾値ちょうどの場合、中スコアバケット（上位）が選択される（境界値）', () => {
    // behavior: totalScore=バケット閾値ちょうど（境界値）→ 上位バケット選択
    const result = selectTemplate('love', SCORE_BUCKET_MEDIUM_THRESHOLD);
    expect(result).toBe(CATEGORY_TEMPLATES['love'].medium);
    // 閾値ちょうどは上位バケット（medium > low）であることを明示
    expect(classifyScoreBucket(SCORE_BUCKET_MEDIUM_THRESHOLD)).toBe('medium');
  });

  // behavior: totalScore=0 → 低スコアバケット選択、エラーにならない
  it('totalScore=0の場合、低スコアバケットが選択されエラーにならない', () => {
    // behavior: totalScore=0 → 低スコアバケット選択、エラーにならない
    expect(() => selectTemplate('work', 0)).not.toThrow();
    const result = selectTemplate('work', 0);
    expect(result).toBe(CATEGORY_TEMPLATES['work'].low);
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });

  // behavior: totalScore=NaN → エラースロー（不正な入力）
  it('totalScore=NaNの場合、エラーをスローする', () => {
    // behavior: totalScore=NaN → エラースロー（不正な入力）
    expect(() => selectTemplate('love', NaN)).toThrow();
    expect(() => selectTemplate('love', NaN)).toThrow(/NaN/);
  });

  // ─── classifyScoreBucket の単独テスト ────────────────────────────────────

  describe('classifyScoreBucket - スコアからバケットへの分類', () => {
    it('85は高スコアバケット（high）に分類される', () => {
      expect(classifyScoreBucket(85)).toBe('high');
    });

    it('100は高スコアバケット（high）に分類される', () => {
      expect(classifyScoreBucket(100)).toBe('high');
    });

    it('50は中スコアバケット（medium）に分類される', () => {
      expect(classifyScoreBucket(50)).toBe('medium');
    });

    it('15は低スコアバケット（low）に分類される', () => {
      expect(classifyScoreBucket(15)).toBe('low');
    });

    it('0は低スコアバケット（low）に分類される', () => {
      expect(classifyScoreBucket(0)).toBe('low');
    });

    it('高スコア閾値ちょうどは high に分類される（境界値）', () => {
      expect(classifyScoreBucket(SCORE_BUCKET_HIGH_THRESHOLD)).toBe('high');
    });

    it('高スコア閾値-1は medium に分類される（境界値直下）', () => {
      expect(classifyScoreBucket(SCORE_BUCKET_HIGH_THRESHOLD - 1)).toBe('medium');
    });

    it('中スコア閾値ちょうどは medium に分類される（境界値）', () => {
      expect(classifyScoreBucket(SCORE_BUCKET_MEDIUM_THRESHOLD)).toBe('medium');
    });

    it('中スコア閾値-1は low に分類される（境界値直下）', () => {
      expect(classifyScoreBucket(SCORE_BUCKET_MEDIUM_THRESHOLD - 1)).toBe('low');
    });

    it('NaNはエラーをスローする', () => {
      expect(() => classifyScoreBucket(NaN)).toThrow();
      expect(() => classifyScoreBucket(NaN)).toThrow(/NaN/);
    });
  });

  // ─── カテゴリ別テンプレートの検証 ─────────────────────────────────────────

  describe('各カテゴリでのテンプレートテキスト取得', () => {
    const categories = ['love', 'work', 'health', 'money'] as const;

    it('全カテゴリ（love/work/health/money）でhighテンプレートが返される', () => {
      // behavior: [追加] 4カテゴリすべてでhighテンプレートが取得できる
      categories.forEach((category) => {
        const result = selectTemplate(category, 85);
        expect(result).toBe(CATEGORY_TEMPLATES[category].high);
        expect(result.length).toBeGreaterThan(0);
      });
    });

    it('全カテゴリ（love/work/health/money）でmediumテンプレートが返される', () => {
      // behavior: [追加] 4カテゴリすべてでmediumテンプレートが取得できる
      categories.forEach((category) => {
        const result = selectTemplate(category, 50);
        expect(result).toBe(CATEGORY_TEMPLATES[category].medium);
        expect(result.length).toBeGreaterThan(0);
      });
    });

    it('全カテゴリ（love/work/health/money）でlowテンプレートが返される', () => {
      // behavior: [追加] 4カテゴリすべてでlowテンプレートが取得できる
      categories.forEach((category) => {
        const result = selectTemplate(category, 15);
        expect(result).toBe(CATEGORY_TEMPLATES[category].low);
        expect(result.length).toBeGreaterThan(0);
      });
    });

    it('同じカテゴリで異なるバケットのテンプレートテキストは異なる', () => {
      // behavior: [追加] バケット毎にユニークなテキスト
      categories.forEach((category) => {
        const highText = selectTemplate(category, 85);
        const mediumText = selectTemplate(category, 50);
        const lowText = selectTemplate(category, 15);
        expect(highText).not.toBe(mediumText);
        expect(mediumText).not.toBe(lowText);
        expect(highText).not.toBe(lowText);
      });
    });
  });

  // ─── エッジケース ──────────────────────────────────────────────────────────

  it('totalScore=100の場合、高スコアバケットが選択される（最大値エッジ）', () => {
    // behavior: [追加] エッジ最大値（100）でも正常動作
    const result = selectTemplate('love', 100);
    expect(result).toBe(CATEGORY_TEMPLATES['love'].high);
  });

  it('存在しないカテゴリを指定した場合、エラーをスローする', () => {
    // behavior: [追加] 未知のカテゴリはエラー
    expect(() => selectTemplate('unknown_category', 50)).toThrow();
    expect(() => selectTemplate('unknown_category', 50)).toThrow(/カテゴリ/);
  });

  it('高スコア閾値の直前値（69）はmediumに分類される', () => {
    // behavior: [追加] 閾値直前の詳細境界値テスト
    const result = selectTemplate('work', SCORE_BUCKET_HIGH_THRESHOLD - 1);
    expect(result).toBe(CATEGORY_TEMPLATES['work'].medium);
  });

  it('中スコア閾値の直前値はlowに分類される', () => {
    // behavior: [追加] 閾値直前の詳細境界値テスト
    const result = selectTemplate('health', SCORE_BUCKET_MEDIUM_THRESHOLD - 1);
    expect(result).toBe(CATEGORY_TEMPLATES['health'].low);
  });
});
