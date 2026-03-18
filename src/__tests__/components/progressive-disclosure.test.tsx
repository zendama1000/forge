/**
 * ProgressiveDisclosure コンポーネントロジック Layer 1 テスト
 *
 * - createDisclosureItem() の初期状態を検証
 * - toggleDisclosureItem() の開閉トグルを検証
 * - createProgressiveDisclosure() の複数カテゴリ管理を検証
 * - toggleCategory() の独立開閉状態を検証
 * - 全 required_behaviors をカバー
 *
 * vitest + node 環境（DOM レンダリングなし）
 */

import { describe, it, expect } from 'vitest';
import {
  createDisclosureItem,
  createProgressiveDisclosure,
  toggleDisclosureItem,
  toggleCategory,
} from '../../components/progressive-disclosure';
import type { DisclosureCategory } from '../../components/progressive-disclosure';

// ─── テスト用フィクスチャ ──────────────────────────────────────────────────────

const CATEGORY_WITH_DIMENSIONS: DisclosureCategory = {
  id: 'love',
  name: '恋愛運',
  totalScore: 75,
  templateText: '恋愛運は良好です。',
  dimensions: [
    { name: '直感力', rawScore: 80 },
    { name: '感受性', rawScore: 70 },
    { name: '行動力', rawScore: 65 },
  ],
};

const CATEGORY_EMPTY_DIMENSIONS: DisclosureCategory = {
  id: 'work',
  name: '仕事運',
  totalScore: 60,
  dimensions: [],
};

const CATEGORY_NO_DIMENSIONS: DisclosureCategory = {
  id: 'money',
  name: '金運',
  totalScore: 50,
  // dimensions プロパティ自体が未定義
};

const FOUR_CATEGORIES: DisclosureCategory[] = [
  {
    id: 'love',
    name: '恋愛運',
    dimensions: [{ rawScore: 75 }, { rawScore: 70 }],
  },
  {
    id: 'work',
    name: '仕事運',
    dimensions: [{ rawScore: 60 }, { rawScore: 55 }],
  },
  {
    id: 'money',
    name: '金運',
    dimensions: [{ rawScore: 50 }],
  },
  {
    id: 'health',
    name: '健康運',
    dimensions: [{ rawScore: 80 }],
  },
];

// ─── createDisclosureItem() ───────────────────────────────────────────────────

describe('createDisclosureItem()', () => {
  // behavior: サマリーカード初期表示 → 詳細セクション非表示、aria-expanded='false'
  it('初期状態は isExpanded=false、ariaExpanded="false" である', () => {
    const state = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);

    expect(state.isExpanded).toBe(false);
    expect(state.ariaExpanded).toBe('false');
  });

  // behavior: 展開時にdata-testid='fortune-detail-{categoryId}'要素がDOMに存在
  it('detailTestId が "fortune-detail-{categoryId}" 形式になっている', () => {
    const state = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);

    expect(state.detailTestId).toBe('fortune-detail-love');
  });

  it('categoryId が入力カテゴリの id と一致する', () => {
    const state = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);

    expect(state.categoryId).toBe('love');
  });

  // behavior: dimensions配列が空の場合 → 詳細セクションに「データなし」表示、エラーにならない
  it('dimensions が空配列の場合 → emptyMessage="データなし"、hasData=false、エラーにならない', () => {
    expect(() => createDisclosureItem(CATEGORY_EMPTY_DIMENSIONS)).not.toThrow();

    const state = createDisclosureItem(CATEGORY_EMPTY_DIMENSIONS);

    expect(state.hasData).toBe(false);
    expect(state.emptyMessage).toBe('データなし');
  });

  it('dimensions が未定義の場合 → emptyMessage="データなし"、hasData=false、エラーにならない', () => {
    expect(() => createDisclosureItem(CATEGORY_NO_DIMENSIONS)).not.toThrow();

    const state = createDisclosureItem(CATEGORY_NO_DIMENSIONS);

    expect(state.hasData).toBe(false);
    expect(state.emptyMessage).toBe('データなし');
  });

  it('dimensions がある場合 → hasData=true、emptyMessage=null', () => {
    const state = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);

    expect(state.hasData).toBe(true);
    expect(state.emptyMessage).toBeNull();
  });
});

// ─── toggleDisclosureItem() ───────────────────────────────────────────────────

