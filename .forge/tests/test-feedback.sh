#!/bin/bash
# test-feedback.sh — P0 キャリブレーション配管修復の end-to-end テスト
#
# 受入基準（ux-judgment-and-calibration-spec.md §2.3）:
#   □ completed → pending の手動変更が ralph-loop 1周相当で calibration-data.jsonl に記録される
#   □ feedback.sh 実行 → レコード追記 → 次回 evidence-da の実プロンプトに事例セクションが出現
#   □ dashboard.sh の出力に乖離率が表示される（0件時は警告）
#
# 使い方: bash .forge/tests/test-feedback.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:300}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== パス設定 =====
HARNESS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="/tmp/test-feedback-$$"

# ===== テスト環境セットアップ（実ファイルをコピーした隔離プロジェクト） =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/.forge/lib" "${TEST_ROOT}/.forge/loops" \
  "${TEST_ROOT}/.forge/state/notifications" "${TEST_ROOT}/.forge/state/.lock" \
  "${TEST_ROOT}/.forge/templates" "${TEST_ROOT}/.forge/logs/development" \
  "${TEST_ROOT}/.claude/agents"

cp "${HARNESS_ROOT}/.forge/lib/"*.sh "${TEST_ROOT}/.forge/lib/"
cp "${HARNESS_ROOT}/.forge/loops/feedback.sh" "${TEST_ROOT}/.forge/loops/"
cp "${HARNESS_ROOT}/.forge/loops/dashboard.sh" "${TEST_ROOT}/.forge/loops/"
cp "${HARNESS_ROOT}/.forge/templates/dev-da-prompt.md" "${TEST_ROOT}/.forge/templates/"
echo "evidence-da agent" > "${TEST_ROOT}/.claude/agents/evidence-da.md"

trap "rm -rf '$TEST_ROOT'" EXIT

# ===== グローバル変数（source する lib が参照） =====
PROJECT_ROOT="$TEST_ROOT"
TASK_STACK="${TEST_ROOT}/.forge/state/task-stack.json"
TASK_EVENTS_FILE="${TEST_ROOT}/.forge/state/task-events.jsonl"
DEV_LOG_DIR="${TEST_ROOT}/.forge/logs/development"
AGENTS_DIR="${TEST_ROOT}/.claude/agents"
TEMPLATES_DIR="${TEST_ROOT}/.forge/templates"
SCHEMAS_DIR="${HARNESS_ROOT}/.forge/schemas"
ERRORS_FILE="${TEST_ROOT}/.forge/state/errors.jsonl"
WORK_DIR="$TEST_ROOT"
RESEARCH_DIR="test-session"
json_fail_count=0
CLAUDE_TIMEOUT=600
touch "$ERRORS_FILE" "$TASK_EVENTS_FILE"

if ! source "${TEST_ROOT}/.forge/lib/common.sh"; then
  echo "FATAL: common.sh の source に失敗" >&2
  exit 1
fi
if ! source "${TEST_ROOT}/.forge/lib/calibration.sh"; then
  echo "FATAL: calibration.sh の source に失敗" >&2
  exit 1
fi
CALIBRATION_FILE="${TEST_ROOT}/.forge/state/calibration-data.jsonl"

echo -e "  ${GREEN}✓${NC} テスト環境作成完了"

# ===== update_task_status を ralph-loop.sh から抽出 =====
extract_function() {
  local func_name="$1" src="$2"
  local start_line
  start_line=$(grep -n "^${func_name}()" "$src" | head -1 | cut -d: -f1)
  [ -z "$start_line" ] && return 1
  awk -v s="$start_line" 'NR >= s { print; if (NR > s && /^}/) exit }' "$src"
}

EXTRACT_FILE=$(mktemp)
if ! extract_function "update_task_status" "${HARNESS_ROOT}/.forge/loops/ralph-loop.sh" > "$EXTRACT_FILE" \
  || ! grep -q '^update_task_status()' "$EXTRACT_FILE"; then
  echo "FATAL: update_task_status の抽出失敗" >&2
  exit 1
