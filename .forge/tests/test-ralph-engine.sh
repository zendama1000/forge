#!/bin/bash
# test-ralph-engine.sh — Circuit Breaker + タスクライフサイクル テスト (28 assertions)
# ralph-loop.sh のタスクエンジン関数を抽出しテスト。
# 使い方: bash .forge/tests/test-ralph-engine.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-ralph-engine.sh — Circuit Breaker + タスクライフサイクル =====${NC}"
echo ""

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"
INVESTIGATION_SH="${REAL_ROOT}/.forge/lib/investigation.sh"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

# ===== テスト環境セットアップ =====
PROJECT_ROOT="/tmp/test-ralph-engine"
rm -rf "$PROJECT_ROOT"

mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"
mkdir -p "${PROJECT_ROOT}/.claude/agents"

cp "${REAL_ROOT}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${REAL_ROOT}/.forge/lib/bootstrap.sh" "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"
cp "${REAL_ROOT}/.forge/config/circuit-breaker.json" "${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
cp "${REAL_ROOT}/.forge/config/development.json" "${PROJECT_ROOT}/.forge/config/development.json"

touch "${PROJECT_ROOT}/.forge/state/errors.jsonl"
touch "${PROJECT_ROOT}/.forge/state/investigation-log.jsonl"

# ===== グローバル変数設定 =====
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
INVESTIGATION_LOG="${PROJECT_ROOT}/.forge/state/investigation-log.jsonl"
LOOP_SIGNAL_FILE="${PROJECT_ROOT}/.forge/state/loop-signal"
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"
WORK_DIR="$PROJECT_ROOT"
RESEARCH_DIR="test-engine"
NOTIFY_DIR="${PROJECT_ROOT}/.forge/state/notifications"
PROGRESS_FILE="${PROJECT_ROOT}/.forge/state/progress.json"
VALIDATION_STATS_FILE="${PROJECT_ROOT}/.forge/state/validation-stats.jsonl"
json_fail_count=0
CLAUDE_TIMEOUT=600

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'; rm -rf '$PROJECT_ROOT'" EXIT

extract_all_functions_awk "$RALPH_SH" \
  check_circuit_breakers get_next_task get_task_json \
  update_task_status update_task_fail_count count_tasks_by_status \
  handle_task_pass handle_task_fail load_development_config \
  sync_task_stack \
  > "$EXTRACT_FILE"

extract_all_functions_awk "$INVESTIGATION_SH" \
  check_loop_signal \
  >> "$EXTRACT_FILE"

source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} 関数抽出完了"
echo ""

# ===== 設定読み込み =====
load_development_config

# ===== モック定義 =====
run_claude() { :; }
INVESTIGATOR_CALLED=false
INVESTIGATOR_TASK_ID=""
run_investigator() {
  INVESTIGATOR_CALLED=true
  INVESTIGATOR_TASK_ID="${1:-}"
}
run_evidence_da() { :; }
run_approach_explorer() { :; }
notify_human() { :; }
sync_task_stack() { :; }

# ===== フィクスチャ読み込みヘルパー =====
reload_fixture() {
  cp "${FIXTURES_DIR}/task-stack-engine.json" "$TASK_STACK"
}

# ===== セッション変数初期化ヘルパー =====
reset_engine() {
  task_count=0
  investigation_count=0
  START_SECONDS=$SECONDS
  INVESTIGATOR_CALLED=false
  INVESTIGATOR_TASK_ID=""
  reload_fixture
}

# ========================================================================
# Part A: Circuit Breakers (14 assertions)
# ========================================================================
echo -e "${BOLD}===== Part A: Circuit Breakers =====${NC}"

# --- Group 1: task_count ブレーカー (3) ---
echo -e "${BOLD}--- Group 1: task_count ブレーカー ---${NC}"
reset_engine

# 1. task_count=0, MAX_TOTAL_TASKS=5 → return 1 (CONTINUE)
task_count=0
MAX_TOTAL_TASKS=5
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "task_count=0 → CONTINUE (return 1)" "1" "$ret"

# 2. task_count=5 → return 0 (BREAK)
task_count=5
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "task_count=5 → BREAK (return 0)" "0" "$ret"

# 3. task_count=10 → return 0 (BREAK)
task_count=10
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "task_count=10 → BREAK (return 0)" "0" "$ret"

echo ""

# --- Group 2: investigation_count ブレーカー (2) ---
echo -e "${BOLD}--- Group 2: investigation_count ブレーカー ---${NC}"
reset_engine
MAX_TOTAL_TASKS=999
MAX_DURATION_MINUTES=999

# 4. investigation_count=0, MAX_INVESTIGATIONS=3 → return 1
investigation_count=0
MAX_INVESTIGATIONS=3
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "investigation_count=0 → CONTINUE" "1" "$ret"

# 5. investigation_count=3 → return 0
investigation_count=3
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "investigation_count=3 → BREAK" "0" "$ret"

echo ""

