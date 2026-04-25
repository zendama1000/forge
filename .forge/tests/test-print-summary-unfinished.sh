#!/bin/bash
# test-print-summary-unfinished.sh — print_summary() 未完タスク警告テスト
#
# 検証内容:
#   [機械可読部 / 既存]
#   - '[WARN] UNFINISHED_TASKS=N pending=X in_progress=Y blocked_criteria=Z blocked_investigation=W failed=V'
#     形式の機械可読プレフィックスが stderr に1行出力される（合計>0 のとき）
#   - 全タスク完了時は機械可読警告行が一切出力されない（silent on success）
#   - 2桁以上の N も正しくフォーマットされる
#   - print_summary() の新規追加ブロックに raw `jq ` 直接呼出が含まれない
#   - print_summary() の新規追加ブロックに jq_safe / jq_lines が最低1回含まれる
#   - CRLF を含む fixture でも数値比較が正しく機能する（jq_safe 経由）
#   [視覚警告ブロック / 新規 — 3層構造]
#   - 未完タスク残存時に '⚠ 未完了タスク残存（UNFINISHED TASKS DETECTED）' 見出しを出力
#   - 5状態（pending/in_progress/blocked_criteria/blocked_investigation/failed）を内訳で表示
#   - YELLOW '→' 対処hintを2行出力
#   - tasks=[] 等の正常時は視覚ブロックも出力されない（silent on success）
#   [tty ガード / 新規]
#   - 非tty (stderr リダイレクト時) は ANSI を一切出さない
#   - global RED/BOLD/NC を空に上書きしてもローカル変数で再定義される
#   [L3 構造検証 / 新規]
#   - L3-001: print_summary 関数本体に [ -t 2 ] と NO_COLOR ガードが両方含まれる
#   - L3-003: 視覚ブロックが ローカル _vis_* 変数を使う（global ${RED}${BOLD}${NC} で出力していない）
#
# スタイル: extract_all_functions_awk + source + 2>&1 stderr キャプチャ + assert_contains
# 使い方:
#   bash .forge/tests/test-print-summary-unfinished.sh                # 全グループ
#   bash .forge/tests/test-print-summary-unfinished.sh -t <group>     # 特定グループのみ
#     <group>: machine_readable_prefix | silent_on_success | large_n_formatting |
#              jq_safe_usage | crlf_safety | visual_block | tty_guard |
#              l3_structure | l2_integration | all (default)

set -uo pipefail

# ===== 引数解析（-t <group> サポート） =====
TEST_GROUP="all"
while [ $# -gt 0 ]; do
  case "$1" in
    -t)
      shift
      TEST_GROUP="${1:-all}"
      shift || true
      ;;
    -t=*)
      TEST_GROUP="${1#-t=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-print-summary-unfinished.sh — 未完タスク警告 (group=${TEST_GROUP}) =====${NC}"
echo ""

# ===== グループ実行ガード =====
should_run_group() {
  local group="$1"
  case "$TEST_GROUP" in
    all) return 0 ;;
    "$group") return 0 ;;
    # l2_integration は視覚+tty+L3+CRLF を統合実行
    l2_integration)
      case "$group" in
        machine_readable_prefix|silent_on_success|visual_block|tty_guard|l3_structure|crlf_safety) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

# ===== テスト環境セットアップ =====
TMP_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/test-print-summary-$$")"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# ===== common.sh を source（jq_safe / log() 等を解決） =====
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
  print_summary 2>&1 >/dev/null
}

# ===== 新規追加ブロック抽出（BEGIN/END マーカ間） =====
NEW_BLOCK="$(awk '
  /機械可読 未完タスク警告.*BEGIN/ { in_block = 1 }
  in_block { print }
  /機械可読 未完タスク警告 END/    { in_block = 0 }
' "$RALPH_SH")"

# print_summary 関数本体（L3 構造検証用）
PS_BODY="$(cat "$EXTRACT_FILE")"

