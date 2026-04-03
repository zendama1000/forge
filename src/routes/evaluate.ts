/**
 * 品質評価ルート
 * POST /api/evaluate — LLMによる4次元ルーブリック評価
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../middleware/error-handler';
import { evaluateLetter } from '../services/evaluate-service';

// ─── Zod スキーマ ──────────────────────────────────────────────────────────────

const EvaluateBodySchema = z.object({
  /** 評価対象のセールスレター本文（必須・空文字列不可） */
  letter_text: z.string(),
  /** カスタムルーブリック設定（省略時はデフォルト使用） */
  rubric: z.record(z.unknown()).optional(),
  /** 使用するLLMモデル（省略時はPrimaryモデル） */
  model: z.string().optional(),
});

// ─── ルーター ─────────────────────────────────────────────────────────────────

const evaluateRouter = Router();

/**
 * POST /api/evaluate
 * セールスレターを4次元ルーブリックで評価してスコアを返す
 *
 * バリデーション:
 *   - letter_text が未指定 → 400 (Zodバリデーションエラー)
 *   - letter_text が空文字列（空白のみ含む） → 400 "letter_text must not be empty"
 */
evaluateRouter.post(
  '/evaluate',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    // ── Zod バリデーション ─────────────────────────────────────────────────
    const parseResult = EvaluateBodySchema.safeParse(req.body);

    if (!parseResult.success) {
      const errors = parseResult.error.errors;
      res.status(400).json({
        error: errors.map((e) => `${e.path.join('.')}: ${e.message}`).join(', '),
      });
      return;
    }

    const { letter_text, rubric, model } = parseResult.data;

    // ── 空文字列チェック ───────────────────────────────────────────────────
    if (letter_text.trim().length === 0) {
      res.status(400).json({ error: 'letter_text must not be empty' });
      return;
    }

    // ── 品質評価 ───────────────────────────────────────────────────────────
    const result = await evaluateLetter(letter_text, rubric, model);

    res.status(200).json(result);
  }),
);

export default evaluateRouter;
