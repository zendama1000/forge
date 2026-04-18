#!/bin/bash
# quality-gate-validator.sh — QualityGate オブジェクト（required_mechanical_gates[]）のバリデータ
#
# 使い方:
#   source .forge/lib/quality-gate-validator.sh
#   validate_quality_gate <path/to/quality-gate.json>           # 検証のみ
#   validate_quality_gate <path/to/quality-gate.json> <schema>  # スキーマパス明示
#
# CLI 実行:
#   bash .forge/lib/quality-gate-validator.sh <path/to/quality-gate.json>
#
# 依存: jq
#
# 設計方針:
#   ajv 等の外部 JSON Schema validator は harness 依存に含まれないため、
#   jq で機械的に必須項目/型/minItems/enum を検査する薄い validator を自前実装。
#   enum 値はスキーマ (quality-gate-schema.json) を単一情報源として参照する。
#
# 検証ルール（スキーマと同期）:
#   - required_mechanical_gates: 必須フィールド（欠落は 'field required'）
#   - 型は array であること
#   - minItems >= 1（空配列は 'empty not allowed'）
#   - 各要素は enum ["ffprobe_exists","duration_check","size_threshold"] のいずれか

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _QGV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_QGV_SCRIPT_DIR}/../.." && pwd)"
fi

# デフォルトスキーマパス
QUALITY_GATE_SCHEMA_DEFAULT="${PROJECT_ROOT}/.forge/schemas/quality-gate-schema.json"

# --- helper: エラー/情報出力（stderr） -----------------------------------
_qgv_err() {
  echo "ERROR: $*" >&2
}

_qgv_info() {
  echo "INFO: $*" >&2
}

# --- enum 値抽出: スキーマ JSON から enum 配列を読み出す ------------------
# $1: schema_path, $2: jq path
# Windows Git Bash: jq may emit CRLF — strip \r for exact equality comparisons.
_qgv_read_enum() {
  local schema_path="$1" jq_path="$2"
  if [ ! -f "$schema_path" ]; then
    return 1
  fi
  jq -r "${jq_path} // [] | .[]" "$schema_path" 2>/dev/null | tr -d '\r'
}

# --- 個別検査: JSON パース可能か ------------------------------------------
_qgv_check_parseable() {
  local file="$1"
  if ! jq empty "$file" >/dev/null 2>&1; then
    _qgv_err "quality-gate file is not valid JSON: $file"
    return 1
  fi
  return 0
}

# =========================================================================
# メイン: validate_quality_gate <file> [<schema>]
# 戻り値: 0=OK, 1=検証失敗
# stderr にエラーを累積報告（複数違反は全て出力）
# =========================================================================
validate_quality_gate() {
  local qg_file="$1"
  local schema_file="${2:-$QUALITY_GATE_SCHEMA_DEFAULT}"
  local errors=0

  if [ ! -f "$qg_file" ]; then
    _qgv_err "quality-gate file not found: $qg_file"
    return 1
  fi

  # Layer 1: parseable JSON
  if ! _qgv_check_parseable "$qg_file"; then
    return 1
  fi

  # Layer 2: required_mechanical_gates フィールド必須
  if ! jq -e 'has("required_mechanical_gates")' "$qg_file" >/dev/null 2>&1; then
    _qgv_err "field required: 'required_mechanical_gates' is missing"
    errors=$((errors + 1))
    # 欠落時は以降の検査不要
    _qgv_err "quality-gate validation failed: ${errors} error(s) in ${qg_file}"
    return 1
  fi

  # Layer 3: 型が array であること
  local gates_type
  gates_type=$(jq -r '.required_mechanical_gates | type' "$qg_file" 2>/dev/null)
  if [ "$gates_type" != "array" ]; then
    _qgv_err "type error: required_mechanical_gates must be array (got ${gates_type})"
    errors=$((errors + 1))
    _qgv_err "quality-gate validation failed: ${errors} error(s) in ${qg_file}"
    return 1
  fi

  # Layer 4: minItems >= 1（空配列禁止）
  local gates_len
  gates_len=$(jq '.required_mechanical_gates | length' "$qg_file" 2>/dev/null)
  if [ "${gates_len:-0}" -lt 1 ]; then
    _qgv_err "required_mechanical_gates is empty not allowed (minItems: 1)"
    errors=$((errors + 1))
  fi

  # Layer 5: 各要素の型 + enum 検証
  local allowed
  allowed=$(_qgv_read_enum "$schema_file" '.properties.required_mechanical_gates.items.enum')
  if [ -z "$allowed" ]; then
    # スキーマが読めない場合は harness の設定事故なので警告し、続行はする
    _qgv_info "warning: enum could not be loaded from schema ${schema_file}; skipping enum check"
  fi

  local i=0
  while [ "$i" -lt "${gates_len:-0}" ]; do
    local item_type
    item_type=$(jq -r ".required_mechanical_gates[$i] | type" "$qg_file" 2>/dev/null)
    if [ "$item_type" != "string" ]; then
      _qgv_err "type error: required_mechanical_gates[${i}] must be string (got ${item_type})"
      errors=$((errors + 1))
      i=$((i + 1))
      continue
    fi
    local val
    val=$(jq -r ".required_mechanical_gates[$i]" "$qg_file" 2>/dev/null | tr -d '\r')
    if [ -n "$allowed" ]; then
      local ok=0
      local a
      while IFS= read -r a; do
        [ -z "$a" ] && continue
        if [ "$val" = "$a" ]; then
          ok=1
          break
        fi
      done <<< "$allowed"
      if [ "$ok" -ne 1 ]; then
        local allowed_oneline
        allowed_oneline=$(echo "$allowed" | tr '\n' ',' | sed 's/,$//')
        _qgv_err "enum violation at required_mechanical_gates[${i}]: '${val}' not in [${allowed_oneline}]"
        errors=$((errors + 1))
      fi
    fi
    i=$((i + 1))
  done

  if [ "$errors" -gt 0 ]; then
    _qgv_err "quality-gate validation failed: ${errors} error(s) in ${qg_file}"
    return 1
  fi

  _qgv_info "quality-gate validation passed: ${qg_file}"
  return 0
}

# --- CLI エントリポイント -------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: bash $0 <quality-gate.json> [<schema.json>]" >&2
    exit 2
  fi
  validate_quality_gate "$@"
  exit $?
fi
