#!/bin/bash
# probe-env.sh — 環境能力プローブサブシステム
# generate-tasks.sh / research-loop.sh から source される。単独実行も可（末尾ディスパッチ）。
#
# 目的: Phase 1/1.5 のテスト設計前に「この環境で実際に実行できる検証手段」を機械的に
# 検出し、Task Planner / criteria 生成へ注入する。環境で実行不能な e2e が生成され
# futile ループ化する問題（browser-cockpit 実害）の生成時対策。
#
# 出力: .forge/state/env-capabilities.json（env-capabilities.schema.json 準拠）
#   capability_tags[] は requires 語彙に正規化したフラット配列
#   （例: cmd:node / cmd:npm / browser / server / network / docker / display）
#
# 原則: プローブ失敗は capability=false であってエラーではない（常に exit 0 系）。
# 各プローブは timeout でタイムボックスし、ハング（docker info 等）を遮断する。
#
# 依存関数（common.sh）: log, jq_safe

PROBE_ENV_VERSION=1

# _probe_cmd <name> — コマンド存在 + バージョン取得
# stdout: "true|<version>" or "false|"
_probe_cmd() {
  local name="$1"
  if command -v "$name" > /dev/null 2>&1; then
    local ver
    ver=$(timeout 10 "$name" --version 2>/dev/null | head -1 | tr -d '\r' | head -c 80)
    printf 'true|%s' "${ver:-unknown}"
  else
    printf 'false|'
  fi
  return 0
}

# _probe_playwright_mcp <dev_config> — Playwright MCP の解決可否
# browser-test.sh の start_playwright_mcp と同基準 + npx --no-install で実解決を確認
_probe_playwright_mcp() {
  local dev_config="${1:-}"
  local mcp_command="npx"
  if [ -n "$dev_config" ] && [ -f "$dev_config" ]; then
    mcp_command=$(jq_safe -r '.browser_testing.playwright_mcp.command // "npx"' "$dev_config" 2>/dev/null)
  fi
  if ! command -v "$mcp_command" > /dev/null 2>&1; then
    printf 'false|%s not found' "$mcp_command"
    return 0
  fi
  # --no-install でネットワーク依存を切ってローカル解決のみ確認（20s タイムボックス）
  if timeout 20 npx --no-install @playwright/mcp --version > /dev/null 2>&1; then
    printf 'true|@playwright/mcp resolved locally'
  else
    # ローカル未解決でも npx -y で実行時解決される設定なら条件付き可
    local uses_y
    uses_y=$(jq_safe -r '(.browser_testing.playwright_mcp.args // []) | map(select(. == "-y")) | length' "${dev_config:-/nonexistent}" 2>/dev/null)
    case "$uses_y" in (*[!0-9]*|"") uses_y=0 ;; esac
    if [ "$uses_y" -gt 0 ]; then
      printf 'true|npx -y (実行時解決 — 初回はネットワーク必要)'
    else
      printf 'false|@playwright/mcp unresolved'
    fi
  fi
  return 0
}

# _probe_browser_headless [dev_config] — headless ブラウザ起動可否
# tier1(既定): playwright CLI のローカル解決確認
# tier2(config で .probe.deep_browser_probe==true): 実 launch 試行（45s タイムボックス）
_probe_browser_headless() {
  local dev_config="${1:-}"
  if ! command -v npx > /dev/null 2>&1; then
    printf 'false|npx not found'
    return 0
  fi
  if ! timeout 20 npx --no-install playwright --version > /dev/null 2>&1; then
    printf 'false|playwright unresolved locally'
    return 0
  fi
  local deep="false"
  if [ -n "$dev_config" ] && [ -f "$dev_config" ]; then
    deep=$(jq_safe -r '.probe.deep_browser_probe // false' "$dev_config" 2>/dev/null)
  fi
  if [ "$deep" = "true" ]; then
    if timeout 45 npx --no-install playwright cr --help > /dev/null 2>&1 && \
       timeout 45 node -e "require('playwright').chromium.launch({headless:true}).then(b=>b.close()).then(()=>process.exit(0)).catch(()=>process.exit(1))" > /dev/null 2>&1; then
      printf 'true|headless launch verified'
    else
      printf 'false|headless launch failed'
    fi
  else
    printf 'true|playwright resolved (launch 未検証 — deep_browser_probe で実測可)'
  fi
  return 0
}

