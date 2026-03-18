# Forge Harness v3.2 全体最適化 — 最終リサーチレポート

**Research ID:** `2026-03-15-4d6f45-111036`
**日付:** 2026-03-15
**テーマ:** 信頼性・保守性重点、マクロ（アーキテクチャ・Phase間連携）からミクロ（関数・プロンプト・設定値）まで網羅的分析。言語移行・最新技術取り込み含む

---

## 1. エグゼクティブサマリー

6視点（技術的実現性・コスト・リスク・代替案・開発者体験・エコシステム進化）による横断分析の結果、以下の核心的知見が得られた。

| # | 発見 | インパクト |
|---|------|-----------|
| 1 | errors.jsonl 106件全件が**100%未分類**（error_categoryフィールド不在）、retry_with_backoff()は**デッドコード** | Phase A の緊急性を裏付け |
| 2 | 過去7件のバグは全て**Bash言語固有でなくアーキテクチャ設計起因** → 言語移行のROIは信頼性目的では低い | Bash内改善を優先 |
| 3 | Claude CLI -pモードは4ヶ月で80+リリース、破壊的変更4件確認 → **中期的に最大のアーキテクチャリスク** | SDK移行パスを維持 |
| 4 | Windows Git Bashに**flockが標準不在** → Phase C(7)の排他制御はmkdirベースに縮小修正 | 実装方針の変更 |
| 5 | scaffold-agent.sh の ROI が全施策中**最高**（回収期間6ヶ月〜1.5年） | Phase D(11)を前倒し |

**結論:** d-20260314-225356 の4フェーズ計画（A→B→C→D）は概ね妥当。Phase A を7-10日に上方修正、Phase C(7) をmkdirベースロックに縮小、全体推定 **22-31日**。

---

## 2. 調査計画

### 2.1 未決事項（Core Questions）

| # | 未決事項 | 関連視点 |
|---|---------|---------|
| CQ1 | Phase A（circuit-breaker改善・エラー分類強化）の即効性は実測データで裏付けられるか？ | risk, cost |
| CQ2 | Bash→他言語移行のROIは、Bash内改善のROIを上回るか？移行効果が最大の層はどこか？ | cost, alternatives, technical |
| CQ3 | Claude API/CLI最新機能でvalidation-stats.jsonlの3層recoveryやタイムアウト問題を根本解決できるか？ | ecosystem_evolution, technical |
| CQ4 | Phase間状態受け渡しの設計は障害復旧・再開可能性・データ整合性の観点で十分か？ | risk, technical |
| CQ5 | run_claude()の9パラメータ設計・.pending/validate_jsonは技術的負債としてどの程度深刻か？ | technical, cost |
| CQ6 | 12エージェント定義のプロンプト設計に改善余地があるか？ | devex |
| CQ7 | 並行処理の現行実装は信頼性と効率の観点で改善可能か？ | risk, alternatives |

### 2.2 検証された前提（Assumptions Exposed）

- **棄却:** 「信頼性問題がBash言語の制約に起因する」→ 7バグ全てアーキテクチャ設計起因
- **確認:** 「CLI仕様変更リスクが高い」→ 4ヶ月で80+リリース、破壊的変更4件
- **部分確認:** 「3層recoveryが--json-schemaで大幅削減済み」→ Layer 2/3は削減、Layer 1(CRLF 66.7%)は残存
- **未検証:** 「12エージェント構成が最適」→ プロンプト文面の詳細分析は未実施

---

## 3. 視点別調査結果

### 3.1 技術的実現性（Technical）

| 調査項目 | 結論 | 信頼度 |
|---------|------|--------|
| run_claude() 9位置引数→名前付き引数移行 | 技術的に実現可能（Bash nameref活用）。46箇所のうち本番呼出は約20箇所。Strangler Patternで段階的移行可能 | High |
| validate_json 3層recovery の --json-schema 後の必要性 | Layer 1(CRLF=230件/66.7%)は引き続き必要（Windows OS層問題）。Layer 2/3はJSON返却エージェントでは不要化 | High |
| run_task() 5関数分解の実現性 | set -euo pipefail+trap維持で実現可能。ERR trap継承にset -E追加が必要。110個のグローバル変数依存は残存 | High |
| Bash→SDK移行の技術的障壁 | Agent SDKがBuilt-inツールをネイティブ提供 → 最大障壁「ツール実行ループ自前実装」が消滅。残る障壁は認証方式のみ | High |
| flock排他制御+差分更新 | **Windows Git Bashにflockが標準不在**。jqでは差分更新も不可能。mkdirベースロックが現実的代替 | Medium |

