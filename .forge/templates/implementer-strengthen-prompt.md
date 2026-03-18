## タスク定義

{{TASK_JSON}}

## Layer 1 テスト情報

テスト実行コマンド: `{{LAYER1_COMMAND}}`
テストタイムアウト: {{LAYER1_TIMEOUT}}秒

## 必須テスト振る舞い

{{REQUIRED_BEHAVIORS}}

## Mutation Audit フィードバック

{{MUTATION_FEEDBACK}}

## 追加コンテキスト

{{CONTEXT}}

## タスク: テスト強化

前回の実装とテストは正常に動作していますが、Mutation Audit でテストの検出力が不足していると判定されました。

### 制約
- 実装コード（src/ 配下）は変更しないでください
- テストコード（tests/ 配下）のみを修正・追加してください
- 修正後、全テストがパスすることを確認してください

### Mutation Audit フィードバックの読み方

上記「Mutation Audit フィードバック」セクションに、テストで検出できなかった変更（surviving mutant）が列挙されています。各項目は:
- **変更箇所**: 実装コードのどの行がどう変更されたか
- **意味**: なぜその変更がテストで検出されるべきか
- **対応するbehavior**: どの振る舞い定義に関係するか

各 surviving mutant に対して、その変更を検出できるアサーションを追加してください。

### テストフレームワーク検出（必須）

テストコードを修正する前に、以下の手順でプロジェクトのテストフレームワークを特定すること:

1. `package.json` の `devDependencies` / `dependencies` を確認する
2. 検出されたフレームワークに対応する API を使用する:

| フレームワーク | モック関数 | タイマー | テストランナー |
|---|---|---|---|
| vitest | `vi.fn()`, `vi.mock()` | `vi.useFakeTimers()` | `vitest run` |
| jest | `jest.fn()`, `jest.mock()` | `jest.useFakeTimers()` | `jest run` |
| mocha + sinon | `sinon.stub()` | `sinon.useFakeTimers()` | `mocha` |

CRITICAL: `jest.fn()` と `vi.fn()` を混同しないこと。フレームワークが vitest なら `vi.*`、jest なら `jest.*` を使うこと。

### テスト強化ルール

- surviving mutant の各項目に対応するアサーションを追加または強化する
- 各テストケースに `// behavior:` コメントを維持する
- アサーションは具体的な値を検証すること
  - NG: `expect(result).toBeTruthy()`
  - OK: `expect(result.status).toBe(201)`
- 既存テストのアサーションを強化する場合は、既存のテストが引き続きパスすることを確認する
- 新規テストケースを追加する場合は `// behavior: [強化]` コメントで surviving mutant との対応を明記する

### Layer 1 テスト実行

修正完了後、以下のコマンドでテストを実行してください:
```
{{LAYER1_COMMAND}}
```

全テストが通ったらテスト強化完了です。

### 出力

修正したテストコードをファイルとして出力してください。
説明テキストや前置きは不要です。
