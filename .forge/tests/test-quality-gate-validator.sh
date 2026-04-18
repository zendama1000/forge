#!/bin/bash
# test-quality-gate-validator.sh — QualityGate バリデータテスト
#
# 使い方: bash .forge/tests/test-quality-gate-validator.sh
#
# 必須テスト振る舞い:
#   1. required_mechanical_gates: ['ffprobe_exists'] を含む QualityGate → 検証通過
#   2. required_mechanical_gates: [] の QualityGate → 検証失敗 + エラーに 'empty not allowed'
#   3. required_mechanical_gates フィールド欠落 → 検証失敗 + 'field required' エラー
#   4. 未知のゲート名（'magic_check'）を指定 → 検証失敗 + enum 違反エラー
#   5. ffprobe_exists/duration_check/size_threshold の 3 デフォルトゲート名は全て検証通過

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALIDATOR="${PROJECT_ROOT}/.forge/lib/quality-gate-validator.sh"
SCHEMA="${PROJECT_ROOT}/.forge/schemas/quality-gate-schema.json"
FIXTURE_DIR="${PROJECT_ROOT}/tests/fixtures/video/quality-gates"

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

# assert: 正常系（exit 0 期待）
assert_validator_pass() {
  local label="$1" file="$2"
  local out
  out=$(bash "$VALIDATOR" "$file" 2>&1)
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    _record_pass "$label (exit=0)"
  else
    _record_fail "$label" "expected exit 0, got $rc. output: ${out:0:300}"
  fi
}

# assert: 失敗系（exit 非0 期待）+ 出力にパターンが含まれること
assert_validator_fail() {
  local label="$1" file="$2" expected_pattern="$3"
  local out
  out=$(bash "$VALIDATOR" "$file" 2>&1)
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
echo -e "${BOLD}=== quality-gate バリデータテスト ===${NC}"
echo ""

# 必要ツール
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}"
  exit 2
fi

# 必須ファイル存在確認
for required in "$VALIDATOR" "$SCHEMA" \
                "$FIXTURE_DIR/valid.json" \
                "$FIXTURE_DIR/empty.json" \
                "$FIXTURE_DIR/missing.json" \
                "$FIXTURE_DIR/unknown-gate.json" \
                "$FIXTURE_DIR/all-default.json"; do
  if [ ! -f "$required" ]; then
    echo -e "${RED}ERROR: required file missing: $required${NC}"
    exit 2
  fi
done

echo -e "${BOLD}[preflight]${NC} validator + schema + 5 fixtures 存在確認 OK"
echo ""

# --- Group 0: Schema 自体の健全性 --------------------------------------
echo -e "${BOLD}[0] Schema 自体の健全性${NC}"
if jq empty "$SCHEMA" >/dev/null 2>&1; then
  _record_pass "schema ファイルが有効な JSON"
else
  _record_fail "schema ファイルが有効な JSON" "jq parse failed"
fi

# required_mechanical_gates.items.enum が3要素定義されていること
enum_count=$(jq '.properties.required_mechanical_gates.items.enum | length' "$SCHEMA" 2>/dev/null)
if [ "${enum_count:-0}" -eq 3 ]; then
  _record_pass "schema に required_mechanical_gates.items.enum が 3 要素定義されている"
else
  _record_fail "schema enum 要素数" "expected 3, got ${enum_count}"
fi

# enum に 3 デフォルト名が含まれていること
for gate in "ffprobe_exists" "duration_check" "size_threshold"; do
  if jq -e --arg g "$gate" '.properties.required_mechanical_gates.items.enum | index($g) != null' "$SCHEMA" >/dev/null 2>&1; then
    _record_pass "schema enum に '${gate}' が含まれる"
  else
    _record_fail "schema enum に '${gate}' が含まれる" "not found in enum"
  fi
done

# minItems が 1 に設定されていること（空配列禁止）
min_items=$(jq '.properties.required_mechanical_gates.minItems' "$SCHEMA" 2>/dev/null)
if [ "$min_items" = "1" ]; then
  _record_pass "schema の required_mechanical_gates.minItems が 1（空配列禁止）"
else
  _record_fail "schema minItems" "expected 1, got ${min_items}"
fi
echo ""

# --- Group 1: 正常系 -----------------------------------------------------
echo -e "${BOLD}[1] 正常系${NC}"

# behavior: required_mechanical_gates: ['ffprobe_exists'] を含む QualityGate → 検証通過
assert_validator_pass \
  "valid.json (['ffprobe_exists']) → 検証通過" \
  "$FIXTURE_DIR/valid.json"

# behavior: ffprobe_exists/duration_check/size_threshold の 3 デフォルトゲート名は全て検証通過
assert_validator_pass \
  "all-default.json (3 デフォルト全て) → 検証通過" \
  "$FIXTURE_DIR/all-default.json"
echo ""

# --- Group 2: 空配列禁止 -------------------------------------------------
echo -e "${BOLD}[2] 空配列禁止（minItems: 1）${NC}"

