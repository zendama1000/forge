#!/bin/bash
# test-transcribe-backend.sh — transcribe.sh の Layer 1 / Layer 2 テスト
#
# 使い方: bash .forge/tests/test-transcribe-backend.sh
#
# 必須テスト振る舞い（task-stack.json 定義）:
#   1. ffprobe コマンドが存在しない環境 → 事前チェックで即エラー（assertion 実行前に検出）
#
# 追加テスト:
#   - バックエンド自動検出: whisper.cpp / ffmpeg_whisper / none のいずれかを返す
#   - whisper.cpp 優先 (両方利用可能時)
#   - ffmpeg_whisper fallback (whisper.cpp 欠落時)
#   - TRANSCRIBE_FORCE_BACKEND によるバックエンド固定
#   - 入力 wav 不在 → INPUT_MISSING (rc=4)
#   - 入力 wav 空 → INPUT_MISSING (rc=4)
#   - 両バックエンド欠落 → NO_BACKEND (rc=2)
#   - 正常系 (mock whisper.cpp + stub model) → srt 生成 + rc=0
#   - source 後に必要な関数が定義されている
#   - ffmpeg 7.x + whisper filter なし → detect は fallback しない
#   - ffmpeg 8.0 + whisper filter あり → ffmpeg_whisper 検出
#   - sample-10s.wav fixture を ffmpeg で生成 (存在しない場合のみ)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TR_LIB="${PROJECT_ROOT}/.forge/lib/transcribe.sh"
FIXTURE_DIR="${PROJECT_ROOT}/tests/fixtures/video"
SAMPLE_WAV="${FIXTURE_DIR}/sample-10s.wav"

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
echo -e "${BOLD}=== transcribe-backend テスト ===${NC}"
echo ""

# --- preflight ------------------------------------------------------------
if [ ! -f "$TR_LIB" ]; then
  echo -e "${RED}ERROR: library missing: $TR_LIB${NC}"
  exit 2
fi

for tool in bash sed awk grep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: required tool missing: $tool${NC}"
    exit 2
  fi
done

STAGE_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/tr-stage-$$")"
mkdir -p "${STAGE_DIR}/mocks"
mkdir -p "${STAGE_DIR}/out"

cleanup() {
  if [ -d "$STAGE_DIR" ]; then
    chmod -R u+rwX "$STAGE_DIR" 2>/dev/null || true
    rm -rf "$STAGE_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- mock bin 生成 helper ---
make_mock_bin() {
  local name="$1" body="$2"
  local p="${STAGE_DIR}/mocks/${name}"
  printf '#!/bin/bash\n%s\n' "$body" >"$p"
  chmod +x "$p"
  echo "$p"
}

# ---- mock ffprobe / ffmpeg / whisper ---------------------------------
MOCK_FFPROBE=$(make_mock_bin "ffprobe-ok" '
  # -version and any call succeed
  case "${1:-}" in
    -version) echo "ffprobe version 6.1.1"; exit 0 ;;
    *)        echo "{}"; exit 0 ;;
  esac
')

# ffmpeg-ok: version 7.1.0 (whisper filter NOT supported)
MOCK_FFMPEG_7=$(make_mock_bin "ffmpeg-7" '
  case "${1:-}" in
    -version)
      echo "ffmpeg version 7.1.0 Copyright (c) 2000-2024"
      exit 0
      ;;
  esac
  # -filters / any other: list filters WITHOUT whisper
  args="$*"
  case "$args" in
    *-filters*)
      echo " T.. scale            V->V       Scale the input video."
      echo " T.. volume           A->A       Change input volume."
      exit 0
      ;;
  esac
  # transcription call: fail (no whisper filter)
  exit 1
')

