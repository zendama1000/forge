/**
 * ブランドコンセプト CRUD ルート
 * POST /  → 新規コンセプト作成（201 + concept_id）
 * GET /:id → ID でコンセプト取得（200 or 404）
 */

import { Hono } from 'hono';
import { validateCore } from '../../schemas/core-validator';
import { createConcept, getConcept } from '../store';

const conceptRouter = new Hono();

/**
 * POST / — ブランドコンセプト新規作成
 * - バリデーション失敗 → 400 + errors 配列（欠落フィールド名を含む）
 * - 不正 JSON → 400 + パースエラーメッセージ
 * - 成功 → 201 + concept_id
 */
conceptRouter.post('/', async (c) => {
  let body: unknown;
  try {
    body = await c.req.json<unknown>();
  } catch {
    return c.json(
      { error: 'Bad Request', message: 'JSON parse error: invalid JSON body' },
      400,
    );
  }

  const result = validateCore(body);
  if (!result.valid) {
    return c.json({ errors: result.errors }, 400);
  }

  const entry = createConcept(body as Record<string, unknown>);
  return c.json({ concept_id: entry.concept_id, created_at: entry.created_at }, 201);
});

/**
 * GET /:id — concept_id でコンセプトを取得
 * - 存在しない ID → 404 + error メッセージ
 * - 存在する → 200 + エントリ全体
 */
conceptRouter.get('/:id', (c) => {
  const id = c.req.param('id');
  const entry = getConcept(id);
  if (!entry) {
    return c.json({ error: `Concept not found: ${id}` }, 404);
  }
  return c.json(entry);
});

export default conceptRouter;
