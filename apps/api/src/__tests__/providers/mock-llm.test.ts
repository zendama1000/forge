import { describe, it, expect } from 'vitest';
import {
  MockLLMProvider,
  createLLMProvider,
  type LLMProvider,
} from '../../providers/llm-provider';
import { FortuneResponseSchema } from '../../schemas/fortune-response';

// ─── テストフィクスチャ ─────────────────────────────────────────────────────────

/** 有効な7次元入力（値0〜100の整数） */
const VALID_INPUT = { dimensions: [50, 60, 70, 80, 90, 40, 55] };

/** 別の有効な7次元入力（決定論的動作の検証用） */
const ANOTHER_VALID_INPUT = { dimensions: [10, 20, 30, 40, 50, 60, 70] };

// ─── MockLLMProvider ─────────────────────────────────────────────────────────

describe('MockLLMProvider', () => {
  // behavior: MockLLMProvider.generate(validInput) → 4カテゴリ×7次元のZodスキーマ準拠JSON返却
  it('有効な入力で4カテゴリ×7次元のZodスキーマ準拠JSONを返す', async () => {
    const provider = new MockLLMProvider();
    const result = await provider.generate(VALID_INPUT);

    // 戻り値が文字列であること
    expect(typeof result).toBe('string');

    // JSONとしてパース可能であること
    const parsed: unknown = JSON.parse(result);
    expect(parsed).toHaveProperty('categories');

    const categories = (parsed as { categories: unknown[] }).categories;
    // 4カテゴリ
    expect(categories).toHaveLength(4);

    // 各カテゴリに7次元
    categories.forEach((cat) => {
      const c = cat as { dimensions: unknown[]; totalScore: number; templateText: string };
      expect(c.dimensions).toHaveLength(7);
      expect(typeof c.totalScore).toBe('number');
      expect(typeof c.templateText).toBe('string');
      expect(c.templateText.length).toBeGreaterThanOrEqual(1);
    });
  });

  // behavior: 異なる入力パラメータで2回generate()呼び出し → 両方同一レスポンス（決定論的動作）
  it('異なる入力パラメータで2回呼び出しても同一レスポンスを返す（決定論的動作）', async () => {
    const provider = new MockLLMProvider();

    const result1 = await provider.generate(VALID_INPUT);
    const result2 = await provider.generate(ANOTHER_VALID_INPUT);

    // 両方同一レスポンス
    expect(result1).toBe(result2);
  });

  // behavior: MockLLMProviderのレスポンスをFortuneResponseスキーマでparse → 成功
  it('レスポンスをFortuneResponseスキーマでparseすると成功する', async () => {
    const provider = new MockLLMProvider();
    const result = await provider.generate(VALID_INPUT);

    const parsed: unknown = JSON.parse(result);
    const zodResult = FortuneResponseSchema.safeParse(parsed);

    // スキーマバリデーション成功
    expect(zodResult.success).toBe(true);

    if (zodResult.success) {
      // 4カテゴリ
      expect(zodResult.data.categories).toHaveLength(4);

      zodResult.data.categories.forEach((cat) => {
        // 各カテゴリに7次元
        expect(cat.dimensions).toHaveLength(7);
        // totalScore は 0〜100 の範囲
        expect(cat.totalScore).toBeGreaterThanOrEqual(0);
        expect(cat.totalScore).toBeLessThanOrEqual(100);
        // templateText は1文字以上
        expect(cat.templateText.length).toBeGreaterThanOrEqual(1);

        cat.dimensions.forEach((dim) => {
          // rawScore は 0〜100 の整数
          expect(dim.rawScore).toBeGreaterThanOrEqual(0);
          expect(dim.rawScore).toBeLessThanOrEqual(100);
          expect(Number.isInteger(dim.rawScore)).toBe(true);
        });
      });
    }
  });

  // behavior: [追加] エッジケース - 境界値入力（全次元0）でも決定論的に動作する
  it('境界値入力（全次元0）でも決定論的なレスポンスを返す', async () => {
    const provider = new MockLLMProvider();
    const boundaryInput = { dimensions: [0, 0, 0, 0, 0, 0, 0] };

    const result = await provider.generate(boundaryInput);

    expect(typeof result).toBe('string');
    const parsed: unknown = JSON.parse(result);
    expect((parsed as { categories: unknown[] }).categories).toHaveLength(4);
  });

  // behavior: [追加] 同一インスタンスで複数回呼び出しても同一結果
  it('同一インスタンスで連続3回呼び出しても全て同一レスポンスを返す', async () => {
    const provider = new MockLLMProvider();

    const results = await Promise.all([
      provider.generate(VALID_INPUT),
      provider.generate(VALID_INPUT),
      provider.generate(VALID_INPUT),
    ]);

    expect(results[0]).toBe(results[1]);
    expect(results[1]).toBe(results[2]);
  });
});

