/**
 * パイプライン実行サービス
 * Phase A (メタフレーム抽出) → B (アウトライン+セクション生成) → C (統合+商品注入) → D (品質評価)
 * の逐次実行オーケストレーションとインメモリステータス管理
 */

import { v4 as uuidv4 } from 'uuid';
import { theoryStore } from './theory-store';
import { extractMetaframe } from './metaframe-service';
import { generateOutline } from './outline-service';
import { generateSection } from './section-service';
import { integrateSections } from './integrate-service';
import { injectProductInfo } from './product-service';
import { evaluateLetter, EvaluationResult } from './evaluate-service';
import { callLLM } from './llm-service';
import {
  TheoryFile,
  PipelineStatus,
  StyleGuide,
} from '../types';

// ─── 型定義 ──────────────────────────────────────────────────────────────────

export type PipelinePhase = 'A' | 'B' | 'C' | 'D';

export interface PipelineSection {
  index: number;
  title: string;
  aida_band: string;
  content: string;
  char_count: number;
}

export interface PipelineResult {
  final_text: string;
  total_chars: number;
  quality_score: number;
  sections: PipelineSection[];
  product_injected: boolean;
}

export interface PipelineState {
  pipeline_id: string;
  status: PipelineStatus;
  phase: PipelinePhase | null;
  progress: number;
  result?: PipelineResult;
  error?: string;
  updated_at: string;
}

export interface PipelineProductInfo {
  name: string;
  price?: string;
  features: string[];
  target_audience?: string;
  benefits?: string[];
  offer_details?: string;
  cta_text?: string;
}

export interface PipelineConfigInput {
  total_chars: number;
  copy_framework: 'PAS_PPPP_HYBRID' | 'AIDA' | 'PAS' | 'PPPP';
  style_guide: StyleGuide;
  model: string;
  metaframe_target_tokens?: number;
  quality_threshold?: number;
  max_rewrite_attempts?: number;
}

export interface PipelineRunInput {
  theory_files: TheoryFile[];
  product_info: PipelineProductInfo;
  config: PipelineConfigInput;
}

// ─── インメモリステータスストア ───────────────────────────────────────────────

const pipelineStore = new Map<string, PipelineState>();

/** パイプラインステータスを取得 */
export function getPipelineState(pipelineId: string): PipelineState | undefined {
  return pipelineStore.get(pipelineId);
}

/** テスト用: ストアをクリア */
export function _clearPipelineStore(): void {
  pipelineStore.clear();
}

// ─── ヘルパー ──────────────────────────────────────────────────────────────

function updateState(id: string, patch: Partial<PipelineState>): void {
  const current = pipelineStore.get(id);
  if (current) {
    pipelineStore.set(id, {
      ...current,
      ...patch,
      updated_at: new Date().toISOString(),
    });
  }
}

/**
 * 品質評価結果を基にリライトプロンプトを構築する
 */
