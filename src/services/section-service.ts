/**
 * セクション生成サービス
 * LLMを使用してセールスレターの各セクション本文を生成する
 * overlap_context による文脈継続と target_chars 目標文字数制御を実装
 */

import { callLLM, LLM_MODELS } from './llm-service';
import { countChars, estimateTokens } from '../utils/text-utils';
import {
  OutlineSection,
  MetaframeSubset,
  StyleGuide,
  SectionGenerationResponse,
} from '../types';

// ─── 型定義 ──────────────────────────────────────────────────────────────────

export interface SectionGenerationInput {
  section_index: number;
  outline_section: OutlineSection;
  metaframe_subset: MetaframeSubset;
  overlap_context: string;
  style_guide: StyleGuide;
  model?: string;
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * セールスレターの1セクション分の本文を生成する
 *
 * - overlap_context が非空の場合、前セクションとの文脈継続を促す
 * - target_chars に近い文字数になるようLLMに指示する
 * - 出力はプレーンテキスト（JSON非構造化）
 */
export async function generateSection(
  input: SectionGenerationInput,
): Promise<SectionGenerationResponse> {
  const {
    section_index,
    outline_section,
    metaframe_subset,
    overlap_context,
    style_guide,
    model,
  } = input;

  const { title, aida_band, target_chars, primary_theories, key_points, emotional_goal } =
    outline_section;

  // ── プロンプト構築 ─────────────────────────────────────────────────────────

  const systemPrompt = `あなたはプロの日本語セールスコピーライターです。
指定されたセクションの本文を、目標文字数に合わせて生成してください。
出力は本文テキストのみとし、タイトルや見出し、前置き、説明文は一切含めないこと。
日本語で、読者の感情に訴えるセールスコピーを書いてください。`;

  // 原則リスト
  const principlesText = metaframe_subset.principles
    .map((p) => `- ${p.name}: ${p.description}（適用場面: ${p.application_trigger}）`)
    .join('\n');

  // 感情トリガーリスト（存在する場合）
  const triggersText =
    metaframe_subset.triggers && metaframe_subset.triggers.length > 0
      ? metaframe_subset.triggers
          .map((t) => `- ${t.name}: ${t.mechanism}（強度: ${t.intensity}）`)
          .join('\n')
      : '（なし）';

  // キーポイントリスト（存在する場合）
  const keyPointsText =
    key_points && key_points.length > 0
      ? key_points.map((kp) => `- ${kp}`).join('\n')
      : '（指定なし）';

  // overlap_context セクション（空の場合は省略）
  const overlapSection =
    overlap_context && overlap_context.trim().length > 0
      ? `## 前セクションの末尾（文脈継続用）
以下の文章の直後に続く形で、自然な文脈で本文を書き始めてください:
"""
${overlap_context}
"""
`
      : `## 文脈継続
これはレターの最初のセクションです。読者の注意を引く書き出しから始めてください。
`;

  const writingStyle = style_guide.writing_style
    ? `- 文章スタイル: ${style_guide.writing_style}`
    : '';

  const emotionalGoalText = emotional_goal ? emotional_goal : `${aida_band}帯域の感情目標を達成すること`;

  const prompt = `以下の仕様に基づいて、セールスレターのセクション本文を生成してください。

## セクション情報
- セクション番号: ${section_index}
- タイトル: ${title}
- AIDA帯域: ${aida_band}
- 目標文字数: ${target_chars}文字
- 感情目標: ${emotionalGoalText}
- キーポイント:
${keyPointsText}

## 適用する理論原則
${principlesText}

## 感情トリガー
${triggersText}

## スタイルガイド
- トーン: ${style_guide.tone}
- ターゲット読者: ${style_guide.target_audience}
${writingStyle}

${overlapSection}
## 生成指示
- 本文テキストのみ出力すること（タイトル・見出し・前置き・説明文は不要）
- 目標文字数 ${target_chars} 文字（±20%以内）になるよう生成すること
- セクションの感情目標「${emotionalGoalText}」を達成する文章にすること
- 読者の感情を動かす具体的なエピソード・事例・数字を活用すること
- ${style_guide.tone}なトーンで、${style_guide.target_audience}に向けて書くこと`;

  // ── LLM 呼び出し ──────────────────────────────────────────────────────────

  // target_chars * 2 トークン(日本語換算)にバッファを加えた max_tokens を設定
  const maxTokens = Math.max(8192, Math.round(target_chars * 2.5));

  const result = await callLLM({
    prompt,
    systemPrompt,
    model: model ?? LLM_MODELS.PRIMARY,
    maxTokens,
  });

  const content = result.text.trim();

  // ── レスポンス構築 ────────────────────────────────────────────────────────

  return {
    section_index,
    content,
    char_count: countChars(content),
    token_estimate: estimateTokens(content),
  };
}
