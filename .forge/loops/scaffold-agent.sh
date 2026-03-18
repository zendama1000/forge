#!/bin/bash
# scaffold-agent.sh — 新規エージェント用ボイラープレート生成スクリプト
#
# 使い方:
#   bash .forge/loops/scaffold-agent.sh <name> [--with-schema] [--with-template]
#
# 引数:
#   <name>           エージェント名 (kebab-case, 例: my-agent)
#
# オプション:
#   --with-schema    .forge/schemas/<name>.schema.json を追加生成
#   --with-template  .forge/templates/<name>-prompt.md を追加生成

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCAFFOLD_BASE_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# =============================================================================
# 使用法
# =============================================================================
usage() {
  echo "Usage: scaffold-agent.sh <name> [--with-schema] [--with-template]" >&2
  exit 1
}

# =============================================================================
# 引数パース
# =============================================================================
NAME=""
WITH_SCHEMA=false
WITH_TEMPLATE=false

for arg in "$@"; do
  case "$arg" in
    --with-schema)   WITH_SCHEMA=true ;;
    --with-template) WITH_TEMPLATE=true ;;
    --*)
      echo "Unknown option: $arg" >&2
      usage
      ;;
    *)
      if [ -z "$NAME" ]; then
        NAME="$arg"
      else
        echo "Unexpected argument: $arg" >&2
        usage
      fi
      ;;
  esac
done

# 名前が未指定
if [ -z "$NAME" ]; then
  usage
fi

# =============================================================================
# 既存エージェントの上書き防止
# =============================================================================
AGENT_FILE="${PROJECT_ROOT}/.claude/agents/${NAME}.md"
if [ -f "$AGENT_FILE" ]; then
  echo "Agent ${NAME} already exists" >&2
  exit 1
fi

# =============================================================================
# 表示用名前: kebab-case → Title Case
# =============================================================================
DISPLAY_NAME=$(echo "$NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')

# =============================================================================
# 1. エージェント定義ファイル生成: .claude/agents/<name>.md
#    Role / Instructions / Output Format セクションを含む
# =============================================================================
mkdir -p "${PROJECT_ROOT}/.claude/agents"
cat > "$AGENT_FILE" << AGENT_CONTENT_EOF
# ${DISPLAY_NAME}

## 役割

あなたは${DISPLAY_NAME}です。{{PLACEHOLDER: エージェントの役割を1-2文で説明してください}}

## 行動原則

1. {{PLACEHOLDER: 原則1を記述してください}}
2. {{PLACEHOLDER: 原則2を記述してください}}
3. {{PLACEHOLDER: 原則3を記述してください}}

## 制約

- {{PLACEHOLDER: 制約1を記述してください}}
- 出力はJSON形式のみ。説明文や前置きは一切不要

## 出力フォーマット

{{PLACEHOLDER: 出力フォーマットの説明を記述してください}}
AGENT_CONTENT_EOF

echo "Created: ${AGENT_FILE}"

# =============================================================================
# 2. JSONスキーマ生成（--with-schema 時）: .forge/schemas/<name>.schema.json
# =============================================================================
if [ "$WITH_SCHEMA" = true ]; then
  SCHEMA_FILE="${PROJECT_ROOT}/.forge/schemas/${NAME}.schema.json"
  mkdir -p "${PROJECT_ROOT}/.forge/schemas"
  cat > "$SCHEMA_FILE" << 'SCHEMA_CONTENT_EOF'
{
  "type": "object",
  "properties": {
    "{{PLACEHOLDER_KEY}}": {
      "type": "string",
      "description": "{{PLACEHOLDER: フィールドの説明}}"
    }
  },
  "required": ["{{PLACEHOLDER_KEY}}"]
}
SCHEMA_CONTENT_EOF
  echo "Created: ${SCHEMA_FILE}"
fi

# =============================================================================
# 3. プロンプトテンプレート生成（--with-template 時）:
#    .forge/templates/<name>-prompt.md
# =============================================================================
if [ "$WITH_TEMPLATE" = true ]; then
  TEMPLATE_FILE="${PROJECT_ROOT}/.forge/templates/${NAME}-prompt.md"
  mkdir -p "${PROJECT_ROOT}/.forge/templates"
  cat > "$TEMPLATE_FILE" << 'TEMPLATE_CONTENT_EOF'
## コンテキスト

{{PLACEHOLDER_CONTEXT}}

## タスク

{{PLACEHOLDER: エージェントへの指示を記述してください}}

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "{{PLACEHOLDER_KEY}}": "{{PLACEHOLDER_VALUE}}"
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（` ` `json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
TEMPLATE_CONTENT_EOF
  echo "Created: ${TEMPLATE_FILE}"
fi

# =============================================================================
# 完了
# =============================================================================
echo "Scaffold completed for agent: ${NAME}"
