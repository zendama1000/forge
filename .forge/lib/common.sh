#!/bin/bash
# common.sh — Forge Harness 共有ユーティリティ関数
# 使い方: source "${PROJECT_ROOT}/.forge/lib/common.sh"
#
# 前提変数（呼び出し元で定義すること）:
#   PROJECT_ROOT    — プロジェクトルートの絶対パス
#   ERRORS_FILE     — errors.jsonl のパス（record_error, validate_json が使用）
#   json_fail_count — JSON検証失敗カウンタ（validate_json が読み書き。0で初期化すること）
#   RESEARCH_DIR    — エラー記録のコンテキスト識別子（未定義時は "unknown" にフォールバック）
#
# 注意: Opus モデルは応答が遅い場合がある（Task Planner で ~9 分以上の事例あり）。
# Claude CLI -p モードは処理完了後に初めて stdout 出力するため、timeout で kill されると
# .pending ファイルが空→削除される。Opus 使用時は development.json の timeout_sec を
# 1800 以上に設定することを推奨。

# ===== カラー定数 =====
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ===== トレースID =====
# FORGE_CALL_ID: run_claude() 呼出ごとにインクリメントされるシーケンス番号
# FORGE_SESSION_ID: forge-flow.sh 起動時に生成される UUID v4 セッション識別子
: "${FORGE_CALL_ID:=0}"

# ===== コストトラッキング用グローバル変数 =====
# run_claude() が extract_cost_from_debug_log() 経由で更新し、
# metrics_record() が参照後にリセットする。
# フォールバック値は 0（ログ解析失敗時）
: "${_LAST_INPUT_TOKENS:=0}"
: "${_LAST_OUTPUT_TOKENS:=0}"
: "${_LAST_COST_USD:=0}"

# ===== ログ出力 =====
# 常にstderrへ出力。stdoutをverdict返却に使う関数と干渉させない。
# LOG_PREFIX が定義されていればタイムスタンプ直後に挿入する。
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')]${LOG_PREFIX:+ $LOG_PREFIX} $1" >&2
}

# ===== タイムスタンプ生成 =====
# ログファイル名用。呼び出し毎に更新。
now_ts() {
  date +%Y%m%d-%H%M%S
}

