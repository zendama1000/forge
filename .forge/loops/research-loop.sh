#!/bin/bash
# research-loop.sh v2.0 - Forge Research Harness オーケストレーター
# 使い方: ./research-loop.sh "テーマ" ["方向性"] [--research-config <file>]
#
# v2.0変更点: DA削除、リニアフロー化（SC→R→Syn→criteria→report）、research-config対応。
# 設計書: forge-architecture-v3.2.md
# Ralph原則: 各ステージは独立セッション。完全コンテキストリセット。状態はファイル経由。

set -euo pipefail

# ===== 異常終了時クリーンアップ（B2: stuck state 防止） =====
_cleanup_on_exit() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ -f "${STATE_FILE:-}" ]; then
    local current_status
    current_status=$(jq_safe -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [ "$current_status" = "running" ]; then
      jq --arg ts "$(date -Iseconds)" \
        '.status = "interrupted" | .updated_at = $ts | .exit_code = '"$exit_code" \
        "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ 異常終了検出（exit=$exit_code）— current-research.json を interrupted に更新" >&2
    fi
  fi
}
trap _cleanup_on_exit EXIT

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"

# ===== コマンド依存チェック =====
check_dependencies claude jq md5sum timeout

# ===== パス定数 =====
AGENTS_DIR=".claude/agents"
TEMPLATES_DIR=".forge/templates"
SCHEMAS_DIR=".forge/schemas"

# ===== エージェント・テンプレート存在チェック =====
for agent in scope-challenger researcher synthesizer; do
  if [ ! -f "${AGENTS_DIR}/${agent}.md" ]; then
    echo -e "${RED}[ERROR] エージェント定義が見つかりません: ${AGENTS_DIR}/${agent}.md${NC}" >&2
    exit 1
  fi
done
for tmpl in scope-challenger-prompt researcher-prompt synthesizer-prompt; do
  if [ ! -f "${TEMPLATES_DIR}/${tmpl}.md" ]; then
    echo -e "${RED}[ERROR] テンプレートが見つかりません: ${TEMPLATES_DIR}/${tmpl}.md${NC}" >&2
    exit 1
  fi
done

# ===== 引数チェック =====
_RESEARCH_CONFIG_FILE=""
_positional_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --research-config=*) _RESEARCH_CONFIG_FILE="${1#*=}"; shift ;;
    --research-config)   _RESEARCH_CONFIG_FILE="$2"; shift 2 ;;
    *)                   _positional_args+=("$1"); shift ;;
  esac
done
set -- "${_positional_args[@]}"

