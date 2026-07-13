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

# batch#8 Fix1: sanitize step(0) が参照する unwrap 定義
# （FORGE_JQ_UNWRAP_BASH_C / unwrap_bash_c）を common.sh から取り込む
source "${REAL_ROOT}/.forge/lib/common.sh" 2>/dev/null

# スタブは source 後に定義（common.sh の実装を上書き）
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

echo -e "${BOLD}--- Test 11: bash -c ラッパー展開（batch#8 Fix1 step(0)） ---${NC}"
cat > "${TEST_DIR}/t11.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T11a", "validation": {
      "layer_1": {"command": "bash -c \"test -f x && echo OK\""},
      "layer_2": {"command": "bash -c \"curl -sf http://localhost:3001/health\""},
      "layer_3": [
        {"id": "L3-1", "strategy": "cli_flow",
         "definition": {"command": "bash -c \"mycli run\"", "verify_command": "bash -c \"jq -e .ok out.json\""}}
      ]
    }},
    {"task_id": "T11b", "validation": {"layer_1": {"command": "bash -c \"vitest run src/a.test.ts\""}}},
    {"task_id": "T11c", "validation": {"layer_1": {"command": "bash -c \"for s in *.json; do jq -e . \\\"$s\\\" || exit 1; done\""}}}
  ],
  "phases": [
    {"phase_id": "p1", "exit_criteria": [
      {"type": "auto", "description": "d", "command": "bash -c \"npm test\""}
    ]}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t11.json" > /dev/null 2>&1
assert_eq "L1 の bash -c が展開される" "test -f x && echo OK" \
  "$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t11.json")"
assert_eq "L2 の bash -c が展開される" "curl -sf http://localhost:3001/health" \
  "$(jq -r '.tasks[0].validation.layer_2.command' "${TEST_DIR}/t11.json")"
assert_eq "L3 command が展開される" "mycli run" \
  "$(jq -r '.tasks[0].validation.layer_3[0].definition.command' "${TEST_DIR}/t11.json")"
assert_eq "L3 verify_command が展開される" "jq -e .ok out.json" \
  "$(jq -r '.tasks[0].validation.layer_3[0].definition.verify_command' "${TEST_DIR}/t11.json")"
assert_eq "exit_criteria の bash -c が展開される" "npm test" \
  "$(jq -r '.phases[0].exit_criteria[0].command' "${TEST_DIR}/t11.json")"
assert_eq "unwrap → npx 前置の順で合成される" "npx vitest run src/a.test.ts" \
  "$(jq -r '.tasks[1].validation.layer_1.command' "${TEST_DIR}/t11.json")"
assert_eq "歴史的15連敗ケース: 内側 \\\"\$s\\\" が正しく復元される" \
  'for s in *.json; do jq -e . "$s" || exit 1; done' \
  "$(jq -r '.tasks[2].validation.layer_1.command' "${TEST_DIR}/t11.json")"

echo -e "${BOLD}--- Test 12: 曖昧な bash -c は不変（安全側） ---${NC}"
cat > "${TEST_DIR}/t12.json" <<'EOF'
{
  "tasks": [
    {"task_id": "T12a", "validation": {"layer_1": {"command": "bash -c \"a\" && echo done"}}},
    {"task_id": "T12b", "validation": {"layer_1": {"command": "timeout 5 bash -c \"a\""}}},
    {"task_id": "T12c", "validation": {"layer_1": {"command": "npx vitest run"}}}
  ]
}
EOF
sanitize_task_commands "${TEST_DIR}/t12.json" > /dev/null 2>&1
assert_eq "後続トークン付きは不変" 'bash -c "a" && echo done' \
  "$(jq -r '.tasks[0].validation.layer_1.command' "${TEST_DIR}/t12.json")"
assert_eq "非先頭 (timeout 前置) は不変" 'timeout 5 bash -c "a"' \
  "$(jq -r '.tasks[1].validation.layer_1.command' "${TEST_DIR}/t12.json")"
assert_eq "bare コマンドは不変" "npx vitest run" \
  "$(jq -r '.tasks[2].validation.layer_1.command' "${TEST_DIR}/t12.json")"

# ===== クリーンアップ =====
rm -rf "$TEST_DIR"

# ===== サマリー =====
print_test_summary