# behavior: required_mechanical_gates: [] の QualityGate → 検証失敗 + エラーメッセージに 'empty not allowed' を含む
assert_validator_fail \
  "empty.json ([]) → 失敗 + 'empty not allowed'" \
  "$FIXTURE_DIR/empty.json" \
  "empty not allowed"
echo ""

# --- Group 3: フィールド欠落 ---------------------------------------------
echo -e "${BOLD}[3] required_mechanical_gates フィールド欠落${NC}"

# behavior: required_mechanical_gates フィールド自体が欠落 → 検証失敗 + 'field required' エラー
assert_validator_fail \
  "missing.json (フィールド欠落) → 失敗 + 'field required'" \
  "$FIXTURE_DIR/missing.json" \
  "field required"
echo ""

# --- Group 4: enum 違反（未知ゲート名） ---------------------------------
echo -e "${BOLD}[4] 未知ゲート名（enum 違反）${NC}"

# behavior: 未知のゲート名（例: 'magic_check'）を指定 → 検証失敗 + enum 違反エラー
assert_validator_fail \
  "unknown-gate.json ('magic_check') → 失敗 + enum 違反" \
  "$FIXTURE_DIR/unknown-gate.json" \
  "enum violation"

# より厳密: 違反値 'magic_check' がエラーに含まれる
out=$(bash "$VALIDATOR" "$FIXTURE_DIR/unknown-gate.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "magic_check"; then
  _record_pass "[追加] unknown-gate: 違反値 'magic_check' がエラーに含まれる"
else
  _record_fail "[追加] unknown-gate: 違反値報告" "output: ${out:0:300}"
fi
echo ""

# --- Group 5: エッジケース -----------------------------------------------
echo -e "${BOLD}[5] エッジケース${NC}"

# [追加] 存在しないファイル → 失敗
out=$(bash "$VALIDATOR" "/nonexistent/path/qg.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] 存在しないファイル → 失敗 (exit=$rc)"
else
  _record_fail "[追加] 存在しないファイル" "expected non-zero exit"
fi

# [追加] 不正 JSON → 失敗
TMP_BAD_JSON=$(mktemp 2>/dev/null || echo "/tmp/qgv-bad-$$.json")
echo "this is not { valid json" > "$TMP_BAD_JSON"
out=$(bash "$VALIDATOR" "$TMP_BAD_JSON" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "not valid JSON|valid JSON"; then
  _record_pass "[追加] 不正 JSON → 失敗 + 'not valid JSON' メッセージ"
else
  _record_fail "[追加] 不正 JSON" "expected non-zero + 'not valid JSON'. output: ${out:0:200}"
fi
rm -f "$TMP_BAD_JSON"

# [追加] required_mechanical_gates が array でない（object） → 型エラーで失敗
TMP_OBJ_JSON=$(mktemp 2>/dev/null || echo "/tmp/qgv-obj-$$.json")
cat > "$TMP_OBJ_JSON" <<'EOF'
{
  "required_mechanical_gates": { "invalid": "object-not-array" }
}
EOF
out=$(bash "$VALIDATOR" "$TMP_OBJ_JSON" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "type error|must be array"; then
  _record_pass "[追加] 型が array でない → 型エラーで失敗"
else
  _record_fail "[追加] 型エラー検出" "output: ${out:0:300}"
fi
rm -f "$TMP_OBJ_JSON"
echo ""

# --- Group 6: 有効値の個別検証 ------------------------------------------
echo -e "${BOLD}[6] 有効値の個別検証（duration_check / size_threshold 単独）${NC}"

# duration_check 単独
TMP_DUR=$(mktemp 2>/dev/null || echo "/tmp/qgv-dur-$$.json")
echo '{"required_mechanical_gates":["duration_check"]}' > "$TMP_DUR"
out=$(bash "$VALIDATOR" "$TMP_DUR" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] duration_check 単独 → 検証通過"
else
  _record_fail "[追加] duration_check 単独" "exit=$rc. output: ${out:0:200}"
fi
rm -f "$TMP_DUR"

# size_threshold 単独
TMP_SIZE=$(mktemp 2>/dev/null || echo "/tmp/qgv-size-$$.json")
echo '{"required_mechanical_gates":["size_threshold"]}' > "$TMP_SIZE"
out=$(bash "$VALIDATOR" "$TMP_SIZE" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] size_threshold 単独 → 検証通過"
else
  _record_fail "[追加] size_threshold 単独" "exit=$rc. output: ${out:0:200}"
fi
rm -f "$TMP_SIZE"
echo ""

# --- Group 7: source 利用 ------------------------------------------------
echo -e "${BOLD}[7] source での利用${NC}"
(
  set +e
  source "$VALIDATOR"
  if declare -F validate_quality_gate >/dev/null; then
    validate_quality_gate "$FIXTURE_DIR/valid.json" >/dev/null 2>&1
    exit $?
  else
    exit 99
  fi
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] source 後に validate_quality_gate を呼び出せる"
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
