#!/bin/bash
# test-run-claude-effort.sh — run_claude() の effort オプション引数テスト
# common.sh の validate_effort / run_claude(FORGE_DRY_RUN) を検証する。
# 使い方: bash .forge/tests/test-run-claude-effort.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# テストヘルパ（assert_cmd_contains 等）と被テスト対象を読み込む
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/test-helpers.sh"
# common.sh が source 時に参照しうる前提変数を最小定義（set -u 対策）
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
RESEARCH_DIR="test"
json_fail_count=0
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/.forge/lib/common.sh"

echo -e "${BOLD}===== run_claude effort オプションテスト =====${NC}"

# run_claude を DRY RUN で呼び出しコマンド文字列を取得するヘルパ
# 引数: <effort> <work_dir>
build_cmd() {
  local effort="$1" work_dir="$2"
  FORGE_DRY_RUN=1 run_claude \
    "claude-fable-5" "" "dummy prompt" \
    "/tmp/effort-out.json" "/tmp/effort.log" \
    "" "600" "$work_dir" "" "$effort"
}

# --- behavior: effort 引数を省略して run_claude を呼出 → 従来通り --effort フラグなしで claude CLI コマンドが構築される（後方互換） ---
echo -e "\n${BOLD}[1] effort 省略 → --effort フラグなし（後方互換）${NC}"
# 第10引数を渡さない（省略）で DRY RUN 呼び出し
out=$(FORGE_DRY_RUN=1 run_claude "claude-fable-5" "" "p" "/tmp/o.json" "/tmp/o.log")
rc=$?
assert_eq "effort 省略時 run_claude は成功 (exit 0)" "0" "$rc"
assert_cmd_not_contains "effort 省略時は --effort を含まない" "--effort" "$out"
assert_cmd_contains "effort 省略でも claude -p コマンドは構築される" "-p" "$out"

# --- behavior: effort=high を指定して run_claude を呼出 → 構築コマンドに `--effort high` が含まれる ---
echo -e "\n${BOLD}[2] effort=high → --effort high を含む${NC}"
out=$(build_cmd "high" "")
rc=$?
assert_eq "effort=high で run_claude は成功 (exit 0)" "0" "$rc"
assert_cmd_contains "effort=high → '--effort high' を含む" "--effort high" "$out"

# --- behavior: effort=invalid（low/medium/high/xhigh/max 以外）を指定 → バリデーションエラーで非ゼロ終了し全エージェント波及クラッシュを防ぐ ---
echo -e "\n${BOLD}[3] effort=invalid → 非ゼロ終了${NC}"
out=$(build_cmd "invalid" "" 2>/dev/null)
rc=$?
assert_eq "effort=invalid で run_claude は非ゼロ終了 (exit 2)" "2" "$rc"
assert_cmd_not_contains "不正値はコマンドに反映されない" "--effort invalid" "$out"
# validate_effort 単体でも非ゼロを確認
if validate_effort "invalid" >/dev/null 2>&1; then
  assert_eq "validate_effort('invalid') は非ゼロ" "nonzero" "zero"
else
  assert_eq "validate_effort('invalid') は非ゼロ" "nonzero" "nonzero"
fi

# --- behavior: effort 指定かつ work_dir(第8引数相当)指定の併用 → 両方が正しくコマンドに反映される（既存引数との非干渉） ---
echo -e "\n${BOLD}[4] effort + work_dir 併用 → 両方反映（非干渉）${NC}"
out=$(build_cmd "high" "$PROJECT_ROOT")
rc=$?
assert_eq "effort+work_dir 併用で run_claude は成功 (exit 0)" "0" "$rc"
assert_cmd_contains "併用時も '--effort high' を含む" "--effort high" "$out"
assert_cmd_contains "併用時 WORK_DIR が正しく反映される" "WORK_DIR: ${PROJECT_ROOT}" "$out"
assert_cmd_contains "併用時も -p モードは維持される" "-p" "$out"

# --- behavior: effort=low を指定 → `--effort low` が含まれ -p モードと併用される ---
echo -e "\n${BOLD}[5] effort=low → --effort low かつ -p 併用${NC}"
out=$(build_cmd "low" "")
rc=$?
assert_eq "effort=low で run_claude は成功 (exit 0)" "0" "$rc"
assert_cmd_contains "effort=low → '--effort low' を含む" "--effort low" "$out"
assert_cmd_contains "effort=low は -p モードと併用される" "-p" "$out"

# --- behavior: [追加] validate_effort は全許可値を受理する（エッジケース網羅） ---
echo -e "\n${BOLD}[6] [追加] 全許可値 (low/medium/high/xhigh/max) を受理${NC}"
for lvl in low medium high xhigh max; do
  s=$(validate_effort "$lvl"); r=$?
  assert_eq "validate_effort('${lvl}') は exit 0" "0" "$r"
  assert_eq "validate_effort('${lvl}') 出力" "--effort ${lvl}" "$s"
done

# --- behavior: [追加] validate_effort 空文字は出力なし・exit 0（後方互換の土台） ---
echo -e "\n${BOLD}[7] [追加] 空文字 → 出力なし・exit 0${NC}"
s=$(validate_effort ""); r=$?
assert_eq "validate_effort('') は exit 0" "0" "$r"
assert_eq "validate_effort('') は空出力" "" "$s"

print_test_summary
