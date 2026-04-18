#!/bin/bash
# run-quality-gates.sh — 全シナリオの quality_gates.required_mechanical_gates[] を一括実行するランナー
#
# 使い方:
#   bash .forge/lib/run-quality-gates.sh <scenarios_dir>       # scenarios/*/scenario.json を走査
#   bash .forge/lib/run-quality-gates.sh --scenario <file>     # 単一 scenario.json を対象
#   bash .forge/lib/run-quality-gates.sh --help
#
# 入力: scenario.json (scenario-schema.json 準拠)
#   .quality_gates.required_mechanical_gates[] = [{id, command, expect, blocking}, ...]
#
# 実行セマンティクス:
#   - 各 gate の command を PROJECT_ROOT で bash -c 実行
#   - exit code を expect ("exit 0" / "exit 1" / 数値のみ) と比較
#   - 不一致かつ blocking=true → scenario FAIL / blocking=false → 警告 (全体 PASS)
#   - 各 gate の結果を PASS/✗/! で出力し、FAIL 時は stderr 出力先頭 4 行をプレビュー
#
# Exit codes:
#   0  全シナリオの blocking gate が PASS（invalid/fail 無し）
#   1  1 つ以上の blocking gate が FAIL、または scenario 構造が invalid
#   2  引数/使用法エラー
#   3  preflight エラー（jq 等の依存不在）
#
# 依存: jq, bash
# 参照: .forge/lib/quality-gate-validator.sh (構造バリデーション側と enum 同期)
#       .forge/lib/video-assertions.sh (典型的な gate command が呼出す評価ライブラリ)

set -uo pipefail

# PROJECT_ROOT 推定
if [ -z "${PROJECT_ROOT:-}" ]; then
  _RQG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_RQG_SCRIPT_DIR}/../.." && pwd)"
fi

# ANSI colors (terminal でなくても不快にならないよう必要最小限)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- helpers --------------------------------------------------------------
_rqg_info() { echo -e "${CYAN}INFO:${NC} $*" >&2; }
_rqg_warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
_rqg_err()  { echo -e "${RED}ERROR:${NC} $*" >&2; }

_rqg_usage() {
  cat >&2 <<EOF
Usage: bash $0 <scenarios_dir>
   or: bash $0 --scenario <scenario.json>

Executes all quality_gates.required_mechanical_gates[] commands across scenarios
and reports pass/fail. Gate commands are executed from PROJECT_ROOT.

Exit codes:
  0  all blocking gates passed
  1  one or more blocking gates failed (or invalid scenario structure)
  2  argument / usage error
  3  preflight error (missing dependencies, e.g. jq)
EOF
}

# "expect" → 期待 exit code の数値を標準出力（default 0）
_rqg_parse_expected_code() {
  local ex="${1:-}"
  if [ -z "$ex" ]; then echo 0; return; fi
  local n
  n=$(echo "$ex" | tr -d '[:space:]' | sed -E 's/^[Ee][Xx][Ii][Tt]//')
  if [[ "$n" =~ ^[0-9]+$ ]]; then echo "$n"; else echo 0; fi
}

