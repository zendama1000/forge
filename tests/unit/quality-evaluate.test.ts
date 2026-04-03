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

// ─── モック LLM 評価レスポンス ──────────────────────────────────────────────
const MOCK_LLM_EVALUATION = {
  structural_completeness: 25,
  theory_reflection: 20,
  readability: 16,
  call_to_action: 22,
  section_scores: {
    structural_completeness: {
      score: 25,
      max: 30,
      criteria: {
        aida5_band_presence: 8,
        pas_intro_clarity: 6,
        pppp_completeness: 7,
        closing_elements: 4,
      },
      comment: 'AIDA5帯域が明確に存在し、PAS導入部も機能している',
    },
    theory_reflection: {
      score: 20,
      max: 25,
      criteria: {
        metaframe_principle_count: 8,
        theory_connection_quality: 7,
        target_audience_fit: 5,
      },
      comment: 'メタフレーム原則の適用が全体的に良好',
    },
    readability: {
      score: 16,
      max: 20,
      criteria: {
        paragraph_hooks: 4,
        reader_questions: 4,
        story_elements: 4,
        visual_readability: 4,
      },
      comment: '読みやすさは高いが段落長にムラがある',
    },
    call_to_action: {
      score: 22,
      max: 25,
      criteria: {
        cta_clarity: 7,
        urgency_scarcity: 6,
        risk_reversal: 5,
        benefit_specificity: 4,
      },
      comment: 'CTA明確性が高く緊急性も適切',
    },
  },
};

// ─── テスト用セールスレター本文 ───────────────────────────────────────────────
const VALID_LETTER_TEXT = `
【セールスレターサンプル】

あなたは毎日、こんな悩みを抱えていませんか？
時間をかけて作ったコンテンツが、なぜか読まれない。
一生懸命書いたのに、反応がゼロ。

その原因は、実は「構造」にあります。私たちが開発した「メタフレーム・コピーシステム」は、
6つの心理学的理論を統合した革新的な手法です。

実際に導入した300社のうち、97%が3ヶ月以内にコンバージョン率2倍以上を達成しました。
しかも、30日間の全額返金保証付きです。リスクはゼロです。

今なら期間限定で初月50%オフ。残り7席のみとなっております。
今すぐ申し込みフォームへ進み、あなたのビジネスを変えてください。
`.trim();

// ─── テストスイート ──────────────────────────────────────────────────────────

