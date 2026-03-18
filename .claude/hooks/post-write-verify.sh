#!/bin/bash
# PostToolUse gate: verify written file is non-empty
# Non-blocking (exit 0 always, warnings via stderr)

PROFILE="${FORGE_HOOK_PROFILE:-standard}"
[ "$PROFILE" = "minimal" ] && exit 0

read -r -d '' INPUT < /dev/stdin 2>/dev/null || true

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

if [ -f "$FILE_PATH" ]; then
  SIZE=$(wc -c < "$FILE_PATH" 2>/dev/null || echo 0)
  if [ "$SIZE" -eq 0 ]; then
    echo "[Hook] WARNING: Written file is empty: $FILE_PATH" >&2
  fi
fi

exit 0
