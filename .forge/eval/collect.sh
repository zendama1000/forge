#!/bin/bash
# collect.sh — 1 ラン = 1 行の計測台帳（runs.jsonl）を .forge/state から生成する（batch#11 R15）
#
# 依存: bash + jq（+ git があれば harness_rev）。bootstrap.sh / common.sh は source しない
#（forge-flow の終了 trap から呼ばれるため、ハーネス本体の状態に触れず・失敗しても本流を止めない）。
#
# 使い方:
#   bash .forge/eval/collect.sh --state .forge/state                 # 1 行を stdout へ（append しない）
#   bash .forge/eval/collect.sh --state .forge/state --append        # runs.jsonl に追記（jq -e で自己検証）
#   bash .forge/eval/collect.sh --state .forge/state/archive/<ts> --append --end-reason archived
#   bash .forge/eval/collect.sh --latest                             # run_id 毎の最新行
#   bash .forge/eval/collect.sh --kpi <run_id>                       # カナリア KPI 判定（exit 0/1）
#   env RUNS_FILE=<path> で台帳の場所を差し替え（テスト用。既定 <state>/runs.jsonl）
#
# 行の意味: 1 行 = 1 launch（append-only。同 run_id は最後の行が正、--latest で dedupe）。
# タイムスタンプは task-events=UTC / metrics・notifications=+09:00 の混在を epoch に正規化する。
# 計測できない値は null + incomplete[] に理由を残す（黙って 0 にしない）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="${FORGE_HARNESS_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

STATE=""; APPEND=false; LATEST=false; KPI=""; END_REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="${2:-}"; shift 2 ;;
    --state=*) STATE="${1#*=}"; shift ;;
    --append) APPEND=true; shift ;;
    --latest) LATEST=true; shift ;;
    --kpi) KPI="${2:-}"; shift 2 ;;
    --kpi=*) KPI="${1#*=}"; shift ;;
    --end-reason) END_REASON="${2:-}"; shift 2 ;;
    --end-reason=*) END_REASON="${1#*=}"; shift ;;
    --harness-root) HARNESS_ROOT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[collect] 不明な引数: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$STATE" ] || STATE="${HARNESS_ROOT}/.forge/state"
RUNS_FILE="${RUNS_FILE:-${STATE}/runs.jsonl}"

command -v jq >/dev/null 2>&1 || { echo "[collect] jq が必要です" >&2; exit 2; }

# ===== --latest / --kpi は台帳だけを読む =====
if [ "$LATEST" = "true" ]; then
  [ -f "$RUNS_FILE" ] || exit 0
  jq -c -R 'fromjson? // empty' "$RUNS_FILE" | jq -s -c 'group_by(.run_id) | map(last) | .[]'
  exit 0
fi

