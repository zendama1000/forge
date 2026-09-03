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

# サブエージェント上限（batch#11 R25a）: 公式 docs（code.claude.com/docs/en/sub-agents）で確認した
# 環境変数。既定は depth 3 / concurrent 20 だが、ハーネスの -p 呼出で必要なのは L3 agent_flow の
# 1 段委譲（--agents インライン定義）だけなので depth 1 / 4 並列に絞る。外部から設定済みなら尊重する
: "${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH:=1}"
: "${CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS:=4}"
export CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS

source "${PROJECT_ROOT}/.forge/lib/common.sh"
