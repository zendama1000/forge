#!/bin/bash
# render-loop.sh v3.2 — 動画レンダリングループ（Ralph Loop の video-domain 派生）
#
# 使い方:
#   bash .forge/loops/render-loop.sh <task-stack.json> [--work-dir <dir>] \
#                                    [--render-config <file>] [--scenario <id>]
#
# 位置引数 1: render-task-stack.json（Phase 1.5 の task-planner が生成）
# オプション:
#   --work-dir        : 作業ディレクトリ（既定: PROJECT_ROOT）
#   --render-config   : Render-System 用設定（省略時 .forge/config/development.json）
#   --scenario        : シナリオ識別子（scenarios/{id}/scenario.json を参照）
#
# 設計:
#   - Ralph 原則をそのまま踏襲（1 タスク = 1 独立セッション、状態はファイル経由）
#   - validate_task_changes は動画レンダ領域では有効でないため、
#     ffprobe / size_threshold / RenderJob status を検証する validate_render_output に置換。
#   - 副作用は WORK_DIR 側に限定し、PROJECT_ROOT（ハーネス本体）は触らない。

set -euo pipefail

# ===== 異常終了時クリーンアップ =====
_render_cleanup_on_exit() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ -f "${TASK_STACK:-}" ]; then
    local in_progress_ids
    in_progress_ids=$(jq_safe -r '.tasks[]? | select(.status == "in_progress") | .task_id' \
      "$TASK_STACK" 2>/dev/null || true)
    for tid in $in_progress_ids; do
      jq --arg id "$tid" --arg ts "$(date -Iseconds)" '
        .tasks |= map(
          if .task_id == $id then .status = "interrupted" | .updated_at = $ts else . end
        ) | .updated_at = $ts
      ' "$TASK_STACK" > "${TASK_STACK}.tmp" 2>/dev/null \
        && mv "${TASK_STACK}.tmp" "$TASK_STACK"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ 異常終了検出（exit=${exit_code}）— render task ${tid} を interrupted に更新" >&2
    done
  fi
}
trap _render_cleanup_on_exit EXIT INT TERM

# ===== 共通初期化 =====
# bootstrap.sh が PROJECT_ROOT / SCRIPT_DIR / common.sh 読込を担う。
# shellcheck disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"

# video-assertions は ffprobe / size_threshold 評価ロジックを提供する。
# shellcheck disable=SC1090,SC1091
if [ -f "${PROJECT_ROOT}/.forge/lib/video-assertions.sh" ]; then
  source "${PROJECT_ROOT}/.forge/lib/video-assertions.sh"
fi

# ===== 依存コマンドチェック =====
check_dependencies jq timeout

# ffprobe は存在しなければ validate_render_output が明示エラーを返す（下で検出）。
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "[WARN] ffprobe が PATH に存在しません。validate_render_output は preflight 失敗を返します。" >&2
fi

# ===== パス定数 =====
AGENTS_DIR=".claude/agents"
TEMPLATES_DIR=".forge/templates"
SCHEMAS_DIR=".forge/schemas"
RENDER_LOG_DIR=".forge/logs/render"
RENDER_JOBS_FILE=".forge/state/render-jobs.jsonl"
RENDER_SIGNAL_FILE=".forge/state/render-signal"
HEARTBEAT_FILE=".forge/state/render-heartbeat.json"
ERRORS_FILE=".forge/state/errors.jsonl"
RENDER_EVENTS_FILE=".forge/state/render-events.jsonl"

# common.sh 互換変数
RESEARCH_DIR="render-session-$(date +%Y%m%d-%H%M%S)"
json_fail_count=0

# ===== 引数パース =====
_TASK_STACK_ARG=""
_WORK_DIR_ARG=""
_RENDER_CONFIG_ARG=""
_SCENARIO_ARG=""
_positional_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir) _WORK_DIR_ARG="$2"; shift 2 ;;
    --work-dir=*) _WORK_DIR_ARG="${1#*=}"; shift ;;
    --render-config) _RENDER_CONFIG_ARG="$2"; shift 2 ;;
    --render-config=*) _RENDER_CONFIG_ARG="${1#*=}"; shift ;;
    --scenario) _SCENARIO_ARG="$2"; shift 2 ;;
    --scenario=*) _SCENARIO_ARG="${1#*=}"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 <task-stack.json> [--work-dir <dir>] [--render-config <file>] [--scenario <id>]
