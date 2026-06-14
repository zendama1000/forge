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

# ===== コマンド文字列 assert =====
# 構築されたコマンドライン文字列に対する包含/非包含検証。
# assert_contains の意味的エイリアスだが、用途（コマンド構築検証）を明示するため別名で提供する。
# grep -F -- でリテラル一致（--effort 等のハイフン始まり needle を安全に扱う）。
assert_cmd_contains() {
  local label="$1" needle="$2" cmd_str="$3"
  if echo "$cmd_str" | grep -qF -- "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected cmd to contain: ${needle}"
    echo -e "    actual cmd: ${cmd_str:0:200}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_cmd_not_contains() {
  local label="$1" needle="$2" cmd_str="$3"
  if echo "$cmd_str" | grep -qF -- "$needle"; then
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected cmd NOT to contain: ${needle}"
    echo -e "    actual cmd: ${cmd_str:0:200}"
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

# ===== opt-in ERR trap ヘルパー =====
# 使い方: source 後に enable_err_trap を明示的に呼んだテストのみ有効化される（opt-in）。
# source しただけでは trap は一切設置されない（既存テストの挙動不変）。
# negative test 区間（意図的な失敗コマンド）は disable_err_trap / enable_err_trap で囲む。

# 内部ハンドラ: 失敗コマンドのファイル名と行番号を stderr に出力する
_forge_err_trap_handler() {
  local rc="$1" src="$2" line="$3"
  echo "[ERR-TRAP] command failed (exit=${rc}) at ${src}:${line}" >&2
}

# ERR trap を有効化（errtrace で関数/サブシェルにも継承）
enable_err_trap() {
  set -o errtrace
  trap '_forge_err_trap_handler "$?" "${BASH_SOURCE[0]}" "${LINENO}"' ERR
}

# ERR trap を無効化（negative test 区間用）
disable_err_trap() {
  trap - ERR
  set +o errtrace
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

# ===== 自己テスト（直接実行時のみ。source 時は実行されない） =====
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo -e "${BOLD}test-helpers.sh self-test${NC}"

  HELPERS_PATH="$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"
  SELFTEST_TMP="$(mktemp -d)"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT

  # --- 既存 assert 関数の基本動作確認 ---
  # behavior: [追加] assert_eq / assert_contains が PASS_COUNT を正しく加算する
  out="$(echo "hello world")"
  assert_eq "assert_eq: 同一文字列で PASS する" "hello world" "$out"
  assert_contains "assert_contains: 部分文字列を検出する" "world" "$out"
  assert_not_contains "assert_not_contains: 非含有を検出する" "xyz" "$out"
  assert_cmd_contains "assert_cmd_contains: ハイフン始まり needle を扱える" "--effort high" "claude -p --effort high"
  assert_cmd_not_contains "assert_cmd_not_contains: 非含有コマンド断片を検出する" "--dangerous" "claude -p --effort high"

  # --- ERR trap: 発火テスト ---
  # behavior: ERR trap ヘルパーを有効化したテストで意図的にコマンド失敗 → 失敗ファイル名と行番号が stderr に出力される
  script1="$SELFTEST_TMP/errtrap-fire.sh"
  cat > "$script1" <<EOF
#!/bin/bash
source "$HELPERS_PATH"
enable_err_trap
false
echo done
EOF
  stderr1="$(bash "$script1" 2>&1 >/dev/null)"
  stdout1="$(bash "$script1" 2>/dev/null)"
  assert_contains "ERR trap 発火: ファイル名が stderr に出力される" "errtrap-fire.sh" "$stderr1"
  assert_contains "ERR trap 発火: 行番号(4)が stderr に出力される" "errtrap-fire.sh:4" "$stderr1"
  assert_contains "ERR trap 発火: exit code が報告される" "exit=1" "$stderr1"
  assert_eq "ERR trap 発火: スクリプト自体は続行する（done 出力）" "done" "$stdout1"

  # --- ERR trap: disable/enable で囲んだ negative test 区間 ---
  # behavior: disable_err_trap/enable_err_trap で囲んだ negative test 区間で失敗コマンド実行 → trap が発火せずテスト続行
  script2="$SELFTEST_TMP/errtrap-negative.sh"
  cat > "$script2" <<EOF
#!/bin/bash
source "$HELPERS_PATH"
enable_err_trap
disable_err_trap
false
enable_err_trap
echo survived
exit 0
EOF
  stderr2="$(bash "$script2" 2>&1 >/dev/null)"
  stdout2="$(bash "$script2" 2>/dev/null)"
  rc2=0; bash "$script2" >/dev/null 2>&1 || rc2=$?
  assert_not_contains "negative 区間: trap が発火しない（stderr 空）" "ERR-TRAP" "$stderr2"
  assert_contains "negative 区間: テストが続行する（survived 出力）" "survived" "$stdout2"
  assert_eq "negative 区間: exit code 0 で終了する" "0" "$rc2"

  # --- ERR trap: opt-in（source のみではグローバル trap 非設置） ---
  # behavior: ERR trap ヘルパーを source しない既存テスト → 挙動不変（opt-in であること、グローバル trap 非設置）
  trap_after_source="$(bash -c "source \"$HELPERS_PATH\"; trap -p ERR")"
  assert_eq "opt-in: source 直後は ERR trap 未設置（trap -p ERR が空）" "" "$trap_after_source"
  errtrace_after_source="$(bash -c "source \"$HELPERS_PATH\"; set -o | grep errtrace")"
  assert_contains "opt-in: source 直後は errtrace オフ" "off" "$errtrace_after_source"
  plain_fail="$(bash -c "source \"$HELPERS_PATH\"; false; echo unchanged" 2>&1)"
  assert_eq "opt-in: enable しない限り失敗コマンドでも出力は不変" "unchanged" "$plain_fail"

  # --- ERR trap: サブシェル/関数への errtrace 継承 ---
  # behavior: サブシェル内の失敗（errtrace 継承） → trap が発火し行番号を報告
  script3="$SELFTEST_TMP/errtrap-subshell.sh"
  cat > "$script3" <<EOF
#!/bin/bash
source "$HELPERS_PATH"
enable_err_trap
( false )
echo done
EOF
  stderr3="$(bash "$script3" 2>&1 >/dev/null)"
  assert_contains "errtrace 継承: サブシェル内の失敗で trap 発火 + 行番号(4)報告" "errtrap-subshell.sh:4" "$stderr3"

  script4="$SELFTEST_TMP/errtrap-func.sh"
  cat > "$script4" <<EOF
#!/bin/bash
source "$HELPERS_PATH"
enable_err_trap
my_func() { false; }
my_func
echo done
EOF
  stderr4="$(bash "$script4" 2>&1 >/dev/null)"
  assert_contains "errtrace 継承: 関数内の失敗で trap 発火 + 行番号(4)報告" "errtrap-func.sh:4" "$stderr4"

  # --- エッジケース: exit code 2 の失敗 ---
  # behavior: [追加] exit code 1 以外の失敗でも実際の exit code が報告される
  script5="$SELFTEST_TMP/errtrap-exit2.sh"
  cat > "$script5" <<EOF
#!/bin/bash
source "$HELPERS_PATH"
enable_err_trap
fail2() { return 2; }
fail2
echo done
EOF
  stderr5="$(bash "$script5" 2>&1 >/dev/null)"
  assert_contains "エッジケース: exit=2 が正しく報告される" "exit=2" "$stderr5"

  print_test_summary
  exit $?
fi
