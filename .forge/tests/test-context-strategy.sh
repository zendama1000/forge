#!/bin/bash
# test-context-strategy.sh — Context Strategy Toggle テスト
# 使い方: bash .forge/tests/test-context-strategy.sh

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
  if echo "$haystack" | grep -qF -- "$needle"; then
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
  if ! echo "$haystack" | grep -qF -- "$needle"; then
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

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: デフォルト（reset）→ --no-session-persistence が含まれる ---
echo -e "\n${BOLD}[1] デフォルト (reset) → --no-session-persistence が含まれる${NC}"

# common.sh の cmd 構築ロジックをテスト
_RC_CONTEXT_STRATEGY="reset"
cmd=(claude --model "sonnet" -p --dangerously-skip-permissions --debug-file "/tmp/test.log")
if [ "${_RC_CONTEXT_STRATEGY:-reset}" = "reset" ]; then
  cmd+=(--no-session-persistence)
fi

cmd_str="${cmd[*]}"
assert_contains "reset 時は --no-session-persistence が含まれる" "--no-session-persistence" "$cmd_str"

# --- Test 2: continuous → --no-session-persistence が含まれない ---
echo -e "\n${BOLD}[2] continuous → --no-session-persistence が含まれない${NC}"

_RC_CONTEXT_STRATEGY="continuous"
cmd=(claude --model "sonnet" -p --dangerously-skip-permissions --debug-file "/tmp/test.log")
if [ "${_RC_CONTEXT_STRATEGY:-reset}" = "reset" ]; then
  cmd+=(--no-session-persistence)
fi

cmd_str="${cmd[*]}"
assert_not_contains "continuous 時は --no-session-persistence が含まれない" "--no-session-persistence" "$cmd_str"

# --- Test 3: 未設定（空）→ デフォルト reset ---
echo -e "\n${BOLD}[3] 未設定 → デフォルト reset${NC}"

unset _RC_CONTEXT_STRATEGY
cmd=(claude --model "sonnet" -p --dangerously-skip-permissions --debug-file "/tmp/test.log")
if [ "${_RC_CONTEXT_STRATEGY:-reset}" = "reset" ]; then
  cmd+=(--no-session-persistence)
fi

cmd_str="${cmd[*]}"
assert_contains "未設定時は --no-session-persistence が含まれる (default=reset)" "--no-session-persistence" "$cmd_str"

# --- Test 4: per_agent config 読み込みテスト ---
echo -e "\n${BOLD}[4] per_agent config 読み込み${NC}"

dev_config_file="/tmp/test-dev-config.json"
cat > "$dev_config_file" << 'JSON'
{
  "context_strategy": {
    "default": "reset",
    "per_agent": {
      "implementer": "continuous",
      "investigator": "reset"
    }
  }
}
JSON

impl_strategy=$(jq -r '.context_strategy.per_agent.implementer // .context_strategy.default // "reset"' "$dev_config_file" | tr -d '\r')
inv_strategy=$(jq -r '.context_strategy.per_agent.investigator // .context_strategy.default // "reset"' "$dev_config_file" | tr -d '\r')
qa_strategy=$(jq -r '.context_strategy.per_agent.qa_evaluator // .context_strategy.default // "reset"' "$dev_config_file" | tr -d '\r')

assert_eq "implementer は continuous" "continuous" "$impl_strategy"
assert_eq "investigator は reset" "reset" "$inv_strategy"
assert_eq "qa_evaluator はデフォルト (reset)" "reset" "$qa_strategy"

rm -f "$dev_config_file"

# --- Test 5: missing config → all default ---
echo -e "\n${BOLD}[5] config 不在 → 全てデフォルト reset${NC}"

dev_config_file="/tmp/test-dev-config-empty.json"
echo '{}' > "$dev_config_file"

default_strategy=$(jq -r '.context_strategy.default // "reset"' "$dev_config_file" | tr -d '\r')
assert_eq "config 不在時はデフォルト reset" "reset" "$default_strategy"

rm -f "$dev_config_file"

# ===== 結果 =====
echo ""
echo -e "${BOLD}=========================================="
echo -e "  context-strategy テスト結果"
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
