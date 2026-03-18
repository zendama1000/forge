/**
 * Dependency Graph - 7次元間の参照整合性チェック
 *
 * 7次元間の依存関係を有向グラフとして構築し、
 * 孤立参照（存在しないIDへの参照）と循環参照を検出する
 */

/**
 * 7次元の各次元を表す型
 */
export type DimensionType =
  | 'cosmology'
  | 'theology'
  | 'ethics'
  | 'ritual'
  | 'narrative'
  | 'symbolism'
  | 'socialStructure';

/**
 * 次元内のエンティティ（IDを持つオブジェクト）
 */
export interface DimensionEntity {
  id: string;
  [key: string]: any;
}

/**
 * 7次元世界観データの型
 */
export interface ReligionWorldView {
  cosmology?: DimensionEntity[];
  theology?: DimensionEntity[];
  ethics?: DimensionEntity[];
  ritual?: DimensionEntity[];
  narrative?: DimensionEntity[];
  symbolism?: DimensionEntity[];
  socialStructure?: DimensionEntity[];
  [key: string]: any;
}

/**
 * 依存関係グラフのノード
 */
export interface GraphNode {
  dimension: DimensionType;
  entityId: string;
  references: Set<string>; // 参照先のフルID（dimension:entityId形式）
}

/**
 * 依存関係グラフ
 */
export interface DependencyGraph {
  nodes: Map<string, GraphNode>; // キー: "dimension:entityId"
}

/**
 * 孤立参照の情報
 */
export interface OrphanReference {
  source: string; // 参照元（dimension:entityId形式）
  target: string; // 存在しない参照先（dimension:entityId形式）
  field?: string; // 参照元のフィールド名（オプション）
}

/**
 * 循環参照の情報
 */
export interface CircularReference {
  cycle: string[]; // 循環するノードのパス（dimension:entityId形式）
}

/**
 * 7次元世界観データから依存関係グラフを構築
 *
 * @param world - 7次元世界観データ
 * @returns 依存関係グラフ
 */
export function buildDependencyGraph(world: ReligionWorldView): DependencyGraph {
  const graph: DependencyGraph = {
    nodes: new Map(),
  };

  const dimensions: DimensionType[] = [
    'cosmology',
    'theology',
    'ethics',
    'ritual',
    'narrative',
    'symbolism',
    'socialStructure',
  ];

  // 全ノードを登録
  for (const dimension of dimensions) {
    const entities = world[dimension];
    if (!Array.isArray(entities)) continue;

    for (const entity of entities) {
      if (!entity.id) continue;

      const nodeId = `${dimension}:${entity.id}`;
      graph.nodes.set(nodeId, {
        dimension,
        entityId: entity.id,
        references: new Set(),
      });
    }
  }

  // 参照関係を収集
  for (const dimension of dimensions) {
    const entities = world[dimension];
    if (!Array.isArray(entities)) continue;

    for (const entity of entities) {
      if (!entity.id) continue;

      const nodeId = `${dimension}:${entity.id}`;
      const node = graph.nodes.get(nodeId);
      if (!node) continue;

      // エンティティ内の全フィールドをスキャンして参照を検出
      extractReferences(entity, node.references);
    }
  }

  return graph;
}

/**
 * オブジェクトから参照ID（dimension:entityId形式）を抽出
 *
 * @param obj - スキャン対象のオブジェクト
 * @param references - 参照を格納するSet
 */
function extractReferences(obj: any, references: Set<string>): void {
  if (!obj || typeof obj !== 'object') return;

  for (const key in obj) {
    const value = obj[key];

    // 参照フィールドの命名規則: "*Ref", "*Refs", "*Reference", "*References"
    if (
      (key.endsWith('Ref') ||
        key.endsWith('Refs') ||
        key.endsWith('Reference') ||
        key.endsWith('References')) &&
      value
    ) {
      if (typeof value === 'string' && value.includes(':')) {
        // 単一参照: "dimension:entityId"
        references.add(value);
      } else if (Array.isArray(value)) {
        // 配列参照
        for (const ref of value) {
          if (typeof ref === 'string' && ref.includes(':')) {
            references.add(ref);
          }
        }
      }
    }

    // 再帰的にネストされたオブジェクトをスキャン
    if (typeof value === 'object' && value !== null) {
      extractReferences(value, references);
    }
  }
}

