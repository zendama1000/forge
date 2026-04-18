#!/bin/bash
# scenario-validator.sh — scenarios/{id}/scenario.json バリデータ
#
# 使い方:
#   source .forge/lib/scenario-validator.sh
#   validate_scenario_json <path/to/scenario.json>            # 検証のみ
#   validate_scenario_json <path/to/scenario.json> <schema>   # スキーマパス明示
#
# CLI 実行:
#   bash .forge/lib/scenario-validator.sh <path/to/scenario.json>
#
# 依存: jq
#
# 設計方針:
#   ajv などの JSON Schema validator は harness 依存に含まれないため、
#   jq で機械的に必須項目/型/enum/非空を検査する薄い validator を自前実装。
#   スキーマ定義ファイルは enum 値の単一情報源として参照する。

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _SV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_SV_SCRIPT_DIR}/../.." && pwd)"
fi

# デフォルトスキーマパス
SCENARIO_SCHEMA_DEFAULT="${PROJECT_ROOT}/.forge/schemas/scenario-schema.json"

# --- helper: エラー出力（stderr） ----------------------------------------
_sv_err() {
  echo "ERROR: $*" >&2
}

_sv_info() {
  echo "INFO: $*" >&2
}

# --- enum 値抽出: スキーマ JSON から enum 配列を読み出す ------------------
# $1: schema_path
# $2: jq path (例: '.properties.type.enum')
_sv_read_enum() {
  local schema_path="$1" jq_path="$2"
  if [ ! -f "$schema_path" ]; then
    return 1
  fi
  # Windows Git Bash: jq may emit CRLF — strip \r to make equality comparisons work.
  jq -r "${jq_path} // [] | .[]" "$schema_path" 2>/dev/null | tr -d '\r'
}

# --- 個別検査: JSON パース可能か ------------------------------------------
_sv_check_parseable() {
  local file="$1"
  if ! jq empty "$file" >/dev/null 2>&1; then
    _sv_err "scenario.json is not valid JSON: $file"
    return 1
  fi
  return 0
}

# --- 個別検査: 必須フィールド ---------------------------------------------
# $1: file, $2: field (top-level)
# 欠落なら exit 1、エラーに field 名を出力
_sv_check_required() {
  local file="$1" field="$2"
  if ! jq -e --arg f "$field" 'has($f)' "$file" >/dev/null 2>&1; then
    _sv_err "missing required field: '${field}'"
    return 1
  fi
  return 0
}

# --- 個別検査: 値の JSON 型 -----------------------------------------------
# $1: file, $2: jq path (例: .id, .input_sources), $3: expected type
_sv_check_type() {
  local file="$1" path="$2" expected="$3"
  local actual
  actual=$(jq -r "${path} | type" "$file" 2>/dev/null)
  if [ "$actual" != "$expected" ]; then
    _sv_err "type error: ${path} must be ${expected} (got ${actual})"
    return 1
  fi
  return 0
}

# --- 個別検査: enum メンバー --------------------------------------------
# $1: actual value, $2: newline-separated allowed values, $3: context label
_sv_check_enum() {
  local value="$1" allowed="$2" context="$3"
  if [ -z "$allowed" ]; then
    return 0  # スキーマから enum が読めなかった場合はスキップ
  fi
  local ok=0
  local v
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    if [ "$value" = "$v" ]; then
      ok=1
      break
    fi
  done <<< "$allowed"
  if [ "$ok" -ne 1 ]; then
    local allowed_oneline
    allowed_oneline=$(echo "$allowed" | tr '\n' ',' | sed 's/,$//')
    _sv_err "enum violation at ${context}: '${value}' not in [${allowed_oneline}]"
    return 1
  fi
  return 0
}