**validation-stats.jsonl 内訳:**

| リカバリレベル | 件数 | 割合 | --json-schema後の必要性 |
|--------------|------|------|----------------------|
| CRLF (Layer 1) | 230 | 66.7% | 必要（Windows OS層問題） |
| extraction (Layer 3) | 67 | 19.4% | 不要（JSON返却エージェント） |
| fence (Layer 2) | 26 | 7.5% | 不要（JSON返却エージェント） |
| failed | 22 | 6.4% | — |

### 3.2 コスト・リソース（Cost）

#### 工数見積もり比較

| 施策 | 推定工数 | ROI | 回収期間 |
|------|---------|-----|---------|
| Bash内改善（Phase A-D） | 22-31日 | 最高 | 1-2年 |
| Python部分移行（loops/層） | 40-80日 | 中 | 3-4年 |
| TypeScript全面移行 | 60-120日 | 低 | 5年以上 |
| scaffold-agent.sh（D11単独） | 4-8h | **全施策中最高** | 6ヶ月〜1.5年 |
| run_task()分解（D9単独） | 18-30h | 中 | 1.5-2.5年 |

#### Phase別ボトムアップ推計

| Phase | 工数(h) | 工数(日) | 主要リスク |
|-------|---------|---------|-----------|
| A: エラー分類+CB改善 | 42-60h | 7-10日 | retry_with_backoff()統合の複雑性 |
| B: トレースID+観測性 | 20-40h | 5-8日 | トークンログ実装（過去に未完了実績あり） |
| C: 設定検証+排他制御 | 14-28h | 3-5日 | flock断念→mkdirベースに縮小 |
| D: コード分解+ツール整備 | 28-56h | 5-8日 | run_task()テストカバレッジゼロ |
| **合計** | **104-184h** | **22-31日** | |

#### API費用の現状

- **metrics.jsonlにトークン/コストデータが存在しない**（989件全てduration_sec・parse_successのみ）
- Phase B(5)実装後まで正確なコスト評価は不可能
- 推計: 1リサーチラウンド ≈ $1.02（Opus $0.66 + Sonnet $0.36）
- Prompt Cachingで理論的に入力トークン最大70%削減可能（ただしCLI経由での制御は困難）

### 3.3 リスク・失敗モード（Risk）

#### errors.jsonl 106件の分析結果

| 失敗カテゴリ（メッセージベース粗分類） | 件数 | 割合 |
|--------------------------------------|------|------|
| Claude実行エラー（根本原因不明） | 63 | 59.4% |
| 出力が不正なJSON | 29 | 27.4% |
| Investigator実行エラー | 6 | 5.7% |
| 出力が空 | 6 | 5.7% |
| 自動ABORT/loop-control | 2 | 1.9% |

> **重要:** error_categoryフィールドは全106件で**0件**。d-20260314-225356の指摘から改善なし。

#### 主要リスク一覧

| リスク | 深刻度 | 現状 |
|--------|--------|------|
| エラー分類基盤の完全欠如 | **Critical** | error_category 0件、retry_with_backoff()デッドコード |
| Claude CLI -pモード破壊的変更 | **High** | 4ヶ月で80+リリース、今後6ヶ月で影響確率80%超推定、バージョンピン留めなし |
| False Positive ABORT | **High** | 2026-03-01実測: 6並列Researcher全員空出力→全体中断。バックオフなし（18秒で3回リトライ完了） |
| in_progress残留 | **Medium** | 3層緩和策で実用的にカバー済み。根本原因（原子的状態遷移欠如）は未解消 |
| Evolve Harnessバグ修正未同期 | **Medium** | Forge側バグ修正4件がEvolve未反映の可能性。ただし「共有」ではなく「コピー」管理 |
| 言語移行中の並行運用リスク | **Medium** | CWD断絶の実例あり（2026-03-08修正済み）。Strangler Pattern推奨 |

