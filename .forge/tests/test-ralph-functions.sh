#!/bin/bash
# test-ralph-functions.sh — wrapper
# 正本は <repo-root>/test-ralph-functions.sh（プロジェクト履歴上ルート配置）。
# 本ファイルは validation コマンドが `.forge/tests/test-ralph-functions.sh` を
# 参照するため、正本を呼び出す薄いラッパーとして配置する。
# 引数はそのまま透過する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CANONICAL="${PROJECT_ROOT}/test-ralph-functions.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "ERROR: canonical test-ralph-functions.sh not found at: $CANONICAL" >&2
  exit 1
fi

exec bash "$CANONICAL" "$@"
