/**
 * FortunePage ロジック Layer 1 テスト
 *
 * - 7次元パラメータ管理（全フィールド表示・0-100値設定）
 * - フォーム送信 → POST /api/fortune
 * - APIレスポンス後 → FortuneCardで結果カード（カテゴリ名・プログレスバー・スコア値）表示
 * - API通信中 → ローディング状態表示
 *
 * テストフレームワーク: vitest
 */

import { describe, it, expect, vi } from 'vitest';
import {
  DIMENSIONS,
  createInitialPageState,
  updateDimensionValue,
  setLoadingState,
  buildResultCards,
  setResultState,
  setErrorState,
  buildFortuneRequest,
  submitFortune,
} from '../../components/fortune-page';
import type { FortuneCardCategory } from '../../components/fortune-card';

// ─── テスト用モックデータ ──────────────────────────────────────────────────────

const MOCK_CATEGORIES: FortuneCardCategory[] = [
  {
    name: '恋愛運',
    totalScore: 75,
    templateText: '恋愛運は良好です。積極的に行動することで新たな出会いが期待できます。',
    dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 70 + i })),
  },
  {
    name: '仕事運',
    totalScore: 60,
    templateText: '仕事運は普通です。着実にコツコツと取り組みましょう。',
    dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 55 + i })),
  },
  {
    name: '金運',
    totalScore: 50,
    templateText: '金運は安定しています。無駄遣いに気をつけましょう。',
    dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 45 + i })),
  },
  {
    name: '健康運',
    totalScore: 80,
    templateText: '健康運は優れています。体を動かす絶好の機会です。',
    dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: 75 + i })),
  },
];

// ─── 7次元パラメータ管理 ──────────────────────────────────────────────────────

describe('FortunePage: 7次元パラメータ管理', () => {
  // behavior: 7次元パラメータ入力フィールドが全て表示され、0-100の値を設定できる
  it('初期状態で7つの次元が存在し、全て0-100の範囲内の整数値を持つ', () => {
    const state = createInitialPageState();

    // 7次元の存在確認（DIMENSIONS定義と一致）
    expect(DIMENSIONS).toHaveLength(7);
    expect(state.dimensions).toHaveLength(7);

    // 全次元が0-100の整数値を持つ
    state.dimensions.forEach((d) => {
      expect(d.value).toBeGreaterThanOrEqual(0);
      expect(d.value).toBeLessThanOrEqual(100);
      expect(Number.isInteger(d.value)).toBe(true);
    });
  });

  // behavior: 7次元パラメータ入力フィールドが全て表示され、0-100の値を設定できる
  it('updateDimensionValueで0・中間・100の値を設定できる', () => {
    let state = createInitialPageState();

    // 最小値 0
    state = updateDimensionValue(state, 0, 0);
    expect(state.dimensions[0].value).toBe(0);

    // 最大値 100
    state = updateDimensionValue(state, 6, 100);
    expect(state.dimensions[6].value).toBe(100);

    // 中間値 50
    state = updateDimensionValue(state, 3, 50);
    expect(state.dimensions[3].value).toBe(50);
  });

  // behavior: 7次元パラメータ入力フィールドが全て表示され、0-100の値を設定できる
  it('7次元の各インデックス（0〜6）に対して独立して値を設定できる', () => {
    let state = createInitialPageState();

    // 全インデックスにそれぞれ異なる値を設定
    for (let i = 0; i < 7; i++) {
      state = updateDimensionValue(state, i, i * 10 + 10); // 10, 20, ..., 70
    }

    for (let i = 0; i < 7; i++) {
      expect(state.dimensions[i].value).toBe(i * 10 + 10);
    }
  });

  // behavior: [追加] 1つの次元を更新しても他の次元は変化しない
  it('[追加] 1つの次元を更新しても他の次元の値は変わらない', () => {
    let state = createInitialPageState();
    const originalValues = state.dimensions.map((d) => d.value);

    state = updateDimensionValue(state, 2, 75);
    expect(state.dimensions[2].value).toBe(75);

    // インデックス2以外は変化なし
    state.dimensions.forEach((d, i) => {
      if (i !== 2) {
        expect(d.value).toBe(originalValues[i]);
      }
    });
  });

  // behavior: [追加] エッジケース: 100を超える値は100にクランプ
  it('[追加] エッジケース: 100を超える値は100にクランプされる', () => {
    let state = createInitialPageState();
    state = updateDimensionValue(state, 0, 150);
    expect(state.dimensions[0].value).toBe(100);
  });

  // behavior: [追加] エッジケース: 0未満の値は0にクランプ
  it('[追加] エッジケース: 0未満の値は0にクランプされる', () => {
    let state = createInitialPageState();
    state = updateDimensionValue(state, 0, -10);
    expect(state.dimensions[0].value).toBe(0);
  });

  // behavior: [追加] 小数値は整数に丸める
  it('[追加] 小数値は最も近い整数に丸められる（45.7 → 46）', () => {
    let state = createInitialPageState();
    state = updateDimensionValue(state, 1, 45.7);
    expect(state.dimensions[1].value).toBe(46);
    expect(Number.isInteger(state.dimensions[1].value)).toBe(true);
  });
});

