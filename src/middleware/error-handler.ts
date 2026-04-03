import { Request, Response, NextFunction } from 'express';

// ─── エラー型定義 ─────────────────────────────────────────────────────────────

export interface AppError extends Error {
  statusCode?: number;
  code?: string;
  details?: unknown;
}

// ─── エラー生成ヘルパー ──────────────────────────────────────────────────────

export function createError(
  message: string,
  statusCode: number = 500,
  code?: string,
  details?: unknown,
): AppError {
  const err: AppError = new Error(message);
  err.statusCode = statusCode;
  err.code = code;
  err.details = details;
  return err;
}

export function createBadRequest(message: string, details?: unknown): AppError {
  return createError(message, 400, 'BAD_REQUEST', details);
}

export function createNotFound(resource: string): AppError {
  return createError(`${resource} not found`, 404, 'NOT_FOUND');
}

export function createInternalError(message: string = 'Internal Server Error'): AppError {
  return createError(message, 500, 'INTERNAL_ERROR');
}

/**
 * バリデーションエラー生成ヘルパー
 * Zod / 手動バリデーション両方で使用可能
 */
export function createValidationError(message: string, details?: unknown): AppError {
  return createError(message, 400, 'VALIDATION_ERROR', details);
}

// ─── Express エラーハンドラーミドルウェア ─────────────────────────────────────

/**
 * 全エンドポイント共通エラーハンドラー
 *
 * 処理優先順:
 * 1. express.json() が投げる JSON パースエラー (entity.parse.failed) → 400
 * 2. Zod バリデーションエラー (ZodError) → 400
 * 3. AppError (statusCode 付き) → そのまま使用
 * 4. その他の Error → 500
 */
export function errorHandler(
  err: AppError | SyntaxError | Error,
  _req: Request,
  res: Response,
  _next: NextFunction,
): void {
  // ── 1. JSON パースエラー（express.json() ミドルウェアから）→ 400 ───────────
  // body-parser は type='entity.parse.failed' + status=400 の SyntaxError を投げる
  const bodyParseErr = err as unknown as { type?: string; status?: number };
  if (
    bodyParseErr.type === 'entity.parse.failed' ||
    (err instanceof SyntaxError && bodyParseErr.status === 400 && 'body' in err)
  ) {
    console.warn(`[Warn] 400 INVALID_JSON: ${err.message}`);
    res.status(400).json({
      error: 'Invalid JSON body',
      code: 'INVALID_JSON',
    });
    return;
  }

  // ── 2. Zod バリデーションエラー → 400 ────────────────────────────────────
  const zodErr = err as unknown as { name?: string; issues?: unknown[] };
  if (zodErr.name === 'ZodError' && Array.isArray(zodErr.issues)) {
    console.warn(`[Warn] 400 VALIDATION_ERROR: ${err.message}`);
    res.status(400).json({
      error: 'Validation error',
      code: 'VALIDATION_ERROR',
      details: zodErr.issues,
    });
    return;
  }

  // ── 3. AppError（statusCode 付き）または汎用エラー ──────────────────────
  const appErr = err as AppError;
  const statusCode = appErr.statusCode ?? 500;
  const message = appErr.message || 'Internal Server Error';
  const code = appErr.code ?? 'INTERNAL_ERROR';

  // サーバーサイドログ
  if (statusCode >= 500) {
    console.error(`[Error] ${statusCode} ${code}: ${message}`, err.stack);
  } else {
    console.warn(`[Warn] ${statusCode} ${code}: ${message}`);
  }

  res.status(statusCode).json({
    error: message,
    code,
    ...(appErr.details !== undefined ? { details: appErr.details } : {}),
  });
}

// ─── 非同期ルートハンドラーラッパー ──────────────────────────────────────────

type AsyncRequestHandler = (
  req: Request,
  res: Response,
  next: NextFunction,
) => Promise<void>;

export function asyncHandler(fn: AsyncRequestHandler) {
  return (req: Request, res: Response, next: NextFunction): void => {
    fn(req, res, next).catch(next);
  };
}
