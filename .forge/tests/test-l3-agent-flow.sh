#!/bin/bash
# test-l3-agent-flow.sh — L3 strategy enum に agent_flow が追加されたことを検証する
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/test-helpers.sh"

TASK_STACK_SCHEMA="${PROJECT_ROOT}/.forge/schemas/task-stack.schema.json"
CRITERIA_SCHEMA="${PROJECT_ROOT}/.forge/schemas/criteria.schema.json"
DEVELOPMENT_SCHEMA="${PROJECT_ROOT}/.forge/schemas/development.schema.json"

echo ""
echo "=================================================="
echo " test-l3-agent-flow: L3 strategy enum 検証"
echo "=================================================="
echo ""

# ===== スキーマファイル存在確認 =====
echo "[前提確認] スキーマファイル存在チェック"

for f in "$TASK_STACK_SCHEMA" "$CRITERIA_SCHEMA" "$DEVELOPMENT_SCHEMA"; do
  if [ ! -f "$f" ]; then
    echo -e "  \033[0;31m✗\033[0m ファイルが存在しない: $f"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo -e "  \033[0;32m✓\033[0m ファイル存在: $(basename $f)"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
done

echo ""
echo "[Section 1] task-stack.schema.json — strategy enum 検証"

# behavior: jq で task-stack.schema.json の .properties.tasks.items.properties.validation.properties.layer_3.items.properties.strategy.enum を取得 → 配列に 'agent_flow' が含まれる
TASKSTACK_ENUM=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.strategy.enum[]' "$TASK_STACK_SCHEMA" 2>/dev/null | sort | tr '\n' ',')
assert_contains \
  "task-stack strategy.enum に 'agent_flow' が含まれる" \
  "agent_flow" \
  "$TASKSTACK_ENUM"

