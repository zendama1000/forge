#!/bin/bash
# test-llm-judge.sh — generate-summary.sh + llm-judge-runner.sh の Layer 1 テスト
#
# 使い方: bash .forge/tests/test-llm-judge.sh
#
# 必須テスト振る舞い（required_behaviors）:
#   1. timeline.json が 10MB 超 → サイズ警告を出力するが検証自体は通過（polish フェーズ対応）
#   2. RenderJob.status が ['pending','running','succeeded','failed'] 以外 → enum 違反で失敗
#
# 追加検証:
#   - generate_scenario_summary が valid fixture で summary.json を生成
#   - run_llm_judge がスタブ claude で result.json を生成（score >= 0.7 想定）
#   - run_llm_judge が claude 不在環境で graceful fallback（score=0, pass=false）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GENERATOR="${PROJECT_ROOT}/.forge/lib/generate-summary.sh"
RUNNER="${PROJECT_ROOT}/.forge/lib/llm-judge-runner.sh"
TEMPLATE="${PROJECT_ROOT}/.forge/templates/llm-judge-prompt.md"
VALIDATOR="${PROJECT_ROOT}/.forge/lib/timeline-validator.sh"
SCHEMA="${PROJECT_ROOT}/.forge/schemas/timeline-schema.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

_pass() { echo -e "  ${GREEN}OK${NC} $1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
_fail() { echo -e "  ${RED}FAIL${NC} $1"; [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

echo ""
echo -e "${BOLD}=== llm-judge + generate-summary テスト ===${NC}"
echo ""

# --- preflight -----------------------------------------------------------
for f in "$GENERATOR" "$RUNNER" "$TEMPLATE" "$VALIDATOR" "$SCHEMA"; do
  if [ ! -f "$f" ]; then
    echo -e "${RED}ERROR: required file missing: $f${NC}"
    exit 2
  fi
done
for tool in jq awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo -e "${RED}ERROR: $tool is required${NC}"; exit 2; }
done

# 一時作業領域（Windows /tmp 差異対策: bash(MSYS) 由来で生成→bash で読むので OK）
TMP_ROOT="$(mktemp -d 2>/dev/null || echo "/tmp/test-llm-judge-$$")"
mkdir -p "$TMP_ROOT"

cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

echo -e "${BOLD}[preflight]${NC} files + jq OK   (tmp=${TMP_ROOT})"
echo ""

# --- 共通: scenario.json 生成ヘルパ -------------------------------------
_mk_scenario_dir() {
  local root="$1" sid="$2" extra="$3"
  local dir="${root}/scenarios/${sid}"
  mkdir -p "$dir/out" "$dir/media"
  # 軽量 mp4 のダミー（ffprobe 不在環境では size だけ拾える）
  head -c 2048 /dev/urandom > "${dir}/media/sample.mp4" 2>/dev/null \
    || dd if=/dev/urandom of="${dir}/media/sample.mp4" bs=1 count=2048 >/dev/null 2>&1
  head -c 4096 /dev/urandom > "${dir}/out/output.mp4" 2>/dev/null \
    || dd if=/dev/urandom of="${dir}/out/output.mp4" bs=1 count=4096 >/dev/null 2>&1
  cat > "${dir}/scenario.json" <<EOF
{
  "id": "${sid}",
  "type": "image_slideshow",
  "version": "1.0.0",
  "description": "テスト用シナリオ",
  "intent": "静止画を 1920x1080 mp4 に変換",
  "target_format": "mp4",
  "expected_duration_sec": 15,
  "duration_tolerance_sec": 2,
  "input_sources": [
    { "type": "image_dir", "path": "media", "required": true }
  ],
  "quality_gates": {
    "required_mechanical_gates": [
      { "id": "output_exists", "command": "test -f out/output.mp4", "expect": "exit 0", "blocking": true }
    ]
  },
  "agent_prompt_patch": ""
  ${extra}
}
EOF
  echo "$dir"
}

# --- 共通: 有効 timeline.json を書き出し -------------------------------
_mk_valid_timeline() {
  local dir="$1"
  cat > "${dir}/timeline.json" <<'EOF'
{
  "id": "t1",
  "version": "1.0.0",
  "tracks": [
    {
      "id": "v1",
      "kind": "Video",
      "clips": [
        {
          "id": "c1",
          "source_range": { "start_time": 0, "duration": 5.0 },
          "media_reference": { "target_url": "media/sample.mp4" }
        }
      ]
    }
  ],
  "render_jobs": [
    { "id": "job-1", "status": "pending" }
  ]
}
EOF
}

# =========================================================================
# Group 1: generate_scenario_summary 基本動作
# =========================================================================
echo -e "${BOLD}[1] generate-summary 基本動作${NC}"

SCEN_OK=$(_mk_scenario_dir "$TMP_ROOT" "ok-scenario" "")
_mk_valid_timeline "$SCEN_OK"

out="$($GENERATOR "$SCEN_OK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "${SCEN_OK}/out/summary.json" ]; then
  _pass "valid scenario → exit 0, summary.json 生成"
else
  _fail "valid scenario" "rc=$rc out=${out:0:400}"
fi

# summary.json が valid JSON か
if [ -f "${SCEN_OK}/out/summary.json" ] && jq empty "${SCEN_OK}/out/summary.json" 2>/dev/null; then
  _pass "summary.json が valid JSON"
else
  _fail "summary.json valid JSON" "not valid"
fi

# 必須キー検証
if [ -f "${SCEN_OK}/out/summary.json" ]; then
  missing=""
  for key in scenario output timeline_validity mechanical_gates_summary errors warnings generated_at; do
    if ! jq -e "has(\"$key\")" "${SCEN_OK}/out/summary.json" >/dev/null 2>&1; then
      missing="${missing}${key} "
    fi
  done
  if [ -z "$missing" ]; then
    _pass "summary.json 必須キー（scenario/output/timeline_validity/...）存在"
  else
    _fail "summary.json 必須キー" "missing: ${missing}"
  fi
fi

# timeline_validity.ok=true の確認
if [ -f "${SCEN_OK}/out/summary.json" ]; then
  tl_ok=$(jq -r '.timeline_validity.ok' "${SCEN_OK}/out/summary.json" 2>/dev/null | tr -d '\r')
  if [ "$tl_ok" = "true" ]; then
    _pass "valid timeline: timeline_validity.ok=true"
  else
    _fail "valid timeline ok=true" "actual=${tl_ok}"
  fi
fi
echo ""

# =========================================================================
# Group 2: [behavior] timeline.json が 10MB 超 → サイズ警告を出力するが検証自体は通過（polish フェーズ対応）
# =========================================================================
# behavior: timeline.json が 10MB 超 → サイズ警告を出力するが検証自体は通過（polish フェーズ対応）
#
# 実装: 閾値 TIMELINE_SIZE_WARN_BYTES を 100 bytes に下げ、それを超える timeline.json を作成する。
#       実際に 10MB のファイルを作らずとも同一コードパスを通るため、テストは高速 & 決定的。
echo -e "${BOLD}[2] behavior: timeline.json が 10MB 超 → サイズ警告を出力するが検証自体は通過${NC}"

SCEN_BIG=$(_mk_scenario_dir "$TMP_ROOT" "big-timeline" "")
cat > "${SCEN_BIG}/timeline.json" <<'EOF'
{
  "id": "big",
  "version": "1.0.0",
  "padding": "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  "tracks": [
    {
      "id": "v1",
      "kind": "Video",
      "clips": [
        {
          "id": "c1",
          "source_range": { "start_time": 0, "duration": 5.0 },
          "media_reference": { "target_url": "media/sample.mp4" }
        }
      ]
    }
  ],
  "render_jobs": [
    { "id": "job-big", "status": "succeeded" }
  ]
}
EOF

