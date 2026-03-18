#!/bin/bash
# test-priming.sh — Priming ユニットテスト
set -euo pipefail

source "$(dirname "$0")/test-helpers.sh"

echo -e "${BOLD}=== Priming テスト ===${NC}"

# ===== セットアップ =====
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# 関数を抽出して source
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "${PROJECT_ROOT}/.forge/lib/priming.sh"

# ===== テスト 1: vitest プロジェクトの検出 =====
echo ""
echo "--- テスト: vitest 検出 ---"
fixture="${TMPDIR_BASE}/vitest-project"
mkdir -p "$fixture"
cat > "$fixture/package.json" << 'EOF'
{"devDependencies":{"vitest":"^1.0.0"},"scripts":{"test":"vitest run"}}
EOF
output=$(prime_project_context "$fixture")
assert_contains "vitest 検出" "vitest" "$output"
assert_contains "test script 検出" "vitest run" "$output"

# ===== テスト 2: jest プロジェクトの検出 =====
echo ""
echo "--- テスト: jest 検出 ---"
fixture="${TMPDIR_BASE}/jest-project"
mkdir -p "$fixture"
cat > "$fixture/package.json" << 'EOF'
{"devDependencies":{"jest":"^29.0.0"},"scripts":{"test":"jest"}}
EOF
output=$(prime_project_context "$fixture")
assert_contains "jest 検出" "jest" "$output"

# ===== テスト 3: TypeScript 検出 =====
echo ""
echo "--- テスト: TypeScript 検出 ---"
fixture="${TMPDIR_BASE}/ts-project"
mkdir -p "$fixture"
cat > "$fixture/package.json" << 'EOF'
{"devDependencies":{"vitest":"^1.0.0"}}
EOF
echo '{}' > "$fixture/tsconfig.json"
output=$(prime_project_context "$fixture")
assert_contains "TypeScript あり" "あり" "$output"

# ===== テスト 4: pnpm 検出 =====
echo ""
echo "--- テスト: pnpm 検出 ---"
fixture="${TMPDIR_BASE}/pnpm-project"
mkdir -p "$fixture"
touch "$fixture/pnpm-lock.yaml"
output=$(prime_project_context "$fixture")
assert_contains "pnpm 検出" "pnpm" "$output"

# ===== テスト 5: npm 検出 =====
echo ""
echo "--- テスト: npm 検出 ---"
fixture="${TMPDIR_BASE}/npm-project"
mkdir -p "$fixture"
touch "$fixture/package-lock.json"
output=$(prime_project_context "$fixture")
assert_contains "npm 検出" "npm" "$output"

# ===== テスト 6: テストファイルパターン検出 =====
echo ""
echo "--- テスト: テストファイルパターン検出 ---"
fixture="${TMPDIR_BASE}/testfiles-project"
mkdir -p "$fixture/src"
touch "$fixture/src/app.test.ts"
output=$(prime_project_context "$fixture")
assert_contains "テストファイル表示" "app.test.ts" "$output"

# ===== テスト 7: 存在しないディレクトリ =====
echo ""
echo "--- テスト: 存在しないディレクトリ ---"
output=$(prime_project_context "${TMPDIR_BASE}/nonexistent" 2>&1 || true)
assert_eq "空出力" "" "$output"

# ===== テスト 8: エントリポイント検出 =====
echo ""
echo "--- テスト: エントリポイント検出 ---"
fixture="${TMPDIR_BASE}/entry-project"
mkdir -p "$fixture/src"
touch "$fixture/src/index.ts"
output=$(prime_project_context "$fixture")
assert_contains "エントリポイント検出" "src/index.ts" "$output"

# ===== サマリー =====
print_test_summary
