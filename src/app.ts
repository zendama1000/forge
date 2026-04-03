import express, { Application, Request, Response } from 'express';
import { errorHandler } from './middleware/error-handler';

const app: Application = express();

// ─── ミドルウェア ─────────────────────────────────────────────────────────────

// JSON パーサー（理論ファイル最大10MB）
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// デフォルト Content-Type ヘッダー
app.use((_req: Request, res: Response, next) => {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  next();
});

// リクエストロギング
app.use((req: Request, _res: Response, next) => {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${req.method} ${req.path}`);
  next();
});

// ─── ルート ───────────────────────────────────────────────────────────────────

// GET /api/health — ヘルスチェック
app.get('/api/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// ─── エラーハンドラー（最後に登録） ─────────────────────────────────────────
app.use(errorHandler);

export default app;
