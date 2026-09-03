#!/bin/bash
# test-per-call-guards.sh — per-call 予算ガード（--max-budget-usd / --max-turns プローブ）のテスト
# build_per_call_guard_args / claude_cli_supports_flag / run_claude への合成を FORGE_DRY_RUN で検証。
# 使い方: bash .forge/tests/test-per-call-guards.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:300}"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export RESEARCH_DIR="test-per-call-guards"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMPDIR}/notifications"
json_fail_count=0
touch "$ERRORS_FILE"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

echo -e "${BOLD}===== test-per-call-guards.sh — per-call 予算ガード =====${NC}"
echo ""

# ===== fixture config =====
CFG_OFF="${TMPDIR}/cb-off.json"
CFG_BUDGET="${TMPDIR}/cb-budget.json"
CFG_BOTH="${TMPDIR}/cb-both.json"
CFG_INVALID="${TMPDIR}/cb-invalid.json"
CFG_ABSENT="${TMPDIR}/cb-absent.json"
echo '{"per_call_guards": {"max_budget_usd": 0, "max_turns": 0}}' > "$CFG_OFF"
echo '{"per_call_guards": {"max_budget_usd": 3.0, "max_turns": 0}}' > "$CFG_BUDGET"
echo '{"per_call_guards": {"max_budget_usd": 2.5, "max_turns": 150}}' > "$CFG_BOTH"
echo '{"per_call_guards": {"max_budget_usd": "abc", "max_turns": -5}}' > "$CFG_INVALID"
echo '{}' > "$CFG_ABSENT"

# ========================================================================
echo -e "${BOLD}--- Group 1: build_per_call_guard_args（純関数） ---${NC}"
# ========================================================================

# behavior: 0/キー不在/config 不在 → 空出力（後方互換: フラグなし）
assert_eq "全て 0 → 空出力" "" "$(build_per_call_guard_args "$CFG_OFF")"
assert_eq "per_call_guards キー不在 → 空出力" "" "$(build_per_call_guard_args "$CFG_ABSENT")"
assert_eq "config ファイル不在 → 空出力" "" "$(build_per_call_guard_args "${TMPDIR}/nonexistent.json")"

# behavior: budget のみ設定 → --max-budget-usd のみ
assert_eq "budget=3.0 → --max-budget-usd 3.0" "--max-budget-usd 3.0" "$(build_per_call_guard_args "$CFG_BUDGET")"

# behavior: 非数値/負値 → 無効扱い（フラグなし）
assert_eq "非数値 budget / 負 turns → 空出力" "" "$(build_per_call_guard_args "$CFG_INVALID")"

# behavior: turns は CLI プローブ通過時のみ付与（キャッシュ注入で両分岐を検証）
_RC_CLI_HELP_CACHE="  --max-budget-usd <amount>  --max-turns <n>  --model <model>"
out_both=$(build_per_call_guard_args "$CFG_BOTH")
assert_eq "プローブ通過 → budget + turns" "--max-budget-usd 2.5 --max-turns 150" "$out_both"

_RC_CLI_HELP_CACHE="  --max-budget-usd <amount>  --model <model>"
out_noturns=$(build_per_call_guard_args "$CFG_BOTH")
assert_eq "プローブ不通過 → budget のみ（未知フラグを渡さない）" "--max-budget-usd 2.5" "$out_noturns"
unset _RC_CLI_HELP_CACHE

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: run_claude への合成（FORGE_DRY_RUN） ---${NC}"
# ========================================================================

AGENT_FILE="${TMPDIR}/agent.md"
echo "test agent" > "$AGENT_FILE"

# behavior: ガード無効（実 config は初期値 0）→ CMD にガードフラグが含まれない
_ORIG_PROJECT_ROOT="$PROJECT_ROOT"
FAKE_ROOT="${TMPDIR}/fake-root-off"
mkdir -p "${FAKE_ROOT}/.forge/config"
cp "$CFG_OFF" "${FAKE_ROOT}/.forge/config/circuit-breaker.json"
PROJECT_ROOT="$FAKE_ROOT"
cmd_off=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_not_contains "ガード 0 → CMD に --max-budget-usd なし" "--max-budget-usd" "$cmd_off"

# behavior: budget=3.0 → CMD に --max-budget-usd 3.0 が含まれる
FAKE_ROOT2="${TMPDIR}/fake-root-on"
mkdir -p "${FAKE_ROOT2}/.forge/config"
cp "$CFG_BUDGET" "${FAKE_ROOT2}/.forge/config/circuit-breaker.json"
PROJECT_ROOT="$FAKE_ROOT2"
cmd_on=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_contains "budget=3.0 → CMD に --max-budget-usd 3.0" "--max-budget-usd 3.0" "$cmd_on"

