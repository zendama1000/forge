#!/bin/bash
# test-task-state-locking.sh — タスク状態ロック機構テスト
# acquire_lock/release_lock の正常系・競合制御・タイムアウト・staleロック・統合確認を検証。
# 使い方: bash .forge/tests/test-task-state-locking.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-task-state-locking.sh — タスク状態ロック機構 =====${NC}"
echo ""

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_SH="${REAL_ROOT}/.forge/lib/common.sh"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"

# ===== テスト環境セットアップ =====
TEST_DIR=$(mktemp -d)
EXTRACT_FILE=$(mktemp)

cleanup() {
  rm -f "$EXTRACT_FILE" 2>/dev/null || true
  rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${TEST_DIR}/.forge/state/.lock"
mkdir -p "${TEST_DIR}/.forge/logs/development"

# ===== グローバル変数設定 =====
PROJECT_ROOT="$TEST_DIR"
ERRORS_FILE="${TEST_DIR}/.forge/state/errors.jsonl"
json_fail_count=0
RESEARCH_DIR="test-locking"
TASK_STACK="${TEST_DIR}/.forge/state/task-stack.json"
LOOP_SIGNAL_FILE="${TEST_DIR}/.forge/state/loop-signal"
VALIDATION_STATS_FILE="${TEST_DIR}/.forge/state/validation-stats.jsonl"
PROGRESS_FILE="${TEST_DIR}/.forge/state/progress.json"

touch "$ERRORS_FILE"

# テスト共通ロックパス
LOCK_DIR="${TEST_DIR}/.forge/state/.lock/task-stack.lock"

# common.sh を source（acquire_lock / release_lock を含む）
source "$COMMON_SH"

# --------------------------------------------------------------------------
# テスト用ヘルパー
# --------------------------------------------------------------------------

# update_task_status / update_task_fail_count が依存する関数をスタブ化
sync_task_stack() { true; }
record_task_event() { true; }

# タスクスタックを初期化
init_task_stack() {
  cat > "$TASK_STACK" <<'JSON'
{
  "tasks": [
    {
      "task_id": "t1",
      "status": "in_progress",
      "fail_count": 0,
      "updated_at": "2026-01-01T00:00:00Z"
    }
  ],
  "updated_at": "2026-01-01T00:00:00Z"
}
JSON
}

# --------------------------------------------------------------------------
# テスト 1: 正常系 — ロック取得・解放
# behavior: update_task_status()呼出時に .forge/state/.lock/task-stack.lock ディレクトリが作成され、操作完了後に削除される（正常系: ロック取得・解放）
# --------------------------------------------------------------------------
echo -e "${BOLD}--- Test 1: 正常系 ロック取得・解放 ---${NC}"

# acquire_lock がロックディレクトリを作成する
acquire_lock "$LOCK_DIR" 10 0.5
acquire_rc=$?

assert_eq "acquire_lock が exit 0 を返す" "0" "$acquire_rc"
assert_eq "ロック取得後にディレクトリが存在する" "true" "$([ -d "$LOCK_DIR" ] && echo true || echo false)"

# release_lock がロックディレクトリを削除する
release_lock "$LOCK_DIR"

assert_eq "release_lock 後にディレクトリが削除される" "true" "$([ ! -d "$LOCK_DIR" ] && echo true || echo false)"

echo ""

# --------------------------------------------------------------------------
# テスト 2: 競合制御 — 待機リトライ
# behavior: ロック保持中に別シェルプロセスからupdate_task_status()を呼出 → 最大10秒間0.5秒間隔でリトライ後にロック取得（競合制御: 待機リトライ）
# --------------------------------------------------------------------------
echo -e "${BOLD}--- Test 2: 競合制御 待機リトライ ---${NC}"

# 別プロセスがロックを2秒間保持してから解放する
mkdir -p "$(dirname "$LOCK_DIR")"
mkdir "$LOCK_DIR"
( sleep 2; rmdir "$LOCK_DIR" 2>/dev/null || true ) &
BG_PID=$!

# acquire_lock は最大10秒待機し、2秒後にロック取得できるはず
start_t=$(date +%s)
acquire_lock "$LOCK_DIR" 10 0.5
contention_rc=$?
end_t=$(date +%s)
elapsed=$(( end_t - start_t ))

wait "$BG_PID" 2>/dev/null || true

assert_eq "競合後にロック取得成功(exit 0)" "0" "$contention_rc"

# 少なくとも1秒以上待機していることを確認（0.5s間隔で2sの待機）
if [ "$elapsed" -ge 1 ]; then
  assert_eq "待機リトライ後に取得（1秒以上経過）" "true" "true"
else
  assert_eq "待機リトライ後に取得（1秒以上経過）" "true" "false（elapsed=${elapsed}s）"
fi

release_lock "$LOCK_DIR"

echo ""

# --------------------------------------------------------------------------
# テスト 3: 異常系 — タイムアウト
# behavior: ロック取得タイムアウト（10秒）到達 → エラーログ'Lock acquisition timeout'が出力されexit 1（異常系: デッドロック防止）
# --------------------------------------------------------------------------
echo -e "${BOLD}--- Test 3: 異常系 タイムアウト ---${NC}"

# ロックを手動で保持（解放しない）
mkdir "$LOCK_DIR"

# 2秒タイムアウトで試行（テスト高速化のため: 実際の10秒挙動を短縮して検証）
timeout_output=$(acquire_lock "$LOCK_DIR" 2 0.5 2>&1)
timeout_rc=$?

# ロックを手動解放（後続テストのため）
rmdir "$LOCK_DIR" 2>/dev/null || true

assert_eq "タイムアウト時に exit 1 を返す" "1" "$timeout_rc"
assert_contains "エラーログ 'Lock acquisition timeout' が出力される" "Lock acquisition timeout" "$timeout_output"

echo ""

# --------------------------------------------------------------------------
# テスト 4: staleロック自動回復
# behavior: ロックディレクトリのmtime > 60秒（stale lock）→ 自動削除してから新規ロック取得（エッジケース: 異常終了後の自動回復）
# --------------------------------------------------------------------------
echo -e "${BOLD}--- Test 4: staleロック自動回復 ---${NC}"

# staleロックを作成（mtimeを2分前に設定）
mkdir "$LOCK_DIR"
stale_ts=$(date -d '2 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo "202601010000.00")
touch -t "$stale_ts" "$LOCK_DIR" 2>/dev/null || touch -t "202601010000.00" "$LOCK_DIR"

# staleロック検出: 自動削除してロック取得できることを確認
stale_output=$(acquire_lock "$LOCK_DIR" 10 0.5 2>&1)
stale_rc=$?

assert_eq "staleロック削除後にロック取得成功(exit 0)" "0" "$stale_rc"
assert_eq "新規ロックディレクトリが存在する" "true" "$([ -d "$LOCK_DIR" ] && echo true || echo false)"
assert_contains "staleロック検出ログが出力される" "stale lock" "$stale_output"

release_lock "$LOCK_DIR"
assert_eq "解放後にディレクトリが削除される" "true" "$([ ! -d "$LOCK_DIR" ] && echo true || echo false)"

echo ""

# --------------------------------------------------------------------------
# テスト 5: 統合確認 — update_task_fail_count が acquire_lock/release_lock を使用
# behavior: update_task_fail_count()もupdate_task_status()と同じロック機構（acquire_lock/release_lock関数）を使用する（統合確認: 共通関数利用）
# --------------------------------------------------------------------------
echo -e "${BOLD}--- Test 5: 統合確認 共通関数利用 ---${NC}"

# ralph-loop.sh から update_task_status と update_task_fail_count を抽出
extract_all_functions_awk "$RALPH_SH" \
  update_task_status update_task_fail_count \
  > "$EXTRACT_FILE"

# モニタリング用カウンタ
_ACQUIRE_COUNT=0
_RELEASE_COUNT=0

# acquire_lock / release_lock をモックに差し替えてカウント
acquire_lock() {
  _ACQUIRE_COUNT=$(( _ACQUIRE_COUNT + 1 ))
  mkdir -p "$(dirname "$1")" 2>/dev/null || true
  mkdir "$1" 2>/dev/null || true
  return 0
}
release_lock() {
  _RELEASE_COUNT=$(( _RELEASE_COUNT + 1 ))
  rmdir "$1" 2>/dev/null || rm -rf "$1" 2>/dev/null || true
}

source "$EXTRACT_FILE"

# --- update_task_status が acquire_lock / release_lock を呼ぶことを確認 ---
init_task_stack
_ACQUIRE_COUNT=0
_RELEASE_COUNT=0

update_task_status "t1" "completed"

assert_eq "update_task_status が acquire_lock を呼ぶ" "1" "$_ACQUIRE_COUNT"
assert_eq "update_task_status が release_lock を呼ぶ" "1" "$_RELEASE_COUNT"

# --- update_task_fail_count が acquire_lock / release_lock を呼ぶことを確認 ---
init_task_stack
_ACQUIRE_COUNT=0
_RELEASE_COUNT=0

update_task_fail_count "t1" 1

assert_eq "update_task_fail_count が acquire_lock を呼ぶ" "1" "$_ACQUIRE_COUNT"
assert_eq "update_task_fail_count が release_lock を呼ぶ" "1" "$_RELEASE_COUNT"

echo ""

# --------------------------------------------------------------------------
# サマリー
# --------------------------------------------------------------------------
print_test_summary
