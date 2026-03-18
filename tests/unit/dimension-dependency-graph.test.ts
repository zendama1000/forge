/**
 * Layer 1 Test: 次元間依存関係グラフのユニットテスト
 *
 * L1-002: 次元間依存関係の整合性チェック
 */

import { describe, it, expect } from 'vitest';
import {
  buildDependencyGraph,
  findOrphanReferences,
  findCircularReferences,
  findSelfReferences,
  getGraphStats,
  type ReligionWorldView,
} from '../../packages/shared/src/validation/dependency-graph';

describe('次元間依存関係グラフ', () => {
  describe('buildDependencyGraph', () => {
    it('正常系: 全参照が有効なグラフを構築できる', () => {
      const world: ReligionWorldView = {
        cosmology: [
          { id: 'c1', name: '創世神話', theologyRef: 'theology:t1' },
          { id: 'c2', name: '終末論', theologyRef: 'theology:t2' },
        ],
        theology: [
          { id: 't1', name: '主神', cosmologyRef: 'cosmology:c1' },
          { id: 't2', name: '破壊神', cosmologyRef: 'cosmology:c2' },
        ],
        ethics: [
          {
            id: 'e1',
            name: '十戒',
            theologyRefs: ['theology:t1', 'theology:t2'],
          },
        ],
        ritual: [
          {
            id: 'r1',
            name: '祈祷',
            ethicsRef: 'ethics:e1',
            symbolismRef: 'symbolism:s1',
          },
        ],
        narrative: [{ id: 'n1', name: '創世記', cosmologyRef: 'cosmology:c1' }],
        symbolism: [{ id: 's1', name: '聖印', theologyRef: 'theology:t1' }],
        socialStructure: [
          { id: 'ss1', name: '聖職者階級', ritualRefs: ['ritual:r1'] },
        ],
      };

      const graph = buildDependencyGraph(world);

      expect(graph.nodes.size).toBe(9); // 全エンティティ
      expect(graph.nodes.has('cosmology:c1')).toBe(true);
      expect(graph.nodes.has('theology:t1')).toBe(true);
      expect(graph.nodes.has('ethics:e1')).toBe(true);
    });

    it('正常系: 空の世界観でもエラーにならない', () => {
      const world: ReligionWorldView = {};
      const graph = buildDependencyGraph(world);

      expect(graph.nodes.size).toBe(0);
    });

    it('正常系: 一部の次元のみ存在する場合', () => {
      const world: ReligionWorldView = {
        cosmology: [{ id: 'c1', name: '創世神話' }],
        theology: [{ id: 't1', name: '主神' }],
      };

      const graph = buildDependencyGraph(world);

      expect(graph.nodes.size).toBe(2);
      expect(graph.nodes.has('cosmology:c1')).toBe(true);
      expect(graph.nodes.has('theology:t1')).toBe(true);
    });

    it('エッジケース: IDのないエンティティは無視される', () => {
      const world: ReligionWorldView = {
        cosmology: [
          { id: 'c1', name: '創世神話' },
          { name: '無名の神話' }, // IDなし
        ],
      };

      const graph = buildDependencyGraph(world);

      expect(graph.nodes.size).toBe(1);
      expect(graph.nodes.has('cosmology:c1')).toBe(true);
    });

    it('エッジケース: ネストされた参照フィールドも検出できる', () => {
      const world: ReligionWorldView = {
        cosmology: [
          {
            id: 'c1',
            name: '創世神話',
            details: {
              nested: {
                theologyRef: 'theology:t1',
              },
            },
          },
        ],
        theology: [{ id: 't1', name: '主神' }],
      };

      const graph = buildDependencyGraph(world);
      const node = graph.nodes.get('cosmology:c1');

      expect(node?.references.has('theology:t1')).toBe(true);
    });
  });

  describe('findOrphanReferences', () => {
    it('正常系: 孤立参照がない場合は空配列を返す', () => {
      const world: ReligionWorldView = {
        cosmology: [{ id: 'c1', name: '創世神話', theologyRef: 'theology:t1' }],
        theology: [{ id: 't1', name: '主神' }],
      };

      const graph = buildDependencyGraph(world);
      const orphans = findOrphanReferences(graph);

      expect(orphans).toEqual([]);
    });

    it('異常系: 存在しないIDへの参照を検出できる', () => {
      const world: ReligionWorldView = {
        cosmology: [
          { id: 'c1', name: '創世神話', theologyRef: 'theology:t999' }, // 存在しない
        ],
        theology: [{ id: 't1', name: '主神' }],
      };

      const graph = buildDependencyGraph(world);
      const orphans = findOrphanReferences(graph);

      expect(orphans.length).toBe(1);
      expect(orphans[0].source).toBe('cosmology:c1');
      expect(orphans[0].target).toBe('theology:t999');
    });

    it('異常系: 存在しない次元への参照を検出できる', () => {
      const world: ReligionWorldView = {
        cosmology: [
          { id: 'c1', name: '創世神話', unknownRef: 'unknown:u1' },
        ],
      };

      const graph = buildDependencyGraph(world);
      const orphans = findOrphanReferences(graph);

      expect(orphans.length).toBe(1);
      expect(orphans[0].target).toBe('unknown:u1');
    });

    it('異常系: 複数の孤立参照を検出できる', () => {
      const world: ReligionWorldView = {
        cosmology: [
          {
            id: 'c1',
            name: '創世神話',
            theologyRef: 'theology:t999',
            ethicsRef: 'ethics:e999',
          },
        ],
        theology: [{ id: 't1', name: '主神' }],
      };

      const graph = buildDependencyGraph(world);
      const orphans = findOrphanReferences(graph);

      expect(orphans.length).toBe(2);
    });
  });

  describe('findCircularReferences', () => {
    it('正常系: 循環参照がない場合は空配列を返す', () => {
      const world: ReligionWorldView = {
        cosmology: [{ id: 'c1', name: '創世神話', theologyRef: 'theology:t1' }],
        theology: [{ id: 't1', name: '主神' }], // 参照なし
      };

      const graph = buildDependencyGraph(world);
      const cycles = findCircularReferences(graph);

      expect(cycles).toEqual([]);
    });

    it('異常系: 単純な循環参照（A→B→A）を検出できる', () => {
      const world: ReligionWorldView = {
        cosmology: [{ id: 'c1', name: '創世神話', theologyRef: 'theology:t1' }],
        theology: [{ id: 't1', name: '主神', cosmologyRef: 'cosmology:c1' }],
      };

      const graph = buildDependencyGraph(world);
      const cycles = findCircularReferences(graph);

      expect(cycles.length).toBe(1);
      expect(cycles[0].cycle.length).toBe(2);
      expect(cycles[0].cycle).toContain('cosmology:c1');
      expect(cycles[0].cycle).toContain('theology:t1');
    });

    it('異常系: 複雑な循環参照（A→B→C→A）を検出できる', () => {
      const world: ReligionWorldView = {
        cosmology: [{ id: 'c1', name: '創世神話', theologyRef: 'theology:t1' }],
        theology: [{ id: 't1', name: '主神', ethicsRef: 'ethics:e1' }],
        ethics: [{ id: 'e1', name: '十戒', cosmologyRef: 'cosmology:c1' }],
      };

      const graph = buildDependencyGraph(world);
      const cycles = findCircularReferences(graph);

      expect(cycles.length).toBe(1);
      expect(cycles[0].cycle.length).toBe(3);
      expect(cycles[0].cycle).toContain('cosmology:c1');
      expect(cycles[0].cycle).toContain('theology:t1');
      expect(cycles[0].cycle).toContain('ethics:e1');
    });

    it('異常系: 複数の独立した循環参照を検出できる', () => {
      const world: ReligionWorldView = {
        // 循環1: c1 ⇄ t1
        cosmology: [{ id: 'c1', name: '創世神話', theologyRef: 'theology:t1' }],
        theology: [{ id: 't1', name: '主神', cosmologyRef: 'cosmology:c1' }],
        // 循環2: r1 ⇄ s1
        ritual: [{ id: 'r1', name: '祈祷', symbolismRef: 'symbolism:s1' }],
        symbolism: [{ id: 's1', name: '聖印', ritualRef: 'ritual:r1' }],
      };

      const graph = buildDependencyGraph(world);
      const cycles = findCircularReferences(graph);

      expect(cycles.length).toBe(2);
    });

    it('エッジケース: 孤立参照を含む循環参照（存在しないノードへの参照は無視）', () => {
      const world: ReligionWorldView = {
        cosmology: [
          {
            id: 'c1',
            name: '創世神話',
            theologyRef: 'theology:t1',
            unknownRef: 'unknown:u1', // 孤立参照
          },
        ],
        theology: [{ id: 't1', name: '主神', cosmologyRef: 'cosmology:c1' }],
      };

      const graph = buildDependencyGraph(world);
      const cycles = findCircularReferences(graph);

      // 孤立参照は無視され、c1⇄t1の循環のみ検出
      expect(cycles.length).toBe(1);
      expect(cycles[0].cycle.length).toBe(2);
    });
  });

  describe('findSelfReferences', () => {
    it('正常系: 自己参照がない場合は空配列を返す', () => {
      const world: ReligionWorldView = {
        cosmology: [{ id: 'c1', name: '創世神話' }],
      };

      const graph = buildDependencyGraph(world);
      const selfRefs = findSelfReferences(graph);

      expect(selfRefs).toEqual([]);
    });

    it('異常系: 自己参照を検出できる', () => {
      const world: ReligionWorldView = {
        cosmology: [
          {
            id: 'c1',
            name: '創世神話',
            selfRef: 'cosmology:c1', // 自己参照
          },
        ],
      };

      const graph = buildDependencyGraph(world);
      const selfRefs = findSelfReferences(graph);

      expect(selfRefs.length).toBe(1);
      expect(selfRefs[0]).toBe('cosmology:c1');
    });

    it('異常系: 複数の自己参照を検出できる', () => {
      const world: ReligionWorldView = {
        cosmology: [
          { id: 'c1', name: '創世神話', selfRef: 'cosmology:c1' },
        ],
        theology: [{ id: 't1', name: '主神', selfRef: 'theology:t1' }],
      };

      const graph = buildDependencyGraph(world);
      const selfRefs = findSelfReferences(graph);

      expect(selfRefs.length).toBe(2);
      expect(selfRefs).toContain('cosmology:c1');
      expect(selfRefs).toContain('theology:t1');
    });
  });

  describe('getGraphStats', () => {
    it('正常系: グラフ統計情報を取得できる', () => {
      const world: ReligionWorldView = {
        cosmology: [
          { id: 'c1', name: '創世神話', theologyRef: 'theology:t1' },
          { id: 'c2', name: '終末論', theologyRef: 'theology:t2' },
        ],
        theology: [
          { id: 't1', name: '主神' },
          { id: 't2', name: '破壊神' },
        ],
        ethics: [
          {
            id: 'e1',
            name: '十戒',
            theologyRefs: ['theology:t1', 'theology:t2'],
          },
        ],
      };

      const graph = buildDependencyGraph(world);
      const stats = getGraphStats(graph);

      expect(stats.totalNodes).toBe(5);
      expect(stats.totalEdges).toBe(4); // c1→t1, c2→t2, e1→t1, e1→t2
      expect(stats.nodesByDimension.cosmology).toBe(2);
      expect(stats.nodesByDimension.theology).toBe(2);
      expect(stats.nodesByDimension.ethics).toBe(1);
      expect(stats.nodesByDimension.ritual).toBe(0);
    });

    it('エッジケース: 空のグラフの統計', () => {
      const world: ReligionWorldView = {};
      const graph = buildDependencyGraph(world);
      const stats = getGraphStats(graph);

      expect(stats.totalNodes).toBe(0);
      expect(stats.totalEdges).toBe(0);
    });
  });

  describe('統合テスト: 複雑なシナリオ', () => {
    it('複雑な世界観の整合性チェック', () => {
      const world: ReligionWorldView = {
        cosmology: [
          { id: 'c1', name: '創世神話', theologyRefs: ['theology:t1'] },
          { id: 'c2', name: '終末論', theologyRefs: ['theology:t2'] },
        ],
        theology: [
          { id: 't1', name: '主神', ethicsRef: 'ethics:e1' },
          { id: 't2', name: '破壊神', narrativeRef: 'narrative:n1' },
        ],
        ethics: [
          {
            id: 'e1',
            name: '十戒',
            theologyRef: 'theology:t1',
            ritualRefs: ['ritual:r1', 'ritual:r2'],
          },
        ],
        ritual: [
          { id: 'r1', name: '祈祷', symbolismRef: 'symbolism:s1' },
          { id: 'r2', name: '供犠', symbolismRef: 'symbolism:s2' },
        ],
        narrative: [
          { id: 'n1', name: '黙示録', cosmologyRef: 'cosmology:c2' },
        ],
        symbolism: [
          { id: 's1', name: '聖印', theologyRef: 'theology:t1' },
          { id: 's2', name: '祭壇', ritualRef: 'ritual:r2' }, // 循環参照
        ],
        socialStructure: [
          {
            id: 'ss1',
            name: '聖職者階級',
            ritualRefs: ['ritual:r1', 'ritual:r2'],
          },
        ],
      };

      const graph = buildDependencyGraph(world);

      // グラフ統計
      const stats = getGraphStats(graph);
      expect(stats.totalNodes).toBe(11);
      expect(stats.totalEdges).toBeGreaterThan(0);

      // 孤立参照チェック
      const orphans = findOrphanReferences(graph);
      expect(orphans).toEqual([]);

      // 循環参照チェック（r2⇄s2の循環が存在）
      const cycles = findCircularReferences(graph);
      expect(cycles.length).toBeGreaterThan(0);
    });
  });
});
