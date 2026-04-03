/**
 * 商品情報後差し注入ルート
 * POST /api/product/inject — LLMによるdraft→critique→rewrite 3段構成で商品情報を注入
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../middleware/error-handler';
import { injectProductInfo } from '../services/product-service';

// ─── Zod スキーマ ──────────────────────────────────────────────────────────────

const ProductInfoSchema = z.object({
  name: z.string().min(1, 'name is required'),
  price: z.string().min(1, 'price is required'),
  features: z.array(z.string()).min(1, 'features must contain at least one item'),
  target_audience: z.string().min(1, 'target_audience is required'),
});

const ProductInjectBodySchema = z.object({
  letter_draft: z.string().min(1, 'letter_draft is required'),
  product_info: ProductInfoSchema,
  model: z.string().optional(),
});

// ─── ルーター ─────────────────────────────────────────────────────────────────

const productRouter = Router();

/**
 * POST /api/product/inject
 * letter_draftとproduct_infoを受け取り、LLMで商品情報を自然に注入したmodified_letterを返す
 *
 * バリデーション（優先順）:
 *   1. letter_draft 未指定 → 400 "letter_draft required"
 *   2. product_info 未指定 → 400 "product_info required"
 *   3. Zod スキーマ検証（product_info の name・price・features・target_audience 構造）
 */
productRouter.post(
  '/product/inject',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    // ── 1. letter_draft 優先チェック ──────────────────────────────────────
    if (!req.body || !req.body.letter_draft) {
      res.status(400).json({ error: 'letter_draft required' });
      return;
    }

    // ── 2. product_info 優先チェック ──────────────────────────────────────
    if (!req.body.product_info) {
      res.status(400).json({ error: 'product_info required' });
      return;
    }

    // ── 3. Zod スキーマバリデーション ─────────────────────────────────────
    const parseResult = ProductInjectBodySchema.safeParse(req.body);

    if (!parseResult.success) {
      const errors = parseResult.error.errors;
      res.status(400).json({
        error: errors.map((e) => `${e.path.join('.')}: ${e.message}`).join(', '),
      });
      return;
    }

    const { letter_draft, product_info, model } = parseResult.data;

    // ── 商品情報注入（draft→critique→rewrite 3段構成） ────────────────────
    const result = await injectProductInfo(letter_draft, product_info, model);

    res.status(200).json(result);
  }),
);

export default productRouter;
