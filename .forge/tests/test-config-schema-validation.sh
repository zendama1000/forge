#!/bin/bash
# test-config-schema-validation.sh — 設定ファイルスキーマ検証テスト
# 使い方: bash .forge/tests/test-config-schema-validation.sh

set -uo pipefail

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ===== テスト集計 =====
PASS_COUNT=0
FAIL_COUNT=0

# ===== アサーション関数 =====
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:300}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
    echo -e "    actual: ${haystack:0:300}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ===== common.sh のソース =====
# validate_config() を使うために common.sh を source する
export ERRORS_FILE="/dev/null"
export RESEARCH_DIR="test-config-schema-validation"
json_fail_count=0
source "${SCRIPT_DIR}/../lib/common.sh"

# ===== テスト用 fixtures =====
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SCHEMAS_DIR="${PROJECT_ROOT}/.forge/schemas"
CONFIGS_DIR="${PROJECT_ROOT}/.forge/config"

# スキーマファイルのパス
DEV_SCHEMA="${SCHEMAS_DIR}/development.schema.json"
CB_SCHEMA="${SCHEMAS_DIR}/circuit-breaker.schema.json"
RESEARCH_SCHEMA="${SCHEMAS_DIR}/research.schema.json"
MA_SCHEMA="${SCHEMAS_DIR}/mutation-audit.schema.json"

# 各設定ファイルの有効コピーを作成
VALID_DEV="${TMP_DIR}/development-valid.json"
VALID_CB="${TMP_DIR}/circuit-breaker-valid.json"
VALID_RESEARCH="${TMP_DIR}/research-valid.json"
VALID_MA="${TMP_DIR}/mutation-audit-valid.json"

cp "${CONFIGS_DIR}/development.json" "$VALID_DEV"
cp "${CONFIGS_DIR}/circuit-breaker.json" "$VALID_CB"
cp "${CONFIGS_DIR}/research.json" "$VALID_RESEARCH"
cp "${CONFIGS_DIR}/mutation-audit.json" "$VALID_MA"

echo ""
echo -e "${BOLD}===== test-config-schema-validation.sh — スキーマ検証テスト =====${NC}"
echo ""

# ========================================================================
# Group 1: 正常系 — 有効設定バリデーション通過
# behavior: 正規のdevelopment.jsonがJSON Schemaバリデーション通過 → exit 0（正常系: 有効設定）
# ========================================================================
echo -e "${BOLD}===== Group 1: 正常系 — 有効設定バリデーション通過 =====${NC}"

# test 1: 有効な development.json が通過
exit_code=0
validate_config "$VALID_DEV" "$DEV_SCHEMA" 2>/dev/null || exit_code=$?
assert_eq "有効な development.json → exit 0" "0" "$exit_code"

# test 2: 有効な circuit-breaker.json が通過
# behavior: circuit-breaker.json, research.json, mutation-audit.jsonもそれぞれ対応するスキーマで検証可能（汎用性: 全設定ファイル対応）
exit_code=0
validate_config "$VALID_CB" "$CB_SCHEMA" 2>/dev/null || exit_code=$?
assert_eq "有効な circuit-breaker.json → exit 0" "0" "$exit_code"

# test 3: 有効な research.json が通過
exit_code=0
validate_config "$VALID_RESEARCH" "$RESEARCH_SCHEMA" 2>/dev/null || exit_code=$?
assert_eq "有効な research.json → exit 0" "0" "$exit_code"

# test 4: 有効な mutation-audit.json が通過
exit_code=0
validate_config "$VALID_MA" "$MA_SCHEMA" 2>/dev/null || exit_code=$?
assert_eq "有効な mutation-audit.json → exit 0" "0" "$exit_code"

echo ""

# ========================================================================
# Group 2: 異常系 — 必須フィールド欠落
# behavior: implementer.modelフィールドが欠落したdevelopment.json → exit 1 + 欠落フィールドパスを含むエラーメッセージ（異常系: 必須フィールド欠落）
# ========================================================================
echo -e "${BOLD}===== Group 2: 異常系 — 必須フィールド欠落 =====${NC}"

# implementer.model を削除した development.json を作成
MISSING_MODEL="${TMP_DIR}/development-missing-model.json"
jq 'del(.implementer.model)' "$VALID_DEV" > "$MISSING_MODEL"

# test 5: exit code = 1
exit_code=0
output_missing=$(validate_config "$MISSING_MODEL" "$DEV_SCHEMA" 2>&1) || exit_code=$?
assert_eq "implementer.model欠落 → exit 1" "1" "$exit_code"

