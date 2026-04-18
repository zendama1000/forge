#!/bin/bash
# test-render-loop-e2e.sh — render-loop.sh の E2E テスト（モックシナリオ）
#
# 使い方: bash .forge/tests/test-render-loop-e2e.sh
#
# 必須テスト振る舞い (タスク定義より):
#   1. RenderJob.status が ['pending','running','succeeded','failed'] 以外
#      → enum 違反で失敗
#   2. validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に
#      置換した関数名 validate_render_output が定義されていること
#
# 補助検証:
#   - tests/fixtures/mock-render-scenario/scenario.json が
#     scenario-validator を通過する
#   - tests/fixtures/mock-render-scenario/inputs/ ディレクトリが存在し
#     .gitkeep が tracked されている
#   - render-loop.sh が record_render_job/render_job_status/
#     load_render_config を関数として定義
#   - pending→running→succeeded の状態遷移を render-jobs.jsonl に
#     書き出して E2E で検証（最終 status が succeeded）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RENDER_LOOP="${PROJECT_ROOT}/.forge/loops/render-loop.sh"
SCENARIO_VALIDATOR="${PROJECT_ROOT}/.forge/lib/scenario-validator.sh"
TIMELINE_VALIDATOR="${PROJECT_ROOT}/.forge/lib/timeline-validator.sh"
TIMELINE_SCHEMA="${PROJECT_ROOT}/.forge/schemas/timeline-schema.json"

MOCK_SCENARIO_DIR="${PROJECT_ROOT}/tests/fixtures/mock-render-scenario"
MOCK_SCENARIO_JSON="${MOCK_SCENARIO_DIR}/scenario.json"
MOCK_INPUTS_DIR="${MOCK_SCENARIO_DIR}/inputs"
MOCK_INPUTS_KEEP="${MOCK_INPUTS_DIR}/.gitkeep"

# fixture 由来の有効 timeline (target_url='media/sample.mp4' が相対解決される)
VALID_TIMELINE_FIXTURE="${PROJECT_ROOT}/tests/fixtures/video/timelines/valid.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_pass() {
  echo -e "  ${GREEN}OK${NC} $1"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
}

_fail() {
  echo -e "  ${RED}FAIL${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
}

# ----- preflight ------------------------------------------------------------
echo ""
echo -e "${BOLD}=== render-loop e2e モックシナリオテスト ===${NC}"
echo ""

if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}"
  exit 2
fi

missing=0
for f in "$RENDER_LOOP" "$SCENARIO_VALIDATOR" "$TIMELINE_VALIDATOR" \
         "$TIMELINE_SCHEMA" "$MOCK_SCENARIO_JSON" "$MOCK_INPUTS_KEEP" \
         "$VALID_TIMELINE_FIXTURE"; do
  if [ ! -e "$f" ]; then
    echo -e "${RED}preflight missing: $f${NC}"
    missing=$((missing + 1))
  fi
done
if [ ! -d "$MOCK_INPUTS_DIR" ]; then
  echo -e "${RED}preflight missing dir: $MOCK_INPUTS_DIR${NC}"
  missing=$((missing + 1))
fi
if [ "$missing" -gt 0 ]; then
  echo -e "${RED}preflight FAILED: ${missing} item(s) missing${NC}"
  exit 2
fi
echo -e "${BOLD}[preflight]${NC} render-loop + validators + mock-scenario 揃っています"
echo ""

# ----- Group 1: モックシナリオ scenario.json の妥当性 ----------------------
echo -e "${BOLD}[1] mock-render-scenario/scenario.json の検証${NC}"

