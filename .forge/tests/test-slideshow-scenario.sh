#!/bin/bash
# test-slideshow-scenario.sh — scenarios/slideshow/ の L1 テスト
#
# 使い方: bash .forge/tests/test-slideshow-scenario.sh
#
# 必須テスト振る舞い (タスク定義より):
#   1. scenarios/slideshow/scenario.json を schema 検証 → 成功（exit 0）
#   2. required_mechanical_gates: ['ffprobe_exists'] を含む QualityGate → 検証通過
#   3. ffprobe_exists/duration_check/size_threshold の 3 デフォルトゲート名は全て検証通過
#
# 補助チェック:
#   - agent_prompt_patch.md が存在し非空
#   - render.sh の bash 構文が正しい
#   - assets/ ディレクトリが存在する
#   - scenario.json.type == "image_slideshow"
#   - scenario.json.input_sources に image_dir ソースが最低 1 件
#   - scenario.json.quality_gates.required_mechanical_gates が非空 (object 形式)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SCENARIO_VALIDATOR="${PROJECT_ROOT}/.forge/lib/scenario-validator.sh"
QG_VALIDATOR="${PROJECT_ROOT}/.forge/lib/quality-gate-validator.sh"
SLIDESHOW_DIR="${PROJECT_ROOT}/scenarios/slideshow"
SLIDESHOW_JSON="${SLIDESHOW_DIR}/scenario.json"
AGENT_PATCH_MD="${SLIDESHOW_DIR}/agent_prompt_patch.md"
RENDER_SH="${SLIDESHOW_DIR}/render.sh"
ASSETS_DIR="${SLIDESHOW_DIR}/assets"

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
  mktemp 2>/dev/null || echo "/tmp/slides-$$-$RANDOM.json"
}

echo ""
echo -e "${BOLD}=== slideshow scenario L1 test ===${NC}"
echo ""

# --- preflight --------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}"
  exit 2
fi

missing=0
for required in "$SCENARIO_VALIDATOR" "$QG_VALIDATOR" "$SLIDESHOW_JSON" \
                "$AGENT_PATCH_MD" "$RENDER_SH"; do
  if [ ! -f "$required" ]; then
    echo -e "${RED}preflight: required file missing: $required${NC}"
    missing=$((missing + 1))
  fi
done
if [ ! -d "$ASSETS_DIR" ]; then
  echo -e "${RED}preflight: assets/ directory missing: $ASSETS_DIR${NC}"
  missing=$((missing + 1))
fi
if [ "$missing" -gt 0 ]; then
  echo -e "${RED}preflight FAILED: ${missing} item(s) missing${NC}"
  exit 2
fi
echo -e "${BOLD}[preflight]${NC} validators + scenario.json + agent_prompt_patch.md + render.sh + assets/ 存在 OK"
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

