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

// ─── Express エラーハンドラーミドルウェア ─────────────────────────────────────

export function errorHandler(
  err: AppError,
  _req: Request,
  res: Response,
  _next: NextFunction,
): void {
  const statusCode = err.statusCode ?? 500;
  const message = err.message || 'Internal Server Error';
  const code = err.code ?? 'INTERNAL_ERROR';

  // サーバーサイドログ
  if (statusCode >= 500) {
    console.error(`[Error] ${statusCode} ${code}: ${message}`, err.stack);
  } else {
    console.warn(`[Warn] ${statusCode} ${code}: ${message}`);
  }

  res.status(statusCode).json({
    error: message,
    code,
    ...(err.details !== undefined ? { details: err.details } : {}),
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
