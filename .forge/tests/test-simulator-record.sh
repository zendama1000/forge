#!/bin/bash
# test-simulator-record.sh — フライトシミュレータ RECORD 経路のテスト
# 検証対象: simulator.sh の録画 + common.sh フック（無効時の挙動不変を含む）
# 使い方: bash .forge/tests/test-simulator-record.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export NOTIFY_DIR="${TMPDIR}/notifications"
export CLAUDE_TIMEOUT=30
export _RC_CLI_HELP_CACHE="  --max-budget-usd <amount>  --max-turns <n>  --agents <json>"
json_fail_count=0
touch "$ERRORS_FILE"

# ===== fake claude（PATH shim。--debug-file にトークン行を書き stdout に応答） =====
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
export PATH="${FAKE_BIN}:$PATH"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

echo -e "${BOLD}===== test-simulator-record.sh — RECORD 経路 =====${NC}"
echo ""

# ===== T1: 無効時のバイト同一性（sim 環境変数なし vs RC_RECORD_DIR あり） =====
echo -e "${BOLD}--- T1: 無効時バイト同一性 ---${NC}"
rc1=0
run_claude haiku "" "hello" "${TMPDIR}/plain.json" "${TMPDIR}/plain.log" "" 30 "" "" "" || rc1=$?
assert_eq "sim 無効: rc=0" "0" "$rc1"

rc2=0
( export RC_RECORD_DIR="${TMPDIR}/rec1" FORGE_CALL_ID=0
  run_claude haiku "" "hello" "${TMPDIR}/rec.json" "${TMPDIR}/rec.log" "" 30 "" "" "" ) || rc2=$?
assert_eq "録画モード: rc=0" "0" "$rc2"
if cmp -s "${TMPDIR}/plain.json.pending" "${TMPDIR}/rec.json.pending"; then
  assert_eq "無効時と録画時の .pending がバイト同一" "same" "same"
else
  assert_eq "無効時と録画時の .pending がバイト同一" "same" "different"
fi

