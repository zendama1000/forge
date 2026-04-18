#!/bin/bash
# test-screen-recording.sh — scenarios/screen-recording/ の L1 テスト
#
# 使い方: bash .forge/tests/test-screen-recording.sh
#
# 必須テスト振る舞い（タスク定義より）:
#   1. scenarios/slideshow/scenario.json を schema 検証 → 成功（exit 0）
#   2. required_mechanical_gates: ['ffprobe_exists'] を含む QualityGate → 検証通過
#
# 補助チェック:
#   - scenarios/screen-recording/scenario.json が schema 検証 → 成功
#   - scenario.json.type == "screen_record"
#   - scenario.json.id == "screen-recording"
#   - input_sources に video_file ソースが最低 1 件
#   - quality_gates.required_mechanical_gates が非空
#   - agent_prompt_patch.md 存在 + 非空
#   - render.sh の bash 構文が正しい、shebang 有り、ffmpeg / transcribe.sh を呼び出す
#   - assets/ ディレクトリ存在 + sample.mp4 が 1 KB 以上（または後段で生成予定）
#   - ffprobe_exists / duration_check / size_threshold の 3 デフォルトゲート名が全て検証通過
#   - 3 ゲートそれぞれ単独で検証通過

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SCENARIO_VALIDATOR="${PROJECT_ROOT}/.forge/lib/scenario-validator.sh"
QG_VALIDATOR="${PROJECT_ROOT}/.forge/lib/quality-gate-validator.sh"

# 対象: screen-recording
SR_DIR="${PROJECT_ROOT}/scenarios/screen-recording"
SR_JSON="${SR_DIR}/scenario.json"
SR_PATCH_MD="${SR_DIR}/agent_prompt_patch.md"
SR_RENDER_SH="${SR_DIR}/render.sh"
SR_ASSETS_DIR="${SR_DIR}/assets"
SR_SAMPLE_MP4="${SR_ASSETS_DIR}/sample.mp4"

