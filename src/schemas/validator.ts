/**
 * 共通スキーマバリデータユーティリティ
 * AJV v8 + ajv-formats を使用したJSONスキーマ検証
 * $schema_version フィールドによるlazy migration方式のバージョン管理
 */
import Ajv, { JSONSchemaType, ValidateFunction } from 'ajv';
import addFormats from 'ajv-formats';

export const SCHEMA_VERSION = '1.0.0';

/** バリデーション結果 */
export interface ValidationResult {
  valid: boolean;
  errors?: string[];
}

// AJVインスタンス（シングルトン）
const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv);

/**
 * スキーマに $schema_version プロパティを追加するヘルパー
 * 全スキーマファイルに付与し、lazy migration方式でバージョン管理する
 */
export function withSchemaVersion(schema: Record<string, unknown>): Record<string, unknown> {
  const properties = (schema.properties as Record<string, unknown>) ?? {};
  return {
    ...schema,
    properties: {
      $schema_version: {
        type: 'string',
        description: 'Schema version for lazy migration tracking',
        default: SCHEMA_VERSION,
      },
      ...properties,
    },
  };
}

/**
 * 単発バリデーション
 */
export function validate(schema: Record<string, unknown>, data: unknown): ValidationResult {
  const validator = ajv.compile(schema);
  const valid = validator(data);
  if (!valid) {
    const errors = validator.errors?.map((e) => {
      const path = e.instancePath || '(root)';
      return `${path}: ${e.message ?? 'invalid'}`;
    }) ?? [];
    return { valid: false, errors };
  }
  return { valid: true };
}

/**
 * バリデータ関数をキャッシュして返す（高頻度呼び出し用）
 */
export function createValidator<T = unknown>(
  schema: Record<string, unknown>
): (data: unknown) => ValidationResult & { data?: T } {
  const validator: ValidateFunction = ajv.compile(schema);
  return (data: unknown) => {
    const valid = validator(data);
    if (!valid) {
      const errors = validator.errors?.map((e) => {
        const path = e.instancePath || '(root)';
        return `${path}: ${e.message ?? 'invalid'}`;
      }) ?? [];
      return { valid: false, errors };
    }
    return { valid: true, data: data as T };
  };
}

/**
 * スキーマバージョン検証（lazy migration用）
 * データの $schema_version が現在バージョンと一致するか確認
 */
export function checkSchemaVersion(data: unknown): {
  current: boolean;
  version: string | undefined;
} {
  if (typeof data !== 'object' || data === null) {
    return { current: false, version: undefined };
  }
  const version = (data as Record<string, unknown>).$schema_version as string | undefined;
  return {
    current: version === SCHEMA_VERSION,
    version,
  };
}

export default ajv;
