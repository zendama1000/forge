/**
 * Database Schema - Drizzle ORM + PostgreSQL
 *
 * 7次元生成プラットフォームのDBスキーマ定義
 * テスト時はSQLiteインメモリDBに切替可能
 */

import {
  pgTable,
  text,
  timestamp,
  jsonb,
  integer,
  boolean,
  uuid,
  varchar,
  index
} from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

// ===========================
// Users Table
// ===========================

export const users = pgTable('users', {
  id: uuid('id').defaultRandom().primaryKey(),
  email: varchar('email', { length: 255 }).notNull().unique(),
  username: varchar('username', { length: 100 }),
  passwordHash: text('password_hash').notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
  lastLoginAt: timestamp('last_login_at'),
  isActive: boolean('is_active').default(true).notNull(),
  metadata: jsonb('metadata'), // ユーザー設定、プリファレンス等
}, (table) => ({
  emailIdx: index('users_email_idx').on(table.email),
  usernameIdx: index('users_username_idx').on(table.username),
}));

// ===========================
// Sessions Table
// ===========================

export const sessions = pgTable('sessions', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  token: text('token').notNull().unique(),
  refreshToken: text('refresh_token'),
  expiresAt: timestamp('expires_at').notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  ipAddress: varchar('ip_address', { length: 45 }), // IPv6対応
  userAgent: text('user_agent'),
  isRevoked: boolean('is_revoked').default(false).notNull(),
}, (table) => ({
  tokenIdx: index('sessions_token_idx').on(table.token),
  userIdIdx: index('sessions_user_id_idx').on(table.userId),
  expiresAtIdx: index('sessions_expires_at_idx').on(table.expiresAt),
}));

// ===========================
// Worlds Table (7次元データ保存)
// ===========================

export const worlds = pgTable('worlds', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  title: varchar('title', { length: 500 }).notNull(),
  description: text('description').notNull(),

  // 7次元パラメータ (JSONB)
  dimensions: jsonb('dimensions').notNull().$type<{
    complexity: number;
    novelty: number;
    coherence: number;
    emotion: number;
    interactivity: number;
    scale: number;
    uncertainty: number;
  }>(),

  // 生成コンテンツ本体 (JSONB)
  content: jsonb('content'),

  tags: jsonb('tags').$type<string[]>(),
  isPublic: boolean('is_public').default(false).notNull(),

  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),

  viewCount: integer('view_count').default(0).notNull(),
  likeCount: integer('like_count').default(0).notNull(),

  // 生成メタデータ
  metadata: jsonb('metadata').$type<{
    generationTime?: number;
    model?: string;
    version?: string;
    prompt?: string;
  }>(),
}, (table) => ({
  userIdIdx: index('worlds_user_id_idx').on(table.userId),
  isPublicIdx: index('worlds_is_public_idx').on(table.isPublic),
  createdAtIdx: index('worlds_created_at_idx').on(table.createdAt),
}));

// ===========================
// World Versions Table
// ===========================

export const worldVersions = pgTable('world_versions', {
  id: uuid('id').defaultRandom().primaryKey(),
  worldId: uuid('world_id').references(() => worlds.id, { onDelete: 'cascade' }).notNull(),
  versionNumber: integer('version_number').notNull(),

  title: varchar('title', { length: 500 }).notNull(),
  description: text('description').notNull(),
  dimensions: jsonb('dimensions').notNull().$type<{
    complexity: number;
    novelty: number;
    coherence: number;
    emotion: number;
    interactivity: number;
    scale: number;
    uncertainty: number;
  }>(),
  content: jsonb('content'),

  createdAt: timestamp('created_at').defaultNow().notNull(),
  createdBy: uuid('created_by').references(() => users.id, { onDelete: 'set null' }),
  changeNote: text('change_note'),
}, (table) => ({
  worldIdIdx: index('world_versions_world_id_idx').on(table.worldId),
  worldVersionIdx: index('world_versions_world_version_idx').on(table.worldId, table.versionNumber),
}));

// ===========================
// Shared Links Table
// ===========================

export const sharedLinks = pgTable('shared_links', {
  id: uuid('id').defaultRandom().primaryKey(),
  worldId: uuid('world_id').references(() => worlds.id, { onDelete: 'cascade' }).notNull(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),

  token: varchar('token', { length: 64 }).notNull().unique(),
  expiresAt: timestamp('expires_at'),
  maxViews: integer('max_views'),
  viewCount: integer('view_count').default(0).notNull(),

  isActive: boolean('is_active').default(true).notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),

  metadata: jsonb('metadata').$type<{
    allowDownload?: boolean;
    requirePassword?: boolean;
    passwordHash?: string;
  }>(),
}, (table) => ({
  tokenIdx: index('shared_links_token_idx').on(table.token),
  worldIdIdx: index('shared_links_world_id_idx').on(table.worldId),
  expiresAtIdx: index('shared_links_expires_at_idx').on(table.expiresAt),
}));

