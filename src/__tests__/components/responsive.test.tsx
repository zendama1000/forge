/**
 * Responsive design and accessibility logic Layer 1 テスト
 *
 * - detectViewport() のビューポート判定を検証
 * - getLayoutConfig() のビューポート別レイアウト設定を検証
 * - getLayoutConfigForWidth() のショートカット関数を検証
 * - ACCESSIBLE_DIMENSIONS の冗長表現（アイコン + カラー）を検証
 * - 色覚シミュレーション環境での弁別性を検証
 * - 全 required_behaviors をカバー
 *
 * vitest + node 環境（DOM レンダリングなし）
 */

import { describe, it, expect } from 'vitest';
import {
  BREAKPOINTS,
  ACCESSIBLE_DIMENSIONS,
  detectViewport,
  getLayoutConfig,
  getLayoutConfigForWidth,
  hasUniqueIcons,
  hasUniqueColors,
  hasUniqueNames,
  hasNonEmptyIcons,
  getDimensionRedundancy,
  getAllDimensionRedundancies,
  getDimensionByName,
} from '../../components/responsive';
import type { Viewport, LayoutConfig } from '../../components/responsive';

// ─── ブレークポイント定数 ─────────────────────────────────────────────────────

describe('BREAKPOINTS 定数', () => {
  it('mobile が 375 である', () => {
    expect(BREAKPOINTS.mobile).toBe(375);
  });

  it('tablet が 768 である', () => {
    expect(BREAKPOINTS.tablet).toBe(768);
  });

  it('desktop が 1280 である', () => {
    expect(BREAKPOINTS.desktop).toBe(1280);
  });
});

// ─── detectViewport() ─────────────────────────────────────────────────────────

describe('detectViewport()', () => {
  // behavior: モバイルビューポート（375px）→ カード・タブ・プログレスバーが縦積みレイアウト
  it('375px → "mobile" を返す', () => {
    expect(detectViewport(375)).toBe('mobile');
  });

  it('374px → "mobile" を返す（ブレークポイント未満）', () => {
    expect(detectViewport(374)).toBe('mobile');
  });

  it('320px → "mobile" を返す（小さい画面）', () => {
    expect(detectViewport(320)).toBe('mobile');
  });

  it('767px → "mobile" を返す（タブレット未満）', () => {
    expect(detectViewport(767)).toBe('mobile');
  });

  // behavior: タブレットビューポート（768px）→ 中間レイアウトでコンテンツ幅最適化
  it('768px → "tablet" を返す', () => {
    expect(detectViewport(768)).toBe('tablet');
  });

  it('1024px → "tablet" を返す（タブレット範囲内）', () => {
    expect(detectViewport(1024)).toBe('tablet');
  });

  it('1279px → "tablet" を返す（デスクトップ未満）', () => {
    expect(detectViewport(1279)).toBe('tablet');
  });

  // behavior: デスクトップビューポート（1280px）→ フル幅レイアウト
  it('1280px → "desktop" を返す', () => {
    expect(detectViewport(1280)).toBe('desktop');
  });

  it('1920px → "desktop" を返す（大画面）', () => {
    expect(detectViewport(1920)).toBe('desktop');
  });

  it('2560px → "desktop" を返す（4K画面）', () => {
    expect(detectViewport(2560)).toBe('desktop');
  });

  // behavior: [追加] エッジケース: 幅0はmobileとして扱う
  it('0px → "mobile" を返す（エッジケース）', () => {
    expect(detectViewport(0)).toBe('mobile');
  });
});

// ─── getLayoutConfig() ────────────────────────────────────────────────────────

