#!/bin/bash
# bootstrap.sh — Forge Harness スクリプト共通初期化
# 各スクリプトの冒頭で source する。BASH_SOURCE[1] から呼び出し元を特定する。
#
# 提供する変数:
#   SCRIPT_DIR   — 呼び出し元スクリプトのディレクトリ（絶対パス）
#   PROJECT_ROOT — プロジェクトルート（.forge/ の親ディレクトリ、絶対パス）
#
# 副作用:
#   - cd $PROJECT_ROOT
#   - source common.sh（log, jq_safe, check_dependencies 等が使用可能になる）

# 呼び出し元のパスから SCRIPT_DIR を導出
# BASH_SOURCE[0] = bootstrap.sh 自身, BASH_SOURCE[1] = source した側
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ ! -d "${PROJECT_ROOT}/.forge" ]; then
  echo -e "\033[0;31m[ERROR] プロジェクトルートが見つかりません: ${PROJECT_ROOT}\033[0m" >&2
  exit 1
fi

cd "$PROJECT_ROOT"

source "${PROJECT_ROOT}/.forge/lib/common.sh"
