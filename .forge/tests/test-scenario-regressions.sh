#!/bin/bash
# test-scenario-regressions.sh — 過去実バグのシナリオ回帰（シミュレータ駆動）
# (c) 429 → detect → recover の E2E（実 run_claude 発のログで実検出器を駆動）
# (d) budget 超過は非リトライ（呼出1回のみ）
# (e) validate_json 復旧はしご（crlf/fence/extraction/failed）
# 使い方: bash .forge/tests/test-scenario-regressions.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export NOTIFY_DIR="${TMPDIR}/notifications"
export CLAUDE_TIMEOUT=30
export _RC_CLI_HELP_CACHE="  --max-budget-usd <amount>  --max-turns <n>"
json_fail_count=0
touch "$ERRORS_FILE"

FAKE_BIN="${TMPDIR}/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"clean":true}'
EOF
chmod +x "${FAKE_BIN}/claude"
export PATH="${FAKE_BIN}:$PATH"

source "${PROJECT_ROOT}/.forge/lib/common.sh"
# 実 state を汚染しないよう隔離
COSTS_FILE="${TMPDIR}/costs.jsonl"
VALIDATION_STATS_FILE="${TMPDIR}/validation-stats.jsonl"
TASK_EVENTS_FILE="${TMPDIR}/task-events.jsonl"

echo -e "${BOLD}===== test-scenario-regressions.sh — 過去実バグ再現回帰 =====${NC}"
echo ""

echo "implementer" > "${TMPDIR}/implementer.md"

# ===== (c) 429 レートリミット検出→自動復旧 E2E =====
echo -e "${BOLD}--- (c) 429 → detect → recover E2E ---${NC}"
DEV_LOG_DIR="${TMPDIR}/logs"
mkdir -p "$DEV_LOG_DIR"
TASK_STACK="${TMPDIR}/task-stack.json"
RATE_LIMIT_RECOVERY_ENABLED="true"
RATE_LIMIT_MAX_RECOVERIES=1
RATE_LIMIT_COOLDOWN_SEC=0
update_heartbeat() { :; }

# ralph-loop.sh から実関数を抽出
eval "$(extract_all_functions_awk "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" \
  detect_rate_limit_from_debug_logs recover_rate_limited_tasks)"

# 実 run_claude チョークポイント経由で 429 汚染ログを生成（ralph の命名規約で）
PLAN_RL="${TMPDIR}/plan-rl.json"
jq -n '{rules:[{match:{agent_pattern:"implementer"}, fault:"rate_limit"}]}' > "$PLAN_RL"
rc_rl=0
( export RC_FAULT_PLAN="$PLAN_RL" RC_SIM_STATE_DIR="${TMPDIR}/state-rl" FORGE_CALL_ID=0
  run_claude haiku "${TMPDIR}/implementer.md" "p" \
    "${TMPDIR}/impl-out.json" "${DEV_LOG_DIR}/impl-T1-1234.log" "" 30 "" "" "" ) >/dev/null 2>&1 || rc_rl=$?
assert_eq "429 fault: run_claude rc=1" "1" "$rc_rl"

if detect_rate_limit_from_debug_logs "T1"; then
  assert_eq "実検出器 detect_rate_limit_from_debug_logs が 429 を検出" "detected" "detected"
else
  assert_eq "実検出器 detect_rate_limit_from_debug_logs が 429 を検出" "detected" "not-detected"
fi

jq -n '{tasks:[{task_id:"T1", status:"blocked_investigation", fail_count:3}]}' > "$TASK_STACK"
recover_rate_limited_tasks >/dev/null 2>&1
assert_eq "復旧: status が pending に戻る" "pending" "$(jq -r '.tasks[0].status' "$TASK_STACK")"
assert_eq "復旧: fail_count が 0 リセット" "0" "$(jq -r '.tasks[0].fail_count' "$TASK_STACK")"
assert_eq "復旧: rate_limit_recoveries=1" "1" "$(jq -r '.tasks[0].rate_limit_recoveries' "$TASK_STACK")"
assert_contains "復旧: task-events に記録" "rate_limit_recovery" "$(cat "$TASK_EVENTS_FILE" 2>/dev/null)"

