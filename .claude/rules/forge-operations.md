# Forge Harness 運用ガイド

## 新規プロジェクト起動前チェックリスト

1. `cd <work-dir> && git init`
2. `.gitignore` 作成（`node_modules/`, `.next/`, `.env`, `dist/`, `package-lock.json` 等）
3. 既存ファイルがあれば `git add -A && git commit -m "Initial commit"`
4. `.forge/config/development.json` の `server.start_command` と `server.health_check_url` をプロジェクトに合わせる
5. `bash .forge/loops/forge-flow.sh` で起動

## --research-config フロー

`/sc:forge` の Phase 0.5 で `research-config.json` が生成される:
```json
{
  "mode": "validate | explore",
  "locked_decisions": [{"decision": "...", "reason": "..."}],
  "open_questions": ["..."]
}
```
- `locked_decisions`: ユーザーが確定済みの事項 → リサーチで覆さない
- `open_questions`: 調査対象 → リサーチで解決する
- `locked_decisions` に `assertions` 配列を追加すると、実装後に機械的検証が走る

## LLM が task-stack を手動編集する場合のチェックリスト

criteria/task-stack が破損・不整合で LLM が `.forge/state/task-stack.json` を手動書き換えする際、**省略が起きやすい**のが L2/L3（行動検証）テスト。以下を必ず確認せよ。

### 必須確認項目

- [ ] **各 dev_phase に最低1つ** `validation.layer_2.command` または `validation.layer_3[]` を含むタスクがあるか
- [ ] 定義した L2/L3 コマンドが `research-config.json` の locked_decisions に矛盾しないか
  - 例: 「HTTP API 禁止」下で `curl` を使っていないか
  - 例: 「Node.js 不使用」下で `node scripts/*.js` を使っていないか
  - 例: 「Claude Code .md のみ」なら L3 は `claude -p --agent <name>` ベースで設計
- [ ] L1 だけで済ませていないか — **L1 はファイル構造の検証のみで『動作』は保証しない**
- [ ] 省略する場合は `research-config.json` に明示（将来の自動化の余地を残す）

### L3 テスト設計の型（locked_decision 別）

| 制約 | L3 strategy | 実装例 | 注意 |
|---|---|---|---|
| Claude Code agent のみ | `agent_flow` | step に `subagent_files: [".claude/agents/X.md"]` を指定 → `--agents` インライン定義で `-p` 内 Task 委譲が自動実行される（**2026-07-03 配線実装済み・E2E 実機確認済み**） | `.claude/agents/*.md` 自動ロードは依然不可（subagent_files 経由でインライン化すること） |
| CLI ツール | `cli_flow` | `mycli run --input=test.txt && jq -e '.status' out.json` | スクリプト化可 |
| HTTP API 可 | `api_e2e` | `curl -X POST ... \| jq -e '.status == "ok"'` | スクリプト化可 |
| UI あり + browser_testing 有効 | `browser` | Playwright MCP 経由で browser-tester が実操作 | 2026-07 配線修正済み |
| 純リサーチ/ドキュメント | `human_check` のみ | 目視確認 | L3 未定義 ≠ 省略可、可能な限り自動化 |

### ⚠ `claude -p` モードの制約（2026-04-12 実地検証 / **2026-07-02 再検証で一部解消**）

**`claude -p --system-prompt "$(cat .claude/agents/X.md)" "..."` 形式では `.claude/agents/*.md` はロードされない。**

2026-04-12 の実地テストで判明した事実:
- `-p` モードでは `.claude/agents/*.md` のサブエージェントが**ロードされない**（`Total plugin agents loaded: 0`）
- 当時は Task ツールも利用不可 → Claude は作業内容を**ハルシネーション**で出力（「実行した」と主張するが実ファイル未作成）

**2026-07-02 再検証（CLI 2.1.198）**: `--agents '{"name":{"description":"...","prompt":"..."}}'` による**インライン定義なら `-p` モードでも Task 委譲が実動作する**ことを確認:
- debug log に `source=agent:custom:<name>` / `agent_completion turns=N` が記録される
- サブエージェントが Write した**実ファイルの生成を確認**（ハルシネーションではない）
- `.claude/agents/*.md` の自動ロードは依然 `Total plugin agents loaded: 0` のまま（変化なし）

