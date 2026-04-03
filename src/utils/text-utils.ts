/**
 * テキストユーティリティ
 * 文字数カウント・トークン推定・オーバーラップ抽出
 */

/**
 * テキストの文字数をマルチバイト対応でカウントする
 * Array.from を使用してサロゲートペア・絵文字も正確にカウント
 */
export function countChars(text: string): number {
  return Array.from(text).length;
}

/**
 * CJK統合漢字・ひらがな・カタカナ等の日本語文字かどうかを判定
 */
function isJapaneseCJK(codePoint: number): boolean {
  return (
    (codePoint >= 0x3000 && codePoint <= 0x9FFF) || // ひらがな・カタカナ・CJK統合漢字等
    (codePoint >= 0xF900 && codePoint <= 0xFAFF) || // CJK互換漢字
    (codePoint >= 0x20000 && codePoint <= 0x2FA1F)  // CJK拡張B〜F
  );
}

/**
 * テキストのトークン数を推定する
 * - 日本語/CJK文字: 1文字 ≈ 2トークン（1.5〜3の中間値）
 * - ASCII文字:      4文字 ≈ 1トークン（0.25トークン/文字）
 * - その他Unicode:  1文字 ≈ 1トークン
 * @param text 推定対象のテキスト
 * @returns 推定トークン数（整数）
 */
export function estimateTokens(text: string): number {
  if (text.length === 0) return 0;

  const chars = Array.from(text);
  let tokens = 0;

  for (const char of chars) {
    const cp = char.codePointAt(0) ?? 0;
    if (isJapaneseCJK(cp)) {
      tokens += 2;      // 日本語1文字 ≈ 2トークン
    } else if (cp < 128) {
      tokens += 0.25;   // ASCII4文字 ≈ 1トークン
    } else {
      tokens += 1;      // その他Unicodeは1トークン
    }
  }

  return Math.round(tokens);
}

/**
 * テキストの末尾N文字を抽出する（オーバーラップ用）
 * テキストがN文字未満の場合はテキスト全体を返す
 * @param text 対象テキスト
 * @param n    抽出する文字数
 * @returns 末尾N文字（またはテキスト全体）
 */
export function extractOverlap(text: string, n: number): string {
  const chars = Array.from(text);
  if (chars.length <= n) {
    return text;
  }
  return chars.slice(-n).join('');
}
