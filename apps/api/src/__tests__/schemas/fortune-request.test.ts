import { describe, it, expect } from 'vitest';
import { ZodError } from 'zod';
import {
  FortuneRequestSchema,
  type FortuneRequest,
} from '../../schemas/fortune-request';

// 全次元を0-100の整数で埋めた有効なリクエスト
const VALID_DIMENSIONS = [10, 20, 30, 40, 50, 60, 70] as const;

describe('FortuneRequestSchema', () => {
  // ─── 正常系 ────────────────────────────────────────────────────────────

  it('7つの有効な整数次元をパースしてFortuneRequestオブジェクトを返す', () => {
    // behavior: 7次元パラメータ全て0-100の整数で送信 → パース成功、FortuneRequest型オブジェクト返却
    const result = FortuneRequestSchema.parse({
      dimensions: [...VALID_DIMENSIONS],
    });

    expect(result).toEqual({ dimensions: [10, 20, 30, 40, 50, 60, 70] });
    // 型互換性の実行時確認: FortuneRequest 型に代入できること
    const typed: FortuneRequest = result;
    expect(typed.dimensions).toHaveLength(7);
  });

  it('境界値0と100を含む7要素配列をパースできる', () => {
    // behavior: [追加] 境界値（0と100）が有効
    const result = FortuneRequestSchema.parse({
      dimensions: [0, 100, 0, 100, 0, 100, 0],
    });
    expect(result.dimensions).toEqual([0, 100, 0, 100, 0, 100, 0]);
  });

  // ─── 配列長バリデーション ────────────────────────────────────────────────

  it('6要素配列でZodError(too_small)をthrowする', () => {
    // behavior: dimensions配列が6要素（1つ不足）→ ZodError（too_small）
    const input = { dimensions: [10, 20, 30, 40, 50, 60] };

    expect(() => FortuneRequestSchema.parse(input)).toThrow(ZodError);

    const result = FortuneRequestSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const dimError = result.error.issues.find(
        (issue) => issue.path[0] === 'dimensions',
      );
      expect(dimError).toBeDefined();
      expect(dimError?.code).toBe('too_small');
    }
  });

  it('8要素配列でZodError(too_big)をthrowする', () => {
    // behavior: [追加] 8要素の超過ケース
    const input = { dimensions: [10, 20, 30, 40, 50, 60, 70, 80] };

    const result = FortuneRequestSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const dimError = result.error.issues.find(
        (issue) => issue.path[0] === 'dimensions',
      );
      expect(dimError).toBeDefined();
      expect(dimError?.code).toBe('too_big');
    }
  });

  // ─── 最小値バリデーション ────────────────────────────────────────────────

  it('要素に-1を含む場合にZodError（最小値0未満）をthrowする', () => {
    // behavior: dimensions要素に-1を含む → ZodError（値が最小値0未満）
    const input = { dimensions: [-1, 20, 30, 40, 50, 60, 70] };

    expect(() => FortuneRequestSchema.parse(input)).toThrow(ZodError);

    const result = FortuneRequestSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const rangeError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path[0] === 'dimensions' &&
          issue.path[1] === 0,
      );
      expect(rangeError).toBeDefined();
      expect(rangeError?.code).toBe('too_small');
    }
  });

  // ─── 最大値バリデーション ────────────────────────────────────────────────

  it('要素に101を含む場合にZodError（最大値100超過）をthrowする', () => {
    // behavior: dimensions要素に101を含む → ZodError（値が最大値100超過）
    const input = { dimensions: [10, 20, 30, 40, 50, 60, 101] };

    expect(() => FortuneRequestSchema.parse(input)).toThrow(ZodError);

    const result = FortuneRequestSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const rangeError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path[0] === 'dimensions' &&
          issue.path[1] === 6,
      );
      expect(rangeError).toBeDefined();
      expect(rangeError?.code).toBe('too_big');
    }
  });

  // ─── 整数型バリデーション ────────────────────────────────────────────────

  it('要素に小数50.5を含む場合にZodError（整数型でない）をthrowする', () => {
    // behavior: dimensions要素に小数50.5を含む → ZodError（整数型でない）
    const input = { dimensions: [10, 20, 30, 40, 50.5, 60, 70] };

    expect(() => FortuneRequestSchema.parse(input)).toThrow(ZodError);

    const result = FortuneRequestSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const intError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path[0] === 'dimensions' &&
          issue.path[1] === 4,
      );
      expect(intError).toBeDefined();
      expect(intError?.code).toBe('invalid_type');
    }
  });

  // ─── 必須フィールドバリデーション ──────────────────────────────────────

  it('dimensionsフィールドがundefinedの場合にZodError（必須フィールド欠損）をthrowする', () => {
    // behavior: dimensionsフィールドがundefined → ZodError（必須フィールド欠損）
    const input = {};

    expect(() => FortuneRequestSchema.parse(input)).toThrow(ZodError);

    const result = FortuneRequestSchema.safeParse(input);
    expect(result.success).toBe(false);
    if (!result.success) {
      const requiredError = result.error.issues.find(
        (issue) => issue.path[0] === 'dimensions',
      );
      expect(requiredError).toBeDefined();
      expect(requiredError?.code).toBe('invalid_type');
    }
  });

  it('dimensionsがnullの場合もZodErrorをthrowする（エッジケース）', () => {
    // behavior: [追加] null値はundefinedと同様に弾く
    const input = { dimensions: null };

    const result = FortuneRequestSchema.safeParse(input);
    expect(result.success).toBe(false);
  });

  // ─── TypeScript 型安全性の確認 ──────────────────────────────────────────

  it('string[]はnumber[]に代入不可のため実行時にZodErrorを返す', () => {
    // behavior: FortuneRequest型にstring[]を代入するコードパターン → コンパイル時型エラー検出
    // 実行時テスト: string[]はnumber[]でないため invalid_type エラーが発生する
    const stringArrayInput = { dimensions: ['a', 'b', 'c', 'd', 'e', 'f', 'g'] };
    const result = FortuneRequestSchema.safeParse(stringArrayInput);
    expect(result.success).toBe(false);
    if (!result.success) {
      // string[]の各要素はnumber型でないため invalid_type エラーが発生する
      const typeError = result.error.issues.find(
        (issue) =>
          Array.isArray(issue.path) &&
          issue.path[0] === 'dimensions',
      );
      expect(typeError).toBeDefined();
    }
  });

  it('パース後の型がFortuneRequest型と構造的に一致する', () => {
    // behavior: [追加] 型推論の正確性確認
    const parsed = FortuneRequestSchema.parse({
      dimensions: [1, 2, 3, 4, 5, 6, 7],
    });

    // dimensions は number[] でなければならない
    expect(Array.isArray(parsed.dimensions)).toBe(true);
    expect(parsed.dimensions).toHaveLength(7);
    parsed.dimensions.forEach((v) => {
      expect(typeof v).toBe('number');
      expect(Number.isInteger(v)).toBe(true);
    });
  });
});
