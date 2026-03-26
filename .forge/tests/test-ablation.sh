#!/bin/bash
# test-ablation.sh — ablation.sh 単体テスト
# 使い方: bash .forge/tests/test-ablation.sh

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

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="/tmp/test-ablation"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$PROJECT_ROOT"
mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/state/ablation-results"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"

# 必要な共通関数のスタブ
cat > "${PROJECT_ROOT}/.forge/lib/stub-common.sh" << 'STUB'
log() { echo "[LOG] $1" >&2; }
now_ts() { date +%Y%m%d-%H%M%S; }
jq_safe() { jq "$@" | tr -d '\r'; }
STUB

source "${PROJECT_ROOT}/.forge/lib/stub-common.sh"

# テスト用変数
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
START_SECONDS=$SECONDS
investigation_count=0

cat > "$TASK_STACK" << 'JSON'
{"tasks":[{"task_id":"t1","status":"completed","fail_count":0},{"task_id":"t2","status":"failed","fail_count":2}]}
JSON

# ablation.sh をコピーして source
cp "${SCRIPT_DIR}/.forge/lib/ablation.sh" "${PROJECT_ROOT}/.forge/lib/"
source "${PROJECT_ROOT}/.forge/lib/ablation.sh"
# ABLATION_CONFIG をオーバーライド
ABLATION_CONFIG="${PROJECT_ROOT}/.forge/config/ablation.json"
ABLATION_RESULTS_DIR="${PROJECT_ROOT}/.forge/state/ablation-results"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: 設定ファイル不在 → no-op ---
echo -e "\n${BOLD}[1] ablation.json 不在で no-op${NC}"
ABLATION_EXPERIMENT_NAME=""
load_ablation_config
assert_eq "実験名が空のまま" "" "$ABLATION_EXPERIMENT_NAME"

# --- Test 2: enabled=false → no-op ---
echo -e "\n${BOLD}[2] enabled=false で no-op${NC}"
cat > "$ABLATION_CONFIG" << 'JSON'
{"experiment_name":"test-exp","enabled":false,"components":{"mutation_audit":true}}
JSON
ABLATION_EXPERIMENT_NAME=""
load_ablation_config
assert_eq "enabled=false 時は実験名が空" "" "$ABLATION_EXPERIMENT_NAME"

# --- Test 3: enabled=true → 設定読み込み ---
echo -e "\n${BOLD}[3] enabled=true で設定読み込み${NC}"
cat > "$ABLATION_CONFIG" << 'JSON'
{
  "experiment_name": "no-mutation-audit",
  "enabled": true,
  "components": {
    "mutation_audit": false,
    "evidence_da": true,
    "investigator": true,
    "qa_evaluator": false,
    "sprint_contract": true,
    "layer_3_tests": true,
    "dev_phase_gating": false,
    "priming": false,
    "lessons_learned": false,
    "l2_regression_tests": true
  }
}
JSON
ABLATION_EXPERIMENT_NAME=""
load_ablation_config
assert_eq "実験名が設定される" "no-mutation-audit" "$ABLATION_EXPERIMENT_NAME"

# --- Test 4: apply_ablation_overrides ---
echo -e "\n${BOLD}[4] apply_ablation_overrides でコンポーネント無効化${NC}"
MUTATION_AUDIT_ENABLED=true
EVIDENCE_DA_ENABLED=true
QA_EVALUATOR_ENABLED=true
SPRINT_CONTRACT_ENABLED=true
L3_ENABLED=true
L2_AUTO_RUN=true

apply_ablation_overrides

assert_eq "mutation_audit が無効化" "false" "$MUTATION_AUDIT_ENABLED"
assert_eq "evidence_da は有効のまま" "true" "$EVIDENCE_DA_ENABLED"
assert_eq "qa_evaluator が無効化" "false" "$QA_EVALUATOR_ENABLED"
assert_eq "sprint_contract は有効のまま" "true" "$SPRINT_CONTRACT_ENABLED"
assert_eq "priming が無効化" "false" "${ABLATION_PRIMING_ENABLED}"
assert_eq "lessons が無効化" "false" "${ABLATION_LESSONS_ENABLED}"
assert_eq "dev_phase_gating が無効化" "false" "${ABLATION_DEV_PHASE_GATING_ENABLED}"

# --- Test 5: save_ablation_results ---
echo -e "\n${BOLD}[5] save_ablation_results で結果保存${NC}"
save_ablation_results
result_files=$(ls -1 "$ABLATION_RESULTS_DIR" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "結果ファイルが作成される" "1" "$result_files"

# 結果ファイルの内容検証
result_file=$(ls -1 "$ABLATION_RESULTS_DIR"/*.json 2>/dev/null | head -1)
if [ -n "$result_file" ]; then
  exp_name=$(jq -r '.experiment_name' "$result_file" | tr -d '\r')
  assert_eq "experiment_name が正しい" "no-mutation-audit" "$exp_name"
  total=$(jq -r '.metrics.total_tasks' "$result_file" | tr -d '\r')
  assert_eq "total_tasks が正しい" "2" "$total"
fi

# --- Test 6: ablation 無効時は save しない ---
echo -e "\n${BOLD}[6] ablation 無効時は save しない${NC}"
ABLATION_EXPERIMENT_NAME=""
rm -f "${ABLATION_RESULTS_DIR}"/*.json 2>/dev/null
save_ablation_results
result_files=$(ls -1 "$ABLATION_RESULTS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
assert_eq "無効時は結果ファイルなし" "0" "$result_files"

# ===== クリーンアップ =====
rm -rf "$PROJECT_ROOT"

# ===== 結果 =====
echo ""
echo -e "${BOLD}=========================================="
echo -e "  ablation テスト結果"
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
