/**
 * セクション統合サービス
 * LLMを使用してセールスレターの複数セクションを統合し、
 * オーバーラップ部分の重複除去・文体統一・継ぎ目調整を行う
 */

import { callLLM, LLM_MODELS } from './llm-service';
import { countChars } from '../utils/text-utils';
import { GeneratedSection } from '../types';

// ─── 型定義 ──────────────────────────────────────────────────────────────────

export interface SeamAdjustment {
  /** 継ぎ目の前後セクション index（[前index, 後index]） */
  between_sections: [number, number];
  /** 継ぎ目で行った調整の説明 */
  adjustment_description: string;
  /** 重複削除により除去した文字数 */
  chars_removed: number;
}

export interface SectionIntegrationResult {
  /** 統合後のセールスレター全文 */
  integrated_letter: string;
  /** 統合後の文字数 */
  total_chars: number;
  /** 継ぎ目調整箇所リスト */
  seam_adjustments: SeamAdjustment[];
}

// ─── LLM レスポンス型 ─────────────────────────────────────────────────────────

interface LLMIntegrationResponse {
  integrated_letter: string;
  seam_adjustments: SeamAdjustment[];
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * 複数のセクションを統合してシームレスなセールスレターを生成する
 *
 * - セクションは index 順にソートしてから統合する
 * - セクションが1つの場合はLLM不要で即座に返す
 * - 統合後文字数が元合計の90%以上になることを検証する
 *
 * @param sections 生成済みセクション配列
 * @param model    使用するLLMモデル（省略時はPrimaryモデル）
 * @throws {Error} 統合後文字数が90%未満の場合
 */
export async function integrateSections(
  sections: GeneratedSection[],
  model?: string,
): Promise<SectionIntegrationResult> {
  // ── インデックス順にソート ──────────────────────────────────────────────
  const sorted = [...sections].sort((a, b) => a.index - b.index);

  // ── 個別セクション文字数合計 ───────────────────────────────────────────
  const totalIndividualChars = sorted.reduce(
    (sum, s) => sum + countChars(s.content),
    0,
  );

  // ── 単一セクションの場合は統合処理不要 ───────────────────────────────────
  if (sorted.length === 1) {
    const content = sorted[0].content;
    return {
      integrated_letter: content,
      total_chars: countChars(content),
      seam_adjustments: [],
    };
  }

  // ── LLM プロンプト構築 ─────────────────────────────────────────────────
  const systemPrompt = `あなたはプロの日本語セールスコピーライターです。
複数のセクションを受け取り、それらを自然に統合した1つのセールスレターを生成してください。
出力はJSON形式のみとし、説明文や前置きは一切含めないこと。`;

  const sectionsText = sorted
    .map((s) => `=== セクション${s.index} ===\n${s.content}`)
    .join('\n\n');

  const seamsDesc = sorted
    .slice(0, -1)
    .map((s, i) => `セクション${s.index}とセクション${sorted[i + 1].index}の継ぎ目`)
    .join('、');

  const prompt = `以下の${sorted.length}つのセクションを、自然なセールスレターとして統合してください。

## セクション一覧
${sectionsText}

## 統合指示
1. セクションを順序通りに結合する
2. 継ぎ目（${seamsDesc}）を自然に調整し、オーバーラップ部分の重複を除去する
3. 文体・トーン・敬語レベルを全体で統一する
4. セクション境界が読者に意識されない自然な流れにする
5. 元の合計文字数の90%以上を維持すること（大幅な削除禁止）

## 出力形式（JSON）
以下のJSON形式のみで回答すること:
{
  "integrated_letter": "統合されたセールスレター本文（全文）",
  "seam_adjustments": [
    {
      "between_sections": [前セクションindex, 後セクションindex],
      "adjustment_description": "調整内容の説明",
      "chars_removed": 削除した文字数（整数）
    }
  ]
}`;

  // max_tokens: 個別合計の約3倍 + バッファ（最低16384）
  const maxTokens = Math.max(16384, Math.round(totalIndividualChars * 3));

  // ── LLM 呼び出し ──────────────────────────────────────────────────────
  const llmResult = await callLLM({
    prompt,
    systemPrompt,
    model: model ?? LLM_MODELS.PRIMARY,
    maxTokens,
  });

  // ── JSON パース ────────────────────────────────────────────────────────
  const cleaned = llmResult.text
    .replace(/^```(?:json)?\s*/m, '')
    .replace(/\s*```$/m, '')
    .trim();

  let parsed: LLMIntegrationResponse;
  try {
    parsed = JSON.parse(cleaned) as LLMIntegrationResponse;
  } catch {
    throw new Error(
      `LLM response is not valid JSON: ${cleaned.slice(0, 200)}`,
    );
  }

  const integratedLetter = (parsed.integrated_letter ?? '').trim();
  const seamAdjustments: SeamAdjustment[] = Array.isArray(parsed.seam_adjustments)
    ? parsed.seam_adjustments
    : [];

  // ── 90% 検証 ──────────────────────────────────────────────────────────
  const integratedChars = countChars(integratedLetter);
  const minRequired = Math.floor(totalIndividualChars * 0.9);

  if (integratedChars < minRequired) {
    throw new Error(
      `統合後文字数(${integratedChars})が元合計(${totalIndividualChars})の90%未満です。` +
        `必要最低文字数: ${minRequired}`,
    );
  }

  return {
    integrated_letter: integratedLetter,
    total_chars: integratedChars,
    seam_adjustments: seamAdjustments,
  };
}
