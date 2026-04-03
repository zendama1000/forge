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

import { callLLM, callLLMJson } from '../../src/services/llm-service';

// ─── モックLLMレスポンス ───────────────────────────────────────────────────────

/** Stage 2 (Critique) の模擬結果 */
const MOCK_CRITIQUE_RESULT = {
  injection_points: [
    '導入部（Attention帯域）で商品名「テスト商品」を問題提起の解決策として言及する',
    '中盤（Desire帯域）で特徴「高品質・使いやすい・副業実績あり」を読者の課題解決として文脈化する',
    'Conviction帯域（後半70%以降）で価格「9,800円」を価値提案と共に提示する',
  ],
  suggestions:
    '理論フレームワーク（PAS+PPPP/AIDA5）の流れを維持しながら、商品名を3箇所以上自然に言及し、価格はConviction帯域以降に配置する',
};

/** Stage 3 (Rewrite) の模擬結果（letter_draftと異なる内容 + 商品名を含む） */
const MOCK_MODIFIED_LETTER =
  '【テスト商品】が、あなたの副業の壁を突破する唯一の鍵です。\n\n' +
  'あなたはこれまで何度も変わろうとしてきたはずです。その繰り返しの中で少しずつ自信を失ってきたのではないでしょうか。\n\n' +
  'テスト商品の特徴である「高品質・使いやすい・副業実績あり」は、まさに情報過多の時代に翻弄されてきた30〜50代のあなたのために開発されました。\n\n' +
  '正しい方法を知れば誰でも変われます。そして今、テスト商品がその正しい方法を提供します。\n\n' +
  '今なら特別価格9,800円でご提供しています。今すぐ始めましょう。';

const MOCK_LLM_RESULT = {
  text: MOCK_MODIFIED_LETTER,
  model: 'claude-sonnet-4-5',
  input_tokens: 600,
  output_tokens: 400,
};

// ─── テスト用有効データ ────────────────────────────────────────────────────────

const VALID_LETTER_DRAFT =
  'あなたはこれまで何度も変わろうとしてきたはずです。\n' +
  'その繰り返しの中で少しずつ自信を失ってきたのではないでしょうか。\n' +
  'しかし、正しい方法を知れば誰でも変われます。';

const VALID_PRODUCT_INFO = {
  name: 'テスト商品',
  price: '9,800円',
  features: ['高品質', '使いやすい', '副業実績あり'],
  target_audience: '副業の壁を感じている30〜50代',
};

// ─── テストスイート ──────────────────────────────────────────────────────────

describe('POST /api/product/inject', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // デフォルトのモックLLMレスポンスを設定
    vi.mocked(callLLMJson).mockResolvedValue(MOCK_CRITIQUE_RESULT);
    vi.mocked(callLLM).mockResolvedValue(MOCK_LLM_RESULT);
  });

  // behavior: POST /api/product/inject に有効なletter_draft + product_info → 200 + modified_letter文字列を含むJSON
  it('正常注入: 有効なletter_draft + product_info → 200 + modified_letter文字列を含むJSON', async () => {
    const res = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        letter_draft: VALID_LETTER_DRAFT,
        product_info: VALID_PRODUCT_INFO,
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('modified_letter');
    expect(typeof res.body.modified_letter).toBe('string');
    expect(res.body.modified_letter.length).toBeGreaterThan(0);
    expect(res.body).toHaveProperty('char_count');
    expect(res.body.char_count).toBeGreaterThan(0);
  });

  // behavior: POST /api/product/inject にproduct_info未指定 → 400 + 'product_info required'相当のエラー
  it('product_info未指定: 400 + product_info required 相当のエラー', async () => {
    const res = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        letter_draft: VALID_LETTER_DRAFT,
        // product_info を省略
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('product_info');
  });

  // behavior: POST /api/product/inject にletter_draft未指定 → 400 + 'letter_draft required'相当のエラー
  it('letter_draft未指定: 400 + letter_draft required 相当のエラー', async () => {
    const res = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        // letter_draft を省略
        product_info: VALID_PRODUCT_INFO,
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('letter_draft');
  });

  // behavior: レスポンスのmodified_letterがletter_draftと異なる内容であること（商品情報が注入されている）
  it('内容変更確認: modified_letterがletter_draftと異なる内容であること（商品情報が注入されている）', async () => {
    const res = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        letter_draft: VALID_LETTER_DRAFT,
        product_info: VALID_PRODUCT_INFO,
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('modified_letter');

    // modified_letter は letter_draft と異なること
    expect(res.body.modified_letter).not.toBe(VALID_LETTER_DRAFT);

    // 商品名が注入されていること（商品情報が含まれている証拠）
    expect(res.body.modified_letter).toContain(VALID_PRODUCT_INFO.name);
  });

  // behavior: product_infoに name・price・features・target_audience が含まれることを検証
  it('構造検証: product_infoにname・price・features・target_audienceが必須', async () => {
    // name 欠落 → 400
    const resNoName = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        letter_draft: VALID_LETTER_DRAFT,
        product_info: {
          // name を省略
          price: '9,800円',
          features: ['高品質'],
          target_audience: 'ターゲット層',
        },
      });
    expect(resNoName.status).toBe(400);
    expect(resNoName.body).toHaveProperty('error');

    // price 欠落 → 400
    const resNoPrice = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        letter_draft: VALID_LETTER_DRAFT,
        product_info: {
          name: 'テスト商品',
          // price を省略
          features: ['高品質'],
          target_audience: 'ターゲット層',
        },
      });
    expect(resNoPrice.status).toBe(400);
    expect(resNoPrice.body).toHaveProperty('error');

    // features 欠落 → 400
    const resNoFeatures = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        letter_draft: VALID_LETTER_DRAFT,
        product_info: {
          name: 'テスト商品',
          price: '9,800円',
          // features を省略
          target_audience: 'ターゲット層',
        },
      });
    expect(resNoFeatures.status).toBe(400);
    expect(resNoFeatures.body).toHaveProperty('error');

    // target_audience 欠落 → 400
    const resNoTarget = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        letter_draft: VALID_LETTER_DRAFT,
        product_info: {
          name: 'テスト商品',
          price: '9,800円',
          features: ['高品質'],
          // target_audience を省略
        },
      });
    expect(resNoTarget.status).toBe(400);
    expect(resNoTarget.body).toHaveProperty('error');
  });

  // [追加] エッジケース: 空ボディ送信 → 400 + letter_draft required
  it('[追加] 空ボディ送信: 400 + letter_draft required エラー', async () => {
    const res = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(res.body.error.toLowerCase()).toContain('letter_draft');
  });

  // [追加] エッジケース: features が空配列 → 400 + バリデーションエラー
  it('[追加] featuresが空配列: 400 + バリデーションエラー', async () => {
    const res = await request(app)
      .post('/api/product/inject')
      .set('Content-Type', 'application/json')
      .send({
        letter_draft: VALID_LETTER_DRAFT,
        product_info: {
          name: 'テスト商品',
          price: '9,800円',
          features: [], // 空配列
          target_audience: 'ターゲット層',
        },
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
  });
});
