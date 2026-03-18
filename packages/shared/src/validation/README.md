# Dependency Graph - 7次元間参照整合性チェック

## 概要

7次元宗教世界観データの次元間参照整合性を検証するためのモジュール。
有向グラフを構築し、孤立参照・循環参照・自己参照を検出します。

## 7次元の構造

1. **Cosmology** (宇宙論) - 世界の構造・創世神話
2. **Theology** (神学) - 神々の定義・性質
3. **Ethics** (倫理体系) - 戒律・道徳規範
4. **Ritual** (儀式) - 祈祷・儀礼
5. **Narrative/Myth** (神話/物語) - 創世記・救済神話
6. **Symbolism** (シンボル) - 聖印・象徴
7. **Social Structure** (社会構造) - 聖職者階級・組織

## 参照フィールドの命名規則

次元間参照は以下の接尾辞を持つフィールド名で表現されます:

- `*Ref` - 単一参照（例: `theologyRef: "theology:deity-1"`）
- `*Refs` - 複数参照（例: `theologyRefs: ["theology:t1", "theology:t2"]`）
- `*Reference` - 単一参照
- `*References` - 複数参照

参照値の形式: `"dimension:entityId"`

## 使用例

### 基本的な使用方法

```typescript
import {
  buildDependencyGraph,
  findOrphanReferences,
  findCircularReferences,
} from '@shared/validation/dependency-graph';

const world = {
  cosmology: [
    { id: 'c1', name: '創世神話', theologyRef: 'theology:t1' },
  ],
  theology: [
    { id: 't1', name: '主神', ethicsRef: 'ethics:e1' },
  ],
  ethics: [
    { id: 'e1', name: '十戒', cosmologyRef: 'cosmology:c1' }, // 循環参照!
  ],
};

// グラフ構築
const graph = buildDependencyGraph(world);

// 孤立参照を検出
const orphans = findOrphanReferences(graph);
if (orphans.length > 0) {
  console.error('存在しない参照が検出されました:', orphans);
}

// 循環参照を検出
const cycles = findCircularReferences(graph);
if (cycles.length > 0) {
  console.warn('循環参照が検出されました:', cycles);
}
```

### バリデーション統合例

```typescript
import { buildDependencyGraph, findOrphanReferences } from './dependency-graph';

function validateWorldIntegrity(world: ReligionWorldView): {
  valid: boolean;
  errors: string[];
} {
  const errors: string[] = [];

  // グラフ構築
  const graph = buildDependencyGraph(world);

  // 孤立参照チェック
  const orphans = findOrphanReferences(graph);
  if (orphans.length > 0) {
    for (const orphan of orphans) {
      errors.push(
        `孤立参照: ${orphan.source} -> ${orphan.target} (存在しません)`
      );
    }
  }

  // 循環参照チェック（警告のみ）
  const cycles = findCircularReferences(graph);
  if (cycles.length > 0) {
    for (const cycle of cycles) {
      errors.push(`循環参照: ${cycle.cycle.join(' -> ')}`);
    }
  }

  return {
    valid: errors.length === 0,
    errors,
  };
}
```

## API リファレンス

### `buildDependencyGraph(world: ReligionWorldView): DependencyGraph`

7次元世界観データから依存関係グラフを構築します。

**パラメータ:**
- `world` - 7次元世界観データ

**戻り値:**
- `DependencyGraph` - 有向グラフ（ノードと参照エッジ）

### `findOrphanReferences(graph: DependencyGraph): OrphanReference[]`

存在しないエンティティへの参照を検出します。

**パラメータ:**
- `graph` - 依存関係グラフ

**戻り値:**
- `OrphanReference[]` - 孤立参照のリスト

### `findCircularReferences(graph: DependencyGraph): CircularReference[]`

Tarjanアルゴリズムで循環参照を検出します。

**パラメータ:**
- `graph` - 依存関係グラフ

**戻り値:**
- `CircularReference[]` - 循環参照のリスト

### `findSelfReferences(graph: DependencyGraph): string[]`

自己参照（エンティティが自分自身を参照）を検出します。

**パラメータ:**
- `graph` - 依存関係グラフ

**戻り値:**
- `string[]` - 自己参照しているノードIDのリスト

### `getGraphStats(graph: DependencyGraph): GraphStats`

グラフの統計情報を取得します。

**パラメータ:**
- `graph` - 依存関係グラフ

**戻り値:**
- `GraphStats` - 統計情報（ノード数、エッジ数、次元別ノード数）

## アルゴリズム

### Tarjanの強連結成分アルゴリズム

循環参照の検出には Tarjan のアルゴリズムを使用しています。
時間計算量: O(V + E) （V: ノード数、E: エッジ数）

1. DFS で全ノードを訪問
2. 各ノードに index と lowlink を割り当て
3. スタックで強連結成分を追跡
4. lowlink == index のノードが SCC のルート
5. サイズ 2 以上の SCC を循環参照として報告

## テスト

```bash
# Layer 1 ユニットテスト
vitest run tests/unit/dimension-dependency-graph.test.ts

# Layer 2 統合テスト
vitest run tests/integration/dependency-graph-integration.test.ts
```

## 制約事項

- 参照フィールドは命名規則（`*Ref(s)`, `*Reference(s)`）に従う必要があります
- 参照値は `"dimension:entityId"` 形式である必要があります
- ネストされたオブジェクト内の参照も検出しますが、配列の深い階層は非推奨

## パフォーマンス

- 700ノード（100エンティティ×7次元）のグラフ構築: < 1秒
- 循環参照検出（Tarjan）: < 2秒
- メモリ使用量: O(V + E)

## 今後の拡張

- [ ] 参照の重み付け（重要度）
- [ ] 次元間の依存度スコア算出
- [ ] グラフの可視化エクスポート（Graphviz DOT形式）
- [ ] 参照の推奨/非推奨パターンの検出