// ─── フォーム送信 → POST /api/fortune ────────────────────────────────────────

describe('FortunePage: 占い実行ボタンクリック → POST /api/fortune にリクエスト送信', () => {
  // behavior: 占い実行ボタンクリック → POST /api/fortune にリクエスト送信
  it('buildFortuneRequestがurl=/api/fortune・method=POST・Content-Typeを生成する', () => {
    const state = createInitialPageState();
    const req = buildFortuneRequest(state);

    expect(req.url).toBe('/api/fortune');
    expect(req.method).toBe('POST');
    expect(req.headers['Content-Type']).toBe('application/json');
  });

  // behavior: 占い実行ボタンクリック → POST /api/fortune にリクエスト送信
  it('buildFortuneRequestのボディに7つの次元値が含まれる', () => {
    let state = createInitialPageState();
    state = updateDimensionValue(state, 0, 10);
    state = updateDimensionValue(state, 1, 20);
    state = updateDimensionValue(state, 6, 90);

    const req = buildFortuneRequest(state);
    const body = JSON.parse(req.body) as { dimensions: number[] };

    expect(body.dimensions).toHaveLength(7);
    expect(body.dimensions[0]).toBe(10);
    expect(body.dimensions[1]).toBe(20);
    expect(body.dimensions[6]).toBe(90);
  });

  // behavior: 占い実行ボタンクリック → POST /api/fortune にリクエスト送信
  it('submitFortuneがfetchFnをPOST /api/fortuneで呼び出す', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ categories: MOCK_CATEGORIES }),
    });

    const state = createInitialPageState();
    await submitFortune(state, mockFetch as unknown as typeof fetch);

    expect(mockFetch).toHaveBeenCalledOnce();
    const [url, init] = mockFetch.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('/api/fortune');
    expect(init.method).toBe('POST');
    expect((init.headers as Record<string, string>)['Content-Type']).toBe(
      'application/json',
    );
  });

  // behavior: [追加] API呼び出し成功時にcategoriesとstatus=200が返される
  it('[追加] API呼び出し成功時に{ categories, status:200 }が返される', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ categories: MOCK_CATEGORIES }),
    });

    const state = createInitialPageState();
    const result = await submitFortune(state, mockFetch as unknown as typeof fetch);

    expect('categories' in result).toBe(true);
    if ('categories' in result) {
      expect(result.status).toBe(200);
      expect(result.categories).toHaveLength(4);
      expect(result.categories[0].name).toBe('恋愛運');
    }
  });

  // behavior: [追加] API呼び出し失敗時にerrorとstatusが返される
  it('[追加] API呼び出し失敗時に{ error, status }が返される', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 400,
      json: async () => ({ error: 'バリデーションエラー' }),
    });

    const state = createInitialPageState();
    const result = await submitFortune(state, mockFetch as unknown as typeof fetch);

    expect('error' in result).toBe(true);
    if ('error' in result) {
      expect(result.status).toBe(400);
      expect(result.error).toBe('バリデーションエラー');
    }
  });
});

// ─── APIレスポンス後 → FortuneCardで結果カード表示 ────────────────────────────

