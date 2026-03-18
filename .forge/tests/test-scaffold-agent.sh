#!/bin/bash
# test-scaffold-agent.sh — scaffold-agent.sh のテスト
#
# 使い方: bash .forge/tests/test-scaffold-agent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCAFFOLD_SCRIPT="${PROJECT_ROOT}/.forge/loops/scaffold-agent.sh"

# カラー
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

# =============================================================================
# テストヘルパー
# =============================================================================
pass() {
  echo -e "  ${GREEN}✓${NC} $1"
  PASS=$((PASS + 1))
}

fail() {
  local msg="${2:-}"
  echo -e "  ${RED}✗${NC} $1"
  [ -n "$msg" ] && echo -e "    detail: $msg"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label" "expected='${expected}' actual='${actual}'"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label" "expected to contain: '${needle}'"
  fi
}

# =============================================================================
# クリーンアップ
# =============================================================================
GENERATED_AGENT="${PROJECT_ROOT}/.claude/agents/test-agent.md"
GENERATED_SCHEMA="${PROJECT_ROOT}/.forge/schemas/test-agent.schema.json"
GENERATED_TEMPLATE="${PROJECT_ROOT}/.forge/templates/test-agent-prompt.md"

cleanup() {
  rm -f "$GENERATED_AGENT" "$GENERATED_SCHEMA" "$GENERATED_TEMPLATE"
}

trap cleanup EXIT

# テスト開始前にクリーンアップ（前回実行の残骸除去）
cleanup

# =============================================================================
# Test 1: 基本生成（正常系）
# behavior: scaffold-agent.sh 'test-agent' → .claude/agents/test-agent.md が生成され、
#           Role/Instructions/Output Formatセクションを含む（正常系: 基本生成）
# =============================================================================
echo -e "\n${BOLD}========== Test 1: 基本生成 ==========${NC}"

# Test 1.1: エージェント定義ファイルが生成されること
echo -e "\n${YELLOW}Test 1.1: test-agent.md が生成されること${NC}"
bash "$SCAFFOLD_SCRIPT" "test-agent"
assert_eq "test-agent.md が生成される" "true" "$([ -f "$GENERATED_AGENT" ] && echo true || echo false)"

# Test 1.2〜1.5: 必要なセクションを含むこと
AGENT_CONTENT=$(cat "$GENERATED_AGENT" 2>/dev/null || true)

echo -e "\n${YELLOW}Test 1.2: 役割セクション (Role) を含む${NC}"
assert_contains "## 役割 セクションを含む" "## 役割" "$AGENT_CONTENT"

echo -e "\n${YELLOW}Test 1.3: 行動原則セクション (Instructions) を含む${NC}"
assert_contains "## 行動原則 セクションを含む" "## 行動原則" "$AGENT_CONTENT"

echo -e "\n${YELLOW}Test 1.4: 出力フォーマットセクション (Output Format) を含む${NC}"
assert_contains "## 出力フォーマット セクションを含む" "## 出力フォーマット" "$AGENT_CONTENT"

echo -e "\n${YELLOW}Test 1.5: カスタマイズ用 {{PLACEHOLDER}} マーカーを含む${NC}"
assert_contains "{{PLACEHOLDER}} マーカーを含む" "{{PLACEHOLDER" "$AGENT_CONTENT"

# =============================================================================
# Test 2: スキーマ生成（正常系）
# behavior: scaffold-agent.sh 'test-agent' --with-schema →
#           .forge/schemas/test-agent.schema.json が追加生成され、有効なJSON Schemaである
#           （正常系: スキーマ生成）
# =============================================================================
echo -e "\n${BOLD}========== Test 2: スキーマ生成 (--with-schema) ==========${NC}"

# test-agent.md が既に存在するので削除してから再生成
rm -f "$GENERATED_AGENT"

echo -e "\n${YELLOW}Test 2.1: --with-schema でスキーマファイルが生成されること${NC}"
bash "$SCAFFOLD_SCRIPT" "test-agent" --with-schema
assert_eq "test-agent.schema.json が生成される" "true" "$([ -f "$GENERATED_SCHEMA" ] && echo true || echo false)"

echo -e "\n${YELLOW}Test 2.2: 生成されたスキーマが有効なJSONであること${NC}"
SCHEMA_VALID=$(jq . "$GENERATED_SCHEMA" > /dev/null 2>&1 && echo true || echo false)
assert_eq "有効なJSONである" "true" "$SCHEMA_VALID"

echo -e "\n${YELLOW}Test 2.3: スキーマのトップレベルが type: object であること${NC}"
SCHEMA_TYPE=$(jq -r '.type' "$GENERATED_SCHEMA" 2>/dev/null || echo "")
assert_eq "type フィールドが object" "object" "$SCHEMA_TYPE"

# =============================================================================
# Test 3: テンプレート生成（正常系）
# behavior: scaffold-agent.sh 'test-agent' --with-template →
#           .forge/templates/test-agent-prompt.md が追加生成される（正常系: テンプレート生成）
# =============================================================================
echo -e "\n${BOLD}========== Test 3: テンプレート生成 (--with-template) ==========${NC}"

rm -f "$GENERATED_AGENT"

echo -e "\n${YELLOW}Test 3.1: --with-template でテンプレートファイルが生成されること${NC}"
bash "$SCAFFOLD_SCRIPT" "test-agent" --with-template
assert_eq "test-agent-prompt.md が生成される" "true" "$([ -f "$GENERATED_TEMPLATE" ] && echo true || echo false)"

