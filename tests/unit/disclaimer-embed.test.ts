/**
 * Layer 1 Test: 免責表示埋め込みのユニットテスト
 *
 * L1-013: embedDisclaimerでメタデータ3フィールド付与確認、
 * hasDisclaimerの真偽値確認、既存データ非破壊確認
 */

import { describe, it, expect } from 'vitest';
import {
  embedDisclaimer,
  hasDisclaimer,
  DISCLAIMER_TEXT,
  DEFAULT_LANGUAGE,
  type WorldDataWithMetadata,
  type SupportedLanguage,
} from '../../packages/shared/src/disclaimer';

// ===========================
// Test Fixtures
// ===========================

/**
 * モック用の最小限のWorldDataを生成
 */
const createMockWorld = (
  overrides?: Partial<WorldDataWithMetadata>
): WorldDataWithMetadata => ({
  id: 'test-world-001',
  title: 'Test World',
  description: 'A test world for disclaimer embedding',
  dimensions: {
    complexity: 0.7,
    novelty: 0.5,
    coherence: 0.8,
    emotion: 0.6,
    interactivity: 0.4,
    scale: 0.5,
    uncertainty: 0.3,
  },
  tags: ['test', 'disclaimer'],
  isPublic: false,
  userId: 'user-test-123',
  createdAt: '2026-02-15T00:00:00Z',
  updatedAt: '2026-02-15T00:00:00Z',
  ...overrides,
});

// ===========================
// Core Tests
// ===========================

describe('embedDisclaimer - メタデータ3フィールド付与確認', () => {
  it('正常系: デフォルト言語で _disclaimer, _generated_at, _is_fictional の3フィールドを付与する', () => {
    const world = createMockWorld();
    const result = embedDisclaimer(world);

    // 3フィールドの存在確認
    expect(result.metadata).toBeDefined();
    expect(result.metadata?._disclaimer).toBeDefined();
    expect(result.metadata?._generated_at).toBeDefined();
    expect(result.metadata?._is_fictional).toBeDefined();

    // 型と値の確認
    expect(typeof result.metadata?._disclaimer).toBe('string');
    expect(result.metadata?._disclaimer).toBe(DISCLAIMER_TEXT[DEFAULT_LANGUAGE]);
    expect(typeof result.metadata?._generated_at).toBe('string');
    expect(result.metadata?._generated_at).toMatch(/^\d{4}-\d{2}-\d{2}T/); // ISO 8601形式
    expect(result.metadata?._is_fictional).toBe(true);
  });

  it('正常系: 日本語（ja）で免責表示を付与する', () => {
    const world = createMockWorld();
    const result = embedDisclaimer(world, 'ja');

    expect(result.metadata?._disclaimer).toBe(DISCLAIMER_TEXT.ja);
    expect(result.metadata?._is_fictional).toBe(true);
  });

  it('正常系: 中国語（zh）で免責表示を付与する', () => {
    const world = createMockWorld();
    const result = embedDisclaimer(world, 'zh');

    expect(result.metadata?._disclaimer).toBe(DISCLAIMER_TEXT.zh);
    expect(result.metadata?._is_fictional).toBe(true);
  });

  it('エッジケース: サポート外の言語コードを渡した場合、デフォルト言語（en）にフォールバックする', () => {
    const world = createMockWorld();
    const result = embedDisclaimer(world, 'unsupported-lang' as SupportedLanguage);

    expect(result.metadata?._disclaimer).toBe(DISCLAIMER_TEXT.en);
    expect(result.metadata?._is_fictional).toBe(true);
  });

  it('エッジケース: metadata が undefined の場合でも正常に動作する', () => {
    const world = createMockWorld();
    delete (world as any).metadata;

    const result = embedDisclaimer(world);

    expect(result.metadata?._disclaimer).toBeDefined();
    expect(result.metadata?._generated_at).toBeDefined();
    expect(result.metadata?._is_fictional).toBe(true);
  });
});

describe('hasDisclaimer - 真偽値確認', () => {
  it('正常系: embedDisclaimerで処理された世界データは true を返す', () => {
    const world = createMockWorld();
    const withDisclaimer = embedDisclaimer(world);

    expect(hasDisclaimer(withDisclaimer)).toBe(true);
  });

  it('正常系: 免責表示が付与されていない世界データは false を返す', () => {
    const world = createMockWorld();

    expect(hasDisclaimer(world)).toBe(false);
  });

  it('エッジケース: metadata が null の場合 false を返す', () => {
    const world = createMockWorld({ metadata: null as any });

    expect(hasDisclaimer(world)).toBe(false);
  });

  it('エッジケース: metadata が undefined の場合 false を返す', () => {
    const world = createMockWorld();
    delete (world as any).metadata;

    expect(hasDisclaimer(world)).toBe(false);
  });

  it('エッジケース: _disclaimer が空文字列の場合 false を返す', () => {
    const world = createMockWorld({
      metadata: {
        _disclaimer: '',
        _generated_at: '2026-02-15T00:00:00Z',
        _is_fictional: true,
      } as any,
    });

    expect(hasDisclaimer(world)).toBe(false);
  });

  it('エッジケース: _disclaimer が文字列でない場合（数値） false を返す', () => {
    const world = createMockWorld({
      metadata: {
        _disclaimer: 12345,
        _generated_at: '2026-02-15T00:00:00Z',
        _is_fictional: true,
      } as any,
    });

    expect(hasDisclaimer(world)).toBe(false);
  });

  it('エッジケース: _disclaimer が文字列でない場合（オブジェクト） false を返す', () => {
    const world = createMockWorld({
      metadata: {
        _disclaimer: { text: 'Not a string' },
        _generated_at: '2026-02-15T00:00:00Z',
        _is_fictional: true,
      } as any,
    });

    expect(hasDisclaimer(world)).toBe(false);
  });
});