# 閾値を 100 bytes に下げて走らせる（実 10MB を模倣）
out="$(TIMELINE_SIZE_WARN_BYTES=100 $GENERATOR "$SCEN_BIG" 2>&1)"; rc=$?

if [ "$rc" -eq 0 ]; then
  _pass "behavior: timeline.json が 10MB 超 → サイズ警告を出力するが検証自体は通過（polish フェーズ対応） [exit 0]"
else
  _fail "behavior: size-warn exit 0" "rc=$rc out=${out:0:500}"
fi

# 警告メッセージが出ているか（summary.warnings に含まれる）
if [ -f "${SCEN_BIG}/out/summary.json" ]; then
  warn_len=$(jq '.warnings | length' "${SCEN_BIG}/out/summary.json" 2>/dev/null | tr -d '\r')
  if [ "${warn_len:-0}" -gt 0 ]; then
    _pass "behavior: size-warn が summary.warnings に記録される (len=${warn_len})"
  else
    _fail "behavior: size-warn が summary.warnings に記録される" "warnings is empty. out=${out:0:500}"
  fi

  # サイズ警告パターン検出
  if jq -e '.warnings | map(select(test("threshold"; "i"))) | length >= 1' "${SCEN_BIG}/out/summary.json" >/dev/null 2>&1; then
    _pass "behavior: size-warn 本文に 'threshold' を含む"
  else
    _fail "behavior: size-warn pattern" "warnings=$(jq -c '.warnings' "${SCEN_BIG}/out/summary.json" 2>/dev/null)"
  fi

  # 検証自体は通過（ok=true）
  tl_ok=$(jq -r '.timeline_validity.ok' "${SCEN_BIG}/out/summary.json" 2>/dev/null | tr -d '\r')
  if [ "$tl_ok" = "true" ]; then
    _pass "behavior: size-warn でも timeline_validity.ok=true（検証自体は通過）"
  else
    _fail "behavior: size-warn ok=true" "actual=${tl_ok}"
  fi