fi
# 依存スタブ（lock は簡略化、sync は no-op。record_task_event は common.sh の実物を使う）
acquire_lock() { return 0; }
release_lock() { :; }
sync_task_stack() { :; }
source "$EXTRACT_FILE"
rm -f "$EXTRACT_FILE"

# ========================================================================
# Group 1: 経路A — update_task_status 経由の completed → pending（P0-1）
# ========================================================================
echo -e "\n${BOLD}===== Group 1: 経路A（update_task_status 経由） =====${NC}"

cat > "$TASK_STACK" << 'JSON'
{
  "tasks": [
    {"task_id": "T-100", "status": "completed", "fail_count": 0,
     "created_at": "2026-07-01T00:00:00Z"}
  ]
}
JSON
# 完了時点のイベント履歴を再現
record_task_event "T-100" "status_changed" '{"new_status":"in_progress"}'
record_task_event "T-100" "status_changed" '{"new_status":"completed"}'

# 1. update_task_status が previous_status を記録する
update_task_status "T-100" "pending"
prev=$(jq -r '.tasks[0].previous_status // "ABSENT"' "$TASK_STACK")
assert_eq "previous_status が記録される" "completed" "$prev"
assert_eq "status が pending になる" "pending" "$(jq -r '.tasks[0].status' "$TASK_STACK")"

# 2. detect_reworked_tasks がキャリブレーション記録を生成する（evaluator 結果あり）
mkdir -p "${DEV_LOG_DIR}/T-100"
echo '{"recommendation":"continue","confidence":"high"}' > "${DEV_LOG_DIR}/T-100/evidence-da-result.json"
detect_reworked_tasks 2>/dev/null

assert_eq "calibration-data.jsonl が生成される" "true" \
  "$([ -f "$CALIBRATION_FILE" ] && echo true || echo false)"
rec_count=$(wc -l < "$CALIBRATION_FILE" | tr -d ' ')
assert_eq "記録は1件" "1" "$rec_count"
assert_contains "evidence-da の記録" '"evaluator":"evidence-da"' "$(cat "$CALIBRATION_FILE")"
assert_eq "previous_status がクリアされる" "ABSENT" \
  "$(jq -r '.tasks[0].previous_status // "ABSENT"' "$TASK_STACK")"

# 3. 再実行しても重複記録されない
detect_reworked_tasks 2>/dev/null
rec_count=$(wc -l < "$CALIBRATION_FILE" | tr -d ' ')
assert_eq "再実行で重複記録なし" "1" "$rec_count"

# ========================================================================
# Group 2: 経路B — raw jq で .status のみ手動変更（受入基準①の実運用経路）
# ========================================================================
echo -e "\n${BOLD}===== Group 2: 経路B（raw jq 手動変更） =====${NC}"

rm -f "$CALIBRATION_FILE" "$TASK_EVENTS_FILE"
touch "$TASK_EVENTS_FILE"
cat > "$TASK_STACK" << 'JSON'
{
  "tasks": [
    {"task_id": "T-200", "status": "completed", "fail_count": 0,
     "created_at": "2026-07-01T00:00:00Z"},
    {"task_id": "T-300", "status": "pending", "fail_count": 0,
     "created_at": "2026-07-01T00:00:00Z"}
  ]
}
JSON
record_task_event "T-200" "status_changed" '{"new_status":"in_progress"}'
record_task_event "T-200" "status_changed" '{"new_status":"completed"}'

mkdir -p "${DEV_LOG_DIR}/T-200"
echo '{"verdict":"pass","confidence":"high"}' > "${DEV_LOG_DIR}/T-200/qa-evaluator-result.json"

# 人間の手動復旧手順そのまま: .status のみ書き換え（previous_status は書かれない）
jq '(.tasks[] | select(.task_id=="T-200")).status = "pending"' "$TASK_STACK" \
  > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"

detect_reworked_tasks 2>/dev/null

assert_eq "手動変更でも記録される（経路B）" "true" \
  "$([ -f "$CALIBRATION_FILE" ] && [ -s "$CALIBRATION_FILE" ] && echo true || echo false)"
