/**
 * 理論ファイルアップロードルート
 * POST /api/theory/upload
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { v4 as uuidv4 } from 'uuid';
import { theoryStore, MAX_TOTAL_SIZE_BYTES } from '../services/theory-store';
import { countChars, estimateTokens } from '../utils';
import { asyncHandler } from '../middleware/error-handler';

// ─── Zod スキーマ ──────────────────────────────────────────────────────────────

const TheoryFileInputSchema = z.object({
  id: z.string().optional(),
  title: z.string().min(1, 'title is required'),
  content: z.string(),
  metadata: z.record(z.unknown()).optional(),
});

const TheoryUploadBodySchema = z.object({
  theory_files: z
    .array(TheoryFileInputSchema)
    .min(1, 'at least one theory file required'),
});

// ─── ルーター ─────────────────────────────────────────────────────────────────

const theoryRouter = Router();

/**
 * POST /api/theory/upload
 * theory_files 配列を受け取り、インメモリストアに保存してメタデータを返す
 *
 * バリデーション:
 *   - theory_files フィールドが必須
 *   - 最低1件以上
 *   - 各ファイルの content が空文字列でないこと
 *   - 合計コンテンツサイズが 500KB 以内
 */
theoryRouter.post(
  '/theory/upload',
  asyncHandler(async (req: Request, res: Response): Promise<void> => {
    // Zod バリデーション
    const parseResult = TheoryUploadBodySchema.safeParse(req.body);

    if (!parseResult.success) {
      const errors = parseResult.error.errors;

      // theory_files フィールド関連エラー（missing / 型不一致 / 空配列）を優先
      const theoryFilesError = errors.find(
        (e) => e.path.length === 0 || e.path[0] === 'theory_files',
      );

      if (theoryFilesError) {
        res.status(400).json({
          error: `theory_files: ${theoryFilesError.message}`,
        });
        return;
      }

      // その他フィールドのバリデーションエラー
      res.status(400).json({
        error: errors.map((e) => `${e.path.join('.')}: ${e.message}`).join(', '),
      });
      return;
    }

    const { theory_files } = parseResult.data;

    // 空 content チェック（Zod は空文字を許容するため個別チェック）
    for (const file of theory_files) {
      if (file.content === '') {
        const fileId = file.id ?? '(no id)';
        res.status(400).json({
          error: `File '${fileId}' has empty content`,
        });
        return;
      }
    }

    // 合計サイズ上限チェック（500KB = 512,000 bytes）
    const totalBytes = theory_files.reduce(
      (sum, f) => sum + Buffer.byteLength(f.content, 'utf8'),
      0,
    );
    if (totalBytes > MAX_TOTAL_SIZE_BYTES) {
      res.status(400).json({
        error: `Total content size exceeds the 500KB limit (${totalBytes} bytes)`,
      });
      return;
    }

    // ストア保存 + メタデータ生成
    const files = theory_files.map((file) => {
      const id = file.id ?? uuidv4();
      theoryStore.set({
        id,
        title: file.title,
        content: file.content,
        metadata: file.metadata,
      });
      return {
        id,
        title: file.title,
        char_count: countChars(file.content),
        estimated_tokens: estimateTokens(file.content),
      };
    });

    const total_chars = files.reduce((sum, f) => sum + f.char_count, 0);
    const total_estimated_tokens = files.reduce(
      (sum, f) => sum + f.estimated_tokens,
      0,
    );

    res.status(200).json({ files, total_chars, total_estimated_tokens });
  }),
);

export default theoryRouter;
