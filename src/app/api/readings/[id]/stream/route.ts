/**
 * GET /api/readings/[id]/stream
 *
 * Node.js Runtime でのSSEストリーミングAPIルート
 *
 * Edge Runtimeを使用しないことで、src/lib/llm/client.ts 経由での
 * 環境変数ベースのLLM接続（OLLAMA_BASE_URL, LLM_MODEL）が可能になる。
 *
 * 環境変数:
 * - OLLAMA_BASE_URL : Ollama等のOpenAI互換エンドポイントURL
 * - LLM_MODEL       : 使用するモデル名 (例: qwen3.5:27b)
 */

// Edge Runtimeではなく Node.js Runtimeを使用する
export const runtime = 'nodejs';

import { getLLMConfig } from '../../../../../lib/llm/client';

/**
 * GET ハンドラー: SSEストリームを返す
 */
export async function GET(
  _request: Request,
  { params }: { params: { id: string } }
): Promise<Response> {
  const { id } = params;

  // 環境変数ベースのLLMクライアント設定を取得 (LLM_MODEL参照)
  const config = getLLMConfig();

  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    async start(controller): Promise<void> {
      const sendEvent = (data: string): void => {
        controller.enqueue(encoder.encode(`data: ${data}\n\n`));
      };

      try {
        // 読み込み開始イベントを送信 (LLM設定情報を含む)
        sendEvent(
          JSON.stringify({
            type: 'start',
            readingId: id,
            model: config.model,
          })
        );

        // ストリーム完了シグナル
        sendEvent('[DONE]');
      } catch (error) {
        const message =
          error instanceof Error ? error.message : 'Unknown error';
        sendEvent(JSON.stringify({ type: 'error', message }));
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    },
  });
}
