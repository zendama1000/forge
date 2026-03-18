#!/bin/bash
# test-ralph-functions.sh — ralph-loop.sh の関数単体テスト
# 自己完結型: セットアップ → 関数抽出 → テスト → クリーンアップ
# 使い方: bash test-ralph-functions.sh

set -uo pipefail

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ===== テスト集計 =====
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
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

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RALPH_SH="${SCRIPT_DIR}/.forge/loops/ralph-loop.sh"
PROJECT_ROOT="/tmp/ralph-test"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

# クリーンスタート
rm -rf "$PROJECT_ROOT"

# ディレクトリ作成
mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/templates"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"
mkdir -p "${PROJECT_ROOT}/.forge/loops"
mkdir -p "${PROJECT_ROOT}/.claude/agents"

# 実ファイルコピー
cp "${SCRIPT_DIR}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${SCRIPT_DIR}/.forge/lib/bootstrap.sh" "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"
for libmod in mutation-audit.sh investigation.sh dev-phases.sh phase3.sh evidence-da.sh; do
  [ -f "${SCRIPT_DIR}/.forge/lib/${libmod}" ] && cp "${SCRIPT_DIR}/.forge/lib/${libmod}" "${PROJECT_ROOT}/.forge/lib/${libmod}"
done
cp "${SCRIPT_DIR}/.forge/config/mutation-audit.json" "${PROJECT_ROOT}/.forge/config/mutation-audit.json"
cp "${SCRIPT_DIR}/.forge/templates/implementer-prompt.md" "${PROJECT_ROOT}/.forge/templates/implementer-prompt.md"
cp "${SCRIPT_DIR}/.forge/templates/mutation-auditor-prompt.md" "${PROJECT_ROOT}/.forge/templates/mutation-auditor-prompt.md"
cp "${SCRIPT_DIR}/.forge/templates/implementer-strengthen-prompt.md" "${PROJECT_ROOT}/.forge/templates/implementer-strengthen-prompt.md"
cp "${SCRIPT_DIR}/.claude/agents/mutation-auditor.md" "${PROJECT_ROOT}/.claude/agents/mutation-auditor.md"
cp "${SCRIPT_DIR}/.forge/loops/mutation-runner.sh" "${PROJECT_ROOT}/.forge/loops/mutation-runner.sh"

# モック task-stack.json
cat > "${PROJECT_ROOT}/.forge/state/task-stack.json" << 'TASKSTACK'
{
  "phases": [
    {
      "id": "mvp",
      "name": "MVP",
      "mutation_survival_threshold": 0.50
    },
    {
      "id": "core",
      "name": "Core"
    },
    {
      "id": "polish",
      "name": "Polish"
    }
  ],
  "tasks": [
    {
      "task_id": "T-001",
      "task_type": "setup",
      "dev_phase_id": "mvp",
      "description": "プロジェクト初期セットアップ",
      "status": "completed"
    },
    {
      "task_id": "T-002",
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "required_behaviors": ["ユーザー作成 → 200"],
      "description": "MVP ユーザー作成API",
      "status": "pending",
      "validation": {
        "layer_1": {
          "command": "vitest run src/user.test.ts",
          "timeout_sec": 30
        }
      }
    },
    {
      "task_id": "T-003",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "required_behaviors": [
        "有効トークン → next()",
        "無効トークン → 401",
        "期限切れ → 401"
      ],
      "description": "認証ミドルウェア実装",
      "status": "pending",
      "validation": {
        "layer_1": {
          "command": "vitest run src/auth.test.ts",
          "timeout_sec": 30
        }
      }
    },
    {
      "task_id": "T-004",
      "task_type": "documentation",
      "dev_phase_id": "core",
      "description": "API ドキュメント",
      "status": "pending"
    },
    {
      "task_id": "T-005",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "旧フォーマットタスク（required_behaviors なし）",
      "status": "pending",
      "validation": {
        "layer_1": {
          "command": "vitest run src/old.test.ts",
          "timeout_sec": 30
        }
      }
    }
  ]
}
TASKSTACK

