#!/bin/bash
# test-server-lifecycle.sh — server-lifecycle.sh 単体テスト
# 使い方: bash .forge/tests/test-server-lifecycle.sh

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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    needle not found: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="/tmp/test-server-lifecycle"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$PROJECT_ROOT"
mkdir -p "${PROJECT_ROOT}/.forge/lib" "${PROJECT_ROOT}/.forge/state" "${PROJECT_ROOT}/.forge/logs" "${PROJECT_ROOT}/work"

cat > "${PROJECT_ROOT}/.forge/lib/stub-common.sh" << 'STUB'
log() { echo "[LOG] $1" >&2; }
now_ts() { date +%Y%m%d-%H%M%S; }
jq_safe() { jq "$@" | tr -d '\r'; }
STUB
source "${PROJECT_ROOT}/.forge/lib/stub-common.sh"

cp "${SCRIPT_DIR}/.forge/lib/server-lifecycle.sh" "${PROJECT_ROOT}/.forge/lib/"

DEV_CONFIG="${PROJECT_ROOT}/.forge/development.json"
WORK_DIR="${PROJECT_ROOT}/work"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs"
SERVER_LC_PID_FILE="${PROJECT_ROOT}/.forge/state/server.pid"

source "${PROJECT_ROOT}/.forge/lib/server-lifecycle.sh"

write_config() {
  local start_cmd="$1" health_url="$2" timeout="${3:-3}"
  jq -n --arg s "$start_cmd" --arg h "$health_url" --argjson t "$timeout" \
    '{server: {start_command: $s, health_check_url: $h, startup_timeout_sec: $t}}' > "$DEV_CONFIG"
}

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: server_http_code は接続不能で 000 ---
echo -e "\n${BOLD}[1] server_http_code: 接続不能 → 000${NC}"
code=$(server_http_code "http://127.0.0.1:59999/nope")
assert_eq "接続不能は 000" "000" "$code"

# --- Test 2: start_command=none → rc=2（環境不足） ---
echo -e "\n${BOLD}[2] start_command=none → rc=2${NC}"
write_config "none" "http://127.0.0.1:59999/health"
rc=0; ensure_server_running || rc=$?
assert_eq "none は rc=2" "2" "$rc"
assert_contains "REASON に none の説明" "start_command=none" "$SERVER_LC_REASON"

# --- Test 3: health_check_url 空 → rc=2 ---
echo -e "\n${BOLD}[3] health_check_url 空 → rc=2${NC}"
write_config "npm start" ""
rc=0; ensure_server_running || rc=$?
assert_eq "health_url 空は rc=2" "2" "$rc"

# --- Test 4: 外部所有検出（起動も kill もしない） ---
echo -e "\n${BOLD}[4] 外部所有検出${NC}"
write_config "none" "http://127.0.0.1:59999/health"
server_http_code() { printf '200'; }
rc=0; ensure_server_running || rc=$?
assert_eq "既存サーバー応答時は rc=0" "0" "$rc"
assert_eq "外部所有では OWNED=false" "false" "$SERVER_LC_OWNED"
assert_eq "外部所有では PID 空" "" "$SERVER_LC_PID"
teardown_server
assert_eq "teardown は外部所有で何もせず rc=0" "0" "$?"

# --- Test 5: 自前起動成功 → teardown で停止 ---
echo -e "\n${BOLD}[5] 自前起動 → teardown${NC}"
# 1回目(外部チェック)は 000、以降 200 を返すカウンタ式スタブ
_HC_COUNT_FILE="${PROJECT_ROOT}/.forge/state/hc-count"
echo 0 > "$_HC_COUNT_FILE"
server_http_code() {
  local n
  n=$(cat "$_HC_COUNT_FILE")
  n=$((n + 1))
  echo "$n" > "$_HC_COUNT_FILE"
  if [ "$n" -le 1 ]; then printf '000'; else printf '200'; fi
}
write_config "sleep 30" "http://127.0.0.1:59999/health" 5
rc=0; ensure_server_running || rc=$?
assert_eq "自前起動は rc=0" "0" "$rc"
assert_eq "自前起動では OWNED=true" "true" "$SERVER_LC_OWNED"
srv_pid="$SERVER_LC_PID"
assert_eq "プロセスが生存" "alive" "$(kill -0 "$srv_pid" 2>/dev/null && echo alive || echo dead)"
assert_eq "pid ファイルが記録される" "true" "$([ -f "$SERVER_LC_PID_FILE" ] && echo true || echo false)"

# 冪等: 再呼出は即 rc=0・PID 不変
rc=0; ensure_server_running || rc=$?
assert_eq "冪等再呼出は rc=0" "0" "$rc"
assert_eq "PID が変わらない" "$srv_pid" "$SERVER_LC_PID"

teardown_server
sleep 1
assert_eq "teardown 後プロセスが停止" "dead" "$(kill -0 "$srv_pid" 2>/dev/null && echo alive || echo dead)"
assert_eq "pid ファイルが削除される" "false" "$([ -f "$SERVER_LC_PID_FILE" ] && echo true || echo false)"

# --- Test 6: health 404 タイムアウト → rc=1 + 404 診断 ---
# 初回(外部チェック)は 000、起動後のポーリングは 404（listen しているが health URL 不一致）
echo -e "\n${BOLD}[6] 404 診断${NC}"
echo 0 > "$_HC_COUNT_FILE"
server_http_code() {
  local n
  n=$(cat "$_HC_COUNT_FILE")
  n=$((n + 1))
  echo "$n" > "$_HC_COUNT_FILE"
  if [ "$n" -le 1 ]; then printf '000'; else printf '404'; fi
}
write_config "sleep 30" "http://127.0.0.1:59999/health" 2
rc=0; ensure_server_running || rc=$?
assert_eq "404 タイムアウトは rc=1" "1" "$rc"
assert_contains "REASON に 404 と設定確認の示唆" "404" "$SERVER_LC_REASON"
assert_contains "REASON に health_check_url 確認" "health_check_url" "$SERVER_LC_REASON"
assert_eq "失敗後 OWNED リセット" "false" "$SERVER_LC_OWNED"

# --- Test 7: 起動プロセス早期終了 → rc=1 ---
echo -e "\n${BOLD}[7] 起動プロセス早期終了${NC}"
server_http_code() { printf '000'; }
write_config "false" "http://127.0.0.1:59999/health" 3
rc=0; ensure_server_running || rc=$?
assert_eq "早期終了は rc=1" "1" "$rc"
assert_contains "REASON に早期終了" "早期終了" "$SERVER_LC_REASON"

# --- Test 8: phase_test_requires_server 判定 ---
echo -e "\n${BOLD}[8] phase_test_requires_server${NC}"
mk="${PROJECT_ROOT}/marker.sh"; printf '#!/bin/bash\n# forge-requires: server\necho ok\n' > "$mk"
hu="${PROJECT_ROOT}/heuristic.sh"; printf '#!/bin/bash\ncurl -sf http://localhost:3001/api\n' > "$hu"
pl="${PROJECT_ROOT}/plain.sh"; printf '#!/bin/bash\ntest -f README.md\n' > "$pl"
assert_eq "マーカー → server" "server" "$(phase_test_requires_server "$mk")"
assert_eq "curl ヒューリスティック → server" "server" "$(phase_test_requires_server "$hu")"
assert_eq "http なし → none" "none" "$(phase_test_requires_server "$pl")"
assert_eq "ファイル不在 → none" "none" "$(phase_test_requires_server "${PROJECT_ROOT}/nope.sh")"

# ===== クリーンアップ =====
rm -rf "$PROJECT_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  server-lifecycle テスト結果"
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
