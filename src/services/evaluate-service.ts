/**
 * 品質評価サービス
 * LLMを使用してセールスレターを4次元ルーブリックで評価する
 *
 * 評価次元:
 *   - structural_completeness (0-30): AIDA5帯域・PAS導入部・PPPP展開・クロージング
 *   - theory_reflection       (0-25): メタフレーム原則適用・理論接続・ターゲット適合
 *   - readability             (0-20): 段落フック・問いかけ・ストーリー・視覚的読みやすさ
 *   - call_to_action          (0-25): CTA明確性・緊急性・リスクリバーサル・ベネフィット具体性
 */

import { callLLMJson, LLM_MODELS } from './llm-service';

// ─── 型定義 ──────────────────────────────────────────────────────────────────

export interface SectionScoreBreakdown {
  /** このカテゴリの得点 */
  score: number;
  /** このカテゴリの満点 */
  max: number;
  /** サブ基準毎の得点内訳 */
  criteria: Record<string, number>;
  /** 評価コメント（任意） */
  comment?: string;
}

export interface SectionScores {
  structural_completeness: SectionScoreBreakdown;
  theory_reflection: SectionScoreBreakdown;
  readability: SectionScoreBreakdown;
  call_to_action: SectionScoreBreakdown;
}

export interface EvaluationResult {
  /** 構造完全性スコア (0-30) */
  structural_completeness: number;
  /** 理論反映度スコア (0-25) */
  theory_reflection: number;
  /** 読了促進力スコア (0-20) */
  readability: number;
  /** 行動喚起力スコア (0-25) */
  call_to_action: number;
  /** 合計スコア (0-100) = 4次元の合算 */
  total: number;
  /** セクション毎の詳細内訳 */
  section_scores: SectionScores;
}

// ─── LLM レスポンス型 ─────────────────────────────────────────────────────────

interface LLMEvaluationResponse {
  structural_completeness: number;
  theory_reflection: number;
  readability: number;
  call_to_action: number;
  section_scores: {
    structural_completeness: SectionScoreBreakdown;
    theory_reflection: SectionScoreBreakdown;
    readability: SectionScoreBreakdown;
    call_to_action: SectionScoreBreakdown;
  };
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * セールスレターを4次元ルーブリックで評価する
 *
 * - LLMに評価を依頼し、4次元スコアと詳細内訳を取得する
 * - スコアは定義範囲にクランプ（範囲外の場合は境界値に制限）
 * - total は4次元の合算値として自動計算（LLM値を使用しない）
 *
 * @param letterText 評価対象のセールスレター本文
 * @param rubric     カスタムルーブリック設定（省略時はデフォルトルーブリックを使用）
 * @param model      使用するLLMモデル（省略時はPrimaryモデル）
 */
export async function evaluateLetter(
  letterText: string,
  rubric?: Record<string, unknown>,
  model?: string,
): Promise<EvaluationResult> {
  // ── システムプロンプト ──────────────────────────────────────────────────
  const systemPrompt = `あなたは日本語セールスレターの品質評価専門家です。
与えられたセールスレターを4次元ルーブリックに基づいて客観的に評価してください。
出力はJSON形式のみとし、説明文や前置きは一切含めないこと。`;

  // ── カスタムルーブリック注入（任意） ────────────────────────────────────
  const rubricNote = rubric
    ? `\n## カスタムルーブリック\n${JSON.stringify(rubric, null, 2)}\n`
    : '';

  // ── 評価プロンプト構築 ─────────────────────────────────────────────────
  const prompt = `以下のセールスレターを4次元ルーブリックで評価してください。${rubricNote}

## 評価対象セールスレター
${letterText}

## 評価基準

### 1. 構造完全性（structural_completeness）: 0〜30点
- AIDA5帯域の存在（Attention/Interest/Desire/Conviction/Action）
- PAS導入部の明確さ（Problem/Agitation/Solution）
- PPPP展開の完全性（Promise/Picture/Proof/Push）
- クロージング要素の存在（CTA・保証・締め）

### 2. 理論反映度（theory_reflection）: 0〜25点
- メタフレーム原則の具体的適用数
- 理論間の自然な接続
- ターゲット読者への適合性

### 3. 読了促進力（readability）: 0〜20点
- 段落間フック要素
- 読者への問いかけ頻度
- ストーリー要素
- 視覚的読みやすさ（段落長）

### 4. 行動喚起力（call_to_action）: 0〜25点
- CTA明確性
- 緊急性・希少性の適切な使用
- リスクリバーサル（リスク軽減要素）
- ベネフィットの具体性

## 出力形式（JSON）
以下のJSON形式のみで回答すること:
{
  "structural_completeness": 整数(0-30),
  "theory_reflection": 整数(0-25),
  "readability": 整数(0-20),
  "call_to_action": 整数(0-25),
  "section_scores": {
    "structural_completeness": {
      "score": 整数,
      "max": 30,
      "criteria": {
        "aida5_band_presence": 整数,
        "pas_intro_clarity": 整数,
        "pppp_completeness": 整数,
        "closing_elements": 整数
      },
      "comment": "評価コメント"
    },
    "theory_reflection": {
      "score": 整数,
      "max": 25,
      "criteria": {
        "metaframe_principle_count": 整数,
        "theory_connection_quality": 整数,
        "target_audience_fit": 整数
      },
      "comment": "評価コメント"
    },
    "readability": {
      "score": 整数,
      "max": 20,
      "criteria": {
        "paragraph_hooks": 整数,
        "reader_questions": 整数,
        "story_elements": 整数,
        "visual_readability": 整数
      },
      "comment": "評価コメント"
    },
    "call_to_action": {
      "score": 整数,
      "max": 25,
      "criteria": {
        "cta_clarity": 整数,
        "urgency_scarcity": 整数,
        "risk_reversal": 整数,
        "benefit_specificity": 整数
      },
      "comment": "評価コメント"
    }
  }
}`;

  // ── LLM 呼び出し ──────────────────────────────────────────────────────
  const llmResult = await callLLMJson<LLMEvaluationResponse>({
    prompt,
    systemPrompt,
    model: model ?? LLM_MODELS.PRIMARY,
    maxTokens: 2048,
  });

  // ── スコアのクランプ（定義範囲外を境界値に制限） ───────────────────────
  const structural = Math.min(30, Math.max(0, Math.round(llmResult.structural_completeness ?? 0)));
  const theory = Math.min(25, Math.max(0, Math.round(llmResult.theory_reflection ?? 0)));
  const readability = Math.min(20, Math.max(0, Math.round(llmResult.readability ?? 0)));
  const cta = Math.min(25, Math.max(0, Math.round(llmResult.call_to_action ?? 0)));

  // ── total は4次元の合算として自動計算 ─────────────────────────────────
  const total = structural + theory + readability + cta;

  // ── section_scores の構築（LLM値を優先、欠損時はデフォルト） ────────────
  const sectionScores: SectionScores = {
    structural_completeness: llmResult.section_scores?.structural_completeness ?? {
      score: structural,
      max: 30,
      criteria: {},
    },
    theory_reflection: llmResult.section_scores?.theory_reflection ?? {
      score: theory,
      max: 25,
      criteria: {},
    },
    readability: llmResult.section_scores?.readability ?? {
      score: readability,
      max: 20,
      criteria: {},
    },
    call_to_action: llmResult.section_scores?.call_to_action ?? {
      score: cta,
      max: 25,
      criteria: {},
    },
  };

  return {
    structural_completeness: structural,
    theory_reflection: theory,
    readability,
    call_to_action: cta,
    total,
    section_scores: sectionScores,
  };
}
