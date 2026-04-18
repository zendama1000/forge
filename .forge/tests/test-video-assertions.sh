#!/bin/bash
# test-video-assertions.sh — video-assertions.sh の Layer 1 テスト
#
# 使い方: bash .forge/tests/test-video-assertions.sh
#
# 必須テスト振る舞い（required_behaviors）:
#   1. ffprobe_exists: 'output.mp4' 指定 + ファイル存在 → 評価 PASS
#   2. ffprobe_exists: 存在しないパス → 評価 FAIL + 明確なエラーメッセージ
#   3. duration_check: expected=60, tolerance=2, 実 duration=61 → PASS
#   4. duration_check: expected=60, tolerance=2, 実 duration=65 → FAIL + 差分値を報告
#   5. size_threshold: min_bytes=1000, 実サイズ=500 → FAIL
#   6. 未知の assertion type 'magic_gate' → TypeError で拒否
#   7. ffprobe コマンドが存在しない環境 → 事前チェックで即エラー（assertion 実行前に検出）
#
# 設計:
#   実環境での ffprobe 有無に依存しない決定的なテストにするため、テスト実行時に
#   Mock ffprobe を temp dir に生成し PATH の先頭に差し込む。
#   Mock はファイル名の末尾で挙動を変える:
#     - ok.mp4       → duration 61 / show_format 成功
#     - long65.mp4   → duration 65 / show_format 成功
#     - *.mp4        → duration 60 / show_format 成功（fallback）
#     - *.txt 他     → show_format / duration とも失敗（非動画扱い）
#   behavior #7（ffprobe 不在）は PATH を空にしたサブシェルで検証する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VA_LIB="${PROJECT_ROOT}/.forge/lib/video-assertions.sh"
FIXTURE_DIR="${PROJECT_ROOT}/tests/fixtures/video/assertions"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_record_pass() {
  echo -e "  ${GREEN}✓${NC} $1"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
}

_record_fail() {
  echo -e "  ${RED}✗${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
}

# --- preflight ------------------------------------------------------------
echo ""
echo -e "${BOLD}=== video-assertions テスト ===${NC}"
echo ""

if [ ! -f "$VA_LIB" ]; then
  echo -e "${RED}ERROR: library not found: $VA_LIB${NC}"
  exit 2
fi

for tool in jq awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: required tool not found: $tool${NC}"
    exit 2
  fi
done

mkdir -p "$FIXTURE_DIR"

# --- fixture setup --------------------------------------------------------
OK_MP4="${FIXTURE_DIR}/ok.mp4"
SMALL_MP4="${FIXTURE_DIR}/small.mp4"
MISSING_TXT="${FIXTURE_DIR}/missing.txt"
LONG_MP4="${FIXTURE_DIR}/long65.mp4"  # test 実行時に生成（committed fixture ではない）

# missing.txt: 非動画ファイル（ffprobe パース失敗のテスト用）
if [ ! -f "$MISSING_TXT" ]; then
  echo "placeholder text fixture for video-assertion tests (not a video)" > "$MISSING_TXT"
fi

# ok.mp4: 500-byte placeholder（Mock ffprobe がファイル内容を読まないので任意 bytes で OK）
if [ ! -f "$OK_MP4" ] || [ "$(wc -c <"$OK_MP4" 2>/dev/null | tr -d ' \r\n')" -lt 1 ]; then
  head -c 2048 /dev/urandom > "$OK_MP4" 2>/dev/null || dd if=/dev/urandom of="$OK_MP4" bs=1 count=2048 >/dev/null 2>&1
fi

# small.mp4: 500-byte placeholder（size_threshold FAIL テスト用 = 実サイズ 500）
# 既存ファイルがある場合も 500 bytes に正規化
if [ ! -f "$SMALL_MP4" ] || [ "$(wc -c <"$SMALL_MP4" 2>/dev/null | tr -d ' \r\n')" != "500" ]; then
  head -c 500 /dev/zero > "$SMALL_MP4" 2>/dev/null || dd if=/dev/zero of="$SMALL_MP4" bs=1 count=500 >/dev/null 2>&1