echo -e "\n${YELLOW}Test 3.2: テンプレートに出力フォーマットセクションが含まれること${NC}"
TEMPLATE_CONTENT=$(cat "$GENERATED_TEMPLATE" 2>/dev/null || true)
assert_contains "テンプレートに ## 出力フォーマット セクションを含む" "## 出力フォーマット" "$TEMPLATE_CONTENT"

# =============================================================================
# Test 4: 上書き防止（異常系）
# behavior: 既存の 'implementer' を指定 → exit 1 + 'Agent implementer already exists' エラー
#           （異常系: 上書き防止）
# =============================================================================
echo -e "\n${BOLD}========== Test 4: 上書き防止 ==========${NC}"

echo -e "\n${YELLOW}Test 4.1: 既存エージェント (implementer) 指定で exit 1${NC}"
OVERWRITE_EXIT=0
bash "$SCAFFOLD_SCRIPT" "implementer" > /dev/null 2>&1 || OVERWRITE_EXIT=$?
assert_eq "implementer 指定で exit 1" "1" "$OVERWRITE_EXIT"

echo -e "\n${YELLOW}Test 4.2: エラーメッセージに 'implementer' と 'already exists' を含む${NC}"
OVERWRITE_MSG=$(bash "$SCAFFOLD_SCRIPT" "implementer" 2>&1 || true)
assert_contains "エラーメッセージに agent 名を含む" "implementer" "$OVERWRITE_MSG"
assert_contains "エラーメッセージに 'already exists' を含む" "already exists" "$OVERWRITE_MSG"

# =============================================================================
# Test 5: 引数不足（エッジケース）
# behavior: 引数なしで実行 → exit 1 + 使用法（Usage: scaffold-agent.sh <name>
#           [--with-schema] [--with-template]）が表示される（エッジケース: 引数不足）
# =============================================================================
echo -e "\n${BOLD}========== Test 5: 引数不足 ==========${NC}"

echo -e "\n${YELLOW}Test 5.1: 引数なしで exit 1${NC}"
NO_ARG_EXIT=0
bash "$SCAFFOLD_SCRIPT" > /dev/null 2>&1 || NO_ARG_EXIT=$?
assert_eq "引数なしで exit 1" "1" "$NO_ARG_EXIT"

echo -e "\n${YELLOW}Test 5.2: Usage メッセージに scaffold-agent.sh を含む${NC}"
NO_ARG_MSG=$(bash "$SCAFFOLD_SCRIPT" 2>&1 || true)
assert_contains "Usage に scaffold-agent.sh を含む" "scaffold-agent.sh" "$NO_ARG_MSG"

echo -e "\n${YELLOW}Test 5.3: Usage メッセージに --with-schema を含む${NC}"
assert_contains "Usage に --with-schema を含む" "--with-schema" "$NO_ARG_MSG"

echo -e "\n${YELLOW}Test 5.4: Usage メッセージに --with-template を含む${NC}"
assert_contains "Usage に --with-template を含む" "--with-template" "$NO_ARG_MSG"

# =============================================================================
# Test 6: 構造一貫性
# behavior: 生成されたtest-agent.mdが既存エージェント（implementer.md等）と
#           同じ構造パターンに従う（構造検証: テンプレート一貫性）
# =============================================================================
echo -e "\n${BOLD}========== Test 6: 構造一貫性 ==========${NC}"

# test-agent.md はテスト 3 で生成済み（まだ存在するはず）
[ -f "$GENERATED_AGENT" ] || bash "$SCAFFOLD_SCRIPT" "test-agent"
AGENT_CONTENT=$(cat "$GENERATED_AGENT" 2>/dev/null || true)

echo -e "\n${YELLOW}Test 6.1: H1見出しにエージェント名 Title Case を含む${NC}"
assert_contains "H1見出しに '# Test Agent' を含む" "# Test Agent" "$AGENT_CONTENT"

echo -e "\n${YELLOW}Test 6.2: implementer.md と同じ 役割 セクション数を持つ${NC}"
IMPL_ROLE_COUNT=$(grep -c "## 役割" "${PROJECT_ROOT}/.claude/agents/implementer.md" 2>/dev/null || echo 0)
GEN_ROLE_COUNT=$(grep -c "## 役割" "$GENERATED_AGENT" 2>/dev/null || echo 0)
assert_eq "役割セクション数が一致" "$IMPL_ROLE_COUNT" "$GEN_ROLE_COUNT"

echo -e "\n${YELLOW}Test 6.3: implementer.md と同じ 行動原則 セクション数を持つ${NC}"
IMPL_PRIN_COUNT=$(grep -c "## 行動原則" "${PROJECT_ROOT}/.claude/agents/implementer.md" 2>/dev/null || echo 0)
GEN_PRIN_COUNT=$(grep -c "## 行動原則" "$GENERATED_AGENT" 2>/dev/null || echo 0)
assert_eq "行動原則セクション数が一致" "$IMPL_PRIN_COUNT" "$GEN_PRIN_COUNT"

echo -e "\n${YELLOW}Test 6.4: 制約セクションを含む（implementer.md パターン準拠）${NC}"
if grep -q "## 制約" "$GENERATED_AGENT" 2>/dev/null; then
  pass "制約セクションを含む"
else
  fail "制約セクションを含むべき"
fi

# =============================================================================
# サマリー
# =============================================================================
echo ""
echo -e "${BOLD}=========================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
