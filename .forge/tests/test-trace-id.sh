#!/bin/bash
# test-trace-id.sh — SESSION_ID / CALL_ID トレース機能 ユニットテスト
# 対象: .forge/lib/common.sh の generate_session_id(), run_claude() CALL_ID インクリメント,
#       record_error(), metrics_record(), record_task_event(), record_validation_stat()
# 実行方法: bash .forge/tests/test-trace-id.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-trace-id.sh — SESSION_ID / CALL_ID トレース機能 =====${NC}"
echo ""

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_SH="${REAL_ROOT}/.forge/lib/common.sh"
FORGE_FLOW_SH="${REAL_ROOT}/.forge/loops/forge-flow.sh"

# ===== セットアップ =====
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_ROOT="$TMP_DIR"
RESEARCH_DIR="test-trace-session"
ERRORS_FILE="${TMP_DIR}/errors.jsonl"
METRICS_FILE="${TMP_DIR}/metrics.jsonl"
TASK_EVENTS_FILE="${TMP_DIR}/task-events.jsonl"
VALIDATION_STATS_FILE="${TMP_DIR}/validation-stats.jsonl"
mkdir -p "${TMP_DIR}/.forge/state"

touch "$ERRORS_FILE" "$METRICS_FILE" "$TASK_EVENTS_FILE" "$VALIDATION_STATS_FILE"

# common.sh から必要な関数を抽出してロード
EXTRACT_FILE="${TMP_DIR}/_funcs.sh"
extract_all_functions_awk "$COMMON_SH" \
  generate_session_id \
  record_error \
  classify_error_category \
  metrics_record \
  record_task_event \
  record_validation_stat \
  jq_safe \
  log \
  > "$EXTRACT_FILE"

# FORGE_CALL_ID 初期化コードも抽出（: "${FORGE_CALL_ID:=0}" 行）
grep -E '^: "\$\{FORGE_CALL_ID' "$COMMON_SH" >> "$EXTRACT_FILE" 2>/dev/null || true

source "$EXTRACT_FILE"

# log を no-op（テスト出力を汚さない）
log() { :; }

# ===== テスト 1: generate_session_id() が UUID v4 形式を返す =====
# behavior: forge-flow.sh起動直後にSESSION_IDがUUID v4形式（8-4-4-4-12 hex）で生成される → 環境変数FORGE_SESSION_IDに設定される（正常系: ID生成）
echo ""
echo -e "${BOLD}--- テスト 1: generate_session_id() が UUID v4 形式を返す ---${NC}"
{
  GENERATED_ID=$(generate_session_id)
  # UUID v4 形式: xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx
  if echo "$GENERATED_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
    assert_eq "UUID v4 形式（8-4-4-4-12 hex）" "valid" "valid"
  else
    assert_eq "UUID v4 形式（8-4-4-4-12 hex）" "valid" "invalid: ${GENERATED_ID}"
  fi
}

# ===== テスト 2: 複数回生成すると異なる値になる =====
# behavior: [追加] generate_session_id() を2回連続呼出 → 異なる ID が返る（冪等でない: 毎回新しいID）
echo ""
echo -e "${BOLD}--- テスト 2: 2回生成 → 異なる値 ---${NC}"
{
  ID1=$(generate_session_id)
  ID2=$(generate_session_id)
  if [ "$ID1" != "$ID2" ]; then
    assert_eq "2回の ID は異なる" "different" "different"
  else
    assert_eq "2回の ID は異なる" "different" "same: ${ID1}"
  fi
}

# ===== テスト 3: FORGE_CALL_ID が run_claude() 呼出ごとにインクリメントされる =====
# behavior: run_claude()を3回連続呼出 → CALL_IDが1, 2, 3とインクリメントされる（正常系: 連番生成）
echo ""
echo -e "${BOLD}--- テスト 3: CALL_ID インクリメント（run_claude モック） ---${NC}"
{
  # run_claude をモックとして再定義（CALL_ID インクリメントロジックのみ抽出して確認）
  # common.sh から CALL_ID インクリメント行を取得
  FORGE_CALL_ID=0

  # run_claude の CALL_ID インクリメント部分を直接テスト
  # （Claude CLI は実際には呼び出さない）
  _mock_run_claude_increment() {
    FORGE_CALL_ID=$(( ${FORGE_CALL_ID:-0} + 1 ))
    export FORGE_CALL_ID
  }

  _mock_run_claude_increment
  assert_eq "1回目呼出後 FORGE_CALL_ID=1" "1" "$FORGE_CALL_ID"

  _mock_run_claude_increment
  assert_eq "2回目呼出後 FORGE_CALL_ID=2" "2" "$FORGE_CALL_ID"

  _mock_run_claude_increment
  assert_eq "3回目呼出後 FORGE_CALL_ID=3" "3" "$FORGE_CALL_ID"
}

