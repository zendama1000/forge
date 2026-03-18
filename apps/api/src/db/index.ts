/**
 * Database Abstraction Layer
 *
 * PostgreSQL (本番) と SQLite (テスト) の切り替え可能な抽象化レイヤー
 */

import { drizzle as drizzlePg } from 'drizzle-orm/node-postgres';
import { drizzle as drizzleBetterSqlite } from 'drizzle-orm/better-sqlite3';
import { migrate as migratePg } from 'drizzle-orm/node-postgres/migrator';
import { migrate as migrateSqlite } from 'drizzle-orm/better-sqlite3/migrator';
import Database from 'better-sqlite3';
import pg from 'pg';
import * as schema from './schema.js';

// ===========================
// Types
// ===========================

export type DbInstance = ReturnType<typeof drizzlePg<typeof schema>> | ReturnType<typeof drizzleBetterSqlite<typeof schema>>;
export type DbConfig = PostgresConfig | SqliteConfig;

export interface PostgresConfig {
  type: 'postgres';
  connectionString: string;
  ssl?: boolean;
  maxConnections?: number;
}

export interface SqliteConfig {
  type: 'sqlite';
  filename?: string; // デフォルト: ':memory:'
}

// ===========================
// Database Connection Manager
// ===========================

let dbInstance: DbInstance | null = null;
let clientInstance: pg.Pool | Database.Database | null = null;

/**
 * データベース接続を初期化
 *
 * @param config - DB設定（未指定時は環境変数から自動判定）
 * @returns Drizzle ORM インスタンス
 */
export function initDb(config?: DbConfig): DbInstance {
  // 既存接続がある場合はクローズ
  if (dbInstance) {
    closeDb();
  }

  const dbConfig = config || getConfigFromEnv();

  if (dbConfig.type === 'postgres') {
    const pool = new pg.Pool({
      connectionString: dbConfig.connectionString,
      ssl: dbConfig.ssl ? { rejectUnauthorized: false } : false,
      max: dbConfig.maxConnections || 20,
    });

    clientInstance = pool;
    dbInstance = drizzlePg(pool, { schema });
  } else {
    // SQLite (テスト用)
    const filename = dbConfig.filename || ':memory:';
    const sqlite = new Database(filename);

    clientInstance = sqlite;
    dbInstance = drizzleBetterSqlite(sqlite, { schema });
  }

  return dbInstance;
}

/**
 * 既存のDB接続を取得（未初期化の場合は自動初期化）
 *
 * @returns Drizzle ORM インスタンス
 */
export function getDb(): DbInstance {
  if (!dbInstance) {
    return initDb();
  }
  return dbInstance;
}

/**
 * DB接続をクローズ
 */
export async function closeDb(): Promise<void> {
  if (!clientInstance) return;

  if (clientInstance instanceof pg.Pool) {
    await clientInstance.end();
  } else if (clientInstance instanceof Database) {
    clientInstance.close();
  }

  dbInstance = null;
  clientInstance = null;
}

/**
 * テスト用: SQLiteクライアントインスタンスを取得
 * @returns Database インスタンス or null
 */
export function getSqliteClient(): Database.Database | null {
  if (clientInstance instanceof Database) {
    return clientInstance;
  }
  return null;
}

/**
 * マイグレーション実行
 *
 * @param migrationsFolder - マイグレーションフォルダパス
 */
export async function runMigrations(migrationsFolder: string = './drizzle'): Promise<void> {
  if (!dbInstance || !clientInstance) {
    throw new Error('Database not initialized. Call initDb() first.');
  }

  if (clientInstance instanceof pg.Pool) {
    await migratePg(dbInstance as ReturnType<typeof drizzlePg>, { migrationsFolder });
  } else if (clientInstance instanceof Database) {
    migrateSqlite(dbInstance as ReturnType<typeof drizzleBetterSqlite>, { migrationsFolder });
  }
}

/**
 * 環境変数からDB設定を取得
 *
 * NODE_ENV=test → SQLite (インメモリ)
 * それ以外 → PostgreSQL (DATABASE_URL)
 */
function getConfigFromEnv(): DbConfig {
  const nodeEnv = process.env.NODE_ENV || 'development';
  const isTest = nodeEnv === 'test';

  if (isTest) {
    return {
      type: 'sqlite',
      filename: ':memory:',
    };
  }

  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error('DATABASE_URL environment variable is required for non-test environments');
  }

  return {
    type: 'postgres',
    connectionString,
    ssl: process.env.DB_SSL === 'true',
    maxConnections: process.env.DB_MAX_CONNECTIONS
      ? parseInt(process.env.DB_MAX_CONNECTIONS, 10)
      : 20,
  };
}

// ===========================
// Transaction Helper
// ===========================

/**
 * トランザクション実行ヘルパー
 *
 * @param callback - トランザクション内で実行する処理
 * @returns コールバックの戻り値
 */
export async function withTransaction<T>(
  callback: (tx: DbInstance) => Promise<T>
): Promise<T> {
  const db = getDb();

  // Drizzle ORM の transaction API を使用
  // @ts-ignore - transaction メソッドの型定義が不完全
  return db.transaction(callback);
}

// ===========================
// Exports
// ===========================

export { schema };
export * from './schema.js';
