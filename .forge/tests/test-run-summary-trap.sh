#!/bin/bash
# test-run-summary-trap.sh — forge-flow.sh の終了記録（run-end.json + runs.jsonl 追記）のテスト（batch#11 R15）
#
# _forge_run_finalize <exit_code> [signal] を抽出して検証:
#   completed / error / signal:TERM / paused（_FORGE_END_REASON）/ 2 回呼んでも 1 回だけ書く /
#   collect.sh --append が runs.jsonl に 1 行残す / init_session_state の安全網（run-end.json 不在の旧ランを
#   アーカイブ前に台帳へ）/ 配線（trap が daemonize の exit 0 より後、`> "$FLOW_LOG"` が 0 件）
# 使い方: bash .forge/tests/test-run-summary-trap.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

FORGE_FLOW="${PROJECT_ROOT}/.forge/loops/forge-flow.sh"
TMP=$(mktemp -d 2>/dev/null || echo "/tmp/run-summary-$$")
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo -e "${BOLD}===== test-run-summary-trap.sh — 終了記録（run-end.json / runs.jsonl） =====${NC}"
echo ""

log() { :; }
eval "$(extract_all_functions_awk "$FORGE_FLOW" _forge_run_finalize init_session_state)"
if ! declare -f _forge_run_finalize >/dev/null || ! declare -f init_session_state >/dev/null; then
  echo -e "${RED}✗ _forge_run_finalize / init_session_state を forge-flow.sh から抽出できません${NC}"
  exit 1
fi

STATE_DIR="${TMP}/state"; mkdir -p "$STATE_DIR"
LOOPS_DIR="${PROJECT_ROOT}/.forge/loops"
FORGE_SESSION_ID="sess-test-1"
export RUNS_FILE="${TMP}/runs.jsonl"
echo '{"stage":"implementer-a","duration_sec":10,"timestamp":"2026-09-10T10:00:00+09:00","session_id":"sess-test-1","cost_usd":0.1}' > "${STATE_DIR}/metrics.jsonl"
echo '{"research_dir":".docs/research/2026-09-10-trap00-000000","status":"completed"}' > "${STATE_DIR}/current-research.json"

