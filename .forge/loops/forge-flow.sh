#!/bin/bash
# forge-flow.sh — Forge Harness エンドツーエンドオーケストレーター
# 使い方: ./forge-flow.sh "テーマ" "方向性/制約（省略可）" [--work-dir <dir>]
#
# Phase 1(Research) → Phase 1.5(Task Planning) → Phase 2(Development) を自動接続。
# RESEARCH_REMAND 検出時に Phase 1 から再実行（最大 max_research_remands 回）。
# 設計書: forge-architecture-v3.2.md

set -euo pipefail

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"

# ===== server.start_command ↔ package.json スクリプト整合性チェック =====
# 戻り値: 0=OK/スキップ, 1=不整合（exit 1 の前に呼び出し元が exit する）
_check_server_script_compat() {
  local dev_config="${PROJECT_ROOT}/.forge/config/development.json"
  [ ! -f "$dev_config" ] && return 0

  local start_cmd
  start_cmd=$(jq_safe -r '.server.start_command // ""' "$dev_config" 2>/dev/null || echo "")

  # "none" / 空 / "null" → スキップ
  case "$start_cmd" in
    ""|none|null) return 0 ;;
  esac

  # パッケージマネージャ判別とスクリプト名抽出
  local pkg_mgr="" script_name=""
  if [[ "$start_cmd" =~ ^npm[[:space:]]+(run[[:space:]]+)?([A-Za-z0-9:_-]+) ]]; then
    pkg_mgr="npm"
    script_name="${BASH_REMATCH[2]}"
  elif [[ "$start_cmd" =~ ^(pnpm|yarn)[[:space:]] ]]; then
    pkg_mgr="${BASH_REMATCH[1]}"
    echo -e "${YELLOW}[PREFLIGHT] ⚠ ${pkg_mgr} を使用中 — server.start_command のスクリプト検証をスキップ${NC}" >&2
    return 0
  else
    # npm/pnpm/yarn 以外（シェルコマンド等）→ スキップ
    return 0
  fi

  # package.json の参照先（WORK_DIR > PROJECT_ROOT）
  local check_dir="${_WORK_DIR_ARG:-${PROJECT_ROOT}}"
  local pkg_json="${check_dir}/package.json"

  if [ ! -f "$pkg_json" ]; then
    log "ℹ package.json 不在 (${pkg_json}) — server.start_command スクリプト検証スキップ"
    return 0
  fi

  # スクリプト存在チェック
  local has_script available
  has_script=$(jq_safe -r ".scripts[\"${script_name}\"] // \"__ABSENT__\"" "$pkg_json" 2>/dev/null || echo "__ABSENT__")

  if [ "$has_script" = "__ABSENT__" ]; then
    available=$(jq_safe -r '(.scripts // {}) | keys | join(", ")' "$pkg_json" 2>/dev/null || echo "")
    echo -e "${RED}[PREFLIGHT] ✗ script '${script_name}' not found in package.json. Available: ${available}${NC}" >&2
    return 1
  fi

  log "✓ server.start_command スクリプト '${script_name}' を確認 (${pkg_json})"
  return 0
}