# ffmpeg-8: version 8.0 WITH whisper filter support (mock srt output)
MOCK_FFMPEG_8=$(make_mock_bin "ffmpeg-8" '
  case "${1:-}" in
    -version)
      echo "ffmpeg version 8.0 Copyright (c) 2000-2025"
      exit 0
      ;;
  esac
  args="$*"
  case "$args" in
    *-filters*)
      echo " T.. scale            V->V       Scale the input video."
      echo " T.. whisper          A->A       Transcribe audio using whisper.cpp."
      exit 0
      ;;
  esac
  # Transcription call — parse "destination=PATH" from -af and write a fake SRT
  dest=""
  for tok in "$@"; do
    case "$tok" in
      *destination=*)
        dest="${tok#*destination=}"
        dest="${dest%%:*}"
        ;;
    esac
  done
  if [ -n "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    printf "1\n00:00:00,000 --> 00:00:10,000\nmock ffmpeg whisper transcription\n\n" >"$dest"
  fi
  exit 0
')

# whisper.cpp mock: accepts -m model -f input -osrt -of prefix (or --output-srt --output-file)
MOCK_WHISPER=$(make_mock_bin "whisper-cpp" '
  prefix=""
  # parse -of PREFIX or --output-file PREFIX
  while [ $# -gt 0 ]; do
    case "$1" in
      -of|--output-file) prefix="$2"; shift 2;;
      *) shift;;
    esac
  done
  if [ -z "$prefix" ]; then
    exit 1
  fi
  mkdir -p "$(dirname "$prefix")"
  printf "1\n00:00:00,000 --> 00:00:10,000\nmock whisper.cpp transcription\n\n" >"${prefix}.srt"
  exit 0
')

# ---- model stub --------------------------------------------------------
STUB_MODEL="${STAGE_DIR}/mocks/ggml-base.bin"
# create a non-empty stub so transcribe_via_* treats it as "present"
printf 'GGML_STUB_MODEL\n' >"$STUB_MODEL"

# ---- sample wav fixture: generate via real ffmpeg if absent -----------
ensure_sample_wav() {
  if [ -s "$SAMPLE_WAV" ]; then return 0; fi
  mkdir -p "$FIXTURE_DIR"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -loglevel error -y -f lavfi \
      -i "sine=frequency=440:duration=10" \
      -ar 16000 -ac 1 "$SAMPLE_WAV" 2>/dev/null || true
  fi
  if [ ! -s "$SAMPLE_WAV" ]; then
    # Fallback: write a minimal RIFF/WAVE header (≈0.01s silence) so existence
    # checks succeed even when ffmpeg is unavailable at test time.
    printf 'RIFF$\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x80>\x00\x00\x00}\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00' \
      >"$SAMPLE_WAV" 2>/dev/null || true
  fi
}
ensure_sample_wav

echo -e "${BOLD}[preflight]${NC} library + mocks OK"
echo -e "  stage_dir: $STAGE_DIR"
echo -e "  sample_wav: $SAMPLE_WAV ($( [ -s "$SAMPLE_WAV" ] && echo "ok" || echo "missing" ))"
echo ""

# source lib once for function tests
# shellcheck disable=SC1090
source "$TR_LIB"
if ! declare -F transcribe_audio >/dev/null; then
  echo -e "${RED}ERROR: transcribe_audio not defined after source${NC}"
  exit 2
fi

# -------------------------------------------------------------------------
# Group 1: preflight (必須 behavior)
# -------------------------------------------------------------------------
echo -e "${BOLD}[1] ffprobe 欠落 preflight${NC}"

# behavior: ffprobe コマンドが存在しない環境 → 事前チェックで即エラー（assertion 実行前に検出）
out=$(
  export TRANSCRIBE_FFPROBE_BIN="/does/not/exist/ffprobe-xyz"
  # even with a valid whisper backend available, preflight must short-circuit
  export TRANSCRIBE_WHISPER_BIN="$MOCK_WHISPER"
  bash "$TR_LIB" "$SAMPLE_WAV" "${STAGE_DIR}/out/a.srt" "$STUB_MODEL" 2>&1
)
rc=$?
if [ "$rc" -eq 3 ] && echo "$out" | grep -qE 'preflight failed.*ffprobe'; then
  _record_pass "behavior: ffprobe コマンドが存在しない環境 → 事前チェックで即エラー（assertion 実行前に検出）"
else
  _record_fail "behavior: ffprobe 欠落 → preflight fail (rc=3)" "rc=$rc out: ${out:0:400}"
fi

# [追加] preflight 関数単独で rc=1 を返す
(
  export TRANSCRIBE_FFPROBE_BIN="/does/not/exist/ffprobe"
  source "$TR_LIB" >/dev/null 2>&1
  ! transcribe_preflight 2>/dev/null
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] transcribe_preflight 単独: ffprobe 欠落時に rc=1"
else
  _record_fail "[追加] transcribe_preflight 単独 rc=1" "got rc=$rc"
fi

# [追加] preflight OK (ffprobe 存在) → rc=0
(
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_preflight 2>/dev/null
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] transcribe_preflight: ffprobe あり → rc=0"
else
  _record_fail "[追加] transcribe_preflight rc=0" "rc=$rc"
fi
echo ""

# -------------------------------------------------------------------------
# Group 2: バックエンド自動検出
# -------------------------------------------------------------------------
echo -e "${BOLD}[2] バックエンド自動検出${NC}"

# [追加] whisper.cpp あり → 'whisper_cpp'
out=$(
  export TRANSCRIBE_WHISPER_BIN="$MOCK_WHISPER"
  export TRANSCRIBE_FFMPEG_BIN="$MOCK_FFMPEG_7"
  export PATH="${STAGE_DIR}/mocks:$PATH"
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_detect_backend 2>/dev/null
)
if [ "$out" = "whisper_cpp" ]; then
  _record_pass "[追加] whisper.cpp あり → detect_backend='whisper_cpp' (優先)"
else
  _record_fail "[追加] whisper_cpp 検出" "got: '$out'"
fi

# [追加] whisper.cpp 欠落 + ffmpeg 8.0 whisper フィルタあり → 'ffmpeg_whisper'
out=$(
  unset TRANSCRIBE_WHISPER_BIN
  export TRANSCRIBE_FFMPEG_BIN="$MOCK_FFMPEG_8"
  # empty PATH so whisper-cli/whisper/main are NOT found
  export PATH="${STAGE_DIR}/empty:/usr/bin:/bin"
  mkdir -p "${STAGE_DIR}/empty"
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_detect_backend 2>/dev/null
)
if [ "$out" = "ffmpeg_whisper" ]; then
  _record_pass "[追加] whisper.cpp なし + ffmpeg 8.0 whisper フィルタあり → 'ffmpeg_whisper'"
else
  _record_fail "[追加] ffmpeg_whisper fallback" "got: '$out'"
fi

# [追加] whisper.cpp 欠落 + ffmpeg 7.x (whisper filter なし) → 'none'
out=$(
  unset TRANSCRIBE_WHISPER_BIN
  export TRANSCRIBE_FFMPEG_BIN="$MOCK_FFMPEG_7"
  export PATH="${STAGE_DIR}/empty:/usr/bin:/bin"
  mkdir -p "${STAGE_DIR}/empty"
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_detect_backend 2>/dev/null
)
if [ "$out" = "none" ]; then
  _record_pass "[追加] ffmpeg 7.x (whisper フィルタ無) → detect='none'"
else
  _record_fail "[追加] detect='none'" "got: '$out'"
fi

# [追加] TRANSCRIBE_FORCE_BACKEND='ffmpeg_whisper' で強制
out=$(
  export TRANSCRIBE_FORCE_BACKEND="ffmpeg_whisper"
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_detect_backend 2>/dev/null
)
if [ "$out" = "ffmpeg_whisper" ]; then
  _record_pass "[追加] TRANSCRIBE_FORCE_BACKEND による強制固定"
else
  _record_fail "[追加] FORCE_BACKEND" "got: '$out'"
fi

# [追加] transcribe_ffmpeg_has_whisper: 8.0 + filter → 0, 7.x → 1
(
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_ffmpeg_has_whisper "$MOCK_FFMPEG_8"
)
rc1=$?
(
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_ffmpeg_has_whisper "$MOCK_FFMPEG_7"
)
rc2=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -ne 0 ]; then
  _record_pass "[追加] transcribe_ffmpeg_has_whisper: 8.0 filter=yes / 7.x filter=no"
