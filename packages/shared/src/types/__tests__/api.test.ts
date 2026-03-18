/**
 * API Types Unit Tests
 *
 * Layer 1: 型定義の整合性・Type Guards検証
 */

import {
  ApiError,
  SevenDimParams,
  GenerateRequest,
  GenerateResponse,
  SignUpRequest,
  LoginRequest,
  TokenResponse,
  SaveWorldRequest,
  WorldData,
  WorldListResponse,
  isApiError,
  isValidSevenDimParams,
} from '../api';

describe('API Types - Type Guards', () => {
  // ===========================
  // isApiError
  // ===========================

  test('[正常系] 正しいApiError構造を判定できる', () => {
    const validError: ApiError = {
      error: 'NotFound',
      message: 'Resource not found',
      statusCode: 404,
    };

    expect(isApiError(validError)).toBe(true);
  });

  test('[正常系] timestampとpathが含まれていても判定できる', () => {
    const validError = {
      error: 'BadRequest',
      message: 'Invalid input',
      statusCode: 400,
      timestamp: '2026-02-15T10:00:00Z',
      path: '/api/worlds',
    };

    expect(isApiError(validError)).toBe(true);
  });

  test('[異常系] 必須フィールド欠落を検出', () => {
    const invalidError = {
      error: 'Error',
      message: 'Something went wrong',
      // statusCode missing
    };

    expect(isApiError(invalidError)).toBe(false);
  });

  test('[異常系] 型不一致を検出', () => {
    const invalidError = {
      error: 'Error',
      message: 'Message',
      statusCode: '500', // should be number
    };

    expect(isApiError(invalidError)).toBe(false);
  });

  test('[エッジケース] null/undefinedを拒否', () => {
    expect(isApiError(null)).toBe(false);
    expect(isApiError(undefined)).toBe(false);
  });

  // ===========================
  // isValidSevenDimParams
  // ===========================

  test('[正常系] 正しい7次元パラメータを判定できる', () => {
    const validParams: SevenDimParams = {
      complexity: 0.5,
      novelty: 0.7,
      coherence: 0.8,
      emotion: 0.3,
      interactivity: 0.6,
      scale: 0.9,
      uncertainty: 0.2,
    };

    expect(isValidSevenDimParams(validParams)).toBe(true);
  });

  test('[正常系] 境界値（0.0, 1.0）を許容', () => {
    const boundaryParams: SevenDimParams = {
      complexity: 0.0,
      novelty: 1.0,
      coherence: 0.0,
      emotion: 1.0,
      interactivity: 0.5,
      scale: 0.0,
      uncertainty: 1.0,
    };

    expect(isValidSevenDimParams(boundaryParams)).toBe(true);
  });

  test('[異常系] 範囲外の値を拒否（負の値）', () => {
    const invalidParams = {
      complexity: -0.1,
      novelty: 0.7,
      coherence: 0.8,
      emotion: 0.3,
      interactivity: 0.6,
      scale: 0.9,
      uncertainty: 0.2,
    };

    expect(isValidSevenDimParams(invalidParams)).toBe(false);
  });

  test('[異常系] 範囲外の値を拒否（1.0超過）', () => {
    const invalidParams = {
      complexity: 0.5,
      novelty: 1.1,
      coherence: 0.8,
      emotion: 0.3,
      interactivity: 0.6,
      scale: 0.9,
      uncertainty: 0.2,
    };

    expect(isValidSevenDimParams(invalidParams)).toBe(false);
  });

  test('[異常系] 必須フィールド欠落を検出', () => {
    const invalidParams = {
      complexity: 0.5,
      novelty: 0.7,
      coherence: 0.8,
      // emotion missing
      interactivity: 0.6,
      scale: 0.9,
      uncertainty: 0.2,
    };

    expect(isValidSevenDimParams(invalidParams)).toBe(false);
  });

  test('[異常系] 型不一致を検出', () => {
    const invalidParams = {
      complexity: '0.5', // should be number
      novelty: 0.7,
      coherence: 0.8,
      emotion: 0.3,
      interactivity: 0.6,
      scale: 0.9,
      uncertainty: 0.2,
    };

    expect(isValidSevenDimParams(invalidParams)).toBe(false);
  });

  test('[エッジケース] null/undefinedを拒否', () => {
    expect(isValidSevenDimParams(null)).toBe(false);
    expect(isValidSevenDimParams(undefined)).toBe(false);
  });

  test('[エッジケース] 空オブジェクトを拒否', () => {
    expect(isValidSevenDimParams({})).toBe(false);
  });
});