describe('toggleDisclosureItem()', () => {
  // behavior: サマリーカードクリック → 詳細セクション表示、aria-expanded='true'
  it('閉じた状態でトグル → isExpanded=true、ariaExpanded="true"', () => {
    const initial = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);
    const toggled = toggleDisclosureItem(initial);

    expect(toggled.isExpanded).toBe(true);
    expect(toggled.ariaExpanded).toBe('true');
  });

  // behavior: 展開済みカード再クリック → 詳細セクション非表示に戻る、aria-expanded='false'
  it('展開済み状態で再トグル → isExpanded=false、ariaExpanded="false" に戻る', () => {
    const initial = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);
    const expanded = toggleDisclosureItem(initial);
    const collapsed = toggleDisclosureItem(expanded);

    expect(collapsed.isExpanded).toBe(false);
    expect(collapsed.ariaExpanded).toBe('false');
  });

  // behavior: 展開時にdata-testid='fortune-detail-{categoryId}'要素がDOMに存在
  it('展開後も detailTestId は変わらない（fortune-detail-love）', () => {
    const initial = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);
    const expanded = toggleDisclosureItem(initial);

    expect(expanded.detailTestId).toBe('fortune-detail-love');
  });

  it('トグルは元の state を変更しない（不変更新）', () => {
    const initial = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);
    toggleDisclosureItem(initial);

    // 元の state は変更されていない
    expect(initial.isExpanded).toBe(false);
    expect(initial.ariaExpanded).toBe('false');
  });

  it('3回トグルすると展開状態 → 閉じ → 展開 のサイクルになる', () => {
    let state = createDisclosureItem(CATEGORY_WITH_DIMENSIONS);

    state = toggleDisclosureItem(state); // 1回目: 展開
    expect(state.isExpanded).toBe(true);

    state = toggleDisclosureItem(state); // 2回目: 閉じ
    expect(state.isExpanded).toBe(false);

    state = toggleDisclosureItem(state); // 3回目: 展開
    expect(state.isExpanded).toBe(true);
  });
});

// ─── createProgressiveDisclosure() ───────────────────────────────────────────

describe('createProgressiveDisclosure()', () => {
  it('4カテゴリを渡すと items.length が 4 になる', () => {
    const state = createProgressiveDisclosure(FOUR_CATEGORIES);

    expect(state.items).toHaveLength(4);
  });

  // behavior: サマリーカード初期表示 → 詳細セクション非表示、aria-expanded='false'
  it('全アイテムが初期状態で isExpanded=false、ariaExpanded="false" である', () => {
    const state = createProgressiveDisclosure(FOUR_CATEGORIES);

    state.items.forEach((item) => {
      expect(item.isExpanded).toBe(false);
      expect(item.ariaExpanded).toBe('false');
    });
  });

  it('空配列を渡すとエラーにならず items=[] を返す', () => {
    expect(() => createProgressiveDisclosure([])).not.toThrow();

    const state = createProgressiveDisclosure([]);
    expect(state.items).toHaveLength(0);
  });

  it('各アイテムの detailTestId が "fortune-detail-{categoryId}" 形式になっている', () => {
    const state = createProgressiveDisclosure(FOUR_CATEGORIES);

    expect(state.items[0].detailTestId).toBe('fortune-detail-love');
    expect(state.items[1].detailTestId).toBe('fortune-detail-work');
    expect(state.items[2].detailTestId).toBe('fortune-detail-money');
    expect(state.items[3].detailTestId).toBe('fortune-detail-health');
  });
});

// ─── toggleCategory() ────────────────────────────────────────────────────────

