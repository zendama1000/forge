#!/bin/bash
# test-agents-wiring.sh — run_claude への --agents 配線（agent_flow L3 の -p 自動化）のテスト
# build_agents_json（.md → インライン JSON 変換）/ _RC_AGENTS_FILE env チャネル /
# execute_l3_agent_flow の step.subagent_files 対応を検証する。
# 使い方: bash .forge/tests/test-agents-wiring.sh

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
export RESEARCH_DIR="test-agents-wiring"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMPDIR}/notifications"
json_fail_count=0
touch "$ERRORS_FILE"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

echo -e "${BOLD}===== test-agents-wiring.sh — --agents 配線（-p Task 委譲） =====${NC}"
echo ""

# ===== fixture: エージェント定義 .md =====
AGENT_A="${TMPDIR}/agent-alpha.md"
AGENT_B="${TMPDIR}/agent-beta.md"
AGENT_NOHEAD="${TMPDIR}/agent-nohead.md"
cat > "$AGENT_A" <<'EOF'
# Alpha Agent

## 役割

あなたは Alpha です。ファイルを生成します。
EOF
cat > "$AGENT_B" <<'EOF'
## Beta Reviewer

レビューを行う。
EOF
printf 'no heading here\njust prose\n' > "$AGENT_NOHEAD"

# ========================================================================
echo -e "${BOLD}--- Group 1: build_agents_json（純関数） ---${NC}"
# ========================================================================

# behavior: 単一 .md → name=stem / description=先頭見出し / prompt=全文 の JSON になる
out1=$(build_agents_json "$AGENT_A" 2>/dev/null)
assert_eq "valid JSON である" "0" "$(echo "$out1" | jq empty 2>/dev/null; echo $?)"
assert_eq "name はファイル名 stem" "agent-alpha" "$(echo "$out1" | jq -r 'keys[0]')"
assert_eq "description は先頭見出し（# 除去）" "Alpha Agent" "$(echo "$out1" | jq -r '."agent-alpha".description')"
assert_eq "prompt に本文全文が含まれる" "true" "$(echo "$out1" | jq '."agent-alpha".prompt | contains("あなたは Alpha です")')"

# behavior: 複数 .md → 全エージェントがマージされる
out2=$(build_agents_json "$AGENT_A" "$AGENT_B" 2>/dev/null)
assert_eq "2 エージェントがマージされる" "2" "$(echo "$out2" | jq 'keys | length')"
assert_eq "## 見出しも description になる" "Beta Reviewer" "$(echo "$out2" | jq -r '."agent-beta".description')"

# behavior: 見出しなし .md → description は name にフォールバック
out3=$(build_agents_json "$AGENT_NOHEAD" 2>/dev/null)
assert_eq "見出しなし → description=name" "agent-nohead" "$(echo "$out3" | jq -r '."agent-nohead".description')"

# behavior: ファイル不在は skip して残りを処理（graceful）
out4=$(build_agents_json "${TMPDIR}/nonexistent.md" "$AGENT_A" 2>/dev/null)
assert_eq "不在ファイル skip 後も有効エージェントは処理" "1" "$(echo "$out4" | jq 'keys | length')"

# behavior: 引数 0 件 → "{}"
assert_eq "引数 0 件 → 空オブジェクト" "{}" "$(build_agents_json 2>/dev/null)"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: run_claude への合成（FORGE_DRY_RUN + env チャネル） ---${NC}"
# ========================================================================

SYS_AGENT="${TMPDIR}/sys-agent.md"
echo "system prompt agent" > "$SYS_AGENT"
AGENTS_JSON_FILE="${TMPDIR}/agents.json"
build_agents_json "$AGENT_A" > "$AGENTS_JSON_FILE" 2>/dev/null

