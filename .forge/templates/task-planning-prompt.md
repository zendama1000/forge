## Implementation Criteria

{{CRITERIA_CONTENT}}

## リサーチテーマ

{{THEME}}

## 前提条件

{{ASSUMPTIONS}}

## 環境能力

{{ENV_PROBE}}

## Layer 2 Criteria（統合テスト定義）

{{L2_CRITERIA}}

L2 デフォルトタイムアウト: {{L2_DEFAULT_TIMEOUT}}秒

## タスク

上記の Implementation Criteria を実行可能なタスクスタック（task-stack.json）に分解してください。

### 出力スキーマ

以下の JSON スキーマに厳密に従うこと:

```json
{
  "source_criteria": "{{CRITERIA_PATH}}",
  "generated_at": "(ISO 8601 タイムスタンプ)",
  "phases": "(criteriaのphases配列をそのまま引き継ぐ。criteriaにphasesがない場合は省略可)",
  "tasks": [
    {
      "task_id": "(ケバブケース。例: setup-config)",
      "description": "(何を実装するかの明確な説明)",
      "task_type": "(setup | implementation | documentation)",
      "dev_phase_id": "(mvp | core | polish)",
      "depends_on": ["(依存タスクの task_id。なければ空配列)"],
      "status": "pending",
      "fail_count": 0,
      "validation": {
        "layer_1": {
          "command": "(テスト実行コマンド。下記ルール参照)",
          "timeout_sec": "(下記ガイドライン参照)"
        },
        "layer_2": {
          "command": "(L2テスト実行コマンド。テストファイルパスを含む。省略可)",
          "requires": ["(command を定義する場合は必須。語彙: server | env:VAR | cmd:NAME | file:PATH | browser | network | docker)"],
          "deferred": "(boolean 省略可。環境能力で実行不能な場合のみ true + deferred_reason 必須)",
          "deferred_reason": "(deferred:true の理由。省略可)",
          "timeout_sec": 120
        },
        "layer_3": [
          {
            "id": "(L3テストID。例: L3-concept-quality)",
            "strategy": "(structural | api_e2e | llm_judge | cli_flow | context_injection | agent_flow | browser)",
            "description": "(テストの説明)",
            "definition": {
              "command": "(データ取得・実行コマンド)",
              "judge_criteria": ["(llm_judge の場合の評価基準。他は省略可)"],
              "success_threshold": 0.7,
              "verify_command": "(追加検証コマンド。省略可)"
            },
            "instructions": "(browser strategy のみ: ブラウザで実行する操作/検証の自然言語指示。UI を持つプロジェクトかつ browser_testing 有効時のみ使用)",
            "requires": ["(必要な環境能力。語彙: server | env:VAR | cmd:NAME | file:PATH | browser | network | docker)"],
            "deferred": "(boolean 省略可。環境能力で実行不能な場合のみ true + deferred_reason 必須)",
            "deferred_reason": "(deferred:true の理由。省略可)",
            "blocking": true
          }
        ]
      },
      "l1_criteria_refs": ["(対応する layer_1_criteria の ID。必須。例: [\"L1-001\", \"L1-003\"])"],
      "l2_criteria_refs": ["(対応する layer_2_criteria の ID。省略可)"],
      "replaces": ["(このタスクが置換する旧ファイル/シンボル名。置換型タスクのみ。非空なら L1 に grep 配線検証必須)"],
      "required_behaviors": [
        "(criteria の behaviors から引き継いだ振る舞い定義。implementation タスクのみ必須)"
      ]
    }
  ],
  "scope_coverage": {
    "theme_elements": [
      {"element": "テーマから分解された要素", "mapped_tasks": ["task-id"]}
    ],
    "coverage_complete": true
  },
  "excluded_elements": [
    {"element": "除外要素", "reason": "除外理由", "suggested_phase": "future"}
  ]
}
```

## Layer 3 Criteria（受入テスト定義）

