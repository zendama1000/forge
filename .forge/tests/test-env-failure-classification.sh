#!/bin/bash
# test-env-failure-classification.sh — 環境起因失敗の分類 / requires 充足判定 / filter_l3_tests 3値分類
# 使い方: bash .forge/tests/test-env-failure-classification.sh

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
TEST_ROOT="/tmp/test-env-failure-classification"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/.forge/state" "${TEST_ROOT}/work"

log() { echo "[LOG] $1" >&2; }
jq_safe() { jq "$@" | tr -d '\r'; }

# common.sh から被テスト関数を sed 抽出
EXTRACT="${TEST_ROOT}/extract.sh"
: > "$EXTRACT"
for fn in is_environmental_failure requires_entry_satisfiable filter_l3_tests; do
  sed -n "/^${fn}() {/,/^}/p" "${SCRIPT_DIR}/.forge/lib/common.sh" >> "$EXTRACT"
done
if ! grep -q '^is_environmental_failure() {' "$EXTRACT" || \
   ! grep -q '^requires_entry_satisfiable() {' "$EXTRACT" || \
   ! grep -q '^filter_l3_tests() {' "$EXTRACT"; then
  echo "FATAL: 関数抽出失敗"
  echo "  PASS: 0  FAIL: 1"
  exit 1
fi
source "$EXTRACT"

PROJECT_ROOT="$TEST_ROOT"
WORK_DIR="${TEST_ROOT}/work"
DEV_CONFIG="${TEST_ROOT}/development.json"
echo '{"server":{"start_command":"none","health_check_url":""}}' > "$DEV_CONFIG"
ENV_CAPABILITIES_FILE="${TEST_ROOT}/.forge/state/env-capabilities.json"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: 環境系署名の判定 ---
echo -e "\n${BOLD}[1] is_environmental_failure 署名判定${NC}"
is_environmental_failure "Error: connect ECONNREFUSED 127.0.0.1:3001" && r=env || r=not
assert_eq "ECONNREFUSED → 環境起因" "env" "$r"
is_environmental_failure "browserType.launch: Executable doesn't exist at /ms-playwright/chromium" && r=env || r=not
assert_eq "playwright 実行ファイル不在 → 環境起因" "env" "$r"
is_environmental_failure "bash: camoufox: command not found" && r=env || r=not
assert_eq "command not found → 環境起因" "env" "$r"
is_environmental_failure "Error: cannot open display :0" && r=env || r=not
assert_eq "display 不能 → 環境起因" "env" "$r"

# --- Test 2: 偽陽性ガード（実装バグは環境起因にしない） ---
echo -e "\n${BOLD}[2] 偽陽性ガード${NC}"
is_environmental_failure "AssertionError: expected 42 but got 41" && r=env || r=not
assert_eq "assertion 失敗 → 非環境" "not" "$r"
is_environmental_failure "HTTP status 404 returned from /api/users" && r=env || r=not
assert_eq "HTTP 404 単体 → 非環境" "not" "$r"
is_environmental_failure "ENOENT: no such file or directory, open 'config.json'" && r=env || r=not
assert_eq "一般 ENOENT → 非環境（playwright 等の文脈なし）" "not" "$r"
is_environmental_failure "" && r=env || r=not
assert_eq "空出力 → 非環境" "not" "$r"

# --- Test 3: DEV_CONFIG による署名拡張 ---
echo -e "\n${BOLD}[3] env_failure_signatures 拡張${NC}"
echo '{"env_failure_signatures":["CUSTOM_ENV_MARKER"]}' > "$DEV_CONFIG"
is_environmental_failure "failed with CUSTOM_ENV_MARKER detected" && r=env || r=not
assert_eq "カスタム署名 → 環境起因" "env" "$r"
echo '{"server":{"start_command":"none","health_check_url":""}}' > "$DEV_CONFIG"

# --- Test 4: requires_entry_satisfiable（live 判定） ---
echo -e "\n${BOLD}[4] requires 充足判定（live）${NC}"
requires_entry_satisfiable "cmd:bash" && r=ok || r=ng
assert_eq "cmd:bash → 充足" "ok" "$r"
requires_entry_satisfiable "cmd:nonexistent-cmd-xyz" && r=ok || r=ng
assert_eq "cmd:不在 → 不足" "ng" "$r"
export TEST_SET_VAR="1"
requires_entry_satisfiable "env:TEST_SET_VAR" && r=ok || r=ng
assert_eq "env:設定済み → 充足" "ok" "$r"
requires_entry_satisfiable "env:TEST_UNSET_VAR_XYZ" && r=ok || r=ng
assert_eq "env:未設定 → 不足" "ng" "$r"
touch "${WORK_DIR}/exists.txt"
requires_entry_satisfiable "file:exists.txt" && r=ok || r=ng
assert_eq "file:存在 → 充足" "ok" "$r"
requires_entry_satisfiable "server" && r=ok || r=ng
assert_eq "server (start_command=none, health なし) → 不足" "ng" "$r"

