#!/bin/bash
# test-simulator-faults.sh — フライトシミュレータ FAULT 注入のテスト
# 全7故障が「実分類経路」を通ること、nth_call/once、fault>replay 合成、不正プランを検証。
# 使い方: bash .forge/tests/test-simulator-faults.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export NOTIFY_DIR="${TMPDIR}/notifications"
export CLAUDE_TIMEOUT=30
export _RC_CLI_HELP_CACHE="  --max-budget-usd <amount>  --max-turns <n>"
json_fail_count=0
touch "$ERRORS_FILE"

FAKE_BIN="${TMPDIR}/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/bin/bash
debug=""
prev=""
for a in "$@"; do
  [ "$prev" = "--debug-file" ] && debug="$a"
  prev="$a"
done
cat > /dev/null
[ -n "$debug" ] && printf '{"usage": {"input_tokens": 10, "output_tokens": 5}}\n' > "$debug"
printf '%s\n' "${FAKE_CLAUDE_OUTPUT:-{\"clean\":true}}"
EOF
chmod +x "${FAKE_BIN}/claude"
export PATH="${FAKE_BIN}:$PATH"

source "${PROJECT_ROOT}/.forge/lib/common.sh"
COSTS_FILE="${TMPDIR}/costs.jsonl"

echo -e "${BOLD}===== test-simulator-faults.sh — FAULT 注入 =====${NC}"
echo ""

echo "implementer agent" > "${TMPDIR}/implementer.md"