describe('getLayoutConfig()', () => {
  // behavior: モバイルビューポート（375px）→ カード・タブ・プログレスバーが縦積みレイアウト
  describe('mobile レイアウト', () => {
    let config: LayoutConfig;

    // eslint-disable-next-line vitest/no-hooks
    beforeEach(() => {
      config = getLayoutConfig('mobile');
    });

    it('viewport が "mobile" である', () => {
      expect(config.viewport).toBe('mobile');
    });

    it('cardLayout が "stack"（縦積み）である', () => {
      expect(config.cardLayout).toBe('stack');
    });

    it('tabLayout が "stack"（縦積み）である', () => {
      expect(config.tabLayout).toBe('stack');
    });

    it('progressBarLayout が "stack"（縦積み）である', () => {
      expect(config.progressBarLayout).toBe('stack');
    });

    it('contentMaxWidth が "100%"（フル幅）である', () => {
      expect(config.contentMaxWidth).toBe('100%');
    });
  });

  // behavior: タブレットビューポート（768px）→ 中間レイアウトでコンテンツ幅最適化
  describe('tablet レイアウト', () => {
    let config: LayoutConfig;

    // eslint-disable-next-line vitest/no-hooks
    beforeEach(() => {
      config = getLayoutConfig('tablet');
    });

    it('viewport が "tablet" である', () => {
      expect(config.viewport).toBe('tablet');
    });

    it('cardLayout が "grid"（グリッド）である', () => {
      expect(config.cardLayout).toBe('grid');
    });

    it('tabLayout が "row"（横並び）である', () => {
      expect(config.tabLayout).toBe('row');
    });

    it('progressBarLayout が "inline" である', () => {
      expect(config.progressBarLayout).toBe('inline');
    });

    it('contentMaxWidth が "768px" である', () => {
      expect(config.contentMaxWidth).toBe('768px');
    });
  });

  // behavior: デスクトップビューポート（1280px）→ フル幅レイアウト
  describe('desktop レイアウト', () => {
    let config: LayoutConfig;

    // eslint-disable-next-line vitest/no-hooks
    beforeEach(() => {
      config = getLayoutConfig('desktop');
    });

    it('viewport が "desktop" である', () => {
      expect(config.viewport).toBe('desktop');
    });

    it('cardLayout が "full-width"（フル幅）である', () => {
      expect(config.cardLayout).toBe('full-width');
    });

    it('tabLayout が "row"（横並び）である', () => {
      expect(config.tabLayout).toBe('row');
    });

    it('progressBarLayout が "inline" である', () => {
      expect(config.progressBarLayout).toBe('inline');
    });

    it('contentMaxWidth が "1280px" である', () => {
      expect(config.contentMaxWidth).toBe('1280px');
    });
  });
});

// ─── getLayoutConfigForWidth() ────────────────────────────────────────────────

describe('getLayoutConfigForWidth()', () => {
  // behavior: モバイルビューポート（375px）→ カード・タブ・プログレスバーが縦積みレイアウト
  it('375px → mobile レイアウト（cardLayout="stack", tabLayout="stack", progressBarLayout="stack"）', () => {
    const config = getLayoutConfigForWidth(375);
    expect(config.viewport).toBe('mobile');
    expect(config.cardLayout).toBe('stack');
    expect(config.tabLayout).toBe('stack');
    expect(config.progressBarLayout).toBe('stack');
  });

  // behavior: タブレットビューポート（768px）→ 中間レイアウトでコンテンツ幅最適化
  it('768px → tablet レイアウト（cardLayout="grid", contentMaxWidth="768px"）', () => {
    const config = getLayoutConfigForWidth(768);
    expect(config.viewport).toBe('tablet');
    expect(config.cardLayout).toBe('grid');
    expect(config.contentMaxWidth).toBe('768px');
  });

  // behavior: デスクトップビューポート（1280px）→ フル幅レイアウト
  it('1280px → desktop レイアウト（cardLayout="full-width", contentMaxWidth="1280px"）', () => {
    const config = getLayoutConfigForWidth(1280);
    expect(config.viewport).toBe('desktop');
    expect(config.cardLayout).toBe('full-width');
    expect(config.contentMaxWidth).toBe('1280px');
  });

  // behavior: [追加] 境界値: 768px 未満はモバイル
  it('767px → mobile レイアウトを返す（境界値）', () => {
    const config = getLayoutConfigForWidth(767);
    expect(config.viewport).toBe('mobile');
    expect(config.cardLayout).toBe('stack');
  });

  // behavior: [追加] 境界値: 1280px 未満はタブレット
  it('1279px → tablet レイアウトを返す（境界値）', () => {
    const config = getLayoutConfigForWidth(1279);
    expect(config.viewport).toBe('tablet');
    expect(config.cardLayout).toBe('grid');
  });
});

// ─── ACCESSIBLE_DIMENSIONS ───────────────────────────────────────────────────

