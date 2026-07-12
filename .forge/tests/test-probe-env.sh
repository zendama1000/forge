#!/bin/bash
# test-probe-env.sh — probe-env.sh 単体テスト
# 使い方: bash .forge/tests/test-probe-env.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="/tmp/test-probe-env"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/state" "${TEST_ROOT}/work"

log() { echo "[LOG] $1" >&2; }
jq_safe() { jq "$@" | tr -d '\r'; }

source "${SCRIPT_DIR}/.forge/lib/probe-env.sh"

# フェイク bin: node/npm は成功、npx は --no-install 解決失敗、docker はハング
cat > "${TEST_ROOT}/bin/node" << 'SH'
#!/bin/bash
echo "v99.0.0-fake"
SH
cat > "${TEST_ROOT}/bin/npm" << 'SH'
#!/bin/bash
echo "99.0.0-fake"
SH
cat > "${TEST_ROOT}/bin/npx" << 'SH'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "99.0.0-fake"; exit 0; fi
exit 1
SH
cat > "${TEST_ROOT}/bin/docker" << 'SH'
#!/bin/bash
sleep 60
SH
chmod +x "${TEST_ROOT}/bin/"*

DEV_CONFIG_NONE="${TEST_ROOT}/dev-none.json"
echo '{"server":{"start_command":"none","health_check_url":""},"browser_testing":{"enabled":true,"playwright_mcp":{"command":"npx","args":["@playwright/mcp@latest"]}}}' > "$DEV_CONFIG_NONE"
DEV_CONFIG_SRV="${TEST_ROOT}/dev-srv.json"
echo '{"server":{"start_command":"npm start","health_check_url":"http://localhost:3001"},"browser_testing":{"enabled":true,"playwright_mcp":{"command":"npx","args":["@playwright/mcp@latest"]}}}' > "$DEV_CONFIG_SRV"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: フェイク bin での検出 + ハング docker のタイムボックス ---
echo -e "\n${BOLD}[1] プローブ実行（ハング docker 含む）${NC}"
_ORIG_PATH="$PATH"
export PATH="${TEST_ROOT}/bin:$PATH"
OUT1="${TEST_ROOT}/state/caps1.json"
start_epoch=$(date +%s)
rc=0; probe_env_capabilities "${TEST_ROOT}/work" "$OUT1" "$DEV_CONFIG_NONE" >/dev/null 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start_epoch ))
export PATH="$_ORIG_PATH"
assert_eq "プローブは rc=0" "0" "$rc"
assert_eq "出力ファイルが生成される" "true" "$([ -f "$OUT1" ] && echo true || echo false)"
assert_eq "ハング docker でも 40 秒以内に完走（タイムボックス）" "true" "$([ "$elapsed" -lt 40 ] && echo true || echo false)"
assert_eq "node が検出される" "true" "$(jq -r '.capabilities.node.available' "$OUT1")"
assert_eq "cmd:node タグが付く" "1" "$(jq '[.capability_tags[] | select(. == "cmd:node")] | length' "$OUT1")"
assert_eq "docker はハングで false" "false" "$(jq -r '.capabilities.docker.available' "$OUT1")"
assert_eq "docker タグは付かない" "0" "$(jq '[.capability_tags[] | select(. == "docker")] | length' "$OUT1")"
assert_eq "mcp 未解決(+-y なし)で browser タグなし" "0" "$(jq '[.capability_tags[] | select(. == "browser")] | length' "$OUT1")"
assert_eq "server=none で server タグなし" "0" "$(jq '[.capability_tags[] | select(. == "server")] | length' "$OUT1")"

# --- Test 2: スキーマ適合（構造検査） ---
echo -e "\n${BOLD}[2] スキーマ適合${NC}"
assert_eq "required: probed_at" "true" "$(jq 'has("probed_at")' "$OUT1")"
assert_eq "required: capabilities" "true" "$(jq 'has("capabilities")' "$OUT1")"
assert_eq "required: capability_tags (array)" "true" "$(jq '.capability_tags | type == "array"' "$OUT1")"
assert_eq "各 cap は available (boolean) を持つ" "true" \
  "$(jq '[.capabilities | to_entries[] | .value.available | type] | all(. == "boolean")' "$OUT1")"

# --- Test 3: server 設定ありで server タグ ---
echo -e "\n${BOLD}[3] server タグ${NC}"
OUT2="${TEST_ROOT}/state/caps2.json"
probe_env_capabilities "${TEST_ROOT}/work" "$OUT2" "$DEV_CONFIG_SRV" >/dev/null 2>&1
assert_eq "start_command 設定済みで server タグ" "1" "$(jq '[.capability_tags[] | select(. == "server")] | length' "$OUT2")"

# --- Test 4: work_dir scripts 抽出 ---
echo -e "\n${BOLD}[4] package.json scripts${NC}"
echo '{"scripts":{"dev":"x","build":"y","test":"z"}}' > "${TEST_ROOT}/work/package.json"
OUT3="${TEST_ROOT}/state/caps3.json"
probe_env_capabilities "${TEST_ROOT}/work" "$OUT3" "$DEV_CONFIG_NONE" >/dev/null 2>&1
assert_eq "scripts が抽出される" "3" "$(jq '.work_dir_scripts | length' "$OUT3")"
rm -f "${TEST_ROOT}/work/package.json"
OUT4="${TEST_ROOT}/state/caps4.json"
probe_env_capabilities "${TEST_ROOT}/work" "$OUT4" "$DEV_CONFIG_NONE" >/dev/null 2>&1
assert_eq "package.json なしで空配列" "0" "$(jq '.work_dir_scripts | length' "$OUT4")"

# --- Test 5: format_env_probe_for_prompt ---
echo -e "\n${BOLD}[5] プロンプト用フォーマット${NC}"
fmt=$(format_env_probe_for_prompt "$OUT1")
assert_eq "非空出力" "true" "$([ -n "$fmt" ] && echo true || echo false)"
line_count=$(echo "$fmt" | wc -l | tr -d ' ')
assert_eq "15 行以内（プロンプト肥大対策）" "true" "$([ "$line_count" -le 15 ] && echo true || echo false)"
case "$fmt" in
  *"利用可能タグ"*) assert_eq "利用可能タグ行を含む" "ok" "ok" ;;
  *) assert_eq "利用可能タグ行を含む" "含む" "含まない" ;;
esac
fmt_missing=$(format_env_probe_for_prompt "/nonexistent/caps.json")
case "$fmt_missing" in
  *"保守的に deferred"*) assert_eq "ファイル不在時は保守的フォールバック文" "ok" "ok" ;;
  *) assert_eq "ファイル不在時は保守的フォールバック文" "含む" "含まない" ;;
esac

# ===== クリーンアップ =====
rm -rf "$TEST_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  probe-env テスト結果"
echo -e "==========================================${NC}"
echo -e "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}SOME TESTS FAILED${NC}"
  exit 1
fi
