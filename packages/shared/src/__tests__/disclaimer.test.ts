/**
 * Disclaimer Embedding Logic - Layer 1 Tests
 *
 * 免責表示埋め込み機能の単体テスト
 */

import {
  DISCLAIMER_TEXT,
  DEFAULT_LANGUAGE,
  embedDisclaimer,
  hasDisclaimer,
  getDisclaimerMetadata,
  isSupportedLanguage,
  getSupportedLanguages,
  type SupportedLanguage,
  type WorldDataWithMetadata,
} from '../disclaimer';
import type { WorldData } from '../types/api';

// ===========================
// Test Fixtures
// ===========================

const createMockWorld = (overrides?: Partial<WorldDataWithMetadata>): WorldDataWithMetadata => ({
  id: 'world-123',
  title: 'Test World',
  description: 'A test world for disclaimer tests',
  dimensions: {
    complexity: 0.5,
    novelty: 0.5,
    coherence: 0.5,
    emotion: 0.5,
    interactivity: 0.5,
    scale: 0.5,
    uncertainty: 0.5,
  },
  tags: ['test'],
  isPublic: false,
  userId: 'user-123',
  createdAt: '2026-02-15T00:00:00Z',
  updatedAt: '2026-02-15T00:00:00Z',
  ...overrides,
});

// ===========================
// Constants Tests
// ===========================

describe('DISCLAIMER_TEXT 定数', () => {
  test('必須言語（ja, en）を含む', () => {
    expect(DISCLAIMER_TEXT.ja).toBeDefined();
    expect(DISCLAIMER_TEXT.en).toBeDefined();
    expect(typeof DISCLAIMER_TEXT.ja).toBe('string');
    expect(typeof DISCLAIMER_TEXT.en).toBe('string');
  });

  test('すべての免責文が非空文字列', () => {
    Object.values(DISCLAIMER_TEXT).forEach(text => {
      expect(text.length).toBeGreaterThan(0);
    });
  });

  test('デフォルト言語が "en"', () => {
    expect(DEFAULT_LANGUAGE).toBe('en');
  });
});

// ===========================
// embedDisclaimer Tests
// ===========================

describe('embedDisclaimer(world, language?)', () => {
  test('デフォルト言語（en）で免責メタデータを付与する', () => {
    const world = createMockWorld();
    const result = embedDisclaimer(world);

    expect(result.metadata?._disclaimer).toBe(DISCLAIMER_TEXT.en);
    expect(result.metadata?._is_fictional).toBe(true);
    expect(result.metadata?._generated_at).toMatch(/^\d{4}-\d{2}-\d{2}T/); // ISO 8601形式
  });

  test('指定言語（ja）で免責メタデータを付与する', () => {
    const world = createMockWorld();
    const result = embedDisclaimer(world, 'ja');

    expect(result.metadata?._disclaimer).toBe(DISCLAIMER_TEXT.ja);
    expect(result.metadata?._is_fictional).toBe(true);
  });

  test('既存のmetadataを保持する', () => {
    const world = createMockWorld({
      metadata: {
        generationTime: 1500,
        model: 'gpt-4',
        version: '1.0',
      },
    });
    const result = embedDisclaimer(world);

    expect(result.metadata?.generationTime).toBe(1500);
    expect(result.metadata?.model).toBe('gpt-4');
    expect(result.metadata?.version).toBe('1.0');
    expect(result.metadata?._disclaimer).toBeDefined();
  });

  test('元のWorldDataオブジェクトを変更しない（イミュータブル）', () => {
    const world = createMockWorld();
    const original = { ...world };
    embedDisclaimer(world);

    expect(world).toEqual(original);
  });

  // エッジケース: サポートされていない言語コード
  test('サポート外言語の場合、デフォルト言語（en）にフォールバック', () => {
    const world = createMockWorld();
    const result = embedDisclaimer(world, 'invalid-lang' as SupportedLanguage);

    expect(result.metadata?._disclaimer).toBe(DISCLAIMER_TEXT.en);
  });

  // エッジケース: metadata が undefined の場合
  test('metadata が未定義でも正常に動作', () => {
    const world = createMockWorld();
    delete (world as any).metadata;

    const result = embedDisclaimer(world);
    expect(result.metadata?._disclaimer).toBeDefined();
    expect(result.metadata?._is_fictional).toBe(true);
  });
});

