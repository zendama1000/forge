/**
 * Database Seed Script
 *
 * テスト用のシードデータを投入するスクリプト
 * 開発環境・テスト環境で使用
 */

import { drizzle } from 'drizzle-orm/node-postgres';
import { drizzle as drizzleSqlite } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';
import { Pool } from 'pg';
import * as bcrypt from 'bcrypt';
import * as schema from './schema';

// 環境変数からDB接続文字列を取得
const DATABASE_URL = process.env.DATABASE_URL || '';
const USE_SQLITE = process.env.NODE_ENV === 'test' || DATABASE_URL === '';

/**
 * シードデータ投入メイン関数
 */
async function seed() {
  console.log('🌱 Starting database seed...');
  console.log(`Using ${USE_SQLITE ? 'SQLite' : 'PostgreSQL'}`);

  // DB接続
  let db: any;
  let pool: Pool | undefined;
  let sqlite: Database.Database | undefined;

  if (USE_SQLITE) {
    sqlite = new Database(':memory:');
    db = drizzleSqlite(sqlite, { schema });
  } else {
    pool = new Pool({ connectionString: DATABASE_URL });
    db = drizzle(pool, { schema });
  }

  try {
    // パスワードハッシュ生成
    const passwordHash = await bcrypt.hash('password123', 10);

    // ユーザーデータ投入
    console.log('Creating test users...');
    const [user1, user2, user3] = await db.insert(schema.users).values([
      {
        email: 'test1@example.com',
        username: 'testuser1',
        passwordHash,
        isActive: true,
        metadata: { preferences: { theme: 'dark' } },
      },
      {
        email: 'test2@example.com',
        username: 'testuser2',
        passwordHash,
        isActive: true,
        metadata: { preferences: { theme: 'light' } },
      },
      {
        email: 'admin@example.com',
        username: 'admin',
        passwordHash,
        isActive: true,
        metadata: { role: 'admin', preferences: { theme: 'dark' } },
      },
    ]).returning();

    console.log(`✅ Created ${3} users`);

    // Worldsデータ投入
    console.log('Creating test worlds...');
    const [world1, world2] = await db.insert(schema.worlds).values([
      {
        userId: user1.id,
        title: 'Fantasy World - Dragon Quest',
        description: 'A medieval fantasy world with dragons and magic',
        dimensions: {
          complexity: 0.7,
          novelty: 0.8,
          coherence: 0.9,
          emotion: 0.6,
          interactivity: 0.5,
          scale: 0.8,
          uncertainty: 0.3,
        },
        content: {
          narrative: 'In a land far away...',
          characters: ['Hero', 'Dragon', 'Wizard'],
          locations: ['Castle', 'Forest', 'Mountain'],
        },
        tags: ['fantasy', 'adventure', 'dragons'],
        isPublic: true,
        viewCount: 42,
        likeCount: 15,
        metadata: {
          generationTime: 3500,
          model: 'gpt-4',
          version: '1.0',
        },
      },
      {
        userId: user2.id,
        title: 'Sci-Fi Universe - Galactic War',
        description: 'A futuristic space opera with interstellar conflicts',
        dimensions: {
          complexity: 0.9,
          novelty: 0.95,
          coherence: 0.85,
          emotion: 0.7,
          interactivity: 0.8,
          scale: 1.0,
          uncertainty: 0.6,
        },
        content: {
          narrative: 'In the year 3042...',
          factions: ['Empire', 'Rebellion', 'Traders'],
          technologies: ['Warp Drive', 'Plasma Cannons', 'AI'],
        },
        tags: ['scifi', 'space', 'war'],
        isPublic: false,
        viewCount: 0,
        likeCount: 0,
        metadata: {
          generationTime: 5200,
          model: 'claude-3',
          version: '1.0',
        },
      },
    ]).returning();

    console.log(`✅ Created ${2} worlds`);

    // World Versionsデータ投入
    console.log('Creating world versions...');
    await db.insert(schema.worldVersions).values([
      {
        worldId: world1.id,
        versionNumber: 1,
        title: world1.title,
        description: world1.description,
        dimensions: world1.dimensions,
        content: world1.content,
        createdBy: user1.id,
        changeNote: 'Initial version',
      },
      {
        worldId: world1.id,
        versionNumber: 2,
        title: world1.title + ' - Extended',
        description: world1.description + ' with new quests',
        dimensions: world1.dimensions,
        content: { ...world1.content, quests: ['Save the Princess'] },
        createdBy: user1.id,
        changeNote: 'Added new quests',
      },
    ]).returning();

    console.log(`✅ Created ${2} world versions`);

    // Sessionsデータ投入
    console.log('Creating test sessions...');
    const expiresAt = new Date();
    expiresAt.setHours(expiresAt.getHours() + 24);

    await db.insert(schema.sessions).values([
      {
        userId: user1.id,
        token: 'test-token-user1-' + Date.now(),
        refreshToken: 'refresh-token-user1-' + Date.now(),
        expiresAt,
        ipAddress: '127.0.0.1',
        userAgent: 'Mozilla/5.0 (Test Browser)',
        isRevoked: false,
      },
    ]).returning();

    console.log(`✅ Created ${1} session`);

    // Shared Linksデータ投入
    console.log('Creating shared links...');
    const linkExpiresAt = new Date();
    linkExpiresAt.setDate(linkExpiresAt.getDate() + 7);

    await db.insert(schema.sharedLinks).values([
      {
        worldId: world1.id,
        userId: user1.id,
        token: 'share-token-' + Math.random().toString(36).substring(2, 15),
        expiresAt: linkExpiresAt,
        maxViews: 100,
        viewCount: 5,
        isActive: true,
        metadata: {
          allowDownload: true,
          requirePassword: false,
        },
      },
    ]).returning();

    console.log(`✅ Created ${1} shared link`);

    // Subscriptionsデータ投入
    console.log('Creating subscriptions...');
    const now = new Date();
    const periodEnd = new Date();
    periodEnd.setMonth(periodEnd.getMonth() + 1);

    await db.insert(schema.subscriptions).values([
      {
        userId: user1.id,
        plan: 'free',
        status: 'active',
        currentPeriodStart: now,
        currentPeriodEnd: periodEnd,
        metadata: {
          features: {
            maxWorlds: 10,
            apiAccess: false,
          },
        },
      },
      {
        userId: user2.id,
        plan: 'pro',
        status: 'active',
        currentPeriodStart: now,
        currentPeriodEnd: periodEnd,
        metadata: {
          stripeCustomerId: 'cus_test123',
          stripeSubscriptionId: 'sub_test123',
          features: {
            maxWorlds: 100,
            apiAccess: true,
          },
        },
      },
    ]).returning();

    console.log(`✅ Created ${2} subscriptions`);

    // Usage Logsデータ投入
    console.log('Creating usage logs...');
    await db.insert(schema.usageLogs).values([
      {
        userId: user1.id,
        action: 'generate',
        resourceType: 'world',
        resourceId: world1.id,
        tokensUsed: 1500,
        cost: 5, // 5セント
        metadata: {
          model: 'gpt-4',
          provider: 'openai',
          duration: 3500,
        },
      },
      {
        userId: user2.id,
        action: 'generate',
        resourceType: 'world',
        resourceId: world2.id,
        tokensUsed: 2500,
        cost: 8, // 8セント
        metadata: {
          model: 'claude-3',
          provider: 'anthropic',
          duration: 5200,
        },
      },
    ]).returning();

    console.log(`✅ Created ${2} usage logs`);

    console.log('✨ Seed completed successfully!');
    console.log(`
    Test Credentials:
    - Email: test1@example.com, Password: password123
    - Email: test2@example.com, Password: password123
    - Email: admin@example.com, Password: password123
    `);

  } catch (error) {
    console.error('❌ Seed failed:', error);
    throw error;
  } finally {
    // クリーンアップ
    if (pool) await pool.end();
    if (sqlite) sqlite.close();
  }
}

// スクリプト実行
if (require.main === module) {
  seed()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

export { seed };
