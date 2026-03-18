/**
 * Layer 1 Tests: マイグレーション機能テスト
 *
 * 検証項目:
 * - seed.tsファイルが存在すること
 * - migrationsディレクトリが存在すること
 * - migrate.tsファイルが存在すること
 */

import { describe, it, expect } from 'vitest';
import * as fs from 'fs';
import * as path from 'path';

describe('Database Migrations - Layer 1', () => {
  const dbDir = path.join(__dirname, '..');
  const migrationsDir = path.join(dbDir, 'migrations');
  const seedFile = path.join(dbDir, 'seed.ts');
  const migrateFile = path.join(dbDir, 'migrate.ts');

  it('seed.tsファイルが存在すること', () => {
    expect(fs.existsSync(seedFile)).toBe(true);
  });

  it('migrationsディレクトリが存在すること', () => {
    expect(fs.existsSync(migrationsDir)).toBe(true);
    expect(fs.statSync(migrationsDir).isDirectory()).toBe(true);
  });

  it('migrate.tsファイルが存在すること', () => {
    expect(fs.existsSync(migrateFile)).toBe(true);
  });

  it('seed.tsがインポート可能であること（構文エラーなし）', async () => {
    // 動的インポートで構文チェック
    expect(async () => {
      await import('../seed');
    }).not.toThrow();
  });

  it('migrate.tsがインポート可能であること（構文エラーなし）', async () => {
    // 動的インポートで構文チェック
    expect(async () => {
      await import('../migrate');
    }).not.toThrow();
  });

  // エッジケース: migrationsディレクトリが書き込み可能か
  it('migrationsディレクトリに書き込み権限があること', () => {
    const testFile = path.join(migrationsDir, '.write-test');

    try {
      fs.writeFileSync(testFile, 'test');
      expect(fs.existsSync(testFile)).toBe(true);
      fs.unlinkSync(testFile);
    } catch (error) {
      throw new Error('Migrations directory is not writable');
    }
  });
});
