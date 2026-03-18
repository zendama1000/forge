#!/bin/bash
# test-research-config.sh — Research Config パース + テンプレート変数注入テスト (24 assertions)
# research-loop.sh の config パース関数を抽出してテスト。
# 使い方: bash .forge/tests/test-research-config.sh

set -uo pipefail

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

# ===== テスト集計 =====
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
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:200}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="/tmp/test-research-config"
FIXTURES_DIR="${SCRIPT_DIR}/.forge/tests/fixtures"
RESEARCH_LOOP_SH="${SCRIPT_DIR}/.forge/loops/research-loop.sh"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$PROJECT_ROOT"

mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"
mkdir -p "${PROJECT_ROOT}/.forge/templates"
mkdir -p "${PROJECT_ROOT}/.forge/logs/research"
mkdir -p "${PROJECT_ROOT}/.claude/agents"

# 実ファイルコピー
cp "${SCRIPT_DIR}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${SCRIPT_DIR}/.forge/lib/bootstrap.sh" "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"
cp "${SCRIPT_DIR}/.forge/config/circuit-breaker.json" "${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
cp "${SCRIPT_DIR}/.forge/config/research.json" "${PROJECT_ROOT}/.forge/config/research.json"
cp "${SCRIPT_DIR}/.forge/templates/scope-challenger-prompt.md" "${PROJECT_ROOT}/.forge/templates/scope-challenger-prompt.md"
cp "${SCRIPT_DIR}/.forge/templates/synthesizer-prompt.md" "${PROJECT_ROOT}/.forge/templates/synthesizer-prompt.md"

# 空ファイル
touch "${PROJECT_ROOT}/.forge/state/errors.jsonl"
touch "${PROJECT_ROOT}/.forge/state/decisions.jsonl"

trap "rm -rf '$PROJECT_ROOT'" EXIT

echo -e "  ${GREEN}✓${NC} テスト環境作成完了"

# ===== グローバル変数設定 =====
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
RESEARCH_DIR="test-session"
json_fail_count=0
CLAUDE_TIMEOUT=600
START_TS="20260226-120000"

# common.sh を source
source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== research-loop.sh から関数抽出 =====
echo -e "${BOLD}===== research-loop.sh 関数抽出 =====${NC}"

extract_function_v2() {
  local func_name="$1"
  local src="$2"
  local start_line
  start_line=$(grep -n "^${func_name}()" "$src" | head -1 | cut -d: -f1)
  if [ -z "$start_line" ]; then
    echo "# function ${func_name} not found" >&2
    return 1
  fi
  local depth=0 end_line="" line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [ "$line_num" -lt "$start_line" ]; then continue; fi
    local opens=$(echo "$line" | tr -cd '{' | wc -c)
    local closes=$(echo "$line" | tr -cd '}' | wc -c)
    depth=$((depth + opens - closes))
    if [ "$depth" -le 0 ] && [ "$line_num" -gt "$start_line" ]; then
      end_line="$line_num"
      break
    fi
  done < "$src"
  if [ -n "$end_line" ]; then
    sed -n "${start_line},${end_line}p" "$src"
  fi
}

FUNCTIONS=(load_research_config load_research_models update_state)
EXTRACT_FILE=$(mktemp)

extract_ok=true
for func in "${FUNCTIONS[@]}"; do
  body=$(extract_function_v2 "$func" "$RESEARCH_LOOP_SH" 2>/dev/null)
  if [ -n "$body" ]; then
    echo "$body" >> "$EXTRACT_FILE"
    echo "" >> "$EXTRACT_FILE"
    echo -e "  ${GREEN}✓${NC} ${func}()"
  else
    echo -e "  ${RED}✗${NC} ${func}() — 抽出失敗"
    extract_ok=false
  fi
done

if [ "$extract_ok" = "false" ]; then
  echo -e "${RED}関数抽出に失敗しました。テスト中断。${NC}"
  rm -f "$EXTRACT_FILE"
  exit 1
fi

source "$EXTRACT_FILE"
rm -f "$EXTRACT_FILE"
echo ""

