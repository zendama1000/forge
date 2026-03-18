/**
 * 倫理チェック第1段ゲート: 禁止表現検出エンジン（ルールベース）
 * ethics-data.ts の禁止表現リストを用いて正規表現マッチングを実行する
 */

import { PROHIBITED_EXPRESSIONS } from './ethics-data';

/** 違反検出結果の1件 */
export interface ViolationResult {
  /** マッチした表現文字列 */
  pattern: string;
  /** テキスト内の開始位置（0始まり） */
  position: number;
  /** 適用法令（景品表示法 | 消費者契約法） */
  law_reference: string;
  /** 否定的文脈フラグ（「〜わけではありません」等の否定文脈で使われている場合 true） */
  context_flag: boolean;
}

/** detectViolations の戻り値 */
export interface DetectionResult {
  violations: ViolationResult[];
}

/**
 * 否定的文脈の判定に使うパターン
 * マッチ位置の直後に否定表現が続く場合に context_flag = true とする
 */
const NEGATION_PATTERNS: RegExp[] = [
  /わけではありません/,
  /とは限りません/,
  /わけでは/,
  /保証しません/,
  /とは言えません/,
  /ではなく/,
];

/** マッチ直後に参照するコンテキストウィンドウのサイズ（文字数） */
const CONTEXT_WINDOW_SIZE = 30;

/**
 * 指定位置のマッチが否定的文脈かどうかを判定する
 * @param text 検査対象テキスト全体
 * @param matchStart マッチ開始位置
 * @param matchLength マッチ長
 * @returns 否定的文脈であれば true
 */
function isNegationContext(
  text: string,
  matchStart: number,
  matchLength: number,
): boolean {
  const contextEnd = Math.min(
    text.length,
    matchStart + matchLength + CONTEXT_WINDOW_SIZE,
  );
  const contextText = text.substring(matchStart, contextEnd);
  return NEGATION_PATTERNS.some((pat) => pat.test(contextText));
}

/**
 * テキスト中の禁止表現を検出する（ルールベース第1段ゲート）
 *
 * @param text 検査対象テキスト
 * @returns 違反結果の配列を含む DetectionResult
 *
 * @example
 * detectViolations('必ず当たる占いです')
 * // => { violations: [{ pattern: '必ず当たる', position: 0, law_reference: '景品表示法', context_flag: false }] }
 */
export function detectViolations(text: string): DetectionResult {
  if (!text) {
    return { violations: [] };
  }

  const violations: ViolationResult[] = [];

  for (const expr of PROHIBITED_EXPRESSIONS) {
    // グローバルフラグ付きで全マッチを取得
    const globalPattern = new RegExp(expr.pattern.source, 'g');
    const matches = [...text.matchAll(globalPattern)];

    for (const match of matches) {
      const position = match.index ?? 0;
      const matchedText = match[0];
      const context_flag = isNegationContext(text, position, matchedText.length);

      violations.push({
        pattern: matchedText,
        position,
        law_reference: expr.law_reference,
        context_flag,
      });
    }
  }

  return { violations };
}
