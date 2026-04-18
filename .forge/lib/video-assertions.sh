#!/bin/bash
# video-assertions.sh — 動画ハーネス用 assertion 型チェッカー + 評価ロジック
#
# 使い方:
#   source .forge/lib/video-assertions.sh
#   evaluate_video_assertion <type> [args...]
#     type: ffprobe_exists | duration_check | size_threshold
#
# CLI 実行:
#   bash .forge/lib/video-assertions.sh <type> [args...]
#
# 戻り値:
#   0 = PASS
#   1 = FAIL（評価結果が不合格 / 引数エラー等）
#   2 = TypeError（未知の assertion type）
#   3 = Preflight failure（ffprobe が PATH に無い等の実行環境エラー）
#
# 依存: ffprobe (ffprobe_exists / duration_check のみ必要), awk, stat または wc
#
# 設計方針:
#   - 動画特有の 3 assertion を薄く実装（Forge 既存 assertions メカニズムの video ドメイン拡張）
#   - ffprobe が PATH に無い環境では assertion 実行前に明確なエラー (rc=3) で失敗する
#     （黙って誤検出 PASS / FAIL を返さない）
#   - 型チェッカー: evaluate_video_assertion の dispatcher が未知の type を rc=2 で拒否
#   - 各評価関数は単独呼び出し可 (evaluate_ffprobe_exists / _duration_check / _size_threshold)

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _VA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_VA_SCRIPT_DIR}/../.." && pwd)"
fi

# ffprobe デフォルトタイムアウト（秒）。長時間動画対策で呼出側が上書き可能。
FFPROBE_DEFAULT_TIMEOUT_SEC="${FFPROBE_DEFAULT_TIMEOUT_SEC:-60}"

# 許容 assertion type 一覧（dispatch テーブルと同期）
VIDEO_ASSERTION_TYPES=("ffprobe_exists" "duration_check" "size_threshold")

# --- helper: stderr 出力 -------------------------------------------------
_va_err()  { echo "ERROR: $*" >&2; }
_va_info() { echo "INFO: $*" >&2; }
_va_warn() { echo "WARNING: $*" >&2; }

# --- type checker: 既知 type か判定 --------------------------------------
# $1: type name → 0 if known, 1 if unknown
video_assertion_is_known_type() {
  local t="${1:-}"
  local known
  for known in "${VIDEO_ASSERTION_TYPES[@]}"; do
    if [ "$t" = "$known" ]; then
      return 0
    fi
  done
  return 1
}

# --- preflight: ffprobe が PATH に存在するか --------------------------------
# 戻り値: 0=OK, 1=ffprobe 不在
# 呼び出し側で評価実行前にチェックすることで、黙って誤判定を返さないようにする。
video_assertion_preflight() {
  if ! command -v ffprobe >/dev/null 2>&1; then
    _va_err "preflight failed: ffprobe not found in PATH — video assertions cannot run"
    return 1
  fi
  return 0
}

# --- ファイルサイズ取得（bytes, cross-OS） -------------------------------
# GNU stat → BSD stat → wc -c の順でフォールバック
_va_file_size() {
  local f="$1" sz=""
  if command -v stat >/dev/null 2>&1; then
    sz=$(stat -c '%s' "$f" 2>/dev/null || true)
    if [ -z "$sz" ]; then
      sz=$(stat -f '%z' "$f" 2>/dev/null || true)
    fi
  fi
  if [ -z "$sz" ]; then
    sz=$(wc -c <"$f" 2>/dev/null | tr -d ' \r\n' || true)
  fi
  echo "${sz:-0}"
}

