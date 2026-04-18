#!/bin/bash
# video-prerequisites.sh — 動画ハーネス用 前提条件チェック
#
# 使い方:
#   source .forge/lib/video-prerequisites.sh
#   check_video_prerequisites <work-dir>
#
# CLI:
#   bash .forge/lib/video-prerequisites.sh <work-dir>
#
# 戻り値:
#   0 = OK（WARN のみ/全項目満足）
#   1 = FAIL（非 CRITICAL の検証失敗。例: gitignore / disk / git 未初期化）
#   2 = CRITICAL（OneDrive 配下で実行しようとしている等。即中断すべき）
#
# チェック項目:
#   [C]   OneDrive 配下で動作させようとしていないか（abs path に 'OneDrive' を含まない）
#   [F]   git リポジトリとして初期化済み（git rev-parse --git-dir）
#   [F]   .gitignore に 'node_modules/' が記載されている
#   [F]   disk 残量 >= VPREREQ_MIN_DISK_GB（default 5GB）
#   [W]   .gitattributes に '* text=auto eol=lf' が設定されている（Windows 環境のみ）
#   [W]   development.json の server.start_command が 'none' に設定されている
#
# 制御用環境変数（主にテスト/CI 用）:
#   VPREREQ_MIN_DISK_GB        — disk 残量ゲートの最小値 GB（default 5）
#   VPREREQ_DISK_OVERRIDE_GB   — df の実測値を上書き（数値）。テスト決定性用。
#   VPREREQ_FORCE_WINDOWS      — 1=Windows 扱い / 0=非 Windows 扱いで .gitattributes 検証を強制
#   VPREREQ_DEV_JSON           — development.json のパスを上書き
#
# 設計方針:
#   - CRITICAL と FAIL と WARN を明確に分離（それぞれ CRITICAL: / FAIL: / WARN: prefix）
#   - 検査は全て走らせてから結果を集計（fail-fast しない）: ユーザーに全問題を一度に提示
#   - OneDrive 検出は case-insensitive の substring マッチ（パス区切り非依存）
#   - 外部プロジェクト作業時の誤爆防止: development.json は server.start_command='none'
#     を期待する（動画ハーネスでは HTTP サーバー不要）。違反時は WARN のみ。

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _VP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_VP_SCRIPT_DIR}/../.." && pwd)"
fi

# デフォルト閾値
VPREREQ_MIN_DISK_GB="${VPREREQ_MIN_DISK_GB:-5}"

# --- helper: 出力（stderr） ----------------------------------------------
_vp_err()  { echo "ERROR: $*" >&2; }
_vp_crit() { echo "CRITICAL: $*" >&2; }
_vp_fail() { echo "FAIL: $*" >&2; }
_vp_warn() { echo "WARN: $*" >&2; }
_vp_info() { echo "INFO: $*" >&2; }

# --- Windows 環境判定 ---------------------------------------------------
# VPREREQ_FORCE_WINDOWS で明示的に上書き可（1=Windows, 0=非Windows）
vp_is_windows() {
  case "${VPREREQ_FORCE_WINDOWS:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*) return 0 ;;
  esac
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

# --- disk 残量取得（GB, 整数） -----------------------------------------
# 戻り値: 標準出力に GB 値（整数）、取得不能なら空文字
vp_disk_free_gb() {
  local dir="$1"
  # テスト用オーバーライド（decimal も可だが整数比較のため整数に寄せる）
  if [ -n "${VPREREQ_DISK_OVERRIDE_GB:-}" ]; then
    # 整数部のみ取り出す（小数点以下は切り捨て）
    local ov="${VPREREQ_DISK_OVERRIDE_GB}"
    case "$ov" in
      *.*) ov="${ov%%.*}" ;;
    esac
    if [[ "$ov" =~ ^-?[0-9]+$ ]]; then
      echo "$ov"
      return 0
    fi
    echo ""
    return 1
  fi
  # df -P -k: POSIX 1K ブロック単位
  local kb
  kb=$(df -P -k "$dir" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d '\r')
  if [ -z "$kb" ] || ! [[ "$kb" =~ ^[0-9]+$ ]]; then
    echo ""
    return 1
  fi
  # kb -> gb（1024 * 1024 KB = 1 GB）
  echo $(( kb / 1024 / 1024 ))
  return 0
}

