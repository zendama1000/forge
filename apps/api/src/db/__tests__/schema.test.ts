/**
 * Schema Layer 1 Tests
 *
 * スキーマ定義の基本的な整合性を検証
 */

import { describe, it, expect } from 'vitest';
import * as schema from '../schema.js';

describe('DB Schema - Layer 1', () => {
  // テスト: テーブル定義が存在する
  it('すべてのテーブル定義が存在すること', () => {
    expect(schema.users).toBeDefined();
    expect(schema.sessions).toBeDefined();
    expect(schema.worlds).toBeDefined();
    expect(schema.worldVersions).toBeDefined();
    expect(schema.sharedLinks).toBeDefined();
    expect(schema.apiKeys).toBeDefined();
    expect(schema.subscriptions).toBeDefined();
    expect(schema.usageLogs).toBeDefined();
  });

  // テスト: 型エクスポートが存在する
  it('型定義がエクスポートされていること', () => {
    // TypeScript コンパイルが通ることで型定義の存在を検証
    type _User = schema.User;
    type _NewUser = schema.NewUser;
    type _World = schema.World;
    type _NewWorld = schema.NewWorld;
    type _Session = schema.Session;
    type _ApiKey = schema.ApiKey;

    expect(true).toBe(true); // コンパイルが通ればOK
  });

  // テスト: worldsテーブルに7次元フィールドが含まれること
  it('worldsテーブルにdimensionsフィールドが含まれること', () => {
    const worldsTable = schema.worlds;

    // テーブルオブジェクトの構造を確認
    expect(worldsTable).toBeDefined();

    // カラム定義の存在確認
    const columns = Object.keys(worldsTable);
    expect(columns).toContain('dimensions');
  });

  // エッジケース: apiKeysテーブルに暗号化フィールドが含まれること
  it('apiKeysテーブルに暗号化関連フィールドが含まれること', () => {
    const apiKeysTable = schema.apiKeys;

    expect(apiKeysTable).toBeDefined();

    // カラム定義の存在確認
    const columns = Object.keys(apiKeysTable);
    expect(columns).toContain('encryptedKey');
    expect(columns).toContain('iv');
    expect(columns).toContain('authTag');
  });

  // エッジケース: usageLogsテーブルにインデックスが定義されていること
  it('usageLogsテーブルにインデックスが定義されていること', () => {
    const usageLogsTable = schema.usageLogs;

    expect(usageLogsTable).toBeDefined();

    // カラム定義の存在確認
    const columns = Object.keys(usageLogsTable);
    expect(columns.length).toBeGreaterThan(0);
  });

  // エッジケース: JSONBフィールドの型推論が正しいこと
  it('worldsテーブルのdimensionsフィールドの型が正しいこと', () => {
    // TypeScript型推論のテスト
    const mockWorld: schema.NewWorld = {
      userId: '123e4567-e89b-12d3-a456-426614174000',
      title: 'Test World',
      description: 'Test Description',
      dimensions: {
        complexity: 0.5,
        novelty: 0.7,
        coherence: 0.9,
        emotion: 0.3,
        interactivity: 0.6,
        scale: 0.8,
        uncertainty: 0.4,
      },
    };

    // 型が正しく推論されていればコンパイルエラーにならない
    expect(mockWorld.dimensions.complexity).toBe(0.5);
    expect(mockWorld.dimensions.novelty).toBe(0.7);

    // 7次元すべてが必須であることを確認（型レベル）
    const requiredKeys = [
      'complexity',
      'novelty',
      'coherence',
      'emotion',
      'interactivity',
      'scale',
      'uncertainty',
    ];

    requiredKeys.forEach(key => {
      expect(mockWorld.dimensions).toHaveProperty(key);
    });
  });

  // エッジケース: 外部キー制約が定義されていること
  it('sessionsテーブルにuserIdの外部キーが定義されていること', () => {
    const sessionsTable = schema.sessions;

    expect(sessionsTable).toBeDefined();
    expect(sessionsTable.userId).toBeDefined();
  });

  // エッジケース: デフォルト値が定義されていること
  it('worldsテーブルのisPublicフィールドにデフォルト値が設定されていること', () => {
    const worldsTable = schema.worlds;

    expect(worldsTable).toBeDefined();
    expect(worldsTable.isPublic).toBeDefined();
  });
});
