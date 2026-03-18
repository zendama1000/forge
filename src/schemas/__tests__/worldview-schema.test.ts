import { describe, it, expect } from 'vitest';
import { validateWorldview } from '../worldview-validator';

/** 全必須フィールドを含む有効な世界観データのベースライン */
const validWorldview: Record<string, unknown> = {
  tone: '神秘的で癒しに満ちた、静かな語りかけ',
  aesthetic_direction: 'ethereal',
  keywords: ['神秘', '癒し', '星空', '内なる光'],
  color_palette: ['#7B2FBE', '#E8D5F5', '#1A0533'],
  exemplar_texts: ['星が囁く、あなたの運命の物語', '宇宙のリズムに身を委ねて'],
  $schema_version: '1.0.0',
};

describe('worldview-schema validateWorldview', () => {
  // behavior: 全必須フィールド（tone, aesthetic_direction, keywords[], color_palette[], exemplar_texts[], $schema_version）を含むworldview.json → バリデーション通過
  it('全必須フィールドが揃った場合はバリデーション通過', () => {
    const result = validateWorldview(validWorldview);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: aesthetic_directionが定義済みenum値（ethereal/mystical/healing/elegant/natural）のいずれか → バリデーション通過
  it('aesthetic_directionが定義済みenum値のいずれかの場合はバリデーション通過', () => {
    const enumValues = ['ethereal', 'mystical', 'healing', 'elegant', 'natural'];
    for (const value of enumValues) {
      const data = { ...validWorldview, aesthetic_direction: value };
      const result = validateWorldview(data);
      expect(result.valid).toBe(true);
      expect(result.errors).toBeUndefined();
    }
  });

  // behavior: aesthetic_directionが未定義enum値（例: 'aggressive'）→ バリデーションエラー（許可値リストを含むメッセージ）
  it('aesthetic_directionが未定義enum値（"aggressive"）の場合はバリデーションエラー（許可値リストを含むメッセージ）', () => {
    const data: Record<string, unknown> = { ...validWorldview, aesthetic_direction: 'aggressive' };
    const result = validateWorldview(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    // 許可値リストを含むメッセージを検証
    const hasEnumError = result.errors!.some(
      (e) =>
        e.includes('aesthetic_direction') &&
        (e.includes('ethereal') ||
          e.includes('mystical') ||
          e.includes('healing') ||
          e.includes('elegant') ||
          e.includes('natural') ||
          e.includes('allowed'))
    );
    expect(hasEnumError).toBe(true);
  });

  // behavior: color_paletteの要素がHEXカラーコード形式でない（例: 'red'）→ バリデーションエラー（HEX形式要求メッセージ）
  it('color_paletteの要素がHEXカラーコード形式でない（"red"）場合はバリデーションエラー（HEX形式要求メッセージ）', () => {
    const data: Record<string, unknown> = {
      ...validWorldview,
      color_palette: ['#7B2FBE', 'red'],
    };
    const result = validateWorldview(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    // HEX形式要求メッセージを検証
    const hasHexError = result.errors!.some(
      (e) =>
        e.includes('color_palette') &&
        (e.toLowerCase().includes('hex') || e.includes('#') || e.includes('pattern'))
    );
    expect(hasHexError).toBe(true);
  });

  // behavior: keywords配列が空 → バリデーションエラー（最低1要素必須）
  it('keywords配列が空の場合はバリデーションエラー（最低1要素必須）', () => {
    const data: Record<string, unknown> = { ...validWorldview, keywords: [] };
    const result = validateWorldview(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasMinItemsError = result.errors!.some(
      (e) =>
        e.includes('keywords') &&
        (e.includes('fewer than 1 items') || e.includes('minItems') || e.includes('1'))
    );
    expect(hasMinItemsError).toBe(true);
  });

  // behavior: tone がfree-textフィールドとして100文字以内の文字列 → バリデーション通過
  it('toneが100文字以内の文字列の場合はバリデーション通過', () => {
    // ちょうど100文字のtone
    const tone100 = 'あ'.repeat(100);
    const data: Record<string, unknown> = { ...validWorldview, tone: tone100 };
    const result = validateWorldview(data);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: tone が空文字 → バリデーションエラー
  it('toneが空文字の場合はバリデーションエラー', () => {
    const data: Record<string, unknown> = { ...validWorldview, tone: '' };
    const result = validateWorldview(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasToneError = result.errors!.some((e) => e.includes('tone'));
    expect(hasToneError).toBe(true);
  });

  // behavior: [追加] 必須フィールドが欠落した場合はバリデーションエラー
  it('必須フィールド $schema_version が欠落した場合はバリデーションエラー', () => {
    const data: Record<string, unknown> = { ...validWorldview };
    delete data['$schema_version'];
    const result = validateWorldview(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasVersionError = result.errors!.some((e) => e.includes('$schema_version'));
    expect(hasVersionError).toBe(true);
  });

  // behavior: [追加] color_paletteが空配列 → バリデーションエラー
  it('color_paletteが空配列の場合はバリデーションエラー（最低1要素必須）', () => {
    const data: Record<string, unknown> = { ...validWorldview, color_palette: [] };
    const result = validateWorldview(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasColorError = result.errors!.some((e) => e.includes('color_palette'));
    expect(hasColorError).toBe(true);
  });

  // behavior: [追加] exemplar_textsが空配列 → バリデーションエラー
  it('exemplar_textsが空配列の場合はバリデーションエラー（最低1要素必須）', () => {
    const data: Record<string, unknown> = { ...validWorldview, exemplar_texts: [] };
    const result = validateWorldview(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasExemplarError = result.errors!.some((e) => e.includes('exemplar_texts'));
    expect(hasExemplarError).toBe(true);
  });

  // behavior: [追加] toneが101文字 → バリデーションエラー
  it('toneが101文字の場合はバリデーションエラー（100文字上限超過）', () => {
    const tone101 = 'a'.repeat(101);
    const data: Record<string, unknown> = { ...validWorldview, tone: tone101 };
    const result = validateWorldview(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasToneMaxError = result.errors!.some((e) => e.includes('tone'));
    expect(hasToneMaxError).toBe(true);
  });

  // behavior: [追加] 短縮HEX形式（#RGB）は有効なカラーコードとして通過
  it('短縮HEX形式（#RGB）のcolor_paletteはバリデーション通過', () => {
    const data: Record<string, unknown> = {
      ...validWorldview,
      color_palette: ['#FFF', '#ABC', '#123'],
    };
    const result = validateWorldview(data);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: [追加] additionalProperties（スキーマ未定義フィールド）を含む場合もバリデーション通過
  it('スキーマ未定義の追加フィールドがあってもバリデーション通過（additionalProperties 許可）', () => {
    const data: Record<string, unknown> = {
      ...validWorldview,
      custom_note: '月の満ち欠けを象徴するビジュアル',
      season: 'autumn',
    };
    const result = validateWorldview(data);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });
});
