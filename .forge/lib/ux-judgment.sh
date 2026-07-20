#!/bin/bash
# ux-judgment.sh — UX判定システム（3チャネル: 構造検査 / 模擬ユーザー / 美観ジャッジ）
# ralph-loop.sh から source される。dashboard.sh は集計関数のみ利用（source 安全）。
#
# 設計: .forge/docs/ux-judgment-and-calibration-spec.md
#   - 証拠の直交性: 機械検査(非LLM) / 行動証拠(sim-user) / 視覚評価(レンズ別ジャッジ)
#   - 全チャネル一致 → 自動処理（pass or fixタスク生成）/ 不一致 → record_and_continue
#   - 裁定は feedback.sh 経由でキャリブレーションに蓄積される
#
# 前提変数（ralph-loop.sh で定義済み。dashboard からは集計関数のみ呼ぶこと）:
#   PROJECT_ROOT, DEV_CONFIG, TASK_STACK, DEV_LOG_DIR, WORK_DIR
#   AGENTS_DIR, TEMPLATES_DIR, SCHEMAS_DIR, CRITERIA_FILE

UX_JUDGMENT_CONFIG="${UX_JUDGMENT_CONFIG:-${PROJECT_ROOT:-.}/.forge/config/ux-judgment.json}"
UX_LENSES_DIR="${UX_LENSES_DIR:-${PROJECT_ROOT:-.}/.forge/lenses}"
UX_SCENARIOS_FILE="${UX_SCENARIOS_FILE:-${PROJECT_ROOT:-.}/.forge/state/ux-scenarios.json}"

# run_ux_judgment_phase_exit が fix タスクを生成したかのフラグ
# （情報用 — advance するかの判定は main ループ側の pending 再カウントが正）
UX_JUDGMENT_TASKS_CREATED=false