# _probe_display — ディスプレイ有無（Windows デスクトップセッションは常に true）
_probe_display() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      printf 'true|windows-session'
      ;;
    Darwin)
      printf 'true|macos-session'
      ;;
    *)
      if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        printf 'true|%s' "${DISPLAY:-$WAYLAND_DISPLAY}"
      else
        printf 'false|no DISPLAY'
      fi
      ;;
  esac
  return 0
}

# _probe_docker — docker 可用性（docker info はハングし得るため 8s タイムボックス）
_probe_docker() {
  if ! command -v docker > /dev/null 2>&1; then
    printf 'false|docker not found'
    return 0
  fi
  if timeout 8 docker info > /dev/null 2>&1; then
    printf 'true|daemon reachable'
  else
    printf 'false|daemon unreachable'
  fi
  return 0
}

# _probe_network — 外部ネットワーク到達性
_probe_network() {
  if curl -sf --max-time 5 "https://registry.npmjs.org/-/ping" > /dev/null 2>&1; then
    printf 'true|registry.npmjs.org reachable'
  else
    printf 'false|外部到達不能（またはプロキシ要）'
  fi
  return 0
}

# _probe_server_config <dev_config> — server 設定の有効性
_probe_server_config() {
  local dev_config="${1:-}"
  local start_cmd=""
  if [ -n "$dev_config" ] && [ -f "$dev_config" ]; then
    start_cmd=$(jq_safe -r '.server.start_command // "none"' "$dev_config" 2>/dev/null)
  fi
  if [ -n "$start_cmd" ] && [ "$start_cmd" != "none" ] && [ "$start_cmd" != "null" ]; then
    printf 'true|%s' "$start_cmd"
  else
    printf 'false|start_command=none（development.json の server ブロックを手動設定すれば有効化）'
  fi
  return 0
}

# _probe_work_dir_scripts <work_dir> — package.json の scripts 一覧（JSON 配列）
_probe_work_dir_scripts() {
  local work_dir="${1:-.}"
  if [ -f "${work_dir}/package.json" ]; then
    jq -c '.scripts // {} | keys' "${work_dir}/package.json" 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
  return 0
}

