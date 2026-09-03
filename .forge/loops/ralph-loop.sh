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
  # 所有サーバーの停止保険（外部所有は触らない — server-lifecycle.sh 参照）
  if type teardown_server &>/dev/null; then
    teardown_server 2>/dev/null || true
  fi
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

if [ ! -f "$TASK_STACK" ]; then
  echo -e "${RED}[ERROR] task-stack.json が見つかりません: ${TASK_STACK}${NC}" >&2
  exit 1
fi

# --work-dir 必須（batch#11 R20a）: 従来の既定 = PROJECT_ROOT（ハーネス自身に生成）では checkpoint /
# ファイル数 / 聖域 / ERR trap / auto-revert の 5 経路が全て無効だった。エスケープハッチは設けない
if [ -z "${_WORK_DIR_ARG:-}" ]; then
  echo -e "${RED}[ERROR] --work-dir は必須です（生成コードの出力先 = ハーネス外の独立した git リポジトリ）${NC}" >&2
  exit 1
fi
if [ ! -d "$_WORK_DIR_ARG" ]; then
  echo -e "${RED}[ERROR] 作業ディレクトリが見つかりません: ${_WORK_DIR_ARG}${NC}" >&2
  exit 1
fi
WORK_DIR="$(cd "$_WORK_DIR_ARG" && pwd -P)"
if work_dir_is_self_write "$WORK_DIR" "$PROJECT_ROOT"; then
  echo -e "${RED}[ERROR] --work-dir がハーネス自身（またはその配下/親）です: ${WORK_DIR}。ハーネス外の独立リポジトリを指定してください${NC}" >&2
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
    L2_AUTO_RUN=$(cfg_bool "$DEV_CONFIG" '.layer_2.auto_run_after_all_tasks' true)
    L2_FAIL_CREATES_TASK=$(cfg_bool "$DEV_CONFIG" '.layer_2.fail_creates_task' true)
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
    SPRINT_CONTRACT_HUMAN_REVIEW=$(cfg_bool "$DEV_CONFIG" '.sprint_contract.human_review_on_infeasible' true)

    # Context Strategy 設定
    # 注: DEFAULT / INVESTIGATOR は参照ゼロの死に変数だったため削除（batch#10 Stage1）。
    # run_claude は -p 単発呼出で --resume 配線が無く、"continuous" は実質未実装。
    CONTEXT_STRATEGY_IMPLEMENTER=$(jq_safe -r '.context_strategy.per_agent.implementer // .context_strategy.default // "reset"' "$DEV_CONFIG")
    CONTEXT_STRATEGY_EVIDENCE_DA=$(jq_safe -r '.context_strategy.per_agent.evidence_da // .context_strategy.default // "reset"' "$DEV_CONFIG")
    CONTEXT_STRATEGY_QA_EVALUATOR=$(jq_safe -r '.context_strategy.per_agent.qa_evaluator // .context_strategy.default // "reset"' "$DEV_CONFIG")

    # best-of-N 設定（fail_count==trigger の attempt で N 候補生成 → 選択）
    BEST_OF_N_ENABLED=$(jq_safe -r '.best_of_n.enabled // false' "$DEV_CONFIG")
    BEST_OF_N=$(jq_safe -r '.best_of_n.n // 2' "$DEV_CONFIG")
    BEST_OF_N_TRIGGER=$(jq_safe -r '.best_of_n.trigger_fail_count // 2' "$DEV_CONFIG")
    # selection: mechanical（L1 exit → diff 最小）| judge（L1 同値タイの時のみ LLM がタイブレーク）
    BEST_OF_N_SELECTION=$(jq_safe -r '.best_of_n.selection // "mechanical"' "$DEV_CONFIG")
    BEST_OF_N_JUDGE_MODEL=$(jq_safe -r '.best_of_n.judge_model // "sonnet"' "$DEV_CONFIG")
    BEST_OF_N_JUDGE_TIMEOUT=$(jq_safe -r '.best_of_n.judge_timeout_sec // 240' "$DEV_CONFIG")
    BEST_OF_N_JUDGE_MAX_PATCH_LINES=$(jq_safe -r '.best_of_n.judge_max_patch_lines // 400' "$DEV_CONFIG")
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
    CONTEXT_STRATEGY_IMPLEMENTER="reset"
    CONTEXT_STRATEGY_EVIDENCE_DA="reset"
    CONTEXT_STRATEGY_QA_EVALUATOR="reset"
    BEST_OF_N_ENABLED=false
    BEST_OF_N=2
    BEST_OF_N_TRIGGER=2
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
    SAFETY_AUTO_REVERT_ON_REGRESSION=$(cfg_bool "$DEV_CONFIG" '.safety.auto_revert_on_regression' true)
    SAFETY_AUTO_COMMIT_PER_PHASE=$(cfg_bool "$DEV_CONFIG" '.safety.auto_commit_per_phase' true)
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

  # PreToolUse deny hook（batch#11 R05 後半）: 開発ループの全 claude 呼出に --settings で注入。
  # Implementer / Fixer に Bash を返した代わりに、ハーネス配下・WORK_DIR 外の書込と破壊的 git を
  # 機械拒否する（.claude/hooks/forge-guard.sh、拒否は .forge/state/guard-denials.jsonl に残る）。
  # FORGE_GUARD_DISABLE=1 で無効化（run_claude 側でも同 env を見る）。
  if [ "${FORGE_GUARD_DISABLE:-0}" != "1" ] && [ -f "${PROJECT_ROOT}/.forge/config/claude-guard-settings.json" ]; then
    _RC_SETTINGS_FILE="${PROJECT_ROOT}/.forge/config/claude-guard-settings.json"
    export _RC_SETTINGS_FILE
  fi
}

load_development_config

# ===== モデル設定の hot-reload（2026-07 batch#8 Fix7） =====
# fable⇄opus のクォータ往復が「development.json 書換だけ」で効くようにする
# （従来はモデルが起動時キャッシュのため 再起動 + counters/flow-state の状態手術が必要だった）。
# 対象はモデル系フィールドのみ。limits/counters/timeouts/enabled 系は起動時の値を維持。
# 再読込はタスク境界のみ（main while ループ先頭から呼ぶ）— 実行中タスクは開始時のモデルで完走する。
HOT_RELOAD_MODELS=$(cfg_bool "$DEV_CONFIG" '.hot_reload.models' true)
_HOT_RELOAD_LAST_MTIME=""

reload_model_config() {
  [ "$HOT_RELOAD_MODELS" = "true" ] || return 0
  [ -f "$DEV_CONFIG" ] || return 0

  local _hr_mtime
  _hr_mtime=$(stat -c %Y "$DEV_CONFIG" 2>/dev/null || echo "")
  [ -z "$_hr_mtime" ] && return 0
  if [ -z "$_HOT_RELOAD_LAST_MTIME" ]; then
    _HOT_RELOAD_LAST_MTIME="$_hr_mtime"
    return 0
  fi
  [ "$_hr_mtime" = "$_HOT_RELOAD_LAST_MTIME" ] && return 0
  _HOT_RELOAD_LAST_MTIME="$_hr_mtime"

  # 書換途中の不正 JSON は旧値を維持（jq 失敗 → 何も更新しない）
  if ! jq empty "$DEV_CONFIG" 2>/dev/null; then
    log "  ⚠ hot-reload: development.json が不正 JSON — 旧モデル設定を維持"
    return 0
  fi

  local _hr_field _hr_var _hr_new
  for _hr_field in \
    "implementer.model:IMPLEMENTER_MODEL" \
    "investigator.model:INVESTIGATOR_MODEL" \
    "evidence_da.model:EVIDENCE_DA_MODEL" \
    "qa_evaluator.model:QA_EVALUATOR_MODEL" \
    "sprint_contract.model:SPRINT_CONTRACT_MODEL" \
    "best_of_n.judge_model:BEST_OF_N_JUDGE_MODEL"; do
    _hr_var="${_hr_field#*:}"
    _hr_new=$(jq_safe -r ".${_hr_field%%:*} // empty" "$DEV_CONFIG" 2>/dev/null)
    if [ -n "$_hr_new" ] && [ "$_hr_new" != "${!_hr_var}" ]; then
      log "  ⟳ hot-reload: ${_hr_var} ${!_hr_var} → ${_hr_new}"
      printf -v "$_hr_var" '%s' "$_hr_new"
    fi
  done
  return 0
}

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
# validation-dsl.sh は common.sh が guarded source 済み（run_workdir_* / v2 セレクタ）
source "${PROJECT_ROOT}/.forge/lib/quality-ledger.sh"
source "${PROJECT_ROOT}/.forge/lib/server-lifecycle.sh"
source "${PROJECT_ROOT}/.forge/lib/mutation-audit.sh"
source "${PROJECT_ROOT}/.forge/lib/investigation.sh"
source "${PROJECT_ROOT}/.forge/lib/dev-phases.sh"
source "${PROJECT_ROOT}/.forge/lib/phase3.sh"
source "${PROJECT_ROOT}/.forge/lib/evidence-da.sh"
source "${PROJECT_ROOT}/.forge/lib/priming.sh"
source "${PROJECT_ROOT}/.forge/lib/calibration.sh"
source "${PROJECT_ROOT}/.forge/lib/qa-evaluator.sh"
source "${PROJECT_ROOT}/.forge/lib/ux-judgment.sh"
source "${PROJECT_ROOT}/.forge/lib/validation-gates.sh"
source "${PROJECT_ROOT}/.forge/lib/ablation.sh"

# ===== UX 判定設定読み込み（ablation より先 — apply_ablation_overrides が上書きする） =====
if [ -f "${PROJECT_ROOT}/.forge/config/ux-judgment.json" ]; then
  if ! validate_config "${PROJECT_ROOT}/.forge/config/ux-judgment.json" \
       "${PROJECT_ROOT}/.forge/schemas/ux-judgment.schema.json"; then
    echo -e "${RED}[ERROR] ux-judgment.json スキーマ検証失敗${NC}" >&2
    exit 1
  fi
fi
load_ux_judgment_config

