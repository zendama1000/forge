/**
 * セクション生成ルート
 * POST /api/section/generate — LLMによるセールスレターセクション本文生成
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../middleware/error-handler';
import { generateSection } from '../services/section-service';
import { OutlineSection, MetaframeSubset, StyleGuide } from '../types';

// ─── Zod スキーマ ──────────────────────────────────────────────────────────────

const OutlineSectionSchema = z.object({
  index: z.number().int().min(0),
  title: z.string(),
  aida_band: z.enum(['attention', 'interest', 'desire', 'conviction', 'action']),
  target_chars: z.number().min(1),
  primary_theories: z.array(z.string()),
  key_points: z.array(z.string()).optional(),
  emotional_goal: z.string().optional(),
});

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

const MetaframeSubsetSchema = z.object({
  principles: z.array(PrincipleSchema).min(1),
  triggers: z.array(EmotionalTriggerSchema).optional(),
});

const StyleGuideSchema = z.object({
  tone: z.string(),
  target_audience: z.string(),
  writing_style: z.string().optional(),
});

const SectionGenerateBodySchema = z.object({
  /** セクションインデックス（0始まり、必須） */
  section_index: z.number().int().min(0),
  /** アウトライン全体のセクション総数（指定時は範囲バリデーションを実施） */
  total_sections: z.number().int().min(1).optional(),
  /** 生成対象セクションのアウトライン定義 */
  outline_section: OutlineSectionSchema,
  /** このセクションに適用するメタフレームのサブセット */
  metaframe_subset: MetaframeSubsetSchema,
  /** 前セクションとのオーバーラップ文脈（最初のセクションの場合は空文字列） */
  overlap_context: z.string(),
  /** スタイルガイド */
  style_guide: StyleGuideSchema,
  /** 使用するLLMモデル（省略時はPrimaryモデル） */
  model: z.string().optional(),
});

// ─── ルーター ─────────────────────────────────────────────────────────────────

const sectionRouter = Router();

/**
 * POST /api/section/generate
 * outline_section と metaframe_subset を受け取り、LLM でセクション本文を生成して返す
 *
 * バリデーション:
 *   - section_index フィールドが必須（未指定は 400 "section_index required"）
 *   - total_sections が指定された場合、section_index < total_sections であること
 *   - overlap_context は空文字列を許容（最初のセクション）
 */
sectionRouter.post(
  '/section/generate',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    // ── section_index 存在チェック（最優先） ─────────────────────────────────
    if (
      !req.body ||
      req.body.section_index === undefined ||
      req.body.section_index === null
    ) {
      res.status(400).json({ error: 'section_index required' });
      return;
    }

    // ── Zod バリデーション ─────────────────────────────────────────────────
    const parseResult = SectionGenerateBodySchema.safeParse(req.body);

    if (!parseResult.success) {
      const errors = parseResult.error.errors;
      res.status(400).json({
        error: errors.map((e) => `${e.path.join('.')}: ${e.message}`).join(', '),
      });
      return;
    }

    const {
      section_index,
      total_sections,
      outline_section,
      metaframe_subset,
      overlap_context,
      style_guide,
      model,
    } = parseResult.data;

    // ── 範囲バリデーション（total_sections が指定された場合） ──────────────
    if (total_sections !== undefined && section_index >= total_sections) {
      res.status(400).json({
        error: `section_index ${section_index} is out of range (total_sections: ${total_sections})`,
      });
      return;
    }

    // ── セクション本文生成 ─────────────────────────────────────────────────
    const result = await generateSection({
      section_index,
      outline_section: outline_section as OutlineSection,
      metaframe_subset: metaframe_subset as MetaframeSubset,
      overlap_context,
      style_guide: style_guide as StyleGuide,
      model,
    });

    res.status(200).json(result);
  }),
);

export default sectionRouter;