# test 6: エラーメッセージにフィールドパスが含まれる
assert_contains "エラーメッセージに .implementer.model が含まれる" ".implementer.model" "$output_missing"

# test 7: ERROR キーワードが含まれる
assert_contains "エラーメッセージに ERROR が含まれる" "ERROR" "$output_missing"

# 追加: server.health_check_url 欠落
MISSING_URL="${TMP_DIR}/development-missing-url.json"
jq 'del(.server.health_check_url)' "$VALID_DEV" > "$MISSING_URL"
exit_code=0
output_missing_url=$(validate_config "$MISSING_URL" "$DEV_SCHEMA" 2>&1) || exit_code=$?
assert_eq "server.health_check_url欠落 → exit 1" "1" "$exit_code"
assert_contains "エラーメッセージに .server.health_check_url が含まれる" ".server.health_check_url" "$output_missing_url"

echo ""

# ========================================================================
# Group 3: 異常系 — 型エラー
# behavior: task_planner.timeout_secに文字列'abc'を設定 → exit 1 + 型不一致エラー（異常系: 型エラー）
# ========================================================================
echo -e "${BOLD}===== Group 3: 異常系 — 型エラー =====${NC}"

# task_planner.timeout_sec を文字列に変更
TYPE_ERROR_DEV="${TMP_DIR}/development-type-error.json"
jq '.task_planner.timeout_sec = "abc"' "$VALID_DEV" > "$TYPE_ERROR_DEV"

# test 9: exit code = 1
exit_code=0
output_type=$(validate_config "$TYPE_ERROR_DEV" "$DEV_SCHEMA" 2>&1) || exit_code=$?
assert_eq "timeout_sec=\"abc\" → exit 1" "1" "$exit_code"

# test 10: エラーメッセージにフィールドパスが含まれる
assert_contains "エラーメッセージに .task_planner.timeout_sec が含まれる" ".task_planner.timeout_sec" "$output_type"

# test 11: 型不一致情報が含まれる（expected number）
assert_contains "エラーメッセージに 'number' が含まれる" "number" "$output_type"

# test 12: 型不一致情報が含まれる（got string）
assert_contains "エラーメッセージに 'string' が含まれる" "string" "$output_type"

# 追加: research.json の models.scope_challenger に数値を設定（型チェック）
TYPE_ERROR_RESEARCH="${TMP_DIR}/research-type-error.json"
jq '.models.scope_challenger = 42' "$VALID_RESEARCH" > "$TYPE_ERROR_RESEARCH"
exit_code=0
output_type_r=$(validate_config "$TYPE_ERROR_RESEARCH" "$RESEARCH_SCHEMA" 2>&1) || exit_code=$?
assert_eq "scope_challenger=42 → exit 1" "1" "$exit_code"
assert_contains "エラーメッセージに .models.scope_challenger が含まれる" ".models.scope_challenger" "$output_type_r"

echo ""

# ========================================================================
# Group 4: 汎用性 — 全4設定ファイル対応
# behavior: circuit-breaker.json, research.json, mutation-audit.jsonもそれぞれ対応するスキーマで検証可能（汎用性: 全設定ファイル対応）
# ========================================================================
echo -e "${BOLD}===== Group 4: 汎用性 — 全4設定ファイルのスキーマ存在確認 =====${NC}"

# test 14: 4つのスキーマファイルが存在する
assert_eq "development.schema.json 存在" "exists" "$([ -f "$DEV_SCHEMA" ] && echo exists || echo missing)"
assert_eq "circuit-breaker.schema.json 存在" "exists" "$([ -f "$CB_SCHEMA" ] && echo exists || echo missing)"
assert_eq "research.schema.json 存在" "exists" "$([ -f "$RESEARCH_SCHEMA" ] && echo exists || echo missing)"
assert_eq "mutation-audit.schema.json 存在" "exists" "$([ -f "$MA_SCHEMA" ] && echo exists || echo missing)"

# test 18: 各スキーマが有効な JSON である
assert_eq "development.schema.json は有効なJSON" "0" "$(jq empty "$DEV_SCHEMA" 2>/dev/null; echo $?)"
assert_eq "circuit-breaker.schema.json は有効なJSON" "0" "$(jq empty "$CB_SCHEMA" 2>/dev/null; echo $?)"
assert_eq "research.schema.json は有効なJSON" "0" "$(jq empty "$RESEARCH_SCHEMA" 2>/dev/null; echo $?)"
assert_eq "mutation-audit.schema.json は有効なJSON" "0" "$(jq empty "$MA_SCHEMA" 2>/dev/null; echo $?)"

