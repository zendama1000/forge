/**
 * ヘルスチェックルート
 * GET /api/health → 200 + { status: 'ok' }
 */

import { Router, Request, Response } from 'express';

const healthRouter = Router();

// GET /health — ヘルスチェックエンドポイント
healthRouter.get('/health', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok' });
});

export default healthRouter;