# ===== セッションID生成 =====
# UUID v4形式 (8-4-4-4-12 hex) を生成。forge-flow.sh 起動時に呼び出す。
# 優先度: python3 → uuidgen → /dev/urandom フォールバック
generate_session_id() {
  if command -v python3 &>/dev/null; then
    local _uuid
    _uuid=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
    if [ -n "$_uuid" ]; then echo "$_uuid"; return; fi
  fi
  if command -v uuidgen &>/dev/null; then
    local _uuid
    _uuid=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -n "$_uuid" ]; then echo "$_uuid"; return; fi
  fi
  # フォールバック: /dev/urandom から 128bit を取得し UUID v4 形式にフォーマット
  local h
  h=$(od -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n\r' | head -c 32)
  local v16
  v16=$(printf '%x' $(( ( 16#${h:16:1} & 3 ) | 8 )))
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "${v16}" "${h:17:3}" "${h:20:12}"
}

# ===== テンプレートレンダリング =====
# {{KEY}} プレースホルダーを値で置換する。
# 使い方: render_template <template_file> <KEY1> <VALUE1> [<KEY2> <VALUE2> ...]
# bash parameter expansion を使用（値に / や & や改行が含まれても安全）
render_template() {
  local template_file="$1"
  shift
  local content
  content=$(cat "$template_file")
  while [ $# -ge 2 ]; do
    local key="$1"
    local value="$2"
    shift 2
    content="${content//\{\{${key}\}\}/$value}"
  done
  printf '%s\n' "$content"
}

# ===== CRLF-safe jq ラッパー =====
# Windows (Git Bash) 環境で jq -r の出力に付加される \r を除去する。
# 使い方: jq_safe <jq_args...>  — jq の全引数をそのまま渡す
# 例: count=$(jq_safe -r '.count' file.json)
#     jq_safe -r '.phases[].id' file.json | while read -r pid; do ...
jq_safe() {
  jq "$@" | tr -d '\r'
}

# ===== Claude CLI ラッパー =====
# 使い方: run_claude <model> <agent_file> <prompt> <output_file> <log_file> [disallowed_tools] [timeout] [work_dir] [json_schema_file]
# agent_file: .claude/agents/*.md のパス。空文字の場合は --system-prompt を省略する。
# work_dir: Claude CLI を実行するカレントディレクトリ。省略時は現在のディレクトリ（通常 PROJECT_ROOT）。
#           WORK_DIR が PROJECT_ROOT と異なる場合（外部プロジェクト作業時）に必ず指定すること。
# json_schema_file: JSON Schema ファイルのパス（.forge/schemas/*.schema.json）。
#                   指定時は --output-format json --json-schema を付与し、
#                   Constrained Decoding で構文的に正しい JSON 出力を保証する。
#                   .pending には structured_output のみを書き出す。
# プロンプトはパイプでstdinから渡す（ARG_MAX制限を回避）
run_claude() {
  local model="$1"
  local agent_file="$2"
  local prompt="$3"
  local output_file="$4"
  local log_file="$5"
  local disallowed_tools="${6:-}"
  local stage_timeout="${7:-${CLAUDE_TIMEOUT:-600}}"
  local work_dir="${8:-}"
  local json_schema_file="${9:-}"

  # FORGE_CALL_ID をインクリメント（run_claude 呼出ごとのクロスステージ追跡用シーケンス番号）
  FORGE_CALL_ID=$(( ${FORGE_CALL_ID:-0} + 1 ))
  export FORGE_CALL_ID

  # work_dir 指定時: output_file / log_file が相対パスなら絶対パスへ変換
  # （呼び出し元は PROJECT_ROOT 基準で相対パスを指定するため、cd 後に迷子になる）
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    case "$output_file" in /*) ;; *) output_file="$(pwd)/${output_file}" ;; esac
    case "$log_file" in /*) ;; *) log_file="$(pwd)/${log_file}" ;; esac
    mkdir -p "$(dirname "$output_file")" "$(dirname "$log_file")"
  fi

  # json_schema_file が相対パスなら絶対パスに変換（cd 前に解決）
  if [ -n "$json_schema_file" ]; then
    case "$json_schema_file" in /*) ;; *) json_schema_file="$(pwd)/${json_schema_file}" ;; esac
  fi

  local cmd=(claude --model "$model" -p --dangerously-skip-permissions --no-session-persistence --debug-file "$log_file")
  if [ -n "$agent_file" ] && [ -f "$agent_file" ]; then
    cmd+=(--system-prompt "$(cat "$agent_file")")
  fi
  if [ -n "$disallowed_tools" ]; then
    cmd+=(--disallowed-tools "$disallowed_tools")
  fi

  # JSON Schema 指定時: Constrained Decoding で構文的に正しい JSON を保証
  local _rc_use_schema=false
  if [ -n "$json_schema_file" ] && [ -f "$json_schema_file" ]; then
    cmd+=(--output-format json --json-schema "$(cat "$json_schema_file")")
    _rc_use_schema=true
  fi

  # パイプでstdinからプロンプトを渡す（ARG_MAX制限を回避）
  # CLAUDECODE を unset してネストセッション検出を回避（親セッション内からの呼び出し対応）
  # Safe overwrite: .pending に書き出し、validate_json 成功後に本ファイルへ昇格
  # work_dir 指定時はサブシェルで cd してから実行（Claude CLI には --cwd オプションがないため）
  local _rc_raw_output="${output_file}.raw-envelope"
  local _rc_target="${output_file}.pending"
  # スキーマモード時は一旦 raw-envelope に書き出し、後で structured_output を抽出
  local _rc_dest="$_rc_target"
  $_rc_use_schema && _rc_dest="$_rc_raw_output"

  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    (
      cd "$work_dir" || return 1
      echo "$prompt" | env -u CLAUDECODE timeout "$stage_timeout" "${cmd[@]}" \
        > "$_rc_dest" 2>/dev/null
    ) || {
      local exit_code=$?
      if [ "$exit_code" -eq 124 ]; then
        log "  タイムアウト（${stage_timeout}秒）"
      fi
      rm -f "$_rc_dest" "$_rc_raw_output"
      return "$exit_code"
    }
  else
    echo "$prompt" | env -u CLAUDECODE timeout "$stage_timeout" "${cmd[@]}" \
      > "$_rc_dest" 2>/dev/null || {
      local exit_code=$?
      if [ "$exit_code" -eq 124 ]; then
        log "  タイムアウト（${stage_timeout}秒）"
      fi
      rm -f "$_rc_dest" "$_rc_raw_output"
      return "$exit_code"
    }
  fi

  # スキーマモード: エンベロープから structured_output を抽出
  if $_rc_use_schema; then
    local _rc_subtype
    _rc_subtype=$(jq -r '.subtype // "unknown"' "$_rc_raw_output" 2>/dev/null)
    if [ "$_rc_subtype" = "success" ]; then
      # structured_output を .pending に書き出す
      # 注意: structured_output が null の場合は jq が "null" を出力し有効JSONとして通過してしまう
      # → jq 'if . == null then error("null") ...' で null を明示的に弾く
      jq 'if .structured_output == null then error("structured_output is null") else .structured_output end' \
        "$_rc_raw_output" > "$_rc_target" 2>/dev/null
      if [ $? -ne 0 ] || [ ! -s "$_rc_target" ] || ! jq empty "$_rc_target" 2>/dev/null; then
        # structured_output 抽出失敗 or null → フォールバック: result フィールドを .pending に書き出す
        log "  ⚠ structured_output 抽出失敗、result フォールバック"
        jq -r '.result // empty' "$_rc_raw_output" > "$_rc_target" 2>/dev/null
      fi
    else
      # スキーマ検証失敗（error_max_structured_output_retries 等）→ result をフォールバック
      log "  ⚠ スキーマ検証失敗 (subtype=${_rc_subtype})、result フォールバック"
      jq -r '.result // empty' "$_rc_raw_output" > "$_rc_target" 2>/dev/null
    fi
    rm -f "$_rc_raw_output"
  fi

  # スキーマモードフラグを公開（validate_json → record_validation_stat に伝達）
  FORGE_SCHEMA_MODE="$_rc_use_schema"
  export FORGE_SCHEMA_MODE

  # コスト記録（ベストエフォート）
  # グローバルをリセット（抽出失敗時のフォールバック 0 保証）
  _LAST_INPUT_TOKENS=0
  _LAST_OUTPUT_TOKENS=0
  _LAST_COST_USD="0"
  local _stage_name
  _stage_name=$(basename "${output_file%.pending}" | sed 's/\.[^.]*$//')
  extract_cost_from_debug_log "$log_file" "$_stage_name" "$model" 2>/dev/null || true
}

# ===== コスト追跡 =====
COSTS_FILE="${PROJECT_ROOT:-.}/.forge/state/costs.jsonl"

# run_claude の debug ログからコスト情報を抽出
# 使い方: extract_cost_from_debug_log <log_file> <stage> <model>
extract_cost_from_debug_log() {
  local log_file="$1"
  local stage="$2"
  local model="$3"

  [ -f "$log_file" ] || return 0
  [ -s "$log_file" ] || return 0

  # debug ログから usage 情報を抽出（コロン後の空白を許容）
  local input_tokens output_tokens
  input_tokens=$(grep -oE '"input_tokens":[[:space:]]*[0-9]+' "$log_file" | tail -1 | grep -oE '[0-9]+' | tail -1 || echo 0)
  output_tokens=$(grep -oE '"output_tokens":[[:space:]]*[0-9]+' "$log_file" | tail -1 | grep -oE '[0-9]+' | tail -1 || echo 0)

  # トークン数が取得できなければスキップ
  if [ "$input_tokens" -eq 0 ] && [ "$output_tokens" -eq 0 ]; then
    return 0
  fi

  # コスト推定（per million tokens）
  local cost_usd="0"
  case "$model" in
    *haiku*)  cost_usd=$(awk "BEGIN { printf \"%.4f\", ($input_tokens * 0.25 + $output_tokens * 1.25) / 1000000 }") ;;
    *sonnet*) cost_usd=$(awk "BEGIN { printf \"%.4f\", ($input_tokens * 3.0 + $output_tokens * 15.0) / 1000000 }") ;;
    *opus*)   cost_usd=$(awk "BEGIN { printf \"%.4f\", ($input_tokens * 15.0 + $output_tokens * 75.0) / 1000000 }") ;;
    *)        cost_usd=$(awk "BEGIN { printf \"%.4f\", ($input_tokens * 3.0 + $output_tokens * 15.0) / 1000000 }") ;;
  esac

  # グローバル変数を更新（metrics_record() が参照してメトリクスに記録する）
  _LAST_INPUT_TOKENS=$input_tokens
  _LAST_OUTPUT_TOKENS=$output_tokens
  _LAST_COST_USD="$cost_usd"

  # costs.jsonl に追記
  local entry
  entry=$(printf '{"stage":"%s","model":"%s","input_tokens":%d,"output_tokens":%d,"cost_usd":%s,"timestamp":"%s"}' \
    "$stage" "$model" "$input_tokens" "$output_tokens" "$cost_usd" "$(date -Iseconds)")
  echo "$entry" >> "$COSTS_FILE"
}

# ===== セッションコスト集計 =====
# session_id 別の cost_usd 合計を集計し返す。
# 使い方: aggregate_session_cost [session_id] [metrics_file]
# 出力: {"session_id": "xxx", "total_cost_usd": N.NN} 形式の JSON
aggregate_session_cost() {
  local session_id="${1:-${FORGE_SESSION_ID:-no-session}}"
  local metrics_file="${2:-${METRICS_FILE}}"

  if [ ! -f "$metrics_file" ] || [ ! -s "$metrics_file" ]; then
    jq -n --arg sid "$session_id" '{session_id: $sid, total_cost_usd: 0}'
    return 0
  fi

  tr -d '\r' < "$metrics_file" | jq -s --arg sid "$session_id" '
    map(select(.session_id == $sid)) |
    {
      session_id: $sid,
      total_cost_usd: (map(.cost_usd // 0) | add // 0)
    }
  '
}

# ===== Write ツール直接書き込みフォールバック =====
# Claude が stdout ではなく Write ツールで直接ファイルに書き込んだ場合の救済。
# run_claude は stdout を .pending にキャプチャするが、Write ツール経由の場合
# stdout にはマークダウンサマリーのみが出力され、validate_json が正しく拒否する。
# しかし実際の JSON は既に final_path に存在しているケースがある。
# 使い方: check_direct_write_fallback <final_path> <stage>
# 戻り値: 0=直接書き込み検出（利用可能）, 1=検出されず
check_direct_write_fallback() {
  local final_path="$1" stage="$2"
  if [ -f "$final_path" ] && [ -s "$final_path" ] && jq empty "$final_path" 2>/dev/null; then
    rm -f "${final_path}.failed" "${final_path}.pending" 2>/dev/null || true
    log "⚠ [fallback] ${stage}: stdout は非JSON だが ${final_path} への直接書き込みを検出"
    return 0
  fi
  return 1
}

# ===== JSON妥当性チェック =====
# Claude出力の自動正規化付き。3層リカバリ:
#   1. CRLF除去
#   2. コードフェンス除去
#   3. 前後の非JSONテキスト除去（最初の { から最後の } まで抽出）
validate_json() {
  local final_path="$1"
  local stage="$2"

  # Safe overwrite: run_claude が .pending に書き出した場合、そちらを検証する。
  # 成功時のみ本ファイルに昇格し、失敗時は既存ファイルを保全する。
  local file="$final_path"
  local _vj_pending=false
  if [ -f "${final_path}.pending" ]; then
    file="${final_path}.pending"
    _vj_pending=true
  fi

  # 成功時: .pending → 本ファイルに昇格
  _vj_promote() { $_vj_pending && mv "$file" "$final_path"; }
  # 失敗時: .pending を削除、既存ファイルはそのまま
  _vj_cleanup() { $_vj_pending && mv "$file" "${final_path}.failed" 2>/dev/null || true; }

  if [ ! -s "$file" ]; then
    record_error "$stage" "出力が空"
    record_validation_stat "$stage" "failed"
    log "✗ ${stage} 出力が空"
    json_fail_count=$((json_fail_count + 1))
    _vj_cleanup
    return 1
  fi

  # CRLF→LF正規化（Windows/Git Bash環境対応）
  tr -d '\r' < "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"

  # 既にJSONとして有効ならそのまま返す（CRLFのみで修復 or 元から正常）
  if jq empty "$file" 2>/dev/null; then
    record_validation_stat "$stage" "crlf"
    _vj_promote
    return 0
  fi

  # コードフェンス行を除去（```json / ```）
  if grep -qm1 '^```' "$file"; then
    grep -v '^```' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    log "  (コードフェンス除去: ${stage})"
  fi

  if jq empty "$file" 2>/dev/null; then
    resolve_errors "$stage" "recovered:fence_removal"
    record_validation_stat "$stage" "fence"
    notify_human "info" "JSON自動修復: ${stage} (コードフェンス除去)" ""
    _vj_promote
    return 0
  fi

  # Layer 3a: 行頭ブレース検出（精密 — 説明文中の { を誤検出しない）
  local first_brace last_brace
  first_brace=$(grep -n '^[[:space:]]*{' "$file" | head -1 | cut -d: -f1)
  last_brace=$(grep -n '^[[:space:]]*}' "$file" | tail -1 | cut -d: -f1)
  if [ -n "$first_brace" ] && [ -n "$last_brace" ] && [ "$first_brace" -le "$last_brace" ]; then
    sed -n "${first_brace},${last_brace}p" "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    log "  (JSON抽出: ${stage} — 行${first_brace}〜${last_brace})"
  fi

  if ! jq empty "$file" 2>/dev/null; then
    # Layer 3b: 任意位置ブレース検出（従来フォールバック）
    first_brace=$(grep -n '{' "$file" | head -1 | cut -d: -f1)
    last_brace=$(grep -n '}' "$file" | tail -1 | cut -d: -f1)
    if [ -n "$first_brace" ] && [ -n "$last_brace" ] && [ "$first_brace" -le "$last_brace" ]; then
      sed -n "${first_brace},${last_brace}p" "$file" > "${file}.tmp"
      mv "${file}.tmp" "$file"
      log "  (JSON抽出フォールバック: ${stage} — 行${first_brace}〜${last_brace})"
    fi
  fi

  if ! jq empty "$file" 2>/dev/null; then
    record_error "$stage" "出力が不正なJSON"
    record_validation_stat "$stage" "failed"
    log "✗ ${stage} 出力が不正なJSON"
    json_fail_count=$((json_fail_count + 1))
    _vj_cleanup
    return 1
  fi

  resolve_errors "$stage" "recovered:json_extraction"
  record_validation_stat "$stage" "extraction"
  notify_human "info" "JSON自動修復: ${stage} (JSON抽出)" ""
  _vj_promote
  return 0
}

# ===== エラー解決記録（B1: resolution 更新） =====
# 同一 stage + research_dir の未解決エラーに resolution を書き込む
resolve_errors() {
  local stage="$1"
  local resolution="$2"
  [ -f "$ERRORS_FILE" ] || return 0
  [ -s "$ERRORS_FILE" ] || return 0
  local research_dir="${RESEARCH_DIR:-unknown}"
  # jq で同一 stage/research_dir かつ resolution==null のエントリを更新
  local tmpfile="${ERRORS_FILE}.resolve.tmp"
  while IFS= read -r line; do
    local line_stage line_dir line_res
    line_stage=$(echo "$line" | jq_safe -r '.stage // ""' 2>/dev/null)
    line_dir=$(echo "$line" | jq_safe -r '.research_dir // ""' 2>/dev/null)
    line_res=$(echo "$line" | jq_safe -r '.resolution // "null"' 2>/dev/null)
    if [ "$line_stage" = "$stage" ] && [ "$line_dir" = "$research_dir" ] && [ "$line_res" = "null" ]; then
      echo "$line" | jq -c --arg r "$resolution" --arg ts "$(date -Iseconds)" \
        '.resolution = $r | .resolved_at = $ts'
    else
      echo "$line"
    fi
  done < "$ERRORS_FILE" > "$tmpfile"
  mv "$tmpfile" "$ERRORS_FILE"
}

# ===== エラーカテゴリ分類 =====
# 終了コード・メッセージパターンに基づき error_category を決定する（決定的ルール）
# 使い方: classify_error_category <message> [exit_code]
# 返値: timeout | rate_limit | invalid_json | empty_output | unknown
classify_error_category() {
  local message="${1:-}"
  local exit_code="${2:-}"

  # 1. timeout — 終了コード 124(timeoutコマンド) もタイムアウトを示す
  if [ -n "$exit_code" ] && [ "$exit_code" = "124" ]; then
    echo "timeout"; return
  fi
  if echo "$message" | grep -qi "timeout\|timed out"; then
    echo "timeout"; return
  fi

  # 2. rate_limit — 429 / Too Many Requests / rate_limit / overloaded
  if echo "$message" | grep -qi "429\|too many requests\|rate.limit\|overloaded"; then
    echo "rate_limit"; return
  fi

  # 3. invalid_json — 不正なJSON / invalid json
  if echo "$message" | grep -qi "不正なjson\|invalid.json"; then
    echo "invalid_json"; return
  fi

  # 4. empty_output — が空 / empty
  if echo "$message" | grep -qi "が空\|empty"; then
    echo "empty_output"; return
  fi

  # 5. unknown（フォールバック）
  echo "unknown"
}

# ===== エラー記録 =====
# jqで安全にJSON生成。CRLF除去付き。
# 使い方: record_error <stage> <message> [exit_code]
#   exit_code: 省略可。124(timeout)等の終了コードがあれば分類精度が向上する。
record_error() {
  local stage="${1//$'\r'/}"
  local message="${2//$'\r'/}"
  local exit_code="${3:-}"
  local error_category
  error_category=$(classify_error_category "$message" "$exit_code")
  jq -n -c \
    --arg stage "$stage" \
    --arg message "$message" \
    --arg research_dir "${RESEARCH_DIR:-unknown}" \
    --arg timestamp "$(date -Iseconds)" \
    --arg error_category "$error_category" \
    --arg session_id "${FORGE_SESSION_ID:-no-session}" \
    --arg call_id "${FORGE_CALL_ID:-0}" \
    '{stage: $stage, message: $message, research_dir: $research_dir, timestamp: $timestamp, resolution: null, error_category: $error_category, session_id: $session_id, call_id: $call_id}' \
    | tr -d '\r' >> "$ERRORS_FILE"
}

# ===== バリデーション統計記録（G2: validation-stats.jsonl） =====
VALIDATION_STATS_FILE="${PROJECT_ROOT:-.}/.forge/state/validation-stats.jsonl"

# リカバリ段階を記録: none(元から正常)/crlf/fence/extraction/failed
# was_schema_mode: run_claude() が --json-schema を使用したか（FORGE_SCHEMA_MODE グローバル変数から取得）
record_validation_stat() {
  local stage="$1"
  local recovery_level="$2"
  local _vsm_bool
  [ "${FORGE_SCHEMA_MODE:-false}" = "true" ] && _vsm_bool="true" || _vsm_bool="false"
  jq -n -c \
    --arg stage "$stage" \
    --arg recovery_level "$recovery_level" \
    --argjson was_schema_mode "$_vsm_bool" \
    --arg research_dir "${RESEARCH_DIR:-unknown}" \
    --arg timestamp "$(date -Iseconds)" \
    --arg session_id "${FORGE_SESSION_ID:-no-session}" \
    --arg call_id "${FORGE_CALL_ID:-0}" \
    '{stage: $stage, recovery_level: $recovery_level, was_schema_mode: $was_schema_mode, research_dir: $research_dir, timestamp: $timestamp, session_id: $session_id, call_id: $call_id}' \
    >> "$VALIDATION_STATS_FILE"
}

# ===== バリデーション統計集計（G2: aggregate_validation_stats） =====
# ステージ別のリカバリレベル集計（failed率を含む）
# 使い方: aggregate_validation_stats [stats_file]
# 出力: [{stage, total, failed, failed_rate}] 形式の JSON 配列
# 空データの場合は [] を返す
aggregate_validation_stats() {
  local stats_file="${1:-${VALIDATION_STATS_FILE}}"

  if [ ! -f "$stats_file" ] || [ ! -s "$stats_file" ]; then
    echo "[]"
    return 0
  fi

  tr -d '\r' < "$stats_file" | jq -s '
    if length == 0 then []
    else
      group_by(.stage) |
      map(
        . as $entries |
        ($entries | length) as $total |
        ($entries | map(select(.recovery_level == "failed")) | length) as $failed |
        {
          stage: $entries[0].stage,
          total: $total,
          failed: $failed,
          failed_rate: (if $total == 0 then 0 else ($failed / $total) end)
        }
      )
    end
  '
}

# ===== Lessons Learned（AnimaWorks Consolidation 概念の適用） =====
# 失敗パターンと解決策を蓄積し、次のタスクの Implementer プロンプトに注入する。
LESSONS_FILE="${PROJECT_ROOT:-.}/.forge/state/lessons-learned.jsonl"

# record_lesson <category> <pattern> <resolution> [source_task_id]
# category: test_framework | path_issue | timeout | hallucination | file_limit | env_mismatch | dependency | other
record_lesson() {
  local category="${1:-other}"
  local pattern="${2:-}"
  local resolution="${3:-}"
  local source_task="${4:-}"

  [ -z "$pattern" ] && return 0

  # 重複チェック: 同じ pattern が既に存在するならスキップ
  if [ -f "$LESSONS_FILE" ] && grep -qF "\"pattern\":\"${pattern}\"" "$LESSONS_FILE" 2>/dev/null; then
    return 0
  fi

  jq -n -c \
    --arg cat "$category" \
    --arg pat "$pattern" \
    --arg res "$resolution" \
    --arg src "$source_task" \
    --arg ts "$(date -Iseconds)" \
    '{category: $cat, pattern: $pat, resolution: $res, source_task: $src, created_at: $ts}' \
    | tr -d '\r' >> "$LESSONS_FILE"
}

# get_relevant_lessons <task_json>
# タスクの L1 command と description からキーワードマッチで関連レッスンを抽出。
# 結果を stdout に出力（最大10件）。レッスンがなければ空文字。
get_relevant_lessons() {
  local task_json="$1"
  [ -f "$LESSONS_FILE" ] || return 0
  [ -s "$LESSONS_FILE" ] || return 0

  local command=""
  command=$(echo "$task_json" | jq -r '.validation.layer_1.command // ""' 2>/dev/null | tr -d '\r')

  local results=""

  # カテゴリベースのフィルタ（L1 command からキーワード検出）
  if echo "$command" | grep -qiE 'vitest|jest|mocha|test'; then
    local fw_lessons=""
    fw_lessons=$(grep '"category":"test_framework"' "$LESSONS_FILE" 2>/dev/null | tail -3)
    [ -n "$fw_lessons" ] && results="${results}${fw_lessons}"$'\n'
  fi

  if echo "$command" | grep -qiE 'path|windows|tmp'; then
    local path_lessons=""
    path_lessons=$(grep '"category":"path_issue"' "$LESSONS_FILE" 2>/dev/null | tail -3)
    [ -n "$path_lessons" ] && results="${results}${path_lessons}"$'\n'
  fi

  # 直近のレッスンを最大5件追加（カテゴリ不問）
  local recent=""
  recent=$(tail -5 "$LESSONS_FILE" 2>/dev/null)
  [ -n "$recent" ] && results="${results}${recent}"$'\n'

  # 重複排除して最大10件に制限、人間可読フォーマットに変換
  echo "$results" | sort -u | head -10 | while IFS= read -r line; do
    [ -z "$line" ] && continue
    local pat="" res=""
    pat=$(echo "$line" | jq -r '.pattern // ""' 2>/dev/null | tr -d '\r')
    res=$(echo "$line" | jq -r '.resolution // ""' 2>/dev/null | tr -d '\r')
    [ -z "$pat" ] && continue
    echo "- ${pat} → ${res}"
  done
}

# ===== タスクイベントソーシング（AnimaWorks event sourcing 概念の適用） =====
# task-stack.json（canonical state）はそのまま維持し、追記専用のイベントログを併設する（write-through）。
TASK_EVENTS_FILE="${PROJECT_ROOT:-.}/.forge/state/task-events.jsonl"

# record_task_event <task_id> <event_type> [detail_json]
# event_type: status_changed | fail_recorded | investigator_invoked |
#             lesson_recorded | checkpoint_created | checkpoint_restored |
#             task_passed | task_started | heartbeat
record_task_event() {
  local task_id="$1"
  local event_type="$2"
  local _empty_obj='{}'
  local detail="${3:-$_empty_obj}"

  jq -n -c \
    --arg tid "$task_id" \
    --arg evt "$event_type" \
    --argjson det "$detail" \
    --arg ts "$(date -Iseconds)" \
    --arg ses "${RESEARCH_DIR:-unknown}" \
    --arg session_id "${FORGE_SESSION_ID:-no-session}" \
    '{task_id: $tid, event: $evt, detail: $det, timestamp: $ts, session: $ses, session_id: $session_id}' \
    | tr -d '\r' >> "$TASK_EVENTS_FILE" 2>/dev/null || true
}

# ===== メトリクス記録（G1: metrics.jsonl） =====
METRICS_FILE="${PROJECT_ROOT:-.}/.forge/state/metrics.jsonl"

# ステージ開始時刻を記録（エポック秒）
metrics_start() {
  _METRICS_START_EPOCH=$(date +%s)
}

# ステージ終了後にメトリクスを追記
# 使い方: metrics_record <stage> <parse_success:true|false> [extra_field_json]
# token/cost フィールドは run_claude() → extract_cost_from_debug_log() が設定した
# グローバル変数 _LAST_INPUT_TOKENS / _LAST_OUTPUT_TOKENS / _LAST_COST_USD から取得する。
# 抽出失敗時は各フィールドが 0 のフォールバック値となる。
metrics_record() {
  local stage="$1"
  local parse_success="${2:-true}"
  local extra="${3:-}"
  local end_epoch
  end_epoch=$(date +%s)
  local duration=$(( end_epoch - ${_METRICS_START_EPOCH:-$end_epoch} ))

  # token/cost 情報（run_claude() → extract_cost_from_debug_log() 経由のグローバル変数から取得）
  local _m_input_tokens="${_LAST_INPUT_TOKENS:-0}"
  local _m_output_tokens="${_LAST_OUTPUT_TOKENS:-0}"
  local _m_cost_usd="${_LAST_COST_USD:-0}"
  # 読み取り後にリセット（次の呼出がゼロフォールバックを持つよう保証）
  _LAST_INPUT_TOKENS=0
  _LAST_OUTPUT_TOKENS=0
  _LAST_COST_USD="0"

  local entry
  entry=$(jq -n -c \
    --arg stage "$stage" \
    --argjson duration "$duration" \
    --argjson parse_success "$parse_success" \
    --arg research_dir "${RESEARCH_DIR:-unknown}" \
    --arg timestamp "$(date -Iseconds)" \
    --arg session_id "${FORGE_SESSION_ID:-no-session}" \
    --arg call_id "${FORGE_CALL_ID:-0}" \
    --arg input_tokens "${_m_input_tokens}" \
    --arg output_tokens "${_m_output_tokens}" \
    --arg cost_usd "${_m_cost_usd}" \
    '{stage: $stage, duration_sec: $duration, parse_success: $parse_success, research_dir: $research_dir, timestamp: $timestamp, session_id: $session_id, call_id: $call_id, input_tokens: ($input_tokens | tonumber), output_tokens: ($output_tokens | tonumber), cost_usd: ($cost_usd | tonumber)}')
  if [ -n "$extra" ]; then
    entry=$(echo "$entry" | jq -c ". + $extra" 2>/dev/null || echo "$entry")
  fi
  echo "$entry" >> "$METRICS_FILE"
}

# ===== コマンド依存チェック =====
# 使い方: check_dependencies claude jq md5sum timeout
check_dependencies() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${RED}[ERROR] $cmd が見つかりません。インストールしてください。${NC}" >&2
      exit 1
    fi
  done
}

# ===== 人間通知 =====
NOTIFY_DIR="${PROJECT_ROOT:-.}/.forge/state/notifications"

notify_human() {
  local level="$1"
  local message="$2"
  local detail="${3:-}"

  mkdir -p "$NOTIFY_DIR"
  local notify_id="n-$(date +%Y%m%d-%H%M%S)"
  local notify_file="${NOTIFY_DIR}/${notify_id}.json"

  jq -n -c \
    --arg id "$notify_id" \
    --arg level "$level" \
    --arg message "$message" \
    --arg detail "$detail" \
    --arg timestamp "$(date -Iseconds)" \
    --arg acknowledged "false" \
    '{id: $id, level: $level, message: $message, detail: $detail, timestamp: $timestamp, acknowledged: $acknowledged}' \
    > "$notify_file"

  case "$level" in
    "critical")
      echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════╗${NC}" >&2
      echo -e "${RED}${BOLD}║ ⚠ CRITICAL: ${message}${NC}" >&2
      echo -e "${RED}${BOLD}╚══════════════════════════════════════════╝${NC}" >&2
      ;;
    "warning")
      echo -e "\n${YELLOW}${BOLD}⚠ WARNING: ${message}${NC}" >&2
      ;;
    "info")
      echo -e "${DIM}[INFO] ${message}${NC}" >&2
      ;;
  esac

  [ -n "$detail" ] && echo -e "  ${detail}" >&2

  # ベル音は critical/warning のみ
  [ "$level" != "info" ] && echo -ne '\a' >&2

  log "通知記録: ${notify_file}"
}

# ===== 対象プロジェクト Git 安全チェック =====
# 作業ディレクトリの git 状態を検証し、未コミット変更による損失を防止する。
# 使い方: safe_work_dir_check <work_dir>
# 戻り値: 0=OK, 1=ERROR（実行を停止すべき）
safe_work_dir_check() {
  local work_dir="$1"

  # 1. git リポジトリであることを確認
  if ! git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    log "✗ [SAFETY] ${work_dir} は git リポジトリではありません"
    notify_human "critical" "作業ディレクトリが git リポジトリではない" \
      "パス: ${work_dir}\ngit init するか、正しいディレクトリを指定してください"
    return 1
  fi

  # 2. 未ステージ変更チェック（Modified/Deleted）
  local staged_changes
  staged_changes=$(git -C "$work_dir" status --porcelain 2>/dev/null | grep -E '^[ MADRCU][MD]' || true)
  if [ -n "$staged_changes" ]; then
    local change_count
    change_count=$(echo "$staged_changes" | wc -l | tr -d ' ')
    log "✗ [SAFETY] 未コミットの変更が ${change_count} 件あります"
    notify_human "critical" "未コミット変更を検出 — 先に git commit/stash してください" \
      "変更ファイル数: ${change_count}\nパス: ${work_dir}\n先頭5件:\n$(echo "$staged_changes" | head -5)"
    return 1
  fi

  # 3. 未追跡ファイルチェック
  local untracked
  untracked=$(git -C "$work_dir" status --porcelain 2>/dev/null | grep -E '^\?\?' || true)
  if [ -n "$untracked" ]; then
    local untracked_count
    untracked_count=$(echo "$untracked" | wc -l | tr -d ' ')
    if [ "$untracked_count" -gt 10 ]; then
      log "✗ [SAFETY] 未追跡ファイルが ${untracked_count} 件（上限: 10）"
      notify_human "critical" "大量の未追跡ファイルを検出" \
        "件数: ${untracked_count}\nパス: ${work_dir}\ngit add + commit するか、.gitignore に追加してください"
      return 1
    else
      log "⚠ [SAFETY] 未追跡ファイル ${untracked_count} 件（許容範囲）"
    fi
  fi

  # 4. ブランチ確認（main/master 上なら WARNING）
  local current_branch
  current_branch=$(git -C "$work_dir" branch --show-current 2>/dev/null || echo "")
  if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    log "⚠ [SAFETY] ${current_branch} ブランチ上で作業中（推奨: feature branch）"
    notify_human "warning" "${current_branch} ブランチで実行中" \
      "推奨: feature branch での作業を推奨します"
  fi

  log "✓ [SAFETY] 作業ディレクトリ安全チェック通過: ${work_dir}"
  return 0
}

# ===== タスク単位 Git Checkpoint =====
CHECKPOINT_DIR="${PROJECT_ROOT:-.}/.forge/state/checkpoints"

# タスク実行前のスナップショットを保存する（diff + untracked リスト）
# 使い方: task_checkpoint_create <work_dir> <task_id>
task_checkpoint_create() {
  local work_dir="$1"
  local task_id="$2"

  mkdir -p "$CHECKPOINT_DIR"

  # git リポジトリでなければスキップ
  if ! git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    log "  [CHECKPOINT] ${work_dir} は git リポジトリではない — スキップ"
    return 0
  fi

  # tracked ファイルの差分を保存
  local patch_file="${CHECKPOINT_DIR}/${task_id}.patch"
  git -C "$work_dir" diff HEAD > "$patch_file" 2>/dev/null || true

  # untracked ファイルのリストを保存
  local untracked_file="${CHECKPOINT_DIR}/${task_id}.untracked"
  git -C "$work_dir" ls-files --others --exclude-standard > "$untracked_file" 2>/dev/null || true

  # HEAD の commit hash を保存（復帰先の参照点）
  local ref_file="${CHECKPOINT_DIR}/${task_id}.ref"
  git -C "$work_dir" rev-parse HEAD > "$ref_file" 2>/dev/null || true

  log "  [CHECKPOINT] タスク ${task_id} のスナップショット作成完了"
  return 0
}

# タスク失敗・暴走時に対象プロジェクトをタスク前の状態に復帰する
# 使い方: task_checkpoint_restore <work_dir> <task_id>
task_checkpoint_restore() {
  local work_dir="$1"
  local task_id="$2"

  # git リポジトリでなければスキップ
  if ! git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    log "  [CHECKPOINT] ${work_dir} は git リポジトリではない — 復帰スキップ"
    return 1
  fi

  local untracked_file="${CHECKPOINT_DIR}/${task_id}.untracked"

  # 1. tracked ファイルを HEAD に復帰
  git -C "$work_dir" checkout -- . 2>/dev/null || true

  # 2. checkpoint 時に存在しなかった untracked ファイルを削除
  if [ -f "$untracked_file" ]; then
    local current_untracked
    current_untracked=$(git -C "$work_dir" ls-files --others --exclude-standard 2>/dev/null || true)
    while IFS= read -r file; do
      # checkpoint 時のリストに含まれていなければ新規作成されたファイル → 削除
      if [ -n "$file" ] && ! grep -qxF "$file" "$untracked_file" 2>/dev/null; then
        rm -f "${work_dir}/${file}" 2>/dev/null || true
      fi
    done <<< "$current_untracked"
  else
    # checkpoint の untracked リストがない場合、全 untracked を削除（安全側に倒す）
    git -C "$work_dir" clean -fd > /dev/null 2>&1 || true
  fi

  log "  [CHECKPOINT] タスク ${task_id} の状態を復帰しました"
  return 0
}

# ===== 変更ファイル数バリデーション =====
# Implementer 実行後に呼び出し、変更ファイル数がリミットを超えていないか検証する。
# ハードリミット超過時は自動ロールバック（S3 と連携）。
# 使い方: validate_task_changes <work_dir> <task_id> [soft_limit] [hard_limit]
# 戻り値: 0=OK, 1=ハードリミット超過（復帰済み）, 2=ソフトリミット超過（続行）
validate_task_changes() {
  local work_dir="$1"
  local task_id="$2"
  local soft_limit="${3:-5}"
  local hard_limit="${4:-10}"

  # git リポジトリでなければスキップ
  if ! git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    return 0
  fi

  # 変更ファイル数を集計
  local changed_files
  changed_files=$(git -C "$work_dir" diff --name-only HEAD 2>/dev/null || true)
  local new_files
  new_files=$(git -C "$work_dir" ls-files --others --exclude-standard 2>/dev/null || true)

  local changed_count=0 new_count=0
  [ -n "$changed_files" ] && changed_count=$(echo "$changed_files" | wc -l | tr -d ' ')
  [ -n "$new_files" ] && new_count=$(echo "$new_files" | wc -l | tr -d ' ')
  local total=$((changed_count + new_count))

  # 保護パターンチェック（S6: circuit-breaker.json の protected_patterns）
  local cb_config="${PROJECT_ROOT:-.}/.forge/config/circuit-breaker.json"
  if [ -f "$cb_config" ]; then
    local protected_patterns
    protected_patterns=$(jq_safe -r '.protected_patterns[]? // empty' "$cb_config" 2>/dev/null)
    if [ -n "$protected_patterns" ]; then
      local all_changed
      all_changed=$(printf '%s\n%s' "$changed_files" "$new_files" | grep -v '^$' || true)
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        local matched
        # シンプルなパターンマッチ（fnmatch スタイル）
        # .env* → .env で始まるファイル
        # *.lock → .lock で終わるファイル
        # dir/** → dir/ 以下
        local regex_pattern
        regex_pattern=$(echo "$pattern" | sed 's/\*\*/.*/' | sed 's/\*/[^\/]*/')
        matched=$(echo "$all_changed" | grep -E "^${regex_pattern}$" 2>/dev/null || true)
        if [ -n "$matched" ]; then
          log "✗ [SAFETY] 保護ファイルの変更を検出: ${matched}"
          notify_human "critical" "タスク ${task_id}: 保護ファイルの変更検出" \
            "パターン: ${pattern}\nマッチ:\n${matched}"
          task_checkpoint_restore "$work_dir" "$task_id"
          return 1
        fi
      done <<< "$protected_patterns"
    fi
  fi

  # ハードリミットチェック
  if [ "$total" -gt "$hard_limit" ]; then
    log "✗ [SAFETY] タスク ${task_id} が ${total} ファイルを変更（ハードリミット: ${hard_limit}）"
    notify_human "critical" "タスク ${task_id}: 変更ファイル数上限超過" \
      "変更: ${changed_count} / 新規: ${new_count} / 合計: ${total}（上限: ${hard_limit}）\n自動ロールバック実行"
    task_checkpoint_restore "$work_dir" "$task_id"
    return 1
  fi

  # ソフトリミットチェック
  if [ "$total" -gt "$soft_limit" ]; then
    log "⚠ [SAFETY] タスク ${task_id} が ${total} ファイルを変更（推奨上限: ${soft_limit}）"
    return 2
  fi

  return 0
}

# ===== Locked Decision Assertions 検証 =====
# research-config.json の assertions を WORK_DIR に対して機械的に検証する。
# 戻り値: 0=全通過 or assertions未定義, 1=違反あり
# stdout: 違反レポート（失敗時）
# 使い方: validate_locked_assertions <config> <work_dir> [task_id]
validate_locked_assertions() {
  local config="$1" work_dir="$2" task_id="${3:-}"

  # ガード: config不在 → return 0
  if [ -z "$config" ] || [ ! -f "$config" ]; then
    return 0
  fi

  # ガード: assertions.enabled=false（development.json で無効化されている場合）
  local dev_cfg="${PROJECT_ROOT:-.}/.forge/config/development.json"
  if [ -f "$dev_cfg" ]; then
    local enabled
    enabled=$(jq_safe -r '.assertions.enabled // true' "$dev_cfg" 2>/dev/null)
    if [ "$enabled" = "false" ]; then
      return 0
    fi
  fi

  # assertions を持つ locked_decisions を抽出
  local has_assertions
  has_assertions=$(jq '[.locked_decisions // [] | .[].assertions // [] | length] | add // 0' "$config" 2>/dev/null)
  if [ "${has_assertions:-0}" -eq 0 ]; then
    return 0
  fi

  local violations=0
  local report=""

  # locked_decisions を1件ずつ処理
  local decision_count
  decision_count=$(jq '.locked_decisions | length' "$config" 2>/dev/null || echo 0)

  local i=0
  while [ "$i" -lt "$decision_count" ]; do
    local decision_text
    decision_text=$(jq_safe -r ".locked_decisions[$i].decision // \"\"" "$config" 2>/dev/null)

    local assertion_count
    assertion_count=$(jq ".locked_decisions[$i].assertions // [] | length" "$config" 2>/dev/null || echo 0)

    if [ "$assertion_count" -eq 0 ]; then
      i=$((i + 1))
      continue
    fi

    local j=0
    while [ "$j" -lt "$assertion_count" ]; do
      local atype apath apattern aglob
      atype=$(jq_safe -r ".locked_decisions[$i].assertions[$j].type // \"\"" "$config" 2>/dev/null)
      apath=$(jq_safe -r ".locked_decisions[$i].assertions[$j].path // \"\"" "$config" 2>/dev/null)
      apattern=$(jq_safe -r ".locked_decisions[$i].assertions[$j].pattern // \"\"" "$config" 2>/dev/null)
      aglob=$(jq_safe -r ".locked_decisions[$i].assertions[$j].glob // \"\"" "$config" 2>/dev/null)

      case "$atype" in
        file_exists)
          if [ ! -f "${work_dir}/${apath}" ]; then
            report="${report}VIOLATION [${decision_text}]: file_exists — ${apath} が存在しない\n"
            violations=$((violations + 1))
          fi
          ;;
        file_absent)
          if [ -f "${work_dir}/${apath}" ]; then
            report="${report}VIOLATION [${decision_text}]: file_absent — ${apath} が存在する\n"
            violations=$((violations + 1))
          fi
          ;;
        grep_present)
          if [ -z "$apattern" ] || [ -z "$aglob" ]; then
            j=$((j + 1))
            continue
          fi
          local search_dir search_include
          search_dir=$(_resolve_glob_search_dir "$work_dir" "$aglob")
          search_include=$(_resolve_glob_include "$aglob")
          local hits
          hits=$(grep -rlE "$apattern" $search_include "$search_dir" 2>/dev/null || true)
          if [ -z "$hits" ]; then
            report="${report}VIOLATION [${decision_text}]: grep_present — パターン '${apattern}' が ${aglob} 内で見つからない\n"
            violations=$((violations + 1))
          fi
          ;;
        grep_absent)
          if [ -z "$apattern" ] || [ -z "$aglob" ]; then
            j=$((j + 1))
            continue
          fi
          local search_dir search_include
          search_dir=$(_resolve_glob_search_dir "$work_dir" "$aglob")
          search_include=$(_resolve_glob_include "$aglob")
          local hits
          hits=$(grep -rlE "$apattern" $search_include "$search_dir" 2>/dev/null || true)

          # except 配列で除外
          if [ -n "$hits" ]; then
            local except_json
            except_json=$(jq -c ".locked_decisions[$i].assertions[$j].except // []" "$config" 2>/dev/null || echo "[]")
            local except_count
            except_count=$(echo "$except_json" | jq 'length' 2>/dev/null || echo 0)

            if [ "$except_count" -gt 0 ]; then
              local filtered_hits=""
              while IFS= read -r hit_file; do
                [ -z "$hit_file" ] && continue
                local rel_path="${hit_file#${work_dir}/}"
                local is_excepted=false
                local k=0
                while [ "$k" -lt "$except_count" ]; do
                  local except_path
                  except_path=$(echo "$except_json" | jq_safe -r ".[$k]" 2>/dev/null)
                  if [ "$rel_path" = "$except_path" ]; then
                    is_excepted=true
                    break
                  fi
                  k=$((k + 1))
                done
                if [ "$is_excepted" = "false" ]; then
                  filtered_hits="${filtered_hits}${hit_file}\n"
                fi
              done <<< "$hits"
              hits=$(echo -e "$filtered_hits" | grep -v '^$' || true)
            fi

            if [ -n "$hits" ]; then
              local hit_files
              hit_files=$(echo "$hits" | sed "s|${work_dir}/||g" | head -5 | tr '\n' ', ' | sed 's/,$//')
              report="${report}VIOLATION [${decision_text}]: grep_absent — パターン '${apattern}' が ${aglob} 内でヒット: ${hit_files}\n"
              violations=$((violations + 1))
            fi
          fi
          ;;
      esac
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  if [ "$violations" -gt 0 ]; then
    echo -e "Locked Decision Assertions: ${violations} 件の違反\n${report}"
    return 1
  fi
  return 0
}

# glob パターンから grep の検索ディレクトリを解決する
# 例: "src/app/**/*.ts" → "$work_dir/src/app"
#     "src/**/*.ts"     → "$work_dir/src"
_resolve_glob_search_dir() {
  local work_dir="$1" glob="$2"
  # ** より前のディレクトリ部分を抽出
  local prefix="${glob%%\*\**}"
  prefix="${prefix%/}"
  if [ -n "$prefix" ]; then
    echo "${work_dir}/${prefix}"
  else
    echo "$work_dir"
  fi
}

# glob パターンから grep の --include オプションを解決する
# 例: "src/**/*.ts" → '--include=*.ts'
#     "*.js"        → '--include=*.js'
_resolve_glob_include() {
  local glob="$1"
  # 最後の / 以降のファイルパターンを抽出
  local file_pattern="${glob##*/}"
  if [ -n "$file_pattern" ] && [[ "$file_pattern" == *"."* ]]; then
    echo "--include=${file_pattern}"
  fi
}

# ===== Progress Tracking =====
PROGRESS_FILE="${PROJECT_ROOT:-.}/.forge/state/progress.json"

update_progress() {
  local phase="$1" stage="$2" detail="${3:-}" pct="${4:-}"
  jq -n \
    --arg phase "$phase" \
    --arg stage "$stage" \
    --arg detail "$detail" \
    --arg pct "$pct" \
    --arg updated "$(date -Iseconds)" \
    '{phase: $phase, stage: $stage, detail: $detail,
      progress_pct: (if $pct != "" then ($pct | tonumber) else null end),
      updated_at: $updated}' \
    > "${PROGRESS_FILE}.tmp" && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

# ===== SERVER_URL 取得 =====
# development.json の health_check_url からベースURL（scheme + host + port）を抽出する。
# servers[] 配列があれば最初のサーバーを使用し、なければ server にフォールバック。
# 使い方: server_url=$(get_server_url [config_file] [server_name])
get_server_url() {
  local config="${1:-${PROJECT_ROOT:-.}/.forge/config/development.json}"
  local server_name="${2:-}"
  local default="http://localhost:3000"
  if [ -f "$config" ]; then
    local health_url=""
    # servers[] 配列を優先チェック
    local servers_count
    servers_count=$(jq '.servers // [] | length' "$config" 2>/dev/null || echo 0)
    if [ "$servers_count" -gt 0 ]; then
      if [ -n "$server_name" ]; then
        health_url=$(jq_safe -r --arg name "$server_name" '.servers[] | select(.name == $name) | .health_check_url // ""' "$config")
      else
        health_url=$(jq_safe -r '.servers[0].health_check_url // ""' "$config")
      fi
    fi
    # servers[] になければ server にフォールバック
    if [ -z "$health_url" ]; then
      health_url=$(jq_safe -r '.server.health_check_url // ""' "$config")
    fi
    if [ -n "$health_url" ]; then
      echo "$health_url" | sed 's|\(https\?://[^/]*\).*|\1|'
      return
    fi
  fi
  echo "$default"
}

# ===== 設定値取得ヘルパー =====
# jq_safe パターンの簡略化ラッパー。
# 使い方: val=$(config_get '.key.subkey' 'default_value' config_file)
config_get() {
  local filter="$1"
  local default="$2"
  local config="$3"
  if [ -n "$config" ] && [ -f "$config" ]; then
    local result
    result=$(jq_safe -r "${filter} // empty" "$config" 2>/dev/null)
    if [ -n "$result" ]; then
      echo "$result"
      return
    fi
  fi
  echo "$default"
}

# ===== L1 テストファイル参照検証 =====
# L1 テストコマンドに含まれるファイルパスが WORK_DIR に存在するか検証。
# Implementer がファイルを作成していない場合を早期検出する。
# 戻り値: 0=全ファイル存在 or パス抽出不可, 1=未作成ファイルあり
# stdout: 未作成ファイル一覧（失敗時）
validate_l1_file_refs() {
  local command="$1" work_dir="$2"

  # テストファイルパスを抽出（.test./.spec./.e2e. + .sh）
  local file_refs=""
  file_refs=$(echo "$command" | grep -oE '[^ ]+\.(test|spec|e2e)\.[jt]sx?' 2>/dev/null || true)
  local sh_refs=""
  sh_refs=$(echo "$command" | grep -oE '[^ ]+\.sh' 2>/dev/null || true)
  [ -n "$sh_refs" ] && file_refs=$(printf '%s\n%s' "$file_refs" "$sh_refs")

  # パスが抽出できなかった場合は検証スキップ（return 0）
  file_refs=$(echo "$file_refs" | grep -v '^$' || true)
  [ -z "$file_refs" ] && return 0

  local missing=""
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ ! -f "${work_dir}/${ref}" ]; then
      missing="${missing}${ref}\n"
    fi
  done <<< "$file_refs"

  if [ -n "$missing" ]; then
    echo -e "$missing" | grep -v '^$'
    return 1
  fi
  return 0
}

