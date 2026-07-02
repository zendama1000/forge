#!/bin/bash
# test-devils-advocate.sh — advisory DA 純関数の単体テスト
# research-loop.sh から DA 関連関数を抽出し、LLM 呼出なしで検証する。
# 対象: run_devils_advocate_advisory のガード分岐 / _demote_unevidenced_criticals /
#       _da_critical_count / inject_da_findings_into_criteria / DA_REFOCUS_TEXT 構築 jq
# 使い方: bash .forge/tests/test-devils-advocate.sh

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
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/.forge/tests/fixtures"
RESEARCH_LOOP_SH="${SCRIPT_DIR}/.forge/loops/research-loop.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# ===== 関数抽出（awk、e2e と同方式） =====
extract_functions() {
  local src="$1"
  shift
  local funcs="$*"
  awk -v "names=$funcs" '
    BEGIN {
      split(names, arr, " ")
      for (i in arr) targets[arr[i] "()"] = 1
    }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ {
      fname = $1
      if (fname in targets) { found = 1; depth = 0 }
    }
    found {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      print
      if (depth <= 0 && NR > start_line) { found = 0; print "" }
      if (found && depth > 0) start_line = NR
    }
  ' "$src"
}

EXTRACT_FILE="${TMP_ROOT}/da-funcs.sh"
extract_functions "$RESEARCH_LOOP_SH" \
  run_devils_advocate_advisory _demote_unevidenced_criticals \
  _da_critical_count inject_da_findings_into_criteria \
  > "$EXTRACT_FILE"

if ! source "$EXTRACT_FILE"; then
  echo "FATAL: DA 関数の抽出 source に失敗" >&2
  exit 1
fi

# 抽出漏れ検出（関数が空だと以降が全て偽装 PASS になるため即死）
for fn in run_devils_advocate_advisory _demote_unevidenced_criticals _da_critical_count inject_da_findings_into_criteria; do
  if ! declare -f "$fn" > /dev/null; then
    echo "FATAL: 関数 ${fn} が research-loop.sh から抽出できなかった" >&2
    exit 1
  fi
done

# ===== 最小スタブ =====
log() { :; }
update_state() { :; }
update_progress() { :; }
record_error() { :; }
metrics_start() { :; }
metrics_record() { :; }

CLAUDE_CALL_COUNT=0
run_claude() { CLAUDE_CALL_COUNT=$((CLAUDE_CALL_COUNT + 1)); return 0; }
retry_with_backoff() { shift 2; "$@"; }

echo -e "${BOLD}===== test-devils-advocate.sh — advisory DA 純関数テスト =====${NC}"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 1: run_devils_advocate_advisory ガード分岐 ---${NC}"
# ========================================================================

# behavior: enabled=false → LLM 未呼出で即 return 0（advisory スキップ）
DA_ENABLED=false
CLAUDE_CALL_COUNT=0
rc=0
run_devils_advocate_advisory 1 > /dev/null 2>&1 || rc=$?
assert_eq "enabled=false → return 0" "0" "$rc"
assert_eq "enabled=false → claude 未呼出" "0" "$CLAUDE_CALL_COUNT"

# behavior: エージェント/テンプレート不在 → graceful skip（return 0、claude 未呼出）
DA_ENABLED=true
AGENTS_DIR="${TMP_ROOT}/no-agents"
TEMPLATES_DIR="${TMP_ROOT}/no-templates"
RESEARCH_DIR="${TMP_ROOT}/research"
mkdir -p "$RESEARCH_DIR"
CLAUDE_CALL_COUNT=0
rc=0
run_devils_advocate_advisory 1 > /dev/null 2>&1 || rc=$?
assert_eq "agent/template 不在 → return 0" "0" "$rc"
assert_eq "agent/template 不在 → claude 未呼出" "0" "$CLAUDE_CALL_COUNT"