assert_contains "qa-evaluator の記録" '"evaluator":"qa-evaluator"' "$(cat "$CALIBRATION_FILE" 2>/dev/null)"
assert_contains "correct_judgment は fail" '"correct_judgment":"fail"' "$(cat "$CALIBRATION_FILE" 2>/dev/null)"
assert_not_contains "未完了タスク T-300 は記録されない" "T-300" "$(cat "$CALIBRATION_FILE" 2>/dev/null)"

# 再実行で重複しない（rework_detected マーカー）
detect_reworked_tasks 2>/dev/null
rec_count=$(wc -l < "$CALIBRATION_FILE" | tr -d ' ')
assert_eq "経路B 再実行で重複記録なし" "1" "$rec_count"

# ========================================================================
# Group 3: feedback.sh CLI（P0-2）
# ========================================================================
echo -e "\n${BOLD}===== Group 3: feedback.sh CLI =====${NC}"

rm -f "$CALIBRATION_FILE"
cat > "$TASK_STACK" << 'JSON'
{
  "tasks": [
    {"task_id": "T-400", "status": "completed", "fail_count": 0,
     "created_at": "2026-07-01T00:00:00Z"}
  ]
}
JSON
mkdir -p "${DEV_LOG_DIR}/T-400"
echo '{"recommendation":"continue","confidence":"high"}' > "${DEV_LOG_DIR}/T-400/evidence-da-result.json"
echo '{"verdict":"pass","confidence":"medium"}' > "${DEV_LOG_DIR}/T-400/qa-evaluator-result.json"
# 完了時点のイベント履歴（feedback.sh 後の detect 重複防止マーカーを検証するため）
record_task_event "T-400" "status_changed" '{"new_status":"completed"}'

# ux_disagreement 債務を仕込む（裁定で解消されることを検証）
cat > "${TEST_ROOT}/.forge/state/quality-debts.jsonl" << 'JSON'
{"id":"qd-test-1","type":"ux_disagreement","task_id":"T-400","detail":"チャネル不一致","resolved":false}
JSON

out=$(bash "${TEST_ROOT}/.forge/loops/feedback.sh" "T-400" "reject" "UI が使いにくい" 2>/dev/null)
assert_contains "記録件数が表示される" "2 件" "$out"
assert_eq "2件記録される" "2" "$(wc -l < "$CALIBRATION_FILE" | tr -d ' ')"
assert_contains "evidence-da 記録" '"evaluator":"evidence-da"' "$(cat "$CALIBRATION_FILE")"
assert_contains "qa-evaluator 記録" '"evaluator":"qa-evaluator"' "$(cat "$CALIBRATION_FILE")"
assert_contains "理由が記録される" "UI が使いにくい" "$(cat "$CALIBRATION_FILE")"
assert_eq "reject でタスクが pending に差戻される" "pending" \
  "$(jq -r '.tasks[0].status' "$TASK_STACK")"
assert_eq "ux_disagreement 債務が解消される" "true" \
  "$(jq -s -r '.[0].resolved' "${TEST_ROOT}/.forge/state/quality-debts.jsonl")"

# feedback.sh の後に detect が走っても重複しない（rework_detected マーカー）
detect_reworked_tasks 2>/dev/null
assert_eq "feedback.sh 後の detect で重複なし" "2" "$(wc -l < "$CALIBRATION_FILE" | tr -d ' ')"

# evaluator 結果なし → human-direct 記録
rm -f "$CALIBRATION_FILE"
cat > "$TASK_STACK" << 'JSON'
{"tasks": [{"task_id": "T-500", "status": "completed", "fail_count": 0}]}
JSON
out=$(bash "${TEST_ROOT}/.forge/loops/feedback.sh" "T-500" "reject" "動かない" --no-requeue 2>/dev/null)
assert_contains "human-direct として記録される" '"evaluator":"human-direct"' "$(cat "$CALIBRATION_FILE")"
assert_eq "--no-requeue で差戻しされない" "completed" "$(jq -r '.tasks[0].status' "$TASK_STACK")"

