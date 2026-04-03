import { describe, it, expect } from 'vitest';
import { validateAidaBands, AidaBand } from '../../src/utils/aida-config';

/**
 * 基準となる有効な5帯域設定
 * Attention 0-10% / Interest 10-35% / Desire 35-70% / Conviction 70-90% / Action 90-100%
 */
const VALID_BANDS: AidaBand[] = [
  { name: 'Attention',  start_percent: 0,  end_percent: 10,  primary_theory_limit: 2 },
  { name: 'Interest',   start_percent: 10, end_percent: 35,  primary_theory_limit: 2 },
  { name: 'Desire',     start_percent: 35, end_percent: 70,  primary_theory_limit: 2 },
  { name: 'Conviction', start_percent: 70, end_percent: 90,  primary_theory_limit: 1 },
  { name: 'Action',     start_percent: 90, end_percent: 100, primary_theory_limit: 1 },
];

describe('validateAidaBands', () => {
  // ─────────────────────────────────────────────────────────────────────────
  // behavior 1: 有効な5帯域設定 → バリデーション通過
  // ─────────────────────────────────────────────────────────────────────────
  it('有効な5帯域設定はバリデーションを通過する', () => {
    // behavior: 有効な5帯域設定（Attention 0-10%, Interest 10-35%, Desire 35-70%, Conviction 70-90%, Action 90-100%）→ バリデーション通過
    const result = validateAidaBands(VALID_BANDS);

    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior 2: 帯域が欠落 → バリデーションエラー + 欠落band名を含むメッセージ
  // ─────────────────────────────────────────────────────────────────────────
  it('Actionが欠落した4帯域設定はエラーを返し欠落band名を含む', () => {
    // behavior: 帯域が4つ以下（bandが欠落）→ バリデーションエラー + 欠落band名を含むメッセージ
    const bandsWithoutAction = VALID_BANDS.filter((b) => b.name !== 'Action');

    const result = validateAidaBands(bandsWithoutAction);

    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
    const combinedErrors = result.errors.join('\n');
    expect(combinedErrors).toContain('Action');
  });

  it('複数の帯域（DesireとAction）が欠落した場合は両方の欠落band名を含む', () => {
    // behavior: [追加] 複数帯域欠落時のエラーメッセージに欠落band名が全て含まれる
    const bandsSubset = VALID_BANDS.filter(
      (b) => b.name !== 'Desire' && b.name !== 'Action'
    );

    const result = validateAidaBands(bandsSubset);

    expect(result.valid).toBe(false);
    const combinedErrors = result.errors.join('\n');
    expect(combinedErrors).toContain('Desire');
    expect(combinedErrors).toContain('Action');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior 3: 帯域の割合合計が100%を超過 → バリデーションエラー + 超過分を含むメッセージ
  // ─────────────────────────────────────────────────────────────────────────
  it('帯域の割合合計が100%を超過した場合は超過分を含むエラーを返す', () => {
    // behavior: 帯域の割合合計が100%を超過 → バリデーションエラー + 超過分を含むメッセージ
    // 合計: 15+25+35+20+15 = 110%（超過: 10%）
    const oversizedBands: AidaBand[] = [
      { name: 'Attention',  start_percent: 0,  end_percent: 15,  primary_theory_limit: 2 },
      { name: 'Interest',   start_percent: 15, end_percent: 40,  primary_theory_limit: 2 },
      { name: 'Desire',     start_percent: 40, end_percent: 75,  primary_theory_limit: 2 },
      { name: 'Conviction', start_percent: 75, end_percent: 95,  primary_theory_limit: 1 },
      { name: 'Action',     start_percent: 95, end_percent: 110, primary_theory_limit: 1 },
    ];

    const result = validateAidaBands(oversizedBands);

    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
    const combinedErrors = result.errors.join('\n');
    // エラーメッセージに超過量（10%）の情報が含まれること
    expect(combinedErrors).toMatch(/10/);
    // "exceed" または "超" のような語を含むこと
    expect(combinedErrors.toLowerCase()).toMatch(/exceed/);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior 4: 帯域間にギャップ → バリデーションエラー
  // ─────────────────────────────────────────────────────────────────────────
  it('帯域間にギャップがある場合はバリデーションエラーを返す', () => {
    // behavior: 帯域間にギャップ（例: Attention 0-10%, Interest 15-35%で10-15%が未定義）→ バリデーションエラー
    const bandsWithGap: AidaBand[] = [
      { name: 'Attention',  start_percent: 0,  end_percent: 10,  primary_theory_limit: 2 },
      { name: 'Interest',   start_percent: 15, end_percent: 35,  primary_theory_limit: 2 }, // ギャップ: 10-15%
      { name: 'Desire',     start_percent: 35, end_percent: 70,  primary_theory_limit: 2 },
      { name: 'Conviction', start_percent: 70, end_percent: 90,  primary_theory_limit: 1 },
      { name: 'Action',     start_percent: 90, end_percent: 100, primary_theory_limit: 1 },
    ];

    const result = validateAidaBands(bandsWithGap);

    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
    const combinedErrors = result.errors.join('\n').toLowerCase();
    expect(combinedErrors).toContain('gap');
  });

  it('複数箇所にギャップがある場合はそれぞれのギャップエラーを返す', () => {
    // behavior: [追加] 複数ギャップの検出
    const bandsWithMultipleGaps: AidaBand[] = [
      { name: 'Attention',  start_percent: 0,  end_percent: 10,  primary_theory_limit: 2 },
      { name: 'Interest',   start_percent: 15, end_percent: 35,  primary_theory_limit: 2 }, // ギャップ: 10-15%
      { name: 'Desire',     start_percent: 40, end_percent: 70,  primary_theory_limit: 2 }, // ギャップ: 35-40%
      { name: 'Conviction', start_percent: 70, end_percent: 90,  primary_theory_limit: 1 },
      { name: 'Action',     start_percent: 90, end_percent: 100, primary_theory_limit: 1 },
    ];

    const result = validateAidaBands(bandsWithMultipleGaps);

    expect(result.valid).toBe(false);
    const gapErrors = result.errors.filter((e) => e.toLowerCase().includes('gap'));
    expect(gapErrors.length).toBeGreaterThanOrEqual(2);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior 5: 帯域間にオーバーラップ → バリデーションエラー
  // ─────────────────────────────────────────────────────────────────────────
  it('帯域間にオーバーラップがある場合はバリデーションエラーを返す', () => {
    // behavior: 帯域間にオーバーラップ（例: Attention 0-12%, Interest 10-35%）→ バリデーションエラー
    const bandsWithOverlap: AidaBand[] = [
      { name: 'Attention',  start_percent: 0,  end_percent: 12,  primary_theory_limit: 2 }, // オーバーラップ: 10-12%
      { name: 'Interest',   start_percent: 10, end_percent: 35,  primary_theory_limit: 2 },
      { name: 'Desire',     start_percent: 35, end_percent: 70,  primary_theory_limit: 2 },
      { name: 'Conviction', start_percent: 70, end_percent: 90,  primary_theory_limit: 1 },
      { name: 'Action',     start_percent: 90, end_percent: 100, primary_theory_limit: 1 },
    ];

    const result = validateAidaBands(bandsWithOverlap);

    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
    const combinedErrors = result.errors.join('\n').toLowerCase();
    expect(combinedErrors).toContain('overlap');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior 6: primary_theory_limit が 1-2 の範囲外 → バリデーションエラー
  // ─────────────────────────────────────────────────────────────────────────
  it('primary_theory_limitが範囲外（0や3）の帯域があればバリデーションエラーを返す', () => {
    // behavior: 各帯域にprimary_theory_limitが1-2の範囲であることを検証
    const bandsWithInvalidLimit: AidaBand[] = [
      { name: 'Attention',  start_percent: 0,  end_percent: 10,  primary_theory_limit: 0 }, // 無効: 0
      { name: 'Interest',   start_percent: 10, end_percent: 35,  primary_theory_limit: 3 }, // 無効: 3
      { name: 'Desire',     start_percent: 35, end_percent: 70,  primary_theory_limit: 2 }, // 有効
      { name: 'Conviction', start_percent: 70, end_percent: 90,  primary_theory_limit: 1 }, // 有効
      { name: 'Action',     start_percent: 90, end_percent: 100, primary_theory_limit: 2 }, // 有効
    ];

    const result = validateAidaBands(bandsWithInvalidLimit);

    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThanOrEqual(2);
    const combinedErrors = result.errors.join('\n');
    // 無効な帯域名がエラーメッセージに含まれること
    expect(combinedErrors).toContain('Attention');
    expect(combinedErrors).toContain('Interest');
    // 有効な帯域はエラーに含まれないこと（primary_theory_limit のエラーについて）
    const limitErrors = result.errors.filter((e) => e.includes('primary_theory_limit'));
    expect(limitErrors.every((e) => !e.includes('Desire'))).toBe(true);
    expect(limitErrors.every((e) => !e.includes('Conviction'))).toBe(true);
    expect(limitErrors.every((e) => !e.includes('Action'))).toBe(true);
  });

  it('primary_theory_limitが境界値1と2の場合はバリデーションを通過する', () => {
    // behavior: [追加] primary_theory_limit の境界値テスト（1と2は有効）
    const bandsWithBoundaryLimits: AidaBand[] = [
      { name: 'Attention',  start_percent: 0,  end_percent: 10,  primary_theory_limit: 1 },
      { name: 'Interest',   start_percent: 10, end_percent: 35,  primary_theory_limit: 2 },
      { name: 'Desire',     start_percent: 35, end_percent: 70,  primary_theory_limit: 1 },
      { name: 'Conviction', start_percent: 70, end_percent: 90,  primary_theory_limit: 2 },
      { name: 'Action',     start_percent: 90, end_percent: 100, primary_theory_limit: 1 },
    ];

    const result = validateAidaBands(bandsWithBoundaryLimits);

    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // エッジケース
  // ─────────────────────────────────────────────────────────────────────────
  it('空配列を渡した場合は全5帯域が欠落したエラーを返す', () => {
    // behavior: [追加] 空配列エッジケース
    const result = validateAidaBands([]);

    expect(result.valid).toBe(false);
    const combinedErrors = result.errors.join('\n');
    expect(combinedErrors).toContain('Attention');
    expect(combinedErrors).toContain('Interest');
    expect(combinedErrors).toContain('Desire');
    expect(combinedErrors).toContain('Conviction');
    expect(combinedErrors).toContain('Action');
  });

  it('帯域の順序がバラバラでも正しくバリデーションを通過する', () => {
    // behavior: [追加] 順不同の帯域定義でも正しく動作する
    const shuffledBands: AidaBand[] = [
      { name: 'Action',     start_percent: 90, end_percent: 100, primary_theory_limit: 1 },
      { name: 'Desire',     start_percent: 35, end_percent: 70,  primary_theory_limit: 2 },
      { name: 'Attention',  start_percent: 0,  end_percent: 10,  primary_theory_limit: 2 },
      { name: 'Conviction', start_percent: 70, end_percent: 90,  primary_theory_limit: 1 },
      { name: 'Interest',   start_percent: 10, end_percent: 35,  primary_theory_limit: 2 },
    ];

    const result = validateAidaBands(shuffledBands);

    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });
});