fi

# long65.mp4: temp fixture（committed 不要、test 実行時生成）
if [ ! -f "$LONG_MP4" ]; then
  head -c 1024 /dev/urandom > "$LONG_MP4" 2>/dev/null || dd if=/dev/urandom of="$LONG_MP4" bs=1 count=1024 >/dev/null 2>&1
fi

# --- Mock ffprobe bin -----------------------------------------------------
MOCK_BIN_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/va-mock-$$")"
mkdir -p "$MOCK_BIN_DIR"
cat > "${MOCK_BIN_DIR}/ffprobe" <<'MOCK_EOF'
#!/bin/bash
# Mock ffprobe for video-assertions tests. Deterministic by filename.
# Arg spec: last positional arg is the file path.
set -uo pipefail

# last arg = input file
file="${!#}"

# Determine mode by scanning args for -show_entries
mode="show_format"
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "-show_entries" ]; then
    j=$((i+1))
    if [ "$j" -le "$#" ] && [ "${!j}" = "format=duration" ]; then
      mode="duration"
    fi
  fi
done

if [ -z "$file" ] || [ ! -e "$file" ]; then
  echo "Mock ffprobe: file not found or not specified: '$file'" >&2
  exit 1
fi

basename_f="$(basename -- "$file")"

case "$mode" in
  duration)
    case "$basename_f" in
      ok.mp4)      echo "61.000000" ;;
      long65.mp4)  echo "65.000000" ;;
      *.mp4)       echo "60.000000" ;;
      *)
        echo "Mock ffprobe: not a recognized media container: '$file'" >&2
        exit 1
        ;;
    esac
    ;;
  show_format)
    case "$basename_f" in
      *.mp4) exit 0 ;;
      *)
        echo "Mock ffprobe: Invalid data found when processing input: '$file'" >&2
        exit 1
        ;;
    esac
    ;;
esac
MOCK_EOF
chmod +x "${MOCK_BIN_DIR}/ffprobe"

# Cleanup trap
cleanup() {
  rm -rf "$MOCK_BIN_DIR" 2>/dev/null || true
  rm -f "$LONG_MP4" 2>/dev/null || true
}
trap cleanup EXIT

# Mock を PATH の先頭に差し込む
export PATH="${MOCK_BIN_DIR}:${PATH}"

# Mock が機能することを確認
if ! command -v ffprobe >/dev/null 2>&1; then
  echo -e "${RED}ERROR: mock ffprobe failed to be placed on PATH${NC}"
  exit 2
fi

echo -e "${BOLD}[preflight]${NC} library + fixtures + mock ffprobe OK"
echo -e "  fixture_dir : $FIXTURE_DIR"
echo -e "  mock_ffprobe: ${MOCK_BIN_DIR}/ffprobe"
echo ""

# --- load library ---------------------------------------------------------
# shellcheck disable=SC1090
source "$VA_LIB"

# -------------------------------------------------------------------------
# Group 1: type checker
# -------------------------------------------------------------------------
echo -e "${BOLD}[1] type checker${NC}"

