#!/bin/bash
# test-orphan-detector.sh — detect_orphan_files（新規ファイルの被参照チェック）
# 使い方: bash .forge/tests/test-orphan-detector.sh

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
TEST_ROOT="/tmp/test-orphan-detector"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/repo/src"

DEBT_LOG="${TEST_ROOT}/debts.log"
NOTIFY_LOG="${TEST_ROOT}/notify.log"
log() { echo "[LOG] $1" >&2; }
jq_safe() { jq "$@" | tr -d '\r'; }
notify_human() { echo "$1|$2" >> "$NOTIFY_LOG"; }
record_quality_debt() { echo "$1|$2|$3" >> "$DEBT_LOG"; }

EXTRACT="${TEST_ROOT}/extract.sh"
sed -n '/^detect_orphan_files() {/,/^}/p' "${SCRIPT_DIR}/.forge/lib/dev-phases.sh" > "$EXTRACT"
if ! grep -q '^detect_orphan_files() {' "$EXTRACT"; then
  echo "FATAL: 関数抽出失敗"
  echo "  PASS: 0  FAIL: 1"
  exit 1
fi
source "$EXTRACT"

DEV_CONFIG="${TEST_ROOT}/development.json"
echo '{}' > "$DEV_CONFIG"

REPO="${TEST_ROOT}/repo"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@test" && git -C "$REPO" config user.name "test"
cat > "${REPO}/src/app.ts" << 'TS'
import { helper } from "./wired-module";
console.log(helper());
TS
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Initial commit"
git -C "$REPO" commit -q --allow-empty -m "forge: dev-phase mvp completed - 3 tasks"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: 被参照ありの新規ファイルは orphan にならない ---
echo -e "\n${BOLD}[1] 配線済みファイルは検出しない${NC}"
: > "$DEBT_LOG"
echo 'export const helper = () => "ok";' > "${REPO}/src/wired-module.ts"
rc=0; detect_orphan_files "$REPO" "core" || rc=$?
assert_eq "rc=0" "0" "$rc"
assert_eq "wired-module は orphan にならない" "0" "$(grep -c 'wired-module' "$DEBT_LOG" || true)"

# --- Test 2: 被参照ゼロの新規ファイルを検出 ---
echo -e "\n${BOLD}[2] 被参照ゼロを検出${NC}"
: > "$DEBT_LOG"
echo 'export const dead = () => "dead";' > "${REPO}/src/dead-orphan-module.ts"
detect_orphan_files "$REPO" "core"
assert_eq "orphan_file が台帳記録される" "1" "$(grep -c '^orphan_file|phase-core|' "$DEBT_LOG" || true)"
assert_eq "orphan にファイル名が含まれる" "1" "$(grep -c 'dead-orphan-module' "$DEBT_LOG" || true)"

# --- Test 3: allowlist（.md / index.* / テスト）は対象外 ---
echo -e "\n${BOLD}[3] allowlist 対象外${NC}"
rm -f "${REPO}/src/dead-orphan-module.ts"
: > "$DEBT_LOG"
echo '# doc' > "${REPO}/NOTES-unreferenced.md"
echo 'export {};' > "${REPO}/src/index.ts"
echo 'test("x", () => {});' > "${REPO}/src/foo.test.ts"
detect_orphan_files "$REPO" "core"
assert_eq "md/index/test は orphan にならない" "0" "$(grep -c '^orphan_file' "$DEBT_LOG" || true)"
rm -f "${REPO}/NOTES-unreferenced.md" "${REPO}/src/index.ts" "${REPO}/src/foo.test.ts"

# --- Test 4: 空白入りファイル名でも安全 ---
echo -e "\n${BOLD}[4] 空白入りファイル名${NC}"
: > "$DEBT_LOG"
echo 'export const s = 1;' > "${REPO}/src/space orphan.ts"
rc=0; detect_orphan_files "$REPO" "core" || rc=$?
assert_eq "空白パスでも rc=0" "0" "$rc"
assert_eq "空白入り orphan も検出" "1" "$(grep -c 'space orphan' "$DEBT_LOG" || true)"
rm -f "${REPO}/src/space orphan.ts"

# --- Test 5: 非 git ディレクトリは skip ---
echo -e "\n${BOLD}[5] 非 git は skip${NC}"
mkdir -p "${TEST_ROOT}/not-git"
rc=0; detect_orphan_files "${TEST_ROOT}/not-git" "core" || rc=$?
assert_eq "非 git で rc=0（skip）" "0" "$rc"

# ===== クリーンアップ =====
rm -rf "$TEST_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  orphan-detector テスト結果"
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
