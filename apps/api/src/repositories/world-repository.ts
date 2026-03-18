/**
 * World Repository - 宗教世界観データのCRUDリポジトリ
 *
 * インメモリDB対応、バージョン自動作成、論理削除をサポート
 */

import { randomUUID } from 'crypto';
import type { DbInstance } from '../db/index.js';
import { getSqliteClient } from '../db/index.js';
import type { World, NewWorld } from '../db/schema.js';

export interface PaginationOptions {
  limit?: number;
  offset?: number;
}

export interface WorldRepository {
  create(userId: string, worldData: Omit<NewWorld, 'userId' | 'id'>): Promise<World>;
  findById(id: string): Promise<World | null>;
  findByUserId(userId: string, pagination?: PaginationOptions): Promise<World[]>;
  update(id: string, worldData: Partial<Omit<World, 'id' | 'userId' | 'createdAt'>>): Promise<World | null>;
  delete(id: string): Promise<boolean>;
}

/**
 * World Repository 実装
 */
export class WorldRepositoryImpl implements WorldRepository {
  constructor(private db: DbInstance) {}

  /**
   * 新規世界観を作成
   */
  async create(userId: string, worldData: Omit<NewWorld, 'userId' | 'id'>): Promise<World> {
    const sqlite = getSqliteClient();
    if (!sqlite) {
      throw new Error('SQLite client not available');
    }

    const now = Math.floor(Date.now() / 1000);
    const id = randomUUID();

    const stmt = sqlite.prepare(`
      INSERT INTO worlds (
        id, user_id, title, description, dimensions, content, tags,
        is_public, created_at, updated_at, view_count, like_count, metadata
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      userId,
      worldData.title,
      worldData.description,
      JSON.stringify(worldData.dimensions),
      worldData.content ? JSON.stringify(worldData.content) : null,
      worldData.tags ? JSON.stringify(worldData.tags) : null,
      worldData.isPublic ? 1 : 0,
      now,
      now,
      0,
      0,
      worldData.metadata ? JSON.stringify(worldData.metadata) : null
    );

    const created = await this.findById(id);
    if (!created) {
      throw new Error('Failed to create world');
    }

    return created;
  }

  /**
   * IDで世界観を取得
   */
  async findById(id: string): Promise<World | null> {
    const sqlite = getSqliteClient();
    if (!sqlite) {
      throw new Error('SQLite client not available');
    }

    const stmt = sqlite.prepare('SELECT * FROM worlds WHERE id = ? LIMIT 1');
    const row = stmt.get(id);

    if (!row) {
      return null;
    }

    return this.parseWorldRow(row);
  }

  /**
   * ユーザーIDで世界観一覧を取得（ページネーション対応）
   */
  async findByUserId(userId: string, pagination?: PaginationOptions): Promise<World[]> {
    const sqlite = getSqliteClient();
    if (!sqlite) {
      throw new Error('SQLite client not available');
    }

    const limit = pagination?.limit ?? 20;
    const offset = pagination?.offset ?? 0;

    const stmt = sqlite.prepare(`
      SELECT * FROM worlds
      WHERE user_id = ?
      ORDER BY created_at DESC
      LIMIT ? OFFSET ?
    `);

    const rows = stmt.all(userId, limit, offset);
    return rows.map(row => this.parseWorldRow(row));
  }

  /**
   * 世界観を更新（バージョン自動作成）
   */
  async update(id: string, worldData: Partial<Omit<World, 'id' | 'userId' | 'createdAt'>>): Promise<World | null> {
    const sqlite = getSqliteClient();
    if (!sqlite) {
      throw new Error('SQLite client not available');
    }

    // 既存の世界観を取得
    const existing = await this.findById(id);
    if (!existing) {
      return null;
    }

    // 更新前の状態をバージョンとして保存
    await this.createVersion(existing);

    // 更新
    const now = Math.floor(Date.now() / 1000);
    const updates: string[] = [];
    const values: any[] = [];

    if (worldData.title !== undefined) {
      updates.push('title = ?');
      values.push(worldData.title);
    }
    if (worldData.description !== undefined) {
      updates.push('description = ?');
      values.push(worldData.description);
    }
    if (worldData.dimensions !== undefined) {
      updates.push('dimensions = ?');
      values.push(JSON.stringify(worldData.dimensions));
    }
    if (worldData.content !== undefined) {
      updates.push('content = ?');
      values.push(JSON.stringify(worldData.content));
    }

    updates.push('updated_at = ?');
    values.push(now);

    values.push(id);

    const stmt = sqlite.prepare(`UPDATE worlds SET ${updates.join(', ')} WHERE id = ?`);
    stmt.run(...values);

    return this.findById(id);
  }

  /**
   * 世界観を削除（物理削除）
   */
  async delete(id: string): Promise<boolean> {
    const sqlite = getSqliteClient();
    if (!sqlite) {
      throw new Error('SQLite client not available');
    }

    const existing = await this.findById(id);
    if (!existing) {
      return false;
    }

    const stmt = sqlite.prepare('DELETE FROM worlds WHERE id = ?');
    stmt.run(id);

    return true;
  }

  /**
   * 世界観のバージョンを作成
   */
  private async createVersion(world: World): Promise<void> {
    const sqlite = getSqliteClient();
    if (!sqlite) {
      throw new Error('SQLite client not available');
    }

    // 既存のバージョン数を取得
    const stmt = sqlite.prepare(`
      SELECT version_number FROM world_versions
      WHERE world_id = ?
      ORDER BY version_number DESC
      LIMIT 1
    `);

    const result = stmt.get(world.id) as { version_number: number } | undefined;
    const nextVersionNumber = result ? result.version_number + 1 : 1;
    const now = Math.floor(Date.now() / 1000);

    const insertStmt = sqlite.prepare(`
      INSERT INTO world_versions (
        id, world_id, version_number, title, description, dimensions,
        content, created_at, created_by, change_note
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    insertStmt.run(
      randomUUID(),
      world.id,
      nextVersionNumber,
      world.title,
      world.description,
      JSON.stringify(world.dimensions),
      world.content ? JSON.stringify(world.content) : null,
      now,
      world.userId,
      'Auto-saved version before update'
    );
  }

  /**
   * SQLite行データをWorldオブジェクトにパース
   */
  private parseWorldRow(row: any): World {
    return {
      id: row.id,
      userId: row.user_id,
      title: row.title,
      description: row.description,
      dimensions: JSON.parse(row.dimensions),
      content: row.content ? JSON.parse(row.content) : null,
      tags: row.tags ? JSON.parse(row.tags) : null,
      isPublic: Boolean(row.is_public),
      createdAt: new Date(row.created_at * 1000),
      updatedAt: new Date(row.updated_at * 1000),
      viewCount: row.view_count,
      likeCount: row.like_count,
      metadata: row.metadata ? JSON.parse(row.metadata) : null,
    };
  }
}

/**
 * World Repository Factory
 */
export function createWorldRepository(db: DbInstance): WorldRepository {
  return new WorldRepositoryImpl(db);
}
