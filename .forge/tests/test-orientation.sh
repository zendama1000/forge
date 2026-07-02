#!/bin/bash
# test-orientation.sh — Implementer 自己定位コンテキスト（build_orientation_context）のテスト
# 使い方: bash .forge/tests/test-orientation.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export RESEARCH_DIR="test-orientation"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMPDIR}/notifications"
json_fail_count=0
touch "$ERRORS_FILE"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

echo -e "${BOLD}===== test-orientation.sh — 自己定位コンテキスト =====${NC}"

# ===== fixture: git repo（コミット5個） =====
REPO="${TMPDIR}/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@test.com"
git -C "$REPO" config user.name "Test"
for i in 1 2 3 4 5; do
  echo "content $i" > "$REPO/file-$i.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "commit-number-$i"
done

# ===== fixture: task-stack（completed 4件 / 全6件） =====
STACK="${TMPDIR}/task-stack.json"
cat > "$STACK" <<'EOF'
{
  "tasks": [
    {"task_id": "t-1", "description": "最初のセットアップタスク", "status": "completed", "updated_at": "2026-07-01T10:00:00Z"},
    {"task_id": "t-2", "description": "コア機能の実装", "status": "completed", "updated_at": "2026-07-01T11:00:00Z"},
    {"task_id": "t-3", "description": "UI コンポーネント作成", "status": "completed", "updated_at": "2026-07-01T12:00:00Z"},
    {"task_id": "t-4", "description": "テスト追加", "status": "completed", "updated_at": "2026-07-01T13:00:00Z"},
    {"task_id": "t-5", "description": "進行中タスク", "status": "in_progress", "updated_at": "2026-07-01T14:00:00Z"},
    {"task_id": "t-6", "description": "未着手タスク", "status": "pending", "updated_at": ""}
  ]
}
EOF

echo -e "\n${YELLOW}Test 1: git + task-stack 両方あり → 完全な orientation${NC}"
out=$(build_orientation_context "$REPO" "$STACK")
assert_contains "git log 5件目が含まれる" "commit-number-5" "$out"
assert_contains "git log 1件目が含まれる" "commit-number-1" "$out"
assert_contains "進捗 4/6" "進捗: 4/6" "$out"
assert_contains "直近完了に t-4（updated_at 降順先頭）" "t-4" "$out"
assert_contains "見出しが含まれる" "現在地（自動生成 — Orientation）" "$out"
# 直近3件のみ: t-1 は含まれない
if echo "$out" | grep -q "t-1:"; then
  assert_eq "直近3件のみ（t-1 は除外）" "excluded" "included"
else
  assert_eq "直近3件のみ（t-1 は除外）" "excluded" "excluded"
fi

echo -e "\n${YELLOW}Test 2: 非 git dir → task-stack 部分のみ${NC}"
NONGIT="${TMPDIR}/non-git"
mkdir -p "$NONGIT"
out2=$(build_orientation_context "$NONGIT" "$STACK")
assert_contains "進捗は出る" "進捗: 4/6" "$out2"
assert_contains "git 部分は（なし）" "（なし）" "$out2"

echo -e "\n${YELLOW}Test 3: 破損 task-stack → git 部分のみ${NC}"
BROKEN="${TMPDIR}/broken.json"
echo "not json" > "$BROKEN"
out3=$(build_orientation_context "$REPO" "$BROKEN")
assert_contains "git log は出る" "commit-number-5" "$out3"

echo -e "\n${YELLOW}Test 4: 両方不在 → 空出力 + exit 0（set -e 安全）${NC}"
rc=0
out4=$(build_orientation_context "$NONGIT" "${TMPDIR}/nonexistent.json") || rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "空出力" "" "$out4"

echo -e "\n${YELLOW}Test 5: 配線の静的確認（build_implementer_prompt から呼出）${NC}"
WIRED=$(grep -c "build_orientation_context" "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" 2>/dev/null || echo 0)
if [ "$WIRED" -ge 1 ]; then
  assert_eq "ralph-loop.sh が build_orientation_context を呼出" "wired" "wired"
else
  assert_eq "ralph-loop.sh が build_orientation_context を呼出" "wired" "not-wired"
fi
# priming（起動時1回キャッシュ）に混入していないことを確認
PRIMING_HIT=$(grep -c "build_orientation_context" "${PROJECT_ROOT}/.forge/lib/priming.sh" 2>/dev/null || echo 0)
assert_eq "priming.sh に混入していない（毎 attempt fresh 生成の原則）" "0" "$PRIMING_HIT"

# ===== サマリー =====
TOTAL=$((PASS + FAIL))
echo ""
echo -e "${BOLD}=========================================${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL}/${TOTAL}${NC}"
fi
echo -e "${BOLD}=========================================${NC}"

exit "$FAIL"
