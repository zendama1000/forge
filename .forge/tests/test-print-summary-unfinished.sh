#!/bin/bash
# test-print-summary-unfinished.sh — print_summary() 機械可読 未完タスク警告のテスト
#
# 検証内容:
#   - '[WARN] UNFINISHED_TASKS=N pending=X in_progress=Y blocked_criteria=Z blocked_investigation=W failed=V'
#     形式の機械可読プレフィックスが stderr に1行出力される（合計>0 のとき）
#   - 全タスク完了時は機械可読警告行が一切出力されない（silent on success）
#   - 2桁以上の N も正しくフォーマットされる
#   - print_summary() の新規追加ブロックに raw `jq ` 直接呼出が含まれない
#   - print_summary() の新規追加ブロックに jq_safe / jq_lines が最低1回含まれる
#   - CRLF を含む fixture でも数値比較が正しく機能する（jq_safe 経由）
#
# スタイル: extract_all_functions_awk + source + 2>&1 stderr キャプチャ + assert_contains
# 使い方: bash .forge/tests/test-print-summary-unfinished.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-print-summary-unfinished.sh — 機械可読 未完タスク警告 =====${NC}"
echo ""

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

# ===== テスト環境セットアップ =====
TMP_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/test-print-summary-$$")"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# ===== common.sh を source（jq_safe / log() 等を解決） =====
# common.sh は PROJECT_ROOT 等を前提とする関数を含むが、
# print_summary() が必要とするのは jq_safe と log() のみ。
PROJECT_ROOT="$REAL_ROOT"
ERRORS_FILE="${TMP_DIR}/errors.jsonl"
RESEARCH_DIR="test-print-summary"
json_fail_count=0
touch "$ERRORS_FILE"

source "${REAL_ROOT}/.forge/lib/common.sh"

# ===== print_summary が参照するセッション変数 =====
TASK_STACK=""
START_SECONDS=$SECONDS
task_count=0
investigation_count=0
approach_scope_count=0
CALIBRATION_FILE=""

# print_summary が呼ぶが本テストでは無視するスタブ
compute_divergence_rate() { echo "0%"; }
count_tasks_by_status() {
  local status="$1"
  jq --arg s "$status" '[.tasks[] | select(.status == $s)] | length' "$TASK_STACK"
}

# ===== 関数抽出（print_summary のみ） =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
EXTRACT_FILE=$(mktemp)
trap 'rm -f "$EXTRACT_FILE"; rm -rf "$TMP_DIR"' EXIT INT TERM

extract_all_functions_awk "$RALPH_SH" print_summary > "$EXTRACT_FILE"

# 抽出に成功したか軽く確認
if ! grep -q '^print_summary()' "$EXTRACT_FILE"; then
  echo -e "  ${RED}✗${NC} print_summary 関数を抽出できませんでした"
  exit 1
fi
source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} print_summary 関数抽出完了"
echo ""

# ===== ヘルパー: fixture 指定で print_summary を呼び stderr を返す =====
run_summary() {
  local fixture="$1"
  TASK_STACK="$fixture"
  # log() は stderr に書き出すため stderr を捕捉する
  print_summary 2>&1 >/dev/null
}

# ===== 新規追加ブロック抽出（BEGIN/END マーカ間） =====
NEW_BLOCK="$(awk '
  /機械可読 未完タスク警告.*BEGIN/ { in_block = 1 }
  in_block { print }
  /機械可読 未完タスク警告 END/    { in_block = 0 }
' "$RALPH_SH")"

# ========================================================================
# Group 1: 機械可読プレフィックス基本検証 (-t machine_readable_prefix)
# ========================================================================
echo -e "${BOLD}--- Group 1: machine_readable_prefix ---${NC}"

# behavior: fixture task-stack-mixed-unfinished.json (pending=2, failed=1, 計3) を source 実行 → stderr に '[WARN] UNFINISHED_TASKS=3' を正確に含む行が grep で抽出可能
out_mixed=$(run_summary "${FIXTURES_DIR}/task-stack-mixed-unfinished.json")
warn_line=$(echo "$out_mixed" | grep -E '\[WARN\] UNFINISHED_TASKS=' | head -1)
assert_contains "mixed fixture → '[WARN] UNFINISHED_TASKS=3' 含有" "[WARN] UNFINISHED_TASKS=3" "$warn_line"

# behavior: 同 fixture 実行 → 'pending=2' 'failed=1' 'in_progress=0' 'blocked_criteria=0' 'blocked_investigation=0' の5つの key=value ペアが全て1行内に含まれる
assert_contains "mixed fixture → pending=2 含有"               "pending=2"               "$warn_line"
assert_contains "mixed fixture → failed=1 含有"                "failed=1"                "$warn_line"
assert_contains "mixed fixture → in_progress=0 含有"           "in_progress=0"           "$warn_line"
assert_contains "mixed fixture → blocked_criteria=0 含有"      "blocked_criteria=0"      "$warn_line"
assert_contains "mixed fixture → blocked_investigation=0 含有" "blocked_investigation=0" "$warn_line"

echo ""

# ========================================================================
# Group 2: 正常時は警告行を出力しない (silent on success)
# ========================================================================
echo -e "${BOLD}--- Group 2: silent_on_success ---${NC}"