# behavior: 未知の assertion type 'magic_gate' → TypeError で拒否
out=$(evaluate_video_assertion "magic_gate" "dummy" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -qF "TypeError"; then
  _record_pass "behavior: 未知の assertion type 'magic_gate' → TypeError で拒否"
else
  _record_fail "behavior: 未知の assertion type 'magic_gate' → TypeError で拒否" \
    "expected rc=2 + 'TypeError' in output. rc=$rc. output: ${out:0:300}"
fi

# [追加] 既知 type は video_assertion_is_known_type で true を返す
for t in ffprobe_exists duration_check size_threshold; do
  if video_assertion_is_known_type "$t"; then
    _record_pass "[追加] '${t}' は既知 assertion type と判定される"
  else
    _record_fail "[追加] '${t}' should be known" "is_known_type returned non-zero"
  fi
done

# [追加] 未知 type は is_known_type で false
if ! video_assertion_is_known_type "magic_gate"; then
  _record_pass "[追加] 'magic_gate' は未知 assertion type と判定される"
else
  _record_fail "[追加] 'magic_gate' should be unknown" "is_known_type returned 0"
fi

# [追加] 空文字 type → TypeError (rc=2)
out=$(evaluate_video_assertion "" 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then
  _record_pass "[追加] 空文字 type → TypeError (rc=2)"
else
  _record_fail "[追加] 空文字 type" "expected rc=2, got $rc. output: ${out:0:200}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 2: ffprobe_exists
# -------------------------------------------------------------------------
echo -e "${BOLD}[2] ffprobe_exists${NC}"

# behavior: ffprobe_exists: 'output.mp4' 指定 + ファイル存在 → 評価 PASS
out=$(evaluate_video_assertion "ffprobe_exists" "$OK_MP4" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "behavior: ffprobe_exists: 'output.mp4' 指定 + ファイル存在 → 評価 PASS"
else
  _record_fail "behavior: ffprobe_exists PASS 系" "rc=$rc output: ${out:0:300}"
fi

# behavior: ffprobe_exists: 存在しないパス → 評価 FAIL + 明確なエラーメッセージ
out=$(evaluate_video_assertion "ffprobe_exists" "${FIXTURE_DIR}/nonexistent-xyz.mp4" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "FAIL|does not exist"; then
  _record_pass "behavior: ffprobe_exists: 存在しないパス → FAIL + 明確なエラーメッセージ"
else
  _record_fail "behavior: ffprobe_exists FAIL 系" "rc=$rc output: ${out:0:300}"
fi

# [追加] missing.txt（非動画ファイル） → ffprobe パース失敗で FAIL
out=$(evaluate_video_assertion "ffprobe_exists" "$MISSING_TXT" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "could not parse|FAIL"; then
  _record_pass "[追加] 非動画ファイル(missing.txt) → ffprobe パース失敗で FAIL"
else
  _record_fail "[追加] 非動画ファイル → FAIL 期待" "rc=$rc output: ${out:0:300}"
fi

# [追加] 空パス引数 → FAIL
out=$(evaluate_video_assertion "ffprobe_exists" "" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] 空パス引数 → FAIL"
else
  _record_fail "[追加] 空パス引数" "rc=$rc output: ${out:0:200}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 3: duration_check
# -------------------------------------------------------------------------
echo -e "${BOLD}[3] duration_check${NC}"

# behavior: duration_check: expected=60, tolerance=2, 実 duration=61 → PASS
out=$(evaluate_video_assertion "duration_check" "$OK_MP4" "60" "2" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qF "PASS"; then
  _record_pass "behavior: duration_check: expected=60, tolerance=2, 実 duration=61 → PASS"
else
  _record_fail "behavior: duration_check PASS 系" "rc=$rc output: ${out:0:300}"
fi

# behavior: duration_check: expected=60, tolerance=2, 実 duration=65 → FAIL + 差分値を報告
out=$(evaluate_video_assertion "duration_check" "$LONG_MP4" "60" "2" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "diff=" && echo "$out" | grep -qF "FAIL"; then
  _record_pass "behavior: duration_check: expected=60, tolerance=2, 実 duration=65 → FAIL + diff 報告"
else
  _record_fail "behavior: duration_check FAIL 系（diff 報告）" "rc=$rc output: ${out:0:400}"
fi

# [追加] duration_check FAIL 時の diff 値が 5（|65-60|）を含む
out=$(evaluate_video_assertion "duration_check" "$LONG_MP4" "60" "2" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "diff=5\."; then
  _record_pass "[追加] duration_check FAIL 時に diff=5.xxx が報告される"
else
  _record_fail "[追加] diff 値の具体値" "rc=$rc output: ${out:0:400}"
fi

# [追加] tolerance=0, actual=61 expected=60 → FAIL
out=$(evaluate_video_assertion "duration_check" "$OK_MP4" "60" "0" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] duration_check tol=0 境界: actual=61 expected=60 → FAIL"
else
  _record_fail "[追加] duration_check tol=0" "rc=$rc output: ${out:0:300}"
fi

# [追加] 引数不足（expected 欠落）→ FAIL
out=$(evaluate_video_assertion "duration_check" "$OK_MP4" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] duration_check 引数不足 → FAIL"
else
  _record_fail "[追加] duration_check 引数不足" "rc=$rc output: ${out:0:200}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 4: size_threshold
# -------------------------------------------------------------------------
echo -e "${BOLD}[4] size_threshold${NC}"

# behavior: size_threshold: min_bytes=1000, 実サイズ=500 → FAIL
out=$(evaluate_video_assertion "size_threshold" "$SMALL_MP4" "1000" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "below min_bytes|FAIL"; then
  _record_pass "behavior: size_threshold: min_bytes=1000, 実サイズ=500 → FAIL"
else
  _record_fail "behavior: size_threshold FAIL 系" "rc=$rc output: ${out:0:300}"
fi

# [追加] size_threshold FAIL メッセージに実サイズ 500 と min 1000 が含まれる
out=$(evaluate_video_assertion "size_threshold" "$SMALL_MP4" "1000" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "size=500" && echo "$out" | grep -qE "min_bytes=1000"; then
  _record_pass "[追加] size_threshold FAIL 詳細: size=500 と min_bytes=1000 両方報告"
else
  _record_fail "[追加] size_threshold 詳細メッセージ" "rc=$rc output: ${out:0:300}"
fi

# [追加] size_threshold PASS: min_bytes=100, 実サイズ=500 → PASS
out=$(evaluate_video_assertion "size_threshold" "$SMALL_MP4" "100" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] size_threshold min_bytes=100, actual=500 → PASS"
else
  _record_fail "[追加] size_threshold PASS 系" "rc=$rc output: ${out:0:300}"
fi

# [追加] size_threshold max_bytes 違反: size=2048, max_bytes=100 → FAIL
out=$(evaluate_video_assertion "size_threshold" "$OK_MP4" "0" "100" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "exceeds max_bytes|FAIL"; then
  _record_pass "[追加] size_threshold max_bytes 超過 → FAIL"
else
  _record_fail "[追加] size_threshold max_bytes" "rc=$rc output: ${out:0:300}"
fi

# [追加] 存在しないパス
out=$(evaluate_video_assertion "size_threshold" "${FIXTURE_DIR}/nope-xyz.bin" "100" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] size_threshold 存在しないパス → FAIL"
else
  _record_fail "[追加] size_threshold 不存在" "rc=$rc output: ${out:0:300}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 5: preflight — ffprobe 不在環境での即エラー
# -------------------------------------------------------------------------
echo -e "${BOLD}[5] preflight: ffprobe 不在環境${NC}"

# behavior: ffprobe コマンドが存在しない環境 → 事前チェックで即エラー（assertion 実行前に検出）
# 戦略: サブシェル内で PATH を存在しないパスのみに上書き → ffprobe 不可視化
# Mock ffprobe も MOCK_BIN_DIR 経由でしか解決されないので PATH 空なら両方消える。
out=$(
  export PROJECT_ROOT="$PROJECT_ROOT"
  export PATH="/no-such-path-for-va-test-$$"
  # shellcheck disable=SC1090
  source "$VA_LIB" 2>/dev/null
  evaluate_video_assertion ffprobe_exists "$OK_MP4" 2>&1
)
rc=$?
if [ "$rc" -eq 3 ] && echo "$out" | grep -qE "preflight failed|ffprobe not found"; then
  _record_pass "behavior: ffprobe 不在環境 → 事前チェックで即エラー (rc=3, preflight failed)"
else
  _record_fail "behavior: ffprobe 不在環境 preflight エラー" "rc=$rc output: ${out:0:400}"
fi

# [追加] duration_check も ffprobe 不在で rc=3
out=$(
  export PROJECT_ROOT="$PROJECT_ROOT"
  export PATH="/no-such-path-for-va-test-$$"
  # shellcheck disable=SC1090
  source "$VA_LIB" 2>/dev/null
  evaluate_video_assertion duration_check "$OK_MP4" "60" "2" 2>&1
)
rc=$?
if [ "$rc" -eq 3 ] && echo "$out" | grep -qE "preflight failed|ffprobe not found"; then
  _record_pass "[追加] duration_check: ffprobe 不在 → rc=3 + preflight failed"
else
  _record_fail "[追加] duration_check preflight" "rc=$rc output: ${out:0:400}"
fi

# [追加] size_threshold は ffprobe 不要なので PATH 空でも rc=0 or rc=1（preflight 起動しない）
out=$(
  export PROJECT_ROOT="$PROJECT_ROOT"
  # stat / wc は bash 環境に含まれる外部コマンドだが Git Bash の場合は /usr/bin に
  # ある。PATH を空にすると動かなくなるので、size_threshold の preflight 無関係性は
  # 「rc!=3 であること」（ffprobe preflight が発動しない）で判定する。
  export PATH="/no-such-path-for-va-test-$$"
  export PROJECT_ROOT="$PROJECT_ROOT"
  # shellcheck disable=SC1090
  source "$VA_LIB" 2>/dev/null
  evaluate_video_assertion size_threshold "$SMALL_MP4" "100" 2>&1
)
rc=$?
if [ "$rc" -ne 3 ]; then
  _record_pass "[追加] size_threshold は ffprobe 不在でも preflight(rc=3) 発動しない (rc=$rc)"
else
  _record_fail "[追加] size_threshold preflight 誤発動" "rc=$rc output: ${out:0:400}"
fi

# [追加] video_assertion_preflight 関数単体: ffprobe 不在なら rc!=0
out=$(
  export PROJECT_ROOT="$PROJECT_ROOT"
  export PATH="/no-such-path-for-va-test-$$"
  # shellcheck disable=SC1090
  source "$VA_LIB" 2>/dev/null
  video_assertion_preflight 2>&1
)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qF "ffprobe not found"; then
  _record_pass "[追加] video_assertion_preflight 関数: ffprobe 不在で rc!=0 + 'ffprobe not found'"
else
  _record_fail "[追加] preflight 関数単体" "rc=$rc output: ${out:0:300}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 6: source / CLI / 関数存在
# -------------------------------------------------------------------------
echo -e "${BOLD}[6] source / 関数定義${NC}"

(
  set +e
  # shellcheck disable=SC1090
  source "$VA_LIB" 2>/dev/null
  if declare -F evaluate_video_assertion >/dev/null \
     && declare -F evaluate_ffprobe_exists >/dev/null \
     && declare -F evaluate_duration_check >/dev/null \
     && declare -F evaluate_size_threshold >/dev/null \
     && declare -F video_assertion_is_known_type >/dev/null \
     && declare -F video_assertion_preflight >/dev/null; then
    exit 0
  fi
  exit 99
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] source 後に全 6 関数が定義されている"
else
  _record_fail "[追加] source 後関数定義" "rc=$rc"
fi

# [追加] CLI 実行（引数なし）→ usage を出して rc=2
out=$(bash "$VA_LIB" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -qF "Usage:"; then
  _record_pass "[追加] CLI 引数なし → Usage + rc=2"
else
  _record_fail "[追加] CLI usage" "rc=$rc output: ${out:0:300}"
fi

# [追加] CLI 経由で size_threshold を実行
out=$(bash "$VA_LIB" size_threshold "$SMALL_MP4" "100" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] CLI size_threshold 成功呼び出し → rc=0"
else
  _record_fail "[追加] CLI size_threshold" "rc=$rc output: ${out:0:300}"
fi
echo ""

# -------------------------------------------------------------------------
# サマリー
# -------------------------------------------------------------------------
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