# --- 個別チェック: git リポジトリ初期化済み ------------------------------
vp_check_git_init() {
  local dir="$1"
  (cd "$dir" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1)
}

# --- 個別チェック: .gitignore に node_modules/ --------------------------
vp_check_gitignore_node_modules() {
  local dir="$1"
  local file="$dir/.gitignore"
  if [ ! -f "$file" ]; then
    return 1
  fi
  # 先頭に / 許容、末尾スラッシュ optional、前後 whitespace 許容。
  # コメント行 '# node_modules/' は弾く（^[[:space:]]*/?node_modules の形で行頭マッチ必須）。
  if grep -Eq '^[[:space:]]*/?node_modules/?[[:space:]]*$' "$file"; then
    return 0
  fi
  return 1
}

# --- 個別チェック: .gitattributes に eol=lf ------------------------------
vp_check_gitattributes_eol_lf() {
  local dir="$1"
  local file="$dir/.gitattributes"
  if [ ! -f "$file" ]; then
    return 1
  fi
  # "* text=auto eol=lf" を厳密にはスペース数柔軟に検出
  if grep -Eq '^\*[[:space:]]+text=auto[[:space:]]+eol=lf([[:space:]]|$)' "$file"; then
    return 0
  fi
  return 1
}

# --- 個別チェック: OneDrive 配下でない ---------------------------------
# 戻り値: 0=OneDrive 配下でない / 1=OneDrive 配下（CRITICAL）
vp_check_not_onedrive() {
  local dir="$1"
  local abs
  abs="$(cd "$dir" 2>/dev/null && pwd 2>/dev/null)" || abs="$dir"
  # lower-case して case-insensitive substring マッチ
  local lower
  lower="$(echo "$abs" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *onedrive*) return 1 ;;
  esac
  return 0
}

# --- 個別チェック: development.json の server.start_command = 'none' -----
vp_check_dev_json_server_none() {
  local file
  if [ -n "${VPREREQ_DEV_JSON:-}" ]; then
    file="$VPREREQ_DEV_JSON"
  else
    file="${PROJECT_ROOT}/.forge/config/development.json"
  fi
  if [ ! -f "$file" ]; then
    # development.json 不在は WARN 相当（呼び出し側で扱う）だが、ここでは 0 を返す
    # （=制約違反ではない）。不在検出は呼出側で実施。
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    # jq 不在なら判定不能。WARN を促すため非0 を返す（呼出側で WARN 表示）。
    return 2
  fi
  local cmd
  cmd="$(jq -r '.server.start_command // ""' "$file" 2>/dev/null | tr -d '\r')"
  if [ "$cmd" = "none" ]; then
    return 0
  fi
  return 1
}

