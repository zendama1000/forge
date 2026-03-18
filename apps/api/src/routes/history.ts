/**
 * Fortune History API Route
 *
 * GET /api/fortune/history - インメモリストアから占い履歴を返す
 *
 * - createdAt 降順（最新順）でソートされたエントリ配列を返す
 * - POST は 405 Method Not Allowed
 */

import { Hono } from 'hono';
import { getHistory } from '../store/fortune-history.js';

const history = new Hono();

// ─── GET / → 履歴一覧 ─────────────────────────────────────────────────────────

history.get('/', (c) => {
  const entries = getHistory();
  return c.json(entries, 200);
});

// ─── POST / → 405 Method Not Allowed ─────────────────────────────────────────

history.post('/', (c) => {
  return c.json({ error: 'Method Not Allowed' }, 405);
});

export default history;
