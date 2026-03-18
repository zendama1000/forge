/**
 * L1-005: Authentication - Login Tests
 *
 * login エンドポイントのユニットテスト
 * - 正常系: 200 OK + トークン
 * - 不正パスワード: 401 Unauthorized
 * - 存在しないユーザー: 401 Unauthorized
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
    login: async (body: any) => {
      const req = new Request('http://localhost/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      return app.fetch(req);
    },
  };
}

describe('POST /auth/login', () => {
  beforeEach(async () => {
    initDb({ type: 'sqlite', filename: ':memory:' });
    setupTestTables();

    // テストユーザー作成（SQL直接実行でPostgreSQL型変換を回避）
    const sqlite = getSqliteClient();
    if (!sqlite) throw new Error('SQLite client not initialized');

    const passwordHash = await bcrypt.hash('correct-password', 10);
    const now = new Date().toISOString();

    sqlite.prepare(`
      INSERT INTO users (id, email, password_hash, is_active, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run('test-user-id', 'login-test@example.com', passwordHash, 1, now, now);
  });

  afterEach(async () => {
    await closeDb();
  });

  it('[正常系] 正しいメールアドレスとパスワードで200+トークンを返す', async () => {
    const client = createTestClient();

    const res = await client.login({
      email: 'login-test@example.com',
      password: 'correct-password',
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Login successful');
    expect(data.user.email).toBe('login-test@example.com');
    expect(data.tokens).toHaveProperty('accessToken');
    expect(data.tokens).toHaveProperty('refreshToken');

    // トークンの検証
    const decoded = jwt.verify(data.tokens.accessToken, TEST_JWT_SECRET) as any;
    expect(decoded.userId).toBe('test-user-id');
    expect(decoded.type).toBe('access');

    // セッションが作成されているか確認
    const db = getDb();
    const foundSessions = await db.select().from(sessions).where(eq(sessions.userId, 'test-user-id'));
    expect(foundSessions.length).toBe(1);
    expect(foundSessions[0].token).toBe(data.tokens.accessToken);
  });

  it('[不正パスワード] 間違ったパスワードで401を返す', async () => {
    const client = createTestClient();

    const res = await client.login({
      email: 'login-test@example.com',
      password: 'wrong-password',
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Invalid email or password');
  });

  it('[存在しないユーザー] 存在しないメールアドレスで401を返す', async () => {
    const client = createTestClient();

    const res = await client.login({
      email: 'nonexistent@example.com',
      password: 'any-password',
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Invalid email or password');
  });

  it('[エッジケース] 非アクティブユーザーで403を返す', async () => {
    const sqlite = getSqliteClient();
    if (!sqlite) throw new Error('SQLite client not initialized');

    // ユーザーを非アクティブに変更
    sqlite.prepare(`
      UPDATE users SET is_active = 0 WHERE id = ?
    `).run('test-user-id');

    const client = createTestClient();

    const res = await client.login({
      email: 'login-test@example.com',
      password: 'correct-password',
    });

    expect(res.status).toBe(403);
    const data = await res.json();
    expect(data.error).toBe('Account is inactive');
  });

  it('[エッジケース] emailが未指定で400を返す', async () => {
    const client = createTestClient();

    const res = await client.login({
      password: 'correct-password',
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe('Email and password are required');
  });

  it('[エッジケース] passwordが未指定で400を返す', async () => {
    const client = createTestClient();

    const res = await client.login({
      email: 'login-test@example.com',
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe('Email and password are required');
  });
});
