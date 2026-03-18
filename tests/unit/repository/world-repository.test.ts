/**
 * World Repository ユニットテスト
 *
 * インメモリSQLite使用、CRUD操作のテスト
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { initDb, closeDb, getSqliteClient } from '../../../apps/api/src/db/index.js';
import { createWorldRepository } from '../../../apps/api/src/repositories/world-repository.js';
import type { DbInstance } from '../../../apps/api/src/db/index.js';
import type { WorldRepository } from '../../../apps/api/src/repositories/world-repository.js';

describe('WorldRepository', () => {
  let db: DbInstance;
  let repository: WorldRepository;

  beforeEach(() => {
    // インメモリSQLiteでDB初期化
    db = initDb({ type: 'sqlite', filename: ':memory:' });
    repository = createWorldRepository(db);

    // テーブル作成 (SQLite用の簡易スキーマ)
    const sqlite = getSqliteClient();
    if (!sqlite) {
      throw new Error('SQLite client not available');
    }

    // users テーブル
    sqlite.exec(`
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        username TEXT,
        password_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        last_login_at INTEGER,
        is_active INTEGER NOT NULL DEFAULT 1,
        metadata TEXT
      );
    `);

    // worlds テーブル
    sqlite.exec(`
      CREATE TABLE IF NOT EXISTS worlds (
        id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
        user_id TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        dimensions TEXT NOT NULL,
        content TEXT,
        tags TEXT,
        is_public INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        view_count INTEGER NOT NULL DEFAULT 0,
        like_count INTEGER NOT NULL DEFAULT 0,
        metadata TEXT,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      );
    `);

    // world_versions テーブル
    sqlite.exec(`
      CREATE TABLE IF NOT EXISTS world_versions (
        id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
        world_id TEXT NOT NULL,
        version_number INTEGER NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        dimensions TEXT NOT NULL,
        content TEXT,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        created_by TEXT,
        change_note TEXT,
        FOREIGN KEY (world_id) REFERENCES worlds(id) ON DELETE CASCADE,
        FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL
      );
    `);

    // テストユーザーを挿入
    sqlite.exec(`
      INSERT INTO users (id, email, password_hash)
      VALUES ('test-user-id', 'test@example.com', 'hashed_password');
    `);
  });

  afterEach(async () => {
    await closeDb();
  });

  describe('create + findById', () => {
    it('新規世界観を作成し、IDで取得できる', async () => {
      const worldData = {
        title: 'Test World',
        description: 'A test world',
        dimensions: {
          complexity: 5,
          novelty: 7,
          coherence: 8,
          emotion: 6,
          interactivity: 4,
          scale: 9,
          uncertainty: 3,
        },
        content: { test: 'data' },
        tags: ['test', 'world'],
        isPublic: false,
      };

      const created = await repository.create('test-user-id', worldData);

      expect(created).toBeDefined();
      expect(created.id).toBeDefined();
      expect(created.title).toBe(worldData.title);
      expect(created.userId).toBe('test-user-id');

      // findById で取得確認
      const found = await repository.findById(created.id);
      expect(found).toBeDefined();
      expect(found?.id).toBe(created.id);
      expect(found?.title).toBe(worldData.title);
    });

    it('存在しないIDで取得した場合、nullを返す', async () => {
      const result = await repository.findById('non-existent-id');
      expect(result).toBeNull();
    });
  });

  describe('findByUserId + ページネーション', () => {
    it('ユーザーIDで世界観一覧を取得できる', async () => {
      // 3つの世界観を作成 (タイムスタンプの差を保証するため待機)
      await repository.create('test-user-id', {
        title: 'World 1',
        description: 'First world',
        dimensions: {
          complexity: 5,
          novelty: 5,
          coherence: 5,
          emotion: 5,
          interactivity: 5,
          scale: 5,
          uncertainty: 5,
        },
        isPublic: false,
      });
      await new Promise(resolve => setTimeout(resolve, 1001)); // 1秒待機

      await repository.create('test-user-id', {
        title: 'World 2',
        description: 'Second world',
        dimensions: {
          complexity: 6,
          novelty: 6,
          coherence: 6,
          emotion: 6,
          interactivity: 6,
          scale: 6,
          uncertainty: 6,
        },
        isPublic: false,
      });
      await new Promise(resolve => setTimeout(resolve, 1001)); // 1秒待機

      await repository.create('test-user-id', {
        title: 'World 3',
        description: 'Third world',
        dimensions: {
          complexity: 7,
          novelty: 7,
          coherence: 7,
          emotion: 7,
          interactivity: 7,
          scale: 7,
          uncertainty: 7,
        },
        isPublic: false,
      });

      const results = await repository.findByUserId('test-user-id');
      expect(results).toHaveLength(3);
      expect(results[0].title).toBe('World 3'); // 最新順
    }, 10000); // 10秒タイムアウト

    it('ページネーション: limit=2, offset=1 で2番目から2件取得', async () => {
      // 5つの世界観を作成 (タイムスタンプの差を保証するため待機)
      for (let i = 1; i <= 5; i++) {
        await repository.create('test-user-id', {
          title: `World ${i}`,
          description: `World ${i}`,
          dimensions: {
            complexity: i,
            novelty: i,
            coherence: i,
            emotion: i,
            interactivity: i,
            scale: i,
            uncertainty: i,
          },
          isPublic: false,
        });
        await new Promise(resolve => setTimeout(resolve, 1001)); // 1秒待機
      }

      const results = await repository.findByUserId('test-user-id', {
        limit: 2,
        offset: 1,
      });

      expect(results).toHaveLength(2);
      expect(results[0].title).toBe('World 4'); // 最新から2番目
      expect(results[1].title).toBe('World 3');
    }, 10000); // 10秒タイムアウト

    it('別のユーザーの世界観は取得できない', async () => {
      await repository.create('test-user-id', {
        title: 'User 1 World',
        description: 'World',
        dimensions: {
          complexity: 5,
          novelty: 5,
          coherence: 5,
          emotion: 5,
          interactivity: 5,
          scale: 5,
          uncertainty: 5,
        },
        isPublic: false,
      });

      const results = await repository.findByUserId('other-user-id');
      expect(results).toHaveLength(0);
    });
  });

  describe('update + バージョン自動作成', () => {
    it('世界観を更新し、バージョンが自動作成される', async () => {
      const created = await repository.create('test-user-id', {
        title: 'Original Title',
        description: 'Original Description',
        dimensions: {
          complexity: 5,
          novelty: 5,
          coherence: 5,
          emotion: 5,
          interactivity: 5,
          scale: 5,
          uncertainty: 5,
        },
        isPublic: false,
      });

      // 更新
      const updated = await repository.update(created.id, {
        title: 'Updated Title',
        description: 'Updated Description',
      });

      expect(updated).toBeDefined();
      expect(updated?.title).toBe('Updated Title');
      expect(updated?.description).toBe('Updated Description');

      // バージョンが作成されているか確認
      const sqlite = getSqliteClient();
      if (!sqlite) throw new Error('SQLite client not available');

      const versions = sqlite
        .prepare('SELECT * FROM world_versions WHERE world_id = ?')
        .all(created.id);

      expect(versions).toHaveLength(1);
      expect(versions[0].version_number).toBe(1);
      expect(versions[0].title).toBe('Original Title'); // 更新前の状態が保存される
    });

    it('存在しないIDで更新した場合、nullを返す', async () => {
      const result = await repository.update('non-existent-id', {
        title: 'New Title',
      });

      expect(result).toBeNull();
    });

    it('複数回更新するとバージョン番号がインクリメントされる', async () => {
      const created = await repository.create('test-user-id', {
        title: 'Version 0',
        description: 'Initial',
        dimensions: {
          complexity: 5,
          novelty: 5,
          coherence: 5,
          emotion: 5,
          interactivity: 5,
          scale: 5,
          uncertainty: 5,
        },
        isPublic: false,
      });

      // 1回目の更新
      await repository.update(created.id, { title: 'Version 1' });

      // 2回目の更新
      await repository.update(created.id, { title: 'Version 2' });

      const sqlite = getSqliteClient();
      if (!sqlite) throw new Error('SQLite client not available');

      const versions = sqlite
        .prepare('SELECT * FROM world_versions WHERE world_id = ? ORDER BY version_number ASC')
        .all(created.id);

      expect(versions).toHaveLength(2);
      expect(versions[0].version_number).toBe(1);
      expect(versions[1].version_number).toBe(2);
    });
  });

  describe('delete + 論理削除', () => {
    it('世界観を削除できる（物理削除）', async () => {
      const created = await repository.create('test-user-id', {
        title: 'To Delete',
        description: 'Will be deleted',
        dimensions: {
          complexity: 5,
          novelty: 5,
          coherence: 5,
          emotion: 5,
          interactivity: 5,
          scale: 5,
          uncertainty: 5,
        },
        isPublic: false,
      });

      const deleted = await repository.delete(created.id);
      expect(deleted).toBe(true);

      // 削除後は取得できない
      const found = await repository.findById(created.id);
      expect(found).toBeNull();
    });

    it('存在しないIDで削除した場合、falseを返す', async () => {
      const result = await repository.delete('non-existent-id');
      expect(result).toBe(false);
    });

    it('エッジケース: 空のdescriptionでも作成・削除できる', async () => {
      const created = await repository.create('test-user-id', {
        title: 'Empty Description Test',
        description: '',
        dimensions: {
          complexity: 1,
          novelty: 1,
          coherence: 1,
          emotion: 1,
          interactivity: 1,
          scale: 1,
          uncertainty: 1,
        },
        isPublic: false,
      });

      expect(created.description).toBe('');

      const deleted = await repository.delete(created.id);
      expect(deleted).toBe(true);
    });
  });

  describe('エッジケース', () => {
    it('タイトルに特殊文字が含まれていても正常に動作する', async () => {
      const created = await repository.create('test-user-id', {
        title: 'Test <script>alert("XSS")</script> World',
        description: 'Special chars: & < > " \' /',
        dimensions: {
          complexity: 5,
          novelty: 5,
          coherence: 5,
          emotion: 5,
          interactivity: 5,
          scale: 5,
          uncertainty: 5,
        },
        isPublic: false,
      });

      expect(created.title).toContain('<script>');

      const found = await repository.findById(created.id);
      expect(found?.title).toBe(created.title);
    });

    it('非常に大きなコンテンツでも保存できる', async () => {
      const largeContent = {
        data: 'x'.repeat(100000), // 100KB
      };

      const created = await repository.create('test-user-id', {
        title: 'Large Content',
        description: 'Very large content test',
        dimensions: {
          complexity: 5,
          novelty: 5,
          coherence: 5,
          emotion: 5,
          interactivity: 5,
          scale: 5,
          uncertainty: 5,
        },
        content: largeContent,
        isPublic: false,
      });

      const found = await repository.findById(created.id);
      expect(found?.content).toEqual(largeContent);
    });
  });
});
