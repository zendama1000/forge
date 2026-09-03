#!/bin/bash
# test-runs-ledger.sh — .forge/eval/collect.sh（1 ラン = 1 行の計測台帳 runs.jsonl）のテスト（batch#11 R15）
#
# 合成 state で検証する: run_id フォールバック / launches / TZ 混在の epoch 正規化 / gap_min /
# bon_apply_failed の source（task-events 優先 → notifications）/ quality-debts の session フィルタ /
# cost null + incomplete / fail_cause の unknown 既定 / --append 2 回で 2 行と --latest の dedupe /
# --kpi の exit code / metrics 欠損でも有効 JSON / RUNS_FILE 差替え時に実 runs.jsonl が不変。
# 使い方: bash .forge/tests/test-runs-ledger.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

COLLECT="${PROJECT_ROOT}/.forge/eval/collect.sh"
TMP=$(mktemp -d 2>/dev/null || echo "/tmp/runs-ledger-$$")
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo -e "${BOLD}===== test-runs-ledger.sh — collect.sh / runs.jsonl =====${NC}"
echo ""

REAL_RUNS="${PROJECT_ROOT}/.forge/state/runs.jsonl"
real_md5_before=$([ -f "$REAL_RUNS" ] && md5sum "$REAL_RUNS" | cut -d' ' -f1 || echo "absent")

# ===== 合成 state: live-run（4.5f の縮図） =====
LIVE="${TMP}/live-run"
mkdir -p "${LIVE}/notifications"
cat > "${LIVE}/current-research.json" <<'EOF'
{"research_dir":".docs/research/2026-08-19-fe5cc6-222637","status":"completed","theme":"テスト案件"}
EOF
cat > "${LIVE}/task-stack.json" <<'EOF'
{"workflow":"cli-lib","phases":[{"id":"mvp"},{"id":"core"}],"tasks":[
 {"task_id":"t1","status":"completed"},{"task_id":"t2","status":"completed"},{"task_id":"t3","status":"pending"},{"task_id":"t4","status":"completed"}]}
EOF
# metrics: +09:00 表記。3 セッション、コストは 1 件だけ 0 でない。2 件目と 3 件目の間に 30 分の空白
cat > "${LIVE}/metrics.jsonl" <<'EOF'
{"stage":"scope-challenger","duration_sec":100,"timestamp":"2026-08-19T22:00:00+09:00","session_id":"s1","cost_usd":0}
{"stage":"implementer-t1","duration_sec":600,"timestamp":"2026-08-19T22:20:00+09:00","session_id":"s1","cost_usd":0}
{"stage":"qa-evaluator-t1","duration_sec":60,"timestamp":"2026-08-19T22:51:00+09:00","session_id":"s2","cost_usd":0.5}
not json line
{"stage":"implementer-t2","duration_sec":120,"timestamp":"2026-08-19T22:54:00+09:00","session_id":"s3","cost_usd":0}
EOF
# task-events: UTC 表記（+00:00）。fail_recorded は cause あり/なし混在
cat > "${LIVE}/task-events.jsonl" <<'EOF'
{"task_id":"t1","event":"task_started","detail":{},"timestamp":"2026-08-19T13:20:00+00:00","session_id":"s1"}
{"task_id":"t1","event":"fail_recorded","detail":{"fail_count":1},"timestamp":"2026-08-19T13:30:00+00:00","session_id":"s1"}
{"task_id":"t1","event":"task_started","detail":{},"timestamp":"2026-08-19T13:31:00+00:00","session_id":"s1"}
{"task_id":"t1","event":"fail_recorded","detail":{"fail_count":2,"cause":"l1"},"timestamp":"2026-08-19T13:40:00+00:00","session_id":"s1"}
{"task_id":"t1","event":"task_started","detail":{},"timestamp":"2026-08-19T13:41:00+00:00","session_id":"s2"}
{"task_id":"t1","event":"best_of_n_completed","detail":{"selected":2,"apply_ok":false},"timestamp":"2026-08-19T13:45:00+00:00","session_id":"s2"}
{"task_id":"t1","event":"qa_evaluator_fail","detail":{},"timestamp":"2026-08-19T13:50:00+00:00","session_id":"s2"}
{"task_id":"t1","event":"investigator_invoked","detail":{},"timestamp":"2026-08-19T13:52:00+00:00","session_id":"s2"}
{"task_id":"t2","event":"task_started","detail":{},"timestamp":"2026-08-19T13:54:00+00:00","session_id":"s3"}
{"task_id":"t2","event":"rework_detected","detail":{},"timestamp":"2026-08-19T14:00:00+00:00","session_id":"s3"}
EOF
cat > "${LIVE}/errors.jsonl" <<'EOF'
{"stage":"implementer-t1","message":"Claude実行エラー","error_category":"unknown","timestamp":"2026-08-19T22:30:00+09:00"}
{"stage":"implementer-t2","message":"Claude実行エラー","error_category":"interrupted","exit_code":143,"timestamp":"2026-08-19T22:55:00+09:00"}
{"stage":"researcher-x","message":"timeout","error_category":"timeout","exit_code":124,"timestamp":"2026-08-19T22:05:00+09:00"}
EOF
cat > "${LIVE}/quality-debts.jsonl" <<'EOF'
{"id":"qd1","type":"qa_auto_pass","task_id":"t1","session_id":"s2","resolved":false}
{"id":"qd2","type":"deferred_test","task_id":"t2","session_id":"s3","resolved":true}
{"id":"qd3","type":"env_blocked","task_id":"t9","session_id":"other-session","resolved":false}
EOF
cat > "${LIVE}/notifications/n-1.json" <<'EOF'
{"id":"n-1","level":"warning","message":"タスク t1: best-of-N patch 適用失敗","timestamp":"2026-08-19T22:45:00+09:00"}
EOF
cat > "${LIVE}/notifications/n-2.json" <<'EOF'
{"id":"n-2","level":"critical","message":"未コミット変更を検出","timestamp":"2026-08-19T22:46:00+09:00"}
EOF
printf '===== launch 2026-08-19T22:00:00+09:00 (resume=false parent_pid=1) =====\nlog\n===== launch 2026-08-19T22:50:00+09:00 (resume=true parent_pid=2) =====\n' > "${LIVE}/forge-flow.log"

