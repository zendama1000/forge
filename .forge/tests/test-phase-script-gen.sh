#!/bin/bash
# test-phase-script-gen.sh — generate_phase_test_scripts の生成物検証
# 検証: --work-dir パース + cd / forge-requires マーカー / 位置引数の無害消費 /
#       Assertions 注入の research-config 絶対パス化（契約 grep）
# 使い方: bash .forge/tests/test-phase-script-gen.sh

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
TEST_ROOT="/tmp/test-phase-script-gen-$$"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/.forge/state" "${TEST_ROOT}/work dir"

log() { echo "[LOG] $1" >&2; }
jq_safe() { jq "$@" | tr -d '\r'; }

# 被テスト関数を sed 抽出
EXTRACT="${TEST_ROOT}/extract.sh"
: > "$EXTRACT"
for fn in _phase_test_needs_server generate_phase_test_scripts; do
  sed -n "/^${fn}() {/,/^}/p" "${SCRIPT_DIR}/.forge/loops/generate-tasks.sh" >> "$EXTRACT"
done
if ! grep -q '^generate_phase_test_scripts() {' "$EXTRACT"; then
  echo "FATAL: 関数抽出失敗"
  echo "  PASS: 0  FAIL: 1"
  exit 1
fi
source "$EXTRACT"

# fixture task-stack: mvp=curl あり(server 要), core=pwd 記録のみ(server 不要)
TASK_STACK="${TEST_ROOT}/task-stack.json"
cat > "$TASK_STACK" << 'JSON'
{
  "phases": [
    {
      "id": "mvp",
      "goal": "g",
      "exit_criteria": [
        {"type": "auto", "kind": "walking_skeleton", "description": "api scenario", "command": "curl -sf http://localhost:3001/api/items"},
        {"type": "human_check", "description": "visual", "level": "A"}
      ]
    },
    {
      "id": "core",
      "goal": "g",
      "exit_criteria": [
        {"type": "auto", "description": "record pwd", "command": "pwd > pwd-out.txt"},
        {"type": "auto", "description": "relative file check", "command": "test -f marker.txt"}
      ]
    }
  ]
}
JSON

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: 生成 + マーカー ---
echo -e "\n${BOLD}[1] 生成 + forge-requires マーカー${NC}"
cd "$TEST_ROOT"
generate_phase_test_scripts "$TASK_STACK"
cd "$SCRIPT_DIR"
MVP="${TEST_ROOT}/.forge/state/phase-tests/mvp.sh"
CORE="${TEST_ROOT}/.forge/state/phase-tests/core.sh"
assert_eq "mvp.sh が生成される" "true" "$([ -f "$MVP" ] && echo true || echo false)"
assert_eq "core.sh が生成される" "true" "$([ -f "$CORE" ] && echo true || echo false)"
assert_eq "mvp.sh に server マーカーあり" "1" "$(grep -c '^# forge-requires: server' "$MVP" || true)"
assert_eq "core.sh に server マーカーなし" "0" "$(grep -c '^# forge-requires: server' "$CORE" || true)"
assert_eq "set -euo pipefail を使用" "1" "$(grep -c '^set -euo pipefail' "$CORE" || true)"
assert_eq "human_check は auto テストに含まれない" "0" "$(grep -c 'visual' "$MVP" || true)"

# --- Test 2: --work-dir パース + cd（相対パスが WORK_DIR 基準で解決） ---
echo -e "\n${BOLD}[2] --work-dir パース + cd${NC}"
WD="${TEST_ROOT}/work dir"
touch "${WD}/marker.txt"
rc=0
bash "$CORE" "core" --keep-server --work-dir "$WD" >/dev/null 2>&1 || rc=$?
assert_eq "位置引数+--keep-server+--work-dir で実行成功" "0" "$rc"
assert_eq "pwd-out.txt が WORK_DIR に生成される（cd 効果）" "true" "$([ -f "${WD}/pwd-out.txt" ] && echo true || echo false)"
recorded=$(cat "${WD}/pwd-out.txt" 2>/dev/null | tr -d '\r')
case "$recorded" in
  *"work dir") assert_eq "記録 pwd が WORK_DIR（空白パス対応）" "ok" "ok" ;;
  *) assert_eq "記録 pwd が WORK_DIR（空白パス対応）" "*/work dir" "$recorded" ;;
esac

# --- Test 3: --work-dir=VALUE 形式 ---
echo -e "\n${BOLD}[3] --work-dir=VALUE 形式${NC}"
rm -f "${WD}/pwd-out.txt"
rc=0
bash "$CORE" --work-dir="$WD" >/dev/null 2>&1 || rc=$?
assert_eq "--work-dir= 形式でも成功" "0" "$rc"
assert_eq "pwd-out.txt 生成" "true" "$([ -f "${WD}/pwd-out.txt" ] && echo true || echo false)"

# --- Test 4: 引数なし（後方互換 — カレントで実行） ---
echo -e "\n${BOLD}[4] 引数なし後方互換${NC}"
rc=0
(cd "$WD" && bash "$CORE") >/dev/null 2>&1 || rc=$?
assert_eq "引数なし + cwd=WORK_DIR で成功" "0" "$rc"

# --- Test 5: 失敗する criterion で exit 1 ---
echo -e "\n${BOLD}[5] criterion 失敗で exit 1${NC}"
rm -f "${WD}/marker.txt"
rc=0
bash "$CORE" --work-dir "$WD" >/dev/null 2>&1 || rc=$?
assert_eq "marker.txt 不在で exit 1" "1" "$rc"

# --- Test 6: Assertions 注入の絶対パス契約（generate-tasks.sh 本体の grep） ---
echo -e "\n${BOLD}[6] Assertions 注入の絶対パス契約${NC}"
assert_eq "research-config を PROJECT_ROOT 絶対パスで参照" "1" \
  "$(grep -c 'validate_locked_assertions "\${PROJECT_ROOT}/.forge/state/research-config.json"' "${SCRIPT_DIR}/.forge/loops/generate-tasks.sh" || true)"

# ===== クリーンアップ =====
rm -rf "$TEST_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  phase-script-gen テスト結果"
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
