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
# batch#10 Stage4: Planner はゴールと制約のみ。strategy マトリクス / 実効果スモーク /
# 配線検証の各ルールは validation-authoring-prompt.md（Implementer 執筆ステップ）へ移設
TP="${ROOT}/.forge/templates/task-planning-prompt.md"
check "task-planning: {{ENV_PROBE}} プレースホルダ" "$TP" '{{ENV_PROBE}}'
check "task-planning: Walking Skeleton 手順" "$TP" 'Walking Skeleton 対応'
check "task-planning: L3 は refs 割当のみ（コマンド禁止）" "$TP" 'l3_criteria_refs'
check "task-planning: 検証手順を書かない原則" "$TP" 'テストコマンドは書かない'

VA="${ROOT}/.forge/templates/validation-authoring-prompt.md"
check "validation-authoring: {{ENV_PROBE}} プレースホルダ" "$VA" '{{ENV_PROBE}}'
check "validation-authoring: strategy 適合マトリクス" "$VA" 'strategy 適合マトリクス'
check "validation-authoring: 実効果スモーク必須" "$VA" '外部境界タスクの実効果スモーク'
check "validation-authoring: replaces 配線検証ルール" "$VA" 'grep_ref を必ず含める'
check "validation-authoring: 実物契約の原則" "$VA" '契約は実装の現実から書く'

CG="${ROOT}/.forge/templates/criteria-generation.md"
check "criteria-gen: {{ENV_PROBE}} プレースホルダ" "$CG" '{{ENV_PROBE}}'
check "criteria-gen: Walking Skeleton 必須節" "$CG" 'Walking Skeleton（必須'
check "criteria-gen: kind=walking_skeleton サンプル" "$CG" '"kind": "walking_skeleton"'
check "criteria-gen: browser strategy 条件" "$CG" 'browser'

IMPL="${ROOT}/.forge/templates/implementer-prompt.md"
check "implementer: 外部境界は本物を実装" "$IMPL" '本物を実装する'
check "implementer: テストダブルはテストコード内のみ" "$IMPL" 'テストコード内のみ'
check "implementer: {{CLI_CONTRACT}} プレースホルダ（出口基準の CLI 形 — batch#11 R08a）" "$IMPL" '{{CLI_CONTRACT}}'
check "implementer: CLI 契約に合否条件を含めない旨" "$IMPL" '合否条件・期待値はここには示さない'

QA="${ROOT}/.forge/templates/qa-evaluator-prompt.md"
check "qa-evaluator: テスト監査の任務定義" "$QA" 'テスト自体の品質を監査'
check "qa-evaluator: stub_suspected カテゴリ" "$QA" 'stub_suspected'
check "qa-evaluator: ガード退行検出ルール" "$QA" 'untested_guard'

HANDOFF="${ROOT}/.forge/templates/phase4-handoff.md"
check "phase4-handoff: DEBT_SUMMARY" "$HANDOFF" '{{DEBT_SUMMARY}}'
check "phase4-handoff: DEFERRED_TESTS" "$HANDOFF" '{{DEFERRED_TESTS}}'

echo -e "\n${BOLD}===== [2] render 配線契約 =====${NC}"
GT="${ROOT}/.forge/loops/generate-tasks.sh"
check "generate-tasks: ENV_PROBE render ペア" "$GT" '"ENV_PROBE"'
check "generate-tasks: probe_env_capabilities 呼出" "$GT" 'probe_env_capabilities'
RL="${ROOT}/.forge/loops/research-loop.sh"
check "research-loop: ENV_PROBE render ペア" "$RL" '"ENV_PROBE"'
RALPH="${ROOT}/.forge/loops/ralph-loop.sh"
check "ralph-loop: CLI_CONTRACT render ペア" "$RALPH" '"CLI_CONTRACT"'
check "ralph-loop: build_cli_contract_context 定義" "$RALPH" 'build_cli_contract_context() {'

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
# batch#10 Stage4: L3 strategy enum / impl-test-commands は執筆後ゲート
# （validation-gates.sh の validate_authored_validation）へ移設。
# 生成時は L3 refs 割当（validate_l3_refs_claimed）と phase scope 突合を検査する
VG="${ROOT}/.forge/lib/validation-gates.sh"
check "validation-gates: L3 strategy enum に browser" "$VG" 'structural|api_e2e|llm_judge|cli_flow|context_injection|agent_flow|browser'
check "validation-gates: 執筆後ゲート定義" "$VG" 'validate_authored_validation'
check "generate-tasks: validate_server_consistency 配線" "$GT" 'validate_server_consistency "\$OUTPUT_FILE"'
check "generate-tasks: validate_walking_skeleton 配線" "$GT" 'validate_walking_skeleton "\$OUTPUT_FILE"'
check "generate-tasks: validate_requires_satisfiable 配線" "$GT" 'run_plan_gate_with_retry validate_requires_satisfiable'
check "generate-tasks: L3 refs 割当ゲート配線" "$GT" 'validate_l3_refs_claimed'
check "generate-tasks: phase scope 突合配線" "$GT" 'validate_phase_scope_mapping'
check "generate-tasks: validation-gates source" "$GT" 'validation-gates.sh'
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
check "ralph-loop: validation-gates source" "$RALPH" 'validation-gates.sh'
check "ralph-loop: validation 執筆ステップ配線" "$RALPH" 'task_author_validation "\$task_id"'
check "ralph-loop: 執筆後ゲート呼出" "$RALPH" 'validate_authored_validation'

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
