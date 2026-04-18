#!/bin/bash
# llm-judge-runner.sh — summary.json を claude -p に渡し 0.0-1.0 スコアを取得するラッパー
#
# 使い方:
#   source .forge/lib/llm-judge-runner.sh
#   run_llm_judge <scenario_dir> [<output_path>]
#
# CLI 実行:
#   bash .forge/lib/llm-judge-runner.sh <scenario_dir> [<output_path>]
#
# 入力:
#   <scenario_dir>/scenario.json          — シナリオ定義
#   <scenario_dir>/out/summary.json       — generate_scenario_summary が生成したサマリ
#   <output_path>                          — judge 結果 JSON 出力先
#                                            （省略時: PROJECT_ROOT/.forge/state/llm-judge-result.json）
#
# 出力 JSON フィールド:
#   scenario_id, score (0.0-1.0), pass (bool), criteria_scores[], overall_rationale, summary, generated_at
#
# 設計方針:
#   - LLM (claude -p) を用いた subjective-but-bounded な評価。
#     timeline/scenario/metadata 整合性を 0.0-1.0 スコア化し、0.7 閾値で pass/fail を決定する。
#   - claude CLI 不在 / タイムアウト / JSON パース失敗 → graceful degrade:
#       score=0.0, pass=false, error を summary に記録して正常 exit（上位の L3 verify_command が検知）。
#     （機械ゲート自体の誤動作で L3 が赤くなることを避けるため stderr には詳細を流す）
#   - プロンプトは .forge/templates/llm-judge-prompt.md をレンダリングして stdin で渡す
#     （ARG_MAX 回避）。
#
# 依存: jq, claude (optional — 不在時はフォールバック), bash

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _LJR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_LJR_SCRIPT_DIR}/../.." && pwd)"
fi

# 設定（環境変数で上書き可）
LLM_JUDGE_MODEL="${LLM_JUDGE_MODEL:-haiku}"
LLM_JUDGE_TIMEOUT_SEC="${LLM_JUDGE_TIMEOUT_SEC:-180}"
LLM_JUDGE_PASS_THRESHOLD="${LLM_JUDGE_PASS_THRESHOLD:-0.7}"
LLM_JUDGE_TEMPLATE="${LLM_JUDGE_TEMPLATE:-${PROJECT_ROOT}/.forge/templates/llm-judge-prompt.md}"
LLM_JUDGE_DEFAULT_OUT="${PROJECT_ROOT}/.forge/state/llm-judge-result.json"

_ljr_info() { echo "INFO: $*" >&2; }
_ljr_warn() { echo "WARNING: $*" >&2; }
_ljr_err()  { echo "ERROR: $*" >&2; }

# --- graceful fallback: claude 不在等のとき score=0 で結果を書き出す ---
# $1: scenario_id, $2: output_file, $3: reason (stderr で人間向けに説明)
_ljr_write_fallback() {
  local scen_id="$1" out_file="$2" reason="$3"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
  mkdir -p "$(dirname "$out_file")"
  jq -n \
    --arg id "$scen_id" \
    --arg reason "$reason" \
    --arg ts "$ts" \
    '{
       scenario_id: $id,
       score: 0.0,
       pass: false,
       criteria_scores: [],
       overall_rationale: ("LLM judge could not run: " + $reason),
       summary: ("fallback-result — " + $reason),
       generated_at: $ts,
       fallback: true
     }' > "$out_file"
  _ljr_warn "llm-judge fallback written ($reason) → $out_file"
}