# run_one <fault_type> <out_prefix> [extra_rule_json] → rc を echo。dest/log は ${out_prefix}.json/.log
run_one() {
  local fault="$1" prefix="$2"
  local plan="${TMPDIR}/plan-${fault}.json"
  jq -n --arg f "$fault" '{rules:[{match:{agent_pattern:"implementer"}, fault:$f}]}' > "$plan"
  local rc=0
  ( export RC_FAULT_PLAN="$plan" RC_SIM_STATE_DIR="${TMPDIR}/state-${fault}" FORGE_CALL_ID=0
    run_claude haiku "${TMPDIR}/implementer.md" "p" "${prefix}.json" "${prefix}.log" "" 30 "" "" "" ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# ===== T1: 各故障タイプの exit / 実分類 =====
echo -e "${BOLD}--- T1: 故障7種の実分類 ---${NC}"

rc=$(run_one timeout "${TMPDIR}/t-timeout")
assert_eq "timeout → run_claude rc=124" "124" "$rc"

rc=$(run_one budget_exceeded "${TMPDIR}/t-budget")
assert_eq "budget_exceeded → classify_run_claude_exit が rc=21 を導出" "21" "$rc"

rc=$(run_one rate_limit "${TMPDIR}/t-rl")
assert_eq "rate_limit → rc=1" "1" "$rc"
if grep -qE '429|too many requests|rate.limit|rate_limit|overloaded' "${TMPDIR}/t-rl.log" 2>/dev/null; then
  assert_eq "rate_limit → debug log が実検出 grep にヒット" "hit" "hit"
else
  assert_eq "rate_limit → debug log が実検出 grep にヒット" "hit" "miss"
fi

rc=$(run_one malformed_json "${TMPDIR}/t-mj")
assert_eq "malformed_json → rc=0（呼出自体は成功）" "0" "$rc"
if jq empty "${TMPDIR}/t-mj.json.pending" 2>/dev/null; then
  assert_eq "malformed_json → .pending は不正 JSON" "invalid" "valid"
else
  assert_eq "malformed_json → .pending は不正 JSON" "invalid" "invalid"
fi

rc=$(run_one empty_output "${TMPDIR}/t-empty")
assert_eq "empty_output → rc=0" "0" "$rc"
if [ -f "${TMPDIR}/t-empty.json.pending" ] && [ ! -s "${TMPDIR}/t-empty.json.pending" ]; then
  assert_eq "empty_output → .pending は空ファイル" "empty" "empty"
else
  assert_eq "empty_output → .pending は空ファイル" "empty" "not-empty-or-missing"
fi

rc=$(run_one exit_1 "${TMPDIR}/t-e1")
assert_eq "exit_1 → rc=1" "1" "$rc"

rc=$(run_one quota_exhausted "${TMPDIR}/t-quota")
assert_eq "quota_exhausted → classify_run_claude_exit が rc=22 を導出（検出器 2026-07-22 追加）" "22" "$rc"
assert_contains "quota_exhausted → debug log に quota 文言" \
  "reached your usage limit" "$(cat "${TMPDIR}/t-quota.log" 2>/dev/null)"

# ===== T2: nth_call ターゲティング + once =====
echo -e "${BOLD}--- T2: nth_call + once ---${NC}"
PLAN_NTH="${TMPDIR}/plan-nth.json"
jq -n '{rules:[{match:{agent_pattern:"implementer", nth_call:2}, fault:"exit_1", once:true}]}' > "$PLAN_NTH"
read -r rc1 rc2 rc3 <<< "$(
  export RC_FAULT_PLAN="$PLAN_NTH" RC_SIM_STATE_DIR="${TMPDIR}/state-nth" FORGE_CALL_ID=0
  a=0; run_claude haiku "${TMPDIR}/implementer.md" "p1" "${TMPDIR}/n1.json" "${TMPDIR}/n1.log" "" 30 "" "" "" >/dev/null 2>&1 || a=$?
  b=0; run_claude haiku "${TMPDIR}/implementer.md" "p2" "${TMPDIR}/n2.json" "${TMPDIR}/n2.log" "" 30 "" "" "" >/dev/null 2>&1 || b=$?
  c=0; run_claude haiku "${TMPDIR}/implementer.md" "p3" "${TMPDIR}/n3.json" "${TMPDIR}/n3.log" "" 30 "" "" "" >/dev/null 2>&1 || c=$?
  echo "$a $b $c"
)"
assert_eq "1回目: 素通し（rc=0）" "0" "$rc1"
assert_eq "2回目: fault 発火（rc=1）" "1" "$rc2"
assert_eq "3回目: once 消費済みで素通し（rc=0）" "0" "$rc3"

# ===== T3: 永続 fault（once なし・nth なし = 毎回発火） =====
echo -e "${BOLD}--- T3: 永続 fault ---${NC}"
PLAN_ALL="${TMPDIR}/plan-all.json"
jq -n '{rules:[{match:{agent_pattern:"implementer"}, fault:"exit_1"}]}' > "$PLAN_ALL"
read -r pa pb <<< "$(
  export RC_FAULT_PLAN="$PLAN_ALL" RC_SIM_STATE_DIR="${TMPDIR}/state-all" FORGE_CALL_ID=0
  a=0; run_claude haiku "${TMPDIR}/implementer.md" "p1" "${TMPDIR}/a1.json" "${TMPDIR}/a1.log" "" 30 "" "" "" >/dev/null 2>&1 || a=$?
  b=0; run_claude haiku "${TMPDIR}/implementer.md" "p2" "${TMPDIR}/a2.json" "${TMPDIR}/a2.log" "" 30 "" "" "" >/dev/null 2>&1 || b=$?
  echo "$a $b"
)"
assert_eq "永続 fault: 1回目も発火" "1" "$pa"
assert_eq "永続 fault: 2回目も発火" "1" "$pb"

# ===== T4: agent_pattern 非対象は素通し =====
echo -e "${BOLD}--- T4: pattern 非対象 ---${NC}"
echo "other agent" > "${TMPDIR}/other.md"
rc4=0
( export RC_FAULT_PLAN="$PLAN_ALL" RC_SIM_STATE_DIR="${TMPDIR}/state-other" FORGE_CALL_ID=0
  run_claude haiku "${TMPDIR}/other.md" "p" "${TMPDIR}/ot.json" "${TMPDIR}/ot.log" "" 30 "" "" "" ) >/dev/null 2>&1 || rc4=$?
assert_eq "パターン非対象エージェントは素通し" "0" "$rc4"

