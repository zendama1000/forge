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
# Group 7: ファイル数上限の整合 (implementer.md ⇄ development.json) — config-alignment fix #1
# ========================================================================
echo -e "${BOLD}===== Group 7: ファイル数上限の整合 (implementer.md ⇄ development.json) =====${NC}"

IMPLEMENTER_MD="${SCRIPT_DIR}/.claude/agents/implementer.md"

# implementer.md のファイル数上限記述が development.json の safety リミット値と一致するか検証する関数。
# 一致なら exit 0、不一致（新値欠落 / 旧値残存）なら exit 1。負のテストでも再利用する。
check_file_count_alignment() {
  local md="$1" dev="$2"
  local soft hard
  soft=$(jq -r '.safety.max_files_per_task' "$dev" 2>/dev/null)
  hard=$(jq -r '.safety.max_files_hard_limit' "$dev" 2>/dev/null)
  [ -n "$soft" ] && [ "$soft" != "null" ] || return 1
  [ -n "$hard" ] && [ "$hard" != "null" ] || return 1
  grep -qE "最大${soft}ファイル" "$md" || return 1   # 新ソフト上限(15)の記載必須
  grep -qE "${hard}ファイル" "$md" || return 1        # 新ハードリミット(30)の記載必須
  grep -qE "最大5ファイル" "$md" && return 1          # 旧値(最大5ファイル)残存 → 不一致
  return 0
}

# behavior: implementer.md 内のファイル数上限記述と development.json の validate_task_changes リミット値を grep 比較 → 一致（検出すべきでないパターン: 旧値の残存）
if check_file_count_alignment "$IMPLEMENTER_MD" "$DEVELOPMENT_JSON"; then
  assert_eq "implementer.md のファイル数上限が development.json(15/30)と一致" "aligned" "aligned"
else
  assert_eq "implementer.md のファイル数上限が development.json(15/30)と一致" "aligned" "mismatch"
fi

# 整合の基準値（development.json 実値）が 15/30 であることを明示確認
soft_val=$(jq -r '.safety.max_files_per_task' "$DEVELOPMENT_JSON")
hard_val=$(jq -r '.safety.max_files_hard_limit' "$DEVELOPMENT_JSON")
assert_eq "development.json safety.max_files_per_task == 15" "15" "$soft_val"
assert_eq "development.json safety.max_files_hard_limit == 30" "30" "$hard_val"

# behavior: 意図的に implementer.md に旧値を書き戻した状態で整合チェック実行 → 不一致を検出して FAIL（チェック自体の有効性）
STALE_MD=$(mktemp 2>/dev/null || echo "/tmp/stale-impl-$$.md")
printf '%s\n' '- 1タスクあたりの変更ファイル数は最大5ファイル（超過は自動ロールバック対象）' > "$STALE_MD"
if check_file_count_alignment "$STALE_MD" "$DEVELOPMENT_JSON"; then
  assert_eq "旧値(最大5ファイル)を書き戻した implementer.md を不一致として検出" "detected" "not-detected(false-negative)"
else
  assert_eq "旧値(最大5ファイル)を書き戻した implementer.md を不一致として検出" "detected" "detected"
fi
rm -f "$STALE_MD" 2>/dev/null

echo ""

# ========================================================================
# Group 8: mutation timeout の整合 (mutation-audit.json ⇄ 関連スクリプト) — config-alignment fix #2
# ========================================================================
echo -e "${BOLD}===== Group 8: mutation timeout の整合 =====${NC}"

MUTATION_AUDIT_JSON="${SCRIPT_DIR}/.forge/config/mutation-audit.json"
MUTATION_RUNNER_SH="${SCRIPT_DIR}/.forge/loops/mutation-runner.sh"
RALPH_LOOP_SH="${SCRIPT_DIR}/.forge/loops/ralph-loop.sh"

# behavior: mutation-audit.json / 関連スクリプトの timeout 値が定義され、ハードコード値との乖離がない → grep で整合確認
# (1) config の timeout 値が数値として定義されていること
cfg_runner=$(jq -r '.mutation_audit.runner_timeout_per_mutant_sec' "$MUTATION_AUDIT_JSON" 2>/dev/null)
cfg_auditor=$(jq -r '.mutation_audit.auditor_timeout_sec' "$MUTATION_AUDIT_JSON" 2>/dev/null)
runner_type=$(jq -r '.mutation_audit.runner_timeout_per_mutant_sec | type' "$MUTATION_AUDIT_JSON" 2>/dev/null)
auditor_type=$(jq -r '.mutation_audit.auditor_timeout_sec | type' "$MUTATION_AUDIT_JSON" 2>/dev/null)
assert_eq "mutation-audit.json runner_timeout_per_mutant_sec が数値" "number" "$runner_type"
assert_eq "mutation-audit.json auditor_timeout_sec が数値" "number" "$auditor_type"