{{L3_CRITERIA}}

### L3 strategy 適合マトリクス（必須遵守 — 機械ゲート対象）

| 対象の性質 | 選ぶ strategy | 条件 |
|---|---|---|
| URL で開ける Web UI | browser | browser_testing 有効 かつ 環境能力タグに browser がある場合のみ |
| HTTP API | api_e2e | 環境能力タグに server がある場合のみ |
| Electron/デスクトップアプリ/外部プロセス/CLI | cli_flow（実効果スモーク） | **browser strategy は原理的に不適合（禁止）** — Playwright MCP は URL の Web ページしか操作できない |
| 出力構造の機械検証 | structural | 外部境界検証の「代替」に使ってはならない（補助のみ） |
| 品質のスコアリング | llm_judge | 同上（補助のみ） |

- 環境能力で満たせない検証: `deferred: true` + `deferred_reason` を設定し、**到達可能な最強ティアの代替検証を同タスクの layer_3 に必ず併設する**（deferred のみで検証ゼロのタスクは禁止）
- 検証ティア強度: browser / api_e2e（実物 E2E）＞ cli_flow 実効果スモーク ＞ structural ＞ ユニットテストのみ

### 外部境界タスクの実効果スモーク（必須）

外部境界（プロセス起動 / ネットワーク / ブラウザ制御 / ファイルシステム / 外部API）を実装するタスクには、「**実物を最小限に叩き、観測可能な副作用を assert する**」L3 検証を必ず1本定義すること。

- 例: ブラウザ制御実装 → 実際に headless 起動し title 取得 / exit code / 生成ファイルを検証する cli_flow
- 例: プロセス起動実装 → 実プロセスを起動し stdout / 生成物を検証
- NG 実例: navigate()/screenshot() が固定値を返すスタブ実装のままユニットテスト green で「完了」（過去の実害）
- 決定的スタブ・固定値返却を本実装として提出することは禁止（QA Evaluator が stub_suspected で fail させる）

### 分解手順

1. **L1 criteria 解析**: Implementation Criteria の各成功条件（L1-001, L1-002, ...）を全て列挙する
2. **タスク化**: 各条件を1つ以上の実装タスクに変換する
   - 粒度: 1タスク = 1セッション（5-10分）で実装可能
   - 1タスク = 1責務
   - **全 L1 ID が少なくとも1つのタスクの `l1_criteria_refs` に含まれること（機械チェック対象）**
3. **実装とテストの統合（重要）**: 実装タスクとテスト作成タスクを分離しない。1つのタスクで実装コード＋テストコードの両方を生成する
   - NG: `impl-auth-handlers` と `write-auth-tests` を別タスクにする
   - OK: `impl-auth`（実装＋テスト込み）を1タスクにする
4. **依存関係定義**: タスク間の depends_on を設定する
   - 基盤（設定/型定義/共通関数）→ 個別実装 → 統合
5. **順序付け**: depends_on を考慮し、並列実行可能なタスクを最大化する
6. **テスト定義**: 各タスクに layer_1（必須）と layer_2（可能なら）を定義する
7. **behaviors 引き継ぎ（重要）**: criteria の各 L1 基準に含まれる behaviors を、対応するタスクの required_behaviors フィールドに引き継ぐ
8. **モノレポ依存**: cross-package import がある場合、依存元パッケージの設定タスクを先行させること
9. **dev-phase割り当て**: criteriaの phases[].criteria_refs を使い、タスクの対応する layer_1_criteria がどの dev-phase に属するかを判定し、各タスクに dev_phase_id を割り当てる
10. **MVP優先順序**: タスクは mvp → core → polish の順に配置する。同一 dev-phase 内では depends_on による順序を優先する
11. **phases引き継ぎ**: criteria の phases 配列をそのまま出力JSONの "phases" フィールドに含める
12. **スコープカバレッジ検証（重要）**: テーマの全要素がタスクでカバーされていることを確認する
    - テーマを離散的な要素（機能、コンポーネント、非機能要件）に分解する
    - 各要素が少なくとも1つのタスクにマッピングされていることを確認する
    - 意図的に除外した要素は `excluded_elements` に理由とともに記録する
    - この検証結果を `scope_coverage` フィールドに記録する
