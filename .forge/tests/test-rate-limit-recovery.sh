#!/bin/bash
# test-rate-limit-recovery.sh — レートリミット自動復旧テスト
# ralph-loop.sh の detect_rate_limit_from_debug_logs / recover_rate_limited_tasks をテスト。
# 使い方: bash .forge/tests/test-rate-limit-recovery.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-rate-limit-recovery.sh — レートリミット自動復旧 =====${NC}"
echo ""

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"

# ===== テスト環境セットアップ =====
PROJECT_ROOT="/tmp/test-rate-limit-recovery"
rm -rf "$PROJECT_ROOT"

mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"
mkdir -p "${PROJECT_ROOT}/.forge/schemas"
mkdir -p "${PROJECT_ROOT}/.claude/agents"

cp "${REAL_ROOT}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${REAL_ROOT}/.forge/lib/bootstrap.sh" "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"
cp "${REAL_ROOT}/.forge/config/circuit-breaker.json" "${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
cp "${REAL_ROOT}/.forge/config/development.json" "${PROJECT_ROOT}/.forge/config/development.json"

touch "${PROJECT_ROOT}/.forge/state/errors.jsonl"

# ===== グローバル変数設定 =====
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
TASK_EVENTS_FILE="${PROJECT_ROOT}/.forge/state/task-events.jsonl"
HEARTBEAT_FILE="${PROJECT_ROOT}/.forge/state/heartbeat.json"
LOOP_SIGNAL_FILE="${PROJECT_ROOT}/.forge/state/loop-signal"
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"
NOTIFY_DIR="${PROJECT_ROOT}/.forge/state/notifications"
PROGRESS_FILE="${PROJECT_ROOT}/.forge/state/progress.json"
METRICS_FILE="${PROJECT_ROOT}/.forge/state/metrics.jsonl"
VALIDATION_STATS_FILE="${PROJECT_ROOT}/.forge/state/validation-stats.jsonl"
WORK_DIR="$PROJECT_ROOT"
RESEARCH_DIR="test-rate-limit"
json_fail_count=0
CLAUDE_TIMEOUT=600
START_SECONDS=$SECONDS

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'; rm -rf '$PROJECT_ROOT'" EXIT

extract_all_functions_awk "$RALPH_SH" \
  detect_rate_limit_from_debug_logs recover_rate_limited_tasks \
  update_task_status update_heartbeat load_development_config \
  sync_task_stack \
  > "$EXTRACT_FILE"

source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} 関数抽出完了"
echo ""

# ===== モック定義 =====
notify_human() { :; }
sync_task_stack() { :; }
update_heartbeat() { :; }
# sleep をモック（テストで実際に待たない）
sleep() { :; }

# ===== 設定読み込み =====
load_development_config

# ===== フィクスチャヘルパー =====
create_task_stack() {
  cat > "$TASK_STACK" <<'FIXTURE'
{
  "tasks": [
    {
      "task_id": "task-a",
      "description": "Task A",
      "status": "blocked_investigation",
      "fail_count": 3,
      "dev_phase_id": "mvp",
      "validation": {"layer_1": {"command": "echo ok"}}
    },
    {
      "task_id": "task-b",
      "description": "Task B",
      "status": "completed",
      "fail_count": 0,
      "dev_phase_id": "mvp",
      "validation": {"layer_1": {"command": "echo ok"}}
    },
    {
      "task_id": "task-c",
      "description": "Task C",
      "status": "blocked_investigation",
      "fail_count": 2,
      "dev_phase_id": "core",
      "validation": {"layer_1": {"command": "echo ok"}}
    }
  ]
}
FIXTURE
}

# ===== テスト 1: blocked タスクなし → 復旧 0 =====
echo -e "${BOLD}--- テスト 1: blocked タスクなし ---${NC}"

cat > "$TASK_STACK" <<'EOF'
{"tasks":[{"task_id":"ok-1","status":"completed","fail_count":0},{"task_id":"ok-2","status":"pending","fail_count":0}]}
EOF

recover_rate_limited_tasks
status_after=$(jq -r '.tasks[1].status' "$TASK_STACK")
assert_eq "pending タスクは変更なし" "pending" "$status_after"

# ===== テスト 2: blocked + rate_limit 検出 → pending に復旧 =====
echo ""
echo -e "${BOLD}--- テスト 2: rate_limit 検出 → pending 復旧 ---${NC}"

create_task_stack
# レートリミットエラーのデバッグログを作成
echo "HTTP 429 Too Many Requests" > "${DEV_LOG_DIR}/impl-task-a-20260315-120000.log"
# task-events.jsonl を初期化
> "$TASK_EVENTS_FILE"

recover_rate_limited_tasks
status_a=$(jq -r '.tasks[] | select(.task_id=="task-a") | .status' "$TASK_STACK")
fail_a=$(jq -r '.tasks[] | select(.task_id=="task-a") | .fail_count' "$TASK_STACK")
recovery_a=$(jq -r '.tasks[] | select(.task_id=="task-a") | .rate_limit_recoveries // 0' "$TASK_STACK")

assert_eq "task-a: blocked_investigation → pending" "pending" "$status_a"
assert_eq "task-a: fail_count リセット" "0" "$fail_a"
assert_eq "task-a: rate_limit_recoveries = 1" "1" "$recovery_a"

