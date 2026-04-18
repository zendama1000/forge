#!/bin/bash
# test-run-quality-gates.sh — run-quality-gates.sh の Layer 1 テスト
#
# 使い方: bash .forge/tests/test-run-quality-gates.sh
#
# 必須テスト振る舞い（required_behaviors）:
#   1. ffprobe_exists: 'output.mp4' 指定 + ファイル存在 → 評価 PASS
#   2. ffprobe_exists: 存在しないパス → 評価 FAIL + 明確なエラーメッセージ
#   3. duration_check: expected=60, tolerance=2, 実 duration=61 → PASS
#   4. duration_check: expected=60, tolerance=2, 実 duration=65 → FAIL + 差分値を報告
#   5. size_threshold: min_bytes=1000, 実サイズ=500 → FAIL
#
# 設計:
#   - 5 つの fixture (ok / missing-output / bad-duration / bad-size / empty-gates)
#     を tests/fixtures/video/gates-runner/ に test 実行時に作成
#   - ffprobe 依存を決定的にするため mock ffprobe を temp dir + PATH で差し込む
#   - scenario.json の gate.command は .forge/lib/video-assertions.sh を呼び出す
#     形式に統一（ランナー→bash -c→video-assertions→mock ffprobe の経路を通す）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNNER="${PROJECT_ROOT}/.forge/lib/run-quality-gates.sh"
VA_LIB="${PROJECT_ROOT}/.forge/lib/video-assertions.sh"
FIXTURE_ROOT="${PROJECT_ROOT}/tests/fixtures/video/gates-runner"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