describe('既存データ非破壊確認', () => {
  it('正常系: 既存の metadata フィールドを保持する', () => {
    const world = createMockWorld({
      metadata: {
        generationTime: 2500,
        model: 'claude-sonnet-4.5',
        version: '2.0.1',
        customField: 'custom-value',
      },
    });

    const result = embedDisclaimer(world, 'ja');

    // 既存フィールドが保持されていることを確認
    expect(result.metadata?.generationTime).toBe(2500);
    expect(result.metadata?.model).toBe('claude-sonnet-4.5');
    expect(result.metadata?.version).toBe('2.0.1');
    expect(result.metadata?.customField).toBe('custom-value');

    // 免責フィールドも追加されていることを確認
    expect(result.metadata?._disclaimer).toBeDefined();
    expect(result.metadata?._is_fictional).toBe(true);
  });

  it('正常系: 元のWorldDataオブジェクトを変更しない（イミュータブル）', () => {
    const world = createMockWorld({
      metadata: {
        generationTime: 1000,
        model: 'test-model',
      },
    });

    // 元のオブジェクトのコピーを作成
    const originalMetadata = { ...world.metadata };
    const originalWorldString = JSON.stringify(world);

    // embedDisclaimerを実行
    const result = embedDisclaimer(world);

    // 元のオブジェクトが変更されていないことを確認
    expect(JSON.stringify(world)).toBe(originalWorldString);
    expect(world.metadata).toEqual(originalMetadata);

    // 新しいオブジェクトには免責情報が含まれる
    expect(result.metadata?._disclaimer).toBeDefined();
  });

  it('正常系: トップレベルのWorldDataフィールドを保持する', () => {
    const world = createMockWorld();

    const result = embedDisclaimer(world);

    // トップレベルのフィールドがすべて保持されていることを確認
    expect(result.id).toBe(world.id);
    expect(result.title).toBe(world.title);
    expect(result.description).toBe(world.description);
    expect(result.dimensions).toEqual(world.dimensions);
    expect(result.tags).toEqual(world.tags);
    expect(result.isPublic).toBe(world.isPublic);
    expect(result.userId).toBe(world.userId);
    expect(result.createdAt).toBe(world.createdAt);
    expect(result.updatedAt).toBe(world.updatedAt);
  });

  it('エッジケース: metadata が存在しない場合でも既存データを保持する', () => {
    const world = createMockWorld();
    delete (world as any).metadata;

    const result = embedDisclaimer(world);

    // トップレベルのフィールドが保持されている
    expect(result.id).toBe(world.id);
    expect(result.title).toBe(world.title);

    // metadata が新規作成され、免責情報が含まれる
    expect(result.metadata?._disclaimer).toBeDefined();
  });

  it('エッジケース: 複数回 embedDisclaimer を実行しても既存の免責情報を上書きする', () => {
    const world = createMockWorld();

    const firstEmbed = embedDisclaimer(world, 'ja');
    const firstDisclaimer = firstEmbed.metadata?._disclaimer;
    const firstGeneratedAt = firstEmbed.metadata?._generated_at;

    // 少し待ってから再度実行（タイムスタンプが変わることを確認）
    const secondEmbed = embedDisclaimer(firstEmbed, 'en');

    expect(secondEmbed.metadata?._disclaimer).toBe(DISCLAIMER_TEXT.en);
    expect(secondEmbed.metadata?._disclaimer).not.toBe(firstDisclaimer);
    expect(secondEmbed.metadata?._is_fictional).toBe(true);
    // タイムスタンプは更新される（ISO 8601形式であることを確認）
    expect(secondEmbed.metadata?._generated_at).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });
});

// ===========================
// Integration Test
// ===========================

describe('統合テスト: embedDisclaimer + hasDisclaimer', () => {
  it('埋め込み前と埋め込み後で hasDisclaimer の結果が変化する', () => {
    const world = createMockWorld();

    // 埋め込み前
    expect(hasDisclaimer(world)).toBe(false);

    // 埋め込み実行
    const withDisclaimer = embedDisclaimer(world);

    // 埋め込み後
    expect(hasDisclaimer(withDisclaimer)).toBe(true);
  });

  it('すべてのサポート言語で正しく埋め込みと検出ができる', () => {
    const languages: SupportedLanguage[] = ['en', 'ja', 'zh', 'es', 'fr'];

    languages.forEach((lang) => {
      const world = createMockWorld();
      const result = embedDisclaimer(world, lang);

      expect(hasDisclaimer(result)).toBe(true);
      expect(result.metadata?._disclaimer).toBe(DISCLAIMER_TEXT[lang]);
      expect(result.metadata?._is_fictional).toBe(true);
    });
  });
});
