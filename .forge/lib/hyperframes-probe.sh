#!/bin/bash
# hyperframes-probe.sh — hyperframes CLI + Node.js 22+ optional 依存検出
#
# 使い方:
#   source .forge/lib/hyperframes-probe.sh
#   probe_hyperframes           # 結果を stdout（SELECTED_SCENARIO=...）/ stderr（診断）に出す
#   hfp_resolve_mode            # "hyperframes" or "mock" を stdout に返す
#
# CLI:
#   bash .forge/lib/hyperframes-probe.sh [--json]
#
# 戻り値:
#   0 = 常に（optional 依存のため、検出失敗は FAIL ではなく fallback）
#   1 = 前提欠落（jq 等、検出以前の問題）
#
# 設計方針:
#   - hyperframes CLI と Node.js 22+ は optional 依存 — 欠落時は WARN で mock に降格
#   - AI-avatar プラグインは scenarios/ai-avatar/mock_runner.sh に自動フォールバック
#   - 結果行:
#       SELECTED_SCENARIO=hyperframes   （両方揃った場合）
#       SELECTED_SCENARIO=mock          （いずれか欠落 → mock フォールバック）
#   - development.json server.start_command != 'none' → WARN（動画ハーネスでは不要）
#   - fail-fast しない — 全項目検査後に集計
#
# 環境変数:
#   HFP_NODE_BIN        — node バイナリ上書き（default: node, PATH 検索）
#   HFP_HYPERFRAMES_BIN — hyperframes CLI 上書き（default: hyperframes）
#   HFP_NODE_MIN        — Node.js 最小バージョン（default: 22.0）
#   HFP_DEV_JSON        — development.json パス上書き
#   HFP_JQ_BIN          — jq バイナリ上書き（default: jq）

set -uo pipefail

# PROJECT_ROOT 推定
if [ -z "${PROJECT_ROOT:-}" ]; then
  _HFP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_HFP_SCRIPT_DIR}/../.." && pwd)"
fi

HFP_NODE_MIN="${HFP_NODE_MIN:-22.0}"

# --- helper: 出力（stderr） --------------------------------------------
_hfp_err()  { echo "ERROR: $*" >&2; }
_hfp_fail() { echo "FAIL: $*" >&2; }
_hfp_warn() { echo "WARN: $*" >&2; }
_hfp_info() { echo "INFO: $*" >&2; }
_hfp_ok()   { echo "OK: $*" >&2; }
_hfp_skip() { echo "SKIP: $*" >&2; }

