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

// ─── モックLLMレスポンス（3000文字相当の日本語テキスト） ───────────────────────

const MOCK_SECTION_CONTENT =
  'あなたはこれまで何度も変わろうとしてきたはずです。毎朝目を覚ますたびに「今日こそは」と誓い、しかし気がつけば夜には同じ自分に戻っている。' +
  'その繰り返しの中で、少しずつ自信を失ってきたのではないでしょうか。あなただけではありません。多くの人が同じ壁に何度もぶつかってきました。' +
  'しかし、今日お伝えすることを知った後、あなたの見方は根本から変わるでしょう。なぜなら、問題はあなたの意志の弱さではなく、' +
  'アプローチそのものにあったからです。正しい方法を知れば、誰でも変われます。それは特別な才能でもなく、膨大な時間でもなく、' +
  '「原理」を理解することだけで達成できるのです。想像してみてください。半年後、周囲の人々があなたを見る目が変わっている場面を。' +
  'あなた自身が鏡の前に立ったとき、そこに映る自分に初めて誇りを感じる瞬間を。それは夢ではありません。実際にそれを実現した人たちが、' +
  'この国のあちこちにいます。彼らに特別なものはありませんでした。ただひとつ、あなたがこれから手にするものを持っていた。それだけの違いです。' +
  'では、なぜ多くの人が失敗してきたのでしょうか。答えは単純です。間違ったゴールを追いかけていたからです。結果だけを見て、' +
  'プロセスを無視した。数字だけを追いかけて、根本的な仕組みを理解しなかった。それが、努力が報われない最大の理由です。' +
  '本当の変化は、外側ではなく内側から始まります。あなたの思考パターン、習慣の構造、感情の反応様式。これらを理解したとき、' +
  '初めて持続的な変化が可能になります。そしてそのための具体的なロードマップが、ここに存在しています。';

const mockLLMCallResult = {
  text: MOCK_SECTION_CONTENT,
  model: 'claude-sonnet-4-5',
  input_tokens: 500,
  output_tokens: 800,
};

// ─── テスト用有効リクエストデータ ─────────────────────────────────────────────

const validOutlineSection = {
  index: 3,
  title: 'あなたの人生を変える5つの具体的なベネフィット',
  aida_band: 'desire',
  target_chars: 3000,
  primary_theories: ['感情的訴求', 'ストーリーテリング'],
  key_points: ['即効性のある変化を描写', 'ビフォー・アフターの鮮明な対比'],
  emotional_goal: '強烈な欲求と憧れを生み出す',
};

const validMetaframeSubset = {
  principles: [
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
  ],
};

const validStyleGuide = {
  tone: '情熱的で共感的',
  target_audience: '変化を求める30〜50代の日本人',
  writing_style: '物語形式で感情に訴える',
};

const validOverlapContext =
  'これまであなたは何度も挑戦してきたかもしれません。しかし、なぜかうまくいかなかった。その理由が今日、ようやく明らかになります。';

// ─── テストスイート ──────────────────────────────────────────────────────────

