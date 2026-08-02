## 受入契約の執筆

タスクID: {{TASK_ID}}

あなたはこのタスクの実装を今完了した。次に、**自分が実際に作った実物**に基づいて、
このタスクの受入契約（validation）を執筆する。

原則: **契約は実装の現実から書く。あるべき姿から書かない。**
あなたが定義したコマンドは、この直後にハーネスが機械実行する。実在しないフラグ・
未実装のスクリプト・存在しないファイルを参照した契約は、そのままタスク失敗になる。

## タスク定義

{{TASK_JSON}}

## このタスクで実際に変更されたファイル

{{CHANGED_FILES}}

## 対応する成功条件（criteria 抜粋）

### L1（構造・ユニットレベル）
{{L1_CRITERIA_EXCERPT}}

### L2（統合レベル — Phase 3 で実行）
{{L2_CRITERIA_EXCERPT}}

### L3（受入レベル）
{{L3_CRITERIA_EXCERPT}}

## 環境能力

{{ENV_PROBE}}

## 既存の validation（あれば維持・統合すること）

{{EXISTING_VALIDATION}}

## 執筆ルール

### validation.checks（L1/L2 — 型付き形式で書く）

| verb | 用途 | 必須フィールド | PASS 条件 |
|---|---|---|---|
| `file_exists` | 成果物の存在 | `paths[]`（WORK_DIR 相対・末尾 `/` はディレクトリ） | 全パス存在 |
| `grep_ref` | 配線/被参照/旧名不在 | `pattern`(ERE), `paths[]`（`expect_absent:true` で不在検証） | ≥1 パスでヒット（absent は全不在） |
| `run_test` | テスト FW 実行 | `runner`(vitest\|jest\|pytest\|playwright\|node-test\|go-test\|cargo-test\|tsc\|eslint\|biome), `args[]` | exit 0 |
| `http_check` | API 挙動 | `url_path` or `url`。任意: `method`/`expect_status`/`body_jq` | status 一致 + body_jq 成立 |
| `effect_smoke` | 実効果スモーク | `argv[]`。任意: `expect.exit_code`/`expect.stdout_contains`/`expect.creates_files[]` | expect 全成立 |
| `raw_shell` | 最終手段 | `shell`, `reason`（必須） | exit 0（品質債務として記録される） |

- `args` / `argv` は argv 要素の配列。クォート・`&&`・パイプを要素内に書かない
- `paths` は WORK_DIR 相対のみ（絶対パス・`..`・グロブは reject）
- layer:1 の checks に `server` / `env:` 系 requires を付けない（L1 に defer 経路なし — サーバー依存は layer:2 へ）
- `http_check` は暗黙で server 能力を要求 — 環境能力に server がある場合のみ
- **run_test が参照するテストファイルは、実装セッションで自分が作ったものを指すこと**
- **置換型タスク（replaces 非空）は grep_ref を必ず含める**: 旧名の残存なし（expect_absent）+ 新名の被参照あり
- implementation タスクは run_test か effect_smoke を最低1つ含める（file_exists 単体は禁止）

### validation.layer_3[]（受入テスト — strategy 配列）

タスクの `l3_criteria_refs` に列挙された各 L3 criteria を、以下の strategy 適合マトリクスに従って materialize する:

| 対象の性質 | 選ぶ strategy | 条件 |
|---|---|---|
| URL で開ける Web UI | browser | browser_testing 有効 かつ 環境能力タグに browser がある場合のみ |
| HTTP API | api_e2e | 環境能力タグに server がある場合のみ |
| Electron/デスクトップ/外部プロセス/CLI | cli_flow（実効果スモーク） | **browser strategy は原理的に不適合（禁止）** |
| 出力構造の機械検証 | structural | 外部境界検証の「代替」に使わない（補助のみ） |

- **決定論 strategy（cli_flow / api_e2e / structural / browser）を優先する。llm_judge は決定論的に検証不能な品質基準にのみ使う（judge_criteria + success_threshold 必須）**
- `definition.command` には**自分が実装した実際の CLI / エントリポイントをそのまま**書く（実装に無いフラグを発明しない）
- 環境能力で満たせない検証: `deferred: true` + `deferred_reason` + **到達可能な最強ティアの代替検証を併設**（deferred のみで検証ゼロは禁止）
- `requires` 語彙: `server` | `env:VAR` | `cmd:NAME` | `file:PATH` | `browser` | `network` | `docker`
- `blocking: true`（既定）= 失敗時 Investigator 回送

### 外部境界タスクの実効果スモーク（必須）

外部境界（プロセス起動/ネットワーク/ブラウザ/FS/外部API）を実装した場合、「実物を最小限に叩き、観測可能な副作用を assert する」検証を必ず1本定義する（例: headless 起動して title/exit code/生成ファイルを確認する cli_flow）。

### コマンド記述ルール

- 生のシェルコマンドで書く。`bash -c "…"` ラッパー禁止（ハーネスが実行時に包むため二重ラップは引用符を破壊する）
- パスは WORK_DIR 相対・区切りは `/`（Git Bash 互換）
- 正規表現引数にパス区切りを含めない
- バックグラウンドプロセス（`&`）禁止 — サーバー依存は layer:2 / requires:["server"] へ

### timeout_sec ガイドライン

| テスト種別 | 推奨 timeout_sec |
|-----------|-----------------|
| file_exists / grep_ref / 構造チェック | 30-60 |
| vitest / jest / pytest | 120-200 |
| tsc --noEmit | 60 |
| effect_smoke / cli_flow | 120-300 |
| e2e / agent_flow | 600-1800 |

範囲は 10-3600。省略時はシステムデフォルト（L1={{L1_DEFAULT_TIMEOUT}}, L3=120）。

## 出力形式（厳守 — 機械パーサー直結）

以下の形の JSON **のみ**を出力する:

{"validation": {"checks": [...], "layer_2": {...または省略}, "layer_3": [...]}}

1. 最初の文字は `{`、最後の文字は `}`
2. コードフェンス・説明テキスト禁止
3. 出力は jq で直接パースされ、そのまま task-stack.json に書き込まれて機械実行される