// ===========================
// API Keys Table (BYOK暗号化保存)
// ===========================

export const apiKeys = pgTable('api_keys', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),

  provider: varchar('provider', { length: 50 }).notNull(), // 'openai', 'anthropic', etc.

  // 暗号化されたAPIキー (AES-256-GCM想定)
  encryptedKey: text('encrypted_key').notNull(),

  // 暗号化に使用したIV (Initialization Vector)
  iv: text('iv').notNull(),

  // 暗号化に使用したタグ (GCM認証タグ)
  authTag: text('auth_tag').notNull(),

  name: varchar('name', { length: 100 }), // ユーザー定義のキー名
  isActive: boolean('is_active').default(true).notNull(),

  createdAt: timestamp('created_at').defaultNow().notNull(),
  lastUsedAt: timestamp('last_used_at'),
  expiresAt: timestamp('expires_at'),

  metadata: jsonb('metadata').$type<{
    model?: string;
    rateLimit?: number;
    customSettings?: Record<string, unknown>;
  }>(),
}, (table) => ({
  userIdIdx: index('api_keys_user_id_idx').on(table.userId),
  providerIdx: index('api_keys_provider_idx').on(table.provider),
  isActiveIdx: index('api_keys_is_active_idx').on(table.isActive),
}));

// ===========================
// Subscriptions Table
// ===========================

export const subscriptions = pgTable('subscriptions', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull().unique(),

  plan: varchar('plan', { length: 50 }).notNull(), // 'free', 'pro', 'enterprise'
  status: varchar('status', { length: 50 }).notNull(), // 'active', 'cancelled', 'expired', 'trial'

  currentPeriodStart: timestamp('current_period_start').notNull(),
  currentPeriodEnd: timestamp('current_period_end').notNull(),

  cancelAt: timestamp('cancel_at'),
  cancelledAt: timestamp('cancelled_at'),

  trialStart: timestamp('trial_start'),
  trialEnd: timestamp('trial_end'),

  metadata: jsonb('metadata').$type<{
    stripeCustomerId?: string;
    stripeSubscriptionId?: string;
    paymentMethod?: string;
    features?: Record<string, boolean>;
  }>(),

  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
}, (table) => ({
  userIdIdx: index('subscriptions_user_id_idx').on(table.userId),
  statusIdx: index('subscriptions_status_idx').on(table.status),
  planIdx: index('subscriptions_plan_idx').on(table.plan),
}));

// ===========================
// Usage Logs Table
// ===========================

export const usageLogs = pgTable('usage_logs', {
  id: uuid('id').defaultRandom().primaryKey(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),

  action: varchar('action', { length: 100 }).notNull(), // 'generate', 'save', 'share', etc.
  resourceType: varchar('resource_type', { length: 50 }), // 'world', 'api_call', etc.
  resourceId: uuid('resource_id'),

  // コスト/使用量情報
  tokensUsed: integer('tokens_used'),
  cost: integer('cost'), // 整数でセント単位保存

  timestamp: timestamp('timestamp').defaultNow().notNull(),

  metadata: jsonb('metadata').$type<{
    model?: string;
    provider?: string;
    duration?: number;
    requestSize?: number;
    responseSize?: number;
    ipAddress?: string;
    userAgent?: string;
  }>(),
}, (table) => ({
  userIdIdx: index('usage_logs_user_id_idx').on(table.userId),
  actionIdx: index('usage_logs_action_idx').on(table.action),
  timestampIdx: index('usage_logs_timestamp_idx').on(table.timestamp),
  resourceTypeIdx: index('usage_logs_resource_type_idx').on(table.resourceType),
}));

// ===========================
// Type Exports
// ===========================

export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;

export type Session = typeof sessions.$inferSelect;
export type NewSession = typeof sessions.$inferInsert;

export type World = typeof worlds.$inferSelect;
export type NewWorld = typeof worlds.$inferInsert;

export type WorldVersion = typeof worldVersions.$inferSelect;
export type NewWorldVersion = typeof worldVersions.$inferInsert;

export type SharedLink = typeof sharedLinks.$inferSelect;
export type NewSharedLink = typeof sharedLinks.$inferInsert;

export type ApiKey = typeof apiKeys.$inferSelect;
export type NewApiKey = typeof apiKeys.$inferInsert;

export type Subscription = typeof subscriptions.$inferSelect;
export type NewSubscription = typeof subscriptions.$inferInsert;

export type UsageLog = typeof usageLogs.$inferSelect;
export type NewUsageLog = typeof usageLogs.$inferInsert;