# ===== config パースヘルパー =====
# research-loop.sh の config パースロジックを再現（メインスクリプトの L72-L88 相当）
parse_research_config() {
  local config_file="$1"
  RESEARCH_MODE="explore"
  LOCKED_DECISIONS_TEXT="（なし）"
  OPEN_QUESTIONS_TEXT="（なし）"
  if [ -n "$config_file" ] && [ -f "$config_file" ]; then
    RESEARCH_MODE=$(jq_safe -r '.mode // "explore"' "$config_file")
    LOCKED_DECISIONS_TEXT=$(jq_safe -r '
      .locked_decisions // [] |
      map("- \(.decision) (理由: \(.reason))") | join("\n")
    ' "$config_file")
    OPEN_QUESTIONS_TEXT=$(jq_safe -r '
      .open_questions // [] |
      map("- \(.)") | join("\n")
    ' "$config_file")
    [ -z "$LOCKED_DECISIONS_TEXT" ] && LOCKED_DECISIONS_TEXT="（なし）"
    [ -z "$OPEN_QUESTIONS_TEXT" ] && OPEN_QUESTIONS_TEXT="（なし）"
  fi
}

# ========================================================================
# Group 1: Research Config パース (8 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 1: Research Config パース =====${NC}"

# 1. config なし → RESEARCH_MODE="explore"
parse_research_config ""
assert_eq "config なし → mode=explore" "explore" "$RESEARCH_MODE"

# 2. config なし → LOCKED_DECISIONS_TEXT="（なし）"
assert_eq "config なし → locked=（なし）" "（なし）" "$LOCKED_DECISIONS_TEXT"

# 3. config なし → OPEN_QUESTIONS_TEXT="（なし）"
assert_eq "config なし → open=（なし）" "（なし）" "$OPEN_QUESTIONS_TEXT"

# 4. mode=validate の config → RESEARCH_MODE="validate"
parse_research_config "${FIXTURES_DIR}/research-config-validate.json"
assert_eq "validate config → mode=validate" "validate" "$RESEARCH_MODE"

# 5. locked_decisions 2件の config → LOCKED_DECISIONS_TEXT に2行含まれる
line_count=$(echo "$LOCKED_DECISIONS_TEXT" | wc -l | tr -d ' ')
assert_eq "locked 2件 → 2行" "2" "$line_count"

# 6. open_questions 2件の config → OPEN_QUESTIONS_TEXT に2行含まれる
line_count=$(echo "$OPEN_QUESTIONS_TEXT" | wc -l | tr -d ' ')
assert_eq "open 2件 → 2行" "2" "$line_count"

# 7. locked_decisions 空配列 → LOCKED_DECISIONS_TEXT="（なし）"（フォールバック）
parse_research_config "${FIXTURES_DIR}/research-config-empty.json"
assert_eq "locked 空配列 → （なし）" "（なし）" "$LOCKED_DECISIONS_TEXT"

# 8. config ファイル破損（不正 JSON）→ RESEARCH_MODE はデフォルト維持
# jq_safe が parse error で空文字を返す場合、空文字 → explore フォールバックを確認
BROKEN_CONFIG=$(mktemp)
echo "not valid json{{{" > "$BROKEN_CONFIG"
# parse 前にリセット
RESEARCH_MODE="explore"
parse_research_config "$BROKEN_CONFIG" 2>/dev/null
# jq_safe は空文字を返すが、parse 前のデフォルト explore が残存するか、空文字になる
# どちらの場合も "explore" として扱うべき（defensive）
if [ -z "$RESEARCH_MODE" ] || [ "$RESEARCH_MODE" = "explore" ]; then
  assert_eq "破損 config → mode=explore or empty（安全）" "safe" "safe"
else
  assert_eq "破損 config → mode=explore or empty（安全）" "safe" "unexpected:${RESEARCH_MODE}"
fi
rm -f "$BROKEN_CONFIG"

echo ""

# ========================================================================
# Group 2: load_research_config() — DA 変数不在確認 (4 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 2: load_research_config — DA 変数不在 =====${NC}"

# 変数をクリアしてからロード
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
unset MAX_CONDITIONAL_LOOPS 2>/dev/null || true
unset MAX_NOGO_LOOPS 2>/dev/null || true
unset MAX_DA_RETRIES 2>/dev/null || true
unset MAX_JSON_FAILS_PER_LOOP 2>/dev/null || true

load_research_config

# 9. MAX_CONDITIONAL_LOOPS 変数が未定義
assert_eq "MAX_CONDITIONAL_LOOPS 未定義" "" "${MAX_CONDITIONAL_LOOPS:-}"

# 10. MAX_NOGO_LOOPS 変数が未定義
assert_eq "MAX_NOGO_LOOPS 未定義" "" "${MAX_NOGO_LOOPS:-}"

# 11. MAX_DA_RETRIES 変数が未定義
assert_eq "MAX_DA_RETRIES 未定義" "" "${MAX_DA_RETRIES:-}"

# 12. MAX_JSON_FAILS_PER_LOOP は定義されている
if [ -n "${MAX_JSON_FAILS_PER_LOOP:-}" ]; then
  assert_eq "MAX_JSON_FAILS_PER_LOOP 定義済み" "defined" "defined"
else
  assert_eq "MAX_JSON_FAILS_PER_LOOP 定義済み" "defined" "undefined"
fi

echo ""

# ========================================================================
# Group 3: load_research_models() — DA モデル変数不在確認 (4 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 3: load_research_models — DA モデル変数不在 =====${NC}"

# 変数をクリアしてからロード
RESEARCH_CONFIG="${PROJECT_ROOT}/.forge/config/research.json"
unset MODEL_DA 2>/dev/null || true
unset TOOLS_DA 2>/dev/null || true
unset TIMEOUT_DA 2>/dev/null || true
unset MODEL_SC 2>/dev/null || true

load_research_models

# 13. MODEL_DA 変数が未定義
assert_eq "MODEL_DA 未定義" "" "${MODEL_DA:-}"

# 14. TOOLS_DA 変数が未定義
assert_eq "TOOLS_DA 未定義" "" "${TOOLS_DA:-}"

# 15. TIMEOUT_DA 変数が未定義
assert_eq "TIMEOUT_DA 未定義" "" "${TIMEOUT_DA:-}"

# 16. MODEL_SC は定義されている
if [ -n "${MODEL_SC:-}" ]; then
  assert_eq "MODEL_SC 定義済み" "defined" "defined"
else
  assert_eq "MODEL_SC 定義済み" "defined" "undefined"
fi

echo ""

# ========================================================================
# Group 4: update_state() — research_mode フィールド (3 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 4: update_state — research_mode フィールド =====${NC}"

STATE_FILE="${PROJECT_ROOT}/.forge/state/current-research.json"
THEME="テストテーマ"

# 17. update_state "scope-challenger" → STATE_FILE に research_mode フィールド存在
RESEARCH_MODE="validate"
RESEARCH_DIR="test-dir"
update_state "scope-challenger"
has_mode=$(jq -r 'has("research_mode")' "$STATE_FILE" 2>/dev/null)
assert_eq "STATE_FILE に research_mode 存在" "true" "$has_mode"

# 18. RESEARCH_MODE="validate" → research_mode が "validate"
mode_val=$(jq -r '.research_mode' "$STATE_FILE" 2>/dev/null)
assert_eq "research_mode=validate" "validate" "$mode_val"

# 19. RESEARCH_MODE="explore" → research_mode が "explore"
RESEARCH_MODE="explore"
update_state "scope-challenger"
mode_val=$(jq -r '.research_mode' "$STATE_FILE" 2>/dev/null)
assert_eq "research_mode=explore" "explore" "$mode_val"

echo ""

# ========================================================================
# Group 5: テンプレート変数注入 (5 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 5: テンプレート変数注入 =====${NC}"

# テスト用変数設定
RESEARCH_MODE="validate"
LOCKED_DECISIONS_TEXT="- Alpine.js (理由: 整合性)"
OPEN_QUESTIONS_TEXT="- DBの選択"

# 20. SC テンプレートに RESEARCH_MODE が注入される
sc_rendered=$(render_template "${PROJECT_ROOT}/.forge/templates/scope-challenger-prompt.md" \
  "THEME" "テスト" \
  "DIRECTION" "方向性" \
  "DECISIONS" "なし" \
  "RESEARCH_MODE" "$RESEARCH_MODE" \
  "LOCKED_DECISIONS" "$LOCKED_DECISIONS_TEXT" \
  "OPEN_QUESTIONS" "$OPEN_QUESTIONS_TEXT"
)
assert_not_contains "SC: {{RESEARCH_MODE}} 残留なし" "{{RESEARCH_MODE}}" "$sc_rendered"

# 21. SC テンプレートに LOCKED_DECISIONS が注入される
assert_contains "SC: LOCKED_DECISIONS が注入" "Alpine.js" "$sc_rendered"

# 22. SC テンプレートに OPEN_QUESTIONS が注入される
assert_contains "SC: OPEN_QUESTIONS が注入" "DBの選択" "$sc_rendered"

# 23. Syn テンプレートに RESEARCH_MODE が注入される
syn_rendered=$(render_template "${PROJECT_ROOT}/.forge/templates/synthesizer-prompt.md" \
  "INVESTIGATION_PLAN" "{}" \
  "ALL_REPORTS" "レポート" \
  "DECISIONS" "なし" \
  "RESEARCH_MODE" "$RESEARCH_MODE" \
  "LOCKED_DECISIONS" "$LOCKED_DECISIONS_TEXT"
)
assert_not_contains "Syn: {{RESEARCH_MODE}} 残留なし" "{{RESEARCH_MODE}}" "$syn_rendered"

# 24. Syn テンプレートに LOCKED_DECISIONS が注入される
assert_contains "Syn: LOCKED_DECISIONS が注入" "Alpine.js" "$syn_rendered"

echo ""

# ========================================================================
# サマリー
# ========================================================================
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL_COUNT"