# behavior: fixture task-stack-all-done.json 実行 → '[WARN] UNFINISHED_TASKS=' で始まる行が一切出力されない（正常時は機械可読行も非表示）
out_done=$(run_summary "${FIXTURES_DIR}/task-stack-all-done.json")
assert_not_contains "all-done fixture → '[WARN] UNFINISHED_TASKS=' 行は非出力" "[WARN] UNFINISHED_TASKS=" "$out_done"

echo ""

# ========================================================================
# Group 3: 2桁以上の N も正しくフォーマットされる（エッジケース）
# ========================================================================
echo -e "${BOLD}--- Group 3: large_n_formatting ---${NC}"

# behavior: fixture task-stack-large.json (pending=15, in_progress=3, 合計18) 実行 → '[WARN] UNFINISHED_TASKS=18' が出力され、grep '\[WARN\] UNFINISHED_TASKS=[1-9]' で検出可能（2桁以上の N も正しくフォーマットされる、エッジケース）
out_large=$(run_summary "${FIXTURES_DIR}/task-stack-large.json")
warn_large=$(echo "$out_large" | grep -E '\[WARN\] UNFINISHED_TASKS=[1-9]' | head -1)
assert_contains "large fixture → '[WARN] UNFINISHED_TASKS=18' 含有" "[WARN] UNFINISHED_TASKS=18" "$warn_large"
assert_contains "large fixture → pending=15 含有"     "pending=15"     "$warn_large"
assert_contains "large fixture → in_progress=3 含有"  "in_progress=3"  "$warn_large"

# 2桁以上検出パターンの確認
match_count=$(echo "$out_large" | grep -cE '\[WARN\] UNFINISHED_TASKS=[1-9]' || true)
assert_eq "large fixture → 2桁以上 grep パターンマッチ件数=1" "1" "$match_count"

echo ""

# ========================================================================
# Group 4: jq_safe 使用検証 (-t jq_safe_usage)
# ========================================================================
echo -e "${BOLD}--- Group 4: jq_safe_usage ---${NC}"

# behavior: 新規追加されたコードブロック (print_summary 内の警告ブロック部分) を grep '^[[:space:]]*jq ' で検索 → マッチ件数0（raw jq の直接呼出が含まれない、検出すべきでないパターン）
raw_jq_count=$(echo "$NEW_BLOCK" | grep -cE '^[[:space:]]*jq ' || true)
assert_eq "新規ブロック内に raw 'jq ' 呼出 0件" "0" "$raw_jq_count"

# behavior: 新規追加されたコードブロックに 'jq_safe' または 'jq_lines' のいずれかの呼出が最低1回含まれる（検出すべきパターン）
jq_helper_count=$(echo "$NEW_BLOCK" | grep -cE 'jq_safe|jq_lines' || true)
if [ "$jq_helper_count" -ge 1 ]; then
  assert_eq "新規ブロックに jq_safe/jq_lines 最低1回含有" "ok" "ok"
else
  assert_eq "新規ブロックに jq_safe/jq_lines 最低1回含有" "ok" "missing(count=${jq_helper_count})"
fi

# 念のため: 抽出した NEW_BLOCK が空でないこと（マーカ漏れ検出）
if [ -z "$NEW_BLOCK" ]; then
  assert_eq "新規ブロック抽出 (BEGIN/END マーカ)" "non-empty" "empty"
else
  assert_eq "新規ブロック抽出 (BEGIN/END マーカ)" "non-empty" "non-empty"
fi

echo ""

# ========================================================================
# Group 5: CRLF fixture でも数値比較が正しく機能する（エッジケース）
# ========================================================================
echo -e "${BOLD}--- Group 5: crlf_safety ---${NC}"

# behavior: 新規追加部の jq クエリ末尾に '\r' を含む CRLF 出力をシミュレート（fixture を CRLF で保存）→ jq_safe 経由で読んだ値が数値比較 [ "$count" -gt 0 ] で正しく true/false 判定される（既存 jq_safe が tr -d '\r' を含むため、エッジケース）
CRLF_FIXTURE="${TMP_DIR}/task-stack-mixed-crlf.json"
# 既存 fixture を CRLF に変換して保存
sed 's/$/\r/' "${FIXTURES_DIR}/task-stack-mixed-unfinished.json" > "$CRLF_FIXTURE"

# CRLF 保存が反映されたか軽く確認
crlf_bytes=$(tr -cd '\r' < "$CRLF_FIXTURE" | wc -c | tr -d ' ')
if [ "$crlf_bytes" -gt 0 ]; then
  assert_eq "CRLF fixture 生成: '\\r' バイト含有" "yes" "yes"
else
  assert_eq "CRLF fixture 生成: '\\r' バイト含有" "yes" "no(bytes=${crlf_bytes})"
fi

# CRLF 入力でも警告行が正しく1行出力され、数値比較 [ -gt 0 ] が true 判定されたこと
out_crlf=$(run_summary "$CRLF_FIXTURE")
warn_crlf=$(echo "$out_crlf" | grep -E '\[WARN\] UNFINISHED_TASKS=' | head -1)
assert_contains "CRLF fixture → '[WARN] UNFINISHED_TASKS=3' 含有" "[WARN] UNFINISHED_TASKS=3" "$warn_crlf"
assert_contains "CRLF fixture → pending=2 含有"  "pending=2"  "$warn_crlf"
assert_contains "CRLF fixture → failed=1 含有"   "failed=1"   "$warn_crlf"

echo ""

# ===== サマリー =====
print_test_summary
exit $?
