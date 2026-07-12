#!/bin/bash
# test-phase-regression-cwd.sh — handle_dev_phase_completion の回帰実行改修テスト
# 検証: (1) phase-test が WORK_DIR で実行される (2) server 環境不足→env_blocked+続行
#       (3) 外部所有サーバーを kill しない (4) 非環境起因の block ポリシーは維持
# 使い方: bash .forge/tests/test-phase-regression-cwd.sh

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
TEST_ROOT="/tmp/test-phase-regression-cwd"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"
rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/.forge/lib" "${TEST_ROOT}/.forge/state/phase-tests" \
         "${TEST_ROOT}/.forge/logs" "${TEST_ROOT}/work"

# スタブ群
DEBT_LOG="${TEST_ROOT}/debts.log"
cat > "${TEST_ROOT}/.forge/lib/stub-common.sh" << STUB
log() { echo "[LOG] \$1" >&2; }
now_ts() { date +%Y%m%d-%H%M%S; }
jq_safe() { jq "\$@" | tr -d '\r'; }
notify_human() { echo "[NOTIFY] \$1 \$2" >&2; }
run_evidence_da() { :; }
task_checkpoint_restore() { :; }
run_checklist_concretize() { :; }
show_dev_phase_checkpoint() { return 0; }
record_quality_debt() { echo "\$1|\$2|\$3" >> "$DEBT_LOG"; }
detect_orphan_files() { :; }
STUB
source "${TEST_ROOT}/.forge/lib/stub-common.sh"

# 実物: server-lifecycle.sh + handle_dev_phase_completion を sed 抽出
cp "${SCRIPT_DIR}/.forge/lib/server-lifecycle.sh" "${TEST_ROOT}/.forge/lib/"
sed -n '/^handle_dev_phase_completion() {/,/^}/p' "${SCRIPT_DIR}/.forge/lib/dev-phases.sh" \
  > "${TEST_ROOT}/.forge/lib/handler-extract.sh"
if [ ! -s "${TEST_ROOT}/.forge/lib/handler-extract.sh" ]; then
  echo "FATAL: handle_dev_phase_completion を抽出できない"
  echo "  PASS: 0  FAIL: 1"
  exit 1
fi

# 前提変数
PROJECT_ROOT="$TEST_ROOT"
WORK_DIR="${TEST_ROOT}/work"
DEV_LOG_DIR="${TEST_ROOT}/.forge/logs"
TASK_STACK="${TEST_ROOT}/.forge/state/task-stack.json"
DEV_CONFIG="${TEST_ROOT}/.forge/development.json"
SERVER_LC_PID_FILE="${TEST_ROOT}/.forge/state/server.pid"
SAFETY_AUTO_REVERT_ON_REGRESSION=false
SAFETY_AUTO_COMMIT_PER_PHASE=false
PHASE_CONTROL="auto"

echo '{"tasks":[]}' > "$TASK_STACK"
echo '{"server":{"start_command":"none","health_check_url":"http://127.0.0.1:59998"},"safety":{"regression_failure_policy":"block"},"layer_2":{"setup_commands":[]}}' > "$DEV_CONFIG"

source "${TEST_ROOT}/.forge/lib/server-lifecycle.sh"
source "${TEST_ROOT}/.forge/lib/handler-extract.sh"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: phase-test が WORK_DIR で実行される（cwd 修正） ---
echo -e "\n${BOLD}[1] cwd == WORK_DIR${NC}"
cat > "${TEST_ROOT}/.forge/state/phase-tests/mvp.sh" << 'SH'
#!/bin/bash
set -e
pwd > pwd-out.txt
SH
rc=0; handle_dev_phase_completion "mvp" || rc=$?
assert_eq "回帰成功で rc=0" "0" "$rc"
assert_eq "pwd-out.txt が WORK_DIR に生成される" "true" "$([ -f "${WORK_DIR}/pwd-out.txt" ] && echo true || echo false)"
recorded_pwd=$(cat "${WORK_DIR}/pwd-out.txt" 2>/dev/null | tr -d '\r')
case "$recorded_pwd" in
  *"/work") assert_eq "記録された pwd が WORK_DIR" "ok" "ok" ;;
  *) assert_eq "記録された pwd が WORK_DIR" "*/work" "$recorded_pwd" ;;
esac

# --- Test 2: server 要求 + start_command=none → env_blocked + deferred で続行 ---
echo -e "\n${BOLD}[2] server 環境不足 → 繰延で続行${NC}"
: > "$DEBT_LOG"
cat > "${TEST_ROOT}/.forge/state/phase-tests/core.sh" << 'SH'
#!/bin/bash
# forge-requires: server
set -e
curl -sf http://127.0.0.1:59998/health
SH
rc=0; handle_dev_phase_completion "core" || rc=$?
assert_eq "環境不足でも rc=0（block しない）" "0" "$rc"
assert_eq "env_blocked が台帳記録される" "1" "$(grep -c '^env_blocked|phase-core|' "$DEBT_LOG" || true)"
assert_eq "deferred_test が台帳記録される" "1" "$(grep -c '^deferred_test|phase-core|' "$DEBT_LOG" || true)"

# --- Test 3: 外部所有サーバーを kill しない ---
echo -e "\n${BOLD}[3] 外部所有サーバー非 kill${NC}"
# 外部サーバーの代役プロセス（このテストが所有）
sleep 30 &
EXTERNAL_PID=$!
# health が常に 200 → ensure は外部所有と判定
server_http_code() { printf '200'; }
cat > "${TEST_ROOT}/.forge/state/phase-tests/polish.sh" << 'SH'
#!/bin/bash
# forge-requires: server
set -e
echo ok
SH
rc=0; handle_dev_phase_completion "polish" || rc=$?
assert_eq "外部サーバー到達可能で rc=0" "0" "$rc"
assert_eq "外部プロセスが生存している（kill されない）" "alive" \
  "$(kill -0 "$EXTERNAL_PID" 2>/dev/null && echo alive || echo dead)"
kill "$EXTERNAL_PID" 2>/dev/null || true
unset -f server_http_code
source "${TEST_ROOT}/.forge/lib/server-lifecycle.sh"

# --- Test 4: 非環境起因の失敗は block ポリシー維持（rc=1） ---
echo -e "\n${BOLD}[4] 非環境起因の失敗は block${NC}"
PHASE_CONTROL="checkpoint"
: > "$DEBT_LOG"
cat > "${TEST_ROOT}/.forge/state/phase-tests/mvp.sh" << 'SH'
#!/bin/bash
set -e
echo "assertion mismatch: expected 42 got 41"
exit 1
SH
rc=0; handle_dev_phase_completion "mvp" || rc=$?
assert_eq "非環境起因 + block ポリシーで rc=1" "1" "$rc"
assert_eq "env_blocked は記録されない" "0" "$(grep -c '^env_blocked|' "$DEBT_LOG" || true)"

# ===== クリーンアップ =====
rm -rf "$TEST_ROOT"

echo ""
echo -e "${BOLD}=========================================="
echo -e "  phase-regression-cwd テスト結果"
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