else
  _record_fail "[追加] has_whisper 判定" "8.0 rc=$rc1 / 7.x rc=$rc2"
fi
echo ""

# -------------------------------------------------------------------------
# Group 3: 入力バリデーション
# -------------------------------------------------------------------------
echo -e "${BOLD}[3] 入力バリデーション${NC}"

# [追加] 入力不在 → rc=4 (INPUT_MISSING)
out=$(
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  export TRANSCRIBE_WHISPER_BIN="$MOCK_WHISPER"
  bash "$TR_LIB" "${STAGE_DIR}/does-not-exist.wav" "${STAGE_DIR}/out/b.srt" "$STUB_MODEL" 2>&1
)
rc=$?
if [ "$rc" -eq 4 ] && echo "$out" | grep -qE 'input file not found'; then
  _record_pass "[追加] 入力 wav 不在 → rc=4 INPUT_MISSING + 明確なエラー"
else
  _record_fail "[追加] 入力不在 rc=4" "rc=$rc out: ${out:0:400}"
fi

# [追加] 入力が空ファイル → rc=4
EMPTY_WAV="${STAGE_DIR}/empty.wav"
: >"$EMPTY_WAV"
out=$(
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  export TRANSCRIBE_WHISPER_BIN="$MOCK_WHISPER"
  bash "$TR_LIB" "$EMPTY_WAV" "${STAGE_DIR}/out/c.srt" "$STUB_MODEL" 2>&1
)
rc=$?
if [ "$rc" -eq 4 ] && echo "$out" | grep -qE 'empty'; then
  _record_pass "[追加] 入力 wav 空 → rc=4"