EOF
      exit 0 ;;
    -*) echo "不明なオプション: $1" >&2; exit 1 ;;
    *) _positional_args+=("$1"); shift ;;
  esac
done

if [ ${#_positional_args[@]} -lt 1 ]; then
  echo "使い方: $0 <task-stack.json> [--work-dir <dir>] [--render-config <file>] [--scenario <id>]" >&2
  exit 1
fi

_TASK_STACK_ARG="${_positional_args[0]}"
TASK_STACK="$(cd "$(dirname "$_TASK_STACK_ARG")" && pwd)/$(basename "$_TASK_STACK_ARG")"
WORK_DIR="${_WORK_DIR_ARG:-$PROJECT_ROOT}"
RENDER_CONFIG="${_RENDER_CONFIG_ARG:-${PROJECT_ROOT}/.forge/config/development.json}"
SCENARIO_ID="${_SCENARIO_ARG:-}"

if [ ! -f "$TASK_STACK" ]; then
  echo "[ERROR] task-stack.json が見つかりません: ${TASK_STACK}" >&2
  exit 1
fi
if [ ! -d "$WORK_DIR" ]; then
  echo "[ERROR] 作業ディレクトリが見つかりません: ${WORK_DIR}" >&2
  exit 1
fi

# ===== エージェント定義存在チェック（ソフト）=====
if [ ! -f "${AGENTS_DIR}/implementer.md" ]; then
  echo "[WARN] エージェント定義が見つかりません: ${AGENTS_DIR}/implementer.md" >&2
fi

# ===== 状態ディレクトリ準備 =====
mkdir -p "$RENDER_LOG_DIR" ".forge/state"
[ -f "$RENDER_JOBS_FILE" ] || : > "$RENDER_JOBS_FILE"
[ -f "$RENDER_EVENTS_FILE" ] || : > "$RENDER_EVENTS_FILE"
[ -f "$ERRORS_FILE" ] || : > "$ERRORS_FILE"

# ===== 設定読込 =====
# development.json の render セクション（存在すれば）を読み、既定値は動画レンダ向けに調整。
load_render_config() {
  if [ -f "$RENDER_CONFIG" ]; then
    IMPLEMENTER_MODEL=$(jq_safe -r '.implementer.model // "sonnet"' "$RENDER_CONFIG")
    IMPLEMENTER_TIMEOUT=$(jq_safe -r '.implementer.timeout_sec // 1200' "$RENDER_CONFIG")
    RENDER_DEFAULT_TIMEOUT=$(jq_safe -r '.render.default_timeout_sec // 1800' "$RENDER_CONFIG")
    RENDER_SIZE_THRESHOLD=$(jq_safe -r '.render.size_threshold_bytes // 102400' "$RENDER_CONFIG")
    RENDER_MIN_DURATION=$(jq_safe -r '.render.min_duration_sec // 1' "$RENDER_CONFIG")
    RENDER_MAX_TASK_RETRIES=$(jq_safe -r '.render.max_task_retries // 2' "$RENDER_CONFIG")
  else
    IMPLEMENTER_MODEL="sonnet"
    IMPLEMENTER_TIMEOUT=1200
    RENDER_DEFAULT_TIMEOUT=1800
    RENDER_SIZE_THRESHOLD=102400
    RENDER_MIN_DURATION=1
    RENDER_MAX_TASK_RETRIES=2
  fi
}
load_render_config

log "render-loop 起動  task_stack=${TASK_STACK}  work_dir=${WORK_DIR}  scenario=${SCENARIO_ID:-<none>}"

# ===== Render Jobs 管理 =====
# render-jobs.jsonl に 1 行 1 ジョブで status 遷移を記録する。
# JSON: {"job_id":"...","task_id":"...","status":"pending|running|completed|failed","output":"...","updated_at":"..."}
record_render_job() {
  local job_id="$1" task_id="$2" status="$3" output="${4:-}"
  local _empty_obj='{}'
  local extra="${5:-$_empty_obj}"
  local ts
  ts="$(date -Iseconds)"
  local line
  line=$(jq -cn \
    --arg j "$job_id" --arg t "$task_id" --arg s "$status" \
    --arg o "$output" --arg ts "$ts" --argjson e "$extra" \
    '{job_id:$j, task_id:$t, status:$s, output:$o, updated_at:$ts} + $e')
  echo "$line" >> "$RENDER_JOBS_FILE"
}

render_job_status() {
  local job_id="$1"
  if [ ! -f "$RENDER_JOBS_FILE" ]; then
    echo "unknown"; return 0
  fi
  jq -r --arg j "$job_id" 'select(.job_id == $j) | .status' "$RENDER_JOBS_FILE" 2>/dev/null \
    | tail -1 || echo "unknown"
}

render_job_output_path() {
  local job_id="$1"
  jq -r --arg j "$job_id" 'select(.job_id == $j) | .output' "$RENDER_JOBS_FILE" 2>/dev/null \
    | tail -1 || true
}

# ===== validate_render_output — validate_task_changes の置換 =====
#
# 使い方:
#   validate_render_output <output_file> <size_threshold_bytes> <job_id>
#
# 検証:
#   1. ffprobe が出力ファイルを読めること（コーデック/ストリームが検出できる）
#   2. 出力ファイルサイズが size_threshold_bytes 以上
#   3. render-jobs.jsonl の最新 status が "completed"
#
# 戻り値:
#   0 = 全て通過
#   1 = サイズ不足
#   2 = ffprobe エラー（壊れた動画 / 非動画）
#   3 = ffprobe preflight 失敗（ffprobe 不在）
#   4 = RenderJob status != completed
#   5 = 引数エラー / 出力ファイル不在
validate_render_output() {
  local output_file="${1:-}"
  local size_threshold="${2:-${RENDER_SIZE_THRESHOLD:-102400}}"
  local job_id="${3:-}"

  # --- 引数・存在チェック ---
  if [ -z "$output_file" ]; then
    log "✗ validate_render_output: output_file 引数が空"
    return 5
  fi
  if [ ! -f "$output_file" ]; then
    log "✗ validate_render_output: 出力ファイルが存在しません: ${output_file}"
    return 5
  fi

  # --- ffprobe preflight（無ければ rc=3 を上流へ伝播） ---
  if ! command -v ffprobe >/dev/null 2>&1; then
    log "✗ validate_render_output: ffprobe が PATH に存在しません (preflight)"
    return 3
  fi

  # --- (1) ffprobe による動画ファイル妥当性検証 ---
  local ff_out ff_rc=0
  ff_out=$(
    timeout "${FFPROBE_DEFAULT_TIMEOUT_SEC:-60}" \
      ffprobe -v error -select_streams v:0 \
              -show_entries stream=codec_name,width,height \
              -of default=noprint_wrappers=1:nokey=1 \
              "$output_file" 2>&1
  ) || ff_rc=$?

  if [ "$ff_rc" -ne 0 ] || [ -z "$ff_out" ]; then
    log "✗ validate_render_output: ffprobe が読み取り失敗 (rc=${ff_rc}) ${output_file}"
    log "    ffprobe 出力: $(echo "$ff_out" | head -c 400)"
    return 2
  fi

  # --- (2) サイズ閾値チェック ---
  local actual_size
  if command -v stat >/dev/null 2>&1; then
    # Linux/mac 互換の -c/-f を順に試す
    actual_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo 0)
  else
    actual_size=$(wc -c < "$output_file" | tr -d ' ')
  fi
  actual_size=${actual_size:-0}

  if ! [[ "$actual_size" =~ ^[0-9]+$ ]]; then
    log "✗ validate_render_output: サイズ取得失敗（非数値: ${actual_size}）"
    return 1
  fi

  if [ "$actual_size" -lt "$size_threshold" ]; then
    log "✗ validate_render_output: サイズ不足 ${actual_size} < ${size_threshold} バイト"
    return 1
  fi

  # --- (3) RenderJob status チェック ---
  if [ -n "$job_id" ]; then
    local job_status
    job_status=$(render_job_status "$job_id")
    if [ "$job_status" != "completed" ]; then
      log "✗ validate_render_output: RenderJob [${job_id}] status=${job_status} (期待: completed)"
      return 4
    fi
  fi

  log "✓ validate_render_output: PASS ffprobe=ok size=${actual_size} >= ${size_threshold} status=completed"
  return 0
}

# ===== シナリオ情報ロード =====
# scenarios/<id>/scenario.json があれば agent_prompt_patch 等を取り込む。
load_scenario() {
  SCENARIO_PATCH=""
  SCENARIO_TYPE=""
  if [ -z "$SCENARIO_ID" ]; then
    return 0
  fi
  local scenario_file="${WORK_DIR}/scenarios/${SCENARIO_ID}/scenario.json"
  if [ ! -f "$scenario_file" ]; then
    log "⚠ シナリオ定義が見つかりません: ${scenario_file}"
    return 0
  fi
  SCENARIO_TYPE=$(jq_safe -r '.type // ""' "$scenario_file")
  SCENARIO_PATCH=$(jq_safe -r '.agent_prompt_patch // ""' "$scenario_file")
  log "シナリオロード: id=${SCENARIO_ID} type=${SCENARIO_TYPE}"
}

# ===== 次タスク選択 =====
# depends_on を満たした pending タスクを優先度順に返す。
select_next_render_task() {
  jq -r '
    [.tasks[]
      | select(.status == "pending")
      | select(
          (.depends_on // []) as $deps
          | ($deps | length == 0) or all($deps[]; . as $d |
               any(.tasks[]?; .task_id == $d and .status == "completed")
             )
        )
      | .task_id
    ][0] // empty
  ' "$TASK_STACK" 2>/dev/null || true
}

update_task_state() {
  local task_id="$1" new_state="$2"
  jq --arg id "$task_id" --arg s "$new_state" --arg ts "$(date -Iseconds)" '
    .tasks |= map(
      if .task_id == $id then .status = $s | .updated_at = $ts else . end
    ) | .updated_at = $ts
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
}

record_render_event() {
  local task_id="$1" event="$2"
  local _empty_obj='{}'
  local detail="${3:-$_empty_obj}"
  local ts
  ts="$(date -Iseconds)"
  jq -cn --arg t "$task_id" --arg e "$event" --arg ts "$ts" --argjson d "$detail" \
    '{task_id:$t, event:$e, timestamp:$ts, detail:$d}' \
    >> "$RENDER_EVENTS_FILE"
}

# ===== Implementer 起動（1 render タスク分） =====
# Ralph 原則: 独立セッション。common.sh の run_claude を使う。
run_render_implementer() {
  local task_id="$1" task_dir="$2" task_json="$3"

  local agent_file="${AGENTS_DIR}/implementer.md"
  local prompt_file="${task_dir}/prompt.md"
  local output_file="${task_dir}/implementation-output.txt"
  local log_file="${task_dir}/implementer.log"

  # プロンプト組み立て（agent_prompt_patch は scenario.json 由来）
  {
    echo "# Render Task: ${task_id}"
    echo ""
    echo "## Task JSON"
    echo '```json'
    echo "$task_json" | jq -S . 2>/dev/null || echo "$task_json"
    echo '```'
    echo ""
    if [ -n "${SCENARIO_PATCH:-}" ]; then
      echo "## Scenario prompt patch"
      echo "$SCENARIO_PATCH"
      echo ""
    fi
    echo "## Working Directory"
    echo "${WORK_DIR}"
  } > "$prompt_file"

  local disallowed=""
  run_claude "$IMPLEMENTER_MODEL" "$agent_file" "$prompt_file" \
             "$output_file" "$log_file" "$disallowed" \
             "$IMPLEMENTER_TIMEOUT" "$WORK_DIR" || {
    log "  ✗ Implementer 実行失敗 (${task_id})"
    record_error "render-implementer-${task_id}" "Claude 実行エラー"
    return 1
  }

  # .pending → 本ファイル昇格（common.sh 規約）
  [ -f "${output_file}.pending" ] && mv "${output_file}.pending" "$output_file"
  return 0
}

# ===== 1 タスク処理 =====
render_task() {
  local task_id="$1"
  local task_dir="${RENDER_LOG_DIR}/${task_id}"
  mkdir -p "$task_dir"

  log "--- render task: ${task_id} ---"

  update_task_state "$task_id" "in_progress"
  record_render_event "$task_id" "task_started" "{}"

  local task_json
  task_json=$(jq -c --arg id "$task_id" '.tasks[] | select(.task_id == $id)' "$TASK_STACK")

  local expected_output
  expected_output=$(echo "$task_json" \
    | jq -r '.render.output // .output // empty')
  local job_id
  job_id=$(echo "$task_json" | jq -r '.render.job_id // .task_id')
  local size_threshold
  size_threshold=$(echo "$task_json" \
    | jq -r --arg def "$RENDER_SIZE_THRESHOLD" '.render.size_threshold // ($def|tonumber)')

  # チェックポイント（git 管理下の場合のみ）
  if git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    task_checkpoint_create "$WORK_DIR" "$task_id" 2>/dev/null || true
  fi

  record_render_job "$job_id" "$task_id" "running" "$expected_output" "{}"

  # === Implementer（render コマンド生成 + 実行） ===
  if ! run_render_implementer "$task_id" "$task_dir" "$task_json"; then
    record_render_job "$job_id" "$task_id" "failed" "$expected_output" "{}"
    record_render_event "$task_id" "implementer_failed" "{}"
    handle_render_fail "$task_id" "$task_dir" "Implementer 実行エラー"
    return 1
  fi

  # Implementer が書き出した成果物の status を completed として記録
  record_render_job "$job_id" "$task_id" "completed" "$expected_output" "{}"

  # === validate_render_output === validate_task_changes の置換箇所
  local vr_out vr_rc=0
  if [ -z "$expected_output" ]; then
    log "  ⚠ task_json に .render.output が無い — サイズ検証をスキップ"
  else
    vr_out=$(validate_render_output "$expected_output" "$size_threshold" "$job_id" 2>&1) || vr_rc=$?
    echo "$vr_out" > "${task_dir}/validate-render-output.log"
    if [ "$vr_rc" -ne 0 ]; then
      log "  ✗ validate_render_output 失敗 (rc=${vr_rc})"
      record_render_job "$job_id" "$task_id" "failed" "$expected_output" \
        "$(jq -cn --arg r "$vr_rc" '{validate_rc:($r|tonumber)}')"
      handle_render_fail "$task_id" "$task_dir" \
        "validate_render_output rc=${vr_rc}"
      return 1
    fi
  fi

  # === Layer 1 テスト（shell level — task 定義に command があれば実行） ===
  local l1_cmd
  l1_cmd=$(echo "$task_json" | jq -r '.validation.layer_1.command // ""')
  if [ -n "$l1_cmd" ]; then
    local l1_out l1_rc=0
    l1_out=$(timeout "${L1_DEFAULT_TIMEOUT:-120}" bash -c "$l1_cmd" 2>&1) || l1_rc=$?
    echo "$l1_out" > "${task_dir}/l1-output.txt"
    if [ "$l1_rc" -ne 0 ]; then
      log "  ✗ Layer 1 テスト失敗 (rc=${l1_rc})"
      handle_render_fail "$task_id" "$task_dir" "Layer 1 テスト失敗: ${l1_cmd}"
      return 1
    fi
  fi

  handle_render_pass "$task_id"
  return 0
}

handle_render_pass() {
  local task_id="$1"
  update_task_state "$task_id" "completed"
  record_render_event "$task_id" "task_completed" "{}"
  log "  ✓ render task ${task_id} 完了"

  # タスクごと auto-commit（残留差分の累積防止）
  if git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    local uncommitted
    uncommitted=$(git -C "$WORK_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$uncommitted" -gt 0 ]; then
      git -C "$WORK_DIR" add -A 2>/dev/null || true
      git -C "$WORK_DIR" commit -m "render: ${task_id} completed" --no-verify 2>/dev/null \
        && log "  [AUTO-COMMIT] ${task_id} の変更をコミット (${uncommitted} files)" \
        || log "  ⚠ [AUTO-COMMIT] コミット失敗 (${task_id})"
    fi
  fi
}

handle_render_fail() {
  local task_id="$1"
  local task_dir="$2"
  local message="${3:-}"

  # 失敗カウントをインクリメント
  local prev
  prev=$(jq -r --arg id "$task_id" \
    '.tasks[] | select(.task_id == $id) | .fail_count // 0' "$TASK_STACK")
  local next=$((prev + 1))

  jq --arg id "$task_id" --arg fc "$next" --arg ts "$(date -Iseconds)" '
    .tasks |= map(
      if .task_id == $id then
        .fail_count = ($fc | tonumber) | .updated_at = $ts
      else . end
    )
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"

  echo "$message" > "${task_dir}/fail-${next}.txt"
  record_render_event "$task_id" "task_failed" \
    "$(jq -cn --arg m "$message" --arg fc "$next" '{message:$m, fail_count:($fc|tonumber)}')"

  if [ "$next" -ge "$RENDER_MAX_TASK_RETRIES" ]; then
    update_task_state "$task_id" "blocked_render"
    log "  ✗ render task ${task_id}: 最大リトライ (${RENDER_MAX_TASK_RETRIES}) 到達 → blocked_render"
    notify_human "critical" "render task blocked: ${task_id}" "$message" || true
  else
    update_task_state "$task_id" "pending"
    log "  ↻ render task ${task_id}: リトライキューへ戻す (fail=${next}/${RENDER_MAX_TASK_RETRIES})"
  fi

  # チェックポイント復元
  if git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    task_checkpoint_restore "$WORK_DIR" "$task_id" 2>/dev/null || true
  fi
}

update_render_heartbeat() {
  local current_task="$1"
  jq -cn \
    --arg ts "$(date -Iseconds)" \
    --arg t "$current_task" \
    --arg scn "${SCENARIO_ID:-}" \
    '{timestamp:$ts, current_task:$t, scenario:$scn, loop:"render-loop"}' \
    > "$HEARTBEAT_FILE.tmp" && mv "$HEARTBEAT_FILE.tmp" "$HEARTBEAT_FILE"
}

# ===== in_progress 残留の自動復帰 =====
reclaim_stale_in_progress() {
  local stale
  stale=$(jq -r '.tasks[]? | select(.status == "in_progress") | .task_id' "$TASK_STACK" 2>/dev/null || true)
  for t in $stale; do
    log "⚠ 起動時 in_progress 残留を検出: ${t} → pending に戻す"
    update_task_state "$t" "pending"
  done
}

# ===== サマリ表示 =====
print_render_summary() {
  local total completed failed blocked
  total=$(jq '.tasks | length' "$TASK_STACK" 2>/dev/null || echo 0)
  completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  failed=$(jq '[.tasks[] | select(.status == "blocked_render")] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  blocked=$(jq '[.tasks[] | select(.status != "completed" and .status != "blocked_render")] | length' \
    "$TASK_STACK" 2>/dev/null || echo 0)

  echo ""
  echo "========================================"
  echo " render-loop summary"
  echo "----------------------------------------"
  echo "  total        : ${total}"
  echo "  completed    : ${completed}"
  echo "  blocked      : ${failed}"
  echo "  outstanding  : ${blocked}"
  echo "========================================"
}

# ===== メインループ =====
main() {
  load_scenario
  reclaim_stale_in_progress

  local loop_count=0
  local max_loop
  max_loop=$(jq '.tasks | length' "$TASK_STACK" 2>/dev/null || echo 50)
  max_loop=$((max_loop * (RENDER_MAX_TASK_RETRIES + 1) + 5))

  while :; do
    loop_count=$((loop_count + 1))
    if [ "$loop_count" -gt "$max_loop" ]; then
      log "⚠ ループ上限 (${max_loop}) 到達 — 中断"
      break
    fi

    # 外部シグナル（render-signal）による中断
    if [ -f "$RENDER_SIGNAL_FILE" ]; then
      local sig
      sig=$(cat "$RENDER_SIGNAL_FILE" 2>/dev/null || echo "")
      if [ "$sig" = "stop" ]; then
        log "外部シグナル受信 → 中断"
        rm -f "$RENDER_SIGNAL_FILE"
        break
      fi
    fi

    local next
    next=$(select_next_render_task)
    if [ -z "$next" ]; then
      local remaining
      remaining=$(jq '[.tasks[] | select(.status != "completed" and .status != "blocked_render")] | length' \
        "$TASK_STACK" 2>/dev/null || echo 0)
      if [ "$remaining" -eq 0 ]; then
        log "✓ 全 render task 完了"
      else
        log "⚠ 実行可能な render task なし（残 ${remaining}件）— 依存関係を確認"
        notify_human "warning" "render-loop: 実行可能タスクなし" \
          "残 ${remaining} 件。depends_on または blocked_render を確認してください" || true
      fi
      break
    fi

    update_render_heartbeat "$next"
    render_task "$next" || true
  done

  update_render_heartbeat "loop-finished"
  print_render_summary
}

main "$@"