function buildRewritePrompt(letter: string, evaluation: EvaluationResult, threshold: number): string {
  return `以下のセールスレターの品質を改善してください。

現在の品質スコア: ${evaluation.total}/100（目標: ${threshold}点以上）

## 評価内訳
- 構造完全性: ${evaluation.structural_completeness}/30
- 理論反映度: ${evaluation.theory_reflection}/25
- 読了促進力: ${evaluation.readability}/20
- 行動喚起力: ${evaluation.call_to_action}/25

## 改善対象のセールスレター
${letter}

## 改善指示
上記の評価フィードバックを踏まえ、品質スコアを${threshold}点以上に改善した完全なセールスレターを出力してください。
- 文字数を大きく変えないこと（元の文字数の±10%以内）
- スコアの低い次元を重点的に改善すること
- セールスの説得力と読了率を高めること

改善したセールスレター本文のみを出力してください（説明文・前置き不要）。`;
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * パイプラインを実行する
 * Phase A → B → C → D の逐次実行
 * 実行中はインメモリのステータスストアを更新する
 *
 * Phase D では品質スコアが quality_threshold 未満の場合、
 * 最大 max_rewrite_attempts 回のリライトループを実行する
 *
 * @param input パイプライン入力（理論ファイル・商品情報・設定）
 * @returns 実行完了後のパイプラインステート
 */
export async function runPipeline(input: PipelineRunInput): Promise<PipelineState> {
  const pipelineId = uuidv4();
  const model = input.config.model;

  // ── 初期ステータス登録 ─────────────────────────────────────────────────
  const initialState: PipelineState = {
    pipeline_id: pipelineId,
    status: 'running',
    phase: 'A',
    progress: 0,
    updated_at: new Date().toISOString(),
  };
  pipelineStore.set(pipelineId, initialState);

  try {
    // ── Phase A: 理論ファイルストア登録 + メタフレーム抽出 ─────────────────
    updateState(pipelineId, { phase: 'A', progress: 5 });

    // 理論ファイルをストアに登録
    for (const file of input.theory_files) {
      theoryStore.set(file);
    }

    const theoryIds = input.theory_files.map((f) => f.id);
    const metaframeTargetTokens = input.config.metaframe_target_tokens ?? 5000;

    const metaframe = await extractMetaframe({
      theory_ids: theoryIds,
      config: {
        target_tokens: metaframeTargetTokens,
      },
    });

    updateState(pipelineId, { phase: 'A', progress: 20 });

    // ── Phase B: アウトライン生成 + 全セクション生成 ──────────────────────
    updateState(pipelineId, { phase: 'B', progress: 25 });

    const outline = await generateOutline({
      metaframe,
      config: {
        total_chars: input.config.total_chars,
        copy_framework: input.config.copy_framework,
      },
    });

    updateState(pipelineId, { phase: 'B', progress: 35 });

    // 各セクションを逐次生成
    const generatedSections: PipelineSection[] = [];
    const styleGuide = input.config.style_guide;

    for (let i = 0; i < outline.sections.length; i++) {
      const section = outline.sections[i];
      const overlapContext =
        i > 0 ? generatedSections[i - 1].content.slice(-200) : '';

      const metaframeSubset = {
        principles: metaframe.principles.filter((p) =>
          section.primary_theories.includes(p.name),
        ),
        triggers: metaframe.triggers,
      };

      const generated = await generateSection({
        section_index: section.index,
        outline_section: section,
        metaframe_subset: metaframeSubset,
        overlap_context: overlapContext,
        style_guide: styleGuide,
        model,
      });

      generatedSections.push({
        index: section.index,
        title: section.title,
        aida_band: section.aida_band,
        content: generated.content,
        char_count: generated.char_count,
      });

      const sectionProgress = 35 + Math.round(((i + 1) / outline.sections.length) * 20);
      updateState(pipelineId, { phase: 'B', progress: sectionProgress });
    }

    updateState(pipelineId, { phase: 'B', progress: 55 });

    // ── Phase C: セクション統合 + 商品情報注入 ──────────────────────────
    updateState(pipelineId, { phase: 'C', progress: 60 });

    const integrationInput = generatedSections.map((s) => ({
      index: s.index,
      content: s.content,
    }));

    const integrated = await integrateSections(integrationInput, model);

    updateState(pipelineId, { phase: 'C', progress: 70 });

    // 商品情報を注入（product-serviceの ProductInfo 型に合わせてマッピング）
    const productInfoForService = {
      name: input.product_info.name,
      price: input.product_info.price ?? '',
      features: input.product_info.features,
      target_audience: input.product_info.target_audience ?? '',
    };

    const injected = await injectProductInfo(
      integrated.integrated_letter,
      productInfoForService,
      model,
    );

    updateState(pipelineId, { phase: 'C', progress: 85 });

    // ── Phase D: 品質評価 + 品質不足時自動リライトループ ──────────────────
    updateState(pipelineId, { phase: 'D', progress: 88 });

    const qualityThreshold = input.config.quality_threshold ?? 60;
    const maxRewriteAttempts = input.config.max_rewrite_attempts ?? 2;

    let currentLetter = injected.modified_letter;
    let evaluation = await evaluateLetter(currentLetter, undefined, model);

    // 品質スコアが閾値未満の場合はリライトループ（最大 maxRewriteAttempts 回）
    for (let rewriteAttempt = 0;
         rewriteAttempt < maxRewriteAttempts && evaluation.total < qualityThreshold;
         rewriteAttempt++) {
      console.log(
        `[Pipeline] Quality score ${evaluation.total} < ${qualityThreshold}, ` +
          `rewriting attempt ${rewriteAttempt + 1}/${maxRewriteAttempts}`,
      );

      updateState(pipelineId, {
        phase: 'D',
        progress: 88 + Math.round(((rewriteAttempt + 1) / maxRewriteAttempts) * 6),
      });

      const rewriteResult = await callLLM({
        prompt: buildRewritePrompt(currentLetter, evaluation, qualityThreshold),
        model,
      });

      currentLetter = rewriteResult.text;
      evaluation = await evaluateLetter(currentLetter, undefined, model);
    }

    // ── 完了 ──────────────────────────────────────────────────────────
    const result: PipelineResult = {
      final_text: currentLetter,
      total_chars: Array.from(currentLetter).length,
      quality_score: evaluation.total,
      sections: generatedSections,
      product_injected: true,
    };

    updateState(pipelineId, {
      status: 'completed',
      phase: 'D',
      progress: 100,
      result,
    });

    return pipelineStore.get(pipelineId)!;

  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    updateState(pipelineId, {
      status: 'failed',
      error: errorMessage,
    });
    return pipelineStore.get(pipelineId)!;
  }
}
