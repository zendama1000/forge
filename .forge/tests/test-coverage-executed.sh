#!/bin/bash
# test-coverage-executed.sh — coverage/prominence の実行実績ベース化
# browser-cockpit の実害（L2/L3 定義済み・1件も未実行なのに prominence=none）の再現修正テスト
# 使い方: bash .forge/tests/test-coverage-executed.sh

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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    needle not found: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="/tmp/test-coverage-executed-$$"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/.forge/state"

log() { echo "[LOG] $1" >&2; }
jq_safe() { jq "$@" | tr -d '\r'; }

EXTRACT="${TEST_ROOT}/extract.sh"
: > "$EXTRACT"
for fn in _count_per_task_l3_executed compute_test_coverage_gaps compute_coverage_prominence; do
  sed -n "/^${fn}() {/,/^}/p" "${SCRIPT_DIR}/.forge/lib/phase3.sh" >> "$EXTRACT"
done
if ! grep -q '^compute_coverage_prominence() {' "$EXTRACT"; then
  echo "FATAL: 関数抽出失敗"
  echo "  PASS: 0  FAIL: 1"
  exit 1
fi
source "$EXTRACT"

# browser-cockpit 再現 fixture: 16 タスク completed、L2 定義 6 / L3 定義 5
TASK_STACK="${TEST_ROOT}/.forge/state/task-stack.json"
{
  echo '{"tasks":['
  for i in $(seq 1 16); do
    sep=","
    [ "$i" -eq 16 ] && sep=""
    if [ "$i" -le 6 ]; then
      echo "{\"task_id\":\"t${i}\",\"status\":\"completed\",\"validation\":{\"layer_1\":{\"command\":\"true\",\"expect\":\"e\"},\"layer_2\":{\"command\":\"npm run e2e -- e2e/t${i}.e2e.ts\",\"requires\":[\"server\"]}}}${sep}"
    elif [ "$i" -le 11 ]; then
      echo "{\"task_id\":\"t${i}\",\"status\":\"completed\",\"validation\":{\"layer_1\":{\"command\":\"true\",\"expect\":\"e\"},\"layer_3\":[{\"id\":\"L3-t${i}\",\"strategy\":\"api_e2e\",\"description\":\"d\",\"definition\":{},\"requires\":[\"server\"]}]}}${sep}"
    else
      echo "{\"task_id\":\"t${i}\",\"status\":\"completed\",\"validation\":{\"layer_1\":{\"command\":\"true\",\"expect\":\"e\"}}}${sep}"
    fi
  done
  echo ']}'
} | jq . > "$TASK_STACK"

TASK_EVENTS_FILE="${TEST_ROOT}/.forge/state/task-events.jsonl"
: > "$TASK_EVENTS_FILE"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: browser-cockpit 再現 — 定義済み・全未実行 → critical ---
echo -e "\n${BOLD}[1] 定義済み・未実行 → critical（偽陰性の修正）${NC}"
prom=$(compute_coverage_prominence 0 0)
assert_eq "L2/L3 定義済み・実行 0 件 → critical" "critical" "$prom"
gaps=$(compute_test_coverage_gaps 0 0 6 5)
assert_contains "gaps に NEVER EXECUTED (L3)" "L3 tests: defined but NEVER EXECUTED" "$gaps"
assert_contains "gaps に NEVER EXECUTED (L2)" "L2 tests: defined but NEVER EXECUTED" "$gaps"
assert_contains "gaps に L2 deferred 件数" "L2 deferred: 6" "$gaps"
assert_contains "gaps に L3 deferred 件数" "L3 deferred: 5" "$gaps"

# --- Test 2: 実行実績ありなら none ---
echo -e "\n${BOLD}[2] 実行実績あり → none${NC}"
prom=$(compute_coverage_prominence 4 3)
assert_eq "L2/L3 とも実行実績あり → none" "none" "$prom"

