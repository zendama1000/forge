# Forge Harness ファイル構成詳細

> batch#10（2026-08-02）: 判定者統合により DA(research 用) / 統合 Evaluator（旧 QA — 任務=テスト監査）/
> Investigator / UX 判定（ui-app のみ）以外の判定者は config OFF（Evidence DA / Mutation Auditor /
> Checklist Verifier / Best-of-N judge）。物理削除はカナリア検証後。
> validation の書き手は Planner → Implementer（実装後執筆）に移管。

## エージェント一覧（20体）

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
| UX Scenario Generator | ux-scenario-generator.md | criteria → ユーザー語彙ゴール変換（文脈遮断層。識別子漏出は機械ゲートで再生成） |
| UX Sim-User | ux-sim-user.md | 模擬ユーザー（スクリーンショットのみ知覚・座標操作。行動証拠チャネル） |
| UX Aesthetic Judge | ux-aesthetic-judge.md | レンズ別視覚品質評価（must_fix 上位3件 + resolution_criteria 必須） |
| UX Aggregator | ux-aggregator.md | 3チャネル must_fix の統合・反証不能リジェクト・矛盾調停 |

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
| calibration.sh | Few-Shot 較正（rework 2経路検出 / record_feedback_for_task / 乖離率） |
| ux-judgment.sh | UX判定システム（3チャネル発火・集約・fix タスク生成・レンズ採択率集計） |
| validation-gates.sh | validation 構造ゲート共有ライブラリ（batch#10 — 生成時 VG_REQUIRE_L1=0 / 執筆後 validate_authored_validation） |

## スキーマ（`.forge/schemas/`）

criteria, task-stack, synthesizer, scope-challenger, researcher, devils-advocate, mutation-auditor, investigator, evidence-da, approach-explorer, qa-evaluator, browser-test, l3-judge, best-of-n-judge, development, research, circuit-breaker, ux-judgment（config）, ux-scenarios, ux-sim-user, ux-aesthetic-judge, ux-aggregator の各 JSON Schema。

## テスト（`.forge/tests/`）

`run-all-tests.sh` で一括実行（curated リスト + 自動検出。長時間/環境依存は DISCOVERY_EXCLUDE で手動実行扱い）。主要スイート: config-integrity, research-config, devils-advocate, validate-json, safety, test-sanctity, evidence-da, ralph-engine, research-e2e, qa-evaluator, browser-integration, per-call-guards, orientation, best-of-n, scaffold-report, feedback（P0キャリブレーション）, ux-judgment ほか。

## 設定ファイル（`.forge/config/`）

| ファイル | 内容 |
|---|---|
| development.json | Implementer/Investigator/TaskPlanner 設定、L3/QA/browser/best_of_n、サーバー設定、安全プロファイル |
| research.json | モデル指定、並列リサーチ設定、視点、タイムアウト、devils_advocate（advisory DA） |
| circuit-breaker.json | 中断トリガー、リトライ上限、保護パターン、test_sanctity、per_call_guards |
| mutation-audit.json | ミューテーション監査設定 |
| ablation.json | アブレーション実験トグル（スキャフォールド削減テスト用。ux_judgment 含む） |
| ux-judgment.json | UX判定設定（phase別発火・レンズ・sim-user知覚制限・エスカレーション・プルーニング閾値） |
