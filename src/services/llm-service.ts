import Anthropic from '@anthropic-ai/sdk';

// ─── クライアント初期化 ───────────────────────────────────────────────────────

const client = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY,
});

// ─── モデル定数 ──────────────────────────────────────────────────────────────

export const LLM_MODELS = {
  /** Primary: Claude Sonnet 4.6 (64K output tokens) */
  PRIMARY: process.env.LLM_PRIMARY_MODEL ?? 'claude-sonnet-4-5',
  /** Fallback: Claude Opus 4.6 (128K output tokens) */
  FALLBACK: process.env.LLM_FALLBACK_MODEL ?? 'claude-opus-4-5',
} as const;

// ─── 型定義 ──────────────────────────────────────────────────────────────────

export interface LLMCallParams {
  prompt: string;
  model?: string;
  maxTokens?: number;
  systemPrompt?: string;
}

export interface LLMCallResult {
  text: string;
  model: string;
  input_tokens: number;
  output_tokens: number;
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * LLM を呼び出し、テキストレスポンスを返す汎用関数
 * 失敗時はフォールバックモデルに自動切替
 */
export async function callLLM(params: LLMCallParams): Promise<LLMCallResult> {
  const {
    prompt,
    model = LLM_MODELS.PRIMARY,
    maxTokens = 8192,
    systemPrompt,
  } = params;

  const messages: Anthropic.Messages.MessageParam[] = [
    { role: 'user', content: prompt },
  ];

  try {
    const response = await client.messages.create({
      model,
      max_tokens: maxTokens,
      ...(systemPrompt ? { system: systemPrompt } : {}),
      messages,
    });

    const content = response.content[0];
    if (content.type !== 'text') {
      throw new Error(`Unexpected content type: ${content.type}`);
    }

    return {
      text: content.text,
      model,
      input_tokens: response.usage.input_tokens,
      output_tokens: response.usage.output_tokens,
    };
  } catch (err) {
    // フォールバックモデルへ切替（primaryと異なる場合のみ）
    if (model === LLM_MODELS.PRIMARY && model !== LLM_MODELS.FALLBACK) {
      console.warn(`[LLM] Primary model failed, falling back to ${LLM_MODELS.FALLBACK}:`, (err as Error).message);
      return callLLM({ ...params, model: LLM_MODELS.FALLBACK });
    }
    throw err;
  }
}

/**
 * LLM を呼び出し、JSON パース済みのオブジェクトを返す
 */
export async function callLLMJson<T>(params: LLMCallParams): Promise<T> {
  const result = await callLLM(params);

  // コードブロック除去
  const cleaned = result.text
    .replace(/^```(?:json)?\s*/m, '')
    .replace(/\s*```$/m, '')
    .trim();

  try {
    return JSON.parse(cleaned) as T;
  } catch {
    throw new Error(`LLM response is not valid JSON: ${cleaned.slice(0, 200)}`);
  }
}

export { client };
