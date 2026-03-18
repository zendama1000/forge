#!/bin/bash
# priming.sh — プロジェクト文脈の自動収集（AnimaWorks Priming 概念の適用）
# ralph-loop.sh から source される。単独では実行しない。

# prime_project_context <work_dir>
# 対象プロジェクトの基本情報を収集し stdout に出力。
# ralph-loop 起動時に1回だけ呼出し、結果をキャッシュして全タスクに注入する。
prime_project_context() {
  local work_dir="$1"
  [ -d "$work_dir" ] || return 0

  # 1. パッケージマネージャ検出
  local pkg_manager="不明"
  if [ -f "${work_dir}/pnpm-lock.yaml" ]; then
    pkg_manager="pnpm"
  elif [ -f "${work_dir}/yarn.lock" ]; then
    pkg_manager="yarn"
  elif [ -f "${work_dir}/package-lock.json" ]; then
    pkg_manager="npm"
  elif [ -f "${work_dir}/bun.lockb" ]; then
    pkg_manager="bun"
  fi

  # 2. テストフレームワーク検出（package.json）
  local test_framework="不明"
  local test_script="未定義"
  if [ -f "${work_dir}/package.json" ]; then
    if jq -e '.devDependencies.vitest // .dependencies.vitest' "${work_dir}/package.json" >/dev/null 2>&1; then
      test_framework="vitest"
    elif jq -e '.devDependencies.jest // .dependencies.jest' "${work_dir}/package.json" >/dev/null 2>&1; then
      test_framework="jest"
    elif jq -e '.devDependencies.mocha // .dependencies.mocha' "${work_dir}/package.json" >/dev/null 2>&1; then
      test_framework="mocha"
    fi
    test_script=$(jq -r '.scripts.test // "未定義"' "${work_dir}/package.json" 2>/dev/null | tr -d '\r')
  fi

  # 3. TypeScript 有無
  local typescript="なし"
  [ -f "${work_dir}/tsconfig.json" ] && typescript="あり"

  # 4. 既存テストファイルパターン検出（上位5件）
  local test_files=""
  test_files=$(find "$work_dir" -maxdepth 4 \
    \( -name '*.test.*' -o -name '*.spec.*' -o -name '*.e2e.*' \) \
    ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.next/*' \
    2>/dev/null | head -5 | sed "s|${work_dir}/||" || true)

  # 5. ディレクトリ構造概要（深さ2）
  local dir_tree=""
  dir_tree=$(find "$work_dir" -maxdepth 2 -type d \
    ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.next/*' ! -path '*/dist/*' \
    2>/dev/null | head -25 | sed "s|${work_dir}/||" | sed '/^$/d' || true)

  # 6. エントリポイント検出
  local entry_point="不明"
  if [ -f "${work_dir}/src/index.ts" ]; then
    entry_point="src/index.ts"
  elif [ -f "${work_dir}/src/index.js" ]; then
    entry_point="src/index.js"
  elif [ -f "${work_dir}/src/app.ts" ]; then
    entry_point="src/app.ts"
  elif [ -f "${work_dir}/index.ts" ]; then
    entry_point="index.ts"
  fi

  # 出力
  cat <<PRIME_EOF
パッケージマネージャ: ${pkg_manager}
テストフレームワーク: ${test_framework}
テストスクリプト: ${test_script}
TypeScript: ${typescript}
エントリポイント: ${entry_point}
PRIME_EOF

  if [ -n "$test_files" ]; then
    echo "既存テストファイル例:"
    echo "$test_files" | sed 's/^/  /'
  fi

  if [ -n "$dir_tree" ]; then
    echo "ディレクトリ構造:"
    echo "$dir_tree" | sed 's/^/  /'
  fi
}
