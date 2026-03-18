#!/bin/bash
# test-assertions.sh — Locked Decision Assertions テスト
# 使い方: bash .forge/tests/test-assertions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# カラー
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

# テストヘルパー
assert_exit() {
  local label="$1" expected_exit="$2"
  shift 2
  local actual_exit=0
  "$@" > /dev/null 2>&1 || actual_exit=$?
  TOTAL=$((TOTAL + 1))
  if [ "$expected_exit" -eq "$actual_exit" ]; then
    echo -e "  ${GREEN}✓${NC} ${label} (exit=${actual_exit})"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected exit: ${expected_exit}"
    echo -e "    actual exit:   ${actual_exit}"
    FAIL=$((FAIL + 1))
  fi
}

assert_output_contains() {
  local label="$1" expected_pattern="$2"
  shift 2
  local output=""
  output=$("$@" 2>/dev/null) || true
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qE "$expected_pattern"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected pattern: ${expected_pattern}"
    echo -e "    actual output:    ${output:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

# ===== テスト環境セットアップ =====
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# common.sh の source に必要な変数
export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export RESEARCH_DIR="test-assertions"
json_fail_count=0

# development.json (assertions.enabled=true)
mkdir -p "${TMPDIR}/.forge/config"
echo '{"assertions":{"enabled":true}}' > "${TMPDIR}/.forge/config/development.json"
export PROJECT_ROOT="$TMPDIR"

# common.sh を source
source "${SCRIPT_DIR}/../lib/common.sh"

# ===== fixture 作成ヘルパー =====
make_work_dir() {
  local wd="${TMPDIR}/workdir-${RANDOM}"
  mkdir -p "$wd"
  echo "$wd"
}

make_config() {
  local path="${TMPDIR}/config-${RANDOM}.json"
  echo "$1" > "$path"
  echo "$path"
}

echo ""
echo -e "${BOLD}=== Locked Decision Assertions テスト ===${NC}"
echo ""

# ===== Test 1: config 不在 =====
echo -e "${BOLD}[1] config 不在 → return 0${NC}"
WD=$(make_work_dir)
assert_exit "config不在" 0 validate_locked_assertions "" "$WD"
assert_exit "config不在ファイル" 0 validate_locked_assertions "/nonexistent/config.json" "$WD"

# ===== Test 2: assertions 未定義 =====
echo -e "${BOLD}[2] assertions 未定義 → return 0${NC}"
CFG=$(make_config '{"locked_decisions":[{"decision":"test","reason":"r"}]}')
WD=$(make_work_dir)
assert_exit "assertions未定義" 0 validate_locked_assertions "$CFG" "$WD"

# ===== Test 3: file_exists: 存在する =====
echo -e "${BOLD}[3] file_exists: 存在する → return 0${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src/lib"
echo "export const client = {};" > "$WD/src/lib/client.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"file_exists","path":"src/lib/client.ts"}]}]}')
assert_exit "file_exists存在" 0 validate_locked_assertions "$CFG" "$WD"

# ===== Test 4: file_exists: 不在 =====
echo -e "${BOLD}[4] file_exists: 不在 → return 1 + レポート${NC}"
WD=$(make_work_dir)
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"file_exists","path":"src/lib/client.ts"}]}]}')
assert_exit "file_exists不在" 1 validate_locked_assertions "$CFG" "$WD"
assert_output_contains "レポートにパス含む" "client.ts" validate_locked_assertions "$CFG" "$WD"

# ===== Test 5: file_absent: 不在 =====
echo -e "${BOLD}[5] file_absent: 不在 → return 0${NC}"
WD=$(make_work_dir)
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"file_absent","path":"src/legacy.ts"}]}]}')
assert_exit "file_absent不在" 0 validate_locked_assertions "$CFG" "$WD"

# ===== Test 6: file_absent: 存在する =====
echo -e "${BOLD}[6] file_absent: 存在する → return 1${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src"
echo "legacy" > "$WD/src/legacy.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"file_absent","path":"src/legacy.ts"}]}]}')
assert_exit "file_absent存在" 1 validate_locked_assertions "$CFG" "$WD"

# ===== Test 7: grep_present: ヒット =====
echo -e "${BOLD}[7] grep_present: ヒット → return 0${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src"
echo 'const url = process.env.LLM_BASE_URL;' > "$WD/src/config.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"grep_present","pattern":"LLM_BASE_URL","glob":"src/**/*.ts"}]}]}')
assert_exit "grep_presentヒット" 0 validate_locked_assertions "$CFG" "$WD"

# ===== Test 8: grep_present: ヒットなし =====
echo -e "${BOLD}[8] grep_present: ヒットなし → return 1${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src"
echo 'const url = "http://localhost";' > "$WD/src/config.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"grep_present","pattern":"LLM_BASE_URL","glob":"src/**/*.ts"}]}]}')
assert_exit "grep_presentヒットなし" 1 validate_locked_assertions "$CFG" "$WD"

# ===== Test 9: grep_absent: ヒットなし =====
echo -e "${BOLD}[9] grep_absent: ヒットなし → return 0${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src"
echo 'const x = 1;' > "$WD/src/app.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"grep_absent","pattern":"OPENAI_API_KEY","glob":"src/**/*.ts"}]}]}')
assert_exit "grep_absentヒットなし" 0 validate_locked_assertions "$CFG" "$WD"