_record_pass() { echo -e "  ${GREEN}${NC} $1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
_record_fail() { echo -e "  ${RED}${NC} $1"; [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

echo ""
echo -e "${BOLD}=== run-quality-gates テスト ===${NC}"
echo ""

# --- preflight -----------------------------------------------------------
if [ ! -f "$RUNNER" ];  then echo -e "${RED}ERROR: runner not found: $RUNNER${NC}"; exit 2; fi
if [ ! -f "$VA_LIB" ];  then echo -e "${RED}ERROR: video-assertions.sh not found: $VA_LIB${NC}"; exit 2; fi
for tool in jq awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo -e "${RED}ERROR: $tool is required${NC}"; exit 2; }
done

# --- fixture setup -------------------------------------------------------
F_OK="${FIXTURE_ROOT}/ok"
F_EMPTY="${FIXTURE_ROOT}/empty-gates"
F_MISSING="${FIXTURE_ROOT}/missing-output"
F_BAD_DUR="${FIXTURE_ROOT}/bad-duration"
F_BAD_SIZE="${FIXTURE_ROOT}/bad-size"

mkdir -p "$F_OK/out" "$F_EMPTY" "$F_MISSING/out" "$F_BAD_DUR/out" "$F_BAD_SIZE/out"

# out/output.mp4 (2048 bytes) — mock ffprobe で duration=61 扱い
head -c 2048 /dev/urandom > "$F_OK/out/output.mp4" 2>/dev/null \
  || dd if=/dev/urandom of="$F_OK/out/output.mp4" bs=1 count=2048 >/dev/null 2>&1

# missing-output/out/ — placeholder ファイルを置いて「未レンダー SKIP」判定を回避。
# このフィクスチャは gate が nope.mp4（存在しない）を参照するため FAIL を期待する。
# out/ 自体は空でないので、ランナーは SKIP せず gate を実行し、期待どおり FAIL する。
: > "$F_MISSING/out/.placeholder"

# bad-duration/out/long65.mp4 — mock ffprobe で duration=65 扱い
head -c 1024 /dev/urandom > "$F_BAD_DUR/out/long65.mp4" 2>/dev/null \
  || dd if=/dev/urandom of="$F_BAD_DUR/out/long65.mp4" bs=1 count=1024 >/dev/null 2>&1

# bad-size/out/small.mp4 — 実サイズ 500 bytes（size_threshold FAIL 用）
if [ "$(wc -c <"$F_BAD_SIZE/out/small.mp4" 2>/dev/null | tr -d ' \r\n')" != "500" ]; then
  head -c 500 /dev/zero > "$F_BAD_SIZE/out/small.mp4" 2>/dev/null \
    || dd if=/dev/zero of="$F_BAD_SIZE/out/small.mp4" bs=1 count=500 >/dev/null 2>&1
fi

# --- scenario.json 生成 --------------------------------------------------
cat > "$F_OK/scenario.json" <<'EOF'
{
  "id": "ok",
  "type": "screen_record",
  "version": "1.0.0",
  "input_sources": [],
  "quality_gates": {
    "required_mechanical_gates": [
      {
        "id": "output_exists",
        "description": "ffprobe_exists on existing output.mp4",
        "command": "bash .forge/lib/video-assertions.sh ffprobe_exists tests/fixtures/video/gates-runner/ok/out/output.mp4",
        "expect": "exit 0",
        "blocking": true
      },
      {
        "id": "duration_ok",
        "description": "duration_check expected=60 tolerance=2 (actual=61)",
        "command": "bash .forge/lib/video-assertions.sh duration_check tests/fixtures/video/gates-runner/ok/out/output.mp4 60 2",
        "expect": "exit 0",
        "blocking": true
      },
      {
        "id": "size_ok",
        "description": "size_threshold min=100 on 2048-byte file",
        "command": "bash .forge/lib/video-assertions.sh size_threshold tests/fixtures/video/gates-runner/ok/out/output.mp4 100",
        "expect": "exit 0",
        "blocking": true
      }
    ]
  },
  "agent_prompt_patch": ""
}
EOF

cat > "$F_EMPTY/scenario.json" <<'EOF'
{"id":"empty-gates","type":"screen_record","version":"1.0.0","input_sources":[],"quality_gates":{"required_mechanical_gates":[]},"agent_prompt_patch":""}
EOF

cat > "$F_MISSING/scenario.json" <<'EOF'
{
  "id": "missing-output",
  "type": "screen_record",
  "version": "1.0.0",
  "input_sources": [],
  "quality_gates": {
    "required_mechanical_gates": [
      {
        "id": "missing_output",
        "description": "ffprobe_exists on nonexistent path",
        "command": "bash .forge/lib/video-assertions.sh ffprobe_exists tests/fixtures/video/gates-runner/missing-output/out/nope.mp4",
        "expect": "exit 0",
        "blocking": true
      }
    ]
  },
  "agent_prompt_patch": ""
}
EOF

cat > "$F_BAD_DUR/scenario.json" <<'EOF'
{
  "id": "bad-duration",
  "type": "screen_record",
  "version": "1.0.0",
  "input_sources": [],
  "quality_gates": {
    "required_mechanical_gates": [
      {
        "id": "bad_duration",
        "description": "duration_check expected=60 tolerance=2 (actual=65)",
        "command": "bash .forge/lib/video-assertions.sh duration_check tests/fixtures/video/gates-runner/bad-duration/out/long65.mp4 60 2",
        "expect": "exit 0",
        "blocking": true
      }
    ]
  },
  "agent_prompt_patch": ""
}
EOF

cat > "$F_BAD_SIZE/scenario.json" <<'EOF'
{
  "id": "bad-size",
  "type": "screen_record",
  "version": "1.0.0",
  "input_sources": [],
  "quality_gates": {
    "required_mechanical_gates": [
      {
        "id": "bad_size",
        "description": "size_threshold min=1000 on 500-byte file",
        "command": "bash .forge/lib/video-assertions.sh size_threshold tests/fixtures/video/gates-runner/bad-size/out/small.mp4 1000",
        "expect": "exit 0",
        "blocking": true
      }
    ]
  },
  "agent_prompt_patch": ""
}
EOF

# --- Mock ffprobe -------------------------------------------------------
MOCK_BIN_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/rqg-mock-$$")"
mkdir -p "$MOCK_BIN_DIR"
cat > "${MOCK_BIN_DIR}/ffprobe" <<'MOCK_EOF'
#!/bin/bash
# Mock ffprobe for run-quality-gates tests. Deterministic by filename.
set -uo pipefail
file="${!#}"
mode="show_format"
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "-show_entries" ]; then
    j=$((i+1))
    [ "$j" -le "$#" ] && [ "${!j}" = "format=duration" ] && mode="duration"
  fi
done
[ -z "$file" ] || [ ! -e "$file" ] && { echo "Mock ffprobe: file not found: '$file'" >&2; exit 1; }
base="$(basename -- "$file")"
case "$mode" in
  duration)
    case "$base" in
      output.mp4|ok.mp4) echo "61.000000" ;;
      long65.mp4)        echo "65.000000" ;;
      *.mp4)             echo "60.000000" ;;
      *) echo "Mock ffprobe: not recognized: '$file'" >&2; exit 1 ;;
    esac
    ;;
  show_format)
    case "$base" in
      *.mp4) exit 0 ;;
      *) echo "Mock ffprobe: invalid data: '$file'" >&2; exit 1 ;;
    esac
    ;;