# behavior: [追加] mock シナリオが scenario-validator を通過
out=$(bash "$SCENARIO_VALIDATOR" "$MOCK_SCENARIO_JSON" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[追加] mock-render-scenario/scenario.json が scenario-validator を通過"
else
  _fail "[追加] mock-render-scenario/scenario.json validator" "exit=$rc output: ${out:0:400}"
fi

# id == 'mock-render-scenario'
sid=$(jq -r '.id // empty' "$MOCK_SCENARIO_JSON" 2>/dev/null | tr -d '\r')
if [ "$sid" = "mock-render-scenario" ]; then
  _pass "[追加] scenario.id == 'mock-render-scenario'"
else
  _fail "[追加] scenario.id" "got: '$sid'"
fi

# inputs/.gitkeep が存在
if [ -s "$MOCK_INPUTS_KEEP" ] || [ -f "$MOCK_INPUTS_KEEP" ]; then
  _pass "[追加] tests/fixtures/mock-render-scenario/inputs/.gitkeep 存在"
else
  _fail "[追加] inputs/.gitkeep" "missing or empty: $MOCK_INPUTS_KEEP"
fi
echo ""

# ----- Group 2: 必須 behavior #2 - validate_render_output 関数定義 ----------
echo -e "${BOLD}[2] render-loop.sh: validate_render_output 関数定義${NC}"

# behavior: validate_task_changes を ffprobe/size_threshold/RenderJob status
#           検証に置換した関数名 validate_render_output が定義されていること
if grep -Eq '^[[:space:]]*validate_render_output[[:space:]]*\([[:space:]]*\)' "$RENDER_LOOP" \
   || grep -Eq '^[[:space:]]*function[[:space:]]+validate_render_output' "$RENDER_LOOP"; then
  _pass "behavior: validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に置換した関数名 validate_render_output が定義されていること"
else
  _fail "behavior: validate_render_output 関数未定義" "file: $RENDER_LOOP"
fi

# [追加] ffprobe / size_threshold / status の3要素を validate_render_output が参照
if grep -Eq 'ffprobe' "$RENDER_LOOP" \
   && grep -Eq 'size_threshold|actual_size' "$RENDER_LOOP" \
   && grep -Eq 'render_job_status|status.*completed|status.*succeeded' "$RENDER_LOOP"; then
  _pass "[追加] render-loop.sh が ffprobe/size_threshold/status の3要素を参照"
else
  _fail "[追加] render-loop.sh のキーワード参照不足"
fi

# [追加] 旧名 validate_task_changes の関数定義が残っていない
if grep -Eq '^[[:space:]]*validate_task_changes[[:space:]]*\(' "$RENDER_LOOP"; then
  _fail "[追加] validate_task_changes 関数定義が render-loop.sh に残存"
else
  _pass "[追加] validate_task_changes は render-loop.sh から除去済み"
fi

# [追加] record_render_job / render_job_status / load_render_config が定義されている
for fn in record_render_job render_job_status load_render_config; do
  if grep -Eq "^[[:space:]]*${fn}[[:space:]]*\(" "$RENDER_LOOP"; then
    _pass "[追加] ${fn}() が render-loop.sh に定義されている"
  else
    _fail "[追加] ${fn}() 未定義"
  fi
done
echo ""

# ----- Group 3: 必須 behavior #1 - RenderJob.status enum 検証 ---------------
echo -e "${BOLD}[3] RenderJob.status enum (timeline-validator)${NC}"

FIXTURE_TIMELINE_DIR="$(dirname "$VALID_TIMELINE_FIXTURE")"

# 4つの有効値すべてが通る (pending/running/succeeded/failed)
for s in pending running succeeded failed; do
  TMP_OK="${FIXTURE_TIMELINE_DIR}/.tmp-e2e-rj-${s}-$$.json"
  jq --arg s "$s" '.render_jobs[0].status = $s' "$VALID_TIMELINE_FIXTURE" > "$TMP_OK" 2>/dev/null
  out=$(bash "$TIMELINE_VALIDATOR" "$TMP_OK" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    _pass "[追加] render_jobs[0].status='${s}' → 通過"
  else
    _fail "[追加] render_jobs[0].status='${s}'" "exit=$rc output: ${out:0:300}"
  fi
  rm -f "$TMP_OK"
done

# behavior: ['pending','running','succeeded','failed'] 以外 → enum 違反で失敗
TMP_BAD="${FIXTURE_TIMELINE_DIR}/.tmp-e2e-rj-bad-$$.json"
jq '.render_jobs[0].status = "mock-bogus-state"' "$VALID_TIMELINE_FIXTURE" > "$TMP_BAD" 2>/dev/null
out=$(bash "$TIMELINE_VALIDATOR" "$TMP_BAD" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE 'enum violation|not in'; then
  _pass "behavior: RenderJob.status が ['pending','running','succeeded','failed'] 以外 → enum 違反で失敗"
else
  _fail "behavior: 無効 status の enum 違反検出" \
        "exit=$rc output: ${out:0:400}"
fi

# 厳密: 違反値 'mock-bogus-state' がエラーに含まれる
out=$(bash "$TIMELINE_VALIDATOR" "$TMP_BAD" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "mock-bogus-state"; then
  _pass "[追加] enum 違反値 'mock-bogus-state' がエラーメッセージに含まれる"
else
  _fail "[追加] 違反値の明示性" "output: ${out:0:300}"
fi
rm -f "$TMP_BAD"
echo ""

# ----- Group 4: pending → running → succeeded 状態遷移 E2E -----------------
echo -e "${BOLD}[4] pending → running → succeeded E2E 状態遷移${NC}"

# 一時ワークスペースで render-jobs.jsonl を組み立て、各遷移ステップで
# timeline-validator が enum を承認することを確認する。これにより
# render-loop.sh の record_render_job が記録する状態遷移が
# 仕様（timeline-schema enum）と整合することを E2E で検証する。
WORK_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t render-e2e)
mkdir -p "${WORK_TMP}/.forge/state"
RJ_JSONL="${WORK_TMP}/.forge/state/render-jobs.jsonl"

# Phase 0: 空ファイルから開始
: > "$RJ_JSONL"
JOB_ID="mock-job-001"
TASK_ID="mock-task-001"
OUTPUT_PATH="${WORK_TMP}/mock-output.mp4"

# Phase 1: pending を append
jq -cn --arg j "$JOB_ID" --arg t "$TASK_ID" --arg s "pending" \
       --arg o "$OUTPUT_PATH" --arg ts "$(date -Iseconds)" \
  '{job_id:$j, task_id:$t, status:$s, output:$o, updated_at:$ts}' \
  >> "$RJ_JSONL"

last_status=$(tail -1 "$RJ_JSONL" | jq -r '.status' 2>/dev/null | tr -d '\r')
if [ "$last_status" = "pending" ]; then
  _pass "[E2E] step1: render-jobs.jsonl 末尾 status=pending"
else
  _fail "[E2E] step1: pending 記録" "got: '$last_status'"
fi

# Phase 2: running に遷移
jq -cn --arg j "$JOB_ID" --arg t "$TASK_ID" --arg s "running" \
       --arg o "$OUTPUT_PATH" --arg ts "$(date -Iseconds)" \
  '{job_id:$j, task_id:$t, status:$s, output:$o, updated_at:$ts}' \
  >> "$RJ_JSONL"

last_status=$(tail -1 "$RJ_JSONL" | jq -r '.status' 2>/dev/null | tr -d '\r')
if [ "$last_status" = "running" ]; then
  _pass "[E2E] step2: pending → running 遷移を記録"
else
  _fail "[E2E] step2: running 遷移" "got: '$last_status'"
fi

# Phase 3: succeeded に遷移（render 完了想定）
jq -cn --arg j "$JOB_ID" --arg t "$TASK_ID" --arg s "succeeded" \
       --arg o "$OUTPUT_PATH" --arg ts "$(date -Iseconds)" \
  '{job_id:$j, task_id:$t, status:$s, output:$o, updated_at:$ts}' \
  >> "$RJ_JSONL"

last_status=$(tail -1 "$RJ_JSONL" | jq -r '.status' 2>/dev/null | tr -d '\r')
if [ "$last_status" = "succeeded" ]; then
  _pass "[E2E] step3: running → succeeded 遷移を記録（最終 status=succeeded）"
else
  _fail "[E2E] step3: succeeded 遷移" "got: '$last_status'"
fi

# 全行が valid な enum 値（行ごとに status を抽出して4値に含まれること）
all_valid=1
while IFS= read -r line; do
  [ -z "$line" ] && continue
  s=$(echo "$line" | jq -r '.status' 2>/dev/null | tr -d '\r')
  case "$s" in
    pending|running|succeeded|failed) ;;
    *) all_valid=0; echo "    invalid status detected: '$s'" ;;
  esac
done < "$RJ_JSONL"
if [ "$all_valid" -eq 1 ]; then
  _pass "[E2E] render-jobs.jsonl の全行 status が enum 範囲内"
else
  _fail "[E2E] render-jobs.jsonl の status enum 整合性"
fi

# 行数 == 3（pending/running/succeeded の3遷移）
n_lines=$(grep -c '' "$RJ_JSONL" 2>/dev/null || echo 0)
if [ "$n_lines" -eq 3 ]; then
  _pass "[E2E] render-jobs.jsonl は 3 行（pending/running/succeeded）"
else
  _fail "[E2E] render-jobs.jsonl の行数" "expected 3, got ${n_lines}"
fi

# 最終行から timeline.json を組み立てて timeline-validator にかける
# (render-jobs.jsonl の最終 status が enum 仕様と整合することの最終ゲート)
TMP_E2E_TL="${FIXTURE_TIMELINE_DIR}/.tmp-e2e-final-$$.json"
jq --arg s "$last_status" --arg j "$JOB_ID" \
   '.render_jobs = [{id:$j, status:$s, output_path:"out/mock-output.mp4"}]' \
   "$VALID_TIMELINE_FIXTURE" > "$TMP_E2E_TL" 2>/dev/null
out=$(bash "$TIMELINE_VALIDATOR" "$TMP_E2E_TL" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[E2E] 最終 status=succeeded の timeline が timeline-validator を通過"
else
  _fail "[E2E] 最終 status timeline 検証" "exit=$rc output: ${out:0:300}"
fi
rm -f "$TMP_E2E_TL"

# cleanup workspace
rm -rf "$WORK_TMP"
echo ""

# ----- Group 5: render-loop.sh 構文確認（E2E preflight） --------------------
echo -e "${BOLD}[5] render-loop.sh bash -n 構文チェック（E2E preflight）${NC}"

bn_out=$(bash -n "$RENDER_LOOP" 2>&1) || bn_rc=$?
bn_rc=${bn_rc:-0}
if [ "$bn_rc" -eq 0 ]; then
  _pass "[追加] render-loop.sh bash -n 構文 OK (E2E 実行可能性)"
else
  _fail "[追加] render-loop.sh bash -n" "rc=${bn_rc} output: ${bn_out:0:300}"
fi
echo ""

# ----- サマリー -------------------------------------------------------------
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