if [ $# -lt 1 ]; then
  echo "使い方: $0 \"テーマ\" [\"方向性\"] [--research-config <file>]" >&2
  exit 1
fi

THEME="$1"
DIRECTION="${2:-}"

# Research Config 読み込み（Phase 0 で生成、locked/open の分類）
RESEARCH_MODE="explore"
LOCKED_DECISIONS_TEXT="（なし）"
OPEN_QUESTIONS_TEXT="（なし）"
if [ -n "$_RESEARCH_CONFIG_FILE" ] && [ -f "$_RESEARCH_CONFIG_FILE" ]; then
  RESEARCH_MODE=$(jq_safe -r '.mode // "explore"' "$_RESEARCH_CONFIG_FILE")
  LOCKED_DECISIONS_TEXT=$(jq_safe -r '
    .locked_decisions // [] |
    map("- \(.decision) (理由: \(.reason))") | join("\n")
  ' "$_RESEARCH_CONFIG_FILE")
  OPEN_QUESTIONS_TEXT=$(jq_safe -r '
    .open_questions // [] |
    map("- \(.)") | join("\n")
  ' "$_RESEARCH_CONFIG_FILE")
  [ -z "$LOCKED_DECISIONS_TEXT" ] && LOCKED_DECISIONS_TEXT="（なし）"
  [ -z "$OPEN_QUESTIONS_TEXT" ] && OPEN_QUESTIONS_TEXT="（なし）"
  log "Research Config: mode=${RESEARCH_MODE}, locked=${LOCKED_DECISIONS_TEXT:0:50}..."
fi

TOPIC_HASH=$(echo "$THEME" | md5sum | cut -c1-6)
DATE=$(date +%Y-%m-%d)
START_TS=$(date +%Y%m%d-%H%M%S)
RESEARCH_DIR=".docs/research/${DATE}-${TOPIC_HASH}-${START_TS##*-}"
STATE_FILE=".forge/state/current-research.json"
DECISIONS_FILE=".forge/state/decisions.jsonl"
ERRORS_FILE=".forge/state/errors.jsonl"
LOG_DIR=".forge/logs/research"

# ===== 設定読み込み（circuit-breaker.json からフォールバック付き） =====
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"

load_research_config() {
  if [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
    MAX_JSON_FAILS_PER_LOOP=$(jq_safe -r '.research_limits.max_json_fails_per_loop // 3' "$CIRCUIT_BREAKER_CONFIG")
    CLAUDE_TIMEOUT=$(jq_safe -r '.research_limits.claude_timeout_sec // 600' "$CIRCUIT_BREAKER_CONFIG")
    MAX_DECISIONS_IN_PROMPT=$(jq_safe -r '.research_limits.max_decisions_in_prompt // 30' "$CIRCUIT_BREAKER_CONFIG")
    PARALLEL_ALL_FAIL_COOLDOWN_SEC=$(jq_safe -r '.research_limits.parallel_all_fail_cooldown_sec // 30' "$CIRCUIT_BREAKER_CONFIG")
    PERSPECTIVE_MAX_CONSECUTIVE_FAILS=$(jq_safe -r '.research_limits.perspective_max_consecutive_fails // 3' "$CIRCUIT_BREAKER_CONFIG")
  else
    log "⚠ circuit-breaker.json が見つかりません。デフォルト値を使用"
    MAX_JSON_FAILS_PER_LOOP=3
    CLAUDE_TIMEOUT=600
    MAX_DECISIONS_IN_PROMPT=30
    PARALLEL_ALL_FAIL_COOLDOWN_SEC=30
    PERSPECTIVE_MAX_CONSECUTIVE_FAILS=3
  fi
}

# G3: research.json からモデル・ツール・タイムアウト設定を読み込む
RESEARCH_CONFIG="${PROJECT_ROOT}/.forge/config/research.json"

load_research_models() {
  if [ -f "$RESEARCH_CONFIG" ]; then
    MODEL_SC=$(jq_safe -r '.models.scope_challenger // "opus"' "$RESEARCH_CONFIG")
    MODEL_RESEARCHER=$(jq_safe -r '.models.researcher // "sonnet"' "$RESEARCH_CONFIG")
    MODEL_SYNTHESIZER=$(jq_safe -r '.models.synthesizer // "opus"' "$RESEARCH_CONFIG")
    MODEL_CRITERIA=$(jq_safe -r '.models.criteria_generation // "opus"' "$RESEARCH_CONFIG")
    MODEL_REPORT=$(jq_safe -r '.models.final_report // "opus"' "$RESEARCH_CONFIG")

    TOOLS_SC=$(jq_safe -r '.disallowed_tools.scope_challenger // "WebSearch WebFetch"' "$RESEARCH_CONFIG")
    TOOLS_RESEARCHER=$(jq_safe -r '.disallowed_tools.researcher // ""' "$RESEARCH_CONFIG")
    TOOLS_SYNTHESIZER=$(jq_safe -r '.disallowed_tools.synthesizer // "WebSearch WebFetch"' "$RESEARCH_CONFIG")

    TIMEOUT_SC=$(jq_safe -r '.timeouts.scope_challenger_sec // 300' "$RESEARCH_CONFIG")
    TIMEOUT_RESEARCHER=$(jq_safe -r '.timeouts.researcher_sec // 600' "$RESEARCH_CONFIG")
    TIMEOUT_SYNTHESIZER=$(jq_safe -r '.timeouts.synthesizer_sec // 600' "$RESEARCH_CONFIG")
    TIMEOUT_CRITERIA=$(jq_safe -r '.timeouts.criteria_generation_sec // 900' "$RESEARCH_CONFIG")

    PARALLEL_RESEARCHERS=$(jq_safe -r '.parallel_researchers // true' "$RESEARCH_CONFIG")
  else
    log "⚠ research.json が見つかりません。デフォルト値を使用"
    MODEL_SC="opus"; MODEL_RESEARCHER="sonnet"; MODEL_SYNTHESIZER="opus"
    MODEL_CRITERIA="opus"; MODEL_REPORT="opus"
    TOOLS_SC="WebSearch WebFetch"; TOOLS_RESEARCHER=""
    TOOLS_SYNTHESIZER="WebSearch WebFetch"
    TIMEOUT_SC=300; TIMEOUT_RESEARCHER=600; TIMEOUT_SYNTHESIZER=600; TIMEOUT_CRITERIA=900
    PARALLEL_RESEARCHERS=true
  fi
}

load_research_config
load_research_models

# ===== 設定スキーマ検証（起動時） =====
_RL_SCHEMAS_DIR="${PROJECT_ROOT}/.forge/schemas"
if ! validate_config "${CIRCUIT_BREAKER_CONFIG}" "${_RL_SCHEMAS_DIR}/circuit-breaker.schema.json"; then
  echo -e "${RED}[ERROR] circuit-breaker.json スキーマ検証失敗${NC}" >&2
  exit 1
fi
if ! validate_config "${RESEARCH_CONFIG}" "${_RL_SCHEMAS_DIR}/research.schema.json"; then
  echo -e "${RED}[ERROR] research.json スキーマ検証失敗${NC}" >&2
  exit 1
fi
unset _RL_SCHEMAS_DIR

# ループ制御カウンタ
json_fail_count=0

# ===== ディレクトリ準備 =====
mkdir -p "$RESEARCH_DIR" "$LOG_DIR" ".forge/state"

# ===== 状態ファイル初期化（存在しない場合のみ） =====
if [ ! -f "$ERRORS_FILE" ]; then
  touch "$ERRORS_FILE"
fi
if [ ! -f "$DECISIONS_FILE" ]; then
  touch "$DECISIONS_FILE"
fi

# ===== ユーティリティ関数 =====
# log(), now_ts(), render_template(), run_claude(), validate_json(),
# record_error(), check_dependencies() は common.sh から提供

# jqで安全にJSON生成（シェル変数の特殊文字をエスケープ）
# started_atはリサーチ開始時刻を保持（上書きしない）
update_state() {
  local stage="$1"
  local status="${2:-running}"
  jq -n \
    --arg status "$status" \
    --arg theme "$THEME" \
    --arg research_dir "$RESEARCH_DIR" \
    --arg stage "$stage" \
    --arg mode "$RESEARCH_MODE" \
    --arg started "$START_TS" \
    --arg updated "$(date -Iseconds)" \
    '{
      status: $status,
      theme: $theme,
      research_dir: $research_dir,
      current_stage: $stage,
      research_mode: $mode,
      started_at: $started,
      updated_at: $updated
    }' > "$STATE_FILE"
}

# エラーローテーション（設計書 §4.4）
rotate_errors() {
  [ -f "$ERRORS_FILE" ] || return 0
  local line_count
  line_count=$(wc -l < "$ERRORS_FILE" 2>/dev/null | tr -d ' ')
  line_count=${line_count:-0}
  if [ "$line_count" -gt 100 ]; then
    log "errors.jsonl ローテーション実行（${line_count}行 > 100行）"
    jq -c 'select(.resolution != null)' "$ERRORS_FILE" \
      >> "${LOG_DIR}/errors-archive.jsonl" 2>/dev/null || true
    jq -c 'select(.resolution == null)' "$ERRORS_FILE" \
      > "${ERRORS_FILE}.tmp" 2>/dev/null || true
    mv "${ERRORS_FILE}.tmp" "$ERRORS_FILE"
  fi
}

# G8: decisions.jsonl の要約注入（50件超対応）
# 件数が少ない間は原文、多くなったら要約+参照パス
get_recent_decisions() {
  if [ ! -s "$DECISIONS_FILE" ]; then
    return
  fi
  local total_lines
  total_lines=$(wc -l < "$DECISIONS_FILE" 2>/dev/null | tr -d ' ')
  total_lines=${total_lines:-0}

  if [ "$total_lines" -le "$MAX_DECISIONS_IN_PROMPT" ]; then
    # 件数が閾値以下: 全件そのまま
    cat "$DECISIONS_FILE"
  else
    # 件数が閾値超: 要約形式（id, theme, decision, verdict のみ抽出）+ 参照パス
    echo "（${total_lines}件中、直近${MAX_DECISIONS_IN_PROMPT}件を要約表示。原文: ${DECISIONS_FILE}）"
    tail -n "$MAX_DECISIONS_IN_PROMPT" "$DECISIONS_FILE" | jq -c '{id, theme, decision, verdict}' 2>/dev/null
  fi
}

# ===== ① Scope Challenger =====
# 検索なし（設計書 §2.4: 内部分析のみ。外部情報は先入観のリスク）
run_scope_challenger() {
  log "① Scope Challenger 開始"
  update_state "scope-challenger"
  update_progress "research" "scope-challenger" "Scope Challenger 実行中" "10"

  local ts
  ts=$(now_ts)
  local output="${RESEARCH_DIR}/investigation-plan.json"
  local log_file="${LOG_DIR}/sc-${ts}-${TOPIC_HASH}.log"

  # 過去決定コンテキスト
  local decisions=""
  local recent_decisions
  recent_decisions=$(get_recent_decisions)
  if [ -n "$recent_decisions" ]; then
    decisions="直近${MAX_DECISIONS_IN_PROMPT}件:
${recent_decisions}"
  else
    decisions="（なし）"
  fi

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/scope-challenger-prompt.md" \
    "THEME"              "$THEME" \
    "DIRECTION"          "${DIRECTION:-（指定なし。テーマから自律的に判断すること）}" \
    "DECISIONS"          "$decisions" \
    "RESEARCH_MODE"      "$RESEARCH_MODE" \
    "LOCKED_DECISIONS"   "$LOCKED_DECISIONS_TEXT" \
    "OPEN_QUESTIONS"     "$OPEN_QUESTIONS_TEXT"
  )

  # --disallowed-tools: SC は検索禁止（設計書 §2.4）
  metrics_start
  retry_with_backoff 3 1 run_claude "$MODEL_SC" "${AGENTS_DIR}/scope-challenger.md" \
    "$prompt" "$output" "$log_file" "$TOOLS_SC" "$TIMEOUT_SC" "" \
    "${SCHEMAS_DIR}/scope-challenger.schema.json" || {
    metrics_record "scope-challenger" false
    record_error "scope-challenger" "Claude実行エラー"
    log "✗ Scope Challenger Claude実行エラー"
    return 1
  }

  if validate_json "$output" "scope-challenger"; then
    metrics_record "scope-challenger" true
  elif check_direct_write_fallback "$output" "scope-challenger"; then
    metrics_record "scope-challenger" true
  else
    metrics_record "scope-challenger" false
    return 1
  fi

  log "✓ Scope Challenger 完了 → ${output}"
  update_progress "research" "scope-challenger-done" "完了" "15"
}

# ===== 視点別連続失敗カウンタ（circuit-breaker parallel） =====
# perspective の連続失敗回数を RESEARCH_DIR 配下のファイルで管理する。
# サブシェル (background &) からも安全に読み書きできるようファイルベースで実装。

_get_perspective_fail_count() {
  local perspective="$1"
  local count_file="${RESEARCH_DIR}/.perspective-fails/${perspective}.count"
  [ -f "$count_file" ] && cat "$count_file" || echo "0"
}

_set_perspective_fail_count() {
  local perspective="$1"
  local count="$2"
  mkdir -p "${RESEARCH_DIR}/.perspective-fails"
  echo "$count" > "${RESEARCH_DIR}/.perspective-fails/${perspective}.count"
}

# perspective をスキップすべきか判定する。
# 連続失敗数が PERSPECTIVE_MAX_CONSECUTIVE_FAILS 以上の場合は 0 を返す。
should_skip_perspective() {
  local perspective="$1"
  local fail_count
  fail_count=$(_get_perspective_fail_count "$perspective")
  [ "$fail_count" -ge "${PERSPECTIVE_MAX_CONSECUTIVE_FAILS:-3}" ] && return 0
  return 1
}

# ===== 単一 Researcher 実行（サブシェル対応） =====
# 引数: perspective plan result_dir
# result_dir/<perspective>.status に "pass" / "fail" を書出す。
# result_dir/<perspective>.duration に経過秒を書出す。
_run_single_researcher() {
  local perspective="$1"
  local plan="$2"
  local result_dir="$3"
  local _start
  _start=$(date +%s)

  local ts
  ts=$(now_ts)
  local focus
  focus=$(jq_safe -r --arg p "$perspective" '
    .investigation_plan.perspectives |
    ((.fixed // []) + (.dynamic // [])) |
    .[] | select(.id == $p) | .focus
  ' "$plan" | tr -d '\r')

  local questions
  questions=$(jq -c --arg p "$perspective" '
    .investigation_plan.perspectives |
    ((.fixed // []) + (.dynamic // [])) |
    .[] | select(.id == $p) | .key_questions
  ' "$plan" | tr -d '\r')

  local output="${RESEARCH_DIR}/perspective-${perspective}.json"
  local log_file="${LOG_DIR}/r-${perspective}-${ts}-${TOPIC_HASH}.log"

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/researcher-prompt.md" \
    "PERSPECTIVE_ID" "$perspective" \
    "FOCUS"          "$focus" \
    "QUESTIONS"      "$questions"
  )

  # 各Researcherは独立セッション（Ralph原則: 完全リセット）
  retry_with_backoff 3 1 run_claude "$MODEL_RESEARCHER" "${AGENTS_DIR}/researcher.md" \
    "$prompt" "$output" "$log_file" "$TOOLS_RESEARCHER" "$TIMEOUT_RESEARCHER" "" \
    "${SCHEMAS_DIR}/researcher.schema.json" || {
    record_error "researcher-${perspective}" "Claude実行エラー"
    log "  ✗ Researcher [${perspective}] Claude実行エラー"
    echo "fail" > "${result_dir}/${perspective}.status"
    echo "$(($(date +%s) - _start))" > "${result_dir}/${perspective}.duration"
    return 0
  }

  if validate_json "$output" "researcher-${perspective}"; then
    echo "pass" > "${result_dir}/${perspective}.status"
  elif check_direct_write_fallback "$output" "researcher-${perspective}"; then
    echo "pass" > "${result_dir}/${perspective}.status"
  else
    echo "fail" > "${result_dir}/${perspective}.status"
  fi
  echo "$(($(date +%s) - _start))" > "${result_dir}/${perspective}.duration"
}

# ===== ② Researcher =====
# 検索あり（設計書 §2.4: 情報収集が本業）
# parallel_researchers=true 時は並列実行、false 時は順次実行
run_researchers() {
  log "② Researcher 開始"
  update_state "researcher"
  update_progress "research" "researcher" "Researcher 実行中" "20"

  local plan="${RESEARCH_DIR}/investigation-plan.json"

  # 視点一覧を取得（固定 + 動的）。tr -d '\r' でCRLF対策。
  local perspectives
  perspectives=$(jq_safe -r '
    .investigation_plan.perspectives |
    ((.fixed // []) + (.dynamic // [])) |
    .[].id
  ' "$plan" | tr -d '\r')

  if [ -z "$perspectives" ]; then
    record_error "researcher" "視点が0個"
    log "✗ 視点が取得できない"
    return 1
  fi

  local result_dir="${RESEARCH_DIR}/.researcher-results"
  mkdir -p "$result_dir"

  # _run_single_researcher は外部関数として定義済み（circuit-breaker parallel 対応）

  local perspective_count=0

  if [ "${PARALLEL_RESEARCHERS:-true}" = "true" ]; then
    log "  (並列実行モード)"
    local pids=()
    for perspective in $perspectives; do
      perspective_count=$((perspective_count + 1))

      # [circuit-breaker] 連続失敗閾値チェック: スキップ
      if should_skip_perspective "$perspective"; then
        log "  ⏭ Researcher [${perspective}] 連続$(_get_perspective_fail_count "$perspective")回失敗 — スキップ"
        echo "skipped" > "${result_dir}/${perspective}.status"
        echo "0" > "${result_dir}/${perspective}.duration"
        continue
      fi

      log "  ② Researcher [${perspective_count}] ${perspective} (background)"
      update_progress "research" "researcher-${perspective}" "[${perspective}]" ""
      _run_single_researcher "$perspective" "$plan" "$result_dir" &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    # 結果集約 [circuit-breaker: 全失敗検出のためにカウント]
    local pass_round_count=0
    local active_run_count=0
    for perspective in $perspectives; do
      local dur=0; [ -f "${result_dir}/${perspective}.duration" ] && dur=$(cat "${result_dir}/${perspective}.duration")
      local status="fail"; [ -f "${result_dir}/${perspective}.status" ] && status=$(cat "${result_dir}/${perspective}.status")
      # metrics.jsonl に記録
      jq -n -c --arg s "researcher-${perspective}" --argjson d "$dur" \
        --argjson ps "$([ "$status" = "pass" ] && echo true || echo false)" \
        --arg rd "${RESEARCH_DIR}" --arg ts "$(date -Iseconds)" \
        '{stage:$s,duration_sec:$d,parse_success:$ps,research_dir:$rd,timestamp:$ts}' >> "$METRICS_FILE"
      if [ "$status" = "pass" ]; then
        pass_round_count=$((pass_round_count + 1))
        active_run_count=$((active_run_count + 1))
        _set_perspective_fail_count "$perspective" 0
        log "  ✓ Researcher [${perspective}] 完了"
      elif [ "$status" = "skipped" ]; then
        log "  ⏭ Researcher [${perspective}] スキップ（連続失敗）"
      else
        active_run_count=$((active_run_count + 1))
        json_fail_count=$((json_fail_count + 1))
        local new_fail_count
        new_fail_count=$(( $(_get_perspective_fail_count "$perspective") + 1 ))
        _set_perspective_fail_count "$perspective" "$new_fail_count"
        log "  ✗ Researcher [${perspective}] 失敗（連続${new_fail_count}回）"
      fi
    done

    # [circuit-breaker] 全並列失敗検出: active 全件失敗 → クールダウン + リトライ
    if [ "$active_run_count" -gt 0 ] && [ "$pass_round_count" -eq 0 ]; then
      local _cooldown="${COOLDOWN_SEC:-${PARALLEL_ALL_FAIL_COOLDOWN_SEC}}"
      log "  ⚠ 全Researcher同時失敗検出（API障害パターン）— ${_cooldown}秒クールダウン後にリトライ"
      sleep "$_cooldown"

      # リトライ: 失敗 perspective を再実行（skipped はそのまま）
      local retry_pids=()
      for perspective in $perspectives; do
        local prev_s="fail"
        [ -f "${result_dir}/${perspective}.status" ] && prev_s=$(cat "${result_dir}/${perspective}.status")
        [ "$prev_s" = "skipped" ] && continue
        rm -f "${result_dir}/${perspective}.status" "${result_dir}/${perspective}.duration"
        log "  ↻ Researcher [${perspective}] リトライ (background)"
        _run_single_researcher "$perspective" "$plan" "$result_dir" &
        retry_pids+=($!)
      done
      for pid in "${retry_pids[@]}"; do wait "$pid" || true; done

      # リトライ結果集約: 初回失敗分を json_fail_count からロールバック
      json_fail_count=$((json_fail_count - active_run_count))
      local retry_pass_count=0
      for perspective in $perspectives; do
        local r_status="fail"
        [ -f "${result_dir}/${perspective}.status" ] && r_status=$(cat "${result_dir}/${perspective}.status")
        [ "$r_status" = "skipped" ] && continue
        if [ "$r_status" = "pass" ]; then
          retry_pass_count=$((retry_pass_count + 1))
          _set_perspective_fail_count "$perspective" 0
          log "  ✓ Researcher [${perspective}] リトライ成功"
        else
          json_fail_count=$((json_fail_count + 1))
          local retry_fail_count
          retry_fail_count=$(( $(_get_perspective_fail_count "$perspective") + 1 ))
          _set_perspective_fail_count "$perspective" "$retry_fail_count"
          log "  ✗ Researcher [${perspective}] リトライ失敗（連続${retry_fail_count}回）"
        fi
      done

      if [ "$retry_pass_count" -ge 3 ]; then
        log "  ✓ クールダウン後回復（${retry_pass_count}件成功）— json_fail_countリセット"
        json_fail_count=0
      else
        log "  ✗ クールダウン後も全件失敗 — AUTO-ABORT"
        record_error "parallel-researcher" "全並列Researcher失敗（クールダウン後リトライも全失敗）"
        update_state "aborted" "auto-abort-json-failures"
        rm -rf "$result_dir"
        return 1
      fi
    fi
  else
    log "  (順次実行モード)"
    for perspective in $perspectives; do
      perspective_count=$((perspective_count + 1))
      log "  ② Researcher [${perspective_count}] 視点: ${perspective}"
      update_progress "research" "researcher-${perspective}" "[${perspective}]" ""

      metrics_start
      _run_single_researcher "$perspective" "$plan" "$result_dir"

      local dur=0; [ -f "${result_dir}/${perspective}.duration" ] && dur=$(cat "${result_dir}/${perspective}.duration")
      local status="fail"; [ -f "${result_dir}/${perspective}.status" ] && status=$(cat "${result_dir}/${perspective}.status")
      if [ "$status" = "pass" ]; then
        metrics_record "researcher-${perspective}" true
        log "  ✓ Researcher [${perspective}] 完了 → ${RESEARCH_DIR}/perspective-${perspective}.json"
      else
        metrics_record "researcher-${perspective}" false
        log "  ✗ Researcher [${perspective}] 失敗"
      fi
    done
  fi

  rm -rf "$result_dir"
  log "✓ Researcher 全視点完了（${perspective_count}視点）"
  update_progress "research" "researcher-done" "全Researcher完了" "50"
}

# ===== ③ Synthesizer =====
# 検索なし（設計書 §2.4: 統合のみ。追加検索は役割逸脱）
run_synthesizer() {
  log "③ Synthesizer 開始"
  update_state "synthesizer"
  update_progress "research" "synthesizer" "Synthesizer 実行中" "60"

  local ts
  ts=$(now_ts)
  local output="${RESEARCH_DIR}/synthesis.json"
  local log_file="${LOG_DIR}/syn-${ts}-${TOPIC_HASH}.log"

  # 調査計画を読み込む
  local investigation_plan
  investigation_plan=$(cat "${RESEARCH_DIR}/investigation-plan.json")

  # 全Researcherレポートを結合
  local all_reports=""
  for report_file in "${RESEARCH_DIR}"/perspective-*.json; do
    if [ -f "$report_file" ]; then
      all_reports="${all_reports}
--- $(basename "$report_file") ---
$(cat "$report_file")
"
    fi
  done

  # 過去決定コンテキスト
  local decisions=""
  local recent_decisions
  recent_decisions=$(get_recent_decisions)
  if [ -n "$recent_decisions" ]; then
    decisions="直近${MAX_DECISIONS_IN_PROMPT}件:
${recent_decisions}"
  else
    decisions="（なし）"
  fi

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/synthesizer-prompt.md" \
    "INVESTIGATION_PLAN" "$investigation_plan" \
    "ALL_REPORTS"        "$all_reports" \
    "DECISIONS"          "$decisions" \
    "RESEARCH_MODE"      "$RESEARCH_MODE" \
    "LOCKED_DECISIONS"   "$LOCKED_DECISIONS_TEXT"
  )

  # --disallowed-tools: Synthesizer は検索禁止（設計書 §2.4）
  metrics_start
  retry_with_backoff 3 1 run_claude "$MODEL_SYNTHESIZER" "${AGENTS_DIR}/synthesizer.md" \
    "$prompt" "$output" "$log_file" "$TOOLS_SYNTHESIZER" "$TIMEOUT_SYNTHESIZER" "" \
    "${SCHEMAS_DIR}/synthesizer.schema.json" || {
    metrics_record "synthesizer" false
    record_error "synthesizer" "Claude実行エラー"
    log "✗ Synthesizer Claude実行エラー"
    return 1
  }

  if validate_json "$output" "synthesizer"; then
    metrics_record "synthesizer" true
  elif check_direct_write_fallback "$output" "synthesizer"; then
    metrics_record "synthesizer" true
  else
    metrics_record "synthesizer" false
    return 1
  fi

  log "✓ Synthesizer 完了 → ${output}"
  update_progress "research" "synthesizer-done" "完了" "70"
}

# ===== implementation-criteria.json 生成（v3.2: Research→Development接続） =====
# GO verdict 後に呼び出す。Synthesizer出力から3層の成功条件を導出。
# 失敗時は warn のみ（リサーチ結果自体は保存済み）。
generate_criteria() {
  log "implementation-criteria.json 生成中..."

  local ts
  ts=$(now_ts)
  local synthesis="${RESEARCH_DIR}/synthesis.json"
  local output="${RESEARCH_DIR}/implementation-criteria.json"
  local log_file="${LOG_DIR}/criteria-${ts}-${TOPIC_HASH}.log"
  local research_id="${DATE}-${TOPIC_HASH}-${START_TS##*-}"

  if [ ! -s "$synthesis" ]; then
    log "⚠ synthesis.json が見つかりません。criteria生成をスキップ"
    return 0
  fi

  local synthesis_content
  synthesis_content=$(cat "$synthesis")

  # SERVER_URL 取得（common.sh の get_server_url を使用）
  local server_url
  server_url=$(get_server_url)

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/criteria-generation.md" \
    "SYNTHESIS"    "$synthesis_content" \
    "THEME"        "$THEME" \
    "RESEARCH_ID"  "$research_id" \
    "SERVER_URL"   "$server_url"
  )

  # Synthesizer エージェントを再利用（検索禁止）
  run_claude "$MODEL_CRITERIA" "${AGENTS_DIR}/synthesizer.md" \
    "$prompt" "$output" "$log_file" "WebSearch WebFetch" "$TIMEOUT_CRITERIA" "" \
    "${SCHEMAS_DIR}/criteria.schema.json" || {
    log "⚠ implementation-criteria.json 生成失敗（リサーチ結果自体は保存済み）"
    return 0
  }

  if validate_json "$output" "criteria-generation"; then
    # 基本スキーマ検証: layer_1_criteria の存在チェック
    if jq -e '.layer_1_criteria' "$output" >/dev/null 2>&1; then
      log "✓ implementation-criteria.json → ${output}"
    else
      log "⚠ implementation-criteria.json に layer_1_criteria が含まれていません"
    fi
  elif check_direct_write_fallback "$output" "criteria-generation"; then
    if jq -e '.layer_1_criteria' "$output" >/dev/null 2>&1; then
      log "✓ implementation-criteria.json → ${output}（直接書き込みフォールバック）"
    else
      log "⚠ implementation-criteria.json に layer_1_criteria が含まれていません（直接書き込みフォールバック）"
    fi
  else
    log "⚠ implementation-criteria.json 生成失敗（JSON検証エラー）"
  fi
}

# ===== 最終レポート生成 =====
generate_final_report() {
  log "最終レポート生成中..."

  local ts
  ts=$(now_ts)
  local output="${RESEARCH_DIR}/final-report.md"
  local log_file="${LOG_DIR}/report-${ts}-${TOPIC_HASH}.log"

  local prompt="以下のリサーチ結果から、人間が読みやすい日本語の最終レポートを生成してください。
Markdown形式で、見出し・表・箇条書きを適切に使ってください。

リサーチディレクトリ: ${RESEARCH_DIR}

以下のファイルを全て読み込んでレポートにまとめてください:
- ${RESEARCH_DIR}/investigation-plan.json
- ${RESEARCH_DIR}/perspective-*.json（全ファイル）
- ${RESEARCH_DIR}/synthesis.json
- ${RESEARCH_DIR}/implementation-criteria.json（生成されている場合）"

  run_claude "$MODEL_REPORT" "" "$prompt" "$output" "$log_file" "" "" || {
    log "⚠ 最終レポート生成失敗（リサーチ結果自体は保存済み）"
    return 0
  }

  log "✓ 最終レポート → ${output}"
}

# ===== decisions.jsonlへの記録（jqで安全にJSON生成） =====
record_decision() {
  local primary_action
  primary_action=$(jq_safe -r '.synthesis.recommendations.primary.action // "不明"' "${RESEARCH_DIR}/synthesis.json")
  local primary_rationale
  primary_rationale=$(jq_safe -r '.synthesis.recommendations.primary.rationale // "不明"' "${RESEARCH_DIR}/synthesis.json")

  local decision_id="d-$(date +%Y%m%d)-$(date +%H%M%S)"

  jq -n -c \
    --arg id "$decision_id" \
    --arg theme "$THEME" \
    --arg decision "$primary_action" \
    --arg rationale "$primary_rationale" \
    --arg timestamp "$(date -Iseconds)" \
    '{id: $id, theme: $theme, decision: $decision, rationale: $rationale, verdict: "DIRECT", timestamp: $timestamp}' \
    >> "$DECISIONS_FILE"

  log "✓ 決定記録 → ${DECISIONS_FILE} (${decision_id})"

  # G4: index.md 自動更新
  update_research_index "$primary_action"
}

# ===== index.md 自動更新（G4） =====
update_research_index() {
  local action="${1:-}"
  local index_file=".docs/research/index.md"
  if [ ! -f "$index_file" ]; then
    return 0
  fi
  # テーマの | をエスケープ（Markdownテーブル壊れ防止）
  local safe_theme="${THEME//|/\\|}"
  local safe_action="${action//|/\\|}"
  local verdict_val="DIRECT"

  # プレースホルダー行を削除して実データ行を追記
  # テーブルの末尾に追記
  echo "| ${DATE} | ${safe_theme} | ${verdict_val} | [レポート](${RESEARCH_DIR}/final-report.md) |" >> "$index_file"
  log "✓ index.md 更新 → ${index_file}"
}

# ===== メインループ =====
log "=========================================="
log "Forge Research Harness v2.0 開始"
log "テーマ: ${THEME}"
log "方向性: ${DIRECTION:-（なし）}"
log "出力先: ${RESEARCH_DIR}"
log "=========================================="

# B2: 起動時にstuck状態チェック
if [ -f "$STATE_FILE" ]; then
  _prev_status=$(jq_safe -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
  if [ "$_prev_status" = "running" ]; then
    log "⚠ 前回リサーチが running のまま残っています。interrupted に更新して続行。"
    jq --arg ts "$(date -Iseconds)" \
      '.status = "interrupted" | .updated_at = $ts' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
fi

# 初期状態を running に設定
update_state "initializing" "running"

# エラーローテーション
rotate_errors

# 初回: Scope Challenger
run_scope_challenger || {
  log "✗ Scope Challenger 失敗。終了。"
  update_state "scope-challenger" "failed"
  exit 1
}

# ② Researcher
json_fail_count=0
run_researchers || {
  log "✗ Researcher 失敗。終了。"
  update_state "researcher" "failed"
  exit 1
}

# ABORT閾値チェック
if [ "$json_fail_count" -ge "$MAX_JSON_FAILS_PER_LOOP" ]; then
  log "✗ JSON検証失敗が${json_fail_count}件（閾値${MAX_JSON_FAILS_PER_LOOP}） — 自動ABORT"
  record_error "loop-control" "自動ABORT: JSON検証失敗${json_fail_count}件"
  update_state "aborted" "auto-abort-json-failures"
  exit 1
fi

# ③ Synthesizer
run_synthesizer || {
  log "✗ Synthesizer 失敗。終了。"
  update_state "synthesizer" "failed"
  exit 1
}

# ④ 決定記録 + criteria + レポート（DA不要、直接進行）
log "=========================================="
log "✓ リサーチ完了 — 意思決定を記録"
record_decision
generate_criteria
generate_final_report
update_state "completed" "completed"
log "✓ リサーチ完了"
log "=========================================="

log "=========================================="
log "Forge Research Harness 終了"
log "=========================================="
