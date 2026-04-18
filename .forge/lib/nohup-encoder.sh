#!/bin/bash
# nohup-encoder.sh — 長時間エンコード（>10分）の nohup + progress file 分離実行
#
# 目的:
#   Claude Code Bash SIGTERM 伝播バグ（Issue #45717, 2026-04 時点未修正）を回避する。
#   親プロセスがタイムアウトで SIGTERM を受けても、nohup で分離した子プロセス（ffmpeg 等）
#   は HUP/TERM を無視して継続する。進捗・完了は progress file 経由で非同期に確認する。
#
# 設計原則:
#   - 親プロセス終了 ≠ 子プロセス終了（nohup + setsid/disown + stdin切断）
#   - 状態はすべてファイル経由（PID / progress / log / output）
#   - ポーリングは呼出元の制御下（blocking/non-blocking の選択可）
#   - validate_render_output は render-loop.sh の同名関数と同契約（ffprobe/size/status）
#
# 使い方（source 必須）:
#   source .forge/lib/nohup-encoder.sh
#   start_long_encode <output_file> <progress_file> <log_file> <pid_file> <cmd> [args...]
#   wait_for_encode   <progress_file> <output_file> <max_wait_sec> [poll_interval_sec]
#   read_encode_progress <progress_file>   # stdout: "status=<s> percent=<p>"
#   is_encode_running    <pid_file>        # rc=0 if alive, rc=1 if exited
#   stop_encode          <pid_file>        # graceful SIGTERM → force SIGKILL after 3s
#   validate_render_output <output_file> <size_threshold> <job_id> [render_jobs_file]
#
# 戻り値:
#   start_long_encode   : 0=起動成功 / 2=引数不足 / 3=コマンド不在
#   wait_for_encode     : 0=完了 / 4=タイムアウト / 5=progress file 不正
#   validate_render_output: 0=PASS / 1=サイズ不足 / 2=ffprobe失敗 / 3=ffprobe不在 /
#                           4=RenderJob status!=completed / 5=引数/ファイル不在

# ----------------------------------------------------------------------------
# log 未定義ガード（単体テストで common.sh を source しない場合の保険）
# ----------------------------------------------------------------------------
if ! declare -F log >/dev/null 2>&1; then
  log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fi

# ffprobe timeout（長尺動画で 60s を超える場合は呼出側で上書き）
NOHUP_ENC_FFPROBE_TIMEOUT="${NOHUP_ENC_FFPROBE_TIMEOUT:-60}"

