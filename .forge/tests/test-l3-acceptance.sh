#!/bin/bash
# test-l3-acceptance.sh — L3 受入テストインフラのユニットテスト
# 使い方: bash .forge/tests/test-l3-acceptance.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-l3-acceptance.sh — L3 受入テストインフラ =====${NC}"
echo ""

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"

# ===== テスト環境セットアップ =====
PROJECT_ROOT="/tmp/test-l3-acceptance"
rm -rf "$PROJECT_ROOT"

mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"
mkdir -p "${PROJECT_ROOT}/.claude/agents"
mkdir -p "${PROJECT_ROOT}/.forge/schemas"
mkdir -p "${PROJECT_ROOT}/work"

cp "${REAL_ROOT}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${REAL_ROOT}/.forge/lib/bootstrap.sh" "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"
cp "${REAL_ROOT}/.forge/config/circuit-breaker.json" "${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
cp "${REAL_ROOT}/.forge/config/development.json" "${PROJECT_ROOT}/.forge/config/development.json"
cp "${REAL_ROOT}/.forge/schemas/l3-judge.schema.json" "${PROJECT_ROOT}/.forge/schemas/l3-judge.schema.json"
cp "${REAL_ROOT}/.claude/agents/l3-judge.md" "${PROJECT_ROOT}/.claude/agents/l3-judge.md"

touch "${PROJECT_ROOT}/.forge/state/errors.jsonl"

# ===== グローバル変数設定 =====
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
WORK_DIR="${PROJECT_ROOT}/work"
RESEARCH_DIR="test-l3"
NOTIFY_DIR="${PROJECT_ROOT}/.forge/state/notifications"
PROGRESS_FILE="${PROJECT_ROOT}/.forge/state/progress.json"
VALIDATION_STATS_FILE="${PROJECT_ROOT}/.forge/state/validation-stats.jsonl"
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"
json_fail_count=0
CLAUDE_TIMEOUT=600

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'; rm -rf '$PROJECT_ROOT'" EXIT

extract_all_functions_awk "$RALPH_SH" \
  task_run_l3_test \
  > "$EXTRACT_FILE"

source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} 関数抽出完了"
echo ""

# ===== L3 設定読み込みテスト =====
echo -e "${BOLD}--- L3 設定読み込み ---${NC}"

load_l3_config "$DEV_CONFIG"

assert_eq "L3_ENABLED が true" "true" "$L3_ENABLED"
assert_eq "L3_JUDGE_MODEL が haiku" "haiku" "$L3_JUDGE_MODEL"
assert_eq "L3_JUDGE_TIMEOUT が 300" "300" "$L3_JUDGE_TIMEOUT"
assert_eq "L3_MAX_JUDGE_CALLS が 20" "20" "$L3_MAX_JUDGE_CALLS"
assert_eq "L3_DEFAULT_TIMEOUT が 120" "120" "$L3_DEFAULT_TIMEOUT"
assert_eq "L3_FAIL_CREATES_TASK が true" "true" "$L3_FAIL_CREATES_TASK"

echo ""

# ===== filter_l3_tests テスト =====
echo -e "${BOLD}--- filter_l3_tests ---${NC}"

TASK_WITH_L3='{
  "task_id": "test-task",
  "validation": {
    "layer_1": {"command": "echo ok", "expect": "exit 0"},
    "layer_3": [
      {"id": "L3-struct", "strategy": "structural", "description": "構造テスト", "definition": {"command": "echo ok"}},
      {"id": "L3-api", "strategy": "api_e2e", "description": "APIテスト", "definition": {"command": "curl http://localhost:3000"}, "requires": ["server"]},
      {"id": "L3-judge", "strategy": "llm_judge", "description": "品質テスト", "definition": {"command": "echo output", "judge_criteria": ["品質"], "success_threshold": 0.7}, "requires": ["server"]}
    ]
  }
}'

# immediate モード: サーバー不要テストのみ
immediate_tests=$(filter_l3_tests "$TASK_WITH_L3" "immediate")
immediate_count=$(echo "$immediate_tests" | jq 'length')
assert_eq "immediate フィルタで 1 件（structural のみ）" "1" "$immediate_count"

immediate_id=$(echo "$immediate_tests" | jq -r '.[0].id')
assert_eq "immediate の先頭が L3-struct" "L3-struct" "$immediate_id"

# server モード: サーバー依存テストのみ
server_tests=$(filter_l3_tests "$TASK_WITH_L3" "server")
server_count=$(echo "$server_tests" | jq 'length')
assert_eq "server フィルタで 2 件（api_e2e + llm_judge）" "2" "$server_count"