describe('ACCESSIBLE_DIMENSIONS', () => {
  // behavior: 各次元のアイコンとカラーが冗長表現（色のみに依存しない）で表示される
  it('7次元が定義されている', () => {
    expect(ACCESSIBLE_DIMENSIONS).toHaveLength(7);
  });

  it('全次元に name, icon, color, ariaLabel, testId が定義されている', () => {
    for (const dim of ACCESSIBLE_DIMENSIONS) {
      expect(dim.name).toBeTruthy();
      expect(dim.icon).toBeTruthy();
      expect(dim.color).toBeTruthy();
      expect(dim.ariaLabel).toBeTruthy();
      expect(dim.testId).toBeTruthy();
    }
  });

  // behavior: 各次元のアイコンとカラーが冗長表現（色のみに依存しない）で表示される
  it('全次元に icon と color の両方が存在する（冗長表現）', () => {
    for (const dim of ACCESSIBLE_DIMENSIONS) {
      // アイコンが空でない
      expect(dim.icon.trim().length).toBeGreaterThan(0);
      // カラーが空でない
      expect(dim.color.trim().length).toBeGreaterThan(0);
    }
  });

  // behavior: 色覚シミュレーション環境で全7次元が弁別可能
  it('全7次元のアイコンが一意（重複なし）で弁別可能', () => {
    expect(hasUniqueIcons(ACCESSIBLE_DIMENSIONS)).toBe(true);
  });

  // behavior: 色覚シミュレーション環境で全7次元が弁別可能
  it('全7次元のカラーが一意（重複なし）', () => {
    expect(hasUniqueColors(ACCESSIBLE_DIMENSIONS)).toBe(true);
  });

  it('全7次元の名前が一意（重複なし）', () => {
    expect(hasUniqueNames(ACCESSIBLE_DIMENSIONS)).toBe(true);
  });

  it('全次元のアイコンが空でない（絵文字が存在する）', () => {
    expect(hasNonEmptyIcons(ACCESSIBLE_DIMENSIONS)).toBe(true);
  });

  it('7次元の名前が全て日本語で定義されている', () => {
    const names = ACCESSIBLE_DIMENSIONS.map((d) => d.name);
    expect(names).toContain('運気');
    expect(names).toContain('活力');
    expect(names).toContain('知性');
    expect(names).toContain('感情');
    expect(names).toContain('財運');
    expect(names).toContain('健康');
    expect(names).toContain('社交');
  });

  it('カラーが CSS color 形式（# で始まるか rgb/hsl 形式）である', () => {
    for (const dim of ACCESSIBLE_DIMENSIONS) {
      const isHex = /^#[0-9a-fA-F]{3,8}$/.test(dim.color);
      const isRgb = /^rgb/.test(dim.color);
      const isHsl = /^hsl/.test(dim.color);
      expect(isHex || isRgb || isHsl).toBe(true);
    }
  });
});

// ─── 弁別性バリデーション関数 ────────────────────────────────────────────────

describe('hasUniqueIcons()', () => {
  it('全アイコンが一意なら true を返す', () => {
    const dims = [
      { name: 'A', icon: '⭐', color: '#111', ariaLabel: 'A', testId: 'a' },
      { name: 'B', icon: '⚡', color: '#222', ariaLabel: 'B', testId: 'b' },
    ];
    expect(hasUniqueIcons(dims)).toBe(true);
  });

  it('アイコンが重複する場合 false を返す', () => {
    const dims = [
      { name: 'A', icon: '⭐', color: '#111', ariaLabel: 'A', testId: 'a' },
      { name: 'B', icon: '⭐', color: '#222', ariaLabel: 'B', testId: 'b' }, // 重複
    ];
    expect(hasUniqueIcons(dims)).toBe(false);
  });

  it('空配列は true を返す', () => {
    expect(hasUniqueIcons([])).toBe(true);
  });
});

describe('hasUniqueColors()', () => {
  it('全カラーが一意なら true を返す', () => {
    const dims = [
      { name: 'A', icon: '⭐', color: '#111', ariaLabel: 'A', testId: 'a' },
      { name: 'B', icon: '⚡', color: '#222', ariaLabel: 'B', testId: 'b' },
    ];
    expect(hasUniqueColors(dims)).toBe(true);
  });

  it('カラーが重複する場合 false を返す', () => {
    const dims = [
      { name: 'A', icon: '⭐', color: '#111', ariaLabel: 'A', testId: 'a' },
      { name: 'B', icon: '⚡', color: '#111', ariaLabel: 'B', testId: 'b' }, // 重複
    ];
    expect(hasUniqueColors(dims)).toBe(false);
  });
});