# =========================================================================
# evaluate_ffprobe_exists <path>
#   ファイルが存在し、かつ ffprobe でパース可能なら PASS。
#   - ファイル不存在 → FAIL（明確なメッセージ）
#   - ffprobe 不在 → FAIL（preflight 相当）
#   - 非動画ファイル（ffprobe がパース不可）→ FAIL
# =========================================================================
evaluate_ffprobe_exists() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    _va_err "ffprobe_exists FAIL: path argument is required"
    return 1
  fi
  if [ ! -e "$path" ]; then
    _va_err "ffprobe_exists FAIL: file does not exist: '${path}'"
    return 1
  fi
  if [ ! -f "$path" ]; then
    _va_err "ffprobe_exists FAIL: path is not a regular file: '${path}'"
    return 1
  fi
  if ! command -v ffprobe >/dev/null 2>&1; then
    _va_err "ffprobe_exists FAIL: ffprobe not found in PATH (preflight)"
    return 1
  fi
  if ! ffprobe -v error -show_format "$path" >/dev/null 2>&1; then
    _va_err "ffprobe_exists FAIL: ffprobe could not parse file (not a valid media container): '${path}'"
    return 1
  fi
  _va_info "ffprobe_exists PASS: '${path}'"
  return 0
}

# =========================================================================
# evaluate_duration_check <path> <expected_sec> [tolerance_sec]
#   ffprobe で動画の duration を取得し、|actual - expected| <= tolerance なら PASS。
#   tolerance 未指定は 0（完全一致）。
# =========================================================================
evaluate_duration_check() {
  local path="${1:-}" expected="${2:-}" tolerance="${3:-0}"
  if [ -z "$path" ] || [ -z "$expected" ]; then
    _va_err "duration_check FAIL: path and expected arguments are required"
    return 1
  fi
  if [ ! -f "$path" ]; then
    _va_err "duration_check FAIL: file does not exist: '${path}'"
    return 1
  fi
  if ! command -v ffprobe >/dev/null 2>&1; then
    _va_err "duration_check FAIL: ffprobe not found in PATH (preflight)"
    return 1
  fi
  # expected / tolerance が数値か
  if ! awk -v v="$expected" 'BEGIN{ if (v+0==v+0 && v+0>=0) exit 0; else exit 1 }' 2>/dev/null; then
    _va_err "duration_check FAIL: expected must be a non-negative number (got '${expected}')"
    return 1
  fi
  if ! awk -v v="$tolerance" 'BEGIN{ if (v+0==v+0 && v+0>=0) exit 0; else exit 1 }' 2>/dev/null; then
    _va_err "duration_check FAIL: tolerance must be a non-negative number (got '${tolerance}')"
    return 1
  fi
  local actual
  actual=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$path" 2>/dev/null | tr -d '\r\n')
  if [ -z "$actual" ] || [ "$actual" = "N/A" ]; then
    _va_err "duration_check FAIL: could not determine duration of '${path}'"
    return 1
  fi
  if ! awk -v v="$actual" 'BEGIN{ if (v+0==v+0) exit 0; else exit 1 }' 2>/dev/null; then
    _va_err "duration_check FAIL: ffprobe returned non-numeric duration: '${actual}'"
    return 1
  fi
  local diff_abs
  diff_abs=$(awk -v a="$actual" -v b="$expected" 'BEGIN{d=a-b; if(d<0) d=-d; printf "%.6f", d}')
  if awk -v d="$diff_abs" -v t="$tolerance" 'BEGIN{exit !(d+0<=t+0)}'; then
    _va_info "duration_check PASS: actual=${actual}s expected=${expected}s diff=${diff_abs}s tolerance=${tolerance}s"
    return 0
  else
    _va_err "duration_check FAIL: actual=${actual}s expected=${expected}s diff=${diff_abs}s exceeds tolerance=${tolerance}s"
    return 1
  fi
}

