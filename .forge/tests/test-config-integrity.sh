#!/bin/bash
# test-config-integrity.sh — v3.3 Config ファイル整合性テスト
# DA 除去 + evidence_da 追加の正当性を静的に検証する。
# 使い方: bash .forge/tests/test-config-integrity.sh

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

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RESEARCH_JSON="${SCRIPT_DIR}/.forge/config/research.json"
CIRCUIT_BREAKER_JSON="${SCRIPT_DIR}/.forge/config/circuit-breaker.json"
DEVELOPMENT_JSON="${SCRIPT_DIR}/.forge/config/development.json"
SC_TEMPLATE="${SCRIPT_DIR}/.forge/templates/scope-challenger-prompt.md"
SYN_TEMPLATE="${SCRIPT_DIR}/.forge/templates/synthesizer-prompt.md"

# common.sh の resolve_agent_effort をロード（agent_effort 解決テスト用）
# set -u 対策で前提変数を最小定義
PROJECT_ROOT="$SCRIPT_DIR"
DEVELOPMENT_JSON="$DEVELOPMENT_JSON"
ERRORS_FILE="${SCRIPT_DIR}/.forge/state/errors.jsonl"
RESEARCH_DIR="test-config-integrity"
json_fail_count=0
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/.forge/lib/common.sh"

echo -e "${BOLD}===== test-config-integrity.sh — v3.3 Config 整合性テスト =====${NC}"
echo ""

# ========================================================================
# Group 1: research.json — DA 除去確認 (4 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 1: research.json — DA 除去確認 =====${NC}"

# 1. .models.devils_advocate が存在しない
val=$(jq -r '.models.devils_advocate // "ABSENT"' "$RESEARCH_JSON")
assert_eq "models.devils_advocate が存在しない" "ABSENT" "$val"

# 2. .disallowed_tools.devils_advocate が存在しない
val=$(jq -r '.disallowed_tools.devils_advocate // "ABSENT"' "$RESEARCH_JSON")
assert_eq "disallowed_tools.devils_advocate が存在しない" "ABSENT" "$val"

# 3. .timeouts.devils_advocate_sec が存在しない
val=$(jq -r '.timeouts.devils_advocate_sec // "ABSENT"' "$RESEARCH_JSON")
assert_eq "timeouts.devils_advocate_sec が存在しない" "ABSENT" "$val"

# 4. .feedback_injection が存在しない
val=$(jq -r '.feedback_injection // "ABSENT"' "$RESEARCH_JSON")
assert_eq "feedback_injection が存在しない" "ABSENT" "$val"

echo ""

# ========================================================================
# Group 2: circuit-breaker.json — DA ループ変数除去 (4 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 2: circuit-breaker.json — DA ループ変数除去 =====${NC}"

# 5. .research_limits.max_conditional_loops が存在しない
val=$(jq -r '.research_limits.max_conditional_loops // "ABSENT"' "$CIRCUIT_BREAKER_JSON")
assert_eq "max_conditional_loops が存在しない" "ABSENT" "$val"

# 6. .research_limits.max_nogo_loops が存在しない
val=$(jq -r '.research_limits.max_nogo_loops // "ABSENT"' "$CIRCUIT_BREAKER_JSON")
assert_eq "max_nogo_loops が存在しない" "ABSENT" "$val"

# 7. .research_limits.max_da_retries が存在しない
val=$(jq -r '.research_limits.max_da_retries // "ABSENT"' "$CIRCUIT_BREAKER_JSON")
assert_eq "max_da_retries が存在しない" "ABSENT" "$val"

# 8. .research_limits.max_json_fails_per_loop が存在する（残存確認）
val=$(jq -r '.research_limits.max_json_fails_per_loop // "ABSENT"' "$CIRCUIT_BREAKER_JSON")
if [ "$val" != "ABSENT" ] && [ "$val" -gt 0 ] 2>/dev/null; then
  assert_eq "max_json_fails_per_loop が存在する" "exists" "exists"
else
  assert_eq "max_json_fails_per_loop が存在する" "exists" "ABSENT"
fi

echo ""

# ========================================================================
# Group 3: development.json — evidence_da セクション (4 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 3: development.json — evidence_da セクション =====${NC}"

# 9. .evidence_da.enabled が boolean
val=$(jq -r '.evidence_da.enabled | type' "$DEVELOPMENT_JSON")
assert_eq "evidence_da.enabled が boolean" "boolean" "$val"

# 10. .evidence_da.model が文字列
val=$(jq -r '.evidence_da.model | type' "$DEVELOPMENT_JSON")
assert_eq "evidence_da.model が文字列" "string" "$val"

# 11. .evidence_da.timeout_sec が数値
val=$(jq -r '.evidence_da.timeout_sec | type' "$DEVELOPMENT_JSON")
assert_eq "evidence_da.timeout_sec が数値" "number" "$val"

