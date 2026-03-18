/**
 * ResultPage ロジック Layer 1 テスト
 *
 * 対象振る舞い:
 * - 4カテゴリ分の結果データ → タブナビゲーション+各カテゴリのFortuneCardが表示される
 * - 各カテゴリカードに重みマトリクス計算済みのweightedScoreとtotalScoreが表示される
 * - 各カテゴリカードにスコアバケットに対応するテンプレートテキストが表示される
 * - 不正入力送信時 → ユーザーフレンドリーなバリデーションエラーメッセージが表示される
 * - API通信エラー発生時 → エラー状態の表示とリトライ手段が提供される
 *
 * テストフレームワーク: vitest
 */

import { describe, it, expect } from 'vitest';
import {
  createResultPage,
  createEmptyResultPage,
  switchTab,
  toggleCategoryDisclosure,
  getActiveCard,
  buildResultFortuneCard,
  validateDimensions,
  getValidationErrorMessages,
  setValidationErrors,
  setApiError,
  retryRequest,
  canRetry,
  setResultPageLoading,
  setResultFromApi,
  type ResultCategory,
  type ResultPageState,
} from '../../components/result-page';

// ─── テスト用モックデータ ──────────────────────────────────────────────────────

/** 重みマトリクス計算済みの4カテゴリモックデータ（APIレスポンス想定） */
const MOCK_CATEGORIES: ResultCategory[] = [
  {
    id: 'love',
    name: '恋愛運',
    totalScore: 75,
    weightedScore: 75.3,
    templateText: '恋愛運が絶好調です。積極的な行動が大きな実を結ぶでしょう。',
    dimensions: Array.from({ length: 7 }, (_, i) => ({
      name: `次元${i + 1}`,
      rawScore: 70 + i,
      weightedScore: (70 + i) * 0.142,
    })),
  },
  {
    id: 'work',
    name: '仕事運',
    totalScore: 60,
    weightedScore: 60.1,
    templateText: '仕事は順調に進んでいます。コツコツと積み上げることが大切です。',
    dimensions: Array.from({ length: 7 }, (_, i) => ({
      name: `次元${i + 1}`,
      rawScore: 55 + i,
      weightedScore: (55 + i) * 0.142,
    })),
  },
  {
    id: 'money',
    name: '金運',
    totalScore: 35,
    weightedScore: 35.5,
    templateText: '金銭面では節約が必要な時期です。無駄遣いを避けて堅実に過ごしましょう。',
    dimensions: Array.from({ length: 7 }, (_, i) => ({
      name: `次元${i + 1}`,
      rawScore: 30 + i,
      weightedScore: (30 + i) * 0.142,
    })),
  },
  {
    id: 'health',
    name: '健康運',
    totalScore: 80,
    weightedScore: 80.0,
    templateText: '健康状態は非常に良好です。活力に満ちた毎日を送れるでしょう。',
    dimensions: Array.from({ length: 7 }, (_, i) => ({
      name: `次元${i + 1}`,
      rawScore: 75 + i,
      weightedScore: (75 + i) * 0.142,
    })),
  },
];

// ─── 4カテゴリ結果データ → タブナビゲーション + FortuneCard ─────────────────

