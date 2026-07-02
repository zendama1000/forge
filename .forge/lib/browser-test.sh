#!/bin/bash
# browser-test.sh — Playwright MCP ブラウザテストサブシステム
# phase3.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh / phase3.sh で定義済み）:
#   PROJECT_ROOT, WORK_DIR, DEV_CONFIG, DEV_LOG_DIR
#   AGENTS_DIR, TEMPLATES_DIR, SCHEMAS_DIR

# ===== Playwright MCP 可用性チェック =====
# 旧実装は MCP サーバーを & でバックグラウンド常駐させていたが、stdio 型 MCP は
# claude CLI 自身が --mcp-config から spawn するためクライアント不在の常駐は無意味
# （stdin 切断で即死するだけ）だった。本関数は「npx が存在するか」の可用性チェックに
# 意味変更する（関数名と戻り値は呼出互換のため維持）。
_PLAYWRIGHT_MCP_READY=""

start_playwright_mcp() {
  local mcp_command mcp_args
  mcp_command=$(jq_safe -r '.browser_testing.playwright_mcp.command // "npx"' "$DEV_CONFIG" 2>/dev/null)
  mcp_args=$(jq_safe -r '.browser_testing.playwright_mcp.args // [] | join(" ")' "$DEV_CONFIG" 2>/dev/null)

  if [ -z "$mcp_command" ] || [ -z "$mcp_args" ]; then
    log "  ⚠ Browser Test: MCP サーバー設定不足 — スキップ"
    return 1
  fi

  # MCP binary 存在チェック（パッケージ本体は claude CLI が npx 経由で解決する）
  if ! command -v "$mcp_command" > /dev/null 2>&1; then
    log "  ⚠ Browser Test: ${mcp_command} が見つからない — スキップ"
    return 1
  fi

  _PLAYWRIGHT_MCP_READY=1
  log "  Browser Test: Playwright MCP 可用性確認 OK (${mcp_command} ${mcp_args})"
  return 0
}

# 互換のため残置（stdio 型 MCP は claude CLI が spawn/終了を管理するため停止処理は不要）
stop_playwright_mcp() {
  _PLAYWRIGHT_MCP_READY=""
  return 0
}

# ===== ブラウザテスト実行 =====
# execute_browser_test <l3_test_json> <work_dir> <timeout>
# 戻り値: 0=pass, 1=fail, 2=skip
execute_browser_test() {
  local l3_test="$1"
  local work_dir="${2:-${WORK_DIR:-.}}"
  local timeout="${3:-120}"

  # 設定チェック
  local browser_enabled
  browser_enabled=$(jq_safe -r '.browser_testing.enabled // false' "$DEV_CONFIG" 2>/dev/null)
  if [ "$browser_enabled" != "true" ]; then
    echo "Browser testing disabled"
    return 2
  fi

  local test_id instructions browser_model
  test_id=$(echo "$l3_test" | jq_safe -r '.id // "browser-unknown"')
  instructions=$(echo "$l3_test" | jq_safe -r '.instructions // ""')
  browser_model=$(jq_safe -r '.browser_testing.model // "sonnet"' "$DEV_CONFIG" 2>/dev/null)

  if [ -z "$instructions" ]; then
    echo "Browser test instructions missing"
    return 2
  fi

  # エージェント/テンプレート不在チェック
  if [ ! -f "${AGENTS_DIR}/browser-tester.md" ] || \
     [ ! -f "${TEMPLATES_DIR}/browser-test-prompt.md" ]; then
    echo "Browser test agent/template not found"
    return 2
  fi

  # MCP 可用性チェック（未確認時）
  if [ -z "$_PLAYWRIGHT_MCP_READY" ]; then
    if ! start_playwright_mcp; then
      echo "Playwright MCP unavailable"
      return 2
    fi
  fi

  log "    Browser Test [${test_id}]: 実行開始"

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/browser-test-prompt.md" \
    "TEST_ID"       "$test_id" \
    "INSTRUCTIONS"  "$instructions" \
    "WORK_DIR"      "$work_dir"
  )

  local ts
  ts=$(now_ts)
  local output="${DEV_LOG_DIR}/browser-test-${test_id}-${ts}.json"
  local log_file="${DEV_LOG_DIR}/browser-test-${test_id}-${ts}.log"

  # MCP config for Playwright（headless は @playwright/mcp の正式オプション --headless を args に合成）
  local mcp_config_file="${DEV_LOG_DIR}/.playwright-mcp-config.json"
  local mcp_command mcp_args headless
  mcp_command=$(jq_safe -r '.browser_testing.playwright_mcp.command // "npx"' "$DEV_CONFIG" 2>/dev/null)
  mcp_args=$(jq_safe -r '.browser_testing.playwright_mcp.args // []' "$DEV_CONFIG" 2>/dev/null)
  headless=$(jq_safe -r '.browser_testing.headless // true' "$DEV_CONFIG" 2>/dev/null)
  jq -n --arg cmd "$mcp_command" --argjson args "$mcp_args" --arg headless "$headless" \
    '{mcpServers: {playwright: {command: $cmd,
       args: ($args + (if $headless == "true" then ["--headless"] else [] end))}}}' \
    > "$mcp_config_file" 2>/dev/null

  # run_claude の env チャネルで MCP config を渡す（--mcp-config + --strict-mcp-config が付与される）
  metrics_start
  export _RC_MCP_CONFIG="$mcp_config_file"
  if ! run_claude "$browser_model" "${AGENTS_DIR}/browser-tester.md" \
    "$prompt" "$output" "$log_file" "" "$timeout" "$work_dir" \
    "${SCHEMAS_DIR}/browser-test.schema.json"; then
    unset _RC_MCP_CONFIG
    metrics_record "browser-test-${test_id}" "false"
    echo "Browser test execution failed"
    return 1
  fi
  unset _RC_MCP_CONFIG
  metrics_record "browser-test-${test_id}" "true"

  # JSON 検証
  if ! validate_json "$output" "browser-test-${test_id}"; then
    echo "Browser test output invalid JSON"
    return 1
  fi

  local verdict
  verdict=$(jq_safe -r '.verdict // "fail"' "$output" 2>/dev/null)

  if [ "$verdict" = "pass" ]; then
    echo "Browser test passed"
    return 0
  else
    local reason
    reason=$(jq_safe -r '.failure_reason // "不明"' "$output" 2>/dev/null)
    echo "Browser test failed: ${reason}"
    return 1
  fi
}
