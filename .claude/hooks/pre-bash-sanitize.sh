#!/bin/bash
# PreToolUse gate: block commands with template placeholders or bare tool names
# Exit 2 = block, Exit 0 = allow

PROFILE="${FORGE_HOOK_PROFILE:-standard}"

read -r -d '' INPUT < /dev/stdin 2>/dev/null || true

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# === minimal profile: placeholder check only ===
if echo "$COMMAND" | grep -qE '\{\{[A-Z_]+\}\}'; then
  echo "[Hook] BLOCKED: Template placeholder detected in command" >&2
  echo "[Hook] Replace {{PLACEHOLDER}} with actual values before execution" >&2
  exit 2
fi

[ "$PROFILE" = "minimal" ] && exit 0

# === standard profile: bare tool name check ===
if echo "$COMMAND" | grep -qE '^\s*(vitest|jest|tsc|eslint|prettier|playwright)\s'; then
  echo "[Hook] BLOCKED: Use 'npx' prefix for npm tools" >&2
  echo "[Hook] Example: 'npx vitest' instead of 'vitest'" >&2
  exit 2
fi

[ "$PROFILE" = "standard" ] && exit 0

# === strict profile: dev server direct execution warning ===
if echo "$COMMAND" | grep -qE '\b(npm\s+run\s+dev|pnpm\s+(run\s+)?dev|yarn\s+dev)\b'; then
  if ! echo "$COMMAND" | grep -qE '(tmux|nohup|&\s*$|run_in_background)'; then
    echo "[Hook] BLOCKED: Dev server must be managed by harness (dev-phases.sh)" >&2
    echo "[Hook] Use ralph-loop.sh --work-dir for managed server lifecycle" >&2
    exit 2
  fi
fi

exit 0