# behavior: effort / schema フラグと併存できる
SCHEMA_FILE="${TMPDIR}/schema.json"
echo '{"type":"object"}' > "$SCHEMA_FILE"
cmd_all=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt" "" 600 "" "$SCHEMA_FILE" "high")
assert_contains "併存: --effort high" "--effort high" "$cmd_all"
assert_contains "併存: --max-budget-usd" "--max-budget-usd 3.0" "$cmd_all"
assert_contains "併存: --json-schema" "--json-schema" "$cmd_all"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: _RC_MCP_CONFIG env チャネル ---${NC}"
# ========================================================================

# behavior: _RC_MCP_CONFIG 設定時のみ --mcp-config + --strict-mcp-config が付与される
MCP_FILE="${TMPDIR}/mcp.json"
echo '{"mcpServers":{}}' > "$MCP_FILE"
export _RC_MCP_CONFIG="$MCP_FILE"
cmd_mcp=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_contains "MCP 設定時: --mcp-config 付与" "--mcp-config ${MCP_FILE}" "$cmd_mcp"
assert_contains "MCP 設定時: --strict-mcp-config 付与（外部 MCP 遮断）" "--strict-mcp-config" "$cmd_mcp"
unset _RC_MCP_CONFIG

cmd_nomcp=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_not_contains "MCP 未設定: --mcp-config なし（他エージェント非汚染）" "--mcp-config" "$cmd_nomcp"

# behavior: 存在しないパスを指す場合は付与しない（graceful）
export _RC_MCP_CONFIG="${TMPDIR}/nonexistent-mcp.json"
cmd_badmcp=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_not_contains "MCP パス不在: --mcp-config なし" "--mcp-config" "$cmd_badmcp"
unset _RC_MCP_CONFIG

PROJECT_ROOT="$_ORIG_PROJECT_ROOT"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 4: classify_run_claude_exit（予算超過の exit code 分類・純関数） ---${NC}"
# ========================================================================

BUDGET_MSG_FILE="${TMPDIR}/budget-msg.txt"
OTHER_MSG_FILE="${TMPDIR}/other-msg.txt"
echo "Error: Exceeded USD budget (3.0)" > "$BUDGET_MSG_FILE"
echo "some other error" > "$OTHER_MSG_FILE"

# behavior: exit 1 + 予算超過メッセージ → RC_EXIT_BUDGET_EXCEEDED(21) に分類
assert_eq "exit 1 + budget メッセージ → 21" "21" "$(classify_run_claude_exit 1 "$BUDGET_MSG_FILE")"

# behavior: exit 1 + 無関係メッセージ → 素通し（1 のまま）
assert_eq "exit 1 + 他メッセージ → 1 素通し" "1" "$(classify_run_claude_exit 1 "$OTHER_MSG_FILE")"

# behavior: exit 124（タイムアウト）はメッセージがあっても分類しない
assert_eq "exit 124 + budget メッセージ → 124 素通し（タイムアウト優先）" "124" "$(classify_run_claude_exit 124 "$BUDGET_MSG_FILE")"

# behavior: exit 0（成功）は分類対象外
assert_eq "exit 0 → 0 素通し" "0" "$(classify_run_claude_exit 0 "$BUDGET_MSG_FILE")"

# behavior: 出力ファイル不在 → 素通し（graceful）
assert_eq "ファイル不在 → 1 素通し" "1" "$(classify_run_claude_exit 1 "${TMPDIR}/nonexistent-out.txt")"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 5: run_claude 統合（fake claude で予算超過 exit 21） ---${NC}"
# ========================================================================

# fake claude: 実 CLI の予算超過挙動（exit 1 + stdout メッセージ、2.1.199 実測）を再現
# プローブ（claude --help）が fake claude を呼んで呼出カウントを汚染しないようキャッシュを事前注入
_RC_CLI_HELP_CACHE="  --max-budget-usd <amount>  --max-turns <n>  --agents <json>"
FAKE_BIN="${TMPDIR}/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/bin/bash
echo "Error: Exceeded USD budget (3.0)"
exit 1
EOF
chmod +x "${FAKE_BIN}/claude"

# behavior: claude が予算超過で失敗 → run_claude は 21 を返し .pending を残さない
rc=0
PATH="${FAKE_BIN}:$PATH" run_claude "haiku" "$AGENT_FILE" "prompt" \
  "${TMPDIR}/out-budget.txt" "${TMPDIR}/log-budget.txt" 2>/dev/null || rc=$?
assert_eq "予算超過 → run_claude exit 21" "21" "$rc"
assert_eq ".pending が残らない" "false" "$([ -f "${TMPDIR}/out-budget.txt.pending" ] && echo true || echo false)"

