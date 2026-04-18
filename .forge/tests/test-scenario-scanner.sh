#!/bin/bash
# test-scenario-scanner.sh — scenarios/ ディレクトリスキャナのテスト
#
# 使い方: bash .forge/tests/test-scenario-scanner.sh
#
# 必須テスト振る舞い:
#   1. scenarios/ 配下に 3 ディレクトリ（slideshow/screen-recording/ai-avatar）→ 検出数 3
#   2. scenario.json が欠落したディレクトリ → 警告を出すがスキップ（他のシナリオは検出）
#   3. 新規ディレクトリ scenarios/new-test/scenario.json を追加 → 再スキャンで検出数が +1
#   4. scenarios/ ディレクトリ自体が存在しない → エラーメッセージ + exit 非0
#   5. scenario.json 内の id がディレクトリ名と一致しない → 整合性エラー

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCANNER="${PROJECT_ROOT}/.forge/lib/scenario-scanner.sh"
FIXTURE_ROOT="${PROJECT_ROOT}/tests/fixtures/video/scanner"
OK_DIR="${FIXTURE_ROOT}/scenarios-ok"
MISSING_DIR="${FIXTURE_ROOT}/scenarios-missing-json"
MISMATCH_DIR="${FIXTURE_ROOT}/scenarios-mismatch-id"
EMPTY_DIR="${FIXTURE_ROOT}/scenarios-empty"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

# --- helpers --------------------------------------------------------------
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

# 一時ディレクトリ（cleanup は trap で）
TMP_WORK=""
cleanup() {
  if [ -n "$TMP_WORK" ] && [ -d "$TMP_WORK" ]; then
    rm -rf "$TMP_WORK"
  fi
}
trap cleanup EXIT

# --- preflight ------------------------------------------------------------
echo ""
echo -e "${BOLD}=== scenario-scanner テスト ===${NC}"
echo ""

if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}"
  exit 2
fi

for required in "$SCANNER" \
                "$OK_DIR/slideshow/scenario.json" \
                "$OK_DIR/screen-recording/scenario.json" \
                "$OK_DIR/ai-avatar/scenario.json" \
                "$MISSING_DIR/slideshow/scenario.json" \
                "$MISSING_DIR/screen-recording/scenario.json" \
                "$MISMATCH_DIR/slideshow/scenario.json"; do
  if [ ! -f "$required" ]; then
    echo -e "${RED}ERROR: required fixture missing: $required${NC}"
    exit 2
  fi
done

if [ ! -d "$MISSING_DIR/no-json-here" ]; then
  echo -e "${RED}ERROR: missing-json fixture must contain no-json-here/ directory${NC}"
  exit 2
fi

if [ ! -d "$EMPTY_DIR" ]; then
  echo -e "${RED}ERROR: empty fixture dir missing: $EMPTY_DIR${NC}"
  exit 2
fi

echo -e "${BOLD}[preflight]${NC} scanner + 4 fixture dirs 確認 OK"
echo ""

# =========================================================================
# Group 0: scanner ファイル自体の基本整合性
# =========================================================================
echo -e "${BOLD}[0] scanner ファイルの健全性${NC}"
if bash -n "$SCANNER" 2>/dev/null; then
  _record_pass "scanner は bash 構文エラーなし (bash -n)"
else
  _record_fail "scanner bash 構文エラー" "$(bash -n "$SCANNER" 2>&1 | head -5)"
fi

# source 可能であること（関数が定義される）
(
  set +e
  source "$SCANNER" 2>/dev/null
  declare -F scan_scenarios_dir >/dev/null \
    && declare -F count_scenarios >/dev/null \
    && declare -F list_scenario_ids >/dev/null
)
if [ $? -eq 0 ]; then
  _record_pass "scanner は source 可能で 3 つの public 関数を定義する"
else
  _record_fail "scanner source 後に public 関数が定義されていない"
fi
echo ""

# =========================================================================
# Group 1: 正常系 — 3 ディレクトリ → 検出数 3
# =========================================================================
echo -e "${BOLD}[1] 正常系 (必須 behavior 1)${NC}"

