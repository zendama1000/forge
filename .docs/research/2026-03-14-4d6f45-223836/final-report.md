# Forge Harness v3.2 全体最適化 — 最終リサーチレポート

> **リサーチID**: `2026-03-14-4d6f45-223836`
> **テーマ**: 信頼性・保守性重点、マクロ→ミクロ網羅分析、言語移行含む最新技術検討
> **調査日**: 2026-03-14

---

## 目次

1. [調査設計](#1-調査設計)
2. [視点別調査結果](#2-視点別調査結果)
   - 2.1 技術的実現性
   - 2.2 開発者体験
   - 2.3 代替案・競合比較
   - 2.4 Claude API 進化活用
   - 2.5 コスト・リソース
   - 2.6 リスク・失敗モード
3. [統合分析（Synthesis）](#3-統合分析)
4. [視点間の矛盾と解決](#4-視点間の矛盾と解決)
5. [過去決定との整合性](#5-過去決定との整合性)
6. [推奨アクション](#6-推奨アクション)
7. [実装基準（Implementation Criteria）](#7-実装基準)
8. [残存ギャップ](#8-残存ギャップ)

---

## 1. 調査設計

### 1.1 コアクエスチョン（7問）

| ID | テーマ |
|----|--------|
| CQ1 | Bash 6,019行が信頼性・保守性のボトルネックか。言語移行の定量的トレードオフは |
| CQ2 | Phase間連携（forge-flow→research-loop→generate-tasks→ralph-loop）の最大ボトルネックはどこか |
| CQ3 | common.sh（28関数）、13プロンプトテンプレート、4設定ファイルのうち最高ROI改修対象は |
| CQ4 | Claude API新機能（構造化出力/Extended Thinking/Agent SDK/Prompt Caching）の活用余地は |
| CQ5 | 状態管理（JSONL×5 + task-stack + progress + heartbeat）と障害復旧の信頼性ギャップは |
| CQ6 | テストスイート（15スクリプト/113KB）のカバレッジギャップは。特にresearch-loop E2E未カバー |
| CQ7 | 12エージェント・13テンプレートの構造的重複・保守コスト削減の余地は |

### 1.2 検証された前提（8項目）

| ID | 前提 | 検証結果 |
|----|------|----------|
| A1 | 「Bashが信頼性の主因」 | **部分的に正しい** — Bash固有制約が5関数で障害事例と1:1対応。ただしLLM出力不確実性との複合 |
| A2 | 「言語移行で保守性向上」 | **条件付き** — 70-90%のWindows制約解消可能だが、外部コマンド呼出し時のMSYSパス問題は残存 |
| A3 | 「Claude CLI経由が最適」 | **否定的** — CLI依存で複数の既知問題（hang、work_dir不可、高頻度更新による破壊的変更） |
| A4 | 「12エージェント構成が最適」 | **未検証** — 重複候補あるが本リサーチのスコープ外 |
| A5 | 「parallel_researchers=6が最適」 | **リスクあり** — 全6体同時失敗→False Positive ABORTの実測事例あり |
| A6 | 「JSON Schema検証で十分」 | **不十分** — セマンティック妥当性（L1コマンドの実行可能性等）は未検証 |
| A7 | 「git stashベースの復旧が堅牢」 | **条件付き** — Windowsファイルロック、stash競合は潜在リスク |
| A8 | 「速度・コストは副次的」 | **見直し推奨** — API呼出回数削減は信頼性向上と直結 |

### 1.3 調査視点（6視点）

| 視点 | フォーカス | 種別 |
|------|-----------|------|
| Technical | 言語移行・API進化・アーキテクチャ改善の実装可能性 | 固定 |
| Cost | 改善施策の工数・API費用・移行コスト | 固定 |
| Risk | 改善施策のリスクと既存障害モードの体系的分析 | 固定 |
| Alternatives | ロック決定範囲内での最適選択肢比較 | 固定 |
| Developer Experience | 日常運用の認知負荷・操作効率・拡張容易性 | 動的 |
| Claude API Evolution | 最新API機能による構造的改善 | 動的 |

---

## 2. 視点別調査結果

### 2.1 技術的実現性（Technical）

#### T1: Bash固有制約による障害関数の特定

common.shの**5関数**がBash固有制約で実際の障害事例と1:1対応:

| 関数 | 行数 | 障害事例 | 根本原因 |
|------|------|----------|----------|
| `jq_safe()` | L61-63 | CRLF比較失敗（サイレント） | Windows Git Bashでjq -rが全行末に`\r`付加 |
| `validate_json()` | L239-326 | parse失敗 87行4層リカバリ | LLM出力不確実性 + 型安全性の欠如 |
| `run_claude()` | L75-176 | パス迷子問題 | subshell `cd`で相対パスが迷子に |
| `.pending`昇格 | L119-170 | 非JSON出力の昇格漏れ | Bashにオブジェクト返却がなく、stdout+filesystem二重管理 |
| `resolve_errors()` | L330-351 | O(n)全行走査 | indexed update不可、全状態操作がファイル経由 |

**信頼度**: 高

#### T2: Claude API直接呼出しへの移行効果

- **Structured Outputs（GA）**: constrained decodingにより**スキーマ違反は原理的に発生しない**
- `validate_json()`の4層リカバリは**JSON返却エージェント限定で不要に**
- `run_claude()`は8引数→**5引数に簡素化**可能（output_file、.pending昇格、work_dir等が消滅）
- **制約**: Implementer/Investigator/Fixerはツール実行エージェントのためAPI直接移行のメリットが薄い
- 現CLI `--json-schema`は既に部分的にStructured Outputsを活用中（common.sh L107-112）

#### T3: run_task()の複雑度分解

| 項目 | 値 |
|------|----|
| 行数 | 145行（L598-742） |
| ステップ数 | 15 |
| 分岐点 | 7箇所 |
| 推定CC | 8〜9（高複雑度） |

**推奨アプローチ**: Pipeline/Chain-of-Responsibilityパターンで5関数に分解:
`prepare_task` → `execute_agent` → `validate_output` → `run_tests` → `finalize_task`

#### T4: JSONL→SQLite移行の評価

| 軸 | 現状(JSONL) | SQLite |
|----|-------------|--------|
| クエリ性能 | O(ファイルサイズ)全体書き戻し | O(1)インデックス使用 |
| 並行アクセス | 競合リスク（flock無し） | WALモード + ロックタイムアウト |
| 障害復旧 | `.tmp`+`mv`パターン | ACID保証、自動ロールバック |
| git追跡 | 差分可視 | バイナリで不可 |

**結論**: 現規模（455KB、~20タスク/セッション）では**オーバーキルの可能性**。flock+部分更新の最適化が先。

#### T5: Windows Git Bash制約の言語移行による解消度

| 制約 | Python解消度 | Node.js解消度 |
|------|-------------|--------------|
| /tmpパス問題 | **完全** (`tempfile.mkdtemp()`) | **完全** (`os.tmpdir()`) |
| CRLF問題 | **完全** (`json.loads()`直接) | **完全** |
| プロセス管理 | **大幅改善** (ProactorEventLoop) | **安定** (`child_process.spawn()`) |
| MSYSパス変換 | **部分残存** (外部コマンド呼出時) | **部分残存** |

---

### 2.2 開発者体験（Developer Experience）

#### DX1: デバッグ体験の問題

- 障害の根本原因特定に**最低5〜7ステップ**の手動クロスファイル参照が必要
- `errors.jsonl`全107件で**resolution=null**のまま
- ログ間に**トレースIDが存在しない**（日時目視合わせのみ）
- ログ分散: forge-flow.log + JSONL 8種 + エージェント別デバッグログ = **計9種類**

**改善策**: トレースID（SESSION_ID + CALL_ID）導入で**1〜2ステップに削減可能**

#### DX2: エージェント追加の手順複雑度

新規エージェント追加に必要な変更: **最低5ファイル、実用的には7〜9ファイル**

1. `.claude/agents/<name>.md`（システムプロンプト）
2. `.forge/templates/<name>-prompt.md`（テンプレート）
3. `.forge/schemas/<name>.schema.json`（出力スキーマ）
4. ループスクリプト内のハードコード追加
5. 設定ファイルへのモデル・タイムアウト追加
6. `test-config-integrity.sh`へのテスト追加
7. `forge-structure.md`エージェント一覧更新

**問題**: エージェントリストが全てシェルスクリプト内にハードコード。自動登録メカニズムなし。

#### DX3: 設定変更の安全性

| リスク | 事例 |
|--------|------|
| server.start_command不整合 | 前プロジェクト設定のまま→core回帰テスト失敗→ロールバック→中断 |
| timeout_sec設定ミス | 1800sで3回連続タイムアウト→.pending空→削除→リトライの無限ループ |
| セマンティック検証なし | `test-config-integrity.sh`は構造検証のみ。コマンド存在確認やモデル名検証なし |
| dry-run機能なし | 設定変更は次回実行に即時反映。フェーズ途中の変更は状態不整合リスク |

---

### 2.3 代替案・競合比較（Alternatives）

#### A1: 言語移行候補比較

| 軸 | Python | Node.js/TypeScript | Deno |
|----|--------|-------------------|------|
| Claude SDK | 公式SDK（同期/非同期） | 公式SDK（Node/Deno/Bun対応） | 公式SDKの対象ランタイム |
| JSON処理 | jsonschema + Pydantic | ajv（最速） | npm:スペシファイア経由 |
| プロセス管理 | asyncio（ProactorEventLoop要） | child_process（Windows最安定） | Deno.Command API |
| テスト | pytest（最成熟） | vitest/jest（ESM必須） | Deno.test()組込み |
| Windows互換 | 良好（一部フラグ要） | **最安定** | ARM正式対応（Git Bash実証少） |

**結論**: **Node.js/TypeScriptが最もバランスが良い**。Windows安定性、Agent SDK完全対応、AsyncLocalStorageによるコンテキスト伝播が優位。

#### A2: Claude CLI代替パターン比較

| 機能 | (a) CLI維持+強化 | (b) SDK直接呼出 | (c) Agent SDK |
|------|-----------------|----------------|--------------|
| モデル指定 | `--model` | `model`パラメータ | `model`オプション |
| スキーマ検証 | `--json-schema` + validate_json | Pydantic/ajv（型安全） | `output_format`（強制） |
| work_dir | subshellでcd（現workaround） | 自前実装要 | **`cwd`パラメータ** |
| コスト追跡 | 未取得 | `response.usage` | **`total_cost_usd`** |
| stop_reason | stdout末尾パース（不安定） | `response.stop_reason` | `ResultMessage`付与 |
| 出力パース | jq/validate_json | 型付きオブジェクト | typed AsyncGenerator |

**結論**: **Agent SDKが8機能全てをネイティブAPIで実現可能**。ただしCLIサブプロセスラッパーのため、CLI依存は本質的に解消されない。

#### A3: 状態管理の代替

- **(a) JSONL維持+強化**: 現規模で十分。flock追加+クエリ関数キャッシュ化で改善可能
- **(b) SQLite移行**: 大量タスク（数百件~）で有利だが、Bashからの操作が煩雑
- **(c) イベントソーシング**: 現JSONLをそのまま活用可能。スナップショット機構追加で実用的

**推奨**: 現規模では**(a) JSONL維持+強化**が適切

#### A4: テスト戦略の代替

- **bats-core**: TAP準拠だが**Windows Git Bash上の互換性問題が未解決**
- **現状Bashテスト拡充**: 外部依存ゼロ、最小コスト
- **言語移行先のフレームワーク**: pytest/vitestは最強だが移行コスト前提

**結論**: 現環境では**Bashテスト拡充**が安全。bats-coreはGit Bash互換性検証後に再判断。

---

### 2.4 Claude API進化活用

#### API1: Structured Outputs（GA）

- **constrained decoding**によりトークン生成レベルでスキーマ準拠を強制
- `run_claude→.pending→validate_json→昇格`パイプラインは**JSON返却エージェントで不要に**
- validation-stats.jsonlの**377件の失敗をほぼ全て排除可能**
- 最も即効性の高い改善

#### API2: Extended Thinking

- DA/Evidence DA/Investigatorの**判断根拠を構造的に可視化**
- Interleaved Thinking（ツール呼出間の思考継続）が多段階調査エージェントに有効
- Adaptive Thinking（Opus 4.6）で問題の複雑さに応じた自動調整
- **注意**: Claude 4モデルでは要約されたthinkingのみ返却。課金は完全思考トークン数ベース

#### API3: Claude Agent SDK

| 既知課題 | SDK改善度 |
|---------|-----------|
| work_dir問題 | **完全解決** (`cwd`パラメータ) |
| コスト追跡 | **大幅改善** (`total_cost_usd`、モデル別内訳) |
| 並行実行制御 | **改善** (サブエージェント宣言的定義) |

**障壁**: Bash全体をPython/TSに書き換える大規模移行コスト

#### API4: Prompt Caching

| 適用対象 | キャッシュ効果 |
|---------|---------------|
| エージェント定義12体（システムプロンプト） | **60〜85%コスト削減** |
| Researcher 6体×3ラウンド=18回 | 約**84%削減** |
| Synthesizer（大量入力受信） | **最高優先度** |

**前提**: CLI(-p)ベースでは自動キャッシュ適用不可。API直接呼出しへの変更が必要。

---

### 2.5 コスト・リソース

#### C1: 言語移行の工数見積もり

| 項目 | Python | TypeScript |
|------|--------|-----------|
| 移植工数 | 60〜120開発日 | 80〜150開発日 |
| Strangler Pattern | +20〜40%工数だがリスク分散 | 同上 |
| Big Bang | 2〜4ヶ月集中だが完全停止リスク | 同上 |
| AIアシスト活用 | 30〜50%削減可能 | 同上 |

#### C2: API費用構造

- metrics.jsonl: **981レコード**（ただし**トークン数・費用額が未記録**で実額算出不能）
- モデル配置: Researcher=Sonnet ($3/$15/MTok)、判断系=Opus ($5/$25/MTok)
- **Prompt Caching適用で50〜70%削減見込み**（システムプロンプトのみで20〜40%）

#### C3: テスト投資vs障害対応コスト

- investigation-log.jsonl: **54〜55件**の調査記録
- 主要パターン: vitestコマンド不在/PATH問題（~15件）、Implementerハルシネーション（~8件）
- research-loop.sh E2E構築コスト: **3〜5開発日**
- E2Eが存在していれば早期発見できたパターン: 推定**20〜25件**

#### C4: プロンプトテンプレート管理

- 現状render_template()の置き換えROIは**低い**
- promptfooは**評価・テストツール**であり、レンダリングエンジンの代替にならない
- 言語移行時にJinja2/Handlebarsに統合するのが合理的

#### C5: Evolve Harnessとの共通基盤

- 共有コンポーネント3層（ライブラリ/ループ/エージェント）
- 自動同期メカニズム**なし**（Gitサブモジュール等なし）
- 月あたりの同期工数: **1.5〜3時間**
- common.sh変更の手動伝播コスト: **30〜60分/件**

---

### 2.6 リスク・失敗モード

#### R1: errors.jsonl 106件のパターン分析

| カテゴリ | 件数 | 割合 |
|---------|------|------|
| Claude実行エラー | 63件 | 59% |
| 出力が不正なJSON | 29件 | 27% |
| 出力が空 | 6件 | 6% |
| その他 | 8件 | 8% |

**新規発見された障害モード**:

| ID | 障害モード | 詳細 |
|----|-----------|------|
| A | CLIクラッシュループ | 7件のエラーが<1分で発生。実行時間1〜2秒（通常100-300秒）= CLI起動時に即座に終了 |
| B | 全Researcher空出力ABORT | 6体全員が空出力→自動ABORT。**一時的API障害を永続的失敗として扱う** |
| C | blocked_criteria構造問題 | ESLintサブプロセスの副作用ファイルがファイル変更カウントを超過→criteria満足が構造的に不可能 |
| D | task-planner JSON失敗連鎖 | 同一根本原因で3回全てが無駄にリトライ |

#### R2: Strangler Pattern適用時の半完成状態リスク

1. **デュアルメンテナンス倍増**: Bash+Python/Node.js両スタック並行維持
2. **エラー伝播の断絶**: Python/Node.jsのスタックトレースがBash側に到達しない
3. **環境変数漏洩**: CLAUDE_*変数の親→子プロセス継承による干渉
4. **半完成状態のgitコミット**: ロールバック時にどちらのランタイムが必要か不明瞭に
5. **プロキシレイヤーSPOF**: ルーティング層がSingle Point of Failure化

#### R3: Claude CLI依存リスク

| リスク | 深刻度 | 詳細 |
|--------|--------|------|
| -pモードhang | 高 | macOS M1で無限ハング（Issue #24481） |
| --cwdフラグ欠如 | 中 | stale判定・low priority（Issue #26287）。workaround適用済み |
| Windows ARM64問題 | 中 | -pモード完全失敗（Issue #20623） |
| 高頻度破壊的変更 | 中 | 4ヶ月で80+リリース。バージョンピン留めなし |
| レートリミットカスケード | 高 | **指数バックオフ未実装**。即時再試行→追加429エラーの悪循環 |

#### R4: circuit-breaker閾値の問題

- `max_consecutive_failures`フィールドは**存在しない**（investigation-planの想定と乖離）
- 実際の設定: `max_json_fails_per_loop: 3`, `max_task_retries: 3`, `max_investigations_per_session: 5`
- **閾値に実証的根拠なし**（経験則による値）
- **False Positive ABORT実測事例**: 2026-03-01、一時的API障害で全Researcher空出力→ABORT発動
- **高速無意味リトライ**: fail_count 1→2→3が18秒で完了（指数バックオフなし）

#### R5: checkpoint-restore (git stash) の障害モード

- **Windowsファイルロック**: gitクラッシュで.lockファイル残留→次のgit操作がブロック
- **stash競合**: conflict marker挿入、stashが自動削除されない
- **緩和要因**: `auto_commit_per_phase: true`でstashスコープが1フェーズに限定

---

## 3. 統合分析

### 最重要発見: 障害の根本原因は3つの構造的欠陥の複合

Bash言語そのものではなく、以下の3つの構造的欠陥が信頼性低下の根本原因:

#### (1) CLI出力パイプラインの脆弱性

- errors.jsonl 106件中**59%（63件）**が「Claude実行エラー」だが、レートリミット・CLIクラッシュ・ネットワーク障害の**区別がつかない**
- **指数バックオフなし**の高速リトライ（18秒で3回失敗）が状況を悪化
- `validate_json()`の87行4層リカバリはLLM出力不確実性とBashの型安全性欠如の両方に起因
- **Structured Outputs（GA）で原理的にゼロ化可能**

#### (2) 観測性の体系的欠如

- ログ間にトレースIDなし → 根本原因特定に**5-7ステップ**
- errors.jsonl全107件で**resolution=null**
- metrics.jsonlに**トークン数・費用額が未記録**でコスト分析不能
- circuit-breaker閾値は**経験則設定**で実測データに基づかない

#### (3) 設定・状態管理の安全性不足

- `development.json`のserver.start_commandが**プロジェクト間で非連動**
- 設定変更のセマンティックバリデーション・dry-run機能が**不在**
- `task-stack.json`の全体書き戻し（`jq→.tmp→mv`）は**並行書込みに脆弱**
- ESLintサブプロセス副作用による**blocked_criteria問題**は安全機構と機能要件の構造的対立

### 言語移行の費用対効果

- 移行工数: **60〜150開発日**（巨大投資）
- 移行後の保守コスト削減量が**定量化されていない**
- Python移行でWindows制約の70-90%解消可能だが、外部コマンド呼出しの問題は残存
- **現時点ではBash内改善を優先し、効果を実測データで評価した後に移行ROIを再判定**すべき

### 即効性の高い改善（Bash内で実行可能）

ROIが最も高い施策（優先順）:

| 順位 | 施策 | 推定工数 | 根拠 |
|------|------|---------|------|
| 1 | circuit-breaker改善 + 指数バックオフ | 2-3日 | False Positive ABORT実測事例（2026-03-01） |
| 2 | トレースID + 構造化ログ | 3-5日 | デバッグ5-7ステップ→2-3ステップ |
| 3 | 設定バリデーション + preflight_check拡張 | 2-3日 | サーバー設定不整合インシデント実績 |
| 4 | run_task()のPipeline分解 | 3-5日 | CC 8-9の高複雑度 |
| 5 | research-loop.sh E2Eテスト構築 | 3-5日 | MEMORY.md残存課題 |

---

## 4. 視点間の矛盾と解決

### 矛盾1: Technical vs Cost — 言語移行のROI

| 視点 | 評価 |
|------|------|
| Technical | common.sh 5関数がBash固有制約で信頼性低下の直接原因。言語移行の技術的有効性を支持 |
| Cost | 60-150開発日の工数に対し、移行後の保守コスト削減量が定量化されておらずROI不確実 |

**解決**: Bash内改善を先行し、改善前後のエラー率・復旧時間・保守工数の**実測データを収集**した後に言語移行ROIを再判定

### 矛盾2: Alternatives vs Risk — Agent SDK移行リスク

| 視点 | 評価 |
|------|------|
| Alternatives | Agent SDKが8機能全てをネイティブAPIで実現。最有力移行先 |
| Risk | Strangler Pattern適用時の半完成状態リスク（デュアルメンテナンス倍増、エラー伝播断絶） |

**解決**: Agent SDK自体がCLIサブプロセスラッパーであり**CLI依存は本質的に解消されない**。まずcircuit-breaker+バックオフ改善でCLI障害耐性を向上させ、Agent SDK移行は改善効果測定後のPhase 2判断事項とする

### 矛盾3: Claude API Evolution vs Technical — CLI既存活用の範囲

| 視点 | 評価 |
|------|------|
| Claude API Evolution | Structured Outputsでvalidate_json()パイプライン全体が不要に |
| Technical | CLI `--json-schema`が既にStructured Outputsを部分的に活用中（L107-112） |

**解決**: validation-stats.jsonl 377件の**失敗内訳を分類**し、CLI既存機能で解決済みの割合とAPI直接移行で追加解決可能な割合を定量化すべき。この分析なしに移行判断は不可

### 矛盾4: Developer Experience vs Cost — E2Eテスト投資効果

| 視点 | 評価 |
|------|------|
| DX | research-loop.sh E2Eテスト不在を重大なギャップとし構築推奨 |
| Cost | investigation-log.jsonl 54件の過半数がWindows環境問題でありE2E単独での解決は限定的 |

**解決**: E2Eテストの主目的は**research-loop.shメインループの回帰防止**（MEMORY.md明記）。Windows環境問題の解決は設定バリデーション+preflight_check強化で別途対応

---

## 5. 過去決定との整合性

### 整合する決定

| 決定ID | 内容 | 整合性 |
|--------|------|--------|
| d-20260211-212744 | Strangler Pattern推奨 | 全6視点がBig Bang非推奨。段階的改善支持 |
| d-20260210-005 | モデル配置（Researcher=Sonnet、判断系=Opus） | cost視点が妥当性を確認 |
| d-20260211-013350 | 観測性最優先 | DX視点がトレースID欠如を再発見。推奨順序と一致 |
| d-20260224-003308 | Evolve Harness common.sh 97%再利用 | cost視点が共通基盤維持コストを特定 |
| d-20260210-004 | ABORT判定: 自律 | risk視点がABORT精度問題を発見。方針維持+ロジック改善を推奨 |

### 注意が必要な決定

| 決定ID | 内容 | 影響 |
|--------|------|------|
| d-20260210-006 | Web検索: Claude Code組込みのみ | API直接呼出へ移行する場合Web検索手段の再設計必要。現時点ではCLI経由で十分 |
| d-20260224-003308 | common.sh 97%再利用前提 | 本リサーチの5関数改修がEvolve側に直接影響。インターフェース互換維持が必要 |

---

## 6. 推奨アクション

### Primary: Bash環境内での段階的信頼性改善（4フェーズ、推定19-30日）

#### Phase A: 即時改善（5-8日）

1. **指数バックオフ導入**: 初回1秒→2秒→4秒→…→最大60秒 + 30秒クールダウン
2. **並列Researcherのcircuit-breakerカウントロジック修正**: 個別連続失敗と全体同時失敗を区別
3. **エラー分類強化**: errors.jsonlに`error_category`フィールド追加（6カテゴリ自動分類）

#### Phase B: 観測性基盤（5-8日）

4. **トレースID導入**: SESSION_ID + CALL_IDの生成と全ログ・全JSONLへの伝播
5. **validation-stats.jsonl分析**: 377件の失敗内訳を分類（API移行の投資判断データ）
6. **metrics.jsonlにトークン数・推定コスト追加**

#### Phase C: 設定・状態管理改善（4-6日）

7. **preflight_check()拡張**: サーバーコマンド存在確認、モデル有効値チェック、閾値範囲検証
8. **task-stack.json部分更新**: flock排他制御+差分更新
9. **設定ファイルのJSON Schema定義追加** + 起動時バリデーション

#### Phase D: コード品質改善（5-8日）

10. **run_task()分解**: 15ステップを5関数に分割
11. **research-loop.sh E2Eテスト構築**
12. **scaffold-agent.sh**: エージェント追加手順の半自動化

### Fallback: JSON返却エージェント群の段階的TypeScript移行

**トリガー条件** (Phase A-B完了後):
1. `cli_crash` + `rate_limit` + `network`カテゴリの合計が全エラーの**40%以上**
2. Phase Aのcircuit-breaker改善後もこれらエラー率が**20%以上残存**

**スコープ**: Researcher, Synthesizer, DA, Task Planner, SCのみ（ツール実行エージェントは対象外）
**推定追加工数**: 15-25日

### Abort条件

以下のいずれかに該当する場合、全改善施策を見送り:
1. ハーネス利用頻度が月1回未満に低下
2. Claude CLI/Agent SDK次期バージョンで主要課題が標準解決される公式ロードマップ確認
3. errors.jsonl分析でエラーの80%以上が環境固有問題と判明

**見送り時の機会損失**: 年間推定**40-80時間**の障害対応・調査コスト継続

---

## 7. 実装基準（Implementation Criteria）

### L1基準（ユニットテスト）— 11項目

| ID | 対象 | テストコマンド |
|----|------|---------------|
| L1-001 | 指数バックオフ付きリトライ機構 | `bash .forge/tests/test-backoff.sh` |
| L1-002 | エラーカテゴリ自動分類 (`classify_error()`) | `bash .forge/tests/test-error-classification.sh` |
| L1-003 | 並列Researcher回路遮断カウントロジック | `bash .forge/tests/test-parallel-cb.sh` |
| L1-004 | トレースID生成と全JSONL伝播 | `bash .forge/tests/test-trace-id.sh` |
| L1-005 | 設定ファイルJSON Schemaバリデーション | `bash .forge/tests/test-config-schemas.sh` |
| L1-006 | 拡張preflight設定チェック | `bash .forge/tests/test-preflight.sh` |
| L1-007 | run_task()分解後の関数インターフェース契約 | `bash .forge/tests/test-run-task-decomposed.sh` |
| L1-008 | metrics.jsonlトークン数・推定コスト記録 | `bash .forge/tests/test-metrics-enhanced.sh` |
| L1-009 | task-stack.json flock排他制御付き部分更新 | `bash .forge/tests/test-task-stack-locking.sh` |
| L1-010 | エージェントスキャフォールドスクリプト | `bash .forge/tests/test-scaffold-agent.sh` |
| L1-011 | 既存テストスイート回帰検証 | `bash .forge/tests/run-all-tests.sh` |

### L2基準（E2E・統合テスト）— 5項目

| ID | 対象 | テストコマンド |
|----|------|---------------|
| L2-001 | Research Loop E2Eテスト拡張 | `bash .forge/tests/test-research-e2e.sh` |
| L2-002 | Ralph Loopエラー分類統合フロー | `bash .forge/tests/test-ralph-error-flow.sh` |
| L2-003 | task-stack.json並行更新ストレステスト | `bash .forge/tests/test-concurrent-updates.sh` |
| L2-004 | トレースID全伝播E2E検証 | `bash .forge/tests/test-trace-propagation-e2e.sh` |
| L2-005 | preflight_check実環境検証 | `bash .forge/tests/test-preflight-live.sh` |

### L3基準（人間判断）— 5項目

| ID | 評価項目 | 成功閾値 |
|----|---------|----------|
| L3-001 | エラーカテゴリ分類の網羅性 | unknownが10%未満、誤分類率5%未満 |
| L3-002 | トレースIDによるデバッグ効率改善 | 特定ステップ3以下、所要時間15分以内 |
| L3-003 | run_task()分解後の可読性 | 各関数50行以下、ネスト深さ3以下 |
| L3-004 | 全体信頼性の改善エビデンス | エラー率30%以上削減、False Positive ABORT 0件 |
| L3-005 | Evolve Harnessとの共通基盤互換性 | 同期工数2時間以内、シグネチャ変更なし |

### 開発フェーズ

| フェーズ | 目標 | L1基準 | ミューテーション閾値 |
|---------|------|--------|---------------------|
| **MVP** | circuit-breaker改善 + エラー分類 → False Positive ABORT防止 | L1-001, 002, 003, 011 | 0.4 |
| **Core** | トレースID + 設定スキーマ + preflight + メトリクス + flock → 観測性と設定安全性の基盤 | L1-004, 005, 006, 008, 009, 011 | 0.3 |
| **Polish** | run_task()分解 + scaffold + E2E → 長期保守性と開発者体験 | L1-007, 010, 011 | 0.2 |

---

## 8. 残存ギャップ

### 定量データ不足

| ギャップ | 取得方法 |
|---------|----------|
| validation-stats.jsonl 377件の失敗内訳分類 | Phase Bで実施 |
| metrics.jsonlのトークン数・API費用 | フィールド未記録のため算出不能。Phase B改修後に蓄積 |
| run_task()のCyclomatic Complexity正確値 | shellmetricsツールで機械計測 |
| investigation-log.jsonl 54件の全件root_cause分類 | 46,202トークンで全件読取不可。手動サンプリングのみ |

### 未検証事項

| 項目 | リスク |
|------|--------|
| SQLiteのWindows MSYS2環境でのファイルロック互換性 | 実環境テスト未実施 |
| Claude Agent SDKのWindows Git Bash環境での実動作 | 実証データなし |
| flockコマンドのWindows MSYS環境での利用可否 | L2-003で検証予定 |
| CLI `--json-schema`がconstrained decodingを適用しているか | 確認要 |
| Evolve Harness common.shとの具体的diff | 実ファイル未確認 |

### 調査対象外

- 12エージェント構成の最適性（役割重複・不足の詳細評価）
- Claude API ベータ/プレビュー機能の評価
- 速度最適化（信頼性・保守性との相関がある場合のみ副次的に評価済み）

---

> **次のステップ**: Phase A（circuit-breaker改善 + 指数バックオフ + エラー分類）を最優先で実行し、2026-03-01の False Positive ABORT 再発を防止する。
