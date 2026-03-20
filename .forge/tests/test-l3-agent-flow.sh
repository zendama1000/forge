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

# ===== サマリー =====
print_test_summary
exit $?
