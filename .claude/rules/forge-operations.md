# Forge Harness 運用ガイド

## 新規プロジェクト起動前チェックリスト

1. `cd <work-dir> && git init`
2. `.gitignore` 作成（`node_modules/`, `.next/`, `.env`, `dist/`, `package-lock.json` 等）
3. 既存ファイルがあれば `git add -A && git commit -m "Initial commit"`
4. `.forge/config/development.json` の `server.start_command` と `server.health_check_url` をプロジェクトに合わせる
   - **サーバー不要のプロジェクトは `"none"` のままでよい**（2026-07 batch#7 以降は none の意味論が定義済み: サーバー依存テストは env_blocked として繰延される）
   - HTTP 検証を含む task-stack が生成されたのに `none` のままだと Phase 1.5 の **server 整合 preflight が exit 1 で block** する（自動推定はしない — 手動設定が正）
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
| **Web UI（URL で開ける）** + browser_testing 有効 + 環境能力 browser | `browser` | Playwright MCP 経由で browser-tester が実操作 | **Electron/デスクトップ UI には原理的に不適合（禁止）** — Playwright MCP は URL の Web ページしか操作できない。browser-cockpit の教訓 |
| Electron / デスクトップ / 外部プロセス | `cli_flow`（**実効果スモーク**） | 実物を headless 最小起動し観測可能な副作用（title 取得/exit code/生成ファイル）を assert | 重い e2e は `deferred:true` + 代替スモーク併設。スタブ実装が unit green で通過した実害（2026-07-10）への対策 |
| 純リサーチ/ドキュメント | `human_check` のみ | 目視確認 | L3 未定義 ≠ 省略可、可能な限り自動化 |

### batch#7 テスト機構（2026-07-12 導入）の要点

「テスト green だが実践で動かない」問題への構造対策。原則: **検証は環境で到達可能な最強ティアで必須。超えるティアのみ deferred 可。deferred・auto-pass・skip は必ず品質債務台帳に残る（黙って劣化しない）**。

- **環境能力プローブ**: Phase 1/1.5 冒頭で `probe-env.sh` が `env-capabilities.json`（capability_tags）を生成し、criteria/Planner のテスト設計に注入。充足不能な requires が `deferred:true` なしで残ると機械ゲートが block
- **Walking Skeleton（機械ゲート）**: 全 dev-phase の exit_criteria に `kind: "walking_skeleton"`（実ユーザーシナリオ1本の E2E）が必須。「ユニット全 green・シナリオ0本」を完了と呼ばせない
- **server ライフサイクル**: `server-lifecycle.sh` が回帰/Phase3 のサーバー起動停止を一元管理（外部所有は kill しない/`none` は繰延/HTTP コード別診断）。phase-test スクリプトは `--work-dir` を解釈して cd する
- **futile ループ根絶**: l3fix dedup + origin 毎 fix 上限（`max_fix_tasks_per_origin`）+ 環境起因失敗（`is_environmental_failure`）は fix を作らず deferred
- **品質債務台帳**: `.forge/state/quality-debts.jsonl`。QA auto-pass / 繰延 / skip / warn 化 / orphan file が記録され、print_summary（`[WARN] QUALITY_DEBTS=N`）/ dashboard / integration-report / **PHASE4-HANDOFF.md（自動生成）** に表面化
- **アンチスタブ**: Implementer に「外部境界のフェイク実装禁止」、QA Evaluator に stub_suspected 検査。外部境界タスクには実効果スモーク必須
- **配線検証**: 置換型タスクは `replaces[]` + L1 grep 検証必須（機械ゲート）。dev-phase 完了時に orphan detector が被参照ゼロの新規ファイルを警告

### フライトシミュレータ（record / replay / fault injection — batch#8, 2026-07-14 導入）

全 `claude -p` 呼出（`run_claude` チョークポイント）を録画し、API コストゼロで決定論的にリプレイし、任意の呼出点に故障を注入できる。ハーネス自体のバグ再現・回帰テストに使う。実装: `.forge/lib/simulator.sh`（common.sh が guarded source。env 未設定時は挙動差ゼロ）。

| env | 意味 |
|---|---|
| `RC_RECORD_DIR` | 設定時、実行された全呼出を `call-<id>-<agent>.json` に録画（失敗呼出も録画。response_b64 がリプレイの正） |
| `RC_REPLAY_DIR` | 設定時、録画から応答を再生（実 CLI を叩かない）。キーは (agent, per-agent 連番)、call_id フォールバック |
| `RC_REPLAY_STRICT` | `1`(既定)=miss は exit 97 / `0`=実 CLI へフォールスルー |
| `RC_FAULT_PLAN` | 故障プラン JSON。fault: timeout / budget_exceeded / rate_limit / malformed_json / empty_output / exit_1 / quota_exhausted |
| `RC_SIM_STATE_DIR` | 連番カウンタ等（既定: record/replay dir 配下の `.sim-state-<session>`） |

```bash
# 実ランを録画
RC_RECORD_DIR=.forge/recordings/$(date +%Y%m%d-%H%M) bash .forge/loops/ralph-loop.sh task-stack.json
# コストゼロでリプレイ
RC_REPLAY_DIR=.forge/recordings/20260714-1200 bash .forge/loops/ralph-loop.sh task-stack.json
# 故障注入（例は .forge/tests/fixtures/sim/*.json）
RC_FAULT_PLAN=.forge/tests/fixtures/sim/fault-rate-limit.json bash .forge/loops/ralph-loop.sh task-stack.json
```

注意:
- 優先順位: `FORGE_DRY_RUN` > fault > replay > real
- **リトライ・故障注入も per-agent 連番を消費する** — 録画時と呼出回数が変わる合成では `RC_REPLAY_STRICT=0`（lenient）を推奨
- 故障ペイロード文言は実測準拠の `SIM_*` 定数（simulator.sh）に集約。CLI 更新で文言が変わったら定数と録画 fixture を更新すること
- `quota_exhausted` は BUG-REPRO 用（現状ハーネスに quota 枯渇検出器なし → unknown 分類で futile リトライ）
- シナリオ回帰: `test-scenario-regressions.sh`（429 復旧 / budget 非リトライ / validate_json 復旧はしご）+ `test-scenario-session-counters.sh`

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