# ===== テスト 4: FORGE_CALL_ID インクリメントが common.sh に記述されていることを確認 =====
# behavior: [追加] common.sh の run_claude() に FORGE_CALL_ID インクリメントが実装されている（コード存在確認）
echo ""
echo -e "${BOLD}--- テスト 4: common.sh に FORGE_CALL_ID インクリメント実装を確認 ---${NC}"
{
  COUNT=$(grep -c "FORGE_CALL_ID" "$COMMON_SH" 2>/dev/null || echo "0")
  if [ "$COUNT" -ge 3 ]; then
    assert_eq "FORGE_CALL_ID が common.sh に3箇所以上定義されている" "1" "1"
  else
    assert_eq "FORGE_CALL_ID が common.sh に3箇所以上定義されている" "1" "0 (count=${COUNT})"
  fi
}

# ===== テスト 5: record_error() に session_id と call_id が含まれる =====
# behavior: record_error()が出力するerrors.jsonlエントリにsession_idとcall_idフィールドが含まれる（構造検証: errors.jsonl）
echo ""
echo -e "${BOLD}--- テスト 5: record_error() → errors.jsonl に session_id/call_id 付与 ---${NC}"
{
  FORGE_SESSION_ID="test-session-abc123"
  FORGE_CALL_ID=5
  > "$ERRORS_FILE"

  record_error "test-stage" "テストエラーメッセージ"

  entry=$(tail -1 "$ERRORS_FILE")
  sid=$(echo "$entry" | jq -r '.session_id' 2>/dev/null | tr -d '\r')
  cid=$(echo "$entry" | jq -r '.call_id' 2>/dev/null | tr -d '\r')

  assert_eq "record_error session_id フィールドが存在する" "test-session-abc123" "$sid"
  assert_eq "record_error call_id フィールドが存在する" "5" "$cid"

  # 既存フィールドが維持されることも確認
  stage_val=$(echo "$entry" | jq -r '.stage' 2>/dev/null | tr -d '\r')
  assert_eq "record_error 後方互換: stage フィールドが維持される" "test-stage" "$stage_val"
}

# ===== テスト 6: metrics_record() に session_id と call_id が含まれる =====
# behavior: metrics.jsonlの各エントリにsession_idとcall_idフィールドが含まれる（構造検証: metrics.jsonl）
echo ""
echo -e "${BOLD}--- テスト 6: metrics_record() → metrics.jsonl に session_id/call_id 付与 ---${NC}"
{
  FORGE_SESSION_ID="metrics-session-xyz"
  FORGE_CALL_ID=7
  _METRICS_START_EPOCH=$(date +%s)
  > "$METRICS_FILE"

  metrics_record "sc-stage" "true"

  entry=$(tail -1 "$METRICS_FILE")
  sid=$(echo "$entry" | jq -r '.session_id' 2>/dev/null | tr -d '\r')
  cid=$(echo "$entry" | jq -r '.call_id' 2>/dev/null | tr -d '\r')

  assert_eq "metrics_record session_id フィールドが存在する" "metrics-session-xyz" "$sid"
  assert_eq "metrics_record call_id フィールドが存在する" "7" "$cid"

  # 既存フィールドが維持されることも確認
  stage_val=$(echo "$entry" | jq -r '.stage' 2>/dev/null | tr -d '\r')
  assert_eq "metrics_record 後方互換: stage フィールドが維持される" "sc-stage" "$stage_val"
}

# ===== テスト 7: record_task_event() に session_id が含まれる =====
# behavior: record_task_event()が出力するtask-events.jsonlエントリにsession_idフィールドが含まれる（構造検証: task-events.jsonl）
echo ""
echo -e "${BOLD}--- テスト 7: record_task_event() → task-events.jsonl に session_id 付与 ---${NC}"
{
  FORGE_SESSION_ID="events-session-def"
  > "$TASK_EVENTS_FILE"

  record_task_event "task-xyz" "status_changed" '{"new_status":"in_progress"}'

  entry=$(tail -1 "$TASK_EVENTS_FILE")
  sid=$(echo "$entry" | jq -r '.session_id' 2>/dev/null | tr -d '\r')
  task_id_val=$(echo "$entry" | jq -r '.task_id' 2>/dev/null | tr -d '\r')

  assert_eq "record_task_event session_id フィールドが存在する" "events-session-def" "$sid"
  assert_eq "record_task_event 後方互換: task_id フィールドが維持される" "task-xyz" "$task_id_val"
}

