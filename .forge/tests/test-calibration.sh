#!/bin/bash
# test-calibration.sh — calibration.sh 単体テスト
# 使い方: bash .forge/tests/test-calibration.sh

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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:200}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="/tmp/test-calibration"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$PROJECT_ROOT"
mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"

# 必要な共通関数のスタブ
cat > "${PROJECT_ROOT}/.forge/lib/stub-common.sh" << 'STUB'
log() { echo "[LOG] $1" >&2; }
now_ts() { date +%Y%m%d-%H%M%S; }
jq_safe() { jq "$@" | tr -d '\r'; }
record_task_event() { :; }
acquire_lock() { return 0; }
release_lock() { :; }
STUB

# source
source "${PROJECT_ROOT}/.forge/lib/stub-common.sh"

# テスト用変数
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"

# calibration.sh をコピーして source
cp "${SCRIPT_DIR}/.forge/lib/calibration.sh" "${PROJECT_ROOT}/.forge/lib/"
source "${PROJECT_ROOT}/.forge/lib/calibration.sh"
# CALIBRATION_FILE を上書き
CALIBRATION_FILE="${PROJECT_ROOT}/.forge/state/calibration-data.jsonl"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: 空の状態で get_calibration_examples ---
echo -e "\n${BOLD}[1] 空の状態で get_calibration_examples${NC}"
result=$(get_calibration_examples "evidence-da" 3)
assert_eq "空データ時は空文字を返す" "" "$result"

# --- Test 2: record_calibration_example ---
echo -e "\n${BOLD}[2] record_calibration_example${NC}"
record_calibration_example "evidence-da" "task-01" \
  '{"recommendation":"continue","confidence":"high"}' \
  "reject" "テストカバレッジ不足" "pivot"

assert_eq "JSONL ファイルが作成される" "true" "$([ -f "$CALIBRATION_FILE" ] && echo true || echo false)"
line_count=$(wc -l < "$CALIBRATION_FILE" | tr -d ' ')
assert_eq "1行記録される" "1" "$line_count"

# --- Test 3: get_calibration_examples で取得 ---
echo -e "\n${BOLD}[3] get_calibration_examples で取得${NC}"
result=$(get_calibration_examples "evidence-da" 3)
assert_contains "事例ヘッダーが含まれる" "キャリブレーション事例" "$result"
assert_contains "task-01 が含まれる" "task-01" "$result"
assert_contains "REJECT が含まれる" "reject" "$result"

# --- Test 4: evaluator フィルタ ---
echo -e "\n${BOLD}[4] evaluator フィルタ${NC}"
record_calibration_example "qa-evaluator" "task-02" \
  '{"verdict":"pass"}' \
  "reject" "エッジケース漏れ" "fail"

result_da=$(get_calibration_examples "evidence-da" 3)
result_qa=$(get_calibration_examples "qa-evaluator" 3)
assert_contains "evidence-da は task-01 を含む" "task-01" "$result_da"
assert_not_contains "evidence-da は task-02 を含まない" "task-02" "$result_da"
assert_contains "qa-evaluator は task-02 を含む" "task-02" "$result_qa"

# --- Test 5: compute_divergence_rate ---
echo -e "\n${BOLD}[5] compute_divergence_rate${NC}"
result=$(compute_divergence_rate)
assert_contains "全体の乖離率" "/" "$result"

result_da=$(compute_divergence_rate "evidence-da")
assert_contains "evidence-da 乖離率" "1/1" "$result_da"

# --- Test 6: 空 bootstrap（compute_divergence_rate） ---
echo -e "\n${BOLD}[6] 空 bootstrap${NC}"
rm -f "$CALIBRATION_FILE"
result=$(compute_divergence_rate)
assert_eq "空時は 0/0 (0%)" "0/0 (0%)" "$result"

# --- Test 7: malformed line resilience ---
echo -e "\n${BOLD}[7] malformed line resilience${NC}"
echo "not valid json" > "$CALIBRATION_FILE"
record_calibration_example "evidence-da" "task-03" \
  '{"recommendation":"continue"}' "accept" "OK" "continue"
result=$(get_calibration_examples "evidence-da" 3)
# 不正行をスキップして正常行が返ること
assert_contains "正常行が取得できる" "task-03" "$result"

# --- Test 8: detect_reworked_tasks ---
echo -e "\n${BOLD}[8] detect_reworked_tasks${NC}"
rm -f "$CALIBRATION_FILE"
# task-stack.json をセットアップ
cat > "$TASK_STACK" << 'JSON'
{
  "tasks": [
    {
      "task_id": "task-rework-01",
      "status": "pending",
      "previous_status": "completed",
      "fail_count": 0
    }
  ]
}
JSON

# evidence-da result を作成
mkdir -p "${DEV_LOG_DIR}/task-rework-01"
echo '{"recommendation":"continue","confidence":"high"}' > "${DEV_LOG_DIR}/task-rework-01/evidence-da-result.json"

detect_reworked_tasks

assert_eq "キャリブレーション記録が生成される" "true" "$([ -f "$CALIBRATION_FILE" ] && echo true || echo false)"
assert_contains "evidence-da の記録" "evidence-da" "$(cat "$CALIBRATION_FILE")"
assert_contains "task-rework-01" "task-rework-01" "$(cat "$CALIBRATION_FILE")"

# previous_status がクリアされたか確認
prev=$(jq_safe -r '.tasks[0].previous_status // "null"' "$TASK_STACK")
assert_eq "previous_status がクリアされる" "null" "$prev"

# ===== クリーンアップ =====
rm -rf "$PROJECT_ROOT"

# ===== 結果 =====
echo ""
echo -e "${BOLD}=========================================="
echo -e "  calibration.sh テスト結果"
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
