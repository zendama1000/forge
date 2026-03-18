/**
 * Database Migration Runner
 *
 * Drizzle ORMマイグレーション適用・ロールバックスクリプト
 */

import { drizzle } from 'drizzle-orm/node-postgres';
import { migrate } from 'drizzle-orm/node-postgres/migrator';
import { Pool } from 'pg';
import * as path from 'path';
import * as fs from 'fs';

const DATABASE_URL = process.env.DATABASE_URL;

if (!DATABASE_URL) {
  console.error('❌ DATABASE_URL environment variable is not set');
  process.exit(1);
}

const MIGRATIONS_FOLDER = path.join(__dirname, 'migrations');

/**
 * マイグレーション適用
 */
async function runMigrations() {
  console.log('🚀 Running migrations...');
  console.log(`Migrations folder: ${MIGRATIONS_FOLDER}`);

  const pool = new Pool({ connectionString: DATABASE_URL });
  const db = drizzle(pool);

  try {
    // マイグレーションフォルダが存在するか確認
    if (!fs.existsSync(MIGRATIONS_FOLDER)) {
      console.log('⚠️  No migrations folder found. Creating...');
      fs.mkdirSync(MIGRATIONS_FOLDER, { recursive: true });
      console.log('✅ Migrations folder created');
      await pool.end();
      return;
    }

    // マイグレーション実行
    await migrate(db, { migrationsFolder: MIGRATIONS_FOLDER });
    console.log('✅ Migrations completed successfully');
  } catch (error) {
    console.error('❌ Migration failed:', error);
    throw error;
  } finally {
    await pool.end();
  }
}

/**
 * マイグレーションロールバック（手動実装）
 * Drizzle ORMは自動ロールバックをサポートしていないため、
 * マイグレーションファイルの.downセクションを手動実行する必要がある
 */
async function rollbackMigration(steps: number = 1) {
  console.log(`⏮️  Rolling back ${steps} migration(s)...`);

  const pool = new Pool({ connectionString: DATABASE_URL });

  try {
    // マイグレーション履歴テーブルから最新のマイグレーションを取得
    const client = await pool.connect();

    // Drizzleのマイグレーション管理テーブル
    const result = await client.query(
      `SELECT * FROM "__drizzle_migrations" ORDER BY created_at DESC LIMIT $1`,
      [steps]
    );

    if (result.rows.length === 0) {
      console.log('⚠️  No migrations to rollback');
      client.release();
      return;
    }

    console.log(`Found ${result.rows.length} migration(s) to rollback:`);
    result.rows.forEach((row, i) => {
      console.log(`  ${i + 1}. ${row.hash} (${row.created_at})`);
    });

    // ロールバック実行の注意書き
    console.log(`
⚠️  WARNING: Drizzle ORM does not support automatic rollback.
You need to manually write and execute the rollback SQL.

To rollback, you can:
1. Write a custom SQL script to reverse the migrations
2. Use Drizzle Studio to manually modify the schema
3. Drop and recreate the database (development only)

Migrations to rollback:
${result.rows.map(r => `  - ${r.hash}`).join('\n')}
    `);

    client.release();
  } catch (error) {
    console.error('❌ Rollback failed:', error);
    throw error;
  } finally {
    await pool.end();
  }
}

/**
 * マイグレーション状態確認
 */
async function checkMigrationStatus() {
  console.log('📊 Checking migration status...');

  const pool = new Pool({ connectionString: DATABASE_URL });

  try {
    const client = await pool.connect();

    // マイグレーション履歴テーブルが存在するか確認
    const tableExists = await client.query(`
      SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_name = '__drizzle_migrations'
      );
    `);

    if (!tableExists.rows[0].exists) {
      console.log('⚠️  No migrations have been run yet');
      client.release();
      return;
    }

    // 適用済みマイグレーション一覧
    const result = await client.query(
      `SELECT * FROM "__drizzle_migrations" ORDER BY created_at ASC`
    );

    if (result.rows.length === 0) {
      console.log('⚠️  No migrations found in database');
    } else {
      console.log(`✅ Found ${result.rows.length} applied migration(s):\n`);
      result.rows.forEach((row, i) => {
        console.log(`  ${i + 1}. ${row.hash}`);
        console.log(`     Created: ${row.created_at}`);
      });
    }

    client.release();
  } catch (error) {
    console.error('❌ Status check failed:', error);
    throw error;
  } finally {
    await pool.end();
  }
}

// CLI実行
if (require.main === module) {
  const command = process.argv[2];
  const args = process.argv.slice(3);

  switch (command) {
    case 'up':
    case 'apply':
      runMigrations()
        .then(() => process.exit(0))
        .catch(() => process.exit(1));
      break;

    case 'down':
    case 'rollback':
      const steps = parseInt(args[0]) || 1;
      rollbackMigration(steps)
        .then(() => process.exit(0))
        .catch(() => process.exit(1));
      break;

    case 'status':
      checkMigrationStatus()
        .then(() => process.exit(0))
        .catch(() => process.exit(1));
      break;

    default:
      console.log(`
Usage: node migrate.js <command> [options]

Commands:
  up, apply         Apply all pending migrations
  down, rollback    Rollback migrations (manual process)
  status            Show migration status

Examples:
  node migrate.js up
  node migrate.js status
  node migrate.js rollback 1
      `);
      process.exit(0);
  }
}

export { runMigrations, rollbackMigration, checkMigrationStatus };
