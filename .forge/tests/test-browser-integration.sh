#!/bin/bash
# test-browser-integration.sh — Playwright MCP ブラウザテスト統合テスト
# 使い方: bash .forge/tests/test-browser-integration.sh

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
PROJECT_ROOT="/tmp/test-browser-integration"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$PROJECT_ROOT"
mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
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
STUB

source "${PROJECT_ROOT}/.forge/lib/stub-common.sh"

# テスト用変数
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
SCHEMAS_DIR="${PROJECT_ROOT}/.forge/schemas"
WORK_DIR="${PROJECT_ROOT}"

# development.json
cat > "$DEV_CONFIG" << 'JSON'
{
  "browser_testing": {
    "enabled": false,
    "playwright_mcp": {
      "command": "npx",
      "args": ["@anthropic/playwright-mcp-server"]
    },
    "model": "sonnet",
    "headless": true
  }
}
JSON

# ファイルをコピー
cp "${SCRIPT_DIR}/.forge/lib/browser-test.sh" "${PROJECT_ROOT}/.forge/lib/" 2>/dev/null || true
cp "${SCRIPT_DIR}/.forge/templates/browser-test-prompt.md" "${TEMPLATES_DIR}/" 2>/dev/null || true
cp "${SCRIPT_DIR}/.forge/schemas/browser-test.schema.json" "${SCHEMAS_DIR}/" 2>/dev/null || true
cp "${SCRIPT_DIR}/.claude/agents/browser-tester.md" "${AGENTS_DIR}/" 2>/dev/null || true

source "${PROJECT_ROOT}/.forge/lib/browser-test.sh"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: config toggle disabled → skip ---
echo -e "\n${BOLD}[1] browser_testing.enabled=false でスキップ${NC}"
l3_test='{"id":"login-test","strategy":"browser","instructions":"Navigate to /login"}'
output=$(execute_browser_test "$l3_test" "$WORK_DIR" 30 2>/dev/null)
result=$?
assert_eq "disabled 時は return 2 (skip)" "2" "$result"

# --- Test 2: config toggle enabled + agent missing → skip ---
echo -e "\n${BOLD}[2] enabled=true + エージェント不在 → スキップ${NC}"
cat > "$DEV_CONFIG" << 'JSON'
{
  "browser_testing": {
    "enabled": true,
    "playwright_mcp": {"command": "nonexistent-binary", "args": []},
    "model": "sonnet",
    "headless": true
  }
}
JSON

# エージェントを削除
rm -f "${AGENTS_DIR}/browser-tester.md"
output=$(execute_browser_test "$l3_test" "$WORK_DIR" 30 2>/dev/null)
result=$?
assert_eq "エージェント不在時は return 2 (skip)" "2" "$result"

# 復元
cp "${SCRIPT_DIR}/.claude/agents/browser-tester.md" "${AGENTS_DIR}/" 2>/dev/null || true

# --- Test 3: instructions missing → skip ---
echo -e "\n${BOLD}[3] instructions 未定義 → スキップ${NC}"
l3_test_no_inst='{"id":"empty-test","strategy":"browser"}'
output=$(execute_browser_test "$l3_test_no_inst" "$WORK_DIR" 30 2>/dev/null)
result=$?
assert_eq "instructions 未定義時は return 2 (skip)" "2" "$result"

# --- Test 4: strategy routing in execute_l3_test ---
echo -e "\n${BOLD}[4] execute_l3_test の strategy routing 確認${NC}"
# common.sh の execute_l3_test に browser strategy があるか確認
if grep -q "browser)" "${SCRIPT_DIR}/.forge/lib/common.sh"; then
  assert_eq "common.sh に browser strategy がある" "true" "true"
else
  assert_eq "common.sh に browser strategy がある" "true" "false"
fi

# --- Test 5: schema ファイルの妥当性 ---
echo -e "\n${BOLD}[5] browser-test.schema.json の妥当性${NC}"
if jq empty "${SCRIPT_DIR}/.forge/schemas/browser-test.schema.json" 2>/dev/null; then
  assert_eq "schema が有効な JSON" "true" "true"
else
  assert_eq "schema が有効な JSON" "true" "false"
fi

verdict_enum=$(jq -r '.properties.verdict.enum | join(",")' "${SCRIPT_DIR}/.forge/schemas/browser-test.schema.json" 2>/dev/null | tr -d '\r')
assert_eq "verdict enum が pass,fail" "pass,fail" "$verdict_enum"

# ===== クリーンアップ =====
rm -rf "$PROJECT_ROOT"

# ===== 結果 =====
echo ""
echo -e "${BOLD}=========================================="
echo -e "  browser-integration テスト結果"
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