**2026-07-03 配線実装**: run_claude に `_RC_AGENTS_FILE` env チャネルを追加し、L3 agent_flow の step 定義に `subagent_files: [".claude/agents/X.md"]` を書くだけで `--agents` インライン定義（`build_agents_json` が .md → JSON 変換）が注入されるようになった。実機 E2E でサブエージェント委譲による実ファイル生成を確認済み（debug log に `agent:custom:<name>` / `agent_completion`）。従来の代替も引き続き有効:
- 対話モードでユーザー手動起動 → 成果物を grep/wc で機械検証
- 単体エージェントが `-p` 内で完結する場合（subagent chain 不使用）は従来どおり自動化可能

### 省略の透明化

L2/L3 を省略した場合、**ユーザーに明示的に報告すること**:
> 「L2/L3 省略済み。実装が仕様通りに動作するかは未検証。behavioral テストは別途実行推奨」

Phase 3 完了時の `integration-report.json` にも `status: "completed_with_gaps"` + `test_coverage_gaps[]` で残る（ralph-loop 完了サマリーで赤字警告表示される）。

### 違反時のコスト

今回（2026-04-12）の実例: `.md` 11ファイル生成は完遂したが、エージェントが仕様通り動くかは未検証のまま「完了」報告。ユーザー側で実動テストが必要になり、ハーネスの信頼性に疑義が生じた。L3 を最低1つ定義しておけば防げた。

## トラブルシューティング

### タスクが `in_progress` のまま残留
Ralph Loop が中断された場合に発生。`check_stale_in_progress()` がメインループ後に自動検出するが、手動復旧:
```bash
jq '(.tasks[] | select(.status=="in_progress")).status = "pending"' .forge/state/task-stack.json > tmp && mv tmp .forge/state/task-stack.json
```

### レートリミットで `blocked_investigation`
status を pending に戻して ralph-loop 再起動で復旧:
```bash
jq '(.tasks[] | select(.status=="blocked_investigation")).status = "pending"' .forge/state/task-stack.json > tmp && mv tmp .forge/state/task-stack.json
```

### generate-tasks.sh タイムアウト
`development.json` の `task_planner.timeout_sec` は `0`（無制限）推奨。Claude CLI `-p` モードは単一 API 呼出でハングリスクほぼゼロ。

### Implementer ファイル数制限超過
`validate_task_changes` のハードリミット(30)超過で自動ロールバック。対策:
- setup/UI系タスクは 1-2 ファイルに分割
- タスク粒度を小さくする

### development.json サーバー設定不一致
プロジェクトが変わったら `server.start_command` と `server.health_check_url` を必ず更新。

## 進捗監視

```bash
bash .forge/loops/dashboard.sh                          # メトリクス表示
cat .forge/state/progress.json                          # 現在フェーズ/ステージ
tail -20 .forge/state/forge-flow.log                    # 直近ログ
jq -r '.status' .forge/state/current-research.json      # Phase 1 完了判定
```

## スキャフォールド棚卸し（モデル更新毎の定例）

```bash
bash .forge/loops/scaffold-report.sh                    # 非荷重コンポーネント候補の列挙
```

「ハーネスの全コンポーネントはモデル欠陥への仮説」の原則に基づき、**モデル更新
（model id 変更）毎および自己改修バッチの定例項目として実行**する。0 発火の
ゲート/修復段は削減候補 — ただし即削除せず、`ablation.json`（enabled=true +
対象 component=false）で OFF 実験 → フル回帰 + 実タスクで品質不変を確認してから削除する。

## サンドボックス運用の推奨

長時間の自律ループ（forge-flow --daemonize 等）は `--dangerously-skip-permissions` で
走るため、**Docker コンテナ経由（`./forge-docker.sh start <project>`）での実行を推奨**する。
素の環境で走らせる場合は、作業前 git チェックポイントがあること（Ralph Loop の
safety check が強制）を最低ラインとする。