# ===== T5: fault > replay 合成 =====
echo -e "${BOLD}--- T5: fault > replay 合成 ---${NC}"
REC="${TMPDIR}/rec"
( export RC_RECORD_DIR="$REC" RC_SIM_STATE_DIR="${TMPDIR}/state-rec" FORGE_CALL_ID=0
  FAKE_CLAUDE_OUTPUT='{"n":1}' run_claude haiku "${TMPDIR}/implementer.md" "p1" "${TMPDIR}/c1.json" "${TMPDIR}/c1.log" "" 30 "" "" ""
  FAKE_CLAUDE_OUTPUT='{"n":2}' run_claude haiku "${TMPDIR}/implementer.md" "p2" "${TMPDIR}/c2.json" "${TMPDIR}/c2.log" "" 30 "" "" ""
  FAKE_CLAUDE_OUTPUT='{"n":3}' run_claude haiku "${TMPDIR}/implementer.md" "p3" "${TMPDIR}/c3.json" "${TMPDIR}/c3.log" "" 30 "" "" ""
) >/dev/null 2>&1
read -r fa fb fc <<< "$(
  export RC_REPLAY_DIR="$REC" RC_FAULT_PLAN="$PLAN_NTH" RC_SIM_STATE_DIR="${TMPDIR}/state-mix" FORGE_CALL_ID=0
  rm -f "${TMPDIR}/state-mix/rule-0.consumed" 2>/dev/null
  a=0; run_claude haiku "${TMPDIR}/implementer.md" "p1" "${TMPDIR}/x1.json" "${TMPDIR}/x1.log" "" 30 "" "" "" >/dev/null 2>&1 || a=$?
  b=0; run_claude haiku "${TMPDIR}/implementer.md" "p2" "${TMPDIR}/x2.json" "${TMPDIR}/x2.log" "" 30 "" "" "" >/dev/null 2>&1 || b=$?
  c=0; run_claude haiku "${TMPDIR}/implementer.md" "p3" "${TMPDIR}/x3.json" "${TMPDIR}/x3.log" "" 30 "" "" "" >/dev/null 2>&1 || c=$?
  echo "$a $b $c"
)"
assert_eq "合成: 1回目はリプレイ（rc=0）" "0" "$fa"
assert_eq "合成: 1回目の内容は録画由来" '{"n":1}' "$(jq -c '.' "${TMPDIR}/x1.json.pending" 2>/dev/null)"
assert_eq "合成: 2回目は fault が replay に優先（rc=1）" "1" "$fb"
assert_eq "合成: 3回目は seq=3 の録画にヒット（rc=0）" "0" "$fc"
assert_eq "合成: 3回目の内容は録画由来" '{"n":3}' "$(jq -c '.' "${TMPDIR}/x3.json.pending" 2>/dev/null)"

# ===== T6: 不正プラン → faults 無効 + 実呼出続行 =====
echo -e "${BOLD}--- T6: 不正プラン ---${NC}"
PLAN_BAD="${TMPDIR}/plan-bad.json"
echo '{"rules": "not-an-array"}' > "$PLAN_BAD"
bad_out=$(
  export RC_FAULT_PLAN="$PLAN_BAD" RC_SIM_STATE_DIR="${TMPDIR}/state-bad" FORGE_CALL_ID=0
  run_claude haiku "${TMPDIR}/implementer.md" "p" "${TMPDIR}/bd.json" "${TMPDIR}/bd.log" "" 30 "" "" "" 2>&1
  echo "RC=$?"
)
assert_contains "不正プラン: 警告ログが出る" "fault plan が不正" "$bad_out"
assert_contains "不正プラン: 実呼出は成功する" "RC=0" "$bad_out"

PLAN_BADRULE="${TMPDIR}/plan-badrule.json"
jq -n '{rules:[{match:{agent_pattern:"implementer"}, fault:"unknown_fault_type"}]}' > "$PLAN_BADRULE"
badrule_out=$(
  export RC_FAULT_PLAN="$PLAN_BADRULE" RC_SIM_STATE_DIR="${TMPDIR}/state-badrule" FORGE_CALL_ID=0
  run_claude haiku "${TMPDIR}/implementer.md" "p" "${TMPDIR}/br.json" "${TMPDIR}/br.log" "" 30 "" "" "" 2>&1
  echo "RC=$?"
)
assert_contains "未知 fault type ルール: 検証で弾かれ警告" "不正ルール" "$badrule_out"
assert_contains "未知 fault type ルール: 実呼出は成功する" "RC=0" "$badrule_out"

print_test_summary
exit $?
