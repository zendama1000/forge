/**
 * Layer 2 Test: 依存関係グラフの統合テスト
 *
 * 実際の7次元スキーマとの統合テスト
 * ※このテストはスキーマ実装後に実行可能
 */

import { describe, it, expect } from 'vitest';
import {
  buildDependencyGraph,
  findOrphanReferences,
  findCircularReferences,
  type ReligionWorldView,
} from '../../packages/shared/src/validation/dependency-graph';

describe('依存関係グラフ統合テスト', () => {
  it('実世界観データの整合性を検証できる', () => {
    // 実際の生成データを想定したテストケース
    const world: ReligionWorldView = {
      cosmology: [
        {
          id: 'cosmos-1',
          name: '三層宇宙論',
          description: '天界・地上界・冥界の三層構造',
          theologyRefs: ['theology:deity-1', 'theology:deity-2'],
        },
      ],
      theology: [
        {
          id: 'deity-1',
          name: '至高神ゼノス',
          domain: '天界',
          cosmologyRef: 'cosmology:cosmos-1',
          ethicsRef: 'ethics:commandments-1',
        },
        {
          id: 'deity-2',
          name: '冥府神ハデリア',
          domain: '冥界',
          cosmologyRef: 'cosmology:cosmos-1',
        },
      ],
      ethics: [
        {
          id: 'commandments-1',
          name: '五徳',
          principles: ['誠実', '慈悲', '勇気', '知恵', '節制'],
          theologyRef: 'theology:deity-1',
          ritualRefs: ['ritual:daily-prayer', 'ritual:confession'],
        },
      ],
      ritual: [
        {
          id: 'daily-prayer',
          name: '日々の祈り',
          frequency: '朝夕',
          ethicsRef: 'ethics:commandments-1',
          symbolismRefs: ['symbolism:holy-sign'],
        },
        {
          id: 'confession',
          name: '懺悔の儀',
          frequency: '月次',
          ethicsRef: 'ethics:commandments-1',
          narrativeRef: 'narrative:redemption-myth',
        },
      ],
      narrative: [
        {
          id: 'creation-myth',
          name: '創世神話',
          summary: 'ゼノスによる世界創造の物語',
          cosmologyRef: 'cosmology:cosmos-1',
          theologyRef: 'theology:deity-1',
        },
        {
          id: 'redemption-myth',
          name: '救済の物語',
          summary: '罪からの解放',
          theologyRef: 'theology:deity-1',
        },
      ],
      symbolism: [
        {
          id: 'holy-sign',
          name: '聖印',
          description: '三角形の中に円',
          theologyRef: 'theology:deity-1',
          ritualRef: 'ritual:daily-prayer',
        },
      ],
      socialStructure: [
        {
          id: 'clergy',
          name: '聖職者階級',
          hierarchy: ['大神官', '神官', '見習い'],
          ritualRefs: ['ritual:daily-prayer', 'ritual:confession'],
          ethicsRef: 'ethics:commandments-1',
        },
      ],
    };

    const graph = buildDependencyGraph(world);

    // 孤立参照チェック
    const orphans = findOrphanReferences(graph);
    expect(orphans.length).toBe(0);

    // 循環参照チェック（holy-sign ⇄ daily-prayerの循環が存在）
    const cycles = findCircularReferences(graph);

    // 循環参照が検出されること
    expect(cycles.length).toBeGreaterThan(0);

    // 検出された循環にはritual:daily-prayerとsymbolism:holy-signが含まれること
    const flatCycle = cycles.flatMap((c) => c.cycle);
    expect(flatCycle).toContain('ritual:daily-prayer');
    expect(flatCycle).toContain('symbolism:holy-sign');
  });

  it('大規模な世界観データでもパフォーマンスが許容範囲内', () => {
    // 100エンティティ×7次元 = 700ノードのグラフ
    const world: ReligionWorldView = {};
    const dimensions = [
      'cosmology',
      'theology',
      'ethics',
      'ritual',
      'narrative',
      'symbolism',
      'socialStructure',
    ] as const;

    for (const dim of dimensions) {
      world[dim] = [];
      for (let i = 0; i < 100; i++) {
        world[dim]!.push({
          id: `${dim}-${i}`,
          name: `Entity ${i}`,
          // ランダムな参照を追加
          ref1: `theology:theology-${(i + 1) % 100}`,
          ref2: `ethics:ethics-${(i + 2) % 100}`,
        });
      }
    }

    const startTime = Date.now();
    const graph = buildDependencyGraph(world);
    const buildTime = Date.now() - startTime;

    expect(graph.nodes.size).toBe(700);
    expect(buildTime).toBeLessThan(1000); // 1秒以内

    const findStartTime = Date.now();
    findOrphanReferences(graph);
    findCircularReferences(graph);
    const findTime = Date.now() - findStartTime;

    expect(findTime).toBeLessThan(2000); // 2秒以内
  });

  it('参照フィールドの命名規則が正しく機能する', () => {
    const world: ReligionWorldView = {
      cosmology: [
        {
          id: 'c1',
          // 様々な命名パターンをテスト
          theologyRef: 'theology:t1', // 単数形Ref
          narrativeRefs: ['narrative:n1', 'narrative:n2'], // 複数形Refs
          symbolismReference: 'symbolism:s1', // Reference
          ethicsReferences: ['ethics:e1'], // References
          // 参照でないフィールド（無視されるべき）
          name: 'cosmology:should-not-be-detected',
          description: 'theology:also-not-a-reference',
        },
      ],
      theology: [{ id: 't1' }],
      narrative: [{ id: 'n1' }, { id: 'n2' }],
      symbolism: [{ id: 's1' }],
      ethics: [{ id: 'e1' }],
    };

    const graph = buildDependencyGraph(world);
    const node = graph.nodes.get('cosmology:c1');

    expect(node?.references.size).toBe(5); // t1, n1, n2, s1, e1
    expect(node?.references.has('theology:t1')).toBe(true);
    expect(node?.references.has('narrative:n1')).toBe(true);
    expect(node?.references.has('narrative:n2')).toBe(true);
    expect(node?.references.has('symbolism:s1')).toBe(true);
    expect(node?.references.has('ethics:e1')).toBe(true);
  });
});
