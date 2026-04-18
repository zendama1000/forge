#!/bin/bash
# render-events.sh — task-stack ⇄ decisions.jsonl 統合ユーティリティ
#
# 役割:
#   render-loop.sh から呼び出され、以下の3機能を提供する共有ライブラリ。
#     1. task-stack.json の status を jq で安全に遷移（in_progress → done 等）
#     2. decisions.jsonl に type=render_completed イベントを append-only で追記
#     3. タスク status の取得（現状確認 / 冪等化）
#
# 依存:
#   - jq（必須）
#   - common.sh の log / jq_safe（源として source 済みを想定するが、
#     単体テストのために log が未定義でも動作するよう guard する）
#
# 使い方:
#   source .forge/lib/render-events.sh
#   mark_task_in_progress  <task_stack.json> <task_id>
#   mark_task_done         <task_stack.json> <task_id>
#   get_task_status        <task_stack.json> <task_id>
#   emit_render_completed_event  <decisions.jsonl> <task_id> <job_id> <output_path>
#   emit_render_event      <decisions.jsonl> <task_id> <event_type> [detail_json]

# ----------------------------------------------------------------------------
# log の未定義ガード（単体テストで common.sh を source しないパスに備える）
# ----------------------------------------------------------------------------
if ! declare -F log >/dev/null 2>&1; then
  log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fi

# ----------------------------------------------------------------------------
# get_task_status — タスクの現在 status を返す（存在しなければ空文字）
# ----------------------------------------------------------------------------
get_task_status() {
  local task_stack="$1" task_id="$2"
  if [ -z "$task_stack" ] || [ -z "$task_id" ]; then
    echo ""
    return 2
  fi
  if [ ! -f "$task_stack" ]; then
    echo ""
    return 2
  fi
  jq -r --arg id "$task_id" \
    '.tasks[]? | select(.task_id == $id) | .status // empty' \
    "$task_stack" 2>/dev/null | tr -d '\r' | head -n1
}

# ----------------------------------------------------------------------------
# _update_task_status_atomic — 任意の status に遷移（内部ヘルパー）
# ----------------------------------------------------------------------------
_update_task_status_atomic() {
  local task_stack="$1" task_id="$2" new_status="$3"
  if [ -z "$task_stack" ] || [ -z "$task_id" ] || [ -z "$new_status" ]; then
    log "✗ render-events: _update_task_status_atomic 引数不足"
    return 2
  fi
  if [ ! -f "$task_stack" ]; then
    log "✗ render-events: task-stack.json が存在しません: ${task_stack}"
    return 2
  fi
  local tmp="${task_stack}.render-events.tmp"
  jq --arg id "$task_id" --arg s "$new_status" --arg ts "$(date -Iseconds)" '
    .tasks |= map(
      if .task_id == $id then .status = $s | .updated_at = $ts else . end
    ) | .updated_at = $ts
  ' "$task_stack" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$task_stack"
  return 0
}

# ----------------------------------------------------------------------------
# mark_task_in_progress — status を in_progress に遷移
# ----------------------------------------------------------------------------
mark_task_in_progress() {
  local task_stack="$1" task_id="$2"
  _update_task_status_atomic "$task_stack" "$task_id" "in_progress"
}

# ----------------------------------------------------------------------------
# mark_task_done — status を in_progress → done に遷移
#
# 冪等: 既に done の場合は no-op で 0 を返す。
# それ以外（pending / in_progress / blocked_render 等）は done に上書きする。
# ----------------------------------------------------------------------------
mark_task_done() {
  local task_stack="$1" task_id="$2"
  local current
  current=$(get_task_status "$task_stack" "$task_id")
  if [ "$current" = "done" ]; then
    log "  ℹ render-events: task ${task_id} は既に done（冪等スキップ）"
    return 0
  fi
  _update_task_status_atomic "$task_stack" "$task_id" "done"
}

# ----------------------------------------------------------------------------
# emit_render_event — decisions.jsonl に任意イベントを append
#
# 使い方: emit_render_event <decisions.jsonl> <task_id> <event_type> [detail_json]
# detail_json 省略時は {} として記録する。
# ----------------------------------------------------------------------------
emit_render_event() {
  local decisions_file="$1" task_id="$2" event_type="$3"
  local detail="${4:-{\}}"
  if [ -z "$decisions_file" ] || [ -z "$task_id" ] || [ -z "$event_type" ]; then
    log "✗ render-events: emit_render_event 引数不足"
    return 2
  fi
  # ファイルが無ければ空で初期化（append-only の前提を担保）
  mkdir -p "$(dirname "$decisions_file")" 2>/dev/null || true
  [ -f "$decisions_file" ] || : > "$decisions_file"
  jq -cn \
    --arg type "$event_type" \
    --arg tid  "$task_id" \
    --arg ts   "$(date -Iseconds)" \
    --argjson d "$detail" \
    '{type: $type, task_id: $tid, timestamp: $ts, detail: $d}' \
    >> "$decisions_file"
}

# ----------------------------------------------------------------------------
# emit_render_completed_event — type=render_completed 固定の便利ラッパー
# ----------------------------------------------------------------------------
emit_render_completed_event() {
  local decisions_file="$1" task_id="$2" job_id="${3:-}" output_path="${4:-}"
  if [ -z "$decisions_file" ] || [ -z "$task_id" ]; then
    log "✗ render-events: emit_render_completed_event 引数不足"
    return 2
  fi
  local detail
  detail=$(jq -cn --arg j "$job_id" --arg o "$output_path" \
    '{job_id: $j, output: $o}')
  emit_render_event "$decisions_file" "$task_id" "render_completed" "$detail"
}