# behavior: synthesis.json 不在 → graceful skip
mkdir -p "$AGENTS_DIR" "$TEMPLATES_DIR"
echo "agent" > "${AGENTS_DIR}/devils-advocate.md"
echo "template" > "${TEMPLATES_DIR}/devils-advocate-prompt.md"
rm -f "${RESEARCH_DIR}/synthesis.json"
CLAUDE_CALL_COUNT=0
rc=0
run_devils_advocate_advisory 1 > /dev/null 2>&1 || rc=$?
assert_eq "synthesis 不在 → return 0" "0" "$rc"
assert_eq "synthesis 不在 → claude 未呼出" "0" "$CLAUDE_CALL_COUNT"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: _da_critical_count ---${NC}"
# ========================================================================

# behavior: ファイル不在 → 0（advisory スキップ扱い）
assert_eq "ファイル不在 → 0" "0" "$(_da_critical_count "${TMP_ROOT}/nonexistent.json")"

# behavior: CRITICAL 1 + HIGH 1 の fixture → 1
cp "${FIXTURES_DIR}/da-output-critical.json" "${TMP_ROOT}/c.json"
assert_eq "critical fixture → 1" "1" "$(_da_critical_count "${TMP_ROOT}/c.json")"

# behavior: HIGH/MEDIUM のみの fixture → 0
cp "${FIXTURES_DIR}/da-output-clean.json" "${TMP_ROOT}/clean.json"
assert_eq "clean fixture → 0" "0" "$(_da_critical_count "${TMP_ROOT}/clean.json")"

# behavior: 壊れた JSON → 0（クラッシュしない）
echo "not json" > "${TMP_ROOT}/broken.json"
assert_eq "壊れた JSON → 0" "0" "$(_da_critical_count "${TMP_ROOT}/broken.json")"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: _demote_unevidenced_criticals ---${NC}"
# ========================================================================

# behavior: evidence 空配列の CRITICAL → HIGH へ降格 + demoted_from 記録
cp "${FIXTURES_DIR}/da-output-critical-no-evidence.json" "${TMP_ROOT}/ne.json"
_demote_unevidenced_criticals "${TMP_ROOT}/ne.json"
assert_eq "空 evidence → HIGH 降格" "HIGH" "$(jq -r '.devils_advocate.findings[0].severity' "${TMP_ROOT}/ne.json")"
assert_eq "demoted_from=CRITICAL 記録" "CRITICAL" "$(jq -r '.devils_advocate.findings[0].demoted_from' "${TMP_ROOT}/ne.json")"
assert_eq "降格後 critical count=0" "0" "$(_da_critical_count "${TMP_ROOT}/ne.json")"

# behavior: evidence が空文字列のみ → 降格（実質証拠なし）
jq '.devils_advocate.findings[0].severity = "CRITICAL" | del(.devils_advocate.findings[0].demoted_from) | .devils_advocate.findings[0].evidence = ["", ""]' \
  "${TMP_ROOT}/ne.json" > "${TMP_ROOT}/ne2.json"
_demote_unevidenced_criticals "${TMP_ROOT}/ne2.json"
assert_eq "空文字列のみ evidence → 降格" "HIGH" "$(jq -r '.devils_advocate.findings[0].severity' "${TMP_ROOT}/ne2.json")"

# behavior: 証拠つき CRITICAL は保持される
cp "${FIXTURES_DIR}/da-output-critical.json" "${TMP_ROOT}/c2.json"
_demote_unevidenced_criticals "${TMP_ROOT}/c2.json"
assert_eq "証拠つき CRITICAL は保持" "1" "$(_da_critical_count "${TMP_ROOT}/c2.json")"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 4: inject_da_findings_into_criteria ---${NC}"
# ========================================================================

# behavior: DA ファイル不在 → criteria 無変更（no-op）
RESEARCH_DIR="${TMP_ROOT}/inj1"
mkdir -p "$RESEARCH_DIR"
echo '{"layer_1_criteria": []}' > "${RESEARCH_DIR}/implementation-criteria.json"
inject_da_findings_into_criteria
assert_eq "DA 不在 → criteria 無変更" "false" "$(jq 'has("da_risk_notes")' "${RESEARCH_DIR}/implementation-criteria.json")"