fi
echo ""

# =========================================================================
# Group 3: [behavior] RenderJob.status が ['pending','running','succeeded','failed'] 以外 → enum 違反で失敗
# =========================================================================
# behavior: RenderJob.status が ['pending','running','succeeded','failed'] 以外 → enum 違反で失敗
echo -e "${BOLD}[3] behavior: RenderJob.status enum 違反 → 失敗${NC}"

SCEN_BAD=$(_mk_scenario_dir "$TMP_ROOT" "bad-status" "")
cat > "${SCEN_BAD}/timeline.json" <<'EOF'
{
  "id": "bad",
  "version": "1.0.0",
  "tracks": [
    {
      "id": "v1",
      "kind": "Video",
      "clips": [
        {
          "id": "c1",
          "source_range": { "start_time": 0, "duration": 5.0 },
          "media_reference": { "target_url": "media/sample.mp4" }
        }
      ]
    }
  ],
  "render_jobs": [
    { "id": "job-x", "status": "mystery-state" }
  ]
}
EOF

out="$($GENERATOR "$SCEN_BAD" 2>&1)"; rc=$?

# behavior: enum 違反で失敗（exit != 0）
if [ "$rc" -ne 0 ]; then
  _pass "behavior: RenderJob.status が ['pending','running','succeeded','failed'] 以外 → enum 違反で失敗 [exit != 0]"
else
  _fail "behavior: enum-fail exit" "rc=$rc out=${out:0:500}"
fi

# summary.json は書き出されている
if [ -f "${SCEN_BAD}/out/summary.json" ]; then
  _pass "enum 違反時も summary.json は書き出される（diagnostic 用）"

  # timeline_validity.ok=false
  tl_ok=$(jq -r '.timeline_validity.ok' "${SCEN_BAD}/out/summary.json" 2>/dev/null | tr -d '\r')
  if [ "$tl_ok" = "false" ]; then
    _pass "behavior: enum 違反 → timeline_validity.ok=false"
  else
    _fail "behavior: enum 違反 ok=false" "actual=${tl_ok}"
  fi

  # errors に enum 違反のメッセージが含まれる
  if jq -e '.timeline_validity.errors | map(select(test("enum|status"; "i"))) | length >= 1' "${SCEN_BAD}/out/summary.json" >/dev/null 2>&1; then
    _pass "behavior: enum-error が timeline_validity.errors に記録される"
  else
    _fail "behavior: enum-error pattern" "errors=$(jq -c '.timeline_validity.errors' "${SCEN_BAD}/out/summary.json" 2>/dev/null)"
  fi
else
  _fail "enum 違反時の summary.json 生成" "not found"
fi
echo ""

# =========================================================================
# Group 4: run_llm_judge — スタブ claude で成功パス
# =========================================================================
echo -e "${BOLD}[4] run_llm_judge — stub claude で成功${NC}"

# スタブ claude: 固定 JSON を stdout に流す
STUB_BIN="${TMP_ROOT}/stub-bin"
mkdir -p "$STUB_BIN"
cat > "${STUB_BIN}/claude" <<'STUB'
#!/bin/bash
# stub claude CLI — 固定 JSON を返して 0.7 以上のスコアをシミュレート
cat <<'JSON'
{
  "scenario_id": "ok-scenario",
  "score": 0.85,
  "pass": true,
  "criteria_scores": [
    {"criterion": "意図整合性", "score": 0.9, "rationale": "OK"},
    {"criterion": "機械ゲート合格", "score": 0.8, "rationale": "OK"}
  ],
  "overall_rationale": "概ね合格",
  "summary": "stub による固定出力"
}
JSON
# stdin を全部読み捨て
cat >/dev/null
exit 0
STUB
chmod +x "${STUB_BIN}/claude"

