import express, { Application, Request, Response } from 'express';
import { errorHandler } from './middleware/error-handler';
import healthRouter from './routes/health';
import theoryRouter from './routes/theory';
import metaframeRouter from './routes/metaframe';
import outlineRouter from './routes/outline';
import sectionRouter from './routes/section';
import integrateRouter from './routes/integrate';
import evaluateRouter from './routes/evaluate';
import productRouter from './routes/product';

const app: Application = express();

// ─── ミドルウェア ─────────────────────────────────────────────────────────────

// JSON パーサー（理論ファイル最大10MB）
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Content-Type: application/json 強制ミドルウェア
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

// ヘルスチェックルート登録（GET /api/health）
app.use('/api', healthRouter);

// 理論ファイルアップロードルート登録（POST /api/theory/upload）
app.use('/api', theoryRouter);

// メタフレーム抽出ルート登録（POST /api/metaframe/extract, GET /api/metaframe/latest）
app.use('/api', metaframeRouter);

// アウトライン生成ルート登録（POST /api/outline/generate）
app.use('/api', outlineRouter);

// セクション生成ルート登録（POST /api/section/generate）
app.use('/api', sectionRouter);

// セクション統合ルート登録（POST /api/integrate）
app.use('/api', integrateRouter);

// 品質評価ルート登録（POST /api/evaluate）
app.use('/api', evaluateRouter);

// 商品情報後差し注入ルート登録（POST /api/product/inject）
app.use('/api', productRouter);

// ─── 405 ハンドラー（既知パスへの不正メソッド） ──────────────────────────────

// POST/PUT/DELETE 等の不正メソッドで /api/health にアクセスした場合
app.all('/api/health', (_req: Request, res: Response) => {
  res.status(405).json({ error: 'Method Not Allowed' });
});

// ─── 404 ハンドラー（未定義パス） ─────────────────────────────────────────────

app.use((_req: Request, res: Response) => {
  res.status(404).json({ error: 'Not Found' });
});

// ─── エラーハンドラー（最後に登録） ─────────────────────────────────────────
app.use(errorHandler);

export default app;
