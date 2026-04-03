/**
 * アウトライン生成ルート
 * POST /api/outline/generate — LLMによるAIDA5帯域アウトライン生成
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../middleware/error-handler';
import { generateOutline } from '../services/outline-service';
import { Metaframe, OutlineGenerationConfig } from '../types';

// ─── Zod スキーマ ──────────────────────────────────────────────────────────────

const PrincipleSchema = z.object({
  name: z.string(),
  description: z.string(),
  application_trigger: z.string(),
  source_theory_ids: z.array(z.string()).optional(),
});

const EmotionalTriggerSchema = z.object({
  name: z.string(),
  mechanism: z.string(),
  intensity: z.enum(['low', 'medium', 'high']),
});

const SectionMappingSchema = z.object({
  aida_band: z.string(),
  recommended_principles: z.array(z.string()),
  emotional_flow: z.string(),
});

const MetaframeSchema = z.object({
  principles: z.array(PrincipleSchema),
  triggers: z.array(EmotionalTriggerSchema),
  section_mappings: z.array(SectionMappingSchema),
  extracted_at: z.string().optional(),
  source_theory_ids: z.array(z.string()).optional(),
});

const OutlineGenerateBodySchema = z.object({
  metaframe: MetaframeSchema,
  config: z
    .object({
      total_chars: z.number().min(1000).default(20000),
      copy_framework: z
        .enum(['PAS_PPPP_HYBRID', 'AIDA', 'PAS', 'PPPP'])
        .default('PAS_PPPP_HYBRID'),
      overlap_chars: z.number().optional(),
    })
    .default({}),
});

// ─── ルーター ─────────────────────────────────────────────────────────────────

const outlineRouter = Router();

/**
 * POST /api/outline/generate
 * metaframe と config を受け取り、LLM で AIDA5帯域アウトラインを生成して返す
 *
 * バリデーション:
 *   - metaframe フィールドが必須（未指定は 400 "metaframe required"）
 *   - config.copy_framework: デフォルト 'PAS_PPPP_HYBRID'
 *   - config.total_chars: デフォルト 20000
 */
outlineRouter.post(
  '/outline/generate',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    // ── metaframe 存在チェック（最優先） ────────────────────────────────────
    if (!req.body || req.body.metaframe === undefined || req.body.metaframe === null) {
      res.status(400).json({ error: 'metaframe required' });
      return;
    }

    // ── Zod バリデーション ─────────────────────────────────────────────────
    const parseResult = OutlineGenerateBodySchema.safeParse(req.body);

    if (!parseResult.success) {
      const errors = parseResult.error.errors;
      res.status(400).json({
        error: errors.map((e) => `${e.path.join('.')}: ${e.message}`).join(', '),
      });
      return;
    }

    const { metaframe, config } = parseResult.data;

    // ── アウトライン生成 ───────────────────────────────────────────────────
    const outline = await generateOutline({
      metaframe: metaframe as Metaframe,
      config: {
        total_chars: config.total_chars,
        copy_framework: config.copy_framework as OutlineGenerationConfig['copy_framework'],
        overlap_chars: config.overlap_chars,
      },
    });

    res.status(200).json(outline);
  }),
);

export default outlineRouter;
