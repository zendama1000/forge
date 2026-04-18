#!/bin/bash
# ralph-loop.sh v3.2 — Development System オーケストレータ
# 使い方: ./ralph-loop.sh <task-stack.json> [implementation-criteria.json]
#
# task-stack.json: Phase 1.5 で人間/LLM が作成したタスク定義
# implementation-criteria.json: Phase 1 の Research System が生成（参照用）
#
# 設計書: forge-architecture-v3.2.md §5
# Ralph原則: 各タスクは独立セッション。完全コンテキストリセット。状態はファイル経由。

set -eEuo pipefail

# ===== 異常終了時クリーンアップ（B2: stuck state 防止） =====
_cleanup_on_exit() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ -f "${TASK_STACK:-}" ]; then
    # in_progress タスクを interrupted に更新
    local in_progress_ids
    in_progress_ids=$(jq_safe -r '.tasks[]? | select(.status == "in_progress") | .task_id' "$TASK_STACK" 2>/dev/null || true)
    for tid in $in_progress_ids; do
      jq --arg id "$tid" --arg ts "$(date -Iseconds)" '
        .tasks |= map(
          if .task_id == $id then .status = "interrupted" | .updated_at = $ts else . end
        ) | .updated_at = $ts
      ' "$TASK_STACK" > "${TASK_STACK}.tmp" 2>/dev/null && mv "${TASK_STACK}.tmp" "$TASK_STACK"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ 異常終了検出（exit=$exit_code）— タスク ${tid} を interrupted に更新" >&2
    done
  fi
}
trap _cleanup_on_exit EXIT INT TERM

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"

# ===== コマンド依存チェック =====
check_dependencies claude jq timeout

# ===== パス定数 =====
AGENTS_DIR=".claude/agents"
TEMPLATES_DIR=".forge/templates"
SCHEMAS_DIR=".forge/schemas"
DEV_LOG_DIR=".forge/logs/development"
INVESTIGATION_LOG=".forge/state/investigation-log.jsonl"
ERRORS_FILE=".forge/state/errors.jsonl"
LOOP_SIGNAL_FILE=".forge/state/loop-signal"
HEARTBEAT_FILE=".forge/state/heartbeat.json"

# common.sh が使う変数
RESEARCH_DIR="dev-session-$(date +%Y%m%d-%H%M%S)"
json_fail_count=0

# ===== コストトラッキング =====
# circuit-breaker.json の cost_tracking.max_session_cost_usd を読み込む
MAX_SESSION_COST_USD=$(jq -r '.cost_tracking.max_session_cost_usd // 0' \
  "${PROJECT_ROOT}/.forge/config/circuit-breaker.json" 2>/dev/null || echo 0)

# ===== 引数チェック（名前付き引数 + 位置引数の後方互換） =====
_TASK_STACK_ARG=""
_CRITERIA_ARG=""
_WORK_DIR_ARG=""

# 名前付き引数を先にパース
_positional_args=()
_PHASE_CONTROL_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --criteria)
      _CRITERIA_ARG="$2"; shift 2 ;;
    --criteria=*)
      _CRITERIA_ARG="${1#*=}"; shift ;;
    --work-dir)
      _WORK_DIR_ARG="$2"; shift 2 ;;
    --work-dir=*)
      _WORK_DIR_ARG="${1#*=}"; shift ;;
    --phase-control)
      _PHASE_CONTROL_ARG="$2"; shift 2 ;;
    --phase-control=*)
      _PHASE_CONTROL_ARG="${1#*=}"; shift ;;
    --research-config)
      _RESEARCH_CONFIG_ARG="$2"; shift 2 ;;
    --research-config=*)
      _RESEARCH_CONFIG_ARG="${1#*=}"; shift ;;
    -*)
      echo "不明なオプション: $1" >&2; exit 1 ;;
    *)
      _positional_args+=("$1"); shift ;;
  esac
done