# ========================================================================
echo -e "${BOLD}--- Group 1: _forge_run_finalize ---${NC}"
# ========================================================================
_FORGE_RUN_FINALIZED=0; _FORGE_END_REASON=""
_forge_run_finalize 0
assert_eq "run-end.json が書かれる" "true" "$([ -f "${STATE_DIR}/run-end.json" ] && echo true || echo false)"
assert_eq "exit 0 → end_reason=completed / exit_code 0" "completed|0" "$(jq -r '"\(.end_reason)|\(.exit_code)"' "${STATE_DIR}/run-end.json" | tr -d '\r')"
assert_eq "session_id / ended_at / harness_rev が入る" "sess-test-1|true|true" "$(jq -r '"\(.session_id)|\(.ended_at != null)|\(.harness_rev != null)"' "${STATE_DIR}/run-end.json" | tr -d '\r')"
assert_eq "runs.jsonl に 1 行追記（collect.sh --append）" "1" "$(grep -c . "$RUNS_FILE" 2>/dev/null || echo 0)"
assert_eq "追記行の run_id / end_reason" "2026-09-10-trap00-000000|completed" "$(tail -1 "$RUNS_FILE" | jq -r '"\(.run_id)|\(.end_reason)"' | tr -d '\r')"
_forge_run_finalize 0
assert_eq "2 回呼んでも 1 回だけ書く（EXIT と TERM の二重発火対策）" "1" "$(grep -c . "$RUNS_FILE")"
_FORGE_RUN_FINALIZED=0
_forge_run_finalize 1
assert_eq "exit 1 → end_reason=error" "error|1" "$(jq -r '"\(.end_reason)|\(.exit_code)"' "${STATE_DIR}/run-end.json" | tr -d '\r')"
_FORGE_RUN_FINALIZED=0
_forge_run_finalize 143 TERM
assert_eq "TERM → end_reason=signal:TERM" "signal:TERM|143" "$(jq -r '"\(.end_reason)|\(.exit_code)"' "${STATE_DIR}/run-end.json" | tr -d '\r')"
_FORGE_RUN_FINALIZED=0; _FORGE_END_REASON="paused"
_forge_run_finalize 0
assert_eq "_FORGE_END_REASON=paused が exit 0 より優先" "paused" "$(jq -r '.end_reason' "${STATE_DIR}/run-end.json" | tr -d '\r')"
_FORGE_END_REASON=""
assert_eq "runs.jsonl は呼出毎に 1 行（計 4 行）" "4" "$(grep -c . "$RUNS_FILE")"
assert_eq "run-end.json.tmp が残らない（tmp → mv）" "false" "$([ -f "${STATE_DIR}/run-end.json.tmp" ] && echo true || echo false)"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: init_session_state の安全網（run-end.json 不在の旧ラン） ---${NC}"
# ========================================================================
STATE2="${TMP}/state2"; mkdir -p "${STATE2}/checkpoints" "${STATE2}/notifications"
STATE_DIR="$STATE2"; _RESUME=false
echo '{"completed_phase":"2"}' > "${STATE2}/flow-state.json"
echo '{"stage":"implementer-b","duration_sec":10,"timestamp":"2026-09-11T10:00:00+09:00","session_id":"old-1","cost_usd":0.1}' > "${STATE2}/metrics.jsonl"
echo '{"research_dir":".docs/research/2026-09-11-old000-000000","status":"completed"}' > "${STATE2}/current-research.json"
export RUNS_FILE="${TMP}/runs2.jsonl"
init_session_state
assert_eq "run-end.json が無い旧ランは台帳に 1 行残る（kill -9 / 旧ラン）" "1" "$(grep -c . "$RUNS_FILE" 2>/dev/null || echo 0)"
assert_eq "その行の end_reason は unknown(no-run-end)" "unknown(no-run-end)" "$(tail -1 "$RUNS_FILE" | jq -r '.end_reason' | tr -d '\r')"
assert_eq "旧 state はアーカイブされる" "1" "$(ls -d "${STATE2}"/archive/*/ 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "runs.jsonl（累積台帳）はアーカイブされない" "true" "$([ -f "$RUNS_FILE" ] && echo true || echo false)"
STATE3="${TMP}/state3"; mkdir -p "$STATE3"
STATE_DIR="$STATE3"
echo '{"completed_phase":"2"}' > "${STATE3}/flow-state.json"
echo '{"end_reason":"completed","exit_code":0}' > "${STATE3}/run-end.json"
export RUNS_FILE="${TMP}/runs3.jsonl"
init_session_state
assert_eq "run-end.json がある旧ランは二重に残さない" "false" "$([ -f "$RUNS_FILE" ] && echo true || echo false)"
unset RUNS_FILE
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: 配線 ---${NC}"
# ========================================================================
_daemon_line=$(grep -n 'nohup bash "\$0"' "$FORGE_FLOW" | head -1 | cut -d: -f1)
_trap_line=$(grep -n "trap '_forge_run_finalize" "$FORGE_FLOW" | head -1 | cut -d: -f1)
assert_eq "trap は daemonize の再起動（親プロセスの exit 0）より後に設置される" "true" "$([ -n "$_trap_line" ] && [ -n "$_daemon_line" ] && [ "$_trap_line" -gt "$_daemon_line" ] && echo true || echo false)"
assert_eq "EXIT / TERM / INT の 3 trap" "3" "$(grep -c "trap '_forge_run_finalize" "$FORGE_FLOW")"
assert_eq "forge-flow.log を truncate する '> \"\$FLOW_LOG\"' は 0 件（追記化）" "0" "$(grep -c '[^>]> "\$FLOW_LOG"' "$FORGE_FLOW")"
assert_eq "forge-flow.log への追記 '>> \"\$FLOW_LOG\"' がある" "true" "$([ "$(grep -c '>> "\$FLOW_LOG"' "$FORGE_FLOW")" -ge 1 ] && echo true || echo false)"
assert_eq "人間チェックポイント中断は end_reason を明示する" "true" "$(grep -q '_FORGE_END_REASON="checkpoint_quit"' "$FORGE_FLOW" && echo true || echo false)"
echo ""

print_test_summary