# 上限到達後は復旧しない
jq '.tasks[0].status = "blocked_investigation"' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
recover2_out=$(recover_rate_limited_tasks 2>&1)
assert_eq "上限到達: status は blocked のまま" "blocked_investigation" "$(jq -r '.tasks[0].status' "$TASK_STACK")"
assert_contains "上限到達: スキップログ" "復旧上限到達" "$recover2_out"

# ===== (d) budget 超過は非リトライ（呼出1回のみ） =====
echo -e "${BOLD}--- (d) budget 非リトライ ---${NC}"
PLAN_BUDGET="${TMPDIR}/plan-budget.json"
jq -n '{rules:[{match:{agent_pattern:"implementer"}, fault:"budget_exceeded"}]}' > "$PLAN_BUDGET"
rc_bg=0
( export RC_FAULT_PLAN="$PLAN_BUDGET" RC_SIM_STATE_DIR="${TMPDIR}/state-bg" FORGE_CALL_ID=0
  retry_with_backoff 3 1 run_claude haiku "${TMPDIR}/implementer.md" "p" \
    "${TMPDIR}/bg.json" "${TMPDIR}/bg.log" "" 30 "" "" "" ) >/dev/null 2>&1 || rc_bg=$?
assert_eq "retry_with_backoff 経由でも rc=21" "21" "$rc_bg"
call_count=$(cat "${TMPDIR}/state-bg/rule-0.count" 2>/dev/null)
assert_eq "非リトライ: run_claude 呼出は1回のみ（fault カウンタ=1）" "1" "$call_count"

# ===== (e) validate_json 復旧はしご =====
echo -e "${BOLD}--- (e) validate_json 復旧はしご ---${NC}"

# run_ladder <name> <payload> <out_basename> → validate_json の rc を echo
run_ladder() {
  local name="$1" payload="$2" out="$3"
  local plan="${TMPDIR}/plan-${name}.json"
  jq -n --arg p "$payload" '{rules:[{match:{agent_pattern:"implementer"}, fault:"malformed_json", payload:$p}]}' > "$plan"
  ( export RC_FAULT_PLAN="$plan" RC_SIM_STATE_DIR="${TMPDIR}/state-${name}" FORGE_CALL_ID=0
    run_claude haiku "${TMPDIR}/implementer.md" "p" "$out" "${TMPDIR}/${name}.log" "" 30 "" "" "" ) >/dev/null 2>&1
  local rc=0
  validate_json "$out" "ladder-${name}" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

last_level() { tail -1 "$VALIDATION_STATS_FILE" 2>/dev/null | jq -r '.recovery_level'; }

rc_l1=$(run_ladder crlf "$(printf '{"ok": true}\r')" "${TMPDIR}/l1.json")
assert_eq "L1 CRLF 汚染: 修復成功 rc=0" "0" "$rc_l1"
assert_eq "L1 recovery_level=crlf" "crlf" "$(last_level)"

rc_l2=$(run_ladder fence "$(printf '%s\n%s\n%s' '```json' '{"ok": true}' '```')" "${TMPDIR}/l2.json")
assert_eq "L2 コードフェンス: 修復成功 rc=0" "0" "$rc_l2"
assert_eq "L2 recovery_level=fence" "fence" "$(last_level)"

rc_l3=$(run_ladder prose "$(printf '%s\n%s\n%s' 'Here is the result:' '{"ok": true}' 'hope this helps')" "${TMPDIR}/l3.json")
assert_eq "L3 前後テキスト: 抽出成功 rc=0" "0" "$rc_l3"
assert_eq "L3 recovery_level=extraction" "extraction" "$(last_level)"

rc_l4=$(run_ladder broken '{ "broken": [1, 2' "${TMPDIR}/l4.json")
assert_eq "L4 破損 JSON: 修復不能 rc=1" "1" "$rc_l4"
assert_eq "L4 recovery_level=failed" "failed" "$(last_level)"
if [ -f "${TMPDIR}/l4.json.failed" ]; then
  assert_eq "L4 .pending は .failed へ降格" "demoted" "demoted"
else
  assert_eq "L4 .pending は .failed へ降格" "demoted" "missing"
fi

print_test_summary
exit $?