# =========================================================================
# メイン: validate_scenario_json <scenario.json> [<schema.json>]
# 戻り値: 0=OK, 1=検証失敗
# stderr に エラーメッセージ全件を出力（複数違反を累積報告）
# =========================================================================
validate_scenario_json() {
  local scenario_file="$1"
  local schema_file="${2:-$SCENARIO_SCHEMA_DEFAULT}"
  local errors=0

  if [ ! -f "$scenario_file" ]; then
    _sv_err "scenario file not found: $scenario_file"
    return 1
  fi

  # Layer 1: parseable
  if ! _sv_check_parseable "$scenario_file"; then
    return 1
  fi

  # Layer 2: 必須トップレベルフィールド
  local required_top=(id type input_sources quality_gates agent_prompt_patch)
  local f
  for f in "${required_top[@]}"; do
    _sv_check_required "$scenario_file" "$f" || errors=$((errors + 1))
  done

  # 以降の検査は必須フィールドが存在する前提だが、各検査は own-guard を持つ
  # (jq のパスが null を返すだけで落ちない)

  # Layer 3: 型検証
  # id: string
  if jq -e 'has("id")' "$scenario_file" >/dev/null 2>&1; then
    _sv_check_type "$scenario_file" '.id' 'string' || errors=$((errors + 1))
  fi
  # type: string
  if jq -e 'has("type")' "$scenario_file" >/dev/null 2>&1; then
    _sv_check_type "$scenario_file" '.type' 'string' || errors=$((errors + 1))
  fi
  # input_sources: array
  if jq -e 'has("input_sources")' "$scenario_file" >/dev/null 2>&1; then
    _sv_check_type "$scenario_file" '.input_sources' 'array' || errors=$((errors + 1))
  fi
  # quality_gates: object
  if jq -e 'has("quality_gates")' "$scenario_file" >/dev/null 2>&1; then
    _sv_check_type "$scenario_file" '.quality_gates' 'object' || errors=$((errors + 1))
  fi
  # agent_prompt_patch: string (NOT object/array)
  if jq -e 'has("agent_prompt_patch")' "$scenario_file" >/dev/null 2>&1; then
    _sv_check_type "$scenario_file" '.agent_prompt_patch' 'string' || errors=$((errors + 1))
  fi

  # Layer 4: enum 検証（scenario.type）
  local type_enum
  type_enum=$(_sv_read_enum "$schema_file" '.properties.type.enum')
  local scenario_type
  scenario_type=$(jq -r '.type // empty' "$scenario_file" 2>/dev/null | tr -d '\r')
  if [ -n "$scenario_type" ] && [ -n "$type_enum" ]; then
    # type が文字列である場合のみ enum 検査
    local t_type
    t_type=$(jq -r '.type | type' "$scenario_file" 2>/dev/null)
    if [ "$t_type" = "string" ]; then
      _sv_check_enum "$scenario_type" "$type_enum" ".type" || errors=$((errors + 1))
    fi
  fi

  # Layer 5: input_sources[].type enum 検証 + 各要素の型検査
  if jq -e '.input_sources | type == "array"' "$scenario_file" >/dev/null 2>&1; then
    local source_type_enum
    source_type_enum=$(_sv_read_enum "$schema_file" '.properties.input_sources.items.properties.type.enum')
    local n_sources
    n_sources=$(jq '.input_sources | length' "$scenario_file" 2>/dev/null)
    local i=0
    while [ "$i" -lt "$n_sources" ]; do
      # 要素はオブジェクトであること
      local item_type
      item_type=$(jq -r ".input_sources[$i] | type" "$scenario_file" 2>/dev/null)
      if [ "$item_type" != "object" ]; then
        _sv_err "input_sources[${i}] must be object (got ${item_type})"
        errors=$((errors + 1))
        i=$((i + 1))
        continue
      fi
      # type フィールド必須
      if ! jq -e ".input_sources[$i] | has(\"type\")" "$scenario_file" >/dev/null 2>&1; then
        _sv_err "input_sources[${i}] missing required field: 'type'"
        errors=$((errors + 1))
        i=$((i + 1))
        continue
      fi
      local src_t
      src_t=$(jq -r ".input_sources[$i].type" "$scenario_file" 2>/dev/null | tr -d '\r')
      if [ -n "$source_type_enum" ]; then
        _sv_check_enum "$src_t" "$source_type_enum" ".input_sources[${i}].type" || errors=$((errors + 1))
      fi
      i=$((i + 1))
    done
  fi

  # Layer 6: quality_gates.required_mechanical_gates 非空
  if jq -e '.quality_gates | type == "object"' "$scenario_file" >/dev/null 2>&1; then
    if ! jq -e '.quality_gates | has("required_mechanical_gates")' "$scenario_file" >/dev/null 2>&1; then
      _sv_err "quality_gates.required_mechanical_gates is missing (required)"
      errors=$((errors + 1))
    else
      local gates_type
      gates_type=$(jq -r '.quality_gates.required_mechanical_gates | type' "$scenario_file" 2>/dev/null)
      if [ "$gates_type" != "array" ]; then
        _sv_err "quality_gates.required_mechanical_gates must be array (got ${gates_type})"
        errors=$((errors + 1))
      else
        local gates_len
        gates_len=$(jq '.quality_gates.required_mechanical_gates | length' "$scenario_file" 2>/dev/null)
        if [ "${gates_len:-0}" -lt 1 ]; then
          _sv_err "quality_gates.required_mechanical_gates must not be empty (at least 1 gate required)"
          errors=$((errors + 1))
        fi
      fi
    fi
  fi

  if [ "$errors" -gt 0 ]; then
    _sv_err "scenario validation failed: ${errors} error(s) in ${scenario_file}"
    return 1
  fi

  _sv_info "scenario validation passed: ${scenario_file}"
  return 0
}

# --- CLI エントリポイント -------------------------------------------------
# source ではなく直接実行された場合のみ validate を走らせる
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: bash $0 <scenario.json> [<schema.json>]" >&2
    exit 2
  fi
  validate_scenario_json "$@"
  exit $?
fi
