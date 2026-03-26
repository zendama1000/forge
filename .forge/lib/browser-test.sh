#!/bin/bash
# browser-test.sh — Playwright MCP ブラウザテストサブシステム
# phase3.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh / phase3.sh で定義済み）:
#   PROJECT_ROOT, WORK_DIR, DEV_CONFIG, DEV_LOG_DIR
#   AGENTS_DIR, TEMPLATES_DIR, SCHEMAS_DIR

# ===== Playwright MCP サーバー管理 =====
_PLAYWRIGHT_MCP_PID=""

start_playwright_mcp() {
  local mcp_command mcp_args headless
  mcp_command=$(jq_safe -r '.browser_testing.playwright_mcp.command // "npx"' "$DEV_CONFIG" 2>/dev/null)
  mcp_args=$(jq_safe -r '.browser_testing.playwright_mcp.args // [] | join(" ")' "$DEV_CONFIG" 2>/dev/null)
  headless=$(jq_safe -r '.browser_testing.headless // true' "$DEV_CONFIG" 2>/dev/null)

  if [ -z "$mcp_command" ] || [ -z "$mcp_args" ]; then
    log "  ⚠ Browser Test: MCP サーバー設定不足 — スキップ"
    return 1
  fi

  # MCP binary 存在チェック
  if ! command -v "$mcp_command" > /dev/null 2>&1; then
    log "  ⚠ Browser Test: ${mcp_command} が見つからない — スキップ"
    return 1
  fi

  log "  Browser Test: Playwright MCP サーバー起動"
  local env_vars=""
  [ "$headless" = "true" ] && env_vars="HEADLESS=true"

  env $env_vars $mcp_command $mcp_args &>/dev/null &
  _PLAYWRIGHT_MCP_PID=$!
  sleep 2

  # プロセス生存チェック
  if ! kill -0 "$_PLAYWRIGHT_MCP_PID" 2>/dev/null; then
    log "  ⚠ Browser Test: MCP サーバー起動失敗"
    _PLAYWRIGHT_MCP_PID=""
    return 1
  fi

  log "  Browser Test: MCP サーバー起動完了 (PID=${_PLAYWRIGHT_MCP_PID})"
  return 0
}

stop_playwright_mcp() {
  if [ -n "$_PLAYWRIGHT_MCP_PID" ] && kill -0 "$_PLAYWRIGHT_MCP_PID" 2>/dev/null; then
    kill "$_PLAYWRIGHT_MCP_PID" 2>/dev/null || true
    wait "$_PLAYWRIGHT_MCP_PID" 2>/dev/null || true
    log "  Browser Test: MCP サーバー停止 (PID=${_PLAYWRIGHT_MCP_PID})"
    _PLAYWRIGHT_MCP_PID=""
  fi
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

  # MCP サーバー起動（未起動時）
  if [ -z "$_PLAYWRIGHT_MCP_PID" ]; then
    if ! start_playwright_mcp; then
      echo "Failed to start Playwright MCP server"
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

  # MCP config for Playwright
  local mcp_config_file="${DEV_LOG_DIR}/.playwright-mcp-config.json"
  local mcp_command mcp_args
  mcp_command=$(jq_safe -r '.browser_testing.playwright_mcp.command // "npx"' "$DEV_CONFIG" 2>/dev/null)
  mcp_args=$(jq_safe -r '.browser_testing.playwright_mcp.args // []' "$DEV_CONFIG" 2>/dev/null)
  jq -n --arg cmd "$mcp_command" --argjson args "$mcp_args" \
    '{mcpServers: {playwright: {command: $cmd, args: $args}}}' \
    > "$mcp_config_file" 2>/dev/null

  metrics_start
  if ! run_claude "$browser_model" "${AGENTS_DIR}/browser-tester.md" \
    "$prompt" "$output" "$log_file" "" "$timeout" "$work_dir" \
    "${SCHEMAS_DIR}/browser-test.schema.json"; then
    metrics_record "browser-test-${test_id}" "false"
    echo "Browser test execution failed"
    return 1
  fi
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