# behavior: scenarios/ 配下に 3 ディレクトリ（slideshow/screen-recording/ai-avatar）→ 検出数 3
count=$(bash "$SCANNER" "$OK_DIR" --count 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$count" = "3" ]; then
  _record_pass "3 ディレクトリ → 検出数 3 (--count) [behavior 1]"
else
  _record_fail "3 ディレクトリ → 検出数 3" "rc=$rc, count=$count"
fi

# --json 出力の検証（配列長 3、id 3 つ）
json_out=$(bash "$SCANNER" "$OK_DIR" --json 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$(echo "$json_out" | jq 'length')" = "3" ]; then
  _record_pass "--json 出力が長さ 3 の配列 [behavior 1]"
else
  _record_fail "--json 出力長" "rc=$rc, got=$(echo "$json_out" | jq 'length' 2>/dev/null)"
fi

# --ids 出力に 3 シナリオが全て含まれる
ids_out=$(bash "$SCANNER" "$OK_DIR" --ids 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] \
   && echo "$ids_out" | grep -qx "slideshow" \
   && echo "$ids_out" | grep -qx "screen-recording" \
   && echo "$ids_out" | grep -qx "ai-avatar"; then
  _record_pass "--ids 出力に slideshow/screen-recording/ai-avatar が含まれる [behavior 1]"
else
  _record_fail "--ids 出力不備" "rc=$rc, got='${ids_out//$'\n'/,}'"
fi

# JSON 出力の各エントリに id/type/path キーが含まれる
if echo "$json_out" | jq -e 'all(.[]; has("id") and has("type") and has("path"))' >/dev/null 2>&1; then
  _record_pass "[追加] 各エントリに id/type/path キーを含む"
else
  _record_fail "[追加] エントリ構造不備"
fi
echo ""

# =========================================================================
# Group 2: scenario.json 欠落 → 警告 + スキップ
# =========================================================================
echo -e "${BOLD}[2] scenario.json 欠落時 (必須 behavior 2)${NC}"

# behavior: scenario.json が欠落したディレクトリ → 警告を出すがスキップ（他のシナリオは検出）
stdout_out=$(bash "$SCANNER" "$MISSING_DIR" --count 2>/dev/null)
stderr_out=$(bash "$SCANNER" "$MISSING_DIR" --count 2>&1 >/dev/null)
rc=$?

# 他の 2 シナリオが検出される
if [ "$stdout_out" = "2" ]; then
  _record_pass "欠落ありでも他 2 シナリオを検出 (count=2) [behavior 2]"
else
  _record_fail "欠落時の検出数" "expected 2, got $stdout_out"
fi

# 警告メッセージが stderr に出る
if echo "$stderr_out" | grep -qE "WARN.*scenario.json.*missing"; then
  _record_pass "欠落ディレクトリに対し WARN が stderr に出力される [behavior 2]"
else
  _record_fail "WARN 出力なし" "stderr: ${stderr_out:0:300}"
fi

# 欠落時でも exit 0（警告止まり）
if [ "$rc" -eq 0 ]; then
  _record_pass "欠落のみでは exit 0 (警告扱い) [behavior 2]"
else
  _record_fail "欠落のみで exit 非0" "rc=$rc"
fi

# 欠落ディレクトリ名 'no-json-here' が警告に含まれる
if echo "$stderr_out" | grep -q "no-json-here"; then
  _record_pass "[追加] 警告に欠落ディレクトリ名 'no-json-here' が含まれる"
else
  _record_fail "[追加] 警告にディレクトリ名なし" "stderr: ${stderr_out:0:300}"
fi
echo ""

# =========================================================================
# Group 3: 新規ディレクトリ追加 → 再スキャン検出数 +1
# =========================================================================
echo -e "${BOLD}[3] 再スキャン時の新規検出 (必須 behavior 3)${NC}"

# behavior: 新規ディレクトリ scenarios/new-test/scenario.json を追加 → 再スキャンで検出数が +1
TMP_WORK=$(mktemp -d 2>/dev/null || echo "/tmp/scan-test-$$")
mkdir -p "$TMP_WORK/scenarios"
cp -r "$OK_DIR"/* "$TMP_WORK/scenarios/" 2>/dev/null

# 初回スキャン
count_before=$(bash "$SCANNER" "$TMP_WORK/scenarios" --count 2>/dev/null)
rc_before=$?

# 新規ディレクトリを追加（ハードコード変更なしに検出できることを確認）
mkdir -p "$TMP_WORK/scenarios/new-test"
cat > "$TMP_WORK/scenarios/new-test/scenario.json" <<'EOF'
{
  "id": "new-test",
  "type": "video_edit",
  "version": "1.0.0",
  "description": "ホットアド: 再スキャンで検出されるはず",
  "input_sources": [
    { "type": "video_file", "path": "inputs/clip.mp4", "required": true }
  ],
  "quality_gates": {
    "required_mechanical_gates": [
      { "id": "output_exists", "command": "test -f output.mp4", "expect": "exit 0" }
    ]
  },
  "agent_prompt_patch": "new-test scenario for rescan"
}
EOF

# 再スキャン
count_after=$(bash "$SCANNER" "$TMP_WORK/scenarios" --count 2>/dev/null)
rc_after=$?

if [ "$rc_before" -eq 0 ] && [ "$rc_after" -eq 0 ] \
   && [ "$count_before" = "3" ] && [ "$count_after" = "4" ]; then
  _record_pass "新規追加前 3 → 追加後 4 (+1) [behavior 3]"
else
  _record_fail "再スキャン検出不備" "before=$count_before (rc=$rc_before), after=$count_after (rc=$rc_after)"
fi

# 新規の id が --ids 出力に含まれる
ids_after=$(bash "$SCANNER" "$TMP_WORK/scenarios" --ids 2>/dev/null)
if echo "$ids_after" | grep -qx "new-test"; then
  _record_pass "[追加] 新規 id 'new-test' が --ids に含まれる (ハードコード不要)"
else
  _record_fail "[追加] 新規 id が --ids に現れない" "ids='${ids_after//$'\n'/,}'"
fi
echo ""

# =========================================================================
# Group 4: scenarios/ ディレクトリ自体が存在しない
# =========================================================================
echo -e "${BOLD}[4] scenarios/ 不在 (必須 behavior 4)${NC}"

# behavior: scenarios/ ディレクトリ自体が存在しない → エラーメッセージ + exit 非0
NONEXISTENT="/this/path/should/not/exist/$$-xyz"
stdout_out=$(bash "$SCANNER" "$NONEXISTENT" --count 2>/dev/null)
stderr_out=$(bash "$SCANNER" "$NONEXISTENT" --count 2>&1 >/dev/null)
rc=$?

if [ "$rc" -ne 0 ]; then
  _record_pass "scenarios/ 不在で exit 非0 (rc=$rc) [behavior 4]"
else
  _record_fail "scenarios/ 不在でも exit 0" "stdout=$stdout_out"
fi

if echo "$stderr_out" | grep -qE "ERROR.*does not exist|scenarios directory.*exist"; then
  _record_pass "エラーメッセージに 'does not exist' を含む [behavior 4]"
else
  _record_fail "エラーメッセージ不備" "stderr: ${stderr_out:0:300}"
fi

# --json モードでも同様にエラー
bash "$SCANNER" "$NONEXISTENT" --json >/dev/null 2>&1
rc_json=$?
if [ "$rc_json" -ne 0 ]; then
  _record_pass "[追加] --json モードでも scenarios/ 不在は exit 非0"
else
  _record_fail "[追加] --json で exit 0 になった" "rc=$rc_json"
fi
echo ""

# =========================================================================
# Group 5: id 不整合 → 整合性エラー
# =========================================================================
echo -e "${BOLD}[5] id ↔ ディレクトリ名 不整合 (必須 behavior 5)${NC}"

# behavior: scenario.json 内の id がディレクトリ名と一致しない → 整合性エラー
stderr_out=$(bash "$SCANNER" "$MISMATCH_DIR" --count 2>&1 >/dev/null)
rc=$?

if [ "$rc" -ne 0 ]; then
  _record_pass "id 不整合時に exit 非0 (rc=$rc) [behavior 5]"
else
  _record_fail "id 不整合でも exit 0"
fi

# 整合性エラー表現が stderr に含まれる
if echo "$stderr_out" | grep -qE "consistency error|integrity error|整合性"; then
  _record_pass "エラーメッセージに 'consistency error' を含む [behavior 5]"
else
  _record_fail "整合性エラー表現なし" "stderr: ${stderr_out:0:300}"
fi

# 違反値（dir 名 slideshow と id wrong-id）の両方が出力されている
if echo "$stderr_out" | grep -q "slideshow" && echo "$stderr_out" | grep -q "wrong-id"; then
  _record_pass "[追加] ディレクトリ名 'slideshow' と不一致 id 'wrong-id' の両方がエラーに出力される"
else
  _record_fail "[追加] 不一致値の報告不備" "stderr: ${stderr_out:0:400}"
fi
echo ""

# =========================================================================
# Group 6: エッジケース
# =========================================================================
echo -e "${BOLD}[6] エッジケース${NC}"

# [追加] 空ディレクトリ (scenarios-empty) → count 0、exit 0
count=$(bash "$SCANNER" "$EMPTY_DIR" --count 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$count" = "0" ]; then
  _record_pass "[追加] 空ディレクトリ → count 0 + exit 0"
else
  _record_fail "[追加] 空ディレクトリ扱い" "rc=$rc, count=$count"
fi

# [追加] 空ディレクトリ --json → []
json_out=$(bash "$SCANNER" "$EMPTY_DIR" --json 2>/dev/null)
if [ "$(echo "$json_out" | jq 'length')" = "0" ]; then
  _record_pass "[追加] 空ディレクトリ --json → []"
else
  _record_fail "[追加] 空ディレクトリ --json 出力" "got=$json_out"
fi

# [追加] 不正 JSON が混入した場合 → 警告してスキップ + 他は検出
TMP_BAD=$(mktemp -d 2>/dev/null || echo "/tmp/scan-bad-$$")
mkdir -p "$TMP_BAD/scenarios"
cp -r "$OK_DIR"/* "$TMP_BAD/scenarios/" 2>/dev/null
mkdir -p "$TMP_BAD/scenarios/corrupt"
echo "this is { not valid json" > "$TMP_BAD/scenarios/corrupt/scenario.json"

count=$(bash "$SCANNER" "$TMP_BAD/scenarios" --count 2>/dev/null)
stderr_out=$(bash "$SCANNER" "$TMP_BAD/scenarios" --count 2>&1 >/dev/null)
if [ "$count" = "3" ] && echo "$stderr_out" | grep -qE "WARN.*not valid JSON"; then
  _record_pass "[追加] 不正 JSON は WARN でスキップ（他 3 は検出）"
else
  _record_fail "[追加] 不正 JSON 扱い" "count=$count, stderr=${stderr_out:0:200}"
fi
rm -rf "$TMP_BAD"

# [追加] 使い方エラー（引数なし）
bash "$SCANNER" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] 引数なし → exit 非0 (usage error)"
else
  _record_fail "[追加] 引数なしで exit 0"
fi

# [追加] 未知の mode → exit 非0
bash "$SCANNER" "$OK_DIR" --bogus >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] 未知 mode (--bogus) → exit 非0"
else
  _record_fail "[追加] 未知 mode で exit 0"
fi
echo ""

# =========================================================================
# Group 7: source 後の関数呼び出し
# =========================================================================
echo -e "${BOLD}[7] source での利用${NC}"
(
  set +e
  source "$SCANNER" 2>/dev/null
  if declare -F scan_scenarios_dir >/dev/null; then
    scan_scenarios_dir "$OK_DIR" >/dev/null 2>&1
    exit $?
  fi
  exit 99
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] source 後 scan_scenarios_dir を呼び出せる"
else
  _record_fail "[追加] source 経由呼び出し失敗" "rc=$rc"
fi

(
  set +e
  source "$SCANNER" 2>/dev/null
  ids=$(list_scenario_ids "$OK_DIR" 2>/dev/null)
  n=$(echo "$ids" | grep -c .)
  [ "$n" -eq 3 ]
)
if [ $? -eq 0 ]; then
  _record_pass "[追加] source 後 list_scenario_ids が 3 件返す"
else
  _record_fail "[追加] source 経由 list_scenario_ids"
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
