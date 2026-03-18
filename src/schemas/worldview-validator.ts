/**
 * 世界観スキーマのバリデーション関数
 * worldview-schema.json に基づいた必須フィールド検証・形式チェック
 * スタンドアロン実装（外部依存なし）- additionalProperties 許可の拡張可能設計
 */

/** バリデーション結果 */
export interface ValidationResult {
  valid: boolean;
  errors?: string[];
}

/** 世界観データ型（additionalProperties 許可） */
export interface WorldviewData {
  tone: string;
  aesthetic_direction: string;
  keywords: string[];
  color_palette: string[];
  exemplar_texts: string[];
  $schema_version: string;
  [key: string]: unknown;
}

/** aesthetic_direction の許可値 */
const AESTHETIC_DIRECTION_ENUM = ['ethereal', 'mystical', 'healing', 'elegant', 'natural'] as const;

/** HEXカラーコードパターン（#RGB または #RRGGBB） */
const HEX_COLOR_PATTERN = /^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$/;

/** semver パターン（x.y.z 形式） */
const SEMVER_PATTERN = /^\d+\.\d+\.\d+/;

/** 必須フィールド一覧 */
const REQUIRED_FIELDS: ReadonlyArray<string> = [
  'tone',
  'aesthetic_direction',
  'keywords',
  'color_palette',
  'exemplar_texts',
  '$schema_version',
];

/**
 * 世界観データのバリデーション
 * - 全必須フィールドの存在チェック
 * - tone: 1-100文字（空文字拒否）
 * - aesthetic_direction: enum チェック（ethereal/mystical/healing/elegant/natural）
 * - keywords: 空配列拒否（minItems: 1）
 * - color_palette: HEXカラーコード形式チェック + 空配列拒否
 * - exemplar_texts: 空配列拒否（minItems: 1）
 * - $schema_version: semver 形式チェック
 * - additionalProperties は許可（拡張可能設計）
 */
export function validateWorldview(data: unknown): ValidationResult {
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

  // tone: 1-100文字（空文字拒否）
  if ('tone' in obj && obj['tone'] != null) {
    if (typeof obj['tone'] !== 'string' || obj['tone'].length === 0) {
      errors.push(`/tone: must NOT have fewer than 1 characters`);
    } else if (obj['tone'].length > 100) {
      errors.push(`/tone: must NOT have more than 100 characters`);
    }
  }

  // aesthetic_direction: enum チェック
  if ('aesthetic_direction' in obj && obj['aesthetic_direction'] != null) {
    if (typeof obj['aesthetic_direction'] !== 'string') {
      errors.push(`/aesthetic_direction: must be string`);
    } else if (!(AESTHETIC_DIRECTION_ENUM as ReadonlyArray<string>).includes(obj['aesthetic_direction'])) {
      errors.push(
        `/aesthetic_direction: must be one of the allowed values: ${AESTHETIC_DIRECTION_ENUM.join(', ')}`
      );
    }
  }

  // keywords: 空配列拒否（minItems: 1）
  if ('keywords' in obj && obj['keywords'] != null) {
    if (!Array.isArray(obj['keywords'])) {
      errors.push(`/keywords: must be array`);
    } else if (obj['keywords'].length === 0) {
      errors.push(`/keywords: must NOT have fewer than 1 items`);
    }
  }

  // color_palette: HEXカラーコード形式チェック + 空配列拒否
  if ('color_palette' in obj && obj['color_palette'] != null) {
    if (!Array.isArray(obj['color_palette'])) {
      errors.push(`/color_palette: must be array`);
    } else if (obj['color_palette'].length === 0) {
      errors.push(`/color_palette: must NOT have fewer than 1 items`);
    } else {
      for (let i = 0; i < obj['color_palette'].length; i++) {
        const color = obj['color_palette'][i];
        if (typeof color !== 'string' || !HEX_COLOR_PATTERN.test(color)) {
          errors.push(
            `/color_palette/${i}: must match HEX color pattern "#RGB" or "#RRGGBB" (e.g. "#7B2FBE")`
          );
        }
      }
    }
  }

  // exemplar_texts: 空配列拒否（minItems: 1）
  if ('exemplar_texts' in obj && obj['exemplar_texts'] != null) {
    if (!Array.isArray(obj['exemplar_texts'])) {
      errors.push(`/exemplar_texts: must be array`);
    } else if (obj['exemplar_texts'].length === 0) {
      errors.push(`/exemplar_texts: must NOT have fewer than 1 items`);
    }
  }

  // $schema_version: semver 形式チェック
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
export function createWorldviewValidator(): (data: unknown) => ValidationResult {
  return validateWorldview;
}