# =========================================================================
# check_video_prerequisites <work-dir>
#   全前提条件チェックを集計し exit code を返す。
#   戻り値: 0=OK, 1=FAIL, 2=CRITICAL
# =========================================================================
check_video_prerequisites() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    _vp_err "check_video_prerequisites: work-dir argument is required"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    _vp_err "check_video_prerequisites: directory does not exist: '${dir}'"
    return 1
  fi

  local abs
  abs="$(cd "$dir" 2>/dev/null && pwd 2>/dev/null)" || abs="$dir"
  _vp_info "checking video prerequisites for: ${abs}"

  local criticals=0
  local failures=0
  local warnings=0

  # ---- [C] OneDrive パス混入 ---------------------------------------
  if ! vp_check_not_onedrive "$dir"; then
    _vp_crit "OneDrive path detected: '${abs}' — 動画ハーネスは OneDrive 同期フォルダ配下で動作させてはならない (file locking / CRLF / sync 衝突で中間成果物が壊れる)"
    criticals=$((criticals + 1))
  fi

  # ---- [F] git repo 初期化 -----------------------------------------
  if ! vp_check_git_init "$dir"; then
    _vp_fail "not a git repository: '${abs}' (must run 'git init' before launching the harness)"
    failures=$((failures + 1))
  fi

  # ---- [F] .gitignore に node_modules/ -----------------------------
  if ! vp_check_gitignore_node_modules "$dir"; then
    if [ ! -f "${dir}/.gitignore" ]; then
      _vp_fail ".gitignore missing in '${abs}' (required entry: 'node_modules/')"
    else
      _vp_fail ".gitignore in '${abs}' does not contain 'node_modules/' — Ralph Loop の保護ファイル検出で CRITICAL 違反になる"
    fi
    failures=$((failures + 1))
  fi

  # ---- [F] disk 残量 ------------------------------------------------
  local free_gb
  free_gb="$(vp_disk_free_gb "$dir")"
  if [ -z "$free_gb" ]; then
    _vp_warn "could not determine disk free space for '${abs}' — skipping disk-free check"
    warnings=$((warnings + 1))
  else
    # free_gb が負値や0 の場合も FAIL 扱い
    if ! [[ "$free_gb" =~ ^[0-9]+$ ]] || [ "$free_gb" -lt "$VPREREQ_MIN_DISK_GB" ]; then
      _vp_fail "disk free = ${free_gb}GB is below minimum ${VPREREQ_MIN_DISK_GB}GB at '${abs}'"
      failures=$((failures + 1))
    fi
  fi

  # ---- [W] .gitattributes eol=lf（Windows 環境のみ） -----------------
  if vp_is_windows; then
    if ! vp_check_gitattributes_eol_lf "$dir"; then
      if [ ! -f "${dir}/.gitattributes" ]; then
        _vp_warn ".gitattributes missing in '${abs}' (Windows: '* text=auto eol=lf' 推奨 — CRLF 変換で shell/テキスト成果物が壊れる可能性)"
      else
        _vp_warn ".gitattributes in '${abs}' does not declare '* text=auto eol=lf' (Windows 環境では CRLF 事故を避けるため設定推奨)"
      fi
      warnings=$((warnings + 1))
    fi
  fi

  # ---- [W] development.json server.start_command = 'none' -----------
  vp_check_dev_json_server_none
  local dev_rc=$?
  case "$dev_rc" in
    0) ;;  # OK
    1)
      local dev_file
      if [ -n "${VPREREQ_DEV_JSON:-}" ]; then
        dev_file="$VPREREQ_DEV_JSON"
      else
        dev_file="${PROJECT_ROOT}/.forge/config/development.json"
      fi
      _vp_warn "development.json の server.start_command が 'none' ではない (${dev_file}) — 動画ハーネスは HTTP サーバー不要。start_command='none' 設定を推奨"
      warnings=$((warnings + 1))
      ;;
    2)
      _vp_warn "jq が PATH にないため development.json の server.start_command を検査不能 — 手動確認してください"
      warnings=$((warnings + 1))
      ;;
  esac

  # ---- 集計 ---------------------------------------------------------
  if [ "$criticals" -gt 0 ]; then
    _vp_err "prerequisites check FAILED: ${criticals} CRITICAL, ${failures} FAIL, ${warnings} WARN"
    return 2
  fi
  if [ "$failures" -gt 0 ]; then
    _vp_err "prerequisites check FAILED: ${failures} FAIL, ${warnings} WARN"
    return 1
  fi
  if [ "$warnings" -gt 0 ]; then
    _vp_info "prerequisites check PASSED with ${warnings} WARN(s)"
  else
    _vp_info "prerequisites check PASSED (all checks clean)"
  fi
  return 0
}

# --- CLI エントリポイント -------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: bash $0 <work-dir>" >&2
    echo "  Env overrides:" >&2
    echo "    VPREREQ_MIN_DISK_GB       — minimum required disk free (GB, default 5)" >&2
    echo "    VPREREQ_DISK_OVERRIDE_GB  — mock disk free value (for tests)" >&2
    echo "    VPREREQ_FORCE_WINDOWS     — 1=Windows / 0=non-Windows force" >&2
    echo "    VPREREQ_DEV_JSON          — override development.json path" >&2
    exit 2
  fi
  check_video_prerequisites "$1"
  exit $?
fi
