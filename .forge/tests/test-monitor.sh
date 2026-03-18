#!/bin/bash
# test-monitor.sh — monitor.sh 異常検出テスト
# 使い方: bash .forge/tests/test-monitor.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-monitor.sh — 異常検出モニター =====${NC}"
echo ""

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MONITOR_SH="${REAL_ROOT}/.forge/loops/monitor.sh"

# ===== テスト環境セットアップ =====
TEST_ROOT="/tmp/test-monitor"
rm -rf "$TEST_ROOT"

setup_test_env() {
  rm -rf "$TEST_ROOT"
  mkdir -p "${TEST_ROOT}/.forge/lib"
  mkdir -p "${TEST_ROOT}/.forge/config"
  mkdir -p "${TEST_ROOT}/.forge/state/notifications"
  mkdir -p "${TEST_ROOT}/.forge/loops"
  mkdir -p "${TEST_ROOT}/.forge/logs/development"

  cp "${REAL_ROOT}/.forge/lib/common.sh" "${TEST_ROOT}/.forge/lib/common.sh"
  cp "${REAL_ROOT}/.forge/lib/bootstrap.sh" "${TEST_ROOT}/.forge/lib/bootstrap.sh"
  cp "${REAL_ROOT}/.forge/config/circuit-breaker.json" "${TEST_ROOT}/.forge/config/circuit-breaker.json"
  cp "${REAL_ROOT}/.forge/config/development.json" "${TEST_ROOT}/.forge/config/development.json"

  # monitor.sh をテスト環境にコピー（bootstrap.sh が正しく動くように）
  cp "$MONITOR_SH" "${TEST_ROOT}/.forge/loops/monitor.sh"

  # 空ファイル初期化
  touch "${TEST_ROOT}/.forge/state/errors.jsonl"

  # スナップショットクリア
  rm -f "${TEST_ROOT}/.forge/state/monitor-snapshot.json"
}

run_monitor() {
  (cd "$TEST_ROOT" && bash "${TEST_ROOT}/.forge/loops/monitor.sh" "$@" 2>/dev/null)
}

trap "rm -rf '$TEST_ROOT'" EXIT

# ===== テスト 1: 状態ファイル不在 → not_running =====
echo -e "${BOLD}--- テスト 1: 未稼動検出 ---${NC}"

setup_test_env
result=$(run_monitor)
status=$(echo "$result" | jq -r '.status')
assert_eq "状態ファイルなし → not_running" "not_running" "$status"

# ===== テスト 2: 正常稼動 → ok =====
echo ""
echo -e "${BOLD}--- テスト 2: 正常稼動 ---${NC}"

setup_test_env

# progress.json
jq -n '{phase:"development",stage:"task-impl-foo",detail:"実行中",progress_pct:42,updated_at:"2026-03-15T12:00:00+09:00"}' \
  > "${TEST_ROOT}/.forge/state/progress.json"

# heartbeat.json（新鮮）
jq -n --arg ts "$(date -Iseconds)" \
  '{loop:"ralph",current_task:"t5",task_count:2,investigation_count:0,elapsed:"10m",heartbeat_at:$ts}' \
  > "${TEST_ROOT}/.forge/state/heartbeat.json"

# task-stack.json
jq -n '{tasks:[
  {task_id:"t1",status:"completed",fail_count:0},
  {task_id:"t2",status:"completed",fail_count:0},
  {task_id:"t3",status:"pending",fail_count:0},
  {task_id:"t4",status:"pending",fail_count:0},
  {task_id:"t5",status:"in_progress",fail_count:0}
]}' > "${TEST_ROOT}/.forge/state/task-stack.json"

# サーバーヘルスチェックを無効化（health_check_url を空に）
jq '.server.health_check_url = ""' "${TEST_ROOT}/.forge/config/development.json" \
  > "${TEST_ROOT}/.forge/config/development.json.tmp" && \
  mv "${TEST_ROOT}/.forge/config/development.json.tmp" "${TEST_ROOT}/.forge/config/development.json"

result=$(run_monitor)
status=$(echo "$result" | jq -r '.status')
summary=$(echo "$result" | jq -r '.summary')
assert_eq "正常稼動 → ok" "ok" "$status"
assert_contains "サマリーに完了数" "2/5" "$summary"

