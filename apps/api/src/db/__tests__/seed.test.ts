/**
 * Layer 2 Tests: シードデータ投入機能テスト
 *
 * 検証項目:
 * - シードデータが正しく投入されること
 * - 必要なテーブルにデータが挿入されること
 * - リレーションが正しく保たれること
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';
import * as schema from '../schema';
import { eq } from 'drizzle-orm';

describe('Database Seed - Layer 2', () => {
  let sqlite: Database.Database;
  let db: ReturnType<typeof drizzle>;

  beforeAll(async () => {
    // インメモリSQLiteでテスト
    sqlite = new Database(':memory:');
    db = drizzle(sqlite, { schema });

    // テーブル作成（簡易版 - 本番はマイグレーション使用）
    sqlite.exec(`
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        username TEXT,
        password_hash TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_login_at TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        metadata TEXT
      );

      CREATE TABLE worlds (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        dimensions TEXT NOT NULL,
        content TEXT,
        tags TEXT,
        is_public INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        view_count INTEGER NOT NULL DEFAULT 0,
        like_count INTEGER NOT NULL DEFAULT 0,
        metadata TEXT
      );

      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        token TEXT NOT NULL UNIQUE,
        refresh_token TEXT,
        expires_at TEXT NOT NULL,
        created_at TEXT NOT NULL,
        ip_address TEXT,
        user_agent TEXT,
        is_revoked INTEGER NOT NULL DEFAULT 0
      );
    `);
  });

  afterAll(() => {
    sqlite.close();
  });

  it('ユーザーデータが正しく投入されること', async () => {
    // シンプルなユーザー作成テスト
    const [user] = await db.insert(schema.users).values({
      email: 'test@example.com',
      username: 'testuser',
      passwordHash: 'hashed_password',
      isActive: true,
    }).returning();

    expect(user).toBeDefined();
    expect(user.email).toBe('test@example.com');
    expect(user.username).toBe('testuser');
    expect(user.isActive).toBe(true);
  });

  it('Worldsデータが正しく投入されること', async () => {
    // ユーザー作成
    const [user] = await db.insert(schema.users).values({
      email: 'world-owner@example.com',
      username: 'worldowner',
      passwordHash: 'hashed',
      isActive: true,
    }).returning();

    // World作成
    const [world] = await db.insert(schema.worlds).values({
      userId: user.id,
      title: 'Test World',
      description: 'A test world',
      dimensions: {
        complexity: 0.5,
        novelty: 0.5,
        coherence: 0.5,
        emotion: 0.5,
        interactivity: 0.5,
        scale: 0.5,
        uncertainty: 0.5,
      },
      tags: ['test'],
      isPublic: true,
    }).returning();

    expect(world).toBeDefined();
    expect(world.title).toBe('Test World');
    expect(world.userId).toBe(user.id);
    expect(world.isPublic).toBe(true);
  });

  it('セッションデータが正しく投入されること', async () => {
    // ユーザー作成
    const [user] = await db.insert(schema.users).values({
      email: 'session-user@example.com',
      username: 'sessionuser',
      passwordHash: 'hashed',
      isActive: true,
    }).returning();

    const expiresAt = new Date();
    expiresAt.setHours(expiresAt.getHours() + 24);

    // セッション作成
    const [session] = await db.insert(schema.sessions).values({
      userId: user.id,
      token: 'test-token-' + Date.now(),
      expiresAt,
      isRevoked: false,
    }).returning();

    expect(session).toBeDefined();
    expect(session.userId).toBe(user.id);
    expect(session.isRevoked).toBe(false);
  });

  // エッジケース: 重複メール登録は失敗すること
  it('重複メールアドレスでユーザー作成は失敗すること', async () => {
    await db.insert(schema.users).values({
      email: 'duplicate@example.com',
      username: 'user1',
      passwordHash: 'hashed',
      isActive: true,
    });

    // 同じメールで再度作成
    await expect(async () => {
      await db.insert(schema.users).values({
        email: 'duplicate@example.com',
        username: 'user2',
        passwordHash: 'hashed',
        isActive: true,
      });
    }).rejects.toThrow();
  });

  // エッジケース: JSONBフィールドが正しく保存されること
  it('JSONB形式のdimensionsが正しく保存・取得されること', async () => {
    const [user] = await db.insert(schema.users).values({
      email: 'jsonb-test@example.com',
      username: 'jsonbuser',
      passwordHash: 'hashed',
      isActive: true,
    }).returning();

    const testDimensions = {
      complexity: 0.123,
      novelty: 0.456,
      coherence: 0.789,
      emotion: 0.321,
      interactivity: 0.654,
      scale: 0.987,
      uncertainty: 0.111,
    };

    const [world] = await db.insert(schema.worlds).values({
      userId: user.id,
      title: 'JSONB Test',
      description: 'Testing JSONB',
      dimensions: testDimensions,
      isPublic: false,
    }).returning();

    // 取得して検証
    const retrieved = await db.select().from(schema.worlds).where(eq(schema.worlds.id, world.id));
    expect(retrieved[0].dimensions).toEqual(testDimensions);
  });
});
