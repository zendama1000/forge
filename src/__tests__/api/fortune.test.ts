/**
 * POST /api/fortune - Layer 1 APIテスト
 *
 * Hono testClient ではなく fortune.request() を使い、
 * Content-Type・メソッド・バリデーションの全ケースを網羅する。
 */

import { describe, it, expect } from 'vitest';
import { z } from 'zod';
import fortune from '@forge/api/routes/fortune';
import {
  FortuneRequestSchema,
  type FortuneRequest,
} from '@forge/api/schemas/fortune-request';

// 有効な7次元パラメータ（全て0-100の整数）
const VALID_DIMENSIONS = [10, 20, 30, 40, 50, 60, 70];

// ─── 正常系 ──────────────────────────────────────────────────────────────────

describe('POST /api/fortune 正常系', () => {
  // behavior: POST /api/fortune + 有効な7次元パラメータJSON body → 200 + {categories: [...]}
  it('有効な7次元パラメータで200と{categories:[...]}を返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ dimensions: VALID_DIMENSIONS }),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('categories');
    expect(Array.isArray(body.categories)).toBe(true);
    expect(body.categories.length).toBeGreaterThanOrEqual(1);
    // 各カテゴリが必要なフィールドを持つことを確認
    const cat = body.categories[0];
    expect(cat).toHaveProperty('totalScore');
    expect(cat).toHaveProperty('templateText');
    expect(cat).toHaveProperty('dimensions');
  });

  // behavior: [追加] 境界値（0と100）を含む7次元パラメータでも200を返す
  it('[追加] 境界値(0と100)を含む7次元パラメータで200を返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ dimensions: [0, 100, 0, 100, 0, 100, 50] }),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty('categories');
  });
});

// ─── バリデーション異常系 ────────────────────────────────────────────────────

describe('POST /api/fortune バリデーション異常系', () => {
  // behavior: POST /api/fortune + body={} → 400 + エラーメッセージJSON
  it('body={}で400とエラーメッセージJSONを返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body).toHaveProperty('error');
    expect(typeof body.error).toBe('string');
  });

  // behavior: POST /api/fortune + dimensions=[50,50,50,50,50,50]（6要素）→ 400 + バリデーションエラー
  it('6要素のdimensions（1つ不足）で400とバリデーションエラーを返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ dimensions: [50, 50, 50, 50, 50, 50] }),
    });

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body).toHaveProperty('error');
    // バリデーションエラー詳細（issues）が含まれることも確認
    expect(body).toHaveProperty('issues');
    expect(Array.isArray(body.issues)).toBe(true);
  });

  // behavior: POST /api/fortune + dimensions=[150,50,50,50,50,50,50]（範囲外）→ 400
  it('範囲外の値150を含むdimensionsで400を返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ dimensions: [150, 50, 50, 50, 50, 50, 50] }),
    });

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body).toHaveProperty('error');
  });

  // behavior: [追加] 負の値を含むdimensionsで400を返す
  it('[追加] 負の値(-1)を含むdimensionsで400を返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ dimensions: [-1, 50, 50, 50, 50, 50, 50] }),
    });

    expect(res.status).toBe(400);
  });

  // behavior: [追加] 8要素のdimensionsで400を返す
  it('[追加] 8要素のdimensions（1つ超過）で400を返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ dimensions: [10, 20, 30, 40, 50, 60, 70, 80] }),
    });

    expect(res.status).toBe(400);
  });

  // behavior: [追加] 小数値を含むdimensionsで400を返す
  it('[追加] 小数値(10.5)を含むdimensionsで400を返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ dimensions: [10.5, 20, 30, 40, 50, 60, 70] }),
    });

    expect(res.status).toBe(400);
  });
});

// ─── HTTPメソッド制御 ────────────────────────────────────────────────────────

describe('HTTPメソッド制御', () => {
  // behavior: GET /api/fortune → 405 Method Not Allowed
  it('GETリクエストで405 Method Not Allowedを返す', async () => {
    const res = await fortune.request('/', {
      method: 'GET',
    });

    expect(res.status).toBe(405);
    const body = await res.json();
    expect(body).toHaveProperty('error');
  });
});

// ─── Content-Type制御 ────────────────────────────────────────────────────────

describe('Content-Type制御', () => {
  // behavior: POST /api/fortune + Content-Type未指定 → 400 または 415
  it('Content-Type未指定のPOSTで400または415を返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      // Content-Typeヘッダーなし
      body: JSON.stringify({ dimensions: VALID_DIMENSIONS }),
    });

    expect([400, 415]).toContain(res.status);
  });

  // behavior: [追加] Content-Type: text/plainで400または415を返す
  it('[追加] Content-Type: text/plainで400または415を返す', async () => {
    const res = await fortune.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: JSON.stringify({ dimensions: VALID_DIMENSIONS }),
    });

    expect([400, 415]).toContain(res.status);
  });
});

// ─── 型推論検証 ──────────────────────────────────────────────────────────────

describe('ZodスキーマType推論', () => {
  // behavior: ZodスキーマからのType推論（z.infer<typeof fortuneRequestSchema>）がAPIハンドラの引数型として使用 → 型チェック通過
  it('FortuneRequest型がz.infer<typeof FortuneRequestSchema>から正しく推論され、型チェックを通過する', () => {
    // TypeScriptコンパイル時型チェック:
    // FortuneRequest === z.infer<typeof FortuneRequestSchema> であることを確認
    type InferredType = z.infer<typeof FortuneRequestSchema>;

    // 実行時検証: 有効なオブジェクトがFortuneRequest型として受け入れられる
    const input: FortuneRequest = { dimensions: [10, 20, 30, 40, 50, 60, 70] };

    // InferredTypeとFortuneRequestは同じ型である（相互代入可能）
    const typedAsInferred: InferredType = input;
    const typedAsRequest: FortuneRequest = typedAsInferred;

    // スキーマでのバリデーション通過確認
    const result = FortuneRequestSchema.safeParse(typedAsRequest);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.dimensions).toHaveLength(7);
      result.data.dimensions.forEach((v) => {
        expect(typeof v).toBe('number');
        expect(Number.isInteger(v)).toBe(true);
      });
    }
  });
});