# L3 なしタスク
TASK_NO_L3='{"task_id": "no-l3", "validation": {"layer_1": {"command": "echo ok"}}}'
no_l3_tests=$(filter_l3_tests "$TASK_NO_L3" "immediate")
no_l3_count=$(echo "$no_l3_tests" | jq 'length')
assert_eq "L3 なしタスクで 0 件" "0" "$no_l3_count"

echo ""

# ===== execute_l3_structural テスト =====
echo -e "${BOLD}--- execute_l3_structural ---${NC}"

# 成功ケース: コマンドが 0 で終了
STRUCT_PASS='{"id":"L3-s1","strategy":"structural","definition":{"command":"echo hello"}}'
struct_result=$(execute_l3_structural "$STRUCT_PASS" "$WORK_DIR" 30 2>&1) && struct_exit=0 || struct_exit=$?
assert_eq "structural 成功 (echo hello)" "0" "$struct_exit"

# 失敗ケース: コマンドが非0で終了
STRUCT_FAIL='{"id":"L3-s2","strategy":"structural","definition":{"command":"false"}}'
struct_result=$(execute_l3_structural "$STRUCT_FAIL" "$WORK_DIR" 30 2>&1) && struct_exit=0 || struct_exit=$?
assert_eq "structural 失敗 (false コマンド)" "1" "$struct_exit"

# JSON 出力の必須フィールド検証
mkdir -p "$WORK_DIR"
cat > "${WORK_DIR}/test-struct.sh" << 'SCRIPT'
echo '{"name":"test","value":42}'
SCRIPT
chmod +x "${WORK_DIR}/test-struct.sh"

STRUCT_SCHEMA='{"id":"L3-s3","strategy":"structural","definition":{"command":"bash test-struct.sh","expected_schema":{"required":["name","value"]}}}'
struct_result=$(execute_l3_structural "$STRUCT_SCHEMA" "$WORK_DIR" 30 2>&1) && struct_exit=0 || struct_exit=$?
assert_eq "structural JSON スキーマ検証成功" "0" "$struct_exit"

# 必須フィールド不足
STRUCT_MISSING='{"id":"L3-s4","strategy":"structural","definition":{"command":"bash test-struct.sh","expected_schema":{"required":["name","missing_field"]}}}'
struct_result=$(execute_l3_structural "$STRUCT_MISSING" "$WORK_DIR" 30 2>&1) && struct_exit=0 || struct_exit=$?
assert_eq "structural 必須フィールド不足で失敗" "1" "$struct_exit"

# verify_command 成功
STRUCT_VERIFY='{"id":"L3-s5","strategy":"structural","definition":{"command":"echo ok","verify_command":"echo verified"}}'
struct_result=$(execute_l3_structural "$STRUCT_VERIFY" "$WORK_DIR" 30 2>&1) && struct_exit=0 || struct_exit=$?
assert_eq "structural verify_command 成功" "0" "$struct_exit"

# verify_command 失敗
STRUCT_VERIFY_FAIL='{"id":"L3-s6","strategy":"structural","definition":{"command":"echo ok","verify_command":"false"}}'
struct_result=$(execute_l3_structural "$STRUCT_VERIFY_FAIL" "$WORK_DIR" 30 2>&1) && struct_exit=0 || struct_exit=$?
assert_eq "structural verify_command 失敗" "1" "$struct_exit"

# command 未定義
STRUCT_NO_CMD='{"id":"L3-s7","strategy":"structural","definition":{}}'
struct_result=$(execute_l3_structural "$STRUCT_NO_CMD" "$WORK_DIR" 30 2>&1) && struct_exit=0 || struct_exit=$?
assert_eq "structural command 未定義で失敗" "1" "$struct_exit"

echo ""

# ===== execute_l3_api_e2e テスト =====
echo -e "${BOLD}--- execute_l3_api_e2e ---${NC}"

API_PASS='{"id":"L3-a1","strategy":"api_e2e","definition":{"command":"echo api_ok"}}'
api_result=$(execute_l3_api_e2e "$API_PASS" "$WORK_DIR" 30 2>&1) && api_exit=0 || api_exit=$?
assert_eq "api_e2e 成功" "0" "$api_exit"

API_FAIL='{"id":"L3-a2","strategy":"api_e2e","definition":{"command":"exit 1"}}'
api_result=$(execute_l3_api_e2e "$API_FAIL" "$WORK_DIR" 30 2>&1) && api_exit=0 || api_exit=$?
assert_eq "api_e2e 失敗" "1" "$api_exit"