// ─── createLLMProvider ───────────────────────────────────────────────────────

describe('createLLMProvider', () => {
  // behavior: createLLMProvider({useMock: true}) → MockLLMProviderインスタンス返却
  it('useMock:true のとき MockLLMProvider インスタンスを返す', () => {
    const provider = createLLMProvider({ useMock: true });

    expect(provider).toBeInstanceOf(MockLLMProvider);
  });

  // behavior: createLLMProvider({useMock: false, apiKey: undefined}) → エラースロー（設定不備）
  it('useMock:false かつ apiKey が undefined のとき設定不備エラーをスローする', () => {
    expect(() =>
      createLLMProvider({ useMock: false, apiKey: undefined }),
    ).toThrow();

    // エラーメッセージに apiKey または設定不備に関する情報が含まれること
    expect(() =>
      createLLMProvider({ useMock: false, apiKey: undefined }),
    ).toThrowError(/apiKey|設定|config/i);
  });

  // behavior: createLLMProvider(引数未指定) → デフォルトでMockLLMProvider返却
  it('引数未指定のときデフォルトで MockLLMProvider を返す', () => {
    const provider = createLLMProvider();

    expect(provider).toBeInstanceOf(MockLLMProvider);
  });

  // behavior: [追加] 空オブジェクト {} でも MockLLMProvider を返す
  it('useMock が未指定のオプションオブジェクト {} でも MockLLMProvider を返す', () => {
    const provider = createLLMProvider({});

    expect(provider).toBeInstanceOf(MockLLMProvider);
  });

  // behavior: [追加] 返されたプロバイダーが LLMProvider インターフェース（generate()）を満たす
  it('返された MockLLMProvider が generate メソッドを持ち呼び出せる', async () => {
    const provider = createLLMProvider({ useMock: true });

    expect(typeof provider.generate).toBe('function');

    // 実際に呼び出せることも確認
    const result = await provider.generate(VALID_INPUT);
    expect(typeof result).toBe('string');
  });

  // behavior: [追加] useMock:false かつ apiKey が空文字列でもエラー（設定不備）
  it('useMock:false かつ apiKey が空文字列のときもエラーをスローする', () => {
    expect(() =>
      createLLMProvider({ useMock: false, apiKey: '' }),
    ).toThrow();
  });
});

// ─── LLMProvider 型チェック ──────────────────────────────────────────────────

describe('LLMProvider インターフェース型安全性', () => {
  // behavior: LLMProviderインターフェースのgenerate()を実装しないクラスをプロバイダーとして使用 → 型エラー検出
  it('generate()を実装しないクラスはLLMProvider型に代入できない（TypeScript型エラー）', () => {
    // generate() メソッドを持たないクラス
    class NotAProvider {
      someOtherMethod(): void {
        // generate() メソッドなし
      }
    }

    // @ts-expect-error LLMProvider インターフェースには generate() が必須のため型エラー
    const _invalid: LLMProvider = new NotAProvider();

    // ランタイムでも generate が存在しないことを確認
    const runtime = new NotAProvider() as unknown as LLMProvider;
    expect(runtime.generate).toBeUndefined();
  });

  // behavior: [追加] MockLLMProvider は LLMProvider インターフェースを完全に実装している
  it('MockLLMProvider は LLMProvider 型変数に代入可能（インターフェース適合）', () => {
    // LLMProvider 型として代入できる（コンパイルエラーなし）
    const provider: LLMProvider = new MockLLMProvider();

    expect(typeof provider.generate).toBe('function');
  });

  // behavior: [追加] generate() の引数型が FortuneRequest に準拠している
  it('generate() は FortuneRequest 形式の入力を受け付ける', async () => {
    const provider: LLMProvider = new MockLLMProvider();

    // FortuneRequest 準拠の入力
    const fortuneRequest = { dimensions: [30, 40, 50, 60, 70, 80, 90] };
    const result = await provider.generate(fortuneRequest);

    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });
});
