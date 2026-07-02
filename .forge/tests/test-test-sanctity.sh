#!/bin/bash
# test-test-sanctity.sh — テスト聖域化（reward hacking 予防層）のテスト
# validate_test_sanctity / snapshot_phase_tests / verify_phase_tests_integrity を検証する。
# 使い方: bash .forge/tests/test-test-sanctity.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

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

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

# ===== テスト環境セットアップ =====
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export RESEARCH_DIR="test-sanctity"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMPDIR}/notifications"
json_fail_count=0
touch "$ERRORS_FILE"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# テスト用ダミーリポジトリ: 既存テスト（tracked）+ 実装コードを含む
setup_sanctity_repo() {
  local repo_dir="${TMPDIR}/sanctity-repo-$1"
  rm -rf "$repo_dir"
  mkdir -p "$repo_dir/tests" "$repo_dir/src/__tests__"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "test@test.com"
  git -C "$repo_dir" config user.name "Test"
  echo "impl" > "$repo_dir/src.js"
  echo "existing unit test" > "$repo_dir/foo.test.ts"
  echo "existing nested test" > "$repo_dir/src/__tests__/bar.tsx"
  echo "existing tests dir" > "$repo_dir/tests/integration.sh"
  git -C "$repo_dir" add -A
  git -C "$repo_dir" commit -m "initial" -q
  echo "$repo_dir"
}

TASK_JSON_DEFAULT='{"task_id": "t-1", "task_type": "implementation"}'
TASK_JSON_ALLOWED='{"task_id": "t-1", "task_type": "implementation", "allows_test_edits": true}'

# ===================================================================
echo -e "\n${BOLD}========== validate_test_sanctity ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 1: HEAD 追跡テストの改変 → 違反 (exit 1)${NC}"
R1=$(setup_sanctity_repo 1)
echo "HACKED" > "$R1/foo.test.ts"
assert_exit "tracked foo.test.ts 改変 → 1" 1 validate_test_sanctity "$R1" "t-1" "$TASK_JSON_DEFAULT"

echo -e "\n${YELLOW}Test 2: 新規テスト作成（untracked）→ 許容 (exit 0)${NC}"
R2=$(setup_sanctity_repo 2)
echo "new test" > "$R2/new-feature.test.ts"
assert_exit "untracked 新規テスト作成 → 0" 0 validate_test_sanctity "$R2" "t-1" "$TASK_JSON_DEFAULT"

echo -e "\n${YELLOW}Test 3: allows_test_edits=true → 改変許可 (exit 0)${NC}"
R3=$(setup_sanctity_repo 3)
echo "LEGIT FIX" > "$R3/foo.test.ts"
assert_exit "allows_test_edits=true → 0" 0 validate_test_sanctity "$R3" "t-1" "$TASK_JSON_ALLOWED"

echo -e "\n${YELLOW}Test 4: 既存テストの削除 → 違反 (exit 1)${NC}"
R4=$(setup_sanctity_repo 4)
rm "$R4/foo.test.ts"
assert_exit "tracked テスト削除 → 1" 1 validate_test_sanctity "$R4" "t-1" "$TASK_JSON_DEFAULT"

echo -e "\n${YELLOW}Test 5: 非テストファイルの改変 → 許容 (exit 0)${NC}"
R5=$(setup_sanctity_repo 5)
echo "changed impl" > "$R5/src.js"
assert_exit "実装コード改変 → 0" 0 validate_test_sanctity "$R5" "t-1" "$TASK_JSON_DEFAULT"

echo -e "\n${YELLOW}Test 6: ネストした __tests__/ 配下の改変 → 違反（F 修正の統合確認）${NC}"
R6=$(setup_sanctity_repo 6)
echo "HACKED NESTED" > "$R6/src/__tests__/bar.tsx"
assert_exit "src/__tests__/bar.tsx 改変 → 1" 1 validate_test_sanctity "$R6" "t-1" "$TASK_JSON_DEFAULT"

echo -e "\n${YELLOW}Test 7: tests/ 配下の改変 → 違反${NC}"
R7=$(setup_sanctity_repo 7)
echo "HACKED DIR" > "$R7/tests/integration.sh"
assert_exit "tests/integration.sh 改変 → 1" 1 validate_test_sanctity "$R7" "t-1" "$TASK_JSON_DEFAULT"

echo -e "\n${YELLOW}Test 8: enabled=false → 全許容 (exit 0)${NC}"
R8=$(setup_sanctity_repo 8)
echo "HACKED" > "$R8/foo.test.ts"
# 一時 config（enabled=false）で PROJECT_ROOT を差し替え
FAKE_ROOT="${TMPDIR}/fake-root"
mkdir -p "${FAKE_ROOT}/.forge/config"
jq '.test_sanctity.enabled = false' "${PROJECT_ROOT}/.forge/config/circuit-breaker.json" \
  > "${FAKE_ROOT}/.forge/config/circuit-breaker.json"
