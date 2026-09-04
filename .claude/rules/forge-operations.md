# Forge Harness 運用ガイド

## batch#11「止血バッチ」の運用変更（2026-09-03 導入）

2026-09-02 の全体監査（`.forge/docs/harness-audit-20260902.md`）で、直近本番ラン make-salesletter4.5f の
損失（LLM 時間の 13〜32%、人間介入 6 件、495 分の空白）の主因がハーネス自身と確定したことへの止血。
新機能ではなく「出荷 + 止血 + 計器」。**#11 に入れたのは直近本番ランで浪費時間に直結した経路と、それを計測する
最小配線のみ**（判断基準）。

- **出荷規則**: 作業ブランチ → master へ FF（`git push . <branch>:master`、非 FF は拒否される）→
  `git push origin master` → `forge-gtr.sh new`（既定 base origin/master、`--base` で上書き、
  `FORGE_GTR_NO_FETCH=1` で fetch 抑止）。master が origin/master より先行していれば new が警告する。
  Stop hook は未コミット変更 / 未追跡ハーネスファイル / origin/master 未反映のまま 7 日超の feature/* を警告
- **--work-dir 必須**: forge-flow / ralph-loop は `--work-dir` 未指定・不在・ハーネス自身（配下/親を含む）を
  preflight で exit 1（エスケープハッチなし）。これで checkpoint / ファイル数 / 聖域 / ERR trap / auto-revert の
  5 経路が常時有効になる。`forge-gtr.sh start` も `--work-dir <path>` を付けて使う
- **基準 SHA の意味論**: `checkpoints/<task>.base_ref` = タスク初回 attempt 開始時の HEAD（validate_task_changes /
  validate_test_sanctity / QA diff / guard hook の既存テスト判定の基準）。`.ref` = 各 attempt 開始時の HEAD
  （復帰先）。復帰は `git reset --mixed <ref>` + `checkout -- .`、checkpoint 時に無かった未追跡ファイルは
  削除せず `checkpoints/<task>.quarantine/` へ退避、`.salvage.patch` を次 attempt に注入
- **QA fail の分離**: QA Evaluator の fail は `qa_fail_count` だけを進め `fail_count` は据え置く（best-of-N /
  Fixer / Investigator を起動しない）。上限到達 auto-pass と実行エラー / 不正 JSON の pass は品質債務
  （qa_auto_pass / qa_execution_error / qa_invalid_output）に残る
- **Bash 返却 + guard hook**: Implementer / Fixer は Bash 可（L1 を実際に実行して報告）。代わりに全 claude -p
  呼出に `--settings .forge/config/claude-guard-settings.json`（PreToolUse: `.claude/hooks/forge-guard.sh`）を
  注入し、ハーネス配下（`.forge/` `.claude/` `forge-*.sh` `CLAUDE.md`）・WORK_DIR 外への書込、
  protected_patterns（`.forge/**` を追加）、既存テストの改変（base_ref 基準、allows_test_edits で解除）、
  `git reset/checkout/clean/push/rebase/stash/restore/switch`、ハーネス側リポジトリ操作、`rm`/リダイレクト/
  `sed -i`/`cp` の書込先を機械的に拒否する。拒否は `.forge/state/guard-denials.jsonl`（wd / norm 付き）と
  封筒の permission_denials に残る。`FORGE_GUARD_DISABLE=1` で無効化（戻し用）。
  hook は cwd=WORK_DIR で動き、パスは Windows 長形式（cygpath -ml）に正規化する — 8.3 短縮名や MSYS /tmp の
  まま渡すと WORK_DIR 内も「外」と判定される（実 CLI スモークで実測）
- **ブレーカー**: `max_duration_minutes` 600→1440、`per_call_guards.max_budget_usd` 15→0（矛盾していた
  session 120 との整合）。総時間ブレーカー発火後に未完了タスクが残れば flow-state に paused を書いて
  ralph が exit 75、forge-flow は「一時停止（再開可能）」として `completed_phase=2` を書かない。
  再開は同じ引数に `--resume`
  - `--resume` 時、作業ディレクトリの未コミット変更は CRITICAL で止めず「forge: resume checkpoint」コミットに
    自動保全して続行する（pause 後の作業ツリーは前セッションの試行途中の変更を必ず含む — カナリア 2026-09-04）。
    通常起動（--resume なし）では従来どおり未コミット変更があれば停止
- **カナリア 2026-09-04（canary-b11、cli-lib 7 タスク、7/7 完了・Phase 3 pass・KPI 8/12）で直したもの**:
  locked_decision の assertions は毎タスク後は**タスクの locked_decision_refs 分のみ**（全件は Phase 3 で走らせ、違反は
  `locked-assertion-violations.txt` + 債務 locked_assertion_violation + gaps + 通知）/ `_resolve_glob_search_dir` が
  `*.md` のような単層 glob で存在しないパスを返し grep_present が常に違反だった真因を修正（パターンは `-e` 渡し）/
  `forge-gtr.sh start` が forge-flow の非 0 終了を黙殺していたのを表示 / `--resume` の未コミット変更は resume checkpoint
  コミットに保全 / guard hook が `node -e` の正規表現リテラル（`/
/g` 等）を WORK_DIR 外パスと誤拒否 /
  TERM 中断は ralph の cleanup が task-events に `interrupted` を書き、手動差戻しは `human_requeue` イベントを残す運用
  （collect.sh の human_interventions = rework + errors interrupted + interrupted + human_requeue）。
  記録: `Desktop/forge-research-harness-v1-worktrees/project-canary-b11/.forge/docs/canary-batch11-2026-09-04.md`
- **errors.jsonl**: `exit_code` フィールド追加。exit 143/130 → interrupted、21 → budget_exceeded、
  22 → quota_exhausted、125-127 → env_error（message より優先）。中断（143/130）は fail_count を進めず
  再キュー（interrupted_requeued イベント）。RETRY_NONRETRYABLE_EXITS 既定 "2 21 22 130 143"
- **計測台帳**: `bash .forge/eval/collect.sh --state .forge/state [--append]` が 1 ラン = 1 行を
  `.forge/state/runs.jsonl` に残す（forge-flow の終了 trap が自動追記。run-end.json に end_reason）。
  `--kpi <run_id>` はカナリア 12 項目（human_interventions 0 / gap ≤ 5 / bon_* 0 / errors_unknown 0 /
  cost > 0 かつ全呼出計測 / attempts ≤ 1.5, max ≤ 3 / completed / launches 1 / qa_auto_pass 0）で exit 0/1。
  比較基準は `.forge/eval/baseline-runs.jsonl`（contents-make / 4.5f の遡及 2 行）。
  fail_recorded の detail.cause（implementer / harness_guard / l1 / assertion / l3 / authoring / mutation）
- **heartbeat**: run_claude の前後で stale 閾値を自己申告（timeout/60 + 5 分、完了後 15 分に戻す）。
  monitor の固定 15 分閾値による長時間呼出の誤報を止める
- **コスト計器**: 封筒（--output-format json）からキャッシュ 2 系統 / session_id / modelUsage 合算も取る。
  `FORGE_KEEP_ENVELOPE=1` で `.raw-envelope` を残す（監査・フィクスチャ採取）
- **probe / Phase 3**: capability_tags に cmd:claude / git / jq / bash / python 等を出す（Planner の deferred
  逃げを止める）。Phase 2 開始時に再プローブ（`FORGE_SKIP_ENV_PROBE=1` で抑止）。Phase 3 の L2/L3 集計は
  validation v2 の checks も数える（旧集計は 4.5f で L2 0/28）。`npx vitest run run x` の二重化を除去
- **research**: 最終レポートに `timeouts.final_report_sec`（1200）を適用。researcher の timeout（124）は
  非リトライ。DA の指摘を criteria 生成プロンプトに注入（`{{DA_FINDINGS}}`）。
  `/sc:research` も `--research-config` を渡す。所要時間の目安は Phase 1 約 80 分（実測）
- **development.json の意図値**（意図せず変わっていたら戻す）: checklist_verifier.enabled=false /
  safety.max_files_per_task=30, max_files_hard_limit=60 / evidence_da.enabled=false /
  safety.auto_revert_on_regression=false / best_of_n.enabled=false（profiles/content.json も false）。
  jq の `// true` は false を潰すので boolean 設定は `cfg_bool` で読む（test-config-integrity が pin）
- **calibration**: `feedback.sh <task> <verdict> "理由" --correct <judgment>` で本来の正解を明示できる
  （accept-with-notes の既定は評価器自身の判定 = 乖離 0）。本番 `calibration-data.jsonl` の cal-20260821-274
  は 2026-09-03 に手動訂正済み（`.bak-20260903-batch11` にバックアップ）:
  ```bash
  cp .forge/state/calibration-data.jsonl .forge/state/calibration-data.jsonl.bak-20260903-batch11
  jq -c 'if .id=="cal-20260821-274" then .correct_judgment="pass" | .correction_note="..." else . end' \
    .forge/state/calibration-data.jsonl > tmp && mv tmp .forge/state/calibration-data.jsonl
  ```
- **自律運用の共通 2 文**: 全 claude -p 呼出に `--append-system-prompt`（`FORGE_APPEND_SYSTEM_PROMPT=''`
  で無効化）。サブエージェント上限 `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` / `_CONCURRENT_SUBAGENTS=4`
  を bootstrap.sh が既定 export
- **敵対レビュー（2026-09-03、2 体）で直したもの**: forge-flow は子ループを `_forge_run_child`（bg + wait）で
  実行し `set -e` 下でも exit code を捕捉（従来は ralph の exit 75 で forge-flow 自体が落ち paused 経路が
  dead code）、TERM/INT は子へ転送してから終了記録。ralph の INT/TERM trap は後片付け後に必ず exit（従来は
  claude が 143 で死んだ後に次タスクを拾って再起動）。`.base_ref` は「無ければ書く・あれば触らない」、
  破棄は handle_task_pass と feedback.sh reject（qa_fail_count も 0 に）。「実行可能タスクなし」は完了ではなく
  一時停止（exit 75）。中断再キューは fail_count が上限なら MAX-1 に降格。QA 差戻しはカウンタが進まなければ
  handle_task_fail に落とす（無限ループ防止）。回帰後の自動復帰は commit を巻き戻さない（keep_commits）。
  hook は引用符を解釈する字句解析（グルーピング / bash -c / eval / cd 追跡 / ヒアドキュメント / git 全体
  オプション / GIT_DIR= / >| / cp -t / sed -Ei / FORGE_GUARD_* 間接指定 / .claude/settings*.json）に
  改め、Bash 側の書込先にも protected_patterns・聖域を適用。`FORGE_GUARD_PATTERNS` を run_claude が
  事前展開して hook の jq を 1 回減らす。collect.sh は型不一致を矯正して必ず 1 行出す
- **#12（衛生バッチ）へ送ったもの**: simulator 削除 / UX 削減 / 死コード・legacy 経路の削除 /
  DISCOVERY_EXCLUDE の整理と test-run-task-decomposition 8/37 の修復 / docs 整理 / .docs/research の
  RESEARCH_DIR 移設 / content プロファイルの task 粒度 QA 切替 / RUN-REPORT と status.sh /
  permissions.deny と --setting-sources / 総時間ブレーカーのセッション横断累積と自動再開 /
  research-config の段毎再読込 / quality-debts への run_id 後付け / Kernel 抽出 / origin の feature/* 削除
  （ユーザー確認後: `git push origin --delete feature/<name>`）

## batch#10「Thin Harness」の運用変更（2026-08-02 導入）

Opus 5 世代の自律性向上を受けた原理転換: **品質保証の主役は決定論テスト（L1/L2/L3）+
統合 Evaluator 1体（任務=テスト監査）。監督層の多重 LLM 判定は廃止方向**。
根拠: salesletter2 実ランの Investigator 診断 16 件中 15 件がハーネス自身の欠陥起因
（モデル起因 0件）、判定者9体は呼出の37%を占めるが実欠陥検出の実績が乏しい。

- **判定者統合**: Evidence DA / Mutation Auditor / Checklist Verifier / Best-of-N judge は
  **config OFF**（development.json / mutation-audit.json）。物理削除はカナリア案件で
  品質不変を確認後の別バッチ（graceful skip は全て検証済み。裸呼出の除去が必要な箇所は
  mutation-audit.sh:387 / dev-phases.sh:406 — 削除時に `set -e` クラッシュ注意）
- **統合 Evaluator（旧 QA Evaluator）**: 任務を「実装の再判定」→「テスト監査」に転換。
  behavior→assertion 対応 / コミット済み成果物の参照 / fail-closed ガードの負テスト /
  assertion 強度を監査する。視野は作業ツリー diff + 直近コミット + タスク参照ファイル実体
  （qa_diff_scope_blindness 根治）
- **validation の書き手**: Planner はゴールと制約のみ（6〜10 の機能単位タスク）。
  L1/L2/L3 の実コマンドは**実装完了直後に Implementer が執筆**（task_author_validation）し、
  直後に validate_authored_validation（validation-gates.sh）が生成時と同じ規則 + L1 必須で
  機械検査する。「実装を見ずに書かれた CLI 契約が結合時に爆発する」事故の根治
- **phase scope 突合**: 生成時に criteria_refs の機械照合 + scope_description の LLM 照合。
  「A腕ランナー欠落」型（scope に明記されたのにタスク化されない）を起動前に検出
- **ロールバックの意味論**: checkpoint 復帰は「HEAD 全消し」ではなく「チェックポイント
  時点への復帰」（.patch 再適用）。今回試行の変更は .salvage.patch に退避され、次試行の
  プロンプトに注入される（scope 外修正の消失ループ根絶）
- **コスト計測**: run_claude は全呼出エンベロープ（--output-format json）から
  usage/total_cost_usd を抽出。costs.jsonl 復活・$120 セッションブレーカー実効化。
  dashboard / scaffold-report の数字が初めて信頼できるようになった
- **ワークフロー・プロファイル**: `.forge/config/profiles/` 参照（CLAUDE.md の表）。
  Phase 0 で workflow を決め research-config.json に記録する

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

### batch#8 その他の運用変更（2026-07-14）

- **validation v2（型付き checks）**: L1/L2 検証は `.validation.checks[]`（verb: file_exists/grep_ref/run_test/http_check/effect_smoke/agent_flow/raw_shell）が推奨形式。layer に checks が1件でもあればその layer は **v2 が権威**（legacy command は warn 付き無視）。手動編集時も生成ゲート `validate_v2_checks` と同じ規則に従うこと（args/argv は配列要素・パスは WORK_DIR 相対・L1 に server/env: requires 禁止）。L3 は従来の `layer_3[]` strategy 配列のまま
- **モデル hot-reload**: `development.json` のモデル系フィールドはタスク境界で自動再読込される（`hot_reload.models: false` で無効化）。fable⇄opus 切替は config 書換のみでよい — 再起動・状態手術は不要
- **session-counters は session_id スコープ**: 別セッション（forge-flow 再起動 = 新 session_id）では自動 0 リセット。「resume 前に手動 0 リセット」の運用は不要になった。standalone ralph でクラッシュ復旧を継続したい場合のみ `FORGE_SESSION_ID` を export して再起動
- **Phase 1 監視**: research-loop も heartbeat.json を書く（ステージ別 stale 閾値の自己申告付き）。/sc:monitor はリサーチ中も実状態を表示し、ハング検出が機能する（2026-07-07 gap 解消）
- **品質債務台帳**: L2/L3 が後で実行 PASS すると該当債務は自動 resolve。表示は「今回セッション N 件 / 全期間 M 件」の2段（`[WARN] QUALITY_DEBTS=全期間 QUALITY_DEBTS_SESSION=今回`）
- **bash -c ラッパー禁止**: validation コマンドは生コマンドで書く（生成時 sanitize が unwrap + L1 実行時も二重防御あり）
- **テストは並行実行安全**: 全テストの /tmp fixture は PID サフィックス付き。複数 worktree での同時スイート実行が可能

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

### UX判定システム + キャリブレーション（batch#9, 2026-07-20 導入）

「たたき台→実践レベル」ギャップの主成分である UX 品質への構造対策。設計書:
`.forge/docs/ux-judgment-and-calibration-spec.md`

- **3チャネル判定**（証拠の直交性）: 構造検査（非LLM: コントラスト/タップ領域/フォーカス順/レイアウト崩れ — `ux-structural-check.js`。タップ既定 24px=WCAG 2.5.8 AA・インラインリンクは対象外・画像背景上テキストはコントラスト判定不能として skip）+ 模擬ユーザー（スクリーンショットのみ知覚・座標操作・行動証拠）+ 美観ジャッジ（`.forge/lenses/*.md` レンズ別、2枚上限）
- **発火**: `ux-judgment.json` の phase_config（mvp=構造のみ per_task / core=+sim_user / polish=全チャネル。phase_exit は dev-phase 完了処理に統合）。未知 phase 名は「最終 phase→polish、他→core」にフォールバック
- **verdict 突合**: 全チャネル一致 pass→続行 / 一致 fail→集約器が統合 must_fix（最大3件・resolution_criteria 必須・反証不能リジェクト・矛盾調停）→ ux-fix タスク自動生成で同一 phase 続行 / **不一致→record_and_continue**（ux_disagreement 債務 + 通知 + 暫定 pass）
- **人間裁定**: `bash .forge/loops/feedback.sh <task-id|ux-<phase>> <reject|accept-with-notes> "理由"` — evaluator 別キャリブレーション記録 + reject は pending 差戻し + ux_disagreement 債務解消。**completed→pending の raw jq 手動差戻しも自動検出**され記録される（task-events 経由の2経路検出）
- **キャリブレーション**: 記録は evidence-da / qa-evaluator / ux-judgment の Few-Shot に注入される（P0 で配管修復済み）。乖離率は dashboard / print_summary に常時表示、**0件時は「無較正」警告**
- **レンズ実測プルーニング**: fix タスクの accepted-finding rate（completed かつ人間 reject なし）を dashboard にレンズ別表示。直近10件で 0.5 未満は無効化候補警告（自動無効化はしない）
- **sim-user の知覚制限は機械強制**: Playwright MCP を `--caps=vision` で起動し、a11y snapshot / DOM read 系ツールを `--disallowed-tools` でブロック（ツール名は ux-judgment.json で管理。2026-07-20 に @playwright/mcp v0.0.78 で実名確認済み）+ トランスクリプト事後検証ゲート（`sim_user.transcript_gate`: 既定 **warn** = 債務記録のみ。**TODO: 実ランで debug ログ形式を確認したら invalid に昇格すること** — 誤爆でチャネルを殺さないための暫定）
- **sim-user はテキスト入力が苦手**（座標クリック + 単一キーのみ）: scenario-generator が入力必須ゴールを避ける指針込み。入力が本質のプロダクトでは完遂率をさらに割り引いて読むこと
- **シナリオは criteria fingerprint 付き**: criteria が変わると自動再生成。別プロジェクトの残骸再利用は起きない（ux-scenarios.json は新セッションでアーカイブもされる）
- **判定不能・fix不能は必ず台帳に残る**: fix 判定でタスク0件 → `ux_unactionable`、チャネル全 invalid → `warn_gate`、サーバー不能 → `env_blocked`。人間裁定（feedback.sh）は evidence-da/qa だけでなく**美観ジャッジ/集約器のプロンプトにも Few-Shot 還流**される
- **注意**: sim_user/aesthetic チャネルはサーバー到達可能時のみ実行（不能時は env_blocked 債務で繰延）。per_task 構造検査はサーバー起動失敗2回連続で phase 完了まで自動 skip。ablation.json `components.ux_judgment=false` で全体 OFF

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
