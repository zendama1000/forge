#!/bin/bash
# test-events.sh — イベントソーシング ユニットテスト
set -euo pipefail

source "$(dirname "$0")/test-helpers.sh"

echo -e "${BOLD}=== イベントソーシング テスト ===${NC}"

# ===== セットアップ =====
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PROJECT_ROOT="$TMPDIR_BASE"
RESEARCH_DIR="test-session"
mkdir -p "$TMPDIR_BASE/.forge/state"

# common.sh から必要な関数を抽出して source
REAL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
extract_all_functions_awk "${REAL_ROOT}/.forge/lib/common.sh" \
  record_task_event jq_safe log > "${TMPDIR_BASE}/_funcs.sh"
source "${TMPDIR_BASE}/_funcs.sh"

TASK_EVENTS_FILE="${TMPDIR_BASE}/.forge/state/task-events.jsonl"
touch "$TASK_EVENTS_FILE"

# ===== テスト 1: record_task_event で JSONL に記録 =====
echo ""
echo "--- テスト: record_task_event 基本記録 ---"
record_task_event "task-01" "status_changed" '{"new_status":"in_progress"}'
count=$(wc -l < "$TASK_EVENTS_FILE" | tr -d ' ')
assert_eq "1件記録" "1" "$count"

# ===== テスト 2: JSON 構造の正しさ =====
echo ""
echo "--- テスト: JSON 構造検証 ---"
line=$(head -1 "$TASK_EVENTS_FILE")
tid=$(echo "$line" | jq -r '.task_id' 2>/dev/null | tr -d '\r')
evt=$(echo "$line" | jq -r '.event' 2>/dev/null | tr -d '\r')
ses=$(echo "$line" | jq -r '.session' 2>/dev/null | tr -d '\r')
assert_eq "task_id" "task-01" "$tid"
assert_eq "event" "status_changed" "$evt"
assert_eq "session" "test-session" "$ses"

# ===== テスト 3: detail が有効な JSON =====
echo ""
echo "--- テスト: detail JSON 検証 ---"
detail_status=$(echo "$line" | jq -r '.detail.new_status' 2>/dev/null | tr -d '\r')
assert_eq "detail.new_status" "in_progress" "$detail_status"

# ===== テスト 4: timestamp 存在 =====
echo ""
echo "--- テスト: timestamp 存在 ---"
ts=$(echo "$line" | jq -r '.timestamp' 2>/dev/null | tr -d '\r')
has_ts="no"
[ -n "$ts" ] && [ "$ts" != "null" ] && has_ts="yes"
assert_eq "timestamp 存在" "yes" "$has_ts"

# ===== テスト 5: 複数イベント記録 =====
echo ""
echo "--- テスト: 複数イベント記録 ---"
record_task_event "task-01" "task_started" "{}"
record_task_event "task-01" "task_passed" "{}"
record_task_event "task-02" "status_changed" '{"new_status":"pending"}'
count=$(wc -l < "$TASK_EVENTS_FILE" | tr -d ' ')
assert_eq "4件記録" "4" "$count"

# ===== テスト 6: デフォルト detail =====
echo ""
echo "--- テスト: デフォルト detail ---"
record_task_event "task-03" "heartbeat"
line=$(tail -1 "$TASK_EVENTS_FILE")
detail=$(echo "$line" | jq -r '.detail' 2>/dev/null | tr -d '\r')
assert_eq "デフォルト detail は空オブジェクト" "{}" "$detail"

# ===== サマリー =====
print_test_summary
