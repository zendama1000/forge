/**
 * FortuneCard / DimensionBar コンポーネントロジック Layer 1 テスト
 *
 * - createFortuneCard() のプログレスバースタイル計算を検証
 * - createDimensionBar() のアイコン・カラー反映を検証
 * - 全 required_behaviors をカバー
 */

import { describe, it, expect } from 'vitest';
import { createFortuneCard } from '../../components/fortune-card';
import { createDimensionBar } from '../../components/dimension-bar';

// ─── FortuneCard ────────────────────────────────────────────────────────────

describe('FortuneCard: createFortuneCard()', () => {
  // behavior: FortuneCardにscore=75を渡す → プログレスバーのwidthスタイルが75%
  it('score=75のとき、progressBarStyle.widthが"75%"になる', () => {
    const state = createFortuneCard({ score: 75 });
    expect(state.progressBarStyle.width).toBe('75%');
  });

  // behavior: FortuneCardにscore=0を渡す → プログレスバーのwidthスタイルが0%
  it('score=0のとき、progressBarStyle.widthが"0%"になる', () => {
    const state = createFortuneCard({ score: 0 });
    expect(state.progressBarStyle.width).toBe('0%');
  });

  // behavior: FortuneCardにscore=100を渡す → プログレスバーのwidthスタイルが100%
  it('score=100のとき、progressBarStyle.widthが"100%"になる', () => {
    const state = createFortuneCard({ score: 100 });
    expect(state.progressBarStyle.width).toBe('100%');
  });

  // behavior: FortuneCardにcategoryデータ未定義を渡す → エラーにならず空状態またはフォールバック表示
  it('category未定義（空props）を渡してもエラーにならず、score=0のフォールバックを返す', () => {
    expect(() => createFortuneCard({})).not.toThrow();
    const state = createFortuneCard({});
    expect(state.progressBarStyle.width).toBe('0%');
    expect(state.score).toBe(0);
    expect(state.categoryName).toBe('');
    expect(state.templateText).toBe('');
  });

  // behavior: [追加] categoryオブジェクトのtotalScoreからwidthが計算される
  it('category.totalScore=60のとき、score propなしでもwidthが"60%"になる', () => {
    const state = createFortuneCard({
      category: {
        name: '運命',
        totalScore: 60,
        templateText: 'あなたの運命は輝いています',
      },
    });
    expect(state.progressBarStyle.width).toBe('60%');
    expect(state.score).toBe(60);
    expect(state.categoryName).toBe('運命');
    expect(state.templateText).toBe('あなたの運命は輝いています');
  });

  // behavior: [追加] score propはcategory.totalScoreより優先される
  it('score propとcategoryの両方を渡したとき、score propが優先される', () => {
    const state = createFortuneCard({
      score: 80,
      category: { totalScore: 40 },
    });
    expect(state.progressBarStyle.width).toBe('80%');
    expect(state.score).toBe(80);
  });

  // behavior: [追加] scoreのwidthスタイルはパーセント文字列形式
  it('progressBarStyle.widthはnumber単位ではなく%付き文字列で返される', () => {
    const state = createFortuneCard({ score: 33 });
    expect(typeof state.progressBarStyle.width).toBe('string');
    expect(state.progressBarStyle.width).toMatch(/^\d+%$/);
  });
});

// ─── DimensionBar ────────────────────────────────────────────────────────────

describe('DimensionBar: createDimensionBar()', () => {
  // behavior: DimensionBarにicon propを渡す → 対応するアイコン要素がDOMに存在
  it('icon="⭐"を渡すと、返却データのiconプロパティが"⭐"と一致する', () => {
    const state = createDimensionBar({ icon: '⭐', color: '#3b82f6' });
    expect(state.icon).toBe('⭐');
  });

  // behavior: DimensionBarにcolor propを渡す → バーの背景色が指定色と一致
  it('color="#ff6347"を渡すと、barStyle.backgroundColorが"#ff6347"と一致する', () => {
    const state = createDimensionBar({ icon: '🌙', color: '#ff6347' });
    expect(state.barStyle.backgroundColor).toBe('#ff6347');
  });

  // behavior: [追加] 別の色でもbarStyle.backgroundColorが正確に反映される
  it('color="rgb(99,102,241)"を渡すと、barStyle.backgroundColorが一致する', () => {
    const state = createDimensionBar({ icon: '💫', color: 'rgb(99,102,241)' });
    expect(state.barStyle.backgroundColor).toBe('rgb(99,102,241)');
  });

  // behavior: [追加] score propを渡すとbarStyle.widthに反映される
  it('score=55を渡すと、barStyle.widthが"55%"になる', () => {
    const state = createDimensionBar({ icon: '🔥', color: '#ef4444', score: 55 });
    expect(state.barStyle.width).toBe('55%');
  });

  // behavior: [追加] score省略時はbarStyle.widthが"0%"のフォールバック
  it('score未指定のとき、barStyle.widthが"0%"のフォールバックになる', () => {
    const state = createDimensionBar({ icon: '💎', color: '#8b5cf6' });
    expect(state.barStyle.width).toBe('0%');
  });

  // behavior: [追加] label propが返却データに反映される
  it('label="活力"を渡すと、返却データのlabelが"活力"と一致する', () => {
    const state = createDimensionBar({ icon: '⚡', color: '#f59e0b', label: '活力' });
    expect(state.label).toBe('活力');
  });

  // behavior: [追加] label省略時は空文字列のフォールバック
  it('label未指定のとき、labelが空文字列になる', () => {
    const state = createDimensionBar({ icon: '🌸', color: '#ec4899' });
    expect(state.label).toBe('');
  });
});
