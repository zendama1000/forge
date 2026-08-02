# Forge Harness v3.2

Research System（自律リサーチループ）+ Development System（自律開発ループ）のハーネス。

IMPORTANT: 以下に該当する依頼を受けた場合、直接回答せず必ず先にハーネス起動を提案すること。

## DO / DON'T

DO: 以下の依頼にはハーネス起動を提案してから作業を始める
- ツール/技術の選定・比較
- アーキテクチャ判断・設計レビュー
- 市場調査・競合分析
- トレードオフ比較を伴う意思決定

DO: ハーネス起動前に必ず Phase 0（壁打ち）を実施すること
- `/sc:forge テーマ` を使用する（Phase 0 壁打ち → ハーネス起動の一連フロー）
- 壁打ちではテーマに応じた重要事項（UIの有無、スコープ、技術スタック等）を確認する
- ユーザーが明示的に壁打ち不要と指示した場合のみ省略可

DON'T: 上記に該当する依頼に対して、ハーネスを経由せず直接意見・分析・レビューを返してはならない
- ユーザーが明示的にハーネス不要と指示した場合のみ例外

直接回答でよいもの: コーディング、バグ修正、既知の事実確認、ファイル編集

## ハーネスを使わない基準（P0 — batch#10 で成文化）

以下のいずれかに該当する作業は**ハーネスを使わず Claude Code で直接**行う
（9バッチの実測: これらは直接の方が速い。ハーネス自己改修は9回中9回とも直接だった）:
- 1コンテキストに収まる規模（バグ修正・リファクタ・調査・既存コードへの局所変更）
- 人間が横で対話しながら進める作業
- ハーネス自身の改修

ハーネスが勝つのは: **長時間（文脈窓超え）/ 多数の独立タスク / 無人実行（夜間・バックグラウンド）/ 新規成果物の一括構築**。
ハーネスの価値は品質判定ではなく「持続・状態・再開・引き継ぎ」のランタイムにある。

## ワークフロー・プロファイル（batch#10）

`/sc:forge` Phase 0 の壁打ちで workflow を決定し、`research-config.json` の `workflow`
フィールドに記録する（自動推定しない）。ralph-loop が `.forge/config/profiles/<workflow>.json`
を適用して判定構成を切り替える。`FORGE_PROFILE` env で一時上書き可。

| workflow | 対象 | 検証構成 |
|---|---|---|
| ui-app | URL で開ける Web UI | 決定論テスト + 統合Evaluator + UX判定 + browser（起動前に browser 能力 preflight） |
| cli-lib | CLI/ライブラリ/パイプライン | 決定論テスト + 統合Evaluator のみ |
| env-blocked | Electron/実ブラウザ/外部API 依存 | 検証は設計して繰延（Phase 4 前提） |
| content | 正解のない成果物 | 比較生成（best-of-N）のみ |
| research | 純リサーチ | Phase 1 のみ |

## 前提条件

- 作業ディレクトリは **git リポジトリ必須**（Ralph Loop が `git rev-parse` で検証）
- `.gitignore` に `node_modules/` 等を含めること（保護ファイルパターン違反防止）
- `development.json` のサーバー設定をプロジェクトに合わせること

詳細: @.claude/rules/forge-operations.md

## 起動方法

### 単一プロジェクト（直接実行）

```
/sc:forge テーマ                                          # 推奨: Phase 0壁打ち → Phase 1→1.5→2
bash .forge/loops/forge-flow.sh "テーマ" "方向性"          # Phase 1→1.5→2（壁打ち省略）
bash .forge/loops/forge-flow.sh "テーマ" "方向性" --daemonize  # バックグラウンド実行
  --research-config .forge/state/research-config.json      # locked_decisions / open_questions 指定
/sc:research テーマ                                        # Phase 1: リサーチ（単独）
bash .forge/loops/generate-tasks.sh criteria.json          # Phase 1.5: タスク分解（単独）
bash .forge/loops/ralph-loop.sh task-stack.json            # Phase 2: 開発ループ（単独）
bash .forge/loops/dashboard.sh [task-stack.json]           # メトリクス表示
bash .forge/loops/feedback.sh <task-id> <verdict> "理由"   # 人間裁定の記録（verdict: reject|accept-with-notes）→ 評価器 Few-Shot 較正
/sc:monitor [--auto-recover]                               # 異常検出モニター（/loop で定期実行推奨）
/loop 5m /sc:monitor                                       # 5分間隔で自動監視
/loop 5m /sc:monitor --auto-recover                        # 5分間隔 + レートリミット自動復旧
```

