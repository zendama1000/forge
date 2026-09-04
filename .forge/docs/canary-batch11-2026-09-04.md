# カナリア batch#11 — 2026-09-04（project-canary-b11 → Desktop/canary-runs-cli）

- ハーネス: master 3f1b05a（batch#11 止血バッチ + レビュー修正、回帰 #3 68/68）
- 起動: 2026-09-04 12:17 `forge-gtr.sh start canary-b11 … --work-dir Desktop/canary-runs-cli --research-config … --phase-control auto`
- 題材: runs.jsonl 集計 CLI `forge-runs`（cli-lib、Node 22 単体、locked 3 件）
- KPI 判定: `bash .forge/eval/collect.sh --kpi <run_id>`（12 項目、exit 0 で合格）
- 観測シート: `.forge/eval/README.md` の 15 項目

## タイムライン（観測メモ、随時追記）

| 時刻 | 出来事 | 判定 / 備考 |
|---|---|---|
| 12:17:37 | 起動境界行 `===== launch … (resume=false)` が forge-flow.log 先頭に出る | R07a（追記化）OK |
| 12:17:45 | `--work-dir` の preflight（必須化・自己書込み拒否・安全チェック）通過 | R20a OK |
| 12:17:47 | `[CONFIG] WARNING: unknown field: .agent_effort` | 既存の設定警告。#12 の衛生項目へ |
| 12:18:12 | Phase 1: Scope Challenger 開始（opus）→ 12:21:35 完了 | 3.4 分 |
| 12:21:38 | Researcher 6 視点を並列起動（technical / cost / risk / alternatives / test_design / data_contract） | |
| 12:41:52 | Researcher [technical] が 1200 秒でタイムアウト。errors.jsonl: `timeout / exit_code 124`、再試行なし（他 5 視点は続行） | R07a の exit_code 記録 OK / R19a の 124 非リトライ OK。**観測: TIMEOUT_RESEARCHER=1200 は opus + WebSearch では 1/6 が超える。debug ログでは締切直前まで出力中だった** |

| 12:42:13 | Researcher [data_contract] も 1200 秒でタイムアウト（2/6 欠落、4 視点で続行） | 「全滅時のみ中断」の設計どおり。#12: `researcher_sec` 1200→1800 を検討 |
| 12:55:25 | Synthesizer（311 秒、$1.32）→ DA r1（463 秒、$2.26、HIGH 5 / MEDIUM 3）完了 | DA は小型 CLI にも HIGH 5 件と厳しめ。criteria に da_risk_notes 8 件が伝搬 |
| 13:12:58 | Phase 1 完了（55 分）: criteria = phases mvp/core/polish、L1 9 / L2 3 / L3 5 | 見込み 80 分より速い |
| 13:13:25 | Phase 1.5: Task Planner 試行 1/3 開始 | |
| — | **計器**: costs.jsonl に 9/9 呼出のコスト（計 $19.59、封筒経由）。metrics.jsonl は並列 Researcher 6 件が cost null（別プロセスで _LAST_* が親に届かない） | collect.sh をその場で修正（a722431: costs.jsonl を正とする）。metrics 側の補完は #12 |

| 15:12:50 | feat-cli-contract 再開（interrupted → pending、fail_count=1 のまま Fixer 経路）→ 15:27:05 完了。LD-3 の assertions（README の --format / --where）通過 | glob 修正 d7d77cc の実効確認 |
| 15:27:17 | dev-phase mvp 完了処理: 回帰 26 秒 → auto でチェックポイント省略 → core | |
| 15:45:39 / 16:46:50 / 17:06:08 | feat-filter-fields（18 分）/ feat-table-rendering（QA fail 1 回 → 2 回目で完了）/ feat-json-stats（19 分） | **R04 QA fail 分離が実機で初通過**: `QA 差戻し（1/3）— fail_count 据え置き。best-of-N / Fixer / Investigator は起動せず、Implementer が QA feedback 付きで再試行` |
| 17:32:43 | feat-e2e-scale-docs 初回: L3-005（cli_flow）fail — verify_command `jq -e '.count >= .n' .tmp/e2e-stats.json` が JSON をオブジェクトと仮定、実装の `--stats --format json` は配列 | **CLI 契約不一致 1 件**（観測 #14）。Phase 1.5 で書かれた L3 の JSON 形状は R08a の CLI 契約注入（先頭コマンド形のみ）に含まれない。Fixer 2 回目で 3 L3 pass |
| 17:51:48 | Phase 3: L2 4/4 pass、**Locked Decision Assertions（全件）通過**（新設の Phase 3 全件検査）、integration-report status=pass、locked_assertion_violations=0 | 観測 #6: L2 集計が 0/N でない |
| 17:53:36 | Forge Flow 完了。PHASE4-HANDOFF.md 生成（未解決債務 1: l2_skip feat-cli-contract `requires file:test`）。run-end.json end_reason=completed、runs.jsonl 3 行目（同 run_id は最後が正） | 経過 161 分（このセッション）。全体 wallclock 329 分 |

