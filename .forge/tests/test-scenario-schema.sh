#!/bin/bash
# test-scenario-schema.sh — scenarios/{id}/scenario.json バリデータテスト
#
# 使い方: bash .forge/tests/test-scenario-schema.sh
#
# 必須テスト振る舞い:
#   1. scenarios/slideshow/scenario.json を schema 検証 → 成功（exit 0）
#   2. quality_gates 配列が空の scenario.json を検証 → 失敗 + 'required_mechanical_gates must not be empty' を含む
#   3. 必須フィールド id が欠落した scenario.json を検証 → 失敗 + 'id' フィールド名を含む
#   4. input_sources[] の type が未定義値 → 失敗 + enum 違反エラー
#   5. agent_prompt_patch が文字列でなくオブジェクト → 型エラーで失敗

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALIDATOR="${PROJECT_ROOT}/.forge/lib/scenario-validator.sh"
SCHEMA="${PROJECT_ROOT}/.forge/schemas/scenario-schema.json"
FIXTURE_DIR="${PROJECT_ROOT}/tests/fixtures/video/scenarios"
SLIDESHOW="${PROJECT_ROOT}/scenarios/slideshow/scenario.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

# --- helpers -------------------------------------------------------------
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

# バリデータを実行し、exit code と stderr を返す
run_validator() {
  local scenario="$1"
  # stderr を stdout に統合してキャプチャ、exit code を $? で取得
  bash "$VALIDATOR" "$scenario" 2>&1
}

# assert: 正常系（exit 0 期待）
assert_validator_pass() {
  local label="$1" scenario="$2"
  local out
  out=$(bash "$VALIDATOR" "$scenario" 2>&1)
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    _record_pass "$label (exit=0)"
  else
    _record_fail "$label" "expected exit 0, got $rc. output: ${out:0:300}"
  fi
}

# assert: 失敗系（exit 非0 期待）+ 出力にパターンが含まれること
assert_validator_fail() {
  local label="$1" scenario="$2" expected_pattern="$3"
  local out
  out=$(bash "$VALIDATOR" "$scenario" 2>&1)
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    _record_fail "$label" "expected non-zero exit, got 0. output: ${out:0:300}"
    return
  fi
  if echo "$out" | grep -qF "$expected_pattern"; then
    _record_pass "$label (exit=$rc, pattern matched)"
  else
    _record_fail "$label" "expected pattern '$expected_pattern' not found. output: ${out:0:400}"
  fi
}

# --- preflight -----------------------------------------------------------
echo ""
echo -e "${BOLD}=== scenario-schema バリデータテスト ===${NC}"
echo ""

# 必要ツール・ファイルの存在確認
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}"
  exit 2
fi

for required in "$VALIDATOR" "$SCHEMA" "$SLIDESHOW" \
                "$FIXTURE_DIR/valid.json" \
                "$FIXTURE_DIR/empty-gates.json" \
                "$FIXTURE_DIR/missing-id.json" \
                "$FIXTURE_DIR/bad-type.json" \
                "$FIXTURE_DIR/bad-patch.json"; do
  if [ ! -f "$required" ]; then
    echo -e "${RED}ERROR: required file missing: $required${NC}"
    exit 2
  fi
done

echo -e "${BOLD}[preflight]${NC} validator + schema + 5 fixtures + slideshow scenario 存在確認 OK"
echo ""

# --- Group 0: 基本整合性（schema 自体が valid JSON） ---------------------
echo -e "${BOLD}[0] Schema 自体の健全性${NC}"
if jq empty "$SCHEMA" >/dev/null 2>&1; then
  _record_pass "schema ファイルが有効な JSON"
else
  _record_fail "schema ファイルが有効な JSON" "jq parse failed"
fi
# scenario.type の enum が定義されていること
if jq -e '.properties.type.enum | type == "array" and length > 0' "$SCHEMA" >/dev/null 2>&1; then
  _record_pass "schema に scenario.type enum が定義されている"
else
  _record_fail "schema に scenario.type enum が定義されている" "enum not found or empty"
fi
# input_sources[].type の enum が定義されていること
if jq -e '.properties.input_sources.items.properties.type.enum | type == "array" and length > 0' "$SCHEMA" >/dev/null 2>&1; then
  _record_pass "schema に input_sources[].type enum が定義されている"
else
  _record_fail "schema に input_sources[].type enum が定義されている" "enum not found or empty"
fi
echo ""

# --- Group 1: 正常系 -----------------------------------------------------
echo -e "${BOLD}[1] 正常系（valid fixture + 実シナリオ）${NC}"

# behavior: scenarios/slideshow/scenario.json を schema 検証 → 成功（exit 0）
assert_validator_pass "scenarios/slideshow/scenario.json → 成功" "$SLIDESHOW"

# 追加: 純正常系フィクスチャも通ること
assert_validator_pass "[追加] valid.json フィクスチャ → 成功" "$FIXTURE_DIR/valid.json"
echo ""

