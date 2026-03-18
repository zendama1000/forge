# Forge Harness ファイル構成詳細

## エージェント一覧（12体）

| エージェント | ファイル | 役割 |
|---|---|---|
| Scope Challenger (SC) | scope-challenger.md | テーマのスコープ検証・質問生成 |
| Researcher (R) | researcher.md | 多角的リサーチ（並列実行） |
| Synthesizer (Syn) | synthesizer.md | リサーチ結果の統合 |
| Devil's Advocate (DA) | devils-advocate.md | GO/NO-GO 判定 |
| Evidence DA | evidence-da.md | エビデンスベース最終判定 |
| Approach Explorer | approach-explorer.md | 代替アプローチ探索 |
| Task Planner | task-planner.md | criteria → タスク分解 |
| Checklist Verifier | checklist-verifier.md | チェックリスト検証 |
| Implementer | implementer.md | コード実装 |
| Investigator | investigator.md | 失敗原因調査 |
| Mutation Auditor | mutation-auditor.md | ミューテーションテスト監査 |
| Fixer | fixer.md | バグ修正 |

## ライブラリ（`.forge/lib/`）

| ファイル | 役割 |
|---|---|
| bootstrap.sh | 初期化（SCRIPT_DIR/PROJECT_ROOT 設定、common.sh 読込） |
| common.sh | 共有関数（run_claude, validate_json, jq_safe 等） |
| dev-phases.sh | 開発フェーズハンドラ |
| investigation.sh | Investigator ロジック |
| mutation-audit.sh | ミューテーション監査 |
| evidence-da.sh | Evidence DA ロジック |
| phase3.sh | Phase 3 統合検証 |
| priming.sh | プライミング/セットアップ |

## スキーマ（`.forge/schemas/`）

criteria, task-stack, synthesizer, scope-challenger, researcher, mutation-auditor, investigator, evidence-da, approach-explorer の各 JSON Schema。

## テスト（`.forge/tests/`）

`run-all-tests.sh` で一括実行。個別: test-assertions, test-config-integrity, test-events, test-evidence-da, test-heartbeat, test-helpers, test-lessons, test-priming, test-ralph-engine, test-research-config, test-research-e2e, test-safety, test-sanitize-commands, test-validate-json。

## 設定ファイル（`.forge/config/`）

| ファイル | 内容 |
|---|---|
| development.json | Implementer/Investigator/TaskPlanner 設定、サーバー設定、安全プロファイル、assertions |
| research.json | モデル指定、並列リサーチ設定、視点、タイムアウト |
| circuit-breaker.json | 中断トリガー、リトライ上限、保護パターン |
| mutation-audit.json | ミューテーション監査設定 |
