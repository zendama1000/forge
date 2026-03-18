/**
 * Layer 2 統合テスト: Ollama Streaming (L2-001)
 *
 * 前提条件:
 * - OLLAMA_BASE_URL=http://localhost:11434/v1 が設定済み
 * - LLM_MODEL=qwen3.5:27b が設定済み
 * - Ollamaサービスが起動済み、対象モデルが pull 済み
 *
 * このテストは Phase 3 でサーバー起動済みを前提として実行される。
 * サーバーが未起動またはenv未設定の場合はスキップされる。
 *
 * 実行コマンド:
 *   OLLAMA_BASE_URL=http://localhost:11434/v1 LLM_MODEL=qwen3.5:27b \
 *     npx vitest run src/test/integration/ollama-stream.test.ts
 */

import { describe, it, expect } from 'vitest';
import { getLLMConfig } from '../../lib/llm/client';

const ollamaAvailable = !!(
  process.env.OLLAMA_BASE_URL && process.env.LLM_MODEL
);

describe.skipIf(!ollamaAvailable)('Ollama Streaming Integration (L2-001)', () => {
  it('OLLAMA_BASE_URLとLLM_MODELの設定でOllamaエンドポイントに接続し非ストリームレスポンスを受信できる', async () => {
    const config = getLLMConfig();

    // 環境変数が正しく反映されていることを確認
    expect(config.baseURL).toBe('http://localhost:11434/v1');
    expect(config.model).toContain('qwen');

    // Ollama OpenAI互換エンドポイントへの接続テスト (stream: false)
    const response = await fetch(`${config.baseURL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: config.model,
        messages: [{ role: 'user', content: '「OK」とだけ返答してください' }],
        stream: false,
        max_tokens: 20,
      }),
    });

    expect(response.status).toBe(200);

    const data = (await response.json()) as {
      choices: Array<{ message: { role: string; content: string } }>;
      model: string;
    };

    expect(data).toHaveProperty('choices');
    expect(Array.isArray(data.choices)).toBe(true);
    expect(data.choices.length).toBeGreaterThan(0);
    expect(data.choices[0]).toHaveProperty('message');
    expect(typeof data.choices[0].message.content).toBe('string');
  }, 60_000); // Ollama初回応答は時間がかかる場合があるため60秒タイムアウト

  it('ストリーミングモードでOllamaからServer-Sent Events形式のチャンクを受信できる', async () => {
    const config = getLLMConfig();

    const response = await fetch(`${config.baseURL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: config.model,
        messages: [{ role: 'user', content: '「OK」とだけ返答してください' }],
        stream: true,
        max_tokens: 20,
      }),
    });

    expect(response.status).toBe(200);

    // Server-Sent Events ストリームの読み取り
    expect(response.body).not.toBeNull();
    const reader = response.body!.getReader();
    const decoder = new TextDecoder();

    let firstChunk = '';
    let receivedData = false;

    try {
      // 最初のデータチャンクを読み取る
      const { value, done } = await reader.read();
      expect(done).toBe(false);
      expect(value).toBeDefined();

      if (value) {
        firstChunk = decoder.decode(value, { stream: true });
        // SSE形式: 各行は "data: {...}" または "data: [DONE]"
        expect(firstChunk).toMatch(/^data:/m);
        receivedData = true;
      }
    } finally {
      await reader.cancel();
    }

    expect(receivedData).toBe(true);
    expect(firstChunk.length).toBeGreaterThan(0);
  }, 60_000); // 60秒タイムアウト

  it('モデル名にOllama固有のタグ形式(qwen3.5:27b)を使用して正常にリクエストできる', async () => {
    const config = getLLMConfig();

    // qwen形式のモデル名がリクエストでそのまま使われること
    expect(config.model).toBe(process.env.LLM_MODEL);

    const response = await fetch(`${config.baseURL}/models`, {
      method: 'GET',
      headers: {
        'Content-Type': 'application/json',
      },
    });

    // モデル一覧エンドポイントが応答すること
    expect(response.status).toBe(200);
    const data = (await response.json()) as { data?: unknown[]; models?: unknown[] };

    // Ollamaは "data" または "models" フィールドでモデル一覧を返す
    const modelList = data.data ?? data.models ?? [];
    expect(Array.isArray(modelList)).toBe(true);
  }, 30_000);
});
