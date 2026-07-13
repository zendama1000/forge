#!/bin/bash
# test-l1-unwrap-runtime.sh — L1 実行ファネルの bash -c unwrap（batch#8 Fix1 二重防御）
# 歴史的実害の再現: Planner が bash -c "…\"$var\"…" を書くと execute_layer1_test の
# 再ラップで内側 $var が外側シェルに先に解釈され 15 連続失敗した（make-video v2, 2026-04-21）。
# 使い方: bash .forge/tests/test-l1-unwrap-runtime.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export NOTIFY_DIR="${TMPDIR}/notifications"
json_fail_count=0
touch "$ERRORS_FILE"

# unwrap_bash_c / FORGE_JQ_UNWRAP_BASH_C は common.sh から
source "${PROJECT_ROOT}/.forge/lib/common.sh"
log() { :; }

# execute_layer1_test を ralph-loop.sh から実抽出
eval "$(extract_all_functions_awk "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" execute_layer1_test)"

echo -e "${BOLD}===== test-l1-unwrap-runtime.sh — L1 unwrap 二重防御 =====${NC}"
echo ""

WORK_DIR="${TMPDIR}/work"
L1_DEFAULT_TIMEOUT=30
mkdir -p "$WORK_DIR"
touch "${WORK_DIR}/marker"
echo '{"ok": true}' > "${WORK_DIR}/a.json"
echo '{"ok": false}' > "${WORK_DIR}/b.json"

# ===== T1: 歴史的15連敗ケース — bash -c ラップされた変数入りループ =====
echo -e "${BOLD}--- T1: 歴史的再現ケース ---${NC}"
rc=0
out=$(execute_layer1_test 'bash -c "for s in *.json; do jq -e . \"$s\" > /dev/null || exit 1; done && echo LOOP_OK"') || rc=$?
assert_eq "旧 Planner 形式（bash -c + \$var）が exit 0 で通る" "0" "$rc"
assert_contains "内側ループが実行される" "LOOP_OK" "$out"

# ===== T2: 単純ラップ =====
echo -e "${BOLD}--- T2: 単純ラップ ---${NC}"
rc=0
out=$(execute_layer1_test 'bash -c "test -f marker && echo OK"') || rc=$?
assert_eq "bash -c \"test -f … && echo OK\" が exit 0" "0" "$rc"
assert_contains "echo OK が出力される" "OK" "$out"

# ===== T3: 生コマンドは従来通り（unwrap は冪等） =====
echo -e "${BOLD}--- T3: 生コマンド不変 ---${NC}"
rc=0
out=$(execute_layer1_test 'test -f marker && echo BARE_OK') || rc=$?
assert_eq "生コマンドは従来通り exit 0" "0" "$rc"
assert_contains "出力も従来通り" "BARE_OK" "$out"

# ===== T4: 失敗コマンドは失敗のまま（unwrap が合否を変えない） =====
echo -e "${BOLD}--- T4: 失敗はそのまま失敗 ---${NC}"
rc=0
execute_layer1_test 'bash -c "test -f no-such-file"' >/dev/null 2>&1 || rc=$?
assert_eq "存在しないファイルは非ゼロ" "1" "$rc"

print_test_summary
exit $?
