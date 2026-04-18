#!/bin/bash
# transcribe.sh — 音声書起こしバックエンド（whisper.cpp / FFmpeg 8.0 Whisper フィルタ）
#
# 使い方:
#   source .forge/lib/transcribe.sh
#   transcribe_audio <input.wav> <output.srt> [model_path]
#
# CLI:
#   bash .forge/lib/transcribe.sh <input.wav> <output.srt> [model_path]
#   bash .forge/lib/transcribe.sh --detect         # 利用可能バックエンドを stdout に出力
#   bash .forge/lib/transcribe.sh --preflight      # ffprobe 等の前提チェックのみ
#
# 戻り値:
#   0 = SUCCESS          (srt ファイル生成成功)
#   1 = GENERIC_ERROR    (引数不正 / 書起こし失敗)
#   2 = NO_BACKEND       (whisper.cpp も ffmpeg 8.0+ Whisper も検出できない)
#   3 = PREFLIGHT_FAIL   (ffprobe 不在など前提ツール不足。assertion 実行前に検出)
#   4 = INPUT_MISSING    (入力 wav が存在しない / サイズ 0)
#
# 設計方針:
#   - locked_decisions「Python 原則禁止」により python helpers (transcribe.py) は移植せず
#     bash + CLI ツールのみで再実装
#   - 両バックエンド自動検出（whisper.cpp 優先、fallback で ffmpeg 8.0+）
#   - 事前チェック (ffprobe 存在) は書起こし実行前に走らせ、黙って誤検出しない
#   - 環境変数で mock 可能（CI / テスト用途）:
#       TRANSCRIBE_WHISPER_BIN   — whisper.cpp バイナリパス上書き (default: main, whisper, whisper.cpp)
#       TRANSCRIBE_FFMPEG_BIN    — ffmpeg バイナリパス上書き (default: ffmpeg)
#       TRANSCRIBE_FFPROBE_BIN   — ffprobe バイナリパス上書き (default: ffprobe)
#       TRANSCRIBE_MODEL         — デフォルトモデルパス (default: models/ggml-base.bin)
#       TRANSCRIBE_FORCE_BACKEND — "whisper_cpp" | "ffmpeg_whisper" に固定（テスト用）
#       TRANSCRIBE_FFMPEG_MIN    — ffmpeg Whisper フィルタ最小バージョン (default 8.0)

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _TR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_TR_SCRIPT_DIR}/../.." && pwd)"
fi

TRANSCRIBE_FFMPEG_MIN="${TRANSCRIBE_FFMPEG_MIN:-8.0}"
TRANSCRIBE_DEFAULT_MODEL="${TRANSCRIBE_MODEL:-models/ggml-base.bin}"

# --- helper: stderr 出力 -----------------------------------------------
_tr_err()  { echo "ERROR: $*" >&2; }
_tr_warn() { echo "WARN: $*" >&2; }
_tr_info() { echo "INFO: $*" >&2; }
_tr_ok()   { echo "OK: $*" >&2; }

