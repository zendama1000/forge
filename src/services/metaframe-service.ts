/**
 * メタフレーム抽出サービス
 * LLM を使用して理論ファイルからメタフレームを抽出する
 */

import { callLLMJson, LLM_MODELS } from './llm-service';
import { theoryStore } from './theory-store';
import {
  Metaframe,
  MetaframeExtractionConfig,
  Principle,
  EmotionalTrigger,
  SectionMapping,
} from '../types';

// ─── インメモリ最新メタフレームストア ─────────────────────────────────────────

let latestMetaframe: Metaframe | null = null;

/** 最新のメタフレームを取得する */
export function getLatestMetaframe(): Metaframe | null {
  return latestMetaframe;
}

/** テスト用: 最新メタフレームをリセットする */
export function _resetLatestMetaframe(): void {
  latestMetaframe = null;
}

// ─── 型定義 ──────────────────────────────────────────────────────────────────

export interface MetaframeExtractionInput {
  theory_ids: string[];
  config: MetaframeExtractionConfig;
}

interface LLMMetaframeOutput {
  principles: Principle[];
  triggers: EmotionalTrigger[];
  section_mappings: SectionMapping[];
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * 指定された理論ファイル群からメタフレームを抽出する
 * - theoryStore から対象ファイルを取得
 * - LLM (callLLMJson) で principles / triggers / section_mappings を生成
 * - 結果を latestMetaframe に保存して返す
 */
export async function extractMetaframe(input: MetaframeExtractionInput): Promise<Metaframe> {
  const { theory_ids, config } = input;

  // 理論ファイルのコンテンツを結合
  const theories = theory_ids
    .map((id) => theoryStore.get(id))
    .filter((t): t is NonNullable<typeof t> => t !== undefined);

  const combinedContent = theories
    .map((t) => `=== ${t.title} ===\n${t.content}`)
    .join('\n\n');

  const systemPrompt = `あなたはセールスコピーライティング理論の専門家です。
与えられた理論ファイルから、セールスレター生成に最適なメタフレームを抽出してください。
出力は必ずJSON形式のみで回答してください。`;

  const focusAreasText =
    config.focus_areas && config.focus_areas.length > 0
      ? `\n重点領域: ${config.focus_areas.join(', ')}`
      : '';

  const prompt = `以下の理論ファイルから、セールスレター生成用のメタフレームを抽出してください。
目標トークン数: ${config.target_tokens}トークン以内に収まるよう要約してください。${focusAreasText}

理論ファイル:
${combinedContent}

以下のJSON形式で回答してください（説明文や前置きは不要、JSONのみ）:
{
  "principles": [
    {
      "name": "原則名",
      "description": "原則の詳細説明",
      "application_trigger": "適用するトリガー条件",
      "source_theory_ids": ["source-id"]
    }
  ],
  "triggers": [
    {
      "name": "感情トリガー名",
      "mechanism": "作用メカニズムの説明",
      "intensity": "low|medium|high"
    }
  ],
  "section_mappings": [
    {
      "aida_band": "attention|interest|desire|conviction|action",
      "recommended_principles": ["原則名"],
      "emotional_flow": "このセクションの感情の流れ説明"
    }
  ]
}`;

  const result = await callLLMJson<LLMMetaframeOutput>({
    prompt,
    systemPrompt,
    model: LLM_MODELS.PRIMARY,
    maxTokens: Math.min(config.target_tokens * 3, 32768),
  });

  const metaframe: Metaframe = {
    principles: result.principles,
    triggers: result.triggers,
    section_mappings: result.section_mappings,
    extracted_at: new Date().toISOString(),
    source_theory_ids: theory_ids,
  };

  // 最新メタフレームとして保存
  latestMetaframe = metaframe;

  return metaframe;
}
