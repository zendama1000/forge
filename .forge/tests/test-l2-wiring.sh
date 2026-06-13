#!/bin/bash
# test-l2-wiring.sh — L2 検証が ralph-loop の実経路で配線されていることのテスト
# locked_decision: test-l2-wiring.sh は参照削除ではなく新規作成する
# （L2 検証 = run_phase3 経由の layer_2.command 実行が ralph-loop 本流から到達可能か静的検証）
# 使い方: bash .forge/tests/test-l2-wiring.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

assert_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    pattern not found: ${pattern} in ${file}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RALPH="${SCRIPT_DIR}/.forge/loops/ralph-loop.sh"
PHASE3="${SCRIPT_DIR}/.forge/lib/phase3.sh"
DEV_JSON="${SCRIPT_DIR}/.forge/config/development.json"

echo -e "${BOLD}===== test-l2-wiring.sh — L2 配線テスト =====${NC}"
echo ""

# behavior: ralph-loop.sh が phase3.sh（L2 実行ロジック）を source している
assert_grep "ralph-loop が phase3.sh を source" 'source .*\.forge/lib/phase3\.sh' "$RALPH"

# behavior: L2_AUTO_RUN が development.json の layer_2.auto_run_after_all_tasks から読み込まれる
assert_grep "L2_AUTO_RUN を layer_2.auto_run_after_all_tasks から読込" \
  'L2_AUTO_RUN=.*layer_2\.auto_run_after_all_tasks' "$RALPH"

# behavior: ralph-loop 本流に L2_AUTO_RUN ガード経由の run_phase3 呼出が存在する
if grep -A2 'L2_AUTO_RUN.*=.*"true"' "$RALPH" 2>/dev/null | grep -q 'run_phase3'; then
  echo -e "  ${GREEN}✓${NC} L2_AUTO_RUN=true ガード直下で run_phase3 が呼ばれる"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} L2_AUTO_RUN=true ガード直下で run_phase3 が呼ばれる"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# behavior: phase3.sh に run_phase3 関数が定義されている
assert_grep "phase3.sh に run_phase3 定義" '^run_phase3\(\)' "$PHASE3"

# behavior: phase3.sh が completed タスクの validation.layer_2.command を収集する
assert_grep "phase3 が validation.layer_2.command を収集" \
  'select\(\.validation\.layer_2\.command != null\)' "$PHASE3"

# behavior: phase3.sh が layer_2.timeout_sec（task-stack 由来）を参照する
assert_grep "phase3 が layer_2.timeout_sec を参照" \
  '\.validation\.layer_2\.timeout_sec' "$PHASE3"

# behavior: phase3.sh の L2 失敗が修正タスク（l2fix）生成に配線されている
assert_grep "L2 失敗 → l2fix タスク生成に配線" 'l2fix' "$PHASE3"

# behavior: development.json に layer_2 設定セクションが存在する
if jq -e '.layer_2 | type == "object"' "$DEV_JSON" >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} development.json に layer_2 セクションが存在"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} development.json に layer_2 セクションが存在"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo ""
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL_COUNT"