# ===== ワークフロー・プロファイル適用（batch#10 Stage5） =====
# ワークフロー種別（ui-app / cli-lib / env-blocked / content / research）ごとに
# 判定トグルの束を切り替える。「Evaluator の必要性はタスク依存」の実装。
# 優先度: base config < profile < ablation（false 方向のみ後勝ち）。
# 解決順: env FORGE_PROFILE > research-config.json の .workflow > なし（無適用）
apply_workflow_profile() {
  local profile_name="${FORGE_PROFILE:-}"
  if [ -z "$profile_name" ] && [ -n "${RESEARCH_CONFIG:-}" ] && [ -f "${RESEARCH_CONFIG}" ]; then
    profile_name=$(jq_safe -r '.workflow // ""' "$RESEARCH_CONFIG" 2>/dev/null)
  fi
  [ -z "$profile_name" ] && return 0

  local profile_file="${PROJECT_ROOT}/.forge/config/profiles/${profile_name}.json"
  if [ ! -f "$profile_file" ]; then
    log "⚠ ワークフロー・プロファイル '${profile_name}' が見つかりません（${profile_file}）— base 設定で続行"
    return 0
  fi

  # 注意: jq の `//` は false を falsy 扱いするため boolean トグルには使えない
  # （ablation.sh:36-38 と同じ罠 — false 上書きが空文字に潰れる）。has() で存在判定する
  local v
  _wp_get() {
    jq_safe -r --arg k "$1" \
      '.overrides | if has($k) then (.[$k] | tostring) else "" end' "$profile_file" 2>/dev/null
  }
  v=$(_wp_get qa_evaluator_enabled);       [ -n "$v" ] && QA_EVALUATOR_ENABLED="$v"
  v=$(_wp_get ux_judgment_enabled);        [ -n "$v" ] && UX_JUDGMENT_ENABLED="$v"
  v=$(_wp_get best_of_n_enabled);          [ -n "$v" ] && BEST_OF_N_ENABLED="$v"
  v=$(_wp_get evidence_da_enabled);        [ -n "$v" ] && EVIDENCE_DA_ENABLED="$v"
  v=$(_wp_get mutation_audit_enabled);     [ -n "$v" ] && MUTATION_AUDIT_ENABLED="$v"
  v=$(_wp_get checklist_verifier_enabled); [ -n "$v" ] && CHECKLIST_VERIFIER_ENABLED="$v"
  # browser_testing.enabled は browser-test.sh が呼出時に config を直読するため env で上書き
  v=$(_wp_get browser_testing_enabled)
  if [ -n "$v" ]; then
    FORGE_BROWSER_TESTING_OVERRIDE="$v"
    export FORGE_BROWSER_TESTING_OVERRIDE
  fi
  unset -f _wp_get

  FORGE_ACTIVE_PROFILE="$profile_name"
  log "ワークフロー・プロファイル適用: ${profile_name}"
  return 0
}
apply_workflow_profile

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
# ブレーカー発火の種別（check_circuit_breakers が設定、pause_if_unfinished が消費 — batch#11 R06）
BREAKER_FIRED=""
PAUSED_EXIT_CODE_ACTIVE=0
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
    --arg sid "${FORGE_SESSION_ID:-}" \
    --arg updated "$(date -Iseconds)" \
    '{task_count: $tc, investigation_count: $ic,
      approach_scope_count: $asc, phase3_retry_count: $p3r,
      session_id: $sid, updated_at: $updated}' \
    > "${SESSION_COUNTERS_FILE}.tmp" 2>/dev/null && \
    mv "${SESSION_COUNTERS_FILE}.tmp" "$SESSION_COUNTERS_FILE" || true
}

# 復元セマンティクス（2026-07 batch#8 Fix5 — 実害: counters 持ち越しで breaker が起動 ~17秒で発火）:
#   - stored session_id が非空かつ現在の FORGE_SESSION_ID と一致 → 復元（同一ラン内クラッシュ復旧）
#   - 不一致 / 欠落（legacy ファイル）/ FORGE_SESSION_ID 未設定 → 全カウンタ 0 リセット + 即 persist
#     （forge-flow は起動毎に新 session_id を生成するため、--resume は自然に 0 リセットになる。
#      standalone ralph でクラッシュ復旧を継続したい場合は FORGE_SESSION_ID を export して再起動すること）
restore_session_state() {
  [ -f "$SESSION_COUNTERS_FILE" ] || return 0
  local _restored _stored_sid
  _restored=$(cat "$SESSION_COUNTERS_FILE" 2>/dev/null) || return 0
  _stored_sid=$(echo "$_restored" | jq -r '.session_id // ""' 2>/dev/null) || _stored_sid=""

  if [ -z "$_stored_sid" ] || [ -z "${FORGE_SESSION_ID:-}" ] || [ "$_stored_sid" != "$FORGE_SESSION_ID" ]; then
    task_count=0
    investigation_count=0
    approach_scope_count=0
    phase3_retry_count=0
    log "セッションカウンタ: session_id 不一致/欠落 (stored='${_stored_sid:-none}' current='${FORGE_SESSION_ID:-unset}') — 0 リセット"
    persist_session_state
    return 0
  fi

  task_count=$(echo "$_restored" | jq -r '.task_count // 0' 2>/dev/null) || task_count=0
  investigation_count=$(echo "$_restored" | jq -r '.investigation_count // 0' 2>/dev/null) || investigation_count=0
  approach_scope_count=$(echo "$_restored" | jq -r '.approach_scope_count // 0' 2>/dev/null) || approach_scope_count=0
  phase3_retry_count=$(echo "$_restored" | jq -r '.phase3_retry_count // 0' 2>/dev/null) || phase3_retry_count=0

  log "セッションカウンタ復元 (同一セッション): task=${task_count}, investigation=${investigation_count}, approach=${approach_scope_count}"
}

# クラッシュ復旧時にカウンタを復元
restore_session_state

# ===== ハートビート =====
# タスク実行ごとに現在状態を JSON で書き出す（デーモンモードの可観測性確保）
# update_heartbeat <current_task> [stale_threshold_min]
# stale_threshold_min は monitor.sh のハング判定閾値の自己申告（既定 15、research-loop と同形）。
# batch#11 R07b: Implementer の 1 呼出は timeout 2400 秒（40 分）に達し得るため、固定 15 分では
# 正常な長時間呼出が「ハング」と誤報される（4.5f で実測）。run_claude 前後のフックで動的に申告する
update_heartbeat() {
  local current_task="${1:-}"
  local stale_threshold_min="${2:-15}"
  case "$stale_threshold_min" in ''|*[!0-9]*) stale_threshold_min=15 ;; esac
  local elapsed_sec=$((SECONDS - ${START_SECONDS:-$SECONDS}))
  local elapsed_min=$((elapsed_sec / 60))
  jq -n \
    --arg loop "ralph" \
    --arg task "$current_task" \
    --argjson tc "${task_count:-0}" \
    --argjson ic "${investigation_count:-0}" \
    --arg elapsed "${elapsed_min}m" \
    --arg ts "$(date -Iseconds)" \
    --argjson th "$stale_threshold_min" \
    '{loop: $loop, current_task: $task, task_count: $tc,
     investigation_count: $ic, elapsed: $elapsed, heartbeat_at: $ts,
     stale_threshold_min: $th}' \
    > "${HEARTBEAT_FILE}.tmp" 2>/dev/null && mv "${HEARTBEAT_FILE}.tmp" "$HEARTBEAT_FILE"
}

# run_claude の前後で呼ばれる heartbeat フック（batch#11 R07b。common.sh run_claude が
# `type forge_heartbeat_hook` で存在確認して呼ぶ — research-loop 等では未定義 = no-op）。
# 閾値 = timeout/60 + 5 分（timeout 0 = 無制限は 1440、空 = 完了後のリセットで 15）。
# バックグラウンドでの定期刻みは採らない（孤児プロセスが本番 heartbeat.json を書き続けるリスク）
_HB_CURRENT_TASK=""
# 失敗の由来（batch#11 R15）。handle_task_fail の直前で設定、update_task_fail_count が消費してリセット
_RT_FAIL_CAUSE=""
forge_heartbeat_hook() {
  local stage="${1:-}" timeout_sec="${2:-}" th=15
  if [ -n "$timeout_sec" ]; then
    case "$timeout_sec" in
      0) th=1440 ;;
      *[!0-9]*) th=15 ;;
      *) th=$(( timeout_sec / 60 + 5 )) ;;
    esac
  fi
  update_heartbeat "${_HB_CURRENT_TASK:-$stage}" "$th" 2>/dev/null || true
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

  # previous_status: completed→pending の人間差戻しを detect_reworked_tasks が
  # キャリブレーション事例として検出するための記録（記録後に del される — P0-1）
  jq --arg id "$task_id" --arg s "$new_status" '
    .tasks |= map(
      if .task_id == $id then
        .previous_status = .status |
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
  # cause（batch#11 R15）: 失敗の由来。implementer / harness_guard / l1 / assertion / l3 / authoring / mutation。
  # 呼出側が直前に _RT_FAIL_CAUSE を設定する（未設定は unknown）。runs.jsonl の fail_cause 内訳に使う
  local _cause="${_RT_FAIL_CAUSE:-unknown}"
  case "$_cause" in (''|*[!a-z0-9_]*) _cause="unknown" ;; esac
  record_task_event "$task_id" "fail_recorded" "{\"fail_count\":$count,\"cause\":\"${_cause}\"}"
  _RT_FAIL_CAUSE=""
}

# ステータス別タスク集計
count_tasks_by_status() {
  local status="$1"
  jq --arg s "$status" '[.tasks[] | select(.status == $s)] | length' "$TASK_STACK"
}

