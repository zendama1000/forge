/**
 * L1-005: Authentication - Refresh Tests
 *
 * refresh エンドポイントのユニットテスト
 * - 有効なリフレッシュトークン: 200 OK
 * - 期限切れトークン: 401 Unauthorized
 * - 無効なトークン: 401 Unauthorized
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
    refresh: async (body: any) => {
      const req = new Request('http://localhost/auth/refresh', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      return app.fetch(req);
    },
  };
}

describe('POST /auth/refresh', () => {
  let validRefreshToken: string;
  let testUserId: string;
  let testSessionId: string;

  beforeEach(async () => {
    initDb({ type: 'sqlite', filename: ':memory:' });
    setupTestTables();

    // テストユーザーとセッション作成（SQL直接実行でPostgreSQL型変換を回避）
    const sqlite = getSqliteClient();
    if (!sqlite) throw new Error('SQLite client not initialized');

    const passwordHash = await bcrypt.hash('password123', 10);

    testUserId = 'refresh-test-user-id';
    testSessionId = 'refresh-test-session-id';

    const now = new Date().toISOString();

    sqlite.prepare(`
      INSERT INTO users (id, email, password_hash, is_active, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(testUserId, 'refresh-test@example.com', passwordHash, 1, now, now);

    validRefreshToken = jwt.sign({ userId: testUserId, type: 'refresh' }, TEST_JWT_SECRET, {
      expiresIn: '7d',
    });

    const accessToken = jwt.sign({ userId: testUserId, type: 'access' }, TEST_JWT_SECRET, {
      expiresIn: '1h',
    });

    const expiresAt = new Date(Date.now() + 3600 * 1000).toISOString();

    sqlite.prepare(`
      INSERT INTO sessions (id, user_id, token, refresh_token, expires_at, is_revoked, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(testSessionId, testUserId, accessToken, validRefreshToken, expiresAt, 0, now);
  });

  afterEach(async () => {
    await closeDb();
  });

  it('[正常系] 有効なリフレッシュトークンで200+新トークンを返す', async () => {
    const client = createTestClient();

    const res = await client.refresh({
      refreshToken: validRefreshToken,
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Token refreshed successfully');
    expect(data.tokens).toHaveProperty('accessToken');
    expect(data.tokens).toHaveProperty('refreshToken');

    // 新しいトークンが古いものと異なることを確認
    expect(data.tokens.refreshToken).not.toBe(validRefreshToken);

    // 古いセッションが無効化されているか確認
    const db = getDb();
    const oldSession = await db.select().from(sessions).where(eq(sessions.id, testSessionId));
    // SQLiteではbooleanが整数(0/1)として保存されるため、truthyチェックを使用
    expect(oldSession[0].isRevoked).toBeTruthy();

    // 新しいセッションが作成されているか確認
    const allSessions = await db.select().from(sessions).where(eq(sessions.userId, testUserId));
    const activeSessions = allSessions.filter(s => !s.isRevoked);
    expect(activeSessions.length).toBe(1);
  });

  it('[期限切れ] 期限切れリフレッシュトークンで401を返す', async () => {
    // 期限切れトークン（既に期限切れ）
    const expiredToken = jwt.sign({ userId: testUserId, type: 'refresh' }, TEST_JWT_SECRET, {
      expiresIn: '-1s', // 1秒前に期限切れ
    });

    const client = createTestClient();

    const res = await client.refresh({
      refreshToken: expiredToken,
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Invalid or expired refresh token');
  });

  it('[無効なトークン] 不正な形式のトークンで401を返す', async () => {
    const client = createTestClient();

    const res = await client.refresh({
      refreshToken: 'invalid-token-format',
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Invalid or expired refresh token');
  });

  it('[無効なトークン] アクセストークンを使用した場合に401を返す', async () => {
    const accessToken = jwt.sign({ userId: testUserId, type: 'access' }, TEST_JWT_SECRET, {
      expiresIn: '1h',
    });

    const client = createTestClient();

    const res = await client.refresh({
      refreshToken: accessToken,
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    // 実装は type チェックで 'Invalid token type' を返す
    expect(data.error).toBe('Invalid token type');
  });

  it('[無効なトークン] 無効化済みセッションのトークンで401を返す', async () => {
    const sqlite = getSqliteClient();
    if (!sqlite) throw new Error('SQLite client not initialized');

    // セッションを無効化
    sqlite.prepare(`
      UPDATE sessions SET is_revoked = 1 WHERE id = ?
    `).run(testSessionId);

    const client = createTestClient();

    const res = await client.refresh({
      refreshToken: validRefreshToken,
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    // 実装は 'Session not found or revoked' を返す
    expect(data.error).toBe('Session not found or revoked');
  });

  it('[エッジケース] refreshTokenが未指定で400を返す', async () => {
    const client = createTestClient();

    const res = await client.refresh({});

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe('Refresh token is required');
  });

  it('[エッジケース] DBに存在しないが有効な署名のトークンで401を返す', async () => {
    // 有効な署名だがDBに存在しないトークン（jtiを追加して一意性を保証）
    const validButUnknownToken = jwt.sign(
      {
        userId: testUserId,
        type: 'refresh',
        jti: 'unique-unknown-token-id'
      },
      TEST_JWT_SECRET,
      {
        expiresIn: '7d',
      }
    );

    const client = createTestClient();

    const res = await client.refresh({
      refreshToken: validButUnknownToken,
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    // 実装は 'Session not found or revoked' を返す
    expect(data.error).toBe('Session not found or revoked');
  });
});
