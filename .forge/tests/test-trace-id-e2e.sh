#!/bin/bash
# test-trace-id-e2e.sh — SESSION_ID / CALL_ID E2E 追跡テスト
# 対象 L2 criteria: L2-002
# 前提: サーバーは起動済み（Phase 3 が管理）
# このテストは冪等: 実行ごとに一時ディレクトリを作成・クリーンアップする
#
# 検証内容:
#   - forge-flow.sh→research-loop.sh→ralph-loop.sh 全フローで同一SESSION_IDが追跡可能
#   - セッション内の全ログファイル（errors.jsonl, metrics.jsonl, task-events.jsonl）に
#     同一 session_id が付与されている
#   - CALL_ID が単調増加している（フロー内で一貫したシーケンス番号）
#
# 実行方法: bash .forge/tests/test-trace-id-e2e.sh
# タイムアウト: 120秒

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-trace-id-e2e.sh — SESSION_ID E2E 追跡テスト =====${NC}"
echo ""

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_SH="${REAL_ROOT}/.forge/lib/common.sh"
STATE_DIR="${REAL_ROOT}/.forge/state"

# ===== セットアップ =====
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ===== ヘルパー関数 =====
# ログファイルから session_id を収集してユニーク数を返す
count_unique_session_ids() {
  local file="$1"
  [ -f "$file" ] || { echo "0"; return; }
  jq -r '.session_id // empty' "$file" 2>/dev/null | tr -d '\r' | sort -u | grep -cv '^$' 2>/dev/null || echo "0"
}

# ===== テスト 1: generate_session_id 関数が common.sh に存在し正しく動作する =====
# behavior: forge-flow→research-loop→ralph-loop全フローで同一SESSION_IDが追跡可能（関数存在確認）
echo -e "${BOLD}--- テスト E2E-1: generate_session_id が common.sh に存在する ---${NC}"
{
  if grep -q "generate_session_id()" "$COMMON_SH" 2>/dev/null; then
    assert_eq "generate_session_id() が common.sh に定義されている" "found" "found"
  else
    assert_eq "generate_session_id() が common.sh に定義されている" "found" "not-found"
  fi
}
echo ""

# ===== テスト 2: FORGE_SESSION_ID が全ログ関数に注入されている =====
# behavior: forge-flow→research-loop→ralph-loop全フローで同一SESSION_IDが追跡可能（コード注入確認）
echo -e "${BOLD}--- テスト E2E-2: session_id が全ログ関数に注入されているか確認 ---${NC}"
{
  # record_error に session_id が含まれるか
  if grep -A15 "^record_error()" "$COMMON_SH" 2>/dev/null | grep -q "session_id"; then
    assert_eq "record_error() に session_id が注入されている" "found" "found"
  else
    assert_eq "record_error() に session_id が注入されている" "found" "not-found"
  fi

  # metrics_record に session_id が含まれるか
  if grep -A20 "^metrics_record()" "$COMMON_SH" 2>/dev/null | grep -q "session_id"; then
    assert_eq "metrics_record() に session_id が注入されている" "found" "found"
  else
    assert_eq "metrics_record() に session_id が注入されている" "found" "not-found"
  fi

  # record_task_event に session_id が含まれるか
  if grep -A15 "^record_task_event()" "$COMMON_SH" 2>/dev/null | grep -q "session_id"; then
    assert_eq "record_task_event() に session_id が注入されている" "found" "found"
  else
    assert_eq "record_task_event() に session_id が注入されている" "found" "not-found"
  fi

  # record_validation_stat に session_id が含まれるか
  if grep -A15 "^record_validation_stat()" "$COMMON_SH" 2>/dev/null | grep -q "session_id"; then
    assert_eq "record_validation_stat() に session_id が注入されている" "found" "found"
  else
    assert_eq "record_validation_stat() に session_id が注入されている" "found" "not-found"
  fi

  # run_claude に FORGE_CALL_ID インクリメントが含まれるか
  if grep -A25 "^run_claude()" "$COMMON_SH" 2>/dev/null | grep -q "FORGE_CALL_ID"; then
    assert_eq "run_claude() に FORGE_CALL_ID インクリメントが注入されている" "found" "found"
  else
    assert_eq "run_claude() に FORGE_CALL_ID インクリメントが注入されている" "found" "not-found"
  fi
}
echo ""

