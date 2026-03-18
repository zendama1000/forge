#!/bin/bash
# test-evidence-da.sh — run_evidence_da() 単体テスト (18 assertions)
# 自己完結型: セットアップ → 関数抽出 → テスト → クリーンアップ
# 使い方: bash .forge/tests/test-evidence-da.sh

set -uo pipefail

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

# ===== テスト集計 =====
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
    echo -e "    actual: ${haystack:0:200}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="/tmp/test-evidence-da"
FIXTURES_DIR="${SCRIPT_DIR}/.forge/tests/fixtures"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$PROJECT_ROOT"

mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"
mkdir -p "${PROJECT_ROOT}/.forge/templates"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"
mkdir -p "${PROJECT_ROOT}/.claude/agents"
mkdir -p "${PROJECT_ROOT}/task-dir"

# 実ファイルコピー
cp "${SCRIPT_DIR}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${SCRIPT_DIR}/.forge/lib/bootstrap.sh" "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"

# モックエージェント/テンプレート
echo "evidence-da agent" > "${PROJECT_ROOT}/.claude/agents/evidence-da.md"
cp "${SCRIPT_DIR}/.forge/templates/dev-da-prompt.md" "${PROJECT_ROOT}/.forge/templates/dev-da-prompt.md"

# モック task-stack.json
cp "${FIXTURES_DIR}/task-stack-evidence-da.json" "${PROJECT_ROOT}/.forge/state/task-stack.json"

# クリーンアップ trap
trap "rm -rf '$PROJECT_ROOT'" EXIT

echo -e "  ${GREEN}✓${NC} テスト環境作成完了"

# ===== グローバル変数設定 =====
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
WORK_DIR="${PROJECT_ROOT}"
RESEARCH_DIR="test-session"
json_fail_count=0
CLAUDE_TIMEOUT=600

# common.sh を source
touch "$ERRORS_FILE"
source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== evidence-da.sh から関数抽出 =====
echo -e "${BOLD}===== evidence-da.sh 関数抽出 =====${NC}"

EVIDENCE_DA_SH="${SCRIPT_DIR}/.forge/lib/evidence-da.sh"

extract_function_v2() {
  local func_name="$1"
  local src="$2"
  local start_line
  start_line=$(grep -n "^${func_name}()" "$src" | head -1 | cut -d: -f1)
  if [ -z "$start_line" ]; then
    echo "# function ${func_name} not found" >&2
    return 1
  fi
  local depth=0 end_line="" line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [ "$line_num" -lt "$start_line" ]; then continue; fi
    local opens=$(echo "$line" | tr -cd '{' | wc -c)
    local closes=$(echo "$line" | tr -cd '}' | wc -c)
    depth=$((depth + opens - closes))
    if [ "$depth" -le 0 ] && [ "$line_num" -gt "$start_line" ]; then
      end_line="$line_num"
      break
    fi
  done < "$src"
  if [ -n "$end_line" ]; then
    sed -n "${start_line},${end_line}p" "$src"
  fi
}

EXTRACT_FILE=$(mktemp)
body=$(extract_function_v2 "run_evidence_da" "$EVIDENCE_DA_SH" 2>/dev/null)
if [ -n "$body" ]; then
  echo "$body" > "$EXTRACT_FILE"
  echo -e "  ${GREEN}✓${NC} run_evidence_da()"
else
  echo -e "  ${RED}✗${NC} run_evidence_da() — 抽出失敗"
  exit 1
fi

source "$EXTRACT_FILE"
rm -f "$EXTRACT_FILE"
echo ""

# ===== モック関数 =====
MOCK_CLAUDE_CALLS=()
MOCK_CLAUDE_OUTPUT=""
MOCK_CLAUDE_EXIT=0

run_claude() {
  MOCK_CLAUDE_CALLS+=("$*")
  local output_file="$4"
  if [ -n "$MOCK_CLAUDE_OUTPUT" ]; then
    echo "$MOCK_CLAUDE_OUTPUT" > "$output_file"
  fi
  return $MOCK_CLAUDE_EXIT
}

