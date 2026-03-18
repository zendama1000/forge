#!/bin/bash
# test-safety.sh — Forge Harness 安全対策テスト
# ダミー git リポジトリを作成し、各安全機構を検証する。
#
# 使い方: bash .forge/tests/test-safety.sh

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

# ===== テスト環境セットアップ =====
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# common.sh の source に必要な変数
export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export RESEARCH_DIR="test-safety"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMPDIR}/notifications"
json_fail_count=0

touch "$ERRORS_FILE"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== テスト用ダミーリポジトリ作成 =====
setup_test_repo() {
  local repo_dir="${TMPDIR}/test-repo"
  rm -rf "$repo_dir"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "test@test.com"
  git -C "$repo_dir" config user.name "Test"
  echo "hello" > "$repo_dir/README.md"
  echo "world" > "$repo_dir/src.js"
  git -C "$repo_dir" add -A
  git -C "$repo_dir" commit -m "initial" -q
  echo "$repo_dir"
}

# ===================================================================
echo -e "\n${BOLD}========== S1: Pre-flight Git Status Check ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 1.1: 非 git ディレクトリ → ERROR${NC}"
NON_GIT="${TMPDIR}/not-a-repo"
mkdir -p "$NON_GIT"
assert_exit "non-git directory returns 1" 1 safe_work_dir_check "$NON_GIT"

echo -e "\n${YELLOW}Test 1.2: クリーンなリポジトリ → OK${NC}"
CLEAN_REPO=$(setup_test_repo)
assert_exit "clean repo returns 0" 0 safe_work_dir_check "$CLEAN_REPO"

echo -e "\n${YELLOW}Test 1.3: 未コミット変更あり → ERROR${NC}"
DIRTY_REPO=$(setup_test_repo)
echo "changed" > "$DIRTY_REPO/src.js"
assert_exit "dirty repo returns 1" 1 safe_work_dir_check "$DIRTY_REPO"

echo -e "\n${YELLOW}Test 1.4: 少数の未追跡ファイル → WARNING (OK)${NC}"
UNTRACKED_REPO=$(setup_test_repo)
touch "$UNTRACKED_REPO/.env"
touch "$UNTRACKED_REPO/temp.txt"
assert_exit "few untracked files returns 0" 0 safe_work_dir_check "$UNTRACKED_REPO"

echo -e "\n${YELLOW}Test 1.5: 大量の未追跡ファイル (>10) → ERROR${NC}"
MANY_UNTRACKED_REPO=$(setup_test_repo)
for i in $(seq 1 15); do
  touch "$MANY_UNTRACKED_REPO/untracked-${i}.txt"
done
assert_exit "many untracked files returns 1" 1 safe_work_dir_check "$MANY_UNTRACKED_REPO"

echo -e "\n${YELLOW}Test 1.6: main ブランチ → WARNING (OK)${NC}"
MAIN_REPO=$(setup_test_repo)
# initial commit は通常 master (Git Bash) or main
assert_exit "main/master branch returns 0 (warning only)" 0 safe_work_dir_check "$MAIN_REPO"

# ===================================================================
echo -e "\n${BOLD}========== S3: Git Checkpoint ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 3.1: checkpoint create → ファイル生成確認${NC}"
CP_REPO=$(setup_test_repo)
CHECKPOINT_DIR="${TMPDIR}/checkpoints"
mkdir -p "$CHECKPOINT_DIR"
# Override CHECKPOINT_DIR for test
_orig_checkpoint_dir="$CHECKPOINT_DIR"
task_checkpoint_create "$CP_REPO" "test-task-1"
assert_eq "patch file exists" "true" "$([ -f "${CHECKPOINT_DIR}/test-task-1.patch" ] && echo true || echo false)"
assert_eq "untracked file exists" "true" "$([ -f "${CHECKPOINT_DIR}/test-task-1.untracked" ] && echo true || echo false)"
assert_eq "ref file exists" "true" "$([ -f "${CHECKPOINT_DIR}/test-task-1.ref" ] && echo true || echo false)"

echo -e "\n${YELLOW}Test 3.2: checkpoint create → 変更 → restore → 元に戻る${NC}"
CP_REPO2=$(setup_test_repo)
task_checkpoint_create "$CP_REPO2" "test-task-2"

