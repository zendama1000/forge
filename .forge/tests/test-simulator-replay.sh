#!/bin/bash
# test-simulator-replay.sh — フライトシミュレータ REPLAY 経路のテスト
# 録画 → リプレイの決定論・API 呼出ゼロ・順序耐性・strict/lenient・分類再導出を検証。
# 使い方: bash .forge/tests/test-simulator-replay.sh

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

# ===== fake claude =====
FAKE_BIN="${TMPDIR}/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/bin/bash
debug=""
schema=0
prev=""
for a in "$@"; do
  [ "$prev" = "--debug-file" ] && debug="$a"
  [ "$a" = "--json-schema" ] && schema=1
  prev="$a"
done
cat > /dev/null
[ -n "$debug" ] && printf '{"usage": {"input_tokens": 111, "output_tokens": 222}}\n' > "$debug"
if [ "${FAKE_CLAUDE_EXIT:-0}" != "0" ]; then
  printf '%s\n' "${FAKE_CLAUDE_OUTPUT:-fake failure output}"
  exit "${FAKE_CLAUDE_EXIT}"
fi
if [ "$schema" = "1" ]; then
  printf '{"subtype":"success","structured_output":{"answer":42},"result":"raw"}\n'
else
  printf '%s\n' "${FAKE_CLAUDE_OUTPUT:-{\"hello\":\"world\"}}"
fi
EOF
chmod +x "${FAKE_BIN}/claude"

# tripwire claude: 呼ばれたらマーカーを残す（リプレイが実 CLI を叩かない証明用）
TRIP_BIN="${TMPDIR}/trip-bin"
mkdir -p "$TRIP_BIN"
cat > "${TRIP_BIN}/claude" <<EOF
#!/bin/bash
touch "${TMPDIR}/CLI_WAS_CALLED"
cat > /dev/null
echo "tripwire"
exit 99
EOF
chmod +x "${TRIP_BIN}/claude"

source "${PROJECT_ROOT}/.forge/lib/common.sh"
COSTS_FILE="${TMPDIR}/costs.jsonl"

echo -e "${BOLD}===== test-simulator-replay.sh — REPLAY 経路 =====${NC}"
echo ""

REC="${TMPDIR}/recording"
echo "agent A" > "${TMPDIR}/alpha.md"
echo "agent B" > "${TMPDIR}/beta.md"

# ===== 録画フェーズ: 3呼出（alpha, beta, alpha）+ schema 1呼出 + budget 失敗 1呼出 =====
( export PATH="${FAKE_BIN}:$PATH" RC_RECORD_DIR="$REC" RC_SIM_STATE_DIR="${TMPDIR}/state-rec" FORGE_CALL_ID=0
  FAKE_CLAUDE_OUTPUT='{"r":"alpha1"}' run_claude haiku "${TMPDIR}/alpha.md" "p1" "${TMPDIR}/r1.json" "${TMPDIR}/r1.log" "" 30 "" "" ""
  FAKE_CLAUDE_OUTPUT='{"r":"beta1"}'  run_claude haiku "${TMPDIR}/beta.md"  "p2" "${TMPDIR}/r2.json" "${TMPDIR}/r2.log" "" 30 "" "" ""
  FAKE_CLAUDE_OUTPUT='{"r":"alpha2"}' run_claude haiku "${TMPDIR}/alpha.md" "p3" "${TMPDIR}/r3.json" "${TMPDIR}/r3.log" "" 30 "" "" ""
  echo '{"type":"object"}' > "${TMPDIR}/dummy.schema.json"
  run_claude haiku "" "p4" "${TMPDIR}/r4.json" "${TMPDIR}/r4.log" "" 30 "" "${TMPDIR}/dummy.schema.json" ""
  FAKE_CLAUDE_EXIT=1 FAKE_CLAUDE_OUTPUT="Error: Exceeded USD budget (3.0)" \
    run_claude haiku "${TMPDIR}/beta.md" "p5" "${TMPDIR}/r5.json" "${TMPDIR}/r5.log" "" 30 "" "" "" || true
) >/dev/null 2>&1

rec_count=$(find "$REC" -maxdepth 1 -name 'call-*.json' | wc -l | tr -d ' ')
assert_eq "録画フェーズ: 5件録画された" "5" "$rec_count"