describe('toggleCategory()', () => {
  // behavior: サマリーカードクリック → 詳細セクション表示、aria-expanded='true'
  it('"love" をトグルすると love アイテムが isExpanded=true になる', () => {
    const initial = createProgressiveDisclosure(FOUR_CATEGORIES);
    const next = toggleCategory(initial, 'love');

    const loveItem = next.items.find((i) => i.categoryId === 'love');
    expect(loveItem?.isExpanded).toBe(true);
    expect(loveItem?.ariaExpanded).toBe('true');
  });

  // behavior: 複数カテゴリの開閉状態が互いに独立（カテゴリA展開中にカテゴリB展開→両方展開状態）
  it('カテゴリA展開中にカテゴリBをトグル → 両方が展開状態になる', () => {
    let state = createProgressiveDisclosure(FOUR_CATEGORIES);

    // love を展開
    state = toggleCategory(state, 'love');
    // work を展開
    state = toggleCategory(state, 'work');

    const loveItem = state.items.find((i) => i.categoryId === 'love');
    const workItem = state.items.find((i) => i.categoryId === 'work');
    const moneyItem = state.items.find((i) => i.categoryId === 'money');
    const healthItem = state.items.find((i) => i.categoryId === 'health');

    // love と work が両方展開されている
    expect(loveItem?.isExpanded).toBe(true);
    expect(loveItem?.ariaExpanded).toBe('true');
    expect(workItem?.isExpanded).toBe(true);
    expect(workItem?.ariaExpanded).toBe('true');

    // money と health は影響を受けていない
    expect(moneyItem?.isExpanded).toBe(false);
    expect(moneyItem?.ariaExpanded).toBe('false');
    expect(healthItem?.isExpanded).toBe(false);
    expect(healthItem?.ariaExpanded).toBe('false');
  });

  // behavior: 展開済みカード再クリック → 詳細セクション非表示に戻る、aria-expanded='false'
  it('展開中のカテゴリを再トグル → そのカテゴリのみ閉じる（他は維持）', () => {
    let state = createProgressiveDisclosure(FOUR_CATEGORIES);

    // love と work を展開
    state = toggleCategory(state, 'love');
    state = toggleCategory(state, 'work');

    // love を閉じる
    state = toggleCategory(state, 'love');

    const loveItem = state.items.find((i) => i.categoryId === 'love');
    const workItem = state.items.find((i) => i.categoryId === 'work');

    expect(loveItem?.isExpanded).toBe(false);
    expect(loveItem?.ariaExpanded).toBe('false');
    // work は展開状態を維持
    expect(workItem?.isExpanded).toBe(true);
    expect(workItem?.ariaExpanded).toBe('true');
  });

  it('全カテゴリを順番にトグルすると全て展開状態になる', () => {
    let state = createProgressiveDisclosure(FOUR_CATEGORIES);

    state = toggleCategory(state, 'love');
    state = toggleCategory(state, 'work');
    state = toggleCategory(state, 'money');
    state = toggleCategory(state, 'health');

    state.items.forEach((item) => {
      expect(item.isExpanded).toBe(true);
      expect(item.ariaExpanded).toBe('true');
    });
  });

  it('トグルは元の state を変更しない（不変更新）', () => {
    const initial = createProgressiveDisclosure(FOUR_CATEGORIES);
    toggleCategory(initial, 'love');

    // 元の state は変更されていない
    const loveItem = initial.items.find((i) => i.categoryId === 'love');
    expect(loveItem?.isExpanded).toBe(false);
  });

  it('存在しないカテゴリIDを指定してもエラーにならず state が変わらない', () => {
    const initial = createProgressiveDisclosure(FOUR_CATEGORIES);

    expect(() => toggleCategory(initial, 'nonexistent')).not.toThrow();

    const next = toggleCategory(initial, 'nonexistent');
    next.items.forEach((item) => {
      expect(item.isExpanded).toBe(false);
    });
  });
});

// ─── 統合シナリオ ─────────────────────────────────────────────────────────────

describe('統合シナリオ', () => {
  // behavior: dimensions配列が空の場合 → 詳細セクションに「データなし」表示、エラーにならない
  it('dimensions が空のカテゴリを含む複数カテゴリでも正常に動作する', () => {
    const categories: DisclosureCategory[] = [
      { id: 'a', dimensions: [{ rawScore: 50 }] },
      { id: 'b', dimensions: [] },
      { id: 'c' }, // dimensions 未定義
    ];

    expect(() => createProgressiveDisclosure(categories)).not.toThrow();

    const state = createProgressiveDisclosure(categories);

    // a はデータあり
    expect(state.items[0].hasData).toBe(true);
    expect(state.items[0].emptyMessage).toBeNull();

    // b と c はデータなし
    expect(state.items[1].hasData).toBe(false);
    expect(state.items[1].emptyMessage).toBe('データなし');
    expect(state.items[2].hasData).toBe(false);
    expect(state.items[2].emptyMessage).toBe('データなし');
  });

  // behavior: 展開時にdata-testid='fortune-detail-{categoryId}'要素がDOMに存在
  it('展開前後で detailTestId が変わらず fortune-detail-{id} 形式を維持する', () => {
    const category: DisclosureCategory = {
      id: 'health',
      dimensions: [{ rawScore: 80 }],
    };
    const initial = createDisclosureItem(category);

    expect(initial.detailTestId).toBe('fortune-detail-health');

    const expanded = toggleDisclosureItem(initial);
    expect(expanded.detailTestId).toBe('fortune-detail-health');

    const collapsed = toggleDisclosureItem(expanded);
    expect(collapsed.detailTestId).toBe('fortune-detail-health');
  });
});
