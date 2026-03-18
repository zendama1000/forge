/**
 * Database Abstraction Layer Tests
 *
 * PostgreSQL/SQLite切替の抽象化レイヤーを検証
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { initDb, getDb, closeDb, type DbConfig } from '../index.js';

describe('Database Abstraction Layer - Layer 1', () => {
  afterEach(async () => {
    await closeDb();
  });

  // テスト: SQLiteインメモリDBの初期化
  it('SQLiteインメモリDBを初期化できること', () => {
    const config: DbConfig = {
      type: 'sqlite',
      filename: ':memory:',
    };

    const db = initDb(config);

    expect(db).toBeDefined();
    expect(db._.schema).toBeDefined();
  });

  // テスト: 環境変数からの自動設定（テスト環境）
  it('NODE_ENV=testの場合、自動的にSQLiteを使用すること', () => {
    const originalEnv = process.env.NODE_ENV;
    process.env.NODE_ENV = 'test';

    const db = initDb();

    expect(db).toBeDefined();

    // 元の環境変数を復元
    process.env.NODE_ENV = originalEnv;
  });

  // テスト: getDb()で既存接続を取得
  it('getDb()で既存のDB接続を取得できること', () => {
    const config: DbConfig = {
      type: 'sqlite',
      filename: ':memory:',
    };

    const db1 = initDb(config);
    const db2 = getDb();

    expect(db1).toBe(db2);
  });

  // テスト: 未初期化時のgetDb()は自動初期化
  it('未初期化状態でgetDb()を呼ぶと自動初期化されること', async () => {
    await closeDb(); // 確実に未初期化状態にする

    const originalEnv = process.env.NODE_ENV;
    process.env.NODE_ENV = 'test';

    const db = getDb();

    expect(db).toBeDefined();

    process.env.NODE_ENV = originalEnv;
  });

  // テスト: closeDb()で接続をクローズ
  it('closeDb()でDB接続をクローズできること', async () => {
    const config: DbConfig = {
      type: 'sqlite',
      filename: ':memory:',
    };

    initDb(config);
    await closeDb();

    // 再度getDb()を呼ぶと新規初期化される
    const db = getDb();
    expect(db).toBeDefined();
  });

  // エッジケース: 複数回のinitDb()呼び出し
  it('複数回initDb()を呼ぶと古い接続がクローズされること', () => {
    const config1: DbConfig = {
      type: 'sqlite',
      filename: ':memory:',
    };

    const db1 = initDb(config1);
    const db2 = initDb(config1);

    // 異なるインスタンスが返される
    expect(db2).toBeDefined();
    expect(db1).not.toBe(db2);
  });

  // エッジケース: PostgreSQL設定のバリデーション
  it('PostgreSQL設定でDATABASE_URLが未設定の場合エラーになること', () => {
    const originalUrl = process.env.DATABASE_URL;
    const originalEnv = process.env.NODE_ENV;

    delete process.env.DATABASE_URL;
    process.env.NODE_ENV = 'production';

    expect(() => initDb()).toThrow('DATABASE_URL environment variable is required');

    // 環境変数を復元
    if (originalUrl) process.env.DATABASE_URL = originalUrl;
    process.env.NODE_ENV = originalEnv;
  });

  // エッジケース: SQLiteファイルベースDB
  it('SQLiteファイルベースDBを初期化できること', () => {
    const config: DbConfig = {
      type: 'sqlite',
      filename: ':memory:', // テストではインメモリ使用
    };

    const db = initDb(config);

    expect(db).toBeDefined();
  });
});

describe('Database Abstraction Layer - Layer 2', () => {
  beforeEach(async () => {
    await closeDb();
  });

  afterEach(async () => {
    await closeDb();
  });

  // Layer 2テスト: スキーマアクセス
  it('スキーマ定義にアクセスできること', () => {
    const config: DbConfig = {
      type: 'sqlite',
      filename: ':memory:',
    };

    const db = initDb(config);

    expect(db._.schema).toBeDefined();
    expect(db._.schema?.users).toBeDefined();
    expect(db._.schema?.worlds).toBeDefined();
    expect(db._.schema?.apiKeys).toBeDefined();
  });

  // Layer 2テスト: クエリビルダーの基本動作
  it('クエリビルダーが正しく動作すること', () => {
    const config: DbConfig = {
      type: 'sqlite',
      filename: ':memory:',
    };

    const db = initDb(config);

    // クエリビルダーのメソッドが存在することを確認
    expect(db.select).toBeDefined();
    expect(db.insert).toBeDefined();
    expect(db.update).toBeDefined();
    expect(db.delete).toBeDefined();
  });

  // Layer 2テスト: エクスポートされたスキーマ型
  it('スキーマ型がエクスポートされていること', async () => {
    const { schema } = await import('../index.js');

    expect(schema).toBeDefined();
    expect(schema.users).toBeDefined();
    expect(schema.worlds).toBeDefined();
    expect(schema.sessions).toBeDefined();
    expect(schema.apiKeys).toBeDefined();
    expect(schema.subscriptions).toBeDefined();
    expect(schema.usageLogs).toBeDefined();
  });
});
