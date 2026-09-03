#!/bin/bash
# test-workflow-profiles.sh — ワークフロー・プロファイル適用（batch#10 Stage5）
# 検証: apply_workflow_profile の (1) FORGE_PROFILE 優先 (2) research-config .workflow
#       フォールバック (3) 未知プロファイルは無適用続行 (4) overrides の変数上書き
#       (5) browser は env 上書き (6) 実プロファイル5種の JSON 妥当性
# 使い方: bash .forge/tests/test-workflow-profiles.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"

TMPDIR="/tmp/test-workflow-profiles-$$"
rm -rf "$TMPDIR"
mkdir -p "${TMPDIR}/.forge/config/profiles" "${TMPDIR}/.forge/state"

log() { echo "[LOG] $1" >&2; }
jq_safe() { jq "$@" 2>/dev/null | tr -d '\r'; }

# ===== 関数抽出 =====
EXTRACT="${TMPDIR}/extract.sh"
sed -n '/^apply_workflow_profile() {/,/^}/p' "$RALPH_SH" > "$EXTRACT"
if ! grep -q '^apply_workflow_profile() {' "$EXTRACT"; then
  echo "FATAL: apply_workflow_profile の抽出失敗"
  exit 1
fi
source "$EXTRACT"

echo -e "${BOLD}===== test-workflow-profiles.sh =====${NC}"

# ===== フィクスチャ =====
PROJECT_ROOT="$TMPDIR"
cat > "${TMPDIR}/.forge/config/profiles/testprof.json" <<'EOF'
{
  "workflow": "testprof",
  "overrides": {
    "qa_evaluator_enabled": false,
    "ux_judgment_enabled": false,
    "best_of_n_enabled": true,
    "browser_testing_enabled": false
  }
}
EOF
cat > "${TMPDIR}/.forge/state/research-config.json" <<'EOF'
{"mode": "validate", "workflow": "testprof", "locked_decisions": [], "open_questions": []}
EOF

reset_vars() {
  QA_EVALUATOR_ENABLED=true
  UX_JUDGMENT_ENABLED=true
  BEST_OF_N_ENABLED=false
  EVIDENCE_DA_ENABLED=true
  MUTATION_AUDIT_ENABLED=true
  CHECKLIST_VERIFIER_ENABLED=""
  unset FORGE_BROWSER_TESTING_OVERRIDE 2>/dev/null || true
  unset FORGE_ACTIVE_PROFILE 2>/dev/null || true
}

# ===== T1: FORGE_PROFILE 明示指定で overrides が適用される =====
echo -e "\n${YELLOW}T1: FORGE_PROFILE 明示指定${NC}"
reset_vars
FORGE_PROFILE="testprof" RESEARCH_CONFIG="" apply_workflow_profile
assert_eq "qa_evaluator_enabled が false に上書き" "false" "$QA_EVALUATOR_ENABLED"
assert_eq "ux_judgment_enabled が false に上書き" "false" "$UX_JUDGMENT_ENABLED"
assert_eq "best_of_n_enabled が true に上書き" "true" "$BEST_OF_N_ENABLED"
assert_eq "overrides に無いキーは不変 (evidence_da)" "true" "$EVIDENCE_DA_ENABLED"
assert_eq "browser は env 上書き" "false" "${FORGE_BROWSER_TESTING_OVERRIDE:-unset}"
assert_eq "FORGE_ACTIVE_PROFILE 記録" "testprof" "${FORGE_ACTIVE_PROFILE:-unset}"

# ===== T2: research-config .workflow フォールバック =====
echo -e "\n${YELLOW}T2: research-config フォールバック${NC}"
reset_vars
FORGE_PROFILE="" RESEARCH_CONFIG="${TMPDIR}/.forge/state/research-config.json" apply_workflow_profile
assert_eq "workflow フィールドからプロファイル解決" "testprof" "${FORGE_ACTIVE_PROFILE:-unset}"
assert_eq "overrides 適用 (qa)" "false" "$QA_EVALUATOR_ENABLED"

# ===== T3: 未知プロファイル → 無適用で続行（rc=0） =====
echo -e "\n${YELLOW}T3: 未知プロファイル${NC}"
reset_vars
rc=0
FORGE_PROFILE="no-such-profile" RESEARCH_CONFIG="" apply_workflow_profile || rc=$?
assert_eq "rc=0（無適用続行）" "0" "$rc"
assert_eq "変数は不変" "true" "$QA_EVALUATOR_ENABLED"

# ===== T4: プロファイル未指定 → no-op =====
echo -e "\n${YELLOW}T4: 未指定 no-op${NC}"
reset_vars
rc=0
FORGE_PROFILE="" RESEARCH_CONFIG="" apply_workflow_profile || rc=$?
assert_eq "rc=0" "0" "$rc"
assert_eq "変数は不変" "true" "$UX_JUDGMENT_ENABLED"

# ===== T5: 実プロファイル5種の JSON 妥当性と必須構造 =====
echo -e "\n${YELLOW}T5: 実プロファイル5種${NC}"
for p in ui-app cli-lib env-blocked content research; do
  f="${REAL_ROOT}/.forge/config/profiles/${p}.json"
  if [ -f "$f" ] && jq -e '.workflow and (.overrides | type == "object")' "$f" >/dev/null 2>&1; then
    assert_eq "profiles/${p}.json 構造妥当" "ok" "ok"
  else
    assert_eq "profiles/${p}.json 構造妥当" "ok" "broken"
  fi
done
# 合意マトリクスの要点: cli-lib は UX off / ui-app は UX on / content は qa off + bon on
assert_eq "cli-lib: ux off" "false" "$(jq -r '.overrides.ux_judgment_enabled' "${REAL_ROOT}/.forge/config/profiles/cli-lib.json")"
assert_eq "ui-app: ux on" "true" "$(jq -r '.overrides.ux_judgment_enabled' "${REAL_ROOT}/.forge/config/profiles/ui-app.json")"
assert_eq "content: qa off" "false" "$(jq -r '.overrides.qa_evaluator_enabled' "${REAL_ROOT}/.forge/config/profiles/content.json")"
assert_eq "content: best_of_n on" "true" "$(jq -r '.overrides.best_of_n_enabled' "${REAL_ROOT}/.forge/config/profiles/content.json")"

# ===== クリーンアップ =====
rm -rf "$TMPDIR"
print_test_summary "workflow-profiles"
