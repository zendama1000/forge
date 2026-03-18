import { describe, it, expect } from 'vitest';
import app from './index';

describe('API Entry Point', () => {
  // Layer 1: ファイル存在確認 → このテストファイル自体がindex.tsをimportできることで検証

  it('Honoアプリケーションをエクスポートしている', () => {
    expect(app).toBeDefined();
    expect(typeof app.fetch).toBe('function');
  });

  it('/ ルートが正しいレスポンスを返す', async () => {
    const res = await app.request('/');
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json).toHaveProperty('message');
    expect(json).toHaveProperty('version');
  });

  it('/health エンドポイントが正しいレスポンスを返す', async () => {
    const res = await app.request('/health');
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json).toHaveProperty('status', 'ok');
    expect(json).toHaveProperty('timestamp');
  });

  // エッジケース: 存在しないルートへのリクエスト
  it('存在しないルートは404を返す', async () => {
    const res = await app.request('/non-existent');
    expect(res.status).toBe(404);
  });
});