# --- helper: バイナリ解決 ----------------------------------------------
_hfp_resolve_bin() {
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

# --- version 比較: A >= B （"[v]major.minor[.patch]" 形式） -----------
hfp_version_ge() {
  local a="$1" b="$2"
  a="${a#v}"
  b="${b#v}"
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

# --- Node.js バージョン抽出 -------------------------------------------
# 例: "v22.3.0" → "22.3.0", "v18.17.0" → "18.17.0"
hfp_extract_node_version() {
  local bin="$1"
  local out ver
  out="$("$bin" --version 2>&1 | head -n1)" || return 1
  ver="$(printf '%s\n' "$out" | sed -E 's/^v?([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
  if [ -z "$ver" ] || [ "$ver" = "$out" ]; then
    echo ""
    return 1
  fi
  echo "$ver"
  return 0
}

# --- 個別チェック: Node.js --------------------------------------------
# 戻り値: 0=OK, 1=not found, 2=version too old, 3=parse error
hfp_check_node() {
  local bin_spec="${HFP_NODE_BIN:-node}"
  local bin
  if ! bin="$(_hfp_resolve_bin "$bin_spec")"; then
    _hfp_warn "node not found (searched: '$bin_spec') — hyperframes CLI は Node.js ${HFP_NODE_MIN}+ 必須"
    return 1
  fi
  local ver
  ver="$(hfp_extract_node_version "$bin")"
  if [ -z "$ver" ]; then
    _hfp_warn "node version could not be parsed from '$bin --version'"
    return 3
  fi
  if ! hfp_version_ge "$ver" "$HFP_NODE_MIN"; then
    _hfp_warn "node version ${ver} < required ${HFP_NODE_MIN} (bin: '$bin') — hyperframes 不可、mock にフォールバック"
    return 2
  fi
  _hfp_ok "node ${ver} (>= ${HFP_NODE_MIN}) at '$bin'"
  return 0
}

# --- 個別チェック: hyperframes CLI ------------------------------------
# 戻り値: 0=OK, 1=not found
hfp_check_hyperframes_cli() {
  local bin_spec="${HFP_HYPERFRAMES_BIN:-hyperframes}"
  local bin
  if ! bin="$(_hfp_resolve_bin "$bin_spec")"; then
    _hfp_warn "hyperframes CLI not found (searched: '$bin_spec') — optional 依存のため mock へフォールバック"
    return 1
  fi
  _hfp_ok "hyperframes CLI at '$bin'"
  return 0
}

# --- 個別チェック: development.json server.start_command == 'none' ----
# 戻り値: 0=OK(='none'), 1=not 'none', 2=jq 不在, 3=file 不在
hfp_check_dev_json_server_none() {
  local file
  if [ -n "${HFP_DEV_JSON:-}" ]; then
    file="$HFP_DEV_JSON"
  else
    file="${PROJECT_ROOT}/.forge/config/development.json"
  fi
  if [ ! -f "$file" ]; then
    return 3
  fi
  local jq_spec="${HFP_JQ_BIN:-jq}"
  local jq_bin
  if ! jq_bin="$(_hfp_resolve_bin "$jq_spec")"; then
    return 2
  fi
  local cmd
  cmd="$("$jq_bin" -r '.server.start_command // ""' "$file" 2>/dev/null | tr -d '\r')"
  if [ "$cmd" = "none" ]; then
    return 0
  fi
  return 1
}

# --- hfp_resolve_mode ---------------------------------------------------
# node>=22 + hyperframes CLI の両方揃えば "hyperframes"、それ以外は "mock"
# stderr には診断行が出る（OK/WARN）、stdout にはモード文字列のみ
hfp_resolve_mode() {
  local node_rc=0 hf_rc=0
  hfp_check_node || node_rc=$?
  hfp_check_hyperframes_cli || hf_rc=$?
  if [ "$node_rc" -eq 0 ] && [ "$hf_rc" -eq 0 ]; then
    echo "hyperframes"
  else
    echo "mock"
  fi
}

# =========================================================================
# probe_hyperframes
#   optional 依存（Node.js 22+ + hyperframes CLI）を検出し、ai-avatar の
#   シナリオ選択を決定する。detection 失敗は FAIL ではなく WARN + mock
#   フォールバックとして扱う。
# =========================================================================
probe_hyperframes() {
  _hfp_info "probing optional hyperframes dependency (node>=${HFP_NODE_MIN} + hyperframes CLI)"

  local warnings=0
  local node_rc=0 hf_rc=0

  hfp_check_node               || node_rc=$?
  hfp_check_hyperframes_cli    || hf_rc=$?
  [ "$node_rc" -ne 0 ] && warnings=$((warnings + 1))
  [ "$hf_rc" -ne 0 ]   && warnings=$((warnings + 1))

  # ---- [W] development.json server.start_command == 'none' ----------
  hfp_check_dev_json_server_none
  local dev_rc=$?
  local dev_file
  if [ -n "${HFP_DEV_JSON:-}" ]; then
    dev_file="$HFP_DEV_JSON"
  else
    dev_file="${PROJECT_ROOT}/.forge/config/development.json"
  fi
  case "$dev_rc" in
    0) ;;
    1)
      _hfp_warn "development.json の server.start_command が 'none' ではない (${dev_file}) — 動画ハーネスでは HTTP サーバー不要。start_command='none' 推奨"
      warnings=$((warnings + 1))
      ;;
    2)
      _hfp_warn "jq が利用不能なため development.json の server.start_command を検査不能"
      warnings=$((warnings + 1))
      ;;
    3)
      _hfp_warn "development.json が見つかりません (${dev_file}) — 検査スキップ"
      warnings=$((warnings + 1))
      ;;
  esac

  # ---- モード決定 ---------------------------------------------------
  local mode
  if [ "$node_rc" -eq 0 ] && [ "$hf_rc" -eq 0 ]; then
    mode="hyperframes"
    _hfp_info "hyperframes 検出 OK — AI-avatar を hyperframes 版で実行"
  else
    mode="mock"
    _hfp_skip "hyperframes 未検出 (node_rc=${node_rc}, cli_rc=${hf_rc}) — ai-avatar/mock_runner.sh に fallback（mock フォールバック）"
  fi

  # 結果行（stdout）— 呼び出し側がパースできるよう 1 行で出す
  echo "SELECTED_SCENARIO=${mode}"

  _hfp_info "hyperframes probe done (${warnings} WARN)"
  return 0
}

# 後方互換: check_hyperframes_optional として公開
check_hyperframes_optional() {
  probe_hyperframes "$@"
}

# --- CLI エントリポイント -------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  probe_hyperframes "$@"
  exit $?
fi