# behavior: critical fixture (CRITICAL+HIGH) → da_risk_notes 2件 + da_open_questions 2件
RESEARCH_DIR="${TMP_ROOT}/inj2"
mkdir -p "$RESEARCH_DIR"
echo '{"layer_1_criteria": []}' > "${RESEARCH_DIR}/implementation-criteria.json"
cp "${FIXTURES_DIR}/da-output-critical.json" "${RESEARCH_DIR}/devils-advocate.json"
inject_da_findings_into_criteria > /dev/null 2>&1
assert_eq "da_risk_notes 2件" "2" "$(jq '.da_risk_notes | length' "${RESEARCH_DIR}/implementation-criteria.json")"
assert_eq "da_open_questions 2件（非 MEDIUM）" "2" "$(jq '.da_open_questions | length' "${RESEARCH_DIR}/implementation-criteria.json")"

# behavior: clean fixture (HIGH+MEDIUM) → da_open_questions は HIGH の1件のみ
RESEARCH_DIR="${TMP_ROOT}/inj3"
mkdir -p "$RESEARCH_DIR"
echo '{"layer_1_criteria": []}' > "${RESEARCH_DIR}/implementation-criteria.json"
cp "${FIXTURES_DIR}/da-output-clean.json" "${RESEARCH_DIR}/devils-advocate.json"
inject_da_findings_into_criteria > /dev/null 2>&1
assert_eq "MEDIUM は open_questions から除外" "1" "$(jq '.da_open_questions | length' "${RESEARCH_DIR}/implementation-criteria.json")"

# behavior: r2 ファイルが存在する場合はそちらを優先
RESEARCH_DIR="${TMP_ROOT}/inj4"
mkdir -p "$RESEARCH_DIR"
echo '{"layer_1_criteria": []}' > "${RESEARCH_DIR}/implementation-criteria.json"
cp "${FIXTURES_DIR}/da-output-critical.json" "${RESEARCH_DIR}/devils-advocate.json"
cp "${FIXTURES_DIR}/da-output-clean.json" "${RESEARCH_DIR}/devils-advocate-r2.json"
inject_da_findings_into_criteria > /dev/null 2>&1
first_id=$(jq -r '.da_risk_notes[0].id' "${RESEARCH_DIR}/implementation-criteria.json")
assert_eq "r2 優先（clean の DA-001 が先頭）" "DA-001" "$first_id"
assert_eq "r2 優先（severity=HIGH = clean 由来）" "HIGH" "$(jq -r '.da_risk_notes[0].severity' "${RESEARCH_DIR}/implementation-criteria.json")"

echo ""

# ========================================================================
echo -e "${BOLD}--- Group 5: DA_REFOCUS_TEXT 構築 jq ---${NC}"
# ========================================================================

# behavior: CRITICAL findings から id + 解消条件つきの再調査指示テキストが構築される
refocus=$(jq -r '[.devils_advocate.findings[]?
  | select(.severity == "CRITICAL")
  | "- [\(.id)] \(.description)\n  解消条件: \(.resolution_criteria)"] | join("\n")' \
  "${FIXTURES_DIR}/da-output-critical.json")
assert_contains "REFOCUS に finding id" "[DA-001]" "$refocus"
assert_contains "REFOCUS に解消条件" "解消条件:" "$refocus"

# behavior: CRITICAL なし → 空文字列（再調査指示なし）
refocus_clean=$(jq -r '[.devils_advocate.findings[]?
  | select(.severity == "CRITICAL")
  | "- [\(.id)] \(.description)\n  解消条件: \(.resolution_criteria)"] | join("\n")' \
  "${FIXTURES_DIR}/da-output-clean.json")
assert_eq "CRITICAL なし → REFOCUS 空" "" "$refocus_clean"

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