RUNS="${TMP}/runs.jsonl"
export RUNS_FILE="$RUNS"

# ========================================================================
echo -e "${BOLD}--- Group 1: 1 行の生成（live-run） ---${NC}"
# ========================================================================
row=$(bash "$COLLECT" --state "$LIVE" --end-reason completed 2>/dev/null)
assert_eq "有効 JSON を 1 行出す" "true" "$(printf '%s' "$row" | jq -e . >/dev/null 2>&1 && echo true || echo false)"
assert_eq "run_id = current-research の research_dir basename" "2026-08-19-fe5cc6-222637" "$(printf '%s' "$row" | jq -r '.run_id')"
assert_eq "project = theme" "テスト案件" "$(printf '%s' "$row" | jq -r '.project')"
assert_eq "workflow = task-stack.workflow" "cli-lib" "$(printf '%s' "$row" | jq -r '.workflow')"
assert_eq "tasks_total / completed" "4|3" "$(printf '%s' "$row" | jq -r '"\(.tasks_total)|\(.tasks_completed)"')"
assert_eq "sessions / launches = metrics ∪ task-events の session_id 種類数（3）" "3|3" "$(printf '%s' "$row" | jq -r '"\(.sessions)|\(.launches)"')"
assert_eq "launch_lines = forge-flow.log の起動境界行数（2）" "2" "$(printf '%s' "$row" | jq -r '.launch_lines')"
assert_eq "llm_calls は不正行を除いた 4" "4" "$(printf '%s' "$row" | jq -r '.llm_calls')"
assert_eq "task_started 4 / attempts_per_task 1.0 / max_attempts 3" "4|1|3" "$(printf '%s' "$row" | jq -r '"\(.task_started)|\(.attempts_per_task)|\(.max_attempts)"')"
assert_eq "fail_recorded 2 / fail_cause は unknown 既定 + cause" "2|1|1" "$(printf '%s' "$row" | jq -r '"\(.fail_recorded)|\(.fail_cause.unknown)|\(.fail_cause.l1)"')"
assert_eq "qa_fail / bon_fired / investigator / rework" "1|1|1|1" "$(printf '%s' "$row" | jq -r '"\(.qa_fail)|\(.bon_fired)|\(.investigator)|\(.rework_detected)"')"
assert_eq "bon_apply_failed: task-events に新イベントが無ければ notifications から（source 記録）" "1|notifications" "$(printf '%s' "$row" | jq -r '"\(.bon_apply_failed.value)|\(.bon_apply_failed.source)"')"
assert_eq "errors_total / unknown / by_category" "3|1|1" "$(printf '%s' "$row" | jq -r '"\(.errors_total)|\(.errors_unknown)|\(.errors_by_category.interrupted)"')"
assert_eq "human_interventions = rework + interrupted（1 + 1）" "2" "$(printf '%s' "$row" | jq -r '.human_interventions')"
assert_eq "notifications_critical = 1" "1" "$(printf '%s' "$row" | jq -r '.notifications_critical')"
assert_eq "cost_usd は合算（0.5）、cost_measured_calls 1" "0.5|1" "$(printf '%s' "$row" | jq -r '"\(.cost_usd)|\(.cost_measured_calls)"')"
assert_eq "quality_debts はこのランの session だけ（other-session を除外）: total 2 / open 1 / qa_auto_pass 1" "2|1|1" "$(printf '%s' "$row" | jq -r '"\(.quality_debts.total)|\(.quality_debts.open)|\(.quality_debts.by_type.qa_auto_pass)"')"
assert_eq "calls_by_stage はエージェント名で集約（implementer 2 / qa-evaluator 1 / scope-challenger 1）" "2|1|1" "$(printf '%s' "$row" | jq -r '"\(.calls_by_stage.implementer)|\(.calls_by_stage["qa-evaluator"])|\(.calls_by_stage["scope-challenger"])"')"
assert_eq "end_reason は run-end.json が無ければ引数" "completed" "$(printf '%s' "$row" | jq -r '.end_reason')"
assert_contains "incomplete に run-end.json 不在" "run-end.json" "$(printf '%s' "$row" | jq -r '.incomplete | join(";")')"
# TZ 混在: metrics は +09:00。22:00 → 22:20（idle 20-10=10min → 600s > 300 → gap）、22:20 → 22:51（idle 31-1=30min）、22:51 → 22:54（idle 3-2=1min）
assert_eq "gap_min = 呼出間の idle（duration 控除）が 5 分超の合計 = 40" "40" "$(printf '%s' "$row" | jq -r '.gap_min')"
assert_eq "wallclock_min = 最初〜最後の metrics（54 分）" "54" "$(printf '%s' "$row" | jq -r '.wallclock_min')"
assert_eq "llm_min = duration 合計（880 秒 = 14.67 分）" "14.67" "$(printf '%s' "$row" | jq -r '.llm_min')"
assert_eq "--append 無しでは台帳に書かない" "false" "$([ -f "$RUNS" ] && echo true || echo false)"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: run-end.json / 新イベント優先 / cost null ---${NC}"
# ========================================================================
LIVE2="${TMP}/live2"; cp -r "$LIVE" "$LIVE2"
cat > "${LIVE2}/run-end.json" <<'EOF'
{"end_reason":"paused","exit_code":75,"ended_at":"2026-08-20T01:00:00+09:00","harness_rev":"abc1234","session_id":"s3"}
EOF
echo '{"task_id":"t2","event":"best_of_n_apply_failed","detail":{"selected":1},"timestamp":"2026-08-19T14:10:00+00:00","session_id":"s3"}' >> "${LIVE2}/task-events.jsonl"
jq -c '.cost_usd = 0' "${LIVE2}/metrics.jsonl" > "${LIVE2}/metrics.tmp" 2>/dev/null; mv "${LIVE2}/metrics.tmp" "${LIVE2}/metrics.jsonl"
row2=$(bash "$COLLECT" --state "$LIVE2" --end-reason completed 2>/dev/null)
assert_eq "run-end.json があれば end_reason / exit_code / ended_at はそちらが正" "paused|75|2026-08-20T01:00:00+09:00" "$(printf '%s' "$row2" | jq -r '"\(.end_reason)|\(.exit_code)|\(.ended_at)"')"
assert_eq "best_of_n_apply_failed イベントがあれば task-events を優先" "1|task-events" "$(printf '%s' "$row2" | jq -r '"\(.bon_apply_failed.value)|\(.bon_apply_failed.source)"')"
assert_eq "全呼出 cost 0 → cost_usd null + incomplete" "null|true" "$(printf '%s' "$row2" | jq -r '"\(.cost_usd)|\(.incomplete | map(select(startswith("cost"))) | length > 0)"')"
assert_eq "run-end.json ありなら incomplete に run-end 不在は出ない" "0" "$(printf '%s' "$row2" | jq -r '.incomplete | map(select(test("run-end"))) | length')"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: run_id フォールバック / metrics 欠損 ---${NC}"
# ========================================================================
NOCR="${TMP}/no-research"; mkdir -p "$NOCR"
echo '{"stage":"implementer-a","duration_sec":10,"timestamp":"2026-08-01T10:00:00+09:00","session_id":"z","research_dir":".docs/research/2026-08-01-abc123-100000"}' > "${NOCR}/metrics.jsonl"
row3=$(bash "$COLLECT" --state "$NOCR" 2>/dev/null)
assert_eq "current-research 不在 → metrics の research_dir から run_id" "2026-08-01-abc123-100000" "$(printf '%s' "$row3" | jq -r '.run_id')"
EMPTY="${TMP}/empty-state"; mkdir -p "$EMPTY"
row4=$(bash "$COLLECT" --state "$EMPTY" 2>/dev/null)
assert_eq "何も無い state でも有効 JSON" "true" "$(printf '%s' "$row4" | jq -e . >/dev/null 2>&1 && echo true || echo false)"
assert_eq "run_id は state-<dir 名> にフォールバック" "state-empty-state" "$(printf '%s' "$row4" | jq -r '.run_id')"
assert_eq "launches は下限 1、end_reason unknown、cost null" "1|unknown|null" "$(printf '%s' "$row4" | jq -r '"\(.launches)|\(.end_reason)|\(.cost_usd)"')"
assert_contains "incomplete に metrics 記録なし" "metrics" "$(printf '%s' "$row4" | jq -r '.incomplete | join(";")')"
assert_eq "不在 state dir は exit 2" "2" "$(bash "$COLLECT" --state "${TMP}/nope" >/dev/null 2>&1; echo $?)"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3b: 型不一致でも行が出る（レビュー 2026-09-03） ---${NC}"
# ========================================================================
BAD="${TMP}/bad-types"; mkdir -p "${BAD}/notifications"
cat > "${BAD}/metrics.jsonl" <<'EOF'
{"stage":"implementer-a","duration_sec":"10","timestamp":"2026-08-01T10:00:00+09:00","session_id":"z","cost_usd":"0.2"}
{"stage":123,"duration_sec":null,"timestamp":12345,"session_id":7}
EOF
echo '{"task_id":"a","event":"fail_recorded","detail":"not an object","timestamp":"2026-08-01T01:00:00+00:00","session_id":"z"}' > "${BAD}/task-events.jsonl"
echo '{"id":"n","level":"critical","message":123}' > "${BAD}/notifications/n-1.json"
echo '{"tasks":"not an array","phases":null}' > "${BAD}/task-stack.json"
echo '{"research_dir":["x"],"theme":null}' > "${BAD}/current-research.json"
echo '{"stage":"s","error_category":42}' > "${BAD}/errors.jsonl"
echo '{"end_reason":["paused"],"exit_code":"75"}' > "${BAD}/run-end.json"
rc=0; row5=$(bash "$COLLECT" --state "$BAD" 2>/dev/null) || rc=$?
assert_eq "型不一致の混入でも exit 0 で 1 行出す" "0" "$rc"
assert_eq "行は有効 JSON" "true" "$(printf '%s' "$row5" | jq -e . >/dev/null 2>&1 && echo true || echo false)"
assert_eq "文字列の cost_usd / duration_sec は数値に矯正" "0.2|0.17" "$(printf '%s' "$row5" | jq -r '"\(.cost_usd)|\(.llm_min)"')"
assert_eq "detail が非オブジェクトの fail_recorded は unknown" "1" "$(printf '%s' "$row5" | jq -r '.fail_cause.unknown')"
assert_eq "tasks が非配列なら 0 件、run_id は state 名にフォールバック" "0|state-bad-types" "$(printf '%s' "$row5" | jq -r '"\(.tasks_total)|\(.run_id)"')"
assert_eq "run-end.json の型不一致は null / unknown" "unknown|null" "$(printf '%s' "$row5" | jq -r '"\(.end_reason)|\(.exit_code)"')"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 4: --append / --latest / --kpi ---${NC}"
# ========================================================================
rm -f "$RUNS"
bash "$COLLECT" --state "$LIVE" --append --end-reason completed >/dev/null 2>&1
bash "$COLLECT" --state "$LIVE2" --append >/dev/null 2>&1
assert_eq "--append 2 回で 2 行（append-only）" "2" "$(grep -c . "$RUNS")"
assert_eq "各行が有効 JSON" "2" "$(jq -c . "$RUNS" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "--latest は run_id 毎に最後の行（1 行、end_reason=paused）" "1|paused" "$(bash "$COLLECT" --latest 2>/dev/null | jq -r '"\(1)|\(.end_reason)"' | tail -1)"
rc=0; kpi_out=$(bash "$COLLECT" --kpi 2026-08-19-fe5cc6-222637 2>/dev/null) || rc=$?
assert_eq "--kpi: 4.5f 縮図は不合格（exit 1）" "1" "$rc"
assert_contains "--kpi: human_interventions が FAIL" "FAIL  human_interventions == 0" "$kpi_out"
assert_contains "--kpi: bon_fired が FAIL" "FAIL  bon_fired == 0" "$kpi_out"
assert_contains "--kpi: サマリー行" "KPI:" "$kpi_out"
# 合格する行を作る
GOOD="${TMP}/good"; mkdir -p "${GOOD}/notifications"
echo '{"research_dir":".docs/research/2026-09-10-good00-000000","status":"completed"}' > "${GOOD}/current-research.json"
echo '{"tasks":[{"task_id":"a","status":"completed"},{"task_id":"b","status":"completed"}],"phases":[{"id":"mvp"}]}' > "${GOOD}/task-stack.json"
cat > "${GOOD}/metrics.jsonl" <<'EOF'
{"stage":"implementer-a","duration_sec":100,"timestamp":"2026-09-10T10:00:00+09:00","session_id":"g1","cost_usd":0.2}
{"stage":"implementer-b","duration_sec":100,"timestamp":"2026-09-10T10:03:00+09:00","session_id":"g1","cost_usd":0.3}
EOF
cat > "${GOOD}/task-events.jsonl" <<'EOF'
{"task_id":"a","event":"task_started","detail":{},"timestamp":"2026-09-10T01:00:00+00:00","session_id":"g1"}
{"task_id":"b","event":"task_started","detail":{},"timestamp":"2026-09-10T01:03:00+00:00","session_id":"g1"}
EOF
echo '{"end_reason":"completed","exit_code":0,"ended_at":"2026-09-10T10:10:00+09:00"}' > "${GOOD}/run-end.json"
bash "$COLLECT" --state "$GOOD" --append >/dev/null 2>&1
rc=0; kpi_good=$(bash "$COLLECT" --kpi 2026-09-10-good00-000000 2>/dev/null) || rc=$?
assert_eq "--kpi: 合格行は exit 0" "0" "$rc"
assert_eq "--kpi: 全 12 項目 PASS" "12/12 PASS" "$(printf '%s' "$kpi_good" | grep -o '[0-9]*/12 PASS')"
assert_eq "--kpi: 未知 run_id は exit 1" "1" "$(bash "$COLLECT" --kpi nope >/dev/null 2>&1; echo $?)"
assert_eq "--latest は 2 run_id → 2 行" "2" "$(bash "$COLLECT" --latest 2>/dev/null | wc -l | tr -d ' ')"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 5: 本番台帳の不変 ---${NC}"
# ========================================================================
real_md5_after=$([ -f "$REAL_RUNS" ] && md5sum "$REAL_RUNS" | cut -d' ' -f1 || echo "absent")
assert_eq "RUNS_FILE 差替え中は実 runs.jsonl が不変" "$real_md5_before" "$real_md5_after"
unset RUNS_FILE
echo ""

print_test_summary