RESULT_OK="${TMP_ROOT}/.state/llm-judge-result.json"
PATH="${STUB_BIN}:${PATH}" out="$(PROJECT_ROOT="$PROJECT_ROOT" bash "$RUNNER" "$SCEN_OK" "$RESULT_OK" 2>&1)"; rc=$?

if [ "$rc" -eq 0 ] && [ -f "$RESULT_OK" ]; then
  _pass "stub claude → exit 0, result.json 生成"
else
  _fail "stub claude success path" "rc=$rc path=$RESULT_OK out=${out:0:400}"
fi

if [ -f "$RESULT_OK" ] && jq empty "$RESULT_OK" 2>/dev/null; then
  _pass "result.json が valid JSON"
  sc=$(jq -r '.score' "$RESULT_OK" 2>/dev/null | tr -d '\r')
  pass_flag=$(jq -r '.pass' "$RESULT_OK" 2>/dev/null | tr -d '\r')
  if awk -v s="$sc" 'BEGIN{ exit !(s+0 >= 0.7) }'; then
    _pass "result.score >= 0.7 (actual=${sc})"
  else
    _fail "result.score threshold" "score=${sc}"
  fi
  if [ "$pass_flag" = "true" ]; then
    _pass "result.pass=true"
  else
    _fail "result.pass=true" "actual=${pass_flag}"
  fi
fi
echo ""

# =========================================================================
# Group 5: run_llm_judge — claude 失敗時は graceful fallback
# =========================================================================
echo -e "${BOLD}[5] run_llm_judge — claude 失敗時の fallback${NC}"

# 「claude が非ゼロで落ちた」をシミュレートする stub を置く
# （PATH を削って jq/awk 等の必須ツールまで失うと runner 本体が動かないため、
#  stub で「見つかるが exit 127」を作って fallback 経路を厳密に再現する）
FAIL_BIN="${TMP_ROOT}/fail-bin"
mkdir -p "$FAIL_BIN"
cat > "${FAIL_BIN}/claude" <<'FAIL_STUB'
#!/bin/bash
# fallback-test stub: 存在はするが実行すると exit 127（claude 不在相当）
exit 127
FAIL_STUB
chmod +x "${FAIL_BIN}/claude"

RESULT_FB="${TMP_ROOT}/.state/llm-judge-fallback.json"
# 先頭に FAIL_BIN を差し込むことで、システムの実 claude より優先させる
out="$(PATH="${FAIL_BIN}:${PATH}" PROJECT_ROOT="$PROJECT_ROOT" bash "$RUNNER" "$SCEN_OK" "$RESULT_FB" 2>&1)"; rc=$?

if [ "$rc" -eq 0 ] && [ -f "$RESULT_FB" ]; then
  _pass "claude 失敗 → exit 0 (graceful)"
else
  _fail "fallback exit" "rc=$rc path=$RESULT_FB out=${out:0:400}"
fi

if [ -f "$RESULT_FB" ]; then
  sc=$(jq -r '.score' "$RESULT_FB" 2>/dev/null | tr -d '\r')
  pass_flag=$(jq -r '.pass' "$RESULT_FB" 2>/dev/null | tr -d '\r')
  fb=$(jq -r '.fallback // false' "$RESULT_FB" 2>/dev/null | tr -d '\r')
  if [ "$sc" = "0" ] || [ "$sc" = "0.0" ]; then
    _pass "fallback score=0.0"
  else
    _fail "fallback score=0.0" "actual=${sc}"
  fi
  if [ "$pass_flag" = "false" ]; then
    _pass "fallback pass=false"
  else
    _fail "fallback pass=false" "actual=${pass_flag}"
  fi
  if [ "$fb" = "true" ]; then
    _pass "fallback フィールドが true"
  else
    _fail "fallback=true" "actual=${fb}"
  fi
fi
echo ""

# =========================================================================
# Group 6: run_llm_judge — summary.json 欠落時の明示失敗
# =========================================================================
echo -e "${BOLD}[6] run_llm_judge — summary.json 不在で rc=1${NC}"

SCEN_NOSUM="${TMP_ROOT}/scenarios/no-summary"
mkdir -p "${SCEN_NOSUM}/out"
cp "${SCEN_OK}/scenario.json" "${SCEN_NOSUM}/scenario.json"

out="$(PROJECT_ROOT="$PROJECT_ROOT" bash "$RUNNER" "$SCEN_NOSUM" "${TMP_ROOT}/.state/nosum.json" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  _pass "summary.json 不在 → rc=1"
else
  _fail "summary.json 不在 rc=1" "rc=$rc out=${out:0:400}"
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
