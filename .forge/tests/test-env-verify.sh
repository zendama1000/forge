#!/bin/bash
# test-env-verify.sh — env-verify.sh の Layer 1 テスト
#
# 使い方: bash .forge/tests/test-env-verify.sh
#
# 必須テスト振る舞い:
#   1. 全項目満たしたディレクトリ → check_video_prerequisites → exit 0
#   2. development.json server.start_command が 'none' 以外 → WARN（動画ハーネスでは不要）
#
# 追加テスト:
#   - ffmpeg 5.1 < 6.0 → FAIL + バージョン値報告
#   - ffmpeg 欠落 → FAIL
#   - ffprobe / convert / jq 欠落 → FAIL
#   - 4 ツール全欠落 → FAIL 4 行以上（fail-fast しない）
#   - ffmpeg = 6.0 境界 → PASS
#   - ffmpeg "n7.0" プレフィックス → PASS
#   - source 後に関数定義
#   - ev_version_ge の比較論理
#   - ev_extract_ffmpeg_version の抽出
#
# 設計:
#   - mock binary を tmp dir に配置して決定的にテスト
#   - mock は stdout に固定バージョン文字列を返す bash script
#   - 本物の jq は PATH の jq を使用（preflight 必須）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EV_LIB="${PROJECT_ROOT}/.forge/lib/env-verify.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_record_pass() {
  echo -e "  ${GREEN}OK${NC} $1"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
}

_record_fail() {
  echo -e "  ${RED}NG${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
}

echo ""
echo -e "${BOLD}=== env-verify テスト ===${NC}"
echo ""

# --- preflight ------------------------------------------------------------
if [ ! -f "$EV_LIB" ]; then
  echo -e "${RED}ERROR: library missing: $EV_LIB${NC}"
  exit 2
fi

for tool in bash jq sed awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: required tool missing: $tool${NC}"
    exit 2
  fi
done

STAGE_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/ev-stage-$$")"
mkdir -p "${STAGE_DIR}/mocks"

cleanup() {
  if [ -d "$STAGE_DIR" ]; then
    chmod -R u+rwX "$STAGE_DIR" 2>/dev/null || true
    rm -rf "$STAGE_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- mock bin 生成 helper ---
# $1: name（ファイル名）, $2: bash 本体スクリプト
make_mock_bin() {
  local name="$1" body="$2"
  local p="${STAGE_DIR}/mocks/${name}"
  printf '#!/bin/bash\n%s\n' "$body" >"$p"
  chmod +x "$p"
  echo "$p"
}

OK_FFMPEG=$(make_mock_bin "ffmpeg-ok"  'echo "ffmpeg version 6.1.1 Copyright (c) 2000-2023 the FFmpeg developers"; exit 0')
OK_FFPROBE=$(make_mock_bin "ffprobe-ok" 'echo "ffprobe version 6.1.1 Copyright (c) 2000-2023"; exit 0')
OK_CONVERT=$(make_mock_bin "convert-ok" 'echo "Version: ImageMagick 7.1.0-0 Q16"; exit 0')
OK_JQ="$(command -v jq)"

OLD_FFMPEG=$(make_mock_bin "ffmpeg-old" 'echo "ffmpeg version 5.1.0 Copyright (c) 2000-2022"; exit 0')
EQ_FFMPEG=$(make_mock_bin  "ffmpeg-eq"  'echo "ffmpeg version 6.0 Copyright (c) 2000-2023"; exit 0')
N_FFMPEG=$(make_mock_bin   "ffmpeg-n"   'echo "ffmpeg version n7.0 Copyright (c) 2000-2024"; exit 0')

# development.json mocks
DEV_OK="${STAGE_DIR}/dev-ok.json"
cat >"$DEV_OK" <<'EOF'
{
  "server": { "start_command": "none", "health_check_url": "none" }
}
EOF
DEV_BAD="${STAGE_DIR}/dev-bad.json"
cat >"$DEV_BAD" <<'EOF'
{
  "server": { "start_command": "npm run dev", "health_check_url": "http://localhost:3000" }
}
EOF

echo -e "${BOLD}[preflight]${NC} library + mocks OK"
echo -e "  stage_dir: $STAGE_DIR"
echo ""

# source test: 関数定義の確認
# shellcheck disable=SC1090
source "$EV_LIB"
if ! declare -F check_video_env >/dev/null; then
  echo -e "${RED}ERROR: check_video_env not defined after source${NC}"
  exit 2
fi

# -------------------------------------------------------------------------
# Group 1: 正常系（全ツール OK + start_command=none）
# -------------------------------------------------------------------------
echo -e "${BOLD}[1] 正常系: 全ツール OK${NC}"

out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
# behavior: 全項目満たしたディレクトリ → check_video_prerequisites → exit 0
if [ "$rc" -eq 0 ]; then
  _record_pass "behavior: 全項目満たしたディレクトリ → check_video_prerequisites → exit 0"
else
  _record_fail "behavior: 全項目満たしたディレクトリ → exit 0" "rc=$rc out: ${out:0:500}"
fi

# [追加] 正常系で FAIL / WARN が出ない
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE '^FAIL:|^WARN:'; then
  _record_pass "[追加] 正常系: FAIL / WARN 出力なし"
else
  _record_fail "[追加] 正常系 FAIL / WARN なし" "out: ${out:0:500}"
fi

# [追加] PASSED メッセージが出力される
if echo "$out" | grep -qE 'PASSED'; then
  _record_pass "[追加] 正常系: PASSED メッセージを含む"
else
  _record_fail "[追加] 正常系 PASSED メッセージ" "out: ${out:0:500}"
fi

# [追加] ffmpeg のバージョン値が OK ラインに含まれる
if echo "$out" | grep -qE '^OK: ffmpeg 6\.1\.1'; then
  _record_pass "[追加] 正常系: 'OK: ffmpeg 6.1.1' 行が出力される"
else
  _record_fail "[追加] OK: ffmpeg バージョン行" "out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 2: development.json server.start_command != 'none' → WARN
# -------------------------------------------------------------------------
echo -e "${BOLD}[2] server != 'none' → WARN${NC}"

out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_BAD"
  bash "$EV_LIB" 2>&1
)
rc=$?
# behavior: development.json server.start_command が 'none' 以外 → WARN（動画ハーネスでは不要）
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE "^WARN:.*start_command.*none"; then
  _record_pass "behavior: development.json server.start_command が 'none' 以外 → WARN（動画ハーネスでは不要）"