### マルチプロジェクト（git worktree 分離）

```
./forge-gtr.sh setup                                       # 前提条件チェック
./forge-gtr.sh new <name> [--base <ref>]                   # プロジェクト用ワークツリー作成
./forge-gtr.sh start <name> "テーマ" ["方向性"]             # forge-flow 起動（自動 daemonize）
./forge-gtr.sh ai <name>                                   # Claude Code をワークツリーで起動
./forge-gtr.sh list                                        # 全プロジェクト一覧 + 状態
./forge-gtr.sh status <name>                               # 個別プロジェクト詳細
./forge-gtr.sh logs <name> [-f]                            # forge-flow.log 表示
./forge-gtr.sh dashboard <name>                            # ダッシュボード表示
./forge-gtr.sh stop <name>                                 # forge-flow 停止
./forge-gtr.sh rm <name>                                   # ワークツリー削除
./forge-gtr.sh clean                                       # マージ済み一括削除
```

> 詳細: `.docs/git-worktree-runner-guide.md`

### Docker（コンテナ分離）

```
./forge-docker.sh build                                    # イメージビルド
./forge-docker.sh start <project-path> [--detach]          # コンテナ起動
./forge-docker.sh list                                     # 一覧
./forge-docker.sh attach <name>                            # 接続
./forge-docker.sh stop <name>                              # 停止
```

> **フロー全体が15分以上かかる場合は `--daemonize` を必ず付けること。**
> フォアグラウンド実行はサービス側のタイムアウトで中断される可能性がある。
> ログは `tail -f .forge/state/forge-flow.log` でリアルタイム追跡できる。

## Phase 概観

| Phase | 名称 | 内容 |
|-------|------|------|
| 0 | 壁打ち（人間） | `/sc:forge` でテーマ確認 → `research-config.json` 生成 |
| 1 | Research | SC→R(並列)→Syn→DA(advisory)。CRITICAL反証時のみ再調査1回、以後は強制続行。完了判定はハーネス |
| 1.5 | 成功条件 | criteria → タスク分解 → `task-stack.json` + フェーズテスト生成 |
| 2 | Development | Ralph Loop: Implementer→L1テスト→L2回帰→(失敗時)Investigator |
| 3 | 統合検証 | 全フェーズテスト一括実行 + Evidence DA による最終判定 |
| 4 | 人間判断 | 結果レビュー → マージ / 修正指示 / 却下 |

## 主要ファイル

詳細な構成は @.claude/rules/forge-structure.md を参照。

- `.forge/loops/` — オーケストレーター（forge-flow, research-loop, ralph-loop, generate-tasks, dashboard, mutation-runner, scaffold-report）
- `.forge/lib/` — 共有ライブラリ（common.sh 他）
- `.forge/config/` — 設定（circuit-breaker.json, development.json, research.json, mutation-audit.json, ablation.json）
- `.forge/schemas/` — JSON Schema 定義（devils-advocate 含む）
- `.forge/templates/` — プロンプトテンプレート
- `.forge/tests/` — テストスクリプト（run-all-tests.sh で一括実行）+ fixtures
- `.forge/state/` — 実行時状態（task-stack.json, decisions.jsonl 等）
- `.forge/lenses/` — UX美観ジャッジのレンズ定義（lens-taste / lens-usability）
- `.claude/agents/` — エージェント定義（20体）
- `.claude/commands/sc/` — スラッシュコマンド（forge.md, research.md）
- `.claude/hooks/` — 品質フック（pre-bash-sanitize, post-write-verify）
- `forge-architecture-v3.2.md` — 設計書（詳細）
