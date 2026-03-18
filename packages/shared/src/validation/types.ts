/**
 * Dependency Graph - 型定義
 *
 * 依存関係グラフで使用される型定義
 */

/**
 * 7次元の各次元を表す型
 */
export type DimensionType =
  | 'cosmology'
  | 'theology'
  | 'ethics'
  | 'ritual'
  | 'narrative'
  | 'symbolism'
  | 'socialStructure';

/**
 * 次元の日本語名マッピング
 */
export const DIMENSION_NAMES: Record<DimensionType, string> = {
  cosmology: '宇宙論',
  theology: '神学',
  ethics: '倫理体系',
  ritual: '儀式',
  narrative: '神話/物語',
  symbolism: 'シンボル',
  socialStructure: '社会構造',
};

/**
 * 次元間の推奨参照パターン
 */
export const RECOMMENDED_REFERENCE_PATTERNS: Record<
  DimensionType,
  DimensionType[]
> = {
  cosmology: ['theology'],
  theology: ['ethics'],
  ethics: ['ritual'],
  ritual: ['symbolism'],
  narrative: ['cosmology', 'theology'],
  symbolism: ['theology'],
  socialStructure: ['ritual', 'ethics'],
};

/**
 * 参照フィールドの命名パターン（正規表現）
 */
export const REFERENCE_FIELD_PATTERN = /(Ref|Refs|Reference|References)$/;

/**
 * 参照値のフォーマット（dimension:entityId）
 */
export const REFERENCE_VALUE_PATTERN = /^[a-z]+:[a-z0-9-_]+$/i;

/**
 * バリデーション結果の型
 */
export interface ValidationResult {
  valid: boolean;
  errors: ValidationError[];
  warnings: ValidationWarning[];
}

/**
 * バリデーションエラー
 */
export interface ValidationError {
  type: 'orphan' | 'self_reference' | 'invalid_format' | 'missing_id';
  message: string;
  source?: string;
  target?: string;
  field?: string;
}

/**
 * バリデーション警告
 */
export interface ValidationWarning {
  type: 'circular_reference' | 'discouraged_pattern' | 'high_complexity';
  message: string;
  details?: any;
}
