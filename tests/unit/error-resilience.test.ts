/**
 * error-resilience.test.ts
 * エラーリカバリ・リトライ・フォールバック・エッジケース対応テスト
 *
 * カバー振る舞い:
 *   1. Claude API接続エラー時にexponential backoffリトライ（最大3回）が実行される
 *   2. リトライ失敗後にSonnet→Opusモデルフォールバックが自動適用される
 *   3. 不正なJSONボディ送信時に全エンドポイントが500ではなく400を返す
 *   4. 出力トークン制限検出時にセクション分割サイズが自動調整される
 *   5. 品質評価60点未満セクションに対してリライトループが1回以上実行される
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import request from 'supertest';
import app from '../../src/app';

// ─── Pipeline Service が依存するサービス群をモック（vi.mock は hoisting される） ───

vi.mock('../../src/services/theory-store', () => ({
  theoryStore: {
    set: vi.fn(),
    get: vi.fn(),
    list: vi.fn().mockReturnValue([]),
  },
}));

vi.mock('../../src/services/metaframe-service', () => ({
  extractMetaframe: vi.fn(),
}));

vi.mock('../../src/services/outline-service', () => ({
  generateOutline: vi.fn(),
}));

vi.mock('../../src/services/section-service', () => ({
  generateSection: vi.fn(),
}));

vi.mock('../../src/services/integrate-service', () => ({
  integrateSections: vi.fn(),
}));

vi.mock('../../src/services/product-service', () => ({
  injectProductInfo: vi.fn(),
}));

vi.mock('../../src/services/evaluate-service', () => ({
  evaluateLetter: vi.fn(),
}));

// ─── インポート ──────────────────────────────────────────────────────────────

import {
  callLLM,
  client,
  _retryConfig,
  LLM_MODELS,
  getAdjustedMaxTokens,
} from '../../src/services/llm-service';

import { runPipeline } from '../../src/services/pipeline-service';
import { extractMetaframe } from '../../src/services/metaframe-service';
import { generateOutline } from '../../src/services/outline-service';
import { generateSection } from '../../src/services/section-service';
import { integrateSections } from '../../src/services/integrate-service';
import { injectProductInfo } from '../../src/services/product-service';
import { evaluateLetter } from '../../src/services/evaluate-service';

// ─── 共通モックレスポンス ────────────────────────────────────────────────────

const MOCK_SUCCESS_RESPONSE = {
  content: [{ type: 'text' as const, text: 'モックLLMレスポンステキスト' }],
  stop_reason: 'end_turn',
  usage: { input_tokens: 100, output_tokens: 50 },
};

const MOCK_TRUNCATED_RESPONSE = {
  content: [{ type: 'text' as const, text: 'トークン制限で切り捨てられたテキスト' }],
  stop_reason: 'max_tokens',
  usage: { input_tokens: 100, output_tokens: 8192 },
};

// ─── テスト 1 & 2: LLM リトライ・フォールバック ──────────────────────────────

describe('LLM Service: Retry & Fallback', () => {
  let createSpy: ReturnType<typeof vi.spyOn>;
  let savedBaseDelay: number;

  beforeEach(() => {
    savedBaseDelay = _retryConfig.baseDelayMs;
    _retryConfig.baseDelayMs = 0; // テスト高速化: exponential backoff 遅延をスキップ
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    createSpy = vi.spyOn(client.messages, 'create' as any);
  });

  afterEach(() => {
    _retryConfig.baseDelayMs = savedBaseDelay;
    vi.restoreAllMocks();
  });

  // behavior: Claude API接続エラー時にexponential backoffリトライ（最大3回）が実行される
  it('接続エラー時にexponential backoffリトライが最大3回実行される', async () => {
    // connection を含む retryable エラー
    const connectionError = new Error('connection refused: ECONNREFUSED');

    // 2回失敗 → 3回目で成功
    createSpy
      .mockRejectedValueOnce(connectionError)
      .mockRejectedValueOnce(connectionError)
      .mockResolvedValueOnce(MOCK_SUCCESS_RESPONSE as any);

    // PRIMARY 以外のモデルを使用（fallback ロジックを除外してリトライのみを検証）
    const result = await callLLM({ prompt: 'テスト', model: 'test-model-retry-only' });

    // client.messages.create が合計3回呼ばれていること（2回失敗 + 1回成功）
    expect(createSpy).toHaveBeenCalledTimes(3);
    expect(result.text).toBe('モックLLMレスポンステキスト');
  });

  // behavior: リトライ失敗後にSonnet→Opusモデルフォールバックが自動適用される
  it('PRIMARYモデルの全リトライ失敗後にFALLBACKモデルへ自動フォールバックする', async () => {
    const connectionError = new Error('network error: fetch failed');

    // PRIMARY モデルは常に失敗、FALLBACK モデルは成功
    createSpy.mockImplementation((params: any) => {
      if (params.model === LLM_MODELS.PRIMARY) {
        return Promise.reject(connectionError);
      }
      // FALLBACK モデルは成功
      return Promise.resolve(MOCK_SUCCESS_RESPONSE as any);
    });

    // PRIMARY モデルで callLLM を呼び出す
    const result = await callLLM({ prompt: 'テスト', model: LLM_MODELS.PRIMARY });

    // FALLBACKモデルで成功していること
    expect(result.model).toBe(LLM_MODELS.FALLBACK);
    expect(result.text).toBe('モックLLMレスポンステキスト');

    // PRIMARY 3回リトライ + FALLBACK 1回 = 合計4回呼ばれていること
    expect(createSpy).toHaveBeenCalledTimes(_retryConfig.maxRetries + 1);

    // 最後の呼び出しが FALLBACK モデルで行われていること
    const lastCall = createSpy.mock.calls[createSpy.mock.calls.length - 1][0] as any;
    expect(lastCall.model).toBe(LLM_MODELS.FALLBACK);
  });
});

// ─── テスト 3: 不正 JSON ボディ → 400 ────────────────────────────────────────

describe('Error Handler: 不正JSONボディ → 400', () => {
  // behavior: 不正なJSONボディ送信時に全エンドポイントが500ではなく400を返す
  it('不正なJSONボディ送信で400が返却される（500ではない）', async () => {
    // Content-Type: application/json で不正なJSONボディを送信
    const res = await request(app)
      .post('/api/evaluate')
      .set('Content-Type', 'application/json')
      .send('{ invalid json: here }');

    // 400 が返ること（500 ではない）
    expect(res.status).toBe(400);
    expect(res.status).not.toBe(500);

    // レスポンスボディにエラー情報が含まれること
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');

    // INVALID_JSON コードが設定されていること
    expect(res.body).toHaveProperty('code');
    expect(res.body.code).toBe('INVALID_JSON');
  });

  // [追加] エッジケース: 別エンドポイントでも同様に400が返ること
  it('[追加] 別エンドポイント（/api/outline/generate）でも不正JSON → 400', async () => {
    const res = await request(app)
      .post('/api/outline/generate')
      .set('Content-Type', 'application/json')
      .send('not a json at all <<<');

    expect(res.status).toBe(400);
    expect(res.status).not.toBe(500);
    expect(res.body).toHaveProperty('code');
    expect(res.body.code).toBe('INVALID_JSON');
  });
});

// ─── テスト 4: トークン制限検出・セクションサイズ自動調整 ─────────────────────

describe('LLM Service: トークン制限検出・セクションサイズ自動調整', () => {
  let createSpy: ReturnType<typeof vi.spyOn>;
  let savedBaseDelay: number;

  beforeEach(() => {
    savedBaseDelay = _retryConfig.baseDelayMs;
    _retryConfig.baseDelayMs = 0;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    createSpy = vi.spyOn(client.messages, 'create' as any);
  });

  afterEach(() => {
    _retryConfig.baseDelayMs = savedBaseDelay;
    vi.restoreAllMocks();
  });

  // behavior: 出力トークン制限検出時にセクション分割サイズが自動調整される
  it('stop_reason=max_tokens時にtruncated=trueが返され、getAdjustedMaxTokensで縮小サイズが算出される', async () => {
    // max_tokens で切り捨てられたレスポンスを返す
    createSpy.mockResolvedValueOnce(MOCK_TRUNCATED_RESPONSE as any);

    const originalMaxTokens = 8192;
    const result = await callLLM({
      prompt: 'テスト',
      model: 'test-model-no-fallback',
      maxTokens: originalMaxTokens,
    });

    // truncated フラグが true であること
    expect(result.truncated).toBe(true);
    expect(result.stop_reason).toBe('max_tokens');

    // getAdjustedMaxTokens でサイズが 80% に縮小されること
    const adjustedTokens = getAdjustedMaxTokens(originalMaxTokens, result.truncated);
    expect(adjustedTokens).toBeLessThan(originalMaxTokens);
    expect(adjustedTokens).toBe(Math.floor(originalMaxTokens * 0.8)); // 6553

    // truncated=false の場合は変更なし（エッジケース）
    const noAdjust = getAdjustedMaxTokens(originalMaxTokens, false);
    expect(noAdjust).toBe(originalMaxTokens);

    // 異なるトークン制限値でも 80% 縮小が適用されること
    expect(getAdjustedMaxTokens(4096, true)).toBe(Math.floor(4096 * 0.8)); // 3276
    expect(getAdjustedMaxTokens(16384, true)).toBe(Math.floor(16384 * 0.8)); // 13107
  });
});

// ─── テスト 5: 品質評価 60点未満 → リライトループ ────────────────────────────

describe('Pipeline Service: 品質評価60点未満 → 自動リライトループ', () => {
  let createSpy: ReturnType<typeof vi.spyOn>;
  let savedBaseDelay: number;

  beforeEach(() => {
    savedBaseDelay = _retryConfig.baseDelayMs;
    _retryConfig.baseDelayMs = 0;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    createSpy = vi.spyOn(client.messages, 'create' as any);

    // callLLM（リライト用）が有効なレスポンスを返すよう設定
    createSpy.mockResolvedValue({
      content: [{ type: 'text' as const, text: 'リライト後の改善されたセールスレター本文（テスト用）' }],
      stop_reason: 'end_turn',
      usage: { input_tokens: 200, output_tokens: 300 },
    } as any);

    // ── Phase A: メタフレーム抽出モック ────────────────────────────────────
    vi.mocked(extractMetaframe).mockResolvedValue({
      principles: [
        {
          name: 'principle-pas',
          description: 'PASフレームワーク原則',
          application_trigger: '問題提示時',
        },
      ],
      triggers: [],
      section_mappings: [],
    } as any);

    // ── Phase B: アウトライン生成モック ────────────────────────────────────
    vi.mocked(generateOutline).mockResolvedValue({
      sections: [
        {
          index: 0,
          title: 'Attentionセクション',
          aida_band: 'attention',
          target_chars: 2000,
          primary_theories: ['principle-pas'],
        },
      ],
    } as any);

    // ── Phase B: セクション生成モック ──────────────────────────────────────
    vi.mocked(generateSection).mockResolvedValue({
      section_index: 0,
      content: 'テスト用セールスコピー本文',
      char_count: 200,
      token_estimate: 400,
    } as any);

    // ── Phase C: セクション統合モック ──────────────────────────────────────
    vi.mocked(integrateSections).mockResolvedValue({
      integrated_letter: '統合されたセールスレター本文（テスト用）',
    } as any);

    // ── Phase C: 商品情報注入モック ────────────────────────────────────────
    vi.mocked(injectProductInfo).mockResolvedValue({
      modified_letter: '商品情報注入済みセールスレター（テスト用）',
    } as any);
  });

  afterEach(() => {
    _retryConfig.baseDelayMs = savedBaseDelay;
    vi.restoreAllMocks();
    vi.clearAllMocks();
  });

  // behavior: 品質評価60点未満セクションに対してリライトループが1回以上実行される
  it('品質スコア60点未満の場合にリライトループが1回以上実行され完了する', async () => {
    // 1回目評価: 55点（閾値60未満）→ リライトトリガー
    // 2回目評価: 80点（閾値60以上）→ ループ終了
    vi.mocked(evaluateLetter)
      .mockResolvedValueOnce({
        structural_completeness: 14,
        theory_reflection: 12,
        readability: 10,
        call_to_action: 19,
        total: 55, // 60 未満 → リライト実行
        section_scores: {
          structural_completeness: { score: 14, max: 30, criteria: {} },
          theory_reflection: { score: 12, max: 25, criteria: {} },
          readability: { score: 10, max: 20, criteria: {} },
          call_to_action: { score: 19, max: 25, criteria: {} },
        },
      } as any)
      .mockResolvedValueOnce({
        structural_completeness: 24,
        theory_reflection: 20,
        readability: 16,
        call_to_action: 22,
        total: 82, // 60 以上 → ループ終了
        section_scores: {
          structural_completeness: { score: 24, max: 30, criteria: {} },
          theory_reflection: { score: 20, max: 25, criteria: {} },
          readability: { score: 16, max: 20, criteria: {} },
          call_to_action: { score: 22, max: 25, criteria: {} },
        },
      } as any);

    const state = await runPipeline({
      theory_files: [
        {
          id: 'theory-001',
          title: 'PASフレームワーク理論',
          content: 'テスト用理論ファイル内容',
        },
      ],
      product_info: {
        name: 'テスト商品',
        features: ['高品質', '30日保証'],
      },
      config: {
        total_chars: 20000,
        copy_framework: 'PAS_PPPP_HYBRID',
        style_guide: {
          tone: '親しみやすく信頼感がある',
          target_audience: '副業を始めたい30〜50代',
        },
        model: 'claude-sonnet-4-5',
        quality_threshold: 60, // 60点未満でリライトトリガー
        max_rewrite_attempts: 2,
      },
    });

    // パイプラインが正常完了していること
    expect(state.status).toBe('completed');
    expect(state.result).toBeDefined();

    // evaluateLetter が2回呼ばれていること
    // （初回評価55点→リライト実行→再評価82点→完了）
    expect(vi.mocked(evaluateLetter)).toHaveBeenCalledTimes(2);

    // リライト用 callLLM（client.messages.create）が1回以上呼ばれていること
    expect(createSpy.mock.calls.length).toBeGreaterThanOrEqual(1);

    // 最終スコアが再評価後の値（82点）であること
    expect(state.result!.quality_score).toBe(82);
  });
});
