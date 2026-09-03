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
# batch#11 R03: 未追跡の新規ファイルは削除せず quarantine へ退避する（監査 2026-09-02: 復帰の削除が
# L1 合格成果物 5 件を破壊し 182〜426 分の浪費の主経路だった）。作業ツリーからは消え、quarantine に残る。
assert_eq "new-file.txt は作業ツリーから消える（checkpoint 時点へ復帰）" "false" "$([ -f "$CP_REPO2/new-file.txt" ] && echo true || echo false)"
assert_eq "new-file.txt は削除されず quarantine に退避される" "new file" "$(cat "${CHECKPOINT_DIR}/test-task-2.quarantine/new-file.txt" 2>/dev/null)"

echo -e "\n${YELLOW}Test 3.3: attempt 内の commit は .ref に巻き戻り、内容は salvage と quarantine に残る${NC}"
CP_REPO3=$(setup_test_repo)
task_checkpoint_create "$CP_REPO3" "test-task-3" 1
CP3_REF=$(tr -d '\r\n' < "${CHECKPOINT_DIR}/test-task-3.ref")
echo "COMMITTED" > "$CP_REPO3/src.js"
echo "brand new" > "$CP_REPO3/added.txt"
git -C "$CP_REPO3" add -A >/dev/null 2>&1
git -C "$CP_REPO3" -c user.email=t@t -c user.name=t commit -qm "attempt commit" >/dev/null 2>&1
assert_eq "attempt 内 commit で HEAD が進む" "true" "$([ "$(git -C "$CP_REPO3" rev-parse HEAD | tr -d '\r\n')" != "$CP3_REF" ] && echo true || echo false)"
task_checkpoint_restore "$CP_REPO3" "test-task-3"
assert_eq "restore で HEAD が attempt 開始点（.ref）に戻る" "$CP3_REF" "$(git -C "$CP_REPO3" rev-parse HEAD | tr -d '\r\n')"
assert_eq "commit されていた src.js の改変も元に戻る" "world" "$(cat "$CP_REPO3/src.js")"
assert_eq "commit されていた新規ファイルは quarantine に残る" "brand new" "$(cat "${CHECKPOINT_DIR}/test-task-3.quarantine/added.txt" 2>/dev/null)"
assert_eq "salvage.patch に commit 済みだった変更が含まれる" "true" "$(grep -q 'COMMITTED' "${CHECKPOINT_DIR}/test-task-3.salvage.patch" 2>/dev/null && echo true || echo false)"