# --- Group 2: quality_gates 空配列 ---------------------------------------
echo -e "${BOLD}[2] quality_gates.required_mechanical_gates が空${NC}"
# behavior: quality_gates 配列が空の scenario.json を検証 → 失敗 + 'required_mechanical_gates must not be empty' を含む
assert_validator_fail \
  "empty-gates.json → 失敗 + エラーメッセージに 'required_mechanical_gates must not be empty'" \
  "$FIXTURE_DIR/empty-gates.json" \
  "required_mechanical_gates must not be empty"
echo ""

# --- Group 3: 必須フィールド id 欠落 -------------------------------------
echo -e "${BOLD}[3] 必須フィールド id 欠落${NC}"
# behavior: 必須フィールド id が欠落した scenario.json を検証 → 失敗 + 'id' フィールド名を含む
assert_validator_fail \
  "missing-id.json → 失敗 + エラーに 'id' フィールド名を含む" \
  "$FIXTURE_DIR/missing-id.json" \
  "id"
# より厳密: "missing required field: 'id'" 相当を含むこと
out=$(bash "$VALIDATOR" "$FIXTURE_DIR/missing-id.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "missing.*required.*field.*['\"]?id['\"]?|required field.*id"; then
  _record_pass "[追加] missing-id: 'missing required field: id' 形式で報告されている"
else
  _record_fail "[追加] missing-id: エラーメッセージ形式" "output: ${out:0:300}"
fi
echo ""

# --- Group 4: input_sources[].type enum 違反 ----------------------------
echo -e "${BOLD}[4] input_sources[].type が未定義値${NC}"
# behavior: input_sources[] の type が未定義値（例: 'unknown_source'）→ 失敗 + enum 違反エラー
assert_validator_fail \
  "bad-type.json → 失敗 + enum 違反エラー" \
  "$FIXTURE_DIR/bad-type.json" \
  "enum violation"
# より厳密: unknown_source という値がエラーに含まれること
out=$(bash "$VALIDATOR" "$FIXTURE_DIR/bad-type.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "unknown_source"; then
  _record_pass "[追加] bad-type: 違反値 'unknown_source' がエラーに含まれる"
else
  _record_fail "[追加] bad-type: 違反値報告" "output: ${out:0:300}"
fi
echo ""

# --- Group 5: agent_prompt_patch 型エラー -------------------------------
echo -e "${BOLD}[5] agent_prompt_patch が文字列でなくオブジェクト${NC}"
# behavior: agent_prompt_patch が文字列でなくオブジェクト → 型エラーで失敗
assert_validator_fail \
  "bad-patch.json → 型エラーで失敗" \
  "$FIXTURE_DIR/bad-patch.json" \
  "agent_prompt_patch"
# より厳密: "type error" または "must be string" を含むこと
out=$(bash "$VALIDATOR" "$FIXTURE_DIR/bad-patch.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "type error|must be string"; then
  _record_pass "[追加] bad-patch: 型エラー表現が含まれる（'type error' or 'must be string'）"
else
  _record_fail "[追加] bad-patch: 型エラー表現" "output: ${out:0:300}"
fi
echo ""

# --- Group 6: エッジケース -----------------------------------------------
echo -e "${BOLD}[6] エッジケース（存在しないファイル・不正JSON）${NC}"
# behavior: [追加] 存在しないファイル → 失敗
out=$(bash "$VALIDATOR" "/nonexistent/path/scenario.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] 存在しないファイル → 失敗 (exit=$rc)"
else
  _record_fail "[追加] 存在しないファイル" "expected non-zero exit"
fi

# behavior: [追加] 不正JSON → 失敗
TMP_BAD_JSON=$(mktemp 2>/dev/null || echo "/tmp/sv-bad-$$.json")
echo "this is not { valid json" > "$TMP_BAD_JSON"
out=$(bash "$VALIDATOR" "$TMP_BAD_JSON" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "not valid JSON|valid JSON"; then
  _record_pass "[追加] 不正JSON → 失敗 + 'not valid JSON' メッセージ"
else
  _record_fail "[追加] 不正JSON" "expected non-zero + 'not valid JSON'. output: ${out:0:200}"
fi
rm -f "$TMP_BAD_JSON"
echo ""

# --- Group 7: validator 関数が source 可能であること --------------------
echo -e "${BOLD}[7] source での利用${NC}"
(
  set +e
  # サブシェルで source + 関数呼び出し
  source "$VALIDATOR"
  if declare -F validate_scenario_json >/dev/null; then
    validate_scenario_json "$SLIDESHOW" >/dev/null 2>&1
    exit $?
  else
    exit 99
  fi
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] source 後に validate_scenario_json を呼び出せる"
else
  _record_fail "[追加] source 後の関数呼び出し" "exit=$rc"
fi
echo ""

# --- サマリー ------------------------------------------------------------
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