# ===== T1: リプレイ roundtrip（tripwire PATH = 実 CLI を叩けば検出） =====
echo -e "${BOLD}--- T1: roundtrip 決定論 + API 呼出ゼロ ---${NC}"
rc1=0
( export PATH="${TRIP_BIN}:$PATH" RC_REPLAY_DIR="$REC" RC_SIM_STATE_DIR="${TMPDIR}/state-rp1" FORGE_CALL_ID=0
  run_claude haiku "${TMPDIR}/alpha.md" "p1" "${TMPDIR}/q1.json" "${TMPDIR}/q1.log" "" 30 "" "" ""
  run_claude haiku "${TMPDIR}/beta.md"  "p2" "${TMPDIR}/q2.json" "${TMPDIR}/q2.log" "" 30 "" "" ""
  run_claude haiku "${TMPDIR}/alpha.md" "p3" "${TMPDIR}/q3.json" "${TMPDIR}/q3.log" "" 30 "" "" ""
) >/dev/null 2>&1 || rc1=$?
assert_eq "リプレイ3呼出が全て rc=0" "0" "$rc1"
if [ -f "${TMPDIR}/CLI_WAS_CALLED" ]; then
  assert_eq "実 CLI は一度も呼ばれない" "no-call" "CALLED"
else
  assert_eq "実 CLI は一度も呼ばれない" "no-call" "no-call"
fi
for i in 1 2 3; do
  if cmp -s "${TMPDIR}/r${i}.json.pending" "${TMPDIR}/q${i}.json.pending"; then
    assert_eq "呼出${i}: .pending バイト一致" "same" "same"
  else
    assert_eq "呼出${i}: .pending バイト一致" "same" "different (r=$(cat "${TMPDIR}/r${i}.json.pending" 2>/dev/null) q=$(cat "${TMPDIR}/q${i}.json.pending" 2>/dev/null))"
  fi
done
cost_entries=$(grep -c 'input_tokens' "$COSTS_FILE" 2>/dev/null || echo 0)
if [ "$cost_entries" -ge 3 ]; then
  assert_eq "リプレイでも costs.jsonl にコスト記録（合成 debug log 経由）" "yes" "yes"
else
  assert_eq "リプレイでも costs.jsonl にコスト記録（合成 debug log 経由）" "yes" "no (entries=$cost_entries)"
fi

# ===== T2: schema モード roundtrip（封筒抽出を再通過） =====
echo -e "${BOLD}--- T2: schema モード roundtrip ---${NC}"
rc2=0
( export PATH="${TRIP_BIN}:$PATH" RC_REPLAY_DIR="$REC" RC_SIM_STATE_DIR="${TMPDIR}/state-rp2" FORGE_CALL_ID=3
  run_claude haiku "" "p4" "${TMPDIR}/q4.json" "${TMPDIR}/q4.log" "" 30 "" "${TMPDIR}/dummy.schema.json" "" ) >/dev/null 2>&1 || rc2=$?
assert_eq "schema リプレイ rc=0" "0" "$rc2"
assert_eq "封筒抽出が再実行され .pending は structured_output" '{"answer":42}' "$(jq -c '.' "${TMPDIR}/q4.json.pending" 2>/dev/null)"

# ===== T3: グローバル順序の入替に耐える（agent+seq キー） =====
echo -e "${BOLD}--- T3: 順序入替耐性 ---${NC}"
rc3=0
( export PATH="${TRIP_BIN}:$PATH" RC_REPLAY_DIR="$REC" RC_SIM_STATE_DIR="${TMPDIR}/state-rp3" FORGE_CALL_ID=0
  # 録画順は alpha,beta,alpha だが、beta を先に呼ぶ
  run_claude haiku "${TMPDIR}/beta.md"  "p2" "${TMPDIR}/o1.json" "${TMPDIR}/o1.log" "" 30 "" "" ""
  run_claude haiku "${TMPDIR}/alpha.md" "p1" "${TMPDIR}/o2.json" "${TMPDIR}/o2.log" "" 30 "" "" ""
) >/dev/null 2>&1 || rc3=$?
assert_eq "順序入替でも rc=0" "0" "$rc3"
assert_eq "beta 先行呼出が beta の録画にヒット" '{"r":"beta1"}' "$(jq -c '.' "${TMPDIR}/o1.json.pending" 2>/dev/null)"
assert_eq "alpha 後続呼出が alpha seq=1 にヒット" '{"r":"alpha1"}' "$(jq -c '.' "${TMPDIR}/o2.json.pending" 2>/dev/null)"

# ===== T4: strict miss / lenient フォールスルー =====
echo -e "${BOLD}--- T4: strict miss / lenient ---${NC}"
echo "agent C" > "${TMPDIR}/gamma.md"
rc4=0
( export PATH="${TRIP_BIN}:$PATH" RC_REPLAY_DIR="$REC" RC_SIM_STATE_DIR="${TMPDIR}/state-rp4" FORGE_CALL_ID=0
  run_claude haiku "${TMPDIR}/gamma.md" "px" "${TMPDIR}/m1.json" "${TMPDIR}/m1.log" "" 30 "" "" "" ) >/dev/null 2>&1 || rc4=$?
