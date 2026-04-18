#!/bin/bash
# test-ai-avatar-plugin.sh — scenarios/ai-avatar/ plugin_interface 雛形の L1 テスト
#
# 使い方: bash .forge/tests/test-ai-avatar-plugin.sh
#
# 必須テスト振る舞い（タスク定義より）:
#   1. agent_prompt_patch が文字列でなくオブジェクト → 型エラーで失敗
#   2. input_sources[] の type が未定義値（例: 'unknown_source'）→ 失敗 + enum 違反エラー
#
# 補助チェック:
#   - scenarios/ai-avatar/scenario.json が schema 検証 → 成功
#   - scenario.type == "ai_avatar"
#   - scenario.id == "ai-avatar"
#   - plugin_interface.provider が非空 string
#   - plugin_interface.required_env が非空配列
#   - plugin_interface.mock_runner が非空 string
#   - mock_runner.sh が bash syntax OK + shebang + exit 0 で完走
#   - agent_prompt_patch.md 存在 + 非空

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SCENARIO_VALIDATOR="${PROJECT_ROOT}/.forge/lib/scenario-validator.sh"

AA_DIR="${PROJECT_ROOT}/scenarios/ai-avatar"
AA_JSON="${AA_DIR}/scenario.json"
AA_PATCH_MD="${AA_DIR}/agent_prompt_patch.md"
AA_MOCK="${AA_DIR}/mock_runner.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_pass() { echo -e "  ${GREEN}OK${NC} $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
_fail() { echo -e "  ${RED}NG${NC} $1"; [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }

_mktemp_json() {
  mktemp 2>/dev/null || echo "/tmp/aa-$$-$RANDOM.json"
}

echo ""
echo -e "${BOLD}=== ai-avatar plugin_interface L1 test ===${NC}"
echo ""

# --- preflight --------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}"
  exit 2
fi

missing=0
for required in "$SCENARIO_VALIDATOR" "$AA_JSON" "$AA_PATCH_MD" "$AA_MOCK"; do
  if [ ! -f "$required" ]; then
    echo -e "${RED}preflight: required file missing: $required${NC}"
    missing=$((missing + 1))
  fi
done
if [ "$missing" -gt 0 ]; then
  echo -e "${RED}preflight FAILED: ${missing} item(s) missing${NC}"
  exit 2
fi
echo -e "${BOLD}[preflight]${NC} validator + scenario.json + mock_runner.sh + agent_prompt_patch.md 存在 OK"
echo ""

# --- Group 1: 必須 behavior #1 ---------------------------------------------
echo -e "${BOLD}[1] 必須: agent_prompt_patch が文字列でなくオブジェクト → 型エラーで失敗${NC}"
# behavior: agent_prompt_patch が文字列でなくオブジェクト → 型エラーで失敗
TMP_OBJ=$(_mktemp_json)
jq '.agent_prompt_patch = {"invalid":"this_must_be_string"}' "$AA_JSON" > "$TMP_OBJ"
out=$(bash "$SCENARIO_VALIDATOR" "$TMP_OBJ" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE 'type error.*agent_prompt_patch|agent_prompt_patch.*must be string'; then
  _pass "agent_prompt_patch が文字列でなくオブジェクト → 型エラーで失敗 (exit=$rc)"
else
  _fail "agent_prompt_patch object 型エラー検出" "exit=$rc output: ${out:0:400}"
fi
rm -f "$TMP_OBJ"
echo ""

# --- Group 2: 必須 behavior #2 ---------------------------------------------
echo -e "${BOLD}[2] 必須: input_sources[].type 未定義値 → 失敗 + enum 違反エラー${NC}"
# behavior: input_sources[] の type が未定義値（例: 'unknown_source'）→ 失敗 + enum 違反エラー
TMP_ENUM=$(_mktemp_json)
jq '.input_sources[0].type = "unknown_source"' "$AA_JSON" > "$TMP_ENUM"
out=$(bash "$SCENARIO_VALIDATOR" "$TMP_ENUM" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE 'enum violation.*input_sources.*unknown_source'; then
  _pass "input_sources[].type が未定義値 'unknown_source' → 失敗 + enum 違反エラー (exit=$rc)"
else
  _fail "input_sources[].type enum 違反検出" "exit=$rc output: ${out:0:400}"
fi
rm -f "$TMP_ENUM"
echo ""

# --- Group 3: scenario.json schema 検証 ------------------------------------
echo -e "${BOLD}[3] scenarios/ai-avatar/scenario.json schema 検証${NC}"
# behavior: [追加] scenarios/ai-avatar/scenario.json を schema 検証 → 成功（exit 0）
out=$(bash "$SCENARIO_VALIDATOR" "$AA_JSON" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[追加] scenarios/ai-avatar/scenario.json を schema 検証 → 成功（exit 0）"
else
  _fail "[追加] ai-avatar scenario.json schema 検証" "exit=$rc output: ${out:0:400}"
fi
echo ""

# --- Group 4: scenario.json 構造 -------------------------------------------
echo -e "${BOLD}[4] scenario.json 構造${NC}"

# [追加] scenario.type == "ai_avatar"
stype=$(jq -r '.type // empty' "$AA_JSON" 2>/dev/null | tr -d '\r')
if [ "$stype" = "ai_avatar" ]; then
  _pass "[追加] scenario.type == 'ai_avatar'"
else
  _fail "[追加] scenario.type" "got: '$stype'"
fi

# [追加] scenario.id == "ai-avatar"
sid=$(jq -r '.id // empty' "$AA_JSON" 2>/dev/null | tr -d '\r')
if [ "$sid" = "ai-avatar" ]; then
  _pass "[追加] scenario.id == 'ai-avatar'"
else
  _fail "[追加] scenario.id" "got: '$sid'"
fi

# [追加] quality_gates.required_mechanical_gates が非空配列
n_gates=$(jq '.quality_gates.required_mechanical_gates | length' "$AA_JSON" 2>/dev/null || echo 0)
if [ "${n_gates:-0}" -ge 1 ]; then
  _pass "[追加] quality_gates.required_mechanical_gates が非空 (count=${n_gates})"
else
  _fail "[追加] quality_gates.required_mechanical_gates 非空" "count=${n_gates}"
fi

# [追加] agent_prompt_patch は string 型かつ非空
patch_type=$(jq -r '.agent_prompt_patch | type' "$AA_JSON" 2>/dev/null)
patch_len=$(jq -r '.agent_prompt_patch | length' "$AA_JSON" 2>/dev/null)
if [ "$patch_type" = "string" ] && [ "${patch_len:-0}" -gt 0 ]; then
  _pass "[追加] agent_prompt_patch は string 型かつ非空 (len=${patch_len})"
else
  _fail "[追加] agent_prompt_patch" "type=${patch_type} len=${patch_len}"
fi
echo ""

# --- Group 5: plugin_interface 契約（L3-003 構造整合） --------------------
echo -e "${BOLD}[5] plugin_interface 契約${NC}"

# [追加] plugin_interface が object
pi_type=$(jq -r '.plugin_interface | type' "$AA_JSON" 2>/dev/null)
if [ "$pi_type" = "object" ]; then
  _pass "[追加] plugin_interface が object"
else
  _fail "[追加] plugin_interface 型" "got: $pi_type"
fi

# [追加] plugin_interface.provider が非空 string
prov=$(jq -r '.plugin_interface.provider // empty' "$AA_JSON" 2>/dev/null | tr -d '\r')
prov_type=$(jq -r '.plugin_interface.provider | type' "$AA_JSON" 2>/dev/null)
if [ "$prov_type" = "string" ] && [ -n "$prov" ]; then
  _pass "[追加] plugin_interface.provider が非空 string (='${prov}')"
else
  _fail "[追加] plugin_interface.provider" "type=${prov_type} val='${prov}'"
fi

# [追加] plugin_interface.required_env が array
renv_type=$(jq -r '.plugin_interface.required_env | type' "$AA_JSON" 2>/dev/null)
renv_len=$(jq '.plugin_interface.required_env | length' "$AA_JSON" 2>/dev/null || echo 0)
if [ "$renv_type" = "array" ] && [ "${renv_len:-0}" -ge 1 ]; then
  _pass "[追加] plugin_interface.required_env が array かつ非空 (len=${renv_len})"
else
  _fail "[追加] plugin_interface.required_env" "type=${renv_type} len=${renv_len}"
fi

# [追加] plugin_interface.mock_runner が非空 string
mock_val=$(jq -r '.plugin_interface.mock_runner // empty' "$AA_JSON" 2>/dev/null | tr -d '\r')
mock_type=$(jq -r '.plugin_interface.mock_runner | type' "$AA_JSON" 2>/dev/null)
if [ "$mock_type" = "string" ] && [ -n "$mock_val" ]; then
  _pass "[追加] plugin_interface.mock_runner が非空 string (='${mock_val}')"
else
  _fail "[追加] plugin_interface.mock_runner" "type=${mock_type} val='${mock_val}'"
fi

# [追加] L3-003 structural command が通る
l3_cmd_out=$(jq -e '.plugin_interface.provider and (.plugin_interface.required_env|type=="array") and .plugin_interface.mock_runner' "$AA_JSON" 2>&1)
l3_cmd_rc=$?
if [ "$l3_cmd_rc" -eq 0 ]; then
  _pass "[追加] L3-003 structural jq expression が exit 0"
else
  _fail "[追加] L3-003 structural jq expression" "rc=$l3_cmd_rc out=$l3_cmd_out"
fi
echo ""

# --- Group 6: mock_runner.sh -----------------------------------------------
echo -e "${BOLD}[6] mock_runner.sh${NC}"

# [追加] shebang
first_line=$(head -n1 "$AA_MOCK" 2>/dev/null)
if echo "$first_line" | grep -qE '^#!.*/(bash|sh)'; then
  _pass "[追加] mock_runner.sh shebang を持つ ($first_line)"
else
  _fail "[追加] mock_runner.sh shebang" "first line: $first_line"
fi

# [追加] bash syntax OK
if bash -n "$AA_MOCK" 2>/dev/null; then
  _pass "[追加] mock_runner.sh bash syntax OK"
else
  _fail "[追加] mock_runner.sh bash syntax" "$(bash -n "$AA_MOCK" 2>&1 | head -3)"
fi

# [追加] set -uo pipefail を宣言
if grep -qE 'set[[:space:]]+-[a-z]*u[a-z]*o|set[[:space:]]+-uo' "$AA_MOCK"; then
  _pass "[追加] mock_runner.sh で set -uo (または含む) が宣言されている"
else
  _fail "[追加] mock_runner.sh set -uo" "'set -uo' 相当パターンが見つからない"
fi

# [追加] jq を参照
if grep -qE '(^|[^a-zA-Z])jq[[:space:]]' "$AA_MOCK"; then
  _pass "[追加] mock_runner.sh が jq を参照している"
else
  _fail "[追加] mock_runner.sh jq 参照なし"
fi

# [追加] 実行完走（credentials 不在でも exit 0 — mock フォールバック）
out=$(bash "$AA_MOCK" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[追加] mock_runner.sh が exit 0 で完走"
else
  _fail "[追加] mock_runner.sh 実行" "exit=$rc output: ${out:0:400}"
fi

# [追加] 実行後に .tmp/mock_status.json が生成
STATUS_JSON="${AA_DIR}/.tmp/mock_status.json"
if [ -s "$STATUS_JSON" ] && jq -e '.status == "ok"' "$STATUS_JSON" >/dev/null 2>&1; then
  _pass "[追加] .tmp/mock_status.json が status=ok で生成されている"
else
  _fail "[追加] .tmp/mock_status.json 生成" "file size=$(wc -c < "$STATUS_JSON" 2>/dev/null || echo 0)B"
fi
echo ""

# --- Group 7: agent_prompt_patch.md ----------------------------------------
echo -e "${BOLD}[7] agent_prompt_patch.md${NC}"

if [ -s "$AA_PATCH_MD" ]; then
  _pass "[追加] agent_prompt_patch.md 存在 + 非空 ($(wc -c < "$AA_PATCH_MD" | tr -d ' ')B)"
else
  _fail "[追加] agent_prompt_patch.md" "file empty or missing"
fi

# [追加] plugin_interface 記述が md に含まれる
if grep -qE 'plugin_interface' "$AA_PATCH_MD"; then
  _pass "[追加] agent_prompt_patch.md が plugin_interface に言及"
else
  _fail "[追加] agent_prompt_patch.md plugin_interface 言及なし"
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