# =========================================================================
# evaluate_size_threshold <path> <min_bytes> [max_bytes]
#   ファイルサイズが min_bytes 以上（かつ max_bytes 指定時は以下）なら PASS。
#   ffprobe 不要（stat/wc でサイズ取得）。
# =========================================================================
evaluate_size_threshold() {
  local path="${1:-}" min_bytes="${2:-}" max_bytes="${3:-}"
  if [ -z "$path" ] || [ -z "$min_bytes" ]; then
    _va_err "size_threshold FAIL: path and min_bytes arguments are required"
    return 1
  fi
  if [ ! -f "$path" ]; then
    _va_err "size_threshold FAIL: file does not exist: '${path}'"
    return 1
  fi
  if ! awk -v v="$min_bytes" 'BEGIN{ if (v+0==v+0 && v+0>=0) exit 0; else exit 1 }' 2>/dev/null; then
    _va_err "size_threshold FAIL: min_bytes must be a non-negative number (got '${min_bytes}')"
    return 1
  fi
  if [ -n "$max_bytes" ]; then
    if ! awk -v v="$max_bytes" 'BEGIN{ if (v+0==v+0 && v+0>=0) exit 0; else exit 1 }' 2>/dev/null; then
      _va_err "size_threshold FAIL: max_bytes must be a non-negative number (got '${max_bytes}')"
      return 1
    fi
  fi
  local sz
  sz=$(_va_file_size "$path")
  if [ -z "$sz" ] || ! [[ "$sz" =~ ^[0-9]+$ ]]; then
    _va_err "size_threshold FAIL: could not determine file size of '${path}' (got '${sz}')"
    return 1
  fi
  if awk -v s="$sz" -v m="$min_bytes" 'BEGIN{exit !(s+0<m+0)}'; then
    _va_err "size_threshold FAIL: size=${sz} bytes is below min_bytes=${min_bytes} for '${path}'"
    return 1
  fi
  if [ -n "$max_bytes" ]; then
    if awk -v s="$sz" -v m="$max_bytes" 'BEGIN{exit !(s+0>m+0)}'; then
      _va_err "size_threshold FAIL: size=${sz} bytes exceeds max_bytes=${max_bytes} for '${path}'"
      return 1
    fi
  fi
  _va_info "size_threshold PASS: size=${sz} bytes (min_bytes=${min_bytes}${max_bytes:+, max_bytes=${max_bytes}}) for '${path}'"
  return 0
}

# =========================================================================
# evaluate_video_assertion <type> [args...]
#   Dispatcher: 型チェック + ffprobe preflight + 個別評価関数への委譲。
#   戻り値: 0=PASS, 1=FAIL, 2=TypeError, 3=Preflight failed
# =========================================================================
evaluate_video_assertion() {
  local type="${1:-}"
  if [ -z "$type" ]; then
    _va_err "TypeError: assertion type argument is required (allowed: ${VIDEO_ASSERTION_TYPES[*]})"
    return 2
  fi
  shift
  if ! video_assertion_is_known_type "$type"; then
    _va_err "TypeError: unknown assertion type '${type}' (allowed: ${VIDEO_ASSERTION_TYPES[*]})"
    return 2
  fi
  # preflight: ffprobe 必要型は事前に PATH チェックして rc=3 で早期失敗
  case "$type" in
    ffprobe_exists|duration_check)
      if ! command -v ffprobe >/dev/null 2>&1; then
        _va_err "preflight failed: ffprobe not found in PATH — cannot evaluate '${type}' (assertion not executed)"
        return 3
      fi
      ;;
  esac
  case "$type" in
    ffprobe_exists) evaluate_ffprobe_exists "$@" ;;
    duration_check) evaluate_duration_check "$@" ;;
    size_threshold) evaluate_size_threshold "$@" ;;
  esac
}

# --- CLI エントリポイント -------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: bash $0 <type> [args...]" >&2
    echo "  types: ${VIDEO_ASSERTION_TYPES[*]}" >&2
    echo "  ffprobe_exists <path>" >&2
    echo "  duration_check <path> <expected_sec> [tolerance_sec]" >&2
    echo "  size_threshold <path> <min_bytes> [max_bytes]" >&2
    exit 2
  fi
  evaluate_video_assertion "$@"
  exit $?
fi