13. **Layer 2 マッピング**: criteria の `layer_2_criteria[]` を対応タスクにマッピングする
    - 各 L2 基準を最もスコープが近い implementation タスクの `validation.layer_2` に設定
    - `l2_criteria_refs` に対応 L2 ID を記録
    - **`layer_2.command` を定義する場合、`requires` は必須**（機械ゲート対象）。語彙: `"server"`, `"env:VAR"`, `"cmd:NAME"`, `"file:PATH"`, `"browser"`, `"network"`, `"docker"`
    - 環境能力で充足できない requires を持つ L2 は `deferred: true` + `deferred_reason` を設定し、到達可能な代替検証を layer_1/layer_3 に併設する
    - layer_2_criteria がない場合はスキップ
14. **Layer 3 マッピング**: criteria の `layer_3_criteria[]` を対応タスクにマッピングする
    - 各 L3 基準を最もスコープが近い implementation タスクの `validation.layer_3[]` に設定
    - L3 テスト定義の各項目: `id`, `strategy`（strategy_type の値）, `description`, `definition`（command 等）
    - `requires: ["server"]` を含む L3 テストは Phase 3 で実行される（per-task では実行されない）
    - `blocking: true`（デフォルト）の場合、失敗時は Investigator に回送
    - `blocking: false` の場合、記録のみ（advisory）
    - llm_judge 戦略は `definition.judge_criteria` と `definition.success_threshold` が必須
    - strategy 選択は上記「L3 strategy 適合マトリクス」に厳密に従うこと
    - layer_3_criteria がない場合はスキップ
15. **Walking Skeleton 対応**: criteria の各 phase の exit_criteria のうち `kind: "walking_skeleton"` の項目（実ユーザーシナリオ1本の end-to-end 検証）が、そのフェーズのタスク群完了時に成立するよう、シナリオ経路上の全コンポーネントを繋ぐタスクを必ず配置すること。ユニットが揃っていてもシナリオが通らない分解は不合格

### タスク粒度制限（Implementer タイムアウト対策）

1. **対象ファイルサイズ上限**: 1タスクが変更する既存ファイルが500行を超える場合、
   タスクを分割すること（新規関数の追記のみの場合は例外）
2. **リファクタリング分割ルール**: 300行以上のファイルのリファクタリングは
   「1関数抽出/タスク」に分解する（forwarding stub + 新関数 + テスト）
3. **コンテキスト予算**: タスク遂行に必要な読解対象ファイルの合計行数が
   800行を超えないようにする
4. **description 必須記載**: 対象ファイルの推定行数を description に含める
   （例: 「ralph-loop.sh（~1400行）の run_task() から task_prepare() を抽出」）

### task_type の分類と validation ルール（重要）

各タスクに task_type を割り当て、validation ルールを適用する:

**setup（セットアップ系）:**
- ファイル/ディレクトリ作成、設定ファイル配置が目的のタスク
- validation: `test -f` / `test -d` + ビルド検証（`tsc --noEmit` 等）の併用を推奨
- required_behaviors: 不要
- 例: `init-monorepo`, `setup-eslint-prettier`, `setup-vitest-config`

**implementation（実装系）:**
- アプリケーションコードとテストコードを生成するタスク
- validation: テストフレームワーク実行コマンド必須（vitest / jest / pytest 等）
- required_behaviors: 必須（criteria の behaviors を引き継ぐ）
- `test -f` のみの validation は禁止
- 例: `impl-auth`, `impl-rate-limiter`, `impl-schema-validation`

