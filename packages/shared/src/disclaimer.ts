/**
 * Disclaimer Embedding Logic
 *
 * AI生成コンテンツへの免責表示埋め込み機能
 * 多言語対応、メタデータ付与、存在チェック
 */

import type { WorldData } from './types/api';

// ===========================
// Type Extensions
// ===========================

/**
 * WorldData with optional metadata field
 * （既存のWorldDataに metadata を追加した拡張型）
 */
export interface WorldDataWithMetadata extends WorldData {
  metadata?: {
    generationTime?: number;
    model?: string;
    version?: string;
    [key: string]: any;
  };
}

// ===========================
// Constants
// ===========================

/**
 * 免責表示テキスト（多言語対応）
 */
export const DISCLAIMER_TEXT = {
  ja: 'このコンテンツはAIによって生成されたフィクションです。実在の人物・団体・出来事とは一切関係ありません。',
  en: 'This content is AI-generated fiction. Any resemblance to real persons, organizations, or events is purely coincidental.',
  zh: '此内容为AI生成的虚构作品。与真实人物、组织或事件无关。',
  es: 'Este contenido es ficción generada por IA. Cualquier parecido con personas, organizaciones o eventos reales es pura coincidencia.',
  fr: 'Ce contenu est une fiction générée par IA. Toute ressemblance avec des personnes, organisations ou événements réels est purement fortuite.',
} as const;

export type SupportedLanguage = keyof typeof DISCLAIMER_TEXT;

/**
 * デフォルト言語
 */
export const DEFAULT_LANGUAGE: SupportedLanguage = 'en';

// ===========================
// Types
// ===========================

/**
 * 免責メタデータ
 */
export interface DisclaimerMetadata {
  _disclaimer: string;
  _generated_at: string;
  _is_fictional: boolean;
}

/**
 * 免責表示付き世界データ
 */
export type WorldDataWithDisclaimer = WorldDataWithMetadata & {
  metadata: WorldDataWithMetadata['metadata'] & DisclaimerMetadata;
};

// ===========================
// Core Functions
// ===========================

/**
 * 世界データに免責表示を埋め込む
 *
 * @param world - 対象の世界データ
 * @param language - 免責表示の言語（デフォルト: 'en'）
 * @returns 免責メタデータが付与された世界データ
 *
 * @example
 * ```ts
 * const world = { id: '123', title: 'Test World', ... };
 * const withDisclaimer = embedDisclaimer(world);
 * console.log(withDisclaimer.metadata?._disclaimer); // => "This content is AI-generated fiction..."
 * ```
 */
export function embedDisclaimer(
  world: WorldDataWithMetadata,
  language: SupportedLanguage = DEFAULT_LANGUAGE
): WorldDataWithDisclaimer {
  const disclaimerText = DISCLAIMER_TEXT[language] || DISCLAIMER_TEXT[DEFAULT_LANGUAGE];
  const generatedAt = new Date().toISOString();

  return {
    ...world,
    metadata: {
      ...world.metadata,
      _disclaimer: disclaimerText,
      _generated_at: generatedAt,
      _is_fictional: true,
    },
  };
}

/**
 * 世界データに免責表示が存在するか確認
 *
 * @param world - チェック対象の世界データ
 * @returns 免責メタデータが存在する場合 true
 *
 * @example
 * ```ts
 * const world = embedDisclaimer(originalWorld);
 * console.log(hasDisclaimer(world)); // => true
 * console.log(hasDisclaimer(originalWorld)); // => false
 * ```
 */
export function hasDisclaimer(world: WorldDataWithMetadata | WorldDataWithDisclaimer): boolean {
  return (
    typeof world.metadata === 'object' &&
    world.metadata !== null &&
    '_disclaimer' in world.metadata &&
    typeof world.metadata._disclaimer === 'string' &&
    world.metadata._disclaimer.length > 0
  );
}

/**
 * 免責メタデータを取得
 *
 * @param world - 対象の世界データ
 * @returns 免責メタデータ（存在しない場合は null）
 */
export function getDisclaimerMetadata(
  world: WorldDataWithMetadata | WorldDataWithDisclaimer
): DisclaimerMetadata | null {
  if (!hasDisclaimer(world)) {
    return null;
  }

  const metadata = world.metadata as Partial<DisclaimerMetadata>;

  return {
    _disclaimer: metadata._disclaimer || '',
    _generated_at: metadata._generated_at || '',
    _is_fictional: metadata._is_fictional ?? true,
  };
}

/**
 * 指定言語がサポートされているか確認
 *
 * @param language - チェック対象の言語コード
 * @returns サポートされている場合 true
 */
export function isSupportedLanguage(language: string): language is SupportedLanguage {
  return language in DISCLAIMER_TEXT;
}

/**
 * すべてのサポート言語を取得
 *
 * @returns サポートされている言語コードの配列
 */
export function getSupportedLanguages(): SupportedLanguage[] {
  return Object.keys(DISCLAIMER_TEXT) as SupportedLanguage[];
}