### 3.4 代替案・競合（Alternatives）

#### 改善アプローチ比較

| アプローチ | 即効性 | 信頼性改善 | 保守性改善 | 移行コスト | 推奨度 |
|-----------|--------|-----------|-----------|-----------|--------|
| **(A)** 4フェーズ順次（d-20260314） | 中 | 高 | 高 | 低 | ★★★★ |
| **(B)** 最頻失敗モード集中攻撃（Pareto） | **最高** | 中 | 低 | 最低 | ★★★★★ |
| **(C)** 観測性基盤先行 | 低 | 低（短期） | 中 | 中 | ★★★ |

> **推奨:** (B)+(A)のハイブリッド — Phase AでPareto的に上位パターンを集中攻撃しつつ、Phase B以降で体系的改善

#### 言語移行の選択肢（Strangler Pattern原則評価）

| 選択肢 | Strangler整合性 | 信頼性効果 | 保守性効果 | 推奨 |
|--------|----------------|-----------|-----------|------|
| (A) Bash維持+ShellCheck/shfmt強化 | — | 低 | 低 | 短期 |
| **(B) loops/層のみPython移行** | **最高** | 中 | 高 | **中期** |
| (C) lib/層のみTypeScript移行 | 中 | 中 | 中 | — |
| (D) Agent SDK全面再構築 | 低（一括置換） | 高 | 最高 | 長期 |

#### run_claude() 呼出方式の比較

| 方式 | JSON parse失敗率 | 型安全性 | 移行コスト |
|------|-----------------|---------|-----------|
| (A) 現行CLI -pモード | 高（truncation問題あり） | なし | — |
| **(B) Anthropic Python SDK** | **ほぼゼロ**（Structured Outputs） | 高 | 中 |
| (C) Claude Agent SDK | CLI同等（subprocess方式） | 中 | 中 |
| (D) OpenAI互換ラッパー | 中 | 低 | 最高 |

#### 状態管理の比較

| 方式 | 障害復旧 | 並行書込み | クエリ柔軟性 |
|------|---------|-----------|------------|
| (A) 現行JSONファイル群 | 低 | なし | 低 |
| **(B) SQLite** | **高** | WALモード対応 | **最高** |
| (C) イベントソーシング | 最高（再構築可能） | 高（append-only） | 中 |

### 3.5 開発者体験（DevEx）

| 課題 | 現状 | 改善策 | 期待効果 |
|------|------|--------|---------|
| トレースID不在 | 障害デバッグに5-7ステップ、30分〜数時間 | SESSION_ID+CALL_ID導入 | デバッグ時間6倍短縮（5-10分へ） |
| 新規プロジェクト設定の手動依存 | 4項目チェックリスト（バグ源として複数回記録） | preflight_check()拡張 | 認知負荷大幅軽減、設定不整合の早期検出 |
| dashboard.shの受動性 | 静的バッチ表示+tail -f依存 | watch自動更新、スタック状態警告表示 | 異常検知・意思決定支援の向上 |
| エージェント定義4ファイル手動作成 | 2-4h/体、整合性ミスリスク | scaffold-agent.sh自動化 | 30-60min/体に短縮（75%削減） |

### 3.6 エコシステム進化対応力（Ecosystem Evolution）

#### Claude API新機能の活用可能性

| 機能 | 適用可能性 | アーキテクチャ変更 |
|------|-----------|-----------------|
| Prompt Caching GA | 即座に活用可能（コスト最大90%削減） | 不要 |
| Batch API GA | Researcher並列で50%割引 | 不要（ただし非同期設計変更推奨） |
| Token Counting API GA | run_claude()前のトークン数事前チェック | 不要 |
| 1時間キャッシュ GA | 長時間開発ループ中のキャッシュ維持 | 不要 |
| Extended Thinking（effort移行） | budget_tokens→effortパラメータ変更必須 | **必要** |
| Structured Outputs GA | output_config.format変更 | **必要** |
| Compaction API（beta） | Implementer長時間セッション最適化 | **必要** |

