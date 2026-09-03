#!/bin/bash
# test-stop-hook.sh — .claude/hooks/stop-check-harness-changes.sh の 3 検査（batch#11 R01）
#   未コミット変更 / 未追跡ハーネスファイル / 出荷遅延（origin/master 未反映 + 7 日超の feature/*）
#   常に exit 0、3 検査は独立（早期 return なし）、4 秒未満
# 使い方: bash .forge/tests/test-stop-hook.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

HOOK="${PROJECT_ROOT}/.claude/hooks/stop-check-harness-changes.sh"
TMP=$(mktemp -d 2>/dev/null || echo "/tmp/stop-hook-$$")
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo -e "${BOLD}===== test-stop-hook.sh — 出荷衛生 Stop hook =====${NC}"
echo ""

# ===== fixture repo =====
REPO="${TMP}/repo"
mkdir -p "${REPO}/.forge/lib" "${REPO}/.forge/loops" "${REPO}/.claude"
git -C "$REPO" init -q -b master
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo "x" > "${REPO}/.forge/lib/common.sh"; echo "# claude" > "${REPO}/CLAUDE.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init
# origin/master を疑似的に用意（master と同じ）
git -C "$REPO" update-ref refs/remotes/origin/master HEAD
# 10 日前のコミットを持つ未マージ feature/stale
old_date="$(date -d '-10 days' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
git -C "$REPO" checkout -q -b feature/stale
echo "stale" > "${REPO}/.forge/lib/stale.sh"; git -C "$REPO" add -A
GIT_COMMITTER_DATE="$old_date" GIT_AUTHOR_DATE="$old_date" git -C "$REPO" commit -q -m stale
# 当日の未マージ feature/fresh
git -C "$REPO" checkout -q master; git -C "$REPO" checkout -q -b feature/fresh
echo "fresh" > "${REPO}/.forge/lib/fresh.sh"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m fresh
# 10 日前だがマージ済み feature/shipped
git -C "$REPO" checkout -q master; git -C "$REPO" checkout -q -b feature/shipped
echo "shipped" > "${REPO}/.forge/lib/shipped.sh"; git -C "$REPO" add -A
GIT_COMMITTER_DATE="$old_date" GIT_AUTHOR_DATE="$old_date" git -C "$REPO" commit -q -m shipped
git -C "$REPO" checkout -q master; git -C "$REPO" merge -q --ff-only feature/shipped
git -C "$REPO" update-ref refs/remotes/origin/master HEAD

run_hook() { CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" 2>"${TMP}/err.txt"; echo $?; }

# ========================================================================
echo -e "${BOLD}--- Group 1: クリーンな状態 ---${NC}"
# ========================================================================
rc=$(run_hook)
assert_eq "exit 0" "0" "$rc"
err=$(cat "${TMP}/err.txt")
assert_contains "出荷遅延: feature/stale（10 日・未マージ）を警告" "feature/stale" "$err"
assert_not_contains "当日の feature/fresh は警告しない" "feature/fresh" "$err"
assert_not_contains "マージ済みの feature/shipped は警告しない（10 日でも）" "feature/shipped" "$err"
assert_not_contains "未コミット変更の警告は出ない" "未コミット" "$err"
assert_not_contains "未追跡の警告は出ない" "未追跡" "$err"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: 3 検査は独立に発火する ---${NC}"
# ========================================================================
echo "changed" >> "${REPO}/.forge/lib/common.sh"          # 未コミット変更
echo "new" > "${REPO}/.forge/lib/new-lib.sh"               # 未追跡ハーネスファイル
mkdir -p "${REPO}/.forge/state"; echo "{}" > "${REPO}/.forge/state/x.json"   # 実行時生成物（対象外）
start=$(date +%s)
rc=$(run_hook)
elapsed=$(( $(date +%s) - start ))
err=$(cat "${TMP}/err.txt")
assert_eq "exit 0（警告があっても止めない）" "0" "$rc"
assert_contains "未コミット変更を警告" "未コミットの変更が 1 件" "$err"
assert_contains "未追跡ハーネスファイルを警告" "未追跡のハーネスファイルが 1 件" "$err"
assert_contains "未追跡の警告にファイル名" "new-lib.sh" "$err"
assert_contains "出荷遅延も同時に警告（早期 return なし）" "feature/stale" "$err"
assert_not_contains ".forge/state は未追跡に数えない" "x.json" "$err"
assert_eq "5 秒未満（Stop hook の timeout=5 内。Windows は git spawn ≈ 0.3 秒/回）" "true" "$([ "$elapsed" -lt 5 ] && echo true || echo false)"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: origin/master が無い / git 外 ---${NC}"
# ========================================================================
git -C "$REPO" update-ref -d refs/remotes/origin/master
rc=$(run_hook)
err=$(cat "${TMP}/err.txt")
assert_eq "origin/master 不在でも exit 0" "0" "$rc"
assert_not_contains "origin/master 不在なら出荷遅延は判定しない" "出荷遅延" "$err"
assert_contains "他の検査は動く" "未コミット" "$err"
NOGIT="${TMP}/nogit"; mkdir -p "$NOGIT"
rc=$(CLAUDE_PROJECT_DIR="$NOGIT" bash "$HOOK" 2>/dev/null; echo $?)
assert_eq "git リポジトリ外は exit 0（無言）" "0" "$rc"
echo ""

print_test_summary
