#!/bin/bash
# test-ralph-retry-e2e.sh — Implementer失敗→リトライ→成功パスの E2E テスト
# L2 criteria: L2-003
# 使い方: bash .forge/tests/test-ralph-retry-e2e.sh
#
# 前提条件:
#   - サーバー起動不要（スタブ方式）
#   - ralph-loop.sh のリトライロジックをスタブ環境で検証
#   - 冪等: 実行ごとにクリーンアップ

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-ralph-retry-e2e.sh — Implementer リトライ E2E =====${NC}"
echo ""

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_SH="${REAL_ROOT}/.forge/lib/common.sh"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"

# ===== テスト環境セットアップ =====
TEST_ROOT=$(mktemp -d)
trap "rm -rf '$TEST_ROOT'" EXIT

mkdir -p "${TEST_ROOT}/.forge/lib"
mkdir -p "${TEST_ROOT}/.forge/config"
mkdir -p "${TEST_ROOT}/.forge/state"
mkdir -p "${TEST_ROOT}/.forge/logs/development"

cp "${REAL_ROOT}/.forge/lib/common.sh"   "${TEST_ROOT}/.forge/lib/common.sh"
cp "${REAL_ROOT}/.forge/lib/bootstrap.sh" "${TEST_ROOT}/.forge/lib/bootstrap.sh"

# circuit-breaker.json と development.json をコピー（なければデフォルト生成）
if [ -f "${REAL_ROOT}/.forge/config/circuit-breaker.json" ]; then
  cp "${REAL_ROOT}/.forge/config/circuit-breaker.json" "${TEST_ROOT}/.forge/config/circuit-breaker.json"
else
  echo '{"development_limits":{"max_task_retries":3,"max_total_tasks":50,"max_investigations_per_session":5,"max_duration_minutes":240}}' \
    > "${TEST_ROOT}/.forge/config/circuit-breaker.json"
fi

if [ -f "${REAL_ROOT}/.forge/config/development.json" ]; then
  cp "${REAL_ROOT}/.forge/config/development.json" "${TEST_ROOT}/.forge/config/development.json"
else
  echo '{"implementer":{"model":"sonnet","timeout_sec":600},"investigator":{"model":"sonnet","timeout_sec":600}}' \
    > "${TEST_ROOT}/.forge/config/development.json"
fi

touch "${TEST_ROOT}/.forge/state/errors.jsonl"
touch "${TEST_ROOT}/.forge/state/investigation-log.jsonl"
touch "${TEST_ROOT}/.forge/state/lessons-learned.jsonl"
touch "${TEST_ROOT}/.forge/state/task-events.jsonl"

# ===== グローバル変数設定（common.sh / ralph-loop.sh が参照） =====
PROJECT_ROOT="$TEST_ROOT"
WORK_DIR="$TEST_ROOT"
AGENTS_DIR="${TEST_ROOT}/.claude/agents"
TEMPLATES_DIR="${TEST_ROOT}/.forge/templates"
SCHEMAS_DIR="${TEST_ROOT}/.forge/schemas"
DEV_LOG_DIR="${TEST_ROOT}/.forge/logs/development"
ERRORS_FILE="${TEST_ROOT}/.forge/state/errors.jsonl"
INVESTIGATION_LOG="${TEST_ROOT}/.forge/state/investigation-log.jsonl"
LESSONS_FILE="${TEST_ROOT}/.forge/state/lessons-learned.jsonl"
TASK_EVENTS_FILE="${TEST_ROOT}/.forge/state/task-events.jsonl"
LOOP_SIGNAL_FILE="${TEST_ROOT}/.forge/state/loop-signal"
HEARTBEAT_FILE="${TEST_ROOT}/.forge/state/heartbeat.json"
CIRCUIT_BREAKER_CONFIG="${TEST_ROOT}/.forge/config/circuit-breaker.json"
DEV_CONFIG="${TEST_ROOT}/.forge/config/development.json"
RESEARCH_DIR="e2e-retry-test"
json_fail_count=0
CLAUDE_TIMEOUT=600
NOTIFY_DIR="${TEST_ROOT}/.forge/state/notifications"
PROGRESS_FILE="${TEST_ROOT}/.forge/state/progress.json"
VALIDATION_STATS_FILE="${TEST_ROOT}/.forge/state/validation-stats.jsonl"
APPROACH_BARRIERS_FILE="${TEST_ROOT}/.forge/state/approach-barriers.jsonl"

mkdir -p "$NOTIFY_DIR"
touch "$APPROACH_BARRIERS_FILE"

# common.sh を source
source "${TEST_ROOT}/.forge/lib/common.sh"

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'; rm -rf '$TEST_ROOT'" EXIT

