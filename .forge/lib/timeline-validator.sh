#!/bin/bash
# timeline-validator.sh — timeline.json (OpenTimelineIO 骨格) バリデータ
#
# 使い方:
#   source .forge/lib/timeline-validator.sh
#   validate_timeline_json <path/to/timeline.json>              # 検証のみ
#   validate_timeline_json <path/to/timeline.json> <schema>     # スキーマパス明示
#
# CLI 実行:
#   bash .forge/lib/timeline-validator.sh <path/to/timeline.json>
#
# 依存: jq
#
# 設計方針:
#   ajv 等の外部 JSON Schema validator は harness 依存に含まれないため、
#   jq で機械的に以下を検査する薄い validator を自前実装。
#     - 必須トップレベル (id, tracks)
#     - tracks 型 (array, minItems: 1)
#     - Track.kind enum (Video/Audio/Subtitle)
#     - Clip.source_range の start_time/duration 非負 & duration>0
#       （start_time > end_time つまり negative duration を弾く）
#     - MediaReference.target_url の存在チェック（file_exists）
#     - RenderJob.status enum (pending/running/succeeded/failed)
#     - 10MB (10_485_760 bytes) 超過は warning だけで検証通過（polish フェーズで扱う）
#
#   enum 値はスキーマ (timeline-schema.json) を単一情報源として参照する。
#   Windows Git Bash 対策で jq 出力の CRLF を剥がす。

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _TLV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_TLV_SCRIPT_DIR}/../.." && pwd)"
fi

# デフォルトスキーマパス
TIMELINE_SCHEMA_DEFAULT="${PROJECT_ROOT}/.forge/schemas/timeline-schema.json"

# 10MB 警告閾値（polish フェーズで扱う。bytes）
TIMELINE_SIZE_WARN_BYTES="${TIMELINE_SIZE_WARN_BYTES:-10485760}"

# --- helper: エラー/情報/警告出力（stderr） ------------------------------
_tlv_err() {
  echo "ERROR: $*" >&2
}

_tlv_warn() {
  echo "WARNING: $*" >&2
}

_tlv_info() {
  echo "INFO: $*" >&2
}

# --- enum 値抽出: スキーマ JSON から enum 配列を読み出す ------------------
# $1: schema_path, $2: jq path
_tlv_read_enum() {
  local schema_path="$1" jq_path="$2"
  if [ ! -f "$schema_path" ]; then
    return 1
  fi
  jq -r "${jq_path} // [] | .[]" "$schema_path" 2>/dev/null | tr -d '\r'
}

# --- enum 所属チェック ---------------------------------------------------
# $1: value, $2: newline-separated allowed, $3: context
_tlv_check_enum() {
  local value="$1" allowed="$2" context="$3"
  if [ -z "$allowed" ]; then
    return 0
  fi
  local ok=0 v
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
    _tlv_err "enum violation at ${context}: '${value}' not in [${allowed_oneline}]"
    return 1
  fi
  return 0
}

# --- ファイルサイズ取得（bytes） -----------------------------------------
# OS 差異を吸収: GNU stat, BSD stat, wc -c の順にフォールバック
_tlv_file_size() {
  local f="$1" sz=""
  if command -v stat >/dev/null 2>&1; then
    sz=$(stat -c '%s' "$f" 2>/dev/null || true)
    if [ -z "$sz" ]; then
      sz=$(stat -f '%z' "$f" 2>/dev/null || true)
    fi
  fi
  if [ -z "$sz" ]; then
    sz=$(wc -c <"$f" 2>/dev/null | tr -d ' \r' || true)
  fi
  echo "${sz:-0}"
}

