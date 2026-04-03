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

import { callLLM } from '../../src/services/llm-service';

// ─── テスト用セクションコンテンツ（各セクション: 約80〜100文字） ────────────────

const SECTION_TEXT_A =
  'これはセクション0のテスト用コンテンツです。セールスレターの冒頭部分として、読者の注意を引きつける役割を担います。具体的なエピソードで始まります。';

const SECTION_TEXT_B =
  'セクション1では読者の問題点を深く掘り下げます。日々の悩みと向き合いながら、解決策を探している読者に共感を示します。感情的なつながりを重視します。';

const SECTION_TEXT_C =
  'セクション2では解決策の提示を行います。具体的なメソッドと実績データを示すことで、読者に信頼感を与えます。証拠に基づいた主張が効果的です。';

const SECTION_TEXT_D =
  'セクション3では商品のベネフィットを詳細に説明します。読者が得られる具体的な変化と価値を明確に伝えます。ビフォーアフターの対比が効果的です。';

const SECTION_TEXT_E =
  'セクション4はクロージングです。行動を促すCTAを含み、今すぐ決断することの重要性を伝えます。限定性と緊急性で読者の背中を押します。';

const SECTION_TEXTS = [
  SECTION_TEXT_A,
  SECTION_TEXT_B,
  SECTION_TEXT_C,
  SECTION_TEXT_D,
  SECTION_TEXT_E,
];

// ─── モック統合結果（各セクションを改行で結合 = 個別合計以上の文字数） ──────────
const MOCK_INTEGRATED_LETTER = SECTION_TEXTS.join('\n\n');

const MOCK_SEAM_ADJUSTMENTS = [
  {
    between_sections: [0, 1],
    adjustment_description: 'セクション0末尾の反復表現を削除し自然な流れを確保',
    chars_removed: 5,
  },
  {
    between_sections: [1, 2],
    adjustment_description: 'セクション1→2の接続詞を調整し文体を統一',
    chars_removed: 3,
  },
  {
    between_sections: [2, 3],
    adjustment_description: 'セクション2→3の重複箇所を除去',
    chars_removed: 8,
  },
  {
    between_sections: [3, 4],
    adjustment_description: 'セクション3→4の感情トーンを統一',
    chars_removed: 2,
  },
];

const mockLLMCallResult = {
  text: JSON.stringify({
    integrated_letter: MOCK_INTEGRATED_LETTER,
    seam_adjustments: MOCK_SEAM_ADJUSTMENTS,
  }),
  model: 'claude-sonnet-4-5',
  input_tokens: 1200,
  output_tokens: 900,
};

// ─── テスト用有効リクエスト（5要素以上） ─────────────────────────────────────

const validSections = [
  { index: 0, content: SECTION_TEXT_A },
  { index: 1, content: SECTION_TEXT_B },
  { index: 2, content: SECTION_TEXT_C },
  { index: 3, content: SECTION_TEXT_D },
  { index: 4, content: SECTION_TEXT_E },
];

// ─── テストスイート ──────────────────────────────────────────────────────────