describe('ResultPage: 4カテゴリ結果データ → タブナビゲーション+FortuneCard表示', () => {
  // behavior: 4カテゴリ分の結果データ → タブナビゲーション+各カテゴリのFortuneCardが表示される
  it('createResultPageがタブナビゲーション(4タブ)と4枚のFortuneCardを生成する', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    // タブナビゲーションに4つのタブが存在する
    expect(state.tabNavigation.tabs).toHaveLength(4);
    expect(state.tabNavigation.isVisible).toBe(true);

    // 4枚のFortuneCardが生成される
    expect(state.cards).toHaveLength(4);

    // カテゴリ名がタブに反映される
    const tabNames = state.tabNavigation.tabs.map((t) => t.name);
    expect(tabNames).toContain('恋愛運');
    expect(tabNames).toContain('仕事運');
    expect(tabNames).toContain('金運');
    expect(tabNames).toContain('健康運');
  });

  // behavior: 4カテゴリ分の結果データ → タブナビゲーション+各カテゴリのFortuneCardが表示される
  it('各タブのdata-testidが"tab-{categoryId}"形式で生成される', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    // 各タブに正しい dataTestId が設定される
    const tab0 = state.tabNavigation.tabs[0];
    const tab1 = state.tabNavigation.tabs[1];
    const tab2 = state.tabNavigation.tabs[2];
    const tab3 = state.tabNavigation.tabs[3];

    expect(tab0?.dataTestId).toBe('tab-love');
    expect(tab1?.dataTestId).toBe('tab-work');
    expect(tab2?.dataTestId).toBe('tab-money');
    expect(tab3?.dataTestId).toBe('tab-health');
  });

  // behavior: 4カテゴリ分の結果データ → タブナビゲーション+各カテゴリのFortuneCardが表示される
  it('初期状態で最初のカテゴリ(love)がアクティブタブとなりaria-selected=trueになる', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    // 最初のタブ(love)がアクティブ
    expect(state.activeTab).toBe('love');
    const firstTab = state.tabNavigation.tabs.find((t) => t.id === 'love');
    expect(firstTab?.ariaSelected).toBe(true);

    // 他のタブはaria-selected=false
    const otherTabs = state.tabNavigation.tabs.filter((t) => t.id !== 'love');
    otherTabs.forEach((t) => {
      expect(t.ariaSelected).toBe(false);
    });
  });

  // behavior: 4カテゴリ分の結果データ → タブナビゲーション+各カテゴリのFortuneCardが表示される
  it('switchTabでタブを切り替えるとactiveTabとariaSelectedが更新される', () => {
    let state = createResultPage(MOCK_CATEGORIES);
    expect(state.activeTab).toBe('love');

    // 'work' タブに切り替え
    state = switchTab(state, 'work');
    expect(state.activeTab).toBe('work');

    const workTab = state.tabNavigation.tabs.find((t) => t.id === 'work');
    expect(workTab?.ariaSelected).toBe(true);

    const loveTab = state.tabNavigation.tabs.find((t) => t.id === 'love');
    expect(loveTab?.ariaSelected).toBe(false);
  });

  // behavior: [追加] getActiveCardが現在のアクティブタブに対応するカードを返す
  it('[追加] getActiveCardが現在のアクティブタブ(love)に対応するResultFortuneCardを返す', () => {
    const state = createResultPage(MOCK_CATEGORIES);
    const activeCard = getActiveCard(state);

    expect(activeCard).not.toBeNull();
    expect(activeCard?.id).toBe('love');
    expect(activeCard?.categoryName).toBe('恋愛運');
  });

  // behavior: [追加] タブ切替後にgetActiveCardが切り替えたカテゴリのカードを返す
  it('[追加] タブ切替後にgetActiveCardが切り替え先のカードを返す', () => {
    let state = createResultPage(MOCK_CATEGORIES);
    state = switchTab(state, 'health');

    const activeCard = getActiveCard(state);
    expect(activeCard?.id).toBe('health');
    expect(activeCard?.categoryName).toBe('健康運');
  });

  // behavior: [追加] エッジケース: カテゴリが空のときタブナビゲーションが非表示になる
  it('[追加] エッジケース: カテゴリが空のとき、isVisible=falseかつhasResult=false', () => {
    const state = createEmptyResultPage();

    expect(state.tabNavigation.isVisible).toBe(false);
    expect(state.tabNavigation.tabs).toHaveLength(0);
    expect(state.cards).toHaveLength(0);
    expect(state.hasResult).toBe(false);
  });

  // behavior: [追加] createResultPageのhasResultが4カテゴリで true
  it('[追加] 4カテゴリで createResultPage すると hasResult=true になる', () => {
    const state = createResultPage(MOCK_CATEGORIES);
    expect(state.hasResult).toBe(true);
  });
});

