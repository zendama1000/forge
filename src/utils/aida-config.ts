/**
 * AIDA5帯域マッピング設定のバリデーションロジック
 *
 * AIDA5は5つの帯域（Attention/Interest/Desire/Conviction/Action）で
 * コンテンツの割合配置を定義するフレームワーク。
 */

/** AIDA5帯域定義 */
export interface AidaBand {
  /** 帯域名（Attention / Interest / Desire / Conviction / Action） */
  name: string;
  /** 開始位置（%、0-100） */
  start_percent: number;
  /** 終了位置（%、0-100） */
  end_percent: number;
  /** 使用可能な主要理論の上限数（1-2） */
  primary_theory_limit: number;
}

/** バリデーション結果 */
export interface AidaValidationResult {
  valid: boolean;
  errors: string[];
}

/** AIDA5で必須の帯域名 */
const REQUIRED_BAND_NAMES = ['Attention', 'Interest', 'Desire', 'Conviction', 'Action'] as const;

/**
 * AIDA5帯域設定をバリデーションする
 *
 * 検証項目:
 * 1. 5帯域（Attention/Interest/Desire/Conviction/Action）が全て存在するか
 * 2. 各帯域の primary_theory_limit が 1-2 の範囲内か
 * 3. 帯域の割合合計が 100% を超えていないか
 * 4. 帯域間にギャップ（未定義領域）がないか
 * 5. 帯域間にオーバーラップ（重複領域）がないか
 *
 * @param bands 検証対象の帯域配列
 * @returns バリデーション結果（valid フラグ + エラーメッセージ一覧）
 */
export function validateAidaBands(bands: AidaBand[]): AidaValidationResult {
  const errors: string[] = [];

  // ── Check 1: 5帯域存在チェック ────────────────────────────────────────────
  const bandNames = bands.map((b) => b.name);
  const missingBands = REQUIRED_BAND_NAMES.filter((name) => !bandNames.includes(name));
  if (missingBands.length > 0) {
    errors.push(
      `Missing required bands: ${missingBands.join(', ')}. All 5 AIDA bands are required.`
    );
  }

  // ── Check 2: primary_theory_limit 範囲検証（1-2） ─────────────────────────
  for (const band of bands) {
    if (
      !Number.isFinite(band.primary_theory_limit) ||
      band.primary_theory_limit < 1 ||
      band.primary_theory_limit > 2
    ) {
      errors.push(
        `Band "${band.name}" has invalid primary_theory_limit: ${band.primary_theory_limit} (must be between 1 and 2)`
      );
    }
  }

  // 以下のチェックは帯域を start_percent 昇順にソートして実施
  const sorted = [...bands].sort((a, b) => a.start_percent - b.start_percent);

  // ── Check 3: 割合合計 100% 超過チェック ───────────────────────────────────
  const totalPercent = sorted.reduce(
    (sum, band) => sum + (band.end_percent - band.start_percent),
    0
  );
  if (totalPercent > 100) {
    const excess = +(totalPercent - 100).toFixed(6);
    errors.push(
      `Total band coverage is ${totalPercent}%, which exceeds 100% by ${excess}%.`
    );
  }

  // ── Check 4 & 5: ギャップ / オーバーラップ検出 ───────────────────────────
  for (let i = 0; i < sorted.length - 1; i++) {
    const current = sorted[i];
    const next = sorted[i + 1];

    if (current.end_percent < next.start_percent) {
      // ギャップ: current の終端 < next の始端
      const gapSize = +(next.start_percent - current.end_percent).toFixed(6);
      errors.push(
        `Gap detected between "${current.name}" (ends at ${current.end_percent}%) and "${next.name}" (starts at ${next.start_percent}%): ${gapSize}% is uncovered.`
      );
    } else if (current.end_percent > next.start_percent) {
      // オーバーラップ: current の終端 > next の始端
      const overlapSize = +(current.end_percent - next.start_percent).toFixed(6);
      errors.push(
        `Overlap detected between "${current.name}" (ends at ${current.end_percent}%) and "${next.name}" (starts at ${next.start_percent}%): ${overlapSize}% overlap.`
      );
    }
    // current.end_percent === next.start_percent → 継続なのでエラーなし
  }

  return {
    valid: errors.length === 0,
    errors,
  };
}
