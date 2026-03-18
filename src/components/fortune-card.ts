/**
 * FortuneCard コンポーネントロジック
 *
 * カテゴリ名・スコア・プログレスバースタイルを計算する。
 * JSX に依存しない純粋な TypeScript モジュール。
 * Next.js の React コンポーネントからはこの関数を呼び出してスタイルを取得する。
 */

export interface FortuneCardCategory {
  name?: string;
  totalScore?: number;
  templateText?: string;
  dimensions?: Array<{ name?: string; rawScore: number }>;
}

export interface FortuneCardProps {
  /** スコアを直接渡す場合（0〜100） */
  score?: number;
  /** カテゴリ名を直接渡す場合 */
  categoryName?: string;
  /** APIレスポンスのカテゴリオブジェクト */
  category?: FortuneCardCategory;
}

export interface FortuneCardState {
  /** 表示スコア（0〜100） */
  score: number;
  /** 表示カテゴリ名 */
  categoryName: string;
  /** テンプレートテキスト */
  templateText: string;
  /** プログレスバーのインラインスタイル */
  progressBarStyle: { width: string };
}

/**
 * FortuneCard の表示に必要な状態を計算する。
 *
 * - score prop が指定されていればそれを使用
 * - なければ category.totalScore を使用
 * - どちらもなければ 0（フォールバック）
 *
 * @param props FortuneCardProps
 * @returns FortuneCardState
 */
export function createFortuneCard(props: FortuneCardProps): FortuneCardState {
  const score = props.score ?? props.category?.totalScore ?? 0;
  const categoryName = props.categoryName ?? props.category?.name ?? '';
  const templateText = props.category?.templateText ?? '';

  return {
    score,
    categoryName,
    templateText,
    progressBarStyle: { width: `${score}%` },
  };
}
