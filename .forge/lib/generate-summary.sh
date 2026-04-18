#!/bin/bash
# generate-summary.sh — シナリオ実行後に scenarios/{id}/out/summary.json を生成
#
# 使い方:
#   source .forge/lib/generate-summary.sh
#   generate_scenario_summary <scenario_dir> [<output_file>]
#
# CLI 実行:
#   bash .forge/lib/generate-summary.sh <scenario_dir> [<output_file>]
#
# 入力:
#   <scenario_dir>/scenario.json          — シナリオ定義（必須）
#   <scenario_dir>/timeline.json          — タイムライン定義（任意）
#   <scenario_dir>/out/output.mp4 等      — 成果物（任意）
#   <output_file>                          — summary.json 出力先（省略時: scenario_dir/out/summary.json）
#
# 出力: summary.json に以下を書き出し
#   - scenario.{id,type,intent,target_format,expected_duration_sec}
#   - output.{path,file_size_bytes,duration_sec,resolution,codec}
#   - timeline_validity.{ok,errors[],warnings[]}
#   - mechanical_gates_summary[] （required_mechanical_gates の実行結果、blocking は未実行でも記録）
#   - errors[] / warnings[] / generated_at
#
# 設計方針:
#   - LLM judge への単一情報源として summary.json を生成する
#   - timeline.json が存在すれば timeline-validator で検証し ok/errors/warnings を収集
#   - RenderJob.status enum 違反など validity.ok=false の場合、関数は exit 1 を返す（上位で検知可能に）
#   - 10MB 超過は警告扱いで exit 0（polish フェーズ対応：TIMELINE_SIZE_WARN_BYTES を環境変数で上書き可）
#   - ffprobe 不在環境でも scenario メタデータと gate 実行結果だけで summary を生成できる
#
# 依存: jq, bash, (optional) ffprobe

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _GS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_GS_SCRIPT_DIR}/../.." && pwd)"
fi

# timeline-validator を読み込む（validate_timeline_json を利用する）
if ! type validate_timeline_json >/dev/null 2>&1; then
  if [ -f "${PROJECT_ROOT}/.forge/lib/timeline-validator.sh" ]; then
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/.forge/lib/timeline-validator.sh"
  fi
fi

_gs_info() { echo "INFO: $*" >&2; }
_gs_warn() { echo "WARNING: $*" >&2; }
_gs_err()  { echo "ERROR: $*" >&2; }

# --- ffprobe で動画メタデータを抽出（ffprobe 不在なら全て null） ---
# $1: media file path → stdout: JSON {duration_sec,resolution,codec}
_gs_probe_media() {
  local f="$1"
  if [ ! -f "$f" ] || ! command -v ffprobe >/dev/null 2>&1; then
    jq -n '{duration_sec: null, resolution: null, codec: null}'
    return 0
  fi
  local dur w h codec
  dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | tr -d '\r' | head -1)
  w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | tr -d '\r' | head -1)
  h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | tr -d '\r' | head -1)
  codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | tr -d '\r' | head -1)
  local res="null"
  if [ -n "${w:-}" ] && [ -n "${h:-}" ]; then
    res="\"${w}x${h}\""
  fi
  local dur_num="null"
  if [ -n "${dur:-}" ] && awk -v v="$dur" 'BEGIN{ if (v+0==v+0 && v+0>0) exit 0; else exit 1 }' 2>/dev/null; then
    dur_num="$dur"
  fi
  local codec_j="null"
  [ -n "${codec:-}" ] && codec_j="\"${codec}\""
  printf '{"duration_sec":%s,"resolution":%s,"codec":%s}\n' "$dur_num" "$res" "$codec_j"
}

# --- ファイルサイズ取得（cross-OS） ---
_gs_file_size() {
  local f="$1" sz=""
  if command -v stat >/dev/null 2>&1; then
    sz=$(stat -c '%s' "$f" 2>/dev/null || true)
    [ -z "$sz" ] && sz=$(stat -f '%z' "$f" 2>/dev/null || true)
  fi
  [ -z "$sz" ] && sz=$(wc -c <"$f" 2>/dev/null | tr -d ' \r\n' || true)
  echo "${sz:-0}"
}

