import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import app from '../../src/app';
import { theoryStore } from '../../src/services/theory-store';

describe('POST /api/theory/upload', () => {
  beforeEach(() => {
    // テスト間でストアをクリアして独立性を保つ
    theoryStore.clear();
  });

  // behavior: POST /api/theory/upload に有効なJSON（theory_files配列）を送信 → 200 + 各ファイルのid・title・char_countを含むメタデータ返却
  it('正常アップロード: 200 + id・title・char_count を含むメタデータ返却', async () => {
    const res = await request(app)
      .post('/api/theory/upload')
      .set('Content-Type', 'application/json')
      .send({
        theory_files: [
          {
            id: 'file-001',
            title: 'テスト理論ファイル1',
            content: 'セールスコピーライティングの基礎について解説します。読者の問題を理解し解決策を提示することが重要です。',
          },
          {
            id: 'file-002',
            title: 'テスト理論ファイル2',
            content: '感情トリガーの活用方法について説明します。恐怖、希望、所属感などが主要なトリガーです。',
          },
        ],
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('files');
    expect(Array.isArray(res.body.files)).toBe(true);
    expect(res.body.files).toHaveLength(2);

    // 各ファイルメタデータの検証
    const f1 = res.body.files[0];
    expect(f1).toHaveProperty('id', 'file-001');
    expect(f1).toHaveProperty('title', 'テスト理論ファイル1');
    expect(f1).toHaveProperty('char_count');
    expect(typeof f1.char_count).toBe('number');
    expect(f1.char_count).toBeGreaterThan(0);

    const f2 = res.body.files[1];
    expect(f2).toHaveProperty('id', 'file-002');
    expect(f2).toHaveProperty('title', 'テスト理論ファイル2');
    expect(f2).toHaveProperty('char_count');

    // 合計文字数の検証
    expect(res.body).toHaveProperty('total_chars');
    expect(res.body.total_chars).toBeGreaterThan(0);
    expect(res.body.total_chars).toBe(f1.char_count + f2.char_count);

    // トークン推定の検証
    expect(res.body).toHaveProperty('total_estimated_tokens');
    expect(res.body.total_estimated_tokens).toBeGreaterThan(0);
  });

  // behavior: POST /api/theory/upload にbodyなし → 400 + エラーメッセージに'theory_files'フィールド名を含む
  it('body無し: 400 + エラーメッセージに theory_files を含む', async () => {
    const res = await request(app)
      .post('/api/theory/upload')
      .set('Content-Type', 'application/json');
    // body を送らない

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error).toContain('theory_files');
  });

  // behavior: POST /api/theory/upload にtheory_files空配列 → 400 + 'at least one theory file required'相当のメッセージ
  it('空配列: 400 + at least one theory file required 相当のメッセージ', async () => {
    const res = await request(app)
      .post('/api/theory/upload')
      .set('Content-Type', 'application/json')
      .send({ theory_files: [] });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('at least one');
  });

  // behavior: POST /api/theory/upload に合計500KB超のコンテンツ → 400 + サイズ制限エラー
  it('500KB超: 400 + サイズ制限エラー', async () => {
    // 300KB × 2 = 600KB 合計（ASCII は 1 byte/char）
    const largeContent = 'a'.repeat(300 * 1024);

    const res = await request(app)
      .post('/api/theory/upload')
      .set('Content-Type', 'application/json')
      .send({
        theory_files: [
          { id: 'big-1', title: '大きいファイル1', content: largeContent },
          { id: 'big-2', title: '大きいファイル2', content: largeContent },
        ],
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    // 500KB / limit / size のいずれかを含む
    expect(res.body.error).toMatch(/500|limit|size/i);
  });

  // behavior: POST /api/theory/upload にcontent空文字列のファイルを含む → 400 + 該当ファイルIDを含むエラー
  it('空content: 400 + 該当ファイルID を含むエラー', async () => {
    const res = await request(app)
      .post('/api/theory/upload')
      .set('Content-Type', 'application/json')
      .send({
        theory_files: [
          { id: 'empty-file-xyz', title: '空コンテンツファイル', content: '' },
        ],
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error).toContain('empty-file-xyz');
  });
});