# ===== メトリクス記録 =====
# metrics_start: 計測開始エポック秒をグローバルに記録
metrics_start() {
  _METRICS_START_EPOCH=$(date +%s)
}

# metrics_record は L648 で既に定義済み（call_id, research_dir, timestamp, extra 対応版）
# ※ 重複定義を削除 — L648 の定義が正とする

# aggregate_session_cost: session_id 別の cost_usd 合計を返す
# 使い方: result=$(aggregate_session_cost <session_id> <metrics_file>)
# 戻り値: {"session_id": "...", "total_cost_usd": N}
aggregate_session_cost() {
  local session_id="$1"
  local mfile="$2"

  if [ ! -f "$mfile" ] || [ ! -s "$mfile" ]; then
    jq -n --arg sid "$session_id" '{session_id: $sid, total_cost_usd: 0}'
    return 0
  fi

  jq -c --arg sid "$session_id" \
    '[.[] | select(.session_id == $sid) | .cost_usd // 0] | add // 0 | {session_id: $sid, total_cost_usd: .}' \
    < <(jq -s '.' "$mfile" 2>/dev/null || echo '[]')
}

# ===== 設定ファイルスキーマ検証 =====
# JSON Schema ファイルを使って config ファイルの必須フィールド・型制約を jq で検証する。
# 使い方: validate_config <config_file> <schema_file>
# 戻り値: 0=検証通過, 1=検証失敗（必須フィールド欠落または型エラー）
# 副作用: スキーマ未定義フィールドは警告ログ出力のみ（exit code に影響しない）
# スキーマ形式: JSON Schema Draft-07 の subset（type, required, properties 2段ネストまで）
validate_config() {
  local config_file="$1"
  local schema_file="$2"

  if [ ! -f "$config_file" ]; then
    echo "[CONFIG] ERROR: config file not found: $config_file" >&2
    return 1
  fi
  if [ ! -f "$schema_file" ]; then
    # スキーマファイルが存在しない場合は警告のみで続行（後方互換性）
    echo "[CONFIG] WARNING: schema file not found: $schema_file — validation skipped" >&2
    return 0
  fi

  # jq ベーススキーマ検証:
  # 1. required フィールドの存在確認（top-level + 1段ネスト）
  # 2. properties で定義された型制約（フィールドが存在する場合のみ）
  # 3. スキーマ未定義のトップレベルキー → WARN 出力（失敗にしない）
  local issues
  if ! issues=$(jq -r -n \
    --slurpfile cfg "$config_file" \
    --slurpfile sch "$schema_file" \
    '
    $cfg[0] as $c | $sch[0] as $s |
    if ($c | type) != "object" then
      "ERROR:config is not a JSON object (got " + ($c | type) + ")"
    else
      (
        ($s.properties // {}) | to_entries[] |
        .key as $k | .value as $pdef |
        if ($c | has($k) | not) then
          if (($s.required // []) | index($k)) != null then
            "ERROR:missing required field: ." + $k
          else empty end
        else
          ($pdef.type // null) as $t |
          ($c[$k] | type) as $actual_t |
          if $t != null and $actual_t != $t then
            "ERROR:type mismatch at ." + $k + ": expected " + $t + ", got " + $actual_t
          elif $t == "object" and $actual_t == "object" then
            (
              ($pdef.properties // {}) | to_entries[] |
              .key as $nk | .value as $npdef |
              if ($c[$k] | has($nk) | not) then
                if (($pdef.required // []) | index($nk)) != null then
                  "ERROR:missing required field: ." + $k + "." + $nk
                else empty end
              else
                ($npdef.type // null) as $nt |
                ($c[$k][$nk] | type) as $actual_nt |
                if $nt != null and $actual_nt != $nt then
                  "ERROR:type mismatch at ." + $k + "." + $nk + ": expected " + $nt + ", got " + $actual_nt
                else empty end
              end
            )
          else empty end
        end
      ),
      (
        ($c | keys)[] as $k |
        if (($s.properties // {}) | has($k) | not) then
          "WARN:unknown field: ." + $k
        else empty end
      )
    end
    ' 2>/dev/null | tr -d '\r'); then
    echo "[CONFIG] ERROR: スキーマ検証スクリプト実行失敗: ${config_file}" >&2
    return 1
  fi

  local error_count=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      ERROR:*)
        echo "[CONFIG] ${line}" >&2
        error_count=$((error_count + 1))
        ;;
      WARN:*)
        echo "[CONFIG] WARNING: ${line#WARN:}" >&2
        ;;
    esac
  done <<< "$issues"

  if [ "$error_count" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ===== リトライヘルパー =====
# コマンドを指数バックオフ付きでリトライ実行する。
# 使い方: retry_with_backoff <max_retries> <backoff_sec> <command...>
# バックオフ: backoff_sec * 2^(retry-1) （1→2→4→8秒 with backoff_sec=1）
# max_retries=0 の場合はコマンドを実行せず即座に return 1。
# 戻り値: 0=成功, 1=全リトライ失敗 or max_retries=0
retry_with_backoff() {
  local max_retries="$1"
  local backoff_sec="$2"
  shift 2

  # max_retries=0: コマンドを実行せず即座に失敗
  if [ "$max_retries" -le 0 ]; then
    return 1
  fi

  # 初回試行（スリープなし）
  if "$@"; then
    return 0
  fi

  # リトライループ（指数バックオフ: backoff_sec * 2^(retry-1)）
  local retry=0
  while [ "$retry" -lt "$max_retries" ]; do
    retry=$((retry + 1))
    local current_sleep
    current_sleep=$((backoff_sec * (2 ** (retry - 1))))
    log "⚠ リトライ（${retry}/${max_retries}）— ${current_sleep}秒後"
    sleep "$current_sleep"
    if "$@"; then
      return 0
    fi
  done
  return 1
}

# ===== L3 Acceptance Test 実行インフラ =====

# L3 設定読み込み（development.json から）
load_l3_config() {
  local dev_cfg="${1:-${DEV_CONFIG:-${PROJECT_ROOT:-.}/.forge/config/development.json}}"
  L3_ENABLED=$(jq_safe -r '.layer_3.enabled // false' "$dev_cfg" 2>/dev/null)
  L3_JUDGE_MODEL=$(jq_safe -r '.layer_3.judge_model // "haiku"' "$dev_cfg" 2>/dev/null)
  L3_JUDGE_TIMEOUT=$(jq_safe -r '.layer_3.judge_timeout_sec // 300' "$dev_cfg" 2>/dev/null)
  L3_MAX_JUDGE_CALLS=$(jq_safe -r '.layer_3.max_judge_calls_per_session // 20' "$dev_cfg" 2>/dev/null)
  L3_DEFAULT_TIMEOUT=$(jq_safe -r '.layer_3.default_timeout_sec // 120' "$dev_cfg" 2>/dev/null)
  L3_FAIL_CREATES_TASK=$(jq_safe -r '.layer_3.fail_creates_task // true' "$dev_cfg" 2>/dev/null)
  L3_JUDGE_CALL_COUNT=0
}

# L3 テスト配列から requires 条件に基づいてフィルタする
# 使い方: filter_l3_tests <task_json> <mode>
#   mode: "immediate" — requires なし or requires に server を含まないテスト
#         "server"    — requires に server を含むテスト
# stdout: フィルタ済み L3 テスト JSON 配列
filter_l3_tests() {
  local task_json="$1"
  local mode="$2"

  if [ "$mode" = "immediate" ]; then
    echo "$task_json" | jq -c '
      .validation.layer_3 // [] |
      [.[] | select((.requires // []) | map(select(. == "server")) | length == 0)]
    '
  else
    echo "$task_json" | jq -c '
      .validation.layer_3 // [] |
      [.[] | select((.requires // []) | map(select(. == "server")) | length > 0)]
    '
  fi
}

# L3 structural 戦略: 出力の構造・制約を機械的に検証
# definition.command: データ取得コマンド
# definition.expected_schema: JSON Schema（簡易チェック — 必須フィールドの存在確認）
# definition.verify_command: 追加の検証コマンド（オプション）
execute_l3_structural() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  local command verify_command
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')
  verify_command=$(echo "$l3_test" | jq_safe -r '.definition.verify_command // ""')

  if [ -z "$command" ]; then
    echo "ERROR: structural テストに command が未定義"
    return 1
  fi

  # メインコマンド実行
  local output exit_code=0
  output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: コマンド実行失敗 (exit=$exit_code): $output"
    return 1
  fi

  # JSON 構造検証（出力が JSON の場合）
  if echo "$output" | jq empty 2>/dev/null; then
    local required_fields
    required_fields=$(echo "$l3_test" | jq -r '.definition.expected_schema.required // [] | .[]' 2>/dev/null | tr -d '\r')
    for field in $required_fields; do
      [ -z "$field" ] && continue
      if ! echo "$output" | jq -e ".$field" > /dev/null 2>&1; then
        echo "FAIL: 必須フィールド '$field' が出力に含まれない"
        return 1
      fi
    done
  fi

  # 追加検証コマンド
  if [ -n "$verify_command" ]; then
    local verify_output verify_exit=0
    verify_output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $verify_command" 2>&1) || verify_exit=$?
    if [ "$verify_exit" -ne 0 ]; then
      echo "FAIL: 追加検証失敗 (exit=$verify_exit): $verify_output"
      return 1
    fi
  fi

  echo "PASS: structural テスト合格"
  return 0
}

# L3 api_e2e 戦略: API 連鎖フローの検証
# definition.command: API 呼出シーケンス（シェルスクリプト or curl チェーン）
execute_l3_api_e2e() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  local command
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')

  if [ -z "$command" ]; then
    echo "ERROR: api_e2e テストに command が未定義"
    return 1
  fi

  local output exit_code=0
  output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: API E2E テスト失敗 (exit=$exit_code): $output"
    return 1
  fi

  echo "PASS: api_e2e テスト合格"
  return 0
}

# L3 llm_judge 戦略: LLM が出力品質をスコアリング
# definition.command: 評価対象の出力を取得するコマンド
# definition.judge_criteria: 評価基準の配列
# definition.success_threshold: 合格閾値（0.0〜1.0）
execute_l3_llm_judge() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  # Judge 呼出回数チェック
  if [ "${L3_JUDGE_CALL_COUNT:-0}" -ge "${L3_MAX_JUDGE_CALLS:-20}" ]; then
    echo "SKIP: LLM Judge 呼出上限 (${L3_MAX_JUDGE_CALLS}) に到達"
    return 2
  fi

  local command judge_criteria_json threshold test_id
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')
  judge_criteria_json=$(echo "$l3_test" | jq_safe -c '.definition.judge_criteria // []')
  threshold=$(echo "$l3_test" | jq_safe -r '.definition.success_threshold // 0.7')
  test_id=$(echo "$l3_test" | jq_safe -r '.id // "unknown"')

  if [ -z "$command" ]; then
    echo "ERROR: llm_judge テストに command が未定義"
    return 1
  fi

  # 評価対象の出力を取得
  local target_output target_exit=0
  target_output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || target_exit=$?

  if [ "$target_exit" -ne 0 ]; then
    echo "FAIL: 評価対象コマンド実行失敗 (exit=$target_exit): $target_output"
    return 1
  fi

  # Judge プロンプト構築
  local judge_prompt
  judge_prompt="以下の出力を評価してください。

## 評価対象の出力
${target_output}

## 評価基準
$(echo "$judge_criteria_json" | jq -r '.[]' 2>/dev/null | while read -r criterion; do echo "- ${criterion}"; done)

## 合格閾値
${threshold}

## テストID
${test_id}

各評価基準に対して 0.0〜1.0 のスコアと根拠を出力してください。"

  # Judge 呼出
  local judge_output_file=".forge/state/l3-judge-${test_id}-$(date +%s).json"
  local judge_log_file=".forge/logs/development/l3-judge-${test_id}.log"
  mkdir -p "$(dirname "$judge_output_file")" "$(dirname "$judge_log_file")"

  L3_JUDGE_CALL_COUNT=$(( ${L3_JUDGE_CALL_COUNT:-0} + 1 ))

  local judge_schema="${PROJECT_ROOT:-.}/.forge/schemas/l3-judge.schema.json"
  if ! run_claude "${L3_JUDGE_MODEL:-haiku}" "${PROJECT_ROOT:-.}/.claude/agents/l3-judge.md" \
    "$judge_prompt" "$judge_output_file" "$judge_log_file" \
    "Write,Edit,MultiEdit,Bash,WebSearch,WebFetch" "${L3_JUDGE_TIMEOUT:-300}" "" \
    "$judge_schema"; then
    echo "FAIL: LLM Judge 実行エラー"
    return 1
  fi

  # .pending → 本ファイルに昇格
  if [ -f "${judge_output_file}.pending" ]; then
    mv "${judge_output_file}.pending" "$judge_output_file"
  fi

  if [ ! -f "$judge_output_file" ] || ! jq empty "$judge_output_file" 2>/dev/null; then
    echo "FAIL: LLM Judge 出力が不正"
    return 1
  fi

  # 判定
  local pass overall_score summary
  pass=$(jq_safe -r '.pass // false' "$judge_output_file")
  overall_score=$(jq_safe -r '.overall_score // 0' "$judge_output_file")
  summary=$(jq_safe -r '.summary // "判定不能"' "$judge_output_file")

  if [ "$pass" = "true" ]; then
    echo "PASS: llm_judge テスト合格 (score=${overall_score}, threshold=${threshold}): ${summary}"
    return 0
  else
    echo "FAIL: llm_judge テスト不合格 (score=${overall_score}, threshold=${threshold}): ${summary}"
    return 1
  fi
}

# L3 cli_flow 戦略: claude -p で対話フロー模擬
# definition.command: CLI フロー実行コマンド
# definition.verify_command: 出力ファイル存在確認等
execute_l3_cli_flow() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  local command verify_command
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')
  verify_command=$(echo "$l3_test" | jq_safe -r '.definition.verify_command // ""')

  if [ -z "$command" ]; then
    echo "ERROR: cli_flow テストに command が未定義"
    return 1
  fi

  # CLI フロー実行
  local output exit_code=0
  output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: CLI フロー実行失敗 (exit=$exit_code): $output"
    return 1
  fi

  # 検証コマンド実行（オプション）
  if [ -n "$verify_command" ]; then
    local verify_output verify_exit=0
    verify_output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $verify_command" 2>&1) || verify_exit=$?
    if [ "$verify_exit" -ne 0 ]; then
      echo "FAIL: CLI フロー検証失敗 (exit=$verify_exit): $verify_output"
      return 1
    fi
  fi

  echo "PASS: cli_flow テスト合格"
  return 0
}

# L3 context_injection 戦略: コンテキスト注入の動作検証
# definition.command: コンテキスト書込コマンド
# definition.verify_command: 注入結果の検証コマンド
# definition.context_file: 検証対象ファイル（オプション）
execute_l3_context_injection() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  local command verify_command context_file
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')
  verify_command=$(echo "$l3_test" | jq_safe -r '.definition.verify_command // ""')
  context_file=$(echo "$l3_test" | jq_safe -r '.definition.context_file // ""')

  if [ -z "$command" ]; then
    echo "ERROR: context_injection テストに command が未定義"
    return 1
  fi

  # コンテキスト書込実行
  local output exit_code=0
  output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: コンテキスト注入失敗 (exit=$exit_code): $output"
    return 1
  fi

  # context_file の存在確認
  if [ -n "$context_file" ] && [ ! -f "${work_dir}/${context_file}" ]; then
    echo "FAIL: コンテキストファイル未生成: ${context_file}"
    return 1
  fi

  # 検証コマンド
  if [ -n "$verify_command" ]; then
    local verify_output verify_exit=0
    verify_output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $verify_command" 2>&1) || verify_exit=$?
    if [ "$verify_exit" -ne 0 ]; then
      echo "FAIL: コンテキスト検証失敗 (exit=$verify_exit): $verify_output"
      return 1
    fi
  fi

  echo "PASS: context_injection テスト合格"
  return 0
}

# L3 テスト実行ディスパッチャ
# 使い方: execute_l3_test <l3_test_json> [work_dir] [timeout]
# 戻り値: 0=PASS, 1=FAIL, 2=SKIP
execute_l3_test() {
  local l3_test="$1"
  local work_dir="${2:-${WORK_DIR:-.}}"
  local timeout="${3:-${L3_DEFAULT_TIMEOUT:-120}}"

  local strategy test_id
  strategy=$(echo "$l3_test" | jq_safe -r '.strategy // ""')
  test_id=$(echo "$l3_test" | jq_safe -r '.id // "unknown"')

  case "$strategy" in
    structural)
      execute_l3_structural "$l3_test" "$work_dir" "$timeout"
      ;;
    api_e2e)
      execute_l3_api_e2e "$l3_test" "$work_dir" "$timeout"
      ;;
    llm_judge)
      execute_l3_llm_judge "$l3_test" "$work_dir" "$timeout"
      ;;
    cli_flow)
      execute_l3_cli_flow "$l3_test" "$work_dir" "$timeout"
      ;;
    context_injection)
      execute_l3_context_injection "$l3_test" "$work_dir" "$timeout"
      ;;
    *)
      echo "ERROR: 不明な L3 戦略: ${strategy}"
      return 1
      ;;
  esac
}

# ===== タスク状態排他ロック =====
# mkdirベース排他ロック（Windows Git Bash環境ではflock不可のためmkdirを使用）
#
# acquire_lock <lock_dir> [timeout_sec] [retry_interval_sec]
#   lock_dir        : ロックディレクトリパス
#                     例: "${PROJECT_ROOT}/.forge/state/.lock/task-stack.lock"
#   timeout_sec     : タイムアウト秒数（デフォルト: 10）
#   retry_interval  : リトライ間隔秒数（デフォルト: 0.5）
# 戻り値: 0=取得成功, 1=タイムアウト（stderrに "Lock acquisition timeout" をログ出力）
acquire_lock() {
  local lock_dir="$1"
  local timeout_sec="${2:-10}"
  local retry_interval="${3:-0.5}"
  # 最大リトライ回数 = timeout_sec / retry_interval（整数切り捨て）
  local max_attempts
  max_attempts=$(awk "BEGIN {printf \"%d\", $timeout_sec / $retry_interval}")

  mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || true

  local attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      return 0
    fi

    # staleロック検出: mtime > 60秒 → 自動削除してリトライ（attempt カウントを増加させない）
    if [ -d "$lock_dir" ]; then
      local lock_mtime now age
      lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null || stat -f %m "$lock_dir" 2>/dev/null || echo 0)
      now=$(date +%s)
      age=$(( now - lock_mtime ))
      if [ "$age" -gt 60 ]; then
        log "acquire_lock: stale lock (${age}s) detected, removing: ${lock_dir}"
        rm -rf "$lock_dir" 2>/dev/null || true
        continue  # 即座にリトライ（attempt を増加させない）
      fi
    fi

    attempt=$(( attempt + 1 ))
    sleep "$retry_interval"
  done

  log "Lock acquisition timeout: ${lock_dir}"
  return 1
}

# release_lock <lock_dir>
# ロックディレクトリを削除してロックを解放する。
release_lock() {
  local lock_dir="$1"
  rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
}