# --- Test 5: capabilities ファイルが権威 ---
echo -e "\n${BOLD}[5] env-capabilities 権威判定${NC}"
echo '{"probed_at":"t","capabilities":{},"capability_tags":["browser","cmd:node"]}' > "$ENV_CAPABILITIES_FILE"
requires_entry_satisfiable "browser" && r=ok || r=ng
assert_eq "caps に browser あり → 充足" "ok" "$r"
requires_entry_satisfiable "docker" && r=ok || r=ng
assert_eq "caps に docker なし → 不足（権威）" "ng" "$r"
requires_entry_satisfiable "network" && r=ok || r=ng
assert_eq "caps に network なし → 不足（権威）" "ng" "$r"
requires_entry_satisfiable "cmd:bash" && r=ok || r=ng
assert_eq "cmd: は caps 外でも live フォールバック" "ok" "$r"
rm -f "$ENV_CAPABILITIES_FILE"

# --- Test 6: filter_l3_tests 3値分類 ---
echo -e "\n${BOLD}[6] filter_l3_tests 3値分類${NC}"
TASK_JSON='{
  "validation": {
    "layer_3": [
      {"id": "L3-a", "strategy": "structural", "description": "d", "definition": {}},
      {"id": "L3-b", "strategy": "api_e2e", "description": "d", "definition": {}, "requires": ["server"]},
      {"id": "L3-c", "strategy": "cli_flow", "description": "d", "definition": {}, "requires": ["cmd:nonexistent-cmd-xyz"]},
      {"id": "L3-d", "strategy": "browser", "description": "d", "definition": {}, "deferred": true, "deferred_reason": "実ブラウザ依存"}
    ]
  }
}'
imm=$(filter_l3_tests "$TASK_JSON" "immediate")
srv=$(filter_l3_tests "$TASK_JSON" "server")
def=$(filter_l3_tests "$TASK_JSON" "deferred")
assert_eq "immediate = 1件 (L3-a)" "1" "$(echo "$imm" | jq 'length')"
assert_eq "immediate に L3-a" "L3-a" "$(echo "$imm" | jq -r '.[0].id')"
assert_eq "server = 1件 (L3-b)" "1" "$(echo "$srv" | jq 'length')"
assert_eq "server に L3-b" "L3-b" "$(echo "$srv" | jq -r '.[0].id')"
assert_eq "deferred = 2件 (L3-c, L3-d)" "2" "$(echo "$def" | jq 'length')"
assert_eq "L3-c に環境能力不足の理由" "環境能力不足: cmd:nonexistent-cmd-xyz" "$(echo "$def" | jq -r '.[] | select(.id=="L3-c") | ._deferred_reason')"
assert_eq "L3-d は明示理由を維持" "実ブラウザ依存" "$(echo "$def" | jq -r '.[] | select(.id=="L3-d") | ._deferred_reason')"

# --- Test 7: 既存2モードの後方互換（requires 全充足のケース） ---
echo -e "\n${BOLD}[7] 後方互換${NC}"
COMPAT_JSON='{
  "validation": {
    "layer_3": [
      {"id": "L3-x", "strategy": "structural", "description": "d", "definition": {}, "requires": ["cmd:bash"]},
      {"id": "L3-y", "strategy": "api_e2e", "description": "d", "definition": {}, "requires": ["server", "cmd:bash"]}
    ]
  }
}'
assert_eq "充足 requires のみ → immediate 維持" "L3-x" "$(filter_l3_tests "$COMPAT_JSON" "immediate" | jq -r '.[0].id')"
assert_eq "server+充足 → server 維持" "L3-y" "$(filter_l3_tests "$COMPAT_JSON" "server" | jq -r '.[0].id')"
assert_eq "layer_3 なしタスク → 空配列" "0" "$(filter_l3_tests '{"validation":{}}' "immediate" | jq 'length')"

# ===== クリーンアップ =====
rm -rf "$TEST_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  env-failure-classification テスト結果"
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
