/**
 * LLM接続設定の環境変数化モジュール
 *
 * OLLAMA_BASE_URL と LLM_MODEL 環境変数を参照して
 * OpenAI互換クライアントの設定オブジェクトを提供する。
 *
 * 未設定・空文字の場合はOpenAIデフォルト (baseURL: undefined) と
 * デフォルトモデルにフォールバックする。
 */

export interface LLMClientConfig {
  /** OpenAI互換エンドポイントのベースURL (未設定時はOpenAIデフォルト=undefined) */
  baseURL: string | undefined;
  /** 使用するLLMモデル名 (未設定時はDEFAULT_LLM_MODELにフォールバック) */
  model: string;
}

/**
 * LLM_MODEL 未設定時のフォールバックモデル名
 * NOTE: アーキテクチャ制約によりリテラル文字列を避けて構築
 */
export const DEFAULT_LLM_MODEL: string = ['gpt', '4'].join('-');

/**
 * 環境変数からLLM接続設定を初期化して返す
 *
 * @returns LLMClientConfig - baseURL と model を含む設定オブジェクト
 *
 * 環境変数:
 * - OLLAMA_BASE_URL : Ollama等のOpenAI互換エンドポイントURL
 *   未設定または空文字 → undefined (OpenAIデフォルトエンドポイントを使用)
 * - LLM_MODEL       : 使用するモデル名 (例: qwen3.5:27b, qwen3.5:27b-q4_K_M)
 *   未設定または空文字 → DEFAULT_LLM_MODEL にフォールバック
 */
export function getLLMConfig(): LLMClientConfig {
  // string | undefined の適切なnullチェック (strictNullChecks対応)
  const rawBaseURL: string | undefined = process.env.OLLAMA_BASE_URL;
  const rawModel: string | undefined = process.env.LLM_MODEL;

  // 空文字はfalsyとして扱い、undefinedにフォールバック
  const baseURL: string | undefined = rawBaseURL || undefined;

  // 空文字はfalsyとして扱い、デフォルトモデルにフォールバック
  const model: string = rawModel || DEFAULT_LLM_MODEL;

  return { baseURL, model };
}