# 12. .evidence_da.fail_threshold が数値 >= 1
val=$(jq -r '.evidence_da.fail_threshold' "$DEVELOPMENT_JSON")
if [ "$val" -ge 1 ] 2>/dev/null; then
  assert_eq "evidence_da.fail_threshold >= 1" "valid" "valid"
else
  assert_eq "evidence_da.fail_threshold >= 1" "valid" "invalid(${val})"
fi

echo ""

# ========================================================================
# Group 4: テンプレート整合性 (2 assertions)
# ========================================================================
echo -e "${BOLD}===== Group 4: テンプレート整合性 =====${NC}"

# 13. scope-challenger-prompt.md に {{RESEARCH_MODE}} プレースホルダが存在
sc_content=$(cat "$SC_TEMPLATE")
assert_contains "SC テンプレートに {{RESEARCH_MODE}}" "{{RESEARCH_MODE}}" "$sc_content"

# 14. synthesizer-prompt.md に {{LOCKED_DECISIONS}} プレースホルダが存在
syn_content=$(cat "$SYN_TEMPLATE")
assert_contains "Syn テンプレートに {{LOCKED_DECISIONS}}" "{{LOCKED_DECISIONS}}" "$syn_content"

echo ""

# ========================================================================
# Group 5: agent_effort — 設定ロード/解決 (resolve_agent_effort)
# ========================================================================
echo -e "${BOLD}===== Group 5: agent_effort 設定ロード/解決 =====${NC}"

# 一時 config ファイル（正常系/異常系/エッジケースを隔離検証）
EFFORT_TMP_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/effort-cfg-$$")
mkdir -p "$EFFORT_TMP_DIR"
NORMAL_CFG="${EFFORT_TMP_DIR}/normal.json"
UNDEF_CFG="${EFFORT_TMP_DIR}/undef.json"
INVALID_CFG="${EFFORT_TMP_DIR}/invalid.json"
printf '%s' '{"agent_effort":{"implementer":"low"}}' > "$NORMAL_CFG"
printf '%s' '{"agent_effort":{"other_agent":"low"}}' > "$UNDEF_CFG"
printf '%s' '{"agent_effort":{"implementer":"ultra-mega-max"}}' > "$INVALID_CFG"

# behavior: config に agent_effort.implementer=low を定義しロード → implementer の effort 値として low が返る（正常系）
val=$(resolve_agent_effort "implementer" "$NORMAL_CFG")
assert_eq "正常系: implementer=low が解決される" "low" "$val"

# behavior: config に effort 未定義のエージェントを問合せ → デフォルト値（無指定/medium）にフォールバックする（異常系）
val=$(resolve_agent_effort "implementer" "$UNDEF_CFG")
assert_eq "異常系: 未定義エージェントは空(デフォルトフォールバック)" "" "$val"

# behavior: config の effort に不正値（max を超える文字列）を設定 → ロード時にバリデーション警告またはデフォルトフォールバック（エッジケース）
val=$(resolve_agent_effort "implementer" "$INVALID_CFG" 2>/dev/null)
assert_eq "エッジケース: 不正値は空(フォールバック)" "" "$val"
# 警告が stderr に出ることを確認
warn=$(resolve_agent_effort "implementer" "$INVALID_CFG" 2>&1 >/dev/null)
assert_contains "エッジケース: 不正値で警告を出力" "不正な agent_effort 値" "$warn"

# behavior: SC/Syn/DA/Investigator の effort=high/xhigh が config から解決される
sc_eff=$(resolve_agent_effort "scope_challenger" "$RESEARCH_JSON")
assert_eq "SC effort=high が research.json から解決" "high" "$sc_eff"
syn_eff=$(resolve_agent_effort "synthesizer" "$RESEARCH_JSON")
assert_eq "Syn effort=high が research.json から解決" "high" "$syn_eff"
da_eff=$(resolve_agent_effort "evidence_da" "$DEVELOPMENT_JSON")
assert_eq "DA(evidence_da) effort=high が development.json から解決" "high" "$da_eff"
inv_eff=$(resolve_agent_effort "investigator" "$DEVELOPMENT_JSON")
assert_eq "Investigator effort=xhigh が development.json から解決" "xhigh" "$inv_eff"
# 解決された値が validate_effort の許可集合に含まれること（high/xhigh）
for e in "$sc_eff" "$syn_eff" "$da_eff" "$inv_eff"; do
  case "$e" in
    high|xhigh) ;;
    *) FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}✗${NC} 解決値 '${e}' が high/xhigh 以外"; continue ;;
  esac
done
assert_eq "SC/Syn/DA/Investigator は全て high/xhigh" "ok" "ok"