API_NO_CMD='{"id":"L3-a3","strategy":"api_e2e","definition":{}}'
api_result=$(execute_l3_api_e2e "$API_NO_CMD" "$WORK_DIR" 30 2>&1) && api_exit=0 || api_exit=$?
assert_eq "api_e2e command 未定義で失敗" "1" "$api_exit"

echo ""

# ===== execute_l3_cli_flow テスト =====
echo -e "${BOLD}--- execute_l3_cli_flow ---${NC}"

CLI_PASS='{"id":"L3-c1","strategy":"cli_flow","definition":{"command":"echo flow_ok"}}'
cli_result=$(execute_l3_cli_flow "$CLI_PASS" "$WORK_DIR" 30 2>&1) && cli_exit=0 || cli_exit=$?
assert_eq "cli_flow 成功" "0" "$cli_exit"

CLI_FAIL='{"id":"L3-c2","strategy":"cli_flow","definition":{"command":"false"}}'
cli_result=$(execute_l3_cli_flow "$CLI_FAIL" "$WORK_DIR" 30 2>&1) && cli_exit=0 || cli_exit=$?
assert_eq "cli_flow 失敗" "1" "$cli_exit"

# verify_command 付き
touch "${WORK_DIR}/cli-output.txt"
CLI_VERIFY='{"id":"L3-c3","strategy":"cli_flow","definition":{"command":"echo done","verify_command":"test -f cli-output.txt"}}'
cli_result=$(execute_l3_cli_flow "$CLI_VERIFY" "$WORK_DIR" 30 2>&1) && cli_exit=0 || cli_exit=$?
assert_eq "cli_flow verify_command 成功" "0" "$cli_exit"

echo ""

# ===== execute_l3_context_injection テスト =====
echo -e "${BOLD}--- execute_l3_context_injection ---${NC}"

CTX_PASS='{"id":"L3-x1","strategy":"context_injection","definition":{"command":"echo injected"}}'
ctx_result=$(execute_l3_context_injection "$CTX_PASS" "$WORK_DIR" 30 2>&1) && ctx_exit=0 || ctx_exit=$?
assert_eq "context_injection 成功" "0" "$ctx_exit"

# context_file 検証
echo "context data" > "${WORK_DIR}/ctx-test.txt"
CTX_FILE='{"id":"L3-x2","strategy":"context_injection","definition":{"command":"echo ok","context_file":"ctx-test.txt"}}'
ctx_result=$(execute_l3_context_injection "$CTX_FILE" "$WORK_DIR" 30 2>&1) && ctx_exit=0 || ctx_exit=$?
assert_eq "context_injection context_file 存在で成功" "0" "$ctx_exit"

CTX_MISSING='{"id":"L3-x3","strategy":"context_injection","definition":{"command":"echo ok","context_file":"nonexistent.txt"}}'
ctx_result=$(execute_l3_context_injection "$CTX_MISSING" "$WORK_DIR" 30 2>&1) && ctx_exit=0 || ctx_exit=$?
assert_eq "context_injection context_file 不在で失敗" "1" "$ctx_exit"

echo ""

# ===== execute_l3_test ディスパッチャテスト =====
echo -e "${BOLD}--- execute_l3_test ディスパッチャ ---${NC}"

DISP_STRUCT='{"id":"L3-d1","strategy":"structural","definition":{"command":"echo dispatch_struct"}}'
disp_result=$(execute_l3_test "$DISP_STRUCT" "$WORK_DIR" 30 2>&1) && disp_exit=0 || disp_exit=$?
assert_eq "ディスパッチ: structural" "0" "$disp_exit"

DISP_API='{"id":"L3-d2","strategy":"api_e2e","definition":{"command":"echo dispatch_api"}}'
disp_result=$(execute_l3_test "$DISP_API" "$WORK_DIR" 30 2>&1) && disp_exit=0 || disp_exit=$?
assert_eq "ディスパッチ: api_e2e" "0" "$disp_exit"

DISP_CLI='{"id":"L3-d3","strategy":"cli_flow","definition":{"command":"echo dispatch_cli"}}'
disp_result=$(execute_l3_test "$DISP_CLI" "$WORK_DIR" 30 2>&1) && disp_exit=0 || disp_exit=$?
assert_eq "ディスパッチ: cli_flow" "0" "$disp_exit"