assert_eq "strict miss: rc=97" "97" "$rc4"
miss_log=$(cat "${TMPDIR}/state-rp4/replay-miss.jsonl" 2>/dev/null)
assert_contains "replay-miss.jsonl に診断が残る" '"agent":"gamma"' "$miss_log"
if [ -f "${TMPDIR}/m1.json.pending" ]; then
  assert_eq "strict miss: .pending は残らない" "absent" "present"
else
  assert_eq "strict miss: .pending は残らない" "absent" "absent"
fi

rm -f "${TMPDIR}/CLI_WAS_CALLED"
rc4l=0
( export PATH="${FAKE_BIN}:$PATH" RC_REPLAY_DIR="$REC" RC_REPLAY_STRICT=0 RC_SIM_STATE_DIR="${TMPDIR}/state-rp4l" FORGE_CALL_ID=0
  FAKE_CLAUDE_OUTPUT='{"r":"live"}' run_claude haiku "${TMPDIR}/gamma.md" "px" "${TMPDIR}/m2.json" "${TMPDIR}/m2.log" "" 30 "" "" "" ) >/dev/null 2>&1 || rc4l=$?
assert_eq "lenient miss: rc=0（実 CLI へフォールスルー）" "0" "$rc4l"
assert_eq "lenient miss: 実 CLI の応答が使われる" '{"r":"live"}' "$(jq -c '.' "${TMPDIR}/m2.json.pending" 2>/dev/null)"

# ===== T5: budget 失敗録画のリプレイ → classify が exit 21 を再導出 =====
echo -e "${BOLD}--- T5: budget 録画 → 21 再導出 ---${NC}"
rc5=0
( export PATH="${TRIP_BIN}:$PATH" RC_REPLAY_DIR="$REC" RC_SIM_STATE_DIR="${TMPDIR}/state-rp5" FORGE_CALL_ID=0
  export RC_SIM_STATE_DIR
  # beta の seq=1 は {"r":"beta1"}、seq=2 が budget 失敗の録画
  run_claude haiku "${TMPDIR}/beta.md" "p2" "${TMPDIR}/b1.json" "${TMPDIR}/b1.log" "" 30 "" "" "" >/dev/null 2>&1
  run_claude haiku "${TMPDIR}/beta.md" "p5" "${TMPDIR}/b2.json" "${TMPDIR}/b2.log" "" 30 "" "" "" ) >/dev/null 2>&1 || rc5=$?
assert_eq "budget 録画リプレイ: rc=21（分類の再導出）" "21" "$rc5"

# ===== T6: debug_rate_limit_marker 録画 → 429 マーカー行の再生 =====
echo -e "${BOLD}--- T6: 429 マーカー再生 ---${NC}"
RLDIR="${TMPDIR}/rl-rec"
mkdir -p "$RLDIR"
jq -n '{version:1, call_id:1, agent:"implementer", agent_seq:1, model:"haiku", effort:"",
        schema:"", work_dir:"", output_file:"", stage_timeout:"30",
        prompt:"p", response:"API Error: 429", exit_code:1, duration_sec:0,
        input_tokens:10, output_tokens:5, debug_rate_limit_marker:true,
        source:"real", timestamp:"2026-07-14T00:00:00+09:00", session_id:""}' \
  > "${RLDIR}/call-0001-implementer.json"
echo "implementer" > "${TMPDIR}/implementer.md"
rc6=0
( export PATH="${TRIP_BIN}:$PATH" RC_REPLAY_DIR="$RLDIR" RC_SIM_STATE_DIR="${TMPDIR}/state-rp6" FORGE_CALL_ID=0
  run_claude haiku "${TMPDIR}/implementer.md" "p" "${TMPDIR}/rl.json" "${TMPDIR}/rl.log" "" 30 "" "" "" ) >/dev/null 2>&1 || rc6=$?
assert_eq "429 録画リプレイ: rc=1" "1" "$rc6"
if grep -qE '429|too many requests|rate.limit|rate_limit|overloaded' "${TMPDIR}/rl.log" 2>/dev/null; then
  assert_eq "合成 debug log が 429 検出 grep にヒットする" "hit" "hit"
else
  assert_eq "合成 debug log が 429 検出 grep にヒットする" "hit" "miss ($(cat "${TMPDIR}/rl.log" 2>/dev/null))"
fi
# 1行目のヘッダ行自体は 429 パターンに引っかからないこと
header_line=$(head -1 "${TMPDIR}/rl.log" 2>/dev/null)
if printf '%s' "$header_line" | grep -qE '429|too many requests|rate.limit|rate_limit|overloaded'; then
  assert_eq "[sim-replay] ヘッダ行は 429 パターンに非該当" "clean" "matched"
else
  assert_eq "[sim-replay] ヘッダ行は 429 パターンに非該当" "clean" "clean"
fi

print_test_summary
exit $?