#### Claude Agent SDK 成熟度評価

| 項目 | 状況 |
|------|------|
| バージョン | Python v0.1.48（sub-1.0） |
| Open Issues | 227件 |
| Open PRs | 92件 |
| アーキテクチャ | CLIをsubprocessで起動（run_claude()と本質的に同じ） |
| Forge要件の充足 | ツール制御: ○、ライフサイクルフック: ○、状態機械: ×、circuit-breaker: ×、git rollback: × |
| **評価** | **フル移行には不十分。段階的移行パスは存在** |

#### Windows Git Bash のUnixツール依存

| ツール | 状況 | 対策 |
|--------|------|------|
| jq | デフォルト未同梱、手動インストール必要 | インストール手順書化 |
| flock | **標準不在、代替なし** | mkdirベースロック or WSL2推奨 |
| GNU timeout | 未同梱 | timeout_sec=0 workaround適用済み |
| /tmp パス | Bash⇔Node.jsで異なる解決 | MEMORY.md記載の回避策適用済み |

---

## 4. 統合分析（Synthesis）

### 4.1 視点間の矛盾と解決

| 矛盾 | 視点 | 解決 |
|------|------|------|
| Bash内改善 vs Python SDK移行 | alternatives ↔ cost | 短中期はBash内改善優先。Phase B完了後にSDK移行を再評価 |
| SDK移行障壁「低い」 vs SDK成熟度「不十分」 | technical ↔ ecosystem | 技術的に可能だがプロダクション品質未達。SDK v1.0待ち |
| SQLite推奨 vs flock不在 | alternatives ↔ technical | mkdirベースロックに縮小。SQLiteはPython移行時に再検討 |
| Phase A工数5-8日 vs retry_with_backoff()デッドコード | cost ↔ risk | Phase A工数を7-10日に上方修正 |
| preflight改善(Forge) vs Evolveバグ未同期 | devex ↔ risk | 補完関係。preflight改善は即実施、Evolve同期は別途検討 |

### 4.2 過去決定との整合性

**整合:**
- d-20260314-225356: 4フェーズBash内改善の方向性は6視点中5視点以上が支持
- d-20260211-212744: Strangler Pattern原則がalternatives・technicalの両視点で直接参照・遵守
- d-20260210-005: モデル配置最適化（Researcher=Sonnet）が既に最大のコスト最適化として確認
- d-20260224-003308: Evolve Harnessとのcommon.shが「コピー」であり、Forge側改修が直接破壊しないことを確認

**要修正:**
- d-20260314-225356 Phase C(7): flockが環境制約で実現困難 → mkdirベースロックに縮小
- d-20260314-225356 工数見積もり: 19-30日 → **22-34日に上方修正**が妥当

### 4.3 未解決事項（Feedback Response）

| 項目 | ステータス | 備考 |
|------|-----------|------|
| 言語移行の定量的ROI比較 | **解決** | cost視点でBash/Python/TS比較実施 |
| errors.jsonl実データに基づくPhase A検証 | **解決** | 100%未分類+デッドコード発見 |
| validation-stats.jsonl時系列分析 | **部分解決** | 内訳特定済み。was_schema_modeフラグ不在で完全比較は不可 |
| Claude API/CLI最新機能の適用可能性 | **解決** | 即活用可能/要変更の2分類完了 |
| Phase間状態受け渡しの評価 | **部分解決** | in_progress残留は3層緩和確認。他状態ファイルは未分析 |
| 12エージェントのプロンプト設計評価 | **未解決** | プロンプト文面の詳細分析は未実施 |

---

## 5. 推奨アクション

### 5.1 Primary: 修正版4フェーズ計画（推定22-31日）