# behavior: 予算超過以外の失敗は従来どおり exit 1（分類の誤爆なし）
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/bin/bash
echo "some transient error"
exit 1
EOF
rc=0
PATH="${FAKE_BIN}:$PATH" run_claude "haiku" "$AGENT_FILE" "prompt" \
  "${TMPDIR}/out-other.txt" "${TMPDIR}/log-other.txt" 2>/dev/null || rc=$?
assert_eq "他の失敗 → run_claude exit 1（後方互換）" "1" "$rc"

# behavior: retry_with_backoff + run_claude 統合 — 予算超過はリトライされず1回で打ち切り
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/bin/bash
echo "call" >> "${FAKE_CALL_LOG}"
echo "Error: Exceeded USD budget (3.0)"
exit 1
EOF
export FAKE_CALL_LOG="${TMPDIR}/fake-call.log"
: > "$FAKE_CALL_LOG"
rc=0
PATH="${FAKE_BIN}:$PATH" retry_with_backoff 3 1 run_claude "haiku" "$AGENT_FILE" "prompt" \
  "${TMPDIR}/out-retry.txt" "${TMPDIR}/log-retry.txt" 2>/dev/null || rc=$?
assert_eq "retry_with_backoff 経由でも exit 21" "21" "$rc"
assert_eq "claude 呼出は1回のみ（無駄リトライなし）" "1" "$(wc -l < "$FAKE_CALL_LOG" | tr -d ' ')"
unset FAKE_CALL_LOG

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 6: --append-system-prompt（自律運用の共通 2 文, batch#11 R25a） ---${NC}"
# ========================================================================
_RC_CLI_HELP_CACHE="  --append-system-prompt <prompt>  --system-prompt <prompt>  --max-budget-usd <amount>"
unset FORGE_APPEND_SYSTEM_PROMPT 2>/dev/null || true
PROJECT_ROOT="$_ORIG_PROJECT_ROOT"
cmd_ap=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out-ap.txt" "${TMPDIR}/log-ap.txt")
assert_contains "既定で --append-system-prompt が付く" "--append-system-prompt" "$cmd_ap"
assert_contains "既定文に書込禁止の規則" "ハーネス配下" "$cmd_ap"
assert_contains "既定文にテスト不改変の規則" "既存のテスト・採点スクリプトを改変しない" "$cmd_ap"
assert_contains "--system-prompt（エージェント定義）と併存" "--system-prompt test agent" "$cmd_ap"
cmd_ap_off=$(FORGE_APPEND_SYSTEM_PROMPT='' FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out-ap.txt" "${TMPDIR}/log-ap.txt")
assert_not_contains "FORGE_APPEND_SYSTEM_PROMPT='' で付かない（無効化）" "--append-system-prompt" "$cmd_ap_off"
cmd_ap_custom=$(FORGE_APPEND_SYSTEM_PROMPT='カスタム規則' FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out-ap.txt" "${TMPDIR}/log-ap.txt")
assert_contains "FORGE_APPEND_SYSTEM_PROMPT で差し替え可" "--append-system-prompt カスタム規則" "$cmd_ap_custom"
_RC_CLI_HELP_CACHE="  --system-prompt <prompt>  --max-budget-usd <amount>"
cmd_ap_noflag=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMPDIR}/out-ap.txt" "${TMPDIR}/log-ap.txt")
assert_not_contains "CLI が非対応（プローブ）なら付けない" "--append-system-prompt" "$cmd_ap_noflag"
unset _RC_CLI_HELP_CACHE
_ap_len=${#FORGE_APPEND_SYSTEM_PROMPT_DEFAULT}
assert_eq "既定文は 400 字以内（総長ガードに影響しない）" "true" "$([ "$_ap_len" -le 400 ] && echo true || echo false)"
# bootstrap.sh のサブエージェント上限 export（実 source で確認）
_bt_probe="${_ORIG_PROJECT_ROOT}/.forge/tests/.tmp-bootstrap-probe-$$.sh"
printf '%s\n' '#!/bin/bash' 'source "$(dirname "${BASH_SOURCE[0]}")/../lib/bootstrap.sh"' 'printf "%s|%s" "${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH:-}" "${CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS:-}"' > "$_bt_probe"
_bt_out=$(env -u CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -u CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS bash "$_bt_probe" 2>/dev/null)
assert_eq "bootstrap.sh がサブエージェント上限を export（depth 1 / concurrent 4）" "1|4" "$_bt_out"
_bt_out2=$(CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2 bash "$_bt_probe" 2>/dev/null)
assert_contains "外部設定済みなら尊重（depth 2）" "2|" "$_bt_out2"
rm -f "$_bt_probe"

echo ""

# ========================================================================
# サマリー
# ========================================================================
TOTAL=$((PASS + FAIL))
echo -e "${BOLD}=========================================${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL}/${TOTAL}${NC}"
fi
echo -e "${BOLD}=========================================${NC}"

exit "$FAIL"