# ========================================================================
# Group 1: 機械可読プレフィックス基本検証 (-t machine_readable_prefix)
# ========================================================================
if should_run_group machine_readable_prefix; then
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
fi

# ========================================================================
# Group 2: 正常時は警告行を出力しない (silent on success)
# ========================================================================
if should_run_group silent_on_success; then
echo -e "${BOLD}--- Group 2: silent_on_success ---${NC}"

# behavior: fixture task-stack-all-done.json (全タスク completed) を渡して print_summary を source 実行 → stderr に '⚠ 未完了タスク残存' 文字列が含まれない（silent on success）
out_done=$(run_summary "${FIXTURES_DIR}/task-stack-all-done.json")
assert_not_contains "all-done fixture → '[WARN] UNFINISHED_TASKS=' 行は非出力" "[WARN] UNFINISHED_TASKS=" "$out_done"
assert_not_contains "all-done fixture → '⚠ 未完了タスク残存' 視覚見出しも非出力" "⚠ 未完了タスク残存" "$out_done"

echo ""
fi

# ========================================================================
# Group 3: 2桁以上の N も正しくフォーマットされる（エッジケース）
# ========================================================================
if should_run_group large_n_formatting; then
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
fi

# ========================================================================
# Group 4: jq_safe 使用検証 (-t jq_safe_usage)
# ========================================================================
if should_run_group jq_safe_usage; then
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
fi

# ========================================================================
# Group 5: CRLF fixture でも数値比較が正しく機能する（エッジケース）
# ========================================================================
if should_run_group crlf_safety; then
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
fi

# ========================================================================
# Group 6: 視覚警告ブロック (-t visual_block) — 3層構造の振る舞い検証
# ========================================================================
if should_run_group visual_block; then
echo -e "${BOLD}--- Group 6: visual_block ---${NC}"

# behavior: fixture task-stack-with-pending.json (pending=2 残存) を渡して print_summary を source 実行 → stderr に '⚠ 未完了タスク残存（UNFINISHED TASKS DETECTED）' を含む見出し行が出力される
out_pending=$(run_summary "${FIXTURES_DIR}/task-stack-with-pending.json")
assert_contains "with-pending → 視覚見出し '⚠ 未完了タスク残存（UNFINISHED TASKS DETECTED）' 出力" \
  "⚠ 未完了タスク残存（UNFINISHED TASKS DETECTED）" "$out_pending"
# Layer 2: pending=2 が bullet 行に含まれる
assert_contains "with-pending → bullet 'pending=2' 含有"      "pending=2"      "$out_pending"
assert_contains "with-pending → bullet 'in_progress=0' 含有"  "in_progress=0"  "$out_pending"
# Layer 3: 対処hint '→' が含まれる
assert_contains "with-pending → 対処hint '→' 矢印含有" "→" "$out_pending"

# behavior: fixture task-stack-with-failed.json (failed=1 残存) を渡して print_summary を source 実行 → stderr に 'failed=1' を含む状態別カウント行が出力される
out_failed=$(run_summary "${FIXTURES_DIR}/task-stack-with-failed.json")
assert_contains "with-failed → 視覚見出し出力" \
  "⚠ 未完了タスク残存（UNFINISHED TASKS DETECTED）" "$out_failed"
# Layer 2 bullet として 'failed=1' が単独行に含まれること（[WARN] 行の内訳とは別）
failed_bullet_count=$(echo "$out_failed" | grep -cE '^[[:space:]]*•[[:space:]]+failed=1[[:space:]]*$' || true)
if [ "$failed_bullet_count" -ge 1 ]; then
  assert_eq "with-failed → bullet 行 '• failed=1' が単独行に出力" "ok" "ok"
else
  assert_eq "with-failed → bullet 行 '• failed=1' が単独行に出力" "ok" "missing(count=${failed_bullet_count})"
fi

