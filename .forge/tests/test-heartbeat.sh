#!/bin/bash
# test-heartbeat.sh — ハートビート ユニットテスト
set -euo pipefail

source "$(dirname "$0")/test-helpers.sh"

echo -e "${BOLD}=== ハートビート テスト ===${NC}"

# ===== セットアップ =====
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# update_heartbeat に必要な変数
HEARTBEAT_FILE="${TMPDIR_BASE}/heartbeat.json"
task_count=5
investigation_count=2
START_SECONDS=$((SECONDS - 120))  # 2分前開始を模擬

# 関数定義を直接用意（ralph-loop.sh から抽出は依存が多いため）
update_heartbeat() {
  local current_task="${1:-}"
  local elapsed_sec=$((SECONDS - START_SECONDS))
  local elapsed_min=$((elapsed_sec / 60))
  jq -n \
    --arg loop "ralph" \
    --arg task "$current_task" \
    --argjson tc "$task_count" \
    --argjson ic "$investigation_count" \
    --arg elapsed "${elapsed_min}m" \
    --arg ts "$(date -Iseconds)" \
    '{loop: $loop, current_task: $task, task_count: $tc,
     investigation_count: $ic, elapsed: $elapsed, heartbeat_at: $ts}' \
    > "${HEARTBEAT_FILE}.tmp" 2>/dev/null && mv "${HEARTBEAT_FILE}.tmp" "$HEARTBEAT_FILE"
}

# ===== テスト 1: heartbeat.json 生成 =====
echo ""
echo "--- テスト: heartbeat.json 生成 ---"
update_heartbeat "task-mvp-01"
assert_eq "ファイル存在" "yes" "$([ -f "$HEARTBEAT_FILE" ] && echo yes || echo no)"

# ===== テスト 2: JSON 構造検証 =====
echo ""
echo "--- テスト: JSON 構造検証 ---"
loop=$(jq -r '.loop' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
task=$(jq -r '.current_task' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
tc=$(jq -r '.task_count' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
ic=$(jq -r '.investigation_count' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
assert_eq "loop" "ralph" "$loop"
assert_eq "current_task" "task-mvp-01" "$task"
assert_eq "task_count" "5" "$tc"
assert_eq "investigation_count" "2" "$ic"

# ===== テスト 3: elapsed 計算 =====
echo ""
echo "--- テスト: elapsed 計算 ---"
elapsed=$(jq -r '.elapsed' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
assert_contains "elapsed に m を含む" "m" "$elapsed"

# ===== テスト 4: アトミック更新（.tmp → mv） =====
echo ""
echo "--- テスト: アトミック更新 ---"
update_heartbeat "task-mvp-02"
task2=$(jq -r '.current_task' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
assert_eq "更新後のタスク" "task-mvp-02" "$task2"
# .tmp が残っていないことを確認
assert_eq ".tmp 不在" "no" "$([ -f "${HEARTBEAT_FILE}.tmp" ] && echo yes || echo no)"

# ===== サマリー =====
print_test_summary
