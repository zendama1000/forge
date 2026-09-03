#!/bin/bash
# =============================================================================
# simulator.sh — フライトシミュレータ（record / replay / fault injection）
#
# run_claude() の実行層ダブル。全 claude -p 呼出を録画し、APIコストゼロで
# 決定論的にリプレイし、任意の呼出点に故障を注入する。
#
# 有効化（env チャネル、common.sh の _RC_* と同じ家風）:
#   RC_RECORD_DIR    録画先ディレクトリ（設定時、実行された全呼出を録画）
#   RC_REPLAY_DIR    再生元ディレクトリ（設定時、録画から応答を再生）
#   RC_REPLAY_STRICT 1(既定)=リプレイ miss は exit 97 / 0=実 CLI へフォールスルー
#   RC_FAULT_PLAN    故障プラン JSON のパス
#   RC_SIM_STATE_DIR 連番カウンタ・once フラグ等の状態ディレクトリ（省略時自動）
#
# 優先順位: FORGE_DRY_RUN > fault > replay > real
#（DRY_RUN は run_claude 側で先に return するため本ファイルには到達しない）
#
# 契約:
#   sim_call_begin  … Hook A。親シェルで呼ばれ、全状態変異（連番・fault 判定・
#                     replay lookup）をここで完結させる。_SIM_DECISION を設定。
#   sim_claude_exec … Hook B。work_dir 分岐ではサブシェル内で呼ばれるため、
#                     変数の変異は禁止 — ファイル効果と return code のみ。
#                     real 経路は common.sh 旧パイプラインの逐語移植であること。
# =============================================================================

: "${SIM_EXIT_REPLAY_MISS:=97}"

# 故障ペイロード定数。文言は実測に基づく（変更すると実検出器を通らなくなる）:
#   BUDGET      … test-per-call-guards.sh:206 の実測 CLI 文言（classify_run_claude_exit が grep）
#   RATE_LIMIT  … ralph-loop.sh detect_rate_limit_from_debug_logs の grep パターンに一致させる
#   QUOTA       … z-lang 運用で実測した quota 枯渇文言（現状ハーネスに検出器なし = BUG-REPRO 用）
SIM_PAYLOAD_BUDGET='Error: Exceeded USD budget (3.0)'
SIM_PAYLOAD_RATE_LIMIT='API Error: 429 Too Many Requests'
SIM_DEBUG_RATE_LIMIT_MARKER='{"type":"error","error":{"type":"rate_limit_error","message":"429 Too many requests"}}'
SIM_PAYLOAD_MALFORMED='{ "broken": [1, 2'
SIM_PAYLOAD_EXIT1='simulated transient error'
SIM_PAYLOAD_QUOTA="You've reached your usage limit. Your limit will reset at 3am."
SIM_FAULT_TYPES='timeout budget_exceeded rate_limit malformed_json empty_output exit_1 quota_exhausted'

# 単体テストで simulator.sh を直接 source する場合のフォールバック
type log &>/dev/null || log() { echo "$@" >&2; }

# ---------------------------------------------------------------------------
# sim_enabled — シミュレータ機能のいずれかが有効か
# ---------------------------------------------------------------------------
sim_enabled() {
  [ -n "${RC_RECORD_DIR:-}" ] || [ -n "${RC_REPLAY_DIR:-}" ] || [ -n "${RC_FAULT_PLAN:-}" ]
}

# ---------------------------------------------------------------------------
# sim_agent_label <agent_file> — basename から .md を除去。空/欠損は "none"
# ファイル名に安全な文字のみ残す
# ---------------------------------------------------------------------------
sim_agent_label() {
  local f="${1:-}"
  [ -z "$f" ] && { echo "none"; return 0; }
  local b
  b=$(basename "$f")
  b="${b%.md}"
  b=$(printf '%s' "$b" | tr -c 'a-zA-Z0-9_.-' '_')
  [ -z "$b" ] && b="none"
  printf '%s\n' "$b"
}