describe('POST /api/integrate', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // デフォルトのモックLLMレスポンスを設定
    vi.mocked(callLLM).mockResolvedValue(mockLLMCallResult);
  });

  // behavior: POST /api/integrate に有効なsections配列（5要素以上） → 200 + integrated_letter文字列 + total_chars数値を含むJSON
  it('正常統合: 有効なsections配列（5要素以上）→ 200 + integrated_letter文字列 + total_chars数値を含むJSON', async () => {
    const res = await request(app)
      .post('/api/integrate')
      .set('Content-Type', 'application/json')
      .send({ sections: validSections });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('integrated_letter');
    expect(res.body).toHaveProperty('total_chars');
    expect(typeof res.body.integrated_letter).toBe('string');
    expect(res.body.integrated_letter.length).toBeGreaterThan(0);
    expect(typeof res.body.total_chars).toBe('number');
    expect(res.body.total_chars).toBeGreaterThan(0);
  });

  // behavior: POST /api/integrate にsections空配列 → 400 + 'at least one section required'相当のエラー
  it('空配列エラー: sections空配列 → 400 + "at least one section required"相当のエラー', async () => {
    const res = await request(app)
      .post('/api/integrate')
      .set('Content-Type', 'application/json')
      .send({ sections: [] });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('at least one section');
  });

  // behavior: sections配列の各要素にcontentが空のものが含まれる → 400 + 該当section_indexを含むエラー
  it('空content検出: contentが空のsectionが含まれる → 400 + 該当section_indexを含むエラー', async () => {
    const sectionsWithEmpty = [
      { index: 0, content: SECTION_TEXT_A },
      { index: 1, content: SECTION_TEXT_B },
      { index: 2, content: '' }, // 空content（section_index: 2）
      { index: 3, content: SECTION_TEXT_D },
      { index: 4, content: SECTION_TEXT_E },
    ];

    const res = await request(app)
      .post('/api/integrate')
      .set('Content-Type', 'application/json')
      .send({ sections: sectionsWithEmpty });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');

    // エラーメッセージまたはsection_indexフィールドに空セクションのindex(2)が含まれること
    const hasIndex =
      res.body.error.includes('2') ||
      res.body.section_index === 2;
    expect(hasIndex).toBe(true);
  });

  // behavior: integrated_letterの文字数がsections個別文字数合計の90%以上（重複削除による減少を許容）
  it('文字数90%以上: integrated_letterの文字数がsections個別合計の90%以上', async () => {
    const res = await request(app)
      .post('/api/integrate')
      .set('Content-Type', 'application/json')
      .send({ sections: validSections });

    expect(res.status).toBe(200);

    // 個別セクション文字数合計（countCharsと同じ Array.from でカウント）
    const totalIndividualChars = validSections.reduce(
      (sum, s) => sum + Array.from(s.content).length,
      0,
    );
    const minRequired = Math.floor(totalIndividualChars * 0.9);

    expect(res.body.total_chars).toBeGreaterThanOrEqual(minRequired);
  });

  // behavior: レスポンスにseam_adjustments（継ぎ目調整箇所リスト）が含まれる
  it('seam_adjustments存在: レスポンスにseam_adjustments配列が含まれる', async () => {
    const res = await request(app)
      .post('/api/integrate')
      .set('Content-Type', 'application/json')
      .send({ sections: validSections });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('seam_adjustments');
    expect(Array.isArray(res.body.seam_adjustments)).toBe(true);
    expect(res.body.seam_adjustments.length).toBeGreaterThan(0);

    // 各調整エントリの構造を確認
    const firstAdj = res.body.seam_adjustments[0];
    expect(firstAdj).toHaveProperty('between_sections');
    expect(firstAdj).toHaveProperty('adjustment_description');
    expect(Array.isArray(firstAdj.between_sections)).toBe(true);
    expect(firstAdj.between_sections).toHaveLength(2);
    expect(typeof firstAdj.adjustment_description).toBe('string');
  });

  // [追加] エッジケース: sections フィールド自体が undefined（空ボディ） → 400
  it('[追加] 空ボディ: sectionsフィールドなし → 400', async () => {
    const res = await request(app)
      .post('/api/integrate')
      .set('Content-Type', 'application/json')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
  });

  // [追加] エッジケース: 空白のみのcontentも空contentとして扱う → 400
  it('[追加] 空白のみcontent: スペースのみのcontentは空とみなす → 400', async () => {
    const sectionsWithWhitespace = [
      { index: 0, content: SECTION_TEXT_A },
      { index: 1, content: '   ' }, // 空白のみ
    ];

    const res = await request(app)
      .post('/api/integrate')
      .set('Content-Type', 'application/json')
      .send({ sections: sectionsWithWhitespace });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(res.body.error).toContain('1');
  });
});