DISP_CTX='{"id":"L3-d4","strategy":"context_injection","definition":{"command":"echo dispatch_ctx"}}'
disp_result=$(execute_l3_test "$DISP_CTX" "$WORK_DIR" 30 2>&1) && disp_exit=0 || disp_exit=$?
assert_eq "ディスパッチ: context_injection" "0" "$disp_exit"

DISP_UNKNOWN='{"id":"L3-d5","strategy":"unknown_strategy","definition":{"command":"echo bad"}}'
disp_result=$(execute_l3_test "$DISP_UNKNOWN" "$WORK_DIR" 30 2>&1) && disp_exit=0 || disp_exit=$?
assert_eq "ディスパッチ: 不明戦略で失敗" "1" "$disp_exit"

echo ""

# ===== スキーマ検証テスト =====
echo -e "${BOLD}--- スキーマ整合性 ---${NC}"

# task-stack schema に layer_3 が定義されているか
TASK_STACK_SCHEMA="${REAL_ROOT}/.forge/schemas/task-stack.schema.json"
has_l3=$(jq -e '.properties.tasks.items.properties.validation.properties.layer_3' "$TASK_STACK_SCHEMA" > /dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "task-stack スキーマに layer_3 プロパティが存在" "yes" "$has_l3"

# criteria schema に strategy_type が定義されているか
CRITERIA_SCHEMA="${REAL_ROOT}/.forge/schemas/criteria.schema.json"
has_strategy=$(jq -e '.properties.layer_3_criteria.items.properties.strategy_type' "$CRITERIA_SCHEMA" > /dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "criteria スキーマに strategy_type プロパティが存在" "yes" "$has_strategy"

# development schema に layer_3 が定義されているか
DEV_SCHEMA="${REAL_ROOT}/.forge/schemas/development.schema.json"
has_l3_config=$(jq -e '.properties.layer_3' "$DEV_SCHEMA" > /dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "development スキーマに layer_3 プロパティが存在" "yes" "$has_l3_config"

# l3-judge schema が valid な JSON Schema か
JUDGE_SCHEMA="${REAL_ROOT}/.forge/schemas/l3-judge.schema.json"
jq empty "$JUDGE_SCHEMA" 2>/dev/null && judge_valid="0" || judge_valid="1"
assert_eq "l3-judge スキーマが valid JSON" "0" "$judge_valid"

# development.json に layer_3 設定があるか
DEV_JSON="${REAL_ROOT}/.forge/config/development.json"
has_l3_val=$(jq -r '.layer_3.enabled // "missing"' "$DEV_JSON" 2>/dev/null)
assert_eq "development.json に layer_3.enabled=true" "true" "$has_l3_val"

echo ""

# ===== L3 戦略 enum 整合性 =====
echo -e "${BOLD}--- 戦略 enum 整合性 ---${NC}"

# task-stack スキーマの enum
TS_ENUM=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.strategy.enum | sort | join(",")' "$TASK_STACK_SCHEMA" 2>/dev/null)
# criteria スキーマの enum
CR_ENUM=$(jq -r '.properties.layer_3_criteria.items.properties.strategy_type.enum | sort | join(",")' "$CRITERIA_SCHEMA" 2>/dev/null)

EXPECTED_ENUM="api_e2e,cli_flow,context_injection,llm_judge,structural"
assert_eq "task-stack スキーマの strategy enum" "$EXPECTED_ENUM" "$TS_ENUM"
assert_eq "criteria スキーマの strategy_type enum" "$EXPECTED_ENUM" "$CR_ENUM"
assert_eq "task-stack と criteria の戦略 enum が一致" "$TS_ENUM" "$CR_ENUM"

echo ""

# ===== エージェント定義検証 =====
echo -e "${BOLD}--- エージェント定義 ---${NC}"

L3_JUDGE_AGENT="${REAL_ROOT}/.claude/agents/l3-judge.md"
test -f "$L3_JUDGE_AGENT" && judge_exists="0" || judge_exists="1"
assert_eq "l3-judge.md エージェント定義が存在" "0" "$judge_exists"

grep -q "criterion" "$L3_JUDGE_AGENT" && has_criterion="0" || has_criterion="1"
assert_eq "l3-judge.md に criterion 記載あり" "0" "$has_criterion"

grep -q "overall_score" "$L3_JUDGE_AGENT" && has_score="0" || has_score="1"
assert_eq "l3-judge.md に overall_score 記載あり" "0" "$has_score"

echo ""

# ===== 結果サマリー =====
print_test_summary
