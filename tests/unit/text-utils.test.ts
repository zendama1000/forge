import { describe, it, expect } from 'vitest';
import { countChars, estimateTokens, extractOverlap } from '../../src/utils/text-utils';

describe('text-utils', () => {
  // ===== countChars =====

  // behavior: 日本語テキスト20,000文字の文字数カウント → 正確に20000を返却
  it('日本語テキスト20,000文字の文字数カウント → 正確に20000を返却', () => {
    const text = 'あ'.repeat(20000);
    expect(countChars(text)).toBe(20000);
  });

  // behavior: 混合テキスト（日本語+英語+数字）の文字数カウント → 正確な文字数を返却
  it('混合テキスト（日本語+英語+数字）の文字数カウント → 正確な文字数を返却', () => {
    const text = 'Hello世界123'; // H,e,l,l,o,世,界,1,2,3 = 10文字
    expect(countChars(text)).toBe(10);
  });

  // behavior: [追加] ひらがな・カタカナ・漢字の混在テキストも正確にカウント
  it('ひらがな・カタカナ・漢字混在テキストの文字数カウント', () => {
    const text = 'あいうえおアイウエオ漢字漢字'; // 14文字
    expect(countChars(text)).toBe(14);
  });

  // ===== estimateTokens =====

  // behavior: 日本語テキスト1000文字のトークン推定 → 1500-3000の範囲内（日本語1文字≈1.5-3トークン）
  it('日本語テキスト1000文字のトークン推定 → 1500-3000の範囲内（日本語1文字≈1.5-3トークン）', () => {
    const text = 'あ'.repeat(1000);
    const tokens = estimateTokens(text);
    expect(tokens).toBeGreaterThanOrEqual(1500);
    expect(tokens).toBeLessThanOrEqual(3000);
  });

  // behavior: 空文字列のトークン推定 → 0を返却
  it('空文字列のトークン推定 → 0を返却', () => {
    expect(estimateTokens('')).toBe(0);
  });

  // behavior: [追加] ASCII文字のみのトークン推定 → 文字数の約0.25倍
  it('ASCII文字のみのトークン推定 → 文字数の約0.25倍（4文字≈1トークン）', () => {
    const text = 'a'.repeat(400); // 400文字 → 100トークン
    const tokens = estimateTokens(text);
    expect(tokens).toBe(100);
  });

  // ===== extractOverlap =====

  // behavior: テキスト末尾500文字のオーバーラップ抽出 → 正確に末尾500文字を返却
  it('テキスト末尾500文字のオーバーラップ抽出 → 正確に末尾500文字を返却', () => {
    const prefix = 'あ'.repeat(500);
    const suffix = 'い'.repeat(500);
    const text = prefix + suffix;
    const result = extractOverlap(text, 500);
    expect(result).toBe(suffix);
    expect(countChars(result)).toBe(500);
  });

  // behavior: 500文字未満のテキストからオーバーラップ抽出 → テキスト全体を返却
  it('500文字未満のテキストからオーバーラップ抽出 → テキスト全体を返却', () => {
    const text = 'あいうえお'; // 5文字
    const result = extractOverlap(text, 500);
    expect(result).toBe(text);
  });

  // behavior: [追加] ちょうどN文字のテキストからオーバーラップ抽出 → テキスト全体を返却
  it('ちょうどN文字のテキストからN文字のオーバーラップ抽出 → テキスト全体を返却', () => {
    const text = 'あ'.repeat(500);
    const result = extractOverlap(text, 500);
    expect(result).toBe(text);
    expect(countChars(result)).toBe(500);
  });
});
