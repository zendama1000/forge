#!/bin/bash
# test-helpers.sh — 共通テストライブラリ
# 新規テストファイルが source する。既存テストは変更しない。
# 使い方: source "$(dirname "$0")/test-helpers.sh"

# ===== カラー定数 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ===== テスト集計（未設定時のみ初期化） =====
: "${PASS_COUNT:=0}"
: "${FAIL_COUNT:=0}"

# ===== assert 関数 =====

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
  if echo "$haystack" | grep -qF "$needle"; then
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
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
    echo -e "    actual: ${haystack:0:200}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ===== awk ベース高速一括関数抽出（MSYS 対応） =====
# extract_all_functions_awk <src_file> <func1> <func2> ...
# stdout に抽出した関数定義を出力する。
extract_all_functions_awk() {
  local src="$1"
  shift
  local funcs="$*"
  awk -v "names=$funcs" '
    BEGIN {
      split(names, arr, " ")
      for (i in arr) targets[arr[i] "()"] = 1
    }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ {
      fname = $1
      if (fname in targets) {
        found = 1
        depth = 0
      }
    }
    found {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      print
      if (depth <= 0 && NR > start_line) {
        found = 0
        print ""
      }
      if (found && depth > 0) start_line = NR
    }
  ' "$src"
}

# ===== テストサマリー表示 =====
# 集計結果を表示し、FAIL_COUNT を exit code として返す。
print_test_summary() {
  echo ""
  echo -e "${BOLD}=========================================="
  local total=$((PASS_COUNT + FAIL_COUNT))
  if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${total}${NC}"
  else
    echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${total}${NC}"
  fi
  echo -e "==========================================${NC}"
  return "$FAIL_COUNT"
}
