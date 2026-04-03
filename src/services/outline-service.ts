/**
 * アウトライン生成サービス
 * LLMを使用してAIDA5帯域マッピングに基づくセールスレターのアウトラインを生成する
 */

import { callLLMJson, LLM_MODELS } from './llm-service';
import { validateAidaBands } from '../utils/aida-config';
import {
  Metaframe,
  OutlineGenerationConfig,
  OutlineGenerationResponse,
  OutlineSection,
  AidaBandName,
} from '../types';

// ─── 型定義 ──────────────────────────────────────────────────────────────────

export interface OutlineGenerationInput {
  metaframe: Metaframe;
  config: OutlineGenerationConfig;
}

/** デフォルトAIDA5帯域比率（total_chars に対する割合） */
const DEFAULT_AIDA_BAND_RATIOS: Record<AidaBandName, number> = {
  attention:  0.08,   //  8% — 注目・掴み
  interest:   0.22,   // 22% — 興味・問題提起
  desire:     0.35,   // 35% — 欲求・ベネフィット
  conviction: 0.20,   // 20% — 確信・証拠
  action:     0.15,   // 15% — 行動・CTA
};

/** LLMが返す個別セクション定義 */
interface LLMOutlineSectionOutput {
  title: string;
  aida_band: AidaBandName;
  target_chars: number;
  primary_theories: string[];
  key_points?: string[];
  emotional_goal?: string;
}

/** LLMが返すアウトライン全体 */
interface LLMOutlineOutput {
  sections: LLMOutlineSectionOutput[];
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * AIDA5帯域マッピングに基づくセールスレターのアウトラインを生成する
 *
 * - メタフレームの原則・トリガーをもとにセクションを設計
 * - 各セクションに aida_band / target_chars / primary_theories を付与
 * - 全セクションの target_chars 合計が total_chars 以上になるよう生成
 * - aida_config が指定された場合は validateAidaBands でバリデーションを実施
 */
export async function generateOutline(input: OutlineGenerationInput): Promise<OutlineGenerationResponse> {
  const { metaframe, config } = input;
  const totalChars = config.total_chars;
  const copyFramework = config.copy_framework;

  // ── AIDA帯域ごとの文字数目安を計算 ──────────────────────────────────────
  let bandCharTargets: Record<AidaBandName, number>;

  if (config.aida_config) {
    // カスタムAIDA設定のバリデーション（aida-config.ts を組み込み）
    // validateAidaBands は大文字始まりのバンド名を期待するため正規化する
    const aidaBandsNormalized = config.aida_config.bands.map((b) => ({
      name: b.name.charAt(0).toUpperCase() + b.name.slice(1),
      start_percent: b.start_percent,
      end_percent: b.end_percent,
      primary_theory_limit: b.primary_theory_limit,
    }));

    const validation = validateAidaBands(aidaBandsNormalized);
    if (!validation.valid) {
      throw new Error(`AIDA configuration is invalid: ${validation.errors.join('; ')}`);
    }

    // カスタム帯域比率から文字数配分を算出
    bandCharTargets = {} as Record<AidaBandName, number>;
    for (const band of config.aida_config.bands) {
      const ratio = (band.end_percent - band.start_percent) / 100;
      bandCharTargets[band.name] = Math.round(totalChars * ratio);
    }
  } else {
    // デフォルト比率を使用
    bandCharTargets = {
      attention:  Math.round(totalChars * DEFAULT_AIDA_BAND_RATIOS.attention),
      interest:   Math.round(totalChars * DEFAULT_AIDA_BAND_RATIOS.interest),
      desire:     Math.round(totalChars * DEFAULT_AIDA_BAND_RATIOS.desire),
      conviction: Math.round(totalChars * DEFAULT_AIDA_BAND_RATIOS.conviction),
      action:     Math.round(totalChars * DEFAULT_AIDA_BAND_RATIOS.action),
    };
  }

  // ── プロンプト構築 ────────────────────────────────────────────────────────

  const principleNames = metaframe.principles.map((p) => p.name);

  const systemPrompt = `あなたはセールスコピーライティングの専門家です。
メタフレームと設定に基づいて、AIDA5帯域マッピングを用いたセールスレターのアウトラインを生成してください。
出力は必ずJSON形式のみで回答してください（前置きや説明文は不要）。`;

  const prompt = `${copyFramework}フレームワークを使用した日本語セールスレターのアウトラインをJSON形式で生成してください。

## コピーフレームワーク: ${copyFramework}
## 合計文字数目標: ${totalChars}文字以上

## AIDA5帯域の文字数配分目安:
- attention（注目・掴み）: 約${bandCharTargets.attention}文字
- interest（興味・問題提起）: 約${bandCharTargets.interest}文字
- desire（欲求・ベネフィット）: 約${bandCharTargets.desire}文字
- conviction（確信・証拠）: 約${bandCharTargets.conviction}文字
- action（行動・CTA）: 約${bandCharTargets.action}文字

## 利用可能な理論原則:
${principleNames.map((n) => `- ${n}`).join('\n')}

## メタフレーム詳細:
### 原則:
${metaframe.principles.map((p) => `- ${p.name}: ${p.description}`).join('\n')}

### 感情トリガー:
${metaframe.triggers.map((t) => `- ${t.name}: ${t.mechanism} (強度: ${t.intensity})`).join('\n')}

## 必須要件:
1. attention/interest/desire/conviction/action の全5帯域を必ず含めること
2. 各セクションの primary_theories は 1-2 個の原則名を含めること
3. 全セクションの target_chars 合計が ${totalChars} 文字以上になること
4. 各帯域の文字数配分は上記目安に従うこと

以下のJSON形式で回答してください:
{
  "sections": [
    {
      "title": "セクションタイトル",
      "aida_band": "attention|interest|desire|conviction|action",
      "target_chars": 数値,
      "primary_theories": ["原則名1"],
      "key_points": ["キーポイント1", "キーポイント2"],
      "emotional_goal": "このセクションで達成する感情目標"
    }
  ]
}`;

  // ── LLM 呼び出し ──────────────────────────────────────────────────────────

  const result = await callLLMJson<LLMOutlineOutput>({
    prompt,
    systemPrompt,
    model: LLM_MODELS.PRIMARY,
    maxTokens: 4096,
  });

  // ── 正規化: index 付与 ────────────────────────────────────────────────────

  const sections: OutlineSection[] = result.sections.map((s, i) => ({
    index: i,
    title: s.title,
    aida_band: s.aida_band,
    target_chars: s.target_chars,
    primary_theories: s.primary_theories,
    ...(s.key_points !== undefined ? { key_points: s.key_points } : {}),
    ...(s.emotional_goal !== undefined ? { emotional_goal: s.emotional_goal } : {}),
  }));

  const totalTargetChars = sections.reduce((sum, s) => sum + s.target_chars, 0);

  return {
    sections,
    total_target_chars: totalTargetChars,
    copy_framework: copyFramework,
  };
}
