# Forge Harness ファイル構成詳細

## エージェント一覧（16体）

| エージェント | ファイル | 役割 |
|---|---|---|
| Scope Challenger (SC) | scope-challenger.md | テーマのスコープ検証・質問生成 |
| Researcher (R) | researcher.md | 多角的リサーチ（並列実行） |
| Synthesizer (Syn) | synthesizer.md | リサーチ結果の統合 |
| Devil's Advocate (DA) | devils-advocate.md | Synthesis への証拠ベース反証レビュー（severity 付き findings、advisory・拒否権なし） |
| Evidence DA | evidence-da.md | 開発フェーズのエビデンスベース助言（advisory） |
| Approach Explorer | approach-explorer.md | 代替アプローチ探索 |
| Task Planner | task-planner.md | criteria → タスク分解 |
| Checklist Verifier | checklist-verifier.md | チェックリスト検証 |
| Implementer | implementer.md | コード実装 |
| Investigator | investigator.md | 失敗原因調査 |
| Mutation Auditor | mutation-auditor.md | ミューテーションテスト監査 |
| Fixer | fixer.md | バグ修正 |
| QA Evaluator | qa-evaluator.md | 実装と独立した品質ゲート（task_finalize 時） |
| L3 Judge | l3-judge.md | L3 llm_judge 戦略の採点 |
| Best-of-N Judge | best-of-n-judge.md | best-of-N 候補の L1 同値タイブレーク選択 |
| Browser Tester | browser-tester.md | Playwright MCP によるブラウザ実操作検証 |

## ライブラリ（`.forge/lib/`）

| ファイル | 役割 |
|---|---|
| bootstrap.sh | 初期化（SCRIPT_DIR/PROJECT_ROOT 設定、common.sh 読込） |
| common.sh | 共有関数（run_claude, validate_json, jq_safe, fnmatch_to_regex, validate_test_sanctity, build_orientation_context 等） |
| dev-phases.sh | 開発フェーズハンドラ |
| investigation.sh | Investigator ロジック |
| mutation-audit.sh | ミューテーション監査 |
| evidence-da.sh | Evidence DA ロジック（advisory） |
| phase3.sh | Phase 3 統合検証 |
| priming.sh | プライミング/セットアップ（起動時1回キャッシュ） |
| qa-evaluator.sh | 独立 QA ゲート |
| browser-test.sh | Playwright MCP ブラウザテスト |
| ablation.sh | コンポーネント切り分け実験（無効化専用トグル） |
| calibration.sh | Few-Shot 較正 |

## スキーマ（`.forge/schemas/`）

criteria, task-stack, synthesizer, scope-challenger, researcher, devils-advocate, mutation-auditor, investigator, evidence-da, approach-explorer, qa-evaluator, browser-test, l3-judge, best-of-n-judge, development, research, circuit-breaker の各 JSON Schema。

## テスト（`.forge/tests/`）

`run-all-tests.sh` で一括実行（curated リスト + 自動検出。長時間/環境依存は DISCOVERY_EXCLUDE で手動実行扱い）。主要スイート: config-integrity, research-config, devils-advocate, validate-json, safety, test-sanctity, evidence-da, ralph-engine, research-e2e, qa-evaluator, browser-integration, per-call-guards, orientation, best-of-n, scaffold-report ほか。

## 設定ファイル（`.forge/config/`）

| ファイル | 内容 |
|---|---|
| development.json | Implementer/Investigator/TaskPlanner 設定、L3/QA/browser/best_of_n、サーバー設定、安全プロファイル |
| research.json | モデル指定、並列リサーチ設定、視点、タイムアウト、devils_advocate（advisory DA） |
| circuit-breaker.json | 中断トリガー、リトライ上限、保護パターン、test_sanctity、per_call_guards |
| mutation-audit.json | ミューテーション監査設定 |
| ablation.json | アブレーション実験トグル（スキャフォールド削減テスト用） |