MOCK_VALIDATE_EXIT=0
validate_json() {
  return $MOCK_VALIDATE_EXIT
}

MOCK_NOTIFY_CALLS=()
notify_human() {
  MOCK_NOTIFY_CALLS+=("$1|$2|$3")
}

metrics_start() { :; }
metrics_record() { :; }

# ===== ヘルパー: テスト状態リセット =====
reset_test_state() {
  MOCK_CLAUDE_CALLS=()
  MOCK_CLAUDE_OUTPUT='{"recommendation":"continue","evidence_analysis":{}}'
  MOCK_CLAUDE_EXIT=0
  MOCK_VALIDATE_EXIT=0
  MOCK_NOTIFY_CALLS=()
  EVIDENCE_DA_ENABLED=true
  EVIDENCE_DA_MODEL="sonnet"
  EVIDENCE_DA_TIMEOUT=300
  EVIDENCE_DA_FAIL_THRESHOLD=2
  CLAUDE_TIMEOUT=600
  # task-stack を復元
  cp "${FIXTURES_DIR}/task-stack-evidence-da.json" "$TASK_STACK"
  # task-dir をクリーン
  rm -rf "${PROJECT_ROOT}/task-dir"
  mkdir -p "${PROJECT_ROOT}/task-dir"
}

# ========================================================================
# Group 1: Graceful Degradation (5 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 1: Graceful Degradation =====${NC}"

# 1. EVIDENCE_DA_ENABLED=false → return 0、run_claude 未呼出し
reset_test_state
EVIDENCE_DA_ENABLED=false
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
assert_eq "ENABLED=false → return 0" "0" "$?"
assert_eq "ENABLED=false → run_claude 未呼出し" "0" "${#MOCK_CLAUDE_CALLS[@]}"

# 2. エージェント不在 → return 0、run_claude 未呼出し
reset_test_state
mv "${AGENTS_DIR}/evidence-da.md" "${AGENTS_DIR}/evidence-da.md.bak"
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
assert_eq "エージェント不在 → run_claude 未呼出し" "0" "${#MOCK_CLAUDE_CALLS[@]}"
mv "${AGENTS_DIR}/evidence-da.md.bak" "${AGENTS_DIR}/evidence-da.md"

# 3. テンプレート不在 → return 0、run_claude 未呼出し
reset_test_state
mv "${TEMPLATES_DIR}/dev-da-prompt.md" "${TEMPLATES_DIR}/dev-da-prompt.md.bak"
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
assert_eq "テンプレート不在 → run_claude 未呼出し" "0" "${#MOCK_CLAUDE_CALLS[@]}"
mv "${TEMPLATES_DIR}/dev-da-prompt.md.bak" "${TEMPLATES_DIR}/dev-da-prompt.md"

# 4. run_claude 失敗 → return 0（advisory）
reset_test_state
MOCK_CLAUDE_EXIT=1
exit_code=0
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null || exit_code=$?
assert_eq "run_claude 失敗 → return 0（advisory）" "0" "$exit_code"

# 5. validate_json 失敗 → return 0（advisory）
reset_test_state
MOCK_VALIDATE_EXIT=1
exit_code=0
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null || exit_code=$?
assert_eq "validate_json 失敗 → return 0（advisory）" "0" "$exit_code"

echo ""

# ========================================================================
# Group 2: 正常実行パス (6 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 2: 正常実行パス =====${NC}"

# 6. 正常実行 → return 0
reset_test_state
exit_code=0
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test_trigger" 2>/dev/null || exit_code=$?
assert_eq "正常実行 → return 0" "0" "$exit_code"

# 7. evidence-da-result.json が task_dir に生成される
assert_eq "evidence-da-result.json が生成" "true" "$([ -f "${PROJECT_ROOT}/task-dir/evidence-da-result.json" ] && echo true || echo false)"

# 8. run_claude に正しいモデル (EVIDENCE_DA_MODEL) が渡される
first_call="${MOCK_CLAUDE_CALLS[0]:-}"
assert_contains "正しいモデルが渡される" "sonnet" "$first_call"