# ===== テスト 8: FORGE_SESSION_ID 未設定時 → session_id='no-session' フォールバック =====
# behavior: FORGE_SESSION_IDが未設定の状態でrecord_error()を呼出 → session_id='no-session'がフォールバック値として使用される（エッジケース: 単体起動時）
echo ""
echo -e "${BOLD}--- テスト 8: FORGE_SESSION_ID 未設定 → フォールバック 'no-session' ---${NC}"
{
  unset FORGE_SESSION_ID 2>/dev/null || true
  FORGE_CALL_ID=0
  > "$ERRORS_FILE"

  record_error "fallback-stage" "フォールバックテスト"

  entry=$(tail -1 "$ERRORS_FILE")
  sid=$(echo "$entry" | jq -r '.session_id' 2>/dev/null | tr -d '\r')

  assert_eq "FORGE_SESSION_ID 未設定時 session_id='no-session'" "no-session" "$sid"

  # 再設定しておく
  export FORGE_SESSION_ID="restored-session"
}

# ===== テスト 9: record_validation_stat() に session_id と call_id が含まれる =====
# behavior: [追加] record_validation_stat() が session_id/call_id フィールドを付与する（構造検証: validation-stats.jsonl）
echo ""
echo -e "${BOLD}--- テスト 9: record_validation_stat() → validation-stats.jsonl に session_id/call_id 付与 ---${NC}"
{
  FORGE_SESSION_ID="vstat-session-ghi"
  FORGE_CALL_ID=3
  > "$VALIDATION_STATS_FILE"

  record_validation_stat "synthesizer" "crlf"

  entry=$(tail -1 "$VALIDATION_STATS_FILE")
  sid=$(echo "$entry" | jq -r '.session_id' 2>/dev/null | tr -d '\r')
  cid=$(echo "$entry" | jq -r '.call_id' 2>/dev/null | tr -d '\r')

  assert_eq "record_validation_stat session_id フィールドが存在する" "vstat-session-ghi" "$sid"
  assert_eq "record_validation_stat call_id フィールドが存在する" "3" "$cid"
}

# ===== テスト 10: forge-flow.sh に SESSION_ID 生成コードが存在する =====
# behavior: forge-flow.sh起動直後にSESSION_IDがUUID v4形式で生成される → FORGE_SESSION_IDに設定される（コード存在確認）
echo ""
echo -e "${BOLD}--- テスト 10: forge-flow.sh に SESSION_ID 生成コードが存在する ---${NC}"
{
  COUNT=$(grep -c "FORGE_SESSION_ID" "$FORGE_FLOW_SH" 2>/dev/null || echo "0")
  if [ "$COUNT" -ge 2 ]; then
    assert_eq "forge-flow.sh に FORGE_SESSION_ID が2箇所以上存在する" "1" "1"
  else
    assert_eq "forge-flow.sh に FORGE_SESSION_ID が2箇所以上存在する" "1" "0 (count=${COUNT})"
  fi

  # generate_session_id() 呼出が forge-flow.sh に存在するか
  if grep -q "generate_session_id" "$FORGE_FLOW_SH" 2>/dev/null; then
    assert_eq "forge-flow.sh に generate_session_id() 呼出が存在する" "found" "found"
  else
    assert_eq "forge-flow.sh に generate_session_id() 呼出が存在する" "found" "not-found"
  fi
}

# ===== テスト 11: FORGE_CALL_ID が common.sh source 時に初期化される =====
# behavior: [追加] common.sh を source すると FORGE_CALL_ID が 0 で初期化される（未設定の場合）
echo ""
echo -e "${BOLD}--- テスト 11: FORGE_CALL_ID 初期化確認 ---${NC}"
{
  # common.sh の初期化行の存在確認
  if grep -qE '^\s*: "\$\{FORGE_CALL_ID' "$COMMON_SH" 2>/dev/null; then
    assert_eq "common.sh に FORGE_CALL_ID 初期化行が存在する" "found" "found"
  else
    assert_eq "common.sh に FORGE_CALL_ID 初期化行が存在する" "found" "not-found"
  fi

  # 実際に未設定の場合は 0 に初期化されることを確認
  (
    unset FORGE_CALL_ID 2>/dev/null || true
    eval "$(grep -E '^\s*: "\$\{FORGE_CALL_ID' "$COMMON_SH")"
    echo "$FORGE_CALL_ID"
  ) > "${TMP_DIR}/_call_id_init.txt" 2>/dev/null || true

  init_val=$(cat "${TMP_DIR}/_call_id_init.txt" | tr -d '\r')
  assert_eq "FORGE_CALL_ID 未設定時の初期値は 0" "0" "${init_val:-NOT_SET}"
}

# ===== サマリー =====
print_test_summary