else
  _record_fail "behavior: server != 'none' WARN" "rc=$rc out: ${out:0:500}"
fi

# [追加] start_command='none' のとき WARN が出ない
out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE "^WARN:.*start_command"; then
  _record_pass "[追加] start_command='none' → start_command WARN 無し"
else
  _record_fail "[追加] start_command='none' 抑制" "rc=$rc out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 3: ffmpeg バージョンチェック
# -------------------------------------------------------------------------
echo -e "${BOLD}[3] ffmpeg バージョンゲート${NC}"

# 古いバージョン
out=$(
  export ENVV_FFMPEG_BIN="$OLD_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*ffmpeg.*5\.1.*6\.0'; then
  _record_pass "[追加] ffmpeg 5.1 < 6.0 → FAIL + 実測値と閾値を両方報告"
else
  _record_fail "[追加] ffmpeg 5.1 FAIL" "rc=$rc out: ${out:0:500}"
fi

# 境界ちょうど
out=$(
  export ENVV_FFMPEG_BIN="$EQ_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE '^FAIL:.*ffmpeg'; then
  _record_pass "[追加] ffmpeg = 6.0 境界 → PASS"
else
  _record_fail "[追加] ffmpeg 6.0 境界" "rc=$rc out: ${out:0:500}"
fi

# 'n' prefix バージョン
out=$(
  export ENVV_FFMPEG_BIN="$N_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] ffmpeg 'n7.0' prefix → PASS"
else
  _record_fail "[追加] ffmpeg n7.0 prefix" "rc=$rc out: ${out:0:500}"
fi

# ffmpeg 閾値上書き: ENVV_FFMPEG_MIN=7.0, 実測 6.1 → FAIL
out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  export ENVV_FFMPEG_MIN="7.0"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*ffmpeg.*6\.1.*7\.0'; then
  _record_pass "[追加] ENVV_FFMPEG_MIN=7.0 上書き + 実測 6.1.1 → FAIL"
else
  _record_fail "[追加] FFMPEG_MIN 上書き" "rc=$rc out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 4: 各ツール欠落
# -------------------------------------------------------------------------
echo -e "${BOLD}[4] 各ツール欠落 → FAIL${NC}"

# ffmpeg 欠落
out=$(
  export ENVV_FFMPEG_BIN="/does/not/exist/ffmpeg-xyz"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*ffmpeg.*not found'; then
  _record_pass "[追加] ffmpeg 欠落 → FAIL + 'ffmpeg not found' 報告"
else
  _record_fail "[追加] ffmpeg 欠落" "rc=$rc out: ${out:0:500}"
fi

# ffprobe 欠落
out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="/does/not/exist/ffprobe-xyz"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*ffprobe.*not found'; then
  _record_pass "[追加] ffprobe 欠落 → FAIL"
else
  _record_fail "[追加] ffprobe 欠落" "rc=$rc out: ${out:0:500}"
fi

# convert 欠落
out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="/does/not/exist/convert-xyz"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*convert.*not found'; then
  _record_pass "[追加] convert 欠落 → FAIL"
else
  _record_fail "[追加] convert 欠落" "rc=$rc out: ${out:0:500}"
fi

# jq 欠落
out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="/does/not/exist/jq-xyz"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*jq.*not found'; then
  _record_pass "[追加] jq 欠落 → FAIL"
else
  _record_fail "[追加] jq 欠落" "rc=$rc out: ${out:0:500}"
fi

# 4ツール全欠落 → fail-fast しない（全 FAIL 報告）
out=$(
  export ENVV_FFMPEG_BIN="/none/ffmpeg"
  export ENVV_FFPROBE_BIN="/none/ffprobe"
  export ENVV_CONVERT_BIN="/none/convert"
  export ENVV_JQ_BIN="/none/jq"
  export ENVV_DEV_JSON="$DEV_OK"
  bash "$EV_LIB" 2>&1
)
rc=$?
fail_lines=$(echo "$out" | grep -cE '^FAIL:' || true)
[ -z "$fail_lines" ] && fail_lines=0
if [ "$rc" -eq 1 ] && [ "$fail_lines" -ge 4 ]; then
  _record_pass "[追加] 4 ツール全欠落 → FAIL >=4 行 (fail-fast しない)"
else
  _record_fail "[追加] 4 ツール全欠落累積" "rc=$rc fails=$fail_lines out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 5: development.json エッジケース
# -------------------------------------------------------------------------
echo -e "${BOLD}[5] development.json エッジケース${NC}"

# development.json が存在しない → WARN（FAIL にはしない）
out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="${STAGE_DIR}/nonexistent-dev.json"
  bash "$EV_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE '^WARN:.*development\.json'; then
  _record_pass "[追加] development.json 不在 → WARN + exit 0 (FAIL にしない)"
else
  _record_fail "[追加] development.json 不在" "rc=$rc out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 6: source / 関数定義
# -------------------------------------------------------------------------
echo -e "${BOLD}[6] source / 関数定義${NC}"

(
  set +e
  # shellcheck disable=SC1090
  source "$EV_LIB" 2>/dev/null
  if declare -F check_video_env >/dev/null \
     && declare -F check_video_prerequisites >/dev/null \
     && declare -F ev_check_ffmpeg >/dev/null \
     && declare -F ev_check_ffprobe >/dev/null \
     && declare -F ev_check_convert >/dev/null \
     && declare -F ev_check_jq >/dev/null \
     && declare -F ev_check_dev_json_server_none >/dev/null \
     && declare -F ev_version_ge >/dev/null \
     && declare -F ev_extract_ffmpeg_version >/dev/null; then
    exit 0
  fi
  exit 99
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] source 後に必要な関数 (check_video_env, check_video_prerequisites, ev_*) が定義されている"
else
  _record_fail "[追加] source 後関数定義" "rc=$rc"
fi

# ev_version_ge の比較論理
(
  source "$EV_LIB" 2>/dev/null
  ev_version_ge "6.0" "6.0" \
    && ev_version_ge "6.1" "6.0" \
    && ev_version_ge "7.0" "6.5" \
    && ev_version_ge "6.1.1" "6.0" \
    && ! ev_version_ge "5.9" "6.0" \
    && ! ev_version_ge "5.1" "6.0" \
    && ! ev_version_ge "6.0" "6.1"
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] ev_version_ge: 比較論理（A>=B の true/false 両方向）が正しい"
else
  _record_fail "[追加] ev_version_ge 比較" "rc=$rc"
fi

# ev_extract_ffmpeg_version: 通常版
out=$(
  source "$EV_LIB" 2>/dev/null
  ev_extract_ffmpeg_version "$OK_FFMPEG"
)
if [ "$out" = "6.1.1" ]; then
  _record_pass "[追加] ev_extract_ffmpeg_version: '6.1.1' を抽出"
else
  _record_fail "[追加] ev_extract_ffmpeg_version (6.1.1)" "got: '$out'"
fi

# ev_extract_ffmpeg_version: n prefix 版
out=$(
  source "$EV_LIB" 2>/dev/null
  ev_extract_ffmpeg_version "$N_FFMPEG"
)
if [ "$out" = "7.0" ]; then
  _record_pass "[追加] ev_extract_ffmpeg_version: 'n7.0' → '7.0' を抽出"
else
  _record_fail "[追加] ev_extract_ffmpeg_version (n7.0)" "got: '$out'"
fi

# check_video_prerequisites (alias) が check_video_env にフォワードする
out=$(
  export ENVV_FFMPEG_BIN="$OK_FFMPEG"
  export ENVV_FFPROBE_BIN="$OK_FFPROBE"
  export ENVV_CONVERT_BIN="$OK_CONVERT"
  export ENVV_JQ_BIN="$OK_JQ"
  export ENVV_DEV_JSON="$DEV_OK"
  source "$EV_LIB" 2>/dev/null
  check_video_prerequisites 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE 'PASSED'; then
  _record_pass "[追加] check_video_prerequisites (alias) が env 検査にフォワードし PASSED"
else
  _record_fail "[追加] check_video_prerequisites alias" "rc=$rc out: ${out:0:400}"
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
