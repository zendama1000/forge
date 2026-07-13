#!/bin/bash
# test-scenario-session-counters.sh — session-counters 持ち越しバグの再現回帰
#
# 実害 (2026-07-09 browser-cockpit): session-counters.json は再起動をまたいで
# 無条件復元され、investigation_count が上限に達していると circuit-breaker が
# 起動 ~17 秒で発火 → タスク未処理のまま「完了」扱いで即終了する。
#
# 本テストは【現状のバグ挙動】を PASS としてエンコードする（BUG-REPRO）。
# Stage-2 Fix5（session_id 一致時のみ復元）適用時に、下記の BUG-REPRO アサートを
# 反転させること（fresh session はカウンタを継承しない、が修正後の正）。
#
# 使い方: bash .forge/tests/test-scenario-session-counters.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log() { echo "$@"; }

# ralph-loop.sh から実関数を抽出
eval "$(extract_all_functions_awk "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" \
  persist_session_state restore_session_state)"

echo -e "${BOLD}===== test-scenario-session-counters.sh — counters 持ち越し再現 =====${NC}"
echo ""

SESSION_COUNTERS_FILE="${TMPDIR}/session-counters.json"
MAX_INVESTIGATIONS=5

# ===== セッション1: 上限到達状態で persist =====
task_count=42
investigation_count=5
approach_scope_count=1
phase3_retry_count=0
export FORGE_SESSION_ID="session-one"
persist_session_state
assert_eq "セッション1: counters ファイルが書かれる" "5" "$(jq -r '.investigation_count' "$SESSION_COUNTERS_FILE" 2>/dev/null)"

# ===== セッション2（別セッション想定）: fresh 起動をシミュレート =====
task_count=0
investigation_count=0
approach_scope_count=0
phase3_retry_count=0
export FORGE_SESSION_ID="session-two"
restore_session_state >/dev/null 2>&1

# --- BUG-REPRO(stage-2): 以下は【現状のバグ挙動】を固定するアサート ---
# Fix5 適用後は expected を "0" に反転し、ラベルを「継承しない」に変えること
assert_eq "BUG-REPRO(stage-2): 別セッションでも investigation_count を継承してしまう（修正後は 0 になるべき）" \
  "5" "$investigation_count"
assert_eq "BUG-REPRO(stage-2): 別セッションでも task_count を継承してしまう（修正後は 0 になるべき）" \
  "42" "$task_count"

# 継承された結果、breaker 条件（investigation_count >= MAX_INVESTIGATIONS）が
# タスクを1つも処理していないのに即成立する = 実害の機序
if [ "$investigation_count" -ge "$MAX_INVESTIGATIONS" ]; then
  assert_eq "BUG-REPRO(stage-2): 起動直後に investigation_limit breaker が成立してしまう" \
    "trips" "trips"
else
  assert_eq "BUG-REPRO(stage-2): 起動直後に investigation_limit breaker が成立してしまう" \
    "trips" "no-trip"
fi

# ===== 現状仕様の確認: counters ファイルには session_id が無い（Fix5 で追加される） =====
sid_field=$(jq -r '.session_id // "ABSENT"' "$SESSION_COUNTERS_FILE" 2>/dev/null)
assert_eq "BUG-REPRO(stage-2): counters に session_id フィールドが無い（Fix5 で追加）" \
  "ABSENT" "$sid_field"

# ===== 同一セッション内クラッシュ復旧（この挙動は修正後も維持されるべき） =====
task_count=7
investigation_count=2
approach_scope_count=0
phase3_retry_count=1
persist_session_state
task_count=0; investigation_count=0; approach_scope_count=0; phase3_retry_count=0
restore_session_state >/dev/null 2>&1
assert_eq "同一セッション復旧: task_count 復元（修正後も維持すべき挙動）" "7" "$task_count"
assert_eq "同一セッション復旧: phase3_retry_count 復元" "1" "$phase3_retry_count"

print_test_summary
exit $?