#### Phase A: エラー分類+Circuit-Breaker改善（7-10日）
1. `record_error()` に error_category 自動分類フィールド追加（CLIの終了コード・実行時間・出力サイズ基準）
2. `retry_with_backoff()` の指数バックオフ化 + research-loop.sh/ralph-loop.sh への統合（**デッドコード解消**）
3. circuit-breaker の並列Researcher失敗カウント修正（個別連続失敗 vs 全体同時失敗の区別）
4. 全体同時失敗時の30秒クールダウン後リトライ

#### Phase B: トレースID+観測性向上（5-8日）
5. SESSION_ID + CALL_ID 導入（全ログファイルにクロスステージ追跡）
6. validation-stats.jsonl に stage 別分析 + was_schema_mode フラグ追加
7. metrics.jsonl にトークン数・コスト追跡追加
   - **Phase B(4)の分析結果をPython SDK移行判断のデータポイントとして位置付け**

#### Phase C: 設定検証+排他制御（3-5日）
8. `preflight_check()` 拡張（development.json ↔ package.json scripts 整合性チェック）
9. mkdirベースロック追加（~~flock~~から変更、update_task_status/update_task_fail_count の2関数のみ）
10. 4設定ファイルの JSON Schema 定義 + 起動時バリデーション

#### Phase D: コード分解+ツール整備（5-8日）
11. `run_task()` 5関数分解（set -E 追加必須）
12. research-loop.sh メインループ E2E テスト
13. `scaffold-agent.sh` 新規作成（**ROI最高のため可能な限り前倒し**）

### 5.2 Fallback: Phase A のみ実施+データ駆動判断

- Phase A のみを実施（7-10日）し、得られた error_category 分布に基づき Phase B 以降を再設計
- **ピボットトリガー:**
  - rate_limit/network エラー > 60%: Python SDK 直接呼出に移行
  - cli_crash エラー > 20%: CLI -pモード自体の不安定性が主因
  - Phase A 中に CLI 破壊的変更が発生し修正工数 > 5日

### 5.3 Abort 条件

- Claude CLI -pモードが非推奨化/廃止の公式アナウンス
- Claude Agent SDK v1.0 がForge固有機能を標準提供
- ハーネス利用頻度が月1回未満に低下

**機会コスト:** 22-31日（132-186h）を他プロジェクトに振り向け可能。ただし改善しない場合の運用効率損失は年間24-80h（年3-5プロジェクト使用時）と推定され、**投資は1年以内に回収**される。

---

## 6. 実装基準（Implementation Criteria）

### 6.1 Layer 1 基準（単体テスト）

| ID | 内容 | テストコマンド |
|----|------|--------------|
| L1-001 | record_error()がerror_categoryを自動分類（timeout/invalid_json/rate_limit/empty_output/unknown） | `test-error-classification.sh` |
| L1-002 | retry_with_backoff()が指数バックオフ(1→2→4→8秒)実装+research-loop/ralph-loopに統合 | `test-retry-backoff.sh` |
| L1-003 | circuit-breakerが並列Researcher個別失敗vs全体同時失敗を区別+クールダウン付きリトライ | `test-circuit-breaker-parallel.sh` |
| L1-004 | SESSION_ID(UUID v4)+CALL_ID(連番)を全ログファイルに付与 | `test-trace-id.sh` |
| L1-005 | validation-stats.jsonlにstage/was_schema_mode追加+集計関数提供 | `test-validation-stats-analysis.sh` |
| L1-006 | metrics.jsonlにinput_tokens/output_tokens/cost_usd追加+セッション累計 | `test-metrics-cost-tracking.sh` |
| L1-007 | preflight_check()でdevelopment.json↔package.json scripts整合性検証 | `test-preflight-check.sh` |
| L1-008 | update_task_status()/update_task_fail_count()にmkdirベース排他ロック | `test-task-state-locking.sh` |
| L1-009 | 4設定ファイルのJSON Schema定義+起動時バリデーション | `test-config-schema-validation.sh` |
| L1-010 | run_task()を5関数に分解(prepare/implement/validate/l1test/finalize)+set -E | `test-run-task-decomposition.sh` |
| L1-011 | research-loop.shメインループ単体テスト(SC→R→Syn→DA状態遷移) | `test-research-main-loop.sh` |
| L1-012 | scaffold-agent.shでagent.md/schema/templateのボイラープレート一括生成 | `test-scaffold-agent.sh` |

