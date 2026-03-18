/**
 * ヘルスチェックルート
 * GET /api/health → 200 + { status: 'ok', ... }
 */

import { Hono } from 'hono';

const healthRouter = new Hono();

// GET /health — ヘルスチェックエンドポイント
healthRouter.get('/health', (c) => {
  return c.json({
    status: 'ok',
    service: 'brand-toolkit',
    timestamp: new Date().toISOString(),
  });
});

export default healthRouter;