# (2) mutation-runner.sh のハードコード default (${4:-N}) が config の runner timeout と一致
mr_default=$(grep 'TIMEOUT_PER_MUTANT=' "$MUTATION_RUNNER_SH" | grep -oE '4:-[0-9]+' | grep -oE '[0-9]+$' | head -1)
assert_eq "mutation-runner.sh の default timeout が config(${cfg_runner})と一致" "$cfg_runner" "$mr_default"

# (3) ralph-loop.sh の jq fallback (// N) が config 値と乖離しない
rl_runner=$(grep -oE 'runner_timeout_per_mutant_sec // [0-9]+' "$RALPH_LOOP_SH" | grep -oE '[0-9]+$' | head -1)
rl_auditor=$(grep -oE 'auditor_timeout_sec // [0-9]+' "$RALPH_LOOP_SH" | grep -oE '[0-9]+$' | head -1)
assert_eq "ralph-loop.sh runner timeout fallback が config と一致" "$cfg_runner" "$rl_runner"
assert_eq "ralph-loop.sh auditor timeout fallback が config と一致" "$cfg_auditor" "$rl_auditor"

echo ""

# ========================================================================
# Group 9: モデルフォールバック opus 統一 — config-alignment fix #3
# ========================================================================
echo -e "${BOLD}===== Group 9: モデルフォールバック opus 統一 =====${NC}"

MUTATION_AUDIT_JSON="${MUTATION_AUDIT_JSON:-${SCRIPT_DIR}/.forge/config/mutation-audit.json}"

# config 内の全モデル指定値を抽出し、非 opus (fable/sonnet/haiku) が残存していれば
# 違反値を stdout に出力(exit 0)、クリーンなら無出力(exit 1)。負/正テストで再利用する。
scan_nonopus_models() {
  local cfg="$1"
  jq -r '[.. | strings] | .[]' "$cfg" 2>/dev/null | grep -iwE 'fable|sonnet|haiku'
}

# behavior: 全 config / スクリプト内のモデルフォールバック指定を grep → opus 系のみ（検出すべきパターン: 非 opus = fable/sonnet/haiku フォールバック残存 → FAIL）
CFG_MODEL_VIOLATIONS=""
for cfg in "$DEVELOPMENT_JSON" "$RESEARCH_JSON" "$MUTATION_AUDIT_JSON" "$CIRCUIT_BREAKER_JSON"; do
  hit=$(scan_nonopus_models "$cfg")
  if [ -n "$hit" ]; then
    CFG_MODEL_VIOLATIONS="${CFG_MODEL_VIOLATIONS}$(basename "$cfg"):[$(echo "$hit" | tr '\n' ',')] "
  fi
done
assert_eq "全 config のモデル指定が opus 系のみ（非 opus フォールバック残存なし）" "" "$CFG_MODEL_VIOLATIONS"

# behavior: [追加] 本番スクリプト(loops/lib)に fable フォールバック残存なし（直近 fable→opus 移行の取りこぼし検出）
# 注: sonnet/haiku の防御的フォールバック(// "sonnet" 等)は config 欠損時のみ発火し、
#     専用ユニットテスト(test-l3-agent-flow.sh Section 9 / test-l3-acceptance.sh)が値を固定しているため
#     意図的に保持する。ここでは移行対象であった fable の本番スクリプト残存のみを検出する。
SCRIPT_FABLE_HITS=$(grep -rIlwiE 'fable' \
  "${SCRIPT_DIR}/.forge/loops" "${SCRIPT_DIR}/.forge/lib" 2>/dev/null || true)
assert_eq "本番スクリプト(loops/lib)に fable フォールバック残存なし" "" "$SCRIPT_FABLE_HITS"

# behavior: 意図的に sonnet/haiku モデルを含む config に対しスキャン → 非 opus を検出する（チェック自体の有効性）
NONOPUS_CFG=$(mktemp 2>/dev/null || echo "/tmp/nonopus-cfg-$$.json")
printf '%s' '{"implementer":{"model":"sonnet"},"models":{"researcher":"haiku"}}' > "$NONOPUS_CFG"
neg_hit=$(scan_nonopus_models "$NONOPUS_CFG")
assert_contains "sonnet を含む config を非 opus として検出 (sonnet)" "sonnet" "$neg_hit"
assert_contains "haiku を含む config を非 opus として検出 (haiku)" "haiku" "$neg_hit"
rm -f "$NONOPUS_CFG" 2>/dev/null

# behavior: opus のみの config に対しスキャン → 違反検出ゼロ（誤検出なし）
OPUS_CFG=$(mktemp 2>/dev/null || echo "/tmp/opus-cfg-$$.json")
printf '%s' '{"implementer":{"model":"opus"},"models":{"researcher":"opus"}}' > "$OPUS_CFG"
opus_hit=$(scan_nonopus_models "$OPUS_CFG")
assert_eq "opus のみ config は違反検出ゼロ（誤検出なし）" "" "$opus_hit"
rm -f "$OPUS_CFG" 2>/dev/null

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
