#!/bin/bash
# ablation.sh — Component Ablation Testing Framework
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   PROJECT_ROOT

# ===== 定数 =====
ABLATION_CONFIG="${PROJECT_ROOT}/.forge/config/ablation.json"
ABLATION_RESULTS_DIR="${PROJECT_ROOT}/.forge/state/ablation-results"
ABLATION_EXPERIMENT_NAME=""

# ===== Ablation 設定読み込み =====
load_ablation_config() {
  [ -f "$ABLATION_CONFIG" ] || return 0

  local enabled
  enabled=$(jq_safe -r '.enabled // false' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$enabled" = "true" ] || return 0

  ABLATION_EXPERIMENT_NAME=$(jq_safe -r '.experiment_name // "unnamed"' "$ABLATION_CONFIG" 2>/dev/null)
  log "  [ABLATION] 実験モード有効: ${ABLATION_EXPERIMENT_NAME}"
  return 0
}

# ===== Ablation オーバーライド適用 =====
# 既存の ENABLED 変数を ablation config で上書きする
apply_ablation_overrides() {
  [ -f "$ABLATION_CONFIG" ] || return 0

  local enabled
  enabled=$(jq_safe -r '.enabled // false' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$enabled" = "true" ] || return 0

  # 各コンポーネントのトグルを読み込み、false なら無効化
  # 注意: jq の // (alternative) は false を null と同様に扱うため、
  # if == null then true else . end パターンを使用する
  local comp_val

  comp_val=$(jq_safe -r '.components.mutation_audit | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { MUTATION_AUDIT_ENABLED=false; log "  [ABLATION] mutation_audit: OFF"; }

  comp_val=$(jq_safe -r '.components.evidence_da | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { EVIDENCE_DA_ENABLED=false; log "  [ABLATION] evidence_da: OFF"; }

  comp_val=$(jq_safe -r '.components.investigator | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { ABLATION_INVESTIGATOR_ENABLED=false; log "  [ABLATION] investigator: OFF"; }
  : "${ABLATION_INVESTIGATOR_ENABLED:=true}"

  comp_val=$(jq_safe -r '.components.qa_evaluator | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { QA_EVALUATOR_ENABLED=false; log "  [ABLATION] qa_evaluator: OFF"; }

  comp_val=$(jq_safe -r '.components.sprint_contract | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { SPRINT_CONTRACT_ENABLED=false; log "  [ABLATION] sprint_contract: OFF"; }

  comp_val=$(jq_safe -r '.components.layer_3_tests | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { L3_ENABLED=false; log "  [ABLATION] layer_3_tests: OFF"; }

  comp_val=$(jq_safe -r '.components.dev_phase_gating | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { ABLATION_DEV_PHASE_GATING_ENABLED=false; log "  [ABLATION] dev_phase_gating: OFF"; }
  : "${ABLATION_DEV_PHASE_GATING_ENABLED:=true}"

  comp_val=$(jq_safe -r '.components.priming | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { ABLATION_PRIMING_ENABLED=false; log "  [ABLATION] priming: OFF"; }
  : "${ABLATION_PRIMING_ENABLED:=true}"

  comp_val=$(jq_safe -r '.components.lessons_learned | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { ABLATION_LESSONS_ENABLED=false; log "  [ABLATION] lessons_learned: OFF"; }
  : "${ABLATION_LESSONS_ENABLED:=true}"

  comp_val=$(jq_safe -r '.components.l2_regression_tests | if . == null then true else . end' "$ABLATION_CONFIG" 2>/dev/null)
  [ "$comp_val" = "false" ] && { L2_AUTO_RUN=false; log "  [ABLATION] l2_regression_tests: OFF"; }

  return 0
}

# ===== Ablation 結果保存 =====
# セッション終了時に呼び出す
save_ablation_results() {
  [ -n "$ABLATION_EXPERIMENT_NAME" ] || return 0

  mkdir -p "$ABLATION_RESULTS_DIR"

  local ts
  ts=$(now_ts)
  local result_file="${ABLATION_RESULTS_DIR}/${ABLATION_EXPERIMENT_NAME}-${ts}.json"

  # メトリクスを task-stack.json から集計
  local total_tasks completed failed total_retries
  total_tasks=$(jq '.tasks | length' "$TASK_STACK" 2>/dev/null || echo 0)
  completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  failed=$(jq '[.tasks[] | select(.status == "failed" or (.status | startswith("blocked")))] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  total_retries=$(jq '[.tasks[].fail_count // 0] | add // 0' "$TASK_STACK" 2>/dev/null || echo 0)

  local elapsed_min=$(( (SECONDS - START_SECONDS) / 60 ))

  # コンポーネント状態を記録
  local components
  components=$(jq_safe '.components' "$ABLATION_CONFIG" 2>/dev/null || echo '{}')

  jq -n \
    --arg name "$ABLATION_EXPERIMENT_NAME" \
    --arg ts "$(date -Iseconds)" \
    --argjson comp "$components" \
    --argjson total "$total_tasks" \
    --argjson compl "$completed" \
    --argjson fail "$failed" \
    --argjson retries "$total_retries" \
    --argjson inv "$investigation_count" \
    --argjson dur "$elapsed_min" \
    '{experiment_name: $name, timestamp: $ts, components: $comp,
      metrics: {total_tasks: $total, completed: $compl, failed: $fail,
                total_retries: $retries, investigations: $inv,
                total_duration_min: $dur}}' \
    > "$result_file"

  log "  [ABLATION] 結果保存: ${result_file}"
}