# mutation-audit.json の mutation_audit.enabled を数値に変更
MA_TYPE_ERROR="${TMP_DIR}/mutation-audit-type-error.json"
jq '.mutation_audit.enabled = 123' "$VALID_MA" > "$MA_TYPE_ERROR"
exit_code=0
validate_config "$MA_TYPE_ERROR" "$MA_SCHEMA" 2>/dev/null || exit_code=$?
assert_eq "mutation_audit.enabled=123 → exit 1" "1" "$exit_code"

echo ""

# ========================================================================
# Group 5: 統合確認 — 起動シーケンスへの組み込み
# behavior: validate_config()関数がforge-flow.sh・ralph-loop.sh・research-loop.shの起動シーケンスで呼ばれている（統合確認: 起動時バリデーション）
# ========================================================================
echo -e "${BOLD}===== Group 5: 統合確認 — 起動シーケンスへの組み込み =====${NC}"

FORGE_FLOW="${PROJECT_ROOT}/.forge/loops/forge-flow.sh"
RALPH_LOOP="${PROJECT_ROOT}/.forge/loops/ralph-loop.sh"
RESEARCH_LOOP="${PROJECT_ROOT}/.forge/loops/research-loop.sh"

# forge-flow.sh に validate_config 呼出がある
ff_calls=$(grep -c "validate_config" "$FORGE_FLOW" 2>/dev/null || echo 0)
assert_eq "forge-flow.sh に validate_config 呼出あり" "true" "$([ "$ff_calls" -gt 0 ] && echo true || echo false)"

# ralph-loop.sh に validate_config 呼出がある
rl_calls=$(grep -c "validate_config" "$RALPH_LOOP" 2>/dev/null || echo 0)
assert_eq "ralph-loop.sh に validate_config 呼出あり" "true" "$([ "$rl_calls" -gt 0 ] && echo true || echo false)"

# research-loop.sh に validate_config 呼出がある
rsl_calls=$(grep -c "validate_config" "$RESEARCH_LOOP" 2>/dev/null || echo 0)
assert_eq "research-loop.sh に validate_config 呼出あり" "true" "$([ "$rsl_calls" -gt 0 ] && echo true || echo false)"

# 各スクリプトがスキーマファイルのパスを参照している
assert_contains "forge-flow.sh が development.schema.json を参照" "development.schema.json" "$(grep "validate_config" "$FORGE_FLOW")"
assert_contains "ralph-loop.sh が development.schema.json を参照" "development.schema.json" "$(grep "validate_config" "$RALPH_LOOP")"
assert_contains "research-loop.sh が research.schema.json を参照" "research.schema.json" "$(grep "validate_config" "$RESEARCH_LOOP")"

echo ""

# ========================================================================
# Group 6: エッジケース — 未知フィールド検出（警告のみ、ブロックしない）
# behavior: スキーマに定義されていないフィールドが追加された場合 → 警告ログ出力（エッジケース: 未知フィールド検出、ただし起動はブロックしない）
# ========================================================================
echo -e "${BOLD}===== Group 6: エッジケース — 未知フィールド検出 =====${NC}"

# 未知フィールドを追加した development.json を作成
UNKNOWN_FIELD="${TMP_DIR}/development-unknown-field.json"
jq '.completely_unknown_field_xyz = "test_value"' "$VALID_DEV" > "$UNKNOWN_FIELD"

# test: exit code = 0（未知フィールドはブロックしない）
exit_code=0
output_warn=$(validate_config "$UNKNOWN_FIELD" "$DEV_SCHEMA" 2>&1) || exit_code=$?
assert_eq "未知フィールド追加 → exit 0（ブロックしない）" "0" "$exit_code"

# test: 警告ログが出力される
assert_contains "未知フィールドの警告ログが出力される" "completely_unknown_field_xyz" "$output_warn"

# test: ERROR ではなく WARNING である
assert_contains "WARNING が出力される（ERROR ではなく）" "WARNING" "$output_warn"
assert_not_contains "ERROR が出力されない" "ERROR" "$output_warn"

# エッジケース: 設定ファイルが存在しない場合
exit_code=0
validate_config "/nonexistent/path/config.json" "$DEV_SCHEMA" 2>/dev/null || exit_code=$?
assert_eq "存在しない設定ファイル → exit 1" "1" "$exit_code"

# エッジケース: スキーマファイルが存在しない場合は警告のみ（exit 0）
exit_code=0
validate_config "$VALID_DEV" "/nonexistent/path/schema.json" 2>/dev/null || exit_code=$?
assert_eq "存在しないスキーマファイル → exit 0（スキップ）" "0" "$exit_code"

echo ""

# ========================================================================
# サマリー
# ========================================================================
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL_COUNT"
