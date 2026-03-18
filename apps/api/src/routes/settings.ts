/**
 * Settings API
 *
 * GET  /api/settings - 現在の設定を返す（200 + 設定JSON）
 * POST /api/settings - 設定を更新する（201 + 更新後設定）
 *                      不正なスキーマの場合 400 + バリデーションエラー詳細
 */

import { Hono } from 'hono';
import { z } from 'zod';

// ===========================
// Zod Schema
// ===========================

const browserAutomationSchema = z.object({
  enabled: z.boolean(),
}).passthrough();

/**
 * POST /api/settings のリクエストボディスキーマ
 * 既知フィールドの型を検証し、追加フィールドはそのまま許容する
 */
export const settingsUpdateSchema = z.object({
  theme: z.string().optional(),
  language: z.string().optional(),
  notifications: z.boolean().optional(),
  browser_automation: browserAutomationSchema.optional(),
}).passthrough();

export type SettingsUpdateInput = z.infer<typeof settingsUpdateSchema>;

// ===========================
// Types
// ===========================

export interface SettingsData {
  theme?: string;
  language?: string;
  notifications?: boolean;
  browser_automation?: {
    enabled: boolean;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

// ===========================
// In-memory Settings Store
// ===========================

const defaultSettings: SettingsData = {
  theme: 'light',
  language: 'ja',
  notifications: true,
  browser_automation: {
    enabled: false,
  },
};

let currentSettings: SettingsData = {
  ...defaultSettings,
  browser_automation: { ...(defaultSettings.browser_automation as { enabled: boolean }) },
};

/**
 * テスト用: 設定をデフォルト値にリセット
 */
export function resetSettings(): void {
  currentSettings = {
    ...defaultSettings,
    browser_automation: { ...(defaultSettings.browser_automation as { enabled: boolean }) },
  };
}

/**
 * テスト用: 現在の設定スナップショットを取得
 */
export function getCurrentSettings(): SettingsData {
  return { ...currentSettings };
}

// ===========================
// Routes
// ===========================

const settingsRouter = new Hono();

/**
 * GET /settings
 * 現在の設定をJSON形式で返す
 */
settingsRouter.get('/', (c) => {
  return c.json(currentSettings, 200);
});

/**
 * POST /settings
 * リクエストボディで設定を更新し、更新後の設定を返す
 */
settingsRouter.post('/', async (c) => {
  let body: unknown;

  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return c.json({ error: 'Settings must be a valid JSON object' }, 400);
  }

  // Zodスキーマでバリデーション
  const parseResult = settingsUpdateSchema.safeParse(body);
  if (!parseResult.success) {
    return c.json(
      {
        error: 'Validation error',
        details: parseResult.error.format(),
      },
      400
    );
  }

  // browser_automation はネストしてマージ
  const incoming = parseResult.data as SettingsData;

  if (incoming.browser_automation !== undefined && typeof incoming.browser_automation === 'object') {
    currentSettings = {
      ...currentSettings,
      ...incoming,
      browser_automation: {
        ...(currentSettings.browser_automation as { enabled: boolean }),
        ...(incoming.browser_automation as { enabled: boolean }),
      },
    };
  } else {
    currentSettings = {
      ...currentSettings,
      ...incoming,
    };
  }

  return c.json(currentSettings, 201);
});

export default settingsRouter;