# --- Group 3: duration ブレーカー (2) ---
echo -e "${BOLD}--- Group 3: duration ブレーカー ---${NC}"
reset_engine
MAX_TOTAL_TASKS=999
MAX_INVESTIGATIONS=999
MAX_DURATION_MINUTES=5

# 6. 開始直後 → return 1
START_SECONDS=$SECONDS
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "開始直後 → CONTINUE" "1" "$ret"

# 7. 上限超過 → return 0
START_SECONDS=$((SECONDS - (MAX_DURATION_MINUTES * 60 + 1)))
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "時間超過 → BREAK" "0" "$ret"

echo ""

# --- Group 4: blocked 過半数ブレーカー (3) ---
echo -e "${BOLD}--- Group 4: blocked 過半数ブレーカー ---${NC}"
reset_engine
MAX_TOTAL_TASKS=999
MAX_INVESTIGATIONS=999
MAX_DURATION_MINUTES=999
START_SECONDS=$SECONDS

# 8. 6タスク中 1 blocked → CONTINUE
# フィクスチャ: T-004 のみ blocked_investigation → 1/6
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "1/6 blocked → CONTINUE" "1" "$ret"

# 9. 4 blocked → BREAK (4*2=8 > 6)
jq '.tasks |= map(
  if .task_id == "T-002" or .task_id == "T-003" or .task_id == "T-006" then
    .status = "blocked_investigation"
  else . end
)' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "4/6 blocked → BREAK" "0" "$ret"

# 10. 3 blocked → CONTINUE (3*2=6, not > 6)
reload_fixture
jq '.tasks |= map(
  if .task_id == "T-002" or .task_id == "T-003" then
    .status = "blocked_investigation"
  else . end
)' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "3/6 blocked → CONTINUE" "1" "$ret"

echo ""

# --- Group 5: loop_signal ブレーカー (3) ---
echo -e "${BOLD}--- Group 5: loop_signal ブレーカー ---${NC}"
reset_engine
MAX_TOTAL_TASKS=999
MAX_INVESTIGATIONS=999
MAX_DURATION_MINUTES=999
START_SECONDS=$SECONDS

# 11. シグナルファイルなし → return 1
rm -f "$LOOP_SIGNAL_FILE"
check_circuit_breakers 2>/dev/null
ret=$?
assert_eq "シグナルなし → CONTINUE" "1" "$ret"

# 12. RESEARCH_REMAND → return 0, ファイル削除
echo "RESEARCH_REMAND" > "$LOOP_SIGNAL_FILE"
check_circuit_breakers 2>/dev/null
ret=$?
signal_exists="$([ -f "$LOOP_SIGNAL_FILE" ] && echo "yes" || echo "no")"
assert_eq "RESEARCH_REMAND → BREAK + 削除" "0:no" "${ret}:${signal_exists}"

# 13. APPROACH_PIVOT → return 0, ファイル削除
echo "APPROACH_PIVOT" > "$LOOP_SIGNAL_FILE"
check_circuit_breakers 2>/dev/null
ret=$?
signal_exists="$([ -f "$LOOP_SIGNAL_FILE" ] && echo "yes" || echo "no")"
assert_eq "APPROACH_PIVOT → BREAK + 削除" "0:no" "${ret}:${signal_exists}"

echo ""

# ========================================================================
# Part B: タスクライフサイクル (14 assertions)
# ========================================================================
echo -e "${BOLD}===== Part B: タスクライフサイクル =====${NC}"

# --- Group 6: count_tasks_by_status (3) ---
echo -e "${BOLD}--- Group 6: count_tasks_by_status ---${NC}"
reset_engine

# 14. completed → 1 (T-001)
result=$(count_tasks_by_status "completed")
assert_eq "completed → 1" "1" "$result"

# 15. pending → 3 (T-002, T-003, T-006)
result=$(count_tasks_by_status "pending")
assert_eq "pending → 3" "3" "$result"

# 16. failed → 1 (T-005)
result=$(count_tasks_by_status "failed")
assert_eq "failed → 1" "1" "$result"

echo ""

# --- Group 7: get_next_task 基本 (4) ---
echo -e "${BOLD}--- Group 7: get_next_task 基本 ---${NC}"
reset_engine
HAS_DEV_PHASES=false
CURRENT_DEV_PHASE=""

# 17. HAS_DEV_PHASES=false → T-002 (deps met: T-001 completed)
next=$(get_next_task)
assert_eq "phase フィルタなし → T-002" "T-002" "$next"

