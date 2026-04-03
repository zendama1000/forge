import { describe, it, expect, beforeEach, vi } from 'vitest';
import request from 'supertest';
import app from '../../src/app';

// ─── pipeline-service をモック（LLM外部呼び出しを回避） ─────────────────────
vi.mock('../../src/services/pipeline-service', () => ({
  runPipeline: vi.fn(),
  getPipelineState: vi.fn(),
  _clearPipelineStore: vi.fn(),
}));

import { runPipeline, getPipelineState } from '../../src/services/pipeline-service';

// ─── テスト用モックデータ ─────────────────────────────────────────────────────

const VALID_THEORY_FILES = [
  {
    id: 'theory-001',
    title: 'セールス理論1: PASフレームワーク',
    content:
      'PAS（Problem-Agitation-Solution）フレームワークは、読者の問題を明確化し、その痛みを増幅させ、解決策を提示するセールスコピーライティングの基本手法です。' +
      '読者がすでに持っている潜在的な問題意識を顕在化させることで、解決策への需要を生み出します。',
  },
];

const VALID_CONFIG = {
  total_chars: 20000,
  copy_framework: 'PAS_PPPP_HYBRID',
  style_guide: {
    tone: '親しみやすく信頼感がある',
    target_audience: '副業を始めたい30〜50代の会社員',
  },
};

const VALID_PRODUCT_INFO = {
  name: 'テスト商品',
  price: '19,800円',
  features: ['高品質なコンテンツ', '24時間サポート', '30日返金保証'],
  target_audience: '副業を始めたい会社員',
};

const MOCK_COMPLETED_STATE = {
  pipeline_id: 'mock-pipeline-id-001',
  status: 'completed' as const,
  phase: 'D' as const,
  progress: 100,
  result: {
    final_text: 'あ'.repeat(21000),
    total_chars: 21000,
    quality_score: 85,
    sections: [
      {
        index: 0,
        title: '注目セクション',
        aida_band: 'attention',
        content: 'あ'.repeat(2000),
        char_count: 2000,
      },
      {
        index: 1,
        title: '興味セクション',
        aida_band: 'interest',
        content: 'い'.repeat(4500),
        char_count: 4500,
      },
      {
        index: 2,
        title: '欲求セクション',
        aida_band: 'desire',
        content: 'う'.repeat(7000),
        char_count: 7000,
      },
      {
        index: 3,
        title: '確信セクション',
        aida_band: 'conviction',
        content: 'え'.repeat(4000),
        char_count: 4000,
      },
      {
        index: 4,
        title: 'アクションセクション',
        aida_band: 'action',
        content: 'お'.repeat(3500),
        char_count: 3500,
      },
    ],
    product_injected: true,
  },
  updated_at: '2026-04-03T10:00:00.000Z',
};

// ─── テストスイート ──────────────────────────────────────────────────────────

describe('Pipeline Orchestrator', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // デフォルト: runPipeline は MOCK_COMPLETED_STATE を返す
    vi.mocked(runPipeline).mockResolvedValue(MOCK_COMPLETED_STATE);
  });

  // behavior: POST /api/letter/generate に全必須設定（theory_files + config + product_info） → 200/202 + pipeline_id返却
  it('正常パイプライン開始: 全必須設定 → 200 + pipeline_id返却', async () => {
    const res = await request(app)
      .post('/api/letter/generate')
      .set('Content-Type', 'application/json')
      .send({
        theory_files: VALID_THEORY_FILES,
        config: VALID_CONFIG,
        product_info: VALID_PRODUCT_INFO,
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('pipeline_id');
    expect(typeof res.body.pipeline_id).toBe('string');
    expect(res.body.pipeline_id.length).toBeGreaterThan(0);
    expect(vi.mocked(runPipeline)).toHaveBeenCalledOnce();
  });

  // behavior: POST /api/letter/generate にtheory_files未指定 → 400 + 必須フィールドエラー
  it('theory_files未指定: 400 + 必須フィールドエラー', async () => {
    const res = await request(app)
      .post('/api/letter/generate')
      .set('Content-Type', 'application/json')
      .send({
        // theory_files を意図的に省略
        config: VALID_CONFIG,
        product_info: VALID_PRODUCT_INFO,
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('theory_files');
    expect(vi.mocked(runPipeline)).not.toHaveBeenCalled();
  });

  // behavior: POST /api/letter/generate にconfig.model未指定 → デフォルトでsonnet-4.6が適用
  it('config.model未指定: デフォルトでsonnet-4.6が適用', async () => {
    // VALID_CONFIG には model フィールドが存在しない
    const configWithoutModel = { ...VALID_CONFIG };

    const res = await request(app)
      .post('/api/letter/generate')
      .set('Content-Type', 'application/json')
      .send({
        theory_files: VALID_THEORY_FILES,
        config: configWithoutModel,
        product_info: VALID_PRODUCT_INFO,
      });

    expect(res.status).toBe(200);
    // runPipeline が config.model = 'claude-sonnet-4-6' で呼び出されることを検証
    expect(vi.mocked(runPipeline)).toHaveBeenCalledWith(
      expect.objectContaining({
        config: expect.objectContaining({ model: 'claude-sonnet-4-6' }),
      }),
    );
  });

  // behavior: GET /api/letter/status/:pipeline_id → 200 + phase(A/B/C/D)・progress(0-100)・status(pending/running/completed/failed)を含むJSON
  it('ステータス取得: 200 + phase・progress・statusを含むJSON', async () => {
    vi.mocked(getPipelineState).mockReturnValue({
      pipeline_id: 'test-pipeline-id',
      status: 'running',
      phase: 'B',
      progress: 45,
      updated_at: '2026-04-03T10:00:00.000Z',
    });

    const res = await request(app).get('/api/letter/status/test-pipeline-id');

    expect(res.status).toBe(200);
    // pipeline_id が返却されること
    expect(res.body).toHaveProperty('pipeline_id');
    expect(res.body.pipeline_id).toBe('test-pipeline-id');
    // status が定義済み値のいずれかであること
    expect(res.body).toHaveProperty('status');
    expect(['pending', 'running', 'completed', 'failed']).toContain(res.body.status);
    // phase が A/B/C/D のいずれかであること
    expect(res.body).toHaveProperty('phase');
    expect(['A', 'B', 'C', 'D']).toContain(res.body.phase);
    // progress が 0-100 の範囲内であること
    expect(res.body).toHaveProperty('progress');
    expect(res.body.progress).toBeGreaterThanOrEqual(0);
    expect(res.body.progress).toBeLessThanOrEqual(100);
  });

  // behavior: 存在しないpipeline_idでstatus取得 → 404
  it('存在しないpipeline_idでstatus取得 → 404', async () => {
    vi.mocked(getPipelineState).mockReturnValue(undefined);

    const res = await request(app).get(
      '/api/letter/status/nonexistent-pipeline-id-xyz-000',
    );

    expect(res.status).toBe(404);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.length).toBeGreaterThan(0);
  });
});
