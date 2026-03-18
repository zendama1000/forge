/**
 * Brand Toolkit Application
 * 占いスピリチュアル系サービスのブランド構築ツールキット
 * Hono フレームワーク使用（http://localhost:3001）
 */

import { Hono } from 'hono';
import healthRouter from './api/routes/health';
import conceptRouter from './api/routes/concept';
import ethicsRouter from './api/routes/ethics';

const app = new Hono();

// ─── リクエストロギングミドルウェア ────────────────────────────────────────
app.use('*', async (c, next) => {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${c.req.method} ${c.req.path}`);
  await next();
});

// ─── ルート登録 ─────────────────────────────────────────────────────────────
// GET  /api/health
app.route('/api', healthRouter);

// POST /api/brand/concept
// GET  /api/brand/concept/:id
app.route('/api/brand/concept', conceptRouter);

// POST /api/brand/ethics/validate
app.route('/api/brand/ethics', ethicsRouter);

// ─── 404 ハンドラ ────────────────────────────────────────────────────────────
app.notFound((c) => {
  return c.json({ error: 'Not Found' }, 404);
});

// ─── グローバルエラーハンドラ ────────────────────────────────────────────────
app.onError((err, c) => {
  console.error('[Error]', err.message);
  return c.json({ error: 'Internal Server Error' }, 500);
});

export default app;
