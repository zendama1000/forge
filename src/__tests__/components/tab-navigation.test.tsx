/**
 * TabNavigation コンポーネントロジック Layer 1 テスト
 *
 * - createTabNavigation() の全 required_behaviors をカバー
 * - vitest + node 環境（DOM レンダリングなし）
 * - aria属性・data-testid・onChangeコールバックをデータレベルで検証
 */

import { describe, it, expect, vi } from 'vitest';
import { createTabNavigation } from '../../components/tab-navigation';
import type { TabNavigationCategory } from '../../components/tab-navigation';

// ─── テスト用フィクスチャ ──────────────────────────────────────────────────────

const FOUR_CATEGORIES: TabNavigationCategory[] = [
  { id: 'love', name: '恋愛運' },
  { id: 'work', name: '仕事運' },
  { id: 'money', name: '金運' },
  { id: 'health', name: '健康運' },
];

// ─── createTabNavigation() ────────────────────────────────────────────────────

describe('TabNavigation: createTabNavigation()', () => {
  // behavior: 4カテゴリデータを渡す → 4つのタブボタンがレンダリング
  it('4カテゴリを渡すと tabs.length が 4 になる', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'love',
      onChange,
    });

    expect(state.tabs).toHaveLength(4);
    expect(state.isVisible).toBe(true);
  });

  // behavior: タブクリック → onChangeコールバックがクリックされたカテゴリIDで発火
  it('タブの onClick() を呼び出すと onChange が対応する categoryId で発火する', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'love',
      onChange,
    });

    // 'work' タブ（index 1）の onClick を呼ぶ
    state.tabs[1].onClick();
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith('work');
  });

  it('各タブの onClick() が対応する categoryId を onChange に渡す（全タブ確認）', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'love',
      onChange,
    });

    // 各タブを順番にクリックして categoryId を検証
    const expectedIds = ['love', 'work', 'money', 'health'];
    expectedIds.forEach((expectedId, index) => {
      onChange.mockClear();
      state.tabs[index].onClick();
      expect(onChange).toHaveBeenCalledWith(expectedId);
    });
  });

  // behavior: activeTab propで指定したタブ → aria-selected='true'、他タブはaria-selected='false'
  it('activeTab="money" を指定すると money タブのみ ariaSelected=true、他は false', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'money',
      onChange,
    });

    const loveTab = state.tabs.find((t) => t.id === 'love');
    const workTab = state.tabs.find((t) => t.id === 'work');
    const moneyTab = state.tabs.find((t) => t.id === 'money');
    const healthTab = state.tabs.find((t) => t.id === 'health');

    expect(moneyTab?.ariaSelected).toBe(true);
    expect(loveTab?.ariaSelected).toBe(false);
    expect(workTab?.ariaSelected).toBe(false);
    expect(healthTab?.ariaSelected).toBe(false);
  });

  it('activeTab="health" のとき health のみ ariaSelected=true', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'health',
      onChange,
    });

    state.tabs.forEach((tab) => {
      if (tab.id === 'health') {
        expect(tab.ariaSelected).toBe(true);
      } else {
        expect(tab.ariaSelected).toBe(false);
      }
    });
  });

  // behavior: 各タブにdata-testid='tab-{categoryId}'属性が存在
  it('各タブの dataTestId が "tab-{categoryId}" 形式になっている', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'love',
      onChange,
    });

    expect(state.tabs[0].dataTestId).toBe('tab-love');
    expect(state.tabs[1].dataTestId).toBe('tab-work');
    expect(state.tabs[2].dataTestId).toBe('tab-money');
    expect(state.tabs[3].dataTestId).toBe('tab-health');
  });

  // behavior: 1カテゴリのみの場合 → 1タブ表示、レイアウト崩れなし
  it('1カテゴリのみを渡すと tabs.length=1 で isVisible=true、エラーにならない', () => {
    const onChange = vi.fn();

    expect(() =>
      createTabNavigation({
        categories: [{ id: 'love', name: '恋愛運' }],
        activeTab: 'love',
        onChange,
      })
    ).not.toThrow();

    const state = createTabNavigation({
      categories: [{ id: 'love', name: '恋愛運' }],
      activeTab: 'love',
      onChange,
    });

    expect(state.tabs).toHaveLength(1);
    expect(state.isVisible).toBe(true);
    expect(state.tabs[0].dataTestId).toBe('tab-love');
    expect(state.tabs[0].ariaSelected).toBe(true);
  });

  // behavior: 0カテゴリの場合 → タブコンポーネント非表示、エラーにならない
  it('0カテゴリ（空配列）を渡すと isVisible=false になり、エラーにならない', () => {
    const onChange = vi.fn();

    expect(() =>
      createTabNavigation({
        categories: [],
        activeTab: '',
        onChange,
      })
    ).not.toThrow();

    const state = createTabNavigation({
      categories: [],
      activeTab: '',
      onChange,
    });

    expect(state.isVisible).toBe(false);
    expect(state.tabs).toHaveLength(0);
  });

  // ─── 追加テスト: エッジケース ────────────────────────────────────────────────

  // behavior: [追加] activeTab が存在しない ID の場合、全タブが ariaSelected=false
  it('[追加] activeTab が存在しない ID のとき、全タブの ariaSelected が false', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'nonexistent',
      onChange,
    });

    state.tabs.forEach((tab) => {
      expect(tab.ariaSelected).toBe(false);
    });
  });

  // behavior: [追加] 各タブの id と name が categories の入力値と一致する
  it('[追加] tabs の id・name が categories の入力データと一致する', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'love',
      onChange,
    });

    FOUR_CATEGORIES.forEach((cat, index) => {
      expect(state.tabs[index].id).toBe(cat.id);
      expect(state.tabs[index].name).toBe(cat.name);
    });
  });

  // behavior: [追加] onChange の呼び出し回数は onClick 呼び出し回数と等しい
  it('[追加] 同じタブの onClick を複数回呼ぶと onChange も同回数呼ばれる', () => {
    const onChange = vi.fn();
    const state = createTabNavigation({
      categories: FOUR_CATEGORIES,
      activeTab: 'love',
      onChange,
    });

    state.tabs[0].onClick();
    state.tabs[0].onClick();
    state.tabs[0].onClick();

    expect(onChange).toHaveBeenCalledTimes(3);
    expect(onChange).toHaveBeenNthCalledWith(1, 'love');
    expect(onChange).toHaveBeenNthCalledWith(2, 'love');
    expect(onChange).toHaveBeenNthCalledWith(3, 'love');
  });
});
