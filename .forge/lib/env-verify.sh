#!/bin/bash
# env-verify.sh — 動画ハーネス用 CLI ツール環境検証
#
# 使い方:
#   source .forge/lib/env-verify.sh
#   check_video_env [work-dir]
#
# CLI:
#   bash .forge/lib/env-verify.sh [work-dir]
#
# 戻り値:
#   0 = OK（全ツール検出、バージョン要件を満たす。WARN は許容）
#   1 = FAIL（必須ツール欠落 または バージョン不足）
#
# チェック項目:
#   [F] ffmpeg  CLI PATH + version >= ENVV_FFMPEG_MIN（default 6.0）
#   [F] ffprobe CLI PATH（バージョン非必須）
#   [F] convert CLI PATH（ImageMagick）
#   [F] jq      CLI PATH
#   [W] development.json の server.start_command が 'none' でない（動画ハーネスでは不要）
#
# 環境変数（主にテスト/CI 用）:
#   ENVV_FFMPEG_BIN   — ffmpeg バイナリパス上書き（default: ffmpeg, PATH 検索）
#   ENVV_FFPROBE_BIN  — ffprobe バイナリパス上書き
#   ENVV_CONVERT_BIN  — convert バイナリパス上書き
#   ENVV_JQ_BIN       — jq バイナリパス上書き
#   ENVV_FFMPEG_MIN   — ffmpeg 最小バージョン（default 6.0）
#   ENVV_DEV_JSON     — development.json のパス上書き
#
# 設計方針:
#   - FAIL / WARN / OK を prefix で分離（行頭文字列マッチで判定可能）
#   - 検査は全て走らせてから結果を集計（fail-fast しない）
#   - ffmpeg バージョンは major.minor 比較（patch suffix 無視、'n' prefix 許容）

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _EV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_EV_SCRIPT_DIR}/../.." && pwd)"
fi

# デフォルト最小バージョン
ENVV_FFMPEG_MIN="${ENVV_FFMPEG_MIN:-6.0}"

# --- helper: 出力（stderr） --------------------------------------------
_ev_err()  { echo "ERROR: $*" >&2; }
_ev_fail() { echo "FAIL: $*" >&2; }
_ev_warn() { echo "WARN: $*" >&2; }
_ev_info() { echo "INFO: $*" >&2; }
_ev_ok()   { echo "OK: $*" >&2; }

# --- helper: バイナリ解決（絶対パス / PATH 検索どちらも対応） ----------
# 戻り値: 0=解決成功（stdout に絶対パス） / 1=未検出 or 非実行可
_ev_resolve_bin() {
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
    echo "$resolved"
    return 0
  fi
  return 1
}