**documentation（ドキュメント系）:**
- README、API仕様書、デプロイメントガイド等
- validation: `test -f` 許容
- required_behaviors: 不要

### validation コマンドの記述ルール

**全 validation コマンド（layer_1 / layer_2 / layer_3 の command・verify_command、exit_criteria の command）は生のシェルコマンドで書くこと。`bash -c "…"` ラッパーは全タスク種別で禁止。**
ハーネスが実行時に `bash -c "cd <work_dir> && <command>"` で包むため、二重ラップは内側の引用符・`$変数` を外側シェルが先に解釈して破壊する（実害: 1 タスク 15 連続失敗）。`&&` で繋ぐ複合コマンドはそのまま書いてよい。

**implementation タスクの validation:**
- テストフレームワーク実行コマンドを使用すること（必須）
- テストコマンドは Implementer が同一タスク内で作成するテストファイルを実行するもの
- `test -f <ファイル>` のみの validation は implementation タスクでは禁止

```
NG (bash -c ラッパー — 全タスク種別で禁止):
  "command": "bash -c \"test -f package.json && npx tsc --noEmit && echo OK\""

NG (implementation タスク — ファイル存在チェックのみ):
  "command": "test -f apps/api/src/routes/auth.ts && echo OK"

OK (implementation タスク):
  "command": "npx vitest run tests/unit/auth.test.ts"

OK (setup タスク — 生の複合コマンド):
  "command": "test -f package.json && test -f tsconfig.json && npx tsc --noEmit && echo OK"
```

### required_behaviors の引き継ぎルール

1. criteria の各 L1 基準が持つ behaviors をタスクに紐付ける
2. 1つの L1 基準の behaviors が複数タスクに分割される場合、各タスクに対応する behaviors のサブセットを割り当てる
3. 全ての behaviors がいずれかのタスクに割り当てられていること（漏れ禁止）
4. required_behaviors の各項目は criteria の behaviors と同一の文字列であること（改変禁止）

```json
// criteria の L1-005 に behaviors が5つある場合:
// タスク impl-auth-signup に3つ、タスク impl-auth-login に2つを割り当てる
{
  "task_id": "impl-auth-signup",
  "required_behaviors": [
    "正しいメールとパスワードでサインアップ → 201 + userId返却",
    "既存メールでサインアップ → 409 Conflict",
    "パスワード8文字未満でサインアップ → 400 Bad Request"
  ]
},
{
  "task_id": "impl-auth-login",
  "required_behaviors": [
    "正しい認証情報でログイン → 200 + JWTトークン返却",
    "間違ったパスワードでログイン → 401 Unauthorized"
  ]
}
```

### プラットフォーム互換ルール

CRITICAL: validation コマンドはクロスプラットフォーム互換であること:

