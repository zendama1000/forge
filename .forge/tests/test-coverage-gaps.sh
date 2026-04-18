#!/bin/bash
# test-coverage-gaps.sh — compute_test_coverage_gaps / compute_coverage_prominence のテスト
# 使い方: bash .forge/tests/test-coverage-gaps.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

pass_case() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}✓${NC} $1"
}
fail_case() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}✗${NC} $1"
  echo -e "    expected: $2"
  echo -e "    actual:   $3"
}

# テスト用一時 task-stack を作成
mktemp_stack() {
  local spec="$1"  # JSON fragment for tasks array
  local tmp
  tmp=$(mktemp)
  jq -n --argjson tasks "$spec" '{tasks: $tasks}' > "$tmp"
  echo "$tmp"
}

# phase3.sh の関数を source
cd "$PROJECT_ROOT"
source .forge/lib/common.sh 2>/dev/null
source .forge/lib/phase3.sh

echo -e "${BOLD}===== compute_test_coverage_gaps / compute_coverage_prominence =====${NC}"
echo ""

# ---- Case 1: 全タスク L1 のみ（今回の失敗シナリオ） ----
echo -e "${BOLD}Case 1: 全タスク L1 のみ (L2=0, L3=0)${NC}"
TASK_STACK=$(mktemp_stack '[
  {"task_id": "t1", "status": "completed", "validation": {"layer_1": {"command": "true"}}},
  {"task_id": "t2", "status": "completed", "validation": {"layer_1": {"command": "true"}}},
  {"task_id": "t3", "status": "completed", "validation": {"layer_1": {"command": "true"}}}
]')
export TASK_STACK

gaps=$(compute_test_coverage_gaps)
prom=$(compute_coverage_prominence)

if echo "$gaps" | jq -e '.[0] | contains("L2 tests: 0 defined / 3 tasks (0%)")' > /dev/null; then
  pass_case "L2 0/3 (0%)"
else
  fail_case "L2 counting" "L2 tests: 0 defined / 3 tasks (0%)" "$(echo "$gaps" | jq -r '.[0]')"
fi
if echo "$gaps" | jq -e '.[1] | contains("L3 tests: 0 defined / 3 tasks (0%)")' > /dev/null; then
  pass_case "L3 0/3 (0%)"
else
  fail_case "L3 counting" "L3 tests: 0 defined / 3 tasks (0%)" "$(echo "$gaps" | jq -r '.[1]')"
fi
if echo "$gaps" | jq -e '.[2] | test("NOT PERFORMED")' > /dev/null; then
  pass_case "NOT PERFORMED 警告メッセージ含む"
else
  fail_case "NOT PERFORMED" "contains 'NOT PERFORMED'" "$gaps"
fi
if [ "$prom" = "critical" ]; then
  pass_case "prominence = critical"
else
  fail_case "prominence" "critical" "$prom"
fi
rm -f "$TASK_STACK"

# ---- Case 2: L2 あり L3 なし ----
echo -e "\n${BOLD}Case 2: L2 あり / L3 なし${NC}"
TASK_STACK=$(mktemp_stack '[
  {"task_id": "t1", "status": "completed", "validation": {"layer_1": {"command": "true"}, "layer_2": {"command": "echo ok"}}},
  {"task_id": "t2", "status": "completed", "validation": {"layer_1": {"command": "true"}, "layer_2": {"command": "echo ok"}}}
]')
export TASK_STACK

gaps=$(compute_test_coverage_gaps)
prom=$(compute_coverage_prominence)

if echo "$gaps" | jq -e '.[0] | contains("L2 tests: 2 defined / 2 tasks (100%)")' > /dev/null; then
  pass_case "L2 2/2 (100%)"
else
  fail_case "L2 counting" "L2 tests: 2 defined / 2 tasks (100%)" "$(echo "$gaps" | jq -r '.[0]')"
fi
if echo "$gaps" | jq -e '.[2] | test("NOT PERFORMED")' > /dev/null; then
  pass_case "NOT PERFORMED 警告メッセージ含む（L3 ゼロのため）"
else
  fail_case "NOT PERFORMED" "contains 'NOT PERFORMED' (L3=0)" "$gaps"
fi
if [ "$prom" = "critical" ]; then
  pass_case "prominence = critical（L3 ゼロ）"
else
  fail_case "prominence" "critical (L3=0)" "$prom"
fi
rm -f "$TASK_STACK"

# ---- Case 3: L3 あり L2 なし ----
echo -e "\n${BOLD}Case 3: L3 あり / L2 なし${NC}"
TASK_STACK=$(mktemp_stack '[
  {"task_id": "t1", "status": "completed", "validation": {"layer_1": {"command": "true"}, "layer_3": [{"id": "l3-1", "strategy": "agent_flow", "description": "d", "definition": {}}]}}
]')
export TASK_STACK

gaps=$(compute_test_coverage_gaps)
prom=$(compute_coverage_prominence)

if [ "$prom" = "medium" ]; then
  pass_case "prominence = medium（L3 あり L2 なし）"
else
  fail_case "prominence" "medium" "$prom"
fi
if echo "$gaps" | jq -e 'map(select(test("NOT PERFORMED"))) | length == 0' > /dev/null; then
  pass_case "NOT PERFORMED 警告なし（L3 存在のため）"
else
  fail_case "NOT PERFORMED" "no 'NOT PERFORMED' line" "$gaps"
fi
rm -f "$TASK_STACK"

# ---- Case 4: L2 + L3 両方あり ----
echo -e "\n${BOLD}Case 4: L2 + L3 両方あり${NC}"
TASK_STACK=$(mktemp_stack '[
  {"task_id": "t1", "status": "completed", "validation": {"layer_1": {"command": "true"}, "layer_2": {"command": "echo ok"}, "layer_3": [{"id": "l3-1", "strategy": "agent_flow", "description": "d", "definition": {}}]}}
]')
export TASK_STACK

prom=$(compute_coverage_prominence)
if [ "$prom" = "none" ]; then
  pass_case "prominence = none"
else
  fail_case "prominence" "none" "$prom"
fi
rm -f "$TASK_STACK"

# ---- Case 5: completed 以外のタスクは除外される ----
echo -e "\n${BOLD}Case 5: pending タスクはカウント外${NC}"
TASK_STACK=$(mktemp_stack '[
  {"task_id": "t1", "status": "completed", "validation": {"layer_1": {"command": "true"}}},
  {"task_id": "t2", "status": "pending", "validation": {"layer_1": {"command": "true"}}}
]')
export TASK_STACK

gaps=$(compute_test_coverage_gaps)
if echo "$gaps" | jq -e '.[0] | contains("/ 1 tasks")' > /dev/null; then
  pass_case "pending は集計対象外（total=1）"
else
  fail_case "completed filter" "/ 1 tasks" "$(echo "$gaps" | jq -r '.[0]')"
fi
rm -f "$TASK_STACK"

# ===== サマリー =====
echo ""
echo -e "${BOLD}==========================================${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS}/${TOTAL}${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL}/${TOTAL} (passed ${PASS})${NC}"
  exit 1
fi