# ===== 設定読み込み =====
load_ux_judgment_config() {
  UX_JUDGMENT_ENABLED=false
  [ -f "$UX_JUDGMENT_CONFIG" ] || return 0

  UX_JUDGMENT_ENABLED=$(jq_safe -r '.ux_judgment.enabled // false' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_APPLIES_TASK_TYPES=$(jq_safe -r '.ux_judgment.applies_to_task_types // ["implementation"] | join(",")' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  UX_AESTHETIC_MODEL=$(jq_safe -r '.ux_judgment.aesthetic.model // "opus"' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_AESTHETIC_TIMEOUT=$(jq_safe -r '.ux_judgment.aesthetic.timeout_sec // 600' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_MAX_LENSES=$(jq_safe -r '.ux_judgment.aesthetic.max_lenses // 2' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_MAX_MUST_FIX=$(jq_safe -r '.ux_judgment.aesthetic.max_must_fix_per_lens // 3' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  # 同一証拠チャネル内のレンズは2枚上限（相関による逓減 — §4.1）。設定値もハードキャップする
  [ "$UX_MAX_LENSES" -gt 2 ] 2>/dev/null && UX_MAX_LENSES=2

  UX_SIM_USER_MODEL=$(jq_safe -r '.ux_judgment.sim_user.model // "opus"' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_SIM_USER_TIMEOUT=$(jq_safe -r '.ux_judgment.sim_user.timeout_sec // 600' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_SIM_USER_MAX_SCENARIOS=$(jq_safe -r '.ux_judgment.sim_user.max_scenarios_per_run // 3' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  UX_SCENGEN_MODEL=$(jq_safe -r '.ux_judgment.scenario_generator.model // "opus"' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_SCENGEN_TIMEOUT=$(jq_safe -r '.ux_judgment.scenario_generator.timeout_sec // 300' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_SCENGEN_MAX_REGEN=$(jq_safe -r '.ux_judgment.scenario_generator.max_regenerations // 2' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  UX_AGGREGATOR_MODEL=$(jq_safe -r '.ux_judgment.aggregator.model // "opus"' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_AGGREGATOR_TIMEOUT=$(jq_safe -r '.ux_judgment.aggregator.timeout_sec // 300' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  UX_STRUCTURAL_TIMEOUT=$(jq_safe -r '.ux_judgment.structural.timeout_sec // 180' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_MIN_TAP=$(jq_safe -r '.ux_judgment.structural.min_tap_target_px // 24' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_MIN_CONTRAST=$(jq_safe -r '.ux_judgment.structural.min_contrast_ratio // 4.5' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  UX_ESCALATION_PAUSE=$(jq_safe -r '.ux_judgment.escalation.pause_on_disagreement // false' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  UX_MAX_FIX_PER_PHASE=$(jq_safe -r '.ux_judgment.max_ux_fix_tasks_per_phase // 6' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  # トランスクリプトゲートの動作: warn(既定 — 債務記録のみ) | invalid(結果無効化) | off
  # 実 debug ログ形式での較正が済むまで invalid にしない（誤爆でチャネルを殺さない — 監査 C-10）
  UX_TRANSCRIPT_GATE=$(jq_safe -r '.ux_judgment.sim_user.transcript_gate // "warn"' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  if [ "$UX_JUDGMENT_ENABLED" = "true" ]; then
    log "UX判定: 有効 (lenses=${UX_MAX_LENSES}, sim_user=${UX_SIM_USER_MODEL}, aesthetic=${UX_AESTHETIC_MODEL})"
  fi
  return 0
}

# ===== phase 別チャネル発火設定 =====
# ux_phase_setting <phase_id> <channel>  → per_task | phase_exit | off
# フォールバック: 未定義 phase 名は「最終 phase なら polish、それ以外は core」の設定を継承
ux_phase_setting() {
  local phase_id="$1"
  local channel="$2"
  [ -f "$UX_JUDGMENT_CONFIG" ] || { echo "off"; return 0; }

  local val
  val=$(jq_safe -r --arg p "$phase_id" --arg c "$channel" \
    '.ux_judgment.phase_config[$p][$c] // ""' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  if [ -n "$val" ]; then
    echo "$val"
    return 0
  fi

  # フォールバック（任意の phase 命名に対応）
  local fallback_key="core"
  if [ -n "${DEV_PHASES+x}" ] && [ "${#DEV_PHASES[@]}" -gt 0 ]; then
    local last_phase="${DEV_PHASES[${#DEV_PHASES[@]}-1]}"
    [ "$phase_id" = "$last_phase" ] && fallback_key="polish"
  fi
  val=$(jq_safe -r --arg p "$fallback_key" --arg c "$channel" \
    '.ux_judgment.phase_config[$p][$c] // "off"' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  echo "${val:-off}"
}

# ===== ベース URL =====
ux_base_url() {
  jq_safe -r '.server.health_check_url // ""' "${DEV_CONFIG:-/nonexistent}" 2>/dev/null
}

# ===== シナリオ生成の機械ゲート（文脈遮断検証） =====
# ux_scenarios_identifier_gate <scenarios_file> <criteria_file>
# criteria 内の識別子（camelCase / snake_case / ファイル名）が user_goal /
# success_signal に漏れていれば、一致した識別子を stdout に出力（空 = pass）
ux_scenarios_identifier_gate() {
  local scenarios_file="$1"
  local criteria_file="$2"
  { [ -f "$scenarios_file" ] && [ -f "$criteria_file" ]; } || { echo ""; return 0; }

  # 識別子の形: ファイル名/パス, camelCase, PascalCase, snake_case
  local ids
  ids=$(jq -r '.. | strings' "$criteria_file" 2>/dev/null | \
    grep -oE '[A-Za-z0-9_/-]+\.[A-Za-z]{2,4}|[a-z]+[A-Z][A-Za-z0-9]+|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*|[A-Za-z][a-z0-9]*_[a-z0-9_]+' | \
    sort -u | head -300)

  local texts
  texts=$(jq -r '.scenarios[]? | (.user_goal // "") + " " + (.success_signal // "")' \
    "$scenarios_file" 2>/dev/null)
  [ -z "$texts" ] && { echo ""; return 0; }

  local matched="" id
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    [ "${#id}" -lt 4 ] && continue  # 短語は誤検知源
    if printf '%s' "$texts" | grep -qF "$id"; then
      matched="${matched}${matched:+, }${id}"
    fi
  done <<< "$ids"
  printf '%s' "$matched"
}

# ===== シナリオ生成（ux-scenario-generator） =====
# run_ux_scenario_generator → 0=生成済み(既存含む) / 2=skip
run_ux_scenario_generator() {
  local criteria="${CRITERIA_FILE:-}"

  # 既に有効なシナリオがあり、かつ現 criteria の fingerprint と一致すれば再利用。
  # 不一致（別プロジェクトの残骸 — 監査 A-3）や fingerprint 欠落は再生成する
  if [ -f "$UX_SCENARIOS_FILE" ] && jq -e '.scenarios | length > 0' "$UX_SCENARIOS_FILE" > /dev/null 2>&1; then
    if [ -n "$criteria" ] && [ -f "$criteria" ]; then
      local _stored_fp _current_fp
      _stored_fp=$(jq_safe -r '.criteria_fingerprint // ""' "$UX_SCENARIOS_FILE" 2>/dev/null)
      _current_fp=$(md5sum "$criteria" 2>/dev/null | cut -d' ' -f1)
      if [ -n "$_stored_fp" ] && [ "$_stored_fp" = "$_current_fp" ]; then
        return 0
      fi
      log "  UX シナリオ: fingerprint 不一致（別 criteria の残骸）— 再生成"
    fi
  fi

  if [ -z "$criteria" ] || [ ! -f "$criteria" ]; then
    log "  ⚠ UX シナリオ生成: criteria 不在 — sim_user チャネル繰延"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "deferred_test" "ux-scenarios" \
        "implementation-criteria 不在のため UX シナリオ生成不可 — sim_user チャネル未実行"
    fi
    return 2
  fi
  if [ ! -f "${AGENTS_DIR}/ux-scenario-generator.md" ] || \
     [ ! -f "${TEMPLATES_DIR}/ux-scenario-generator-prompt.md" ]; then
    log "  ⚠ UX シナリオ生成: エージェント/テンプレート不在 — skip"
    return 2
  fi

  local criteria_json
  criteria_json=$(head -c 30000 "$criteria" 2>/dev/null)
  local base_url
  base_url=$(ux_base_url)

  local attempt=0 max_attempts=$((1 + ${UX_SCENGEN_MAX_REGEN:-2}))
  local rejected_note=""
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))

    local prompt
    prompt=$(render_template "${TEMPLATES_DIR}/ux-scenario-generator-prompt.md" \
      "CRITERIA_JSON"       "$criteria_json" \
      "ENTRY_URL"           "${base_url:-http://localhost:3000}" \
      "MAX_SCENARIOS"       "${UX_SIM_USER_MAX_SCENARIOS:-3}" \
      "REJECTED_TERMS_NOTE" "$rejected_note"
    )

    local ts
    ts=$(now_ts)
    local log_file="${DEV_LOG_DIR}/ux-scengen-${ts}.log"

    export _RC_CONTEXT_STRATEGY="reset"
    metrics_start
    if ! run_claude "${UX_SCENGEN_MODEL:-opus}" "${AGENTS_DIR}/ux-scenario-generator.md" \
      "$prompt" "$UX_SCENARIOS_FILE" "$log_file" \
      "WebSearch,WebFetch,Bash,Task" "${UX_SCENGEN_TIMEOUT:-300}" "" \
      "${SCHEMAS_DIR}/ux-scenarios.schema.json"; then
      metrics_record "ux-scenario-generator" "false"
      log "  ⚠ UX シナリオ生成: 実行エラー（attempt ${attempt}/${max_attempts}）"
      continue
    fi
    metrics_record "ux-scenario-generator" "true"

    if ! validate_json "$UX_SCENARIOS_FILE" "ux-scenarios"; then
      log "  ⚠ UX シナリオ生成: JSON 検証失敗（attempt ${attempt}/${max_attempts}）"
      continue
    fi

    # 機械ゲート: criteria 識別子の漏出チェック
    local matched
    matched=$(ux_scenarios_identifier_gate "$UX_SCENARIOS_FILE" "$criteria")
    if [ -z "$matched" ]; then
      ux_stamp_scenario_fingerprint "$criteria"
      log "  ✓ UX シナリオ生成完了: $(jq -r '.scenarios | length' "$UX_SCENARIOS_FILE" 2>/dev/null) 件"
      return 0
    fi

    log "  ⚠ UX シナリオ生成: 実装用語の漏出検出 [${matched}] — 再生成（attempt ${attempt}/${max_attempts}）"
    rejected_note="## 禁止語（前回の生成でリジェクトされた実装用語 — 使用禁止）
${matched}"
  done

  # 再生成上限到達: 品質債務に記録して最後の生成物のまま続行（§3.1）
  log "  ⚠ UX シナリオ生成: 識別子ゲート失敗のまま上限到達 — 債務記録して続行"
  if type record_quality_debt &>/dev/null; then
    record_quality_debt "warn_gate" "ux-scenarios" \
      "シナリオの実装用語漏出が再生成上限（${max_attempts}回）でも解消せず — 文脈遮断が不完全なまま使用"
  fi
  # 有効な JSON が残っていれば続行、無ければ skip
  if [ -f "$UX_SCENARIOS_FILE" ] && jq -e '.scenarios | length > 0' "$UX_SCENARIOS_FILE" > /dev/null 2>&1; then
    ux_stamp_scenario_fingerprint "$criteria"
    return 0
  fi
  return 2
}

# ===== criteria fingerprint 刻印 =====
# ux_stamp_scenario_fingerprint <criteria_file>
# シナリオファイルに生成元 criteria の md5 を記録（別プロジェクト残骸の再利用防止 — A-3）
ux_stamp_scenario_fingerprint() {
  local criteria="$1"
  { [ -f "$criteria" ] && [ -f "$UX_SCENARIOS_FILE" ]; } || return 0
  local fp
  fp=$(md5sum "$criteria" 2>/dev/null | cut -d' ' -f1)
  [ -z "$fp" ] && return 0
  jq --arg fp "$fp" '. + {criteria_fingerprint: $fp}' "$UX_SCENARIOS_FILE" \
    > "${UX_SCENARIOS_FILE}.tmp" 2>/dev/null && mv "${UX_SCENARIOS_FILE}.tmp" "$UX_SCENARIOS_FILE"
  return 0
}

# ===== Playwright MCP 設定ファイル生成（vision caps 付き — sim-user/judge 用） =====
# ux_build_mcp_config <output_path>
ux_build_mcp_config() {
  local out="$1"
  local mcp_command mcp_args headless
  mcp_command=$(jq_safe -r '.browser_testing.playwright_mcp.command // "npx"' "$DEV_CONFIG" 2>/dev/null)
  mcp_args=$(jq_safe -r '.browser_testing.playwright_mcp.args // []' "$DEV_CONFIG" 2>/dev/null)
  headless=$(jq_safe -r '.browser_testing.headless // true' "$DEV_CONFIG" 2>/dev/null)

  command -v "$mcp_command" > /dev/null 2>&1 || return 1

  jq -n --arg cmd "$mcp_command" --argjson args "$mcp_args" --arg headless "$headless" \
    '{mcpServers: {playwright: {command: $cmd,
       args: ($args + ["--caps=vision"] + (if $headless == "true" then ["--headless"] else [] end))}}}' \
    > "$out" 2>/dev/null
}

# ===== 知覚制限 disallowed-tools 構築 =====
# ux_sim_user_disallowed_tools → "mcp__playwright__browser_snapshot,...,Bash,Read,..."
ux_sim_user_disallowed_tools() {
  local browser_tools
  browser_tools=$(jq_safe -r '
    (.ux_judgment.sim_user.disallowed_browser_tools // []) |
    map(if startswith("browser_") then "mcp__playwright__" + . else . end) |
    join(",")' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  # 実装コード・外部情報へのアクセス遮断（文脈遮断の機械的強制）
  local core_tools="Bash,Read,Write,Edit,Grep,Glob,WebSearch,WebFetch,Task,TodoWrite,NotebookEdit"
  if [ -n "$browser_tools" ]; then
    echo "${browser_tools},${core_tools}"
  else
    echo "$core_tools"
  fi
}

# ===== トランスクリプト事後検証ゲート（§8-1 フォールバック） =====
# ux_transcript_gate <debug_log_file> → 0=クリーン / 1=禁止ツール使用検出
# 検出時は stdout に「ツール名 TAB マッチ行(先頭200字)」を出力（債務 detail 用）。
# --disallowed-tools が一次防御。本ゲートはツール名ドリフト等で素通りした場合の検出網
ux_transcript_gate() {
  local log_file="$1"
  [ -f "$log_file" ] || return 0

  local tools tool
  tools=$(jq_safe -r '.ux_judgment.sim_user.disallowed_browser_tools // [] | .[]' \
    "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  while IFS= read -r tool; do
    [ -z "$tool" ] && continue
    # 呼出シグネチャのみ検出（tools/list のカタログ列挙との誤検知を避ける）
    local matched_line
    matched_line=$(grep -E -m1 "tool_use.*${tool}\"|\"${tool}\".*tool_use" "$log_file" 2>/dev/null | head -c 200)
    if [ -n "$matched_line" ]; then
      log "  ⚠ UX sim-user: 禁止ツール使用検出 (${tool}) — gate=${UX_TRANSCRIPT_GATE:-warn}"
      printf '%s\t%s' "$tool" "$matched_line"
      return 1
    fi
  done <<< "$tools"
  return 0
}

# ===== 模擬ユーザーチャネル =====
# run_ux_sim_user_channel <phase_id> <out_dir>
# 出力: ${out_dir}/sim-user-results.json {results:[], verdict: pass|fail|skip}
run_ux_sim_user_channel() {
  local phase_id="$1"
  local out_dir="$2"

  if [ ! -f "${AGENTS_DIR}/ux-sim-user.md" ] || \
     [ ! -f "${TEMPLATES_DIR}/ux-sim-user-prompt.md" ]; then
    log "  ⚠ UX sim-user: エージェント/テンプレート不在 — skip"
    echo '{"results":[],"verdict":"skip","reason":"agent/template missing"}' > "${out_dir}/sim-user-results.json"
    return 0
  fi

  if ! run_ux_scenario_generator; then
    echo '{"results":[],"verdict":"skip","reason":"scenarios unavailable"}' > "${out_dir}/sim-user-results.json"
    return 0
  fi

  local mcp_config="${out_dir}/.ux-mcp-config.json"
  if ! ux_build_mcp_config "$mcp_config"; then
    log "  ⚠ UX sim-user: Playwright MCP 不可 — skip"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "env_blocked" "ux-${phase_id}" \
        "sim_user チャネルが Playwright MCP を要するが環境不足 — 未実行"
    fi
    echo '{"results":[],"verdict":"skip","reason":"playwright mcp unavailable"}' > "${out_dir}/sim-user-results.json"
    return 0
  fi

  local base_url
  base_url=$(ux_base_url)
  local disallowed
  disallowed=$(ux_sim_user_disallowed_tools)

  local n_scenarios
  n_scenarios=$(jq_safe -r '.scenarios | length' "$UX_SCENARIOS_FILE" 2>/dev/null || echo 0)
  case "$n_scenarios" in (*[!0-9]*|"") n_scenarios=0 ;; esac
  local max="${UX_SIM_USER_MAX_SCENARIOS:-3}"
  [ "$n_scenarios" -gt "$max" ] && n_scenarios=$max

  local i=0 results="[]"
  while [ "$i" -lt "$n_scenarios" ]; do
    local scenario sid goal entry budget viewport signal
    scenario=$(jq -c ".scenarios[$i]" "$UX_SCENARIOS_FILE" 2>/dev/null)
    sid=$(jq -r '.scenario_id' <<< "$scenario")
    goal=$(jq -r '.user_goal' <<< "$scenario")
    entry=$(jq -r '.entry_url // "/"' <<< "$scenario")
    budget=$(jq -r '.action_budget // 10' <<< "$scenario")
    viewport=$(jq -r '.viewport // "mobile"' <<< "$scenario")
    signal=$(jq -r '.success_signal // ""' <<< "$scenario")
    i=$((i + 1))

    local vp_size
    vp_size=$(jq_safe -r --arg v "$viewport" \
      '(.ux_judgment.structural.viewports // []) | map(select(.name == $v)) | first |
       if . then "\(.width)x\(.height)" else (if $v == "mobile" then "390x844" else "1440x900" end) end' \
      "$UX_JUDGMENT_CONFIG" 2>/dev/null)

    local entry_full="${base_url%/}${entry}"
    local ts
    ts=$(now_ts)
    local output="${out_dir}/sim-user-result-${sid}.json"
    local log_file="${out_dir}/sim-user-${sid}-${ts}.log"

    log "  UX sim-user [${sid}]: ${goal:0:50}... (viewport=${viewport}, budget=${budget})"

    local prompt
    prompt=$(render_template "${TEMPLATES_DIR}/ux-sim-user-prompt.md" \
      "SCENARIO_ID"     "$sid" \
      "USER_GOAL"       "$goal" \
      "ENTRY_URL"       "$entry_full" \
      "VIEWPORT"        "$viewport" \
      "VIEWPORT_SIZE"   "$vp_size" \
      "ACTION_BUDGET"   "$budget" \
      "SUCCESS_SIGNAL"  "$signal" \
      "TRANSCRIPT_PATH" "$log_file"
    )

    # 毎回フレッシュコンテキスト + 知覚制限 + 作業 cwd は out_dir（コードベース遮断）
    export _RC_CONTEXT_STRATEGY="reset"
    export _RC_MCP_CONFIG="$mcp_config"
    metrics_start
    local run_rc=0
    run_claude "${UX_SIM_USER_MODEL:-opus}" "${AGENTS_DIR}/ux-sim-user.md" \
      "$prompt" "$output" "$log_file" "$disallowed" "${UX_SIM_USER_TIMEOUT:-600}" "$out_dir" \
      "${SCHEMAS_DIR}/ux-sim-user.schema.json" || run_rc=$?
    unset _RC_MCP_CONFIG
    metrics_record "ux-sim-user-${sid}" "$([ "$run_rc" -eq 0 ] && echo true || echo false)"

    local entry_result
    if [ "$run_rc" -ne 0 ] || ! validate_json "$output" "ux-sim-user-${sid}"; then
      log "  ⚠ UX sim-user [${sid}]: 実行/検証失敗 — invalid"
      entry_result=$(jq -n --arg sid "$sid" '{scenario_id: $sid, valid: false, reason: "execution/validation failed"}')
    else
      # トランスクリプト事後ゲート（監査 C-10: 実ログ較正まで既定 warn — 債務記録のみ）
      local _gate_violation=""
      if [ "${UX_TRANSCRIPT_GATE:-warn}" != "off" ]; then
        _gate_violation=$(ux_transcript_gate "$log_file") || true
      fi
      if [ -n "$_gate_violation" ] && type record_quality_debt &>/dev/null; then
        record_quality_debt "warn_gate" "ux-${phase_id}" \
          "sim-user [${sid}] が知覚制限違反の疑い（gate=${UX_TRANSCRIPT_GATE:-warn}）: ${_gate_violation}"
      fi
      if [ -n "$_gate_violation" ] && [ "${UX_TRANSCRIPT_GATE:-warn}" = "invalid" ]; then
        entry_result=$(jq -n --arg sid "$sid" '{scenario_id: $sid, valid: false, reason: "perception restriction violated"}')
      else
        entry_result=$(jq --arg sid "$sid" --arg gv "$_gate_violation" \
          '. + {valid: true} + (if $gv == "" then {} else {transcript_gate: "violated"} end)' \
          "$output" 2>/dev/null)
        [ -z "$entry_result" ] && entry_result=$(jq -n --arg sid "$sid" '{scenario_id: $sid, valid: false, reason: "empty output"}')
        local _completed _viol
        _completed=$(jq -r '.completed // false' "$output" 2>/dev/null)
        _viol=$(jq -r '(.expectation_violations // []) | length' "$output" 2>/dev/null)
        log "  UX sim-user [${sid}]: completed=${_completed} violations=${_viol}"
      fi
    fi
    results=$(jq -c --argjson e "$entry_result" '. + [$e]' <<< "$results" 2>/dev/null || echo "$results")
  done

  # チャネル verdict: 有効結果のうち1件でも未完遂 → fail / 全完遂 → pass / 有効0件 → skip
  # interpretation は §3.2 の位置づけ明文化（テンプレートとレポート双方に記載する規定）
  local channel
  channel=$(jq -n --argjson r "$results" '
    ($r | map(select(.valid == true))) as $valid |
    {results: $r,
     valid_count: ($valid | length),
     completed_count: ($valid | map(select(.completed == true)) | length),
     friction: {
       expectation_violations: ($valid | map((.expectation_violations // []) | length) | add // 0),
       hesitations: ($valid | map((.hesitations // []) | length) | add // 0),
       backtracks: ($valid | map(.backtracks // 0) | add // 0)
     },
     interpretation: "完遂率の絶対値は信用しないこと。用途は (a) 修正前後の相対比較 (b) 摩擦イベントの検出。実ユーザーテストの代替ではなく下限フィルタである",
     verdict: (if ($valid | length) == 0 then "skip"
               elif ($valid | map(select(.completed != true)) | length) > 0 then "fail"
               else "pass" end)}')
  printf '%s\n' "$channel" > "${out_dir}/sim-user-results.json"
  log "  UX sim-user チャネル: $(jq -r '.verdict' <<< "$channel") (完遂 $(jq -r '.completed_count' <<< "$channel")/$(jq -r '.valid_count' <<< "$channel"))"

  # 実行を試みたのに有効結果 0 件（全 invalid）→ 判定不能を台帳に残す（監査 B-4）
  if [ "$n_scenarios" -gt 0 ] && \
     [ "$(jq -r '.valid_count' <<< "$channel")" = "0" ] && \
     type record_quality_debt &>/dev/null; then
    record_quality_debt "warn_gate" "ux-${phase_id}" \
      "sim_user チャネル: 全 ${n_scenarios} シナリオが実行失敗/invalid で判定不能 — チャネル未評価のまま続行"
  fi
  return 0
}

# ===== 美観ジャッジチャネル =====
# run_ux_aesthetic_channel <phase_id> <out_dir>
# 出力: ${out_dir}/aesthetic-results.json {lenses:[], verdict: pass|fail|skip}
run_ux_aesthetic_channel() {
  local phase_id="$1"
  local out_dir="$2"

  if [ ! -f "${AGENTS_DIR}/ux-aesthetic-judge.md" ] || \
     [ ! -f "${TEMPLATES_DIR}/ux-aesthetic-judge-prompt.md" ]; then
    log "  ⚠ UX 美観ジャッジ: エージェント/テンプレート不在 — skip"
    echo '{"lenses":[],"verdict":"skip","reason":"agent/template missing"}' > "${out_dir}/aesthetic-results.json"
    return 0
  fi

  local mcp_config="${out_dir}/.ux-mcp-config.json"
  if [ ! -f "$mcp_config" ] && ! ux_build_mcp_config "$mcp_config"; then
    log "  ⚠ UX 美観ジャッジ: Playwright MCP 不可 — skip"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "env_blocked" "ux-${phase_id}" \
        "aesthetic チャネルが Playwright MCP を要するが環境不足 — 未実行"
    fi
    echo '{"lenses":[],"verdict":"skip","reason":"playwright mcp unavailable"}' > "${out_dir}/aesthetic-results.json"
    return 0
  fi

  local base_url viewports_desc scenarios_summary
  base_url=$(ux_base_url)
  viewports_desc=$(jq_safe -r '(.ux_judgment.structural.viewports // []) |
    map("\(.name) (\(.width)x\(.height))") | join(" / ")' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  [ -z "$viewports_desc" ] && viewports_desc="mobile (390x844) / desktop (1440x900)"
  scenarios_summary=$(jq -r '.scenarios[]? | "- " + .user_goal' "$UX_SCENARIOS_FILE" 2>/dev/null | head -5)
  [ -z "$scenarios_summary" ] && scenarios_summary="（シナリオ未生成 — エントリ URL から自然に探索すること）"

  # 遮断は「判定素材の DOM 化」経路のみ（evaluate/run_code/console/network）+ コードベース遮断。
  # browser_snapshot はナビゲーション補助として意図的に許可する — 判定根拠を
  # スクリーンショットに限定する縛りはエージェント定義（ux-aesthetic-judge.md）側で担保
  local judge_disallowed="mcp__playwright__browser_evaluate,mcp__playwright__browser_run_code_unsafe,mcp__playwright__browser_console_messages,mcp__playwright__browser_network_requests,mcp__playwright__browser_network_request,Bash,Read,Write,Edit,Grep,Glob,WebSearch,WebFetch,Task,TodoWrite,NotebookEdit"

  # 人間裁定の Few-Shot 較正（feedback.sh の ux-judgment 記録を還流 — 監査 B-5）
  local cal_examples=""
  if type get_calibration_examples &>/dev/null; then
    cal_examples=$(get_calibration_examples "ux-judgment" 3)
  fi
  [ -z "$cal_examples" ] && cal_examples="（キャリブレーションデータなし — デフォルト判定基準を使用）"

  local lenses lens results="[]"
  lenses=$(jq_safe -r '.ux_judgment.aesthetic.lenses // ["lens-taste","lens-usability"] | .[]' \
    "$UX_JUDGMENT_CONFIG" 2>/dev/null | head -"${UX_MAX_LENSES:-2}")

  while IFS= read -r lens; do
    [ -z "$lens" ] && continue
    local lens_file="${UX_LENSES_DIR}/${lens}.md"
    if [ ! -f "$lens_file" ]; then
      log "  ⚠ UX 美観ジャッジ: レンズ定義不在 (${lens}) — skip"
      continue
    fi

    local ts
    ts=$(now_ts)
    local output="${out_dir}/aesthetic-judge-${lens}.json"
    local log_file="${out_dir}/aesthetic-${lens}-${ts}.log"

    log "  UX 美観ジャッジ [${lens}]: 実行中..."

    local prompt
    prompt=$(render_template "${TEMPLATES_DIR}/ux-aesthetic-judge-prompt.md" \
      "LENS_ID"              "$lens" \
      "LENS_DEFINITION"      "$(cat "$lens_file")" \
      "ENTRY_URL"            "${base_url%/}/" \
      "VIEWPORTS"            "$viewports_desc" \
      "SCENARIOS_SUMMARY"    "$scenarios_summary" \
      "MAX_MUST_FIX"         "${UX_MAX_MUST_FIX:-3}" \
      "CALIBRATION_EXAMPLES" "$cal_examples"
    )

    export _RC_CONTEXT_STRATEGY="reset"
    export _RC_MCP_CONFIG="$mcp_config"
    metrics_start
    local run_rc=0
    run_claude "${UX_AESTHETIC_MODEL:-opus}" "${AGENTS_DIR}/ux-aesthetic-judge.md" \
      "$prompt" "$output" "$log_file" "$judge_disallowed" "${UX_AESTHETIC_TIMEOUT:-600}" "$out_dir" \
      "${SCHEMAS_DIR}/ux-aesthetic-judge.schema.json" || run_rc=$?
    unset _RC_MCP_CONFIG
    metrics_record "ux-aesthetic-${lens}" "$([ "$run_rc" -eq 0 ] && echo true || echo false)"

    if [ "$run_rc" -eq 0 ] && validate_json "$output" "ux-aesthetic-${lens}"; then
      local lens_result
      lens_result=$(jq --arg l "$lens" '. + {lens_id: $l, valid: true}' "$output" 2>/dev/null)
      results=$(jq -c --argjson e "$lens_result" '. + [$e]' <<< "$results" 2>/dev/null || echo "$results")
      log "  UX 美観ジャッジ [${lens}]: $(jq -r '.verdict' "$output" 2>/dev/null) (must_fix=$(jq -r '.must_fix | length' "$output" 2>/dev/null))"
    else
      log "  ⚠ UX 美観ジャッジ [${lens}]: 実行/検証失敗 — invalid"
      results=$(jq -c --arg l "$lens" '. + [{lens_id: $l, valid: false}]' <<< "$results" 2>/dev/null || echo "$results")
    fi
  done <<< "$lenses"

  local channel
  channel=$(jq -n --argjson r "$results" '
    ($r | map(select(.valid == true))) as $valid |
    {lenses: $r,
     verdict: (if ($valid | length) == 0 then "skip"
               elif ($valid | map(select(.verdict == "fix_needed")) | length) > 0 then "fail"
               else "pass" end)}')
  printf '%s\n' "$channel" > "${out_dir}/aesthetic-results.json"
  log "  UX 美観チャネル: $(jq -r '.verdict' <<< "$channel")"

  # 実行を試みたのに有効結果 0 件（全レンズ invalid）→ 判定不能を台帳に残す（監査 B-4）
  local _aes_attempted
  _aes_attempted=$(jq -r '.lenses | length' <<< "$channel" 2>/dev/null)
  if [ "${_aes_attempted:-0}" -gt 0 ] && \
     [ "$(jq -r '[.lenses[] | select(.valid == true)] | length' <<< "$channel")" = "0" ] && \
     type record_quality_debt &>/dev/null; then
    record_quality_debt "warn_gate" "ux-${phase_id}" \
      "aesthetic チャネル: 全 ${_aes_attempted} レンズが実行失敗/invalid で判定不能 — チャネル未評価のまま続行"
  fi
  return 0
}

# ===== 構造検査チャネル =====
# run_ux_structural_channel <phase_id> <out_dir>
# 出力: ${out_dir}/structural-result.json（execute_structural_check の生成 + verdict skip 包装）
run_ux_structural_channel() {
  local phase_id="$1"
  local out_dir="$2"

  # browser-test.sh を遅延 source（execute_structural_check）
  if ! type execute_structural_check &>/dev/null; then
    if [ -f "${PROJECT_ROOT}/.forge/lib/browser-test.sh" ]; then
      source "${PROJECT_ROOT}/.forge/lib/browser-test.sh"
    fi
  fi
  if ! type execute_structural_check &>/dev/null; then
    echo '{"verdict":"skip","reason":"browser-test lib missing"}' > "${out_dir}/structural-result.json"
    return 0
  fi

  local base_url
  base_url=$(ux_base_url)
  local viewports
  viewports=$(jq_safe -c '.ux_judgment.structural.viewports // []' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  local rc=0
  execute_structural_check "${base_url%/}/" "${out_dir}/structural-result.json" \
    "${WORK_DIR:-.}" "$viewports" "${UX_MIN_TAP:-24}" "${UX_MIN_CONTRAST:-4.5}" \
    "${UX_STRUCTURAL_TIMEOUT:-180}" > /dev/null 2>&1 || rc=$?

  if [ "$rc" -eq 2 ]; then
    log "  UX 構造検査: skip（環境不足）"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "env_blocked" "ux-${phase_id}" \
        "structural チャネルが node/playwright を要するが環境不足 — 未実行"
    fi
    echo '{"verdict":"skip","reason":"environment insufficient"}' > "${out_dir}/structural-result.json"
    return 0
  fi
  log "  UX 構造検査: $(jq_safe -r '.verdict // "?"' "${out_dir}/structural-result.json" 2>/dev/null) (violations=$(jq_safe -r '.summary.violations_total // "?"' "${out_dir}/structural-result.json" 2>/dev/null))"
  return 0
}

# ===== fix タスク生成 =====
# create_ux_fix_tasks <phase_id> <must_fix_json_array>
# 生成したタスク数を echo。cap / dedup 適用
create_ux_fix_tasks() {
  local phase_id="$1"
  local must_fix_json="$2"
  local created=0

  local existing_count
  existing_count=$(jq_safe --arg p "ux-fix-${phase_id}-" \
    '[.tasks[] | select(.task_id | startswith($p))] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  case "$existing_count" in (*[!0-9]*|"") existing_count=0 ;; esac

  local n
  n=$(jq 'length' <<< "$must_fix_json" 2>/dev/null || echo 0)
  case "$n" in (*[!0-9]*|"") n=0 ;; esac
  local i=0
  while [ "$i" -lt "$n" ]; do
    local item title criteria channel lens
    item=$(jq -c ".[$i]" <<< "$must_fix_json")
    i=$((i + 1))
    title=$(jq -r '.title // ""' <<< "$item")
    criteria=$(jq -r '.resolution_criteria // ""' <<< "$item")
    channel=$(jq -r '.origin_channel // "unknown"' <<< "$item")
    lens=$(jq -r '.origin_lens // ""' <<< "$item")
    [ -z "$title" ] && continue
    # 機械フィルタ: resolution_criteria 空は生成しない（反証不能の最低ライン）
    [ -z "$criteria" ] && continue

    # dedup: 同一タイトルの pending ux-fix が既存なら skip
    local dup
    dup=$(jq_safe --arg t "UX修正: ${title}" \
      '[.tasks[] | select(.status == "pending" and .description == $t)] | length' \
      "$TASK_STACK" 2>/dev/null || echo 0)
    case "$dup" in (*[!0-9]*|"") dup=0 ;; esac
    if [ "${dup:-0}" -gt 0 ]; then
      log "  UX fix タスク重複検出 — skip: ${title:0:40}"
      continue
    fi

    # cap: phase 毎の総数上限（futile ループ防波堤）
    if [ $((existing_count + created)) -ge "${UX_MAX_FIX_PER_PHASE:-6}" ]; then
      log "  ⚠ UX fix タスク生成拒否: phase=${phase_id} の上限（${UX_MAX_FIX_PER_PHASE}）到達"
      if type record_quality_debt &>/dev/null; then
        record_quality_debt "fix_cap_reached" "ux-${phase_id}" \
          "UX fix タスクが phase 上限（${UX_MAX_FIX_PER_PHASE}）到達 — 以後の生成を停止。残 must_fix: ${title:0:80}"
      fi
      break
    fi

    local fix_id="ux-fix-${phase_id}-$((existing_count + created + 1))-$(date +%H%M%S)"
    jq --arg fix_id "$fix_id" \
       --arg desc "UX修正: ${title}" \
       --arg phase "$phase_id" \
       --arg detail "$(jq -r '"問題: " + (.description // "") + "\n解決条件 (resolution_criteria): " + (.resolution_criteria // "")' <<< "$item")" \
       --arg lens "$lens" \
       --arg channel "$channel" \
       '
      .tasks += [{
        task_id: $fix_id,
        description: $desc,
        task_type: "implementation",
        dev_phase_id: $phase,
        depends_on: [],
        status: "pending",
        fail_count: 0,
        investigator_fix: ("UX判定による差戻し:\n" + $detail),
        retry_after_investigation: false,
        validation: {},
        allows_test_edits: true,
        ux_fix_for: ("ux-" + $phase),
        origin_lens: (if $lens == "" then null else $lens end),
        origin_channel: $channel,
        created_at: (now | todate),
        updated_at: (now | todate)
      }] |
      .updated_at = (now | todate)
    ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"

    record_task_event "$fix_id" "ux_fix_created" \
      "$(jq -n -c --arg l "$lens" --arg c "$channel" --arg p "$phase_id" \
        '{origin_lens: $l, origin_channel: $c, phase_id: $p}')"
    created=$((created + 1))
    log "  UX fix タスク追加: ${fix_id} — ${title:0:50}"
  done

  type sync_task_stack &>/dev/null && sync_task_stack
  echo "$created"
}

# ===== 集約（機械的 verdict 突合 + LLM 調停） =====
# run_ux_aggregation <phase_id> <out_dir>
# 出力: ${out_dir}/ux-judgment-result.json
# 全チャネル一致 pass → pass / 一致 fail → fix（LLM 集約 → fix タスク生成）/
# 不一致 → エスカレーション（record_and_continue: 債務 + 通知 + 暫定 pass）
run_ux_aggregation() {
  local phase_id="$1"
  local out_dir="$2"

  local v_struct v_sim v_aes
  v_struct=$(jq_safe -r '.verdict // "skip"' "${out_dir}/structural-result.json" 2>/dev/null || echo "skip")
  v_sim=$(jq_safe -r '.verdict // "skip"' "${out_dir}/sim-user-results.json" 2>/dev/null || echo "skip")
  v_aes=$(jq_safe -r '.verdict // "skip"' "${out_dir}/aesthetic-results.json" 2>/dev/null || echo "skip")

  local active_verdicts=""
  for v in "$v_struct" "$v_sim" "$v_aes"; do
    [ "$v" = "pass" ] || [ "$v" = "fail" ] && active_verdicts="${active_verdicts} ${v}"
  done

  local final_verdict must_fix="[]" escalated=false
  if [ -z "$active_verdicts" ]; then
    final_verdict="skip"
    log "  UX 判定: 全チャネル skip — 判定なし"
  elif ! grep -q "fail" <<< "$active_verdicts"; then
    final_verdict="pass"
    log "  ✓ UX 判定: 全チャネル一致 pass"
  elif ! grep -q "pass" <<< "$active_verdicts"; then
    # 全チャネル一致 fail → LLM 集約で統合 must_fix を作る
    final_verdict="fix"
    must_fix=$(ux_run_aggregator_llm "$phase_id" "$out_dir")
  else
    # 不一致 → エスカレーション
    final_verdict="escalated"
    escalated=true
    ux_escalate_disagreement "$phase_id" "$out_dir" "$v_struct" "$v_sim" "$v_aes"
  fi

  # 最終結果を書き出し（feedback.sh の記録対象: evaluator "ux-judgment"）
  jq -n \
    --arg phase "$phase_id" \
    --arg verdict "$final_verdict" \
    --arg vs "$v_struct" --arg vu "$v_sim" --arg va "$v_aes" \
    --argjson mf "$must_fix" \
    --argjson esc "$escalated" \
    --arg ts "$(date -Iseconds)" \
    '{phase_id: $phase, verdict: $verdict,
      channel_verdicts: {structural: $vs, sim_user: $vu, aesthetic: $va},
      must_fix: $mf, escalated: $esc, generated_at: $ts}' \
    > "${out_dir}/ux-judgment-result.json"

  # fix 経路: タスク生成
  if [ "$final_verdict" = "fix" ]; then
    local created
    created=$(create_ux_fix_tasks "$phase_id" "$must_fix")
    if [ "${created:-0}" -gt 0 ]; then
      UX_JUDGMENT_TASKS_CREATED=true
      log "  UX 判定: fix タスク ${created} 件生成 — phase 続行"
    else
      # 黙って劣化しない: fix 判定が未対処のまま phase を通過する事実を台帳に残す（監査 B-4）
      log "  UX 判定: fix 判定だが生成可能なタスクなし（cap/dedup/criteria不備）"
      if type record_quality_debt &>/dev/null; then
        local _mf_summary
        _mf_summary=$(jq -r 'map(.title // "?") | join(" / ")' <<< "$must_fix" 2>/dev/null | head -c 200)
        record_quality_debt "ux_unactionable" "ux-${phase_id}" \
          "UX判定 fix だが実行可能な fix タスク 0 件（全リジェクト/cap/dedup）— 未対処のまま phase 通過。must_fix: ${_mf_summary:-なし}"
      fi
    fi
  fi
  return 0
}

# ===== LLM 集約器の実行 =====
# ux_run_aggregator_llm <phase_id> <out_dir> → 統合 must_fix JSON 配列を stdout
# 失敗時は機械的フォールバック（各チャネルの must_fix を素通しで最大3件）
ux_run_aggregator_llm() {
  local phase_id="$1"
  local out_dir="$2"

  local structural sim_user aesthetic
  structural=$(head -c 15000 "${out_dir}/structural-result.json" 2>/dev/null || echo '{}')
  sim_user=$(head -c 15000 "${out_dir}/sim-user-results.json" 2>/dev/null || echo '{}')
  aesthetic=$(head -c 20000 "${out_dir}/aesthetic-results.json" 2>/dev/null || echo '{}')

  local agg_output="${out_dir}/aggregator-result.json"
  if [ -f "${AGENTS_DIR}/ux-aggregator.md" ] && [ -f "${TEMPLATES_DIR}/ux-aggregator-prompt.md" ]; then
    # 人間裁定の Few-Shot 較正（監査 B-5）
    local cal_examples=""
    if type get_calibration_examples &>/dev/null; then
      cal_examples=$(get_calibration_examples "ux-judgment" 3)
    fi
    [ -z "$cal_examples" ] && cal_examples="（キャリブレーションデータなし — デフォルト判定基準を使用）"

    local prompt
    prompt=$(render_template "${TEMPLATES_DIR}/ux-aggregator-prompt.md" \
      "MAX_MUST_FIX"         "${UX_MAX_MUST_FIX:-3}" \
      "STRUCTURAL_RESULT"    "$structural" \
      "SIM_USER_RESULTS"     "$sim_user" \
      "AESTHETIC_RESULTS"    "$aesthetic" \
      "CALIBRATION_EXAMPLES" "$cal_examples"
    )
    local ts
    ts=$(now_ts)
    export _RC_CONTEXT_STRATEGY="reset"
    metrics_start
    local rc=0
    run_claude "${UX_AGGREGATOR_MODEL:-opus}" "${AGENTS_DIR}/ux-aggregator.md" \
      "$prompt" "$agg_output" "${out_dir}/aggregator-${ts}.log" \
      "WebSearch,WebFetch,Bash,Task" "${UX_AGGREGATOR_TIMEOUT:-300}" "" \
      "${SCHEMAS_DIR}/ux-aggregator.schema.json" || rc=$?
    metrics_record "ux-aggregator-${phase_id}" "$([ "$rc" -eq 0 ] && echo true || echo false)"

    if [ "$rc" -eq 0 ] && validate_json "$agg_output" "ux-aggregator-${phase_id}"; then
      # 機械的後検証: 上限 + resolution_criteria 非空を強制
      jq -c --argjson max "${UX_MAX_MUST_FIX:-3}" \
        '[.must_fix[]? | select((.resolution_criteria // "") != "")] | .[0:$max]' \
        "$agg_output" 2>/dev/null && return 0
    fi
  fi

  # フォールバック: 美観 must_fix + 構造違反の機械合成（LLM 調停なし）
  log "  ⚠ UX 集約器: LLM 集約失敗 — 機械的フォールバック"
  jq -n -c --argjson max "${UX_MAX_MUST_FIX:-3}" \
    --slurpfile aes "${out_dir}/aesthetic-results.json" \
    --slurpfile str "${out_dir}/structural-result.json" '
    ((($str[0].checks // []) | map(select(.pass == false)) | map({
        title: ("構造検査違反: " + .check + " (" + .viewport + ")"),
        description: ((.violations // []) | map(.detail // "") | join("; ") | .[0:300]),
        resolution_criteria: (.check + " の violation_count を 0 にする"),
        origin_channel: "structural"
      })) +
     (($aes[0].lenses // []) | map(select(.valid == true)) |
       map(.lens_id as $l | (.must_fix // [])[] | . + {origin_channel: "aesthetic", origin_lens: $l}))
    ) | map(select((.resolution_criteria // "") != "")) | .[0:$max]' \
    2>/dev/null || echo "[]"
}

# ===== エスカレーション（record_and_continue — §6） =====
ux_escalate_disagreement() {
  local phase_id="$1"
  local out_dir="$2"
  local v_struct="$3" v_sim="$4" v_aes="$5"

  local summary="チャネル不一致: structural=${v_struct} sim_user=${v_sim} aesthetic=${v_aes}"
  log "  ⚠ UX 判定: ${summary} — エスカレーション（record_and_continue）"

  if type record_quality_debt &>/dev/null; then
    record_quality_debt "ux_disagreement" "ux-${phase_id}" \
      "${summary} — 暫定 pass で続行。人間裁定待ち" \
      "$(jq -n -c --arg s "$v_struct" --arg u "$v_sim" --arg a "$v_aes" \
        '{channel_verdicts: {structural: $s, sim_user: $u, aesthetic: $a}}')"
  fi
  notify_human "warning" "UX判定 チャネル不一致 (phase=${phase_id})" \
    "${summary}\n詳細: ${out_dir}/\n裁定: bash .forge/loops/feedback.sh ux-${phase_id} <reject|accept-with-notes> \"理由\""

  # pause_on_disagreement: 対話モードのみ read 待ち（デーモンでは respected されず続行）
  if [ "${UX_ESCALATION_PAUSE:-false}" = "true" ] && [ -t 0 ]; then
    echo -e "  UX判定が不一致です。Enter で続行 / 'q' で中断: " >&2
    local _ans
    read -t 300 -r _ans 2>/dev/null || _ans=""
    if [ "$_ans" = "q" ] || [ "$_ans" = "Q" ]; then
      # 人間の明示的中断は regression_failure_policy の warn 経路に飲ませず即終了する。
      # サーバーは明示停止し、残処理（in_progress → interrupted 等）は
      # ralph-loop の trap _cleanup_on_exit が行う
      log "UX エスカレーションで中断（人間判断）"
      type teardown_server &>/dev/null && teardown_server 2>/dev/null || true
      exit 20
    fi
  fi
  return 0
}

# ===== phase_exit 発火（dev-phases から呼ばれる） =====
# run_ux_judgment_phase_exit <phase_id>
# 常に rc=0（advisory 統合 — dev ループをブロックしない。fix はタスク生成で表現）
run_ux_judgment_phase_exit() {
  local phase_id="$1"
  UX_JUDGMENT_TASKS_CREATED=false

  # per_task 構造検査の negative cache を phase 境界でリセット
  # （フェーズが進めばアプリが起動可能になっている可能性がある — 監査 C-6）
  _UX_PER_TASK_SERVER_SKIP=false
  _UX_PER_TASK_SERVER_FAILS=0

  [ "${UX_JUDGMENT_ENABLED:-false}" = "true" ] || return 0

  local s_struct s_sim s_aes
  s_struct=$(ux_phase_setting "$phase_id" "structural")
  s_sim=$(ux_phase_setting "$phase_id" "sim_user")
  s_aes=$(ux_phase_setting "$phase_id" "aesthetic")

  # phase_exit 対象チャネルが無ければ何もしない
  if [ "$s_sim" != "phase_exit" ] && [ "$s_aes" != "phase_exit" ] && [ "$s_struct" != "phase_exit" ]; then
    return 0
  fi

  local out_dir="${DEV_LOG_DIR}/ux-${phase_id}"
  mkdir -p "$out_dir"
  log ""
  log "========== UX 判定 (phase=${phase_id}: structural=${s_struct} sim_user=${s_sim} aesthetic=${s_aes}) =========="

  # サーバー到達性（全ブラウザチャネルの前提）
  local base_url
  base_url=$(ux_base_url)
  local srv_rc=0
  if type ensure_server_running &>/dev/null; then
    ensure_server_running || srv_rc=$?
  fi
  if [ -z "$base_url" ] || [ "$srv_rc" -ne 0 ]; then
    log "  ⚠ UX 判定: サーバー到達不能（${SERVER_LC_REASON:-health_check_url 未設定}）— 全チャネル繰延"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "env_blocked" "ux-${phase_id}" \
        "UX 判定がサーバーを要するが到達不能: ${SERVER_LC_REASON:-health_check_url 未設定}"
    fi
    return 0
  fi

  # 構造検査は phase_exit 指定でなくても、他チャネルが走るなら集約のため実行する
  # （per_task の最新結果はタスク粒度でありフェーズ全体の代表にならないため）
  run_ux_structural_channel "$phase_id" "$out_dir"

  if [ "$s_sim" = "phase_exit" ]; then
    run_ux_sim_user_channel "$phase_id" "$out_dir"
  else
    echo '{"results":[],"verdict":"skip","reason":"channel off for this phase"}' > "${out_dir}/sim-user-results.json"
  fi

  if [ "$s_aes" = "phase_exit" ]; then
    run_ux_aesthetic_channel "$phase_id" "$out_dir"
  else
    echo '{"lenses":[],"verdict":"skip","reason":"channel off for this phase"}' > "${out_dir}/aesthetic-results.json"
  fi

  run_ux_aggregation "$phase_id" "$out_dir"
  log "========== UX 判定終了 (phase=${phase_id}) =========="
  return 0
}

# ===== per_task 構造検査（advisory — task_finalize から呼ばれる） =====
# run_ux_structural_per_task <task_id> <task_dir> <task_json>
# 常に rc=0。結果は task_dir に保存し、違反は warn ログ + task event のみ
# （権威ある判定は phase_exit の集約 — ここは早期シグナルの телеметリ）
run_ux_structural_per_task() {
  local task_id="$1"
  local task_dir="$2"
  local task_json="$3"

  [ "${UX_JUDGMENT_ENABLED:-false}" = "true" ] || return 0

  # task_type フィルタ
  local task_type
  task_type=$(jq_safe -r '.task_type // "implementation"' <<< "$task_json" 2>/dev/null)
  case ",${UX_APPLIES_TASK_TYPES:-implementation}," in
    (*",${task_type},"*) ;;
    (*) return 0 ;;
  esac

  # phase 設定
  local phase_id
  phase_id=$(jq_safe -r '.dev_phase_id // "mvp"' <<< "$task_json" 2>/dev/null)
  [ "$(ux_phase_setting "$phase_id" "structural")" = "per_task" ] || return 0

  local base_url
  base_url=$(ux_base_url)
  [ -z "$base_url" ] && return 0

  # negative cache（監査 C-6）: rc=1（実起動試行の失敗）は startup_timeout 分の
  # コストが毎タスクかかるため、2回連続で失敗したら phase 完了まで検査を skip する。
  # rc=2（start_command=none 等）は即時 return の低コスト経路なのでキャッシュしない
  if [ "${_UX_PER_TASK_SERVER_SKIP:-false}" = "true" ]; then
    return 0
  fi

  # サーバー起動（環境不足は 1 回だけ debt 記録して以後静かにスキップ）
  local srv_rc=0
  if type ensure_server_running &>/dev/null; then
    ensure_server_running || srv_rc=$?
  fi
  if [ "$srv_rc" -ne 0 ]; then
    if [ "$srv_rc" -eq 1 ]; then
      _UX_PER_TASK_SERVER_FAILS=$(( ${_UX_PER_TASK_SERVER_FAILS:-0} + 1 ))
      if [ "$_UX_PER_TASK_SERVER_FAILS" -ge 2 ]; then
        _UX_PER_TASK_SERVER_SKIP=true
        log "  UX 構造検査 (per_task): サーバー起動失敗 ${_UX_PER_TASK_SERVER_FAILS} 回連続 — phase 完了まで skip"
      fi
    fi
    if [ "${_UX_PER_TASK_ENV_DEBT_RECORDED:-false}" != "true" ]; then
      _UX_PER_TASK_ENV_DEBT_RECORDED=true
      if type record_quality_debt &>/dev/null; then
        record_quality_debt "env_blocked" "$task_id" \
          "per_task 構造検査がサーバーを要するが到達不能（${SERVER_LC_REASON:-不明}）— このセッションでは以後スキップ"
      fi
    fi
    return 0
  fi
  _UX_PER_TASK_SERVER_FAILS=0

  if ! type execute_structural_check &>/dev/null; then
    [ -f "${PROJECT_ROOT}/.forge/lib/browser-test.sh" ] && source "${PROJECT_ROOT}/.forge/lib/browser-test.sh"
  fi
  type execute_structural_check &>/dev/null || return 0

  local viewports
  viewports=$(jq_safe -c '.ux_judgment.structural.viewports // []' "$UX_JUDGMENT_CONFIG" 2>/dev/null)

  local rc=0
  execute_structural_check "${base_url%/}/" "${task_dir}/ux-structural-result.json" \
    "${WORK_DIR:-.}" "$viewports" "${UX_MIN_TAP:-24}" "${UX_MIN_CONTRAST:-4.5}" \
    "${UX_STRUCTURAL_TIMEOUT:-180}" > /dev/null 2>&1 || rc=$?

  if [ "$rc" -eq 1 ]; then
    local vt
    vt=$(jq_safe -r '.summary.violations_total // "?"' "${task_dir}/ux-structural-result.json" 2>/dev/null)
    log "  ⚠ UX 構造検査 (per_task): 違反 ${vt} 件 — advisory（詳細: ${task_dir}/ux-structural-result.json）"
    record_task_event "$task_id" "ux_structural_violations" "{\"violations\":\"${vt}\"}"
  elif [ "$rc" -eq 0 ]; then
    log "  ✓ UX 構造検査 (per_task): pass"
  fi
  return 0
}

# ===== レンズ実測プルーニング集計（P2） =====
# compute_lens_acceptance_rates [events_file] [calibration_file] [task_stack]
# accepted-finding rate = fix タスクのうち completed かつ人間 reject 無しの割合（直近 window 件）
# stdout: "lens-taste: 4/10 (40%) ⚠ 閾値(50%)未満 — 無効化候補" 形式の行群（データなしは空）
compute_lens_acceptance_rates() {
  local events_file="${1:-${PROJECT_ROOT:-.}/.forge/state/task-events.jsonl}"
  local cal_file="${2:-${PROJECT_ROOT:-.}/.forge/state/calibration-data.jsonl}"
  local stack="${3:-${PROJECT_ROOT:-.}/.forge/state/task-stack.json}"
  { [ -f "$events_file" ] && [ -s "$events_file" ]; } || return 0

  local window threshold
  window=$(jq_safe -r '.ux_judgment.lens_pruning.window // 10' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  threshold=$(jq_safe -r '.ux_judgment.lens_pruning.warn_threshold // 0.5' "$UX_JUDGMENT_CONFIG" 2>/dev/null)
  case "$window" in (*[!0-9]*|"") window=10 ;; esac

  # レンズ別に ux_fix_created イベントを収集（origin_lens 非空のみ）
  local lenses
  lenses=$(jq_safe -s -r '
    [ .[] | select(.event == "ux_fix_created") |
      (.detail.origin_lens // "") | select(. != "") ] | unique | .[]' \
    "$events_file" 2>/dev/null)
  [ -z "$lenses" ] && return 0

  local lens
  while IFS= read -r lens; do
    [ -z "$lens" ] && continue
    local task_ids
    task_ids=$(jq_safe -s -r --arg l "$lens" --argjson w "$window" '
      [ .[] | select(.event == "ux_fix_created" and (.detail.origin_lens // "") == $l) |
        .task_id ] | .[-$w:] | .[]' "$events_file" 2>/dev/null)
    local total=0 accepted=0 tid
    while IFS= read -r tid; do
      [ -z "$tid" ] && continue
      total=$((total + 1))
      # completed 判定: 現 task-stack の status か、イベントログの status_changed=completed
      local is_completed="false"
      if [ -f "$stack" ]; then
        is_completed=$(jq_safe -r --arg t "$tid" \
          '[.tasks[]? | select(.task_id == $t and .status == "completed")] | length > 0' \
          "$stack" 2>/dev/null)
      fi
      if [ "$is_completed" != "true" ]; then
        is_completed=$(jq_safe -s -r --arg t "$tid" \
          '[ .[] | select(.task_id == $t and .event == "status_changed" and
             (.detail.new_status // "") == "completed") ] | length > 0' \
          "$events_file" 2>/dev/null)
      fi
      [ "$is_completed" != "true" ] && continue
      # 人間 reject チェック
      local rejected="false"
      if [ -f "$cal_file" ] && [ -s "$cal_file" ]; then
        if grep -F "\"task_id\":\"${tid}\"" "$cal_file" 2>/dev/null | \
           grep -qF '"human_judgment":"reject"'; then
          rejected="true"
        fi
      fi
      [ "$rejected" = "false" ] && accepted=$((accepted + 1))
    done <<< "$task_ids"

    [ "$total" -eq 0 ] && continue
    local pct=$((accepted * 100 / total))
    local threshold_pct
    threshold_pct=$(awk -v t="$threshold" 'BEGIN{printf "%d", t * 100}' 2>/dev/null || echo 50)
    case "$threshold_pct" in (*[!0-9]*|"") threshold_pct=50 ;; esac
    local line="${lens}: ${accepted}/${total} (${pct}%)"
    if [ "$pct" -lt "${threshold_pct:-50}" ]; then
      line="${line} ⚠ 閾値(${threshold_pct}%)未満 — 無効化候補（自動無効化はしない）"
    fi
    echo "$line"
  done <<< "$lenses"
  return 0
}