# イベント記録確認
event_type=$(tail -1 "$TASK_EVENTS_FILE" 2>/dev/null | jq -r '.event // ""' || true)
assert_eq "rate_limit_recovery イベント記録" "rate_limit_recovery" "$event_type"

# ===== テスト 3: blocked + 非 rate_limit → 変更なし =====
echo ""
echo -e "${BOLD}--- テスト 3: 非 rate_limit → 変更なし ---${NC}"

create_task_stack
# レートリミットではないログ
echo "Normal execution completed successfully" > "${DEV_LOG_DIR}/impl-task-a-20260315-130000.log"
echo "Normal investigation" > "${DEV_LOG_DIR}/inv-task-a-20260315-130000.log"
# 古いレートリミットログを削除
rm -f "${DEV_LOG_DIR}/impl-task-a-20260315-120000.log"
> "$ERRORS_FILE"

recover_rate_limited_tasks
status_a=$(jq -r '.tasks[] | select(.task_id=="task-a") | .status' "$TASK_STACK")
assert_eq "非 rate_limit: status 変更なし" "blocked_investigation" "$status_a"

# ===== テスト 4: 復旧上限到達 → スキップ =====
echo ""
echo -e "${BOLD}--- テスト 4: 復旧上限到達 ---${NC}"

create_task_stack
# rate_limit_recoveries を上限に設定
jq '.tasks |= map(if .task_id == "task-a" then .rate_limit_recoveries = 2 else . end)' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
echo "429 rate limit exceeded" > "${DEV_LOG_DIR}/impl-task-a-20260315-140000.log"

recover_rate_limited_tasks
status_a=$(jq -r '.tasks[] | select(.task_id=="task-a") | .status' "$TASK_STACK")
assert_eq "上限到達: status 変更なし" "blocked_investigation" "$status_a"

# ===== テスト 5: rate_limit_recoveries インクリメント =====
echo ""
echo -e "${BOLD}--- テスト 5: recovery カウント増加 ---${NC}"

create_task_stack
# 既に1回復旧済み
jq '.tasks |= map(if .task_id == "task-a" then .rate_limit_recoveries = 1 else . end)' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
echo "429 Too Many Requests" > "${DEV_LOG_DIR}/impl-task-a-20260315-150000.log"
> "$TASK_EVENTS_FILE"

recover_rate_limited_tasks
recovery_a=$(jq -r '.tasks[] | select(.task_id=="task-a") | .rate_limit_recoveries // 0' "$TASK_STACK")
assert_eq "recoveries: 1 → 2" "2" "$recovery_a"

# ===== テスト 6: ENABLED=false → 復旧なし =====
echo ""
echo -e "${BOLD}--- テスト 6: 無効時はスキップ ---${NC}"

create_task_stack
echo "429 rate limit" > "${DEV_LOG_DIR}/impl-task-a-20260315-160000.log"
RATE_LIMIT_RECOVERY_ENABLED=false

recover_rate_limited_tasks
status_a=$(jq -r '.tasks[] | select(.task_id=="task-a") | .status' "$TASK_STACK")
assert_eq "ENABLED=false: status 変更なし" "blocked_investigation" "$status_a"

RATE_LIMIT_RECOVERY_ENABLED=true  # 戻す

# ===== テスト 7: detect_rate_limit — 429 in log → return 0 =====
echo ""
echo -e "${BOLD}--- テスト 7: detect_rate_limit (429 検出) ---${NC}"

echo "Error: 429 Too Many Requests" > "${DEV_LOG_DIR}/impl-test-detect-20260315-170000.log"
detect_rate_limit_from_debug_logs "test-detect"
result=$?
assert_eq "429 in log → return 0" "0" "$result"

# ===== テスト 8: detect_rate_limit — clean log → return 1 =====
echo ""
echo -e "${BOLD}--- テスト 8: detect_rate_limit (clean log) ---${NC}"

# test-clean 用のログをクリーンに
rm -f "${DEV_LOG_DIR}"/impl-test-clean-*.log "${DEV_LOG_DIR}"/inv-test-clean-*.log
echo "All tests passed successfully" > "${DEV_LOG_DIR}/impl-test-clean-20260315-180000.log"
> "$ERRORS_FILE"

detect_rate_limit_from_debug_logs "test-clean"
result=$?
assert_eq "clean log → return 1" "1" "$result"

# ===== テスト 9: classify_error_category "overloaded" → rate_limit =====
echo ""
echo -e "${BOLD}--- テスト 9: classify_error_category (overloaded) ---${NC}"

category=$(classify_error_category "API is overloaded, please retry" "")
assert_eq "overloaded → rate_limit" "rate_limit" "$category"

# ===== テスト 10: errors.jsonl フォールバック検出 =====
echo ""
echo -e "${BOLD}--- テスト 10: errors.jsonl フォールバック ---${NC}"

# ログファイルなし、errors.jsonl にレートリミットあり
rm -f "${DEV_LOG_DIR}"/impl-task-errlog-*.log "${DEV_LOG_DIR}"/inv-task-errlog-*.log
echo '{"stage":"implementer-task-errlog","message":"429","error_category":"rate_limit","timestamp":"2026-03-15T12:00:00+09:00"}' > "$ERRORS_FILE"

detect_rate_limit_from_debug_logs "task-errlog"
result=$?
assert_eq "errors.jsonl フォールバック → return 0" "0" "$result"

# ===== サマリー =====
print_test_summary