# ===== T2: common.sh 単体コピー環境（simulator.sh 不在）でフォールバック動作 =====
echo -e "${BOLD}--- T2: simulator.sh 不在フォールバック ---${NC}"
FB_ROOT="${TMPDIR}/fallback-proj"
mkdir -p "${FB_ROOT}/.forge/lib" "${FB_ROOT}/.forge/config"
cp "${PROJECT_ROOT}/.forge/lib/common.sh" "${FB_ROOT}/.forge/lib/"
cp "${PROJECT_ROOT}/.forge/config/circuit-breaker.json" "${FB_ROOT}/.forge/config/" 2>/dev/null || true
fb_out=$(cd "$FB_ROOT" && bash -c '
  export PROJECT_ROOT="$PWD" ERRORS_FILE="$PWD/e.jsonl" NOTIFY_DIR="$PWD/n"
  export _RC_CLI_HELP_CACHE="  --max-budget-usd  --max-turns"
  json_fail_count=0
  source .forge/lib/common.sh 2>/dev/null
  declare -f sim_call_begin >/dev/null && echo "FALLBACK_DEFINED"
  run_claude haiku "" "fb-test" "$PWD/fb.json" "$PWD/fb.log" "" 30 "" "" "" && echo "RC_OK"
  cat fb.json.pending
' 2>/dev/null)
assert_contains "フォールバック sim_call_begin が定義される" "FALLBACK_DEFINED" "$fb_out"
assert_contains "フォールバックで run_claude 成功" "RC_OK" "$fb_out"
assert_contains "フォールバックで .pending に応答が書かれる" '{"hello":"world"}' "$fb_out"

# ===== T3: 成功呼出の録画フィールド =====
echo -e "${BOLD}--- T3: 録画フィールド（T1 の rec1 を検査） ---${NC}"
REC_FILE="${TMPDIR}/rec1/call-0001-none.json"
if [ -f "$REC_FILE" ]; then
  assert_eq "録画ファイルが存在する" "yes" "yes"
else
  assert_eq "録画ファイルが存在する" "yes" "no ($(ls "${TMPDIR}/rec1" 2>/dev/null | tr '\n' ' '))"
fi
assert_eq "version=1" "1" "$(jq -r '.version' "$REC_FILE" 2>/dev/null)"
assert_eq "agent=none（agent_file 空）" "none" "$(jq -r '.agent' "$REC_FILE" 2>/dev/null)"
assert_eq "agent_seq=1" "1" "$(jq -r '.agent_seq' "$REC_FILE" 2>/dev/null)"
assert_eq "model=haiku" "haiku" "$(jq -r '.model' "$REC_FILE" 2>/dev/null)"
assert_eq "exit_code=0" "0" "$(jq -r '.exit_code' "$REC_FILE" 2>/dev/null)"
assert_eq "input_tokens=111（debug log から抽出）" "111" "$(jq -r '.input_tokens' "$REC_FILE" 2>/dev/null)"
assert_eq "output_tokens=222" "222" "$(jq -r '.output_tokens' "$REC_FILE" 2>/dev/null)"
assert_eq "prompt が保存される" "hello" "$(jq -r '.prompt' "$REC_FILE" 2>/dev/null)"
assert_eq "source=real" "real" "$(jq -r '.source' "$REC_FILE" 2>/dev/null)"
assert_eq "debug_rate_limit_marker=false" "false" "$(jq -r '.debug_rate_limit_marker' "$REC_FILE" 2>/dev/null)"
# response_b64 == .pending の生バイト（base64 経由 = Windows jq CRLF 変換の影響なし）
resp_tmp="${TMPDIR}/resp-extract.bin"
jq -r '.response_b64' "$REC_FILE" 2>/dev/null | tr -d '\r\n' | base64 -d > "$resp_tmp" 2>/dev/null
if cmp -s "$resp_tmp" "${TMPDIR}/rec.json.pending"; then
  assert_eq "response_b64 が .pending の生バイトと一致" "same" "same"
else
  assert_eq "response_b64 が .pending の生バイトと一致" "same" "different"
fi

# ===== T4: 失敗呼出も録画される =====
echo -e "${BOLD}--- T4: 失敗呼出の録画 ---${NC}"
rc4=0
( export RC_RECORD_DIR="${TMPDIR}/rec2" FORGE_CALL_ID=0 FAKE_CLAUDE_EXIT=1 FAKE_CLAUDE_OUTPUT="boom"
  run_claude haiku "" "fail-prompt" "${TMPDIR}/f.json" "${TMPDIR}/f.log" "" 30 "" "" "" ) || rc4=$?
assert_eq "run_claude が非ゼロを返す" "1" "$rc4"
REC_FAIL="${TMPDIR}/rec2/call-0001-none.json"
assert_eq "失敗録画: exit_code=1" "1" "$(jq -r '.exit_code' "$REC_FAIL" 2>/dev/null)"
assert_contains "失敗録画: response に出力が残る" "boom" "$(jq -r '.response' "$REC_FAIL" 2>/dev/null)"
if [ -f "${TMPDIR}/f.json.pending" ]; then
  assert_eq "失敗時 .pending は削除される（run_claude 既存挙動）" "absent" "present"
else
  assert_eq "失敗時 .pending は削除される（run_claude 既存挙動）" "absent" "absent"
fi

# ===== T5: schema モード（response=生エンベロープ、.pending=抽出後） =====
echo -e "${BOLD}--- T5: schema モード ---${NC}"
SCHEMA_FILE="${TMPDIR}/dummy.schema.json"
echo '{"type":"object"}' > "$SCHEMA_FILE"
rc5=0
( export RC_RECORD_DIR="${TMPDIR}/rec3" FORGE_CALL_ID=0
  run_claude haiku "" "schema-prompt" "${TMPDIR}/s.json" "${TMPDIR}/s.log" "" 30 "" "$SCHEMA_FILE" "" ) || rc5=$?
assert_eq "schema モード rc=0" "0" "$rc5"
REC_SCHEMA="${TMPDIR}/rec3/call-0001-none.json"
assert_contains "録画 response は封筒抽出前の生エンベロープ" '"subtype"' "$(jq -r '.response' "$REC_SCHEMA" 2>/dev/null)"
assert_eq ".pending は structured_output 抽出後" '{"answer":42}' "$(jq -c '.' "${TMPDIR}/s.json.pending" 2>/dev/null)"
assert_eq "録画 schema フィールド" "dummy.schema.json" "$(jq -r '.schema' "$REC_SCHEMA" 2>/dev/null)"

# ===== T6: agent interleave で per-agent 連番が独立 =====
echo -e "${BOLD}--- T6: per-agent 連番 ---${NC}"
echo "agent A" > "${TMPDIR}/alpha.md"
echo "agent B" > "${TMPDIR}/beta.md"
( export RC_RECORD_DIR="${TMPDIR}/rec4" FORGE_CALL_ID=0
  run_claude haiku "${TMPDIR}/alpha.md" "p1" "${TMPDIR}/i1.json" "${TMPDIR}/i1.log" "" 30 "" "" ""
  run_claude haiku "${TMPDIR}/beta.md"  "p2" "${TMPDIR}/i2.json" "${TMPDIR}/i2.log" "" 30 "" "" ""
  run_claude haiku "${TMPDIR}/alpha.md" "p3" "${TMPDIR}/i3.json" "${TMPDIR}/i3.log" "" 30 "" "" ""
) >/dev/null 2>&1
assert_eq "alpha 1回目 seq=1" "1" "$(jq -r '.agent_seq' "${TMPDIR}/rec4/call-0001-alpha.json" 2>/dev/null)"
assert_eq "beta 1回目 seq=1" "1" "$(jq -r '.agent_seq' "${TMPDIR}/rec4/call-0002-beta.json" 2>/dev/null)"
assert_eq "alpha 2回目 seq=2（独立カウンタ）" "2" "$(jq -r '.agent_seq' "${TMPDIR}/rec4/call-0003-alpha.json" 2>/dev/null)"

# ===== T7: work_dir サブシェル分岐でも連番は1回だけ消費 =====
echo -e "${BOLD}--- T7: work_dir 分岐 ---${NC}"
WD="${TMPDIR}/wd"
mkdir -p "$WD"
rc7=0
( export RC_RECORD_DIR="${TMPDIR}/rec5" FORGE_CALL_ID=0
  run_claude haiku "" "wd-prompt" "${TMPDIR}/w.json" "${TMPDIR}/w.log" "" 30 "$WD" "" "" ) || rc7=$?
assert_eq "work_dir 分岐 rc=0" "0" "$rc7"
REC_WD="${TMPDIR}/rec5/call-0001-none.json"
# MSYS のパス自動変換（/tmp/... → C:/...）があるため suffix で比較（情報フィールド）
rec_wd=$(jq -r '.work_dir' "$REC_WD" 2>/dev/null)
case "$rec_wd" in
  */wd) assert_eq "work_dir が録画される（suffix 一致）" "match" "match" ;;
  *)    assert_eq "work_dir が録画される（suffix 一致）" "match" "no-match ($rec_wd)" ;;