# --- target_url を絶対パスに解決（相対パスは timeline.json のあるディレクトリ基準） ---
# $1: base_dir, $2: target_url
_tlv_resolve_path() {
  local base_dir="$1" url="$2"
  case "$url" in
    /*)       echo "$url" ;;
    [A-Za-z]:[/\\]*) echo "$url" ;;  # Windows 絶対パス (C:/... or C:\\...)
    *)        echo "${base_dir}/${url}" ;;
  esac
}

# =========================================================================
# メイン: validate_timeline_json <file> [<schema>]
# 戻り値: 0=OK（警告含む）, 1=検証失敗
# stderr にエラー/警告を累積出力。
# =========================================================================
validate_timeline_json() {
  local tl_file="$1"
  local schema_file="${2:-$TIMELINE_SCHEMA_DEFAULT}"
  local errors=0

  if [ ! -f "$tl_file" ]; then
    _tlv_err "timeline file not found: $tl_file"
    return 1
  fi

  # Layer 0: サイズ警告（検証自体は通す／polish フェーズで扱う）
  local sz
  sz=$(_tlv_file_size "$tl_file")
  if [ -n "$sz" ] && [ "$sz" -gt "$TIMELINE_SIZE_WARN_BYTES" ] 2>/dev/null; then
    _tlv_warn "timeline size ${sz} bytes exceeds ${TIMELINE_SIZE_WARN_BYTES} bytes threshold (polish-phase concern; continuing validation)"
  fi

  # Layer 1: parseable
  if ! jq empty "$tl_file" >/dev/null 2>&1; then
    _tlv_err "timeline.json is not valid JSON: $tl_file"
    return 1
  fi

  # timeline.json のあるディレクトリ（相対 target_url の解決基準）
  local base_dir
  base_dir="$(cd "$(dirname "$tl_file")" && pwd)"

  # Layer 2: 必須トップレベル
  local fld
  for fld in id tracks; do
    if ! jq -e --arg f "$fld" 'has($f)' "$tl_file" >/dev/null 2>&1; then
      _tlv_err "missing required field: '${fld}'"
      errors=$((errors + 1))
    fi
  done

  # id: string
  if jq -e 'has("id")' "$tl_file" >/dev/null 2>&1; then
    local id_type
    id_type=$(jq -r '.id | type' "$tl_file" 2>/dev/null)
    if [ "$id_type" != "string" ]; then
      _tlv_err "type error: .id must be string (got ${id_type})"
      errors=$((errors + 1))
    fi
  fi

  # tracks: array
  local has_tracks=0
  if jq -e 'has("tracks")' "$tl_file" >/dev/null 2>&1; then
    local tr_type
    tr_type=$(jq -r '.tracks | type' "$tl_file" 2>/dev/null)
    if [ "$tr_type" != "array" ]; then
      _tlv_err "type error: .tracks must be array (got ${tr_type})"
      errors=$((errors + 1))
    else
      has_tracks=1
      local tr_len
      tr_len=$(jq '.tracks | length' "$tl_file" 2>/dev/null)
      if [ "${tr_len:-0}" -lt 1 ]; then
        _tlv_err "tracks is empty (minItems: 1)"
        errors=$((errors + 1))
      fi
    fi
  fi

  # Layer 3: Track/Clip の詳細
  local kind_enum
  kind_enum=$(_tlv_read_enum "$schema_file" '.properties.tracks.items.properties.kind.enum')

  if [ "$has_tracks" -eq 1 ]; then
    local n_tracks
    n_tracks=$(jq '.tracks | length' "$tl_file" 2>/dev/null)
    local ti=0
    while [ "$ti" -lt "${n_tracks:-0}" ]; do
      # Track.kind
      local k
      k=$(jq -r ".tracks[$ti].kind // empty" "$tl_file" 2>/dev/null | tr -d '\r')
      if [ -z "$k" ]; then
        _tlv_err ".tracks[${ti}].kind is missing (required)"
        errors=$((errors + 1))
      elif [ -n "$kind_enum" ]; then
        _tlv_check_enum "$k" "$kind_enum" ".tracks[${ti}].kind" || errors=$((errors + 1))
      fi

      # Track.clips が array か
      local clips_type
      clips_type=$(jq -r ".tracks[$ti].clips | type" "$tl_file" 2>/dev/null)
      if [ "$clips_type" != "array" ]; then
        _tlv_err "type error: .tracks[${ti}].clips must be array (got ${clips_type})"
        errors=$((errors + 1))
        ti=$((ti + 1))
        continue
      fi

      local n_clips
      n_clips=$(jq ".tracks[$ti].clips | length" "$tl_file" 2>/dev/null)
      local ci=0
      while [ "$ci" -lt "${n_clips:-0}" ]; do
        local cpath=".tracks[${ti}].clips[${ci}]"
        # source_range
        if ! jq -e "${cpath} | has(\"source_range\")" "$tl_file" >/dev/null 2>&1; then
          _tlv_err "${cpath}.source_range is missing (required)"
          errors=$((errors + 1))
        else
          local st du
          st=$(jq -r "${cpath}.source_range.start_time // \"\"" "$tl_file" 2>/dev/null | tr -d '\r')
          du=$(jq -r "${cpath}.source_range.duration // \"\"" "$tl_file" 2>/dev/null | tr -d '\r')
          # start_time 存在 & 非負
          if [ -z "$st" ]; then
            _tlv_err "${cpath}.source_range.start_time is missing"
            errors=$((errors + 1))
          else
            # 数値として比較できるか
            if ! awk -v v="$st" 'BEGIN{ if (v+0==v+0 && v+0>=0) exit 0; else exit 1 }' 2>/dev/null; then
              _tlv_err "${cpath}.source_range.start_time invalid or negative: '${st}'"
              errors=$((errors + 1))
            fi
          fi
          # duration 存在 & > 0 （負 duration = 開始>終了 を弾く）
          if [ -z "$du" ]; then
            _tlv_err "${cpath}.source_range.duration is missing"
            errors=$((errors + 1))
          else
            if ! awk -v v="$du" 'BEGIN{ if (v+0==v+0 && v+0>0) exit 0; else exit 1 }' 2>/dev/null; then
              _tlv_err "range error at ${cpath}.source_range: duration must be > 0 (got '${du}'; negative duration means start > end)"
              errors=$((errors + 1))
            fi
          fi
        fi

        # media_reference
        if ! jq -e "${cpath} | has(\"media_reference\")" "$tl_file" >/dev/null 2>&1; then
          _tlv_err "${cpath}.media_reference is missing (required)"
          errors=$((errors + 1))
        else
          local turl
          turl=$(jq -r "${cpath}.media_reference.target_url // \"\"" "$tl_file" 2>/dev/null | tr -d '\r')
          if [ -z "$turl" ]; then
            _tlv_err "${cpath}.media_reference.target_url is missing"
            errors=$((errors + 1))
          else
            local resolved
            resolved=$(_tlv_resolve_path "$base_dir" "$turl")
            if [ ! -e "$resolved" ]; then
              _tlv_err "file_exists failed at ${cpath}.media_reference.target_url: '${turl}' (resolved='${resolved}')"
              errors=$((errors + 1))
            fi
          fi
        fi

        ci=$((ci + 1))
      done
      ti=$((ti + 1))
    done
  fi

  # Layer 4: render_jobs[].status enum
  if jq -e 'has("render_jobs")' "$tl_file" >/dev/null 2>&1; then
    local rj_type
    rj_type=$(jq -r '.render_jobs | type' "$tl_file" 2>/dev/null)
    if [ "$rj_type" != "array" ]; then
      _tlv_err "type error: .render_jobs must be array (got ${rj_type})"
      errors=$((errors + 1))
    else
      local rs_enum
      rs_enum=$(_tlv_read_enum "$schema_file" '.properties.render_jobs.items.properties.status.enum')
      local n_jobs
      n_jobs=$(jq '.render_jobs | length' "$tl_file" 2>/dev/null)
      local ji=0
      while [ "$ji" -lt "${n_jobs:-0}" ]; do
        local s
        s=$(jq -r ".render_jobs[$ji].status // empty" "$tl_file" 2>/dev/null | tr -d '\r')
        if [ -z "$s" ]; then
          _tlv_err ".render_jobs[${ji}].status is missing (required)"
          errors=$((errors + 1))
        elif [ -n "$rs_enum" ]; then
          _tlv_check_enum "$s" "$rs_enum" ".render_jobs[${ji}].status" || errors=$((errors + 1))
        fi
        ji=$((ji + 1))
      done
    fi
  fi

  if [ "$errors" -gt 0 ]; then
    _tlv_err "timeline validation failed: ${errors} error(s) in ${tl_file}"
    return 1
  fi

  _tlv_info "timeline validation passed: ${tl_file}"
  return 0
}

# --- CLI エントリポイント -------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: bash $0 <timeline.json> [<schema.json>]" >&2
    exit 2
  fi
  validate_timeline_json "$@"
  exit $?
fi