# 位置引数のフォールバック
if [ ${#_positional_args[@]} -lt 1 ]; then
  echo "使い方: $0 <task-stack.json> [--criteria <file>] [--work-dir <dir>]" >&2
  echo "        $0 <task-stack.json> [implementation-criteria.json] [working-directory]" >&2
  exit 1
fi

_TASK_STACK_ARG="${_positional_args[0]}"

# 位置引数2番目: ファイルなら criteria、ディレクトリなら work-dir
if [ ${#_positional_args[@]} -ge 2 ] && [ -z "$_CRITERIA_ARG" ] && [ -z "$_WORK_DIR_ARG" ]; then
  if [ -f "${_positional_args[1]}" ]; then
    _CRITERIA_ARG="${_positional_args[1]}"
  elif [ -d "${_positional_args[1]}" ]; then
    _WORK_DIR_ARG="${_positional_args[1]}"
  else
    _CRITERIA_ARG="${_positional_args[1]}"
  fi
fi
if [ ${#_positional_args[@]} -ge 3 ] && [ -z "$_WORK_DIR_ARG" ]; then
  _WORK_DIR_ARG="${_positional_args[2]}"
fi

TASK_STACK="$(cd "$(dirname "$_TASK_STACK_ARG")" && pwd)/$(basename "$_TASK_STACK_ARG")"
CRITERIA_FILE="${_CRITERIA_ARG}"
WORK_DIR="${_WORK_DIR_ARG:-$PROJECT_ROOT}"

if [ ! -f "$TASK_STACK" ]; then
  echo -e "${RED}[ERROR] task-stack.json が見つかりません: ${TASK_STACK}${NC}" >&2
  exit 1
fi

if [ -n "$WORK_DIR" ] && [ ! -d "$WORK_DIR" ]; then
  echo -e "${RED}[ERROR] 作業ディレクトリが見つかりません: ${WORK_DIR}${NC}" >&2
  exit 1
fi

# ===== エージェント・テンプレート存在チェック =====
if [ ! -f "${AGENTS_DIR}/implementer.md" ]; then
  echo -e "${RED}[ERROR] エージェント定義が見つかりません: ${AGENTS_DIR}/implementer.md${NC}" >&2
  exit 1
fi
if [ ! -f "${TEMPLATES_DIR}/implementer-prompt.md" ]; then
  echo -e "${RED}[ERROR] テンプレートが見つかりません: ${TEMPLATES_DIR}/implementer-prompt.md${NC}" >&2
  exit 1
fi

# ===== ディレクトリ準備 =====
mkdir -p "$DEV_LOG_DIR" ".forge/state"

# Locked Decision Assertions 用の research-config
RESEARCH_CONFIG="${_RESEARCH_CONFIG_ARG:-.forge/state/research-config.json}"
[ ! -f "$RESEARCH_CONFIG" ] && RESEARCH_CONFIG=""

# ===== 状態ファイル初期化 =====
if [ ! -f "$ERRORS_FILE" ]; then
  touch "$ERRORS_FILE"
fi
if [ ! -f "$INVESTIGATION_LOG" ]; then
  touch "$INVESTIGATION_LOG"
fi
APPROACH_BARRIERS_FILE=".forge/state/approach-barriers.jsonl"
if [ ! -f "$APPROACH_BARRIERS_FILE" ]; then
  touch "$APPROACH_BARRIERS_FILE"
fi

# Lessons Learned / Task Events ファイル初期化
LESSONS_FILE=".forge/state/lessons-learned.jsonl"
if [ ! -f "$LESSONS_FILE" ]; then
  touch "$LESSONS_FILE"
fi
TASK_EVENTS_FILE=".forge/state/task-events.jsonl"
if [ ! -f "$TASK_EVENTS_FILE" ]; then
  touch "$TASK_EVENTS_FILE"
fi

# ===== 設定読み込み =====
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"

# ===== 設定スキーマ検証（起動時） =====
_RL_SCHEMAS_DIR="${PROJECT_ROOT}/.forge/schemas"
if ! validate_config "${DEV_CONFIG}" "${_RL_SCHEMAS_DIR}/development.schema.json"; then
  echo -e "${RED}[ERROR] development.json スキーマ検証失敗${NC}" >&2
  exit 1
fi
if ! validate_config "${CIRCUIT_BREAKER_CONFIG}" "${_RL_SCHEMAS_DIR}/circuit-breaker.schema.json"; then
  echo -e "${RED}[ERROR] circuit-breaker.json スキーマ検証失敗${NC}" >&2
  exit 1
fi
unset _RL_SCHEMAS_DIR

# ===== Safety Profile 取得 =====
# task_type に応じた制約値を development.json の safety_profiles から読み込む。
# safety_profiles 未定義時はデフォルト値にフォールバック。
get_safety_profile() {
  local task_type="$1"
  local field="$2"
  local default="$3"
  if [ -f "$DEV_CONFIG" ]; then
    local val
    val=$(jq_safe -r ".safety_profiles.${task_type}.${field} // empty" "$DEV_CONFIG" 2>/dev/null)
    if [ -n "$val" ]; then echo "$val"; return; fi
  fi
  echo "$default"
}

load_development_config() {
  # circuit-breaker.json から Development System 設定を読み込む
  if [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
    MAX_TASK_RETRIES=$(jq_safe -r '.development_limits.max_task_retries // 3' "$CIRCUIT_BREAKER_CONFIG")
    MAX_TOTAL_TASKS=$(jq_safe -r '.development_limits.max_total_tasks // 50' "$CIRCUIT_BREAKER_CONFIG")
    MAX_INVESTIGATIONS=$(jq_safe -r '.development_limits.max_investigations_per_session // 5' "$CIRCUIT_BREAKER_CONFIG")
    MAX_DURATION_MINUTES=$(jq_safe -r '.development_limits.max_duration_minutes // 240' "$CIRCUIT_BREAKER_CONFIG")
  else
    log "⚠ circuit-breaker.json が見つかりません。デフォルト値を使用"
    MAX_TASK_RETRIES=3
    MAX_TOTAL_TASKS=50
    MAX_INVESTIGATIONS=5
    MAX_DURATION_MINUTES=240
  fi

  # development.json からモデル設定を読み込む
  if [ -f "$DEV_CONFIG" ]; then
    IMPLEMENTER_MODEL=$(jq_safe -r '.implementer.model // "sonnet"' "$DEV_CONFIG")
    IMPLEMENTER_TIMEOUT=$(jq_safe -r '.implementer.timeout_sec // 600' "$DEV_CONFIG")
    INVESTIGATOR_MODEL=$(jq_safe -r '.investigator.model // "sonnet"' "$DEV_CONFIG")
    INVESTIGATOR_TIMEOUT=$(jq_safe -r '.investigator.timeout_sec // 600' "$DEV_CONFIG")
    L1_DEFAULT_TIMEOUT=$(jq_safe -r '.layer_1_test.default_timeout_sec // 60' "$DEV_CONFIG")
    L2_AUTO_RUN=$(jq_safe -r '.layer_2.auto_run_after_all_tasks // true' "$DEV_CONFIG")
    L2_FAIL_CREATES_TASK=$(jq_safe -r '.layer_2.fail_creates_task // true' "$DEV_CONFIG")
    L2_DEFAULT_TIMEOUT=$(jq_safe -r '.layer_2.default_timeout_sec // 120' "$DEV_CONFIG")
    L2_MAX_TIMEOUT=$(jq_safe -r '.layer_2.max_timeout_sec // 300' "$DEV_CONFIG")

    EVIDENCE_DA_ENABLED=$(jq_safe -r '.evidence_da.enabled // false' "$DEV_CONFIG")
    EVIDENCE_DA_MODEL=$(jq_safe -r '.evidence_da.model // "sonnet"' "$DEV_CONFIG")
    EVIDENCE_DA_TIMEOUT=$(jq_safe -r '.evidence_da.timeout_sec // 300' "$DEV_CONFIG")
    EVIDENCE_DA_FAIL_THRESHOLD=$(jq_safe -r '.evidence_da.fail_threshold // 2' "$DEV_CONFIG")

    # QA Evaluator 設定
    QA_EVALUATOR_ENABLED=$(jq_safe -r '.qa_evaluator.enabled // false' "$DEV_CONFIG")
    QA_EVALUATOR_MODEL=$(jq_safe -r '.qa_evaluator.model // "opus"' "$DEV_CONFIG")
    QA_EVALUATOR_TIMEOUT=$(jq_safe -r '.qa_evaluator.timeout_sec // 300' "$DEV_CONFIG")
    QA_MAX_FAILURES=$(jq_safe -r '.qa_evaluator.max_qa_failures_per_task // 2' "$DEV_CONFIG")

    # Sprint Contract 設定
    SPRINT_CONTRACT_ENABLED=$(jq_safe -r '.sprint_contract.enabled // false' "$DEV_CONFIG")
    SPRINT_CONTRACT_MODEL=$(jq_safe -r '.sprint_contract.model // "haiku"' "$DEV_CONFIG")
    SPRINT_CONTRACT_TIMEOUT=$(jq_safe -r '.sprint_contract.timeout_sec // 120' "$DEV_CONFIG")
    SPRINT_CONTRACT_HUMAN_REVIEW=$(jq_safe -r '.sprint_contract.human_review_on_infeasible // true' "$DEV_CONFIG")

    # Context Strategy 設定
    CONTEXT_STRATEGY_DEFAULT=$(jq_safe -r '.context_strategy.default // "reset"' "$DEV_CONFIG")
    CONTEXT_STRATEGY_IMPLEMENTER=$(jq_safe -r '.context_strategy.per_agent.implementer // .context_strategy.default // "reset"' "$DEV_CONFIG")
    CONTEXT_STRATEGY_INVESTIGATOR=$(jq_safe -r '.context_strategy.per_agent.investigator // .context_strategy.default // "reset"' "$DEV_CONFIG")
    CONTEXT_STRATEGY_EVIDENCE_DA=$(jq_safe -r '.context_strategy.per_agent.evidence_da // .context_strategy.default // "reset"' "$DEV_CONFIG")
    CONTEXT_STRATEGY_QA_EVALUATOR=$(jq_safe -r '.context_strategy.per_agent.qa_evaluator // .context_strategy.default // "reset"' "$DEV_CONFIG")
  else
    log "⚠ development.json が見つかりません。デフォルト値を使用"
    IMPLEMENTER_MODEL="sonnet"
    IMPLEMENTER_TIMEOUT=600
    INVESTIGATOR_MODEL="sonnet"
    INVESTIGATOR_TIMEOUT=600
    L1_DEFAULT_TIMEOUT=60
    L2_AUTO_RUN=true
    L2_FAIL_CREATES_TASK=true
    L2_DEFAULT_TIMEOUT=120
    L2_MAX_TIMEOUT=300
    EVIDENCE_DA_ENABLED=false
    EVIDENCE_DA_MODEL="sonnet"
    EVIDENCE_DA_TIMEOUT=300
    EVIDENCE_DA_FAIL_THRESHOLD=2
    QA_EVALUATOR_ENABLED=false
    QA_EVALUATOR_MODEL="opus"
    QA_EVALUATOR_TIMEOUT=300
    QA_MAX_FAILURES=2
    SPRINT_CONTRACT_ENABLED=false
    SPRINT_CONTRACT_MODEL="haiku"
    SPRINT_CONTRACT_TIMEOUT=120
    SPRINT_CONTRACT_HUMAN_REVIEW=true
    CONTEXT_STRATEGY_DEFAULT="reset"
    CONTEXT_STRATEGY_IMPLEMENTER="reset"
    CONTEXT_STRATEGY_INVESTIGATOR="reset"
    CONTEXT_STRATEGY_EVIDENCE_DA="reset"
    CONTEXT_STRATEGY_QA_EVALUATOR="reset"
  fi

  # Layer 3 設定読み込み
  load_l3_config "$DEV_CONFIG"

  # Approach Pivot 設定
  if [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
    MAX_APPROACH_SCOPE_COUNT=$(jq_safe -r '.approach_pivot.max_approach_scope_count // 2' "$CIRCUIT_BREAKER_CONFIG")
    EXPLORER_MODEL=$(jq_safe -r '.approach_pivot.explorer_model // "opus"' "$CIRCUIT_BREAKER_CONFIG")
    EXPLORER_TIMEOUT=$(jq_safe -r '.approach_pivot.explorer_timeout_sec // 900' "$CIRCUIT_BREAKER_CONFIG")
  else
    MAX_APPROACH_SCOPE_COUNT=2
    EXPLORER_MODEL="opus"
    EXPLORER_TIMEOUT=900
  fi

  # Rate Limit Recovery 設定
  if [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
    RATE_LIMIT_RECOVERY_ENABLED=$(jq_safe -r '.rate_limit_recovery.enabled // false' "$CIRCUIT_BREAKER_CONFIG")
    RATE_LIMIT_COOLDOWN_SEC=$(jq_safe -r '.rate_limit_recovery.cooldown_sec // 60' "$CIRCUIT_BREAKER_CONFIG")
    RATE_LIMIT_MAX_RECOVERIES=$(jq_safe -r '.rate_limit_recovery.max_recoveries_per_task // 2' "$CIRCUIT_BREAKER_CONFIG")
  else
    RATE_LIMIT_RECOVERY_ENABLED=false
    RATE_LIMIT_COOLDOWN_SEC=60
    RATE_LIMIT_MAX_RECOVERIES=2
  fi

  # Safety 設定読み込み（S4: 変更ファイル数バリデーション）
  if [ -f "$DEV_CONFIG" ]; then
    SAFETY_MAX_FILES_PER_TASK=$(jq_safe -r '.safety.max_files_per_task // 5' "$DEV_CONFIG")
    SAFETY_MAX_FILES_HARD_LIMIT=$(jq_safe -r '.safety.max_files_hard_limit // 10' "$DEV_CONFIG")
    SAFETY_AUTO_REVERT_ON_REGRESSION=$(jq_safe -r '.safety.auto_revert_on_regression // true' "$DEV_CONFIG")
    SAFETY_AUTO_COMMIT_PER_PHASE=$(jq_safe -r '.safety.auto_commit_per_phase // true' "$DEV_CONFIG")
  else
    SAFETY_MAX_FILES_PER_TASK=5
    SAFETY_MAX_FILES_HARD_LIMIT=10
    SAFETY_AUTO_REVERT_ON_REGRESSION=true
    SAFETY_AUTO_COMMIT_PER_PHASE=true
  fi

  # コスト追跡設定（circuit-breaker.json の cost_tracking セクション）
  # 0 = 無効。非ゼロ時はセッション累計コストが超過した際に circuit-breaker を発動する。
  if [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
    MAX_SESSION_COST_USD=$(jq_safe -r '.cost_tracking.max_session_cost_usd // 0' "$CIRCUIT_BREAKER_CONFIG")
  else
    MAX_SESSION_COST_USD=0
  fi

}

load_development_config

# ===== Mutation Audit 設定読み込み =====
MUTATION_AUDIT_CONFIG="${PROJECT_ROOT}/.forge/config/mutation-audit.json"

load_mutation_config() {
  if [ -f "$MUTATION_AUDIT_CONFIG" ]; then
    MUTATION_AUDIT_ENABLED=$(jq_safe -r '.mutation_audit.enabled // false' "$MUTATION_AUDIT_CONFIG")
    MUTATION_SKIP_TASK_TYPES=$(jq_safe -r '.mutation_audit.skip_task_types // [] | join(",")' "$MUTATION_AUDIT_CONFIG")
    MUTATION_ERROR_RATE_THRESHOLD=$(jq_safe -r '.mutation_audit.error_rate_threshold // 0.40' "$MUTATION_AUDIT_CONFIG")
    MUTATION_MAX_PLAN_ATTEMPTS=$(jq_safe -r '.mutation_audit.max_plan_attempts // 2' "$MUTATION_AUDIT_CONFIG")
    MUTATION_MAX_AUDIT_ATTEMPTS=$(jq_safe -r '.mutation_audit.max_audit_attempts // 2' "$MUTATION_AUDIT_CONFIG")
    MUTATION_RUNNER_TIMEOUT=$(jq_safe -r '.mutation_audit.runner_timeout_per_mutant_sec // 60' "$MUTATION_AUDIT_CONFIG")
    MUTATION_MODEL=$(jq_safe -r '.mutation_audit.model // "sonnet"' "$MUTATION_AUDIT_CONFIG")
    MUTATION_AUDITOR_TIMEOUT=$(jq_safe -r '.mutation_audit.auditor_timeout_sec // 300' "$MUTATION_AUDIT_CONFIG")
  else
    log "⚠ mutation-audit.json が見つかりません。Mutation Audit 無効"
    MUTATION_AUDIT_ENABLED=false
  fi

  # ファイル存在ガード: 必要ファイルが揃っていなければ自動降格
  if [ "$MUTATION_AUDIT_ENABLED" = "true" ]; then
    local missing=false
    for f in "${AGENTS_DIR}/mutation-auditor.md" \
             "${TEMPLATES_DIR}/mutation-auditor-prompt.md" \
             "${TEMPLATES_DIR}/implementer-strengthen-prompt.md" \
             ".forge/loops/mutation-runner.sh"; do
      if [ ! -f "$f" ]; then
        log "⚠ Mutation Audit 必須ファイル不在: ${f}"
        missing=true
      fi
    done
    if [ "$missing" = "true" ]; then
      log "⚠ Mutation Audit を無効化（必須ファイル不在）"
      MUTATION_AUDIT_ENABLED=false
    fi
  fi
}

load_mutation_config

# ===== PHASE_CONTROL 設定 =====
# 優先順位: コマンドライン引数 > circuit-breaker.json > デフォルト
if [ -n "$_PHASE_CONTROL_ARG" ]; then
  PHASE_CONTROL="$_PHASE_CONTROL_ARG"
elif [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
  PHASE_CONTROL=$(jq_safe -r '.flow_limits.phase_control_default // "mvp-gate"' "$CIRCUIT_BREAKER_CONFIG")
else
  PHASE_CONTROL="mvp-gate"
fi

# ===== モジュール読み込み =====
source "${PROJECT_ROOT}/.forge/lib/mutation-audit.sh"
source "${PROJECT_ROOT}/.forge/lib/investigation.sh"
source "${PROJECT_ROOT}/.forge/lib/dev-phases.sh"
source "${PROJECT_ROOT}/.forge/lib/phase3.sh"
source "${PROJECT_ROOT}/.forge/lib/evidence-da.sh"
source "${PROJECT_ROOT}/.forge/lib/priming.sh"
source "${PROJECT_ROOT}/.forge/lib/calibration.sh"
source "${PROJECT_ROOT}/.forge/lib/qa-evaluator.sh"
source "${PROJECT_ROOT}/.forge/lib/ablation.sh"

# ===== Ablation 実験モード =====
load_ablation_config && apply_ablation_overrides

# ===== dev-phase 変数初期化 =====
HAS_DEV_PHASES=false
DEV_PHASES=()
CURRENT_DEV_PHASE=""
CHECKLIST_VERIFIER_MODEL="sonnet"
CHECKLIST_VERIFIER_TIMEOUT=300

# ===== 状態ディレクトリ =====
STATE_DIR=".forge/state"

# ===== セッション変数 =====
task_count=0
investigation_count=0
approach_scope_count=0
START_SECONDS=$SECONDS
phase3_retry_count=0
MAX_PHASE3_RETRIES=2

# ===== セッションカウンタ永続化 =====
SESSION_COUNTERS_FILE="${STATE_DIR}/session-counters.json"

persist_session_state() {
  jq -n \
    --argjson tc "$task_count" \
    --argjson ic "$investigation_count" \
    --argjson asc "$approach_scope_count" \
    --argjson p3r "$phase3_retry_count" \
    --arg updated "$(date -Iseconds)" \
    '{task_count: $tc, investigation_count: $ic,
      approach_scope_count: $asc, phase3_retry_count: $p3r,
      updated_at: $updated}' \
    > "${SESSION_COUNTERS_FILE}.tmp" 2>/dev/null && \
    mv "${SESSION_COUNTERS_FILE}.tmp" "$SESSION_COUNTERS_FILE" || true
}

restore_session_state() {
  [ -f "$SESSION_COUNTERS_FILE" ] || return 0
  local _restored
  _restored=$(cat "$SESSION_COUNTERS_FILE" 2>/dev/null) || return 0

  task_count=$(echo "$_restored" | jq -r '.task_count // 0' 2>/dev/null) || task_count=0
  investigation_count=$(echo "$_restored" | jq -r '.investigation_count // 0' 2>/dev/null) || investigation_count=0
  approach_scope_count=$(echo "$_restored" | jq -r '.approach_scope_count // 0' 2>/dev/null) || approach_scope_count=0
  phase3_retry_count=$(echo "$_restored" | jq -r '.phase3_retry_count // 0' 2>/dev/null) || phase3_retry_count=0

  log "セッションカウンタ復元: task=${task_count}, investigation=${investigation_count}, approach=${approach_scope_count}"
}

# クラッシュ復旧時にカウンタを復元
restore_session_state

# ===== ハートビート =====
# タスク実行ごとに現在状態を JSON で書き出す（デーモンモードの可観測性確保）
update_heartbeat() {
  local current_task="${1:-}"
  local elapsed_sec=$((SECONDS - START_SECONDS))
  local elapsed_min=$((elapsed_sec / 60))
  jq -n \
    --arg loop "ralph" \
    --arg task "$current_task" \
    --argjson tc "$task_count" \
    --argjson ic "$investigation_count" \
    --arg elapsed "${elapsed_min}m" \
    --arg ts "$(date -Iseconds)" \
    '{loop: $loop, current_task: $task, task_count: $tc,
     investigation_count: $ic, elapsed: $elapsed, heartbeat_at: $ts}' \
    > "${HEARTBEAT_FILE}.tmp" 2>/dev/null && mv "${HEARTBEAT_FILE}.tmp" "$HEARTBEAT_FILE"
}

# ===== タスクスタック同期（canonical パスへコピー） =====
CANONICAL_TASK_STACK=".forge/state/task-stack.json"

sync_task_stack() {
  # 引数のタスクスタックパスが canonical と異なる場合のみコピー
  if [ "$(realpath "$TASK_STACK" 2>/dev/null || echo "$TASK_STACK")" != \
       "$(realpath "$CANONICAL_TASK_STACK" 2>/dev/null || echo "$CANONICAL_TASK_STACK")" ]; then
    cp "$TASK_STACK" "$CANONICAL_TASK_STACK"
  fi
}

# ===== タスク操作関数 =====

# 次の実行可能タスクを取得（depends_on 考慮 + dev-phase フィルタ）
# depends_on の全タスクが completed であることをチェック
get_next_task() {
  local phase_filter=""
  if [ "$HAS_DEV_PHASES" = "true" ] && [ -n "$CURRENT_DEV_PHASE" ]; then
    # dev_phase_id がないタスクは "mvp" とみなす（後方互換）
    phase_filter='select((.dev_phase_id // "mvp") == "'"$CURRENT_DEV_PHASE"'") |'
  fi

  local next_id
  next_id=$(jq_safe -r '
    . as $root |
    .tasks[] |
    '"$phase_filter"'
    select(.status == "pending" or .status == "failed") |
    select(.fail_count < '"$MAX_TASK_RETRIES"') |
    . as $task |
    if (($task.depends_on // []) | length) == 0 then
      $task.task_id
    else
      ($task.depends_on | length) as $deps_count |
      [$task.depends_on[] | . as $dep |
        $root.tasks[] | select(.task_id == $dep) | .status] |
      if (length == $deps_count) and all(. == "completed") then
        $task.task_id
      else
        empty
      end
    end
  ' "$TASK_STACK" 2>/dev/null | head -1)
  echo "$next_id"
}

# タスク情報を取得
get_task_json() {
  local task_id="$1"
  jq --arg id "$task_id" '.tasks[] | select(.task_id == $id)' "$TASK_STACK"
}

# タスク状態をアトミックに更新（排他ロック + .tmp + mv）
update_task_status() {
  local task_id="$1"
  local new_status="$2"
  local _lock_dir
  _lock_dir="$(dirname "${TASK_STACK}")/.lock/task-stack.lock"

  acquire_lock "$_lock_dir" || return 1

  jq --arg id "$task_id" --arg s "$new_status" '
    .tasks |= map(
      if .task_id == $id then
        .status = $s |
        .updated_at = (now | todate) |
        if $s == "pending" then .fail_count = 0 else . end
      else . end
    ) |
    .updated_at = (now | todate)
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"

  release_lock "$_lock_dir"
  sync_task_stack
  record_task_event "$task_id" "status_changed" "{\"new_status\":\"$new_status\"}"
}

# 失敗カウントを更新（排他ロック付き）
update_task_fail_count() {
  local task_id="$1"
  local count="$2"
  local _lock_dir
  _lock_dir="$(dirname "${TASK_STACK}")/.lock/task-stack.lock"

  acquire_lock "$_lock_dir" || return 1

  jq --arg id "$task_id" --argjson c "$count" '
    .tasks |= map(
      if .task_id == $id then
        .fail_count = $c |
        .status = "failed" |
        .updated_at = (now | todate)
      else . end
    ) |
    .updated_at = (now | todate)
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"

  release_lock "$_lock_dir"
  sync_task_stack
  record_task_event "$task_id" "fail_recorded" "{\"fail_count\":$count}"
}

# ステータス別タスク集計
count_tasks_by_status() {
  local status="$1"
  jq --arg s "$status" '[.tasks[] | select(.status == $s)] | length' "$TASK_STACK"
}

# ===== 実装プロンプト構築 =====
build_implementer_prompt() {
  local task_json="$1"
  local task_id
  task_id=$(echo "$task_json" | jq_safe -r '.task_id')

  # Layer 1 テスト情報
  local l1_command
  l1_command=$(echo "$task_json" | jq_safe -r '.validation.layer_1.command // "echo \"No Layer 1 test defined\""')
  local l1_timeout
  l1_timeout=$(echo "$task_json" | jq_safe -r '.validation.layer_1.timeout_sec // '"$L1_DEFAULT_TIMEOUT")

  # Layer 2 テスト情報
  local l2_info="（Layer 2 テスト定義なし）"
  local l2_command
  l2_command=$(echo "$task_json" | jq_safe -r '.validation.layer_2.command // empty' 2>/dev/null)
  if [ -n "$l2_command" ]; then
    local l2_requires
    l2_requires=$(echo "$task_json" | jq_safe -r '.validation.layer_2.requires // [] | join(", ")' 2>/dev/null)
    local l2_timeout
    l2_timeout=$(echo "$task_json" | jq_safe -r ".validation.layer_2.timeout_sec // $L2_DEFAULT_TIMEOUT" 2>/dev/null)
    local l2_refs
    l2_refs=$(echo "$task_json" | jq_safe -r '.l2_criteria_refs // [] | join(", ")' 2>/dev/null)
    # テストファイルパス抽出（コマンドからファイルパスを推定）
    local l2_test_file
    l2_test_file=$(echo "$l2_command" | grep -oE '[^ ]+\.(test|spec|e2e)\.[^ ]+' 2>/dev/null || echo "")
    l2_info="コマンド: ${l2_command}
前提条件 (requires): ${l2_requires:-なし}
タイムアウト: ${l2_timeout}秒
対応 L2 criteria: ${l2_refs:-なし}"
    if [ -n "$l2_test_file" ]; then
      l2_info="${l2_info}
テストファイル: ${l2_test_file}"
    fi
    l2_info="${l2_info}

IMPORTANT: validation.layer_2.command が参照するテストファイルをこのセッション内で作成すること。"
  fi

  # Investigator 修正提案
  local inv_fix="（なし — 初回実装）"
  local fix_content
  fix_content=$(echo "$task_json" | jq_safe -r '.investigator_fix // empty' 2>/dev/null)
  if [ -n "$fix_content" ]; then
    inv_fix="$fix_content"
  fi

  # Sprint Contract 調整注入
  local contract_adj="${DEV_LOG_DIR}/${task_id}/sprint-contract-adjustments.txt"
  if [ -f "$contract_adj" ]; then
    local adj_info
    adj_info=$(cat "$contract_adj")
    inv_fix="${inv_fix}

## Sprint Contract 調整事項
${adj_info}
上記の調整事項を考慮して実装すること。"
  fi

  # QA Evaluator フィードバック注入
  local qa_feedback="${DEV_LOG_DIR}/${task_id}/qa-evaluator-feedback.txt"
  if [ -f "$qa_feedback" ]; then
    local qa_info
    qa_info=$(cat "$qa_feedback")
    inv_fix="${inv_fix}

## QA Evaluator フィードバック（前回指摘事項）
${qa_info}
上記の品質問題を必ず修正すること。"
  fi

  # Stall 検出情報を注入
  local stall_marker="${DEV_LOG_DIR}/${task_id}/stall-marker.txt"
  if [ -f "$stall_marker" ]; then
    local stall_info
    stall_info=$(cat "$stall_marker")
    inv_fix="${inv_fix}

## ⚠ STALL 警告
${stall_info}
同じ修正方法は機能していません。別のアプローチ（別のアルゴリズム、別のライブラリ、別のファイル構成）を試してください。"
  fi

  # required_behaviors 抽出
  local required_behaviors
  required_behaviors=$(echo "$task_json" | jq_safe -r '.required_behaviors // [] | to_entries | map("- \(.value)") | join("\n")' 2>/dev/null)
  if [ -z "$required_behaviors" ]; then
    required_behaviors="（required_behaviors 未定義）"
  fi

  # 追加コンテキスト（implementation-criteria.json があれば概要を含める）
  local context="（追加コンテキストなし）"
  if [ -n "$CRITERIA_FILE" ] && [ -f "$CRITERIA_FILE" ]; then
    local theme
    theme=$(jq_safe -r '.theme // "不明"' "$CRITERIA_FILE" 2>/dev/null)
    local assumptions
    assumptions=$(jq_safe -r '.assumptions // [] | join("\n- ")' "$CRITERIA_FILE" 2>/dev/null)
    context="リサーチテーマ: ${theme}
前提条件:
- ${assumptions}

IMPORTANT: 作業ディレクトリ: ${WORK_DIR}
全てのファイル操作・コマンド実行はこのディレクトリ内で行うこと。"
  fi

  # 保護パターンを circuit-breaker.json から動的注入
  local cb_config="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
  if [ -f "$cb_config" ]; then
    local protected_list
    protected_list=$(jq_safe -r '.protected_patterns // [] | map("- " + .) | join("\n")' "$cb_config" 2>/dev/null)
    if [ -n "$protected_list" ]; then
      context="${context}

## 変更禁止ファイル（自動検出 — 違反すると自動ロールバック）
以下のパターンにマッチするファイルは一切変更・作成しないこと:
${protected_list}"
    fi
  fi

  # Locked Decision Assertions をコンテキストに追加
  if [ -n "${RESEARCH_CONFIG:-}" ] && [ -f "${RESEARCH_CONFIG}" ]; then
    local locked_ctx
    locked_ctx=$(jq_safe -r '
      .locked_decisions // [] |
      map(select(.assertions != null and (.assertions | length) > 0)) |
      if length == 0 then ""
      else
        "## アーキテクチャ制約（自動検証あり — 違反するとタスク失敗）\n" +
        (map(
          "- \(.decision): " +
          (.assertions | map(
            if .type == "file_exists" then "ファイル必須: \(.path)"
            elif .type == "file_absent" then "ファイル禁止: \(.path)"
            elif .type == "grep_absent" then "パターン禁止: \(.pattern) in \(.glob)"
            elif .type == "grep_present" then "パターン必須: \(.pattern) in \(.glob)"
            else "\(.type)"
            end
          ) | join("; "))
        ) | join("\n"))
      end
    ' "$RESEARCH_CONFIG" 2>/dev/null)
    [ -n "$locked_ctx" ] && context="${context}\n\n${locked_ctx}"
  fi

  # Priming 注入
  if [ -n "${PROJECT_PRIME_CACHE:-}" ]; then
    context="${context}

## プロジェクト基本情報（自動検出 — Priming）
${PROJECT_PRIME_CACHE}"
  fi

  # Lessons Learned 注入
  local lessons=""
  lessons=$(get_relevant_lessons "$task_json")
  if [ -n "$lessons" ]; then
    context="${context}

## 過去の失敗からの教訓（自動注入 — Lessons Learned）
以下は過去に同種のタスクで発生した問題と解決策です。同じ失敗を繰り返さないこと。
${lessons}"
  fi

  render_template "${TEMPLATES_DIR}/implementer-prompt.md" \
    "TASK_JSON"            "$task_json" \
    "LAYER1_COMMAND"       "$l1_command" \
    "LAYER1_TIMEOUT"       "$l1_timeout" \
    "LAYER2_INFO"          "$l2_info" \
    "INVESTIGATOR_FIX"     "$inv_fix" \
    "REQUIRED_BEHAVIORS"   "$required_behaviors" \
    "CONTEXT"              "$context"
}

# ===== Layer 1 テスト実行 =====
execute_layer1_test() {
  local command="$1"
  local timeout_sec="${2:-$L1_DEFAULT_TIMEOUT}"
  timeout "$timeout_sec" env PATH="$WORK_DIR/node_modules/.bin:$PATH" bash -c "cd '$WORK_DIR' && $command" 2>&1
}

# ===== run_task サブパイプライン共有状態 =====
# task_prepare() が設定し、後続の task_implement() / task_validate_changes() /
# task_run_l1_test() / task_finalize() で参照する。
_RT_TASK_JSON=""        # タスク定義 JSON
_RT_PROMPT=""           # 実装プロンプト
_RT_OUTPUT=""           # implementation-output.txt パス
_RT_LOG_FILE=""         # impl-*.log パス
_RT_AGENT_FILE=""       # implementer.md or fixer.md パス
_RT_AGENT_DISALLOWED="" # 禁止ツールリスト
_RT_TASK_TYPE=""        # task_type フィールド値

# ===== タスク前処理: チェックポイント作成 + プロンプト構築 =====
# 使い方: task_prepare <task_id> <task_dir>
# 設定: _RT_TASK_JSON, _RT_PROMPT, _RT_OUTPUT, _RT_LOG_FILE,
#       _RT_AGENT_FILE, _RT_AGENT_DISALLOWED, _RT_TASK_TYPE
# 戻り値: 0=成功
task_prepare() {
  local task_id="$1"
  local task_dir="$2"

  # タスク情報を抽出して共有変数にセット
  _RT_TASK_JSON=$(get_task_json "$task_id")
  echo "$_RT_TASK_JSON" > "${task_dir}/task-definition.json"

  # S3: タスク実行前の Git Checkpoint 作成
  if [ "$WORK_DIR" != "$PROJECT_ROOT" ]; then
    task_checkpoint_create "$WORK_DIR" "$task_id"
  fi

  # Stall marker クリーンアップ（Investigator リセット後の古い警告を除去）
  rm -f "${task_dir}/stall-marker.txt" 2>/dev/null || true

  # Safety Profile: task_type に応じた制約を適用
  _RT_TASK_TYPE=$(echo "$_RT_TASK_JSON" | jq_safe -r '.task_type // "implementation"')
  local profile_disallowed
  profile_disallowed=$(get_safety_profile "$_RT_TASK_TYPE" "disallowed_tools" "WebSearch,WebFetch")

  # 実装プロンプト生成
  _RT_PROMPT=$(build_implementer_prompt "$_RT_TASK_JSON")

  # 出力・ログファイルパス設定
  local ts
  ts=$(now_ts)
  _RT_OUTPUT="${task_dir}/implementation-output.txt"
  _RT_LOG_FILE="${DEV_LOG_DIR}/impl-${task_id}-${ts}.log"

  # エージェント選択: fail_count > 0 なら Fixer を使用
  local current_fail_count
  current_fail_count=$(jq --arg id "$task_id" '.tasks[] | select(.task_id == $id) | .fail_count // 0' "$TASK_STACK")
  _RT_AGENT_FILE="${AGENTS_DIR}/implementer.md"
  _RT_AGENT_DISALLOWED="$profile_disallowed"

  if [ "$current_fail_count" -gt 0 ] && [ -f "${AGENTS_DIR}/fixer.md" ]; then
    _RT_AGENT_FILE="${AGENTS_DIR}/fixer.md"
    # Fixer は常に Bash 禁止（task_type に関係なく）
    _RT_AGENT_DISALLOWED="WebSearch,WebFetch,Bash"
    log "  [FIXER] fail_count=${current_fail_count} → Fixer エージェントで再試行"
  fi

  return 0
}

# ===== Sprint Contract: タスク実行可能性レビュー =====
# 使い方: task_contract_review <task_id> <task_dir>
# 前提: _RT_TASK_JSON が設定済み
# 戻り値: 0=proceed, 1=blocked (task skipped)
task_contract_review() {
  local task_id="$1"
  local task_dir="$2"

  # 無効なら即 return
  if [ "${SPRINT_CONTRACT_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # リトライ時はスキップ（初回のみ実行）
  local current_fail_count
  current_fail_count=$(echo "$_RT_TASK_JSON" | jq_safe -r '.fail_count // 0')
  if [ "$current_fail_count" -gt 0 ]; then
    return 0
  fi

  # テンプレート/スキーマ不在 → graceful skip
  if [ ! -f "${TEMPLATES_DIR}/sprint-contract-prompt.md" ]; then
    log "  ⚠ Sprint Contract: テンプレート不在 — スキップ"
    return 0
  fi

  log "  Sprint Contract: 実行可能性レビュー開始"

  # コンテキスト情報
  local context="（追加コンテキストなし）"
  if [ -n "${PROJECT_PRIME_CACHE:-}" ]; then
    context="$PROJECT_PRIME_CACHE"
  fi

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/sprint-contract-prompt.md" \
    "TASK_JSON" "$_RT_TASK_JSON" \
    "CONTEXT"   "$context"
  )

  local ts
  ts=$(now_ts)
  local output="${task_dir}/sprint-contract-result.json"
  local log_file="${DEV_LOG_DIR}/sprint-contract-${task_id}-${ts}.log"

  metrics_start
  if ! run_claude "${SPRINT_CONTRACT_MODEL:-haiku}" "${AGENTS_DIR}/implementer.md" \
    "$prompt" "$output" "$log_file" "WebSearch,WebFetch,Bash" "${SPRINT_CONTRACT_TIMEOUT:-120}" "" \
    "${SCHEMAS_DIR}/sprint-contract.schema.json"; then
    metrics_record "sprint-contract-${task_id}" "false"
    log "  ⚠ Sprint Contract 実行エラー — スキップ（proceed to implement）"
    return 0
  fi
  metrics_record "sprint-contract-${task_id}" "true"

  # JSON 検証
  if ! validate_json "$output" "sprint-contract-${task_id}"; then
    log "  ⚠ Sprint Contract JSON検証失敗 — スキップ"
    return 0
  fi

  local feasibility
  feasibility=$(jq_safe -r '.feasibility // "achievable"' "$output" 2>/dev/null)

  if [ "$feasibility" = "achievable" ]; then
    log "  Sprint Contract: achievable — 実装に進む"
    return 0
  fi

  # needs_adjustment
  local auto_adjustable
  auto_adjustable=$(jq_safe -r '.auto_adjustable // false' "$output" 2>/dev/null)
  local adjustments
  adjustments=$(jq_safe -r '.adjustments // ""' "$output" 2>/dev/null)

  if [ "$auto_adjustable" = "true" ] && [ -n "$adjustments" ]; then
    # 調整内容をファイルに保存 → build_implementer_prompt で注入
    echo "$adjustments" > "${task_dir}/sprint-contract-adjustments.txt"
    log "  Sprint Contract: needs_adjustment (auto_adjustable) — 調整を Implementer に注入"
    return 0
  fi

  # 自動調整不可
  if [ "${SPRINT_CONTRACT_HUMAN_REVIEW:-true}" = "true" ]; then
    log "  Sprint Contract: needs_adjustment — blocked_contract に更新"
    local issues
    issues=$(jq_safe -r '.issues[]? | "- [\(.type)] \(.description)"' "$output" 2>/dev/null)
    update_task_status "$task_id" "blocked_contract"
    notify_human "warning" "Sprint Contract: タスク ${task_id} が実行不能と判定" \
      "問題:\n${issues}\n調整案: ${adjustments}"
    return 1
  fi

  log "  Sprint Contract: needs_adjustment — human_review 無効のため続行"
  return 0
}

# ===== Implementer 実行 =====
# 使い方: task_implement <task_id> <task_dir>
# 前提: _RT_PROMPT, _RT_OUTPUT, _RT_LOG_FILE, _RT_AGENT_FILE, _RT_AGENT_DISALLOWED が設定済み
# 戻り値: 0=成功, 1=失敗（handle_task_fail 呼出済み）
task_implement() {
  local task_id="$1"
  local task_dir="$2"

  # 実装実行（コード + テスト生成）
  # S2: スコープ制限 — Safety Profile に従う
  export _RC_CONTEXT_STRATEGY="${CONTEXT_STRATEGY_IMPLEMENTER:-reset}"
  metrics_start
  retry_with_backoff 3 1 run_claude "$IMPLEMENTER_MODEL" "$_RT_AGENT_FILE" \
    "$_RT_PROMPT" "$_RT_OUTPUT" "$_RT_LOG_FILE" "$_RT_AGENT_DISALLOWED" "$IMPLEMENTER_TIMEOUT" "$WORK_DIR" || {
    metrics_record "implementer-${task_id}" "false"
    # デバッグログからレートリミット情報を抽出してエラー分類精度を向上
    local _impl_err_detail="Claude実行エラー"
    if [ -f "$_RT_LOG_FILE" ]; then
      local _rate_hint
      _rate_hint=$(tail -50 "$_RT_LOG_FILE" 2>/dev/null | grep -oi "429\|too many requests\|rate.limit\|rate_limit\|overloaded" | head -1 || true)
      [ -n "$_rate_hint" ] && _impl_err_detail="Claude実行エラー (rate_limit: ${_rate_hint})"
    fi
    record_error "implementer-${task_id}" "$_impl_err_detail"
    log "  ✗ Implementer [${task_id}] ${_impl_err_detail}"
    handle_task_fail "$task_id" "$task_dir" "$_impl_err_detail"
    return 1
  }
  metrics_record "implementer-${task_id}" "true"

  # .pending → 本ファイルに昇格（実装出力はJSONではないため validate_json を通さない）
  if [ -f "${_RT_OUTPUT}.pending" ]; then
    mv "${_RT_OUTPUT}.pending" "$_RT_OUTPUT"
  fi

  return 0
}

# ===== 変更ファイル数バリデーション + L1 ファイル参照検証 =====
# 使い方: task_validate_changes <task_id> <task_dir>
# 前提: _RT_TASK_JSON, _RT_TASK_TYPE が設定済み
# 戻り値: 0=成功, 1=失敗（handle_task_fail 呼出済み）
task_validate_changes() {
  local task_id="$1"
  local task_dir="$2"

  # S4: 変更ファイル数バリデーション（Implementer 実行後、Layer 1 テスト前）
  if [ "$WORK_DIR" != "$PROJECT_ROOT" ]; then
    local profile_soft profile_hard
    profile_soft=$(get_safety_profile "$_RT_TASK_TYPE" "max_files_per_task" "$SAFETY_MAX_FILES_PER_TASK")
    profile_hard=$(get_safety_profile "$_RT_TASK_TYPE" "max_files_hard_limit" "$SAFETY_MAX_FILES_HARD_LIMIT")
    local vtc_result=0
    validate_task_changes "$WORK_DIR" "$task_id" "$profile_soft" "$profile_hard" || vtc_result=$?
    if [ "$vtc_result" -eq 1 ]; then
      log "  ✗ タスク ${task_id}: 安全制限超過により自動ロールバック済み"
      handle_task_fail "$task_id" "$task_dir" "安全制限: 変更ファイル数がハードリミットを超過、または保護ファイルの変更を検出"
      return 1
    fi
    # vtc_result=2 はソフトリミット（WARNING のみ、続行）
  fi

  # S4.5: L1 テストファイル参照検証（Implementer ハルシネーション検出）
  local test_command
  test_command=$(echo "$_RT_TASK_JSON" | jq_safe -r '.validation.layer_1.command // ""')
  local missing_files=""
  if [ -n "$test_command" ] && ! missing_files=$(validate_l1_file_refs "$test_command" "$WORK_DIR"); then
    log "  ✗ Implementer がテストファイルを作成していない: ${missing_files}"
    handle_task_fail "$task_id" "$task_dir" "Implementer ファイル未作成: テストコマンドが参照する以下のファイルが存在しません:
${missing_files}
Implementer が Write ツールでファイルを実際に作成していない可能性があります。"
    return 1
  fi

  return 0
}

# ===== Layer 1 テスト実行 =====
# 使い方: task_run_l1_test <task_id> <task_dir>
# 前提: _RT_TASK_JSON が設定済み
# 戻り値: 0=成功（テストパス or テストコマンド未定義）, 1=失敗（handle_task_fail 呼出済み）
task_run_l1_test() {
  local task_id="$1"
  local task_dir="$2"

  local test_command
  test_command=$(echo "$_RT_TASK_JSON" | jq_safe -r '.validation.layer_1.command // ""')
  local test_timeout
  test_timeout=$(echo "$_RT_TASK_JSON" | jq_safe -r '.validation.layer_1.timeout_sec // '"$L1_DEFAULT_TIMEOUT")

  if [ -z "$test_command" ]; then
    log "  ⚠ Layer 1 テストコマンドが未定義。タスクを完了とする"
    return 0
  fi

  log "  Layer 1 テスト実行: ${test_command}"
  local test_output test_exit=0
  test_output=$(execute_layer1_test "$test_command" "$test_timeout" 2>&1) || test_exit=$?
  echo "$test_output" > "${task_dir}/test-output.txt"

  if [ "$test_exit" -ne 0 ]; then
    if [ "$test_exit" -eq 124 ]; then
      log "  ✗ Layer 1 テストがタイムアウト（${test_timeout}秒）"
    fi
    handle_task_fail "$task_id" "$task_dir" "$test_output"
    return 1
  fi

  # === Locked Decision Assertions 検証 ===
  if [ -n "${RESEARCH_CONFIG:-}" ]; then
    local assertion_report=""
    if ! assertion_report=$(validate_locked_assertions "$RESEARCH_CONFIG" "$WORK_DIR" "$task_id"); then
      echo "$assertion_report" > "${task_dir}/assertion-violations.txt"
      log "  ✗ Locked Decision Assertions 違反 (${task_id})"
      handle_task_fail "$task_id" "$task_dir" "Locked Decision Assertions 違反:
${assertion_report}"
      return 1
    fi
  fi

  return 0
}

# ===== Layer 3 受入テスト実行（per-task: サーバー不要分のみ） =====
# 使い方: task_run_l3_test <task_id> <task_dir>
# 前提: _RT_TASK_JSON が設定済み、L3_ENABLED がロード済み
# 戻り値: 0=成功 or L3 無効 or テストなし, 1=失敗（blocking テストの場合 handle_task_fail 呼出済み）
task_run_l3_test() {
  local task_id="$1"
  local task_dir="$2"

  # L3 無効時はスキップ
  if [ "${L3_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # サーバー不要の L3 テストをフィルタ
  local l3_tests
  l3_tests=$(filter_l3_tests "$_RT_TASK_JSON" "immediate")
  local l3_count
  l3_count=$(echo "$l3_tests" | jq 'length' 2>/dev/null || echo 0)

  if [ "$l3_count" -eq 0 ]; then
    return 0
  fi

  log "  Layer 3 受入テスト実行: ${l3_count} 件（per-task, サーバー不要）"

  local l3_pass=0 l3_fail=0 l3_skip=0
  local i=0
  while [ "$i" -lt "$l3_count" ]; do
    local l3_test l3_id l3_strategy l3_blocking
    l3_test=$(echo "$l3_tests" | jq -c ".[$i]")
    l3_id=$(echo "$l3_test" | jq_safe -r '.id')
    l3_strategy=$(echo "$l3_test" | jq_safe -r '.strategy')
    l3_blocking=$(echo "$l3_test" | jq_safe -r '.blocking // true')

    log "    L3 [${l3_id}] strategy=${l3_strategy} blocking=${l3_blocking}"

    local l3_output l3_exit=0
    l3_output=$(execute_l3_test "$l3_test" "$WORK_DIR" "${L3_DEFAULT_TIMEOUT:-120}" 2>&1) || l3_exit=$?

    echo "$l3_output" > "${task_dir}/l3-${l3_id}.txt"

    if [ "$l3_exit" -eq 0 ]; then
      log "    ✓ L3 PASS: ${l3_id}"
      l3_pass=$((l3_pass + 1))
    elif [ "$l3_exit" -eq 2 ]; then
      log "    ⚠ L3 SKIP: ${l3_id}"
      l3_skip=$((l3_skip + 1))
    else
      log "    ✗ L3 FAIL: ${l3_id}"
      l3_fail=$((l3_fail + 1))

      if [ "$l3_blocking" = "true" ]; then
        handle_task_fail "$task_id" "$task_dir" "L3 受入テスト失敗 [${l3_id}] (strategy=${l3_strategy}):
${l3_output}"
        return 1
      fi
    fi

    i=$((i + 1))
  done

  log "  Layer 3 結果: pass=${l3_pass} fail=${l3_fail} skip=${l3_skip}"
  record_task_event "$task_id" "l3_test_completed" "{\"pass\":${l3_pass},\"fail\":${l3_fail},\"skip\":${l3_skip}}"
  return 0
}

# ===== タスク後処理: mutation audit or handle_task_pass =====
# 使い方: task_finalize <task_id> <task_dir>
# 前提: _RT_TASK_JSON が設定済み（mutation audit 判定に使用）
# 戻り値: 0=成功
task_finalize() {
  local task_id="$1"
  local task_dir="$2"

  # QA Evaluator ゲート（success path 上のブロッキング評価）
  if ! run_qa_evaluator "$task_id" "$task_dir" "$_RT_TASK_JSON"; then
    log "  ✗ QA Evaluator: fail — タスクを失敗処理"
    handle_task_fail "$task_id" "$task_dir" "QA Evaluator が品質不足と判定。詳細: ${task_dir}/qa-evaluator-feedback.txt"
    return 0
  fi

  if should_run_mutation_audit "$_RT_TASK_JSON"; then
    run_mutation_audit "$task_id" "$task_dir" "$_RT_TASK_JSON"
  else
    handle_task_pass "$task_id"
  fi
}

# ===== タスク実行（サブパイプライン呼出） =====
run_task() {
  local task_id="$1"
  local task_dir="${DEV_LOG_DIR}/${task_id}"
  mkdir -p "$task_dir"

  log "--- タスク実行: ${task_id} ---"

  # ステータスを in_progress に更新
  update_task_status "$task_id" "in_progress" || {
    log "  ⚠ 状態更新失敗 (in_progress): ${task_id} — スキップ"
    return 0
  }
  record_task_event "$task_id" "task_started" "{}"

  # 進捗更新
  local _total_tasks _completed_tasks _pct
  _total_tasks=$(jq '.tasks | length' "$TASK_STACK" 2>/dev/null || echo 1)
  _completed_tasks=$(jq '[.tasks[] | select(.status == "completed")] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  _pct=$(( _completed_tasks * 100 / _total_tasks ))
  update_progress "development" "task-${task_id}" "実行中" "$_pct"

  # S3前処理: チェックポイント作成 + プロンプト構築
  task_prepare "$task_id" "$task_dir" || return 0

  # Sprint Contract: 初回のみ実行可能性レビュー
  task_contract_review "$task_id" "$task_dir" || return 0

  # ERR trap: task_implement の非想定エラー発生時にチェックポイントから復元
  # set -E により task_implement() 内の未捕捉エラーでも ERR trap が伝播する
  if [ "$WORK_DIR" != "$PROJECT_ROOT" ]; then
    local _rt_eid="$task_id" _rt_wd="$WORK_DIR"
    trap "task_checkpoint_restore '${_rt_wd}' '${_rt_eid}' 2>/dev/null || true" ERR
  fi

  # Implementer 実行（コード + テスト生成）
  if ! task_implement "$task_id" "$task_dir"; then
    trap - ERR 2>/dev/null || true
    return 0
  fi
  trap - ERR 2>/dev/null || true

  # S4: 変更ファイル数 + S4.5: L1 ファイル参照バリデーション
  task_validate_changes "$task_id" "$task_dir" || return 0

  # Layer 1 テスト実行
  task_run_l1_test "$task_id" "$task_dir" || return 0

  # Layer 3 受入テスト実行（サーバー不要分のみ、per-task）
  task_run_l3_test "$task_id" "$task_dir" || return 0

  # 後処理: mutation audit or handle_task_pass
  task_finalize "$task_id" "$task_dir"
}

# ===== タスク成功処理 =====
handle_task_pass() {
  local task_id="$1"
  update_task_status "$task_id" "completed" || \
    log "  ⚠ 状態更新失敗 (completed): ${task_id}"
  record_task_event "$task_id" "task_passed" "{}"
  log "  ✓ タスク ${task_id} 完了（Layer 1 テストパス）"

  # タスクごと auto-commit: validate_task_changes の累積カウント問題を防止
  # HEAD からの差分でカウントするため、未コミットが溜まると後続タスクがハードリミットに到達する
  if [ -n "${WORK_DIR:-}" ] && git -C "$WORK_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    local _uncommitted
    _uncommitted=$(git -C "$WORK_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_uncommitted" -gt 0 ]; then
      git -C "$WORK_DIR" add -A 2>/dev/null
      git -C "$WORK_DIR" commit -m "task: ${task_id} completed" --no-verify 2>/dev/null && \
        log "  [AUTO-COMMIT] タスク ${task_id} の変更をコミット（${_uncommitted} files）" || \
        log "  ⚠ [AUTO-COMMIT] コミット失敗（タスク ${task_id}）— 後続タスクのファイル数に影響する可能性あり"
    fi
  fi

  # 進捗更新
  local _total_tasks _completed_tasks _pct
  _total_tasks=$(jq '.tasks | length' "$TASK_STACK" 2>/dev/null || echo 1)
  _completed_tasks=$(jq '[.tasks[] | select(.status == "completed")] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  _pct=$(( _completed_tasks * 100 / _total_tasks ))
  update_progress "development" "task-done" "${task_id} 完了" "$_pct"
}

# ===== タスク失敗処理 =====
handle_task_fail() {
  local task_id="$1"
  local task_dir="$2"
  local error_output="${3:-}"

  # 現在の失敗カウントを取得
  local current_fail_count
  current_fail_count=$(jq --arg id "$task_id" '.tasks[] | select(.task_id == $id) | .fail_count // 0' "$TASK_STACK")
  current_fail_count=$((current_fail_count + 1))

  # 失敗出力を保存
  if [ -n "$error_output" ]; then
    echo "$error_output" > "${task_dir}/fail-${current_fail_count}.txt"
  fi

  # Stall Detection: 前回失敗と同一エラーかチェック
  if [ "$current_fail_count" -ge 2 ]; then
    local prev_fail="${task_dir}/fail-$((current_fail_count - 1)).txt"
    local curr_fail="${task_dir}/fail-${current_fail_count}.txt"
    if [ -f "$prev_fail" ] && [ -f "$curr_fail" ]; then
      # タイムスタンプ・行番号を正規化して比較（一時ファイル使用 — Windows Git Bash 互換）
      local prev_normalized curr_normalized
      prev_normalized=$(tail -30 "$prev_fail" | sed 's/[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}//g; s/[0-9]\+ms//g')
      curr_normalized=$(tail -30 "$curr_fail" | sed 's/[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}//g; s/[0-9]\+ms//g')

      local _tmp_prev="${task_dir}/.stall-prev.tmp"
      local _tmp_curr="${task_dir}/.stall-curr.tmp"
      echo "$prev_normalized" > "$_tmp_prev"
      echo "$curr_normalized" > "$_tmp_curr"
      local diff_lines
      diff_lines=$(diff "$_tmp_prev" "$_tmp_curr" 2>/dev/null | grep '^[<>]' | wc -l | tr -d ' ')
      diff_lines=${diff_lines:-999}
      rm -f "$_tmp_prev" "$_tmp_curr"

      if [ "$diff_lines" -lt 5 ]; then
        log "  ⚠ STALL 検出: fail-$((current_fail_count-1)) と fail-${current_fail_count} が同一エラー（diff=${diff_lines}行）"
        echo "STALL: 同一エラーが${current_fail_count}回連続。前回と異なるアプローチが必要。" \
          > "${task_dir}/stall-marker.txt"
      fi
    fi
  fi

  # Evidence-DA: 閾値到達時に事前評価（Investigator 前）
  if [ "$current_fail_count" -ge "${EVIDENCE_DA_FAIL_THRESHOLD:-99}" ] && \
     [ "$current_fail_count" -lt "$MAX_TASK_RETRIES" ]; then
    local _fail_texts=""
    for i in $(seq 1 "$current_fail_count"); do
      [ -f "${task_dir}/fail-${i}.txt" ] && _fail_texts="${_fail_texts}
--- fail-${i} ---
$(tail -30 "${task_dir}/fail-${i}.txt")"
    done
    run_evidence_da "$task_id" "$task_dir" "repeated_failure" "$_fail_texts" "" ""
  fi

  if [ "$current_fail_count" -ge "$MAX_TASK_RETRIES" ]; then
    # Investigator 起動閾値に到達
    log "  ✗ タスク ${task_id} が ${current_fail_count}回失敗。Investigator起動"
    update_task_fail_count "$task_id" "$current_fail_count" || \
      log "  ⚠ 失敗カウント更新失敗: ${task_id}"
    run_investigator "$task_id" "$task_dir"
  else
    # 再試行用に失敗カウント更新
    update_task_fail_count "$task_id" "$current_fail_count" || \
      log "  ⚠ 失敗カウント更新失敗: ${task_id}"
    log "  ✗ タスク ${task_id} 失敗（${current_fail_count}/${MAX_TASK_RETRIES}）。再試行"
  fi
}

# ===== サーキットブレーカー =====
check_circuit_breakers() {
  # 1. タスク実行上限
  if [ "$task_count" -ge "$MAX_TOTAL_TASKS" ]; then
    log "✗ サーキットブレーカー: タスク実行上限（${MAX_TOTAL_TASKS}）到達"
    notify_human "warning" "タスク実行上限到達" "実行回数: ${task_count}/${MAX_TOTAL_TASKS}"
    return 0
  fi

  # 2. Investigator起動回数上限
  if [ "$investigation_count" -ge "$MAX_INVESTIGATIONS" ]; then
    log "✗ サーキットブレーカー: Investigator起動上限（${MAX_INVESTIGATIONS}）到達"
    notify_human "warning" "Investigator起動上限到達" "起動回数: ${investigation_count}/${MAX_INVESTIGATIONS}"
    return 0
  fi

  # 3. 総時間上限
  local elapsed_seconds=$((SECONDS - START_SECONDS))
  local elapsed_minutes=$((elapsed_seconds / 60))
  if [ "$elapsed_minutes" -ge "$MAX_DURATION_MINUTES" ]; then
    log "✗ サーキットブレーカー: 総時間上限（${MAX_DURATION_MINUTES}分）到達"
    notify_human "warning" "開発総時間上限到達" "経過: ${elapsed_minutes}分/${MAX_DURATION_MINUTES}分"
    return 0
  fi

  # 4. blocked タスク過半数
  local total_tasks
  total_tasks=$(jq '.tasks | length' "$TASK_STACK")
  local blocked_count
  blocked_count=$(jq '[.tasks[] | select(.status | startswith("blocked"))] | length' "$TASK_STACK")
  if [ "$total_tasks" -gt 0 ] && [ "$((blocked_count * 2))" -gt "$total_tasks" ]; then
    log "✗ サーキットブレーカー: blocked タスク過半数（${blocked_count}/${total_tasks}）"
    notify_human "critical" "過半数のタスクがblocked状態" "blocked: ${blocked_count}/${total_tasks}"
    return 0
  fi

  # 5. セッションコスト上限チェック（metrics.jsonl + circuit-breaker.json ベース）
  if [ "${MAX_SESSION_COST_USD:-0}" != "0" ] && [ "${MAX_SESSION_COST_USD:-0}" != "null" ]; then
    local _cb_cost_result
    _cb_cost_result=$(aggregate_session_cost "${FORGE_SESSION_ID:-no-session}" "$METRICS_FILE" 2>/dev/null)
    local _cb_current_cost
    _cb_current_cost=$(echo "$_cb_cost_result" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)
    local _cb_cost_over
    _cb_cost_over=$(awk "BEGIN { print ($_cb_current_cost > $MAX_SESSION_COST_USD) ? 1 : 0 }" 2>/dev/null || echo 0)
    if [ "${_cb_cost_over:-0}" -eq 1 ]; then
      log "✗ サーキットブレーカー: セッションコスト上限 \$${MAX_SESSION_COST_USD} 超過（現在: \$${_cb_current_cost}）"
      notify_human "warning" "セッションコスト上限超過" "上限: \$${MAX_SESSION_COST_USD} / 現在: \$${_cb_current_cost}"
      return 0
    fi
  fi

  # 6. RESEARCH_REMAND シグナル
  if check_loop_signal; then
    return 0
  fi

  return 1
}

# ===== in_progress 残留解決（Bug #5） =====
# 正常終了時に in_progress が残っている場合、metrics.jsonl を参照して
# implementer 成功記録があれば completed、なければ failed に更新する。
check_stale_in_progress() {
  [ -f "$TASK_STACK" ] || return 0

  local stale_ids
  stale_ids=$(jq_safe -r '.tasks[]? | select(.status == "in_progress") | .task_id' "$TASK_STACK" 2>/dev/null || true)
  [ -z "$stale_ids" ] && return 0

  for tid in $stale_ids; do
    # metrics.jsonl で implementer 成功記録があるか確認
    local has_success=false
    if [ -f "$METRICS_FILE" ] && grep -q "\"stage\":\"implementer-${tid}\"" "$METRICS_FILE" 2>/dev/null; then
      local parse_success
      parse_success=$(grep "\"stage\":\"implementer-${tid}\"" "$METRICS_FILE" | tail -1 | jq -r '.parse_success // false' 2>/dev/null || echo "false")
      if [ "$parse_success" = "true" ]; then
        has_success=true
      fi
    fi

    if [ "$has_success" = "true" ]; then
      update_task_status "$tid" "completed"
      log "⚠ [stale-fix] タスク ${tid}: in_progress → completed（implementer 成功記録あり）"
    else
      update_task_status "$tid" "failed"
      log "⚠ [stale-fix] タスク ${tid}: in_progress → failed（implementer 成功記録なし）"
    fi
  done
}

# ===== レートリミット検出（デバッグログベース） =====
# 指定タスクの最新デバッグログ（implementer + investigator）にレートリミットパターンがあるか検査
# 戻り値: 0=レートリミット検出, 1=未検出
detect_rate_limit_from_debug_logs() {
  local task_id="$1"

  # implementer と investigator の最新ログを検索
  local latest_impl_log latest_inv_log
  latest_impl_log=$(ls -t "${DEV_LOG_DIR}/impl-${task_id}"-*.log 2>/dev/null | head -1 || true)
  latest_inv_log=$(ls -t "${DEV_LOG_DIR}/inv-${task_id}"-*.log 2>/dev/null | head -1 || true)

  # ログの直近 200 行でレートリミットパターンを検索
  local logfile
  for logfile in "$latest_impl_log" "$latest_inv_log"; do
    [ -z "$logfile" ] || [ ! -f "$logfile" ] && continue
    if tail -200 "$logfile" 2>/dev/null | grep -qi "429\|too many requests\|rate.limit\|rate_limit\|overloaded"; then
      return 0
    fi
  done

  # errors.jsonl でも確認（error_category フィールドがある場合）
  if [ -f "$ERRORS_FILE" ] && [ -s "$ERRORS_FILE" ]; then
    if grep -E "\"stage\":\"(implementer|investigator)-${task_id}\"" "$ERRORS_FILE" 2>/dev/null | \
       tail -5 | grep -q '"error_category":"rate_limit"'; then
      return 0
    fi
  fi

  return 1
}

# ===== レートリミット自動復旧 =====
# blocked_investigation タスクのうち、レートリミットが原因のものを pending にリセットする。
# per-task リカバリ回数を task-stack.json の rate_limit_recoveries フィールドで追跡する。
recover_rate_limited_tasks() {
  [ "$RATE_LIMIT_RECOVERY_ENABLED" = "true" ] || return 0
  [ -f "$TASK_STACK" ] || return 0

  # blocked_investigation タスクを列挙
  local blocked_ids
  blocked_ids=$(jq_safe -r '.tasks[]? | select(.status == "blocked_investigation") | .task_id' "$TASK_STACK" 2>/dev/null || true)
  [ -z "$blocked_ids" ] && return 0

  local recovered_count=0

  local task_id
  for task_id in $blocked_ids; do
    # per-task リカバリ回数チェック
    local current_recoveries
    current_recoveries=$(jq_safe -r --arg id "$task_id" \
      '.tasks[] | select(.task_id == $id) | .rate_limit_recoveries // 0' "$TASK_STACK" 2>/dev/null)
    current_recoveries=${current_recoveries:-0}

    if [ "$current_recoveries" -ge "$RATE_LIMIT_MAX_RECOVERIES" ]; then
      log "  [RATE-LIMIT] タスク ${task_id}: 復旧上限到達（${current_recoveries}/${RATE_LIMIT_MAX_RECOVERIES}）— スキップ"
      continue
    fi

    # レートリミットが原因か検査
    if ! detect_rate_limit_from_debug_logs "$task_id"; then
      continue
    fi

    # 復旧: blocked_investigation → pending, fail_count=0, rate_limit_recoveries++
    local new_recoveries=$((current_recoveries + 1))
    jq --arg id "$task_id" --argjson rec "$new_recoveries" '
      .tasks |= map(
        if .task_id == $id then
          .status = "pending" |
          .fail_count = 0 |
          .rate_limit_recoveries = $rec |
          .updated_at = (now | todate)
        else . end
      ) |
      .updated_at = (now | todate)
    ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"

    record_task_event "$task_id" "rate_limit_recovery" \
      "{\"recovery_count\":${new_recoveries},\"max_recoveries\":${RATE_LIMIT_MAX_RECOVERIES}}"

    log "  [RATE-LIMIT] タスク ${task_id} をレートリミット復旧（${new_recoveries}/${RATE_LIMIT_MAX_RECOVERIES}）"
    recovered_count=$((recovered_count + 1))
  done

  if [ "$recovered_count" -gt 0 ]; then
    notify_human "info" "レートリミット自動復旧: ${recovered_count}件" \
      "クールダウン ${RATE_LIMIT_COOLDOWN_SEC}秒後にリトライします"

    # ハートビート更新（可観測性）
    update_heartbeat "rate_limit_cooldown"

    # クールダウン
    log "  [RATE-LIMIT] クールダウン: ${RATE_LIMIT_COOLDOWN_SEC}秒待機"
    sleep "$RATE_LIMIT_COOLDOWN_SEC"
  fi

  return 0
}

# ===== 終了サマリー =====
print_summary() {
  local elapsed_seconds=$((SECONDS - START_SECONDS))
  local elapsed_minutes=$((elapsed_seconds / 60))

  local completed pending failed blocked total
  completed=$(count_tasks_by_status "completed")
  pending=$(count_tasks_by_status "pending")
  failed=$(count_tasks_by_status "failed")
  blocked=$(jq '[.tasks[] | select(.status | startswith("blocked"))] | length' "$TASK_STACK")
  total=$(jq '.tasks | length' "$TASK_STACK")

  log "=========================================="
  log "Ralph Loop 終了サマリー"
  log "=========================================="
  log "タスク: 完了=${completed} 待機=${pending} 失敗=${failed} blocked=${blocked} / 合計=${total}"
  log "実行回数: ${task_count}"
  log "Investigator起動: ${investigation_count}回"
  log "アプローチ限界検出: ${approach_scope_count}回"
  # キャリブレーション乖離率
  if [ -f "${CALIBRATION_FILE:-}" ] && [ -s "${CALIBRATION_FILE:-}" ]; then
    local _div_rate
    _div_rate=$(compute_divergence_rate)
    log "キャリブレーション乖離率: ${_div_rate}"
  fi
  log "経過時間: ${elapsed_minutes}分"
  log "=========================================="

  # ===== 行動検証カバレッジ警告（A-2: Phase 3 の test_coverage_gaps を強調表示） =====
  local _ir=".forge/state/integration-report.json"
  if [ -f "$_ir" ]; then
    local _p3_status _has_gaps _prom
    _p3_status=$(jq_safe -r '.status // ""' "$_ir" 2>/dev/null)
    _has_gaps=$(jq_safe -r '(.test_coverage_gaps // []) | length' "$_ir" 2>/dev/null)
    _prom=$(jq_safe -r '.warning_prominence // ""' "$_ir" 2>/dev/null)

    if [ "$_p3_status" = "completed_with_gaps" ] || [ "$_prom" = "critical" ]; then
      # 赤字＋太字で目立たせる（TTY 非対応環境でも文字列は残る）
      echo "" >&2
      echo -e "${RED:-$'\e[31m'}${BOLD:-$'\e[1m'}⚠ 行動検証未完了（BEHAVIORAL TESTS MISSING）${NC:-$'\e[0m'}" >&2
      jq_safe -r '.test_coverage_gaps[]? | "  • " + .' "$_ir" 2>/dev/null >&2 || true
      echo -e "  ${YELLOW:-$'\e[33m'}→ 実装が仕様通り動くかは未検証です。behavioral テスト追加を強く推奨${NC:-$'\e[0m'}" >&2
      echo -e "  ${YELLOW:-$'\e[33m'}→ 参照: .claude/rules/forge-operations.md『手動編集時チェックリスト』${NC:-$'\e[0m'}" >&2
      echo "" >&2
    elif [ "${_has_gaps:-0}" -gt 0 ]; then
      log "ℹ Test coverage 情報: jq -r '.test_coverage_gaps[]' ${_ir}"
    fi
  fi
}

# ===== メインループ =====
main() {
  log "=========================================="
  log "Ralph Loop v3.2 開始"
  log "タスクスタック: ${TASK_STACK}"
  log "成功条件: ${CRITERIA_FILE:-（なし）}"
  log "作業ディレクトリ: ${WORK_DIR}"
  log "research-config: ${RESEARCH_CONFIG:-（なし）}"
  log "制御モード: ${PHASE_CONTROL}"
  log "=========================================="

  # S1: 作業ディレクトリの git 安全チェック
  if [ "$WORK_DIR" != "$PROJECT_ROOT" ]; then
    if ! safe_work_dir_check "$WORK_DIR"; then
      log "✗ 作業ディレクトリの安全チェック失敗。処理を中断します"
      exit 1
    fi
  fi

  # Priming: プロジェクト文脈を1回だけ収集してキャッシュ
  PROJECT_PRIME_CACHE=""
  if [ "$WORK_DIR" != "$PROJECT_ROOT" ] && [ -d "$WORK_DIR" ]; then
    PROJECT_PRIME_CACHE=$(prime_project_context "$WORK_DIR")
    if [ -n "$PROJECT_PRIME_CACHE" ]; then
      log "Priming: プロジェクト文脈を収集完了"
    fi
  fi

  # dev-phase 検出
  detect_dev_phases

  # ===== 前回実行の残骸クリーンアップ =====
  if [ -f "$TASK_STACK" ]; then
    local l2fix_count
    l2fix_count=$(jq '[.tasks[] | select(.task_id | contains("-l2fix-"))] | length' "$TASK_STACK" 2>/dev/null || echo 0)
    if [ "$l2fix_count" -gt 0 ]; then
      log "前回の l2fix タスク ${l2fix_count}件を削除"
      jq '.tasks |= map(select(.task_id | contains("-l2fix-") | not))' \
        "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
      sync_task_stack
    fi
    # approach-barriers.jsonl をクリア（セッション間のデータ分離）
    if [ -f "$APPROACH_BARRIERS_FILE" ]; then
      : > "$APPROACH_BARRIERS_FILE"
    fi
    # in_progress + interrupted → pending に復帰
    local stale_count
    stale_count=$(jq '[.tasks[] | select(.status == "in_progress" or .status == "interrupted")] | length' "$TASK_STACK" 2>/dev/null || echo 0)
    if [ "$stale_count" -gt 0 ]; then
      log "前回実行の残留タスク ${stale_count}件を pending にリセット"
      jq '.tasks |= map(
        if .status == "in_progress" or .status == "interrupted" then
          .status = "pending"
        else . end
      )' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
      sync_task_stack
    fi
  fi

  # Phase 2: タスク実行ループ
  while true; do
    # サーキットブレーカーチェック
    if check_circuit_breakers; then
      break
    fi

    # キャリブレーション: reworked タスクの自動検出
    detect_reworked_tasks

    # レートリミット自動復旧（get_next_task 前に実行）
    recover_rate_limited_tasks

    # 次の実行可能タスクを取得
    local next_task
    next_task=$(get_next_task)

    # 全タスク完了チェック
    if [ -z "$next_task" ]; then
      if [ "$HAS_DEV_PHASES" = "true" ]; then
        # === dev-phase あり ===

        # CURRENT_DEV_PHASE が空 = 全 dev-phase 完了済み（再開時）→ Phase 3 へ
        if [ -z "$CURRENT_DEV_PHASE" ]; then
          log "✓ 全 dev-phase 完了済み"
          if [ "$L2_AUTO_RUN" = "true" ]; then
            run_phase3
            local phase3_has_failures
            phase3_has_failures=$(jq '[.tasks[] | select(.status == "pending")] | length' "$TASK_STACK")
            if [ "$phase3_has_failures" -gt 0 ] && [ "$phase3_retry_count" -lt "$MAX_PHASE3_RETRIES" ]; then
              phase3_retry_count=$((phase3_retry_count + 1))
              persist_session_state
              log "↻ Phase 3 失敗タスクあり。Phase 2 に戻る（リトライ ${phase3_retry_count}/${MAX_PHASE3_RETRIES}）"
              CURRENT_DEV_PHASE="${DEV_PHASES[${#DEV_PHASES[@]}-1]}"
              continue
            fi
          fi
          break
        fi

        # 現在の dev-phase 内の未完了タスク数を確認
        local phase_remaining
        phase_remaining=$(jq --arg pid "$CURRENT_DEV_PHASE" '
          [.tasks[] |
            select((.dev_phase_id // "mvp") == $pid) |
            select(.status != "completed")
          ] | length
        ' "$TASK_STACK" 2>/dev/null || echo 0)

        if [ "$phase_remaining" -eq 0 ]; then
          # 現在の dev-phase の全タスク完了 → dev-phase 完了処理
          log "✓ dev-phase [${CURRENT_DEV_PHASE}] 全タスク完了"

          if ! handle_dev_phase_completion "$CURRENT_DEV_PHASE"; then
            local _rfp
            _rfp=$(jq_safe -r '.safety.regression_failure_policy // "block"' "$DEV_CONFIG" 2>/dev/null)
            if [ "$_rfp" = "warn_and_continue" ]; then
              log "dev-phase [${CURRENT_DEV_PHASE}] 回帰テスト失敗 — policy=warn_and_continue → 続行"
            else
              log "dev-phase [${CURRENT_DEV_PHASE}] 完了処理で中断"
              break
            fi
          fi

          # 次の dev-phase へ進行
          advance_dev_phase
          if [ -z "$CURRENT_DEV_PHASE" ]; then
            # 全 dev-phase 完了 → 既存 Phase 3 へ
            log "✓ 全 dev-phase 完了"
            if [ "$L2_AUTO_RUN" = "true" ]; then
              run_phase3
              local phase3_has_failures
              phase3_has_failures=$(jq '[.tasks[] | select(.status == "pending")] | length' "$TASK_STACK")
              if [ "$phase3_has_failures" -gt 0 ] && [ "$phase3_retry_count" -lt "$MAX_PHASE3_RETRIES" ]; then
                phase3_retry_count=$((phase3_retry_count + 1))
                log "↻ Phase 3 失敗タスクあり。Phase 2 に戻る（リトライ ${phase3_retry_count}/${MAX_PHASE3_RETRIES}）"
                # Phase 3 で追加されたタスクの dev_phase_id が必要 — 最後の dev-phase に戻す
                CURRENT_DEV_PHASE="${DEV_PHASES[${#DEV_PHASES[@]}-1]}"
                continue
              fi
            fi
            break
          fi
          continue
        else
          # dev-phase 内に未完了タスクがあるが実行可能タスクなし
          log "⚠ dev-phase [${CURRENT_DEV_PHASE}] 内に未完了タスクあり（${phase_remaining}件）だが実行可能タスクなし"
          notify_human "warning" "dev-phase [${CURRENT_DEV_PHASE}] 実行可能タスクなし" \
            "未完了: ${phase_remaining}件。depends_on または blocked 状態を確認してください"
          break
        fi
      else
        # === dev-phase なし（後方互換: 既存ロジックそのまま） ===
        local remaining
        remaining=$(jq '[.tasks[] | select(.status != "completed")] | length' "$TASK_STACK")
        if [ "$remaining" -eq 0 ]; then
          log "✓ 全タスク完了"

          # Phase 3 自動実行判定
          if [ "$L2_AUTO_RUN" = "true" ]; then
            run_phase3
            # Phase 3 失敗時のリトライ
            local phase3_has_failures
            phase3_has_failures=$(jq '[.tasks[] | select(.status == "pending")] | length' "$TASK_STACK")
            if [ "$phase3_has_failures" -gt 0 ] && [ "$phase3_retry_count" -lt "$MAX_PHASE3_RETRIES" ]; then
              phase3_retry_count=$((phase3_retry_count + 1))
              persist_session_state
              log "↻ Phase 3 失敗タスクあり。Phase 2 に戻る（リトライ ${phase3_retry_count}/${MAX_PHASE3_RETRIES}）"
              continue
            fi
          fi
          break
        else
          log "⚠ 未完了タスクあり（${remaining}件）だが実行可能タスクなし"
          notify_human "warning" "実行可能タスクなし" "未完了: ${remaining}件。depends_on または blocked 状態を確認してください"
          break
        fi
      fi
    fi

    # ハートビート更新
    update_heartbeat "$next_task"

    # タスク実行
    run_task "$next_task"
    task_count=$((task_count + 1))
    persist_session_state
  done

  # Bug #5: 正常終了時に in_progress が残っていれば解決する
  check_stale_in_progress

  # 最終ハートビート（ループ終了）
  update_heartbeat "loop-finished"

  # Ablation 実験結果保存
  save_ablation_results

  print_summary
}

# ===== 実行 =====
main
