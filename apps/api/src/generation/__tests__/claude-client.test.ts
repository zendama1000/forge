import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ClaudeClient, resetClaudeClient } from '../claude-client';
import { z } from 'zod';
import Anthropic from '@anthropic-ai/sdk';

// Anthropic SDKのモック
vi.mock('@anthropic-ai/sdk', () => {
  const MockAnthropic = vi.fn();
  MockAnthropic.prototype.messages = {
    create: vi.fn(),
    stream: vi.fn(),
  };
  return {
    default: MockAnthropic,
  };
});

describe('ClaudeClient', () => {
  beforeEach(() => {
    resetClaudeClient();
    vi.clearAllMocks();
    process.env.ANTHROPIC_API_KEY = 'test-api-key';
  });

  describe('constructor', () => {
    // 正常系: APIキーが環境変数から取得できる
    it('should initialize with API key from environment', () => {
      process.env.ANTHROPIC_API_KEY = 'env-api-key';
      const client = new ClaudeClient();
      expect(client).toBeDefined();
    });

    // 正常系: APIキーをオプションで渡す
    it('should initialize with API key from options', () => {
      const client = new ClaudeClient({ apiKey: 'option-api-key' });
      expect(client).toBeDefined();
    });

    // 異常系: APIキーが無い場合はエラー
    it('should throw error when API key is missing', () => {
      delete process.env.ANTHROPIC_API_KEY;
      expect(() => new ClaudeClient()).toThrow('ANTHROPIC_API_KEY is required');
    });

    // エッジケース: カスタムオプションが反映される
    it('should accept custom options', () => {
      const client = new ClaudeClient({
        apiKey: 'test-key',
        model: 'claude-3-opus-20240229',
        maxTokens: 2048,
        temperature: 0.5,
        timeout: 30000,
      });
      expect(client).toBeDefined();
    });
  });

  describe('callClaude', () => {
    // 正常系: テキスト応答を取得できる
    it('should return text response successfully', async () => {
      const mockResponse = {
        content: [
          {
            type: 'text',
            text: 'Hello, world!',
          },
        ],
      };

      const mockCreate = vi.fn().mockResolvedValue(mockResponse);
      vi.mocked(Anthropic.prototype.messages.create).mockImplementation(mockCreate);

      const client = new ClaudeClient({ apiKey: 'test-key' });
      const result = await client.callClaude('Test prompt');

      expect(result).toBe('Hello, world!');
      expect(Anthropic.prototype.messages.create).toHaveBeenCalledWith(
        expect.objectContaining({
          messages: [{ role: 'user', content: 'Test prompt' }],
        })
      );
    });

    // 正常系: システムプロンプトを含む呼び出し
    it('should include system prompt when provided', async () => {
      const mockResponse = {
        content: [{ type: 'text', text: 'Response with system' }],
      };

      const mockCreate = vi.fn().mockResolvedValue(mockResponse);
      vi.mocked(Anthropic.prototype.messages.create).mockImplementation(mockCreate);

      const client = new ClaudeClient({ apiKey: 'test-key' });
      await client.callClaude('Test', {
        systemPrompt: 'You are a helpful assistant',
      });

      expect(Anthropic.prototype.messages.create).toHaveBeenCalledWith(
        expect.objectContaining({
          system: 'You are a helpful assistant',
        })
      );
    });

    // 異常系: テキストコンテンツが無い場合はエラー
    it('should throw error when no text content in response', async () => {
      const mockResponse = {
        content: [],
      };

      vi.mocked(Anthropic.prototype.messages.create).mockResolvedValue(mockResponse);

      const client = new ClaudeClient({ apiKey: 'test-key' });
      await expect(client.callClaude('Test')).rejects.toThrow(
        'No text content in response'
      );
    });

    // リトライ: レート制限エラー（429）で3回リトライ
    it('should retry on rate limit error (429)', async () => {
      const rateLimitError = {
        status: 429,
        message: 'Rate limit exceeded',
      };
      const successResponse = {
        content: [{ type: 'text', text: 'Success after retry' }],
      };

      vi.mocked(Anthropic.prototype.messages.create)
        .mockRejectedValueOnce(rateLimitError)
        .mockRejectedValueOnce(rateLimitError)
        .mockResolvedValueOnce(successResponse);

      const client = new ClaudeClient({ apiKey: 'test-key' });
      const result = await client.callClaude('Test');

      expect(result).toBe('Success after retry');
      expect(Anthropic.prototype.messages.create).toHaveBeenCalledTimes(3);
    }, 10000);

    // リトライ: サーバーエラー（500）でリトライ
    it('should retry on server error (500)', async () => {
      const serverError = {
        status: 500,
        message: 'Internal server error',
      };
      const successResponse = {
        content: [{ type: 'text', text: 'Success after retry' }],
      };

      vi.mocked(Anthropic.prototype.messages.create)
        .mockRejectedValueOnce(serverError)
        .mockResolvedValueOnce(successResponse);

      const client = new ClaudeClient({ apiKey: 'test-key' });
      const result = await client.callClaude('Test');

      expect(result).toBe('Success after retry');
      expect(Anthropic.prototype.messages.create).toHaveBeenCalledTimes(2);
    }, 10000);

    // リトライ: 最大リトライ回数超過でエラー
    it('should throw error after max retries', async () => {
      const rateLimitError = {
        status: 429,
        message: 'Rate limit exceeded',
      };

      vi.mocked(Anthropic.prototype.messages.create).mockRejectedValue(rateLimitError);

      const client = new ClaudeClient({ apiKey: 'test-key' });
      await expect(client.callClaude('Test')).rejects.toEqual(rateLimitError);
      expect(Anthropic.prototype.messages.create).toHaveBeenCalledTimes(4); // 初回 + 3リトライ
    }, 15000);

    // リトライ不要: 認証エラー（401）で即座にエラー
    it('should not retry on authentication error (401)', async () => {
      const authError = {
        status: 401,
        message: 'Unauthorized',
      };

      vi.mocked(Anthropic.prototype.messages.create).mockRejectedValue(authError);

      const client = new ClaudeClient({ apiKey: 'test-key' });
      await expect(client.callClaude('Test')).rejects.toEqual(authError);
      expect(Anthropic.prototype.messages.create).toHaveBeenCalledTimes(1); // リトライしない
    });

    // エッジケース: カスタムモデル・パラメータを使用
    it('should use custom model and parameters', async () => {
      const mockResponse = {
        content: [{ type: 'text', text: 'Custom response' }],
      };

      const mockCreate = vi.fn().mockResolvedValue(mockResponse);
      vi.mocked(Anthropic.prototype.messages.create).mockImplementation(mockCreate);

      const client = new ClaudeClient({ apiKey: 'test-key' });
      await client.callClaude('Test', {
        model: 'claude-3-opus-20240229',
        maxTokens: 2048,
        temperature: 0.5,
      });

      expect(Anthropic.prototype.messages.create).toHaveBeenCalledWith(
        expect.objectContaining({
          model: 'claude-3-opus-20240229',
          max_tokens: 2048,
          temperature: 0.5,
        })
      );
    });
  });

  describe('parseStructuredResponse', () => {
    const TestSchema = z.object({
      name: z.string(),
      age: z.number(),
    });

    // 正常系: 正しいJSONをパースできる
    it('should parse valid JSON successfully', () => {
      const client = new ClaudeClient({ apiKey: 'test-key' });
      const response = JSON.stringify({ name: 'Alice', age: 30 });
      const result = client.parseStructuredResponse(response, TestSchema);

      expect(result).toEqual({ name: 'Alice', age: 30 });
    });

    // 正常系: コードブロック内のJSONをパースできる
    it('should parse JSON inside code block', () => {
      const client = new ClaudeClient({ apiKey: 'test-key' });
      const response = '```json\n{"name": "Bob", "age": 25}\n```';
      const result = client.parseStructuredResponse(response, TestSchema);

      expect(result).toEqual({ name: 'Bob', age: 25 });
    });

    // 正常系: 言語指定なしのコードブロック
    it('should parse JSON inside code block without language', () => {
      const client = new ClaudeClient({ apiKey: 'test-key' });
      const response = '```\n{"name": "Charlie", "age": 35}\n```';
      const result = client.parseStructuredResponse(response, TestSchema);

      expect(result).toEqual({ name: 'Charlie', age: 35 });
    });

    // 異常系: スキーマバリデーションエラー
    it('should throw error on schema validation failure', () => {
      const client = new ClaudeClient({ apiKey: 'test-key' });
      const response = JSON.stringify({ name: 'Dave', age: 'invalid' });

      expect(() =>
        client.parseStructuredResponse(response, TestSchema)
      ).toThrow('Schema validation failed');
    });

    // 異常系: 不正なJSON
    it('should throw error on invalid JSON', () => {
      const client = new ClaudeClient({ apiKey: 'test-key' });
      const response = 'This is not JSON';

      expect(() =>
        client.parseStructuredResponse(response, TestSchema)
      ).toThrow('Failed to parse JSON');
    });

    // エッジケース: 空白文字を含むJSON
    it('should handle JSON with extra whitespace', () => {
      const client = new ClaudeClient({ apiKey: 'test-key' });
      const response = '  \n  {"name": "Eve", "age": 40}  \n  ';
      const result = client.parseStructuredResponse(response, TestSchema);

      expect(result).toEqual({ name: 'Eve', age: 40 });
    });

    // エッジケース: 複雑なネストしたスキーマ
    it('should handle nested schema', () => {
      const NestedSchema = z.object({
        user: z.object({
          name: z.string(),
          age: z.number(),
        }),
        active: z.boolean(),
      });

      const client = new ClaudeClient({ apiKey: 'test-key' });
      const response = JSON.stringify({
        user: { name: 'Frank', age: 45 },
        active: true,
      });
      const result = client.parseStructuredResponse(response, NestedSchema);

      expect(result).toEqual({
        user: { name: 'Frank', age: 45 },
        active: true,
      });
    });
  });
});