# --- Test 3: L3 実行済み・L2 未実行 → medium ---
echo -e "\n${BOLD}[3] L2 未実行 → medium${NC}"
prom=$(compute_coverage_prominence 0 3)
assert_eq "L3 実行済み・L2 未実行 → medium" "medium" "$prom"

# --- Test 4: per-task L3 実行（イベントログ）を合算 ---
echo -e "\n${BOLD}[4] per-task L3 実行の合算${NC}"
echo '{"task_id":"t7","event":"l3_test_completed","detail":{"pass":2,"fail":0,"skip":0},"timestamp":"t"}' >> "$TASK_EVENTS_FILE"
echo '{"task_id":"t8","event":"l3_test_completed","detail":{"pass":0,"fail":1,"skip":1},"timestamp":"t"}' >> "$TASK_EVENTS_FILE"
n=$(_count_per_task_l3_executed)
assert_eq "イベントから実行数 3 (pass2+fail1、skip 除外)" "3" "$n"
prom=$(compute_coverage_prominence 4 0)
assert_eq "Phase3 L3=0 でも per-task 実行があれば critical でない" "none" "$prom"

# --- Test 5: 引数なし（後方互換 — 定義ベース） ---
echo -e "\n${BOLD}[5] 後方互換（定義ベース）${NC}"
prom=$(compute_coverage_prominence)
assert_eq "引数なしは定義ベース（L2/L3 定義あり → none）" "none" "$prom"
gaps=$(compute_test_coverage_gaps)
assert_contains "定義ベース gaps は定義数を出す" "L2 tests: 6 defined / 16 tasks" "$gaps"

# --- Test 6: L3 未定義は従来どおり critical ---
echo -e "\n${BOLD}[6] L3 未定義 → critical 維持${NC}"
jq '.tasks |= map(del(.validation.layer_3))' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
: > "$TASK_EVENTS_FILE"
prom=$(compute_coverage_prominence 4 0)
assert_eq "L3 定義ゼロ → critical" "critical" "$prom"

# --- Test 7: validation v2（checks[].layer==2/3）のみのタスクも「定義あり」に数える（batch#11 R13） ---
echo -e "\n${BOLD}[7] v2 checks のみのタスクを L2/L3 定義に数える（4.5f: L2 0/28 の誤集計）${NC}"
jq '.tasks += [
  {"task_id":"v2-l2","status":"completed","validation":{"checks":[{"layer":1,"verb":"run_test","runner":"vitest"},{"layer":2,"verb":"run_test","runner":"vitest","args":["tests/e2e"],"requires":["server"]}]}},
  {"task_id":"v2-l3","status":"completed","validation":{"checks":[{"layer":3,"verb":"effect_smoke","argv":["node","x.mjs"]}]}}
]' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
gaps=$(compute_test_coverage_gaps)
assert_contains "L2 定義は legacy 6 + v2 1 = 7（18 タスク）" "L2 tests: 7 defined / 18 tasks" "$gaps"
# L3 は「定義あり・未実行」でも critical（仕様）なので、定義数は gaps の文言で検証する
assert_contains "L3 定義は v2 の layer 3 checks 1 件が数えられる（Test 6 で legacy L3 は全削除済み）" "L3 tests: 1 defined / 18 tasks" "$gaps"
prom=$(compute_coverage_prominence 4 3)
assert_eq "v2 L3 定義あり + 実行実績あり → critical でない" "false" "$([ "$prom" = "critical" ] && echo true || echo false)"
jq '.tasks |= map(select(.task_id != "v2-l3"))' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
gaps=$(compute_test_coverage_gaps)
assert_contains "v2 L3 を外すと L3 定義 0" "L3 tests: 0 defined / 17 tasks" "$gaps"
prom=$(compute_coverage_prominence 4 3)
assert_eq "L3 定義ゼロは実行実績があっても critical（legacy と同じ扱い）" "critical" "$prom"

# ===== クリーンアップ =====
rm -rf "$TEST_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  coverage-executed テスト結果"
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