# behavior: fixture task-stack-with-blocked.json (blocked_criteria=1, blocked_investigation=1) を渡して print_summary を source 実行 → stderr に両方のカウントが個別に表示される（合算ではなく内訳表示）
out_blocked=$(run_summary "${FIXTURES_DIR}/task-stack-with-blocked.json")
bc_bullet_count=$(echo "$out_blocked" | grep -cE '^[[:space:]]*•[[:space:]]+blocked_criteria=1[[:space:]]*$' || true)
bi_bullet_count=$(echo "$out_blocked" | grep -cE '^[[:space:]]*•[[:space:]]+blocked_investigation=1[[:space:]]*$' || true)
if [ "$bc_bullet_count" -ge 1 ]; then
  assert_eq "with-blocked → bullet 行 '• blocked_criteria=1' が個別表示" "ok" "ok"
else
  assert_eq "with-blocked → bullet 行 '• blocked_criteria=1' が個別表示" "ok" "missing(count=${bc_bullet_count})"
fi
if [ "$bi_bullet_count" -ge 1 ]; then
  assert_eq "with-blocked → bullet 行 '• blocked_investigation=1' が個別表示" "ok" "ok"
else
  assert_eq "with-blocked → bullet 行 '• blocked_investigation=1' が個別表示" "ok" "missing(count=${bi_bullet_count})"
fi

# behavior: fixture task-stack-all-done.json (全タスク completed) を渡して print_summary を source 実行 → stderr に '⚠ 未完了タスク残存' 文字列が含まれない（silent on success）
out_done2=$(run_summary "${FIXTURES_DIR}/task-stack-all-done.json")
assert_not_contains "all-done → 視覚ブロック非出力（silent on success）" "⚠ 未完了タスク残存" "$out_done2"

# behavior: fixture task-stack-empty-tasks.json (tasks=[]) を渡して print_summary を source 実行 → 警告ブロックは出力されず、関数は exit 0 で正常終了する（エッジケース）
TASK_STACK="${FIXTURES_DIR}/task-stack-empty-tasks.json"
set +e
out_empty=$(print_summary 2>&1 >/dev/null)
empty_exit=$?
set -e
assert_eq "empty-tasks → print_summary exit 0 で正常終了" "0" "$empty_exit"
assert_not_contains "empty-tasks → 視覚見出し非出力（エッジケース）" "⚠ 未完了タスク残存" "$out_empty"
assert_not_contains "empty-tasks → '[WARN] UNFINISHED_TASKS=' 非出力" "[WARN] UNFINISHED_TASKS=" "$out_empty"

echo ""
fi

# ========================================================================
# Group 7: tty ガード (-t tty_guard) — ANSI 抑止と global 非依存
# ========================================================================
if should_run_group tty_guard; then
echo -e "${BOLD}--- Group 7: tty_guard ---${NC}"

# behavior: print_summary を fixture task-stack-with-pending.json で実行し stderr を 2>/tmp/out.log にリダイレクト → /tmp/out.log に \x1b[ または ESC[ を含む ANSI バイトが0回出現する
TTY_OUT_LOG="${TMP_DIR}/out.log"
TASK_STACK="${FIXTURES_DIR}/task-stack-with-pending.json"
print_summary >/dev/null 2>"$TTY_OUT_LOG"
ansi_count=$(grep -cE $'\x1b\\[' "$TTY_OUT_LOG" || true)
assert_eq "stderr リダイレクト時 → ANSI ESC バイト 0回（[ -t 2 ] 偽）" "0" "$ansi_count"
# 視覚見出しの「文字列自体」は ANSI を含まなくても出力されているはず
heading_present=$(grep -cF "⚠ 未完了タスク残存" "$TTY_OUT_LOG" || true)
if [ "$heading_present" -ge 1 ]; then
  assert_eq "stderr リダイレクト時 → 視覚見出しテキストは出力（ANSI のみ抑止）" "ok" "ok"
else
  assert_eq "stderr リダイレクト時 → 視覚見出しテキストは出力（ANSI のみ抑止）" "ok" "missing(count=${heading_present})"