# --- mechanical_gates_summary を作成（実行せず結果のみ集計するモード） ---
# $1: scenario.json path → stdout: JSON array [{id,description,command,blocking}]
_gs_collect_gates() {
  local scen="$1"
  jq '[.quality_gates.required_mechanical_gates[]? | {
        id: (.id // ""),
        description: (.description // ""),
        command: (.command // ""),
        blocking: (if has("blocking") then .blocking else true end),
        status: "not_executed"
      }]' "$scen" 2>/dev/null || echo "[]"
}

# =========================================================================
# メイン: generate_scenario_summary <scenario_dir> [<output_file>]
# 戻り値:
#   0 = summary.json 生成成功（timeline_validity.ok=true、警告はあってもよい）
#   1 = timeline validity error（enum 違反等）。summary.json は書き出される
#   2 = 致命的エラー（scenario.json 不在 / JSON 不正 等）。summary.json は書かない
# =========================================================================
generate_scenario_summary() {
  local scen_dir="$1"
  local out_file="${2:-}"
  local scen_file="${scen_dir}/scenario.json"
  local tl_file="${scen_dir}/timeline.json"

  if [ ! -d "$scen_dir" ] || [ ! -f "$scen_file" ]; then
    _gs_err "scenario.json not found in: ${scen_dir}"
    return 2
  fi
  if ! jq empty "$scen_file" >/dev/null 2>&1; then
    _gs_err "scenario.json is not valid JSON: ${scen_file}"
    return 2
  fi

  # 出力先決定（省略時は scenario_dir/out/summary.json）
  if [ -z "$out_file" ]; then
    out_file="${scen_dir}/out/summary.json"
  fi
  mkdir -p "$(dirname "$out_file")"

  # --- scenario メタ情報 -------------------------------------------------
  local scen_meta
  scen_meta=$(jq '{
      id: (.id // ""),
      type: (.type // ""),
      version: (.version // ""),
      description: (.description // ""),
      intent: (.intent // .description // ""),
      target_format: (.target_format // .output.target_format // ""),
      expected_duration_sec: (.expected_duration_sec // .output.expected_duration_sec // null),
      duration_tolerance_sec: (.duration_tolerance_sec // .output.duration_tolerance_sec // null)
    }' "$scen_file")

  # --- 成果物探索: out/ 配下の主要メディアファイル -----------------------
  local out_dir="${scen_dir}/out"
  local primary_output="" primary_output_rel="" media_meta size_bytes=0
  if [ -d "$out_dir" ]; then
    # 優先順: output.mp4 → 最初の *.mp4 → 最初の *.mov/*.webm
    for cand in "${out_dir}/output.mp4"; do
      [ -f "$cand" ] && { primary_output="$cand"; break; }
    done
    if [ -z "$primary_output" ]; then
      primary_output=$(ls "${out_dir}"/*.mp4 2>/dev/null | head -1 || true)
    fi
    if [ -z "$primary_output" ]; then
      primary_output=$(ls "${out_dir}"/*.mov "${out_dir}"/*.webm 2>/dev/null | head -1 || true)
    fi
  fi

  if [ -n "$primary_output" ] && [ -f "$primary_output" ]; then
    size_bytes=$(_gs_file_size "$primary_output")
    media_meta=$(_gs_probe_media "$primary_output")
    primary_output_rel="${primary_output#${scen_dir}/}"
  else
    media_meta='{"duration_sec": null, "resolution": null, "codec": null}'
    primary_output_rel=""
  fi

  # --- timeline 検証 -----------------------------------------------------
  local tl_ok=true
  local tl_errors_json="[]" tl_warnings_json="[]"
  local has_timeline=false
  local size_warn_threshold="${TIMELINE_SIZE_WARN_BYTES:-10485760}"
  if [ -f "$tl_file" ]; then
    has_timeline=true
    if type validate_timeline_json >/dev/null 2>&1; then
      # timeline-validator は stderr に ERROR/WARNING/INFO を出す。
      # TIMELINE_SIZE_WARN_BYTES を引き継ぐためそのまま呼び出す。
      # 注意: `local tl_out=$(...)` 形式だと local 自体が常に rc=0 を返して
      #       サブシェルの exit code が捨てられる。宣言と代入を分離する。
      local tl_out=""
      local tl_rc=0
      tl_out=$(TIMELINE_SIZE_WARN_BYTES="$size_warn_threshold" validate_timeline_json "$tl_file" 2>&1 1>/dev/null)
      tl_rc=$?
      # errors / warnings 収集
      local errs="" warns=""
      errs=$(echo "$tl_out" | grep -E '^ERROR:' | sed 's/^ERROR: //' || true)
      warns=$(echo "$tl_out" | grep -E '^WARNING:' | sed 's/^WARNING: //' || true)
      if [ -n "$errs" ]; then
        tl_errors_json=$(printf '%s\n' "$errs" | jq -R . | jq -s .)
      fi
      if [ -n "$warns" ]; then
        tl_warnings_json=$(printf '%s\n' "$warns" | jq -R . | jq -s .)
      fi
      if [ "$tl_rc" -ne 0 ]; then
        tl_ok=false
      fi
    else
      _gs_warn "validate_timeline_json not available — skipping timeline validation"
    fi
  fi

  # --- mechanical_gates_summary 収集（未実行マーク）---------------------
  local gates_summary
  gates_summary=$(_gs_collect_gates "$scen_file")

  # --- アグリゲート errors/warnings -------------------------------------
  local agg_errors="[]" agg_warnings="[]"
  agg_errors=$(echo "$tl_errors_json" | jq '.')
  # サイズ警告が発生していれば warnings にフラット結合
  agg_warnings=$(echo "$tl_warnings_json" | jq '.')

  # --- summary.json 組み立て --------------------------------------------
  local generated_at
  generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")

  local output_block
  output_block=$(jq -n \
    --arg path "$primary_output_rel" \
    --argjson size "$size_bytes" \
    --argjson media "$media_meta" \
    '{
       path: (if ($path|length)>0 then $path else null end),
       file_size_bytes: $size,
       duration_sec: $media.duration_sec,
       resolution: $media.resolution,
       codec: $media.codec
     }')

  local timeline_block
  timeline_block=$(jq -n \
    --argjson ok "$tl_ok" \
    --argjson errs "$tl_errors_json" \
    --argjson warns "$tl_warnings_json" \
    --argjson present "$has_timeline" \
    '{present: $present, ok: $ok, errors: $errs, warnings: $warns}')

  jq -n \
    --argjson scen "$scen_meta" \
    --argjson output "$output_block" \
    --argjson timeline "$timeline_block" \
    --argjson gates "$gates_summary" \
    --argjson errs "$agg_errors" \
    --argjson warns "$agg_warnings" \
    --arg generated_at "$generated_at" \
    '{
       scenario: $scen,
       output: $output,
       timeline_validity: $timeline,
       mechanical_gates_summary: $gates,
       gates_total: ($gates | length),
       gates_passed: 0,
       gates_failed: 0,
       errors: $errs,
       warnings: $warns,
       generated_at: $generated_at
     }' > "$out_file" || {
    _gs_err "failed to write summary.json: $out_file"
    return 2
  }

  _gs_info "summary.json written: $out_file"
  if [ "$tl_ok" = "false" ]; then
    _gs_err "timeline_validity.ok=false — summary reflects errors (see $out_file)"
    return 1
  fi
  return 0
}

# --- CLI エントリポイント -------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: bash $0 <scenario_dir> [<output_file>]" >&2
    exit 2
  fi
  generate_scenario_summary "$@"
  exit $?
fi
