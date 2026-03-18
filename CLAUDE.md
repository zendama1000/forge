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

## 前提条件

- 作業ディレクトリは **git リポジトリ必須**（Ralph Loop が `git rev-parse` で検証）
- `.gitignore` に `node_modules/` 等を含めること（保護ファイルパターン違反防止）
- `development.json` のサーバー設定をプロジェクトに合わせること

詳細: @.claude/rules/forge-operations.md

## 起動方法

```
/sc:forge テーマ                                          # 推奨: Phase 0壁打ち → Phase 1→1.5→2
bash .forge/loops/forge-flow.sh "テーマ" "方向性"          # Phase 1→1.5→2（壁打ち省略）
bash .forge/loops/forge-flow.sh "テーマ" "方向性" --daemonize  # バックグラウンド実行
  --research-config .forge/state/research-config.json      # locked_decisions / open_questions 指定
/sc:research テーマ                                        # Phase 1: リサーチ（単独）
bash .forge/loops/generate-tasks.sh criteria.json          # Phase 1.5: タスク分解（単独）
bash .forge/loops/ralph-loop.sh task-stack.json            # Phase 2: 開発ループ（単独）
bash .forge/loops/dashboard.sh [task-stack.json]           # メトリクス表示
/sc:monitor [--auto-recover]                               # 異常検出モニター（/loop で定期実行推奨）
/loop 5m /sc:monitor                                       # 5分間隔で自動監視
/loop 5m /sc:monitor --auto-recover                        # 5分間隔 + レートリミット自動復旧
```

> **フロー全体が15分以上かかる場合は `--daemonize` を必ず付けること。**
> フォアグラウンド実行はサービス側のタイムアウトで中断される可能性がある。
> ログは `tail -f .forge/state/forge-flow.log` でリアルタイム追跡できる。

## Phase 概観

| Phase | 名称 | 内容 |
|-------|------|------|
| 0 | 壁打ち（人間） | `/sc:forge` でテーマ確認 → `research-config.json` 生成 |
| 1 | Research | SC→R(並列)→Syn→DA の反復。最終的に GO/NO-GO 判定 |
| 1.5 | 成功条件 | criteria → タスク分解 → `task-stack.json` + フェーズテスト生成 |
| 2 | Development | Ralph Loop: Implementer→L1テスト→L2回帰→(失敗時)Investigator |
| 3 | 統合検証 | 全フェーズテスト一括実行 + Evidence DA による最終判定 |
| 4 | 人間判断 | 結果レビュー → マージ / 修正指示 / 却下 |

## 主要ファイル

詳細な構成は @.claude/rules/forge-structure.md を参照。

- `.forge/loops/` — オーケストレーター（forge-flow, research-loop, ralph-loop, generate-tasks, dashboard, mutation-runner）
- `.forge/lib/` — 共有ライブラリ（common.sh 他8本）
- `.forge/config/` — 設定（circuit-breaker.json, development.json, research.json, mutation-audit.json）
- `.forge/schemas/` — JSON Schema 定義（9本）
- `.forge/templates/` — プロンプトテンプレート（13本）
- `.forge/tests/` — テストスクリプト（15本 + fixtures）
- `.forge/state/` — 実行時状態（task-stack.json, decisions.jsonl 等）
- `.claude/agents/` — エージェント定義（12体）
- `.claude/commands/sc/` — スラッシュコマンド（forge.md, research.md）
- `.claude/hooks/` — 品質フック（pre-bash-sanitize, post-write-verify）
- `forge-architecture-v3.2.md` — 設計書（詳細）
