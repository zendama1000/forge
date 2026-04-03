import { describe, it, expect, beforeEach, vi } from 'vitest';
import request from 'supertest';
import app from '../../src/app';

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

// ─── モックレスポンス定義（AIDA5帯域 + 合計20000文字） ─────────────────────────

const mockLLMOutlineResponse = {
  sections: [
    {
      title: '驚くべき現実：あなたが見逃している問題の本質',
      aida_band: 'attention',
      target_chars: 1600,
      primary_theories: ['希少性原則'],
      key_points: ['衝撃的な事実で注目を掴む', '読者の現状への強い共感'],
      emotional_goal: '強烈な好奇心と危機意識を喚起する',
    },
    {
      title: 'なぜあなたの問題は解決されなかったのか',
      aida_band: 'interest',
      target_chars: 2200,
      primary_theories: ['社会的証明'],
      key_points: ['問題の根本原因を明らかにする', '多くの人が同じ悩みを抱える事実'],
      emotional_goal: '深い共感と問題意識を高める',
    },
    {
      title: '成功者たちが知っている秘密のアプローチ',
      aida_band: 'interest',
      target_chars: 2300,
      primary_theories: ['権威性'],
      key_points: ['専門家の知見と研究結果', '実績者のアプローチを概説'],
      emotional_goal: '信頼感と期待感を育む',
    },
    {
      title: 'あなたの人生を変える5つの具体的なベネフィット',
      aida_band: 'desire',
      target_chars: 3500,
      primary_theories: ['感情的訴求', 'ストーリーテリング'],
      key_points: ['即効性のある変化を描写', 'ビフォー・アフターの鮮明な対比'],
      emotional_goal: '強烈な欲求と憧れを生み出す',
    },
    {
      title: '実証された効果：数字とデータが証明する結果',
      aida_band: 'desire',
      target_chars: 3700,
      primary_theories: ['社会的証明'],
      key_points: ['統計データと第三者研究', '喜びの声と実績事例'],
      emotional_goal: '欲求をさらに強化し確信に近づける',
    },
    {
      title: '今すぐ決断すべき理由：証拠・保証・実績',
      aida_band: 'conviction',
      target_chars: 4200,
      primary_theories: ['権威性', '希少性原則'],
      key_points: ['権威ある導入実績とメディア掲載', 'リスクリバーサル保証の詳細'],
      emotional_goal: '揺るぎない確信と安心感を持たせる',
    },
    {
      title: '今だけ！特別オファーで人生を変える第一歩を踏み出す',
      aida_band: 'action',
      target_chars: 2500,
      primary_theories: ['希少性原則'],
      key_points: ['期間限定オファーの詳細', '今すぐ申し込む具体的な手順'],
      emotional_goal: '今すぐ行動する強い緊迫感を生む',
    },
  ],
};
// 合計 target_chars: 1600+2200+2300+3500+3700+4200+2500 = 20000

// ─── テスト用有効メタフレーム ─────────────────────────────────────────────────

const validMetaframe = {
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
    {
      name: '権威性',
      description: '専門家の権威が信頼を高める',
      application_trigger: '情報提供フェーズで専門性を示す場面',
    },
    {
      name: '感情的訴求',
      description: '感情に訴えかけることで行動を促進する',
      application_trigger: 'ベネフィット説明フェーズ',
    },
    {
      name: 'ストーリーテリング',
      description: '物語を通じて感情的なつながりを生む',
      application_trigger: '読者との共感構築フェーズ',
    },
  ],
  triggers: [
    {
      name: 'FOMO（機会損失恐怖）',
      mechanism: '限定性と緊迫感により行動を促進する',
      intensity: 'high',
    },
    {
      name: '社会的承認欲求',
      mechanism: '他者から認められたいという欲求を活用する',
      intensity: 'medium',
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
      recommended_principles: ['社会的証明', 'ストーリーテリング'],
      emotional_flow: '欲求喚起から確信形成',
    },
  ],
};

// ─── テストスイート ──────────────────────────────────────────────────────────

