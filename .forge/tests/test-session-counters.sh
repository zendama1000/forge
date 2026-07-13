#!/bin/bash
# test-session-counters.sh — session-counters の session_id スコープ復元（batch#8 Fix5）
# 対象: ralph-loop.sh の persist_session_state / restore_session_state
# 使い方: bash .forge/tests/test-session-counters.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log() { :; }

eval "$(extract_all_functions_awk "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" \
  persist_session_state restore_session_state)"

echo -e "${BOLD}===== test-session-counters.sh — session_id スコープ復元 =====${NC}"
echo ""

SESSION_COUNTERS_FILE="${TMPDIR}/session-counters.json"

reset_counters() {
  task_count=0; investigation_count=0; approach_scope_count=0; phase3_retry_count=0
}

# ===== T1: 同一 session_id → 復元される（クラッシュ復旧維持） =====
echo -e "${BOLD}--- T1: 同一セッション復元 ---${NC}"
export FORGE_SESSION_ID="sess-same"
task_count=7; investigation_count=2; approach_scope_count=1; phase3_retry_count=1
persist_session_state
assert_eq "persist: session_id が書かれる" "sess-same" "$(jq -r '.session_id' "$SESSION_COUNTERS_FILE")"

reset_counters
restore_session_state
assert_eq "同一 sid: task_count 復元" "7" "$task_count"
assert_eq "同一 sid: investigation_count 復元" "2" "$investigation_count"
assert_eq "同一 sid: phase3_retry_count 復元" "1" "$phase3_retry_count"

# ===== T2: 別 session_id → 0 リセット + ファイルが新 sid でスタンプされる =====
echo -e "${BOLD}--- T2: 別セッションは 0 リセット ---${NC}"
export FORGE_SESSION_ID="sess-new"
task_count=99; investigation_count=99; approach_scope_count=99; phase3_retry_count=99
restore_session_state
assert_eq "別 sid: task_count=0" "0" "$task_count"
assert_eq "別 sid: investigation_count=0" "0" "$investigation_count"
assert_eq "別 sid: ファイルが新 sid で再スタンプ" "sess-new" "$(jq -r '.session_id' "$SESSION_COUNTERS_FILE")"
assert_eq "別 sid: ファイルのカウンタも 0" "0" "$(jq -r '.task_count' "$SESSION_COUNTERS_FILE")"

# ===== T3: legacy ファイル（session_id なし）→ 0 リセット =====
echo -e "${BOLD}--- T3: legacy ファイル ---${NC}"
jq -n '{task_count: 42, investigation_count: 5, approach_scope_count: 0, phase3_retry_count: 0, updated_at: "2026-07-01T00:00:00+09:00"}' > "$SESSION_COUNTERS_FILE"
export FORGE_SESSION_ID="sess-legacy-check"
task_count=1; investigation_count=1; approach_scope_count=1; phase3_retry_count=1
restore_session_state
assert_eq "legacy: task_count=0（42 を継承しない）" "0" "$task_count"
assert_eq "legacy: investigation_count=0（5 を継承しない = 即 breaker 発火の根絶）" "0" "$investigation_count"

# ===== T4: FORGE_SESSION_ID 未設定 → 0 リセット（空==空の誤マッチ防止） =====
echo -e "${BOLD}--- T4: sid 未設定 ---${NC}"
jq -n '{task_count: 10, investigation_count: 3, approach_scope_count: 0, phase3_retry_count: 0, session_id: "", updated_at: "x"}' > "$SESSION_COUNTERS_FILE"
unset FORGE_SESSION_ID
task_count=5; investigation_count=5; approach_scope_count=5; phase3_retry_count=5
restore_session_state
assert_eq "sid 未設定: task_count=0（空文字列同士でも復元しない）" "0" "$task_count"
export FORGE_SESSION_ID="sess-after-t4"

# ===== T5: ファイル欠損 → デフォルト（現在値のまま） =====
echo -e "${BOLD}--- T5: ファイル欠損 ---${NC}"
rm -f "$SESSION_COUNTERS_FILE"
task_count=3; investigation_count=1; approach_scope_count=0; phase3_retry_count=0
restore_session_state
assert_eq "ファイル欠損: 現在値が維持される（rc=0 で無害）" "3" "$task_count"

# ===== T6: 破損 JSON → 0 リセット（安全側） =====
echo -e "${BOLD}--- T6: 破損 JSON ---${NC}"
echo '{ broken json' > "$SESSION_COUNTERS_FILE"
export FORGE_SESSION_ID="sess-corrupt"
task_count=8; investigation_count=8; approach_scope_count=8; phase3_retry_count=8
restore_session_state
assert_eq "破損 JSON: task_count=0（jq 失敗 → sid 空扱い → リセット）" "0" "$task_count"

print_test_summary
exit $?
