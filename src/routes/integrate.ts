/**
 * セクション統合ルート
 * POST /api/integrate — LLMによる継ぎ目調整・セクション統合
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../middleware/error-handler';
import { integrateSections } from '../services/integrate-service';

// ─── Zod スキーマ ──────────────────────────────────────────────────────────────

const GeneratedSectionSchema = z.object({
  index: z.number().int().min(0),
  content: z.string(),
});

const IntegrateBodySchema = z.object({
  sections: z.array(GeneratedSectionSchema),
  model: z.string().optional(),
});

// ─── ルーター ─────────────────────────────────────────────────────────────────

const integrateRouter = Router();

/**
 * POST /api/integrate
 * sections配列を受け取り、LLMで継ぎ目調整・統合してセールスレターを返す
 *
 * バリデーション:
 *   - sections が空配列 → 400 "at least one section required"
 *   - sections 内の要素に content が空のものがある → 400 + section_index 付きエラー
 */
integrateRouter.post(
  '/integrate',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    // ── Zod バリデーション ─────────────────────────────────────────────────
    const parseResult = IntegrateBodySchema.safeParse(req.body);

    if (!parseResult.success) {
      const errors = parseResult.error.errors;
      res.status(400).json({
        error: errors.map((e) => `${e.path.join('.')}: ${e.message}`).join(', '),
      });
      return;
    }

    const { sections, model } = parseResult.data;

    // ── 空配列チェック ─────────────────────────────────────────────────────
    if (sections.length === 0) {
      res.status(400).json({ error: 'at least one section required' });
      return;
    }

    // ── 各要素の content 空チェック ────────────────────────────────────────
    for (const section of sections) {
      if (section.content.trim().length === 0) {
        res.status(400).json({
          error: `section at index ${section.index} has empty content`,
          section_index: section.index,
        });
        return;
      }
    }

    // ── セクション統合 ─────────────────────────────────────────────────────
    const result = await integrateSections(sections, model);

    res.status(200).json(result);
  }),
);

export default integrateRouter;