# ===== テスト 3: heartbeat 15分超 → heartbeat_stale =====
echo ""
echo -e "${BOLD}--- テスト 3: ハング検出 ---${NC}"

setup_test_env

jq -n '{phase:"development",stage:"task-impl-bar",detail:"実行中",progress_pct:50}' \
  > "${TEST_ROOT}/.forge/state/progress.json"

# 20分前のハートビート
old_ts=$(date -d "-20 minutes" -Iseconds 2>/dev/null || date -Iseconds)
jq -n --arg ts "$old_ts" \
  '{loop:"ralph",current_task:"impl-bar",task_count:3,investigation_count:0,elapsed:"40m",heartbeat_at:$ts}' \
  > "${TEST_ROOT}/.forge/state/heartbeat.json"

jq -n '{tasks:[{task_id:"t1",status:"completed",fail_count:0},{task_id:"t2",status:"in_progress",fail_count:0}]}' \
  > "${TEST_ROOT}/.forge/state/task-stack.json"

jq '.server.health_check_url = ""' "${TEST_ROOT}/.forge/config/development.json" \
  > "${TEST_ROOT}/.forge/config/development.json.tmp" && \
  mv "${TEST_ROOT}/.forge/config/development.json.tmp" "${TEST_ROOT}/.forge/config/development.json"

result=$(run_monitor)
status=$(echo "$result" | jq -r '.status')
anomaly_type=$(echo "$result" | jq -r '.anomalies[0].type // ""')
assert_eq "ハング → anomalies" "anomalies" "$status"
assert_eq "anomaly type = heartbeat_stale" "heartbeat_stale" "$anomaly_type"

# ===== テスト 4: blocked_investigation → anomaly + recoverable_action =====
echo ""
echo -e "${BOLD}--- テスト 4: blocked タスク検出 ---${NC}"

setup_test_env

jq -n '{phase:"development",stage:"task-impl-x",detail:"実行中",progress_pct:25}' \
  > "${TEST_ROOT}/.forge/state/progress.json"

jq -n --arg ts "$(date -Iseconds)" \
  '{loop:"ralph",current_task:"impl-x",heartbeat_at:$ts}' \
  > "${TEST_ROOT}/.forge/state/heartbeat.json"

jq -n '{tasks:[
  {task_id:"t1",status:"blocked_investigation",fail_count:3},
  {task_id:"t2",status:"completed",fail_count:0},
  {task_id:"t3",status:"pending",fail_count:0},
  {task_id:"t4",status:"pending",fail_count:0}
]}' > "${TEST_ROOT}/.forge/state/task-stack.json"

jq '.server.health_check_url = ""' "${TEST_ROOT}/.forge/config/development.json" \
  > "${TEST_ROOT}/.forge/config/development.json.tmp" && \
  mv "${TEST_ROOT}/.forge/config/development.json.tmp" "${TEST_ROOT}/.forge/config/development.json"

result=$(run_monitor)
status=$(echo "$result" | jq -r '.status')
has_blocked=$(echo "$result" | jq '[.anomalies[] | select(.type=="blocked_tasks")] | length')
has_recovery=$(echo "$result" | jq '.recoverable_actions | length')
assert_eq "blocked → anomalies" "anomalies" "$status"
assert_eq "blocked_tasks anomaly 存在" "1" "$has_blocked"
assert_eq "recoverable_action 存在" "1" "$has_recovery"

# ===== テスト 5: 全タスク completed → completed =====
echo ""
echo -e "${BOLD}--- テスト 5: 全完了検出 ---${NC}"

setup_test_env

jq -n '{phase:"development",stage:"done",detail:"完了",progress_pct:100}' \
  > "${TEST_ROOT}/.forge/state/progress.json"

jq -n --arg ts "$(date -Iseconds)" \
  '{loop:"ralph",current_task:"",heartbeat_at:$ts}' \
  > "${TEST_ROOT}/.forge/state/heartbeat.json"

jq -n '{tasks:[
  {task_id:"t1",status:"completed",fail_count:0},
  {task_id:"t2",status:"completed",fail_count:0},
  {task_id:"t3",status:"completed",fail_count:0}
]}' > "${TEST_ROOT}/.forge/state/task-stack.json"