describe('POST /api/section/generate', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // デフォルトのモックLLMレスポンスを設定
    vi.mocked(callLLM).mockResolvedValue(mockLLMCallResult);
  });

  // behavior: POST /api/section/generate に有効なsection_config + metaframe_subset + overlap_context → 200 + content文字列を含むJSON
  it('正常生成: 有効なsection_config + metaframe_subset + overlap_context → 200 + content文字列を含むJSON', async () => {
    const res = await request(app)
      .post('/api/section/generate')
      .set('Content-Type', 'application/json')
      .send({
        section_index: 3,
        total_sections: 7,
        outline_section: validOutlineSection,
        metaframe_subset: validMetaframeSubset,
        overlap_context: validOverlapContext,
        style_guide: validStyleGuide,
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('section_index');
    expect(res.body).toHaveProperty('content');
    expect(res.body).toHaveProperty('char_count');
    expect(res.body).toHaveProperty('token_estimate');
    expect(res.body.section_index).toBe(3);
    expect(typeof res.body.content).toBe('string');
  });

  // behavior: POST /api/section/generate にsection_index未指定 → 400 + 'section_index required'相当のエラー
  it('section_index未指定: 400 + section_index required 相当のエラー', async () => {
    const res = await request(app)
      .post('/api/section/generate')
      .set('Content-Type', 'application/json')
      .send({
        // section_index を省略
        outline_section: validOutlineSection,
        metaframe_subset: validMetaframeSubset,
        overlap_context: validOverlapContext,
        style_guide: validStyleGuide,
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    expect(res.body.error.toLowerCase()).toContain('section_index');
  });

  // behavior: section_indexがoutlineのsections数を超過 → 400 + 範囲外エラー
  it('section_index範囲外: total_sectionsを超過した場合 → 400 + 範囲外エラー', async () => {
    const res = await request(app)
      .post('/api/section/generate')
      .set('Content-Type', 'application/json')
      .send({
        section_index: 99,       // total_sections: 7 を超過
        total_sections: 7,
        outline_section: { ...validOutlineSection, index: 99 },
        metaframe_subset: validMetaframeSubset,
        overlap_context: validOverlapContext,
        style_guide: validStyleGuide,
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
    // 範囲外エラーのメッセージに section_index または out of range が含まれること
    const errorMsg = res.body.error.toLowerCase();
    expect(
      errorMsg.includes('out of range') || errorMsg.includes('section_index'),
    ).toBe(true);
  });

  // behavior: overlap_contextが空文字列（最初のセクション） → 200 正常処理（オーバーラップなし）
  it('overlap_context空文字: 最初のセクション → 200 正常処理（オーバーラップなし）', async () => {
    const res = await request(app)
      .post('/api/section/generate')
      .set('Content-Type', 'application/json')
      .send({
        section_index: 0,
        total_sections: 7,
        outline_section: {
          ...validOutlineSection,
          index: 0,
          title: '驚くべき現実：あなたが見逃している問題の本質',
          aida_band: 'attention',
          target_chars: 1600,
        },
        metaframe_subset: validMetaframeSubset,
        overlap_context: '',   // 空文字列（最初のセクション）
        style_guide: validStyleGuide,
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('content');
    expect(res.body.section_index).toBe(0);
  });

  // behavior: レスポンスのcontentが空文字列でない
  it('content非空: レスポンスのcontentが空文字列でない', async () => {
    const res = await request(app)
      .post('/api/section/generate')
      .set('Content-Type', 'application/json')
      .send({
        section_index: 3,
        total_sections: 7,
        outline_section: validOutlineSection,
        metaframe_subset: validMetaframeSubset,
        overlap_context: validOverlapContext,
        style_guide: validStyleGuide,
      });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('content');
    expect(typeof res.body.content).toBe('string');
    expect(res.body.content.length).toBeGreaterThan(0);
    // char_count も content が空でないことを間接的に確認
    expect(res.body.char_count).toBeGreaterThan(0);
  });

  // [追加] エッジケース: 空ボディ送信 → 400 + section_index required
  it('[追加] 空ボディ送信: 400 + section_index required エラー', async () => {
    const res = await request(app)
      .post('/api/section/generate')
      .set('Content-Type', 'application/json')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
    expect(res.body.error.toLowerCase()).toContain('section_index');
  });

  // [追加] section_index が total_sections と同値（境界値） → 400 範囲外
  it('[追加] section_index === total_sections（境界値）: 400 + 範囲外エラー', async () => {
    const res = await request(app)
      .post('/api/section/generate')
      .set('Content-Type', 'application/json')
      .send({
        section_index: 7,       // total_sections: 7 と同値（有効範囲外）
        total_sections: 7,
        outline_section: { ...validOutlineSection, index: 7 },
        metaframe_subset: validMetaframeSubset,
        overlap_context: '',
        style_guide: validStyleGuide,
      });

    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
  });
});