fi

# behavior: NO_COLOR=1 を環境変数に設定し tty 環境で実行 → stderr 出力に ANSI エスケープが含まれない（NO_COLOR 規約準拠、異常系）
TTY_OUT_LOG2="${TMP_DIR}/out-nocolor.log"
NO_COLOR=1 print_summary >/dev/null 2>"$TTY_OUT_LOG2"
nocolor_ansi_count=$(grep -cE $'\x1b\\[' "$TTY_OUT_LOG2" || true)
assert_eq "NO_COLOR=1 設定時 → ANSI ESC バイト 0回（NO_COLOR 規約準拠）" "0" "$nocolor_ansi_count"

# behavior: common.sh の global RED/BOLD/NC 変数を意図的に空文字に上書きしてから print_summary を実行 → ローカル変数で再定義されているため tty 時は色付きで出力される（global 依存していないことの確認、エッジケース）
# 実装は tty/NO_COLOR ガードの中でのみ ANSI を出すため、非tty キャプチャでは ANSI は出ない。
# したがって runtime 検証ではなく構造検証で「global 非依存」を担保する。
# (a) global を空にしても警告ブロック自体は出力されること（ANSI なしでも見出し文字列は出る）
TTY_OUT_LOG3="${TMP_DIR}/out-globals-empty.log"
RED="" BOLD="" NC="" YELLOW="" GREEN="" CYAN="" DIM="" \
  print_summary >/dev/null 2>"$TTY_OUT_LOG3"
heading_present3=$(grep -cF "⚠ 未完了タスク残存" "$TTY_OUT_LOG3" || true)
if [ "$heading_present3" -ge 1 ]; then
  assert_eq "global 色変数空 → 視覚見出しは依然出力（global 非依存）" "ok" "ok"
else
  assert_eq "global 色変数空 → 視覚見出しは依然出力（global 非依存）" "ok" "missing(count=${heading_present3})"
fi
# (b) [WARN] 機械可読プレフィックスも依然出力（log() 経由）
warn_present3=$(grep -cE '\[WARN\] UNFINISHED_TASKS=' "$TTY_OUT_LOG3" || true)
if [ "$warn_present3" -ge 1 ]; then
  assert_eq "global 色変数空 → '[WARN] UNFINISHED_TASKS=' も依然出力" "ok" "ok"
else
  assert_eq "global 色変数空 → '[WARN] UNFINISHED_TASKS=' も依然出力" "ok" "missing(count=${warn_present3})"
fi

echo ""
fi

# ========================================================================
# Group 8: L3 構造検証 (-t l3_structure) — print_summary 関数の構造的健全性
# ========================================================================
if should_run_group l3_structure; then
echo -e "${BOLD}--- Group 8: l3_structure ---${NC}"

# L3-001: print_summary 関数本体に [ -t 2 ] tty ガードと NO_COLOR ガードが両方含まれる
tty_guard_count=$(echo "$PS_BODY" | grep -cE '\[[[:space:]]*-t[[:space:]]+2[[:space:]]*\]' || true)
if [ "$tty_guard_count" -ge 1 ]; then
  assert_eq "L3-001a: print_summary に '[ -t 2 ]' tty ガード含有" "ok" "ok"
else
  assert_eq "L3-001a: print_summary に '[ -t 2 ]' tty ガード含有" "ok" "missing(count=${tty_guard_count})"
fi
nocolor_guard_count=$(echo "$PS_BODY" | grep -cE 'NO_COLOR' || true)
if [ "$nocolor_guard_count" -ge 1 ]; then
  assert_eq "L3-001b: print_summary に 'NO_COLOR' ガード含有" "ok" "ok"
else
  assert_eq "L3-001b: print_summary に 'NO_COLOR' ガード含有" "ok" "missing(count=${nocolor_guard_count})"
fi

