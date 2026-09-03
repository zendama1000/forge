#!/bin/bash
# test-run-claude-flags.sh — run_claude の --settings（PreToolUse guard hook）注入と FORGE_GUARD_* export
# のテスト（batch#11 R05）。FORGE_DRY_RUN=1 で構築されたコマンドラインだけを検証する。
# 使い方: bash .forge/tests/test-run-claude-flags.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/rcflags-$$")
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

export ERRORS_FILE="${TMP}/errors.jsonl"
export RESEARCH_DIR="test-run-claude-flags"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMP}/notifications"
touch "$ERRORS_FILE"
source "${PROJECT_ROOT}/.forge/lib/common.sh"

echo -e "${BOLD}===== test-run-claude-flags.sh — run_claude --settings / FORGE_GUARD_* =====${NC}"
echo ""

AGENT_FILE="${TMP}/agent.md"; echo "agent" > "$AGENT_FILE"
WORK="${TMP}/work"; mkdir -p "$WORK"
SETTINGS="${TMP}/guard.json"
echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash x.sh"}]}]}}' > "$SETTINGS"
AGENTS="${TMP}/agents.json"
echo '{"helper":{"description":"d","prompt":"p"}}' > "$AGENTS"

# CLI プローブはキャッシュ注入で決定論化（実 CLI を呼ばない）
_RC_CLI_HELP_CACHE="  --settings <file-or-json>  --agents <json>  --max-budget-usd <amount>"

dry() { FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "prompt" "${TMP}/out.txt" "${TMP}/log.txt" "" 10 "$@"; }

# ========================================================================
echo -e "${BOLD}--- Group 1: --settings の付与条件 ---${NC}"
# ========================================================================
unset _RC_SETTINGS_FILE FORGE_GUARD_WORK_DIR FORGE_GUARD_HARNESS_ROOT 2>/dev/null || true
out=$(dry "$WORK")
assert_not_contains "_RC_SETTINGS_FILE 未設定 → --settings なし" "--settings" "$out"

_RC_SETTINGS_FILE="$SETTINGS"
out=$(dry "$WORK")
assert_contains "_RC_SETTINGS_FILE 設定 → --settings <path>" "--settings ${SETTINGS}" "$out"

_RC_SETTINGS_FILE="${TMP}/missing.json"
out=$(dry "$WORK")
assert_not_contains "不在パス → --settings なし" "--settings" "$out"

_RC_SETTINGS_FILE="$SETTINGS"
out=$(FORGE_GUARD_DISABLE=1 dry "$WORK")
assert_not_contains "FORGE_GUARD_DISABLE=1 → --settings なし（戻し用）" "--settings" "$out"

_RC_CLI_HELP_CACHE="  --agents <json>  --max-budget-usd <amount>"
out=$(dry "$WORK")
assert_not_contains "CLI が --settings 非対応（プローブ）→ 付与しない（未知フラグ即死防止）" "--settings" "$out"
_RC_CLI_HELP_CACHE="  --settings <file-or-json>  --agents <json>  --max-budget-usd <amount>"

# 相対パスは cd 前に絶対化される
( cd "$TMP" && _RC_SETTINGS_FILE="guard.json" && out=$(FORGE_DRY_RUN=1 run_claude "haiku" "$AGENT_FILE" "p" "${TMP}/o.txt" "${TMP}/l.txt" "" 10 "$WORK") && printf '%s' "$out" > "${TMP}/rel.out" )
assert_contains "相対パスの settings は絶対化される" "--settings ${TMP}/guard.json" "$(cat "${TMP}/rel.out")"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: FORGE_GUARD_* の export ---${NC}"
# ========================================================================
_RC_SETTINGS_FILE="$SETTINGS"
unset FORGE_GUARD_WORK_DIR FORGE_GUARD_HARNESS_ROOT FORGE_GUARD_CB_CONFIG 2>/dev/null || true
dry "$WORK" >/dev/null
# Windows では cygpath -ml（長い名前の Windows 形式）に揃えて渡す。Linux では pwd -P のまま
exp_wd="$(cd "$WORK" && pwd -P)"; exp_root="$PROJECT_ROOT"
if command -v cygpath >/dev/null 2>&1; then exp_wd=$(cygpath -ml "$exp_wd"); exp_root=$(cygpath -ml "$exp_root"); fi
assert_eq "FORGE_GUARD_WORK_DIR = 絶対化した work_dir（Windows は長形式）" "$exp_wd" "${FORGE_GUARD_WORK_DIR:-}"
assert_eq "FORGE_GUARD_HARNESS_ROOT = PROJECT_ROOT" "$exp_root" "${FORGE_GUARD_HARNESS_ROOT:-}"
assert_eq "FORGE_GUARD_CB_CONFIG = circuit-breaker.json" "${PROJECT_ROOT}/.forge/config/circuit-breaker.json" "${FORGE_GUARD_CB_CONFIG:-}"
assert_eq "FORGE_GUARD_WORK_DIR は子プロセスに渡る（export）" "$exp_wd" "$(bash -c 'printf "%s" "${FORGE_GUARD_WORK_DIR:-}"')"
assert_eq "WORK_DIR に 8.3 短縮名（~）や MSYS /tmp 形式が残らない" "false" "$(case "${FORGE_GUARD_WORK_DIR:-}" in *~*|/tmp/*) echo true ;; *) echo false ;; esac)"
assert_contains "FORGE_GUARD_PATTERNS に protected_patterns が展開される（hook の jq 節約）" "p:.forge/**" "${FORGE_GUARD_PATTERNS:-}"
assert_contains "FORGE_GUARD_PATTERNS に test_sanctity パターン" "t:*.test.*" "${FORGE_GUARD_PATTERNS:-}"

dry "" >/dev/null
assert_eq "work_dir 空 → FORGE_GUARD_WORK_DIR は空（WORK_DIR 系検査は hook 側でスキップ）" "" "${FORGE_GUARD_WORK_DIR:-}"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: 他フラグとの併存 ---${NC}"
# ========================================================================
_RC_AGENTS_FILE="$AGENTS"
out=$(dry "$WORK")
assert_contains "--settings と --agents が併存" "--settings" "$out"
assert_contains "--agents は最後に残る（総長ガード対象）" "--agents {" "$out"
pos_settings=$(printf '%s' "$out" | grep -o -- '--settings.*' | head -1)
assert_contains "--settings は --agents より前" "--agents" "$pos_settings"
unset _RC_AGENTS_FILE
out=$(dry "$WORK")
assert_contains "--disallowed-tools 等の既存フラグに影響しない（--dangerously-skip-permissions 維持）" "--dangerously-skip-permissions" "$out"
assert_contains "--output-format json 維持" "--output-format json" "$out"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 4: 静的 settings ファイル ---${NC}"
# ========================================================================
REAL="${PROJECT_ROOT}/.forge/config/claude-guard-settings.json"
assert_eq "claude-guard-settings.json が有効 JSON" "true" "$(jq -e . "$REAL" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "hook が forge-guard.sh を呼ぶ" "true" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$REAL" | grep -q 'forge-guard.sh' && echo true || echo false)"
assert_eq "hook は FORGE_GUARD_HARNESS_ROOT でパスを解決する（cwd=WORK_DIR に依存しない）" "true" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$REAL" | grep -q 'FORGE_GUARD_HARNESS_ROOT' && echo true || echo false)"
assert_eq "forge-guard.sh の構文" "true" "$(bash -n "${PROJECT_ROOT}/.claude/hooks/forge-guard.sh" 2>/dev/null && echo true || echo false)"
echo ""

print_test_summary