# --- 単一 gate の実行 ----------------------------------------------------
# $1=scen_id $2=gate_index $3=gate JSON(1 object)
# グローバル counters (RQG_PASS/RQG_FAIL/RQG_WARN/RQG_INVALID) を更新
# 戻り値: 0=この gate で blocking-fail なし, 1=blocking-fail 発生
_rqg_run_gate() {
  local scen_id="$1" idx="$2" gate_json="$3"
  local gate_id gate_desc gate_cmd gate_expect gate_blocking
  gate_id=$(echo "$gate_json"      | jq -r '.id // "gate-'"$idx"'"' 2>/dev/null | tr -d '\r')
  gate_desc=$(echo "$gate_json"    | jq -r '.description // ""'    2>/dev/null | tr -d '\r')
  gate_cmd=$(echo "$gate_json"     | jq -r '.command // ""'        2>/dev/null | tr -d '\r')
  gate_expect=$(echo "$gate_json"  | jq -r '.expect // "exit 0"'   2>/dev/null | tr -d '\r')
  # NOTE: jq の `//` は `false` も empty 扱いするため、.blocking=false が true に化ける。
  # 明示的に has("blocking") で分岐してデフォルト true を適用する。
  gate_blocking=$(echo "$gate_json"| jq -r 'if has("blocking") then .blocking else true end' 2>/dev/null | tr -d '\r')

  if [ -z "$gate_cmd" ]; then
    _rqg_err "[${scen_id}] gate[${idx}] '${gate_id}' has empty .command — invalid"
    RQG_INVALID=$((RQG_INVALID + 1))
    [ "$gate_blocking" = "true" ] && return 1 || return 0
  fi

  local expected_code out actual_rc
  expected_code=$(_rqg_parse_expected_code "$gate_expect")
  # PROJECT_ROOT で gate command を実行（scenario.json の相対パス前提）。
  # 2>&1 で出力を全キャプチャし、FAIL 時に stderr プレビューとして再表示する。
  out=$(cd "$PROJECT_ROOT" && bash -c "$gate_cmd" 2>&1)
  actual_rc=$?

  if [ "$actual_rc" = "$expected_code" ]; then
    echo -e "    ${GREEN}${NC} [${scen_id}] gate[${idx}] ${gate_id}: PASS ${DIM}(expect=${gate_expect}, rc=${actual_rc})${NC}"
    RQG_PASS=$((RQG_PASS + 1))
    return 0
  fi

  # mismatch: FAIL — 出力プレビューを添える
  local preview
  preview=$(echo "$out" | head -n 4 | sed 's/^/      /')
  if [ "$gate_blocking" = "true" ]; then
    echo -e "    ${RED}${NC} [${scen_id}] gate[${idx}] ${gate_id}: FAIL ${DIM}(expect=${gate_expect}, rc=${actual_rc})${NC}"
    [ -n "$gate_desc" ] && echo -e "      ${DIM}desc: ${gate_desc}${NC}"
    [ -n "$preview" ]   && echo -e "${YELLOW}${preview}${NC}" >&2
    RQG_FAIL=$((RQG_FAIL + 1))
    return 1
  else
    echo -e "    ${YELLOW}!${NC} [${scen_id}] gate[${idx}] ${gate_id}: FAIL (non-blocking) ${DIM}(expect=${gate_expect}, rc=${actual_rc})${NC}"
    [ -n "$preview" ]   && echo -e "${DIM}${preview}${NC}" >&2
    RQG_WARN=$((RQG_WARN + 1))
    return 0
  fi
}