# ===== プリフライトチェック =====
preflight_check() {
  local errors=0

  # コマンド依存（common.sh の check_dependencies を使用）
  check_dependencies claude jq timeout

  # 必須ディレクトリ
  for dir in .forge/loops .forge/config .forge/templates .forge/state .claude/agents; do
    if [ ! -d "$dir" ]; then
      echo -e "${RED}[PREFLIGHT] ディレクトリ不在: $dir${NC}" >&2
      errors=$((errors + 1))
    fi
  done

  # 必須設定ファイル
  for f in .forge/config/circuit-breaker.json .forge/config/development.json; do
    if [ ! -f "$f" ]; then
      echo -e "${YELLOW}[PREFLIGHT] 設定ファイル不在: $f（デフォルト値で続行）${NC}" >&2
    fi
  done

  # 必須スクリプト
  for f in .forge/loops/research-loop.sh .forge/loops/generate-tasks.sh .forge/loops/ralph-loop.sh; do
    if [ ! -f "$f" ]; then
      echo -e "${RED}[PREFLIGHT] スクリプト不在: $f${NC}" >&2
      errors=$((errors + 1))
    fi
  done

  if [ "$errors" -gt 0 ]; then
    echo -e "${RED}[PREFLIGHT] ${errors}件のエラー。修正後に再実行してください。${NC}" >&2
    exit 1
  fi

  # 作業ディレクトリの git 安全チェック（S1: Pre-flight Git Status Check）
  if [ -n "${_WORK_DIR_ARG:-}" ]; then
    if ! safe_work_dir_check "$_WORK_DIR_ARG"; then
      echo -e "${RED}[PREFLIGHT] 作業ディレクトリの安全チェック失敗${NC}" >&2
      exit 1
    fi
  fi

  # server.start_command と package.json スクリプト整合性チェック
  if ! _check_server_script_compat; then
    exit 1
  fi

  # 設定ファイルスキーマ検証（validate_config は common.sh 提供）
  local _cf_schemas_dir="${PROJECT_ROOT}/.forge/schemas"
  if ! validate_config "${PROJECT_ROOT}/.forge/config/development.json" "${_cf_schemas_dir}/development.schema.json"; then
    echo -e "${RED}[PREFLIGHT] development.json スキーマ検証失敗${NC}" >&2
    exit 1
  fi
  if ! validate_config "${PROJECT_ROOT}/.forge/config/circuit-breaker.json" "${_cf_schemas_dir}/circuit-breaker.schema.json"; then
    echo -e "${RED}[PREFLIGHT] circuit-breaker.json スキーマ検証失敗${NC}" >&2
    exit 1
  fi

  log "✓ プリフライトチェック完了"
}

# ===== --work-dir 先行解析（preflight_check 用: $@ を消費しない） =====
_WORK_DIR_ARG=""
_pf_args=("$@")
_pf_n=${#_pf_args[@]}
for (( _pf_i=0; _pf_i < _pf_n; _pf_i++ )); do
  case "${_pf_args[$_pf_i]}" in
    --work-dir=*) _WORK_DIR_ARG="${_pf_args[$_pf_i]#--work-dir=}"; break ;;
    --work-dir)
      _pf_next=$((_pf_i + 1))
      [ "$_pf_next" -lt "$_pf_n" ] && _WORK_DIR_ARG="${_pf_args[$_pf_next]}"
      break ;;
  esac
done
unset _pf_args _pf_n _pf_i _pf_next 2>/dev/null || true

preflight_check

# ===== 名前付き引数パース =====
_PHASE_CONTROL_ARG=""
_WORK_DIR_ARG=""
_RESEARCH_CONFIG_ARG=""
_RESUME=false
_DAEMONIZE=false
_positional_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --phase-control=*)
      _PHASE_CONTROL_ARG="${1#*=}"; shift ;;
    --phase-control)
      _PHASE_CONTROL_ARG="$2"; shift 2 ;;
    --work-dir=*)
      _WORK_DIR_ARG="${1#*=}"; shift ;;
    --work-dir)
      _WORK_DIR_ARG="$2"; shift 2 ;;
    --research-config=*)
      _RESEARCH_CONFIG_ARG="${1#*=}"; shift ;;
    --research-config)
      _RESEARCH_CONFIG_ARG="$2"; shift 2 ;;
    --resume)
      _RESUME=true; shift ;;
    --daemonize)
      _DAEMONIZE=true; shift ;;
    *)
      _positional_args+=("$1"); shift ;;
  esac
done
set -- "${_positional_args[@]}"

