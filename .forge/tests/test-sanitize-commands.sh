#!/bin/bash
# test-sanitize-commands.sh — sanitize_task_commands() テスト
# generate-tasks.sh のコマンドサニタイズ関数を直接テスト。
# 使い方: bash .forge/tests/test-sanitize-commands.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-sanitize-commands.sh — sanitize_task_commands テスト =====${NC}"
echo ""

# ===== テスト環境セットアップ =====
TEST_DIR="/tmp/test-sanitize-commands-$$"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# common.sh の最小スタブ（log, notify_human）
PROJECT_ROOT="$TEST_DIR"
mkdir -p "${TEST_DIR}/.forge/state/notifications"
ERRORS_FILE="${TEST_DIR}/.forge/state/errors.jsonl"
RESEARCH_DIR="test-sanitize"
json_fail_count=0

log() { echo "[LOG] $*"; }
notify_human() { true; }

# sanitize_task_commands 関数を抽出
extract_all_functions_awk "${REAL_ROOT}/.forge/loops/generate-tasks.sh" sanitize_task_commands > "${TEST_DIR}/sanitize-func.sh"
source "${TEST_DIR}/sanitize-func.sh"

# ===== テストケース =====

echo -e "${BOLD}--- Test 1: bare vitest → npx vitest ---${NC}"
cat > "${TEST_DIR}/t1.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T1", "validation": {"layer_1": {"command": "vitest run src/test.ts"}}}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t1.json" > /dev/null 2>&1
T1_CMD=$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t1.json")
assert_eq "bare vitest → npx vitest" "npx vitest run src/test.ts" "$T1_CMD"

echo -e "${BOLD}--- Test 2: bare tsc --noEmit → npx tsc --noEmit ---${NC}"
cat > "${TEST_DIR}/t2.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T2", "validation": {"layer_1": {"command": "tsc --noEmit"}}}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t2.json" > /dev/null 2>&1
T2_CMD=$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t2.json")
assert_eq "bare tsc → npx tsc" "npx tsc --noEmit" "$T2_CMD"

echo -e "${BOLD}--- Test 3: npx vitest → 変更なし ---${NC}"
cat > "${TEST_DIR}/t3.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T3", "validation": {"layer_1": {"command": "npx vitest run"}}}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t3.json" > /dev/null 2>&1
T3_CMD=$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t3.json")
assert_eq "npx vitest unchanged" "npx vitest run" "$T3_CMD"

echo -e "${BOLD}--- Test 4: pnpm tsc → 変更なし ---${NC}"
cat > "${TEST_DIR}/t4.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T4", "validation": {"layer_1": {"command": "pnpm tsc --noEmit"}}}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t4.json" > /dev/null 2>&1
T4_CMD=$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t4.json")
assert_eq "pnpm tsc unchanged" "pnpm tsc --noEmit" "$T4_CMD"

echo -e "${BOLD}--- Test 5: {{PLACEHOLDER}} → exit 1 ---${NC}"
cat > "${TEST_DIR}/t5.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T5", "validation": {"layer_1": {"command": "npx vitest run {{TEST_FILE}}"}}}
  ]
}
EOF
T5_EXIT=0
(sanitize_task_commands "${TEST_DIR}/t5.json" > /dev/null 2>&1) || T5_EXIT=$?
assert_eq "{{PLACEHOLDER}} triggers exit 1" "1" "$T5_EXIT"

echo -e "${BOLD}--- Test 6: testPathPattern path → leaf only ---${NC}"
cat > "${TEST_DIR}/t6.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T6", "validation": {"layer_1": {"command": "npx vitest --testPathPattern models/doctrine"}}}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t6.json" > /dev/null 2>&1
T6_CMD=$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t6.json")
assert_eq "testPathPattern leaf only" "npx vitest --testPathPattern doctrine" "$T6_CMD"

echo -e "${BOLD}--- Test 7: phases[].exit_criteria[].command も npx 付与 ---${NC}"
cat > "${TEST_DIR}/t7.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T7", "validation": {"layer_1": {"command": "npx vitest run"}}}
  ],
  "phases": [
    {
      "id": "mvp",
      "exit_criteria": [
        {"type": "auto", "command": "vitest run src/basic.ts", "description": "basic test"},
        {"type": "auto", "command": "npx tsc --noEmit", "description": "type check"},
        {"type": "human_check", "description": "manual check"}
      ]
    }
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t7.json" > /dev/null 2>&1
T7_PHASE_CMD=$(jq -r '.phases[0].exit_criteria[0].command' "${TEST_DIR}/t7.json")
T7_PHASE_CMD2=$(jq -r '.phases[0].exit_criteria[1].command' "${TEST_DIR}/t7.json")
assert_eq "phase exit_criteria bare vitest → npx vitest" "npx vitest run src/basic.ts" "$T7_PHASE_CMD"
assert_eq "phase exit_criteria npx tsc unchanged" "npx tsc --noEmit" "$T7_PHASE_CMD2"

echo -e "${BOLD}--- Test 8: bare eslint → npx eslint ---${NC}"
cat > "${TEST_DIR}/t8.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T8", "validation": {"layer_1": {"command": "eslint src/"}}}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t8.json" > /dev/null 2>&1
T8_CMD=$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t8.json")
assert_eq "bare eslint → npx eslint" "npx eslint src/" "$T8_CMD"

echo -e "${BOLD}--- Test 9: bare playwright → npx playwright ---${NC}"
cat > "${TEST_DIR}/t9.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T9", "validation": {"layer_1": {"command": "playwright test e2e/"}}}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t9.json" > /dev/null 2>&1
T9_CMD=$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t9.json")
assert_eq "bare playwright → npx playwright" "npx playwright test e2e/" "$T9_CMD"

echo -e "${BOLD}--- Test 10: no validation → no error ---${NC}"
cat > "${TEST_DIR}/t10.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T10", "description": "no validation block"}
  ]
}
EOF
T10_EXIT=0
sanitize_task_commands "${TEST_DIR}/t10.json" > /dev/null 2>&1 || T10_EXIT=$?
assert_eq "task without validation passes" "0" "$T10_EXIT"

# ===== クリーンアップ =====
rm -rf "$TEST_DIR"

# ===== サマリー =====
print_test_summary