# behavior: _RC_AGENTS_FILE 設定 + プローブ通過 → CMD に --agents + 定義 JSON が含まれる
_RC_CLI_HELP_CACHE="  --agents <json>  --model <model>"
export _RC_AGENTS_FILE="$AGENTS_JSON_FILE"
cmd_agents=$(FORGE_DRY_RUN=1 run_claude "haiku" "$SYS_AGENT" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_contains "設定時: CMD に --agents 付与" "--agents" "$cmd_agents"
assert_contains "設定時: エージェント定義 JSON が展開される" '"agent-alpha"' "$cmd_agents"

# behavior: プローブ不通過（旧 CLI）→ --agents を渡さない（未知フラグ即死の防止）
_RC_CLI_HELP_CACHE="  --model <model>"
cmd_noflag=$(FORGE_DRY_RUN=1 run_claude "haiku" "$SYS_AGENT" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt" 2>/dev/null)
assert_not_contains "プローブ不通過: --agents なし" "--agents" "$cmd_noflag"

# behavior: 不正 JSON ファイル → 付与しない（graceful）
_RC_CLI_HELP_CACHE="  --agents <json>"
echo "not json {" > "${TMPDIR}/broken.json"
export _RC_AGENTS_FILE="${TMPDIR}/broken.json"
cmd_broken=$(FORGE_DRY_RUN=1 run_claude "haiku" "$SYS_AGENT" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt" 2>/dev/null)
assert_not_contains "不正 JSON: --agents なし" "--agents" "$cmd_broken"

# behavior: 未設定 → --agents なし（他エージェント非汚染）
unset _RC_AGENTS_FILE
cmd_unset=$(FORGE_DRY_RUN=1 run_claude "haiku" "$SYS_AGENT" "prompt" "${TMPDIR}/out.txt" "${TMPDIR}/log.txt")
assert_not_contains "未設定: --agents なし" "--agents" "$cmd_unset"
unset _RC_CLI_HELP_CACHE

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: execute_l3_agent_flow の subagent_files 統合 ---${NC}"
# ========================================================================

# fake PROJECT_ROOT（実 .forge/state を汚染しない）
FAKE_ROOT="${TMPDIR}/fake-root"
mkdir -p "${FAKE_ROOT}/.forge/state" "${FAKE_ROOT}/.forge/logs/development" "${FAKE_ROOT}/agents"
cp "$AGENT_A" "${FAKE_ROOT}/agents/agent-alpha.md"
_ORIG_PROJECT_ROOT="$PROJECT_ROOT"
PROJECT_ROOT="$FAKE_ROOT"

# run_claude モック: 呼出時点の _RC_AGENTS_FILE を記録し、step 出力を生成する
CAPTURE_FILE="${TMPDIR}/captured-agents-env.txt"
run_claude() {
  echo "${_RC_AGENTS_FILE:-<unset>}" >> "$CAPTURE_FILE"
  echo '{"ok": true}' > "${4}.pending"
  return 0
}

# behavior: subagent_files 付き step → run_claude 呼出時に _RC_AGENTS_FILE が
#           state_dir の生成 JSON を指し、内容にエージェント定義が含まれる
: > "$CAPTURE_FILE"
L3_TEST_SUB='{
  "id": "wiring-sub",
  "strategy": "agent_flow",
  "definition": {
    "steps": [
      {"step_id": "s1", "prompt_template": "delegate work", "model": "haiku",
       "subagent_files": ["agents/agent-alpha.md"]}
    ]
  }
}'
rc=0
execute_l3_agent_flow "$L3_TEST_SUB" "$TMPDIR" 30 > /dev/null 2>&1 || rc=$?
GEN_JSON="${FAKE_ROOT}/.forge/state/l3-agent-wiring-sub/agents-s1.json"
assert_eq "agent_flow は成功する" "0" "$rc"
assert_eq "run_claude 呼出時に _RC_AGENTS_FILE が設定されている" "$GEN_JSON" "$(head -1 "$CAPTURE_FILE")"
assert_eq "生成 JSON にエージェント定義がある" "agent-alpha" "$(jq -r 'keys[0]' "$GEN_JSON" 2>/dev/null)"
assert_eq "相対パスが PROJECT_ROOT 基準で解決される（prompt 全文）" "true" "$(jq '."agent-alpha".prompt | contains("あなたは Alpha です")' "$GEN_JSON" 2>/dev/null)"
assert_eq "呼出後に _RC_AGENTS_FILE が復元（unset）される" "<unset>" "${_RC_AGENTS_FILE:-<unset>}"

# behavior: subagent_files なしの step → _RC_AGENTS_FILE は未設定のまま（後方互換）
: > "$CAPTURE_FILE"
L3_TEST_PLAIN='{
  "id": "wiring-plain",
  "strategy": "agent_flow",
  "definition": {
    "steps": [
      {"step_id": "p1", "prompt_template": "plain step", "model": "haiku"}
    ]
  }
}'
rc=0
execute_l3_agent_flow "$L3_TEST_PLAIN" "$TMPDIR" 30 > /dev/null 2>&1 || rc=$?
assert_eq "subagent_files なし: agent_flow は成功する" "0" "$rc"
assert_eq "subagent_files なし: _RC_AGENTS_FILE は未設定のまま" "<unset>" "$(head -1 "$CAPTURE_FILE")"

# behavior: step 失敗時も _RC_AGENTS_FILE が復元される（漏洩防止）
run_claude() {
  echo "${_RC_AGENTS_FILE:-<unset>}" >> "$CAPTURE_FILE"
  return 1
}
: > "$CAPTURE_FILE"
rc=0
execute_l3_agent_flow "$L3_TEST_SUB" "$TMPDIR" 30 > /dev/null 2>&1 || rc=$?
assert_eq "step 失敗時は return 1" "1" "$rc"
assert_eq "失敗 return 後も _RC_AGENTS_FILE が復元（unset）される" "<unset>" "${_RC_AGENTS_FILE:-<unset>}"

PROJECT_ROOT="$_ORIG_PROJECT_ROOT"

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