// ─── 重みマトリクス計算済みのweightedScore + totalScore表示 ────────────────

describe('ResultPage: 各カテゴリカードにweightedScore+totalScoreが表示される', () => {
  // behavior: 各カテゴリカードに重みマトリクス計算済みのweightedScoreとtotalScoreが表示される
  it('buildResultFortuneCardがweightedScoreとtotalScoreを含むカードを生成する', () => {
    const card = buildResultFortuneCard(MOCK_CATEGORIES[0]!);

    // weightedScore (精度値) が含まれる
    expect(card.weightedScore).toBe(75.3);
    // totalScore (最終スコア) が含まれる
    expect(card.totalScore).toBe(75);
    // 両フィールドが数値型
    expect(typeof card.weightedScore).toBe('number');
    expect(typeof card.totalScore).toBe('number');
  });

  // behavior: 各カテゴリカードに重みマトリクス計算済みのweightedScoreとtotalScoreが表示される
  it('createResultPageの全4枚のカードにweightedScoreとtotalScoreが設定される', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    // love カテゴリカード
    const loveCard = state.cards.find((c) => c.id === 'love');
    expect(loveCard?.totalScore).toBe(75);
    expect(loveCard?.weightedScore).toBe(75.3);

    // work カテゴリカード
    const workCard = state.cards.find((c) => c.id === 'work');
    expect(workCard?.totalScore).toBe(60);
    expect(workCard?.weightedScore).toBe(60.1);

    // money カテゴリカード
    const moneyCard = state.cards.find((c) => c.id === 'money');
    expect(moneyCard?.totalScore).toBe(35);
    expect(moneyCard?.weightedScore).toBe(35.5);

    // health カテゴリカード
    const healthCard = state.cards.find((c) => c.id === 'health');
    expect(healthCard?.totalScore).toBe(80);
    expect(healthCard?.weightedScore).toBe(80.0);
  });

  // behavior: 各カテゴリカードに重みマトリクス計算済みのweightedScoreとtotalScoreが表示される
  it('totalScoreからプログレスバースタイル(width%)が正しく計算される', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    const loveCard = state.cards.find((c) => c.id === 'love');
    expect(loveCard?.progressBarStyle.width).toBe('75%');

    const moneyCard = state.cards.find((c) => c.id === 'money');
    expect(moneyCard?.progressBarStyle.width).toBe('35%');

    const healthCard = state.cards.find((c) => c.id === 'health');
    expect(healthCard?.progressBarStyle.width).toBe('80%');
  });

  // behavior: 各カテゴリカードに重みマトリクス計算済みのweightedScoreとtotalScoreが表示される
  it('scoreフィールドがtotalScoreと一致する', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    state.cards.forEach((card) => {
      // score = totalScore（プログレスバー計算用）
      expect(card.score).toBe(card.totalScore);
    });
  });

  // behavior: [追加] カテゴリIDがカードに設定される
  it('[追加] buildResultFortuneCardのidフィールドがResultCategoryのidと一致する', () => {
    const loveCard = buildResultFortuneCard(MOCK_CATEGORIES[0]!);
    expect(loveCard.id).toBe('love');

    const workCard = buildResultFortuneCard(MOCK_CATEGORIES[1]!);
    expect(workCard.id).toBe('work');

    const moneyCard = buildResultFortuneCard(MOCK_CATEGORIES[2]!);
    expect(moneyCard.id).toBe('money');

    const healthCard = buildResultFortuneCard(MOCK_CATEGORIES[3]!);
    expect(healthCard.id).toBe('health');
  });

  // behavior: [追加] エッジケース: totalScore=0のカードのprogressBarStyleが'0%'
  it('[追加] エッジケース: totalScore=0のカードのprogressBarStyle.widthが"0%"', () => {
    const zeroCategory: ResultCategory = {
      id: 'test',
      name: 'テスト運',
      totalScore: 0,
      weightedScore: 0,
      templateText: 'テンプレートテキスト',
      dimensions: Array.from({ length: 7 }, (_, i) => ({ rawScore: i })),
    };

    const card = buildResultFortuneCard(zeroCategory);
    expect(card.progressBarStyle.width).toBe('0%');
    expect(card.totalScore).toBe(0);
    expect(card.weightedScore).toBe(0);
  });
});