if [ -n "$KPI" ]; then
  [ -f "$RUNS_FILE" ] || { echo "[collect] 台帳がありません: ${RUNS_FILE}" >&2; exit 1; }
  row=$(jq -c -R 'fromjson? // empty' "$RUNS_FILE" | jq -s -c --arg id "$KPI" '[.[] | select(.run_id == $id)] | last // empty')
  [ -n "$row" ] || { echo "[collect] run_id が台帳にありません: ${KPI}" >&2; exit 1; }
  # カナリア KPI（計画 S26）: 全て満たして exit 0
  printf '%s\n' "$row" | jq -r '
    def chk(name; ok; val): {name: name, ok: ok, val: (val|tostring)};
    [ chk("human_interventions == 0"; (.human_interventions // 99) == 0; .human_interventions),
      chk("gap_min <= 5"; (.gap_min // 999) <= 5; .gap_min),
      chk("bon_apply_failed == 0"; (.bon_apply_failed.value // 99) == 0; .bon_apply_failed.value),
      chk("bon_fired == 0"; (.bon_fired // 99) == 0; .bon_fired),
      chk("errors_unknown == 0"; (.errors_unknown // 99) == 0; .errors_unknown),
      chk("cost_usd > 0"; ((.cost_usd // 0) > 0); .cost_usd),
      chk("cost_measured_calls == llm_calls"; (.cost_measured_calls // -1) == (.llm_calls // -2); "\(.cost_measured_calls)/\(.llm_calls)"),
      chk("attempts_per_task <= 1.5"; (.attempts_per_task // 99) <= 1.5; .attempts_per_task),
      chk("max_attempts <= 3"; (.max_attempts // 99) <= 3; .max_attempts),
      chk("end_reason == completed"; (.end_reason // "") == "completed"; .end_reason),
      chk("launches == 1"; (.launches // 99) == 1; .launches),
      chk("qa_auto_pass == 0"; ((.quality_debts.by_type.qa_auto_pass // 0) == 0); (.quality_debts.by_type.qa_auto_pass // 0))
    ] as $checks
    | ($checks | map(select(.ok | not)) | length) as $fails
    | ($checks[] | "\(if .ok then "PASS" else "FAIL" end)  \(.name)  (\(.val))"),
      "----", "run_id=\(.run_id)  KPI: \(($checks|length) - $fails)/\($checks|length) PASS",
      (if $fails > 0 then "exit=1" else "exit=0" end)
  '
  printf '%s\n' "$row" | jq -e '
    ((.human_interventions // 99) == 0) and ((.gap_min // 999) <= 5) and ((.bon_apply_failed.value // 99) == 0)
    and ((.bon_fired // 99) == 0) and ((.errors_unknown // 99) == 0) and ((.cost_usd // 0) > 0)
    and ((.cost_measured_calls // -1) == (.llm_calls // -2)) and ((.attempts_per_task // 99) <= 1.5)
    and ((.max_attempts // 99) <= 3) and ((.end_reason // "") == "completed") and ((.launches // 99) == 1)
    and ((.quality_debts.by_type.qa_auto_pass // 0) == 0)' >/dev/null 2>&1
  exit $?
fi

# ===== 集計 =====
[ -d "$STATE" ] || { echo "[collect] state ディレクトリがありません: ${STATE}" >&2; exit 2; }
TMP=$(mktemp -d 2>/dev/null || echo "/tmp/collect-$$"); mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# 不正行をスキップして JSON 配列ファイルにする（--slurpfile で読む。コマンドライン長制限を避ける）
clean_jsonl() {  # clean_jsonl <src> <dst>  — jq 1 回（Windows は spawn 1 回 ≈ 0.3〜0.5 秒なので回数を絞る）
  if [ -f "$1" ]; then
    jq -R -s 'split("\n") | map(select(length > 0) | (fromjson? // empty))' "$1" > "$2" 2>/dev/null || echo '[]' > "$2"
  else
    echo '[]' > "$2"
  fi
  [ -s "$2" ] || echo '[]' > "$2"
}
clean_json() {  # clean_json <src> <dst>  — 単体 JSON、不正/不在は null
  if [ -f "$1" ] && jq -e . "$1" >/dev/null 2>&1; then cp "$1" "$2"; else echo 'null' > "$2"; fi
}
clean_jsonl "${STATE}/metrics.jsonl" "${TMP}/metrics.json"
clean_jsonl "${STATE}/task-events.jsonl" "${TMP}/events.json"
clean_jsonl "${STATE}/errors.jsonl" "${TMP}/errors.json"
clean_jsonl "${STATE}/quality-debts.jsonl" "${TMP}/debts.json"
clean_json "${STATE}/task-stack.json" "${TMP}/stack.json"
clean_json "${STATE}/current-research.json" "${TMP}/research.json"
clean_json "${STATE}/run-end.json" "${TMP}/runend.json"
clean_json "${STATE}/research-config.json" "${TMP}/rconfig.json"
# notifications: n-*.json を配列に
if [ -d "${STATE}/notifications" ] && ls "${STATE}/notifications"/*.json >/dev/null 2>&1; then
  # 全ファイルを jq 1 回で読む（不正 JSON が混ざると全体が失敗するので、その時だけ 1 件ずつに落とす）
  if ! jq -s '[.[] | select(type=="object")]' "${STATE}/notifications"/*.json > "${TMP}/notif.json" 2>/dev/null; then
    { for f in "${STATE}/notifications"/*.json; do jq -c 'select(type=="object")' "$f" 2>/dev/null; done; } | jq -s '.' > "${TMP}/notif.json" 2>/dev/null || echo '[]' > "${TMP}/notif.json"
  fi
else
  echo '[]' > "${TMP}/notif.json"
fi
[ -s "${TMP}/notif.json" ] || echo '[]' > "${TMP}/notif.json"
# forge-flow.log の起動境界行（batch#11 R07a で追記化）
launch_lines=0
if [ -f "${STATE}/forge-flow.log" ]; then
  launch_lines=$(grep -c '^===== launch ' "${STATE}/forge-flow.log" 2>/dev/null || true)
  case "$launch_lines" in (''|*[!0-9]*) launch_lines=0 ;; esac
fi
harness_rev="unknown"
if command -v git >/dev/null 2>&1; then
  harness_rev=$(git -C "$HARNESS_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi
state_base=$(basename "$STATE")

row=$(jq -n -c \
  --slurpfile M "${TMP}/metrics.json" --slurpfile E "${TMP}/events.json" --slurpfile ER "${TMP}/errors.json" \
  --slurpfile QD "${TMP}/debts.json" --slurpfile S "${TMP}/stack.json" --slurpfile R "${TMP}/research.json" \
  --slurpfile RE "${TMP}/runend.json" --slurpfile RC "${TMP}/rconfig.json" --slurpfile N "${TMP}/notif.json" \
  --arg end_reason_arg "$END_REASON" --arg harness_rev "$harness_rev" --arg state_base "$state_base" \
  --argjson launch_lines "$launch_lines" --arg collected_at "$(date -Iseconds)" '
  # ---- helpers ----
  def epoch:
    if . == null or . == "" then null else
      (tostring | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})?") // null) as $c
      | if $c == null then null else
          (try (($c.d + "Z") | fromdateiso8601) catch null) as $base
          | if $base == null then null else
              (if ($c.tz == null or $c.tz == "Z") then 0
               else ((if ($c.tz[0:1] == "-") then -1 else 1 end)
                     * ((($c.tz[1:3] | tonumber) * 3600) + (($c.tz[-2:] | tonumber) * 60))) end) as $off
              | $base - $off
            end
        end
    end;
  def stage_group:
    tostring
    | if test("^(implementer|fixer)") then "implementer"
      elif test("^investigator") then "investigator"
      elif test("^qa-evaluator") then "qa-evaluator"
      elif test("^evidence-da") then "evidence-da"
      elif test("^checklist") then "checklist-verifier"
      elif test("^mutation") then "mutation-auditor"
      elif test("^(bon|best-of-n)") then "best-of-n"
      elif test("^l3-judge") then "l3-judge"
      elif test("^ux-") then "ux-judgment"
      elif test("^browser") then "browser-tester"
      elif test("^researcher") then "researcher"
      elif test("^scope-challenger") then "scope-challenger"
      elif test("^synthesizer") then "synthesizer"
      elif test("^devils-advocate") then "devils-advocate"
      elif test("^criteria") then "criteria-generation"
      elif test("^(final-report|report)") then "final-report"
      elif test("^(task-planner|planner|generate-tasks)") then "task-planner"
      elif test("^(validation-author|authoring)") then "validation-authoring"
      else "other" end;
  def n0: if . == null then 0 else (if type == "number" then . elif type == "string" then (tonumber? // 0) else 0 end) end;
  def str0: if type == "string" then . else "" end;
  def round2: ((. * 100) | round) / 100;

  ($M[0] // []) as $m0 | ($E[0] // []) as $ev | ($ER[0] // []) as $er | ($QD[0] // []) as $qd
  | ($S[0]) as $stack | ($R[0]) as $res | ($RE[0]) as $re | ($RC[0]) as $rc | ($N[0] // []) as $nf
  # ---- metrics ----
  | ($m0 | map(select(type=="object" and (.timestamp|type) == "string")) | map(. + {_t: (.timestamp | epoch)}) | map(select(._t != null)) | sort_by(._t)) as $m
  | ($m | map(.session_id | strings | select(. != "null")) | unique) as $m_sessions
  | ($ev | map(select(type=="object")) | map(.session_id | strings | select(. != "null")) | unique) as $e_sessions
  | ($ev | map(select(type=="object"))) as $ev
  | (($m_sessions + $e_sessions) | unique) as $sessions
  | ($m | length) as $llm_calls
  | ($m | map(.cost_usd | n0) | add | n0) as $cost_sum
  | ($m | map(select((.cost_usd | n0) > 0)) | length) as $cost_measured
  | ($m | map(.duration_sec | n0) | add | n0) as $llm_sec
  | ([range(1; ($m | length)) as $i | ($m[$i]._t - $m[$i-1]._t - ($m[$i].duration_sec | n0))] | map(select(. > 300)) | add | n0) as $gap_sec
  | (if ($m | length) > 0 then ($m[-1]._t - $m[0]._t) else 0 end) as $wall_sec
  | ($m | map(.stage | str0 | stage_group) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $calls_by_stage
  # ---- task events ----
  | ($ev | map(select(.event == "task_started")) | length) as $task_started
  | ($ev | map(select(.event == "task_started")) | group_by(.task_id | tostring) | map(length) | max | n0) as $max_attempts
  | ($ev | map(select(.event == "fail_recorded"))) as $fails
  | ($fails | map((.detail | objects | .cause | strings) // "unknown") | group_by(.) | map({key: .[0], value: length}) | from_entries) as $fail_cause
  | ($ev | map(select(.event == "qa_evaluator_fail" or .event == "qa_fail_recorded")) | length) as $qa_fail
  | ($ev | map(select(.event == "best_of_n_completed")) | length) as $bon_fired
  | ($ev | map(select(.event == "best_of_n_apply_failed")) | length) as $bon_af_ev
  | ($nf | map(select((.message | str0) | test("best-of-N patch 適用失敗"))) | length) as $bon_af_nf
  | (if $bon_af_ev > 0 then {value: $bon_af_ev, source: "task-events"}
     elif $bon_af_nf > 0 then {value: $bon_af_nf, source: "notifications"}
     else {value: 0, source: "none"} end) as $bon_apply_failed
  | ($ev | map(select(.event == "investigator_invoked")) | length) as $investigator
  | ($ev | map(select(.event == "rework_detected")) | length) as $rework
  | ($ev | map(select(.event == "interrupted_requeued")) | length) as $interrupted_requeued
  # ---- errors ----
  | ($er | map(select(type=="object"))) as $errs
  | ($errs | map((.error_category | strings) // "unknown") | group_by(.) | map({key: .[0], value: length}) | from_entries) as $err_by_cat
  | ($errs | map(select(((.error_category | strings) // "unknown") == "unknown")) | length) as $errors_unknown
  | ($errs | map(select(.error_category == "interrupted")) | length) as $errors_interrupted
  # ---- notifications ----
  | ($nf | map(select(.level == "critical")) | length) as $nf_critical
  # ---- quality debts（このランのセッションに属するもの）----
  | ($qd | map(select(type=="object")) | map(select((.session_id | str0) as $s | ($sessions | index($s)) != null))) as $qds
  | ($qds | map((.type | strings) // "unknown") | group_by(.) | map({key: .[0], value: length}) | from_entries) as $qd_by_type
  | ($qds | map(select(.resolved != true)) | length) as $qd_open
  # ---- tasks ----
  | (($stack | objects | .tasks | arrays) // []) as $tasks
  | ($tasks | length) as $tasks_total
  | ($tasks | map(select(type=="object" and .status == "completed")) | length) as $tasks_completed
  | (($stack | objects | .phases | arrays) // [] | length) as $phases
  # ---- identity ----
  | (($res | objects | .research_dir | strings) // "" | if . != "" then (split("/") | last) else "" end) as $rid_res
  | ($m0 | map(select(type=="object")) | map(.research_dir | strings | select(startswith(".docs/research/"))) | first // "" | if . != "" then (split("/") | last) else "" end) as $rid_metrics
  | (if $rid_res != "" then $rid_res elif $rid_metrics != "" then $rid_metrics else ("state-" + $state_base) end) as $run_id
  | ((($res | objects | .theme | strings) // ($rc | objects | .theme | strings) // ($stack | objects | .theme | strings)) // $run_id) as $project
  | ((($stack | objects | .workflow | strings) // ($rc | objects | .workflow | strings)) // "unknown") as $workflow
  | ((($re | objects | .end_reason | strings) // (if $end_reason_arg != "" then $end_reason_arg else "unknown" end))) as $end_reason
  | (($sessions | length) as $n | if $n < 1 then 1 else $n end) as $launches
  | ([] + (if $cost_sum == 0 then ["cost: 全呼出 0（metrics に cost 記録なし）"] else [] end)
        + (if ($m | length) == 0 then ["metrics: 記録なし"] else [] end)
        + (if $re == null then ["run-end.json なし（end_reason は引数/unknown）"] else [] end)) as $incomplete
  | {
      run_id: $run_id, project: $project, workflow: $workflow, harness_rev: $harness_rev,
      collected_at: $collected_at, state_dir: $state_base,
      started_at: (if ($m | length) > 0 then $m[0].timestamp else null end),
      ended_at: (($re | objects | .ended_at | strings) // (if ($m | length) > 0 then $m[-1].timestamp else null end)),
      end_reason: $end_reason, exit_code: (($re | objects | .exit_code | numbers) // null),
      sessions: ($sessions | length), launches: $launches, launch_lines: $launch_lines,
      tasks_total: $tasks_total, tasks_completed: $tasks_completed, phases: $phases,
      task_started: $task_started,
      attempts_per_task: (if $tasks_total > 0 then (($task_started / $tasks_total) | round2) else null end),
      max_attempts: $max_attempts,
      fail_recorded: ($fails | length), fail_cause: $fail_cause,
      qa_fail: $qa_fail, bon_fired: $bon_fired, bon_apply_failed: $bon_apply_failed,
      investigator: $investigator, rework_detected: $rework, interrupted_requeued: $interrupted_requeued,
      human_interventions: ($rework + $errors_interrupted),
      notifications_critical: $nf_critical,
      errors_total: ($errs | length), errors_unknown: $errors_unknown, errors_by_category: $err_by_cat,
      llm_calls: $llm_calls, cost_usd: (if $cost_sum > 0 then ($cost_sum | round2) else null end),
      cost_measured_calls: $cost_measured,
      llm_min: (($llm_sec / 60) | round2), wallclock_min: (($wall_sec / 60) | round2), gap_min: (($gap_sec / 60) | round2),
      calls_by_stage: $calls_by_stage,
      quality_debts: {total: ($qds | length), open: $qd_open, by_type: $qd_by_type},
      incomplete: $incomplete
    }') || { echo "[collect] 集計に失敗しました" >&2; exit 1; }

if ! printf '%s\n' "$row" | jq -e . >/dev/null 2>&1; then
  echo "[collect] 生成した行が有効 JSON ではありません" >&2
  exit 1
fi

if [ "$APPEND" = "true" ]; then
  mkdir -p "$(dirname "$RUNS_FILE")" 2>/dev/null || true
  printf '%s\n' "$row" >> "$RUNS_FILE"
  echo "[collect] runs.jsonl に追記: $(printf '%s' "$row" | jq -r '.run_id') → ${RUNS_FILE}" >&2
fi
printf '%s\n' "$row"
