/**
 * スコアバケット（高/中/低の3段階）に基づくテンプレート選択ロジック
 *
 * - ScoreBucket: 'high' | 'medium' | 'low' の3段階バケット型
 * - SCORE_BUCKET_HIGH_THRESHOLD: 高スコアバケット閾値（この値以上が high）
 * - SCORE_BUCKET_MEDIUM_THRESHOLD: 中スコアバケット閾値（この値以上が medium）
 * - CategoryTemplates: カテゴリごとのバケット別テンプレートテキスト
 * - classifyScoreBucket: totalScore をバケットに分類する
 * - selectTemplate: カテゴリと totalScore に基づいてテンプレートテキストを返す
 */

/**
 * スコアバケットの3段階区分。
 * 'high' ≥ SCORE_BUCKET_HIGH_THRESHOLD
 * 'medium' ≥ SCORE_BUCKET_MEDIUM_THRESHOLD
 * 'low' < SCORE_BUCKET_MEDIUM_THRESHOLD
 */
export type ScoreBucket = 'high' | 'medium' | 'low';

/**
 * カテゴリごとのバケット別テンプレートテキスト。
 * 各バケットに対応するテンプレート文字列を保持する。
 */
export interface CategoryTemplates {
  high: string;
  medium: string;
  low: string;
}

/**
 * 高スコアバケットの閾値。
 * totalScore がこの値以上の場合、'high' バケットに分類される。
 */
export const SCORE_BUCKET_HIGH_THRESHOLD = 70;

/**
 * 中スコアバケットの閾値。
 * totalScore がこの値以上かつ SCORE_BUCKET_HIGH_THRESHOLD 未満の場合、'medium' に分類される。
 */
export const SCORE_BUCKET_MEDIUM_THRESHOLD = 40;

/**
 * カテゴリ別テンプレート定義。
 * カテゴリ名（love / work / health / money）ごとに
 * 高/中/低の各バケットに対応するテンプレートテキストを持つ。
 */
export const CATEGORY_TEMPLATES: Record<string, CategoryTemplates> = {
  love: {
    high: '恋愛運が絶好調です。積極的な行動が大きな実を結ぶでしょう。',
    medium: '恋愛運は安定しています。焦らずに関係を深めていきましょう。',
    low: '恋愛面では慎重さが必要です。自分自身を大切にする時期です。',
  },
  work: {
    high: '仕事運は絶頂期にあります。新しいチャレンジが大きな成果をもたらします。',
    medium: '仕事は順調に進んでいます。コツコツと積み上げることが大切です。',
    low: '仕事では忍耐が必要な時期です。準備を整えて次の機会を待ちましょう。',
  },
  health: {
    high: '健康状態は非常に良好です。活力に満ちた毎日を送れるでしょう。',
    medium: '健康は安定しています。規則正しい生活を心がけてください。',
    low: '体調管理に注意が必要です。無理をせず休養を取ることが大切です。',
  },
  money: {
    high: '金運は上昇気流に乗っています。積極的な投資が吉と出るでしょう。',
    medium: '金運は安定しています。計画的な支出を心がけましょう。',
    low: '金銭面では節約が必要な時期です。無駄遣いを避けて堅実に過ごしましょう。',
  },
};

/**
 * totalScore をスコアバケットに分類する。
 *
 * 分類ルール（境界値は上位バケット優先）:
 * - totalScore >= SCORE_BUCKET_HIGH_THRESHOLD   → 'high'
 * - totalScore >= SCORE_BUCKET_MEDIUM_THRESHOLD → 'medium'
 * - totalScore < SCORE_BUCKET_MEDIUM_THRESHOLD  → 'low'
 *
 * @param totalScore - 分類するスコア（通常 0〜100）
 * @returns 対応するスコアバケット
 * @throws {Error} totalScore が NaN の場合
 */
export function classifyScoreBucket(totalScore: number): ScoreBucket {
  if (Number.isNaN(totalScore)) {
    throw new Error('不正な入力: totalScore が NaN です');
  }

  if (totalScore >= SCORE_BUCKET_HIGH_THRESHOLD) {
    return 'high';
  }

  if (totalScore >= SCORE_BUCKET_MEDIUM_THRESHOLD) {
    return 'medium';
  }

  return 'low';
}

/**
 * カテゴリと totalScore に基づいてテンプレートテキストを選択する。
 *
 * スコアバケット（高/中/低）を決定し、対応するカテゴリのテンプレートテキストを返す。
 *
 * @param category - カテゴリ名（例: 'love', 'work', 'health', 'money'）
 * @param totalScore - 合計重み付きスコア（0〜100）
 * @returns バケットに対応するテンプレートテキスト
 * @throws {Error} totalScore が NaN の場合
 * @throws {Error} 指定したカテゴリが CATEGORY_TEMPLATES に存在しない場合
 */
export function selectTemplate(category: string, totalScore: number): string {
  if (Number.isNaN(totalScore)) {
    throw new Error('不正な入力: totalScore が NaN です');
  }

  const templates = CATEGORY_TEMPLATES[category];
  if (templates === undefined) {
    throw new Error(`カテゴリが見つかりません: ${category}`);
  }

  const bucket = classifyScoreBucket(totalScore);
  return templates[bucket];
}
