## タスク定義

{{TASK_JSON}}

## Layer 1 テスト情報

テスト実行コマンド: `{{LAYER1_COMMAND}}`
テストタイムアウト: {{LAYER1_TIMEOUT}}秒

## 必須テスト振る舞い

{{REQUIRED_BEHAVIORS}}

## Layer 2 テスト情報

{{LAYER2_INFO}}

### Layer 2 テスト作成ガイドライン（定義がある場合のみ）

1. `validation.layer_2.command` が参照するテストファイルを作成する
2. サーバーは起動済みを前提としてよい（Phase 3 が管理）
3. テストは冪等であること（前後でデータ復元）
4. Layer 2 テスト実行はこのセッション内では不要（ファイル作成のみ）

## Investigator修正提案

{{INVESTIGATOR_FIX}}

## 追加コンテキスト

{{CONTEXT}}

## 変更スコープ制限（厳守）

### 変更禁止ファイル
以下のファイルは絶対に変更してはならない:
- package.json, package-lock.json（依存関係の変更は別タスクで行う）
- .env, .env.*（機密情報を含む）
- .git/, node_modules/（インフラファイル）
- *.lock（ロックファイル）

### 変更範囲
- 変更対象はタスクの description に記載されたファイルのみ
- 1タスクあたりの変更ファイル数は最大5ファイル
- description に記載されていないファイルの変更は禁止
- **必須**: 新規ファイルを作成した場合、そのファイルをエントリポイントに登録するための最小限の変更（import 追加 + ルートマウント/エクスポート追加等）は必ず行うこと（省略禁止）

## タスク

上記のタスク定義を実装してください。

### 実装手順

1. タスク定義の `description` を読み、実装の目的を理解する
2. `validation.layer_1` を読み、テストの合格基準を理解する
3. **「必須テスト振る舞い」を読み、テストがカバーすべき振る舞いを把握する**
4. 実装コードを書く
5. Layer 1 テストコードを書く（同一セッション内で。下記「テスト作成ルール」に従う）
6. Layer 2 テストコードを書く（可能な場合）
7. Layer 1 テストを実行し、通ることを確認する

### Investigator修正提案がある場合

上記の「Investigator修正提案」セクションに内容がある場合:
- 修正提案の内容を最優先で適用する
- 前回の実装の問題点を踏まえた上で実装する
- 同じ失敗を繰り返さないよう注意する

### テストフレームワーク検出（必須）

テストコードを書く前に、以下の手順でプロジェクトのテストフレームワークを特定すること:

1. `package.json` の `devDependencies` / `dependencies` を確認する
2. 検出されたフレームワークに対応する API を使用する:

| フレームワーク | モック関数 | タイマー | テストランナー |
|---|---|---|---|
| vitest | `vi.fn()`, `vi.mock()` | `vi.useFakeTimers()` | `vitest run` |
| jest | `jest.fn()`, `jest.mock()` | `jest.useFakeTimers()` | `jest run` |
| mocha + sinon | `sinon.stub()` | `sinon.useFakeTimers()` | `mocha` |

CRITICAL: `jest.fn()` と `vi.fn()` を混同しないこと。フレームワークが vitest なら `vi.*`、jest なら `jest.*` を使うこと。

### モノレポ対応

- モノレポ（workspace）プロジェクトの場合、cross-package import がある依存パッケージが workspace に宣言されていることを確認する
- 依存パッケージが未宣言の場合、`package.json` の `dependencies` に workspace 参照を追加する（例: `"@myorg/shared": "workspace:*"`）

### Playwright テスト構造ルール（E2E テスト作成時）

Playwright テストを書く場合は以下を厳守すること:

1. `test.describe()` のネストは1段まで。ネストした `test.describe()` 内にさらに `test.describe()` を置かない
2. `test.use()` は `test.describe()` の直下に配置する（`test()` の中には置かない）
3. **必須**: テストファイル作成後、必ず `npx playwright test --list <file>` を実行してパースエラーがないことを確認する。エラーが出た場合は必ず修正してから次に進む（無視禁止）
4. Playwright のバージョンは `package.json` で宣言されたものを使う（`@latest` をインストールしない）

### テスト作成ルール

#### behavior カバレッジ（最重要）

「必須テスト振る舞い」セクションに列挙された振る舞いは、全てテストケースとしてカバーすること。

各テストケースに以下のコメントで対応する behavior を明記する:
```
// behavior: 正しいメールとパスワードでサインアップ → 201 + userId返却
test('should return 201 with userId on valid signup', async () => {
  ...
});
```

- 必須テスト振る舞いの各項目に対して、最低1つのテストケースを書く
- コメントの behavior 文字列は、必須テスト振る舞いの文字列と完全に一致させる
- 必須テスト振る舞い以外の追加テストも歓迎する（その場合は `// behavior: [追加]` とする）

#### テスト品質ルール

- テスト名は「何を検証するか」を日本語コメントで明記する
- アサーションは具体的な値を検証すること
  - NG: `expect(result).toBeTruthy()` （何でも通る）
  - OK: `expect(result.status).toBe(201)` （具体値）
- ステータスコードは数値で明示的にアサーションする
  - NG: `expect(response.ok).toBe(true)` （200も201も通る）
  - OK: `expect(response.status).toBe(201)`
- レスポンスボディのキーフィールドもアサーションする
  - `expect(body).toHaveProperty('userId')`
- エラーレスポンスはステータスコードとエラーメッセージの両方を検証する
- エッジケースを最低1つ含める
- テストは決定的であること（同じ入力で毎回同じ結果）
- 外部サービスへの依存がある場合はモックを使用する

### Layer 1 テスト実行

実装完了後、以下のコマンドでテストを実行してください:
```
{{LAYER1_COMMAND}}
```

テストが通ったら実装完了です。

### Layer 3 受入テスト意識

タスク定義に `validation.layer_3` が含まれる場合:
- L3 テストの `definition.command` が何を検証するかを理解する
- structural テスト: 出力が期待する JSON スキーマに適合するよう実装する
- api_e2e テスト: API エンドポイントの連鎖が正しく動作するよう実装する
- llm_judge テスト: `judge_criteria` の各基準を意識した品質で出力を生成する
- L3 テストは実装後に自動実行される。L3 の command で参照されるエンドポイントやファイルは必ず作成すること
- L3 テスト自体のコードを書く必要はない（ハーネスが自動実行する）

### 出力

実装コードとテストコードをファイルとして出力してください。
説明テキストや前置きは不要です。
