/**
 * パイプラインオーケストレーションルート
 * POST /api/letter/generate  — フルパイプライン実行（Phase A→B→C→D）
 * GET  /api/letter/status/:pipeline_id — ステータス取得
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../middleware/error-handler';
import { runPipeline, getPipelineState } from '../services/pipeline-service';

// ─── デフォルトモデル ─────────────────────────────────────────────────────────

const DEFAULT_MODEL = 'claude-sonnet-4-6';

// ─── Zod スキーマ ──────────────────────────────────────────────────────────────

const TheoryFileSchema = z.object({
  id: z.string().min(1, 'theory file id is required'),
  title: z.string().min(1, 'theory file title is required'),
  content: z.string().min(1, 'theory file content is required'),
  metadata: z.record(z.unknown()).optional(),
});

const StyleGuideSchema = z.object({
  tone: z.string().min(1, 'style_guide.tone is required'),
  target_audience: z.string().min(1, 'style_guide.target_audience is required'),
  writing_style: z.string().optional(),
});

const PipelineConfigSchema = z.object({
  total_chars: z.number().int().min(1000, 'total_chars must be at least 1000'),
  copy_framework: z.enum(['PAS_PPPP_HYBRID', 'AIDA', 'PAS', 'PPPP']),
  style_guide: StyleGuideSchema,
  model: z.string().optional(),
  metaframe_target_tokens: z.number().int().optional(),
  quality_threshold: z.number().optional(),
  max_rewrite_attempts: z.number().int().optional(),
});

const ProductInfoSchema = z.object({
  name: z.string().min(1, 'product_info.name is required'),
  price: z.string().optional(),
  features: z.array(z.string()).min(1, 'product_info.features must contain at least one item'),
  target_audience: z.string().optional(),
  benefits: z.array(z.string()).optional(),
  offer_details: z.string().optional(),
  cta_text: z.string().optional(),
});

const GenerateBodySchema = z.object({
  theory_files: z.array(TheoryFileSchema).min(1, 'theory_files must contain at least one file'),
  config: PipelineConfigSchema,
  product_info: ProductInfoSchema,
});

// ─── ルーター ─────────────────────────────────────────────────────────────────

const pipelineRouter = Router();

/**
 * POST /api/letter/generate
 * フルパイプライン実行（Phase A → B → C → D）
 * 必須フィールド: theory_files, config, product_info
 * config.model 未指定時は claude-sonnet-4-6 をデフォルト適用
 */
pipelineRouter.post(
  '/letter/generate',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    // ── 必須フィールド早期チェック ──────────────────────────────────────────
    if (!req.body || req.body.theory_files === undefined) {
      res.status(400).json({ error: 'theory_files is required' });
      return;
    }

    if (req.body.config === undefined) {
      res.status(400).json({ error: 'config is required' });
      return;
    }

    if (req.body.product_info === undefined) {
      res.status(400).json({ error: 'product_info is required' });
      return;
    }

    // ── Zod スキーマバリデーション ─────────────────────────────────────────
    const parseResult = GenerateBodySchema.safeParse(req.body);
    if (!parseResult.success) {
      const errors = parseResult.error.errors;
      res.status(400).json({
        error: errors.map((e) => `${e.path.join('.')}: ${e.message}`).join(', '),
      });
      return;
    }

    const { theory_files, config, product_info } = parseResult.data;

    // ── デフォルトモデル適用 ────────────────────────────────────────────────
    const configWithModel = {
      ...config,
      model: config.model ?? DEFAULT_MODEL,
    };

    // ── パイプライン実行（同期的に完了を待つ） ──────────────────────────────
    const state = await runPipeline({
      theory_files,
      product_info,
      config: configWithModel,
    });

    res.status(200).json(state);
  }),
);

/**
 * GET /api/letter/status/:pipeline_id
 * パイプラインステータス取得
 * phase (A/B/C/D)・progress (0-100)・status (pending/running/completed/failed) を返す
 * 存在しない pipeline_id → 404
 */
pipelineRouter.get(
  '/letter/status/:pipeline_id',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    const { pipeline_id } = req.params;

    const state = getPipelineState(pipeline_id);

    if (!state) {
      res.status(404).json({ error: `Pipeline ${pipeline_id} not found` });
      return;
    }

    res.status(200).json(state);
  }),
);

export default pipelineRouter;