extract_all_functions_awk "$RALPH_SH" \
  load_development_config get_next_task update_task_status \
  update_task_fail_count count_tasks_by_status \
  handle_task_pass handle_task_fail sync_task_stack \
  > "$EXTRACT_FILE"

source "$EXTRACT_FILE"
load_development_config

echo -e "  ${GREEN}✓${NC} 関数抽出完了"
echo ""

# ===== E2E テスト1: retry_with_backoff + run_claude モック =====
# Implementer失敗→リトライ→成功パスでタスク完了
echo -e "${BOLD}--- E2E テスト1: Implementer 失敗→リトライ→成功 ---${NC}"

# タスクスタック作成
E2E_TASK_ID="test-impl-retry-001"
TASK_STACK="${TEST_ROOT}/.forge/state/task-stack.json"
cat > "$TASK_STACK" << 'TASKEOF'
{
  "version": "3.0",
  "tasks": [
    {
      "task_id": "test-impl-retry-001",
      "status": "pending",
      "fail_count": 0,
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "description": "E2E retry test task",
      "validation": {
        "layer_1": {
          "command": "echo 'L1 pass'",
          "expect": "exit 0"
        }
      }
    }
  ],
  "updated_at": "2026-01-01T00:00:00Z"
}
TASKEOF

# run_claude スタブ: 1回目失敗、2回目以降成功
E2E_RUN_CLAUDE_COUNT=0
run_claude() {
  E2E_RUN_CLAUDE_COUNT=$((E2E_RUN_CLAUDE_COUNT + 1))
  local output_file="$4"
  if [ "$E2E_RUN_CLAUDE_COUNT" -le 1 ]; then
    # 1回目は失敗
    return 1
  fi
  # 2回目以降は成功（実装ファイルを生成）
  echo "# stub implementation" > "${output_file:-/dev/null}" 2>/dev/null || true
  return 0
}

# sleep スタブ（実際には待たない）
sleep() { :; }

# retry_with_backoff でラップした run_claude を呼び出し（ralph-loop.sh のパターンを模倣）
E2E_RETRY_SUCCESS=false
if retry_with_backoff 3 1 run_claude "sonnet" "implementer.md" \
    "prompt" "${TEST_ROOT}/impl-output.txt" "${DEV_LOG_DIR}/impl.log" "" "600" "$WORK_DIR"; then
  E2E_RETRY_SUCCESS=true
fi

assert_eq "Implementerリトライ後に成功" "true" "$E2E_RETRY_SUCCESS"
assert_eq "run_claudeは2回呼び出された（1失敗+1成功）" "2" "$E2E_RUN_CLAUDE_COUNT"

unset -f sleep
echo ""

# ===== E2E テスト2: 全リトライ失敗時のエラー伝播 =====
echo -e "${BOLD}--- E2E テスト2: 全リトライ失敗 → エラー伝播 ---${NC}"

E2E2_RUN_COUNT=0
run_claude() {
  E2E2_RUN_COUNT=$((E2E2_RUN_COUNT + 1))
  return 1
}
sleep() { :; }

E2E2_FAILED=false
if ! retry_with_backoff 3 1 run_claude "sonnet" "implementer.md" \
    "prompt" "${TEST_ROOT}/impl-output2.txt" "${DEV_LOG_DIR}/impl2.log" "" "600" "$WORK_DIR"; then
  E2E2_FAILED=true
fi

assert_eq "全リトライ失敗時にエラーが伝播する" "true" "$E2E2_FAILED"
# max_retries=3 → 1初回 + 3リトライ = 4回呼び出し
assert_eq "全失敗時は4回呼び出し（1初回+3リトライ）" "4" "$E2E2_RUN_COUNT"

unset -f sleep run_claude
echo ""

# ===== E2E テスト3: retry_with_backoff が ralph-loop.sh に組み込まれている =====
# Implementer run_claude 呼び出しが retry_with_backoff でラップされていることを確認
echo -e "${BOLD}--- E2E テスト3: ralph-loop.sh に retry_with_backoff が統合済み ---${NC}"

RALPH_RETRY_LINES=$(grep -c "retry_with_backoff" "$RALPH_SH" 2>/dev/null || echo "0")
assert_eq "ralph-loop.sh に retry_with_backoff が1箇所以上ある" \
  "1" "$([ "$RALPH_RETRY_LINES" -ge 1 ] && echo 1 || echo 0)"

# Implementer の run_claude 呼び出し行が retry_with_backoff でラップされていることを確認
IMPL_RETRY=$(grep -A1 "retry_with_backoff" "$RALPH_SH" 2>/dev/null | grep -c "run_claude" || echo "0")
assert_eq "retry_with_backoff の直後に run_claude がある（Implementer統合）" \
  "1" "$([ "$IMPL_RETRY" -ge 1 ] && echo 1 || echo 0)"

echo ""

# ===== サマリー =====
print_test_summary