# ===== 引数チェック =====
if [ $# -lt 1 ]; then
  echo "使い方: $0 \"テーマ\" [\"方向性/制約\"] [--work-dir <dir>] [--phase-control=auto|checkpoint|mvp-gate] [--resume] [--daemonize]" >&2
  exit 1
fi

THEME="$1"
DIRECTION="${2:-}"
WORK_DIR="${_WORK_DIR_ARG:-}"

# --work-dir 未指定警告
if [ -z "$WORK_DIR" ]; then
  log "⚠ --work-dir 未指定: 生成コードはハーネスリポジトリ内（${PROJECT_ROOT}）に直接書き込まれます"
  log "  外部プロジェクトに出力するには --work-dir <path> を指定してください"
  if [ -t 0 ] && [ "${_DAEMONIZE:-false}" != "true" ]; then
    echo -e "\033[1;33m⚠ --work-dir 未指定。ハーネスリポジトリ内に直接生成されます。続行しますか？ [y/N]\033[0m" >&2
    _wd_confirm=""
    read -t 15 -r _wd_confirm 2>/dev/null || _wd_confirm="y"
    if [ "$_wd_confirm" != "y" ] && [ "$_wd_confirm" != "Y" ]; then
      echo "中断しました。--work-dir を指定して再実行してください。" >&2
      exit 0
    fi
  fi
fi

# ===== 設定読み込み =====
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"

if [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
  MAX_RESEARCH_REMANDS=$(jq_safe -r '.flow_limits.max_research_remands // 2' "$CIRCUIT_BREAKER_CONFIG")
  HUMAN_CHECKPOINT_TIMEOUT=$(jq_safe -r '.flow_limits.human_checkpoint_timeout_sec // 30' "$CIRCUIT_BREAKER_CONFIG")
  _CONFIG_PHASE_CONTROL=$(jq_safe -r '.flow_limits.phase_control_default // "mvp-gate"' "$CIRCUIT_BREAKER_CONFIG")
else
  log "⚠ circuit-breaker.json が見つかりません。デフォルト値を使用"
  MAX_RESEARCH_REMANDS=2
  HUMAN_CHECKPOINT_TIMEOUT=30
  _CONFIG_PHASE_CONTROL="mvp-gate"
fi

# PHASE_CONTROL: コマンドライン引数 > 設定ファイル > デフォルト
if [ -n "$_PHASE_CONTROL_ARG" ]; then
  PHASE_CONTROL="$_PHASE_CONTROL_ARG"
else
  PHASE_CONTROL="$_CONFIG_PHASE_CONTROL"
fi

# ===== 作業ディレクトリ検証 =====
if [ -n "$WORK_DIR" ] && [ ! -d "$WORK_DIR" ]; then
  echo -e "${RED}[ERROR] 作業ディレクトリが見つかりません: ${WORK_DIR}${NC}" >&2
  exit 1
fi

# ===== パス定数 =====
LOOPS_DIR=".forge/loops"
STATE_DIR=".forge/state"
LOOP_SIGNAL_FILE="${STATE_DIR}/loop-signal"
TASK_STACK="${STATE_DIR}/task-stack.json"

# ===== セッション状態初期化 =====
# 新規セッション時に前回の state ファイルをアーカイブしてクリアする。
# --resume 時はスキップ（前回データを使って再開するため）。
init_session_state() {
  mkdir -p "$STATE_DIR"

  if [ "$_RESUME" = "true" ]; then
    log "Resume モード: state クリアをスキップ"
    return 0
  fi

  # 前回セッションの存在チェック（flow-state.json が基準）
  if [ ! -f "${STATE_DIR}/flow-state.json" ]; then
    return 0
  fi

  # --- セッション固有ファイル ---
  local session_files=(
    flow-state.json progress.json heartbeat.json
    task-stack.json current-research.json
    monitor-snapshot.json excluded-elements.json
    session-counters.json loop-signal synthesis.json
  )
  # --- セッションログ（累積ファイル） ---
  local session_logs=(
    metrics.jsonl task-events.jsonl investigation-log.jsonl
    validation-stats.jsonl decisions.jsonl errors.jsonl
    lessons-learned.jsonl approach-barriers.jsonl
    ralph-loop.log forge-flow.log
    flow-stdout.log flow-stderr.log
  )
  # --- セッションディレクトリ ---
  local session_dirs=(checkpoints .lock phase-tests test-verification)

  # アーカイブ先（タイムスタンプ付き）
  local archive_ts
  archive_ts=$(date +%Y%m%d-%H%M%S)
  local archive_dir="${STATE_DIR}/archive/${archive_ts}"
  mkdir -p "$archive_dir"

  # ファイル移動
  local f
  for f in "${session_files[@]}" "${session_logs[@]}"; do
    [ -f "${STATE_DIR}/${f}" ] && mv "${STATE_DIR}/${f}" "${archive_dir}/" 2>/dev/null || true
  done

  # パターンマッチファイル（l3-judge-*, ralph-loop-*.log）
  for f in "${STATE_DIR}"/l3-judge-*.json "${STATE_DIR}"/ralph-loop-*.log; do
    [ -f "$f" ] && mv "$f" "${archive_dir}/" 2>/dev/null || true
  done

  # ディレクトリ移動 → 再作成
  local d
  for d in "${session_dirs[@]}"; do
    if [ -d "${STATE_DIR}/${d}" ]; then
      mv "${STATE_DIR}/${d}" "${archive_dir}/" 2>/dev/null || true
    fi
    mkdir -p "${STATE_DIR}/${d}"
  done

  # notifications: ファイルのみ移動（ディレクトリは維持）
  if [ -d "${STATE_DIR}/notifications" ]; then
    local nf_count
    nf_count=$(find "${STATE_DIR}/notifications" -maxdepth 1 -type f 2>/dev/null | wc -l)
    if [ "$nf_count" -gt 0 ]; then
      mkdir -p "${archive_dir}/notifications"
      find "${STATE_DIR}/notifications" -maxdepth 1 -type f -exec mv {} "${archive_dir}/notifications/" \; 2>/dev/null || true
    fi
  fi

  # 古いアーカイブを整理（直近5件を保持）
  local archive_parent="${STATE_DIR}/archive"
  if [ -d "$archive_parent" ]; then
    local old_archives
    old_archives=$(ls -1dt "${archive_parent}"/*/ 2>/dev/null | tail -n +6)
    if [ -n "$old_archives" ]; then
      echo "$old_archives" | xargs rm -rf 2>/dev/null || true
    fi
  fi

  log "✓ 前回セッションをアーカイブ: archive/${archive_ts}"
}

init_session_state

remand_count=0

# ===== デーモン化 =====
FLOW_LOG="${STATE_DIR}/forge-flow.log"
if [ "$_DAEMONIZE" = "true" ]; then
  # 元の引数を --daemonize 抜きで再構築
  _relaunch_args=("$THEME")
  [ -n "$DIRECTION" ] && _relaunch_args+=("$DIRECTION")
  [ -n "$_WORK_DIR_ARG" ] && _relaunch_args+=(--work-dir "$_WORK_DIR_ARG")
  [ -n "$_PHASE_CONTROL_ARG" ] && _relaunch_args+=(--phase-control "$_PHASE_CONTROL_ARG")
  [ -n "$_RESEARCH_CONFIG_ARG" ] && _relaunch_args+=(--research-config "$_RESEARCH_CONFIG_ARG")
  [ "$_RESUME" = "true" ] && _relaunch_args+=(--resume)

  nohup bash "$0" "${_relaunch_args[@]}" > "$FLOW_LOG" 2>&1 &
  _daemon_pid=$!
  echo "DAEMON_PID=$_daemon_pid"
  echo "LOG=$FLOW_LOG"
  echo "PROGRESS=${PROGRESS_FILE}"
  log "デーモン起動: PID=$_daemon_pid LOG=$FLOW_LOG"
  exit 0
fi

# ===== セッションID生成 =====
# FORGE_SESSION_ID が未設定の場合のみ生成（外部からの注入も可能）
if [ -z "${FORGE_SESSION_ID:-}" ]; then
  FORGE_SESSION_ID=$(generate_session_id)
  export FORGE_SESSION_ID
fi
log "SESSION_ID: ${FORGE_SESSION_ID}"

# ===== フロー実行 =====
log "=========================================="
log "Forge Flow 開始"
log "テーマ: ${THEME}"
log "方向性: ${DIRECTION:-（なし）}"
if [ -n "$WORK_DIR" ]; then
  log "作業ディレクトリ: ${WORK_DIR}"
fi
log "最大リサーチ差戻し: ${MAX_RESEARCH_REMANDS}回"
log "=========================================="

while true; do
  # ===== Resume 検出 =====
  _SKIP_PHASE1=false

  # flow-state.json による精密 resume（既存ロジックの前に優先チェック）
  _flow_state="${STATE_DIR}/flow-state.json"
  if [ "$_RESUME" = "true" ] && [ "$remand_count" -eq 0 ] && [ -f "$_flow_state" ]; then
    _completed=$(jq_safe -r '.completed_phase // ""' "$_flow_state")
    case "$_completed" in
      "1")
        # Phase 1 完了済み → criteria を復元して Phase 1.5 から
        CRITERIA_FILE=$(jq_safe -r '.criteria // ""' "$_flow_state")
        if [ -f "$CRITERIA_FILE" ]; then
          log "✓ Resume(flow-state): Phase 1 完了済み → Phase 1.5 から再開"
          # Phase 1.5 をインライン実行（_SKIP_PHASE1 は Phase 1.5 も含むため）
          GENERATE_ARGS=("$CRITERIA_FILE" "$TASK_STACK")
          [ -n "${WORK_DIR:-}" ] && GENERATE_ARGS+=("$WORK_DIR")
          bash "${LOOPS_DIR}/generate-tasks.sh" "${GENERATE_ARGS[@]}" || { log "✗ Phase 1.5 失敗"; exit 1; }
          _SKIP_PHASE1=true
          _RESUME=false
        fi
        ;;
      "1.5")
        # Phase 1.5 完了済み → Phase 2 から
        CRITERIA_FILE=$(jq_safe -r '.criteria // ""' "$_flow_state")
        TASK_STACK_RESUME=$(jq_safe -r '.task_stack // ""' "$_flow_state")
        if [ -f "$CRITERIA_FILE" ] && [ -f "${TASK_STACK_RESUME:-$TASK_STACK}" ]; then
          [ -n "$TASK_STACK_RESUME" ] && TASK_STACK="$TASK_STACK_RESUME"
          log "✓ Resume(flow-state): Phase 1.5 完了済み → Phase 2 から再開"
          _SKIP_PHASE1=true
          _RESUME=false
        fi
        ;;
    esac
  fi

  if [ "$_RESUME" = "true" ] && [ "$remand_count" -eq 0 ]; then
    _state_file="${STATE_DIR}/current-research.json"
    if [ -f "$_state_file" ]; then
      _prev_dir=$(jq_safe -r '.research_dir // ""' "$_state_file")
      _prev_theme=$(jq_safe -r '.theme // ""' "$_state_file")

      if [ -n "$_prev_theme" ] && [ "$_prev_theme" != "$THEME" ]; then
        log "⚠ テーマ不一致（前回: ${_prev_theme}）→ Phase 1 から再実行"
      elif [ -f "${_prev_dir}/implementation-criteria.json" ]; then
        CRITERIA_FILE="${_prev_dir}/implementation-criteria.json"
        log "✓ Resume: criteria 検出 → Phase 1 + 1.5 スキップ"
        if [ -f "$TASK_STACK" ]; then
          log "✓ Resume: task-stack 検出 → Phase 2 へ直行"
        else
          log "  task-stack 不在 → Phase 1.5 から実行"
          GENERATE_ARGS=("$CRITERIA_FILE" "$TASK_STACK")
          [ -n "${WORK_DIR:-}" ] && GENERATE_ARGS+=("$WORK_DIR")
          bash "${LOOPS_DIR}/generate-tasks.sh" "${GENERATE_ARGS[@]}" || { log "✗ Phase 1.5 失敗"; exit 1; }
        fi
        _SKIP_PHASE1=true
      else
        log "  リカバリ可能なアーティファクト不在 → Phase 1 から再実行"
      fi
    fi
    _RESUME=false
  fi

  if [ "$_SKIP_PHASE1" != "true" ]; then
  # ===== Phase 1: Research =====
  log ""
  log "========== Phase 1: Research =========="

  RESEARCH_ARGS=("$THEME")
  if [ -n "$DIRECTION" ]; then
    RESEARCH_ARGS+=("$DIRECTION")
  fi
  if [ -n "${_RESEARCH_CONFIG_ARG:-}" ]; then
    RESEARCH_ARGS+=(--research-config "$_RESEARCH_CONFIG_ARG")
  fi

  if ! bash "${LOOPS_DIR}/research-loop.sh" "${RESEARCH_ARGS[@]}"; then
    log "✗ Phase 1 (Research) が異常終了"
    exit 1
  fi

  # research-loop.sh が生成した criteria ファイルを検出
  RESEARCH_DIR_PATH=$(jq_safe -r '.research_dir // empty' "${STATE_DIR}/current-research.json" 2>/dev/null)
  if [ -n "$RESEARCH_DIR_PATH" ]; then
    CRITERIA_FILE="${RESEARCH_DIR_PATH}/implementation-criteria.json"
  else
    CRITERIA_FILE=""
  fi

  if [ -z "$CRITERIA_FILE" ] || [ ! -f "$CRITERIA_FILE" ]; then
    log "✗ Implementation Criteria が見つかりません"
    log "  research-loop.sh の出力を確認してください"
    exit 1
  fi

  log "✓ Phase 1 完了: ${CRITERIA_FILE}"
  echo '{"completed_phase":"1","criteria":"'"$CRITERIA_FILE"'"}' > "${STATE_DIR}/flow-state.json"

  # ===== Phase 1.5: Task Planning =====
  log ""
  log "========== Phase 1.5: Task Planning =========="

  GENERATE_ARGS=("$CRITERIA_FILE" "$TASK_STACK")
  if [ -n "${WORK_DIR:-}" ]; then
    GENERATE_ARGS+=("$WORK_DIR")
  fi
  if ! bash "${LOOPS_DIR}/generate-tasks.sh" "${GENERATE_ARGS[@]}"; then
    log "✗ Phase 1.5 (Task Planning) が異常終了"
    exit 1
  fi

  log "✓ Phase 1.5 完了: ${TASK_STACK}"
  echo '{"completed_phase":"1.5","criteria":"'"$CRITERIA_FILE"'","task_stack":"'"$TASK_STACK"'"}' > "${STATE_DIR}/flow-state.json"

  fi # _SKIP_PHASE1

  # ===== 人間チェックポイント =====
  log ""
  if [ -t 0 ]; then
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${BOLD}${CYAN}║       Phase 2 開始前チェックポイント             ║${NC}" >&2
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}" >&2
    echo -e "  タスクスタック: ${TASK_STACK}" >&2
    echo -e "  タスク数: $(jq '.tasks | length' "$TASK_STACK" 2>/dev/null || echo '?')" >&2

    # dev-phase 構成表示
    _phase_count=$(jq '.phases // [] | length' "$TASK_STACK" 2>/dev/null || echo 0)
    if [ "$_phase_count" -gt 0 ]; then
      echo -e "" >&2
      echo -e "  ${BOLD}dev-phase構成:${NC}" >&2
      jq_safe -r '
        .phases[] |
        "    \(.id) (\([.exit_criteria[]? | select(.type == "auto")] | length) auto tests): \"\(.goal)\""
      ' "$TASK_STACK" 2>/dev/null | while IFS= read -r line; do
        echo -e "  $line" >&2
      done

      # テストスクリプト存在確認
      echo -e "" >&2
      echo -e "  ${BOLD}テストスクリプト:${NC}" >&2
      for _pid in $(jq_safe -r '.phases[].id' "$TASK_STACK" 2>/dev/null); do
        _test_file=".forge/state/phase-tests/${_pid}.sh"
        if [ -f "$_test_file" ]; then
          echo -e "    ${GREEN}✓${NC} ${_test_file}" >&2
        else
          echo -e "    ${YELLOW}○${NC} ${_test_file} (未生成)" >&2
        fi
      done
    fi

    echo -e "" >&2
    echo -e "  制御モード: ${PHASE_CONTROL}" >&2
    echo -e "" >&2
    echo -e "  ${YELLOW}${HUMAN_CHECKPOINT_TIMEOUT}秒以内に Enter を押すと続行します。${NC}" >&2
    echo -e "  ${YELLOW}何も入力しなければ自動で続行します。${NC}" >&2
    echo -e "  ${YELLOW}'q' を入力すると中断します。${NC}" >&2

    CHECKPOINT_INPUT=""
    read -t "$HUMAN_CHECKPOINT_TIMEOUT" -r CHECKPOINT_INPUT 2>/dev/null || true

    if [ "$CHECKPOINT_INPUT" = "q" ] || [ "$CHECKPOINT_INPUT" = "Q" ]; then
      log "人間チェックポイントで中断"
      exit 0
    fi
  else
    log "非対話モード: 人間チェックポイントをスキップ"
  fi

  # ===== Phase 2: Development =====
  log ""
  log "========== Phase 2: Development =========="

  RALPH_ARGS=("$TASK_STACK" --criteria "$CRITERIA_FILE" --phase-control "${PHASE_CONTROL}")
  if [ -n "$WORK_DIR" ]; then
    RALPH_ARGS+=(--work-dir "$WORK_DIR")
  fi
  if [ -n "${_RESEARCH_CONFIG_ARG:-}" ] && [ -f "$_RESEARCH_CONFIG_ARG" ]; then
    RALPH_ARGS+=(--research-config "$_RESEARCH_CONFIG_ARG")
  fi
  bash "${LOOPS_DIR}/ralph-loop.sh" "${RALPH_ARGS[@]}"
  RALPH_EXIT=$?

  # ===== RALPH_EXIT 評価 =====
  if [ "$RALPH_EXIT" -ne 0 ] && [ ! -f "$LOOP_SIGNAL_FILE" ]; then
    log "✗ Phase 2 失敗（exit code: $RALPH_EXIT）"
    update_progress "development" "failed" "ralph-loop.sh exited with $RALPH_EXIT" 0
    exit 1
  fi

  # ===== RESEARCH_REMAND 検出 =====
  if [ -f "$LOOP_SIGNAL_FILE" ]; then
    SIGNAL=$(cat "$LOOP_SIGNAL_FILE" | tr -d '\r\n')
    rm -f "$LOOP_SIGNAL_FILE"

    if [ "$SIGNAL" = "RESEARCH_REMAND" ]; then
      remand_count=$((remand_count + 1))
      log ""
      log "⚠ RESEARCH_REMAND 検出（${remand_count}/${MAX_RESEARCH_REMANDS}）"

      if [ "$remand_count" -ge "$MAX_RESEARCH_REMANDS" ]; then
        log "✗ リサーチ差戻し上限到達。フロー終了"
        echo -e "${RED}${BOLD}リサーチ差戻し上限（${MAX_RESEARCH_REMANDS}回）に到達しました。${NC}" >&2
        echo -e "手動でテーマまたは方向性を見直してください。" >&2
        exit 1
      fi

      log "→ Phase 1 から再実行します"
      _SKIP_PHASE1=false
      continue
    fi
  fi

  # RESEARCH_REMAND でなければフロー完了
  echo '{"completed_phase":"2"}' > "${STATE_DIR}/flow-state.json"
  break
done

# ===== フロー完了 =====
log ""
log "=========================================="
log "Forge Flow 完了"
log "リサーチ差戻し回数: ${remand_count}"
log "=========================================="

# ダッシュボード表示
if [ -f "${LOOPS_DIR}/dashboard.sh" ]; then
  log "ダッシュボード表示..."
  bash "${LOOPS_DIR}/dashboard.sh" "$TASK_STACK"
fi
