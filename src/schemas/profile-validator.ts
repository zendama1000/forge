/**
 * プラットフォーム別プロフィールスキーマのバリデーション関数
 * profile-schema.json に基づいたプラットフォーム別制約検証
 * マルチバイト文字対応の文字数カウントロジック含む（Unicode code point 単位）
 * スタンドアロン実装（外部依存なし）- additionalProperties 許可の拡張可能設計
 */

/** バリデーション結果 */
export interface ValidationResult {
  valid: boolean;
  errors?: string[];
}

/** 対応プラットフォーム一覧 */
const SUPPORTED_PLATFORMS = [
  'instagram',
  'tiktok',
  'twitter',
  'line_official',
  'youtube',
] as const;

type PlatformType = (typeof SUPPORTED_PLATFORMS)[number];

/** プラットフォームごとのbio文字数上限（マルチバイト対応、Unicode code point 単位） */
const BIO_MAX_LENGTH: Partial<Record<PlatformType, number>> = {
  instagram: 150,
  tiktok: 80,
  twitter: 160,
  youtube: 1000,
};

/** LINE公式 特商法7項目 必須チェックリスト */
const TOKUSHO_REQUIRED_ITEMS: ReadonlyArray<string> = [
  '事業者名',
  '所在地',
  '電話番号',
  '代表者名',
  '販売価格',
  '支払方法',
  '返金・キャンセルポリシー',
];

/** semver パターン（x.y.z 形式） */
const SEMVER_PATTERN = /^\d+\.\d+\.\d+/;

/**
 * マルチバイト対応の文字数カウント
 * Unicode code point 単位でカウントするため、日本語・絵文字も1文字として扱う
 * （例: 'あ' → 1, '😀' → 1, 'a' → 1）
 *
 * @param str 計測する文字列
 * @returns 文字数（Unicode code point 数）
 */
export function countChars(str: string): number {
  return [...str].length;
}

/**
 * プラットフォームプロフィールのバリデーション
 * - platform_type の存在チェック（必須）
 * - platform_type の enum 検証（対応プラットフォーム一覧メッセージ付き）
 * - bio 文字数上限チェック（マルチバイト対応、プラットフォーム別）
 * - line_official: compliance_checklist の存在チェック
 * - line_official: 特商法7項目の網羅チェック
 * - $schema_version の semver 形式チェック
 * - additionalProperties は許可（拡張可能設計）
 */
export function validateProfile(data: unknown): ValidationResult {
  const errors: string[] = [];

  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    return { valid: false, errors: ['(root): must be an object'] };
  }

  const obj = data as Record<string, unknown>;

  // platform_type: 必須チェック（欠落時は早期リターン）
  if (
    !('platform_type' in obj) ||
    obj['platform_type'] === undefined ||
    obj['platform_type'] === null
  ) {
    return {
      valid: false,
      errors: [`(root): must have required property 'platform_type'`],
    };
  }

  // platform_type: 型チェックおよび enum 検証
  if (typeof obj['platform_type'] !== 'string') {
    errors.push(`/platform_type: must be string`);
  } else if (!(SUPPORTED_PLATFORMS as ReadonlyArray<string>).includes(obj['platform_type'])) {
    errors.push(
      `/platform_type: must be one of the supported platforms: ${SUPPORTED_PLATFORMS.join(', ')}`
    );
  }

  // platform_type が有効な値の場合のみプラットフォーム固有バリデーションを実行
  const platformType =
    typeof obj['platform_type'] === 'string' &&
    (SUPPORTED_PLATFORMS as ReadonlyArray<string>).includes(obj['platform_type'])
      ? (obj['platform_type'] as PlatformType)
      : null;

  // bio: 文字数上限チェック（マルチバイト対応）
  if (platformType !== null && 'bio' in obj && obj['bio'] != null) {
    if (typeof obj['bio'] !== 'string') {
      errors.push(`/bio: must be string`);
    } else {
      const maxLength = BIO_MAX_LENGTH[platformType];
      if (maxLength !== undefined) {
        const charCount = countChars(obj['bio']);
        if (charCount > maxLength) {
          errors.push(
            `/bio: must NOT have more than ${maxLength} characters (current: ${charCount}) — ${platformType} bio character limit exceeded`
          );
        }
      }
    }
  }

  // line_official 固有チェック
  if (platformType === 'line_official') {
    // compliance_checklist: 必須チェック
    if (
      !('compliance_checklist' in obj) ||
      obj['compliance_checklist'] === undefined ||
      obj['compliance_checklist'] === null
    ) {
      errors.push(
        `(root): must have required property 'compliance_checklist' for line_official (特商法7項目必須)`
      );
    } else if (!Array.isArray(obj['compliance_checklist'])) {
      errors.push(`/compliance_checklist: must be array`);
    } else {
      // 特商法7項目の網羅チェック
      const checklist = obj['compliance_checklist'] as unknown[];
      const missingItems = TOKUSHO_REQUIRED_ITEMS.filter((item) => !checklist.includes(item));
      if (missingItems.length > 0) {
        errors.push(
          `/compliance_checklist: missing required 特商法 items: ${missingItems.join(', ')}`
        );
      }
    }
  }

  // $schema_version: semver 形式チェック（存在する場合のみ）
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
export function createProfileValidator(): (data: unknown) => ValidationResult {
  return validateProfile;
}