else
  _record_fail "[追加] 空ファイル rc=4" "rc=$rc out: ${out:0:400}"
fi

# [追加] 引数不足 → rc=1
out=$(
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  bash "$TR_LIB" --preflight 2>&1
)
# --preflight は OK で rc=0。引数無しは help で rc=1。
out=$(bash "$TR_LIB" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE 'Usage:'; then
  _record_pass "[追加] 引数なし → help 表示 + rc=1"
else
  _record_fail "[追加] 引数なし help" "rc=$rc out: ${out:0:200}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 4: NO_BACKEND
# -------------------------------------------------------------------------
echo -e "${BOLD}[4] 両バックエンド欠落 → NO_BACKEND${NC}"

out=$(
  unset TRANSCRIBE_WHISPER_BIN
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  export TRANSCRIBE_FFMPEG_BIN="$MOCK_FFMPEG_7"
  export PATH="${STAGE_DIR}/empty:/usr/bin:/bin"
  mkdir -p "${STAGE_DIR}/empty"
  bash "$TR_LIB" "$SAMPLE_WAV" "${STAGE_DIR}/out/d.srt" "$STUB_MODEL" 2>&1
)
rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -qE 'no transcription backend'; then
  _record_pass "[追加] 両バックエンド欠落 → rc=2 NO_BACKEND + 明確なエラー"
else
  _record_fail "[追加] NO_BACKEND rc=2" "rc=$rc out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 5: 正常系 (mock whisper.cpp / ffmpeg_whisper で srt 生成)
# -------------------------------------------------------------------------
echo -e "${BOLD}[5] 正常系: srt 生成${NC}"

# [追加] whisper.cpp 経由で srt 生成
OUT_SRT_A="${STAGE_DIR}/out/whisper.srt"
out=$(
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  export TRANSCRIBE_WHISPER_BIN="$MOCK_WHISPER"
  bash "$TR_LIB" "$SAMPLE_WAV" "$OUT_SRT_A" "$STUB_MODEL" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && [ -s "$OUT_SRT_A" ] && grep -qE '00:00:00' "$OUT_SRT_A"; then
  _record_pass "[追加] 正常系 whisper.cpp: srt 生成 + rc=0"
else
  _record_fail "[追加] whisper.cpp 正常系" "rc=$rc srt_size=$(wc -c <"$OUT_SRT_A" 2>/dev/null || echo 0) out: ${out:0:400}"
fi

# [追加] ffmpeg_whisper 経由で srt 生成
OUT_SRT_B="${STAGE_DIR}/out/ffmpeg.srt"
out=$(
  unset TRANSCRIBE_WHISPER_BIN
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  export TRANSCRIBE_FFMPEG_BIN="$MOCK_FFMPEG_8"
  export PATH="${STAGE_DIR}/empty:/usr/bin:/bin"
  mkdir -p "${STAGE_DIR}/empty"
  bash "$TR_LIB" "$SAMPLE_WAV" "$OUT_SRT_B" "$STUB_MODEL" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && [ -s "$OUT_SRT_B" ] && grep -qE '00:00:00' "$OUT_SRT_B"; then
  _record_pass "[追加] 正常系 ffmpeg_whisper: srt 生成 + rc=0"
else
  _record_fail "[追加] ffmpeg_whisper 正常系" "rc=$rc srt_size=$(wc -c <"$OUT_SRT_B" 2>/dev/null || echo 0) out: ${out:0:500}"
fi

# [追加] モデル欠落時: stub SRT にフォールバックする (rc=0 + [transcription skipped] マーカー)
OUT_SRT_C="${STAGE_DIR}/out/stub.srt"
out=$(
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  export TRANSCRIBE_WHISPER_BIN="$MOCK_WHISPER"
  bash "$TR_LIB" "$SAMPLE_WAV" "$OUT_SRT_C" "/does/not/exist/model.bin" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && grep -qE 'transcription skipped' "$OUT_SRT_C"; then
  _record_pass "[追加] モデル欠落時: stub SRT にフォールバック + rc=0"
else
  _record_fail "[追加] stub SRT fallback" "rc=$rc out: ${out:0:400}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 6: CLI --detect / --preflight
# -------------------------------------------------------------------------
echo -e "${BOLD}[6] CLI --detect / --preflight${NC}"

out=$(
  export TRANSCRIBE_WHISPER_BIN="$MOCK_WHISPER"
  bash "$TR_LIB" --detect 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && [ "$(echo "$out" | tr -d '\r')" = "whisper_cpp" ]; then
  _record_pass "[追加] CLI --detect: whisper.cpp 検出 → stdout='whisper_cpp'"
else
  _record_fail "[追加] CLI --detect" "rc=$rc out: '$out'"
fi

out=$(
  export TRANSCRIBE_FFPROBE_BIN="$MOCK_FFPROBE"
  bash "$TR_LIB" --preflight 2>&1
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] CLI --preflight: ffprobe 存在 → rc=0"
else
  _record_fail "[追加] CLI --preflight ok" "rc=$rc out: ${out:0:200}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 7: source / 関数定義
# -------------------------------------------------------------------------
echo -e "${BOLD}[7] source / 関数定義${NC}"

(
  set +e
  source "$TR_LIB" >/dev/null 2>&1
  for fn in transcribe_audio transcribe_preflight transcribe_detect_backend \
            transcribe_version_ge transcribe_extract_ffmpeg_version \
            transcribe_ffmpeg_has_whisper transcribe_via_whisper_cpp \
            transcribe_via_ffmpeg_whisper; do
    if ! declare -F "$fn" >/dev/null; then
      echo "MISSING: $fn" >&2
      exit 1
    fi
  done
  exit 0
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] source 後に transcribe_* 主要関数が全て定義されている"
else
  _record_fail "[追加] source 関数定義" "rc=$rc"
fi

# [追加] transcribe_version_ge の比較論理
(
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_version_ge "8.0" "8.0" \
    && transcribe_version_ge "8.1" "8.0" \
    && transcribe_version_ge "9.0" "8.5" \
    && ! transcribe_version_ge "7.9" "8.0" \
    && ! transcribe_version_ge "7.0" "8.0"
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] transcribe_version_ge: 比較論理正しい"
else
  _record_fail "[追加] version_ge 比較" "rc=$rc"
fi

# [追加] transcribe_extract_ffmpeg_version
out=$(
  source "$TR_LIB" >/dev/null 2>&1
  transcribe_extract_ffmpeg_version "$MOCK_FFMPEG_8"
)
if [ "$out" = "8.0" ]; then
  _record_pass "[追加] transcribe_extract_ffmpeg_version: '8.0' を抽出"
else
  _record_fail "[追加] extract_ffmpeg_version" "got: '$out'"
fi
echo ""

# -------------------------------------------------------------------------
# Group 8: fixture チェック
# -------------------------------------------------------------------------
echo -e "${BOLD}[8] sample-10s.wav fixture${NC}"

if [ -s "$SAMPLE_WAV" ]; then
  _record_pass "[追加] sample-10s.wav fixture が存在し非空"
else
  _record_fail "[追加] sample-10s.wav" "path: $SAMPLE_WAV"
fi

# RIFF/WAVE マジック (fixture 構造最低限)
head_bytes=$(head -c 4 "$SAMPLE_WAV" 2>/dev/null || echo "")
if [ "$head_bytes" = "RIFF" ]; then
  _record_pass "[追加] sample-10s.wav が RIFF ヘッダを持つ (WAVE マジック検証)"
else
  _record_fail "[追加] RIFF ヘッダ" "head4='$head_bytes'"
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
