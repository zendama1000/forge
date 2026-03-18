#!/bin/bash
# test-preflight-integration.sh — preflight_check: development.json ↔ package.json 不整合検出 統合テスト
# L2 criteria: L2-004
# 前提: サーバー起動済みを前提としてよい（Phase 3 が管理）
# 使い方: bash .forge/tests/test-preflight-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FORGE_FLOW_SH="${REAL_ROOT}/.forge/loops/forge-flow.sh"

# ===== カラー =====
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
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:300}"
    FAIL=$((FAIL + 1))
  fi
}

echo -e "${BOLD}===== test-preflight-integration.sh — L2-004 preflight 統合テスト =====${NC}"
echo ""

# ===== テスト環境セットアップ =====
TMPDIR_INT=$(mktemp -d)
trap "rm -rf '${TMPDIR_INT}'" EXIT

# common.sh source に必要な変数
export ERRORS_FILE="${TMPDIR_INT}/errors.jsonl"
export RESEARCH_DIR="integration-test"
json_fail_count=0
touch "$ERRORS_FILE"

# 実プロジェクトルートを PROJECT_ROOT に設定
export PROJECT_ROOT="$REAL_ROOT"
source "${REAL_ROOT}/.forge/lib/common.sh"

# ===== _check_server_script_compat 抽出（常に実行） =====
EXTRACT_FILE="${TMPDIR_INT}/extract.sh"
awk -v "names=_check_server_script_compat" '
  BEGIN {
    split(names, arr, " ")
    for (i in arr) targets[arr[i] "()"] = 1
  }
  /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ {
    fname = $1
    if (fname in targets) { found = 1; depth = 0 }
  }
  found {
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "{") depth++
      if (c == "}") depth--
    }
    print
    if (depth <= 0 && NR > start_line) { found = 0; print "" }
    if (found && depth > 0) start_line = NR
  }
' "$FORGE_FLOW_SH" > "$EXTRACT_FILE"

if [ ! -s "$EXTRACT_FILE" ]; then
  echo -e "${RED}[ERROR] _check_server_script_compat の抽出失敗${NC}" >&2
  exit 1
fi
source "$EXTRACT_FILE"

# ===== 実際の start_command を読み取る =====
REAL_DEV_CONFIG="${REAL_ROOT}/.forge/config/development.json"
REAL_START_CMD=""
if [ -f "$REAL_DEV_CONFIG" ]; then
  REAL_START_CMD=$(jq -r '.server.start_command // "none"' "$REAL_DEV_CONFIG" 2>/dev/null || echo "none")
fi
echo "実際の start_command: ${REAL_START_CMD:-（不明）}"
echo ""

# ===== ワークプロジェクト（Node.js 模擬） =====
INT_WORK_DIR="${TMPDIR_INT}/work-project"
mkdir -p "$INT_WORK_DIR"

# ===== Test 1: 一致構成 → 検証通過 =====
# behavior: development.json の start_command と WORK_DIR の package.json scripts が一致 → exit 0
echo -e "${BOLD}[1] 一致構成: start_command に対応するスクリプトが存在 → 検証通過${NC}"

# テスト用に別個の PROJECT_ROOT を用意（実設定を汚染しない）
MATCH_PROJECT="${TMPDIR_INT}/match-project"
mkdir -p "${MATCH_PROJECT}/.forge/config"
printf '{"server":{"start_command":"npm run dev"}}' \
  > "${MATCH_PROJECT}/.forge/config/development.json"

# WORK_DIR に dev スクリプトあり
printf '{"scripts":{"dev":"node app.js","build":"webpack","test":"jest"}}' \
  > "${INT_WORK_DIR}/package.json"

OLD_PROJECT_ROOT="$PROJECT_ROOT"
export PROJECT_ROOT="$MATCH_PROJECT"
_WORK_DIR_ARG="$INT_WORK_DIR"
result=0
_check_server_script_compat || result=$?
export PROJECT_ROOT="$OLD_PROJECT_ROOT"

assert_eq "一致構成(npm run dev + devあり) → exit 0" "0" "$result"
echo ""

# ===== Test 2: 不整合構成 → exit 1 + エラーメッセージ =====
# behavior: development.json の start_command に存在しないスクリプト名 → exit 1 + エラーメッセージ出力
echo -e "${BOLD}[2] 不整合構成: 存在しないスクリプト → exit 1 + エラーメッセージ${NC}"

MISMATCH_PROJECT="${TMPDIR_INT}/mismatch-project"
mkdir -p "${MISMATCH_PROJECT}/.forge/config"
printf '{"server":{"start_command":"npm run nonexistent-script-xyz"}}' \
  > "${MISMATCH_PROJECT}/.forge/config/development.json"

# WORK_DIR の package.json に nonexistent-script-xyz なし
printf '{"scripts":{"dev":"node app.js","build":"webpack","test":"jest"}}' \
  > "${INT_WORK_DIR}/package.json"

export PROJECT_ROOT="$MISMATCH_PROJECT"
_WORK_DIR_ARG="$INT_WORK_DIR"
result=0
err_msg=$({ _check_server_script_compat; } 2>&1) || result=$?
export PROJECT_ROOT="$OLD_PROJECT_ROOT"

assert_eq "不整合構成 → exit 1" "1" "$result"
assert_contains "エラーに 'not found' が含まれる" "not found" "$err_msg"
assert_contains "エラーに 'Available:' が含まれる" "Available:" "$err_msg"
assert_contains "エラーに利用可能スクリプトが含まれる" "dev" "$err_msg"
echo ""

# ===== Test 3: pnpm 使用時 → スキップ（exit 0 + 警告） =====
# behavior: pnpm を使用中は検証スキップ、警告メッセージ表示
echo -e "${BOLD}[3] pnpm 使用時 → スキップ（exit 0 + 警告）${NC}"

PNPM_PROJECT="${TMPDIR_INT}/pnpm-project"
mkdir -p "${PNPM_PROJECT}/.forge/config"
printf '{"server":{"start_command":"pnpm --filter api dev"}}' \
  > "${PNPM_PROJECT}/.forge/config/development.json"

export PROJECT_ROOT="$PNPM_PROJECT"
_WORK_DIR_ARG=""
result=0
warn_msg=$({ _check_server_script_compat; } 2>&1) || result=$?
export PROJECT_ROOT="$OLD_PROJECT_ROOT"

assert_eq "pnpm → exit 0 (スキップ)" "0" "$result"
assert_contains "pnpm 警告メッセージ" "pnpm" "$warn_msg"
echo ""

# ===== Test 4: package.json 不在 → スキップ =====
# behavior: package.json が存在しない場合は検証スキップ
echo -e "${BOLD}[4] package.json 不在 → スキップ（exit 0）${NC}"

NOPKG_PROJECT="${TMPDIR_INT}/nopkg-project"
mkdir -p "${NOPKG_PROJECT}/.forge/config"
printf '{"server":{"start_command":"npm run dev"}}' \
  > "${NOPKG_PROJECT}/.forge/config/development.json"

NOPKG_WORK="${TMPDIR_INT}/nopkg-work"
mkdir -p "$NOPKG_WORK"
# package.json は作成しない

export PROJECT_ROOT="$NOPKG_PROJECT"
_WORK_DIR_ARG="$NOPKG_WORK"
result=0
_check_server_script_compat || result=$?
export PROJECT_ROOT="$OLD_PROJECT_ROOT"

assert_eq "package.json不在 → exit 0" "0" "$result"
echo ""

# ===== サマリー =====
echo ""
echo -e "${BOLD}=========================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL"