# ---------------------------------------------------------------------------
# sim_init — 遅延・冪等初期化。パス絶対化 / 状態 dir 作成 / fault プラン検証 /
#            リプレイ index 構築。親シェルでのみ呼ぶこと。
# ---------------------------------------------------------------------------
sim_init() {
  [ "${_SIM_INITIALIZED:-}" = "1" ] && return 0
  _SIM_INITIALIZED=1

  # cd 安全性: work_dir 分岐がサブシェルで cd するため、相対パスはここで絶対化
  local _si_base
  _si_base="$(pwd)"
  case "${RC_RECORD_DIR:-}" in
    "") ;; /*) ;; *) RC_RECORD_DIR="${_si_base}/${RC_RECORD_DIR}" ;;
  esac
  case "${RC_REPLAY_DIR:-}" in
    "") ;; /*) ;; *) RC_REPLAY_DIR="${_si_base}/${RC_REPLAY_DIR}" ;;
  esac
  case "${RC_FAULT_PLAN:-}" in
    "") ;; /*) ;; *) RC_FAULT_PLAN="${_si_base}/${RC_FAULT_PLAN}" ;;
  esac

  if [ -z "${RC_SIM_STATE_DIR:-}" ]; then
    local _si_parent="${RC_RECORD_DIR:-${RC_REPLAY_DIR:-${TMPDIR:-/tmp}}}"
    RC_SIM_STATE_DIR="${_si_parent}/.sim-state-${FORGE_SESSION_ID:-pid$$}"
  else
    case "$RC_SIM_STATE_DIR" in /*) ;; *) RC_SIM_STATE_DIR="${_si_base}/${RC_SIM_STATE_DIR}" ;; esac
  fi
  mkdir -p "$RC_SIM_STATE_DIR" 2>/dev/null
  [ -n "${RC_RECORD_DIR:-}" ] && mkdir -p "$RC_RECORD_DIR" 2>/dev/null

  # fault プラン検証: 不正なら loud warn 一度 + faults 無効（record/replay は無影響）
  _SIM_FAULTS_DISABLED=0
  _SIM_FAULT_RULES_COUNT=0
  if [ -n "${RC_FAULT_PLAN:-}" ]; then
    if [ ! -f "$RC_FAULT_PLAN" ] || ! jq -e '.rules | type == "array"' "$RC_FAULT_PLAN" >/dev/null 2>&1; then
      log "✗ [sim] fault plan が不正（$RC_FAULT_PLAN）— 故障注入を無効化（record/replay は継続）"
      _SIM_FAULTS_DISABLED=1
    else
      # 各ルールの必須フィールド + fault enum を検証
      local _si_bad
      _si_bad=$(jq -r --arg types "$SIM_FAULT_TYPES" '
        [.rules[] | select(
          (.match.agent_pattern // "") == "" or
          ((.fault // "") as $f | ($types | split(" ") | index($f)) == null)
        )] | length' "$RC_FAULT_PLAN" 2>/dev/null)
      if [ "${_si_bad:-1}" != "0" ]; then
        log "✗ [sim] fault plan に不正ルール ${_si_bad:-?} 件（agent_pattern 欠落 or 未知 fault）— 故障注入を無効化"
        _SIM_FAULTS_DISABLED=1
      else
        _SIM_FAULT_RULES_COUNT=$(jq -r '.rules | length' "$RC_FAULT_PLAN" 2>/dev/null || echo 0)
      fi
    fi
  fi

  # リプレイ index 構築: (agent|agent_seq) → path / call_id → path
  declare -gA _SIM_RIDX_KEY 2>/dev/null
  declare -gA _SIM_RIDX_ID 2>/dev/null
  if [ -n "${RC_REPLAY_DIR:-}" ] && [ -d "$RC_REPLAY_DIR" ]; then
    local _si_f _si_agent _si_seq _si_id
    for _si_f in "$RC_REPLAY_DIR"/call-*.json; do
      [ -f "$_si_f" ] || continue
      # 1 パスで 3 フィールドを取得（CRLF 除去込み）
      IFS=$'\t' read -r _si_agent _si_seq _si_id < <(
        jq -r '[(.agent // "none"), (.agent_seq // 0), (.call_id // 0)] | @tsv' "$_si_f" 2>/dev/null | tr -d '\r'
      )
      [ -n "${_si_agent:-}" ] || continue
      _SIM_RIDX_KEY["${_si_agent}|${_si_seq}"]="$_si_f"
      _SIM_RIDX_ID["${_si_id}"]="$_si_f"
    done
  fi
  return 0
}

# ---------------------------------------------------------------------------
# sim_next_seq <label> — per-agent 連番（ファイルベース: サブシェル/プロセス越え）
# ---------------------------------------------------------------------------
sim_next_seq() {
  local _sn_f="${RC_SIM_STATE_DIR}/seq-${1}"
  local _sn_n=0
  [ -f "$_sn_f" ] && _sn_n=$(tr -d '\r\n' < "$_sn_f" 2>/dev/null)
  case "$_sn_n" in ''|*[!0-9]*) _sn_n=0 ;; esac
  _sn_n=$((_sn_n + 1))
  printf '%d' "$_sn_n" > "$_sn_f"
  printf '%d\n' "$_sn_n"
}

# ---------------------------------------------------------------------------
# sim_match_fault — fault プランのルールを順次評価し、最初にマッチしたルールを発火
# 呼出前提: _SIM_AGENT 設定済み。マッチ時: _SIM_DECISION=fault,
# _SIM_FAULT_TYPE, _SIM_FAULT_PAYLOAD を設定。
# nth_call はルール毎の「パターン一致呼出」カウンタ（ファイル永続）で判定。
# ---------------------------------------------------------------------------
sim_match_fault() {
  [ "${_SIM_FAULTS_DISABLED:-1}" = "1" ] && return 0
  [ "${_SIM_FAULT_RULES_COUNT:-0}" -gt 0 ] || return 0

  local _sf_i=0
  while [ "$_sf_i" -lt "$_SIM_FAULT_RULES_COUNT" ]; do
    local _sf_rule _sf_pattern _sf_fault _sf_once _sf_nth
    _sf_rule=$(jq -c ".rules[$_sf_i]" "$RC_FAULT_PLAN" 2>/dev/null)
    _sf_pattern=$(printf '%s' "$_sf_rule" | jq -r '.match.agent_pattern // ""')

    if [ -n "$_sf_pattern" ] && printf '%s' "$_SIM_AGENT" | grep -Eq "$_sf_pattern" 2>/dev/null; then
      _sf_once=$(printf '%s' "$_sf_rule" | jq -r '.once // false')
      # once 消費済みならカウンタも進めず素通し
      if [ "$_sf_once" = "true" ] && [ -f "${RC_SIM_STATE_DIR}/rule-${_sf_i}.consumed" ]; then
        _sf_i=$((_sf_i + 1)); continue
      fi
      # ルール毎カウンタ（パターン一致した呼出のみカウント）
      local _sf_cf="${RC_SIM_STATE_DIR}/rule-${_sf_i}.count" _sf_c=0
      [ -f "$_sf_cf" ] && _sf_c=$(tr -d '\r\n' < "$_sf_cf" 2>/dev/null)
      case "$_sf_c" in ''|*[!0-9]*) _sf_c=0 ;; esac
      _sf_c=$((_sf_c + 1))
      printf '%d' "$_sf_c" > "$_sf_cf"

      _sf_nth=$(printf '%s' "$_sf_rule" | jq -r '.match.nth_call // 0')
      if [ "$_sf_nth" != "0" ] && [ "$_sf_c" != "$_sf_nth" ]; then
        _sf_i=$((_sf_i + 1)); continue
      fi

      # 発火
      _SIM_FAULT_TYPE=$(printf '%s' "$_sf_rule" | jq -r '.fault')
      _SIM_FAULT_PAYLOAD=$(printf '%s' "$_sf_rule" | jq -r '.payload // ""')
      if [ -z "$_SIM_FAULT_PAYLOAD" ]; then
        local _sf_pf
        _sf_pf=$(printf '%s' "$_sf_rule" | jq -r '.payload_file // ""')
        [ -n "$_sf_pf" ] && [ -f "$_sf_pf" ] && _SIM_FAULT_PAYLOAD=$(cat "$_sf_pf")
      fi
      [ "$_sf_once" = "true" ] && : > "${RC_SIM_STATE_DIR}/rule-${_sf_i}.consumed"
      _SIM_DECISION="fault"
      log "  ⚡ [sim] fault 注入: ${_SIM_FAULT_TYPE} (agent=${_SIM_AGENT} rule=${_sf_i} count=${_sf_c})"
      return 0
    fi
    _sf_i=$((_sf_i + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# sim_lookup_replay <label> <seq> <call_id> — 録画ファイルパスを echo（miss は空）
# 主キー (agent|seq)、フォールバックは call_id 完全一致 + agent 一致検証
# ---------------------------------------------------------------------------
sim_lookup_replay() {
  local _sl_key="${1}|${2}"
  local _sl_path="${_SIM_RIDX_KEY[$_sl_key]:-}"
  if [ -n "$_sl_path" ]; then
    printf '%s\n' "$_sl_path"
    return 0
  fi
  _sl_path="${_SIM_RIDX_ID[${3:-_}]:-}"
  if [ -n "$_sl_path" ]; then
    local _sl_agent
    _sl_agent=$(jq -r '.agent // ""' "$_sl_path" 2>/dev/null)
    if [ "$_sl_agent" = "$1" ]; then
      printf '%s\n' "$_sl_path"
      return 0
    fi
  fi
  printf ''
}

# ---------------------------------------------------------------------------
# sim_call_begin — Hook A（親シェル専用: 全状態変異はここで完結）
# 引数: agent_file model effort schema_file work_dir output_file timeout
# 設定: _SIM_DECISION = "" | real | replay | replay-miss | fault
# 常に rc=0（run_claude を壊さない）
# ---------------------------------------------------------------------------
sim_call_begin() {
  _SIM_DECISION=""
  _SIM_FAULT_TYPE=""
  _SIM_FAULT_PAYLOAD=""
  _SIM_REPLAY_FILE=""
  sim_enabled || return 0
  sim_init

  _SIM_AGENT=$(sim_agent_label "${1:-}")
  _SIM_SEQ=$(sim_next_seq "$_SIM_AGENT")
  _SIM_CTX_MODEL="${2:-}"
  _SIM_CTX_EFFORT="${3:-}"
  _SIM_CTX_SCHEMA="${4:-}"
  _SIM_CTX_WORKDIR="${5:-}"
  _SIM_CTX_OUTPUT="${6:-}"
  _SIM_CTX_TIMEOUT="${7:-}"
  _SIM_CALL_T0=$SECONDS
  _SIM_DECISION="real"

  # fault > replay > real
  sim_match_fault
  if [ "$_SIM_DECISION" != "fault" ] && [ -n "${RC_REPLAY_DIR:-}" ]; then
    _SIM_REPLAY_FILE=$(sim_lookup_replay "$_SIM_AGENT" "$_SIM_SEQ" "${FORGE_CALL_ID:-0}")
    if [ -n "$_SIM_REPLAY_FILE" ]; then
      _SIM_DECISION="replay"
    else
      jq -n -c \
        --argjson cid "${FORGE_CALL_ID:-0}" \
        --arg agent "$_SIM_AGENT" \
        --argjson seq "$_SIM_SEQ" \
        --arg strict "${RC_REPLAY_STRICT:-1}" \
        --arg ts "$(date -Iseconds)" \
        '{call_id:$cid, agent:$agent, agent_seq:$seq, strict:$strict, timestamp:$ts}' \
        >> "${RC_SIM_STATE_DIR}/replay-miss.jsonl" 2>/dev/null
      if [ "${RC_REPLAY_STRICT:-1}" = "1" ]; then
        _SIM_DECISION="replay-miss"
        log "  ✗ [sim] replay miss (agent=${_SIM_AGENT} seq=${_SIM_SEQ} call_id=${FORGE_CALL_ID:-0}) — strict モードのため exit ${SIM_EXIT_REPLAY_MISS}"
      else
        log "  ⚠ [sim] replay miss (agent=${_SIM_AGENT} seq=${_SIM_SEQ}) — lenient モード: 実 CLI へフォールスルー"
        _SIM_DECISION="real"
      fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# sim_parse_tokens <log_file> [dest_file] — トークン数を抽出（"in out" を echo）
# 1) debug log の grep（リプレイ合成ログ用 — sim_emit_replay が usage 行を書く）
# 2) 取れなければ dest のエンベロープ .usage を直接読む（batch#10 Stage1:
#    実 CLI は usage をデバッグログに出さないため、real 録画は封筒が正）
# ---------------------------------------------------------------------------
sim_parse_tokens() {
  local _st_in _st_out
  _st_in=$(grep -oE '"input_tokens":[[:space:]]*[0-9]+' "${1:-/dev/null}" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | tail -1)
  _st_out=$(grep -oE '"output_tokens":[[:space:]]*[0-9]+' "${1:-/dev/null}" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | tail -1)
  if [ "${_st_in:-0}" = "0" ] && [ "${_st_out:-0}" = "0" ] && [ -n "${2:-}" ] && [ -f "${2:-}" ]; then
    local _st_env
    _st_env=$(jq -r '"\(.usage.input_tokens // 0) \(.usage.output_tokens // 0)"' "${2}" 2>/dev/null)
    case "$_st_env" in
      ([0-9]*' '[0-9]*) read -r _st_in _st_out <<< "$_st_env" ;;
    esac
  fi
  printf '%d %d\n' "${_st_in:-0}" "${_st_out:-0}"
}

# ---------------------------------------------------------------------------
# sim_write_record <dest> <log_file> <exit_code> <duration> <source> <prompt>
# 録画。dest の生バイト（封筒抽出前・削除前）を response として保存。
# jq --rawfile 使用（ARG_MAX 安全）。失敗呼出（dest 欠損/空）も録画する。
# ---------------------------------------------------------------------------
sim_write_record() {
  local _sw_dest="$1" _sw_log="$2" _sw_rc="$3" _sw_dur="$4" _sw_src="$5" _sw_prompt="$6"
  local _sw_rec _sw_ptmp _sw_rtmp _sw_btmp
  _sw_rec="${RC_RECORD_DIR}/call-$(printf '%04d' "${FORGE_CALL_ID:-0}")-${_SIM_AGENT:-none}.json"
  _sw_ptmp="${RC_SIM_STATE_DIR}/rec-prompt.$$"
  _sw_rtmp="${RC_SIM_STATE_DIR}/rec-response.$$"
  _sw_btmp="${RC_SIM_STATE_DIR}/rec-response-b64.$$"

  printf '%s' "$_sw_prompt" > "$_sw_ptmp"
  if [ -f "$_sw_dest" ]; then
    cat "$_sw_dest" > "$_sw_rtmp" 2>/dev/null
  else
    : > "$_sw_rtmp"
  fi
  # response_b64 がリプレイの正（バイト厳密）。Windows jq はテキストモード出力で
  # LF→CRLF 変換するため、生テキストの再出力ではバイト同一性が壊れる。
  # base64 は decode 時に空白/CRLF を無視するのでこの問題を回避できる。
  base64 -w0 < "$_sw_rtmp" > "$_sw_btmp" 2>/dev/null || : > "$_sw_btmp"

  local _sw_in _sw_out
  read -r _sw_in _sw_out < <(sim_parse_tokens "$_sw_log" "$_sw_dest")

  local _sw_rl="false"
  if [ -f "$_sw_log" ] && tail -200 "$_sw_log" 2>/dev/null | grep -qE '429|too many requests|rate.limit|rate_limit|overloaded'; then
    _sw_rl="true"
  fi

  jq -n \
    --argjson version 1 \
    --argjson call_id "${FORGE_CALL_ID:-0}" \
    --arg agent "${_SIM_AGENT:-none}" \
    --argjson agent_seq "${_SIM_SEQ:-0}" \
    --arg model "${_SIM_CTX_MODEL:-}" \
    --arg effort "${_SIM_CTX_EFFORT:-}" \
    --arg schema "$(basename "${_SIM_CTX_SCHEMA:-}" 2>/dev/null || echo "")" \
    --arg work_dir "${_SIM_CTX_WORKDIR:-}" \
    --arg output_file "${_SIM_CTX_OUTPUT:-}" \
    --arg stage_timeout "${_SIM_CTX_TIMEOUT:-}" \
    --rawfile prompt "$_sw_ptmp" \
    --rawfile response "$_sw_rtmp" \
    --rawfile response_b64 "$_sw_btmp" \
    --argjson exit_code "$_sw_rc" \
    --argjson duration_sec "$_sw_dur" \
    --argjson input_tokens "${_sw_in:-0}" \
    --argjson output_tokens "${_sw_out:-0}" \
    --argjson debug_rate_limit_marker "$_sw_rl" \
    --arg source "$_sw_src" \
    --arg timestamp "$(date -Iseconds)" \
    --arg session_id "${FORGE_SESSION_ID:-}" \
    '{version:$version, call_id:$call_id, agent:$agent, agent_seq:$agent_seq,
      model:$model, effort:$effort, schema:$schema, work_dir:$work_dir,
      output_file:$output_file, stage_timeout:$stage_timeout,
      prompt:$prompt, response:$response, response_b64:$response_b64,
      exit_code:$exit_code,
      duration_sec:$duration_sec, input_tokens:$input_tokens,
      output_tokens:$output_tokens, debug_rate_limit_marker:$debug_rate_limit_marker,
      source:$source, timestamp:$timestamp, session_id:$session_id}' \
    > "$_sw_rec" 2>/dev/null \
    || log "  ⚠ [sim] 録画失敗: $_sw_rec"

  rm -f "$_sw_ptmp" "$_sw_rtmp" "$_sw_btmp" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# sim_emit_replay <record_file> <dest> <log_file> — 録画から応答を再生
# dest に response の生バイトを書き（jq -j で末尾改行を追加しない）、
# 最小 debug log を合成（コスト経路 + 429 検出経路を実駆動）。
# rc = 録画の exit_code（分類前の生コード — classify が 21 等を再導出する）
# ---------------------------------------------------------------------------
sim_emit_replay() {
  local _se_rec="$1" _se_dest="$2" _se_log="$3"
  local _se_rc _se_in _se_out _se_rl

  _se_rc=$(jq -r '.exit_code // 0' "$_se_rec" 2>/dev/null)
  case "$_se_rc" in ''|*[!0-9]*) _se_rc=1 ;; esac
  _se_in=$(jq -r '.input_tokens // 0' "$_se_rec" 2>/dev/null)
  _se_out=$(jq -r '.output_tokens // 0' "$_se_rec" 2>/dev/null)
  _se_rl=$(jq -r '.debug_rate_limit_marker // false' "$_se_rec" 2>/dev/null)

  # response_b64 が正（バイト厳密再生）。手書き fixture 等で b64 が無い場合のみ
  # response（生テキスト、Windows jq の CRLF 変換リスクあり）にフォールバック。
  local _se_b64
  _se_b64=$(jq -r '.response_b64 // ""' "$_se_rec" 2>/dev/null | tr -d '\r\n')
  if [ -n "$_se_b64" ]; then
    printf '%s' "$_se_b64" | base64 -d > "$_se_dest" 2>/dev/null
  else
    jq -j '.response // ""' "$_se_rec" > "$_se_dest" 2>/dev/null
  fi

  mkdir -p "$(dirname "$_se_log")" 2>/dev/null
  {
    # 注意: 1行目に 429 検出正規表現（429|too many requests|rate.limit|…）に
    # 一致する語を含めないこと
    printf '[sim-replay] call_id=%s agent=%s seq=%s\n' \
      "$(jq -r '.call_id // 0' "$_se_rec" 2>/dev/null)" "${_SIM_AGENT:-none}" "${_SIM_SEQ:-0}"
    printf '{"usage": {"input_tokens": %d, "output_tokens": %d}}\n' "${_se_in:-0}" "${_se_out:-0}"
    [ "$_se_rl" = "true" ] && printf '%s\n' "$SIM_DEBUG_RATE_LIMIT_MARKER"
  } > "$_se_log" 2>/dev/null

  return "$_se_rc"
}

# ---------------------------------------------------------------------------
# sim_apply_fault <type> <dest> <log_file> — 故障の実体化
# 各故障は「実検出経路」を通る形で注入する（表は plan/ops doc 参照）
# ---------------------------------------------------------------------------
sim_apply_fault() {
  local _sa_type="$1" _sa_dest="$2" _sa_log="$3"
  local _sa_payload="${_SIM_FAULT_PAYLOAD:-}"
  mkdir -p "$(dirname "$_sa_log")" 2>/dev/null

  case "$_sa_type" in
    timeout)
      : > "$_sa_dest"
      return 124
      ;;
    budget_exceeded)
      printf '%s\n' "${_sa_payload:-$SIM_PAYLOAD_BUDGET}" > "$_sa_dest"
      return 1
      ;;
    rate_limit)
      printf '%s\n' "${_sa_payload:-$SIM_PAYLOAD_RATE_LIMIT}" > "$_sa_dest"
      printf '%s\n' "$SIM_DEBUG_RATE_LIMIT_MARKER" >> "$_sa_log"
      return 1
      ;;
    malformed_json)
      printf '%s\n' "${_sa_payload:-$SIM_PAYLOAD_MALFORMED}" > "$_sa_dest"
      printf '{"usage": {"input_tokens": 100, "output_tokens": 50}}\n' >> "$_sa_log"
      return 0
      ;;
    empty_output)
      : > "$_sa_dest"
      return 0
      ;;
    exit_1)
      printf '%s\n' "${_sa_payload:-$SIM_PAYLOAD_EXIT1}" > "$_sa_dest"
      return 1
      ;;
    quota_exhausted)
      printf '%s\n' "${_sa_payload:-$SIM_PAYLOAD_QUOTA}" > "$_sa_dest"
      printf '%s\n' "${_sa_payload:-$SIM_PAYLOAD_QUOTA}" >> "$_sa_log"
      return 1
      ;;
    *)
      # sim_init のプラン検証で弾かれるため通常到達しない
      log "  ✗ [sim] 未知の fault type: $_sa_type"
      : > "$_sa_dest"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# sim_claude_exec <dest> <log_file> <timeout> <prompt> <cmd...> — Hook B
# サブシェル内で呼ばれ得る: 変数変異禁止、ファイル効果と rc のみ。
# real 経路は common.sh 旧パイプライン（:498-499 / :513-514）の逐語移植。
# ---------------------------------------------------------------------------
sim_claude_exec() {
  local _se_dest="$1" _se_log="$2" _se_timeout="$3" _se_prompt="$4"
  shift 4

  local _se_rc=0
  case "${_SIM_DECISION:-}" in
    fault)
      sim_apply_fault "$_SIM_FAULT_TYPE" "$_se_dest" "$_se_log" || _se_rc=$?
      if [ -n "${RC_RECORD_DIR:-}" ]; then
        sim_write_record "$_se_dest" "$_se_log" "$_se_rc" 0 "fault:${_SIM_FAULT_TYPE}" "$_se_prompt"
      fi
      return "$_se_rc"
      ;;
    replay)
      sim_emit_replay "$_SIM_REPLAY_FILE" "$_se_dest" "$_se_log" || _se_rc=$?
      if [ -n "${RC_RECORD_DIR:-}" ]; then
        sim_write_record "$_se_dest" "$_se_log" "$_se_rc" 0 "replay" "$_se_prompt"
      fi
      return "$_se_rc"
      ;;
    replay-miss)
      : > "$_se_dest"
      return "$SIM_EXIT_REPLAY_MISS"
      ;;
  esac

  # real: 旧パイプラインの逐語移植（挙動差ゼロが契約）
  local _se_t0=$SECONDS
  echo "$_se_prompt" | env -u CLAUDECODE timeout "$_se_timeout" "$@" \
    > "$_se_dest" 2>/dev/null || _se_rc=$?
  if [ -n "${RC_RECORD_DIR:-}" ] && [ -n "${_SIM_DECISION:-}" ]; then
    sim_write_record "$_se_dest" "$_se_log" "$_se_rc" $((SECONDS - _se_t0)) "real" "$_se_prompt"
  fi
  return "$_se_rc"
}