describe('FortunePage: APIレスポンス受信後 → FortuneCardで結果カード表示', () => {
  // behavior: APIレスポンス受信後 → FortuneCardコンポーネントで結果カード（カテゴリ名・プログレスバー・スコア値）が表示される
  it('buildResultCardsがカテゴリ名・スコア値・プログレスバースタイルを含むカードを生成する', () => {
    const cards = buildResultCards(MOCK_CATEGORIES);

    // 4カテゴリ分のカード
    expect(cards).toHaveLength(4);

    // カテゴリ名
    expect(cards[0].categoryName).toBe('恋愛運');
    expect(cards[1].categoryName).toBe('仕事運');
    expect(cards[2].categoryName).toBe('金運');
    expect(cards[3].categoryName).toBe('健康運');

    // スコア値
    expect(cards[0].score).toBe(75);
    expect(cards[1].score).toBe(60);
    expect(cards[2].score).toBe(50);
    expect(cards[3].score).toBe(80);

    // プログレスバースタイル（%付き文字列）
    expect(cards[0].progressBarStyle.width).toBe('75%');
    expect(cards[1].progressBarStyle.width).toBe('60%');
    expect(cards[2].progressBarStyle.width).toBe('50%');
    expect(cards[3].progressBarStyle.width).toBe('80%');
  });

  // behavior: APIレスポンス受信後 → FortuneCardコンポーネントで結果カード（カテゴリ名・プログレスバー・スコア値）が表示される
  it('setResultStateがresultCardsを設定し、isLoadingをfalseにする', () => {
    let state = createInitialPageState();
    state = setLoadingState(state);
    expect(state.isLoading).toBe(true);
    expect(state.resultCards).toBeNull();

    state = setResultState(state, MOCK_CATEGORIES);
    expect(state.isLoading).toBe(false);
    expect(state.resultCards).not.toBeNull();
    expect(state.resultCards).toHaveLength(4);
    expect(state.resultCards![0].categoryName).toBe('恋愛運');
    expect(state.resultCards![0].score).toBe(75);
    expect(state.resultCards![0].progressBarStyle.width).toBe('75%');
  });

  // behavior: APIレスポンス受信後 → FortuneCardコンポーネントで結果カード（カテゴリ名・プログレスバー・スコア値）が表示される
  it('submitFortune成功後にcategoriesからresultCardsを生成できる', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ categories: MOCK_CATEGORIES }),
    });

    let state = createInitialPageState();
    state = setLoadingState(state);

    const result = await submitFortune(state, mockFetch as unknown as typeof fetch);
    if ('categories' in result) {
      state = setResultState(state, result.categories);
    }

    // 結果カードが生成される
    expect(state.resultCards).not.toBeNull();
    expect(state.resultCards).toHaveLength(4);
    expect(state.resultCards![0].categoryName).toBe('恋愛運');
    expect(state.resultCards![0].score).toBe(75);
    expect(state.resultCards![0].progressBarStyle.width).toBe('75%');
  });

  // behavior: [追加] templateTextも結果カードに含まれる
  it('[追加] buildResultCardsがtemplateTextも含むカードを生成する', () => {
    const cards = buildResultCards(MOCK_CATEGORIES);
    expect(cards[0].templateText).toBe(
      '恋愛運は良好です。積極的に行動することで新たな出会いが期待できます。',
    );
    expect(cards[1].templateText).toBe('仕事運は普通です。着実にコツコツと取り組みましょう。');
  });

  // behavior: [追加] エッジケース: 空のcategoriesでもbuildResultCardsは空配列を返す
  it('[追加] エッジケース: categoriesが空でもbuildResultCardsは空配列を返す', () => {
    const cards = buildResultCards([]);
    expect(cards).toHaveLength(0);
    expect(Array.isArray(cards)).toBe(true);
  });
});

// ─── API通信中 → ローディング状態表示 ────────────────────────────────────────

describe('FortunePage: API通信中 → ローディング状態が表示される', () => {
  // behavior: API通信中 → ローディング状態が表示される
  it('setLoadingStateがisLoadingをtrueに設定する', () => {
    const state = createInitialPageState();
    expect(state.isLoading).toBe(false);

    const loadingState = setLoadingState(state);
    expect(loadingState.isLoading).toBe(true);
  });

  // behavior: API通信中 → ローディング状態が表示される
  it('初期状態はisLoading=false、setLoadingState後はisLoading=true（状態遷移確認）', () => {
    let state = createInitialPageState();

    // 初期状態: isLoading=false
    expect(state.isLoading).toBe(false);
    expect(state.resultCards).toBeNull();

    // ローディング開始
    state = setLoadingState(state);
    expect(state.isLoading).toBe(true);

    // dimensions には影響なし
    expect(state.dimensions).toHaveLength(7);
  });

  // behavior: [追加] API成功後にisLoading=falseになる
  it('[追加] setResultStateでisLoading=falseに戻る（APIレスポンス受信後）', () => {
    let state = createInitialPageState();
    state = setLoadingState(state);
    expect(state.isLoading).toBe(true);

    state = setResultState(state, MOCK_CATEGORIES);
    expect(state.isLoading).toBe(false);
    expect(state.resultCards).not.toBeNull();
  });

  // behavior: [追加] API失敗後もisLoading=falseになる
  it('[追加] setErrorStateでisLoading=falseになりerrorが設定される', () => {
    let state = createInitialPageState();
    state = setLoadingState(state);
    expect(state.isLoading).toBe(true);

    state = setErrorState(state, 'ネットワークエラー');
    expect(state.isLoading).toBe(false);
    expect(state.error).toBe('ネットワークエラー');
    expect(state.resultCards).toBeNull();
  });

  // behavior: [追加] エッジケース: setLoadingStateを複数回呼んでもisLoading=trueのまま（べき等）
  it('[追加] エッジケース: setLoadingStateを複数回呼んでもisLoading=trueのまま', () => {
    let state = createInitialPageState();
    state = setLoadingState(state);
    state = setLoadingState(state);
    expect(state.isLoading).toBe(true);
  });
});
