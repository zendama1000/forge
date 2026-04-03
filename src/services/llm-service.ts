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

// ─── リトライ設定（テストから上書き可能） ────────────────────────────────────

/**
 * リトライ動作を制御する設定オブジェクト
 * テストでは baseDelayMs を 0 に設定することで遅延をスキップできる
 */
export const _retryConfig = {
  /** リトライ最大回数（接続エラー時）*/
  maxRetries: 3,
  /** Exponential backoff の基準遅延ミリ秒（実遅延 = baseDelayMs * 2^attempt）*/
  baseDelayMs: 1000,
};

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
  /** stop_reason === 'max_tokens' の場合 true（出力トークン制限検出） */
  truncated: boolean;
  /** LLM が返した stop_reason（'end_turn' | 'max_tokens' | 'stop_sequence' | null） */
  stop_reason: string | null;
}

// ─── ヘルパー ─────────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * リトライ対象エラーかどうか判定する
 * ネットワーク接続エラー・レートリミット・過負荷エラーをリトライ対象とする
 */
export function isRetryableError(err: unknown): boolean {
  if (!(err instanceof Error)) return false;

  // HTTP ステータスコードによる判定（Anthropic SDK は status プロパティを付与）
  const status = (err as Record<string, unknown>).status as number | undefined;
  if (status === 429 || status === 503 || status === 529) return true;

  // エラーメッセージによる判定
  const msg = err.message.toLowerCase();
  return (
    msg.includes('connection') ||
    msg.includes('network') ||
    msg.includes('econnreset') ||
    msg.includes('econnrefused') ||
    msg.includes('rate limit') ||
    msg.includes('overloaded') ||
    msg.includes('timeout') ||
    msg.includes('socket hang up') ||
    msg.includes('fetch failed')
  );
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * LLM を呼び出し、テキストレスポンスを返す汎用関数
 *
 * - 接続エラー時は exponential backoff リトライ（最大 _retryConfig.maxRetries 回）
 * - リトライ全失敗後は FALLBACK モデルへ自動切替
 * - 出力トークン制限（stop_reason === 'max_tokens'）を検出して truncated フラグを設定
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

  let lastError: unknown;

  // ── Exponential backoff リトライループ ──────────────────────────────────
  for (let attempt = 0; attempt < _retryConfig.maxRetries; attempt++) {
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

      // 出力トークン制限検出
      const truncated = response.stop_reason === 'max_tokens';
      if (truncated) {
        console.warn(
          `[LLM] Output token limit reached (stop_reason=max_tokens). ` +
            `model=${model}, maxTokens=${maxTokens}, output_tokens=${response.usage.output_tokens}`,
        );
      }

      return {
        text: content.text,
        model,
        input_tokens: response.usage.input_tokens,
        output_tokens: response.usage.output_tokens,
        truncated,
        stop_reason: response.stop_reason ?? null,
      };
    } catch (err) {
      lastError = err;

      // リトライ対象外エラー（プロンプト不正等）は即座にループを抜ける
      if (!isRetryableError(err)) {
        break;
      }

      // 最後の試行でなければ指数的バックオフで待機
      if (attempt < _retryConfig.maxRetries - 1) {
        const delay = _retryConfig.baseDelayMs * Math.pow(2, attempt);
        console.warn(
          `[LLM] Retry ${attempt + 1}/${_retryConfig.maxRetries} after ${delay}ms: ${(err as Error).message}`,
        );
        await sleep(delay);
      }
    }
  }

  // ── Fallback モデルへ切替（Primary に失敗した場合） ─────────────────────
  if (model === LLM_MODELS.PRIMARY && model !== LLM_MODELS.FALLBACK) {
    console.warn(
      `[LLM] Primary model exhausted, falling back to ${LLM_MODELS.FALLBACK}: ${(lastError as Error).message}`,
    );
    return callLLM({ ...params, model: LLM_MODELS.FALLBACK });
  }

  throw lastError;
}

/**
 * 出力トークン制限（stop_reason === 'max_tokens'）検出時にセクション分割サイズを自動調整する
 *
 * - truncated=true の場合、currentMaxTokens を 80% に縮小して返す
 * - truncated=false の場合はそのまま返す（ノーオペレーション）
 * - セクション単位生成で maxTokens を動的に縮小することで、次回生成時の切り捨てを防ぐ
 *
 * @param currentMaxTokens 現在のトークン上限（maxTokens パラメータ値）
 * @param truncated        callLLM の結果に含まれる truncated フラグ
 * @returns 調整後のトークン上限（80%縮小 or そのまま）
 */
export function getAdjustedMaxTokens(
  currentMaxTokens: number,
  truncated: boolean,
): number {
  if (!truncated) return currentMaxTokens;
  const adjusted = Math.floor(currentMaxTokens * 0.8);
  console.warn(
    `[LLM] Token limit detected (stop_reason=max_tokens). ` +
      `Adjusting maxTokens: ${currentMaxTokens} → ${adjusted} (80% reduction for section split)`,
  );
  return adjusted;
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
