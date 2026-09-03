# .forge/eval — 計測台帳と観測シート（batch#11）

「ハーネスの全コンポーネントはモデル欠陥への仮説」であり、仮説の当否は本番ランの数字で判定する。
ここには **1 ラン = 1 行の台帳（runs.jsonl）** を作る道具と、次の本番案件で埋める観測シートを置く。

## 道具

| ファイル | 役割 |
|---|---|
| `collect.sh` | `.forge/state`（または archive）から 1 行を生成。`--append` で `.forge/state/runs.jsonl` に追記、`--latest` で run_id 毎の最新、`--kpi <run_id>` でカナリア KPI 判定（exit 0/1）。bash + jq のみ |
| `baseline-runs.jsonl` | 遡及 2 行（contents-make 2026-08-05 / make-salesletter4.5f 2026-08-19）。比較基準 |
| `canary/research-config.cli-lib.json` | カナリア（S26）の research-config |

forge-flow は終了 trap で `run-end.json` を書き、`collect.sh --append` を自動で呼ぶ。手動で取り直す時:

```bash
bash .forge/eval/collect.sh --state .forge/state                    # 1 行を表示（追記しない）
bash .forge/eval/collect.sh --state .forge/state --append           # 追記
bash .forge/eval/collect.sh --latest | jq -c '{run_id, attempts_per_task, gap_min, errors_unknown, cost_usd}'
bash .forge/eval/collect.sh --kpi 2026-09-10-xxxxxx-000000          # カナリア判定
```

## 行の主な列（定義）

| 列 | 定義 | 4.5f（基準） |
|---|---|---|
| launches | metrics ∪ task-events の session_id 種類数（下限 1）。再起動の回数 | 4 |
| attempts_per_task / max_attempts | task_started ÷ tasks_total / 1 タスクの最大 task_started | 1.86 / 6 |
| fail_recorded / fail_cause | fail_recorded イベント数 / detail.cause 内訳（implementer / harness_guard / l1 / assertion / l3 / authoring / mutation / unknown） | 24 / unknown 24（旧ラン） |
| qa_fail / bon_fired / bon_apply_failed | QA 差戻し / best-of-N 起動 / patch 適用失敗（source: task-events → notifications） | 13 / 5 / 5 |
| investigator / rework_detected / human_interventions | Investigator 起動 / 人間差戻し / rework + interrupted（kill） | 3 / 0 / 0 |
| errors_unknown / errors_by_category | errors.jsonl の error_category=unknown | 4（全て kill だった） |
| llm_calls / cost_usd / cost_measured_calls | metrics 件数 / cost 合算（全 0 は null）/ cost>0 の件数 | 131 / null / 0 |
| llm_min / wallclock_min / gap_min | duration 合計 / 最初〜最後 / 呼出間の idle（duration 控除）が 5 分超の合計 | 1352 / 1848 / 531 |
| quality_debts | このランの session に属する債務（type 内訳、open） | 19（qa_auto_pass 2） |
| end_reason | run-end.json（completed / paused / error / signal:TERM / checkpoint_quit …） | unknown(pre-batch11) |

## カナリア KPI（S26、`--kpi` が判定）

human_interventions 0 / gap_min ≤ 5 / bon_apply_failed 0 / bon_fired 0 / errors_unknown 0 /
cost_usd > 0 かつ cost_measured_calls == llm_calls / attempts_per_task ≤ 1.5 かつ max_attempts ≤ 3 /
end_reason completed / launches 1 / qa_auto_pass 0

## 観測シート（次の本番案件で記入 — 合否には入れない副次観測）

| # | 観測 | どこを見る | 期待 | 実測 |
|---|---|---|---|---|
| 1 | 判定者 OFF の実効 | `calls_by_stage` に checklist-verifier / mutation-auditor / evidence-da が出ない | 0 | |
| 2 | guard hook の拒否内容 | `.forge/state/guard-denials.jsonl`（reason / target / wd / norm） | 誤拒否 0（正当な WORK_DIR 内書込が outside_work_dir にならない） | |
| 3 | quarantine の発生 | `.forge/state/checkpoints/<task>.quarantine/` と `.salvage.patch` | 発生時に成果物が残っている | |
| 4 | 安全機構 5 経路の誤発火 | fail_cause.harness_guard / notifications（変更ファイル数上限・聖域） | 誤発火で全タスク失敗しない | |
| 5 | heartbeat 誤報 | /sc:monitor の heartbeat_stale（閾値 = timeout/60+5） | 0 | |
| 6 | Phase 3 の L2 集計 | integration-report の "L2 tests: N defined" | 0/N でない（v2 checks を数える） | |
| 7 | forge-flow.log | 起動境界行 `===== launch …` と末尾（truncate されない） | 全 launch の履歴が残る | |
| 8 | run-end.json / runs.jsonl | end_reason と 3 行目 | completed、KPI exit 0 | |
| 9 | validation authoring | attempt 2 到達率、2 回失敗 → handle_task_fail（fail_cause.authoring） | 低い | |
| 10 | authoring の転記誘因 | L1 コマンドが exit_criteria と逐語一致した task 数 | 0（CLI 契約は形だけ渡す） | |
| 11 | Planner の locked_decision_refs 網羅 | task-stack の locked_decision_refs に全 LD が現れる | 全件 | |
| 12 | implementer 分/タスク | metrics の implementer duration（p50 / max） | max ≤ 40 分 | |
| 13 | max_files_hard_limit 60 | notifications の「変更ファイル数上限超過」 | 0 | |
| 14 | CLI 契約不一致 | Phase 3 で exit_criteria コマンドが「フラグ不一致」で落ちる回数 | 0（4.5f: 5） | |
| 15 | guard hook の遅延 | ツール呼出 1 回あたりの hook 所要時間（Windows 実測 2026-09-04: 約 1.9 秒 = bash 起動 0.9 + jq 0.9）× タスクあたりのツール呼出数 | タスクあたり +3 分以内。超えるなら #12 で jq 不要の hook（node 単体等）を検討 | |

記入したら `.forge/docs/canary-batch11-<date>.md` に残し、#12 の go/no-go を数字で決める。
