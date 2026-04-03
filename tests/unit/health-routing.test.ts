import { describe, it, expect } from 'vitest';
import request from 'supertest';
import app from '../../src/app';

describe('Health Routing', () => {
  // behavior: GET /api/health → 200 + JSON {"status": "ok"} を返却
  it('GET /api/health は 200 + { status: "ok" } を返却する', async () => {
    const res = await request(app).get('/api/health');

    expect(res.status).toBe(200);
    expect(res.body).toEqual(expect.objectContaining({ status: 'ok' }));
  });

  // behavior: GET /api/nonexistent → 404 Not Found を返却
  it('GET /api/nonexistent は 404 Not Found を返却する', async () => {
    const res = await request(app).get('/api/nonexistent');

    expect(res.status).toBe(404);
    expect(res.body).toHaveProperty('error');
  });

  // behavior: POST /api/health（不正メソッド） → 405 Method Not Allowed を返却
  it('POST /api/health（不正メソッド）は 405 Method Not Allowed を返却する', async () => {
    const res = await request(app).post('/api/health');

    expect(res.status).toBe(405);
    expect(res.body).toHaveProperty('error');
  });

  // behavior: レスポンスに Content-Type: application/json ヘッダーが含まれる
  it('レスポンスに Content-Type: application/json ヘッダーが含まれる', async () => {
    const res = await request(app).get('/api/health');

    expect(res.headers['content-type']).toContain('application/json');
  });

  // behavior: サーバー起動後5秒以内に /api/health が応答可能になる
  it('サーバー起動後 5 秒以内に /api/health が応答可能になる', async () => {
    const start = Date.now();
    const res = await request(app).get('/api/health');
    const elapsed = Date.now() - start;

    expect(res.status).toBe(200);
    expect(elapsed).toBeLessThan(5000);
  });
});