# ===== メイン: 全プローブ実行 → env-capabilities.json 生成 =====
# probe_env_capabilities <work_dir> <output_json> [dev_config]
# 常に rc=0（プローブ失敗 = capability false であってエラーではない）
probe_env_capabilities() {
  local work_dir="${1:-.}"
  local output_json="$2"
  local dev_config="${3:-}"

  log "環境能力プローブ実行中..."

  local r_node r_npm r_npx r_mcp r_browser r_display r_docker r_network r_server r_scripts
  r_node=$(_probe_cmd node)
  r_npm=$(_probe_cmd npm)
  r_npx=$(_probe_cmd npx)
  r_mcp=$(_probe_playwright_mcp "$dev_config")
  r_browser=$(_probe_browser_headless "$dev_config")
  r_display=$(_probe_display)
  r_docker=$(_probe_docker)
  r_network=$(_probe_network)
  r_server=$(_probe_server_config "$dev_config")
  r_scripts=$(_probe_work_dir_scripts "$work_dir")

  # "true|detail" → {available, detail} へ変換するヘルパー
  _cap_json() {
    local pair="$1"
    local avail="${pair%%|*}"
    local detail="${pair#*|}"
    jq -n --arg a "$avail" --arg d "$detail" '{available: ($a == "true"), detail: $d}'
  }

  # capability_tags の導出（requires 語彙に正規化）
  local tags="[]"
  _add_tag() { tags=$(echo "$tags" | jq -c --arg t "$1" '. + [$t]'); }
  # cmd:<name> タグ（batch#11 R13）: requires_entry_satisfiable は cmd: を live 判定するが、Planner は
  # env-capabilities の capability_tags だけを見て deferred を決める。node/npm/npx 以外（claude / git /
  # jq / bash / python）のタグが無かったため、cmd:claude を要求する L2 が全て deferred になっていた
  # （4.5f: L2 28/28 が deferred）。node/npm/npx は capabilities の既存キーと互換のまま
  local _c
  for _c in node npm npx claude git bash jq python python3 go cargo; do
    case "$_c" in
      node) [ "${r_node%%|*}" = "true" ] && _add_tag "cmd:node" ;;
      npm)  [ "${r_npm%%|*}" = "true" ] && _add_tag "cmd:npm" ;;
      npx)  [ "${r_npx%%|*}" = "true" ] && _add_tag "cmd:npx" ;;
      *)    command -v "$_c" > /dev/null 2>&1 && _add_tag "cmd:${_c}" ;;
    esac
  done
  # browser タグ: MCP 解決可 かつ headless 起動見込み かつ browser_testing 有効
  local bt_enabled="false"
  if [ -n "$dev_config" ] && [ -f "$dev_config" ]; then
    bt_enabled=$(jq_safe -r '.browser_testing.enabled // false' "$dev_config" 2>/dev/null)
  fi
  if [ "${r_mcp%%|*}" = "true" ] && [ "${r_browser%%|*}" = "true" ] && [ "$bt_enabled" = "true" ]; then
    _add_tag "browser"
  fi
  [ "${r_display%%|*}" = "true" ] && _add_tag "display"
  [ "${r_docker%%|*}" = "true" ] && _add_tag "docker"
  [ "${r_network%%|*}" = "true" ] && _add_tag "network"
  [ "${r_server%%|*}" = "true" ] && _add_tag "server"

  mkdir -p "$(dirname "$output_json")" 2>/dev/null || true
  jq -n \
    --arg ts "$(date -Iseconds)" \
    --arg platform "$(uname -s 2>/dev/null || echo unknown)" \
    --argjson ver "$PROBE_ENV_VERSION" \
    --argjson node "$(_cap_json "$r_node")" \
    --argjson npm "$(_cap_json "$r_npm")" \
    --argjson npx "$(_cap_json "$r_npx")" \
    --argjson mcp "$(_cap_json "$r_mcp")" \
    --argjson browser "$(_cap_json "$r_browser")" \
    --argjson display "$(_cap_json "$r_display")" \
    --argjson docker "$(_cap_json "$r_docker")" \
    --argjson network "$(_cap_json "$r_network")" \
    --argjson server "$(_cap_json "$r_server")" \
    --argjson scripts "$r_scripts" \
    --argjson tags "$tags" \
    '{
      probed_at: $ts,
      platform: $platform,
      probe_version: $ver,
      capabilities: {
        node: $node, npm: $npm, npx: $npx,
        playwright_mcp: $mcp, browser_headless: $browser,
        display: $display, docker: $docker, network: $network,
        server_config: $server
      },
      work_dir_scripts: $scripts,
      capability_tags: $tags
    }' > "${output_json}.tmp" 2>/dev/null && mv "${output_json}.tmp" "$output_json"

  if [ -f "$output_json" ]; then
    log "  ✓ 環境能力プローブ完了: $(echo "$tags" | jq -r 'join(", ")' 2>/dev/null)"
    return 0
  fi
  log "  ⚠ 環境能力プローブ: 出力生成失敗"
  return 1
}

# ===== プロンプト注入用の圧縮 Markdown 生成 =====
# format_env_probe_for_prompt <capabilities_json>
# 15 行以内の短い Markdown（プロンプト肥大対策）
format_env_probe_for_prompt() {
  local caps_file="$1"
  if [ ! -f "$caps_file" ]; then
    echo "（環境プローブ結果なし — 外部境界の検証は保守的に deferred 判定すること）"
    return 0
  fi
  local avail unavail scripts
  avail=$(jq_safe -r '(.capability_tags // []) | join(", ")' "$caps_file" 2>/dev/null)
  unavail=$(jq_safe -r '
    [.capabilities | to_entries[] | select(.value.available != true) |
     "\(.key)(\(.value.detail // ""))"] | join(", ")
  ' "$caps_file" 2>/dev/null | head -c 400)
  scripts=$(jq_safe -r '(.work_dir_scripts // []) | join(", ")' "$caps_file" 2>/dev/null | head -c 200)

  cat <<EOF
### 環境能力プローブ結果（この環境で実行可能な検証手段）
- 利用可能タグ: ${avail:-（なし）}
- 利用不可: ${unavail:-（なし）}
- WORK_DIR package.json scripts: ${scripts:-（なし）}

利用不可の能力を requires に持つ検証は deferred:true + deferred_reason を設定し、
利用可能な最強ティアの代替検証を必ず併設すること（deferred のみのタスクは禁止）。
EOF
  return 0
}

# ===== 単独実行ディスパッチ =====
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # 使い方: bash probe-env.sh <work_dir> <output_json> [dev_config]
  command -v log > /dev/null 2>&1 || log() { echo "[probe-env] $1" >&2; }
  command -v jq_safe > /dev/null 2>&1 || jq_safe() { jq "$@" | tr -d '\r'; }
  probe_env_capabilities "${1:-.}" "${2:-.forge/state/env-capabilities.json}" "${3:-}"
fi