# ===== 実装プロンプト構築 =====
# ===== 出口基準の CLI 契約抽出（batch#11 R08a、純関数） =====
# dev-phase の exit_criteria（type=auto）の command から「先頭コマンド形」だけを取り出す。
# 各行は最初の | || && ; で切り、コマンド名・サブコマンド・フラグ名・引数順を残す。expect /
# description / human_check は含めない（期待値を見せない = held-out 維持）。
# 背景: 4.5f では L3 コマンドとスクリプトの CLI 契約不一致（--out vs --output、引数順）が結合時まで
# 露見せず同一案件で 5 回起きた。Implementer は出口基準を見ないので防ぎようがなかった。
# 使い方: build_cli_contract_context <task-stack|criteria json> <dev_phase_id>  → 1 行 1 コマンド形（sort -u）
build_cli_contract_context() {
  local file="${1:-}" pid="${2:-}" line
  [ -n "$file" ] && [ -f "$file" ] && [ -n "$pid" ] || return 0
  jq_safe -r --arg pid "$pid" '
    (.phases // [])[] | select(.id == $pid) | (.exit_criteria // [])[]
    | select((.type // "auto") == "auto") | .command // empty' "$file" 2>/dev/null \
  | while IFS= read -r line; do
      line="${line%%'||'*}"; line="${line%%'&&'*}"; line="${line%%|*}"; line="${line%%;*}"
      line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] && printf '%s\n' "$line"
    done | sort -u
}

build_implementer_prompt() {
  local task_json="$1"
  local task_id
  task_id=$(echo "$task_json" | jq_safe -r '.task_id')

  # 出口基準の CLI 契約（batch#11 R08a）: task-stack の phases（criteria から複製）→ 無ければ criteria
  local cli_contract="（この dev-phase の出口基準に auto コマンドは無い）"
  local _bp_phase _bp_cc=""
  _bp_phase=$(echo "$task_json" | jq_safe -r '.dev_phase_id // "mvp"' 2>/dev/null)
  if [ -n "${TASK_STACK:-}" ] && [ -f "${TASK_STACK}" ]; then
    _bp_cc=$(build_cli_contract_context "$TASK_STACK" "$_bp_phase" 2>/dev/null || true)
  fi
  if [ -z "$_bp_cc" ] && [ -n "${CRITERIA_FILE:-}" ] && [ -f "${CRITERIA_FILE}" ]; then
    _bp_cc=$(build_cli_contract_context "$CRITERIA_FILE" "$_bp_phase" 2>/dev/null || true)
  fi
  [ -n "$_bp_cc" ] && cli_contract="$_bp_cc"

  # Layer 1 テスト情報（v2 checks があれば人間可読サマリーを見せる — batch#8 Stage3）
  local l1_command
  if type task_layer_is_v2 &>/dev/null && task_layer_is_v2 "$task_json" 1; then
    l1_command="validation v2 checks:
$(render_checks_summary "$task_json" 1)"
  else
    l1_command=$(echo "$task_json" | jq_safe -r '.validation.layer_1.command // "echo \"No Layer 1 test defined\""')
  fi
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

  # Salvage patch 注入（batch#10 Stage2 — ロールバック消失ループ対策）:
  # 前回試行のロールバックで巻き戻された変更を task_checkpoint_restore が退避している。
  # 有効な部分の再利用を促し、「直したのに消えて振り出し」の永久ループを断つ
  local salvage_patch="${CHECKPOINT_DIR:-${PROJECT_ROOT}/.forge/state/checkpoints}/${task_id}.salvage.patch"
  if [ -s "$salvage_patch" ]; then
    local salvage_files salvage_body
    salvage_files=$(grep -E '^diff --git' "$salvage_patch" 2>/dev/null | head -30 | sed 's/^diff --git a\///; s/ b\/.*$//' || true)
    salvage_body=$(head -400 "$salvage_patch" 2>/dev/null || true)
    inv_fix="${inv_fix}

## 前回試行の退避パッチ（ロールバックで巻き戻された変更 — 自動退避）
前回の試行は安全制限によりロールバックされたが、変更内容は以下に退避されている。
有効な部分は再利用してよい（失敗原因に関係ない修正まで作り直さないこと）:
対象ファイル:
${salvage_files:-（解析不能 — パッチ本文を参照）}
パッチ（先頭400行）:
${salvage_body}"
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

    # テスト聖域化の警告注入（S4.6 の予防的プロンプト）
    local ts_enabled_bp
    ts_enabled_bp=$(jq_safe -r '.test_sanctity.enabled // false' "$cb_config" 2>/dev/null)
    if [ "$ts_enabled_bp" = "true" ]; then
      local allows_bp
      allows_bp=$(echo "$task_json" | jq_safe -r '.allows_test_edits // false' 2>/dev/null)
      if [ "$allows_bp" = "true" ]; then
        context="${context}

## 既存テストの扱い
このタスクは既存テストファイルの修正が明示的に許可されている（allows_test_edits=true）。"
      else
        context="${context}

## 既存テストの改変禁止（自動検出 — 違反すると自動ロールバック）
コミット済みの既存テストファイル（*.test.* / *.spec.* / *.e2e.* / tests/ / __tests__/ 配下）と
.forge/state/phase-tests/ のスクリプトの変更・削除は禁止。
テストが間違っていると考えた場合も改変せず、実装側で対応するか失敗として報告すること。
このタスクで新規作成するテストファイルは対象外。"
      fi
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

  # 自己定位儀式（Orientation）注入 — 毎 attempt fresh に生成（priming と異なりキャッシュしない）
  local orientation=""
  orientation=$(build_orientation_context "$WORK_DIR" "${TASK_STACK:-}" 2>/dev/null || true)
  if [ -n "$orientation" ]; then
    context="${context}

${orientation}"
  fi

  # ファイル数上限を safety profile の実効値からプレースホルダ注入（enforcement と恒久同期）
  local _bp_task_type _bp_soft _bp_hard
  _bp_task_type=$(echo "$task_json" | jq_safe -r '.task_type // "implementation"' 2>/dev/null)
  _bp_soft=$(get_safety_profile "$_bp_task_type" "max_files_per_task" "${SAFETY_MAX_FILES_PER_TASK:-15}")
  _bp_hard=$(get_safety_profile "$_bp_task_type" "max_files_hard_limit" "${SAFETY_MAX_FILES_HARD_LIMIT:-30}")

  render_template "${TEMPLATES_DIR}/implementer-prompt.md" \
    "TASK_JSON"            "$task_json" \
    "LAYER1_COMMAND"       "$l1_command" \
    "LAYER1_TIMEOUT"       "$l1_timeout" \
    "LAYER2_INFO"          "$l2_info" \
    "INVESTIGATOR_FIX"     "$inv_fix" \
    "REQUIRED_BEHAVIORS"   "$required_behaviors" \
    "MAX_FILES_SOFT"       "$_bp_soft" \
    "MAX_FILES_HARD"       "$_bp_hard" \
    "CLI_CONTRACT"         "$cli_contract" \
    "CONTEXT"              "$context"
}

# ===== Layer 1 テスト実行 =====
execute_layer1_test() {
  local command="$1"
  local timeout_sec="${2:-$L1_DEFAULT_TIMEOUT}"
  # 旧 task-stack / Planner 逸脱の救済: 先頭 bash -c "…" を unwrap（生成時展開の二重防御。
  # run_workdir_shell が bash -c "cd … && $command" と再ラップするため、二重ラップは内側引用符を破壊する）
  command=$(unwrap_bash_c "$command")
  # legacy 実行意味論は validation-dsl.sh の共有 executor に一元化（batch#8 Stage3）
  run_workdir_shell "$timeout_sec" "$WORK_DIR" "$command"
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
_RT_LOADED_TASK_ID=""   # _RT_TASK_JSON を最後にロードした task_id（境界検出/可視化用）
_RT_LOADED_DEV_PHASE="" # _RT_TASK_JSON を最後にロードした dev_phase（境界検出/可視化用）

# ===== _RT_TASK_JSON ロード（タスク境界 / dev_phase 境界での再読込 + 安全ガード） =====
# task-stack.json から指定タスクの定義を「単一スナップショット」として取得し _RT_TASK_JSON に格納する。
#
# 呼び出し契約（重要）:
#   - 本関数は task_prepare()（各タスク/各試行の開始 = タスク境界）でのみ呼ぶこと。
#   - task_implement() / task_validate_changes() / task_run_l1_test() / task_run_l3_test() /
#     task_finalize() などの「同一タスク処理中（サブステージ）」では呼ばない。
#     これにより処理途中で定義がスワップされず、全サブステージは常に同一スナップショットを参照する。
#
# dev_phase 境界:
#   - current_dev_phase が前回ロード時 (_RT_LOADED_DEV_PHASE) と異なる場合は dev_phase 境界を
#     跨いだとみなし、ステイルキャッシュ解消のため再読込した旨をログに残す（可観測性）。
#
# 安全ガード:
#   - task-stack.json が不正 JSON / ファイル不在 / 対象タスク不在の場合は、旧 _RT_TASK_JSON を温存し
#     警告のみ（クラッシュしない / 空値で上書きしない）。
#   - read-only。task-stack.json へは一切書き込まないため、11 ステータス状態機械の status を
#     巻き戻したり上書きしたりしない（status は task-stack.json の現在値がそのまま読まれる）。
#   - get_task_json を1回だけ呼び単一スナップショットを確定する。以降の全参照が同一値を読むため
#     値の不整合は発生しない。
#
# 使い方: reload_rt_task_json <task_id> [current_dev_phase]
# 戻り値: 0 = _RT_TASK_JSON を新スナップショットで更新, 1 = 旧キャッシュ温存（再読込せず）
reload_rt_task_json() {
  local task_id="$1"
  local current_dev_phase="${2:-}"
  local prev_dev_phase="${_RT_LOADED_DEV_PHASE:-}"

  # 入力ガード: task_id 空 → 旧キャッシュ温存
  if [ -z "$task_id" ]; then
    log "  ⚠ [task-reload] task_id 空 — 旧キャッシュ温存"
    return 1
  fi

  # 不正 JSON / ファイル不在ガード: 旧キャッシュ温存 + 警告（クラッシュしない）
  if [ ! -f "$TASK_STACK" ]; then
    log "  ⚠ [task-reload] task-stack.json 不在 — 旧キャッシュ温存 (task=${task_id})"
    return 1
  fi
  if ! jq empty "$TASK_STACK" >/dev/null 2>&1; then
    log "  ⚠ [task-reload] task-stack.json が不正 JSON — 旧キャッシュ温存 (task=${task_id})"
    return 1
  fi

  # 単一スナップショット取得（以降の全参照が同一値を読む → 値の不整合ゼロ）
  local _snapshot
  _snapshot=$(get_task_json "$task_id" 2>/dev/null || true)

  # 対象タスク不在 → 旧キャッシュ温存
  if [ -z "$_snapshot" ]; then
    log "  ⚠ [task-reload] タスク ${task_id} が task-stack.json に不在 — 旧キャッシュ温存"
    return 1
  fi

  # スナップショット確定（read-only: status を含む全フィールドは task-stack.json の現値）
  _RT_TASK_JSON="$_snapshot"
  _RT_LOADED_TASK_ID="$task_id"
  _RT_LOADED_DEV_PHASE="$current_dev_phase"

  # dev_phase 境界ログ（ステイルキャッシュ解消の可視化）
  if [ -n "$prev_dev_phase" ] && [ "$current_dev_phase" != "$prev_dev_phase" ]; then
    log "  [phase-reload] dev_phase 境界 (${prev_dev_phase} → ${current_dev_phase}) — _RT_TASK_JSON 再読込 (task=${task_id})"
  fi

  return 0
}

# ===== タスク前処理: チェックポイント作成 + プロンプト構築 =====
# 使い方: task_prepare <task_id> <task_dir>
# 設定: _RT_TASK_JSON, _RT_PROMPT, _RT_OUTPUT, _RT_LOG_FILE,
#       _RT_AGENT_FILE, _RT_AGENT_DISALLOWED, _RT_TASK_TYPE
# 戻り値: 0=成功
task_prepare() {
  local task_id="$1"
  local task_dir="$2"

  # タスク情報を抽出して共有変数にセット（タスク/dev_phase 境界での再読込 + 安全ガード）。
  # フェーズ境界を跨ぐ場合は task-stack.json の外部更新（例: timeout_sec 変更）を取り込み
  # ステイルキャッシュを解消する。不正 JSON 時は旧キャッシュを温存するが、初回（キャッシュ空）は
  # 従来どおり直接ロードでフォールバックする。
  if ! reload_rt_task_json "$task_id" "${CURRENT_DEV_PHASE:-}"; then
    if [ -z "$_RT_TASK_JSON" ]; then
      _RT_TASK_JSON=$(get_task_json "$task_id")
    fi
  fi
  echo "$_RT_TASK_JSON" > "${task_dir}/task-definition.json"

  # S3: タスク実行前の Git Checkpoint 作成
  # 初回 attempt（fail_count==0 かつ qa_fail_count==0）では .base_ref（タスク基準 SHA）も書く（batch#11 R03）
  local _rt_first_attempt=0
  if [ "$(echo "$_RT_TASK_JSON" | jq_safe -r '((.fail_count // 0) + (.qa_fail_count // 0))' 2>/dev/null)" = "0" ]; then
    _rt_first_attempt=1
  fi
  if [ "$WORK_DIR" != "$PROJECT_ROOT" ]; then
    task_checkpoint_create "$WORK_DIR" "$task_id" "$_rt_first_attempt"
    # 聖域化: dev-phase テストスクリプト（WORK_DIR 外）のスナップショット
    snapshot_phase_tests "$task_id"
  fi

  # Stall marker クリーンアップ: fail_count==0（新規 or Investigator リセット後）のみ除去。
  # 従来は毎 attempt 無条件 rm しており、handle_task_fail が書いた STALL 警告が
  # 次 attempt の build_implementer_prompt に一度も届かない死配線だった（2026-07-02 発見）。
  local _rt_fail_count_pre
  _rt_fail_count_pre=$(echo "$_RT_TASK_JSON" | jq_safe -r '.fail_count // 0' 2>/dev/null)
  if [ "${_rt_fail_count_pre:-0}" = "0" ]; then
    rm -f "${task_dir}/stall-marker.txt" 2>/dev/null || true
    # salvage patch も新規サイクル開始時にクリア（stall-marker と同じライフサイクル）
    rm -f "${CHECKPOINT_DIR:-${PROJECT_ROOT}/.forge/state/checkpoints}/${task_id}.salvage.patch" 2>/dev/null || true
  fi

  # Safety Profile: task_type に応じた制約を適用
  _RT_TASK_TYPE=$(echo "$_RT_TASK_JSON" | jq_safe -r '.task_type // "implementation"')
  local profile_disallowed
  profile_disallowed=$(get_safety_profile "$_RT_TASK_TYPE" "disallowed_tools" "WebSearch,WebFetch")

  # guard hook 用のタスク文脈（batch#11 R05）: 既存テスト判定の基準 SHA と allows_test_edits
  export FORGE_GUARD_TASK_ID="$task_id"
  if type task_base_ref &>/dev/null; then
    export FORGE_GUARD_BASE_REF="$(task_base_ref "$task_id" "$WORK_DIR" 2>/dev/null || echo "")"
  fi
  export FORGE_GUARD_ALLOW_TEST_EDITS="$(echo "$_RT_TASK_JSON" | jq_safe -r 'if (.allows_test_edits|type)=="boolean" then .allows_test_edits else false end' 2>/dev/null || echo false)"

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
    # batch#11 R05: Fixer も safety profile に従う（従来はリテラルで Bash 禁止 → 再試行 24 回すべてが
    # テストを実行できないまま QA/Investigator の要求を満たせなかった）。破壊的 git 操作は PreToolUse
    # deny hook（forge-guard.sh）で機械的に拒否する
    _RT_AGENT_DISALLOWED="$profile_disallowed"
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
# ===== Implementer 実行の生カーネル（fail 処理なし） =====
# task_implement と task_implement_best_of_n の共有実行部。
# 引数: $1=task_id, $2=prompt（省略時 _RT_PROMPT）
# 戻り値: 0=成功（_RT_OUTPUT に出力昇格済み）, 1=失敗（handle_task_fail は呼ばない）
task_implement_raw() {
  local task_id="$1"
  local prompt="${2:-$_RT_PROMPT}"

  # S2: スコープ制限 — Safety Profile に従う
  export _RC_CONTEXT_STRATEGY="${CONTEXT_STRATEGY_IMPLEMENTER:-reset}"
  metrics_start
  # exit code をそのまま返す（batch#11 R07a）: 従来は 1 に潰れ、143（kill）/21（予算）/22（クォータ）が
  # errors.jsonl で "unknown" になっていた
  local _tir_rc=0
  retry_with_backoff 3 1 run_claude "$IMPLEMENTER_MODEL" "$_RT_AGENT_FILE" \
    "$prompt" "$_RT_OUTPUT" "$_RT_LOG_FILE" "$_RT_AGENT_DISALLOWED" "$IMPLEMENTER_TIMEOUT" "$WORK_DIR" || _tir_rc=$?
  if [ "$_tir_rc" -ne 0 ]; then
    metrics_record "implementer-${task_id}" "false"
    return "$_tir_rc"
  fi
  metrics_record "implementer-${task_id}" "true"

  # .pending → 本ファイルに昇格（実装出力はJSONではないため validate_json を通さない）
  if [ -f "${_RT_OUTPUT}.pending" ]; then
    mv "${_RT_OUTPUT}.pending" "$_RT_OUTPUT"
  fi

  return 0
}

task_implement() {
  local task_id="$1"
  local task_dir="$2"

  # 実装実行（コード + テスト生成）
  local _impl_rc=0
  task_implement_raw "$task_id" || _impl_rc=$?
  if [ "$_impl_rc" -ne 0 ]; then
    # デバッグログからレートリミット情報を抽出してエラー分類精度を向上
    local _impl_err_detail="Claude実行エラー"
    if [ -f "$_RT_LOG_FILE" ]; then
      local _rate_hint
      _rate_hint=$(tail -50 "$_RT_LOG_FILE" 2>/dev/null | grep -oi "429\|too many requests\|rate.limit\|rate_limit\|overloaded" | head -1 || true)
      [ -n "$_rate_hint" ] && _impl_err_detail="Claude実行エラー (rate_limit: ${_rate_hint})"
    fi
    record_error "implementer-${task_id}" "$_impl_err_detail" "$_impl_rc"
    log "  ✗ Implementer [${task_id}] ${_impl_err_detail} (exit=${_impl_rc})"
    case "$_impl_rc" in
      143|130)
        # 人間の停止は失敗ではない（batch#11 R07a）: fail_count を進めず再キューして次回に持ち越す
        requeue_task_after_interrupt "$task_id" ;;
      *)
        _RT_FAIL_CAUSE="implementer"
        handle_task_fail "$task_id" "$task_dir" "$_impl_err_detail" ;;
    esac
    return 1
  fi

  return 0
}

# ===== best-of-N LLM judge タイブレーク =====
# L1 exit が同値の候補集合に対し、タスク定義と各候補の patch を提示して1つ選ばせる。
# 機械選択の「diff 行数最小」は内容を見ない粗い代理指標のため、タイブレークのみ置換する。
# L1 の機械的証拠が第一基準（Evidence > assumptions）である構造は変えない。
# 引数: $1=task_id, $2=task_dir, $3=候補番号リスト（スペース区切り、例 "1 3"）
# 前提: _RT_TASK_JSON が設定済み
# stdout: 選択候補番号。judge 失敗/リスト外応答は出力なしで return 1（呼び出し元が機械選択へフォールバック）
bon_judge_select() {
  local task_id="$1"
  local task_dir="$2"
  local tie_list="$3"

  local schema_file="${PROJECT_ROOT}/.forge/schemas/best-of-n-judge.schema.json"
  local agent_file="${PROJECT_ROOT}/.claude/agents/best-of-n-judge.md"
  local judge_out="${task_dir}/bon-judge.json"
  local judge_log="${PROJECT_ROOT}/.forge/logs/development/bon-judge-${task_id}.log"
  mkdir -p "$(dirname "$judge_log")"

  local task_context
  task_context=$(echo "$_RT_TASK_JSON" | jq_safe -c '{task_id, description, required_behaviors: (.required_behaviors // [])}' 2>/dev/null)

  local prompt="以下のタスクに対する複数の実装候補（git patch、いずれも L1 テスト結果は同値）から、タスクの意図を最も正しく満たす候補を1つ選んでください。

## タスク定義
${task_context}
"
  local i max_lines="${BEST_OF_N_JUDGE_MAX_PATCH_LINES:-400}"
  for i in $tie_list; do
    prompt="${prompt}
## 候補 ${i}（diff $(wc -l < "${task_dir}/bon-cand-${i}.patch" 2>/dev/null | tr -d ' ') 行、以下は先頭 ${max_lines} 行まで）
\`\`\`diff
$(head -n "$max_lines" "${task_dir}/bon-cand-${i}.patch" 2>/dev/null)
\`\`\`
"
  done
  prompt="${prompt}
selected には ${tie_list// /, } のいずれかのみを指定すること。"

  export _RC_CONTEXT_STRATEGY="reset"
  if ! run_claude "${BEST_OF_N_JUDGE_MODEL:-sonnet}" "$agent_file" "$prompt" \
    "$judge_out" "$judge_log" "Write,Edit,MultiEdit,Bash,WebSearch,WebFetch" \
    "${BEST_OF_N_JUDGE_TIMEOUT:-240}" "" "$schema_file"; then
    return 1
  fi
  if [ -f "${judge_out}.pending" ]; then
    mv "${judge_out}.pending" "$judge_out"
  fi

  local sel
  sel=$(jq_safe -r '.selected // 0' "$judge_out" 2>/dev/null)
  [[ "$sel" =~ ^[0-9]+$ ]] || return 1
  # tie 集合外の番号は無効（judge の暴走防御）
  local t
  for t in $tie_list; do
    if [ "$t" = "$sel" ]; then
      printf '%s' "$sel"
      return 0
    fi
  done
  return 1
}

# ===== best-of-N 実装（N 候補逐次生成 → L1 判定 → 選択採用） =====
# fail_count が trigger（既定2）に達したタスクの attempt で発動する
# 「Investigator（fail_count=3）前の最後の一手」。1回だけ発動し無限化しない。
# git worktree ではなく task_checkpoint（実績ある復元機構）による同一ツリー逐次試行:
# 候補ごとに 実装 → L1 素実行 → patch/出力保存 → checkpoint 復元、を繰り返し、
# L1 pass 優先 → diff 行数最小で選択して patch を適用する。
# Evidence-DA の分析は .evidence_da_result として TASK_JSON 経由で全候補に既に届いており、
# 候補2以降の多様化指示は「その分析と直交する案」を明示参照する。
# 全候補失敗でも return 0 で通常フロー（後段 L1 → handle_task_fail）へ流す。
task_implement_best_of_n() {
  local task_id="$1"
  local task_dir="$2"
  local n="${BEST_OF_N:-2}"

  log "  [BEST-OF-N] fail_count=${BEST_OF_N_TRIGGER:-2} 到達 — ${n} 候補生成モード（Investigator 前の最後の一手）"

  local l1_command l1_timeout
  l1_command=$(echo "$_RT_TASK_JSON" | jq_safe -r '.validation.layer_1.command // ""')
  l1_timeout=$(echo "$_RT_TASK_JSON" | jq_safe -r '.validation.layer_1.timeout_sec // '"${L1_DEFAULT_TIMEOUT:-200}")
  [[ "$l1_timeout" =~ ^[0-9]+$ ]] || l1_timeout="${L1_DEFAULT_TIMEOUT:-200}"

  local i
  local -a cand_l1=() cand_diff=()

  for i in $(seq 1 "$n"); do
    local prompt="$_RT_PROMPT"
    if [ "$i" -gt 1 ]; then
      prompt="${prompt}

## 候補多様化指示（best-of-N 試行 ${i}/${n} — 自動注入）
これまでの試行と根本的に異なるアプローチ（別のアルゴリズム、別のライブラリ、別のファイル構成）を採ること。
タスク定義内の evidence_da_result や STALL 警告があれば、その分析と直交する案を優先すること。"
    fi

    log "  [BEST-OF-N] 候補 ${i}/${n} 実装中..."
    if ! task_implement_raw "$task_id" "$prompt"; then
      log "  [BEST-OF-N] 候補 ${i}: 実装失敗 — skip"
      cand_l1[$i]=999
      cand_diff[$i]=999999
      task_checkpoint_restore "$WORK_DIR" "$task_id" 0 2>/dev/null || true
      continue
    fi
    cp "$_RT_OUTPUT" "${task_dir}/bon-cand-${i}-output.txt" 2>/dev/null || true

    # L1 素実行（fail 処理なし。候補の良否判定材料）
    local l1_exit=0
    if type task_layer_is_v2 &>/dev/null && task_layer_is_v2 "$_RT_TASK_JSON" 1; then
      # v2 checks で候補スコアリング（batch#8 Stage3）
      run_layer_checks "$_RT_TASK_JSON" 1 "$WORK_DIR" "$l1_timeout" "$task_id" \
        > "${task_dir}/bon-cand-${i}-l1.txt" 2>&1 || l1_exit=$?
    elif [ -n "$l1_command" ]; then
      execute_layer1_test "$l1_command" "$l1_timeout" > "${task_dir}/bon-cand-${i}-l1.txt" 2>&1 || l1_exit=$?
    fi

    # 候補 diff を保存（untracked 新規ファイルを intent-to-add で diff に載せる）
    git -C "$WORK_DIR" add --intent-to-add -A 2>/dev/null || true
    git -C "$WORK_DIR" diff HEAD > "${task_dir}/bon-cand-${i}.patch" 2>/dev/null || true
    git -C "$WORK_DIR" reset -q 2>/dev/null || true
    local diff_lines
    diff_lines=$(wc -l < "${task_dir}/bon-cand-${i}.patch" 2>/dev/null | tr -d ' ')
    diff_lines=${diff_lines:-999999}

    cand_l1[$i]=$l1_exit
    cand_diff[$i]=$diff_lines
    log "  [BEST-OF-N] 候補 ${i}: L1 exit=${l1_exit}, diff=${diff_lines}行"

    # 次候補（および採用 patch 適用）のため毎回リセットする一貫方式
    # （第3引数 0 = salvage 退避を抑止 — 候補間リセットは損失ではない）
    task_checkpoint_restore "$WORK_DIR" "$task_id" 0 2>/dev/null || true
  done

  # 選択: L1 exit 最小（pass=0 優先）→ diff 行数最小 → 先着
  local sel=0 sel_l1=999 sel_diff=999999
  for i in $(seq 1 "$n"); do
    local cl1="${cand_l1[$i]:-999}" cdf="${cand_diff[$i]:-999999}"
    if [ "$cl1" -lt "$sel_l1" ] || { [ "$cl1" -eq "$sel_l1" ] && [ "$cdf" -lt "$sel_diff" ]; }; then
      sel=$i
      sel_l1=$cl1
      sel_diff=$cdf
    fi
  done
  local selection_method="mechanical"

  # L1 同値タイが2候補以上 && selection=judge → LLM judge でタイブレーク。
  # L1 が候補を判別できた場合は judge を呼ばない（機械的証拠優先 + LLM 呼出コスト節約）。
  # judge 失敗時は従来の機械選択（diff 最小 = 上の sel）のまま続行する。
  if [ "${BEST_OF_N_SELECTION:-mechanical}" = "judge" ] && [ "$sel" -ne 0 ]; then
    local tie_list="" tie_count=0
    for i in $(seq 1 "$n"); do
      if [ "${cand_l1[$i]:-999}" -eq "$sel_l1" ] && [ -s "${task_dir}/bon-cand-${i}.patch" ]; then
        tie_list="${tie_list:+$tie_list }$i"
        tie_count=$((tie_count + 1))
      fi
    done
    if [ "$tie_count" -ge 2 ]; then
      log "  [BEST-OF-N] L1 同値 (exit=${sel_l1}) の候補が ${tie_count} 件 — LLM judge でタイブレーク"
      local judge_sel
      if judge_sel=$(bon_judge_select "$task_id" "$task_dir" "$tie_list"); then
        sel="$judge_sel"
        sel_l1="${cand_l1[$sel]:-999}"
        sel_diff="${cand_diff[$sel]:-999999}"
        selection_method="judge"
        log "  [BEST-OF-N] judge 選択: 候補 ${sel}"
      else
        log "  ⚠ [BEST-OF-N] judge 失敗/無効応答 — 機械選択（diff 最小）へフォールバック"
      fi
    fi
  fi

  if [ "$sel" -eq 0 ] || [ ! -s "${task_dir}/bon-cand-${sel}.patch" ]; then
    log "  [BEST-OF-N] 有効な候補なし — 通常フローへ（後段で fail 処理）"
    record_task_event "$task_id" "best_of_n_completed" "{\"selected\": 0, \"n\": ${n}}" || true
    return 0
  fi

  log "  [BEST-OF-N] 候補 ${sel} を採用（L1 exit=${sel_l1}, diff=${sel_diff}行, selection=${selection_method}）— patch 適用"
  # batch#11 R02: task_dir は DEV_LOG_DIR 由来の PROJECT_ROOT 相対パス。git -C で cwd が WORK_DIR に
  # 移るため相対のままでは ENOENT（2 案件通算 9/9 失敗、L1 合格候補 5 件を破棄した根因）。絶対化する。
  local _bon_patch="${task_dir}/bon-cand-${sel}.patch"
  case "$_bon_patch" in /*|[A-Za-z]:*) ;; *) _bon_patch="${PROJECT_ROOT:-.}/${_bon_patch}" ;; esac
  local _bon_apply_ok=false
  if git -C "$WORK_DIR" apply "$_bon_patch" 2>"${task_dir}/bon-apply-err.txt"; then
    _bon_apply_ok=true
    cp "${task_dir}/bon-cand-${sel}-output.txt" "$_RT_OUTPUT" 2>/dev/null || true
  else
    log "  ⚠ [BEST-OF-N] patch 適用失敗 — 候補なしで続行（後段 L1 が真実を判定）"
    notify_human "warning" "タスク ${task_id}: best-of-N patch 適用失敗" \
      "$(head -5 "${task_dir}/bon-apply-err.txt" 2>/dev/null)"
    record_task_event "$task_id" "best_of_n_apply_failed" "{\"selected\": ${sel}, \"patch\": \"${_bon_patch}\"}" || true
  fi
  record_task_event "$task_id" "best_of_n_completed" \
    "{\"selected\": ${sel}, \"n\": ${n}, \"l1_exit\": ${sel_l1}, \"diff_lines\": ${sel_diff}, \"selection\": \"${selection_method}\", \"apply_ok\": ${_bon_apply_ok}}" || true
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
      _RT_FAIL_CAUSE="harness_guard"
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
    _RT_FAIL_CAUSE="implementer"
    handle_task_fail "$task_id" "$task_dir" "Implementer ファイル未作成: テストコマンドが参照する以下のファイルが存在しません:
${missing_files}
Implementer が Write ツールでファイルを実際に作成していない可能性があります。"
    return 1
  fi

  # S4.6: テスト聖域化（既存テスト改変の機械ブロック — reward hacking 予防）
  if [ "$WORK_DIR" != "$PROJECT_ROOT" ]; then
    if ! validate_test_sanctity "$WORK_DIR" "$task_id" "$_RT_TASK_JSON"; then
      task_checkpoint_restore "$WORK_DIR" "$task_id" 2>/dev/null || true
      _RT_FAIL_CAUSE="harness_guard"
      handle_task_fail "$task_id" "$task_dir" "テスト聖域化違反: タスク開始時点で存在した（HEAD 追跡済み）テストファイルの改変/削除を検出（自動ロールバック済み）。既存テストの変更は allows_test_edits=true のタスクでのみ許可されます。テストが誤っていると考える場合は改変せず失敗として報告すること。"
      return 1
    fi
    # dev-phase テストスクリプト（ハーネス所有物・WORK_DIR 外）の改変検証
    if ! verify_phase_tests_integrity "$task_id"; then
      _RT_FAIL_CAUSE="harness_guard"
      handle_task_fail "$task_id" "$task_dir" "dev-phase テストスクリプト（.forge/state/phase-tests/）の改変を検出。ハーネス所有物への変更は禁止です（バックアップから復元済み）。"
      return 1
    fi
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
  local test_timeout timeout_sec timeout_type
  timeout_sec=$(echo "$_RT_TASK_JSON" | jq_safe -r '.validation.layer_1.timeout_sec // '"$L1_DEFAULT_TIMEOUT")
  timeout_type=$(echo "$_RT_TASK_JSON" | jq_safe -r '.validation.layer_1.timeout_sec | type' 2>/dev/null | tr -d '\r')
  # 整数バリデーション: 空文字列・文字列型数値・型違いを防御し L1_DEFAULT_TIMEOUT にフォールバック
  if [ "$timeout_type" = "string" ] || ! [[ "$timeout_sec" =~ ^[0-9]+$ ]]; then
    log "  ⚠ invalid timeout_sec '${timeout_sec}' for layer_1, fallback to L1_DEFAULT_TIMEOUT=${L1_DEFAULT_TIMEOUT}"
    timeout_sec="$L1_DEFAULT_TIMEOUT"
  fi
  # effort 連動倍率: agent_effort.implementer に応じて拡張（0=無制限は維持、結果は base 以上の整数）
  test_timeout=$(apply_effort_timeout "$timeout_sec" "$(resolve_agent_effort implementer "${DEV_CONFIG:-}")")

  # ===== validation v2（batch#8 Stage3）: layer 1 に checks があれば v2 が権威 =====
  if type task_layer_is_v2 &>/dev/null && task_layer_is_v2 "$_RT_TASK_JSON" 1; then
    if [ -n "$test_command" ]; then
      log "  ⚠ [validation-v2] layer 1: legacy command は無視（checks[] が権威）"
    fi
    log "  Layer 1 検証実行 (v2 checks)"
    local v2_output v2_exit=0
    v2_output=$(run_layer_checks "$_RT_TASK_JSON" 1 "$WORK_DIR" "$test_timeout" "$task_id" 2>&1) || v2_exit=$?
    echo "$v2_output" > "${task_dir}/test-output.txt"
    if [ "$v2_exit" -ne 0 ]; then
      _RT_FAIL_CAUSE="l1"
      handle_task_fail "$task_id" "$task_dir" "$v2_output"
      return 1
    fi
    # v2 pass 後も Locked Decision Assertions は従来通り実行（下の共通ブロックへ）
  else

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
    _RT_FAIL_CAUSE="l1"
    handle_task_fail "$task_id" "$task_dir" "$test_output"
    return 1
  fi

  fi  # validation v2 / legacy 分岐ここまで

  # === Locked Decision Assertions 検証 ===
  if [ -n "${RESEARCH_CONFIG:-}" ]; then
    local assertion_report=""
    if ! assertion_report=$(validate_locked_assertions "$RESEARCH_CONFIG" "$WORK_DIR" "$task_id"); then
      echo "$assertion_report" > "${task_dir}/assertion-violations.txt"
      log "  ✗ Locked Decision Assertions 違反 (${task_id})"
      _RT_FAIL_CAUSE="assertion"
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

  # 環境能力不足/明示 deferred の L3 を台帳記録（実行せず・fix なし — futile ループの根絶）
  local l3_deferred_tests l3_deferred_count
  l3_deferred_tests=$(filter_l3_tests "$_RT_TASK_JSON" "deferred")
  l3_deferred_count=$(echo "$l3_deferred_tests" | jq 'length' 2>/dev/null || echo 0)
  if [ "$l3_deferred_count" -gt 0 ] && type record_quality_debt &>/dev/null; then
    local _di=0
    while [ "$_di" -lt "$l3_deferred_count" ]; do
      local _dtest _did _dreason _dcmd
      _dtest=$(echo "$l3_deferred_tests" | jq -c ".[$_di]")
      _did=$(echo "$_dtest" | jq_safe -r '.id // "l3-unknown"')
      _dreason=$(echo "$_dtest" | jq_safe -r '._deferred_reason // .deferred_reason // "明示的 deferred 指定"')
      _dcmd=$(echo "$_dtest" | jq_safe -r '.definition.command // ""')
      # 再試行時の重複記録を回避（同一 task_id + test_id の deferred_test が既存ならスキップ）
      if ! grep -q "\"type\":\"deferred_test\".*\"task_id\":\"${task_id}\".*\"test_id\":\"${_did}\"" "${QUALITY_LEDGER_FILE:-/nonexistent}" 2>/dev/null; then
        record_quality_debt "deferred_test" "$task_id" \
          "L3 [${_did}] を繰延: ${_dreason}" \
          "$(jq -n -c --arg c "$_dcmd" --arg t "$_did" '{command: $c, test_id: $t}')"
      fi
      _di=$((_di + 1))
    done
    log "  ⚠ L3 繰延: ${l3_deferred_count} 件（環境能力不足/明示 deferred — 台帳記録済み）"
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
    # 注意: `.blocking // true` は false を潰して true に化けさせる（jq の // は false も空扱い）。
    # blocking:false の L3 が blocking 扱いになり、非 blocking のはずの失敗でタスクが落ちる。
    l3_blocking=$(echo "$l3_test" | jq_safe -r 'if has("blocking") then .blocking else true end')

    log "    L3 [${l3_id}] strategy=${l3_strategy} blocking=${l3_blocking}"

    # 動的タイムアウト読み取り (jq_safe で layer_3[].timeout_sec を優先、未指定/型違いは L3_DEFAULT_TIMEOUT にフォールバック)
    local timeout_sec timeout_type
    timeout_sec=$(echo "$l3_test" | jq_safe -r '.timeout_sec // '"${L3_DEFAULT_TIMEOUT:-120}")
    timeout_type=$(echo "$l3_test" | jq_safe -r '.timeout_sec | type' 2>/dev/null | tr -d '\r')
    # 整数バリデーション: 空文字列・文字列型数値・型違いを防御し L3_DEFAULT_TIMEOUT にフォールバック
    if [ "$timeout_type" = "string" ] || ! [[ "$timeout_sec" =~ ^[0-9]+$ ]]; then
      log "    ⚠ invalid timeout_sec '${timeout_sec}' for layer_3 [${l3_id}], fallback to L3_DEFAULT_TIMEOUT=${L3_DEFAULT_TIMEOUT:-120}"
      timeout_sec="${L3_DEFAULT_TIMEOUT:-120}"
    fi
    # effort 連動倍率: agent_effort.implementer に応じて拡張（0=無制限は維持、結果は base 以上の整数）
    timeout_sec=$(apply_effort_timeout "$timeout_sec" "$(resolve_agent_effort implementer "${DEV_CONFIG:-}")")

    local l3_output l3_exit=0
    l3_output=$(execute_l3_test "$l3_test" "$WORK_DIR" "$timeout_sec" 2>&1) || l3_exit=$?

    echo "$l3_output" > "${task_dir}/l3-${l3_id}.txt"

    if [ "$l3_exit" -eq 0 ]; then
      log "    ✓ L3 PASS: ${l3_id}"
      l3_pass=$((l3_pass + 1))
      # 過去に繰延/skip された同テストの債務は実行 PASS で解消（batch#8 Fix3）
      if type resolve_quality_debts_matching &>/dev/null; then
        resolve_quality_debts_matching "$task_id" "deferred_test,env_blocked,l3_skip" "$l3_id" "L3 pass"
      fi
    elif [ "$l3_exit" -eq 2 ]; then
      log "    ⚠ L3 SKIP: ${l3_id}"
      l3_skip=$((l3_skip + 1))
      if type record_quality_debt &>/dev/null; then
        record_quality_debt "l3_skip" "$task_id" \
          "L3 [${l3_id}] skip (strategy=${l3_strategy}): $(printf '%s' "$l3_output" | tail -c 200 | tr -d '\000-\037')"
      fi
    else
      log "    ✗ L3 FAIL: ${l3_id}"
      l3_fail=$((l3_fail + 1))

      if [ "$l3_blocking" = "true" ]; then
        _RT_FAIL_CAUSE="l3"
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
    log "  ✗ QA Evaluator: fail — QA 差戻し（fail_count は据え置き）"
    handle_task_qa_fail "$task_id" "$task_dir" "QA Evaluator が品質不足と判定。詳細: ${task_dir}/qa-evaluator-feedback.txt"
    return 0
  fi

  # UX 構造検査（per_task — advisory、ブロックしない。権威判定は phase_exit の集約）
  if type run_ux_structural_per_task &>/dev/null; then
    run_ux_structural_per_task "$task_id" "$task_dir" "$_RT_TASK_JSON" || true
  fi

  if should_run_mutation_audit "$_RT_TASK_JSON"; then
    run_mutation_audit "$task_id" "$task_dir" "$_RT_TASK_JSON"
  else
    handle_task_pass "$task_id"
  fi
}

# ===== validation 執筆（実装後 — batch#10 Stage4） =====
# Planner はゴールと制約のみを書く。受入契約（validation）は実装完了直後に
# Implementer 自身が「実際に作った実物」に基づいて執筆する。
# 背景: Planner が実装を見ずに書いた CLI 契約（--trunk/--map 等）が実装と食い違い、
# 結合時まで露見しない事故が同一案件で3回発生（Investigator 診断 16 件中 8 件の根）。
# 既に有効な validation を持つタスク（fix タスク・legacy スタック）はスキップ。
# 使い方: task_author_validation <task_id> <task_dir>
# 前提: _RT_TASK_JSON 設定済み / 戻り値: 0=続行可, 1=失敗（handle_task_fail 呼出済み）
task_author_validation() {
  local task_id="$1"
  local task_dir="$2"

  # スキップ判定: L1（v2 check か legacy command）を既に持ち、
  # l3_criteria_refs の未充足も無いタスクは執筆不要
  local _av_has_l1 _av_missing_l3
  _av_has_l1=$(echo "$_RT_TASK_JSON" | jq_safe -r '
    (((.validation.layer_1.command // "") != "") or
     (([.validation.checks[]? | select(.layer == 1)] | length) > 0)) | tostring' 2>/dev/null)
  _av_missing_l3=$(echo "$_RT_TASK_JSON" | jq_safe -r '. as $t |
    [ ($t.l3_criteria_refs // [])[] |
      select(([$t.validation.layer_3[]?.id] | index(.)) == null) ] | length' 2>/dev/null)
  case "$_av_missing_l3" in (*[!0-9]*|"") _av_missing_l3=0 ;; esac
  if [ "$_av_has_l1" = "true" ] && [ "$_av_missing_l3" -eq 0 ]; then
    return 0
  fi

  log "  [AUTHOR] validation 執筆: task=${task_id}（実装した実物を契約化）"

  # criteria 抜粋（このタスクの refs に絞る）
  local _av_l1_ex="（なし）" _av_l2_ex="（なし）" _av_l3_ex="（なし）"
  if [ -n "${CRITERIA_FILE:-}" ] && [ -f "$CRITERIA_FILE" ]; then
    local _av_refs
    _av_refs=$(echo "$_RT_TASK_JSON" | jq -c '.l1_criteria_refs // []' 2>/dev/null || echo '[]')
    _av_l1_ex=$(jq --argjson refs "$_av_refs" \
      '[.layer_1_criteria[]? | select(.id as $i | $refs | index($i))]' "$CRITERIA_FILE" 2>/dev/null || echo "（抽出不能）")
    _av_refs=$(echo "$_RT_TASK_JSON" | jq -c '.l2_criteria_refs // []' 2>/dev/null || echo '[]')
    _av_l2_ex=$(jq --argjson refs "$_av_refs" \
      '[.layer_2_criteria[]? | select(.id as $i | $refs | index($i))]' "$CRITERIA_FILE" 2>/dev/null || echo "（抽出不能）")
    _av_refs=$(echo "$_RT_TASK_JSON" | jq -c '.l3_criteria_refs // []' 2>/dev/null || echo '[]')
    _av_l3_ex=$(jq --argjson refs "$_av_refs" \
      '[.layer_3_criteria[]? | select(.id as $i | $refs | index($i))]' "$CRITERIA_FILE" 2>/dev/null || echo "（抽出不能）")
  fi

  # 実装が実際に変更したファイル一覧（契約が実物を指すことの担保材料）
  local _av_changed="（取得不能）"
  if git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    _av_changed=$({ git -C "$WORK_DIR" diff --name-only HEAD 2>/dev/null;
                    git -C "$WORK_DIR" ls-files --others --exclude-standard 2>/dev/null; } | sort -u | head -60)
  fi

  # 環境能力タグ
  local _av_env="（プローブなし）"
  local _av_caps="${ENV_CAPABILITIES_FILE:-${PROJECT_ROOT}/.forge/state/env-capabilities.json}"
  [ -f "$_av_caps" ] && _av_env=$(jq -c '.capability_tags // []' "$_av_caps" 2>/dev/null || echo "（読取不能）")

  local _av_existing
  _av_existing=$(echo "$_RT_TASK_JSON" | jq '.validation // {}' 2>/dev/null || echo '{}')

  local _av_prompt
  _av_prompt=$(render_template "${TEMPLATES_DIR}/validation-authoring-prompt.md" \
    "TASK_ID"              "$task_id" \
    "TASK_JSON"            "$_RT_TASK_JSON" \
    "CHANGED_FILES"        "$_av_changed" \
    "L1_CRITERIA_EXCERPT"  "$_av_l1_ex" \
    "L2_CRITERIA_EXCERPT"  "$_av_l2_ex" \
    "L3_CRITERIA_EXCERPT"  "$_av_l3_ex" \
    "ENV_PROBE"            "$_av_env" \
    "EXISTING_VALIDATION"  "$_av_existing" \
    "L1_DEFAULT_TIMEOUT"   "${L1_DEFAULT_TIMEOUT:-60}")

  local _av_attempt=1 _av_max=2 _av_detail="" _av_validation=""
  while [ "$_av_attempt" -le "$_av_max" ]; do
    local _av_ts _av_out _av_log
    _av_ts=$(now_ts)
    _av_out="${task_dir}/validation-authored.json"
    _av_log="${DEV_LOG_DIR}/author-${task_id}-${_av_ts}.log"

    local _av_run_prompt="$_av_prompt"
    if [ -n "$_av_detail" ]; then
      _av_run_prompt="${_av_prompt}

## 重要: 前回の執筆が機械ゲートに違反した。以下を必ず修正すること
${_av_detail}"
    fi

    export _RC_CONTEXT_STRATEGY="${CONTEXT_STRATEGY_IMPLEMENTER:-reset}"
    metrics_start
    if run_claude "$IMPLEMENTER_MODEL" "${AGENTS_DIR}/implementer.md" \
         "$_av_run_prompt" "$_av_out" "$_av_log" \
         "Write,Edit,MultiEdit,NotebookEdit,Task,WebSearch,WebFetch,Bash" \
         300 "" "${SCHEMAS_DIR}/validation-authoring.schema.json" "low" \
       && validate_json "$_av_out" "author-${task_id}"; then
      metrics_record "author-${task_id}" "true"
      _av_validation=$(jq -c '.validation // empty' "$_av_out" 2>/dev/null)
      if [ -n "$_av_validation" ]; then
        # 執筆後ゲート: 生成時と同じ構造規則 + L1 必須 + L3 構造（validation-gates.sh）
        local _av_task_patched
        _av_task_patched=$(echo "$_RT_TASK_JSON" | jq -c --argjson v "$_av_validation" '.validation = $v' 2>/dev/null)
        if _av_detail=$(validate_authored_validation "$_av_task_patched" "$_av_caps"); then
          # task-stack へ書込（ロック付き）
          local _av_lock
          _av_lock="$(dirname "${TASK_STACK}")/.lock/task-stack.lock"
          acquire_lock "$_av_lock" 2>/dev/null || true
          jq --arg id "$task_id" --argjson v "$_av_validation" '
            .tasks |= map(
              if .task_id == $id then
                .validation = $v | .updated_at = (now | todate)
              else . end
            ) | .updated_at = (now | todate)
          ' "$TASK_STACK" > "${TASK_STACK}.tmp" 2>/dev/null && mv "${TASK_STACK}.tmp" "$TASK_STACK"
          release_lock "$_av_lock" 2>/dev/null || true
          sync_task_stack
          reload_rt_task_json "$task_id" "${CURRENT_DEV_PHASE:-}"
          record_task_event "$task_id" "validation_authored" "{\"attempt\":${_av_attempt}}"
          log "  ✓ [AUTHOR] validation 執筆完了（attempt=${_av_attempt}）"
          return 0
        fi
        log "  ⚠ [AUTHOR] 執筆後ゲート違反（attempt=${_av_attempt}）: ${_av_detail}"
      else
        _av_detail="出力に validation フィールドがない"
        log "  ⚠ [AUTHOR] ${_av_detail}（attempt=${_av_attempt}）"
      fi
    else
      metrics_record "author-${task_id}" "false"
      _av_detail="執筆呼出の実行/JSON検証エラー"
      log "  ⚠ [AUTHOR] ${_av_detail}（attempt=${_av_attempt}）"
    fi
    _av_attempt=$((_av_attempt + 1))
  done

  log "  ✗ [AUTHOR] validation 執筆が ${_av_max} 回失敗 — タスク失敗処理"
  _RT_FAIL_CAUSE="authoring"
  handle_task_fail "$task_id" "$task_dir" "validation 執筆失敗（実装した実物から受入契約を定義できなかった）: ${_av_detail}"
  return 1
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
  # fail_count が best-of-N trigger（既定2）に一致する attempt は N 候補生成 → 選択の経路へ
  local _rt_fc
  _rt_fc=$(echo "$_RT_TASK_JSON" | jq_safe -r '.fail_count // 0' 2>/dev/null)
  if [ "${BEST_OF_N_ENABLED:-false}" = "true" ] && [ "${_rt_fc:-0}" = "${BEST_OF_N_TRIGGER:-2}" ]; then
    if ! task_implement_best_of_n "$task_id" "$task_dir"; then
      trap - ERR 2>/dev/null || true
      return 0
    fi
  else
    if ! task_implement "$task_id" "$task_dir"; then
      trap - ERR 2>/dev/null || true
      return 0
    fi
  fi
  trap - ERR 2>/dev/null || true

  # S4: 変更ファイル数 + S4.5: L1 ファイル参照バリデーション
  task_validate_changes "$task_id" "$task_dir" || return 0

  # validation 執筆（Planner 降格 — 実装後に Implementer が実物から契約を書く。
  # L1 実行より前: 執筆された L1 checks をこの直後の task_run_l1_test が実行する）
  task_author_validation "$task_id" "$task_dir" || return 0

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

  # fix タスク完了時: origin の fix_cap_reached 債務を解消（batch#8 Fix3 —
  # 「人手が必要」の主張は origin への fix が最終的に通った時点で実質解消される）
  if type resolve_quality_debts_matching &>/dev/null; then
    local _fix_origin
    _fix_origin=$(get_task_json "$task_id" | jq_safe -r '.l2_fix_for // .l3_fix_for // ""' 2>/dev/null)
    if [ -n "$_fix_origin" ]; then
      resolve_quality_debts_matching "$_fix_origin" "fix_cap_reached" "" "fix タスク ${task_id} 完了"
    fi
  fi

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
      # 注意: diff は差分ありで exit 1、grep も不一致で exit 1 を返す。
      # set -eEuo pipefail 下では pipefail によりこの非ゼロが伝播し handle_task_fail
      # 全体（＝ralph ループ）が異常終了する（2回目 QA fail でデーモンが落ちる実バグ、
      # 2026-07-24 確認）。末尾 || true で pipeline の失敗を吸収する。
      local diff_lines
      diff_lines=$(diff "$_tmp_prev" "$_tmp_curr" 2>/dev/null | grep '^[<>]' | wc -l | tr -d ' ' || true)
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

# ===== QA fail の差戻し（batch#11 R04） =====
# QA Evaluator の fail は L1 の機械テスト失敗とは別物。従来は handle_task_fail に流れて .fail_count が進み、
# 2 回で best-of-N（patch 適用欠陥で成果物を破壊する経路）→ 3 回で Investigator を起動していた
# （4.5f: QA 真陽性 11/13 が「罰」として作用し、implementer 時間の 43% を 4 タスクで浪費）。
# ここでは qa_fail_count（run_qa_evaluator が更新済み）だけを進め、fail_count は据え置く:
#   - status=failed で再試行（pending にすると update_task_status が fail_count を 0 に戻す）
#   - fail_count が増えないので次 attempt は Fixer（最小修正）ではなく Implementer が QA feedback 付きで再実装
#   - 終了保証は run_qa_evaluator 側の QA_MAX_FAILURES auto-pass + 品質債務（qa_auto_pass）
handle_task_qa_fail() {
  local task_id="$1"
  local task_dir="$2"
  local reason="${3:-}"
  local qfc
  qfc=$(jq_safe -r --arg id "$task_id" '.tasks[] | select(.task_id == $id) | .qa_fail_count // 0' "$TASK_STACK" 2>/dev/null || echo 0)
  case "$qfc" in (''|*[!0-9]*) qfc=0 ;; esac
  [ -n "$reason" ] && echo "$reason" > "${task_dir}/qa-fail-${qfc}.txt"
  update_task_status "$task_id" "failed"
  record_task_event "$task_id" "qa_fail_recorded" "{\"qa_fail_count\":${qfc}}" 2>/dev/null || true
  log "  ✗ QA 差戻し（${qfc}/${QA_MAX_FAILURES:-3}）— fail_count 据え置き。best-of-N / Fixer / Investigator は起動せず、Implementer が QA feedback 付きで再試行"
}

# ===== 中断（SIGTERM=143 / SIGINT=130）の再キュー（batch#11 R07a） =====
# 人間の停止は失敗ではない。fail_count を進めず、fail_count>0 なら failed（Fixer/Investigator の
# 位置を保つ）、0 なら pending に戻す（pending は update_task_status が fail_count を 0 にする）。
requeue_task_after_interrupt() {
  local task_id="$1" fc st
  fc=$(jq_safe -r --arg id "$task_id" '.tasks[] | select(.task_id == $id) | .fail_count // 0' "$TASK_STACK" 2>/dev/null || echo 0)
  case "$fc" in (''|*[!0-9]*) fc=0 ;; esac
  if [ "$fc" -gt 0 ]; then st="failed"; else st="pending"; fi
  update_task_status "$task_id" "$st"
  record_task_event "$task_id" "interrupted_requeued" "{\"fail_count\":${fc},\"status\":\"${st}\"}" 2>/dev/null || true
  log "  ↩ 中断（exit 143/130）— fail_count=${fc} 据え置きで再キュー（status=${st}）"
}

# ===== サーキットブレーカー =====
check_circuit_breakers() {
  # 1. タスク実行上限
  if [ "$task_count" -ge "$MAX_TOTAL_TASKS" ]; then
    log "✗ サーキットブレーカー: タスク実行上限（${MAX_TOTAL_TASKS}）到達"
    notify_human "warning" "タスク実行上限到達" "実行回数: ${task_count}/${MAX_TOTAL_TASKS}"
    BREAKER_FIRED="task_limit"
    return 0
  fi

  # 2. Investigator起動回数上限
  if [ "$investigation_count" -ge "$MAX_INVESTIGATIONS" ]; then
    log "✗ サーキットブレーカー: Investigator起動上限（${MAX_INVESTIGATIONS}）到達"
    notify_human "warning" "Investigator起動上限到達" "起動回数: ${investigation_count}/${MAX_INVESTIGATIONS}"
    BREAKER_FIRED="investigation_limit"
    return 0
  fi

  # 3. 総時間上限
  local elapsed_seconds=$((SECONDS - START_SECONDS))
  local elapsed_minutes=$((elapsed_seconds / 60))
  if [ "$elapsed_minutes" -ge "$MAX_DURATION_MINUTES" ]; then
    log "✗ サーキットブレーカー: 総時間上限（${MAX_DURATION_MINUTES}分）到達"
    notify_human "warning" "開発総時間上限到達" "経過: ${elapsed_minutes}分/${MAX_DURATION_MINUTES}分"
    BREAKER_FIRED="total_timeout"
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
    BREAKER_FIRED="blocked_majority"
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
      BREAKER_FIRED="session_cost"
      return 0
    fi
  fi

  # 6. RESEARCH_REMAND シグナル
  if check_loop_signal; then
    BREAKER_FIRED="research_remand"
    return 0
  fi

  return 1
}

# ===== ブレーカー発火時の再開可能な一時停止（batch#11 R06） =====
# 従来はブレーカーで main ループを抜けた後も exit 0 で終わるため、forge-flow が
# completed_phase=2 を書き「Forge Flow 完了」と記録していた（4.5f で 495 分の空白の一因）。
# 未完了タスクが残るなら flow-state.json に paused を記し、exit 75 で「再開可能な停止」を伝える。
# forge-flow.sh は exit 75 を Phase 2 未完了として扱い、--resume で Phase 2 に再入できる。
pause_if_unfinished() {
  [ -n "${BREAKER_FIRED:-}" ] || return 0
  # 差戻しは forge-flow が loop-signal で処理する（pause ではない）
  [ "$BREAKER_FIRED" = "research_remand" ] && return 0
  [ -f "${TASK_STACK:-}" ] || return 0
  local unfinished
  unfinished=$(jq '[.tasks[] | select(.status == "pending" or .status == "failed" or .status == "in_progress" or ((.status // "") | startswith("blocked")))] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  case "$unfinished" in (''|*[!0-9]*) unfinished=0 ;; esac
  [ "$unfinished" -gt 0 ] || return 0

  local fs="${STATE_DIR}/flow-state.json" ts
  ts=$(date -Iseconds)
  if [ -f "$fs" ] && jq -e . "$fs" >/dev/null 2>&1; then
    jq --arg r "$BREAKER_FIRED" --arg t "$ts" --argjson n "$unfinished" \
      '. + {paused: true, paused_reason: $r, paused_at: $t, unfinished_tasks: $n}' \
      "$fs" > "${fs}.tmp" 2>/dev/null && mv "${fs}.tmp" "$fs"
  else
    jq -n --arg r "$BREAKER_FIRED" --arg t "$ts" --argjson n "$unfinished" \
      '{completed_phase: "1.5", paused: true, paused_reason: $r, paused_at: $t, unfinished_tasks: $n}' \
      > "$fs" 2>/dev/null || true
  fi
  log "⏸ ブレーカー（${BREAKER_FIRED}）で一時停止 — 未完了タスク ${unfinished} 件。再開は forge-flow.sh --resume（Phase 2 から再入）"
  if type record_task_event &>/dev/null; then
    record_task_event "session" "paused" "{\"reason\":\"${BREAKER_FIRED}\",\"unfinished\":${unfinished}}" 2>/dev/null || true
  fi
  PAUSED_EXIT_CODE_ACTIVE=75
  return 0
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
  # キャリブレーション乖離率（0件は無較正を明示 — 黙って劣化しない / P0-3）
  if [ -f "${CALIBRATION_FILE:-}" ] && [ -s "${CALIBRATION_FILE:-}" ]; then
    local _div_rate
    _div_rate=$(compute_divergence_rate)
    log "キャリブレーション乖離率: ${_div_rate}"
  else
    log "⚠ 較正データ0件 — 評価器は無較正（bash .forge/loops/feedback.sh <task-id> <verdict> \"理由\" で裁定を記録）"
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

  # ===== 品質債務台帳サマリー（黙って劣化しない原則の最終表面化） =====
  # 主表示は今回セッション分（全期間合算は数ラン蓄積で狼少年化するため副表示 — batch#8 Fix3）
  if type summarize_quality_debts &>/dev/null; then
    local _debts_summary _debts_unresolved _debts_session
    _debts_summary=$(summarize_quality_debts "" "${FORGE_SESSION_ID:-}")
    _debts_unresolved=$(echo "$_debts_summary" | jq_safe -r '.unresolved // 0' 2>/dev/null)
    case "$_debts_unresolved" in (*[!0-9]*|"") _debts_unresolved=0 ;; esac
    _debts_session=$(echo "$_debts_summary" | jq_safe -r '.session.unresolved // empty' 2>/dev/null)
    case "$_debts_session" in (*[!0-9]*|"") _debts_session="$_debts_unresolved" ;; esac
    if [ "$_debts_unresolved" -gt 0 ]; then
      # 機械可読1行（外部監視/CI 用）: SESSION=今回分, 総数は全期間
      log "[WARN] QUALITY_DEBTS=${_debts_unresolved} QUALITY_DEBTS_SESSION=${_debts_session} $(echo "$_debts_summary" | jq_safe -r '.by_type | to_entries | map("\(.key)=\(.value)") | join(" ")' 2>/dev/null)"
      echo "" >&2
      echo -e "${YELLOW:-$'\e[33m'}${BOLD:-$'\e[1m'}⚠ 品質債務: 今回セッション ${_debts_session} 件 / 全期間未解決 ${_debts_unresolved} 件${NC:-$'\e[0m'}" >&2
      if type list_quality_debts &>/dev/null; then
        list_quality_debts | head -15 >&2 || true
      fi
      echo -e "  ${YELLOW:-$'\e[33m'}→ 詳細: .forge/state/quality-debts.jsonl / 引き継ぎ: PHASE4-HANDOFF.md${NC:-$'\e[0m'}" >&2
      echo "" >&2
      # 人間 Phase 4 への引き継ぎファイルを自動生成
      if type generate_phase4_handoff &>/dev/null; then
        generate_phase4_handoff "${WORK_DIR:-.}"
      fi
    fi
  fi

  # ===== 機械可読 未完タスク警告（B-2: 外部監視/CI 用） BEGIN =====
  # task-stack.json から 5状態 (pending, in_progress, blocked_criteria,
  # blocked_investigation, failed) を集計し、合計>0 の場合のみ:
  #   (1) 機械可読プレフィックス '[WARN] UNFINISHED_TASKS=N ...' を log() 経由で1行出力
  #   (2) 視覚警告ブロック（3層: 見出し+状態別カウント+対処hint）を stderr へ追記
  # 正常時 (合計=0) は何も出力しない (silent on success)。
  # 既存ヘルパー jq_safe を経由するため Windows CRLF 出力でも数値比較は安定する。
  if [ -f "${TASK_STACK:-}" ]; then
    local _unf_counts _unf_pending _unf_in_progress _unf_blocked_criteria _unf_blocked_investigation _unf_failed _unf_total
    _unf_counts=$(jq_safe -r '
      [.tasks[]? | .status] as $s |
      ([$s[] | select(. == "pending")]               | length) as $p  |
      ([$s[] | select(. == "in_progress")]           | length) as $ip |
      ([$s[] | select(. == "blocked_criteria")]      | length) as $bc |
      ([$s[] | select(. == "blocked_investigation")] | length) as $bi |
      ([$s[] | select(. == "failed")]                | length) as $f  |
      "\($p) \($ip) \($bc) \($bi) \($f)"
    ' "$TASK_STACK" 2>/dev/null || echo "0 0 0 0 0")
    read -r _unf_pending _unf_in_progress _unf_blocked_criteria _unf_blocked_investigation _unf_failed <<< "${_unf_counts:-0 0 0 0 0}"
    : "${_unf_pending:=0}"
    : "${_unf_in_progress:=0}"
    : "${_unf_blocked_criteria:=0}"
    : "${_unf_blocked_investigation:=0}"
    : "${_unf_failed:=0}"
    _unf_total=$(( _unf_pending + _unf_in_progress + _unf_blocked_criteria + _unf_blocked_investigation + _unf_failed ))
    if [ "$_unf_total" -gt 0 ]; then
      log "[WARN] UNFINISHED_TASKS=${_unf_total} pending=${_unf_pending} in_progress=${_unf_in_progress} blocked_criteria=${_unf_blocked_criteria} blocked_investigation=${_unf_blocked_investigation} failed=${_unf_failed}"

      # ----- 視覚警告ブロック（3層構造） -----
      # global RED/BOLD/NC に依存しないローカル色変数を定義する。
      # tty ガード: stderr が tty かつ NO_COLOR 未設定のときのみ ANSI を有効化。
      # daemonize 経由 (stderr ファイルリダイレクト) では [ -t 2 ] が偽のため
      # forge-flow.log に ANSI バイトを混入させない。
      local _vis_red _vis_bold _vis_yellow _vis_nc
      if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
        _vis_red=$'\e[31m'
        _vis_bold=$'\e[1m'
        _vis_yellow=$'\e[33m'
        _vis_nc=$'\e[0m'
      else
        _vis_red=""
        _vis_bold=""
        _vis_yellow=""
        _vis_nc=""
      fi
      # Layer 1: 見出し（RED+BOLD）
      echo "" >&2
      printf '%s%s⚠ 未完了タスク残存（UNFINISHED TASKS DETECTED）%s\n' \
        "${_vis_red}" "${_vis_bold}" "${_vis_nc}" >&2
      # Layer 2: 状態別カウント bullets（合算ではなく内訳表示）
      printf '  • pending=%s\n'                "${_unf_pending}"               >&2
      printf '  • in_progress=%s\n'            "${_unf_in_progress}"           >&2
      printf '  • blocked_criteria=%s\n'       "${_unf_blocked_criteria}"      >&2
      printf '  • blocked_investigation=%s\n'  "${_unf_blocked_investigation}" >&2
      printf '  • failed=%s\n'                 "${_unf_failed}"                >&2
      # Layer 3: 対処コマンド hint（YELLOW '→'）
      printf '  %s→%s 残タスクを再開: pending/blocked/failed を pending に戻して ralph-loop を再起動\n' \
        "${_vis_yellow}" "${_vis_nc}" >&2
      printf '  %s→%s 詳細手順: .claude/rules/forge-operations.md 『トラブルシューティング』を参照\n' \
        "${_vis_yellow}" "${_vis_nc}" >&2
      echo "" >&2
    fi
  fi
  # ===== 機械可読 未完タスク警告 END =====
}

# ===== Phase3 リトライの再入 phase 決定 =====
# pending/failed タスクを持つ「最初の」dev_phase を返す（無ければ最後の phase）。
# fix タスク（l2fix/l3fix）は origin の dev_phase_id を継承するため、従来の
# 「最後の phase 固定に戻す」では前段 phase の fix が get_next_task の phase フィルタで
# 永遠に拾われず孤児化していた（football-core バグ#3 — Phase3 リトライ枯渇まで
# 毎回 ~28分の完了処理だけが空回りする実害）。
earliest_phase_with_pending() {
  local pid n
  for pid in "${DEV_PHASES[@]}"; do
    n=$(jq --arg pid "$pid" '
      [.tasks[] |
        select((.dev_phase_id // "mvp") == $pid) |
        select(.status == "pending" or .status == "failed")
      ] | length' "$TASK_STACK" 2>/dev/null || echo 0)
    case "$n" in (*[!0-9]*|"") n=0 ;; esac
    if [ "$n" -gt 0 ]; then
      printf '%s' "$pid"
      return 0
    fi
  done
  printf '%s' "${DEV_PHASES[${#DEV_PHASES[@]}-1]}"
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

  # 環境能力の再プローブ（batch#11 R13）: Phase 1.5 のプローブ結果は CLI 更新・PATH 変化・別マシンでの
  # 再開で陳腐化する（contents-make で L3 が誤繰延）。Phase 2 開始時に 1 回だけ更新する
  if [ "${FORGE_SKIP_ENV_PROBE:-0}" != "1" ] && [ -f "${PROJECT_ROOT}/.forge/lib/probe-env.sh" ]; then
    # shellcheck source=../lib/probe-env.sh
    source "${PROJECT_ROOT}/.forge/lib/probe-env.sh"
    if type probe_env_capabilities &>/dev/null; then
      probe_env_capabilities "$WORK_DIR" "${ENV_CAPABILITIES_FILE:-${PROJECT_ROOT}/.forge/state/env-capabilities.json}" "$DEV_CONFIG" >/dev/null 2>&1 || true
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
    local fix_count
    fix_count=$(jq '[.tasks[] | select((.task_id | contains("-l2fix-")) or (.task_id | contains("-l3fix-")))] | length' "$TASK_STACK" 2>/dev/null || echo 0)
    if [ "$fix_count" -gt 0 ]; then
      log "前回の l2fix/l3fix タスク ${fix_count}件を削除"
      jq '.tasks |= map(select(((.task_id | contains("-l2fix-")) or (.task_id | contains("-l3fix-"))) | not))' \
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
    # モデル設定の hot-reload（タスク境界のみ — batch#8 Fix7）
    reload_model_config

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
              CURRENT_DEV_PHASE="$(earliest_phase_with_pending)"
              log "  Phase 3 リトライ再入 phase: ${CURRENT_DEV_PHASE}（pending/failed を持つ最初の phase）"
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

          # 完了処理中に新規タスクが生成された場合（UX 判定の fix タスク等）は
          # advance せず同一 phase を続行する（実行不能タスクは既存の
          # 「実行可能タスクなし」ガードが検出するため無限ループにはならない）
          local _post_completion_pending
          _post_completion_pending=$(jq --arg pid "$CURRENT_DEV_PHASE" '
            [.tasks[] |
              select((.dev_phase_id // "mvp") == $pid) |
              select(.status == "pending" or .status == "failed")
            ] | length
          ' "$TASK_STACK" 2>/dev/null || echo 0)
          if [ "${_post_completion_pending:-0}" -gt 0 ]; then
            log "↻ dev-phase [${CURRENT_DEV_PHASE}] 完了処理で新規タスク ${_post_completion_pending} 件 — phase 続行"
            continue
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
                CURRENT_DEV_PHASE="$(earliest_phase_with_pending)"
                log "  Phase 3 リトライ再入 phase: ${CURRENT_DEV_PHASE}（pending/failed を持つ最初の phase）"
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

    # ハートビート更新（run_claude フックが current_task を引き継ぐ）
    _HB_CURRENT_TASK="$next_task"
    update_heartbeat "$next_task"

    # タスク実行
    run_task "$next_task"
    _HB_CURRENT_TASK=""
    task_count=$((task_count + 1))
    persist_session_state
  done

  # Bug #5: 正常終了時に in_progress が残っていれば解決する
  check_stale_in_progress

  # 最終ハートビート（ループ終了）
  update_heartbeat "loop-finished"

  # Ablation 実験結果保存
  save_ablation_results

  # ブレーカー発火 + 未完了タスク → 再開可能な一時停止（exit 75）— batch#11 R06
  pause_if_unfinished

  print_summary

  if [ "${PAUSED_EXIT_CODE_ACTIVE:-0}" -ne 0 ]; then
    exit "$PAUSED_EXIT_CODE_ACTIVE"
  fi
}

# ===== 実行 =====
main
