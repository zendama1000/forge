/**
 * Authentication Handlers - Layer 1 Tests
 *
 * 各エンドポイントの基本動作を検証
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { testClient } from 'hono/testing';
import auth from '../auth.js';
import { initDb, closeDb, getDb } from '../../db/index.js';
import { users, sessions } from '../../db/schema.js';
import { eq } from 'drizzle-orm';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';

// テスト用のJWT_SECRET
const TEST_JWT_SECRET = 'test-secret-key';
process.env.JWT_SECRET = TEST_JWT_SECRET;
process.env.JWT_EXPIRES_IN = '1h';
process.env.REFRESH_TOKEN_EXPIRES_IN = '7d';

describe('POST /auth/signup', () => {
  beforeEach(async () => {
    // SQLiteインメモリDB初期化
    initDb({ type: 'sqlite', filename: ':memory:' });
    const db = getDb();

    // テーブル作成（簡易版）
    await db.run(`
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
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

    await db.run(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
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
  });

  afterEach(async () => {
    await closeDb();
  });

  it('正常系: 新規ユーザー登録が成功する', async () => {
    const client = testClient(auth);

    const res = await client.signup.$post({
      json: {
        email: 'test@example.com',
        password: 'password123',
        username: 'testuser',
      },
    });

    expect(res.status).toBe(201);

    const data = await res.json();
    expect(data.message).toBe('User created successfully');
    expect(data.user).toHaveProperty('id');
    expect(data.user.email).toBe('test@example.com');
    expect(data.user.username).toBe('testuser');
    expect(data.tokens).toHaveProperty('accessToken');
    expect(data.tokens).toHaveProperty('refreshToken');

    // DBにユーザーが作成されているか確認
    const db = getDb();
    const foundUsers = await db.select().from(users).where(eq(users.email, 'test@example.com'));
    expect(foundUsers.length).toBe(1);

    // パスワードがハッシュ化されているか確認
    const isHashValid = await bcrypt.compare('password123', foundUsers[0].passwordHash);
    expect(isHashValid).toBe(true);

    // セッションが作成されているか確認
    const foundSessions = await db.select().from(sessions).where(eq(sessions.userId, foundUsers[0].id));
    expect(foundSessions.length).toBe(1);
  });

  it('異常系: 必須フィールド欠如時に400を返す', async () => {
    const client = testClient(auth);

    const res = await client.signup.$post({
      json: {
        email: 'test@example.com',
        // password が欠如
      } as any,
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe('Email and password are required');
  });

  it('異常系: パスワードが短すぎる場合に400を返す', async () => {
    const client = testClient(auth);

    const res = await client.signup.$post({
      json: {
        email: 'test@example.com',
        password: 'short',
      },
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe('Password must be at least 8 characters');
  });

  it('異常系: 既存メールアドレスの場合に409を返す', async () => {
    const client = testClient(auth);

    // 1回目の登録
    await client.signup.$post({
      json: {
        email: 'duplicate@example.com',
        password: 'password123',
      },
    });

    // 2回目の登録（重複）
    const res = await client.signup.$post({
      json: {
        email: 'duplicate@example.com',
        password: 'password456',
      },
    });

    expect(res.status).toBe(409);
    const data = await res.json();
    expect(data.error).toBe('Email already registered');
  });

  it('エッジケース: usernameが省略された場合でも登録できる', async () => {
    const client = testClient(auth);

    const res = await client.signup.$post({
      json: {
        email: 'nousername@example.com',
        password: 'password123',
      },
    });

    expect(res.status).toBe(201);
    const data = await res.json();
    expect(data.user.username).toBeNull();
  });
});

describe('POST /auth/login', () => {
  beforeEach(async () => {
    initDb({ type: 'sqlite', filename: ':memory:' });
    const db = getDb();

    await db.run(`
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
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

    await db.run(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
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

    // テストユーザー作成
    const passwordHash = await bcrypt.hash('password123', 10);
    await db.insert(users).values({
      id: 'user-1',
      email: 'login@example.com',
      passwordHash,
      isActive: true,
    });
  });

  afterEach(async () => {
    await closeDb();
  });

  it('正常系: 正しいメールアドレスとパスワードでログインできる', async () => {
    const client = testClient(auth);

    const res = await client.login.$post({
      json: {
        email: 'login@example.com',
        password: 'password123',
      },
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Login successful');
    expect(data.user.email).toBe('login@example.com');
    expect(data.tokens).toHaveProperty('accessToken');
    expect(data.tokens).toHaveProperty('refreshToken');

    // トークンの検証
    const decoded = jwt.verify(data.tokens.accessToken, TEST_JWT_SECRET) as any;
    expect(decoded.userId).toBe('user-1');
    expect(decoded.type).toBe('access');
  });

  it('異常系: 存在しないメールアドレスで401を返す', async () => {
    const client = testClient(auth);

    const res = await client.login.$post({
      json: {
        email: 'nonexistent@example.com',
        password: 'password123',
      },
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Invalid email or password');
  });

  it('異常系: 間違ったパスワードで401を返す', async () => {
    const client = testClient(auth);

    const res = await client.login.$post({
      json: {
        email: 'login@example.com',
        password: 'wrongpassword',
      },
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Invalid email or password');
  });

  it('異常系: 非アクティブユーザーで403を返す', async () => {
    const db = getDb();

    // ユーザーを非アクティブに変更
    await db.update(users).set({ isActive: false }).where(eq(users.id, 'user-1'));

    const client = testClient(auth);

    const res = await client.login.$post({
      json: {
        email: 'login@example.com',
        password: 'password123',
      },
    });

    expect(res.status).toBe(403);
    const data = await res.json();
    expect(data.error).toBe('Account is inactive');
  });
});

describe('POST /auth/refresh', () => {
  let validRefreshToken: string;

  beforeEach(async () => {
    initDb({ type: 'sqlite', filename: ':memory:' });
    const db = getDb();

    await db.run(`
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
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

    await db.run(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
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

    // テストユーザーとセッション作成
    const passwordHash = await bcrypt.hash('password123', 10);
    await db.insert(users).values({
      id: 'user-2',
      email: 'refresh@example.com',
      passwordHash,
      isActive: true,
    });

    validRefreshToken = jwt.sign({ userId: 'user-2', type: 'refresh' }, TEST_JWT_SECRET, {
      expiresIn: '7d',
    });

    const accessToken = jwt.sign({ userId: 'user-2', type: 'access' }, TEST_JWT_SECRET, {
      expiresIn: '1h',
    });

    await db.insert(sessions).values({
      id: 'session-1',
      userId: 'user-2',
      token: accessToken,
      refreshToken: validRefreshToken,
      expiresAt: new Date(Date.now() + 3600 * 1000),
      isRevoked: false,
    });
  });

  afterEach(async () => {
    await closeDb();
  });

  it('正常系: リフレッシュトークンで新しいトークンを取得できる', async () => {
    const client = testClient(auth);

    const res = await client.refresh.$post({
      json: {
        refreshToken: validRefreshToken,
      },
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Token refreshed successfully');
    expect(data.tokens).toHaveProperty('accessToken');
    expect(data.tokens).toHaveProperty('refreshToken');

    // 古いセッションが無効化されているか確認
    const db = getDb();
    const oldSession = await db.select().from(sessions).where(eq(sessions.id, 'session-1'));
    expect(oldSession[0].isRevoked).toBe(true);
  });

  it('異常系: 無効なリフレッシュトークンで401を返す', async () => {
    const client = testClient(auth);

    const res = await client.refresh.$post({
      json: {
        refreshToken: 'invalid-token',
      },
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Invalid or expired refresh token');
  });

  it('異常系: アクセストークンを使用した場合に401を返す', async () => {
    const accessToken = jwt.sign({ userId: 'user-2', type: 'access' }, TEST_JWT_SECRET, {
      expiresIn: '1h',
    });

    const client = testClient(auth);

    const res = await client.refresh.$post({
      json: {
        refreshToken: accessToken,
      },
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Invalid token type');
  });

  it('エッジケース: 無効化済みセッションのトークンで401を返す', async () => {
    const db = getDb();

    // セッションを無効化
    await db.update(sessions).set({ isRevoked: true }).where(eq(sessions.id, 'session-1'));

    const client = testClient(auth);

    const res = await client.refresh.$post({
      json: {
        refreshToken: validRefreshToken,
      },
    });

    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe('Session not found or revoked');
  });
});

describe('POST /auth/logout', () => {
  let validAccessToken: string;

  beforeEach(async () => {
    initDb({ type: 'sqlite', filename: ':memory:' });
    const db = getDb();

    await db.run(`
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
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

    await db.run(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
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

    // テストユーザーとセッション作成
    const passwordHash = await bcrypt.hash('password123', 10);
    await db.insert(users).values({
      id: 'user-3',
      email: 'logout@example.com',
      passwordHash,
      isActive: true,
    });

    validAccessToken = jwt.sign({ userId: 'user-3', type: 'access' }, TEST_JWT_SECRET, {
      expiresIn: '1h',
    });

    await db.insert(sessions).values({
      id: 'session-2',
      userId: 'user-3',
      token: validAccessToken,
      expiresAt: new Date(Date.now() + 3600 * 1000),
      isRevoked: false,
    });
  });

  afterEach(async () => {
    await closeDb();
  });

  it('正常系: ログアウトでセッションが無効化される', async () => {
    const client = testClient(auth);

    const res = await client.logout.$post({
      json: {
        token: validAccessToken,
      },
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Logout successful');

    // セッションが無効化されているか確認
    const db = getDb();
    const session = await db.select().from(sessions).where(eq(sessions.id, 'session-2'));
    expect(session[0].isRevoked).toBe(true);
  });

  it('エッジケース: 存在しないトークンでも成功を返す（冪等性）', async () => {
    const client = testClient(auth);

    const res = await client.logout.$post({
      json: {
        token: 'non-existent-token',
      },
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.message).toBe('Logout successful');
  });

  it('異常系: トークンが未指定の場合に400を返す', async () => {
    const client = testClient(auth);

    const res = await client.logout.$post({
      json: {} as any,
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBe('Token is required');
  });
});
