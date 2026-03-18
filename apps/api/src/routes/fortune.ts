/**
 * Fortune API Route
 *
 * POST /api/fortune - 7次元パラメータを受け取り占い結果を返す
 *
 * - ZodスキーマによるリクエストバリデーションしてMockLLMを呼び出す
 * - FortuneRequest型はz.infer<typeof FortuneRequestSchema>から推論される
 */

import { Hono } from 'hono';
import { FortuneRequestSchema, type FortuneRequest } from '../schemas/fortune-request.js';
import { FortuneResponseSchema } from '../schemas/fortune-response.js';
import { createLLMProvider } from '../providers/llm-provider.js';
import { addHistoryEntry } from '../store/fortune-history.js';

const fortune = new Hono();

// ─── GET / → 405 Method Not Allowed ──────────────────────────────────────────

fortune.get('/', (c) => {
  return c.json({ error: 'Method Not Allowed' }, 405);
});

// ─── POST / → 占い実行 ────────────────────────────────────────────────────────

fortune.post('/', async (c) => {
  // Content-Type チェック（application/json 必須）
  const contentType = c.req.header('Content-Type') ?? '';
  if (!contentType.includes('application/json')) {
    return c.json(
      { error: 'Content-Type: application/json が必要です' },
      415,
    );
  }

  // JSONパース
  let body: unknown;
  try {
    body = await c.req.json();
  } catch (_e) {
    return c.json({ error: 'リクエストボディのJSONパースに失敗しました' }, 400);
  }

  // Zodバリデーション
  const validationResult = FortuneRequestSchema.safeParse(body);
  if (!validationResult.success) {
    return c.json(
      {
        error: 'バリデーションエラー',
        issues: validationResult.error.issues,
      },
      400,
    );
  }

  // LLM呼び出し（MockLLMProvider使用）
  // FortuneRequest型はz.infer<typeof FortuneRequestSchema>から推論された型を使用
  const input: FortuneRequest = validationResult.data;

  try {
    const llmProvider = createLLMProvider({ useMock: true });
    const rawOutput = await llmProvider.generate(input);
    const parsedOutput = JSON.parse(rawOutput);
    const response = FortuneResponseSchema.parse(parsedOutput);

    // 履歴ストアに保存（categories概要のみ）
    addHistoryEntry(
      response.categories.map((cat) => ({
        name: cat.name,
        totalScore: cat.totalScore,
        templateText: cat.templateText,
      })),
    );

    return c.json(response, 200);
  } catch (_e) {
    return c.json({ error: 'Internal server error' }, 500);
  }
});

export default fortune;
