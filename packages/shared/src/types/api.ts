/**
 * API Types - Shared Request/Response Definitions
 *
 * APIリクエスト/レスポンスの共有型定義
 * フロントエンド/バックエンド間の型安全性を保証
 */

// ===========================
// Base Types
// ===========================

/**
 * API Error Response
 */
export interface ApiError {
  error: string;
  message: string;
  statusCode: number;
  timestamp?: string;
  path?: string;
}

/**
 * Pagination Params
 */
export interface PaginationParams {
  page?: number;
  limit?: number;
  offset?: number;
}

/**
 * Pagination Metadata
 */
export interface PaginationMeta {
  total: number;
  page: number;
  limit: number;
  totalPages: number;
}

// ===========================
// 7次元生成関連
// ===========================

/**
 * 7次元パラメータ（0.0-1.0の正規化値）
 */
export interface SevenDimParams {
  complexity: number;      // 複雑性
  novelty: number;         // 新規性
  coherence: number;       // 一貫性
  emotion: number;         // 感情強度
  interactivity: number;   // 相互作用性
  scale: number;           // スケール
  uncertainty: number;     // 不確実性
}

/**
 * 世界生成リクエスト
 */
export interface GenerateRequest {
  prompt: string;
  dimensions: SevenDimParams;
  userId?: string;
  sessionId?: string;
}

/**
 * 世界生成レスポンス
 */
export interface GenerateResponse {
  worldId: string;
  title: string;
  description: string;
  generatedAt: string;
  dimensions: SevenDimParams;
  metadata?: {
    generationTime?: number;
    model?: string;
    version?: string;
  };
}

// ===========================
// 認証関連
// ===========================

/**
 * サインアップリクエスト
 */
export interface SignUpRequest {
  email: string;
  password: string;
  username?: string;
}

/**
 * ログインリクエスト
 */
export interface LoginRequest {
  email: string;
  password: string;
}

/**
 * トークンレスポンス
 */
export interface TokenResponse {
  accessToken: string;
  refreshToken?: string;
  expiresIn: number;
  tokenType: string;
  user: {
    id: string;
    email: string;
    username?: string;
  };
}

/**
 * リフレッシュトークンリクエスト
 */
export interface RefreshTokenRequest {
  refreshToken: string;
}

// ===========================
// 世界管理関連
// ===========================

/**
 * 世界保存リクエスト
 */
export interface SaveWorldRequest {
  worldId?: string;
  title: string;
  description: string;
  dimensions: SevenDimParams;
  content?: any;
  tags?: string[];
  isPublic?: boolean;
}

/**
 * 世界データ
 */
export interface WorldData {
  id: string;
  title: string;
  description: string;
  dimensions: SevenDimParams;
  content?: any;
  tags?: string[];
  isPublic: boolean;
  userId: string;
  createdAt: string;
  updatedAt: string;
  viewCount?: number;
  likeCount?: number;
}

/**
 * 世界リスト取得レスポンス
 */
export interface WorldListResponse {
  worlds: WorldData[];
  pagination: PaginationMeta;
}

/**
 * 世界詳細取得レスポンス
 */
export interface WorldDetailResponse {
  world: WorldData;
}

/**
 * 世界削除リクエスト
 */
export interface DeleteWorldRequest {
  worldId: string;
}

/**
 * 世界更新リクエスト
 */
export interface UpdateWorldRequest {
  worldId: string;
  title?: string;
  description?: string;
  dimensions?: SevenDimParams;
  content?: any;
  tags?: string[];
  isPublic?: boolean;
}

// ===========================
// ヘルスチェック
// ===========================

/**
 * ヘルスチェックレスポンス
 */
export interface HealthCheckResponse {
  status: 'ok' | 'degraded' | 'down';
  timestamp: string;
  uptime: number;
  version: string;
  services?: {
    database?: 'ok' | 'down';
    cache?: 'ok' | 'down';
    ai?: 'ok' | 'down';
  };
}

// ===========================
// Type Guards
// ===========================

/**
 * ApiErrorかどうかを判定
 */
export function isApiError(obj: any): obj is ApiError {
  return (
    typeof obj === 'object' &&
    obj !== null &&
    typeof obj.error === 'string' &&
    typeof obj.message === 'string' &&
    typeof obj.statusCode === 'number'
  );
}

/**
 * SevenDimParamsのバリデーション
 */
export function isValidSevenDimParams(obj: any): obj is SevenDimParams {
  if (typeof obj !== 'object' || obj === null) return false;

  const requiredKeys: (keyof SevenDimParams)[] = [
    'complexity',
    'novelty',
    'coherence',
    'emotion',
    'interactivity',
    'scale',
    'uncertainty',
  ];

  return requiredKeys.every(key => {
    const value = obj[key];
    return typeof value === 'number' && value >= 0 && value <= 1;
  });
}