## KPI（`collect.sh --kpi 2026-09-04-d19546-121756` = 8/12、exit 1）

| 項目 | 結果 | 値 | 原因 / 判断 |
|---|---|---|---|
| human_interventions == 0 | PASS（**実態は 2**） | 0 | 台帳が TERM 中断と手動差戻しを数えていなかった → deac787 で `interrupted` / `human_requeue` イベントを加算。実態: 手動差戻し 1 + TERM 停止 1 |
| gap_min ≤ 5 | FAIL | 43.87 | 内訳 18.0（Phase 1 の criteria + final-report 生成 = **metrics 未記録の呼出**。costs.jsonl には記録あり → #12: research-loop の 2 呼出を metrics_record に乗せる）/ 8.5（pause → ハーネス修正 → resume）/ 17.4（TERM 停止: kill された Fixer 10 分は metrics に残らない + 再開 5 分）。**ハーネス起因の空白は 0** |
| bon_apply_failed == 0 / bon_fired == 0 | PASS | 0 / 0 | best-of-N OFF が実効 |
| errors_unknown == 0 | PASS | 0 | errors: timeout 2（researcher 1200 秒）のみ |
| cost_usd > 0 かつ全呼出計測 | PASS | $82.28 / 41/41 | costs.jsonl 正（a722431） |
| attempts_per_task ≤ 1.5 / max ≤ 3 | FAIL | 2.0 / 4 | fail 5 = assertion 4（ハーネス欠陥、修正済）+ L3 1（契約不一致）。QA 差戻し 2、中断再開 1。欠陥修正後の 5 タスクは attempts 1.4 |
| end_reason == completed | PASS | completed | |
| launches == 1 | FAIL | 3 | pause 再開 + TERM 再開（いずれもハーネス欠陥の修正のため） |
| qa_auto_pass == 0 | PASS | 0 | |

計: llm_calls 41 / llm_min 340.6 / wallclock 329 / Phase 1 55 分 $19.6 / Phase 2+3 のタスク当たり Implementer p50 11.4 分。
**判断**: KPI 不合格 4 件は全てカナリア中に見つけて直したハーネス欠陥（assertion glob / 毎タスク全件 / resume 停止）とその介入に帰着する。
修正後の 5 タスク区間（15:12〜17:53）は人手 0・空白 0・attempts 1.4・QA 差戻し 1・契約不一致 1 で走った。**次の本番案件は
deac787 以降の master で起動し、この 12 項目を再判定する**（本番が主サンプル）。

## 観測シート（`.forge/eval/README.md` の 15 項目）

