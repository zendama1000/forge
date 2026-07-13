#!/bin/bash
# test-l3-fix-dedup.sh — create_l3_fix_task の dedup + origin 毎キャップ
# 使い方: bash .forge/tests/test-l3-fix-dedup.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="/tmp/test-l3-fix-dedup-$$"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/.forge/state"

DEBT_LOG="${TEST_ROOT}/debts.log"
log() { echo "[LOG] $1" >&2; }
jq_safe() { jq "$@" | tr -d '\r'; }
sync_task_stack() { :; }
notify_human() { echo "[NOTIFY] $1 $2" >&2; }
record_quality_debt() { echo "$1|$2|$3" >> "$DEBT_LOG"; }

# 被テスト関数を sed 抽出（common.sh: dedup/カウント、phase3.sh: fix 生成 + キャップ）
EXTRACT="${TEST_ROOT}/extract.sh"
: > "$EXTRACT"
for fn in l3_fix_pending_duplicate fix_tasks_for_origin_count; do
  sed -n "/^${fn}() {/,/^}/p" "${SCRIPT_DIR}/.forge/lib/common.sh" >> "$EXTRACT"
done
for fn in _fix_cap_allows create_l3_fix_task; do
  sed -n "/^${fn}() {/,/^}/p" "${SCRIPT_DIR}/.forge/lib/phase3.sh" >> "$EXTRACT"
done
if ! grep -q '^create_l3_fix_task() {' "$EXTRACT" || ! grep -q '^_fix_cap_allows() {' "$EXTRACT"; then
  echo "FATAL: 関数抽出失敗"
  echo "  PASS: 0  FAIL: 1"
  exit 1
fi
source "$EXTRACT"

TASK_STACK="${TEST_ROOT}/.forge/state/task-stack.json"
CIRCUIT_BREAKER_CONFIG="${TEST_ROOT}/.forge/circuit-breaker.json"
echo '{"development_limits":{"max_fix_tasks_per_origin":3}}' > "$CIRCUIT_BREAKER_CONFIG"

cat > "$TASK_STACK" << 'JSON'
{
  "tasks": [
    {
      "task_id": "impl-driver",
      "description": "driver 実装",
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "status": "completed",
      "validation": {
        "layer_1": {"command": "true", "expect": "exit 0"},
        "layer_3": [
          {"id": "L3-e2e", "strategy": "api_e2e", "description": "d", "definition": {}, "requires": ["server"]}
        ]
      },
      "l1_criteria_refs": []
    }
  ]
}
JSON

count_fix() { jq '[.tasks[] | select(.task_id | contains("-l3fix-"))] | length' "$TASK_STACK"; }

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: 初回 fix 生成 ---
echo -e "\n${BOLD}[1] 初回 fix 生成${NC}"
create_l3_fix_task "impl-driver" "L3-e2e" "connection failed output"
assert_eq "fix タスクが 1 件生成される" "1" "$(count_fix)"
assert_eq "l3_fix_for が記録される" "impl-driver" "$(jq -r '.tasks[] | select(.task_id | contains("-l3fix-")) | .l3_fix_for' "$TASK_STACK")"
assert_eq "l3_test_id が記録される" "L3-e2e" "$(jq -r '.tasks[] | select(.task_id | contains("-l3fix-")) | .l3_test_id' "$TASK_STACK")"

# --- Test 2: 同一 origin + 同一 test_id → dedup ---
echo -e "\n${BOLD}[2] dedup（同一 origin + test_id）${NC}"
create_l3_fix_task "impl-driver" "L3-e2e" "connection failed again"
assert_eq "重複 pending fix は生成されない" "1" "$(count_fix)"

# --- Test 3: 別 test_id → 生成される ---
echo -e "\n${BOLD}[3] 別 test_id は生成${NC}"
sleep 1
create_l3_fix_task "impl-driver" "L3-other" "other failure"
assert_eq "別 test_id の fix は生成される" "2" "$(count_fix)"

# --- Test 4: completed になった fix は dedup 対象外 ---
echo -e "\n${BOLD}[4] completed fix は dedup 対象外${NC}"
jq '(.tasks[] | select(.l3_test_id == "L3-e2e")).status = "completed"' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
sleep 1
create_l3_fix_task "impl-driver" "L3-e2e" "failure recurred after fix completed"
assert_eq "completed fix があっても新規生成される（再発対応）" "3" "$(count_fix)"

# --- Test 5: origin 毎キャップ（3件で上限） ---
echo -e "\n${BOLD}[5] origin 毎キャップ${NC}"
: > "$DEBT_LOG"
sleep 1
create_l3_fix_task "impl-driver" "L3-yet-another" "4th failure"
assert_eq "上限（3）到達後は生成拒否" "3" "$(count_fix)"
assert_eq "fix_cap_reached が台帳記録される" "1" "$(grep -c '^fix_cap_reached|impl-driver|' "$DEBT_LOG" || true)"

# ===== クリーンアップ =====
rm -rf "$TEST_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  l3-fix-dedup テスト結果"
echo -e "==========================================${NC}"
echo -e "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}SOME TESTS FAILED${NC}"
  exit 1
fi