describe('API Types - Structure Validation', () => {
  // ===========================
  // GenerateRequest/Response
  // ===========================

  test('[正常系] GenerateRequestの構造が正しい', () => {
    const request: GenerateRequest = {
      prompt: 'Create a mysterious forest',
      dimensions: {
        complexity: 0.6,
        novelty: 0.8,
        coherence: 0.7,
        emotion: 0.5,
        interactivity: 0.4,
        scale: 0.9,
        uncertainty: 0.3,
      },
      userId: 'user-123',
      sessionId: 'session-456',
    };

    expect(request.prompt).toBeDefined();
    expect(isValidSevenDimParams(request.dimensions)).toBe(true);
  });

  test('[正常系] GenerateResponseの構造が正しい', () => {
    const response: GenerateResponse = {
      worldId: 'world-789',
      title: 'Mysterious Forest',
      description: 'A dense forest filled with ancient trees',
      generatedAt: '2026-02-15T10:00:00Z',
      dimensions: {
        complexity: 0.6,
        novelty: 0.8,
        coherence: 0.7,
        emotion: 0.5,
        interactivity: 0.4,
        scale: 0.9,
        uncertainty: 0.3,
      },
      metadata: {
        generationTime: 1234,
        model: 'gpt-4',
        version: '3.2',
      },
    };

    expect(response.worldId).toBeDefined();
    expect(response.generatedAt).toBeDefined();
    expect(isValidSevenDimParams(response.dimensions)).toBe(true);
  });

  // ===========================
  // Auth Types
  // ===========================

  test('[正常系] SignUpRequestの構造が正しい', () => {
    const request: SignUpRequest = {
      email: 'user@example.com',
      password: 'securePassword123',
      username: 'testuser',
    };

    expect(request.email).toBeDefined();
    expect(request.password).toBeDefined();
  });

  test('[正常系] TokenResponseの構造が正しい', () => {
    const response: TokenResponse = {
      accessToken: 'eyJhbGciOiJIUzI1NiIs...',
      refreshToken: 'refresh-token-xyz',
      expiresIn: 3600,
      tokenType: 'Bearer',
      user: {
        id: 'user-123',
        email: 'user@example.com',
        username: 'testuser',
      },
    };

    expect(response.accessToken).toBeDefined();
    expect(response.expiresIn).toBeGreaterThan(0);
    expect(response.user.id).toBeDefined();
  });

  // ===========================
  // World Types
  // ===========================

  test('[正常系] SaveWorldRequestの構造が正しい', () => {
    const request: SaveWorldRequest = {
      worldId: 'world-123',
      title: 'My World',
      description: 'A wonderful world',
      dimensions: {
        complexity: 0.5,
        novelty: 0.5,
        coherence: 0.5,
        emotion: 0.5,
        interactivity: 0.5,
        scale: 0.5,
        uncertainty: 0.5,
      },
      tags: ['fantasy', 'adventure'],
      isPublic: true,
    };

    expect(request.title).toBeDefined();
    expect(isValidSevenDimParams(request.dimensions)).toBe(true);
  });

  test('[正常系] WorldListResponseの構造が正しい', () => {
    const response: WorldListResponse = {
      worlds: [
        {
          id: 'world-1',
          title: 'World One',
          description: 'First world',
          dimensions: {
            complexity: 0.5,
            novelty: 0.5,
            coherence: 0.5,
            emotion: 0.5,
            interactivity: 0.5,
            scale: 0.5,
            uncertainty: 0.5,
          },
          isPublic: true,
          userId: 'user-1',
          createdAt: '2026-02-15T10:00:00Z',
          updatedAt: '2026-02-15T10:00:00Z',
        },
      ],
      pagination: {
        total: 100,
        page: 1,
        limit: 10,
        totalPages: 10,
      },
    };

    expect(response.worlds).toHaveLength(1);
    expect(response.pagination.total).toBeGreaterThan(0);
  });

  test('[エッジケース] WorldListResponseが空配列を許容', () => {
    const response: WorldListResponse = {
      worlds: [],
      pagination: {
        total: 0,
        page: 1,
        limit: 10,
        totalPages: 0,
      },
    };

    expect(response.worlds).toHaveLength(0);
    expect(response.pagination.total).toBe(0);
  });
});
