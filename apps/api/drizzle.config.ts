/**
 * Drizzle Kit Configuration
 *
 * マイグレーション生成・管理のための設定ファイル
 */

import type { Config } from 'drizzle-kit';

export default {
  schema: './src/db/schema.ts',
  out: './src/db/migrations',
  driver: 'pg',
  dbCredentials: {
    connectionString: process.env.DATABASE_URL || 'postgresql://localhost:5432/forge_dev',
  },
  verbose: true,
  strict: true,
} satisfies Config;
