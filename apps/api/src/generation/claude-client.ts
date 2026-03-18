import Anthropic from '@anthropic-ai/sdk';
import { z } from 'zod';

export interface ClaudeClientOptions {
  apiKey?: string;
  model?: string;
  maxTokens?: number;
  temperature?: number;
  timeout?: number;
}

export interface CallClaudeOptions {
  model?: string;
  maxTokens?: number;
  temperature?: number;
  systemPrompt?: string;
  stream?: boolean;
}

const DEFAULT_MODEL = 'claude-3-5-sonnet-20241022';
const DEFAULT_MAX_TOKENS = 4096;
const DEFAULT_TEMPERATURE = 1.0;
const DEFAULT_TIMEOUT = 60000; // 60秒
const MAX_RETRIES = 3;
const INITIAL_BACKOFF_MS = 1000;

/**
 * Claude API呼び出しクライアント
 * - ストリーミング対応
 * - 指数バックオフリトライ（最大3回）
 * - エラーハンドリング（タイムアウト・レート制限・500）
 */
export class ClaudeClient {
  private client: Anthropic;
  private model: string;
  private maxTokens: number;
  private temperature: number;
  private timeout: number;

  constructor(options: ClaudeClientOptions = {}) {
    const apiKey = options.apiKey || process.env.ANTHROPIC_API_KEY;
    if (!apiKey) {
      throw new Error('ANTHROPIC_API_KEY is required');
    }

    this.client = new Anthropic({
      apiKey,
      timeout: options.timeout || DEFAULT_TIMEOUT,
    });

    this.model = options.model || DEFAULT_MODEL;
    this.maxTokens = options.maxTokens || DEFAULT_MAX_TOKENS;
    this.temperature = options.temperature || DEFAULT_TEMPERATURE;
    this.timeout = options.timeout || DEFAULT_TIMEOUT;
  }

  /**
   * Claude APIを呼び出す
   * @param prompt ユーザープロンプト
   * @param options オプション設定
   * @returns ストリーミングの場合はAsyncIterable、それ以外はテキスト
   */
  async callClaude(
    prompt: string,
    options: CallClaudeOptions = {}
  ): Promise<string | AsyncIterable<Anthropic.MessageStreamEvent>> {
    const model = options.model || this.model;
    const maxTokens = options.maxTokens || this.maxTokens;
    const temperature = options.temperature ?? this.temperature;
    const stream = options.stream ?? false;

    const messages: Anthropic.MessageParam[] = [
      {
        role: 'user',
        content: prompt,
      },
    ];

    const params: Anthropic.MessageCreateParams = {
      model,
      max_tokens: maxTokens,
      temperature,
      messages,
    };

    if (options.systemPrompt) {
      params.system = options.systemPrompt;
    }

    if (stream) {
      return this.callWithRetry(() =>
        this.client.messages.stream(params)
      ) as Promise<AsyncIterable<Anthropic.MessageStreamEvent>>;
    }

    const response = await this.callWithRetry(() =>
      this.client.messages.create(params)
    );

    const textContent = response.content.find(
      (block) => block.type === 'text'
    );
    if (!textContent || textContent.type !== 'text') {
      throw new Error('No text content in response');
    }

    return textContent.text;
  }

  /**
   * 構造化レスポンスをパースしてZodスキーマでバリデーション
   * @param response API応答テキスト
   * @param schema Zodスキーマ
   * @returns バリデーション済みオブジェクト
   */
  parseStructuredResponse<T>(response: string, schema: z.ZodSchema<T>): T {
    // JSON部分を抽出（```json ... ``` や ``` ... ``` に囲まれている場合に対応）
    let jsonString = response.trim();

    const jsonBlockMatch = jsonString.match(/```(?:json)?\s*\n([\s\S]*?)\n```/);
    if (jsonBlockMatch) {
      jsonString = jsonBlockMatch[1].trim();
    }

    try {
      const parsed = JSON.parse(jsonString);
      return schema.parse(parsed);
    } catch (error) {
      if (error instanceof z.ZodError) {
        throw new Error(
          `Schema validation failed: ${JSON.stringify(error.errors)}`
        );
      }
      throw new Error(`Failed to parse JSON: ${error}`);
    }
  }

  /**
   * 指数バックオフでリトライ実行
   */
  private async callWithRetry<T>(
    fn: () => Promise<T>,
    attempt = 0
  ): Promise<T> {
    try {
      return await fn();
    } catch (error: any) {
      // リトライ不要なエラー（認証エラー、バリデーションエラー等）
      if (
        error.status === 401 ||
        error.status === 400 ||
        error.status === 403
      ) {
        throw error;
      }

      // リトライ対象エラー（レート制限、タイムアウト、サーバーエラー）
      const isRetryable =
        error.status === 429 || // レート制限
        error.status === 500 || // サーバーエラー
        error.status === 502 ||
        error.status === 503 ||
        error.status === 504 ||
        error.code === 'ECONNABORTED' || // タイムアウト
        error.code === 'ETIMEDOUT';

      if (!isRetryable || attempt >= MAX_RETRIES) {
        throw error;
      }

      // 指数バックオフ
      const backoffMs = INITIAL_BACKOFF_MS * Math.pow(2, attempt);
      const jitter = Math.random() * 0.1 * backoffMs; // ±10% jitter
      const delayMs = backoffMs + jitter;

      await new Promise((resolve) => setTimeout(resolve, delayMs));

      return this.callWithRetry(fn, attempt + 1);
    }
  }
}

/**
 * シングルトンインスタンス取得用ヘルパー
 */
let defaultInstance: ClaudeClient | null = null;

export function getClaudeClient(options?: ClaudeClientOptions): ClaudeClient {
  if (!defaultInstance) {
    defaultInstance = new ClaudeClient(options);
  }
  return defaultInstance;
}

/**
 * シングルトンリセット用（テスト用）
 */
export function resetClaudeClient(): void {
  defaultInstance = null;
}
