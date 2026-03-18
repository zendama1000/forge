import { FortuneRequest } from '../schemas/fortune-request';
import { FortuneResponse } from '../schemas/fortune-response';

// ─── Interface ────────────────────────────────────────────────────────────────

/**
 * LLMプロバイダーインターフェース
 * 占いリクエストを受け取り、FortuneResponseのJSON文字列を非同期で返す
 */
export interface LLMProvider {
  generate(input: FortuneRequest): Promise<string>;
}

// ─── Mock Response Fixture ────────────────────────────────────────────────────

/**
 * MockLLMProvider が返す固定レスポンス
 * 4カテゴリ × 7次元、FortuneResponseSchema 準拠
 */
const MOCK_FORTUNE_RESPONSE: FortuneResponse = {
  categories: [
    {
      name: '恋愛運',
      totalScore: 75,
      templateText: '恋愛運は良好です。積極的に行動することで新たな出会いが期待できます。',
      dimensions: [
        { rawScore: 70 },
        { rawScore: 80 },
        { rawScore: 75 },
        { rawScore: 65 },
        { rawScore: 85 },
        { rawScore: 72 },
        { rawScore: 78 },
      ],
    },
    {
      name: '仕事運',
      totalScore: 60,
      templateText: '仕事運は普通です。着実にコツコツと取り組みましょう。',
      dimensions: [
        { rawScore: 55 },
        { rawScore: 65 },
        { rawScore: 60 },
        { rawScore: 58 },
        { rawScore: 62 },
        { rawScore: 57 },
        { rawScore: 63 },
      ],
    },
    {
      name: '金運',
      totalScore: 50,
      templateText: '金運は安定しています。無駄遣いに気をつけましょう。',
      dimensions: [
        { rawScore: 45 },
        { rawScore: 55 },
        { rawScore: 50 },
        { rawScore: 48 },
        { rawScore: 52 },
        { rawScore: 49 },
        { rawScore: 51 },
      ],
    },
    {
      name: '健康運',
      totalScore: 80,
      templateText: '健康運は優れています。体を動かす絶好の機会です。',
      dimensions: [
        { rawScore: 75 },
        { rawScore: 85 },
        { rawScore: 80 },
        { rawScore: 78 },
        { rawScore: 82 },
        { rawScore: 79 },
        { rawScore: 81 },
      ],
    },
  ],
};

// ─── MockLLMProvider ──────────────────────────────────────────────────────────

/**
 * MockLLMProvider
 * 決定論的な固定レスポンスを返すモック実装。
 * 実際のLLM APIを呼び出さず、テスト・開発環境で使用する。
 */
export class MockLLMProvider implements LLMProvider {
  /**
   * 入力に関わらず常に同一の FortuneResponse JSON 文字列を返す
   * @param _input 占いリクエスト（モックでは使用しない）
   * @returns FortuneResponseSchema 準拠の JSON 文字列
   */
  async generate(_input: FortuneRequest): Promise<string> {
    return JSON.stringify(MOCK_FORTUNE_RESPONSE);
  }
}

// ─── Factory ──────────────────────────────────────────────────────────────────

/**
 * createLLMProvider のオプション
 */
export interface LLMProviderOptions {
  /** true またはデフォルト: MockLLMProvider を使用 */
  useMock?: boolean;
  /** useMock=false の場合は必須 */
  apiKey?: string;
}

/**
 * createLLMProvider ファクトリ関数
 *
 * - 引数未指定: MockLLMProvider を返す
 * - useMock が true（またはデフォルト）: MockLLMProvider を返す
 * - useMock が false かつ apiKey 未指定: 設定不備エラーをスロー
 *
 * @throws {Error} useMock=false かつ apiKey が未指定の場合
 */
export function createLLMProvider(options?: LLMProviderOptions): LLMProvider {
  // 引数未指定、または useMock が明示的に false でない場合はモックを返す
  if (!options || options.useMock !== false) {
    return new MockLLMProvider();
  }

  // useMock=false だが apiKey が未指定の場合は設定不備エラー
  if (!options.apiKey) {
    throw new Error(
      'LLMプロバイダーの設定が不正です: useMock=false の場合は apiKey が必要です',
    );
  }

  // 実LLMプロバイダーは別タスクで実装予定
  // apiKey が指定されていても現時点では実装がない
  throw new Error(
    '実LLMプロバイダーは未実装です。useMock=true を使用してください。',
  );
}