# behavior: task-stack の strategy enum の要素数をカウント → 6（structural, api_e2e, llm_judge, cli_flow, context_injection, agent_flow）
TASKSTACK_COUNT=$(jq '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.strategy.enum | length' "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "task-stack strategy.enum の要素数が 6" \
  "6" \
  "$TASKSTACK_COUNT"

# behavior: 既存5戦略の各値（structural, api_e2e, llm_judge, cli_flow, context_injection）が task-stack enum に残存 → 全て contains で true
for strategy in structural api_e2e llm_judge cli_flow context_injection; do
  FOUND=$(jq --arg s "$strategy" '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.strategy.enum | contains([$s])' "$TASK_STACK_SCHEMA" 2>/dev/null)
  assert_eq \
    "task-stack strategy.enum に既存戦略 '${strategy}' が残存する" \
    "true" \
    "$FOUND"
done

echo ""
echo "[Section 2] criteria.schema.json — strategy_type enum 検証"

# behavior: jq で criteria.schema.json の .properties.layer_3_criteria.items.properties.strategy_type.enum を取得 → 配列に 'agent_flow' が含まれる
CRITERIA_ENUM=$(jq -r '.properties.layer_3_criteria.items.properties.strategy_type.enum[]' "$CRITERIA_SCHEMA" 2>/dev/null | sort | tr '\n' ',')
assert_contains \
  "criteria strategy_type.enum に 'agent_flow' が含まれる" \
  "agent_flow" \
  "$CRITERIA_ENUM"

echo ""
echo "[Section 3] 両スキーマ enum 一致検証"

# behavior: 両スキーマの enum をソートして文字列化し比較 → 完全一致（agent_flow,api_e2e,cli_flow,context_injection,llm_judge,structural）
TASKSTACK_SORTED=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.strategy.enum[]' "$TASK_STACK_SCHEMA" 2>/dev/null | tr -d '\r' | sort | tr '\n' ',' | sed 's/,$//')
CRITERIA_SORTED=$(jq -r '.properties.layer_3_criteria.items.properties.strategy_type.enum[]' "$CRITERIA_SCHEMA" 2>/dev/null | tr -d '\r' | sort | tr '\n' ',' | sed 's/,$//')
EXPECTED_SORTED="agent_flow,api_e2e,cli_flow,context_injection,llm_judge,structural"

assert_eq \
  "task-stack strategy.enum のソート済み文字列が期待値と一致" \
  "$EXPECTED_SORTED" \
  "$TASKSTACK_SORTED"

assert_eq \
  "criteria strategy_type.enum のソート済み文字列が期待値と一致" \
  "$EXPECTED_SORTED" \
  "$CRITERIA_SORTED"

assert_eq \
  "両スキーマの enum が完全一致（ソート比較）" \
  "$TASKSTACK_SORTED" \
  "$CRITERIA_SORTED"

echo ""
echo "[Section 4] development.schema.json — layer_3 agent_flow フィールド存在検証"

# behavior: development.schema.json の layer_3 プロパティ内に agent_flow 関連フィールド定義が存在 → jq -e で true
for field in agent_flow_timeout max_agent_calls judge_model_coherence coherence_retry_count; do
  FIELD_TYPE=$(jq -r --arg f "$field" '.properties.layer_3.properties[$f].type // empty' "$DEVELOPMENT_SCHEMA" 2>/dev/null)
  if [ -n "$FIELD_TYPE" ]; then
    echo -e "  \033[0;32m✓\033[0m development.schema.json layer_3 に '${field}' フィールドが存在する (type: ${FIELD_TYPE})"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  \033[0;31m✗\033[0m development.schema.json layer_3 に '${field}' フィールドが存在しない"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

# jq -e による存在確認（required_behaviors: jq -e で true）
# set -e 対策: jq -e が false を返すと exit code 1 になるため || で捕捉
JQ_CHECK=$(jq -e '.properties.layer_3.properties | has("agent_flow_timeout") and has("max_agent_calls") and has("judge_model_coherence") and has("coherence_retry_count")' "$DEVELOPMENT_SCHEMA" 2>/dev/null) || JQ_CHECK="false"
assert_eq \
  "development.schema.json layer_3 に agent_flow 全関連フィールドが存在する (jq -e)" \
  "true" \
  "$JQ_CHECK"

echo ""
echo "[Section 5] 型定義検証（追加フィールドの type 確認）"

# agent_flow_timeout → number
AGENT_FLOW_TIMEOUT_TYPE=$(jq -r '.properties.layer_3.properties.agent_flow_timeout.type' "$DEVELOPMENT_SCHEMA" 2>/dev/null)
assert_eq \
  "development.schema.json layer_3.agent_flow_timeout の type が 'number'" \
  "number" \
  "$AGENT_FLOW_TIMEOUT_TYPE"

# max_agent_calls → number
MAX_AGENT_CALLS_TYPE=$(jq -r '.properties.layer_3.properties.max_agent_calls.type' "$DEVELOPMENT_SCHEMA" 2>/dev/null)
assert_eq \
  "development.schema.json layer_3.max_agent_calls の type が 'number'" \
  "number" \
  "$MAX_AGENT_CALLS_TYPE"

# judge_model_coherence → string
JUDGE_MODEL_COHERENCE_TYPE=$(jq -r '.properties.layer_3.properties.judge_model_coherence.type' "$DEVELOPMENT_SCHEMA" 2>/dev/null)
assert_eq \
  "development.schema.json layer_3.judge_model_coherence の type が 'string'" \
  "string" \
  "$JUDGE_MODEL_COHERENCE_TYPE"

# coherence_retry_count → number
COHERENCE_RETRY_COUNT_TYPE=$(jq -r '.properties.layer_3.properties.coherence_retry_count.type' "$DEVELOPMENT_SCHEMA" 2>/dev/null)
assert_eq \
  "development.schema.json layer_3.coherence_retry_count の type が 'number'" \
  "number" \
  "$COHERENCE_RETRY_COUNT_TYPE"

echo ""
echo "[Section 6] task-stack.schema.json — definition.properties サブスキーマ構造検証"

DEFINITION_BASE='.properties.tasks.items.properties.validation.properties.layer_3.items.properties.definition.properties'

# behavior: task-stack.schema.json の definition.properties に steps プロパティ（type: array）が存在 → jq -e で確認可能
STEPS_HAS=$(jq -e "${DEFINITION_BASE} | has(\"steps\")" "$TASK_STACK_SCHEMA" 2>/dev/null) || STEPS_HAS="false"
assert_eq \
  "definition.properties に steps プロパティが存在する (jq -e)" \
  "true" \
  "$STEPS_HAS"

STEPS_TYPE=$(jq -r "${DEFINITION_BASE}.steps.type" "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "steps の type が 'array'" \
  "array" \
  "$STEPS_TYPE"

# behavior: steps items に step_id（type: string）プロパティが存在し required 配列に含まれる → jq で required に 'step_id' が含まれることを確認
STEPS_STEPID_TYPE=$(jq -r "${DEFINITION_BASE}.steps.items.properties.step_id.type" "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "steps items に step_id プロパティ（type: string）が存在する" \
  "string" \
  "$STEPS_STEPID_TYPE"

STEPS_REQUIRED=$(jq -r "${DEFINITION_BASE}.steps.items.required[]" "$TASK_STACK_SCHEMA" 2>/dev/null | tr '\n' ',')
assert_contains \
  "steps items の required 配列に 'step_id' が含まれる" \
  "step_id" \
  "$STEPS_REQUIRED"

# behavior: steps items に prompt_template（type: string）プロパティが存在 → jq -e で確認
STEPS_PT_TYPE=$(jq -r "${DEFINITION_BASE}.steps.items.properties.prompt_template.type" "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "steps items に prompt_template プロパティ（type: string）が存在する" \
  "string" \
  "$STEPS_PT_TYPE"

# behavior: steps items に expected_outputs（type: array）、context_from_steps（type: array）、timeout_sec（type: number）プロパティが存在 → 各 jq -e で確認
STEPS_EO_TYPE=$(jq -r "${DEFINITION_BASE}.steps.items.properties.expected_outputs.type" "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "steps items に expected_outputs プロパティ（type: array）が存在する" \
  "array" \
  "$STEPS_EO_TYPE"

STEPS_CFS_TYPE=$(jq -r "${DEFINITION_BASE}.steps.items.properties.context_from_steps.type" "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "steps items に context_from_steps プロパティ（type: array）が存在する" \
  "array" \
  "$STEPS_CFS_TYPE"

STEPS_TIMEOUT_TYPE=$(jq -r "${DEFINITION_BASE}.steps.items.properties.timeout_sec.type" "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "steps items に timeout_sec プロパティ（type: number）が存在する" \
  "number" \
  "$STEPS_TIMEOUT_TYPE"

# behavior: definition.properties に coherence_checks プロパティ（type: array）が存在 → jq -e で確認
COHERENCE_HAS=$(jq -e "${DEFINITION_BASE} | has(\"coherence_checks\")" "$TASK_STACK_SCHEMA" 2>/dev/null) || COHERENCE_HAS="false"
assert_eq \
  "definition.properties に coherence_checks プロパティが存在する (jq -e)" \
  "true" \
  "$COHERENCE_HAS"

COHERENCE_TYPE=$(jq -r "${DEFINITION_BASE}.coherence_checks.type" "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "coherence_checks の type が 'array'" \
  "array" \
  "$COHERENCE_TYPE"

# behavior: coherence_checks items に source_step, target_step, check_type の3プロパティが存在 → jq で全プロパティキー確認
COHERENCE_PROPS=$(jq -e "${DEFINITION_BASE}.coherence_checks.items.properties | has(\"source_step\") and has(\"target_step\") and has(\"check_type\")" "$TASK_STACK_SCHEMA" 2>/dev/null) || COHERENCE_PROPS="false"
assert_eq \
  "coherence_checks items に source_step, target_step, check_type の3プロパティが存在する" \
  "true" \
  "$COHERENCE_PROPS"

# behavior: coherence_checks items の check_type に enum 定義（structural, semantic, hybrid）が存在 → jq で enum 配列取得し3要素確認
COHERENCE_ENUM_COUNT=$(jq "${DEFINITION_BASE}.coherence_checks.items.properties.check_type.enum | length" "$TASK_STACK_SCHEMA" 2>/dev/null)
assert_eq \
  "coherence_checks check_type enum の要素数が 3" \
  "3" \
  "$COHERENCE_ENUM_COUNT"

COHERENCE_ENUM=$(jq -r "${DEFINITION_BASE}.coherence_checks.items.properties.check_type.enum[]" "$TASK_STACK_SCHEMA" 2>/dev/null | sort | tr '\n' ',')
for val in structural semantic hybrid; do
  assert_contains \
    "coherence_checks check_type enum に '${val}' が含まれる" \
    "$val" \
    "$COHERENCE_ENUM"
done

# ===== Section 7: development.json 設定値 jq 直接確認 =====
echo ""
echo "[Section 7] development.json — layer_3 agent_flow 設定値検証"

DEV_JSON="${PROJECT_ROOT}/.forge/config/development.json"

# behavior: development.json の layer_3 に agent_flow_timeout=900 が定義されている → jq -r '.layer_3.agent_flow_timeout' で 900 を返す
AFT=$(jq -r '.layer_3.agent_flow_timeout' "$DEV_JSON" 2>/dev/null | tr -d '\r')
assert_eq \
  "development.json layer_3.agent_flow_timeout が 900" \
  "900" \
  "$AFT"

# behavior: development.json の layer_3 に max_agent_calls=30 が定義されている → jq -r '.layer_3.max_agent_calls' で 30 を返す
MAC=$(jq -r '.layer_3.max_agent_calls' "$DEV_JSON" 2>/dev/null | tr -d '\r')
assert_eq \
  "development.json layer_3.max_agent_calls が 30" \
  "30" \
  "$MAC"

# behavior: development.json の layer_3 に judge_model_coherence='sonnet' が定義されている → jq -r '.layer_3.judge_model_coherence' で sonnet を返す
JMC=$(jq -r '.layer_3.judge_model_coherence' "$DEV_JSON" 2>/dev/null | tr -d '\r')
assert_eq \
  "development.json layer_3.judge_model_coherence が sonnet" \
  "sonnet" \
  "$JMC"

# behavior: development.json の layer_3 に coherence_retry_count=1 が定義されている → jq -r '.layer_3.coherence_retry_count' で 1 を返す
CRC=$(jq -r '.layer_3.coherence_retry_count' "$DEV_JSON" 2>/dev/null | tr -d '\r')
assert_eq \
  "development.json layer_3.coherence_retry_count が 1" \
  "1" \
  "$CRC"

# ===== Section 8: load_l3_config() シェル変数設定検証 =====
echo ""
echo "[Section 8] load_l3_config() — シェル変数設定検証"

COMMON_SH="${PROJECT_ROOT}/.forge/lib/common.sh"
EXTRACT_TMP=$(mktemp)

extract_all_functions_awk "$COMMON_SH" \
  jq_safe \
  load_l3_config \
  > "$EXTRACT_TMP"

# shellcheck disable=SC1090
source "$EXTRACT_TMP"
rm -f "$EXTRACT_TMP"

# behavior: load_l3_config() 実行後に L3_AGENT_FLOW_TIMEOUT=900, L3_MAX_AGENT_CALLS=30, L3_JUDGE_MODEL_COHERENCE=sonnet, L3_COHERENCE_RETRY_COUNT=1 がシェル変数に設定される → assert_eq で検証
load_l3_config "$DEV_JSON"

assert_eq \
  "load_l3_config() 後 L3_AGENT_FLOW_TIMEOUT が 900" \
  "900" \
  "$L3_AGENT_FLOW_TIMEOUT"

assert_eq \
  "load_l3_config() 後 L3_MAX_AGENT_CALLS が 30" \
  "30" \
  "$L3_MAX_AGENT_CALLS"

assert_eq \
  "load_l3_config() 後 L3_JUDGE_MODEL_COHERENCE が sonnet" \
  "sonnet" \
  "$L3_JUDGE_MODEL_COHERENCE"

assert_eq \
  "load_l3_config() 後 L3_COHERENCE_RETRY_COUNT が 1" \
  "1" \
  "$L3_COHERENCE_RETRY_COUNT"

# ===== Section 9: load_l3_config() デフォルト値フォールバック検証 =====
echo ""
echo "[Section 9] load_l3_config() — 未定義フィールドのデフォルト値フォールバック"

MINIMAL_JSON=$(mktemp)
echo '{"layer_3": {"enabled": true}}' > "$MINIMAL_JSON"

# behavior: layer_3 に agent_flow_timeout が未定義の development.json を渡す → load_l3_config() がデフォルト値（L3_AGENT_FLOW_TIMEOUT=900）を設定する
load_l3_config "$MINIMAL_JSON"

assert_eq \
  "agent_flow_timeout 未定義時 L3_AGENT_FLOW_TIMEOUT がデフォルト 900" \
  "900" \
  "$L3_AGENT_FLOW_TIMEOUT"

assert_eq \
  "max_agent_calls 未定義時 L3_MAX_AGENT_CALLS がデフォルト 30" \
  "30" \
  "$L3_MAX_AGENT_CALLS"

assert_eq \
  "judge_model_coherence 未定義時 L3_JUDGE_MODEL_COHERENCE がデフォルト sonnet" \
  "sonnet" \
  "$L3_JUDGE_MODEL_COHERENCE"

assert_eq \
  "coherence_retry_count 未定義時 L3_COHERENCE_RETRY_COUNT がデフォルト 1" \
  "1" \
  "$L3_COHERENCE_RETRY_COUNT"

rm -f "$MINIMAL_JSON"

# ===== サマリー =====
print_test_summary
exit $?
