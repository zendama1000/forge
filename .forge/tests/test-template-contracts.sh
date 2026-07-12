#!/bin/bash
# test-template-contracts.sh — テンプレート/スキーマ/配線の契約検査（軽量・grep ベース）
# バッチ#7 で導入した生成系⇔実行系の契約が崩れていないことを機械的に固定する。
# 使い方: bash .forge/tests/test-template-contracts.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

check() {
  local label="$1" file="$2" pattern="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    pattern not found: ${pattern} in ${file}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

check_jq() {
  local label="$1" file="$2" expr="$3"
  if jq -e "$expr" "$file" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    jq expr failed: ${expr} in ${file}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

echo -e "${BOLD}===== [1] テンプレート契約 =====${NC}"
TP="${ROOT}/.forge/templates/task-planning-prompt.md"
check "task-planning: {{ENV_PROBE}} プレースホルダ" "$TP" '{{ENV_PROBE}}'
check "task-planning: strategy 適合マトリクス" "$TP" 'L3 strategy 適合マトリクス'
check "task-planning: 実効果スモーク必須" "$TP" '外部境界タスクの実効果スモーク'
check "task-planning: Walking Skeleton 手順" "$TP" 'Walking Skeleton 対応'
check "task-planning: replaces 配線検証ルール" "$TP" '配線検証（置換型タスク）'

CG="${ROOT}/.forge/templates/criteria-generation.md"
check "criteria-gen: {{ENV_PROBE}} プレースホルダ" "$CG" '{{ENV_PROBE}}'
check "criteria-gen: Walking Skeleton 必須節" "$CG" 'Walking Skeleton（必須'
check "criteria-gen: kind=walking_skeleton サンプル" "$CG" '"kind": "walking_skeleton"'
check "criteria-gen: browser strategy 条件" "$CG" 'browser'

IMPL="${ROOT}/.forge/templates/implementer-prompt.md"
check "implementer: スタブ偽装の禁止" "$IMPL" 'スタブ偽装の禁止'
check "implementer: テストダブルはテストコード内のみ" "$IMPL" 'テストコード内のみ'

QA="${ROOT}/.forge/templates/qa-evaluator-prompt.md"
check "qa-evaluator: スタブ偽装検査ルール" "$QA" 'スタブ偽装検査'
check "qa-evaluator: stub_suspected カテゴリ" "$QA" 'stub_suspected'

HANDOFF="${ROOT}/.forge/templates/phase4-handoff.md"
check "phase4-handoff: DEBT_SUMMARY" "$HANDOFF" '{{DEBT_SUMMARY}}'
check "phase4-handoff: DEFERRED_TESTS" "$HANDOFF" '{{DEFERRED_TESTS}}'

echo -e "\n${BOLD}===== [2] render 配線契約 =====${NC}"
GT="${ROOT}/.forge/loops/generate-tasks.sh"
check "generate-tasks: ENV_PROBE render ペア" "$GT" '"ENV_PROBE"'
check "generate-tasks: probe_env_capabilities 呼出" "$GT" 'probe_env_capabilities'
RL="${ROOT}/.forge/loops/research-loop.sh"
check "research-loop: ENV_PROBE render ペア" "$RL" '"ENV_PROBE"'

echo -e "\n${BOLD}===== [3] スキーマ契約 =====${NC}"
TS_SCHEMA="${ROOT}/.forge/schemas/task-stack.schema.json"
check_jq "task-stack: layer_2.requires 定義" "$TS_SCHEMA" '.properties.tasks.items.properties.validation.properties.layer_2.properties.requires'
check_jq "task-stack: layer_2.deferred 定義" "$TS_SCHEMA" '.properties.tasks.items.properties.validation.properties.layer_2.properties.deferred'
check_jq "task-stack: layer_3.deferred 定義" "$TS_SCHEMA" '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.deferred'
check_jq "task-stack: exit_criteria.kind (walking_skeleton)" "$TS_SCHEMA" '.properties.phases.items.properties.exit_criteria.items.properties.kind.enum | index("walking_skeleton")'
check_jq "task-stack: tasks.replaces 定義" "$TS_SCHEMA" '.properties.tasks.items.properties.replaces'
check_jq "task-stack: strategy enum に browser" "$TS_SCHEMA" '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.strategy.enum | index("browser")'

QA_SCHEMA="${ROOT}/.forge/schemas/qa-evaluator.schema.json"
check_jq "qa-evaluator: issues.category に stub_suspected" "$QA_SCHEMA" '.properties.issues.items.properties.category.enum | index("stub_suspected")'
check_jq "qa-evaluator: category に other（CD 逃げ道）" "$QA_SCHEMA" '.properties.issues.items.properties.category.enum | index("other")'

CR_SCHEMA="${ROOT}/.forge/schemas/criteria.schema.json"
check_jq "criteria: exit_criteria.kind 定義" "$CR_SCHEMA" '.properties.phases.items.properties.exit_criteria.items.properties.kind'

EC_SCHEMA="${ROOT}/.forge/schemas/env-capabilities.schema.json"
check_jq "env-capabilities: capability_tags 必須" "$EC_SCHEMA" '.required | index("capability_tags")'

# スキーマサイズ回帰ガード（task-stack はコマンドライン渡し — Windows 32K 制限）
size=$(wc -c < "$TS_SCHEMA" | tr -d ' ')
if [ "$size" -lt 20000 ]; then
  echo -e "  ${GREEN}✓${NC} task-stack.schema.json < 20KB (${size} bytes — コマンドライン長ガード)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} task-stack.schema.json が 20KB 超過 (${size} bytes)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo -e "\n${BOLD}===== [4] 実行系ゲート/ゲート配線契約 =====${NC}"
check "generate-tasks: L3 strategy enum ゲートに browser" "$GT" 'structural|api_e2e|llm_judge|cli_flow|context_injection|agent_flow|browser'
check "generate-tasks: validate_server_consistency 配線" "$GT" 'validate_server_consistency "\$OUTPUT_FILE"'
check "generate-tasks: validate_walking_skeleton 配線" "$GT" 'validate_walking_skeleton "\$OUTPUT_FILE"'
check "generate-tasks: validate_requires_satisfiable 配線" "$GT" 'run_plan_gate_with_retry validate_requires_satisfiable'
check "generate-tasks: validate_impl_test_commands 配線" "$GT" 'run_plan_gate_with_retry validate_impl_test_commands'
DP="${ROOT}/.forge/lib/dev-phases.sh"
check "dev-phases: ensure_server_running 配線" "$DP" 'ensure_server_running'
check "dev-phases: cd WORK_DIR で回帰実行" "$DP" 'cd "\$WORK_DIR" && bash "\$regression_script"'
P3="${ROOT}/.forge/lib/phase3.sh"
check "phase3: l3_fix_pending_duplicate 配線" "$P3" 'l3_fix_pending_duplicate'
check "phase3: is_environmental_failure 配線" "$P3" 'is_environmental_failure'
RALPH="${ROOT}/.forge/loops/ralph-loop.sh"
check "ralph-loop: quality-ledger source" "$RALPH" 'quality-ledger.sh'
check "ralph-loop: server-lifecycle source" "$RALPH" 'server-lifecycle.sh'
check "ralph-loop: l3fix セッション掃除" "$RALPH" 'contains("-l3fix-")'

# ===== 結果 =====
echo ""
echo -e "${BOLD}=========================================="
echo -e "  template-contracts テスト結果"
echo -e "==========================================${NC}"
echo -e "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}SOME TESTS FAILED${NC}"
  exit 1
fi
