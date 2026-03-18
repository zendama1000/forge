/**
 * LLM出力のマークダウンコードブロックを除去するプリプロセッサ
 * Qwen/OPENAI_MODEL/LLM_MODEL 対応
 */

/**
 * LLM出力から```json...```や```...```の囲みを除去し、
 * コードブロック内のコンテンツのみを返す。
 * コードブロックが存在しない場合は入力をそのまま返す。
 */
export function removeCodeBlock(input: string): string {
  if (!input) {
    return input;
  }

  // ```json ... ``` または ``` ... ``` にマッチ（複数行、最初のブロックを抽出）
  const codeBlockRegex = /```(?:\w+)?\n([\s\S]*?)```/;
  const match = input.match(codeBlockRegex);

  if (match) {
    return match[1].trim();
  }

  return input;
}
