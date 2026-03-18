import { describe, it, expect } from 'vitest';
import { validateCore } from '../core-validator';

/** 全必須フィールドを含む有効なコアデータのベースライン */
const validCore: Record<string, unknown> = {
  brand_name: 'スターライト占術',
  divination_type: 'tarot',
  target_audience: '20-30代女性・癒しを求める方',
  core_values: ['誠実さ', '癒し', '自己成長'],
  differentiators: ['科学的アプローチ', '個別対応'],
  $schema_version: '1.0.0',
};

describe('core-schema validateCore', () => {
  // behavior: 全必須フィールド（brand_name, divination_type, target_audience, core_values[], differentiators[], $schema_version）を含むcore.json → バリデーション通過
  it('全必須フィールドが揃った場合はバリデーション通過', () => {
    const result = validateCore(validCore);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: brand_nameが空文字のcore.json → バリデーションエラー（フィールド名 'brand_name' を含むメッセージ）
  it('brand_nameが空文字の場合はバリデーションエラー（エラーメッセージに brand_name を含む）', () => {
    const data: Record<string, unknown> = { ...validCore, brand_name: '' };
    const result = validateCore(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasBrandNameError = result.errors!.some((e) => e.includes('brand_name'));
    expect(hasBrandNameError).toBe(true);
  });

  // behavior: 必須フィールドdivination_typeが欠落したcore.json → バリデーションエラー（欠落フィールド名を含むメッセージ）
  it('divination_typeが欠落した場合はバリデーションエラー（エラーメッセージに divination_type を含む）', () => {
    const data: Record<string, unknown> = { ...validCore };
    delete data['divination_type'];
    const result = validateCore(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasDivinationTypeError = result.errors!.some((e) => e.includes('divination_type'));
    expect(hasDivinationTypeError).toBe(true);
  });

  // behavior: $schema_versionフィールドが欠落したcore.json → バリデーションエラー（'$schema_version' 必須を示すメッセージ）
  it('$schema_versionが欠落した場合はバリデーションエラー（エラーメッセージに $schema_version を含む）', () => {
    const data: Record<string, unknown> = { ...validCore };
    delete data['$schema_version'];
    const result = validateCore(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasVersionError = result.errors!.some((e) => e.includes('$schema_version'));
    expect(hasVersionError).toBe(true);
  });

  // behavior: $schema_versionが非semver形式（例: 'v1'）のcore.json → バリデーションエラー（semver形式要求メッセージ）
  it('$schema_versionが非semver形式（"v1"）の場合はバリデーションエラー（semver形式要求メッセージ）', () => {
    const data: Record<string, unknown> = { ...validCore, $schema_version: 'v1' };
    const result = validateCore(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasSemverError = result.errors!.some(
      (e) =>
        e.includes('$schema_version') ||
        e.toLowerCase().includes('semver') ||
        e.includes('pattern')
    );
    expect(hasSemverError).toBe(true);
  });

  // behavior: スキーマ未定義の追加フィールドを含むcore.json → バリデーション通過（拡張可能スキーマ）
  it('スキーマ未定義の追加フィールドがあってもバリデーション通過（additionalProperties 許可）', () => {
    const data: Record<string, unknown> = {
      ...validCore,
      custom_tagline: '星に導かれる運命の旅',
      brand_color: '#7B2FBE',
      launch_year: 2024,
    };
    const result = validateCore(data);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: core_valuesが空配列のcore.json → バリデーションエラー（最低1要素必須）
  it('core_valuesが空配列の場合はバリデーションエラー（最低1要素必須）', () => {
    const data: Record<string, unknown> = { ...validCore, core_values: [] };
    const result = validateCore(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasMinItemsError = result.errors!.some(
      (e) =>
        e.includes('core_values') ||
        e.includes('minItems') ||
        e.includes('fewer than 1 items')
    );
    expect(hasMinItemsError).toBe(true);
  });
});