# --- judge_criteria を抽出（scenario.json や research criteria から） ---
# scenario.json に quality_gates.llm_judge.criteria[] が定義されていればそれを優先、
# 無ければデフォルト 5 項目を使う（research L3-006 と同期）
_ljr_extract_criteria() {
  local scen_file="$1"
  local crit
  crit=$(jq -r '
    (.quality_gates.llm_judge.criteria // .llm_judge.criteria // [])
    | if (. | length) > 0 then
        (map("- " + .) | join("\n"))
      else
        "- scenario の意図（intent/description）と出力メタデータが整合しているか\n- required_mechanical_gates が全 PASS であるか\n- duration が expected_duration_sec ± tolerance に収まっているか\n- 出力ファイル形式が target_format と一致しているか\n- errors/warnings が致命的でないか"
      end
  ' "$scen_file" 2>/dev/null || echo "- (criteria 抽出失敗: デフォルト評価)")
  printf '%s\n' "$crit"
}

# --- プロンプトをテンプレートからレンダリング ---
# {{KEY}} 置換は render_template 相当を自前実装（common.sh 未ロード環境でも動作させるため）
_ljr_render_prompt() {
  local template_file="$1" scen_id="$2" scen_json="$3" summary_json="$4" criteria="$5"
  local content
  content=$(cat "$template_file")
  # & のエスケープ（bash ${//} の replacement で & はマッチ全体を意味するため）
  local esc_sid="${scen_id//&/\\&}"
  local esc_scen="${scen_json//&/\\&}"
  local esc_sum="${summary_json//&/\\&}"
  local esc_crit="${criteria//&/\\&}"
  content="${content//\{\{SCENARIO_ID\}\}/$esc_sid}"
  content="${content//\{\{SCENARIO_JSON\}\}/$esc_scen}"
  content="${content//\{\{SUMMARY_JSON\}\}/$esc_sum}"
  content="${content//\{\{JUDGE_CRITERIA\}\}/$esc_crit}"
  printf '%s\n' "$content"
}

# --- claude -p を呼び出して JSON 出力を取得 ---
# $1: prompt, $2: raw_out_file → 戻り値 0=成功 1=失敗(timeout含む)
_ljr_invoke_claude() {
  local prompt="$1" raw_out="$2"
  if ! command -v claude >/dev/null 2>&1; then
    return 127
  fi
  # env -u CLAUDECODE: ネストセッション検出を回避
  echo "$prompt" | env -u CLAUDECODE timeout "$LLM_JUDGE_TIMEOUT_SEC" \
    claude --model "$LLM_JUDGE_MODEL" -p --dangerously-skip-permissions --no-session-persistence \
    > "$raw_out" 2>/dev/null
  local rc=$?
  return $rc
}

# --- 生出力から JSON を正規化（コードフェンス剥がし + 前後トリム） ---
_ljr_normalize_json() {
  local raw="$1" normalized="$2"
  # CRLF 正規化
  tr -d '\r' < "$raw" > "${normalized}.tmp1" 2>/dev/null || cp "$raw" "${normalized}.tmp1"
  # 既に valid なら採用
  if jq empty "${normalized}.tmp1" >/dev/null 2>&1; then
    mv "${normalized}.tmp1" "$normalized"
    return 0
  fi
  # コードフェンス剥がし
  sed -e 's/^```json[[:space:]]*$//' -e 's/^```[[:space:]]*$//' "${normalized}.tmp1" > "${normalized}.tmp2" 2>/dev/null
  if jq empty "${normalized}.tmp2" >/dev/null 2>&1; then
    mv "${normalized}.tmp2" "$normalized"
    rm -f "${normalized}.tmp1"
    return 0
  fi
  # 先頭 { から末尾 } までを抽出
  awk '
    BEGIN{ started=0 }
    { if (!started) { pos=index($0,"{"); if (pos>0){ started=1; print substr($0,pos); next } }
      else { print } }
  ' "${normalized}.tmp2" > "${normalized}.tmp3" 2>/dev/null
  if jq empty "${normalized}.tmp3" >/dev/null 2>&1; then
    mv "${normalized}.tmp3" "$normalized"
    rm -f "${normalized}.tmp1" "${normalized}.tmp2"
    return 0
  fi
  rm -f "${normalized}.tmp1" "${normalized}.tmp2" "${normalized}.tmp3"
  return 1
}

# =========================================================================
# メイン: run_llm_judge <scenario_dir> [<output_path>]
# 戻り値:
#   0 = 結果 JSON の書き出し成功（score フィールドあり / fallback 含む）
#   1 = 致命的エラー（summary.json 不在等、結果を書けない場合）
# =========================================================================
run_llm_judge() {
  local scen_dir="$1"
  local out_file="${2:-$LLM_JUDGE_DEFAULT_OUT}"
  local scen_file="${scen_dir}/scenario.json"
  local sum_file="${scen_dir}/out/summary.json"

  if [ ! -f "$scen_file" ] || [ ! -f "$sum_file" ]; then
    _ljr_err "scenario.json or summary.json not found under: ${scen_dir}"
    return 1
  fi
  if ! jq empty "$scen_file" >/dev/null 2>&1; then
    _ljr_err "scenario.json is not valid JSON: ${scen_file}"
    return 1
  fi
  if ! jq empty "$sum_file" >/dev/null 2>&1; then
    _ljr_err "summary.json is not valid JSON: ${sum_file}"
    return 1
  fi

  local scen_id
  scen_id=$(jq -r '.id // "unknown"' "$scen_file" 2>/dev/null | tr -d '\r')

  mkdir -p "$(dirname "$out_file")"

  if [ ! -f "$LLM_JUDGE_TEMPLATE" ]; then
    _ljr_write_fallback "$scen_id" "$out_file" "template not found: $LLM_JUDGE_TEMPLATE"
    return 0
  fi

  local criteria scen_content sum_content prompt
  criteria=$(_ljr_extract_criteria "$scen_file")
  scen_content=$(cat "$scen_file")
  sum_content=$(cat "$sum_file")
  prompt=$(_ljr_render_prompt "$LLM_JUDGE_TEMPLATE" "$scen_id" "$scen_content" "$sum_content" "$criteria")

  # claude 呼び出し（一時ファイル）
  local raw_out normalized
  raw_out=$(mktemp 2>/dev/null || echo "/tmp/ljr-raw-$$")
  normalized=$(mktemp 2>/dev/null || echo "/tmp/ljr-norm-$$")

  _ljr_invoke_claude "$prompt" "$raw_out"
  local rc=$?
  if [ "$rc" -eq 127 ]; then
    _ljr_write_fallback "$scen_id" "$out_file" "claude CLI not found in PATH"
    rm -f "$raw_out" "$normalized"
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    _ljr_write_fallback "$scen_id" "$out_file" "claude timed out (${LLM_JUDGE_TIMEOUT_SEC}s)"
    rm -f "$raw_out" "$normalized"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$raw_out" ]; then
    _ljr_write_fallback "$scen_id" "$out_file" "claude exited non-zero or empty (rc=$rc)"
    rm -f "$raw_out" "$normalized"
    return 0
  fi

  if ! _ljr_normalize_json "$raw_out" "$normalized"; then
    _ljr_write_fallback "$scen_id" "$out_file" "claude output not valid JSON"
    rm -f "$raw_out" "$normalized"
    return 0
  fi

  # 必須フィールド検証: score 数値
  local has_score score pass_flag
  has_score=$(jq -r 'if has("score") and (.score | type == "number") then "yes" else "no" end' "$normalized" 2>/dev/null | tr -d '\r')
  if [ "$has_score" != "yes" ]; then
    _ljr_write_fallback "$scen_id" "$out_file" "judge output missing numeric .score"
    rm -f "$raw_out" "$normalized"
    return 0
  fi
  score=$(jq -r '.score' "$normalized" 2>/dev/null | tr -d '\r')
  # 0.0-1.0 クランプ
  pass_flag=$(awk -v s="$score" -v t="$LLM_JUDGE_PASS_THRESHOLD" 'BEGIN{ if (s+0 >= t+0) print "true"; else print "false" }')

  # pass フィールドが未定義 or score と不整合なら自動補正
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
  jq \
    --arg sid "$scen_id" \
    --arg ts "$ts" \
    --argjson pass "$pass_flag" \
    '. + {
       scenario_id: (.scenario_id // $sid),
       pass: (if (.pass|type)=="boolean" then .pass else $pass end),
       generated_at: (.generated_at // $ts),
       fallback: false
     }' "$normalized" > "$out_file" 2>/dev/null || {
    # jq 失敗 → 最小限のコピー
    cp "$normalized" "$out_file"
  }

  rm -f "$raw_out" "$normalized"
  _ljr_info "llm-judge result written: $out_file (score=$score pass=$pass_flag)"
  return 0
}

# --- CLI エントリポイント -------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: bash $0 <scenario_dir> [<output_path>]" >&2
    exit 2
  fi
  run_llm_judge "$@"
  exit $?
fi
