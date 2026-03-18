/**
 * DimensionBar コンポーネントロジック
 *
 * 7次元パラメータの1つを表示するバーのスタイルとアイコン情報を計算する。
 * JSX に依存しない純粋な TypeScript モジュール。
 * Next.js の React コンポーネントからはこの関数を呼び出してスタイルを取得する。
 */

export interface DimensionBarProps {
  /** 表示アイコン（絵文字または文字列） */
  icon: string;
  /** バーの背景色（CSS color文字列、例: '#3b82f6' または 'rgb(59,130,246)'） */
  color: string;
  /** スコア（0〜100）。バーの幅に反映 */
  score?: number;
  /** 次元ラベル名 */
  label?: string;
}

export interface DimensionBarState {
  /** 表示用アイコン文字列 */
  icon: string;
  /** 次元ラベル名 */
  label: string;
  /** バーのインラインスタイル */
  barStyle: {
    backgroundColor: string;
    width: string;
  };
}

/**
 * DimensionBar の表示に必要な状態を計算する。
 *
 * @param props DimensionBarProps
 * @returns DimensionBarState
 */
export function createDimensionBar(props: DimensionBarProps): DimensionBarState {
  const score = props.score ?? 0;

  return {
    icon: props.icon,
    label: props.label ?? '',
    barStyle: {
      backgroundColor: props.color,
      width: `${score}%`,
    },
  };
}
