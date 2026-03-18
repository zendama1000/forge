/**
 * GET /api/fortune/history - Layer 1 APIテスト
 *
 * fortune ルートと history ルートを同一プロセスで結合テストする。
 * beforeEach で clearHistory() を呼び出し、テスト間の状態汚染を防ぐ。
 */

import { describe, it, expect, beforeEach } from 'vitest';
import fortune from '@forge/api/routes/fortune';
import history from '@forge/api/routes/history';
import { clearHistory } from '@forge/api/store/fortune-history';

// ─── ヘルパー ─────────────────────────────────────────────────────────────────

const VALID_DIMENSIONS = [10, 20, 30, 40, 50, 60, 70];

/** POST /api/fortune を呼び出し占い結果を取得するヘルパー */
async function postFortune(dimensions: number[] = VALID_DIMENSIONS) {
  return fortune.request('/', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ dimensions }),
  });
}

/** GET /api/fortune/history を呼び出すヘルパー */
async function getHistory() {
  return history.request('/', { method: 'GET' });
}

// ─── テスト前後処理 ───────────────────────────────────────────────────────────

beforeEach(() => {
  // テスト間の履歴汚染を防ぐため毎回クリア
  clearHistory();
});

// ─── 正常系: データ0件 ────────────────────────────────────────────────────────

describe('GET /api/fortune/history - 空状態', () => {
  // behavior: データ0件状態でGET /api/fortune/history → 200 + 空配列[]
  it('データ0件状態で200と空配列[]を返す', async () => {
    const res = await getHistory();

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body).toHaveLength(0);
  });
});

// ─── 正常系: 1件エントリ ──────────────────────────────────────────────────────

describe('GET /api/fortune/history - 占い1回後', () => {
  // behavior: 占い1回実行後にGET /api/fortune/history → 200 + 1件以上のエントリ配列
  it('占い1回実行後に200と1件以上のエントリ配列を返す', async () => {
    // 事前に占い実行
    const fortuneRes = await postFortune();
    expect(fortuneRes.status).toBe(200);

    // 履歴取得
    const res = await getHistory();
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBeGreaterThanOrEqual(1);
  });

  // behavior: 各履歴エントリにid, createdAt, categories概要フィールドを含む
  it('各履歴エントリにid, createdAt, categories概要フィールドを含む', async () => {
    await postFortune();

    const res = await getHistory();
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.length).toBeGreaterThanOrEqual(1);

    const entry = body[0];

    // id フィールドの検証
    expect(entry).toHaveProperty('id');
    expect(typeof entry.id).toBe('string');
    expect(entry.id.length).toBeGreaterThan(0);

    // createdAt フィールドの検証
    expect(entry).toHaveProperty('createdAt');
    expect(typeof entry.createdAt).toBe('string');
    // ISO 8601 形式であることを確認
    expect(new Date(entry.createdAt).toString()).not.toBe('Invalid Date');

    // categories 概要フィールドの検証
    expect(entry).toHaveProperty('categories');
    expect(Array.isArray(entry.categories)).toBe(true);
    expect(entry.categories.length).toBeGreaterThanOrEqual(1);

    // 各カテゴリに totalScore と templateText が含まれることを確認
    const cat = entry.categories[0];
    expect(cat).toHaveProperty('totalScore');
    expect(cat).toHaveProperty('templateText');
    expect(typeof cat.totalScore).toBe('number');
    expect(typeof cat.templateText).toBe('string');
  });
});

// ─── 正常系: 複数件エントリ・降順ソート ──────────────────────────────────────

describe('GET /api/fortune/history - 複数回占い後', () => {
  // behavior: 複数回占い実行後にGET /api/fortune/history → 実行回数分のエントリ、createdAt降順
  it('複数回占い実行後に実行回数分のエントリをcreatedAt降順で返す', async () => {
    // 3回占いを実行
    await postFortune([10, 20, 30, 40, 50, 60, 70]);
    await postFortune([20, 30, 40, 50, 60, 70, 80]);
    await postFortune([30, 40, 50, 60, 70, 80, 90]);

    const res = await getHistory();
    expect(res.status).toBe(200);

    const body = await res.json();

    // 3件のエントリが返されることを確認
    expect(body).toHaveLength(3);

    // createdAt が降順（新しい順）であることを確認
    for (let i = 0; i < body.length - 1; i++) {
      const current = new Date(body[i].createdAt).getTime();
      const next = new Date(body[i + 1].createdAt).getTime();
      // 降順: current >= next
      expect(current).toBeGreaterThanOrEqual(next);
    }

    // 各エントリの必須フィールド確認
    body.forEach((entry: { id: unknown; createdAt: unknown; categories: unknown[] }) => {
      expect(entry).toHaveProperty('id');
      expect(entry).toHaveProperty('createdAt');
      expect(entry).toHaveProperty('categories');
      expect(Array.isArray(entry.categories)).toBe(true);
    });
  });

  // behavior: [追加] 2回実行後にidがそれぞれ異なることを確認（エッジケース）
  it('[追加] 複数回実行後に各エントリのidがユニークであること', async () => {
    await postFortune();
    await postFortune();

    const res = await getHistory();
    const body = await res.json();

    expect(body).toHaveLength(2);
    expect(body[0].id).not.toBe(body[1].id);
  });
});

// ─── HTTPメソッド制御: POST は 405 ────────────────────────────────────────────

describe('POST /api/fortune/history', () => {
  // behavior: POST /api/fortune/history → 405 Method Not Allowed
  it('POSTリクエストで405 Method Not Allowedを返す', async () => {
    const res = await history.request('/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });

    expect(res.status).toBe(405);
    const body = await res.json();
    expect(body).toHaveProperty('error');
    expect(typeof body.error).toBe('string');
  });
});