// ─── スコアバケットに対応するテンプレートテキスト表示 ──────────────────────

describe('ResultPage: 各カテゴリカードにスコアバケット対応テンプレートテキストが表示される', () => {
  // behavior: 各カテゴリカードにスコアバケットに対応するテンプレートテキストが表示される
  it('buildResultFortuneCardのtemplateTextがResultCategoryのtemplateTextと一致する', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    // love: 高スコア(75) → high バケットのテンプレートテキスト
    const loveCard = state.cards.find((c) => c.id === 'love');
    expect(loveCard?.templateText).toBe(
      '恋愛運が絶好調です。積極的な行動が大きな実を結ぶでしょう。',
    );

    // work: 中スコア(60) → medium バケットのテンプレートテキスト
    const workCard = state.cards.find((c) => c.id === 'work');
    expect(workCard?.templateText).toBe(
      '仕事は順調に進んでいます。コツコツと積み上げることが大切です。',
    );

    // money: 低スコア(35) → low バケットのテンプレートテキスト
    const moneyCard = state.cards.find((c) => c.id === 'money');
    expect(moneyCard?.templateText).toBe(
      '金銭面では節約が必要な時期です。無駄遣いを避けて堅実に過ごしましょう。',
    );

    // health: 高スコア(80) → high バケットのテンプレートテキスト
    const healthCard = state.cards.find((c) => c.id === 'health');
    expect(healthCard?.templateText).toBe(
      '健康状態は非常に良好です。活力に満ちた毎日を送れるでしょう。',
    );
  });

  // behavior: 各カテゴリカードにスコアバケットに対応するテンプレートテキストが表示される
  it('全4カテゴリカードにtemplateTextが設定されている（空文字列でない）', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    state.cards.forEach((card) => {
      expect(card.templateText).toBeTruthy();
      expect(typeof card.templateText).toBe('string');
      expect(card.templateText.length).toBeGreaterThan(0);
    });
  });

  // behavior: 各カテゴリカードにスコアバケットに対応するテンプレートテキストが表示される
  it('setResultFromApiでAPIレスポンスからカードが生成され、各カードにtemplateTextが含まれる', () => {
    const emptyState = createEmptyResultPage();
    const resultState = setResultFromApi(emptyState, MOCK_CATEGORIES);

    expect(resultState.hasResult).toBe(true);
    expect(resultState.cards).toHaveLength(4);

    resultState.cards.forEach((card) => {
      expect(card.templateText.length).toBeGreaterThan(0);
    });
  });

  // behavior: [追加] カテゴリ名とtemplateTextの関係が正しく維持される
  it('[追加] categoryNameとtemplateTextが同じResultCategoryから生成される（整合性確認）', () => {
    MOCK_CATEGORIES.forEach((category) => {
      const card = buildResultFortuneCard(category);
      expect(card.categoryName).toBe(category.name);
      expect(card.templateText).toBe(category.templateText);
    });
  });
});

// ─── バリデーションエラー表示 ────────────────────────────────────────────────