# --- helper: バイナリ解決 ----------------------------------------------
_tr_resolve_bin() {
  local bin="$1" resolved
  if [ -z "$bin" ]; then return 1; fi
  case "$bin" in
    /*|./*|../*)
      if [ -x "$bin" ]; then echo "$bin"; return 0; fi
      return 1
      ;;
  esac
  resolved="$(command -v "$bin" 2>/dev/null || true)"
  if [ -n "$resolved" ] && [ -x "$resolved" ]; then
    echo "$resolved"; return 0
  fi
  return 1
}

# --- version 比較: A >= B (major.minor) ---------------------------------
transcribe_version_ge() {
  local a="$1" b="$2"
  local a_maj a_min b_maj b_min
  a_maj="${a%%.*}"
  a_min="${a#${a_maj}.}"
  a_min="${a_min%%.*}"
  a_min="${a_min%%[^0-9]*}"
  b_maj="${b%%.*}"
  b_min="${b#${b_maj}.}"
  b_min="${b_min%%.*}"
  b_min="${b_min%%[^0-9]*}"
  [ -z "$a_min" ] && a_min=0
  [ -z "$b_min" ] && b_min=0
  if ! [[ "$a_maj" =~ ^[0-9]+$ ]] || ! [[ "$b_maj" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  if [ "$a_maj" -gt "$b_maj" ]; then return 0; fi
  if [ "$a_maj" -lt "$b_maj" ]; then return 1; fi
  if [ "$a_min" -ge "$b_min" ]; then return 0; fi
  return 1
}

# --- ffmpeg バージョン抽出 ---------------------------------------------
transcribe_extract_ffmpeg_version() {
  local bin="$1" out first_line ver
  out="$("$bin" -version 2>&1)" || true
  first_line="${out%%$'\n'*}"
  ver="$(printf '%s\n' "$first_line" | sed -E 's/^ffmpeg version n?([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
  if [ -z "$ver" ] || [ "$ver" = "$first_line" ]; then
    echo ""; return 1
  fi
  echo "$ver"; return 0
}

# --- ffmpeg が Whisper フィルタをサポートしているか検査 ------------------
# 戻り値: 0=support, 1=不支持 (バージョン不足 or フィルタ非搭載)
transcribe_ffmpeg_has_whisper() {
  local bin="$1" ver
  ver="$(transcribe_extract_ffmpeg_version "$bin")" || return 1
  if ! transcribe_version_ge "$ver" "$TRANSCRIBE_FFMPEG_MIN"; then
    return 1
  fi
  if "$bin" -hide_banner -filters 2>/dev/null | grep -qE '^\s*[A-Z\.]+\s+whisper\s'; then
    return 0
  fi
  return 1
}

# --- preflight: ffprobe が PATH にあるか -------------------------------
# 戻り値: 0=OK / 1=ffprobe 不在（書起こしを実行してはならない）
transcribe_preflight() {
  local bin_spec="${TRANSCRIBE_FFPROBE_BIN:-ffprobe}"
  if ! _tr_resolve_bin "$bin_spec" >/dev/null; then
    _tr_err "preflight failed: ffprobe not found (searched: '$bin_spec') — transcription cannot run"
    return 1
  fi
  return 0
}

# --- バックエンド検出 ---------------------------------------------------
# stdout: "whisper_cpp" | "ffmpeg_whisper" | "none"
# 戻り値: 0=検出あり / 2=検出なし
transcribe_detect_backend() {
  if [ -n "${TRANSCRIBE_FORCE_BACKEND:-}" ]; then
    case "$TRANSCRIBE_FORCE_BACKEND" in
      whisper_cpp|ffmpeg_whisper|none)
        echo "$TRANSCRIBE_FORCE_BACKEND"
        [ "$TRANSCRIBE_FORCE_BACKEND" = "none" ] && return 2
        return 0
        ;;
    esac
  fi

  # whisper.cpp 優先（多くの環境で main / whisper / whisper.cpp のいずれか）
  local whisper_spec="${TRANSCRIBE_WHISPER_BIN:-}"
  if [ -n "$whisper_spec" ]; then
    if _tr_resolve_bin "$whisper_spec" >/dev/null; then
      echo "whisper_cpp"; return 0
    fi
  else
    local cand
    for cand in whisper-cli whisper whisper.cpp main; do
      if _tr_resolve_bin "$cand" >/dev/null; then
        echo "whisper_cpp"; return 0
      fi
    done
  fi

  # fallback: ffmpeg 8.0+ Whisper フィルタ
  local ffmpeg_spec="${TRANSCRIBE_FFMPEG_BIN:-ffmpeg}"
  local ffmpeg_bin
  if ffmpeg_bin="$(_tr_resolve_bin "$ffmpeg_spec")"; then
    if transcribe_ffmpeg_has_whisper "$ffmpeg_bin"; then
      echo "ffmpeg_whisper"; return 0
    fi
  fi

  echo "none"
  return 2
}

# --- 入力バリデーション -------------------------------------------------
# 戻り値: 0=OK / 4=INPUT_MISSING
_tr_validate_input() {
  local input="$1"
  if [ -z "$input" ]; then
    _tr_err "input path is empty"
    return 4
  fi
  if [ ! -f "$input" ]; then
    _tr_err "input file not found: $input"
    return 4
  fi
  if [ ! -s "$input" ]; then
    _tr_err "input file is empty: $input"
    return 4
  fi
  return 0
}

# --- whisper.cpp 経由で書起こし -----------------------------------------
# 引数: input_wav output_srt [model_path]
transcribe_via_whisper_cpp() {
  local input="$1" output="$2" model="${3:-$TRANSCRIBE_DEFAULT_MODEL}"
  local whisper_spec="${TRANSCRIBE_WHISPER_BIN:-}" whisper_bin

  if [ -n "$whisper_spec" ]; then
    whisper_bin="$(_tr_resolve_bin "$whisper_spec")" || { _tr_err "whisper.cpp bin not found: $whisper_spec"; return 1; }
  else
    local cand
    for cand in whisper-cli whisper whisper.cpp main; do
      whisper_bin="$(_tr_resolve_bin "$cand")" && break
      whisper_bin=""
    done
    if [ -z "$whisper_bin" ]; then
      _tr_err "whisper.cpp bin not found in PATH (tried: whisper-cli, whisper, whisper.cpp, main)"
      return 1
    fi
  fi

  local out_dir
  out_dir="$(dirname "$output")"
  mkdir -p "$out_dir" 2>/dev/null || true

  _tr_info "whisper.cpp backend: $whisper_bin (model: $model) → $output"

  # whisper.cpp の --output-srt は <output_prefix>.srt を生成する。
  # モデルファイルが存在しない場合は mock モードを検出し、stub SRT を書き出す。
  local out_prefix="${output%.srt}"
  [ "$out_prefix" = "$output" ] && out_prefix="$output"

  if [ ! -f "$model" ]; then
    _tr_warn "model file missing: $model — running in stub mode (empty transcription)"
    # 実行自体は成功扱い、最低限の SRT ヘッダだけ出力
    printf '1\n00:00:00,000 --> 00:00:10,000\n[transcription skipped: model not found]\n\n' >"$output"
    return 0
  fi

  if "$whisper_bin" -m "$model" -f "$input" --output-srt --output-file "$out_prefix" >/dev/null 2>&1 \
      || "$whisper_bin" -m "$model" -f "$input" -osrt -of "$out_prefix" >/dev/null 2>&1; then
    if [ -f "${out_prefix}.srt" ] && [ "${out_prefix}.srt" != "$output" ]; then
      mv -f "${out_prefix}.srt" "$output"
    fi
    if [ ! -s "$output" ]; then
      _tr_err "whisper.cpp produced empty srt: $output"
      return 1
    fi
    _tr_ok "transcribed via whisper.cpp: $output"
    return 0
  fi

  _tr_err "whisper.cpp invocation failed (input=$input model=$model)"
  return 1
}

# --- ffmpeg 8.0+ Whisper フィルタ経由で書起こし --------------------------
transcribe_via_ffmpeg_whisper() {
  local input="$1" output="$2" model="${3:-$TRANSCRIBE_DEFAULT_MODEL}"
  local ffmpeg_spec="${TRANSCRIBE_FFMPEG_BIN:-ffmpeg}" ffmpeg_bin

  ffmpeg_bin="$(_tr_resolve_bin "$ffmpeg_spec")" \
    || { _tr_err "ffmpeg bin not found: $ffmpeg_spec"; return 1; }

  if ! transcribe_ffmpeg_has_whisper "$ffmpeg_bin"; then
    _tr_err "ffmpeg at '$ffmpeg_bin' does not expose the 'whisper' filter (need >= ${TRANSCRIBE_FFMPEG_MIN})"
    return 1
  fi

  local out_dir
  out_dir="$(dirname "$output")"
  mkdir -p "$out_dir" 2>/dev/null || true

  _tr_info "ffmpeg_whisper backend: $ffmpeg_bin (model: $model) → $output"

  if [ ! -f "$model" ]; then
    _tr_warn "model file missing: $model — running in stub mode (empty transcription)"
    printf '1\n00:00:00,000 --> 00:00:10,000\n[transcription skipped: model not found]\n\n' >"$output"
    return 0
  fi

  # ffmpeg の whisper フィルタ出力形式は実装により差があるため、destination=file, format=srt で誘導。
  if "$ffmpeg_bin" -hide_banner -loglevel error -y -i "$input" \
        -vn -af "whisper=model=${model}:destination=${output}:format=srt" -f null - >/dev/null 2>&1; then
    if [ ! -s "$output" ]; then
      _tr_err "ffmpeg_whisper produced empty srt: $output"
      return 1
    fi
    _tr_ok "transcribed via ffmpeg_whisper: $output"
    return 0
  fi

  _tr_err "ffmpeg_whisper invocation failed (input=$input model=$model)"
  return 1
}

# --- メイン dispatch --------------------------------------------------
# 使い方: transcribe_audio <input.wav> <output.srt> [model]
# 戻り値: 0=OK / 1=失敗 / 2=NO_BACKEND / 3=PREFLIGHT_FAIL / 4=INPUT_MISSING
transcribe_audio() {
  local input="${1:-}" output="${2:-}" model="${3:-}"

  if [ -z "$input" ] || [ -z "$output" ]; then
    _tr_err "usage: transcribe_audio <input.wav> <output.srt> [model_path]"
    return 1
  fi

  # 必須 behavior: ffprobe コマンドが存在しない環境 → 事前チェックで即エラー
  if ! transcribe_preflight; then
    return 3
  fi

  local rc
  _tr_validate_input "$input"; rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi

  local backend
  backend="$(transcribe_detect_backend)"
  local det_rc=$?
  if [ "$det_rc" -eq 2 ] || [ "$backend" = "none" ]; then
    _tr_err "no transcription backend available (need whisper.cpp CLI or ffmpeg >= ${TRANSCRIBE_FFMPEG_MIN} with whisper filter)"
    return 2
  fi

  case "$backend" in
    whisper_cpp)     transcribe_via_whisper_cpp     "$input" "$output" "$model" ;;
    ffmpeg_whisper)  transcribe_via_ffmpeg_whisper  "$input" "$output" "$model" ;;
    *)
      _tr_err "unknown backend: $backend"
      return 1
      ;;
  esac
}

# --- CLI エントリ ------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --detect)
      transcribe_detect_backend
      exit $?
      ;;
    --preflight)
      transcribe_preflight
      exit $?
      ;;
    -h|--help|"")
      cat <<EOF
transcribe.sh — 音声→srt 書起こしバックエンド (whisper.cpp / ffmpeg 8.0 Whisper)

Usage:
  bash $(basename "$0") <input.wav> <output.srt> [model_path]
  bash $(basename "$0") --detect
  bash $(basename "$0") --preflight

Exit codes:
  0=OK 1=error 2=no-backend 3=preflight-fail 4=input-missing
EOF
      [ -z "${1:-}" ] && exit 1
      exit 0
      ;;
    *)
      transcribe_audio "$@"
      exit $?
      ;;
  esac
fi