// ===========================
// hasDisclaimer Tests
// ===========================

describe('hasDisclaimer(world)', () => {
  test('免責表示が存在する場合 true を返す', () => {
    const world = createMockWorld();
    const withDisclaimer = embedDisclaimer(world);

    expect(hasDisclaimer(withDisclaimer)).toBe(true);
  });

  test('免責表示が存在しない場合 false を返す', () => {
    const world = createMockWorld();

    expect(hasDisclaimer(world)).toBe(false);
  });

  // エッジケース: metadata が null
  test('metadata が null の場合 false を返す', () => {
    const world = createMockWorld({ metadata: null as any });

    expect(hasDisclaimer(world)).toBe(false);
  });

  // エッジケース: metadata が undefined
  test('metadata が undefined の場合 false を返す', () => {
    const world = createMockWorld();
    delete (world as any).metadata;

    expect(hasDisclaimer(world)).toBe(false);
  });

  // エッジケース: _disclaimer が空文字列
  test('_disclaimer が空文字列の場合 false を返す', () => {
    const world = createMockWorld({
      metadata: { _disclaimer: '' } as any,
    });

    expect(hasDisclaimer(world)).toBe(false);
  });

  // エッジケース: _disclaimer が文字列以外
  test('_disclaimer が文字列でない場合 false を返す', () => {
    const world = createMockWorld({
      metadata: { _disclaimer: 123 } as any,
    });

    expect(hasDisclaimer(world)).toBe(false);
  });
});

// ===========================
// getDisclaimerMetadata Tests
// ===========================

describe('getDisclaimerMetadata(world)', () => {
  test('免責メタデータを正しく取得', () => {
    const world = createMockWorld();
    const withDisclaimer = embedDisclaimer(world, 'ja');
    const metadata = getDisclaimerMetadata(withDisclaimer);

    expect(metadata).not.toBeNull();
    expect(metadata?._disclaimer).toBe(DISCLAIMER_TEXT.ja);
    expect(metadata?._is_fictional).toBe(true);
    expect(metadata?._generated_at).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  test('免責表示が存在しない場合 null を返す', () => {
    const world = createMockWorld();
    const metadata = getDisclaimerMetadata(world);

    expect(metadata).toBeNull();
  });

  // エッジケース: 一部フィールドが欠落
  test('_generated_at が存在しない場合、空文字列でフィル', () => {
    const world = createMockWorld({
      metadata: {
        _disclaimer: 'Test disclaimer',
        _is_fictional: true,
      } as any,
    });

    const metadata = getDisclaimerMetadata(world);
    expect(metadata?._generated_at).toBe('');
  });
});

// ===========================
// Language Support Tests
// ===========================

describe('isSupportedLanguage(language)', () => {
  test('サポートされている言語で true を返す', () => {
    expect(isSupportedLanguage('en')).toBe(true);
    expect(isSupportedLanguage('ja')).toBe(true);
    expect(isSupportedLanguage('zh')).toBe(true);
  });

  test('サポートされていない言語で false を返す', () => {
    expect(isSupportedLanguage('de')).toBe(false);
    expect(isSupportedLanguage('invalid')).toBe(false);
    expect(isSupportedLanguage('')).toBe(false);
  });
});

describe('getSupportedLanguages()', () => {
  test('すべてのサポート言語を配列で返す', () => {
    const languages = getSupportedLanguages();

    expect(Array.isArray(languages)).toBe(true);
    expect(languages).toContain('en');
    expect(languages).toContain('ja');
    expect(languages.length).toBeGreaterThan(0);
  });

  test('返される配列が DISCLAIMER_TEXT のキーと一致', () => {
    const languages = getSupportedLanguages();
    const expectedKeys = Object.keys(DISCLAIMER_TEXT);

    expect(languages.sort()).toEqual(expectedKeys.sort());
  });
});