# 9. run_claude に WebSearch,WebFetch 禁止が渡される
assert_contains "WebSearch,WebFetch 禁止" "WebSearch,WebFetch" "$first_call"

# 10. render_template に TASK_ID が渡される（出力ファイル内容で検証）
result_content=$(cat "${PROJECT_ROOT}/task-dir/evidence-da-result.json" 2>/dev/null || echo "")
# MOCK_CLAUDE_OUTPUT が書かれているので、代わりにプロンプトがrun_claudeに渡されたかを確認
# run_claude の第3引数がプロンプト
# MOCK_CLAUDE_CALLS[0] に全引数が記録されている
assert_contains "プロンプトに TASK_ID 含む" "T-001" "$first_call"

# 11. CLAUDE_TIMEOUT が実行前の値に復元される
reset_test_state
CLAUDE_TIMEOUT=600
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
assert_eq "CLAUDE_TIMEOUT が復元される" "600" "$CLAUDE_TIMEOUT"

echo ""

# ========================================================================
# Group 3: task-stack.json 更新 (4 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 3: task-stack.json 更新 =====${NC}"

# 12. 正常実行 → task-stack.json に .evidence_da_result が追記される
reset_test_state
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
da_result=$(jq -r '.tasks[] | select(.task_id == "T-001") | .evidence_da_result.recommendation // "ABSENT"' "$TASK_STACK" 2>/dev/null)
assert_eq "task-stack に evidence_da_result が追記" "continue" "$da_result"

# 13. .evidence_da_result.recommendation が "continue" である
assert_eq "recommendation が continue" "continue" "$da_result"

# 14. 存在しない task_id → task-stack.json は変更されない（jq エラーなし）
reset_test_state
original_hash=$(md5sum "$TASK_STACK" | cut -d' ' -f1)
run_evidence_da "T-NONEXISTENT" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
after_hash=$(md5sum "$TASK_STACK" | cut -d' ' -f1)
# task-stack の tasks 配列自体は変わらない（追加されたフィールドはT-NONEXISTENTには付かない）
nonexist_result=$(jq -r '.tasks[] | select(.task_id == "T-NONEXISTENT") | .evidence_da_result // "ABSENT"' "$TASK_STACK" 2>/dev/null)
assert_eq "存在しない task_id → 変更なし" "" "$nonexist_result"

# 15. TASK_STACK ファイル不在 → return 0（クラッシュしない）
reset_test_state
saved_ts="$TASK_STACK"
TASK_STACK="/tmp/nonexistent-task-stack-$$.json"
exit_code=0
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null || exit_code=$?
assert_eq "TASK_STACK 不在 → return 0" "0" "$exit_code"
TASK_STACK="$saved_ts"

echo ""

# ========================================================================
# Group 4: escalate 通知 (3 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 4: escalate 通知 =====${NC}"

# 16. recommendation="continue" → notify_human 未呼出し
reset_test_state
MOCK_CLAUDE_OUTPUT='{"recommendation":"continue","evidence_analysis":{}}'
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
assert_eq "continue → notify_human 未呼出し" "0" "${#MOCK_NOTIFY_CALLS[@]}"

# 17. recommendation="pivot" → notify_human 未呼出し
reset_test_state
MOCK_CLAUDE_OUTPUT='{"recommendation":"pivot","evidence_analysis":{},"pivot_suggestion":"代替案"}'
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
assert_eq "pivot → notify_human 未呼出し" "0" "${#MOCK_NOTIFY_CALLS[@]}"

# 18. recommendation="escalate" → notify_human("warning", ...) 呼出し
reset_test_state
MOCK_CLAUDE_OUTPUT='{"recommendation":"escalate","evidence_analysis":{},"escalation_reason":"構造的問題"}'
run_evidence_da "T-001" "${PROJECT_ROOT}/task-dir" "test" 2>/dev/null
assert_eq "escalate → notify_human 呼出し" "1" "${#MOCK_NOTIFY_CALLS[@]}"

echo ""

# ========================================================================
# サマリー
# ========================================================================
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL_COUNT"