describe('hasNonEmptyIcons()', () => {
  it('全アイコンが空でなければ true を返す', () => {
    const dims = [
      { name: 'A', icon: '⭐', color: '#111', ariaLabel: 'A', testId: 'a' },
    ];
    expect(hasNonEmptyIcons(dims)).toBe(true);
  });

  it('空文字列アイコンがあれば false を返す', () => {
    const dims = [
      { name: 'A', icon: '', color: '#111', ariaLabel: 'A', testId: 'a' },
    ];
    expect(hasNonEmptyIcons(dims)).toBe(false);
  });

  it('スペースのみのアイコンは false として扱う', () => {
    const dims = [
      { name: 'A', icon: '   ', color: '#111', ariaLabel: 'A', testId: 'a' },
    ];
    expect(hasNonEmptyIcons(dims)).toBe(false);
  });
});

// ─── getDimensionRedundancy() ────────────────────────────────────────────────

describe('getDimensionRedundancy()', () => {
  // behavior: 各次元のアイコンとカラーが冗長表現（色のみに依存しない）で表示される
  it('iconLabel が "{icon} {name}" 形式で返る', () => {
    const dim = ACCESSIBLE_DIMENSIONS[0]; // 運気
    const redundancy = getDimensionRedundancy(dim);

    expect(redundancy.iconLabel).toBe(`${dim.icon} ${dim.name}`);
    expect(redundancy.iconLabel).toContain('⭐');
    expect(redundancy.iconLabel).toContain('運気');
  });

  it('name, icon, color が元の定義と一致する', () => {
    const dim = ACCESSIBLE_DIMENSIONS[1]; // 活力
    const redundancy = getDimensionRedundancy(dim);

    expect(redundancy.name).toBe(dim.name);
    expect(redundancy.icon).toBe(dim.icon);
    expect(redundancy.color).toBe(dim.color);
    expect(redundancy.ariaLabel).toBe(dim.ariaLabel);
  });

  it('全次元で iconLabel にアイコンと名前の両方が含まれる', () => {
    for (const dim of ACCESSIBLE_DIMENSIONS) {
      const redundancy = getDimensionRedundancy(dim);
      expect(redundancy.iconLabel).toContain(dim.icon);
      expect(redundancy.iconLabel).toContain(dim.name);
    }
  });
});

// ─── getAllDimensionRedundancies() ───────────────────────────────────────────

describe('getAllDimensionRedundancies()', () => {
  // behavior: 色覚シミュレーション環境で全7次元が弁別可能
  it('7件の冗長表現リストを返す', () => {
    const redundancies = getAllDimensionRedundancies();
    expect(redundancies).toHaveLength(7);
  });

  // behavior: 色覚シミュレーション環境で全7次元が弁別可能
  it('全7次元の iconLabel が全て異なる（一意）', () => {
    const redundancies = getAllDimensionRedundancies();
    const iconLabels = redundancies.map((r) => r.iconLabel);
    expect(new Set(iconLabels).size).toBe(7);
  });

  it('全7次元の icon が全て異なる（一意）', () => {
    const redundancies = getAllDimensionRedundancies();
    const icons = redundancies.map((r) => r.icon);
    expect(new Set(icons).size).toBe(7);
  });

  it('全7次元の color が全て異なる（一意）', () => {
    const redundancies = getAllDimensionRedundancies();
    const colors = redundancies.map((r) => r.color);
    expect(new Set(colors).size).toBe(7);
  });

  it('全次元に ariaLabel が含まれる（スクリーンリーダー対応）', () => {
    const redundancies = getAllDimensionRedundancies();
    for (const r of redundancies) {
      expect(r.ariaLabel).toBeTruthy();
      expect(r.ariaLabel.length).toBeGreaterThan(0);
    }
  });
});

// ─── getDimensionByName() ────────────────────────────────────────────────────