# 変更を加える
echo "MODIFIED" > "$CP_REPO2/src.js"
echo "new file" > "$CP_REPO2/new-file.txt"
assert_eq "src.js is modified" "MODIFIED" "$(cat "$CP_REPO2/src.js")"
assert_eq "new-file.txt exists" "true" "$([ -f "$CP_REPO2/new-file.txt" ] && echo true || echo false)"

# 復帰
task_checkpoint_restore "$CP_REPO2" "test-task-2"
assert_eq "src.js restored to original" "world" "$(cat "$CP_REPO2/src.js")"
assert_eq "new-file.txt deleted" "false" "$([ -f "$CP_REPO2/new-file.txt" ] && echo true || echo false)"

# ===================================================================
echo -e "\n${BOLD}========== S4: Change Count Validation ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 4.1: 変更なし → OK (exit 0)${NC}"
VTC_REPO=$(setup_test_repo)
assert_exit "no changes returns 0" 0 validate_task_changes "$VTC_REPO" "vtc-1" 5 10

echo -e "\n${YELLOW}Test 4.2: 3ファイル変更 → OK (ソフトリミット内)${NC}"
VTC_REPO2=$(setup_test_repo)
echo "a" > "$VTC_REPO2/a.js"
echo "b" > "$VTC_REPO2/b.js"
echo "c" > "$VTC_REPO2/c.js"
assert_exit "3 new files within soft limit returns 0" 0 validate_task_changes "$VTC_REPO2" "vtc-2" 5 10

echo -e "\n${YELLOW}Test 4.3: 7ファイル変更 → WARNING (exit 2, ソフト超過)${NC}"
VTC_REPO3=$(setup_test_repo)
for i in $(seq 1 7); do
  echo "content" > "$VTC_REPO3/file-${i}.js"
done
assert_exit "7 new files exceeds soft limit returns 2" 2 validate_task_changes "$VTC_REPO3" "vtc-3" 5 10

echo -e "\n${YELLOW}Test 4.4: 12ファイル変更 → ERROR + 自動復帰 (exit 1)${NC}"
VTC_REPO4=$(setup_test_repo)
task_checkpoint_create "$VTC_REPO4" "vtc-4"
for i in $(seq 1 12); do
  echo "content" > "$VTC_REPO4/file-${i}.js"