echo -e "\n${YELLOW}Test 3.4: .base_ref は初回 attempt のみ書かれ、task_base_ref は .base_ref → .ref → HEAD の順${NC}"
CP_REPO4=$(setup_test_repo)
task_checkpoint_create "$CP_REPO4" "test-task-4" 1
CP4_BASE=$(tr -d '\r\n' < "${CHECKPOINT_DIR}/test-task-4.base_ref" 2>/dev/null)
assert_eq "first_attempt=1 で .base_ref が生成される" "$(git -C "$CP_REPO4" rev-parse HEAD | tr -d '\r\n')" "$CP4_BASE"
echo "x" > "$CP_REPO4/x.txt"; git -C "$CP_REPO4" add -A >/dev/null 2>&1
git -C "$CP_REPO4" -c user.email=t@t -c user.name=t commit -qm "c2" >/dev/null 2>&1
task_checkpoint_create "$CP_REPO4" "test-task-4" 0
assert_eq "first_attempt=0 では .base_ref を上書きしない" "$CP4_BASE" "$(tr -d '\r\n' < "${CHECKPOINT_DIR}/test-task-4.base_ref")"
assert_eq ".ref は毎 attempt 更新される" "$(git -C "$CP_REPO4" rev-parse HEAD | tr -d '\r\n')" "$(tr -d '\r\n' < "${CHECKPOINT_DIR}/test-task-4.ref")"
assert_eq "task_base_ref は .base_ref を優先" "$CP4_BASE" "$(task_base_ref "test-task-4" "$CP_REPO4")"
echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "${CHECKPOINT_DIR}/test-task-4.base_ref"
assert_eq "無効な .base_ref は飛ばして .ref を採る" "$(tr -d '\r\n' < "${CHECKPOINT_DIR}/test-task-4.ref")" "$(task_base_ref "test-task-4" "$CP_REPO4")"
rm -f "${CHECKPOINT_DIR}/test-task-4.base_ref" "${CHECKPOINT_DIR}/test-task-4.ref"
assert_eq "両方無ければ HEAD" "HEAD" "$(task_base_ref "test-task-4" "$CP_REPO4")"

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
# batch#11 R03: ハードリミット超過の復帰でも新規ファイルは削除されず quarantine に残る
quarantined=$(find "${CHECKPOINT_DIR}/vtc-4.quarantine" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "hard limit rollback でも 12 ファイルは quarantine に残る（削除しない）" "12" "$quarantined"

# ===================================================================
echo -e "\n${BOLD}========== S6: Protected File Patterns ==========${NC}"
# ===================================================================

echo -e "\n${YELLOW}Test 6.1: .env ファイル変更 → ERROR + 復帰${NC}"
PF_REPO=$(setup_test_repo)
task_checkpoint_create "$PF_REPO" "pf-1"
echo "SECRET=abc" > "$PF_REPO/.env"
assert_exit ".env change detected returns 1" 1 validate_task_changes "$PF_REPO" "pf-1" 5 10

echo -e "\n${YELLOW}Test 6.2: package-lock.json 変更 → 許可（batch#7: 保護除外）${NC}"
# 2026-07-12 仕様変更: package-lock.json は protected_patterns から除外
# （Implementer が依存追加時に lockfile を正当に更新できるようにする。browser-cockpit 実戦知見）
PF_REPO2=$(setup_test_repo)
# package-lock.json を tracked にする
echo '{}' > "$PF_REPO2/package-lock.json"
git -C "$PF_REPO2" add package-lock.json
git -C "$PF_REPO2" commit -m "add lock" -q
task_checkpoint_create "$PF_REPO2" "pf-2"
echo '{"version": 2}' > "$PF_REPO2/package-lock.json"
assert_exit "package-lock.json change is allowed (returns 0)" 0 validate_task_changes "$PF_REPO2" "pf-2" 5 10

echo -e "\n${YELLOW}Test 6.2b: *.lock（yarn.lock 等）は引き続き保護 → ERROR + 復帰${NC}"
PF_REPO2B=$(setup_test_repo)
echo 'lock v1' > "$PF_REPO2B/yarn.lock"
git -C "$PF_REPO2B" add yarn.lock
git -C "$PF_REPO2B" commit -m "add yarn lock" -q
task_checkpoint_create "$PF_REPO2B" "pf-2b"
echo 'lock v2' > "$PF_REPO2B/yarn.lock"
assert_exit "yarn.lock change detected returns 1" 1 validate_task_changes "$PF_REPO2B" "pf-2b" 5 10

# ===================================================================
echo -e "\n${BOLD}========== S6b: fnmatch_to_regex 変換 ==========${NC}"
# ===================================================================

# ヘルパー: パターンがパスに一致するか（0=一致, 1=不一致）
fnmatch_matches() {
  local pattern="$1" path="$2"
  echo "$path" | grep -qE "^$(fnmatch_to_regex "$pattern")$"
}

echo -e "\n${YELLOW}Test 6b.1: dir/** が任意階層に一致（旧二重バグの回帰）${NC}"
assert_exit "node_modules/** matches node_modules/a/b/c.js" 0 fnmatch_matches "node_modules/**" "node_modules/a/b/c.js"
assert_exit ".git/** matches .git/hooks/pre-commit" 0 fnmatch_matches ".git/**" ".git/hooks/pre-commit"
assert_exit "node_modules/** does not match src/node_modules.js" 1 fnmatch_matches "node_modules/**" "src/node_modules.js"

echo -e "\n${YELLOW}Test 6b.2: * はセパレータを跨がない${NC}"
assert_exit "*.lock matches foo.lock" 0 fnmatch_matches "*.lock" "foo.lock"
assert_exit "*.lock does not match dir/foo.lock" 1 fnmatch_matches "*.lock" "dir/foo.lock"
assert_exit "*.lock does not match foolock" 1 fnmatch_matches "*.lock" "foolock"

echo -e "\n${YELLOW}Test 6b.3: メタ文字エスケープ（. が任意1文字にならない）${NC}"
assert_exit ".env* matches .env.local" 0 fnmatch_matches ".env*" ".env.local"
assert_exit ".env* does not match Xenv" 1 fnmatch_matches ".env*" "Xenv"

echo -e "\n${YELLOW}Test 6b.4: 複合パターン **/*.pem${NC}"
assert_exit "**/*.pem matches a/b/key.pem" 0 fnmatch_matches "**/*.pem" "a/b/key.pem"

echo -e "\n${YELLOW}Test 6b.5: 統合 — node_modules 深層変更で validate_task_changes が復帰${NC}"
NM_REPO=$(setup_test_repo)
task_checkpoint_create "$NM_REPO" "nm-1"
mkdir -p "$NM_REPO/node_modules/pkg/dist"
echo "x" > "$NM_REPO/node_modules/pkg/dist/index.js"
assert_exit "deep node_modules change returns 1" 1 validate_task_changes "$NM_REPO" "nm-1" 5 10

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
# batch#11 R03: 回帰失敗時の自動ロールバックは OFF（監査 2026-09-02: 4.5f では 3 phase 全てで回帰失敗 →
# 直前完了タスクをロールバック → warn_and_continue で通過、という無意味な破壊が起きていた）。
# ロールバック機構自体（Test 5.2）は残す。
assert_eq "auto_revert_on_regression is false (batch#11)" "false" "$AUTO_REVERT"

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