# 18. T-003 (depends_on T-002 = pending) → 返されない
# get_next_task は head -1 で最初の1件を返す。T-003 は依存未解決なので候補にならない。
# T-002 が最初に返されることで間接的に確認済み。
# 明示的に T-003 が候補に入らないことを確認:
all_candidates=$(jq_safe -r '
  . as $root |
  .tasks[] |
  select(.status == "pending" or .status == "failed") |
  select(.fail_count < 3) |
  . as $task |
  if (($task.depends_on // []) | length) == 0 then
    $task.task_id
  else
    if ([$task.depends_on[] | . as $dep |
      $root.tasks[] | select(.task_id == $dep) | .status] |
      all(. == "completed")) then
      $task.task_id
    else
      empty
    end
  end
' "$TASK_STACK" 2>/dev/null)
has_t003=$(echo "$all_candidates" | grep -c "T-003" || true)
assert_eq "T-003 (依存未解決) → 候補外" "0" "$has_t003"

# 19. T-004 (blocked_investigation) → 返されない
has_t004=$(echo "$all_candidates" | grep -c "T-004" || true)
assert_eq "T-004 (blocked) → 候補外" "0" "$has_t004"

# 20. T-005 (failed, fail_count=1 < MAX_TASK_RETRIES=3) → 候補に含まれる
has_t005=$(echo "$all_candidates" | grep -c "T-005" || true)
assert_eq "T-005 (failed, retryable) → 候補内" "1" "$has_t005"

echo ""

# --- Group 8: get_next_task phase フィルタ (3) ---
echo -e "${BOLD}--- Group 8: get_next_task phase フィルタ ---${NC}"
reset_engine
HAS_DEV_PHASES=true

# 21. CURRENT_DEV_PHASE="mvp" → mvp タスクのみ
CURRENT_DEV_PHASE="mvp"
next=$(get_next_task)
assert_eq "mvp フィルタ → T-002" "T-002" "$next"

# 22. CURRENT_DEV_PHASE="core" → T-005 (failed, core)
CURRENT_DEV_PHASE="core"
next=$(get_next_task)
assert_eq "core フィルタ → T-005 (failed)" "T-005" "$next"

# 23. CURRENT_DEV_PHASE="core" → T-006 は依存未解決で返されない
# T-006 depends_on T-003 which is pending → T-006 は候補外
# T-005 が唯一の候補 → next == T-005 で間接確認
# 明示的に全候補を確認:
core_candidates=$(jq_safe -r '
  . as $root |
  .tasks[] |
  select((.dev_phase_id // "mvp") == "core") |
  select(.status == "pending" or .status == "failed") |
  select(.fail_count < 3) |
  . as $task |
  if (($task.depends_on // []) | length) == 0 then
    $task.task_id
  else
    if ([$task.depends_on[] | . as $dep |
      $root.tasks[] | select(.task_id == $dep) | .status] |
      all(. == "completed")) then
      $task.task_id
    else
      empty
    end
  end
' "$TASK_STACK" 2>/dev/null)
has_t006=$(echo "$core_candidates" | grep -c "T-006" || true)
assert_eq "T-006 (依存未解決) → core 候補外" "0" "$has_t006"

echo ""

# --- Group 9: update_task_status (2) ---
echo -e "${BOLD}--- Group 9: update_task_status ---${NC}"
reset_engine

# 24. update_task_status "T-002" "completed" → status 更新確認
update_task_status "T-002" "completed" 2>/dev/null
t002_status=$(jq -r '.tasks[] | select(.task_id == "T-002") | .status' "$TASK_STACK")
assert_eq "T-002 → completed" "completed" "$t002_status"

# 25. update_task_status "T-004" "pending" → fail_count が 0 にリセット
reload_fixture
update_task_status "T-004" "pending" 2>/dev/null
t004_fc=$(jq '.tasks[] | select(.task_id == "T-004") | .fail_count' "$TASK_STACK")
t004_status=$(jq -r '.tasks[] | select(.task_id == "T-004") | .status' "$TASK_STACK")
assert_eq "T-004 → pending + fail_count=0" "pending:0" "${t004_status}:${t004_fc}"

echo ""

# --- Group 10: handle_task_pass / handle_task_fail (2) ---
echo -e "${BOLD}--- Group 10: handle_task_pass / handle_task_fail ---${NC}"
reset_engine

# 26. handle_task_pass "T-002" → status=completed
handle_task_pass "T-002" 2>/dev/null
t002_status=$(jq -r '.tasks[] | select(.task_id == "T-002") | .status' "$TASK_STACK")
assert_eq "handle_task_pass → completed" "completed" "$t002_status"

# 27. handle_task_fail を MAX_TASK_RETRIES 回実行 → run_investigator 呼出し確認
reload_fixture
INVESTIGATOR_CALLED=false
INVESTIGATOR_TASK_ID=""
# T-005: fail_count=1, MAX_TASK_RETRIES=3 → あと2回失敗で investigator 起動
task_dir="${DEV_LOG_DIR}/T-005"
mkdir -p "$task_dir"
# fail_count=1 → handle_task_fail で +1 = 2 (< 3)
handle_task_fail "T-005" "$task_dir" "error1" 2>/dev/null
# fail_count=2 → handle_task_fail で +1 = 3 (>= MAX_TASK_RETRIES) → investigator
handle_task_fail "T-005" "$task_dir" "error2" 2>/dev/null
assert_eq "MAX_TASK_RETRIES 到達 → investigator 呼出" "true:T-005" "${INVESTIGATOR_CALLED}:${INVESTIGATOR_TASK_ID}"

echo ""

# ===== クリーンアップ =====
# trap EXIT で実行

# ===== サマリー =====
print_test_summary
exit $?