describe('POST /api/evaluate', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // デフォルトのモックLLMレスポンスを設定
    vi.mocked(callLLMJson).mockResolvedValue(MOCK_LLM_EVALUATION);
  });

  // behavior: POST /api/evaluate に有効なletter_text → 200 + structural_completeness(0-30)・theory_reflection(0-25)・readability(0-20)・call_to_action(0-25)・total(0-100)を含むJSON
  it('正常評価: 有効なletter_text → 200 + 4次元スコアとtotalを含むJSON', async () => {
    const res = await request(app)
      .post('/api/evaluate')
      .set('Content-Type', 'application/json')
      .send({ letter_text: VALID_LETTER_TEXT });

    expect(res.status).toBe(200);
    // 4次元スコアが存在する
    expect(res.body).toHaveProperty('structural_completeness');
    expect(res.body).toHaveProperty('theory_reflection');
    expect(res.body).toHaveProperty('readability');
    expect(res.body).toHaveProperty('call_to_action');
    // total が存在し数値であること
    expect(res.body).toHaveProperty('total');
    expect(typeof res.body.structural_completeness).toBe('number');
    expect(typeof res.body.theory_reflection).toBe('number');
    expect(typeof res.body.readability).toBe('number');
    expect(typeof res.body.call_to_action).toBe('number');
    expect(typeof res.body.total).toBe('number');
    // total の範囲確認 (0-100)
    expect(res.body.total).toBeGreaterThanOrEqual(0);
    expect(res.body.total).toBeLessThanOrEqual(100);
  });

  // behavior: POST /api/evaluate にletter_text空文字列 → 400 + エラーメッセージ
  it('空文字列拒否: letter_text空文字列 → 400 + エラーメッセージ', async () => {
    const res = await request(app)
      .post('/api/evaluate')
      .set('Content-Type', 'application/json')
      .send({ letter_text: '' });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.length).toBeGreaterThan(0);
  });

  // behavior: 各スコアが定義範囲内（structural: 0-30, theory: 0-25, readability: 0-20, cta: 0-25）であること
  it('スコア範囲: 各スコアが定義範囲内（structural: 0-30, theory: 0-25, readability: 0-20, cta: 0-25）', async () => {
    const res = await request(app)
      .post('/api/evaluate')
      .set('Content-Type', 'application/json')
      .send({ letter_text: VALID_LETTER_TEXT });

    expect(res.status).toBe(200);
    // structural_completeness: 0-30
    expect(res.body.structural_completeness).toBeGreaterThanOrEqual(0);
    expect(res.body.structural_completeness).toBeLessThanOrEqual(30);
    // theory_reflection: 0-25
    expect(res.body.theory_reflection).toBeGreaterThanOrEqual(0);
    expect(res.body.theory_reflection).toBeLessThanOrEqual(25);
    // readability: 0-20
    expect(res.body.readability).toBeGreaterThanOrEqual(0);
    expect(res.body.readability).toBeLessThanOrEqual(20);
    // call_to_action: 0-25
    expect(res.body.call_to_action).toBeGreaterThanOrEqual(0);
    expect(res.body.call_to_action).toBeLessThanOrEqual(25);
  });

  // behavior: totalがstructural + theory + readability + ctaの合計値と一致すること
  it('total合計一致: totalがstructural + theory + readability + ctaの合計値と一致する', async () => {
    const res = await request(app)
      .post('/api/evaluate')
      .set('Content-Type', 'application/json')
      .send({ letter_text: VALID_LETTER_TEXT });

    expect(res.status).toBe(200);
    const expected =
      res.body.structural_completeness +
      res.body.theory_reflection +
      res.body.readability +
      res.body.call_to_action;
    expect(res.body.total).toBe(expected);
  });

  // behavior: レスポンスにsection_scoresが含まれ、セクション毎の内訳が確認可能
  it('section_scores存在: レスポンスにsection_scoresが含まれセクション毎の内訳が確認可能', async () => {
    const res = await request(app)
      .post('/api/evaluate')
      .set('Content-Type', 'application/json')
      .send({ letter_text: VALID_LETTER_TEXT });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('section_scores');

    const scores = res.body.section_scores;
    // 4次元全てが section_scores に含まれること
    expect(scores).toHaveProperty('structural_completeness');
    expect(scores).toHaveProperty('theory_reflection');
    expect(scores).toHaveProperty('readability');
    expect(scores).toHaveProperty('call_to_action');

    // 各内訳に score・max・criteria が含まれること
    expect(scores.structural_completeness).toHaveProperty('score');
    expect(scores.structural_completeness).toHaveProperty('max');
    expect(scores.structural_completeness).toHaveProperty('criteria');
    expect(scores.structural_completeness.max).toBe(30);

    expect(scores.theory_reflection).toHaveProperty('score');
    expect(scores.theory_reflection).toHaveProperty('max');
    expect(scores.theory_reflection.max).toBe(25);

    expect(scores.readability).toHaveProperty('score');
    expect(scores.readability).toHaveProperty('max');
    expect(scores.readability.max).toBe(20);

    expect(scores.call_to_action).toHaveProperty('score');
    expect(scores.call_to_action).toHaveProperty('max');
    expect(scores.call_to_action.max).toBe(25);

    // criteria はオブジェクトであること
    expect(typeof scores.structural_completeness.criteria).toBe('object');
  });

  // [追加] エッジケース: letter_text フィールド自体が未指定（空ボディ） → 400
  it('[追加] 空ボディ: letter_textフィールドなし → 400', async () => {
    const res = await request(app)
      .post('/api/evaluate')
      .set('Content-Type', 'application/json')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
  });

  // [追加] エッジケース: 空白のみのletter_textも空として拒否する → 400
  it('[追加] 空白のみ: 空白のみのletter_textは空とみなして → 400', async () => {
    const res = await request(app)
      .post('/api/evaluate')
      .set('Content-Type', 'application/json')
      .send({ letter_text: '   \n\t  ' });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(res.body.error).toContain('empty');
  });
});