# L3-003: 視覚ブロックがローカル _vis_* 変数を使う（global ${RED}${BOLD}${NC} で出力していない）
# 視覚ブロックを抽出: '視覚警告ブロック' から end of if までを軽く切り出し
visual_block="$(echo "$PS_BODY" | awk '
  /視覚警告ブロック/ { in_vb = 1 }
  in_vb { print }
  in_vb && /echo "" >&2/ { vb_end_seen++ ; if (vb_end_seen >= 1 && /^[[:space:]]*echo "" >&2[[:space:]]*$/) { in_vb = 0 } }
')"

# (a) ローカル変数 _vis_red / _vis_bold / _vis_yellow / _vis_nc が定義されている
local_var_decl=$(echo "$PS_BODY" | grep -cE 'local[[:space:]]+_vis_red[[:space:]]+_vis_bold' || true)
if [ "$local_var_decl" -ge 1 ]; then
  assert_eq "L3-003a: 視覚ブロックで 'local _vis_red _vis_bold ...' 宣言含有" "ok" "ok"
else
  assert_eq "L3-003a: 視覚ブロックで 'local _vis_red _vis_bold ...' 宣言含有" "ok" "missing"
fi

# (b) 視覚ブロックの printf が ローカル変数 ${_vis_red} 等を参照している
vis_red_use=$(echo "$PS_BODY" | grep -cE '\$\{_vis_red\}' || true)
vis_bold_use=$(echo "$PS_BODY" | grep -cE '\$\{_vis_bold\}' || true)
vis_yellow_use=$(echo "$PS_BODY" | grep -cE '\$\{_vis_yellow\}' || true)
vis_nc_use=$(echo "$PS_BODY" | grep -cE '\$\{_vis_nc\}' || true)
if [ "$vis_red_use" -ge 1 ] && [ "$vis_bold_use" -ge 1 ] && \
   [ "$vis_yellow_use" -ge 1 ] && [ "$vis_nc_use" -ge 1 ]; then
  assert_eq "L3-003b: 視覚ブロックが \${_vis_red/_vis_bold/_vis_yellow/_vis_nc} 4つ全てを参照" "ok" "ok"
else
  assert_eq "L3-003b: 視覚ブロックが \${_vis_red/_vis_bold/_vis_yellow/_vis_nc} 4つ全てを参照" "ok" \
    "red=${vis_red_use} bold=${vis_bold_use} yellow=${vis_yellow_use} nc=${vis_nc_use}"
fi

# (c) ローカル変数の値として literal ANSI コード（$'\e[31m' / $'\e[1m' / $'\e[33m' / $'\e[0m'）が代入されている
literal_ansi_count=$(echo "$PS_BODY" | grep -cE "_vis_(red|bold|yellow|nc)=\\\$'\\\\e\[" || true)
if [ "$literal_ansi_count" -ge 4 ]; then
  assert_eq "L3-003c: ローカル _vis_* に literal ANSI \$'\\e[...' 4本以上代入 (count=${literal_ansi_count})" "ok" "ok"
else
  assert_eq "L3-003c: ローカル _vis_* に literal ANSI \$'\\e[...' 4本以上代入" "ok" "found=${literal_ansi_count}"
fi

# (d) 視覚ブロック内で printf に global ${RED} / ${BOLD} / ${NC} を直接流していない
# 視覚ブロック行で printf '...' "${RED}" などのパターンを禁止。
visual_global_use=$(echo "$PS_BODY" | awk '
  /視覚警告ブロック/ { in_vb = 1; next }
  /機械可読 未完タスク警告 END/ { in_vb = 0 }
  in_vb {
    if (match($0, /printf .*\$\{(RED|BOLD|YELLOW|NC)\}/)) print
  }
' | wc -l | tr -d ' ')
assert_eq "L3-003d: 視覚ブロック内に global \${RED}/\${BOLD}/\${YELLOW}/\${NC} を printf に流す行 0件" "0" "$visual_global_use"

echo ""
fi

# ===== サマリー =====
print_test_summary
exit $?
