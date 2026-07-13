#!/bin/bash
# test-validation-v2-e2e.sh — validation v2 の L1 実行経路 E2E（batch#8 Stage3 walking skeleton）
# 対象: ralph-loop.sh task_run_l1_test の v2 分岐（実関数抽出）
# 使い方: bash .forge/tests/test-validation-v2-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
json_fail_count=0
source "${PROJECT_ROOT}/.forge/lib/common.sh"   # validation-dsl.sh も guarded source される
log() { echo "$@"; }

# ralph-loop.sh から実関数を抽出
eval "$(extract_all_functions_awk "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" \
  task_run_l1_test execute_layer1_test)"

# スタブ群
apply_effort_timeout() { echo "$1"; }
resolve_agent_effort() { echo "medium"; }
FAIL_LOG="${TMPDIR}/fail-calls.log"
handle_task_fail() { printf 'FAIL_CALLED task=%s\nreason:\n%s\n' "$1" "$3" >> "$FAIL_LOG"; }
ASSERT_LOG="${TMPDIR}/assert-calls.log"
validate_locked_assertions() { echo "called" >> "$ASSERT_LOG"; return 0; }
record_quality_debt() { :; }

QUALITY_LEDGER_FILE="${TMPDIR}/debts.jsonl"
L1_DEFAULT_TIMEOUT=60
WORK_DIR="${TMPDIR}/work"
mkdir -p "$WORK_DIR"
touch "${WORK_DIR}/real-artifact.ts"
TASK_DIR="${TMPDIR}/task"
mkdir -p "$TASK_DIR"

echo -e "${BOLD}===== test-validation-v2-e2e.sh — L1 v2 経路 =====${NC}"
echo ""

# ===== T1: v2 が権威 — legacy command が exit 1 でも checks pass なら成功 =====
echo -e "${BOLD}--- T1: v2 権威 ---${NC}"
_RT_TASK_JSON='{"task_id":"T-v2","validation":{
  "layer_1":{"command":"exit 1","expect":"dead"},
  "checks":[{"id":"c1","layer":1,"verb":"file_exists","paths":["real-artifact.ts"]}]}}'
: > "$FAIL_LOG"; : > "$ASSERT_LOG"
RESEARCH_CONFIG="${TMPDIR}/rc.json"; echo '{}' > "$RESEARCH_CONFIG"
rc=0
out=$(task_run_l1_test "T-v2" "$TASK_DIR") || rc=$?
assert_eq "v2 checks pass → rc=0（legacy exit 1 は無視）" "0" "$rc"
assert_contains "legacy 無視の警告が出る" "legacy command は無視" "$out"
assert_eq "handle_task_fail は呼ばれない" "0" "$(grep -c FAIL_CALLED "$FAIL_LOG" 2>/dev/null || true)"
assert_eq "locked-assertions は v2 pass 後も実行される" "1" "$(grep -c called "$ASSERT_LOG" 2>/dev/null || true)"
assert_contains "test-output.txt に v2 集約行" "v2 layer1" "$(cat "${TASK_DIR}/test-output.txt")"

# ===== T2: v2 fail → handle_task_fail に check 出力が渡る =====
echo -e "${BOLD}--- T2: v2 fail 経路 ---${NC}"
_RT_TASK_JSON='{"task_id":"T-v2f","validation":{
  "checks":[{"id":"c1","layer":1,"verb":"file_exists","paths":["missing-artifact.ts"]}]}}'
: > "$FAIL_LOG"
rc=0
task_run_l1_test "T-v2f" "$TASK_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "v2 fail → rc=1" "1" "$rc"
assert_eq "handle_task_fail が呼ばれる" "1" "$(grep -c FAIL_CALLED "$FAIL_LOG")"
assert_contains "fail 理由に check 詳細" "missing-artifact.ts" "$(cat "$FAIL_LOG")"

# ===== T3: legacy-only タスクは従来経路（バイト同一挙動） =====
echo -e "${BOLD}--- T3: legacy 経路不変 ---${NC}"
_RT_TASK_JSON='{"task_id":"T-legacy","validation":{
  "layer_1":{"command":"test -f real-artifact.ts && echo LEGACY_OK","expect":"OK"}}}'
: > "$FAIL_LOG"
rc=0
out=$(task_run_l1_test "T-legacy" "$TASK_DIR") || rc=$?
assert_eq "legacy pass → rc=0" "0" "$rc"
assert_contains "legacy 実行ログ" "Layer 1 テスト実行" "$out"
assert_contains "test-output.txt に legacy 出力" "LEGACY_OK" "$(cat "${TASK_DIR}/test-output.txt")"

_RT_TASK_JSON='{"task_id":"T-legacy-f","validation":{"layer_1":{"command":"test -f nope","expect":"x"}}}'
: > "$FAIL_LOG"
rc=0
task_run_l1_test "T-legacy-f" "$TASK_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "legacy fail → rc=1 + handle_task_fail" "1" "$rc"
assert_eq "legacy fail: handle_task_fail 呼出" "1" "$(grep -c FAIL_CALLED "$FAIL_LOG")"

# ===== T4: L1 コマンド未定義（v2 もなし）は従来通り完了扱い =====
echo -e "${BOLD}--- T4: 未定義は従来挙動 ---${NC}"
_RT_TASK_JSON='{"task_id":"T-none","validation":{"layer_1":{}}}'
rc=0
out=$(task_run_l1_test "T-none" "$TASK_DIR") || rc=$?
assert_eq "コマンド未定義 → rc=0（従来挙動）" "0" "$rc"
assert_contains "未定義警告" "未定義" "$out"

# ===== T5: 旧 bash -c ラップ legacy コマンドも（Fix1 unwrap 経由で）通る =====
echo -e "${BOLD}--- T5: legacy + Fix1 unwrap 統合 ---${NC}"
_RT_TASK_JSON='{"task_id":"T-wrap","validation":{"layer_1":{"command":"bash -c \"test -f real-artifact.ts && echo WRAP_OK\"","expect":"OK"}}}'
rc=0
out=$(task_run_l1_test "T-wrap" "$TASK_DIR") || rc=$?
assert_eq "bash -c ラップ legacy も pass" "0" "$rc"
assert_contains "unwrap 済みで実行される" "WRAP_OK" "$(cat "${TASK_DIR}/test-output.txt")"

print_test_summary
exit $?