| # | 観測 | 実測 |
|---|---|---|
| 1 | 判定者 OFF の実効（calls_by_stage） | checklist-verifier / mutation-auditor / evidence-da / best-of-n 判定 = **0**。内訳: implementer 13 / qa-evaluator 8 / other(author 7 + criteria/report) 8 / researcher 6 / task-planner 2 / SC / Syn / DA / investigator 各 1 |
| 2 | guard-denials.jsonl の内容 | **7 件**: outside_work_dir 6（/tmp への mkdir・リダイレクト 4 = 設計どおり、エージェントは .tmp/ に切替えて続行。**正規表現リテラル `/
/g` `/[^x00-x7f]/.test` の誤拒否 2 → deac787 で修正**）、guard_var 1（`echo $FORGE_GUARD_HARNESS_ROOT` — 読取だけだが設計どおり拒否）。timestamp が null（#12: hook の記録に時刻を足す） |
| 3 | quarantine の発生 | **0**（聖域違反・best-of-N・ERR trap のいずれも発火せず。L1/assertion 失敗は作業ツリーを巻き戻さない現行意味論のため salvage も 0） |
| 4 | 安全機構 5 経路の誤発火 | **0**（変更ファイル数上限・聖域・ERR trap・auto-revert の通知なし。checkpoint は 7 タスク全てで作成） |
| 5 | heartbeat 誤報 | monitor は未実行。heartbeat.json の stale_threshold_min は implementer 中 65（3600/60+5）を自己申告していた。誤報の観測 0 |
| 6 | Phase 3 の L2 集計 | **L2 4 defined / 4 pass**（旧集計なら 0/N）。L3 は per-task 5 件実行済みで Phase 3 側 0 |
| 7 | forge-flow.log の起動境界行 | `===== launch` ×3（resume=false / true / true）、追記維持 |
| 8 | run-end.json / runs.jsonl | paused → signal:TERM → completed の 3 行。`--latest` で最終行。KPI 8/12 |
| 9 | validation authoring の失敗経路 | **7/7 が attempt 1 で通過**（v2 構造 / requires 充足とも問題なし）。fail_cause.authoring 0 |
| 10 | authoring の転記誘因 | L1 コマンド 14 本中 exit_criteria と逐語一致 **1**（CLI 契約注入は形だけ渡している） |
| 11 | Planner の locked_decision_refs 網羅 | LD-1 / LD-2 / LD-3 全件が task-stack に出現 |
| 12 | implementer 分/タスク | n=13、p50 11.4 分、max 32.3 分（feat-table-rendering 初回）≤ 40 分 |
| 13 | max_files_hard_limit 60 | 超過通知 **0** |
| 14 | CLI 契約不一致 | **1**（L3-005 verify_command の JSON 形状仮定）。4.5f の 5 から減少。#12: L3 の verify_command も契約注入の対象に |
| 15 | guard hook の遅延 | 事前実測 約 1.9 秒/呼出。タスク当たりのツール呼出数は未計測（#12: 封筒 num_turns から推定） |

## カナリアで見つけて直した欠陥（全て master、origin push 済み）

| commit | 欠陥 | 発見経路 |
|---|---|---|
| d7d77cc | **真因**: `_resolve_glob_search_dir` が `*.md` で `<wd>/*.md` を返し grep_present が常に VIOLATION。副次: `--format` を grep オプション誤認 | setup 3 連敗 → Investigator「scope=criteria」→ pause / feat-cli-contract 再発 |
| dc539fd | 毎タスク後に locked_decisions 全件の assertions が走る（最終成果物前提の assertion が初回タスクで落ちる）。タスク参照分のみに絞り、全件は Phase 3 | 同上 |
| 1f04f2c | pause 後の `--resume` が未コミット変更で常に preflight 停止 → resume checkpoint コミットに自動保全 | 再開時 |
| 9fbc741 | `forge-gtr.sh start` が forge-flow の非 0 終了を黙殺 | 再開時 |
| 465ddc0 | `unknown field: .agent_effort` 警告（スキーマ欠落） | 起動毎 |
| deac787 | guard hook の正規表現リテラル誤拒否 / 台帳が TERM 中断・手動差戻しを数えない | guard-denials / KPI 突合 |
| a722431 | collect.sh のコストは costs.jsonl を正に（並列 Researcher は metrics 側 null） | Phase 1 |

## 実機で初通過した経路（batch#11 の実効）

no_runnable_tasks → exit 75 → paused（偽完了なし）→ run-end.json → runs.jsonl → `--resume` で Phase 2 再入 /
TERM → 子へ転送 → 現行呼出完了後に interrupted 記録 → exit 143 → signal:TERM → resume（fail_count 据え置き）/
QA fail 分離（fail_count 据え置き・Fixer 非起動）/ Phase 3 の L2 v2 集計 / 全 LD assertions の Phase 3 検査 /
封筒コスト 41/41 / guard hook の実拒否 / heartbeat 閾値自己申告 / validation authoring 7/7 / Investigator の正確な切り分け。

## #12 へ送る観測

- research.json `researcher_sec` 1200 → 1800（opus + WebSearch で 2/6 が超過）
- research-loop の criteria / final-report 呼出を metrics_record に乗せる（gap 18 分の正体）。kill された呼出も metrics に痕跡を残す
- エージェントの git commit は `wip:` 接頭辞を指示（Fixer が `task: … completed` 様式で commit していた）
- L3 の verify_command（JSON 形状）も CLI 契約注入の対象に
- guard-denials.jsonl に timestamp / hook 所要時間を記録し #15 を実測
- QA Evaluator の fail 1 件（feat-table-rendering）は較正 0 件のまま → Phase 4 で feedback.sh 裁定を入れる
