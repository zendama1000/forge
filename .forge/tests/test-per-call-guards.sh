#!/bin/bash
# test-per-call-guards.sh — per-call 予算ガード（--max-budget-usd / --max-turns プローブ）のテスト
# build_per_call_guard_args / claude_cli_supports_flag / run_claude への合成を FORGE_DRY_RUN で検証。
# 使い方: bash .forge/tests/test-per-call-guards.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:300}"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export RESEARCH_DIR="test-per-call-guards"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMPDIR}/notifications"
json_fail_count=0
touch "$ERRORS_FILE"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

echo -e "${BOLD}===== test-per-call-guards.sh — per-call 予算ガード =====${NC}"
echo ""

# ===== fixture config =====
CFG_OFF="${TMPDIR}/cb-off.json"
CFG_BUDGET="${TMPDIR}/cb-budget.json"
CFG_BOTH="${TMPDIR}/cb-both.json"
CFG_INVALID="${TMPDIR}/cb-invalid.json"
CFG_ABSENT="${TMPDIR}/cb-absent.json"
echo '{"per_call_guards": {"max_budget_usd": 0, "max_turns": 0}}' > "$CFG_OFF"
echo '{"per_call_guards": {"max_budget_usd": 3.0, "max_turns": 0}}' > "$CFG_BUDGET"
echo '{"per_call_guards": {"max_budget_usd": 2.5, "max_turns": 150}}' > "$CFG_BOTH"
echo '{"per_call_guards": {"max_budget_usd": "abc", "max_turns": -5}}' > "$CFG_INVALID"
echo '{}' > "$CFG_ABSENT"

# ========================================================================
echo -e "${BOLD}--- Group 1: build_per_call_guard_args（純関数） ---${NC}"
# ========================================================================

# behavior: 0/キー不在/config 不在 → 空出力（後方互換: フラグなし）
assert_eq "全て 0 → 空出力" "" "$(build_per_call_guard_args "$CFG_OFF")"
assert_eq "per_call_guards キー不在 → 空出力" "" "$(build_per_call_guard_args "$CFG_ABSENT")"
assert_eq "config ファイル不在 → 空出力" "" "$(build_per_call_guard_args "${TMPDIR}/nonexistent.json")"

# behavior: budget のみ設定 → --max-budget-usd のみ
assert_eq "budget=3.0 → --max-budget-usd 3.0" "--max-budget-usd 3.0" "$(build_per_call_guard_args "$CFG_BUDGET")"

# behavior: 非数値/負値 → 無効扱い（フラグなし）
assert_eq "非数値 budget / 負 turns → 空出力" "" "$(build_per_call_guard_args "$CFG_INVALID")"

# behavior: turns は CLI プローブ通過時のみ付与（キャッシュ注入で両分岐を検証）
_RC_CLI_HELP_CACHE="  --max-budget-usd <amount>  --max-turns <n>  --model <model>"
out_both=$(build_per_call_guard_args "$CFG_BOTH")
assert_eq "プローブ通過 → budget + turns" "--max-budget-usd 2.5 --max-turns 150" "$out_both"

_RC_CLI_HELP_CACHE="  --max-budget-usd <amount>  --model <model>"
out_noturns=$(build_per_call_guard_args "$CFG_BOTH")
assert_eq "プローブ不通過 → budget のみ（未知フラグを渡さない）" "--max-budget-usd 2.5" "$out_noturns"
unset _RC_CLI_HELP_CACHE

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: run_claude への合成（FORGE_DRY_RUN） ---${NC}"
# ========================================================================

AGENT_FILE="${TMPDIR}/agent.md"
echo "test agent" > "$AGENT_FILE"

# behavior: ガード無効（実 config は初期値 0）→ CMD にガードフラグが含まれない
_ORIG_PROJECT_ROOT="$PROJECT_ROOT"
FAKE_ROOT="${TMPDIR}/fake-root-off"
mkdir -p "${FAKE_ROOT}/.forge/config"
cp "$CFG_OFF" "${FAKE_ROOT}/.forge/config/circuit-breaker.json"
PROJECT_ROOT="$FAKE_ROOT"
cmd_off=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_not_contains "ガード 0 → CMD に --max-budget-usd なし" "--max-budget-usd" "$cmd_off"

# behavior: budget=3.0 → CMD に --max-budget-usd 3.0 が含まれる
FAKE_ROOT2="${TMPDIR}/fake-root-on"
mkdir -p "${FAKE_ROOT2}/.forge/config"
cp "$CFG_BUDGET" "${FAKE_ROOT2}/.forge/config/circuit-breaker.json"
PROJECT_ROOT="$FAKE_ROOT2"
cmd_on=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_contains "budget=3.0 → CMD に --max-budget-usd 3.0" "--max-budget-usd 3.0" "$cmd_on"

# behavior: effort / schema フラグと併存できる
SCHEMA_FILE="${TMPDIR}/schema.json"
echo '{"type":"object"}' > "$SCHEMA_FILE"
cmd_all=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt" "" 600 "" "$SCHEMA_FILE" "high")
assert_contains "併存: --effort high" "--effort high" "$cmd_all"
assert_contains "併存: --max-budget-usd" "--max-budget-usd 3.0" "$cmd_all"
assert_contains "併存: --json-schema" "--json-schema" "$cmd_all"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: _RC_MCP_CONFIG env チャネル ---${NC}"
# ========================================================================

# behavior: _RC_MCP_CONFIG 設定時のみ --mcp-config + --strict-mcp-config が付与される
MCP_FILE="${TMPDIR}/mcp.json"
echo '{"mcpServers":{}}' > "$MCP_FILE"
export _RC_MCP_CONFIG="$MCP_FILE"
cmd_mcp=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_contains "MCP 設定時: --mcp-config 付与" "--mcp-config ${MCP_FILE}" "$cmd_mcp"
assert_contains "MCP 設定時: --strict-mcp-config 付与（外部 MCP 遮断）" "--strict-mcp-config" "$cmd_mcp"
unset _RC_MCP_CONFIG

cmd_nomcp=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_not_contains "MCP 未設定: --mcp-config なし（他エージェント非汚染）" "--mcp-config" "$cmd_nomcp"

# behavior: 存在しないパスを指す場合は付与しない（graceful）
export _RC_MCP_CONFIG="${TMPDIR}/nonexistent-mcp.json"
cmd_badmcp=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_not_contains "MCP パス不在: --mcp-config なし" "--mcp-config" "$cmd_badmcp"
unset _RC_MCP_CONFIG

PROJECT_ROOT="$_ORIG_PROJECT_ROOT"

echo ""

# ========================================================================
# サマリー
# ========================================================================
TOTAL=$((PASS + FAIL))
echo -e "${BOLD}=========================================${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL}/${TOTAL}${NC}"
fi
echo -e "${BOLD}=========================================${NC}"

exit "$FAIL"