# accept-with-notes → 乖離なし記録・差戻しなし
rm -f "$CALIBRATION_FILE"
cat > "$TASK_STACK" << 'JSON'
{"tasks": [{"task_id": "T-400", "status": "completed", "fail_count": 0}]}
JSON
out=$(bash "${TEST_ROOT}/.forge/loops/feedback.sh" "T-400" "accept-with-notes" "配色は今後改善余地" 2>/dev/null)
assert_contains "accept-with-notes: correct は評価器自身の判定" '"correct_judgment":"continue"' \
  "$(grep '"evaluator":"evidence-da"' "$CALIBRATION_FILE")"
assert_eq "accept-with-notes は差戻ししない" "completed" "$(jq -r '.tasks[0].status' "$TASK_STACK")"

# 不正 verdict → exit 非0
bash "${TEST_ROOT}/.forge/loops/feedback.sh" "T-400" "bogus" "x" > /dev/null 2>&1
assert_eq "不正 verdict は exit 非0" "1" "$?"

# ========================================================================
# Group 4: Few-Shot 注入 e2e（受入基準② — 実プロンプトに事例が出現）
# ========================================================================
echo -e "\n${BOLD}===== Group 4: evidence-da プロンプトへの Few-Shot 注入 =====${NC}"

# feedback.sh の記録が存在する状態（Group 3 最後の accept-with-notes + 追加 reject）
record_feedback_for_task "T-400" "reject" "エッジケースで壊れる" > /dev/null 2>&1

# evidence-da.sh を実物 source し、run_claude だけ差し替えてプロンプトをキャプチャ
source "${TEST_ROOT}/.forge/lib/evidence-da.sh"
CAPTURED_PROMPT_FILE="${TEST_ROOT}/captured-prompt.txt"
run_claude() {
  printf '%s' "$3" > "$CAPTURED_PROMPT_FILE"
  echo '{"recommendation":"continue"}' > "$4"
  return 0
}
validate_json() { return 0; }
metrics_start() { :; }
metrics_record() { :; }
notify_human() { :; }
EVIDENCE_DA_ENABLED=true
EVIDENCE_DA_MODEL="sonnet"
EVIDENCE_DA_TIMEOUT=300

mkdir -p "${TEST_ROOT}/task-dir"
run_evidence_da "T-400" "${TEST_ROOT}/task-dir" "test_trigger" 2>/dev/null

captured=$(cat "$CAPTURED_PROMPT_FILE" 2>/dev/null || echo "")
assert_contains "実プロンプトに事例セクションが出現" "キャリブレーション事例" "$captured"
assert_contains "実プロンプトに記録済みタスクが出現" "T-400" "$captured"
assert_contains "実プロンプトに人間の理由が出現" "エッジケースで壊れる" "$captured"

# ========================================================================
# Group 5: dashboard.sh の乖離率表示（受入基準③）
# ========================================================================
echo -e "\n${BOLD}===== Group 5: dashboard.sh 表示 =====${NC}"

# 0件時: 警告表示
rm -f "$CALIBRATION_FILE"
dash_out=$(cd "$TEST_ROOT" && bash "${TEST_ROOT}/.forge/loops/dashboard.sh" 2>/dev/null || true)
assert_contains "0件時に無較正警告" "較正データ0件" "$dash_out"

# 記録あり: 乖離率表示（T-400 は evaluator 結果ありのため evidence-da/qa-evaluator で記録される）
record_feedback_for_task "T-400" "reject" "表示確認用" > /dev/null 2>&1
dash_out=$(cd "$TEST_ROOT" && bash "${TEST_ROOT}/.forge/loops/dashboard.sh" 2>/dev/null || true)
assert_contains "乖離率セクションが表示される" "乖離率" "$dash_out"
assert_contains "evaluator 別表示" "evidence-da:" "$dash_out"

# ========================================================================
# サマリー
# ========================================================================
echo ""
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL_COUNT"
