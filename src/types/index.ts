// ─── 共有型定義 ─────────────────────────────────────────────────────────────────
// セールスレター生成サービス全体で使用するリクエスト/レスポンスインターフェース

// ────────────────────────────────────────────────────────────────────────────
// Phase A: 理論ファイル管理
// ────────────────────────────────────────────────────────────────────────────

export interface TheoryFile {
  id: string;
  title: string;
  content: string;
  metadata?: Record<string, unknown>;
}

export interface TheoryUploadRequest {
  theory_files: TheoryFile[];
}

export interface TheoryFileMeta {
  id: string;
  title: string;
  char_count: number;
  estimated_tokens: number;
}

export interface TheoryUploadResponse {
  files: TheoryFileMeta[];
  total_char_count: number;
  total_estimated_tokens: number;
}

// ────────────────────────────────────────────────────────────────────────────
// Phase A: メタフレーム抽出
// ────────────────────────────────────────────────────────────────────────────

export interface MetaframeExtractionConfig {
  target_tokens: number;
  focus_areas?: string[];
}

export interface MetaframeExtractionRequest {
  theory_ids: string[];
  config: MetaframeExtractionConfig;
}

export interface Principle {
  name: string;
  description: string;
  application_trigger: string;
  source_theory_ids?: string[];
}

export interface EmotionalTrigger {
  name: string;
  mechanism: string;
  intensity: 'low' | 'medium' | 'high';
}

export interface SectionMapping {
  aida_band: string;
  recommended_principles: string[];
  emotional_flow: string;
}

export interface Metaframe {
  principles: Principle[];
  triggers: EmotionalTrigger[];
  section_mappings: SectionMapping[];
  extracted_at?: string;
  source_theory_ids?: string[];
}

export interface MetaframeExtractionResponse extends Metaframe {
  token_count: number;
}

// ────────────────────────────────────────────────────────────────────────────
// Phase B: AIDA帯域設定
// ────────────────────────────────────────────────────────────────────────────

export type AidaBandName = 'attention' | 'interest' | 'desire' | 'conviction' | 'action';

export interface AidaBand {
  name: AidaBandName;
  start_percent: number;
  end_percent: number;
  primary_theory_limit: number;
  description?: string;
}

export interface AidaConfig {
  bands: AidaBand[];
  total_chars: number;
}

// ────────────────────────────────────────────────────────────────────────────
// Phase B: アウトライン生成
// ────────────────────────────────────────────────────────────────────────────

export interface OutlineGenerationConfig {
  total_chars: number;
  copy_framework: 'PAS_PPPP_HYBRID' | 'AIDA' | 'PAS' | 'PPPP';
  aida_config?: AidaConfig;
  overlap_chars?: number;
}

export interface OutlineGenerationRequest {
  metaframe: Metaframe;
  config: OutlineGenerationConfig;
}

export interface OutlineSection {
  index: number;
  title: string;
  aida_band: AidaBandName;
  target_chars: number;
  primary_theories: string[];
  key_points?: string[];
  emotional_goal?: string;
}

export interface OutlineGenerationResponse {
  sections: OutlineSection[];
  total_target_chars: number;
  copy_framework: string;
}

// ────────────────────────────────────────────────────────────────────────────
// Phase C: セクション生成
// ────────────────────────────────────────────────────────────────────────────

export interface StyleGuide {
  tone: string;
  target_audience: string;
  writing_style?: string;
}

export interface MetaframeSubset {
  principles: Principle[];
  triggers?: EmotionalTrigger[];
}

export interface SectionGenerationRequest {
  section_index: number;
  outline_section: OutlineSection;
  metaframe_subset: MetaframeSubset;
  overlap_context: string;
  style_guide: StyleGuide;
  model?: string;
}

export interface SectionGenerationResponse {
  section_index: number;
  content: string;
  char_count: number;
  token_estimate: number;
}

// ────────────────────────────────────────────────────────────────────────────
// Phase C: セクション統合
// ────────────────────────────────────────────────────────────────────────────

export interface GeneratedSection {
  index: number;
  content: string;
}

export interface IntegrationRequest {
  sections: GeneratedSection[];
  overlap_chars?: number;
}

export interface IntegrationResponse {
  integrated_text: string;
  total_chars: number;
  section_count: number;
}

// ────────────────────────────────────────────────────────────────────────────
// Phase D: 品質評価
// ────────────────────────────────────────────────────────────────────────────

export interface EvaluationRequest {
  letter_text: string;
  rubric: 'default' | string;
  model?: string;
}

export interface EvaluationResponse {
  structural_completeness: number;  // 0-30
  theory_reflection: number;        // 0-25
  readability: number;              // 0-20
  call_to_action: number;           // 0-25
  total_score: number;              // 0-100
  feedback: string;
  rewrite_required: boolean;
}

// ────────────────────────────────────────────────────────────────────────────
// Phase D: 商品情報後差し注入
// ────────────────────────────────────────────────────────────────────────────

export interface ProductInfo {
  name: string;
  price?: string;
  features: string[];
  benefits: string[];
  target_audience?: string;
  offer_details?: string;
  cta_text?: string;
}

export interface ProductInjectionRequest {
  draft_text: string;
  product_info: ProductInfo;
  style_guide?: StyleGuide;
  model?: string;
}

export interface ProductInjectionResponse {
  final_text: string;
  char_count: number;
  injection_points: string[];
}

// ────────────────────────────────────────────────────────────────────────────
// フルパイプライン
// ────────────────────────────────────────────────────────────────────────────

export type PipelineStatus = 'pending' | 'running' | 'completed' | 'failed';

export interface PipelineConfig {
  total_chars: number;
  copy_framework: OutlineGenerationConfig['copy_framework'];
  style_guide: StyleGuide;
  metaframe_target_tokens?: number;
  quality_threshold?: number;
  max_rewrite_attempts?: number;
}

export interface PipelineRunRequest {
  theory_files: TheoryFile[];
  product_info: ProductInfo;
  config: PipelineConfig;
}

export interface PipelineRunResponse {
  pipeline_id: string;
  status: PipelineStatus;
  message: string;
}

export interface PipelineStatusResponse {
  pipeline_id: string;
  status: PipelineStatus;
  phase?: string;
  progress_pct?: number;
  result?: {
    final_text: string;
    total_chars: number;
    quality_score: number;
  };
  error?: string;
  updated_at: string;
}

// ────────────────────────────────────────────────────────────────────────────
// 共通エラーレスポンス
// ────────────────────────────────────────────────────────────────────────────

export interface ErrorResponse {
  error: string;
  code?: string;
  details?: unknown;
}