describe('ResultPage: 不正入力送信時 → バリデーションエラーメッセージ表示', () => {
  // behavior: 不正入力送信時 → ユーザーフレンドリーなバリデーションエラーメッセージが表示される
  it('validateDimensionsが正常入力（7個・0-100整数）でエラーなしを返す', () => {
    const validDimensions = [50, 60, 70, 30, 20, 80, 90];
    const errors = validateDimensions(validDimensions);
    expect(errors).toHaveLength(0);
  });

  // behavior: 不正入力送信時 → ユーザーフレンドリーなバリデーションエラーメッセージが表示される
  it('7個未満の次元でDIMENSION_COUNT_MISMATCHエラーとユーザーフレンドリーメッセージが返される', () => {
    const dimensions = [50, 60, 70]; // 3個
    const errors = validateDimensions(dimensions);

    expect(errors).toHaveLength(1);
    expect(errors[0]?.code).toBe('DIMENSION_COUNT_MISMATCH');
    // ユーザーフレンドリーな日本語メッセージ
    expect(errors[0]?.message).toContain('7つの次元');
    expect(errors[0]?.message).toContain('3');
  });

  // behavior: 不正入力送信時 → ユーザーフレンドリーなバリデーションエラーメッセージが表示される
  it('0-100範囲外の値でDIMENSION_OUT_OF_RANGEエラーとユーザーフレンドリーメッセージが返される', () => {
    const dimensions = [50, 150, 70, 30, 20, 80, 90]; // 次元2が150（範囲外）
    const errors = validateDimensions(dimensions);

    expect(errors.length).toBeGreaterThanOrEqual(1);

    const outOfRangeError = errors.find((e) => e.code === 'DIMENSION_OUT_OF_RANGE');
    expect(outOfRangeError).toBeDefined();
    expect(outOfRangeError?.message).toContain('0〜100');
    expect(outOfRangeError?.dimensionIndex).toBe(1);
  });

  // behavior: 不正入力送信時 → ユーザーフレンドリーなバリデーションエラーメッセージが表示される
  it('小数値でDIMENSION_NOT_INTEGERエラーとユーザーフレンドリーメッセージが返される', () => {
    const dimensions = [50, 60.5, 70, 30, 20, 80, 90]; // 次元2が小数
    const errors = validateDimensions(dimensions);

    const integerError = errors.find((e) => e.code === 'DIMENSION_NOT_INTEGER');
    expect(integerError).toBeDefined();
    expect(integerError?.message).toContain('整数');
    expect(integerError?.dimensionIndex).toBe(1);
  });

  // behavior: 不正入力送信時 → ユーザーフレンドリーなバリデーションエラーメッセージが表示される
  it('getValidationErrorMessagesがユーザーフレンドリーなメッセージ文字列配列を返す', () => {
    const dimensions = [50]; // 7個未満
    const errors = validateDimensions(dimensions);
    const messages = getValidationErrorMessages(errors);

    expect(messages).toHaveLength(1);
    expect(typeof messages[0]).toBe('string');
    expect(messages[0]!.length).toBeGreaterThan(0);
  });

  // behavior: 不正入力送信時 → ユーザーフレンドリーなバリデーションエラーメッセージが表示される
  it('setValidationErrorsでページ状態にエラーが設定され、hasResultは維持される', () => {
    let state = createResultPage(MOCK_CATEGORIES);
    const errors = validateDimensions([50]); // わざとエラー発生

    state = setValidationErrors(state, errors);

    // バリデーションエラーが設定される
    expect(state.validationErrors).toHaveLength(1);
    expect(state.validationErrors[0]?.code).toBe('DIMENSION_COUNT_MISMATCH');

    // 既存の結果データは維持される
    expect(state.hasResult).toBe(true);
    expect(state.cards).toHaveLength(4);
  });

  // behavior: [追加] エッジケース: 0個の次元でエラー（カウント不一致）
  it('[追加] エッジケース: 空配列でDIMENSION_COUNT_MISMATCHエラーが返される', () => {
    const errors = validateDimensions([]);
    expect(errors).toHaveLength(1);
    expect(errors[0]?.code).toBe('DIMENSION_COUNT_MISMATCH');
    expect(errors[0]?.message).toContain('0');
  });

  // behavior: [追加] エッジケース: 8個の次元でエラー（カウント不一致）
  it('[追加] エッジケース: 8個の次元でDIMENSION_COUNT_MISMATCHエラーが返される', () => {
    const dimensions = [10, 20, 30, 40, 50, 60, 70, 80]; // 8個
    const errors = validateDimensions(dimensions);
    expect(errors).toHaveLength(1);
    expect(errors[0]?.code).toBe('DIMENSION_COUNT_MISMATCH');
  });

  // behavior: [追加] エッジケース: 負の値でDIMENSION_OUT_OF_RANGEエラー
  it('[追加] エッジケース: 負の値でDIMENSION_OUT_OF_RANGEエラーが返される', () => {
    const dimensions = [-1, 20, 30, 40, 50, 60, 70];
    const errors = validateDimensions(dimensions);

    const outOfRangeError = errors.find((e) => e.code === 'DIMENSION_OUT_OF_RANGE');
    expect(outOfRangeError).toBeDefined();
    expect(outOfRangeError?.dimensionIndex).toBe(0);
    expect(outOfRangeError?.message).toContain('0〜100');
  });

  // behavior: [追加] 複数の次元で同時にエラーが返される
  it('[追加] 複数次元が同時に範囲外のとき、複数のエラーが返される', () => {
    const dimensions = [150, -10, 70, 30, 20, 80, 90]; // 次元0と次元1が不正
    const errors = validateDimensions(dimensions);

    expect(errors.length).toBeGreaterThanOrEqual(2);
    const codes = errors.map((e) => e.code);
    // 少なくとも 2 件の DIMENSION_OUT_OF_RANGE エラーが含まれる
    const outOfRangeCount = codes.filter((c) => c === 'DIMENSION_OUT_OF_RANGE').length;
    expect(outOfRangeCount).toBeGreaterThanOrEqual(2);
  });
});