# --- version 比較: A >= B （"major.minor[.patch][-suffix]" 形式） ------
ev_version_ge() {
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

# --- ffmpeg バージョン抽出 --------------------------------------------
# 例: "ffmpeg version 6.1.1-0ubuntu1 Copyright..." → "6.1.1"
# 例: "ffmpeg version n6.0 Copyright..."          → "6.0"
# 解析不能時は空文字 + return 1
ev_extract_ffmpeg_version() {
  local bin="$1"
  local out first_line ver
  out="$("$bin" -version 2>&1)" || true
  first_line="${out%%$'\n'*}"
  ver="$(printf '%s\n' "$first_line" | sed -E 's/^ffmpeg version n?([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
  if [ -z "$ver" ] || [ "$ver" = "$first_line" ]; then
    echo ""
    return 1
  fi
  echo "$ver"
  return 0
}

# --- 個別チェック: ffmpeg ---------------------------------------------
ev_check_ffmpeg() {
  local bin_spec="${ENVV_FFMPEG_BIN:-ffmpeg}"
  local bin
  if ! bin="$(_ev_resolve_bin "$bin_spec")"; then
    _ev_fail "ffmpeg not found (searched: '$bin_spec') — please install ffmpeg >= ${ENVV_FFMPEG_MIN}"
    return 1
  fi
  local ver
  ver="$(ev_extract_ffmpeg_version "$bin")"
  if [ -z "$ver" ]; then
    _ev_fail "ffmpeg version could not be parsed from '$bin -version'"
    return 1
  fi
  if ! ev_version_ge "$ver" "$ENVV_FFMPEG_MIN"; then
    _ev_fail "ffmpeg version ${ver} < required ${ENVV_FFMPEG_MIN} (bin: '$bin')"
    return 1
  fi
  _ev_ok "ffmpeg ${ver} (>= ${ENVV_FFMPEG_MIN}) at '$bin'"
  return 0
}

# --- 個別チェック: ffprobe --------------------------------------------
ev_check_ffprobe() {
  local bin_spec="${ENVV_FFPROBE_BIN:-ffprobe}"
  local bin
  if ! bin="$(_ev_resolve_bin "$bin_spec")"; then
    _ev_fail "ffprobe not found (searched: '$bin_spec') — ffmpeg バンドル付属の ffprobe が PATH に必要"
    return 1
  fi
  _ev_ok "ffprobe at '$bin'"
  return 0
}

# --- 個別チェック: convert (ImageMagick) ------------------------------
ev_check_convert() {
  local bin_spec="${ENVV_CONVERT_BIN:-convert}"
  local bin
  if ! bin="$(_ev_resolve_bin "$bin_spec")"; then
    _ev_fail "convert (ImageMagick) not found (searched: '$bin_spec')"
    return 1
  fi
  _ev_ok "convert at '$bin'"
  return 0
}

# --- 個別チェック: jq --------------------------------------------------
ev_check_jq() {
  local bin_spec="${ENVV_JQ_BIN:-jq}"
  local bin
  if ! bin="$(_ev_resolve_bin "$bin_spec")"; then
    _ev_fail "jq not found (searched: '$bin_spec')"
    return 1
  fi
  _ev_ok "jq at '$bin'"
  return 0
}

# --- 個別チェック: development.json server.start_command == 'none' -----
# 戻り値: 0=OK / 1=not 'none' / 2=jq 不在 / 3=file 不在
ev_check_dev_json_server_none() {
  local file
  if [ -n "${ENVV_DEV_JSON:-}" ]; then
    file="$ENVV_DEV_JSON"
  else
    file="${PROJECT_ROOT}/.forge/config/development.json"
  fi
  if [ ! -f "$file" ]; then
    return 3
  fi
  local jq_spec="${ENVV_JQ_BIN:-jq}"
  local jq_bin
  if ! jq_bin="$(_ev_resolve_bin "$jq_spec")"; then
    return 2
  fi
  local cmd
  cmd="$("$jq_bin" -r '.server.start_command // ""' "$file" 2>/dev/null | tr -d '\r')"
  if [ "$cmd" = "none" ]; then
    return 0
  fi
  return 1
}

# =========================================================================
# check_video_env [work-dir?]
#   ffmpeg / ffprobe / convert / jq の存在とバージョンを集計し exit code を返す。
#   戻り値: 0=OK, 1=FAIL
#   work-dir 引数は現状スキップ対応（将来の拡張余地）。development.json は
#   ENVV_DEV_JSON または $PROJECT_ROOT/.forge/config/development.json を使用。
# =========================================================================
check_video_env() {
  _ev_info "checking video environment tools (ffmpeg>=${ENVV_FFMPEG_MIN}, ffprobe, convert, jq)"

  local failures=0
  local warnings=0

  ev_check_ffmpeg   || failures=$((failures + 1))
  ev_check_ffprobe  || failures=$((failures + 1))
  ev_check_convert  || failures=$((failures + 1))
  ev_check_jq       || failures=$((failures + 1))

  # ---- [W] development.json server.start_command = 'none' -----------
  ev_check_dev_json_server_none
  local dev_rc=$?
  case "$dev_rc" in
    0) ;;
    1)
      local dev_file
      if [ -n "${ENVV_DEV_JSON:-}" ]; then
        dev_file="$ENVV_DEV_JSON"
      else
        dev_file="${PROJECT_ROOT}/.forge/config/development.json"
      fi
      _ev_warn "development.json の server.start_command が 'none' ではない (${dev_file}) — 動画ハーネスでは HTTP サーバー不要。start_command='none' 推奨"
      warnings=$((warnings + 1))
      ;;
    2)
      _ev_warn "jq が利用不能なため development.json の server.start_command を検査不能"
      warnings=$((warnings + 1))
      ;;
    3)
      local dev_file
      if [ -n "${ENVV_DEV_JSON:-}" ]; then
        dev_file="$ENVV_DEV_JSON"
      else
        dev_file="${PROJECT_ROOT}/.forge/config/development.json"
      fi
      _ev_warn "development.json が見つかりません (${dev_file}) — 検査スキップ"
      warnings=$((warnings + 1))
      ;;
  esac

  # ---- 集計 ---------------------------------------------------------
  if [ "$failures" -gt 0 ]; then
    _ev_err "env verification FAILED: ${failures} FAIL, ${warnings} WARN"
    return 1
  fi
  if [ "$warnings" -gt 0 ]; then
    _ev_info "env verification PASSED with ${warnings} WARN(s)"
  else
    _ev_info "env verification PASSED (all tools available)"
  fi
  return 0
}

# 後方互換エイリアス: required_behaviors が check_video_prerequisites を
# 参照するため、env-verify.sh 経由で呼ばれた時は env 検査にフォワード。
# video-prerequisites.sh の同名関数とは別名ではなく、source した方が有効
# になる（呼び分けは呼び出し元の責務）。
check_video_prerequisites() {
  check_video_env "$@"
}

# --- CLI エントリポイント -------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  check_video_env "$@"
  exit $?
fi