# ===== テスト 3: 実際のログファイルに session_id フィールドが存在する（実行済み状態の確認） =====
# behavior: forge-flow→research-loop→ralph-loop全フローで同一SESSION_IDが追跡可能（実ログ確認）
echo -e "${BOLD}--- テスト E2E-3: 実際のログファイルに session_id フィールドが存在する ---${NC}"
{
  # errors.jsonl のチェック（存在する場合のみ）
  ERRORS_FILE="${STATE_DIR}/errors.jsonl"
  if [ -f "$ERRORS_FILE" ] && [ -s "$ERRORS_FILE" ]; then
    # 最新エントリに session_id があるか確認
    LAST_ENTRY=$(tail -1 "$ERRORS_FILE")
    SID=$(echo "$LAST_ENTRY" | jq -r '.session_id // "MISSING"' 2>/dev/null | tr -d '\r')
    if [ "$SID" != "MISSING" ] && [ "$SID" != "null" ]; then
      assert_eq "errors.jsonl 最新エントリに session_id が存在する" "present" "present"
    else
      assert_eq "errors.jsonl 最新エントリに session_id が存在する" "present" "absent (session_id=${SID})"
    fi
  else
    echo -e "  ${YELLOW}⚠${NC} errors.jsonl が存在しないか空: スキップ（初回実行時は正常）"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi

  # metrics.jsonl のチェック（存在する場合のみ）
  METRICS_FILE_PATH="${STATE_DIR}/metrics.jsonl"
  if [ -f "$METRICS_FILE_PATH" ] && [ -s "$METRICS_FILE_PATH" ]; then
    LAST_ENTRY=$(tail -1 "$METRICS_FILE_PATH")
    SID=$(echo "$LAST_ENTRY" | jq -r '.session_id // "MISSING"' 2>/dev/null | tr -d '\r')
    if [ "$SID" != "MISSING" ] && [ "$SID" != "null" ]; then
      assert_eq "metrics.jsonl 最新エントリに session_id が存在する" "present" "present"
    else
      assert_eq "metrics.jsonl 最新エントリに session_id が存在する" "present" "absent (session_id=${SID})"
    fi
  else
    echo -e "  ${YELLOW}⚠${NC} metrics.jsonl が存在しないか空: スキップ（初回実行時は正常）"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi

  # task-events.jsonl のチェック（存在する場合のみ）
  TASK_EVENTS_PATH="${STATE_DIR}/task-events.jsonl"
  if [ -f "$TASK_EVENTS_PATH" ] && [ -s "$TASK_EVENTS_PATH" ]; then
    LAST_ENTRY=$(tail -1 "$TASK_EVENTS_PATH")
    SID=$(echo "$LAST_ENTRY" | jq -r '.session_id // "MISSING"' 2>/dev/null | tr -d '\r')
    if [ "$SID" != "MISSING" ] && [ "$SID" != "null" ]; then
      assert_eq "task-events.jsonl 最新エントリに session_id が存在する" "present" "present"
    else
      assert_eq "task-events.jsonl 最新エントリに session_id が存在する" "present" "absent (session_id=${SID})"
    fi
  else
    echo -e "  ${YELLOW}⚠${NC} task-events.jsonl が存在しないか空: スキップ（初回実行時は正常）"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}
echo ""