# --- 単一シナリオ実行 ----------------------------------------------------
# $1: scenario.json path
# 戻り値: 0=scenario PASS(全 blocking OK), 1=scenario FAIL or invalid
run_scenario_gates() {
  local scen_file="$1" scen_id gates_len
  if [ ! -f "$scen_file" ]; then
    _rqg_err "scenario file not found: $scen_file"
    RQG_INVALID=$((RQG_INVALID + 1))
    return 1
  fi
  if ! jq empty "$scen_file" >/dev/null 2>&1; then
    _rqg_err "scenario.json is not valid JSON: $scen_file"
    RQG_INVALID=$((RQG_INVALID + 1))
    return 1
  fi
  scen_id=$(jq -r '.id // "(unknown)"' "$scen_file" 2>/dev/null | tr -d '\r')

  if ! jq -e '.quality_gates.required_mechanical_gates' "$scen_file" >/dev/null 2>&1; then
    _rqg_err "[${scen_id}] quality_gates.required_mechanical_gates missing in $scen_file"
    RQG_INVALID=$((RQG_INVALID + 1))
    return 1
  fi
  gates_len=$(jq '.quality_gates.required_mechanical_gates | length' "$scen_file" 2>/dev/null | tr -d '\r')
  if [ "${gates_len:-0}" -lt 1 ]; then
    _rqg_err "[${scen_id}] required_mechanical_gates is empty not allowed (minItems: 1): $scen_file"
    RQG_INVALID=$((RQG_INVALID + 1))
    return 1
  fi

  echo -e "${BOLD}[scenario] ${scen_id}${NC} ${DIM}(${gates_len} gate(s), ${scen_file})${NC}"
  RQG_SCENARIOS=$((RQG_SCENARIOS + 1))

  local any_fail=0 i=0 gate_json
  while [ "$i" -lt "$gates_len" ]; do
    gate_json=$(jq -c ".quality_gates.required_mechanical_gates[$i]" "$scen_file" 2>/dev/null)
    if ! _rqg_run_gate "$scen_id" "$i" "$gate_json"; then
      any_fail=1
    fi
    i=$((i + 1))
  done

  if [ "$any_fail" -ne 0 ]; then
    echo -e "  ${RED}scenario ${scen_id}: FAIL${NC}"
    RQG_SCEN_FAIL=$((RQG_SCEN_FAIL + 1))
    return 1
  fi
  echo -e "  ${GREEN}scenario ${scen_id}: PASS${NC}"
  RQG_SCEN_PASS=$((RQG_SCEN_PASS + 1))
  return 0
}

# --- メインエントリ ------------------------------------------------------
main() {
  RQG_SCENARIOS=0; RQG_SCEN_PASS=0; RQG_SCEN_FAIL=0
  RQG_PASS=0; RQG_FAIL=0; RQG_WARN=0; RQG_INVALID=0

  if ! command -v jq >/dev/null 2>&1; then
    _rqg_err "preflight failed: jq not found in PATH (required for scenario parsing)"
    return 3
  fi

  if [ "$#" -lt 1 ]; then
    _rqg_usage
    return 2
  fi

  local mode="dir" arg=""
  case "$1" in
    --help|-h) _rqg_usage; return 0 ;;
    --scenario)
      mode="file"; arg="${2:-}"
      [ -z "$arg" ] && { _rqg_err "--scenario requires a file path"; _rqg_usage; return 2; }
      ;;
    *) mode="dir"; arg="$1" ;;
  esac

  local overall=0
  if [ "$mode" = "file" ]; then
    if [ ! -f "$arg" ]; then
      _rqg_err "scenario file not found: $arg"
      return 2
    fi
    run_scenario_gates "$arg" || overall=1
  else
    if [ ! -d "$arg" ]; then
      _rqg_err "scenarios directory not found: $arg"
      return 2
    fi
    local found=0 scen_json
    shopt -s nullglob
    for scen_json in "$arg"/*/scenario.json; do
      found=1
      run_scenario_gates "$scen_json" || overall=1
    done
    shopt -u nullglob
    if [ "$found" -eq 0 ]; then
      _rqg_warn "no scenario.json files found under $arg"
    fi
  fi

  # サマリー
  echo ""
  echo -e "${BOLD}=== Quality Gates Summary ===${NC}"
  echo -e "  scenarios: ${RQG_SCENARIOS} (${GREEN}pass:${RQG_SCEN_PASS}${NC} / ${RED}fail:${RQG_SCEN_FAIL}${NC})"
  echo -e "  gates    : ${GREEN}pass:${RQG_PASS}${NC}  ${RED}fail:${RQG_FAIL}${NC}  ${YELLOW}warn:${RQG_WARN}${NC}  invalid:${RQG_INVALID}"
  if [ "$overall" -ne 0 ] || [ "${RQG_INVALID:-0}" -gt 0 ] || [ "${RQG_FAIL:-0}" -gt 0 ]; then
    echo -e "${BOLD}${RED}OVERALL: FAIL${NC}"
    return 1
  fi
  echo -e "${BOLD}${GREEN}OVERALL: PASS${NC}"
  return 0
}

# CLI エントリポイント
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