# ===== Test 10: grep_absent: ヒット =====
echo -e "${BOLD}[10] grep_absent: ヒット → return 1${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src"
echo 'const key = process.env.OPENAI_API_KEY;' > "$WD/src/app.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"grep_absent","pattern":"OPENAI_API_KEY","glob":"src/**/*.ts"}]}]}')
assert_exit "grep_absentヒット" 1 validate_locked_assertions "$CFG" "$WD"

# ===== Test 11: grep_absent + except: except内のみ =====
echo -e "${BOLD}[11] grep_absent + except: except内のみ → return 0${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src/lib/llm"
echo 'new OpenAI()' > "$WD/src/lib/llm/client.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"grep_absent","pattern":"new OpenAI","glob":"src/**/*.ts","except":["src/lib/llm/client.ts"]}]}]}')
assert_exit "grep_absent except内のみ" 0 validate_locked_assertions "$CFG" "$WD"

# ===== Test 12: grep_absent + except: except外にも =====
echo -e "${BOLD}[12] grep_absent + except: except外にも → return 1${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src/lib/llm" "$WD/src/app"
echo 'new OpenAI()' > "$WD/src/lib/llm/client.ts"
echo 'new OpenAI()' > "$WD/src/app/handler.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[{"type":"grep_absent","pattern":"new OpenAI","glob":"src/**/*.ts","except":["src/lib/llm/client.ts"]}]}]}')
assert_exit "grep_absent except外" 1 validate_locked_assertions "$CFG" "$WD"

# ===== Test 13: 複数assertions全通過 =====
echo -e "${BOLD}[13] 複数assertions全通過 → return 0${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src/lib"
echo 'export const client = {};' > "$WD/src/lib/client.ts"
echo 'const url = process.env.LLM_BASE_URL;' > "$WD/src/lib/config.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[
  {"type":"file_exists","path":"src/lib/client.ts"},
  {"type":"grep_present","pattern":"LLM_BASE_URL","glob":"src/**/*.ts"},
  {"type":"file_absent","path":"src/legacy.ts"}
]}]}')
assert_exit "複数assertions全通過" 0 validate_locked_assertions "$CFG" "$WD"

# ===== Test 14: 複数assertions一部違反 =====
echo -e "${BOLD}[14] 複数assertions一部違反 → return 1 + 違反のみレポート${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src/lib"
echo 'export const client = {};' > "$WD/src/lib/client.ts"
# LLM_BASE_URL は不在 → grep_present が失敗するはず
echo 'const x = 1;' > "$WD/src/lib/config.ts"
CFG=$(make_config '{"locked_decisions":[{"decision":"d1","reason":"r","assertions":[
  {"type":"file_exists","path":"src/lib/client.ts"},
  {"type":"grep_present","pattern":"LLM_BASE_URL","glob":"src/**/*.ts"}
]}]}')
assert_exit "一部違反" 1 validate_locked_assertions "$CFG" "$WD"
assert_output_contains "1件の違反" "1 件の違反" validate_locked_assertions "$CFG" "$WD"

# ===== Test 15: assertions有無混在 =====
echo -e "${BOLD}[15] assertions有無混在 → assertions有のみ検証${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src"
echo 'const x = 1;' > "$WD/src/app.ts"
CFG=$(make_config '{"locked_decisions":[
  {"decision":"no-assertions","reason":"r"},
  {"decision":"with-assertions","reason":"r","assertions":[{"type":"file_exists","path":"src/app.ts"}]}
]}')
assert_exit "混在テスト" 0 validate_locked_assertions "$CFG" "$WD"

# ===== L1 テストファイル参照検証テスト =====
echo ""
echo -e "${BOLD}=== L1 テストファイル参照検証テスト ===${NC}"
echo ""

# ===== Test 16: vitest コマンド + ファイル存在 =====
echo -e "${BOLD}[16] vitest コマンド + ファイル存在 → return 0${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src/lib"
echo 'test("a", () => {});' > "$WD/src/lib/preprocess.test.ts"
assert_exit "L1参照ファイル存在" 0 validate_l1_file_refs "npx vitest run src/lib/preprocess.test.ts" "$WD"

# ===== Test 17: vitest コマンド + ファイル不在 =====
echo -e "${BOLD}[17] vitest コマンド + ファイル不在 → return 1 + パス出力${NC}"
WD=$(make_work_dir)
assert_exit "L1参照ファイル不在" 1 validate_l1_file_refs "npx vitest run src/lib/preprocess.test.ts" "$WD"
assert_output_contains "不在パス出力" "preprocess.test.ts" validate_l1_file_refs "npx vitest run src/lib/preprocess.test.ts" "$WD"

# ===== Test 18: ファイルパスなしのコマンド =====
echo -e "${BOLD}[18] ファイルパスなしコマンド → return 0${NC}"
WD=$(make_work_dir)
assert_exit "パスなしコマンド" 0 validate_l1_file_refs 'echo "test passed"' "$WD"

# ===== Test 19: 複数ファイル参照 + 一部不在 =====
echo -e "${BOLD}[19] 複数ファイル参照 + 一部不在 → return 1 + 不在分のみ${NC}"
WD=$(make_work_dir)
mkdir -p "$WD/src"
echo 'test("a", () => {});' > "$WD/src/a.test.ts"
assert_exit "一部不在" 1 validate_l1_file_refs "npx vitest run src/a.test.ts src/b.spec.ts" "$WD"
assert_output_contains "不在分のみ出力" "b.spec.ts" validate_l1_file_refs "npx vitest run src/a.test.ts src/b.spec.ts" "$WD"

# ===== サマリー =====
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