# behavior: config ファイル自体が JSON として妥当である（jq でパース可能）
if jq -e . "$DEVELOPMENT_JSON" >/dev/null 2>&1; then
  assert_eq "development.json は妥当な JSON" "valid" "valid"
else
  assert_eq "development.json は妥当な JSON" "valid" "invalid"
fi
if jq -e . "$RESEARCH_JSON" >/dev/null 2>&1; then
  assert_eq "research.json は妥当な JSON" "valid" "valid"
else
  assert_eq "research.json は妥当な JSON" "valid" "invalid"
fi

rm -rf "$EFFORT_TMP_DIR" 2>/dev/null

echo ""

# ========================================================================
# Group 6: NULL バイト検出ゲート（常設）
# ========================================================================
echo -e "${BOLD}===== Group 6: NULL バイト検出ゲート =====${NC}"

FIXTURES_DIR="${SCRIPT_DIR}/.forge/tests/fixtures"
NUL_FIXTURE="${FIXTURES_DIR}/nul-sample.sh.bin"

# has_nul <file> — ファイルに NUL バイト (0x00) が含まれていれば exit 0
# od でバイト列を hex 化し "00" バイトを厳密一致で検出する（grep -P 非依存・Git Bash 互換）
has_nul() {
  od -An -tx1 -- "$1" | tr ' ' '\n' | grep -qx '00'
}

# behavior: common.sh をバイナリスキャン（grep -P '\x00' / od）→ NUL バイト 0 件
if has_nul "${SCRIPT_DIR}/.forge/lib/common.sh"; then
  assert_eq "common.sh に NUL バイトが 0 件" "0" "1+"
else
  assert_eq "common.sh に NUL バイトが 0 件" "0" "0"
fi

# behavior: grep が common.sh を binary file と判定しない → grep -c 'jq_lines' .forge/lib/common.sh が数値を返す（'Binary file matches' でない）
grep_out=$(grep -c 'jq_lines' "${SCRIPT_DIR}/.forge/lib/common.sh" 2>&1)
if echo "$grep_out" | grep -qE '^[0-9]+$' && [ "$grep_out" -gt 0 ]; then
  assert_eq "grep -c jq_lines が数値を返す（binary 判定でない）" "numeric" "numeric"
else
  assert_eq "grep -c jq_lines が数値を返す（binary 判定でない）" "numeric" "non-numeric(${grep_out})"
fi

# behavior: common.sh L114 付近のコメントが '\0' 表記に書換済みで jq_lines 関数が source 後も正常動作 → bash -c 'source .forge/lib/common.sh && type jq_lines' が exit 0
if (cd "$SCRIPT_DIR" && bash -c "source .forge/lib/common.sh && type jq_lines" >/dev/null 2>&1); then
  assert_eq "source common.sh 後に jq_lines が定義済み" "defined" "defined"
else
  assert_eq "source common.sh 後に jq_lines が定義済み" "defined" "undefined"
fi

# behavior: テスト用に NUL を含む一時 .sh ファイルを fixtures に置いて NULL 検出ゲートを実行 → ゲートが FAIL を報告（検出すべきパターン）
if [ -f "$NUL_FIXTURE" ] && has_nul "$NUL_FIXTURE"; then
  assert_eq "NUL 含有 fixture をゲートが検出（FAIL 報告）" "detected" "detected"
else
  assert_eq "NUL 含有 fixture をゲートが検出（FAIL 報告）" "detected" "not-detected"
fi

# behavior: NUL を含まないクリーンな .sh ファイルに対してゲート実行 → PASS（検出すべきでないパターン）
CLEAN_TMP=$(mktemp 2>/dev/null || echo "/tmp/clean-sample-$$.sh")
printf '#!/bin/bash\necho "clean sample"\n' > "$CLEAN_TMP"
if has_nul "$CLEAN_TMP"; then
  assert_eq "クリーン .sh はゲート PASS（誤検出なし）" "clean" "false-positive"
else
  assert_eq "クリーン .sh はゲート PASS（誤検出なし）" "clean" "clean"
fi
rm -f "$CLEAN_TMP" 2>/dev/null

# behavior: [追加] 全 .sh/.json への NULL バイト検出ゲート（fixtures/state 除外）→ 違反ファイル 0 件
NUL_VIOLATIONS=""
while IFS= read -r f; do
  if has_nul "$f"; then
    NUL_VIOLATIONS="${NUL_VIOLATIONS}${f} "
  fi
done < <(find "${SCRIPT_DIR}/.forge" -type f \( -name '*.sh' -o -name '*.json' \) \
           ! -path '*/fixtures/*' ! -path '*/state/*' ! -path '*/node_modules/*' 2>/dev/null)
assert_eq "全 .sh/.json に NUL バイト混入なし" "" "$NUL_VIOLATIONS"

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