# --- Group 3: 必須 behavior #3 ---------------------------------------------
echo -e "${BOLD}[3] 3 デフォルトゲート全て (ffprobe_exists / duration_check / size_threshold)${NC}"
# behavior: ffprobe_exists/duration_check/size_threshold の 3 デフォルトゲート名は全て検証通過
TMP_ALL=$(_mktemp_json)
echo '{"required_mechanical_gates":["ffprobe_exists","duration_check","size_threshold"]}' > "$TMP_ALL"
out=$(bash "$QG_VALIDATOR" "$TMP_ALL" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "ffprobe_exists/duration_check/size_threshold の 3 デフォルトゲート名は全て検証通過"
else
  _fail "3-default QualityGate 検証" "exit=$rc output: ${out:0:400}"
fi
rm -f "$TMP_ALL"

# 個別の単独ゲートも通ること (強化)
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

# --- Group 4: 構造チェック (scenario.json) ---------------------------------
echo -e "${BOLD}[4] scenario.json 構造${NC}"

# [追加] scenario.type == "image_slideshow"
stype=$(jq -r '.type // empty' "$SLIDESHOW_JSON" 2>/dev/null | tr -d '\r')
if [ "$stype" = "image_slideshow" ]; then
  _pass "[追加] scenario.type == 'image_slideshow'"
else
  _fail "[追加] scenario.type" "got: '$stype'"
fi

# [追加] scenario.id == "slideshow"
sid=$(jq -r '.id // empty' "$SLIDESHOW_JSON" 2>/dev/null | tr -d '\r')
if [ "$sid" = "slideshow" ]; then
  _pass "[追加] scenario.id == 'slideshow'"
else
  _fail "[追加] scenario.id" "got: '$sid'"
fi

# [追加] input_sources に image_dir を最低 1 件含む
n_image_dir=$(jq '[.input_sources[]? | select(.type == "image_dir")] | length' "$SLIDESHOW_JSON" 2>/dev/null || echo 0)
if [ "${n_image_dir:-0}" -ge 1 ]; then
  _pass "[追加] input_sources に image_dir が最低 1 件存在"
else
  _fail "[追加] input_sources に image_dir" "count=${n_image_dir}"
fi

# [追加] quality_gates.required_mechanical_gates が非空配列
n_gates=$(jq '.quality_gates.required_mechanical_gates | length' "$SLIDESHOW_JSON" 2>/dev/null || echo 0)
if [ "${n_gates:-0}" -ge 1 ]; then
  _pass "[追加] quality_gates.required_mechanical_gates が非空 (count=${n_gates})"
else
  _fail "[追加] quality_gates.required_mechanical_gates 非空" "count=${n_gates}"
fi

# [追加] agent_prompt_patch が文字列かつ非空
patch_type=$(jq -r '.agent_prompt_patch | type' "$SLIDESHOW_JSON" 2>/dev/null)
patch_len=$(jq -r '.agent_prompt_patch | length' "$SLIDESHOW_JSON" 2>/dev/null)
if [ "$patch_type" = "string" ] && [ "${patch_len:-0}" -gt 0 ]; then
  _pass "[追加] agent_prompt_patch は string 型かつ非空 (len=${patch_len})"
else
  _fail "[追加] agent_prompt_patch" "type=${patch_type} len=${patch_len}"
fi
echo ""

# --- Group 5: 付帯ファイル構造 ---------------------------------------------
echo -e "${BOLD}[5] 付帯ファイル (agent_prompt_patch.md / render.sh / assets/)${NC}"

# [追加] agent_prompt_patch.md が存在し非空
if [ -s "$AGENT_PATCH_MD" ]; then
  _pass "[追加] agent_prompt_patch.md 存在 + 非空"
else
  _fail "[追加] agent_prompt_patch.md" "file empty or missing"
fi

# [追加] render.sh が bash syntax OK
if bash -n "$RENDER_SH" 2>/dev/null; then
  _pass "[追加] render.sh bash syntax OK"
else
  _fail "[追加] render.sh bash syntax" "$(bash -n "$RENDER_SH" 2>&1 | head -3)"
fi

# [追加] render.sh が shebang を持つ
first_line=$(head -n1 "$RENDER_SH" 2>/dev/null)
if echo "$first_line" | grep -qE '^#!.*/(bash|sh)'; then
  _pass "[追加] render.sh shebang を持つ ($first_line)"
else
  _fail "[追加] render.sh shebang" "first line: $first_line"
fi

# [追加] render.sh が ffmpeg を呼ぶ
if grep -qE '(^|[^a-zA-Z])ffmpeg[[:space:]]' "$RENDER_SH"; then
  _pass "[追加] render.sh が ffmpeg を呼び出している"
else
  _fail "[追加] render.sh で ffmpeg 呼び出しが見つからない"
fi

# [追加] assets/ ディレクトリ存在
if [ -d "$ASSETS_DIR" ]; then
  _pass "[追加] assets/ ディレクトリ存在"
else
  _fail "[追加] assets/ ディレクトリ存在"
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