esac
MOCK_EOF
chmod +x "${MOCK_BIN_DIR}/ffprobe"

cleanup() { rm -rf "$MOCK_BIN_DIR" 2>/dev/null || true; }
trap cleanup EXIT

export PATH="${MOCK_BIN_DIR}:${PATH}"
command -v ffprobe >/dev/null 2>&1 || { echo -e "${RED}ERROR: mock ffprobe not on PATH${NC}"; exit 2; }

echo -e "${BOLD}[preflight]${NC} runner + 5 fixtures + mock ffprobe OK"
echo ""

# =========================================================================
# Group 1: basic usage / argument handling
# =========================================================================
echo -e "${BOLD}[1] basic usage${NC}"

# runner 読込可能
if [ -r "$RUNNER" ]; then _record_pass "runner ファイル存在"; else _record_fail "runner ファイル" "unreadable"; fi

# 引数なし → usage + rc=2
out=$(bash "$RUNNER" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -qF "Usage:"; then
  _record_pass "引数なし → Usage + rc=2"
else
  _record_fail "引数なし usage" "rc=$rc output: ${out:0:200}"
fi

# --help → rc=0
out=$(bash "$RUNNER" --help 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qF "Usage:"; then
  _record_pass "--help → rc=0 + Usage"
else
  _record_fail "--help" "rc=$rc output: ${out:0:200}"
fi

# 存在しないディレクトリ → rc=2
out=$(bash "$RUNNER" "/no-such-dir-xyz-$$" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
  _record_pass "存在しない dir → rc=2"
else
  _record_fail "存在しない dir" "rc=$rc output: ${out:0:200}"
fi
echo ""

# =========================================================================
# Group 2: ok scenario — 全 gate PASS
# =========================================================================
echo -e "${BOLD}[2] ok scenario — 全 gate PASS${NC}"

LOG="/tmp/rqg-ok-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" --scenario "$F_OK/scenario.json" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"

# behavior: ffprobe_exists: 'output.mp4' 指定 + ファイル存在 → 評価 PASS
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE "output_exists.*PASS"; then
  _record_pass "behavior: ffprobe_exists: 'output.mp4' 指定 + ファイル存在 → 評価 PASS"
else
  _record_fail "behavior: ffprobe_exists PASS" "rc=$rc output: ${out:0:600}"
fi

# behavior: duration_check: expected=60, tolerance=2, 実 duration=61 → PASS
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE "duration_ok.*PASS"; then
  _record_pass "behavior: duration_check: expected=60, tolerance=2, 実 duration=61 → PASS"
else
  _record_fail "behavior: duration_check PASS" "rc=$rc output: ${out:0:600}"
fi

# OVERALL PASS
if echo "$out" | grep -qF "OVERALL: PASS"; then
  _record_pass "[追加] ok scenario: OVERALL PASS を出力"
else
  _record_fail "[追加] OVERALL PASS" "output: ${out:0:400}"
fi
echo ""

# =========================================================================
# Group 3: missing-output — ffprobe_exists FAIL + エラーメッセージ
# =========================================================================
echo -e "${BOLD}[3] missing-output — ffprobe_exists FAIL${NC}"

LOG="/tmp/rqg-miss-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" --scenario "$F_MISSING/scenario.json" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"

# behavior: ffprobe_exists: 存在しないパス → 評価 FAIL + 明確なエラーメッセージ
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -qE "missing_output.*FAIL" \
   && echo "$out" | grep -qiE "does not exist|not found|FAIL"; then
  _record_pass "behavior: ffprobe_exists: 存在しないパス → 評価 FAIL + 明確なエラーメッセージ"
else
  _record_fail "behavior: missing-output FAIL" "rc=$rc output: ${out:0:600}"
fi
echo ""

# =========================================================================
# Group 4: bad-duration — duration_check FAIL + diff 値
# =========================================================================
echo -e "${BOLD}[4] bad-duration — duration_check FAIL + diff 報告${NC}"

LOG="/tmp/rqg-bd-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" --scenario "$F_BAD_DUR/scenario.json" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"

# behavior: duration_check: expected=60, tolerance=2, 実 duration=65 → FAIL + 差分値を報告
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -qE "bad_duration.*FAIL" \
   && echo "$out" | grep -qE "diff="; then
  _record_pass "behavior: duration_check: expected=60, tolerance=2, 実 duration=65 → FAIL + 差分値を報告"
else
  _record_fail "behavior: bad-duration FAIL + diff" "rc=$rc output: ${out:0:700}"
fi

# 差分値が 5（|65-60|）であることも確認
if echo "$out" | grep -qE "diff=5\."; then
  _record_pass "[追加] diff=5.xxx が報告される（|65-60|）"
else
  _record_fail "[追加] 差分値の具体値" "output: ${out:0:500}"
fi
echo ""

# =========================================================================
# Group 5: bad-size — size_threshold FAIL
# =========================================================================
echo -e "${BOLD}[5] bad-size — size_threshold FAIL${NC}"

LOG="/tmp/rqg-bs-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" --scenario "$F_BAD_SIZE/scenario.json" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"

# behavior: size_threshold: min_bytes=1000, 実サイズ=500 → FAIL
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "bad_size.*FAIL"; then
  _record_pass "behavior: size_threshold: min_bytes=1000, 実サイズ=500 → FAIL"
else
  _record_fail "behavior: bad-size FAIL" "rc=$rc output: ${out:0:600}"
fi
echo ""

# =========================================================================
# Group 6: empty-gates / 構造不正 / 欠落 / malformed JSON
# =========================================================================
echo -e "${BOLD}[6] 構造不正系${NC}"

# empty-gates
LOG="/tmp/rqg-em-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" --scenario "$F_EMPTY/scenario.json" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"
if [ "$rc" -ne 0 ] && echo "$out" | grep -qiE "empty|minItems"; then
  _record_pass "[追加] empty-gates → FAIL + 'empty' メッセージ"
else
  _record_fail "[追加] empty-gates" "rc=$rc output: ${out:0:400}"
fi

# malformed JSON
BAD="$(mktemp 2>/dev/null || echo "/tmp/rqg-bad-$$.json")"
echo "{ not valid json" > "$BAD"
out=$(bash "$RUNNER" --scenario "$BAD" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qiE "valid json"; then
  _record_pass "[追加] malformed scenario.json → FAIL + 'not valid JSON'"
else
  _record_fail "[追加] malformed" "rc=$rc output: ${out:0:300}"
fi
rm -f "$BAD"

# quality_gates 欠落
NOQG="$(mktemp 2>/dev/null || echo "/tmp/rqg-noqg-$$.json")"
echo '{"id":"x","type":"screen_record","input_sources":[],"agent_prompt_patch":""}' > "$NOQG"
out=$(bash "$RUNNER" --scenario "$NOQG" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qiE "required_mechanical_gates|missing"; then
  _record_pass "[追加] quality_gates 欠落 → FAIL"
else
  _record_fail "[追加] quality_gates 欠落" "rc=$rc output: ${out:0:300}"
fi
rm -f "$NOQG"
echo ""

# =========================================================================
# Group 7: dir-mode — 複数シナリオ走査
# =========================================================================
echo -e "${BOLD}[7] dir-mode — scenarios/*/scenario.json 走査${NC}"

DMR="$(mktemp -d 2>/dev/null || echo "/tmp/rqg-dir-$$")"
mkdir -p "$DMR/ok1/out" "$DMR/ok2/out"
head -c 1024 /dev/urandom > "$DMR/ok1/out/output.mp4" 2>/dev/null \
  || dd if=/dev/urandom of="$DMR/ok1/out/output.mp4" bs=1 count=1024 >/dev/null 2>&1 || true
head -c 1024 /dev/urandom > "$DMR/ok2/out/output.mp4" 2>/dev/null \
  || dd if=/dev/urandom of="$DMR/ok2/out/output.mp4" bs=1 count=1024 >/dev/null 2>&1 || true
for d in ok1 ok2; do
  cat > "$DMR/$d/scenario.json" <<EOF
{
  "id": "$d",
  "type": "screen_record",
  "input_sources": [],
  "quality_gates": {
    "required_mechanical_gates": [
      { "id": "exists",
        "command": "bash '$VA_LIB' ffprobe_exists '$DMR/$d/out/output.mp4'",
        "expect": "exit 0",
        "blocking": true }
    ]
  },
  "agent_prompt_patch": ""
}
EOF
done

LOG="/tmp/rqg-dir-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" "$DMR" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"
rm -rf "$DMR"

if [ "$rc" -eq 0 ] && echo "$out" | grep -qE "scenario ok1" && echo "$out" | grep -qE "scenario ok2"; then
  _record_pass "[追加] dir-mode: 複数 scenario を走査して両方 PASS"
else
  _record_fail "[追加] dir-mode" "rc=$rc output: ${out:0:600}"
fi
echo ""

# =========================================================================
# Group 8: non-blocking gate — FAIL しても runner 全体 PASS
# =========================================================================
echo -e "${BOLD}[8] non-blocking gate${NC}"

NB="$(mktemp -d 2>/dev/null || echo "/tmp/rqg-nb-$$")"
mkdir -p "$NB/out"
head -c 1024 /dev/urandom > "$NB/out/output.mp4" 2>/dev/null \
  || dd if=/dev/urandom of="$NB/out/output.mp4" bs=1 count=1024 >/dev/null 2>&1 || true
cat > "$NB/scenario.json" <<EOF
{
  "id": "nb",
  "type": "screen_record",
  "input_sources": [],
  "quality_gates": {
    "required_mechanical_gates": [
      { "id": "ok",   "command": "bash '$VA_LIB' ffprobe_exists '$NB/out/output.mp4'", "expect": "exit 0", "blocking": true  },
      { "id": "warn", "command": "bash '$VA_LIB' ffprobe_exists '$NB/out/nope.mp4'",   "expect": "exit 0", "blocking": false }
    ]
  },
  "agent_prompt_patch": ""
}
EOF
LOG="/tmp/rqg-nb-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" --scenario "$NB/scenario.json" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"
rm -rf "$NB"

if [ "$rc" -eq 0 ] && echo "$out" | grep -qiE "non-blocking"; then
  _record_pass "[追加] blocking=false の FAIL は runner 全体 PASS + 'non-blocking' 表示"
else
  _record_fail "[追加] non-blocking" "rc=$rc output: ${out:0:600}"
fi
echo ""

# =========================================================================
# Group 9: 未レンダー SKIP — out/ が空/不在の scenario は SKIP（OVERALL: PASS）
# =========================================================================
echo -e "${BOLD}[9] skip-if-unrendered — out/ 不在の scenario は SKIP${NC}"

# 未レンダー scenario（out/ 無し）を作る
SKP="$(mktemp -d 2>/dev/null || echo "/tmp/rqg-skp-$$")"
mkdir -p "$SKP/unrendered"
cat > "$SKP/unrendered/scenario.json" <<EOF
{
  "id": "unrendered",
  "type": "screen_record",
  "input_sources": [],
  "quality_gates": {
    "required_mechanical_gates": [
      { "id": "need_output",
        "description": "fails if run (would require out/output.mp4)",
        "command": "bash '$VA_LIB' ffprobe_exists '$SKP/unrendered/out/output.mp4'",
        "expect": "exit 0",
        "blocking": true }
    ]
  },
  "agent_prompt_patch": ""
}
EOF

LOG="/tmp/rqg-skp-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" "$SKP" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"

# behavior: 未レンダー scenario は SKIP されて OVERALL: PASS
if [ "$rc" -eq 0 ] \
   && echo "$out" | grep -qE "scenario unrendered: SKIP" \
   && echo "$out" | grep -qF "OVERALL: PASS"; then
  _record_pass "[追加] 未レンダー scenario は SKIP + OVERALL: PASS"
else
  _record_fail "[追加] skip-if-unrendered" "rc=$rc output: ${out:0:800}"
fi

# behavior: サマリーに skip:1 が現れる
if echo "$out" | grep -qE "skip:1"; then
  _record_pass "[追加] Summary に skip:1 が出る"
else
  _record_fail "[追加] Summary skip カウント" "output: ${out:0:500}"
fi
echo ""

# =========================================================================
# Group 10: --strict — 未レンダー scenario を FAIL 扱いにする
# =========================================================================
echo -e "${BOLD}[10] --strict — 未レンダーでも FAIL 扱い${NC}"

LOG="/tmp/rqg-strict-$$.log"
( cd "$PROJECT_ROOT" && bash "$RUNNER" --strict "$SKP" ) > "$LOG" 2>&1
rc=$?; out=$(cat "$LOG"); rm -f "$LOG"

# --strict では gate が実行され、out/output.mp4 が無いため FAIL する
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -qF "OVERALL: FAIL" \
   && ! echo "$out" | grep -qE "scenario unrendered: SKIP"; then
  _record_pass "[追加] --strict で未レンダー scenario が実行され FAIL"
else
  _record_fail "[追加] --strict 動作" "rc=$rc output: ${out:0:800}"
fi

rm -rf "$SKP"
echo ""

# =========================================================================
# Group 11: L2 ゲート — scenarios/ 実ディレクトリでも exit 0 を保証
# =========================================================================
echo -e "${BOLD}[11] L2 ゲート — scenarios/ 実行で exit 0${NC}"

if [ -d "$PROJECT_ROOT/scenarios" ]; then
  LOG="/tmp/rqg-l2-$$.log"
  # 実 scenarios/ 配下に render が走っていない前提で、SKIP 経路により PASS するはず
  ( cd "$PROJECT_ROOT" && bash "$RUNNER" scenarios/ ) > "$LOG" 2>&1
  rc=$?; out=$(cat "$LOG"); rm -f "$LOG"
  if [ "$rc" -eq 0 ] && echo "$out" | grep -qF "OVERALL: PASS"; then
    _record_pass "[追加] L2: bash run-quality-gates.sh scenarios/ → exit 0"
  else
    _record_fail "[追加] L2 scenarios/" "rc=$rc output: ${out:0:800}"
  fi
else
  _record_pass "[追加] L2: scenarios/ ディレクトリなし — スキップ"
fi
echo ""

# =========================================================================
# サマリー
# =========================================================================
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