/**
 * 孤立参照を検出
 *
 * 存在しないノードへの参照を検出する
 *
 * @param graph - 依存関係グラフ
 * @returns 孤立参照のリスト
 */
export function findOrphanReferences(graph: DependencyGraph): OrphanReference[] {
  const orphans: OrphanReference[] = [];

  for (const [nodeId, node] of graph.nodes) {
    for (const ref of node.references) {
      if (!graph.nodes.has(ref)) {
        orphans.push({
          source: nodeId,
          target: ref,
        });
      }
    }
  }

  return orphans;
}

/**
 * Tarjanのアルゴリズムで循環参照を検出
 *
 * 強連結成分（SCC）を検出し、サイズが2以上のSCCを循環参照として報告
 *
 * @param graph - 依存関係グラフ
 * @returns 循環参照のリスト
 */
export function findCircularReferences(graph: DependencyGraph): CircularReference[] {
  const index = new Map<string, number>();
  const lowlink = new Map<string, number>();
  const onStack = new Set<string>();
  const stack: string[] = [];
  let currentIndex = 0;
  const sccs: string[][] = [];

  function strongConnect(nodeId: string): void {
    index.set(nodeId, currentIndex);
    lowlink.set(nodeId, currentIndex);
    currentIndex++;
    stack.push(nodeId);
    onStack.add(nodeId);

    const node = graph.nodes.get(nodeId);
    if (node) {
      for (const ref of node.references) {
        if (!graph.nodes.has(ref)) continue; // 孤立参照は無視

        if (!index.has(ref)) {
          // 未訪問ノード
          strongConnect(ref);
          lowlink.set(nodeId, Math.min(lowlink.get(nodeId)!, lowlink.get(ref)!));
        } else if (onStack.has(ref)) {
          // スタック上のノード（後方エッジ）
          lowlink.set(nodeId, Math.min(lowlink.get(nodeId)!, index.get(ref)!));
        }
      }
    }

    // SCCのルートノードの場合
    if (lowlink.get(nodeId) === index.get(nodeId)) {
      const scc: string[] = [];
      let w: string;
      do {
        w = stack.pop()!;
        onStack.delete(w);
        scc.push(w);
      } while (w !== nodeId);

      if (scc.length > 1) {
        sccs.push(scc);
      }
    }
  }

  // 全ノードに対してTarjanアルゴリズムを実行
  for (const nodeId of graph.nodes.keys()) {
    if (!index.has(nodeId)) {
      strongConnect(nodeId);
    }
  }

  // SCCを循環参照情報に変換
  return sccs.map((scc) => ({
    cycle: scc,
  }));
}

/**
 * 自己参照を検出
 *
 * ノードが自分自身を参照している場合を検出
 *
 * @param graph - 依存関係グラフ
 * @returns 自己参照しているノードのリスト
 */
export function findSelfReferences(graph: DependencyGraph): string[] {
  const selfRefs: string[] = [];

  for (const [nodeId, node] of graph.nodes) {
    if (node.references.has(nodeId)) {
      selfRefs.push(nodeId);
    }
  }

  return selfRefs;
}

/**
 * グラフの統計情報を取得
 *
 * @param graph - 依存関係グラフ
 * @returns 統計情報
 */
export function getGraphStats(graph: DependencyGraph): {
  totalNodes: number;
  totalEdges: number;
  nodesByDimension: Record<DimensionType, number>;
} {
  const stats = {
    totalNodes: graph.nodes.size,
    totalEdges: 0,
    nodesByDimension: {
      cosmology: 0,
      theology: 0,
      ethics: 0,
      ritual: 0,
      narrative: 0,
      symbolism: 0,
      socialStructure: 0,
    } as Record<DimensionType, number>,
  };

  for (const [, node] of graph.nodes) {
    stats.totalEdges += node.references.size;
    stats.nodesByDimension[node.dimension]++;
  }

  return stats;
}