// ─── API通信エラー → エラー状態表示 + リトライ手段 ─────────────────────────

describe('ResultPage: API通信エラー発生時 → エラー状態の表示とリトライ手段が提供される', () => {
  // behavior: API通信エラー発生時 → エラー状態の表示とリトライ手段が提供される
  it('setApiErrorでapiErrorが設定され、isLoading=falseになる', () => {
    let state = createResultPage(MOCK_CATEGORIES);
    state = setResultPageLoading(state);
    expect(state.isLoading).toBe(true);

    // APIエラー発生
    state = setApiError(state, 'ネットワークエラーが発生しました。接続を確認してください。');

    expect(state.apiError).toBe('ネットワークエラーが発生しました。接続を確認してください。');
    expect(state.isLoading).toBe(false);
  });

  // behavior: API通信エラー発生時 → エラー状態の表示とリトライ手段が提供される
  it('canRetryがapiError設定後かつisLoading=falseのときtrueを返す', () => {
    let state = createEmptyResultPage();
    state = setApiError(state, 'サーバーエラーが発生しました');

    // エラー状態でリトライ可能
    expect(canRetry(state)).toBe(true);
  });

  // behavior: API通信エラー発生時 → エラー状態の表示とリトライ手段が提供される
  it('retryRequestでapiErrorがクリアされ、isLoading=trueになる（リトライ手段）', () => {
    let state = createEmptyResultPage();
    state = setApiError(state, 'タイムアウトエラー');

    // リトライ実行
    state = retryRequest(state);

    expect(state.apiError).toBeNull();
    expect(state.isLoading).toBe(true);
    // canRetry は isLoading=true なので false
    expect(canRetry(state)).toBe(false);
  });

  // behavior: API通信エラー発生時 → エラー状態の表示とリトライ手段が提供される
  it('setResultPageLoadingでisLoading=true・apiError=nullになる', () => {
    let state = createEmptyResultPage();
    state = setApiError(state, '前回のエラー');
    expect(state.apiError).toBe('前回のエラー');

    // ローディング開始（新しいリクエスト）
    state = setResultPageLoading(state);

    expect(state.isLoading).toBe(true);
    expect(state.apiError).toBeNull();
  });

  // behavior: API通信エラー発生時 → エラー状態の表示とリトライ手段が提供される
  it('APIエラー後にretryRequestしてAPIが成功するとhasResult=trueになる', () => {
    let state = createEmptyResultPage();

    // API失敗
    state = setApiError(state, '500 Internal Server Error');
    expect(state.apiError).toBe('500 Internal Server Error');
    expect(state.hasResult).toBe(false);

    // リトライ開始
    state = retryRequest(state);
    expect(state.isLoading).toBe(true);

    // リトライ成功 → 結果設定
    state = setResultFromApi(state, MOCK_CATEGORIES);
    expect(state.hasResult).toBe(true);
    expect(state.apiError).toBeNull();
    expect(state.isLoading).toBe(false);
    expect(state.cards).toHaveLength(4);
  });

  // behavior: [追加] canRetryがisLoading=trueのときfalseを返す（リトライ中はボタン無効）
  it('[追加] canRetryがisLoading=trueのときfalseを返す（二重リトライ防止）', () => {
    let state = createEmptyResultPage();
    state = setApiError(state, 'エラー');
    state = retryRequest(state); // isLoading=true に

    expect(canRetry(state)).toBe(false);
  });

  // behavior: [追加] 初期状態ではcanRetry=false
  it('[追加] 初期状態（エラーなし）ではcanRetry=false', () => {
    const state = createEmptyResultPage();
    expect(canRetry(state)).toBe(false);
  });

  // behavior: [追加] エッジケース: APIエラーに空文字列を渡してもapiErrorが設定される
  it('[追加] エッジケース: 空文字列のAPIエラーでもapiErrorフィールドが設定される', () => {
    let state = createEmptyResultPage();
    state = setApiError(state, '');

    expect(state.apiError).toBe('');
    // 空文字列は null でないのでエラー状態
    expect(state.apiError).not.toBeNull();
  });

  // behavior: [追加] setResultPageLoadingでvalidationErrorsもクリアされる
  it('[追加] setResultPageLoadingでvalidationErrorsもクリアされる', () => {
    let state = createEmptyResultPage();
    const errors = validateDimensions([10]); // バリデーションエラー生成
    state = setValidationErrors(state, errors);
    expect(state.validationErrors.length).toBeGreaterThan(0);

    // ローディング開始でバリデーションエラーもクリア
    state = setResultPageLoading(state);
    expect(state.validationErrors).toHaveLength(0);
  });
});

