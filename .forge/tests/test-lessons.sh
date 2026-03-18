#!/bin/bash
# test-lessons.sh — Lessons Learned ユニットテスト
set -euo pipefail

source "$(dirname "$0")/test-helpers.sh"

echo -e "${BOLD}=== Lessons Learned テスト ===${NC}"

# ===== セットアップ =====
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PROJECT_ROOT="$TMPDIR_BASE"
RESEARCH_DIR="test-session"
mkdir -p "$TMPDIR_BASE/.forge/state"

# common.sh から必要な関数を抽出して source
REAL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# 直接 source すると依存が多いため、関数だけ抽出
extract_all_functions_awk "${REAL_ROOT}/.forge/lib/common.sh" \
  record_lesson get_relevant_lessons jq_safe log > "${TMPDIR_BASE}/_funcs.sh"
source "${TMPDIR_BASE}/_funcs.sh"

LESSONS_FILE="${TMPDIR_BASE}/.forge/state/lessons-learned.jsonl"
touch "$LESSONS_FILE"

# ===== テスト 1: record_lesson で JSONL に記録 =====
echo ""
echo "--- テスト: record_lesson 基本記録 ---"
record_lesson "test_framework" "vitest not found" "npm install vitest" "task-01"
count=$(wc -l < "$LESSONS_FILE" | tr -d ' ')
assert_eq "1件記録" "1" "$count"
assert_contains "カテゴリ記録" '"category":"test_framework"' "$(cat "$LESSONS_FILE")"
assert_contains "パターン記録" '"pattern":"vitest not found"' "$(cat "$LESSONS_FILE")"
assert_contains "解決策記録" '"resolution":"npm install vitest"' "$(cat "$LESSONS_FILE")"

# ===== テスト 2: 重複記録のスキップ =====
echo ""
echo "--- テスト: 重複スキップ ---"
record_lesson "test_framework" "vitest not found" "different resolution" "task-02"
count=$(wc -l < "$LESSONS_FILE" | tr -d ' ')
assert_eq "重複スキップ" "1" "$count"

# ===== テスト 3: 異なるパターンは記録 =====
echo ""
echo "--- テスト: 異なるパターンは記録 ---"
record_lesson "path_issue" "Windows path mismatch" "use forward slashes" "task-03"
count=$(wc -l < "$LESSONS_FILE" | tr -d ' ')
assert_eq "2件記録" "2" "$count"

# ===== テスト 4: get_relevant_lessons — vitest 関連 =====
echo ""
echo "--- テスト: get_relevant_lessons vitest 関連 ---"
task_json='{"validation":{"layer_1":{"command":"npx vitest run test.spec.ts"}}}'
lessons=$(get_relevant_lessons "$task_json")
assert_contains "vitest レッスン返却" "vitest not found" "$lessons"

# ===== テスト 5: get_relevant_lessons — path 関連 =====
echo ""
echo "--- テスト: get_relevant_lessons path 関連 ---"
task_json='{"validation":{"layer_1":{"command":"bash check-path.sh /tmp/output"}}}'
lessons=$(get_relevant_lessons "$task_json")
assert_contains "path レッスン返却" "Windows path" "$lessons"

# ===== テスト 6: get_relevant_lessons — ファイル不在時 =====
echo ""
echo "--- テスト: get_relevant_lessons ファイル不在 ---"
LESSONS_FILE="${TMPDIR_BASE}/nonexistent.jsonl"
task_json='{"validation":{"layer_1":{"command":"test"}}}'
lessons=$(get_relevant_lessons "$task_json")
assert_eq "空出力" "" "$lessons"

# ===== テスト 7: record_lesson — 空パターンはスキップ =====
echo ""
echo "--- テスト: 空パターンスキップ ---"
LESSONS_FILE="${TMPDIR_BASE}/.forge/state/lessons-learned.jsonl"
before_count=$(wc -l < "$LESSONS_FILE" | tr -d ' ')
record_lesson "other" "" "some resolution" "task-04"
after_count=$(wc -l < "$LESSONS_FILE" | tr -d ' ')
assert_eq "空パターンは記録されない" "$before_count" "$after_count"

# ===== テスト 8: investigation.sh の category 分類確認 =====
echo ""
echo "--- テスト: category 分類パターン ---"
# case 文のパターンマッチをシミュレート
check_category() {
  local root_cause="$1"
  local lesson_category="other"
  case "$root_cause" in
    *vitest*|*jest*|*mocha*|*test*framework*) lesson_category="test_framework" ;;
    *path*|*パス*|*Windows*|*windows*) lesson_category="path_issue" ;;
    *timeout*|*タイムアウト*) lesson_category="timeout" ;;
    *not\ found*|*未作成*|*存在しない*) lesson_category="hallucination" ;;
    *file*limit*|*ファイル数*) lesson_category="file_limit" ;;
  esac
  echo "$lesson_category"
}

assert_eq "vitest → test_framework" "test_framework" "$(check_category "vitest module resolution failed")"
assert_eq "Windows path → path_issue" "path_issue" "$(check_category "Windows path separator")"
assert_eq "timeout → timeout" "timeout" "$(check_category "connection timeout after 30s")"
assert_eq "not found → hallucination" "hallucination" "$(check_category "file not found: test.spec.ts")"
assert_eq "file limit → file_limit" "file_limit" "$(check_category "file limit exceeded")"
assert_eq "unknown → other" "other" "$(check_category "some random error")"

# ===== サマリー =====
print_test_summary