### 6.2 Layer 2 基準（E2E/統合テスト）

| ID | 内容 | 前提条件 |
|----|------|---------|
| L2-001 | Phase A改善が実リサーチフローで機能（error_category付与+リトライ回復） | API Key+ネットワーク |
| L2-002 | Trace IDがforge-flow全フロー通じて一貫伝播 | API Key+フル実行30分以上 |
| L2-003 | ralph-loopのretry_with_backoff統合後のタスク完了+circuit-breaker発動 | API Key+task-stack |
| L2-004 | preflight_check()がdevelopment.json↔package.json不整合を実プロジェクトで検出 | Node.jsプロジェクト |
| L2-005 | research-loop.shメインループE2Eテスト自動化 | API Key+research.json |

### 6.3 Layer 3 基準（品質指標）

| ID | 指標 | 成功閾値 |
|----|------|---------|
| L3-001 | Trace ID導入後のエラーデバッグ時間 | 中央値50%以上短縮 |
| L3-002 | False Positive ABORT発生率 | 0.2以下→0.05以下に低減 |
| L3-003 | run_task()分解後のコード可読性 | フロー理解20分以内、修正実行10分以内 |
| L3-004 | scaffold-agent.shによるエージェント追加効率 | 手動比50%以上短縮 |

### 6.4 開発フェーズ

| Phase | Goal | L1基準 | Mutation閾値 |
|-------|------|--------|-------------|
| **MVP** | エラー分類+CB改善で信頼性基盤確立 | L1-001〜003 | 0.4 |
| **Core** | トレースID+観測性+設定検証+排他制御 | L1-004〜009 | 0.3 |
| **Polish** | コード分解+テスト拡充+開発ツール整備 | L1-010〜012 | 0.2 |

---

## 7. 調査のギャップ（未調査事項）

以下の項目は本リサーチでカバーされなかった。必要に応じて追加調査を検討すること。

- **エージェントプロンプト設計の詳細分析**（Chain of Thought・Few-shot等の最新手法適用余地）
- **investigation-log.jsonl 54件のroot_cause/resolution統計分析**（「Claude実行エラー」63件の実際の原因内訳）
- **metrics.jsonl 989件の統計分析**（エラー率の時系列変動、circuit-breaker閾値最適値の導出）
- **Evolveリポジトリ実態のcommon.sh乖離度確認**
- **Claude CLI バージョン固定方法の具体的手順確認**
- **validation-stats.jsonlのstageフィールドベースの層別時系列分析**（was_schema_modeフラグ不在のため完全分離は不可）
- **Claude Agent SDK TypeScript版（v0.2.71）の詳細評価**

---

## 8. 参照エビデンス（主要ソース）

### 内部データ
- `errors.jsonl`: 106件（100%未分類、error_category=0件）
- `validation-stats.jsonl`: 389件（CRLF 66.7% / extraction 19.4% / fence 7.5% / failed 6.4%）
- `metrics.jsonl`: 989件（トークン/コストデータ不在）
- `investigation-log.jsonl`: 54件
- `MEMORY.md`: 過去7件のバグ全てアーキテクチャ設計起因
- `harness-technical-review-20260308.md`: 技術レビュー詳細

### 外部ソース（代表）
- [Claude CLI Reference](https://code.claude.com/docs/en/cli-reference)
- [Anthropic API Release Notes](https://platform.claude.com/docs/en/release-notes/api)
- [Claude Agent SDK Overview](https://platform.claude.com/docs/en/agent-sdk/overview)
- [Structured Outputs Documentation](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
- GitHub Issues: [CLI JSON parse error #14442](https://github.com/anthropics/claude-code/issues/14442), [JSON truncation #913](https://github.com/eyaltoledano/claude-task-master/issues/913), [SDK Windows #208](https://github.com/anthropics/claude-agent-sdk-python/issues/208)
