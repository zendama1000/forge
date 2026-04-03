#!/bin/bash
# test-init-session-state.sh — init_session_state() の単体テスト
set -uo pipefail

source "$(dirname "$0")/test-helpers.sh"

FORGE_FLOW="$(cd "$(dirname "$0")/../loops" && pwd)/forge-flow.sh"

# 共通スタブ
log() { :; }

# ===== ヘルパー =====
count_dirs() {
  # サブディレクトリ数を安全にカウント（グロブ不一致でもエラーにならない）
  local parent="$1"
  if [ ! -d "$parent" ]; then echo 0; return; fi
  local c=0
  for d in "$parent"/*/; do
    [ -d "$d" ] && c=$((c + 1))
  done
  echo "$c"
}

count_files() {
  # ファイル数を安全にカウント
  local dir="$1" pattern="${2:-*}"
  if [ ! -d "$dir" ]; then echo 0; return; fi
  local c=0
  for f in "$dir"/$pattern; do
    [ -f "$f" ] && c=$((c + 1))
  done
  echo "$c"
}

setup_test_state() {
  local dir="$1"
  mkdir -p "$dir"/{checkpoints,.lock,phase-tests,test-verification,notifications,archive}

  # セッション固有ファイル
  echo '{"completed_phase":"1"}' > "$dir/flow-state.json"
  echo '{"phase":"development"}' > "$dir/progress.json"
  echo '{"loop":"ralph"}' > "$dir/heartbeat.json"
  echo '{"tasks":[]}' > "$dir/task-stack.json"
  echo '{"research_dir":"x"}' > "$dir/current-research.json"
  echo '{}' > "$dir/monitor-snapshot.json"
  echo '{}' > "$dir/excluded-elements.json"
  echo '{}' > "$dir/session-counters.json"
  echo '{}' > "$dir/synthesis.json"

  # ログファイル
  for f in metrics.jsonl task-events.jsonl investigation-log.jsonl \
           validation-stats.jsonl decisions.jsonl errors.jsonl \
           lessons-learned.jsonl approach-barriers.jsonl \
           ralph-loop.log forge-flow.log; do
    echo "data" > "$dir/$f"
  done

  # パターンファイル
  echo '{}' > "$dir/l3-judge-L3-001-1234.json"
  echo '{}' > "$dir/l3-judge-L3-002-5678.json"
  echo 'resume' > "$dir/ralph-loop-resume.log"
  echo 'rerun' > "$dir/ralph-loop-rerun.log"

  # notifications
  echo '{}' > "$dir/notifications/n-20260301-123456.json"
  echo '{}' > "$dir/notifications/n-20260302-654321.json"

  # checkpoints にダミー
  echo 'cp1' > "$dir/checkpoints/cp1.json"

  # 永続ファイル（アーカイブ対象外）
  echo 'report' > "$dir/harness-bug-report-20260301.md"
  echo 'feedback' > "$dir/feedback-queue.json"
  echo 'notif config' > "$dir/notifications.json"
}

# forge-flow.sh から init_session_state 関数を抽出してロード
load_init_fn() {
  local fn_body
  fn_body=$(awk '
    /^init_session_state\(\)/ { found=1; depth=0; start_line=NR }
    found {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      print
      if (depth <= 0 && NR > start_line) { found=0; print "" }
    }
  ' "$FORGE_FLOW")

  if [ -z "$fn_body" ]; then
    echo -e "${RED}✗ init_session_state() を forge-flow.sh から抽出できません${NC}"
    exit 1
  fi
  eval "$fn_body"
}

load_init_fn

# ===== テスト1: 前回セッションなし =====
echo ""
echo -e "${BOLD}Test 1: 前回セッションなし（flow-state.json 不在）${NC}"

TMPDIR1=$(mktemp -d)
STATE_DIR="$TMPDIR1"
_RESUME=false

init_session_state

assert_eq "アーカイブなし" "0" "$(count_dirs "$TMPDIR1/archive")"

rm -rf "$TMPDIR1"

# ===== テスト2: 通常セッション → アーカイブ＋クリーンアップ =====
echo ""
echo -e "${BOLD}Test 2: 通常セッション → state がアーカイブされる${NC}"

TMPDIR2=$(mktemp -d)
STATE_DIR="$TMPDIR2"
_RESUME=false

setup_test_state "$TMPDIR2"
init_session_state

# セッションファイルがクリアされている
for f in flow-state.json progress.json task-stack.json heartbeat.json \
         current-research.json synthesis.json monitor-snapshot.json; do
  assert_eq "$f 削除" "false" "$([ -f "$TMPDIR2/$f" ] && echo true || echo false)"
done

# ログファイルがクリアされている
for f in metrics.jsonl decisions.jsonl ralph-loop.log forge-flow.log; do
  assert_eq "$f 削除" "false" "$([ -f "$TMPDIR2/$f" ] && echo true || echo false)"
done

# パターンファイルがクリアされている
assert_eq "l3-judge-*.json 全削除" "0" "$(count_files "$TMPDIR2" "l3-judge-*.json")"
assert_eq "ralph-loop-*.log 全削除" "0" "$(count_files "$TMPDIR2" "ralph-loop-*.log")"

# notifications 内がクリアされている
assert_eq "notifications/ 内クリア" "0" "$(count_files "$TMPDIR2/notifications")"

# ディレクトリが再作成されている
for d in checkpoints .lock phase-tests test-verification; do
  assert_eq "$d/ 再作成" "true" "$([ -d "$TMPDIR2/$d" ] && echo true || echo false)"
done

# アーカイブ確認
assert_eq "アーカイブ1件作成" "1" "$(count_dirs "$TMPDIR2/archive")"
archive_dir=""
for d in "$TMPDIR2"/archive/*/; do [ -d "$d" ] && archive_dir="$d" && break; done

assert_eq "flow-state.json in archive" "true" "$([ -f "${archive_dir}flow-state.json" ] && echo true || echo false)"
assert_eq "metrics.jsonl in archive" "true" "$([ -f "${archive_dir}metrics.jsonl" ] && echo true || echo false)"
assert_eq "checkpoints/ in archive" "true" "$([ -d "${archive_dir}checkpoints" ] && echo true || echo false)"
assert_eq "l3-judge in archive" "true" "$([ -f "${archive_dir}l3-judge-L3-001-1234.json" ] && echo true || echo false)"
assert_eq "notifications in archive" "true" "$([ -f "${archive_dir}notifications/n-20260301-123456.json" ] && echo true || echo false)"

# 永続ファイルは残っている
assert_eq "harness-bug-report 残留" "true" "$([ -f "$TMPDIR2/harness-bug-report-20260301.md" ] && echo true || echo false)"
assert_eq "feedback-queue.json 残留" "true" "$([ -f "$TMPDIR2/feedback-queue.json" ] && echo true || echo false)"
assert_eq "notifications.json 残留" "true" "$([ -f "$TMPDIR2/notifications.json" ] && echo true || echo false)"

rm -rf "$TMPDIR2"

# ===== テスト3: --resume → state 保持 =====
echo ""
echo -e "${BOLD}Test 3: --resume モード → state が保持される${NC}"

TMPDIR3=$(mktemp -d)
STATE_DIR="$TMPDIR3"
_RESUME=true

setup_test_state "$TMPDIR3"
init_session_state

assert_eq "flow-state.json 保持" "true" "$([ -f "$TMPDIR3/flow-state.json" ] && echo true || echo false)"
assert_eq "task-stack.json 保持" "true" "$([ -f "$TMPDIR3/task-stack.json" ] && echo true || echo false)"
assert_eq "metrics.jsonl 保持" "true" "$([ -f "$TMPDIR3/metrics.jsonl" ] && echo true || echo false)"
assert_eq "アーカイブ不作成" "0" "$(count_dirs "$TMPDIR3/archive")"

rm -rf "$TMPDIR3"

# ===== テスト4: アーカイブローテーション（直近5件保持） =====
echo ""
echo -e "${BOLD}Test 4: アーカイブローテーション → 直近5件のみ保持${NC}"

TMPDIR4=$(mktemp -d)
STATE_DIR="$TMPDIR4"
_RESUME=false
mkdir -p "$TMPDIR4/archive"

# 古いアーカイブ7件を事前作成
for i in 1 2 3 4 5 6 7; do
  d="$TMPDIR4/archive/2026010${i}-120000"
  mkdir -p "$d"
  echo "old-$i" > "$d/flow-state.json"
done

setup_test_state "$TMPDIR4"
init_session_state

# 古い7件 + 新しい1件 = 8件中、直近5件のみ保持
assert_eq "アーカイブ5件保持" "5" "$(count_dirs "$TMPDIR4/archive")"

# 古い3件（20260101, 20260102, 20260103）が削除されている
assert_eq "最古アーカイブ削除" "false" "$([ -d "$TMPDIR4/archive/20260101-120000" ] && echo true || echo false)"
assert_eq "2番目も削除" "false" "$([ -d "$TMPDIR4/archive/20260102-120000" ] && echo true || echo false)"
assert_eq "3番目も削除" "false" "$([ -d "$TMPDIR4/archive/20260103-120000" ] && echo true || echo false)"

rm -rf "$TMPDIR4"

# ===== テスト5: 空の notifications → エラーなし =====
echo ""
echo -e "${BOLD}Test 5: 空の notifications → エラーなし${NC}"

TMPDIR5=$(mktemp -d)
STATE_DIR="$TMPDIR5"
_RESUME=false

setup_test_state "$TMPDIR5"
rm -f "$TMPDIR5"/notifications/*.json

init_session_state

assert_eq "正常完了（アーカイブ作成）" "1" "$(count_dirs "$TMPDIR5/archive")"

rm -rf "$TMPDIR5"

# ===== サマリー =====
print_test_summary
exit $?
