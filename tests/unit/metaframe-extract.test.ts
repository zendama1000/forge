import { describe, it, expect, beforeEach, vi } from 'vitest';
import request from 'supertest';
import app from '../../src/app';
import { theoryStore } from '../../src/services/theory-store';
import { _resetLatestMetaframe } from '../../src/services/metaframe-service';

// ─── LLMサービスをモック（外部 API 呼び出しを回避） ──────────────────────────
vi.mock('../../src/services/llm-service', () => ({
  callLLM: vi.fn(),
  callLLMJson: vi.fn(),
  LLM_MODELS: {
    PRIMARY: 'claude-sonnet-4-5',
    FALLBACK: 'claude-opus-4-5',
  },
  client: {},
}));

import { callLLMJson } from '../../src/services/llm-service';

// ─── モックレスポンス定義 ─────────────────────────────────────────────────────

const mockLLMResponse = {
  principles: [
    {
      name: '希少性原則',
      description: '限定性が購買意欲を高める心理メカニズム',
      application_trigger: 'クロージングフェーズで購買を促進する場面',
      source_theory_ids: ['theory-001'],
    },
    {
      name: '社会的証明',
      description: '他者の行動が意思決定に影響を与える',
      application_trigger: '信頼構築フェーズで安心感を与える場面',
      source_theory_ids: ['theory-001'],
    },
  ],
  triggers: [
    {
      name: 'FOMO（機会損失恐怖）',
      mechanism: '限定性と緊迫感により行動を促進する',
      intensity: 'high',
    },
  ],
  section_mappings: [
    {
      aida_band: 'action',
      recommended_principles: ['希少性原則'],
      emotional_flow: '緊迫感から即時行動へ誘導',
    },
    {
      aida_band: 'desire',
      recommended_principles: ['社会的証明'],
      emotional_flow: '他者成功事例による欲求喚起',
    },
  ],
};

// ─── テストスイート ──────────────────────────────────────────────────────────

describe('POST /api/metaframe/extract', () => {
  beforeEach(() => {
    // テスト間の独立性確保
    theoryStore.clear();
    _resetLatestMetaframe();
    vi.clearAllMocks();

    // デフォルトのモックレスポンスを設定
    vi.mocked(callLLMJson).mockResolvedValue(mockLLMResponse);

    // テスト用理論ファイルをストアに事前登録
    theoryStore.set({
      id: 'theory-001',
      title: 'コピーライティング基礎理論',
      content:
        'セールスコピーライティングの基礎的な理論と原則。希少性、社会的証明、権威性などの心理的トリガーを活用した説得技術について解説します。',
    });
  });

  // behavior: POST /api/metaframe/extract に有効なtheory_ids配列とconfig → 200 + principles・triggers・section_mappingsを含むJSON返却
  it('正常抽出: 200 + principles・triggers・section_mappings を含む JSON 返却', async () => {
    const res = await request(app)
      .post('/api/metaframe/extract')
      .set('Content-Type', 'application/json')
      .send({
        theory_ids: ['theory-001'],
        config: { target_tokens: 2000 },
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('principles');
    expect(res.body).toHaveProperty('triggers');
    expect(res.body).toHaveProperty('section_mappings');
    expect(Array.isArray(res.body.principles)).toBe(true);
    expect(Array.isArray(res.body.triggers)).toBe(true);
    expect(Array.isArray(res.body.section_mappings)).toBe(true);
    expect(res.body.principles.length).toBeGreaterThan(0);
    expect(res.body.triggers.length).toBeGreaterThan(0);
    expect(res.body.section_mappings.length).toBeGreaterThan(0);
  });

  // behavior: POST /api/metaframe/extract にtheory_ids未指定 → 400 + 'theory_ids required'相当のエラー
  it('theory_ids未指定: 400 + theory_ids required 相当のエラー', async () => {
    const res = await request(app)
      .post('/api/metaframe/extract')
      .set('Content-Type', 'application/json')
      .send({
        config: { target_tokens: 2000 },
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('theory_ids');
  });

  // behavior: POST /api/metaframe/extract にconfig.target_tokensを100（下限未満）で送信 → 400 + target_tokensの範囲エラー
  it('target_tokens範囲外(100): 400 + target_tokens の範囲エラー', async () => {
    const res = await request(app)
      .post('/api/metaframe/extract')
      .set('Content-Type', 'application/json')
      .send({
        theory_ids: ['theory-001'],
        config: { target_tokens: 100 },
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('target_tokens');
  });

  // behavior: POST /api/metaframe/extract に存在しないtheory_id → 404 + 該当IDを含むエラー
  it('存在しないtheory_id: 404 + 該当ID を含むエラー', async () => {
    const nonExistentId = 'nonexistent-theory-xyz';

    const res = await request(app)
      .post('/api/metaframe/extract')
      .set('Content-Type', 'application/json')
      .send({
        theory_ids: [nonExistentId],
        config: { target_tokens: 2000 },
      });

    expect(res.status).toBe(404);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error).toContain(nonExistentId);
  });

  // behavior: レスポンスのprinciplesが配列であり各要素にname・description・application_triggerを含む
  it('レスポンス構造: principles の各要素に name・description・application_trigger を含む', async () => {
    const res = await request(app)
      .post('/api/metaframe/extract')
      .set('Content-Type', 'application/json')
      .send({
        theory_ids: ['theory-001'],
        config: { target_tokens: 2000 },
      });

    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.principles)).toBe(true);
    expect(res.body.principles.length).toBeGreaterThan(0);

    for (const principle of res.body.principles) {
      expect(principle).toHaveProperty('name');
      expect(principle).toHaveProperty('description');
      expect(principle).toHaveProperty('application_trigger');
      expect(typeof principle.name).toBe('string');
      expect(typeof principle.description).toBe('string');
      expect(typeof principle.application_trigger).toBe('string');
    }
  });
});