# 空ファイル
touch "${PROJECT_ROOT}/.forge/state/errors.jsonl"
touch "${PROJECT_ROOT}/.forge/state/investigation-log.jsonl"

echo -e "  ${GREEN}✓${NC} テスト環境作成完了"

# ===== グローバル変数設定 =====
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
MUTATION_AUDIT_CONFIG="${PROJECT_ROOT}/.forge/config/mutation-audit.json"
WORK_DIR="${PROJECT_ROOT}"
CRITERIA_FILE=""
RESEARCH_DIR="test-session"
json_fail_count=0
L1_DEFAULT_TIMEOUT=60
IMPLEMENTER_MODEL="sonnet"
IMPLEMENTER_TIMEOUT=600
CLAUDE_TIMEOUT=600
INVESTIGATION_LOG="${PROJECT_ROOT}/.forge/state/investigation-log.jsonl"

# common.sh を source（render_template 等を利用可能にする）
source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== ralph-loop.sh + lib モジュールから関数定義を抽出 =====
# 抽出対象の関数一覧
FUNCTIONS=(
  load_mutation_config
  should_run_mutation_audit
  get_survival_threshold
  build_mutation_auditor_prompt
  build_implementer_prompt
  run_test_strengthen
  run_mutation_audit
)

# 検索対象ファイル（ralph-loop.sh + 分割されたモジュール）
SEARCH_FILES=(
  "$RALPH_SH"
  "${SCRIPT_DIR}/.forge/lib/mutation-audit.sh"
  "${SCRIPT_DIR}/.forge/lib/investigation.sh"
  "${SCRIPT_DIR}/.forge/lib/dev-phases.sh"
  "${SCRIPT_DIR}/.forge/lib/phase3.sh"
  "${SCRIPT_DIR}/.forge/lib/evidence-da.sh"
)

