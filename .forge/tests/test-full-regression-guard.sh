#!/bin/bash
# test-full-regression-guard.sh — verify-full-regression タスクの必須振る舞いガード
#
# 全体回帰検証タスク(verify-full-regression)の2つの必須振る舞いを、フルスイートを
# 再帰実行せずに高速・決定的に検証する:
#
#   behavior 1: run-all-tests.sh 経由でも両テストの assert 数が 1 以上として集計される
#               （test-l2-wiring.sh / test-print-summary-unfinished.sh の合格マーカーを
#                 run-all-tests.sh の parse_assert_total が >=1 の数値として抽出すること）
#
#   behavior 2: grep が common.sh を binary file と判定しない
#               → grep -c 'jq_lines' .forge/lib/common.sh が数値を返す（'Binary file matches' でない）
#
# 設計: parse_assert_total は run-all-tests.sh 内に定義された純関数。test-plan-gate.sh 等と
#       同様に sed で関数定義のみを抽出して source し、決定的なマーカー文字列で検証する。
#       run-all-tests.sh 全体を source するとランナー本体が走るため、関数のみを切り出す。
#
# 使い方: bash .forge/tests/test-full-regression-guard.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_ALL="${SCRIPT_DIR}/run-all-tests.sh"
COMMON_SH="${PROJECT_ROOT}/.forge/lib/common.sh"
L2_WIRING="${SCRIPT_DIR}/test-l2-wiring.sh"
PRINT_SUMMARY="${SCRIPT_DIR}/test-print-summary-unfinished.sh"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-full-regression-guard.sh — 必須振る舞いガード =====${NC}"
echo ""

# ===== parse_assert_total を run-all-tests.sh から抽出して source =====
PARSE_FN_FILE="$(mktemp)"
trap 'rm -f "$PARSE_FN_FILE"' EXIT
sed -n '/^parse_assert_total() {/,/^}/p' "$RUN_ALL" > "$PARSE_FN_FILE"
if grep -q '^parse_assert_total() {' "$PARSE_FN_FILE"; then
  echo -e "  ${GREEN}✓${NC} parse_assert_total を run-all-tests.sh から抽出"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} parse_assert_total の抽出に失敗 — 以降検証不能"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  print_test_summary
  exit "$FAIL_COUNT"
fi
# shellcheck disable=SC1090
source "$PARSE_FN_FILE"

# ========================================================================
# behavior 1: run-all-tests.sh 経由でも両テストの assert 数が 1 以上として集計される
# ========================================================================
echo ""
echo -e "${BOLD}--- behavior 1: 両テストの assert 集計 >= 1 ---${NC}"

# 両テストは print_test_summary を呼び、合格時は "ALL PASSED: N/M" マーカーを出力する。
# run-all-tests.sh の parse_assert_total はこのマーカー（形式A）から総数 M を抽出する。

# behavior: run-all-tests.sh 経由でも両テストの assert 数が 1 以上として集計される
l2_total="$(parse_assert_total "ALL PASSED: 18/18")"
assert_eq "test-l2-wiring 合格マーカー → assert 総数 18 を抽出 (>=1)" "18" "$l2_total"

# behavior: run-all-tests.sh 経由でも両テストの assert 数が 1 以上として集計される
ps_total="$(parse_assert_total "ALL PASSED: 40/40")"
assert_eq "test-print-summary 合格マーカー → assert 総数 40 を抽出 (>=1)" "40" "$ps_total"

# behavior: run-all-tests.sh 経由でも両テストの assert 数が 1 以上として集計される（境界値: 1件）
one_total="$(parse_assert_total "ALL PASSED: 1/1")"
assert_eq "境界値: assert 1件でも 1 を抽出 (>=1)" "1" "$one_total"

# behavior: [追加] 完了マーカー欠落（サイレント死）は 'none' として検出され誤集計されない（エッジケース）
none_total="$(parse_assert_total "silent-death-sample: setting up...")"
assert_eq "エッジ: 完了マーカー欠落 → 'none'（サイレント死検出・誤集計しない）" "none" "$none_total"

# 構造保証: 両テストが完了マーカーを出す print_test_summary を実際に呼んでいる
if grep -q 'print_test_summary' "$L2_WIRING"; then
  echo -e "  ${GREEN}✓${NC} test-l2-wiring.sh は print_test_summary を呼ぶ（完了マーカー出力保証）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} test-l2-wiring.sh が print_test_summary を呼んでいない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
if grep -q 'print_test_summary' "$PRINT_SUMMARY"; then
  echo -e "  ${GREEN}✓${NC} test-print-summary-unfinished.sh は print_test_summary を呼ぶ"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} test-print-summary-unfinished.sh が print_test_summary を呼んでいない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 配線保証: 両テストが run-all-tests.sh の実行対象（TEST_SUITES）に登録済み
if grep -q 'test-l2-wiring.sh' "$RUN_ALL"; then
  echo -e "  ${GREEN}✓${NC} test-l2-wiring.sh は run-all-tests.sh に登録済み"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} test-l2-wiring.sh が run-all-tests.sh に未登録"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
if grep -q 'test-print-summary-unfinished.sh' "$RUN_ALL"; then
  echo -e "  ${GREEN}✓${NC} test-print-summary-unfinished.sh は run-all-tests.sh に登録済み"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} test-print-summary-unfinished.sh が run-all-tests.sh に未登録"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ========================================================================
# behavior 2: grep が common.sh を binary file と判定しない
# ========================================================================
echo ""
echo -e "${BOLD}--- behavior 2: grep が common.sh を binary 判定しない ---${NC}"

# behavior: grep が common.sh を binary file と判定しない → grep -c 'jq_lines' .forge/lib/common.sh が数値を返す（'Binary file matches' でない）
grep_out="$(grep -c 'jq_lines' "$COMMON_SH" 2>/dev/null || true)"
if printf '%s' "$grep_out" | grep -qE '^[0-9]+$'; then
  echo -e "  ${GREEN}✓${NC} grep -c 'jq_lines' common.sh が純粋な数値を返す (=${grep_out})"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} grep -c 'jq_lines' common.sh が数値以外を返した: '${grep_out}'"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# behavior: grep が common.sh を binary file と判定しない → grep -c 'jq_lines' .forge/lib/common.sh が数値を返す（'Binary file matches' でない）
assert_not_contains "grep 出力に 'Binary file matches' を含まない" "Binary file matches" "$grep_out"

# jq_lines は common.sh に最低1回定義/使用されている（数値 >=1）
if [ "$grep_out" -ge 1 ] 2>/dev/null; then
  echo -e "  ${GREEN}✓${NC} jq_lines は common.sh に >=1 行で出現 (=${grep_out})"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} jq_lines が common.sh に出現しない (=${grep_out})"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# binary 判定の根本原因（NUL バイト混入）が common.sh に無いこと
nul_hit="$(grep -lP '\x00' "$COMMON_SH" 2>/dev/null || true)"
assert_eq "common.sh に NUL バイト 0件（binary 判定の根本原因なし）" "" "$nul_hit"

print_test_summary
exit $?