// ─── 段階的開示 ──────────────────────────────────────────────────────────────

describe('ResultPage: 段階的開示の状態管理', () => {
  // behavior: [追加] 初期状態では全カテゴリの詳細が閉じた状態
  it('[追加] 初期状態では全カテゴリのisExpanded=false（閉じた状態）', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    state.disclosure.items.forEach((item) => {
      expect(item.isExpanded).toBe(false);
      expect(item.ariaExpanded).toBe('false');
    });
  });

  // behavior: [追加] toggleCategoryDisclosureでカテゴリを展開できる
  it('[追加] toggleCategoryDisclosureで指定カテゴリの詳細が開く', () => {
    let state = createResultPage(MOCK_CATEGORIES);
    state = toggleCategoryDisclosure(state, 'love');

    const loveItem = state.disclosure.items.find((i) => i.categoryId === 'love');
    expect(loveItem?.isExpanded).toBe(true);
    expect(loveItem?.ariaExpanded).toBe('true');

    // 他のカテゴリは閉じたまま
    const workItem = state.disclosure.items.find((i) => i.categoryId === 'work');
    expect(workItem?.isExpanded).toBe(false);
  });

  // behavior: [追加] 段階的開示のdetailTestIdが正しい形式
  it('[追加] detailTestIdが"fortune-detail-{categoryId}"形式で生成される', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    const loveItem = state.disclosure.items.find((i) => i.categoryId === 'love');
    expect(loveItem?.detailTestId).toBe('fortune-detail-love');

    const healthItem = state.disclosure.items.find((i) => i.categoryId === 'health');
    expect(healthItem?.detailTestId).toBe('fortune-detail-health');
  });
});

