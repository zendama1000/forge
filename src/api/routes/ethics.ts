/**
 * 倫理バリデーションルート
 * POST /validate — テキストの禁止表現を検出する（ルールベース第1段ゲート）
 *
 * Content-Type: application/json が必須。未指定・非JSON → 415
 * 不正 JSON → 400
 * 正常 → 200 + violations 配列
 */

import { Hono } from 'hono';
import { detectViolations } from '../../ethics/expression-detector';

const ethicsRouter = new Hono();

/**
 * POST /validate — 倫理チェック
 * リクエストボディ: { text: string }
 * レスポンス: { violations: ViolationResult[] }
 */
ethicsRouter.post('/validate', async (c) => {
  // Content-Type チェック（application/json 以外 → 415）
  const contentType = c.req.header('Content-Type');
  if (!contentType || !contentType.includes('application/json')) {
    return c.json({ error: 'Unsupported Media Type' }, 415);
  }

  // JSON パース
  let body: unknown;
  try {
    body = await c.req.json<unknown>();
  } catch {
    return c.json(
      { error: 'Bad Request', message: 'JSON parse error: invalid JSON body' },
      400,
    );
  }

  // text フィールドの存在チェック
  if (
    typeof body !== 'object' ||
    body === null ||
    typeof (body as Record<string, unknown>).text !== 'string'
  ) {
    return c.json(
      { error: 'Bad Request', message: 'text field is required and must be a string' },
      400,
    );
  }

  const text = (body as { text: string }).text;
  const result = detectViolations(text);

  return c.json({ violations: result.violations });
});

export default ethicsRouter;