describe('getDimensionByName()', () => {
  it('"運気" を検索すると icon="⭐" の次元を返す', () => {
    const dim = getDimensionByName('運気');
    expect(dim).toBeDefined();
    expect(dim?.icon).toBe('⭐');
    expect(dim?.color).toBe('#f59e0b');
  });

  it('"活力" を検索すると icon="⚡" の次元を返す', () => {
    const dim = getDimensionByName('活力');
    expect(dim).toBeDefined();
    expect(dim?.icon).toBe('⚡');
  });

  it('存在しない名前を検索すると undefined を返す', () => {
    const dim = getDimensionByName('存在しない次元');
    expect(dim).toBeUndefined();
  });

  it('全7次元がそれぞれ getDimensionByName で取得できる', () => {
    const names = ['運気', '活力', '知性', '感情', '財運', '健康', '社交'];
    for (const name of names) {
      const dim = getDimensionByName(name);
      expect(dim).toBeDefined();
      expect(dim?.name).toBe(name);
    }
  });
});

// ─── 統合シナリオ ─────────────────────────────────────────────────────────────

describe('統合シナリオ: レスポンシブ + アクセシビリティ', () => {
  // behavior: モバイルビューポート（375px）→ カード・タブ・プログレスバーが縦積みレイアウト
  it('375px モバイルで stack レイアウトかつ7次元が弁別可能', () => {
    const layout = getLayoutConfigForWidth(375);
    const redundancies = getAllDimensionRedundancies();

    // モバイルは全要素縦積み
    expect(layout.cardLayout).toBe('stack');
    expect(layout.tabLayout).toBe('stack');
    expect(layout.progressBarLayout).toBe('stack');

    // 7次元が弁別可能（アイコンと色の冗長表現）
    expect(redundancies).toHaveLength(7);
    const icons = redundancies.map((r) => r.icon);
    expect(new Set(icons).size).toBe(7); // 全アイコン一意
  });

  // behavior: タブレットビューポート（768px）→ 中間レイアウトでコンテンツ幅最適化
  it('768px タブレットで grid レイアウトかつ contentMaxWidth=768px', () => {
    const layout = getLayoutConfigForWidth(768);
    expect(layout.cardLayout).toBe('grid');
    expect(layout.tabLayout).toBe('row');
    expect(layout.contentMaxWidth).toBe('768px');
  });

  // behavior: デスクトップビューポート（1280px）→ フル幅レイアウト
  it('1280px デスクトップで full-width レイアウトかつ contentMaxWidth=1280px', () => {
    const layout = getLayoutConfigForWidth(1280);
    expect(layout.cardLayout).toBe('full-width');
    expect(layout.tabLayout).toBe('row');
    expect(layout.contentMaxWidth).toBe('1280px');
  });

  // behavior: 各次元のアイコンとカラーが冗長表現（色のみに依存しない）で表示される
  it('7次元全てが icon（形状）と color（色）の両方で弁別できる（冗長表現）', () => {
    const dims = ACCESSIBLE_DIMENSIONS;

    // アイコンの一意性（色覚非依存の弁別）
    expect(hasUniqueIcons(dims)).toBe(true);
    // カラーの一意性（色による弁別）
    expect(hasUniqueColors(dims)).toBe(true);
    // アイコンが空でない（形状が視覚的に存在する）
    expect(hasNonEmptyIcons(dims)).toBe(true);
  });

  // behavior: 色覚シミュレーション環境で全7次元が弁別可能
  it('色覚シミュレーション環境: 全7次元の iconLabel が一意で弁別可能', () => {
    const redundancies = getAllDimensionRedundancies();

    // 色覚異常シミュレーションでは色が識別できないため、アイコン + ラベルで弁別
    const iconLabels = redundancies.map((r) => r.iconLabel);
    expect(new Set(iconLabels).size).toBe(7);

    // 各 iconLabel がアイコンと名前の両方を含む（二重の視覚的手がかり）
    for (const r of redundancies) {
      expect(r.iconLabel).toContain(r.icon);
      expect(r.iconLabel).toContain(r.name);
    }
  });
});

// ─── Viewport タイプガード ────────────────────────────────────────────────────

describe('Viewport タイプの網羅性', () => {
  const viewports: Viewport[] = ['mobile', 'tablet', 'desktop'];

  it('全ビューポートで getLayoutConfig がエラーなく動作する', () => {
    for (const vp of viewports) {
      expect(() => getLayoutConfig(vp)).not.toThrow();
      const config = getLayoutConfig(vp);
      expect(config.viewport).toBe(vp);
    }
  });

  it('全ビューポートで contentMaxWidth が空でない', () => {
    for (const vp of viewports) {
      const config = getLayoutConfig(vp);
      expect(config.contentMaxWidth.trim().length).toBeGreaterThan(0);
    }
  });
});
