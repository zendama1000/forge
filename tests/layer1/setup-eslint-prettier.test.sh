#!/usr/bin/env bash
# Layer 1 テスト: setup-eslint-prettier
# 検証内容: eslint.config.js と .prettierrc が存在すること

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Layer 1 Test: setup-eslint-prettier ==="

# テスト1: eslint.config.js が存在すること
echo "Test 1: eslint.config.js が存在すること"
if [ ! -f "eslint.config.js" ]; then
  echo "❌ FAIL: eslint.config.js が見つかりません"
  exit 1
fi
echo "✓ Pass"

# テスト2: .prettierrc が存在すること
echo "Test 2: .prettierrc が存在すること"
if [ ! -f ".prettierrc" ]; then
  echo "❌ FAIL: .prettierrc が見つかりません"
  exit 1
fi
echo "✓ Pass"

# テスト3: eslint.config.js が有効なJavaScriptであること
echo "Test 3: eslint.config.js が有効なJavaScriptであること"
if ! node -c eslint.config.js 2>/dev/null; then
  echo "❌ FAIL: eslint.config.js に構文エラーがあります"
  exit 1
fi
echo "✓ Pass"

# テスト4: .prettierrc が有効なJSONであること
echo "Test 4: .prettierrc が有効なJSONであること"
if ! jq empty .prettierrc 2>/dev/null; then
  echo "❌ FAIL: .prettierrc が有効なJSONではありません"
  exit 1
fi
echo "✓ Pass"

# テスト5: eslint.config.js に TypeScript パーサー設定が含まれること
echo "Test 5: eslint.config.js に TypeScript パーサー設定が含まれること"
if ! grep -q "@typescript-eslint/parser" eslint.config.js; then
  echo "❌ FAIL: TypeScript パーサーの設定が見つかりません"
  exit 1
fi
echo "✓ Pass"

# テスト6: eslint.config.js にセキュリティルール（no-eval等）が含まれること
echo "Test 6: eslint.config.js にセキュリティルール（no-eval）が含まれること"
if ! grep -q "no-eval" eslint.config.js; then
  echo "❌ FAIL: no-eval ルールが見つかりません"
  exit 1
fi
echo "✓ Pass"

# テスト7: eslint.config.js に未使用変数検出が含まれること
echo "Test 7: eslint.config.js に未使用変数検出が含まれること"
if ! grep -q "no-unused-vars" eslint.config.js; then
  echo "❌ FAIL: no-unused-vars ルールが見つかりません"
  exit 1
fi
echo "✓ Pass"

# エッジケース1: eslint.config.js が空ファイルでないこと
echo "Edge Case 1: eslint.config.js が空ファイルでないこと"
if [ ! -s "eslint.config.js" ]; then
  echo "❌ FAIL: eslint.config.js が空です"
  exit 1
fi
echo "✓ Pass"

# エッジケース2: .prettierrc が空ファイルでないこと
echo "Edge Case 2: .prettierrc が空ファイルでないこと"
if [ ! -s ".prettierrc" ]; then
  echo "❌ FAIL: .prettierrc が空です"
  exit 1
fi
echo "✓ Pass"

echo ""
echo "=== All Layer 1 Tests Passed ==="
exit 0