describe('POST /api/outline/generate', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // デフォルトのモックLLMレスポンスを設定
    vi.mocked(callLLMJson).mockResolvedValue(mockLLMOutlineResponse);
  });

  // behavior: POST /api/outline/generate に有効なmetaframe + product_slot設定 → 200 + AIDA5帯域を含むoutline JSON返却
  it('正常生成: 有効なmetaframe + config送信 → 200 + AIDA5帯域を含むoutline JSON返却', async () => {
    const res = await request(app)
      .post('/api/outline/generate')
      .set('Content-Type', 'application/json')
      .send({
        metaframe: validMetaframe,
        config: {
          total_chars: 20000,
          copy_framework: 'PAS_PPPP_HYBRID',
        },
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('sections');
    expect(res.body).toHaveProperty('total_target_chars');
    expect(res.body).toHaveProperty('copy_framework');
    expect(Array.isArray(res.body.sections)).toBe(true);
    expect(res.body.sections.length).toBeGreaterThan(0);
  });

  // behavior: レスポンスのsectionsにaida_band（attention/interest/desire/conviction/action）が必ず含まれる
  it('AIDA5帯域網羅: sectionsに全5帯域（attention/interest/desire/conviction/action）が含まれる', async () => {
    const res = await request(app)
      .post('/api/outline/generate')
      .set('Content-Type', 'application/json')
      .send({
        metaframe: validMetaframe,
        config: { total_chars: 20000, copy_framework: 'PAS_PPPP_HYBRID' },
      });

    expect(res.status).toBe(200);

    const aidaBands: string[] = res.body.sections.map((s: { aida_band: string }) => s.aida_band);
    expect(aidaBands).toContain('attention');
    expect(aidaBands).toContain('interest');
    expect(aidaBands).toContain('desire');
    expect(aidaBands).toContain('conviction');
    expect(aidaBands).toContain('action');
  });

  // behavior: POST /api/outline/generate にmetaframe未指定 → 400 + 'metaframe required'相当のエラー
  it('metaframe未指定: 400 + metaframe required 相当のエラー', async () => {
    const res = await request(app)
      .post('/api/outline/generate')
      .set('Content-Type', 'application/json')
      .send({
        config: { total_chars: 20000 },
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('metaframe');
  });

  // behavior: POST /api/outline/generate にcopy_framework未指定 → デフォルトでPAS_PPPP_HYBRIDが適用される
  it('copy_framework未指定: デフォルトでPAS_PPPP_HYBRIDが適用される', async () => {
    const res = await request(app)
      .post('/api/outline/generate')
      .set('Content-Type', 'application/json')
      .send({
        metaframe: validMetaframe,
        // config を一切指定しない
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('copy_framework');
    expect(res.body.copy_framework).toBe('PAS_PPPP_HYBRID');
  });

  // behavior: レスポンスの各sectionにprimary_theories配列（1-2要素）が含まれる
  it('primary_theories: 各sectionにprimary_theories配列（1-2要素）が含まれる', async () => {
    const res = await request(app)
      .post('/api/outline/generate')
      .set('Content-Type', 'application/json')
      .send({
        metaframe: validMetaframe,
        config: { total_chars: 20000, copy_framework: 'PAS_PPPP_HYBRID' },
      });

    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.sections)).toBe(true);
    expect(res.body.sections.length).toBeGreaterThan(0);

    for (const section of res.body.sections) {
      expect(section).toHaveProperty('primary_theories');
      expect(Array.isArray(section.primary_theories)).toBe(true);
      expect(section.primary_theories.length).toBeGreaterThanOrEqual(1);
      expect(section.primary_theories.length).toBeLessThanOrEqual(2);
    }
  });

  // behavior: レスポンスのsections合計target_charsが20000以上である
  it('合計文字数: sections の合計 target_chars が 20000 以上である', async () => {
    const res = await request(app)
      .post('/api/outline/generate')
      .set('Content-Type', 'application/json')
      .send({
        metaframe: validMetaframe,
        config: { total_chars: 20000, copy_framework: 'PAS_PPPP_HYBRID' },
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('total_target_chars');

    const totalChars: number = res.body.sections.reduce(
      (sum: number, s: { target_chars: number }) => sum + s.target_chars,
      0,
    );
    expect(totalChars).toBeGreaterThanOrEqual(20000);
    expect(res.body.total_target_chars).toBeGreaterThanOrEqual(20000);
    // total_target_chars はセクション合計と一致すること
    expect(res.body.total_target_chars).toBe(totalChars);
  });

  // [追加] エッジケース: 空のbody → 400 + metaframe required
  it('[追加] 空ボディ送信: 400 + metaframe required エラー', async () => {
    const res = await request(app)
      .post('/api/outline/generate')
      .set('Content-Type', 'application/json')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(res.body.error.toLowerCase()).toContain('metaframe');
  });
});
