/**
 * Dependency Graph - 使用例
 *
 * このファイルは依存関係グラフの使用方法を示すサンプルコードです。
 */

import {
  buildDependencyGraph,
  findOrphanReferences,
  findCircularReferences,
  findSelfReferences,
  getGraphStats,
  type ReligionWorldView,
} from './dependency-graph';

/**
 * 例1: 基本的なバリデーション
 */
export function example1_basicValidation() {
  const world: ReligionWorldView = {
    cosmology: [
      {
        id: 'cosmos-1',
        name: '三層宇宙論',
        theologyRef: 'theology:deity-1',
      },
    ],
    theology: [
      {
        id: 'deity-1',
        name: '至高神',
        ethicsRef: 'ethics:commandments-1',
      },
    ],
    ethics: [
      {
        id: 'commandments-1',
        name: '五徳',
        theologyRef: 'theology:deity-1', // 循環参照
      },
    ],
  };

  const graph = buildDependencyGraph(world);
  console.log('グラフ統計:', getGraphStats(graph));

  const orphans = findOrphanReferences(graph);
  console.log('孤立参照:', orphans);

  const cycles = findCircularReferences(graph);
  console.log('循環参照:', cycles);
}

/**
 * 例2: エラーハンドリング付きバリデーション
 */
export function example2_validationWithErrorHandling(
  world: ReligionWorldView
): {
  valid: boolean;
  errors: string[];
  warnings: string[];
} {
  const errors: string[] = [];
  const warnings: string[] = [];

  try {
    const graph = buildDependencyGraph(world);

    // 孤立参照チェック（エラー）
    const orphans = findOrphanReferences(graph);
    if (orphans.length > 0) {
      for (const orphan of orphans) {
        errors.push(
          `孤立参照: ${orphan.source} が存在しない ${orphan.target} を参照しています`
        );
      }
    }

    // 自己参照チェック（エラー）
    const selfRefs = findSelfReferences(graph);
    if (selfRefs.length > 0) {
      for (const selfRef of selfRefs) {
        errors.push(`自己参照: ${selfRef} が自分自身を参照しています`);
      }
    }

    // 循環参照チェック（警告）
    const cycles = findCircularReferences(graph);
    if (cycles.length > 0) {
      for (const cycle of cycles) {
        warnings.push(
          `循環参照が検出されました: ${cycle.cycle.join(' → ')}`
        );
      }
    }

    return {
      valid: errors.length === 0,
      errors,
      warnings,
    };
  } catch (error) {
    return {
      valid: false,
      errors: [`グラフ構築エラー: ${error}`],
      warnings: [],
    };
  }
}

/**
 * 例3: 次元別の参照統計を取得
 */
export function example3_dimensionReferenceStats(world: ReligionWorldView) {
  const graph = buildDependencyGraph(world);

  const referencesByDimension: Record<string, { in: number; out: number }> = {};

  for (const [nodeId, node] of graph.nodes) {
    const dim = node.dimension;

    if (!referencesByDimension[dim]) {
      referencesByDimension[dim] = { in: 0, out: 0 };
    }

    // 出ていく参照数
    referencesByDimension[dim].out += node.references.size;

    // 入ってくる参照数
    for (const ref of node.references) {
      const [targetDim] = ref.split(':');
      if (!referencesByDimension[targetDim]) {
        referencesByDimension[targetDim] = { in: 0, out: 0 };
      }
      referencesByDimension[targetDim].in++;
    }
  }

  return referencesByDimension;
}

/**
 * 例4: 特定の次元への依存度を計算
 */
export function example4_calculateDependencyScore(
  world: ReligionWorldView,
  targetDimension: string
): number {
  const graph = buildDependencyGraph(world);
  let referenceCount = 0;

  for (const [, node] of graph.nodes) {
    for (const ref of node.references) {
      if (ref.startsWith(`${targetDimension}:`)) {
        referenceCount++;
      }
    }
  }

  return referenceCount;
}

/**
 * 例5: 推奨参照パターンのチェック
 *
 * 推奨パターン:
 * - Cosmology → Theology
 * - Theology → Ethics
 * - Ethics → Ritual
 * - Ritual → Symbolism
 * - Narrative → Cosmology, Theology
 * - SocialStructure → Ritual, Ethics
 */
export function example5_checkRecommendedPatterns(world: ReligionWorldView): {
  recommended: string[];
  discouraged: string[];
} {
  const graph = buildDependencyGraph(world);
  const recommended: string[] = [];
  const discouraged: string[] = [];

  const recommendedPatterns = new Map<string, string[]>([
    ['cosmology', ['theology']],
    ['theology', ['ethics']],
    ['ethics', ['ritual']],
    ['ritual', ['symbolism']],
    ['narrative', ['cosmology', 'theology']],
    ['socialStructure', ['ritual', 'ethics']],
  ]);

  for (const [nodeId, node] of graph.nodes) {
    const sourceDim = node.dimension;
    const recommendedTargets = recommendedPatterns.get(sourceDim) || [];

    for (const ref of node.references) {
      const [targetDim] = ref.split(':');

      if (recommendedTargets.includes(targetDim)) {
        recommended.push(`${nodeId} → ${ref} (推奨パターン)`);
      } else {
        discouraged.push(`${nodeId} → ${ref} (非推奨パターン)`);
      }
    }
  }

  return { recommended, discouraged };
}

/**
 * 例6: API統合例（Express/Honoミドルウェア）
 */
export function example6_apiMiddleware() {
  return (req: any, res: any, next: any) => {
    const world = req.body as ReligionWorldView;

    const validation = example2_validationWithErrorHandling(world);

    if (!validation.valid) {
      return res.status(422).json({
        error: 'Validation failed',
        errors: validation.errors,
        warnings: validation.warnings,
      });
    }

    if (validation.warnings.length > 0) {
      // 警告がある場合はヘッダーに含める
      res.setHeader('X-Validation-Warnings', validation.warnings.join('; '));
    }

    next();
  };
}
