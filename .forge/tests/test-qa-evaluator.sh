#!/bin/bash
# test-qa-evaluator.sh — run_qa_evaluator() 単体テスト
# 使い方: bash .forge/tests/test-qa-evaluator.sh

set -uo pipefail

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

# ===== テスト集計 =====
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

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="/tmp/test-qa-evaluator"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$PROJECT_ROOT"
mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/state/.lock"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"
mkdir -p "${PROJECT_ROOT}/.forge/templates"
mkdir -p "${PROJECT_ROOT}/.forge/schemas"
mkdir -p "${PROJECT_ROOT}/.claude/agents"

# 必要な共通関数のスタブ
cat > "${PROJECT_ROOT}/.forge/lib/stub-common.sh" << 'STUB'
log() { echo "[LOG] $1" >&2; }
now_ts() { date +%Y%m%d-%H%M%S; }
jq_safe() { jq "$@" | tr -d '\r'; }
render_template() { cat "$1"; }
run_claude() { return 1; }
validate_json() { return 1; }
metrics_start() { :; }
metrics_record() { :; }
record_task_event() { :; }
notify_human() { :; }
acquire_lock() { return 0; }
release_lock() { :; }
get_calibration_examples() { echo ""; }
STUB

source "${PROJECT_ROOT}/.forge/lib/stub-common.sh"

# テスト用変数
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
SCHEMAS_DIR="${PROJECT_ROOT}/.forge/schemas"
WORK_DIR="${PROJECT_ROOT}"
CONTEXT_STRATEGY_QA_EVALUATOR="reset"

# ファイルをコピー
cp "${SCRIPT_DIR}/.forge/lib/qa-evaluator.sh" "${PROJECT_ROOT}/.forge/lib/" 2>/dev/null || true
cp "${SCRIPT_DIR}/.forge/templates/qa-evaluator-prompt.md" "${TEMPLATES_DIR}/" 2>/dev/null || true
cp "${SCRIPT_DIR}/.forge/schemas/qa-evaluator.schema.json" "${SCHEMAS_DIR}/" 2>/dev/null || true
cp "${SCRIPT_DIR}/.claude/agents/qa-evaluator.md" "${AGENTS_DIR}/" 2>/dev/null || true

# source qa-evaluator.sh
source "${PROJECT_ROOT}/.forge/lib/qa-evaluator.sh"

# task-stack.json
cat > "$TASK_STACK" << 'JSON'
{
  "tasks": [
    {"task_id": "task-01", "status": "in_progress", "fail_count": 0, "qa_fail_count": 0},
    {"task_id": "task-qa-max", "status": "in_progress", "fail_count": 0, "qa_fail_count": 3}
  ]
}
JSON

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: disabled skip ---
echo -e "\n${BOLD}[1] QA_EVALUATOR_ENABLED=false でスキップ${NC}"
QA_EVALUATOR_ENABLED=false
QA_MAX_FAILURES=2
task_dir="${DEV_LOG_DIR}/task-01"
mkdir -p "$task_dir"

run_qa_evaluator "task-01" "$task_dir" '{"task_id":"task-01","required_behaviors":["test"]}'
result=$?
assert_eq "disabled 時は return 0 (pass)" "0" "$result"

# --- Test 2: agent/template missing → graceful pass ---
echo -e "\n${BOLD}[2] エージェント不在で graceful pass${NC}"
QA_EVALUATOR_ENABLED=true
# エージェントファイルを一時的に削除
mv "${AGENTS_DIR}/qa-evaluator.md" "${AGENTS_DIR}/qa-evaluator.md.bak" 2>/dev/null || true

run_qa_evaluator "task-01" "$task_dir" '{"task_id":"task-01"}'
result=$?
assert_eq "エージェント不在時は return 0 (pass)" "0" "$result"

# 復元
mv "${AGENTS_DIR}/qa-evaluator.md.bak" "${AGENTS_DIR}/qa-evaluator.md" 2>/dev/null || true

# --- Test 3: max_qa_failures 超過で auto-pass ---
echo -e "\n${BOLD}[3] max_qa_failures 超過で auto-pass${NC}"
QA_EVALUATOR_ENABLED=true
QA_MAX_FAILURES=2
task_dir_max="${DEV_LOG_DIR}/task-qa-max"
mkdir -p "$task_dir_max"

run_qa_evaluator "task-qa-max" "$task_dir_max" '{"task_id":"task-qa-max"}'
result=$?
assert_eq "QA 失敗上限到達時は return 0 (auto-pass)" "0" "$result"

# --- Test 4: run_claude 失敗 → graceful pass ---
echo -e "\n${BOLD}[4] run_claude 失敗で graceful pass${NC}"
QA_EVALUATOR_ENABLED=true
QA_MAX_FAILURES=5
# run_claude はスタブで return 1 のまま

run_qa_evaluator "task-01" "$task_dir" '{"task_id":"task-01","required_behaviors":["test"]}'
result=$?
assert_eq "run_claude 失敗時は return 0 (pass)" "0" "$result"

# --- Test 5: verdict=pass (mock) ---
echo -e "\n${BOLD}[5] verdict=pass のシミュレーション${NC}"
# run_claude を成功するように上書き
run_claude() {
  local output_file="$4"
  echo '{"verdict":"pass","issues":[],"feedback":""}' > "${output_file}.pending"
  return 0
}
validate_json() {
  local file="$1"
  [ -f "${file}.pending" ] && mv "${file}.pending" "$file"
  return 0
}

run_qa_evaluator "task-01" "$task_dir" '{"task_id":"task-01","required_behaviors":["test"]}'
result=$?
assert_eq "verdict=pass 時は return 0" "0" "$result"

# --- Test 6: verdict=fail (mock) ---
echo -e "\n${BOLD}[6] verdict=fail のシミュレーション${NC}"
run_claude() {
  local output_file="$4"
  echo '{"verdict":"fail","issues":[{"severity":"high","description":"missing edge case"}],"feedback":"Fix edge cases"}' > "${output_file}.pending"
  return 0
}

# qa_fail_count をリセット
jq '.tasks |= map(if .task_id == "task-01" then .qa_fail_count = 0 else . end)' \
  "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"

run_qa_evaluator "task-01" "$task_dir" '{"task_id":"task-01","required_behaviors":["test"]}'
result=$?
assert_eq "verdict=fail 時は return 1" "1" "$result"
assert_eq "feedback ファイルが作成される" "true" "$([ -f "${task_dir}/qa-evaluator-feedback.txt" ] && echo true || echo false)"

# qa_fail_count がインクリメントされたか
qa_fc=$(jq --arg id "task-01" '.tasks[] | select(.task_id == $id) | .qa_fail_count // 0' "$TASK_STACK" | tr -d '\r')
assert_eq "qa_fail_count がインクリメントされる" "1" "$qa_fc"

# ===== クリーンアップ =====
rm -rf "$PROJECT_ROOT"

# ===== 結果 =====
echo ""
echo -e "${BOLD}=========================================="
echo -e "  qa-evaluator テスト結果"
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