1. **正規表現にパス区切りを含めない**: testPathPattern 等の正規表現引数にディレクトリ区切り（`/` や `\`）を含めないこと
   - NG: `npx jest --testPathPattern='api/streaming'`
   - OK: `npx jest --testPathPattern='streaming'`
   - ファイル名部分のみを使用する

2. **作業ディレクトリ**: 全コマンドは `{{WORK_DIR}}` で実行される
   - パスはこのディレクトリからの相対パスで記述する

3. **バックグラウンドプロセス禁止**: Layer 1 テストで `&` やプロセス管理を使わないこと
   - NG: `node server.js & sleep 3 && curl {{SERVER_URL}} && kill $!`
   - OK: `npx jest --testPathPattern='server'`（テストフレームワーク内でライフサイクル管理）
   - サーバ起動テストは Layer 2 に配置する

4. **ファイル存在確認**: `test -f` で相対パスを使う場合、パス区切りは `/` で統一（Git Bash 互換）

### validation.layer_*.timeout_sec のガイドライン

各 validation の Layer（layer_1 / layer_2 / layer_3 items）に `timeout_sec`（任意・整数 10-3600）を設定可能。

#### 3段階大分類（ロック決定: 短時間 / 回帰系 / 長時間処理）

| 大分類 | テスト種別の例 | timeout_sec 目安 |
|--------|---------------|-----------------|
| 短時間検証 | `test -f`, `jq -e`, schema validation, lint, 構造チェック | 60-120 |
| 回帰系テスト | `vitest run`, `jest`, `pytest`, `run-all-tests.sh`, 単体テストスイート | 600-1800 |
| 長時間処理 | 実装系, 大規模ビルド, e2e フル, mutation audit, agent_flow | 1800-3600 |

#### 詳細マトリクス（テスト種別ごとの推奨値）

システム L1 デフォルト: {{L1_DEFAULT_TIMEOUT}}秒、システム L3 デフォルト: 120秒。

| テスト種別 | 推奨 timeout_sec | 大分類 |
|-----------|-----------------|--------|
| vitest / jest | 120〜200 | 回帰系 |
| pytest | 120〜200 | 回帰系 |
| tsc --noEmit | 60 | 短時間検証 |
| test -f | 10 | 短時間検証 |
| curl / HTTP | 30〜60 | 短時間検証 |
| run-all-tests.sh | 600〜1800 | 回帰系 |
| Implementer 実装系 | 1800〜3600 | 長時間処理 |
| mutation audit | 1800〜3600 | 長時間処理 |

#### ルール

- テストフレームワーク（vitest/jest/pytest）を使う implementation タスクでは 60秒未満を設定しないこと
- timeout_sec 省略時はシステムデフォルトが使用される（L1={{L1_DEFAULT_TIMEOUT}}, L3=120）
- minimum=10, maximum=3600 の範囲外は schema validation で拒否される
- 実コード上は整数バリデーション（regex `^[0-9]+$`）も走るため、文字列型・空文字列は防御的にデフォルトへフォールバックする
- layer_3 items にも独立して timeout_sec が設定可能（per-test 単位の動的読み取り）

### ルール

- task_id はケバブケースで一意であること
- description は「何を実装するか」を具体的に記述すること（「〜を実装する」形式）
- task_type は必須（"setup" / "implementation" / "documentation" のいずれか）
- implementation タスクの validation.layer_1.command はテスト実行コマンド必須（test -f 禁止）
- implementation タスクの required_behaviors は必須（criteria の behaviors を引き継ぐ）
- depends_on に存在しない task_id を参照しないこと
- 全タスクの status は "pending"、fail_count は 0 で初期化すること
- dev_phase_id は必須（"mvp" / "core" / "polish" のいずれか）。criteria に phases がない場合は全タスクを "mvp" とする
- タスク順序は dev_phase_id 順（mvp → core → polish）を優先する
- **配線検証（置換型タスク）**: 既存ファイル/シンボルを新実装で置き換えるタスクは、`replaces` に旧名を列挙し、layer_1.command に配線検証を含めること（機械ゲート対象）:
  - 旧名の残存なし: `! grep -rn "旧名" src/`
  - 新名の被参照あり: `grep -rln "新実装名" src/ | grep -v 新実装ファイル自身`
  - 過去の実害: 新設ファイルが consumer から参照されず死蔵したまま「8/8 完了」報告された

### 出力

以下のルールに厳密に従うこと。違反した場合は処理が失敗する。

## 出力形式（厳守 — 機械パーサー直結）

あなたの出力は **jq コマンドで直接パースされる**。人間が読むものではない。

1. 最初の文字は `{` であること（空白・改行すら不可）
2. 最後の文字は `}` であること
3. コードフェンス（```）を絶対に含めない
4. JSON の前後に説明テキスト・コメントを絶対に含めない
5. JSON 内部のコメントも不可（JSON 仕様にコメントは存在しない）
6. 出力全体が `jq empty` で検証される

出力例（先頭と末尾のみ）:
{"source_criteria": "...", "generated_at": "...", "tasks": [...]}