# 必須 behavior #1 の対象: slideshow の scenario.json
SLIDESHOW_JSON="${PROJECT_ROOT}/scenarios/slideshow/scenario.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
_fail() { echo -e "  ${RED}✗${NC} $1"; [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }

_mktemp_json() {
  mktemp 2>/dev/null || echo "/tmp/sr-$$-$RANDOM.json"
}

echo ""
echo -e "${BOLD}=== screen-recording scenario L1 test ===${NC}"
echo ""

# --- preflight --------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}"
  exit 2
fi

missing=0
for required in "$SCENARIO_VALIDATOR" "$QG_VALIDATOR" "$SR_JSON" \
                "$SR_PATCH_MD" "$SR_RENDER_SH" "$SLIDESHOW_JSON"; do
  if [ ! -f "$required" ]; then
    echo -e "${RED}preflight: required file missing: $required${NC}"
    missing=$((missing + 1))
  fi
done
if [ ! -d "$SR_ASSETS_DIR" ]; then
  echo -e "${RED}preflight: assets/ directory missing: $SR_ASSETS_DIR${NC}"
  missing=$((missing + 1))
fi
if [ "$missing" -gt 0 ]; then
  echo -e "${RED}preflight FAILED: ${missing} item(s) missing${NC}"
  exit 2
fi
echo -e "${BOLD}[preflight]${NC} validators + scenario.json (screen-recording/slideshow) + agent_prompt_patch.md + render.sh + assets/ 存在 OK"
echo ""

# --- Group 1: 必須 behavior #1 ---------------------------------------------
echo -e "${BOLD}[1] scenarios/slideshow/scenario.json schema 検証${NC}"
# behavior: scenarios/slideshow/scenario.json を schema 検証 → 成功（exit 0）
out=$(bash "$SCENARIO_VALIDATOR" "$SLIDESHOW_JSON" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "scenarios/slideshow/scenario.json を schema 検証 → 成功（exit 0）"
else
  _fail "scenarios/slideshow/scenario.json schema 検証" "exit=$rc output: ${out:0:400}"
fi
echo ""

# --- Group 2: 必須 behavior #2 ---------------------------------------------
echo -e "${BOLD}[2] QualityGate ['ffprobe_exists']${NC}"
# behavior: required_mechanical_gates: ['ffprobe_exists'] を含む QualityGate → 検証通過
TMP_ONE=$(_mktemp_json)
echo '{"required_mechanical_gates":["ffprobe_exists"]}' > "$TMP_ONE"
out=$(bash "$QG_VALIDATOR" "$TMP_ONE" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "required_mechanical_gates: ['ffprobe_exists'] を含む QualityGate → 検証通過"
else
  _fail "['ffprobe_exists'] QualityGate 検証" "exit=$rc output: ${out:0:400}"
fi
rm -f "$TMP_ONE"
echo ""

# --- Group 3: 3 デフォルトゲート全て --------------------------------------
echo -e "${BOLD}[3] 3 デフォルトゲート全て (ffprobe_exists / duration_check / size_threshold)${NC}"
# behavior: [追加] ffprobe_exists/duration_check/size_threshold の 3 デフォルトゲート名は全て検証通過
TMP_ALL=$(_mktemp_json)
echo '{"required_mechanical_gates":["ffprobe_exists","duration_check","size_threshold"]}' > "$TMP_ALL"
out=$(bash "$QG_VALIDATOR" "$TMP_ALL" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[追加] ffprobe_exists/duration_check/size_threshold の 3 デフォルトゲート名は全て検証通過"
else
  _fail "[追加] 3-default QualityGate 検証" "exit=$rc output: ${out:0:400}"
fi
rm -f "$TMP_ALL"

# 個別の単独ゲートも通ること
for g in ffprobe_exists duration_check size_threshold; do
  TMP_SINGLE=$(_mktemp_json)
  printf '{"required_mechanical_gates":["%s"]}\n' "$g" > "$TMP_SINGLE"
  out=$(bash "$QG_VALIDATOR" "$TMP_SINGLE" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    _pass "[追加] ${g} 単独 QualityGate → 検証通過"
  else
    _fail "[追加] ${g} 単独 QualityGate" "exit=$rc output: ${out:0:300}"
  fi
  rm -f "$TMP_SINGLE"
done
echo ""

# --- Group 4: screen-recording scenario.json 検証 ---------------------------
echo -e "${BOLD}[4] scenarios/screen-recording/scenario.json schema 検証${NC}"
# behavior: [追加] scenarios/screen-recording/scenario.json を schema 検証 → 成功
out=$(bash "$SCENARIO_VALIDATOR" "$SR_JSON" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[追加] scenarios/screen-recording/scenario.json を schema 検証 → 成功（exit 0）"
else
  _fail "[追加] scenarios/screen-recording/scenario.json schema 検証" "exit=$rc output: ${out:0:400}"
fi
echo ""

# --- Group 5: screen-recording scenario.json 構造 ---------------------------
echo -e "${BOLD}[5] screen-recording/scenario.json 構造${NC}"

# [追加] scenario.type == "screen_record"
stype=$(jq -r '.type // empty' "$SR_JSON" 2>/dev/null | tr -d '\r')
if [ "$stype" = "screen_record" ]; then
  _pass "[追加] scenario.type == 'screen_record'"
else
  _fail "[追加] scenario.type" "got: '$stype'"
fi

# [追加] scenario.id == "screen-recording"
sid=$(jq -r '.id // empty' "$SR_JSON" 2>/dev/null | tr -d '\r')
if [ "$sid" = "screen-recording" ]; then
  _pass "[追加] scenario.id == 'screen-recording'"
else
  _fail "[追加] scenario.id" "got: '$sid'"
fi

# [追加] input_sources に video_file を最低 1 件含む
n_video=$(jq '[.input_sources[]? | select(.type == "video_file")] | length' "$SR_JSON" 2>/dev/null || echo 0)
if [ "${n_video:-0}" -ge 1 ]; then
  _pass "[追加] input_sources に video_file が最低 1 件存在 (count=${n_video})"
else
  _fail "[追加] input_sources に video_file" "count=${n_video}"
fi

# [追加] quality_gates.required_mechanical_gates が非空配列
n_gates=$(jq '.quality_gates.required_mechanical_gates | length' "$SR_JSON" 2>/dev/null || echo 0)
if [ "${n_gates:-0}" -ge 1 ]; then
  _pass "[追加] quality_gates.required_mechanical_gates が非空 (count=${n_gates})"
else
  _fail "[追加] quality_gates.required_mechanical_gates 非空" "count=${n_gates}"
fi

# [追加] agent_prompt_patch (JSON 内) が string かつ非空
patch_type=$(jq -r '.agent_prompt_patch | type' "$SR_JSON" 2>/dev/null)
patch_len=$(jq -r '.agent_prompt_patch | length' "$SR_JSON" 2>/dev/null)
if [ "$patch_type" = "string" ] && [ "${patch_len:-0}" -gt 0 ]; then
  _pass "[追加] agent_prompt_patch は string 型かつ非空 (len=${patch_len})"
else
  _fail "[追加] agent_prompt_patch" "type=${patch_type} len=${patch_len}"
fi

# [追加] gate に output_exists 相当が 1 件以上
n_out_gates=$(jq '[.quality_gates.required_mechanical_gates[]? | select(.command | test("output\\.mp4"))] | length' "$SR_JSON" 2>/dev/null || echo 0)
if [ "${n_out_gates:-0}" -ge 1 ]; then
  _pass "[追加] required_mechanical_gates に output.mp4 検証ゲートが存在 (count=${n_out_gates})"
else
  _fail "[追加] required_mechanical_gates に output.mp4 検証ゲート" "count=${n_out_gates}"
fi

# [追加] gate に srt_nonempty 相当（subtitles.srt 参照）が 1 件以上
n_srt_gates=$(jq '[.quality_gates.required_mechanical_gates[]? | select(.command | test("subtitles\\.srt"))] | length' "$SR_JSON" 2>/dev/null || echo 0)
if [ "${n_srt_gates:-0}" -ge 1 ]; then
  _pass "[追加] required_mechanical_gates に subtitles.srt 検証ゲートが存在 (count=${n_srt_gates})"
else
  _fail "[追加] required_mechanical_gates に subtitles.srt 検証ゲート" "count=${n_srt_gates}"
fi
echo ""

# --- Group 6: 付帯ファイル (agent_prompt_patch.md / render.sh / assets/) ----
echo -e "${BOLD}[6] 付帯ファイル${NC}"

# [追加] agent_prompt_patch.md が存在し非空
if [ -s "$SR_PATCH_MD" ]; then
  _pass "[追加] agent_prompt_patch.md 存在 + 非空 ($(wc -c < "$SR_PATCH_MD" | tr -d ' ')B)"
else
  _fail "[追加] agent_prompt_patch.md" "file empty or missing"
fi

# [追加] render.sh が bash syntax OK
if bash -n "$SR_RENDER_SH" 2>/dev/null; then
  _pass "[追加] render.sh bash syntax OK"
else
  _fail "[追加] render.sh bash syntax" "$(bash -n "$SR_RENDER_SH" 2>&1 | head -3)"
fi

# [追加] render.sh が shebang を持つ
first_line=$(head -n1 "$SR_RENDER_SH" 2>/dev/null)
if echo "$first_line" | grep -qE '^#!.*/(bash|sh)'; then
  _pass "[追加] render.sh shebang を持つ ($first_line)"
else
  _fail "[追加] render.sh shebang" "first line: $first_line"
fi

# [追加] render.sh が ffmpeg を呼び出す
if grep -qE '(^|[^a-zA-Z])ffmpeg[[:space:]]' "$SR_RENDER_SH"; then
  _pass "[追加] render.sh が ffmpeg を呼び出している"
else
  _fail "[追加] render.sh で ffmpeg 呼び出しが見つからない"
fi

# [追加] render.sh が transcribe.sh を参照する
if grep -qE 'transcribe\.sh' "$SR_RENDER_SH"; then
  _pass "[追加] render.sh が .forge/lib/transcribe.sh を参照している"
else
  _fail "[追加] render.sh で transcribe.sh 参照が見つからない"
fi

# [追加] render.sh が subtitles フィルタを使う
if grep -qE 'subtitles=' "$SR_RENDER_SH" \
   || grep -qE '"subtitles' "$SR_RENDER_SH" \
   || grep -qE 'subtitles '"'" "$SR_RENDER_SH"; then
  _pass "[追加] render.sh が subtitles フィルタを使用"
else
  _fail "[追加] render.sh subtitles フィルタ" "'subtitles=' パターンが見つからない"
fi

# [追加] render.sh が TRIM_START / TRIM_DURATION をサポート
if grep -qE 'TRIM_START' "$SR_RENDER_SH" && grep -qE 'TRIM_DURATION' "$SR_RENDER_SH"; then
  _pass "[追加] render.sh が TRIM_START / TRIM_DURATION 変数をサポート"
else
  _fail "[追加] render.sh TRIM_START/TRIM_DURATION 参照なし"
fi

# [追加] assets/ ディレクトリ存在
if [ -d "$SR_ASSETS_DIR" ]; then
  _pass "[追加] assets/ ディレクトリ存在"
else
  _fail "[追加] assets/ ディレクトリ存在"
fi

# [追加] assets/sample.mp4 が 1 KB 以上
if [ -f "$SR_SAMPLE_MP4" ]; then
  sz=$(wc -c < "$SR_SAMPLE_MP4" | tr -d ' ')
  if [ "${sz:-0}" -ge 1024 ]; then
    _pass "[追加] assets/sample.mp4 存在 + 1KB 以上 (${sz}B)"
  else
    _fail "[追加] assets/sample.mp4 size" "got ${sz}B (need >=1024B)"
  fi
else
  _fail "[追加] assets/sample.mp4 存在"
fi
echo ""

# --- サマリー -------------------------------------------------------------
echo -e "${BOLD}=========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}=========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