// ─── ページ状態の全体的な整合性テスト ──────────────────────────────────────

describe('ResultPage: 全体整合性テスト', () => {
  // behavior: [追加] createResultPageのカテゴリ数・タブ数・カード数・開示アイテム数が一致
  it('[追加] タブ数・カード数・開示アイテム数がすべてカテゴリ数と一致する（4件）', () => {
    const state = createResultPage(MOCK_CATEGORIES);

    expect(state.categories).toHaveLength(4);
    expect(state.tabNavigation.tabs).toHaveLength(4);
    expect(state.cards).toHaveLength(4);
    expect(state.disclosure.items).toHaveLength(4);
  });

  // behavior: [追加] setResultFromApiが既存のページ状態を新しい結果で上書きする
  it('[追加] setResultFromApiが新しいカテゴリデータでページ状態を完全に再構築する', () => {
    // 初期状態 → エラー発生 → リトライ → 成功
    let state = createEmptyResultPage();
    state = setApiError(state, '503 Service Unavailable');
    state = retryRequest(state);
    state = setResultFromApi(state, MOCK_CATEGORIES);

    expect(state.hasResult).toBe(true);
    expect(state.apiError).toBeNull();
    expect(state.isLoading).toBe(false);
    expect(state.validationErrors).toHaveLength(0);
    expect(state.categories).toHaveLength(4);
    expect(state.cards).toHaveLength(4);
  });

  // behavior: [追加] エッジケース: switchTabに存在しないIDを渡しても状態が壊れない
  it('[追加] エッジケース: 存在しないカテゴリIDでswitchTabしてもcards数は変わらない', () => {
    let state = createResultPage(MOCK_CATEGORIES);
    state = switchTab(state, 'nonexistent');

    expect(state.activeTab).toBe('nonexistent');
    expect(state.cards).toHaveLength(4); // カード数は変わらない

    // 存在しないIDのカードは取得できない
    const activeCard = getActiveCard(state);
    expect(activeCard).toBeNull();
  });

  // behavior: [追加] ResultPageStateはイミュータブル更新（元の状態が変わらない）
  it('[追加] switchTab後も元のstateは変更されない（イミュータブル更新）', () => {
    const originalState = createResultPage(MOCK_CATEGORIES);
    const originalActiveTab = originalState.activeTab;

    // 切り替え後の新しい状態
    const newState = switchTab(originalState, 'work');

    // 元の状態は変わらない
    expect(originalState.activeTab).toBe(originalActiveTab);
    expect(newState.activeTab).toBe('work');
    expect(originalState).not.toBe(newState);
  });

  // behavior: [追加] setApiErrorは既存のカード結果を消去しない
  it('[追加] setApiError後も既存の結果カードは維持される', () => {
    let state = createResultPage(MOCK_CATEGORIES);
    expect(state.cards).toHaveLength(4);

    // エラー状態にしても既存のカードは消えない
    state = setApiError(state, 'エラー発生');
    expect(state.cards).toHaveLength(4);
    expect(state.hasResult).toBe(true);
  });
});

// 型の健全性チェック（コンパイル時型推論の確認）
// これらのテストはコンパイルが通れば成功
describe('ResultPage: 型安全性確認', () => {
  it('ResultPageStateのすべてのフィールドが正しい型を持つ', () => {
    const state: ResultPageState = createResultPage(MOCK_CATEGORIES);

    // 各フィールドの型チェック
    expect(typeof state.activeTab).toBe('string');
    expect(Array.isArray(state.categories)).toBe(true);
    expect(Array.isArray(state.cards)).toBe(true);
    expect(Array.isArray(state.validationErrors)).toBe(true);
    expect(state.apiError === null || typeof state.apiError === 'string').toBe(true);
    expect(typeof state.isLoading).toBe('boolean');
    expect(typeof state.hasResult).toBe('boolean');
  });
});
