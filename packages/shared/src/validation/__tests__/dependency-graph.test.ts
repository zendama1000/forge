/**
 * Layer 1 Unit Tests for Dependency Graph
 *
 * 依存関係グラフの基本機能テスト
 */

import { describe, it, expect } from 'vitest';
import {
  buildDependencyGraph,
  findOrphanReferences,
  findCircularReferences,
  findSelfReferences,
  getGraphStats,
  type ReligionWorldView,
} from '../dependency-graph';

describe('buildDependencyGraph', () => {
  it('空の世界観でもエラーにならない', () => {
    const world: ReligionWorldView = {};
    const graph = buildDependencyGraph(world);
    expect(graph.nodes.size).toBe(0);
  });

  it('単一次元のエンティティを正しく登録できる', () => {
    const world: ReligionWorldView = {
      cosmology: [{ id: 'c1', name: 'Test' }],
    };
    const graph = buildDependencyGraph(world);
    expect(graph.nodes.has('cosmology:c1')).toBe(true);
  });

  it('参照関係を正しく検出できる', () => {
    const world: ReligionWorldView = {
      cosmology: [{ id: 'c1', theologyRef: 'theology:t1' }],
      theology: [{ id: 't1' }],
    };
    const graph = buildDependencyGraph(world);
    const node = graph.nodes.get('cosmology:c1');
    expect(node?.references.has('theology:t1')).toBe(true);
  });
});

describe('findOrphanReferences', () => {
  it('孤立参照を検出できる', () => {
    const world: ReligionWorldView = {
      cosmology: [{ id: 'c1', theologyRef: 'theology:t999' }],
    };
    const graph = buildDependencyGraph(world);
    const orphans = findOrphanReferences(graph);
    expect(orphans.length).toBe(1);
    expect(orphans[0].target).toBe('theology:t999');
  });
});

describe('findCircularReferences', () => {
  it('単純な循環参照を検出できる', () => {
    const world: ReligionWorldView = {
      cosmology: [{ id: 'c1', theologyRef: 'theology:t1' }],
      theology: [{ id: 't1', cosmologyRef: 'cosmology:c1' }],
    };
    const graph = buildDependencyGraph(world);
    const cycles = findCircularReferences(graph);
    expect(cycles.length).toBe(1);
    expect(cycles[0].cycle.length).toBe(2);
  });
});

describe('findSelfReferences', () => {
  it('自己参照を検出できる', () => {
    const world: ReligionWorldView = {
      cosmology: [{ id: 'c1', selfRef: 'cosmology:c1' }],
    };
    const graph = buildDependencyGraph(world);
    const selfRefs = findSelfReferences(graph);
    expect(selfRefs).toContain('cosmology:c1');
  });
});

describe('getGraphStats', () => {
  it('グラフ統計を正しく計算できる', () => {
    const world: ReligionWorldView = {
      cosmology: [{ id: 'c1' }, { id: 'c2' }],
      theology: [{ id: 't1', cosmologyRef: 'cosmology:c1' }],
    };
    const graph = buildDependencyGraph(world);
    const stats = getGraphStats(graph);
    expect(stats.totalNodes).toBe(3);
    expect(stats.nodesByDimension.cosmology).toBe(2);
    expect(stats.nodesByDimension.theology).toBe(1);
  });
});