# 行番号ベースで関数を抽出する（brace depth tracking）
extract_function_v2() {
  local func_name="$1"
  local src="$2"
  local start_line
  start_line=$(grep -n "^${func_name}()" "$src" | head -1 | cut -d: -f1)
  if [ -z "$start_line" ]; then
    echo "# function ${func_name} not found" >&2
    return 1
  fi
  local depth=0
  local end_line=""
  local line_num=0
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

# 全関数を一括でテンポラリファイルに抽出し、source する
# （eval より source の方がマルチライン文字列を含む関数定義に堅牢）
echo -e "${BOLD}===== ralph-loop.sh 関数抽出 =====${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'; rm -rf '$PROJECT_ROOT'" EXIT

extract_ok=true
for func in "${FUNCTIONS[@]}"; do
  body=""
  for src in "${SEARCH_FILES[@]}"; do
    [ -f "$src" ] || continue
    body=$(extract_function_v2 "$func" "$src" 2>/dev/null) && break
  done
  if [ -n "$body" ]; then
    echo "$body" >> "$EXTRACT_FILE"
    echo "" >> "$EXTRACT_FILE"
    echo -e "  ${GREEN}✓${NC} ${func}()"
  else
    echo -e "  ${RED}✗${NC} ${func}() — 抽出失敗"
    extract_ok=false
  fi
done

if [ "$extract_ok" = "false" ]; then
  echo -e "${RED}関数抽出に失敗しました。テスト中断。${NC}"
  exit 1
fi

# source で関数を定義（eval より安全）
source "$EXTRACT_FILE"
echo ""

# ===== テスト1: load_mutation_config =====
echo -e "${BOLD}===== Test: load_mutation_config =====${NC}"

# 正常系
MUTATION_AUDIT_ENABLED=""
load_mutation_config
assert_eq "enabled=true" "true" "$MUTATION_AUDIT_ENABLED"
assert_eq "skip_task_types" "setup,documentation" "$MUTATION_SKIP_TASK_TYPES"
assert_eq "error_rate_threshold" "0.40" "$MUTATION_ERROR_RATE_THRESHOLD"
assert_eq "max_plan_attempts" "2" "$MUTATION_MAX_PLAN_ATTEMPTS"
assert_eq "max_audit_attempts" "2" "$MUTATION_MAX_AUDIT_ATTEMPTS"
assert_eq "runner_timeout" "60" "$MUTATION_RUNNER_TIMEOUT"
assert_eq "model" "sonnet" "$MUTATION_MODEL"
assert_eq "auditor_timeout" "300" "$MUTATION_AUDITOR_TIMEOUT"

# config 不在時の降格
echo ""
echo -e "${BOLD}===== Test: load_mutation_config (config不在) =====${NC}"
mv "$MUTATION_AUDIT_CONFIG" "${MUTATION_AUDIT_CONFIG}.bak"
load_mutation_config 2>/dev/null
assert_eq "config不在 → enabled=false" "false" "$MUTATION_AUDIT_ENABLED"
mv "${MUTATION_AUDIT_CONFIG}.bak" "$MUTATION_AUDIT_CONFIG"

# 必須ファイル不在時の降格
echo ""
echo -e "${BOLD}===== Test: load_mutation_config (ファイル不在降格) =====${NC}"
mv "${TEMPLATES_DIR}/implementer-strengthen-prompt.md" "${TEMPLATES_DIR}/implementer-strengthen-prompt.md.bak"
load_mutation_config 2>/dev/null
assert_eq "テンプレート不在 → enabled=false" "false" "$MUTATION_AUDIT_ENABLED"
mv "${TEMPLATES_DIR}/implementer-strengthen-prompt.md.bak" "${TEMPLATES_DIR}/implementer-strengthen-prompt.md"

# 復元
load_mutation_config 2>/dev/null

# ===== テスト2: should_run_mutation_audit =====
echo ""
echo -e "${BOLD}===== Test: should_run_mutation_audit =====${NC}"

# Case 1: setup タスク → スキップ
task_json='{"task_type":"setup","dev_phase_id":"core","required_behaviors":["a"]}'
if should_run_mutation_audit "$task_json"; then
  assert_eq "setup タスク → スキップ" "skip" "run"
else
  assert_eq "setup タスク → スキップ" "skip" "skip"
fi

# Case 2: documentation タスク → スキップ
task_json='{"task_type":"documentation","dev_phase_id":"core","required_behaviors":["a"]}'
if should_run_mutation_audit "$task_json"; then
  assert_eq "documentation タスク → スキップ" "skip" "run"
else
  assert_eq "documentation タスク → スキップ" "skip" "skip"
fi

# Case 3: mvp implementation → スキップ (phase_config.mvp.enabled=false)
task_json='{"task_type":"implementation","dev_phase_id":"mvp","required_behaviors":["a","b"]}'
if should_run_mutation_audit "$task_json"; then
  assert_eq "mvp implementation → スキップ" "skip" "run"
else
  assert_eq "mvp implementation → スキップ" "skip" "skip"
fi

# Case 4: core implementation + behaviors あり → 実行
task_json='{"task_type":"implementation","dev_phase_id":"core","required_behaviors":["有効トークン → next()","無効トークン → 401"]}'
if should_run_mutation_audit "$task_json"; then
  assert_eq "core implementation + behaviors → 実行" "run" "run"
else
  assert_eq "core implementation + behaviors → 実行" "run" "skip"
fi

# Case 5: polish implementation + behaviors あり → 実行
task_json='{"task_type":"implementation","dev_phase_id":"polish","required_behaviors":["a"]}'
if should_run_mutation_audit "$task_json"; then
  assert_eq "polish implementation + behaviors → 実行" "run" "run"
else
  assert_eq "polish implementation + behaviors → 実行" "run" "skip"
fi

# Case 6: 旧フォーマット（required_behaviors なし）→ スキップ
task_json='{"task_type":"implementation","dev_phase_id":"core"}'
if should_run_mutation_audit "$task_json"; then
  assert_eq "旧フォーマット(behaviors なし) → スキップ" "skip" "run"
else
  assert_eq "旧フォーマット(behaviors なし) → スキップ" "skip" "skip"
fi

# Case 7: required_behaviors が空配列 → スキップ
task_json='{"task_type":"implementation","dev_phase_id":"core","required_behaviors":[]}'
if should_run_mutation_audit "$task_json"; then
  assert_eq "behaviors 空配列 → スキップ" "skip" "run"
else
  assert_eq "behaviors 空配列 → スキップ" "skip" "skip"
fi

# Case 8: グローバル無効時
MUTATION_AUDIT_ENABLED=false
task_json='{"task_type":"implementation","dev_phase_id":"core","required_behaviors":["a"]}'
if should_run_mutation_audit "$task_json"; then
  assert_eq "グローバル無効 → スキップ" "skip" "run"
else
  assert_eq "グローバル無効 → スキップ" "skip" "skip"
fi
MUTATION_AUDIT_ENABLED=true

# ===== テスト3: get_survival_threshold =====
echo ""
echo -e "${BOLD}===== Test: get_survival_threshold =====${NC}"

# task-stack.json に mutation_survival_threshold が定義されている mvp → 0.50
result=$(get_survival_threshold "mvp")
assert_eq "mvp (task-stack定義 0.50)" "0.50" "$result"

# task-stack.json に未定義の core → config フォールバック 0.30
result=$(get_survival_threshold "core")
assert_eq "core (config フォールバック 0.30)" "0.30" "$result"

# task-stack.json に未定義の polish → config フォールバック 0.20
result=$(get_survival_threshold "polish")
assert_eq "polish (config フォールバック 0.20)" "0.20" "$result"

# 未知の phase → core フォールバック
result=$(get_survival_threshold "unknown_phase")
assert_eq "unknown_phase (core フォールバック 0.30)" "0.30" "$result"

# ===== テスト4: build_implementer_prompt (REQUIRED_BEHAVIORS注入) =====
echo ""
echo -e "${BOLD}===== Test: build_implementer_prompt (REQUIRED_BEHAVIORS注入) =====${NC}"

task_json=$(jq '.tasks[] | select(.task_id == "T-003")' "$TASK_STACK")
prompt_output=$(build_implementer_prompt "$task_json" 2>/dev/null)

# REQUIRED_BEHAVIORS が注入されているか
if echo "$prompt_output" | grep -q "有効トークン → next()"; then
  assert_eq "behaviors[0] が注入されている" "found" "found"
else
  assert_eq "behaviors[0] が注入されている" "found" "not found"
fi

if echo "$prompt_output" | grep -q "無効トークン → 401"; then
  assert_eq "behaviors[1] が注入されている" "found" "found"
else
  assert_eq "behaviors[1] が注入されている" "found" "not found"
fi

if echo "$prompt_output" | grep -q "期限切れ → 401"; then
  assert_eq "behaviors[2] が注入されている" "found" "found"
else
  assert_eq "behaviors[2] が注入されている" "found" "not found"
fi

# {{REQUIRED_BEHAVIORS}} プレースホルダーが残っていないか
if echo "$prompt_output" | grep -q '{{REQUIRED_BEHAVIORS}}'; then
  assert_eq "{{REQUIRED_BEHAVIORS}} が残っていない" "replaced" "still_present"
else
  assert_eq "{{REQUIRED_BEHAVIORS}} が残っていない" "replaced" "replaced"
fi

# behaviors なしタスクの場合
task_json_old=$(jq '.tasks[] | select(.task_id == "T-005")' "$TASK_STACK")
prompt_old=$(build_implementer_prompt "$task_json_old" 2>/dev/null)
if echo "$prompt_old" | grep -q "required_behaviors 未定義"; then
  assert_eq "旧タスク → 未定義フォールバック" "fallback" "fallback"
else
  assert_eq "旧タスク → 未定義フォールバック" "fallback" "no_fallback"
fi

# ===== テスト5: build_mutation_auditor_prompt =====
echo ""
echo -e "${BOLD}===== Test: build_mutation_auditor_prompt =====${NC}"

# ダミーの implementation-output.txt を作成
task_dir="${DEV_LOG_DIR}/T-003"
mkdir -p "$task_dir"
touch "${task_dir}/implementation-output.txt"

task_json=$(jq '.tasks[] | select(.task_id == "T-003")' "$TASK_STACK")
auditor_prompt=$(build_mutation_auditor_prompt "T-003" "$task_dir" "$task_json" "" 2>/dev/null)

# TASK_ID が注入されているか
if echo "$auditor_prompt" | grep -q "タスクID: T-003"; then
  assert_eq "TASK_ID 注入" "found" "found"
else
  assert_eq "TASK_ID 注入" "found" "not found"
fi

# REQUIRED_BEHAVIORS が注入されているか
if echo "$auditor_prompt" | grep -q "有効トークン"; then
  assert_eq "REQUIRED_BEHAVIORS 注入" "found" "found"
else
  assert_eq "REQUIRED_BEHAVIORS 注入" "found" "not found"
fi

# TEST_COMMAND が注入されているか
if echo "$auditor_prompt" | grep -q "vitest run"; then
  assert_eq "TEST_COMMAND 注入" "found" "found"
else
  assert_eq "TEST_COMMAND 注入" "found" "not found"
fi

# previous_feedback ありの場合
auditor_prompt_fb=$(build_mutation_auditor_prompt "T-003" "$task_dir" "$task_json" "前回エラー率高" 2>/dev/null)
if echo "$auditor_prompt_fb" | grep -q "前回エラー率高"; then
  assert_eq "previous_feedback 注入" "found" "found"
else
  assert_eq "previous_feedback 注入" "found" "not found"
fi

# ===== テスト6: task-stack.json 連携（実タスクでの should_run 判定） =====
echo ""
echo -e "${BOLD}===== Test: task-stack連携テスト =====${NC}"

# T-001: setup → スキップ
t001=$(jq -c '.tasks[] | select(.task_id == "T-001")' "$TASK_STACK")
if should_run_mutation_audit "$t001"; then
  assert_eq "T-001 (setup) → スキップ" "skip" "run"
else
  assert_eq "T-001 (setup) → スキップ" "skip" "skip"
fi

# T-002: implementation + mvp + behaviors → スキップ (mvp OFF)
t002=$(jq -c '.tasks[] | select(.task_id == "T-002")' "$TASK_STACK")
if should_run_mutation_audit "$t002"; then
  assert_eq "T-002 (mvp impl) → スキップ" "skip" "run"
else
  assert_eq "T-002 (mvp impl) → スキップ" "skip" "skip"
fi

# T-003: implementation + core + behaviors → 実行
t003=$(jq -c '.tasks[] | select(.task_id == "T-003")' "$TASK_STACK")
if should_run_mutation_audit "$t003"; then
  assert_eq "T-003 (core impl + behaviors) → 実行" "run" "run"
else
  assert_eq "T-003 (core impl + behaviors) → 実行" "run" "skip"
fi

# T-004: documentation → スキップ
t004=$(jq -c '.tasks[] | select(.task_id == "T-004")' "$TASK_STACK")
if should_run_mutation_audit "$t004"; then
  assert_eq "T-004 (documentation) → スキップ" "skip" "run"
else
  assert_eq "T-004 (documentation) → スキップ" "skip" "skip"
fi

# T-005: 旧フォーマット → スキップ
t005=$(jq -c '.tasks[] | select(.task_id == "T-005")' "$TASK_STACK")
if should_run_mutation_audit "$t005"; then
  assert_eq "T-005 (旧フォーマット) → スキップ" "skip" "run"
else
  assert_eq "T-005 (旧フォーマット) → スキップ" "skip" "skip"
fi

# ===== テスト7: Mutation Audit Graceful Degradation =====
echo ""
echo -e "${BOLD}===== Test: Mutation Audit Graceful Degradation =====${NC}"

# run_mutation_audit のモックインフラ
# handle_task_pass をスパイ化
HANDLE_PASS_CALLS=()
_orig_handle_task_pass=$(type handle_task_pass 2>/dev/null || true)
handle_task_pass() {
  HANDLE_PASS_CALLS+=("$1")
}

# update_task_status / update_task_fail_count / count_tasks_by_status — スタブ
update_task_status() { :; }
update_task_fail_count() { :; }
update_progress() { :; }
sync_task_stack() { :; }
run_investigator() { :; }
run_evidence_da() { :; }
execute_layer1_test() { echo "OK"; return 0; }

# メトリクス関数スタブ
metrics_start() { :; }
metrics_record() { :; }

# テスト用タスク
_ma_task_json='{"task_id":"T-MA","task_type":"implementation","dev_phase_id":"core","required_behaviors":["a"],"validation":{"layer_1":{"command":"echo ok","timeout_sec":10}}}'
_ma_task_dir="${DEV_LOG_DIR}/T-MA"
mkdir -p "$_ma_task_dir"
touch "${_ma_task_dir}/implementation-output.txt"

# --- Case A: run_claude 失敗 → graceful degradation ---
echo -e "${BOLD}--- run_claude 失敗パス ---${NC}"

# run_claude を失敗モックに差替え
_saved_implementer_timeout="$IMPLEMENTER_TIMEOUT"
run_claude() { return 1; }
HANDLE_PASS_CALLS=()
CLAUDE_TIMEOUT="$MUTATION_AUDITOR_TIMEOUT"

run_mutation_audit "T-MA" "$_ma_task_dir" "$_ma_task_json" 2>/dev/null

# 28. run_claude 失敗 → handle_task_pass が呼ばれる
if [ "${#HANDLE_PASS_CALLS[@]}" -ge 1 ]; then
  assert_eq "run_claude失敗 → handle_task_pass 呼出" "called" "called"
else
  assert_eq "run_claude失敗 → handle_task_pass 呼出" "called" "not_called"
fi

# 29. handle_task_pass に正しい task_id が渡される
if [ "${#HANDLE_PASS_CALLS[@]}" -ge 1 ]; then
  assert_eq "handle_task_pass に T-MA が渡される" "T-MA" "${HANDLE_PASS_CALLS[0]}"
else
  assert_eq "handle_task_pass に T-MA が渡される" "T-MA" "no_calls"
fi

# 30. CLAUDE_TIMEOUT が IMPLEMENTER_TIMEOUT に復元される
assert_eq "CLAUDE_TIMEOUT 復元" "$_saved_implementer_timeout" "$CLAUDE_TIMEOUT"

echo ""

# --- Case B: validate_json 失敗 → graceful degradation ---
echo -e "${BOLD}--- validate_json 失敗パス ---${NC}"

# run_claude を成功モックに差替え
run_claude() {
  local model="$1" agent="$2" prompt="$3" output="$4"
  echo '{"mutations":[]}' > "${output}.pending"
  return 0
}

# validate_json を失敗モックに差替え
validate_json() { return 1; }

HANDLE_PASS_CALLS=()
CLAUDE_TIMEOUT="$MUTATION_AUDITOR_TIMEOUT"

# エラーログをファイルにキャプチャ（$(...)はサブシェルになりHANDLE_PASS_CALLSが失われるため）
_ma_log_file=$(mktemp)
run_mutation_audit "T-MA" "$_ma_task_dir" "$_ma_task_json" 2>"$_ma_log_file" >/dev/null
_ma_stderr=$(cat "$_ma_log_file")
rm -f "$_ma_log_file"

# 31. validate_json 失敗 → handle_task_pass が呼ばれる
if [ "${#HANDLE_PASS_CALLS[@]}" -ge 1 ]; then
  assert_eq "validate_json失敗 → handle_task_pass 呼出" "called" "called"
else
  assert_eq "validate_json失敗 → handle_task_pass 呼出" "called" "not_called"
fi

# 32. ログに "graceful degradation" が記録される
if echo "$_ma_stderr" | grep -qi "graceful degradation"; then
  assert_eq "ログに graceful degradation" "found" "found"
else
  assert_eq "ログに graceful degradation" "found" "not_found"
fi

# ===== 結果サマリー =====
echo ""
echo -e "${BOLD}========================================${NC}"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "${BOLD}========================================${NC}"

# クリーンアップは trap EXIT で実行
exit "$FAIL_COUNT"
