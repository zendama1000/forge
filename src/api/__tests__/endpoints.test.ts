/**
 * Brand Toolkit API エンドポイント統合テスト
 * Hono の app.fetch() を使用（supertest 不要）
 * 必須テスト振る舞い 8 件をすべてカバー
 */

import { describe, test, expect, beforeEach } from 'vitest';
import app from '../../app';
import { clearStore } from '../store';

// テスト間のデータ隔離のためにストアをリセット
beforeEach(() => {
  clearStore();
});

/** 有効なブランドコンセプトのフィクスチャ */
const validConcept = {
  brand_name: 'テストブランド',
  divination_type: 'tarot',
  target_audience: '20代女性',
  core_values: ['誠実さ', '洞察力'],
  differentiators: ['独自のカード解釈'],
  $schema_version: '1.0.0',
};

describe('Brand Toolkit API エンドポイントテスト', () => {
  // ─────────────────────────────────────────────────────────────────────────
  // behavior: GET /api/health → 200 + {"status": "ok"} を含むJSONレスポンス
  // ─────────────────────────────────────────────────────────────────────────
  test('GET /api/health: 200 + status:ok を返す', async () => {
    const res = await app.fetch(new Request('http://localhost/api/health'));

    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.status).toBe('ok');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior: POST /api/brand/concept に有効なブランドコンセプトJSON送信 → 201 + concept_idを含むJSONレスポンス
  // ─────────────────────────────────────────────────────────────────────────
  test('POST /api/brand/concept: 有効なボディで 201 + concept_id を返す', async () => {
    const res = await app.fetch(
      new Request('http://localhost/api/brand/concept', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(validConcept),
      }),
    );

    expect(res.status).toBe(201);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toHaveProperty('concept_id');
    expect(typeof body.concept_id).toBe('string');
    expect((body.concept_id as string).length).toBeGreaterThan(0);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior: POST /api/brand/concept に必須フィールド欠落のJSON送信 → 400 + errorsフィールドに欠落フィールド名を含むJSONレスポンス
  // ─────────────────────────────────────────────────────────────────────────
  test('POST /api/brand/concept: 必須フィールド欠落で 400 + errors（フィールド名含む）を返す', async () => {
    // brand_name のみ指定し、他の必須フィールドを省略
    const incompleteBody = { brand_name: 'テストブランド' };

    const res = await app.fetch(
      new Request('http://localhost/api/brand/concept', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(incompleteBody),
      }),
    );

    expect(res.status).toBe(400);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toHaveProperty('errors');

    const errors = body.errors as string[];
    expect(Array.isArray(errors)).toBe(true);
    expect(errors.length).toBeGreaterThan(0);

    // 欠落フィールド名が errors 配列の文字列に含まれていることを確認
    const errorText = errors.join(' ');
    expect(errorText).toContain('divination_type');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior: GET /api/brand/concept/:id に存在しないID指定 → 404 + エラーメッセージを含むJSONレスポンス
  // ─────────────────────────────────────────────────────────────────────────
  test('GET /api/brand/concept/:id: 存在しない ID で 404 + error を返す', async () => {
    const res = await app.fetch(
      new Request('http://localhost/api/brand/concept/00000000-0000-0000-0000-000000000000'),
    );

    expect(res.status).toBe(404);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toHaveProperty('error');
    expect(typeof body.error).toBe('string');
    expect((body.error as string).length).toBeGreaterThan(0);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior: POST /api/brand/ethics/validate に禁止表現を含むテキスト送信 → 200 + violations配列が1件以上のJSONレスポンス
  // ─────────────────────────────────────────────────────────────────────────
  test('POST /api/brand/ethics/validate: 禁止表現テキストで 200 + violations ≥1 を返す', async () => {
    const res = await app.fetch(
      new Request('http://localhost/api/brand/ethics/validate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: '必ず当たる占いです' }),
      }),
    );

    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toHaveProperty('violations');
    const violations = body.violations as unknown[];
    expect(violations.length).toBeGreaterThan(0);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior: POST /api/brand/ethics/validate に違反なしテキスト送信 → 200 + violations空配列のJSONレスポンス
  // ─────────────────────────────────────────────────────────────────────────
  test('POST /api/brand/ethics/validate: 違反なしテキストで 200 + violations=[] を返す', async () => {
    const res = await app.fetch(
      new Request('http://localhost/api/brand/ethics/validate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: '占いで自分の可能性を探求しましょう' }),
      }),
    );

    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toHaveProperty('violations');
    const violations = body.violations as unknown[];
    expect(violations).toEqual([]);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior: POST /api/brand/ethics/validate にContent-Type未指定 → 415 Unsupported Media Type
  // ─────────────────────────────────────────────────────────────────────────
  test('POST /api/brand/ethics/validate: application/json 以外の Content-Type で 415 を返す', async () => {
    const res = await app.fetch(
      new Request('http://localhost/api/brand/ethics/validate', {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain' },
        body: 'plain text body',
      }),
    );

    expect(res.status).toBe(415);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // behavior: 不正なJSONボディでPOST → 400 + パースエラーメッセージ
  // ─────────────────────────────────────────────────────────────────────────
  test('POST: 不正な JSON ボディで 400 + パースエラーメッセージを返す', async () => {
    const res = await app.fetch(
      new Request('http://localhost/api/brand/concept', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{invalid json here}',
      }),
    );

    expect(res.status).toBe(400);
    const body = (await res.json()) as Record<string, unknown>;
    // error または message フィールドにパースエラー情報が含まれていること
    const hasErrorInfo = 'message' in body || 'error' in body;
    expect(hasErrorInfo).toBe(true);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // [追加] エッジケース: 作成したコンセプトを ID で取得できること
  // ─────────────────────────────────────────────────────────────────────────
  test('[追加] POST → GET ラウンドトリップ: 作成したコンセプトを ID で取得できる', async () => {
    // コンセプト作成
    const createRes = await app.fetch(
      new Request('http://localhost/api/brand/concept', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(validConcept),
      }),
    );
    expect(createRes.status).toBe(201);
    const createBody = (await createRes.json()) as Record<string, unknown>;
    const conceptId = createBody.concept_id as string;

    // 作成した ID で取得
    const getRes = await app.fetch(
      new Request(`http://localhost/api/brand/concept/${conceptId}`),
    );
    expect(getRes.status).toBe(200);
    const getBody = (await getRes.json()) as Record<string, unknown>;
    expect(getBody).toHaveProperty('concept_id', conceptId);
  });
});
