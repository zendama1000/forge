#!/bin/bash
# Stop hook: ハーネスのコードに未コミット変更があれば通知
# .forge/state/ や .forge/logs/ 等の実行時生成物は除外

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# コード変更のみ検出（state/logs/一時ファイルを除外）
changes=$(git -C "$PROJECT_DIR" diff --name-only HEAD -- \
    '.forge/loops/' '.forge/lib/' '.forge/templates/' '.forge/schemas/' \
    '.forge/config/' '.forge/tests/' '.claude/' 'CLAUDE.md' \
    'Dockerfile' 'docker-entrypoint.sh' 'docker-compose.yml' \
    2>/dev/null) || exit 0
[ -z "$changes" ] && exit 0

count=$(echo "$changes" | wc -l | tr -d ' ')
echo "⚠ ハーネスコードに未コミットの変更が ${count} 件あります。git push を推奨します。" >&2
exit 0
