/**
 * ブランドコアスキーマのバリデーション関数
 * core-schema.json に基づいた必須フィールド検証・形式チェック
 * スタンドアロン実装（外部依存なし）- additionalProperties 許可の拡張可能設計
 */

/** バリデーション結果 */
export interface ValidationResult {
  valid: boolean;
  errors?: string[];
}

/** コアブランドデータ型（additionalProperties 許可） */
export interface CoreData {
  brand_name: string;
  divination_type: string;
  target_audience: string;
  core_values: string[];
  differentiators: string[];
  $schema_version: string;
  [key: string]: unknown;
}

/** semver パターン（x.y.z 形式） */
const SEMVER_PATTERN = /^\d+\.\d+\.\d+/;

/** 必須フィールド一覧 */
const REQUIRED_FIELDS: ReadonlyArray<string> = [
  'brand_name',
  'divination_type',
  'target_audience',
  'core_values',
  'differentiators',
  '$schema_version',
];

/**
 * ブランドコアデータのバリデーション
 * - 全必須フィールドの存在チェック
 * - 文字列フィールドの空文字拒否（minLength: 1）
 * - 配列フィールドの空配列拒否（minItems: 1）
 * - $schema_version の semver 形式チェック
 * - additionalProperties は許可（拡張可能設計）
 */
export function validateCore(data: unknown): ValidationResult {
  const errors: string[] = [];

  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    return { valid: false, errors: ['(root): must be an object'] };
  }

  const obj = data as Record<string, unknown>;

  // 必須フィールド存在チェック
  for (const field of REQUIRED_FIELDS) {
    if (!(field in obj) || obj[field] === undefined || obj[field] === null) {
      errors.push(`(root): must have required property '${field}'`);
    }
  }

  // brand_name: 空文字拒否
  if ('brand_name' in obj && obj['brand_name'] != null) {
    if (typeof obj['brand_name'] !== 'string' || obj['brand_name'].length === 0) {
      errors.push(`/brand_name: must NOT have fewer than 1 characters`);
    }
  }

  // divination_type: 空文字拒否
  if ('divination_type' in obj && obj['divination_type'] != null) {
    if (typeof obj['divination_type'] !== 'string' || obj['divination_type'].length === 0) {
      errors.push(`/divination_type: must NOT have fewer than 1 characters`);
    }
  }

  // target_audience: 空文字拒否
  if ('target_audience' in obj && obj['target_audience'] != null) {
    if (typeof obj['target_audience'] !== 'string' || obj['target_audience'].length === 0) {
      errors.push(`/target_audience: must NOT have fewer than 1 characters`);
    }
  }

  // core_values: 空配列拒否（minItems: 1）
  if ('core_values' in obj && obj['core_values'] != null) {
    if (!Array.isArray(obj['core_values'])) {
      errors.push(`/core_values: must be array`);
    } else if (obj['core_values'].length === 0) {
      errors.push(`/core_values: must NOT have fewer than 1 items`);
    }
  }

  // differentiators: 空配列拒否（minItems: 1）
  if ('differentiators' in obj && obj['differentiators'] != null) {
    if (!Array.isArray(obj['differentiators'])) {
      errors.push(`/differentiators: must be array`);
    } else if (obj['differentiators'].length === 0) {
      errors.push(`/differentiators: must NOT have fewer than 1 items`);
    }
  }

  // $schema_version: semver 形式チェック（pattern: "^\d+\.\d+\.\d+"）
  if ('$schema_version' in obj && obj['$schema_version'] != null) {
    if (typeof obj['$schema_version'] !== 'string') {
      errors.push(`/$schema_version: must be string`);
    } else if (!SEMVER_PATTERN.test(obj['$schema_version'])) {
      errors.push(
        `/$schema_version: must match semver pattern "^\\d+\\.\\d+\\.\\d+" (e.g. "1.0.0")`
      );
    }
  }

  if (errors.length > 0) {
    return { valid: false, errors };
  }
  return { valid: true };
}

/**
 * キャッシュ済みバリデータを返す（高頻度呼び出し用）
 */
export function createCoreValidator(): (data: unknown) => ValidationResult {
  return validateCore;
}
