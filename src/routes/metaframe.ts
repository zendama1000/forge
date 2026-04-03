/**
 * メタフレーム抽出ルート
 * POST /api/metaframe/extract  — LLM によるメタフレーム抽出
 * GET  /api/metaframe/latest   — 最新メタフレーム取得
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { asyncHandler, createNotFound } from '../middleware/error-handler';
import { theoryStore } from '../services/theory-store';
import { extractMetaframe, getLatestMetaframe } from '../services/metaframe-service';
import { estimateTokens } from '../utils';

// ─── Zod スキーマ ──────────────────────────────────────────────────────────────

const MetaframeExtractionBodySchema = z.object({
  theory_ids: z
    .array(z.string())
    .min(1, 'theory_ids required'),
  config: z.object({
    target_tokens: z
      .number()
      .min(500, 'target_tokens must be between 500 and 10000')
      .max(10000, 'target_tokens must be between 500 and 10000'),
    focus_areas: z.array(z.string()).optional(),
  }),
});

// ─── ルーター ─────────────────────────────────────────────────────────────────

const metaframeRouter = Router();

/**
 * POST /api/metaframe/extract
 * theory_ids と config を受け取り、LLM でメタフレームを抽出して返す
 *
 * バリデーション:
 *   - theory_ids フィールドが必須かつ1件以上
 *   - config.target_tokens が 500〜10000 の範囲
 *   - 各 theory_id がストアに存在すること
 */
metaframeRouter.post(
  '/metaframe/extract',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    // Zod バリデーション
    const parseResult = MetaframeExtractionBodySchema.safeParse(req.body);

    if (!parseResult.success) {
      const errors = parseResult.error.errors;

      // theory_ids エラー（missing / 空配列）を優先
      const theoryIdsError = errors.find(
        (e) => e.path.length === 0 || e.path[0] === 'theory_ids',
      );

      if (theoryIdsError) {
        res.status(400).json({ error: 'theory_ids required' });
        return;
      }

      // その他のバリデーションエラー（config.target_tokens 等）
      res.status(400).json({
        error: errors.map((e) => `${e.path.join('.')}: ${e.message}`).join(', '),
      });
      return;
    }

    const { theory_ids, config } = parseResult.data;

    // theory_id 存在チェック
    for (const id of theory_ids) {
      if (!theoryStore.get(id)) {
        res.status(404).json({ error: `Theory ID '${id}' not found` });
        return;
      }
    }

    // LLM によるメタフレーム抽出
    const metaframe = await extractMetaframe({ theory_ids, config });

    // トークン数推定
    const token_count = estimateTokens(JSON.stringify(metaframe));

    res.status(200).json({
      ...metaframe,
      token_count,
    });
  }),
);

/**
 * GET /api/metaframe/latest
 * 最後に抽出されたメタフレームを返す。未抽出の場合は 404
 */
metaframeRouter.get(
  '/metaframe/latest',
  asyncHandler(async (_req: Request, res: Response): Promise<void> => {
    const metaframe = getLatestMetaframe();

    if (!metaframe) {
      throw createNotFound('Metaframe');
    }

    res.status(200).json(metaframe);
  }),
);

export default metaframeRouter;
