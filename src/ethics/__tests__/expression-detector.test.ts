/**
 * 禁止表現検出エンジン - ユニットテスト
 * 全7テストケース（Layer 1 required_behaviors）
 */

import { describe, it, expect } from 'vitest';
import { detectViolations } from '../expression-detector';

describe('detectViolations - 禁止表現検出エンジン', () => {
  // ─── 必須テスト振る舞い (7件) ─────────────────────────────────────────────

  // behavior: テキスト '必ず当たる占いです' → 違反検出（law_reference: '景品表示法'、該当パターンを含む結果）
  it("'必ず当たる占いです' → 景品表示法違反を検出する", () => {
    const result = detectViolations('必ず当たる占いです');

    expect(result.violations.length).toBeGreaterThan(0);

    const violation = result.violations.find(
      (v) => v.law_reference === '景品表示法',
    );
    expect(violation).toBeDefined();
    expect(violation!.pattern).toContain('必ず当たる');
    expect(violation!.position).toBeGreaterThanOrEqual(0);
    expect(violation!.context_flag).toBe(false);
  });

  // behavior: テキスト 'あなたの運命が変わります'（断定形）→ 違反検出（law_reference: '消費者契約法'）
  it("'あなたの運命が変わります'（断定形）→ 消費者契約法違反を検出する", () => {
    const result = detectViolations('あなたの運命が変わります');

    expect(result.violations.length).toBeGreaterThan(0);

    const violation = result.violations.find(
      (v) => v.law_reference === '消費者契約法',
    );
    expect(violation).toBeDefined();
    expect(violation!.pattern).toBe('運命が変わります');
    expect(violation!.context_flag).toBe(false);
  });

  // behavior: テキスト '新しい気づきが得られるかもしれません'（非断定形）→ 違反なし（false positive回避）
  it("'新しい気づきが得られるかもしれません'（非断定形）→ 違反なし", () => {
    const result = detectViolations('新しい気づきが得られるかもしれません');

    expect(result.violations).toHaveLength(0);
  });

  // behavior: テキスト '100%的中' → 違反検出（景品表示法: 優良誤認）
  it("'100%的中' → 景品表示法（優良誤認）違反を検出する", () => {
    const result = detectViolations('100%的中');

    expect(result.violations.length).toBeGreaterThan(0);

    const violation = result.violations[0];
    expect(violation.law_reference).toBe('景品表示法');
    expect(violation.pattern).toBe('100%的中');
    expect(violation.position).toBe(0);
  });

  // behavior: テキスト中に複数の違反表現 → 全違反を配列で返却（各要素にpattern, position, law_referenceを含む）
  it('複数の違反表現を含むテキスト → 全違反を配列で返却し各要素に必須フィールドを含む', () => {
    const text = '必ず当たる占いです。あなたの運命が変わります。';
    const result = detectViolations(text);

    expect(result.violations.length).toBeGreaterThanOrEqual(2);

    // 各違反が必須フィールドを持つことを検証
    for (const v of result.violations) {
      expect(v).toHaveProperty('pattern');
      expect(typeof v.pattern).toBe('string');
      expect(v.pattern.length).toBeGreaterThan(0);

      expect(v).toHaveProperty('position');
      expect(typeof v.position).toBe('number');
      expect(v.position).toBeGreaterThanOrEqual(0);

      expect(v).toHaveProperty('law_reference');
      expect(typeof v.law_reference).toBe('string');

      expect(v).toHaveProperty('context_flag');
      expect(typeof v.context_flag).toBe('boolean');
    }

    // 景品表示法と消費者契約法の両方の違反が含まれる
    const laws = result.violations.map((v) => v.law_reference);
    expect(laws).toContain('景品表示法');
    expect(laws).toContain('消費者契約法');

    // 景品表示法違反（必ず当たる）の position は消費者契約法違反より前
    const keihyoViolation = result.violations.find(
      (v) => v.law_reference === '景品表示法' && v.pattern.includes('必ず当たる'),
    );
    const shoshaViolation = result.violations.find(
      (v) => v.law_reference === '消費者契約法',
    );
    expect(keihyoViolation).toBeDefined();
    expect(shoshaViolation).toBeDefined();
    expect(keihyoViolation!.position).toBeLessThan(shoshaViolation!.position);
  });

  // behavior: 空文字列入力 → violations空配列を返却（エラーではない）
  it('空文字列入力 → violations空配列を返却（エラーにならない）', () => {
    const result = detectViolations('');

    expect(result).toBeDefined();
    expect(result.violations).toBeDefined();
    expect(result.violations).toHaveLength(0);
    expect(Array.isArray(result.violations)).toBe(true);
  });

  // behavior: 禁止表現が別の文脈で使われた場合（例: '占いは必ず当たるわけではありません'）→ 検出はするがcontext_flagをtrueに設定
  it("'占いは必ず当たるわけではありません' → 検出するが context_flag を true に設定", () => {
    const result = detectViolations('占いは必ず当たるわけではありません');

    expect(result.violations.length).toBeGreaterThan(0);

    const violation = result.violations.find((v) =>
      v.pattern.includes('必ず当たる'),
    );
    expect(violation).toBeDefined();
    expect(violation!.context_flag).toBe(true);
    expect(violation!.law_reference).toBe('景品表示法');
  });

  // ─── 追加テスト: エッジケース ──────────────────────────────────────────────

  // behavior: [追加] 違反なしの通常テキスト → violations空配列
  it('違反表現を含まない通常テキスト → violations空配列', () => {
    const result = detectViolations(
      'あなたの星座から今週の運勢をお伝えします。良いご縁があるといいですね。',
    );
    expect(result.violations).toHaveLength(0);
  });

  // behavior: [追加] 位置情報の正確性 - '100%的中占い' → position が 0
  it("'100%的中占い' → 違反の position が 0（先頭から始まる）", () => {
    const result = detectViolations('100%的中占い');
    const violation = result.violations[0];
    expect(violation).toBeDefined();
    expect(violation.position).toBe(0);
  });
});