jq '.server.health_check_url = ""' "${TEST_ROOT}/.forge/config/development.json" \
  > "${TEST_ROOT}/.forge/config/development.json.tmp" && \
  mv "${TEST_ROOT}/.forge/config/development.json.tmp" "${TEST_ROOT}/.forge/config/development.json"

result=$(run_monitor)
status=$(echo "$result" | jq -r '.status')
assert_eq "全完了 → completed" "completed" "$status"

# ===== テスト 6: フェーズ遷移検出 =====
echo ""
echo -e "${BOLD}--- テスト 6: フェーズ遷移 ---${NC}"

setup_test_env

# 前回のスナップショット
jq -n '{phase:"research",stage:"synthesizer",completed:0,total:5}' \
  > "${TEST_ROOT}/.forge/state/monitor-snapshot.json"

jq -n '{phase:"development",stage:"task-impl-a",detail:"実行中",progress_pct:10}' \
  > "${TEST_ROOT}/.forge/state/progress.json"

jq -n --arg ts "$(date -Iseconds)" \
  '{loop:"ralph",current_task:"impl-a",heartbeat_at:$ts}' \
  > "${TEST_ROOT}/.forge/state/heartbeat.json"

jq -n '{tasks:[
  {task_id:"t1",status:"completed",fail_count:0},
  {task_id:"t2",status:"pending",fail_count:0}
]}' > "${TEST_ROOT}/.forge/state/task-stack.json"

jq '.server.health_check_url = ""' "${TEST_ROOT}/.forge/config/development.json" \
  > "${TEST_ROOT}/.forge/config/development.json.tmp" && \
  mv "${TEST_ROOT}/.forge/config/development.json.tmp" "${TEST_ROOT}/.forge/config/development.json"

result=$(run_monitor)
has_phase_change=$(echo "$result" | jq '[.changes[] | select(.type=="phase_transition")] | length')
assert_eq "フェーズ遷移検出" "1" "$has_phase_change"

# ===== テスト 7: スナップショット作成 =====
echo ""
echo -e "${BOLD}--- テスト 7: スナップショット ---${NC}"

# テスト6で monitor を実行した後にスナップショットが存在するはず
assert_eq "スナップショットファイル生成" "true" "$([ -f "${TEST_ROOT}/.forge/state/monitor-snapshot.json" ] && echo true || echo false)"

snap_phase=$(jq -r '.phase' "${TEST_ROOT}/.forge/state/monitor-snapshot.json" 2>/dev/null || echo "")
assert_eq "スナップショット内容正確" "development" "$snap_phase"

# ===== テスト 8: 未確認通知検出 =====
echo ""
echo -e "${BOLD}--- テスト 8: 未確認通知 ---${NC}"

setup_test_env

jq -n '{phase:"development",stage:"task-impl-y",detail:"実行中",progress_pct:30}' \
  > "${TEST_ROOT}/.forge/state/progress.json"

jq -n --arg ts "$(date -Iseconds)" \
  '{loop:"ralph",current_task:"impl-y",heartbeat_at:$ts}' \
  > "${TEST_ROOT}/.forge/state/heartbeat.json"

jq -n '{tasks:[{task_id:"t1",status:"pending",fail_count:0}]}' \
  > "${TEST_ROOT}/.forge/state/task-stack.json"

# 未確認の critical 通知
jq -n '{id:"n-test",level:"critical",message:"Investigator上限到達",detail:"5/5",acknowledged:"false"}' \
  > "${TEST_ROOT}/.forge/state/notifications/n-test.json"

jq '.server.health_check_url = ""' "${TEST_ROOT}/.forge/config/development.json" \
  > "${TEST_ROOT}/.forge/config/development.json.tmp" && \
  mv "${TEST_ROOT}/.forge/config/development.json.tmp" "${TEST_ROOT}/.forge/config/development.json"

result=$(run_monitor)
has_notif=$(echo "$result" | jq '[.anomalies[] | select(.type=="unacked_notifications")] | length')
assert_eq "未確認通知検出" "1" "$has_notif"

# ===== サマリー =====
print_test_summary
