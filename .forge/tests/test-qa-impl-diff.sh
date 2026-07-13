#!/bin/bash
# test-qa-impl-diff.sh — qa_collect_impl_diff（QA へ渡す実装 diff 収集）
# 検証: intent-to-add で未追跡ファイル可視化 / lockfile 除外 / 2000 行キャップ /
#       HEAD~1 なし repo / 非 git ディレクトリ
# 使い方: bash .forge/tests/test-qa-impl-diff.sh

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
TEST_ROOT="/tmp/test-qa-impl-diff-$$"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/repo" "${TEST_ROOT}/not-git" "${TEST_ROOT}/fresh"

log() { echo "[LOG] $1" >&2; }

EXTRACT="${TEST_ROOT}/extract.sh"
sed -n '/^qa_collect_impl_diff() {/,/^}/p' "${SCRIPT_DIR}/.forge/lib/qa-evaluator.sh" > "$EXTRACT"
if ! grep -q '^qa_collect_impl_diff() {' "$EXTRACT"; then
  echo "FATAL: 関数抽出失敗"
  echo "  PASS: 0  FAIL: 1"
  exit 1
fi
source "$EXTRACT"

REPO="${TEST_ROOT}/repo"
git -C "$REPO" init -q
git -C "$REPO" config user.email "t@t" && git -C "$REPO" config user.name "t"
echo "base" > "${REPO}/base.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "Initial commit"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: 未追跡ファイルが diff に可視化される（intent-to-add） ---
echo -e "\n${BOLD}[1] intent-to-add で未追跡ファイル可視化${NC}"
echo 'export const core = 1;' > "${REPO}/core-impl.ts"
diff_out=$(qa_collect_impl_diff "$REPO")
assert_eq "未追跡ファイルが diff に含まれる" "true" "$([[ "$diff_out" == *"core-impl.ts"* ]] && echo true || echo false)"
assert_eq "内容行も含まれる" "true" "$([[ "$diff_out" == *"export const core"* ]] && echo true || echo false)"

# --- Test 2: lockfile 除外 ---
echo -e "\n${BOLD}[2] lockfile 除外${NC}"
printf 'LOCKLINE %d\n' $(seq 1 100) > "${REPO}/package-lock.json"
printf 'YARNLOCK %d\n' $(seq 1 50) > "${REPO}/yarn.lock"
diff_out=$(qa_collect_impl_diff "$REPO")
assert_eq "package-lock.json が除外される" "false" "$([[ "$diff_out" == *"LOCKLINE"* ]] && echo true || echo false)"
assert_eq "*.lock が除外される" "false" "$([[ "$diff_out" == *"YARNLOCK"* ]] && echo true || echo false)"
assert_eq "本質ファイルは残る" "true" "$([[ "$diff_out" == *"core-impl.ts"* ]] && echo true || echo false)"

# --- Test 3: 2000 行キャップ ---
echo -e "\n${BOLD}[3] 2000 行キャップ${NC}"
printf 'line %d\n' $(seq 1 3000) > "${REPO}/big-file.txt"
diff_out=$(qa_collect_impl_diff "$REPO")
line_count=$(printf '%s\n' "$diff_out" | wc -l | tr -d ' ')
assert_eq "diff が 2000 行以下にキャップされる" "true" "$([ "$line_count" -le 2000 ] && echo true || echo false)"
assert_eq "500 行キャップ（旧値）より大きい" "true" "$([ "$line_count" -gt 500 ] && echo true || echo false)"

# --- Test 4: コミット1つの repo（HEAD~1 なし）でも動作 ---
echo -e "\n${BOLD}[4] HEAD~1 なし repo${NC}"
FRESH="${TEST_ROOT}/fresh"
git -C "$FRESH" init -q
git -C "$FRESH" config user.email "t@t" && git -C "$FRESH" config user.name "t"
echo 'new file content xyz' > "${FRESH}/only-file.ts"
diff_out=$(qa_collect_impl_diff "$FRESH")
assert_eq "コミットゼロ repo でも diff 取得" "true" "$([[ "$diff_out" == *"only-file.ts"* ]] && echo true || echo false)"

# --- Test 5: 非 git → フォールバック文字列 ---
echo -e "\n${BOLD}[5] 非 git ディレクトリ${NC}"
diff_out=$(qa_collect_impl_diff "${TEST_ROOT}/not-git")
assert_eq "非 git はフォールバック文字列" "（diff 取得不可）" "$diff_out"
diff_out=$(qa_collect_impl_diff "")
assert_eq "空 work_dir もフォールバック" "（diff 取得不可）" "$diff_out"

# ===== クリーンアップ =====
rm -rf "$TEST_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  qa-impl-diff テスト結果"
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