_ORIG_PROJECT_ROOT="$PROJECT_ROOT"
PROJECT_ROOT="$FAKE_ROOT"
assert_exit "enabled=false → 0" 0 validate_test_sanctity "$R8" "t-1" "$TASK_JSON_DEFAULT"
PROJECT_ROOT="$_ORIG_PROJECT_ROOT"

# ===================================================================
echo -e "\n${BOLD}========== phase-tests スナップショット/検証 ==========${NC}"
# ===================================================================

# CHECKPOINT_DIR / phase-tests を一時領域に差し替え
FAKE_ROOT2="${TMPDIR}/fake-root2"
mkdir -p "${FAKE_ROOT2}/.forge/state/phase-tests"
echo "echo mvp test" > "${FAKE_ROOT2}/.forge/state/phase-tests/mvp.sh"
echo "echo core test" > "${FAKE_ROOT2}/.forge/state/phase-tests/core.sh"
_ORIG_PROJECT_ROOT="$PROJECT_ROOT"
_ORIG_CHECKPOINT_DIR="$CHECKPOINT_DIR"
PROJECT_ROOT="$FAKE_ROOT2"
CHECKPOINT_DIR="${FAKE_ROOT2}/.forge/state/checkpoints"
mkdir -p "$CHECKPOINT_DIR"

echo -e "\n${YELLOW}Test 9: snapshot → 無改変 → verify OK (exit 0)${NC}"
snapshot_phase_tests "pt-1"
assert_exit "無改変 → verify 0" 0 verify_phase_tests_integrity "pt-1"

echo -e "\n${YELLOW}Test 10: snapshot → 改変 → verify 違反 + 復元${NC}"
snapshot_phase_tests "pt-2"
echo "exit 0 # HACKED: always pass" > "${FAKE_ROOT2}/.forge/state/phase-tests/mvp.sh"
assert_exit "改変検出 → verify 1" 1 verify_phase_tests_integrity "pt-2"
assert_eq "改変されたスクリプトが復元される" "echo mvp test" "$(cat "${FAKE_ROOT2}/.forge/state/phase-tests/mvp.sh")"

echo -e "\n${YELLOW}Test 11: snapshot → 削除 → verify 違反 + 復元${NC}"
snapshot_phase_tests "pt-3"
rm "${FAKE_ROOT2}/.forge/state/phase-tests/core.sh"
assert_exit "削除検出 → verify 1" 1 verify_phase_tests_integrity "pt-3"
assert_eq "削除されたスクリプトが復元される" "true" "$([ -f "${FAKE_ROOT2}/.forge/state/phase-tests/core.sh" ] && echo true || echo false)"

echo -e "\n${YELLOW}Test 12: スナップショット不在 → verify OK (exit 0)${NC}"
assert_exit "スナップショット不在 → 0" 0 verify_phase_tests_integrity "pt-nonexistent"

PROJECT_ROOT="$_ORIG_PROJECT_ROOT"
CHECKPOINT_DIR="$_ORIG_CHECKPOINT_DIR"

# ===================================================================
echo -e "\n${BOLD}========== 配線の静的確認 ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 13: ralph-loop.sh に S4.6 配線あり${NC}"
WIRED=$(grep -c "validate_test_sanctity" "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" 2>/dev/null || echo 0)
TOTAL=$((TOTAL + 1))
if [ "$WIRED" -ge 1 ]; then
  echo -e "  ${GREEN}✓${NC} ralph-loop.sh が validate_test_sanctity を呼出 (${WIRED} refs)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✗${NC} ralph-loop.sh に validate_test_sanctity の配線がない"
  FAIL=$((FAIL + 1))
fi

echo -e "\n${YELLOW}Test 14: l2fix/l3fix タスクに allows_test_edits 付与${NC}"
HATCH=$(grep -c "allows_test_edits: true" "${PROJECT_ROOT}/.forge/lib/phase3.sh" 2>/dev/null || echo 0)
assert_eq "phase3.sh の fix タスクに escape hatch (2箇所)" "2" "$HATCH"

# ===================================================================
# サマリー
# ===================================================================
echo -e "\n${BOLD}=========================================${NC}"
echo -e "${BOLD} Test Summary: ${PASS}/${TOTAL} PASSED, ${FAIL} FAILED${NC}"
echo -e "${BOLD}=========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}SOME TESTS FAILED${NC}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
fi
