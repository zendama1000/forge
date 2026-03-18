/**
 * L1-005: Authentication - Logout Tests
 *
 * logout エンドポイントのユニットテスト
 * - 正常系: 200 OK
 * - 二重ログアウト: 200 OK (冪等性)
 */

// テスト用のJWT_SECRET（auth.jsインポート前に設定）
const TEST_JWT_SECRET = 'test-secret-key-for-unit-tests';
process.env.JWT_SECRET = TEST_JWT_SECRET;
process.env.JWT_EXPIRES_IN = '1h';
process.env.REFRESH_TOKEN_EXPIRES_IN = '7d';

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Hono } from 'hono';
import auth from '../../../apps/api/src/routes/auth.js';
import { initDb, closeDb, getDb, getSqliteClient } from '../../../apps/api/src/db/index.js';
import { users, sessions } from '../../../apps/api/src/db/schema.js';
import { eq } from 'drizzle-orm';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { randomUUID } from 'crypto';

/**
 * テスト用にDBテーブルを作成
 */
function setupTestTables() {
  const sqlite = getSqliteClient();
  if (!sqlite) throw new Error('SQLite client not initialized');

  // gen_random_uuid() 関数を登録（PostgreSQL互換）
  sqlite.function('gen_random_uuid', () => {
    return randomUUID();
  });

  // now() 関数を登録（PostgreSQL互換）
  sqlite.function('now', () => {
    return new Date().toISOString();
  });

  sqlite.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()),
      email TEXT NOT NULL UNIQUE,
      username TEXT,
      password_hash TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      last_login_at TEXT,
      is_active INTEGER NOT NULL DEFAULT 1,
      metadata TEXT
    )
  `);

  sqlite.exec(`
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()),
      user_id TEXT NOT NULL,
      token TEXT NOT NULL UNIQUE,
      refresh_token TEXT,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      ip_address TEXT,
      user_agent TEXT,
      is_revoked INTEGER NOT NULL DEFAULT 0
    )
  `);
}

/**
 * テスト用のHonoクライアントを作成
 */
function createTestClient() {
  const app = new Hono();
  app.route('/auth', auth);

  return {
    logout: async (body: any) => {
      const req = new Request('http://localhost/auth/logout', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      return app.fetch(req);
    },
  };
}

describe('POST /auth/logout', () => {
  let validAccessToken: string;
  let testUserId: string;
  let testSessionId: string;

  beforeEach(async () => {
    initDb({ type: 'sqlite', filename: ':memory:' });
    setupTestTables();

    // テストユーザーとセッション作成（SQL直接実行でPostgreSQL型変換を回避）
    const sqlite = getSqliteClient();
    if (!sqlite) throw new Error('SQLite client not initialized');

    const passwordHash = await bcrypt.hash('password123', 10);

    testUserId = 'logout-test-user-id';
    testSessionId = 'logout-test-session-id';

    const now = new Date().toISOString();

    sqlite.prepare(`
      INSERT INTO users (id, email, password_hash, is_active, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(testUserId, 'logout-test@example.com', passwordHash, 1, now, now);

    validAccessToken = jwt.sign({ userId: testUserId, type: 'access' }, TEST_JWT_SECRET, {
      expiresIn: '1h',
    });

    const expiresAt = new Date(Date.now() + 3600 * 1000).toISOString();

    sqlite.prepare(`
      INSERT INTO sessions (id, user_id, token, expires_at, is_revoked, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(testSessionId, testUserId, validAccessToken, expiresAt, 0, now);
  });

  afterEach(async () => {
    await closeDb();
  });

  it('[正常系] ログアウトでセッションが無効化され200を返す', async () => {
    const client = createTestClient();

    const res = await client.logout({
      token: validAccessToken,
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Logout successful');

    // セッションが無効化されているか確認
    const sqlite = getSqliteClient();
    if (!sqlite) throw new Error('SQLite client not initialized');
    const session = sqlite.prepare(`SELECT * FROM sessions WHERE id = ?`).get(testSessionId) as any;
    expect(session).toBeDefined();
    expect(session.is_revoked).toBe(1); // SQLiteでは整数
  });

  it('[二重ログアウト] 存在しないトークンでも200を返す（冪等性）', async () => {
    const client = createTestClient();

    const res = await client.logout({
      token: 'non-existent-token',
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Logout successful');
  });

  it('[二重ログアウト] 既に無効化されたトークンでも200を返す', async () => {
    const client = createTestClient();

    // 1回目のログアウト
    await client.logout({
      token: validAccessToken,
    });

    // 2回目のログアウト（同じトークン）
    const res = await client.logout({
      token: validAccessToken,
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Logout successful');
  });

  it('[エッジケース] tokenが未指定で400を返す', async () => {
    const client = createTestClient();

    const res = await client.logout({});

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe('Token is required');
  });

  it('[エッジケース] 空文字列のtokenで400を返す', async () => {
    const client = createTestClient();

    const res = await client.logout({
      token: '',
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe('Token is required');
  });

  it('[エッジケース] 複数のセッションがある場合、指定したトークンのみ無効化', async () => {
    const sqlite = getSqliteClient();
    if (!sqlite) throw new Error('SQLite client not initialized');

    // 2つ目のセッション作成（ユニークなトークンを生成）
    const secondAccessToken = jwt.sign({ userId: testUserId, type: 'access', sessionId: 'second' }, TEST_JWT_SECRET, {
      expiresIn: '1h',
    });

    const expiresAt = new Date(Date.now() + 3600 * 1000).toISOString();
    const now = new Date().toISOString();

    sqlite.prepare(`
      INSERT INTO sessions (id, user_id, token, expires_at, is_revoked, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run('second-session-id', testUserId, secondAccessToken, expiresAt, 0, now);

    const client = createTestClient();

    // 1つ目のセッションをログアウト
    const res = await client.logout({
      token: validAccessToken,
    });

    expect(res.status).toBe(200);

    // 1つ目のセッションが無効化されているか確認
    const firstSession = sqlite.prepare(`SELECT * FROM sessions WHERE id = ?`).get(testSessionId) as any;
    expect(firstSession.is_revoked).toBe(1);

    // 2つ目のセッションは有効なまま
    const secondSession = sqlite.prepare(`SELECT * FROM sessions WHERE id = ?`).get('second-session-id') as any;
    expect(secondSession.is_revoked).toBe(0);
  });
});