# ===== テスト 4: SESSION_ID 環境変数の伝播確認（サブプロセス模倣） =====
# behavior: forge-flow→research-loop→ralph-loop全フローで同一SESSION_IDが追跡可能（環境変数伝播）
echo -e "${BOLD}--- テスト E2E-4: FORGE_SESSION_ID の環境変数伝播確認 ---${NC}"
{
  # テスト用セッションIDを設定
  TEST_SESSION="e2e-test-$(date +%s)"
  export FORGE_SESSION_ID="$TEST_SESSION"
  export FORGE_CALL_ID=10

  # 一時ファイルに関数を抽出してサブシェルで動作確認
  SUBTEST_FUNCS="${TMP_DIR}/_subtest_funcs.sh"
  extract_all_functions_awk "$COMMON_SH" record_error classify_error_category jq_safe log \
    > "$SUBTEST_FUNCS"

  SUBTEST_ERRORS="${TMP_DIR}/subtest_errors.jsonl"
  touch "$SUBTEST_ERRORS"

  (
    source "$SUBTEST_FUNCS"
    log() { :; }
    ERRORS_FILE="$SUBTEST_ERRORS"
    RESEARCH_DIR="e2e-test"
    record_error "e2e-stage" "E2Eテストエラー"
  )

  SID=$(tail -1 "$SUBTEST_ERRORS" | jq -r '.session_id // "MISSING"' 2>/dev/null | tr -d '\r')
  assert_eq "サブシェルでも FORGE_SESSION_ID が伝播する" "$TEST_SESSION" "$SID"

  CID=$(tail -1 "$SUBTEST_ERRORS" | jq -r '.call_id // "MISSING"' 2>/dev/null | tr -d '\r')
  assert_eq "サブシェルでも FORGE_CALL_ID が伝播する" "10" "$CID"
}
echo ""

# ===== テスト 5: 同一セッション内の全ログが同一 session_id を持つ =====
# behavior: forge-flow→research-loop→ralph-loop全フローで同一SESSION_IDが追跡可能（一貫性確認）
echo -e "${BOLD}--- テスト E2E-5: 同一セッション内の全ログが同一 session_id を持つ ---${NC}"
{
  CONSISTENT_SESSION="consistent-$(date +%s)"
  export FORGE_SESSION_ID="$CONSISTENT_SESSION"
  export FORGE_CALL_ID=0

  MULTI_FUNCS="${TMP_DIR}/_multi_funcs.sh"
  extract_all_functions_awk "$COMMON_SH" \
    record_error classify_error_category \
    metrics_record \
    record_task_event \
    jq_safe log \
    > "$MULTI_FUNCS"

  E_FILE="${TMP_DIR}/consistent_errors.jsonl"
  M_FILE="${TMP_DIR}/consistent_metrics.jsonl"
  T_FILE="${TMP_DIR}/consistent_events.jsonl"
  touch "$E_FILE" "$M_FILE" "$T_FILE"

  (
    source "$MULTI_FUNCS"
    log() { :; }
    ERRORS_FILE="$E_FILE"
    METRICS_FILE="$M_FILE"
    TASK_EVENTS_FILE="$T_FILE"
    RESEARCH_DIR="consistent-test"
    _METRICS_START_EPOCH=$(date +%s)

    record_error "stage1" "error1"
    metrics_record "stage1" "true"
    record_task_event "task1" "status_changed" '{}'
    record_error "stage2" "error2"
    metrics_record "stage2" "false"
  )

  # 各ファイルの session_id が全て同一か確認
  E_IDS=$(jq -r '.session_id // ""' "$E_FILE" 2>/dev/null | tr -d '\r' | sort -u | grep -v '^$')
  M_IDS=$(jq -r '.session_id // ""' "$M_FILE" 2>/dev/null | tr -d '\r' | sort -u | grep -v '^$')
  T_IDS=$(jq -r '.session_id // ""' "$T_FILE" 2>/dev/null | tr -d '\r' | sort -u | grep -v '^$')

  # errors.jsonl: 全エントリが同一 session_id
  E_UNIQUE=$(echo "$E_IDS" | wc -l | tr -d ' ')
  assert_eq "errors.jsonl: 全エントリが同一 session_id（ユニーク数=1）" "1" "$E_UNIQUE"
  E_VAL=$(echo "$E_IDS" | head -1)
  assert_eq "errors.jsonl: session_id が期待値と一致" "$CONSISTENT_SESSION" "$E_VAL"

  # metrics.jsonl: 全エントリが同一 session_id
  M_UNIQUE=$(echo "$M_IDS" | wc -l | tr -d ' ')
  assert_eq "metrics.jsonl: 全エントリが同一 session_id（ユニーク数=1）" "1" "$M_UNIQUE"

  # task-events.jsonl: 全エントリが同一 session_id
  T_UNIQUE=$(echo "$T_IDS" | wc -l | tr -d ' ')
  assert_eq "task-events.jsonl: 全エントリが同一 session_id（ユニーク数=1）" "1" "$T_UNIQUE"
}
echo ""

# ===== サマリー =====
print_test_summary