# ----------------------------------------------------------------------------
# start_long_encode — nohup 下で detached にコマンド起動
#   output_file   : 期待される成果物パス（完了検出に使用）
#   progress_file : エンコード進捗書き出し先（子プロセスが更新する想定）
#   log_file      : stdout/stderr の保存先
#   pid_file      : 子プロセス PID の書き出し先
#   cmd [args...] : 実行するコマンド（ffmpeg ... 等）
#
# 振る舞い:
#   - nohup + & で起動し、stdin を /dev/null に切断
#   - 親シェルが SIGTERM を受けても子は継続する
#   - 初期 progress を "status=started" で書き込み、監視側が空ファイルを読まないようにする
# ----------------------------------------------------------------------------
start_long_encode() {
  local output_file="${1:-}"
  local progress_file="${2:-}"
  local log_file="${3:-}"
  local pid_file="${4:-}"
  shift 4 2>/dev/null || { log "✗ start_long_encode: 引数不足 (output/progress/log/pid + cmd)"; return 2; }

  if [ -z "$output_file" ] || [ -z "$progress_file" ] || [ -z "$log_file" ] || [ -z "$pid_file" ]; then
    log "✗ start_long_encode: 必須引数が空"
    return 2
  fi
  if [ $# -lt 1 ]; then
    log "✗ start_long_encode: 実行コマンドが指定されていません"
    return 2
  fi
  if ! command -v "$1" >/dev/null 2>&1; then
    log "✗ start_long_encode: コマンドが PATH に存在しません: $1"
    return 3
  fi

  mkdir -p "$(dirname "$output_file")" "$(dirname "$progress_file")" \
           "$(dirname "$log_file")"    "$(dirname "$pid_file")" 2>/dev/null || true

  # 初期状態を progress file に書き込み（監視側の空読み回避）
  printf 'status=started\npercent=0\nstarted_at=%s\n' "$(date -Iseconds)" > "$progress_file"

  # nohup で detach、stdin切断、stdout/stderr を log に集約、& で背景実行。
  # 注: setsid は挟まない（setsid fork 後に親 setsid が exit し $! が無効 PID になるため、
  # PID 追跡が壊れる）。nohup は SIGHUP を無視し、stdin 切断で端末依存も解く。
  # それだけで SIGTERM 伝播バグ (Issue #45717) に対し十分な分離となる。
  nohup "$@" </dev/null >>"$log_file" 2>&1 &
  local pid=$!
  # bash の job table から外し、親 shell 終了時の暗黙 SIGHUP 送信も防ぐ。
  # bash 4.0+ は PID を直接受ける。古い環境は `|| true` で握りつぶす。
  disown "$pid" 2>/dev/null || true

  if [ -z "$pid" ] || ! [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    log "✗ start_long_encode: PID 取得失敗 (got '$pid')"
    return 3
  fi

  echo "$pid" > "$pid_file"
  log "✓ start_long_encode: pid=$pid cmd='$*' output='$output_file'"
  return 0
}

# ----------------------------------------------------------------------------
# read_encode_progress — progress file から status / percent を取り出す
#   progress file フォーマット: KEY=VALUE 改行区切り（ffmpeg -progress と互換）
#   出力: "status=<value> percent=<value>" を stdout に書く（未定義は empty）
# ----------------------------------------------------------------------------
read_encode_progress() {
  local progress_file="${1:-}"
  if [ -z "$progress_file" ] || [ ! -f "$progress_file" ]; then
    echo "status= percent="
    return 5
  fi
  local st pc
  st=$(grep -E '^(status|progress)=' "$progress_file" | tail -1 | cut -d= -f2- | tr -d '\r')
  pc=$(grep -E '^percent=' "$progress_file" | tail -1 | cut -d= -f2- | tr -d '\r')
  echo "status=${st:-} percent=${pc:-}"
  return 0
}

# ----------------------------------------------------------------------------
# is_encode_running — pid_file の PID が alive か確認
#   戻り値: 0=生存 / 1=終了 / 2=引数不正
# ----------------------------------------------------------------------------
is_encode_running() {
  local pid_file="${1:-}"
  if [ -z "$pid_file" ] || [ ! -f "$pid_file" ]; then return 2; fi
  local pid
  pid=$(tr -d ' \r\n' < "$pid_file")
  if [ -z "$pid" ] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then return 2; fi
  if kill -0 "$pid" 2>/dev/null; then return 0; fi
  return 1
}

# ----------------------------------------------------------------------------
# wait_for_encode — progress file が status=completed / ended / success
#                   または output_file が閾値サイズ以上になるまでポーリング
#   戻り値: 0=完了 / 4=タイムアウト / 5=progress file 消失
# ----------------------------------------------------------------------------
wait_for_encode() {
  local progress_file="${1:-}"
  local output_file="${2:-}"
  local max_wait="${3:-1800}"
  local poll="${4:-2}"
  if [ -z "$progress_file" ] || [ -z "$output_file" ]; then
    log "✗ wait_for_encode: 引数不足"
    return 5
  fi
  local elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    if [ -f "$progress_file" ]; then
      local line
      line=$(read_encode_progress "$progress_file")
      case "$line" in
        *status=completed*|*status=ended*|*status=success*|*status=done*)
          log "✓ wait_for_encode: progress=completed after ${elapsed}s"
          return 0 ;;
        *status=failed*|*status=error*)
          log "✗ wait_for_encode: progress=failed after ${elapsed}s"
          return 4 ;;
      esac
    fi
    # progress が無くても output_file が既に出力されていれば完了扱い
    if [ -f "$output_file" ] && [ "$(wc -c <"$output_file" 2>/dev/null | tr -d ' ')" -gt 0 ]; then
      # ffmpeg がまだ書き込み中かもしれないので status も確認
      if ! is_encode_running "${progress_file%.*}.pid" 2>/dev/null; then
        log "✓ wait_for_encode: output detected, pid exited after ${elapsed}s"
        return 0
      fi
    fi
    sleep "$poll"
    elapsed=$((elapsed + poll))
  done
  log "✗ wait_for_encode: timeout after ${max_wait}s"
  return 4
}