esac
seq_count=$(find "${TMPDIR}/rec5" -name 'seq-none' -exec cat {} \; 2>/dev/null)
assert_eq "連番は1回だけ消費（seq ファイル=1）" "1" "$seq_count"
rec_count=$(find "${TMPDIR}/rec5" -maxdepth 1 -name 'call-*.json' | wc -l | tr -d ' ')
assert_eq "録画は1件のみ" "1" "$rec_count"

# ===== T8: FORGE_DRY_RUN が sim より優先（録画なし・連番非消費） =====
echo -e "${BOLD}--- T8: DRY_RUN 優先 ---${NC}"
dry_out=$(
  export RC_RECORD_DIR="${TMPDIR}/rec6" FORGE_CALL_ID=0 FORGE_DRY_RUN=1
  run_claude haiku "" "dry" "${TMPDIR}/d.json" "${TMPDIR}/d.log" "" 30 "" "" ""
)
assert_contains "DRY_RUN は CMD を出力" "CMD: claude" "$dry_out"
dry_recs=$(find "${TMPDIR}/rec6" -maxdepth 1 -name 'call-*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "DRY_RUN では録画されない" "0" "$dry_recs"
dry_seq=$(find "${TMPDIR}/rec6" -name 'seq-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "DRY_RUN では連番も非消費" "0" "$dry_seq"

print_test_summary
exit $?
