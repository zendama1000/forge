#!/bin/bash
# run-all-tests.sh — 全テストスイート一括実行ランナー
# 各テストを独立サブプロセスで実行し、結果を集約する。
# 使い方: bash .forge/tests/run-all-tests.sh

set -uo pipefail

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ===== テストスイート一覧（実行順: 速い→遅い） =====
TEST_SUITES=(
  "${SCRIPT_DIR}/test-config-integrity.sh"
  "${SCRIPT_DIR}/test-research-config.sh"
  "${SCRIPT_DIR}/test-validate-json.sh"
  "${SCRIPT_DIR}/test-safety.sh"
  "${SCRIPT_DIR}/test-evidence-da.sh"
  "${SCRIPT_DIR}/test-priming.sh"
  "${SCRIPT_DIR}/test-lessons.sh"
  "${SCRIPT_DIR}/test-events.sh"
  "${SCRIPT_DIR}/test-heartbeat.sh"
  "${SCRIPT_DIR}/test-ralph-engine.sh"
  "${SCRIPT_DIR}/test-research-e2e.sh"
  "${SCRIPT_DIR}/test-monitor.sh"
  "${SCRIPT_DIR}/test-rate-limit-recovery.sh"
  "${SCRIPT_DIR}/test-calibration.sh"
  "${SCRIPT_DIR}/test-sprint-contract.sh"
  "${SCRIPT_DIR}/test-qa-evaluator.sh"
  "${SCRIPT_DIR}/test-ablation.sh"
  "${SCRIPT_DIR}/test-context-strategy.sh"
  "${SCRIPT_DIR}/test-browser-integration.sh"
  "${PROJECT_ROOT}/test-l2-wiring.sh"
  "${PROJECT_ROOT}/tests/e2e/run-playwright.sh"
)

echo -e "${BOLD}===== Forge Harness Test Runner =====${NC}"
echo -e "  実行日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

suite_pass=0
suite_fail=0
suite_skip=0
results=()
start_time=$SECONDS

for test_file in "${TEST_SUITES[@]}"; do
  suite_name=$(basename "$test_file")

  if [ ! -f "$test_file" ]; then
    echo -e "  ${YELLOW}SKIP${NC}  ${suite_name}  (ファイル不在)"
    suite_skip=$((suite_skip + 1))
    results+=("SKIP:${suite_name}")
    continue
  fi

  echo -e "  ${BOLD}RUN${NC}   ${suite_name}"
  suite_start=$SECONDS

  # 独立サブプロセスで実行（PROJECT_ROOT を渡す）
  output=$(cd "$PROJECT_ROOT" && bash "$test_file" 2>&1)
  exit_code=$?

  elapsed=$((SECONDS - suite_start))

  if [ "$exit_code" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}  ${suite_name}  (${elapsed}s)"
    suite_pass=$((suite_pass + 1))
    results+=("PASS:${suite_name}")
  else
    echo -e "  ${RED}FAIL${NC}  ${suite_name}  (exit=${exit_code}, ${elapsed}s)"
    # 失敗時は最後の数行を表示
    echo "$output" | tail -20 | sed 's/^/    /'
    suite_fail=$((suite_fail + 1))
    results+=("FAIL:${suite_name}")
  fi
done

total_elapsed=$((SECONDS - start_time))
total_suites=$((suite_pass + suite_fail + suite_skip))

echo ""
echo -e "${BOLD}=========================================="
echo -e "  結果サマリー"
echo -e "==========================================${NC}"
for r in "${results[@]}"; do
  status="${r%%:*}"
  name="${r#*:}"
  case "$status" in
    PASS) echo -e "  ${GREEN}✓${NC} ${name}" ;;
    FAIL) echo -e "  ${RED}✗${NC} ${name}" ;;
    SKIP) echo -e "  ${YELLOW}−${NC} ${name}" ;;
  esac
done
echo ""
echo -e "  PASS: ${suite_pass}  FAIL: ${suite_fail}  SKIP: ${suite_skip}  Total: ${total_suites}  (${total_elapsed}s)"
echo ""

if [ "$suite_fail" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL TEST SUITES PASSED (${suite_pass}/${total_suites} suites)${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}SOME TEST SUITES FAILED (${suite_fail}/${total_suites} failed)${NC}"
  exit 1
fi