# ----------------------------------------------------------------------------
# stop_encode — graceful TERM → 3s 待機 → KILL
# ----------------------------------------------------------------------------
stop_encode() {
  local pid_file="${1:-}"
  if [ -z "$pid_file" ] || [ ! -f "$pid_file" ]; then return 2; fi
  local pid
  pid=$(tr -d ' \r\n' < "$pid_file")
  [ -z "$pid" ] && return 2
  kill -TERM "$pid" 2>/dev/null || return 1
  local i=0
  while [ "$i" -lt 3 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  return 0
}

# ----------------------------------------------------------------------------
# validate_render_output — validate_task_changes を ffprobe/size_threshold/
#                          RenderJob status 検証に置換した関数。
#
# 引数:
#   output_file       : 検証対象動画ファイル
#   size_threshold    : 最小サイズ（bytes）
#   job_id            : RenderJob ID（optional）
#   render_jobs_file  : render-jobs.jsonl のパス（optional）
#
# 戻り値:
#   0 = PASS / 1 = サイズ不足 / 2 = ffprobe 失敗 /
#   3 = ffprobe 不在 / 4 = RenderJob status!=completed / 5 = 引数/ファイル不在
# ----------------------------------------------------------------------------
validate_render_output() {
  local output_file="${1:-}"
  local size_threshold="${2:-102400}"
  local job_id="${3:-}"
  local jobs_file="${4:-${RENDER_JOBS_FILE:-.forge/state/render-jobs.jsonl}}"

  if [ -z "$output_file" ]; then
    log "✗ validate_render_output: output_file 引数が空"
    return 5
  fi
  if [ ! -f "$output_file" ]; then
    log "✗ validate_render_output: 出力ファイル不在: ${output_file}"
    return 5
  fi
  if ! command -v ffprobe >/dev/null 2>&1; then
    log "✗ validate_render_output: ffprobe が PATH に存在しません (preflight)"
    return 3
  fi
  # (1) ffprobe 妥当性
  local ff_rc=0
  timeout "$NOHUP_ENC_FFPROBE_TIMEOUT" \
    ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name,width,height \
            -of default=noprint_wrappers=1:nokey=1 \
            "$output_file" >/dev/null 2>&1 || ff_rc=$?
  if [ "$ff_rc" -ne 0 ]; then
    log "✗ validate_render_output: ffprobe rc=${ff_rc} ${output_file}"
    return 2
  fi
  # (2) サイズ閾値
  local actual_size
  actual_size=$(wc -c <"$output_file" 2>/dev/null | tr -d ' ')
  actual_size=${actual_size:-0}
  if ! [[ "$actual_size" =~ ^[0-9]+$ ]] || [ "$actual_size" -lt "$size_threshold" ]; then
    log "✗ validate_render_output: size_threshold 不足 ${actual_size} < ${size_threshold}"
    return 1
  fi
  # (3) RenderJob status（job_id 指定時のみ）
  if [ -n "$job_id" ] && [ -f "$jobs_file" ]; then
    local job_status
    job_status=$(jq -r --arg j "$job_id" \
      'select(.job_id == $j) | .status' "$jobs_file" 2>/dev/null | tail -1)
    if [ "$job_status" != "completed" ] && [ "$job_status" != "succeeded" ]; then
      log "✗ validate_render_output: RenderJob [${job_id}] status=${job_status:-unknown}"
      return 4
    fi
  fi
  log "✓ validate_render_output: PASS size=${actual_size} threshold=${size_threshold}"
  return 0
}