done
assert_exit "12 new files exceeds hard limit returns 1" 1 validate_task_changes "$VTC_REPO4" "vtc-4" 5 10
# 自動復帰されたか確認
remaining_new=$(git -C "$VTC_REPO4" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
assert_eq "files cleaned up after hard limit rollback" "0" "$remaining_new"

# ===================================================================
echo -e "\n${BOLD}========== S6: Protected File Patterns ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 6.1: .env ファイル変更 → ERROR + 復帰${NC}"
PF_REPO=$(setup_test_repo)
task_checkpoint_create "$PF_REPO" "pf-1"
echo "SECRET=abc" > "$PF_REPO/.env"
assert_exit ".env change detected returns 1" 1 validate_task_changes "$PF_REPO" "pf-1" 5 10

echo -e "\n${YELLOW}Test 6.2: package-lock.json 変更 → ERROR + 復帰${NC}"
PF_REPO2=$(setup_test_repo)
# package-lock.json を tracked にする
echo '{}' > "$PF_REPO2/package-lock.json"
git -C "$PF_REPO2" add package-lock.json
git -C "$PF_REPO2" commit -m "add lock" -q
task_checkpoint_create "$PF_REPO2" "pf-2"
echo '{"version": 2}' > "$PF_REPO2/package-lock.json"
assert_exit "package-lock.json change detected returns 1" 1 validate_task_changes "$PF_REPO2" "pf-2" 5 10

# ===================================================================
echo -e "\n${BOLD}========== S2: Implementer Scope (File Check) ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 2.1: implementer-prompt.md に変更スコープ制限あり${NC}"
IMPL_PROMPT="${PROJECT_ROOT}/.forge/templates/implementer-prompt.md"
HAS_SCOPE=$(grep -c "変更スコープ制限" "$IMPL_PROMPT" 2>/dev/null || echo 0)
assert_eq "implementer-prompt.md has scope restrictions" "1" "$HAS_SCOPE"

echo -e "\n${YELLOW}Test 2.2: implementer-prompt.md に変更スコープ制限あり${NC}"
IMPL_PROMPT_TMPL="${PROJECT_ROOT}/.forge/templates/implementer-prompt.md"
HAS_CONSTRAINT=$(grep -c "変更スコープ制限" "$IMPL_PROMPT_TMPL" 2>/dev/null || echo 0)
assert_eq "implementer-prompt.md has scope restrictions" "1" "$HAS_CONSTRAINT"

echo -e "\n${YELLOW}Test 2.3: ralph-loop.sh で WebSearch,WebFetch を disallow${NC}"
HAS_DISALLOW=$(grep -c "WebSearch,WebFetch" "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" 2>/dev/null || echo 0)
TOTAL=$((TOTAL + 1))
if [ "$HAS_DISALLOW" -ge 1 ]; then
  echo -e "  ${GREEN}✓${NC} ralph-loop.sh has WebSearch,WebFetch in disallowed_tools (${HAS_DISALLOW} refs)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✗${NC} ralph-loop.sh should have >=1 refs to WebSearch,WebFetch, got ${HAS_DISALLOW}"
  FAIL=$((FAIL + 1))
fi

# ===================================================================
echo -e "\n${BOLD}========== S5: Auto-rollback (Config Check) ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 5.1: development.json に safety.auto_revert_on_regression あり${NC}"
DEV_JSON="${PROJECT_ROOT}/.forge/config/development.json"
AUTO_REVERT=$(jq -r '.safety.auto_revert_on_regression' "$DEV_JSON" 2>/dev/null)
assert_eq "auto_revert_on_regression is true" "true" "$AUTO_REVERT"

echo -e "\n${YELLOW}Test 5.2: ralph-loop.sh に自動ロールバックロジックあり${NC}"
HAS_ROLLBACK=$(grep -c "SAFETY_AUTO_REVERT_ON_REGRESSION" "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" 2>/dev/null || echo 0)
# 少なくとも設定読み込み + 使用の2箇所
TOTAL=$((TOTAL + 1))
if [ "$HAS_ROLLBACK" -ge 2 ]; then
  echo -e "  ${GREEN}✓${NC} ralph-loop.sh has auto_revert logic (${HAS_ROLLBACK} refs)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✗${NC} ralph-loop.sh should have >=2 refs to auto_revert, got ${HAS_ROLLBACK}"
  FAIL=$((FAIL + 1))
fi

# ===================================================================
echo -e "\n${BOLD}========== S7: Iteration Git Commit (Config Check) ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 7.1: development.json に safety.auto_commit_per_phase あり${NC}"
AUTO_COMMIT=$(jq -r '.safety.auto_commit_per_phase' "$DEV_JSON" 2>/dev/null)
assert_eq "auto_commit_per_phase is true" "true" "$AUTO_COMMIT"

echo -e "\n${YELLOW}Test 7.2: ralph-loop.sh に auto_commit ロジックあり${NC}"
HAS_COMMIT=$(grep -c "SAFETY_AUTO_COMMIT_PER_PHASE" "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" 2>/dev/null || echo 0)
TOTAL=$((TOTAL + 1))
if [ "$HAS_COMMIT" -ge 2 ]; then
  echo -e "  ${GREEN}✓${NC} ralph-loop.sh has auto_commit logic (${HAS_COMMIT} refs)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✗${NC} ralph-loop.sh should have >=2 refs to auto_commit, got ${HAS_COMMIT}"
  FAIL=$((FAIL + 1))
fi

# ===================================================================
echo -e "\n${BOLD}========== Config Integrity Checks ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test C.1: circuit-breaker.json に protected_patterns あり${NC}"
CB_JSON="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
PP_COUNT=$(jq '.protected_patterns | length' "$CB_JSON" 2>/dev/null || echo 0)
TOTAL=$((TOTAL + 1))
if [ "$PP_COUNT" -ge 3 ]; then
  echo -e "  ${GREEN}✓${NC} circuit-breaker.json has ${PP_COUNT} protected patterns"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}✗${NC} expected >=3 protected patterns, got ${PP_COUNT}"
  FAIL=$((FAIL + 1))
fi

echo -e "\n${YELLOW}Test C.2: checkpoints ディレクトリ存在${NC}"
assert_eq "checkpoints dir exists" "true" "$([ -d "${PROJECT_ROOT}/.forge/state/checkpoints" ] && echo true || echo false)"

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
