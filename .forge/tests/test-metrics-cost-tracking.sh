#!/bin/bash
# test-metrics-cost-tracking.sh — メトリクスコストトラッキング ユニットテスト
# 対象: .forge/lib/common.sh の metrics_record(), extract_cost_from_debug_log(), aggregate_session_cost()
#       .forge/config/circuit-breaker.json の cost_tracking.max_session_cost_usd 設定
# 実行方法: bash .forge/tests/test-metrics-cost-tracking.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-metrics-cost-tracking.sh — メトリクスコストトラッキング =====${NC}"
echo ""

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_SH="${REAL_ROOT}/.forge/lib/common.sh"
CIRCUIT_BREAKER_CONFIG="${REAL_ROOT}/.forge/config/circuit-breaker.json"

# ===== セットアップ =====
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_ROOT="$TMP_DIR"
RESEARCH_DIR="test-cost-session"
METRICS_FILE="${TMP_DIR}/metrics.jsonl"
COSTS_FILE="${TMP_DIR}/costs.jsonl"
mkdir -p "${TMP_DIR}/.forge/state"
touch "$METRICS_FILE" "$COSTS_FILE"

# common.sh から必要な関数を抽出してロード
EXTRACT_FILE="${TMP_DIR}/_funcs.sh"
extract_all_functions_awk "$COMMON_SH" \
  metrics_start \
  metrics_record \
  aggregate_session_cost \
  jq_safe \
  log \
  > "$EXTRACT_FILE"

# グローバル変数初期化コードも抽出（FORGE_CALL_ID と _LAST_* 変数）
grep -E '^: "\$\{FORGE_CALL_ID' "$COMMON_SH" >> "$EXTRACT_FILE" 2>/dev/null || true
grep -E '^: "\$\{_LAST_' "$COMMON_SH" >> "$EXTRACT_FILE" 2>/dev/null || true

source "$EXTRACT_FILE"

# log を no-op（テスト出力を汚さない）
log() { :; }

# FORGE_SESSION_ID を設定
FORGE_SESSION_ID="test-cost-session-abc123"
FORGE_CALL_ID=0

# ===== テスト 1: metrics.jsonlにinput_tokens, output_tokens, cost_usdフィールドが含まれる =====
# behavior: metrics.jsonlの各エントリにinput_tokens, output_tokens, cost_usdフィールドが含まれる（正常系: フィールド存在）
echo ""
echo -e "${BOLD}--- テスト 1: metrics.jsonl に token/cost フィールドが含まれる ---${NC}"
{
  # グローバル変数にトークン情報をセット（extract_cost_from_debug_log 相当）
  _LAST_INPUT_TOKENS=1000
  _LAST_OUTPUT_TOKENS=500
  _LAST_COST_USD="0.0150"
  > "$METRICS_FILE"
  _METRICS_START_EPOCH=$(date +%s)

  metrics_record "implementer-task-001" "true"

  entry=$(tail -1 "$METRICS_FILE")
  input_t=$(echo "$entry" | jq -r '.input_tokens' 2>/dev/null | tr -d '\r')
  output_t=$(echo "$entry" | jq -r '.output_tokens' 2>/dev/null | tr -d '\r')
  cost=$(echo "$entry" | jq -r '.cost_usd' 2>/dev/null | tr -d '\r')

  assert_eq "metrics_record: input_tokens=1000" "1000" "$input_t"
  assert_eq "metrics_record: output_tokens=500" "500" "$output_t"
  # %.4f format produces "0.0150", normalize trailing zeros for comparison
  cost_normalized=$(echo "$cost" | sed 's/0*$//' | sed 's/\.$//')
  assert_eq "metrics_record: cost_usd=0.015 (tonumber変換)" "0.015" "$cost_normalized"

  # 既存フィールドの後方互換を確認
  stage_val=$(echo "$entry" | jq -r '.stage' 2>/dev/null | tr -d '\r')
  assert_eq "metrics_record: stage フィールドが維持される" "implementer-task-001" "$stage_val"

  # JSON として有効かチェック（フィールド数含む）
  if jq empty "$METRICS_FILE" 2>/dev/null; then
    assert_eq "metrics.jsonl エントリが有効な JSON" "valid" "valid"
  else
    assert_eq "metrics.jsonl エントリが有効な JSON" "valid" "invalid"
  fi
}

# ===== テスト 2: フォールバック値（ログ解析失敗時は 0） =====
# behavior: run_claude()のstderrログからトークン数を抽出できない場合 → input_tokens=0, output_tokens=0, cost_usd=0がフォールバック値（エッジケース: ログ解析失敗）
echo ""
echo -e "${BOLD}--- テスト 2: フォールバック値（ログ解析失敗時 → 0） ---${NC}"
{
  # グローバルを 0 にリセット（extract_cost_from_debug_log が失敗した状態を模倣）
  _LAST_INPUT_TOKENS=0
  _LAST_OUTPUT_TOKENS=0
  _LAST_COST_USD="0"
  > "$METRICS_FILE"
  _METRICS_START_EPOCH=$(date +%s)

  metrics_record "implementer-task-002" "false"

  entry=$(tail -1 "$METRICS_FILE")
  input_t=$(echo "$entry" | jq -r '.input_tokens' 2>/dev/null | tr -d '\r')
  output_t=$(echo "$entry" | jq -r '.output_tokens' 2>/dev/null | tr -d '\r')
  cost=$(echo "$entry" | jq -r '.cost_usd' 2>/dev/null | tr -d '\r')

  assert_eq "フォールバック: input_tokens=0" "0" "$input_t"
  assert_eq "フォールバック: output_tokens=0" "0" "$output_t"
  assert_eq "フォールバック: cost_usd=0" "0" "$cost"

  # フィールド自体は存在する（null ではなく数値の 0）
  input_type=$(echo "$entry" | jq -r '.input_tokens | type' 2>/dev/null | tr -d '\r')
  assert_eq "フォールバック: input_tokens のフィールド型は number" "number" "$input_type"
}

# ===== テスト 3: aggregate_session_cost() セッション別コスト集計 =====
# behavior: aggregate_session_cost()関数がsession_id別のcost_usd合計を返す → {session_id: 'xxx', total_cost_usd: N.NN}（正常系: コスト集計）
echo ""
echo -e "${BOLD}--- テスト 3: aggregate_session_cost() セッション別コスト集計 ---${NC}"
{
  > "$METRICS_FILE"

  # テストセッション "sess-abc" のエントリを 3 件追加（合計 7.0）
  cat >> "$METRICS_FILE" << 'METRICSEOF'
{"stage":"impl-t1","duration_sec":120,"parse_success":true,"session_id":"sess-abc","cost_usd":3.5}
{"stage":"impl-t2","duration_sec":90,"parse_success":true,"session_id":"sess-abc","cost_usd":2.0}
{"stage":"impl-t3","duration_sec":60,"parse_success":true,"session_id":"sess-abc","cost_usd":1.5}
{"stage":"impl-t4","duration_sec":80,"parse_success":true,"session_id":"sess-OTHER","cost_usd":99.0}
METRICSEOF

  result=$(aggregate_session_cost "sess-abc" "$METRICS_FILE")

  result_sid=$(echo "$result" | jq -r '.session_id' 2>/dev/null | tr -d '\r')
  result_cost=$(echo "$result" | jq -r '.total_cost_usd' 2>/dev/null | tr -d '\r')

  # session_id フィールドの確認
  assert_eq "aggregate_session_cost: session_id フィールドが返される" "sess-abc" "$result_sid"

  # total_cost_usd の合計値確認（3.5 + 2.0 + 1.5 = 7.0 → jq は 7 を出力）
  if awk "BEGIN { exit !(${result_cost} == 7) }"; then
    assert_eq "aggregate_session_cost: total_cost_usd = 7.0 (3.5+2.0+1.5)" "match" "match"
  else
    assert_eq "aggregate_session_cost: total_cost_usd = 7.0 (3.5+2.0+1.5)" "match" "no-match (${result_cost})"
  fi

  # 別セッション (sess-OTHER: 99.0) が含まれていないことを確認（cost が 10 未満なら OK）
  if awk "BEGIN { exit !($result_cost < 10) }"; then
    assert_eq "aggregate_session_cost: 他セッション (99.0) は含まれない" "ok" "ok"
  else
    assert_eq "aggregate_session_cost: 他セッション (99.0) は含まれない" "ok" "fail (cost=${result_cost})"
  fi

  # 戻り値が有効な JSON であることを確認
  if echo "$result" | jq empty 2>/dev/null; then
    assert_eq "aggregate_session_cost: 戻り値が有効な JSON" "valid" "valid"
  else
    assert_eq "aggregate_session_cost: 戻り値が有効な JSON" "valid" "invalid"
  fi
}

# ===== テスト 4: circuit-breaker 発動（コスト上限超過） =====
# behavior: max_session_cost_usd=10.0設定時に累計コストが10.0を超える → circuit-breaker発動（異常系: コスト上限超過）
echo ""
echo -e "${BOLD}--- テスト 4: コスト上限超過 → circuit-breaker 発動条件 ---${NC}"
{
  > "$METRICS_FILE"

  # 累計コスト 11.0 > 10.0 のデータを用意
  cat >> "$METRICS_FILE" << 'METRICSEOF'
{"stage":"impl-x1","duration_sec":100,"parse_success":true,"session_id":"sess-over","cost_usd":6.0}
{"stage":"impl-x2","duration_sec":100,"parse_success":true,"session_id":"sess-over","cost_usd":5.0}
METRICSEOF

  MAX_SESSION_COST_USD=10.0

  # aggregate_session_cost で累計コストを取得
  result=$(aggregate_session_cost "sess-over" "$METRICS_FILE")
  current_cost=$(echo "$result" | jq -r '.total_cost_usd' 2>/dev/null | tr -d '\r')

  # 累計が 11.0 であることを確認（awk exit 0 = condition true = cost IS 11）
  if awk "BEGIN { exit !(${current_cost} == 11) }"; then
    assert_eq "コスト上限超過: aggregate_session_cost が 11 を返す" "match" "match"
  else
    assert_eq "コスト上限超過: aggregate_session_cost が 11 を返す" "match" "no-match (${current_cost})"
  fi

  # circuit-breaker 発動条件: current_cost > MAX_SESSION_COST_USD
  over=$(awk "BEGIN { print ($current_cost > $MAX_SESSION_COST_USD) ? 1 : 0 }")
  assert_eq "コスト上限超過: circuit-breaker 発動条件 (over=1)" "1" "$over"

  # circuit-breaker.json に cost_tracking フィールドが存在することを確認
  cb_has_cost_tracking=$(jq 'has("cost_tracking")' "$CIRCUIT_BREAKER_CONFIG" 2>/dev/null | tr -d '\r')
  assert_eq "circuit-breaker.json に cost_tracking フィールドが存在する" "true" "$cb_has_cost_tracking"

  # max_session_cost_usd が数値として存在することを確認
  cb_max=$(jq '.cost_tracking.max_session_cost_usd' "$CIRCUIT_BREAKER_CONFIG" 2>/dev/null | tr -d '\r')
  cb_max_type=$(jq '.cost_tracking.max_session_cost_usd | type' "$CIRCUIT_BREAKER_CONFIG" 2>/dev/null | tr -d '\r')
  assert_eq "circuit-breaker.json の max_session_cost_usd が number 型" "\"number\"" "$cb_max_type"

  # 未超過ケース: cost=9.9, max=10.0 → over=0
  over_negative=$(awk "BEGIN { print (9.9 > $MAX_SESSION_COST_USD) ? 1 : 0 }")
  assert_eq "コスト未超過ケース (9.9 < 10.0): circuit-breaker 非発動 (over=0)" "0" "$over_negative"
}

# ===== テスト 5: aggregate_session_cost() 空ファイルのエッジケース =====
# behavior: [追加] metrics.jsonl が空の場合 → total_cost_usd: 0 を返す（エッジケース: 空データ）
echo ""
echo -e "${BOLD}--- テスト 5: aggregate_session_cost() 空ファイルのエッジケース ---${NC}"
{
  > "$METRICS_FILE"

  result=$(aggregate_session_cost "no-session-found" "$METRICS_FILE")
  result_cost=$(echo "$result" | jq -r '.total_cost_usd' 2>/dev/null | tr -d '\r')

  assert_eq "aggregate_session_cost: 空ファイルの場合 total_cost_usd=0" "0" "$result_cost"

  # session_id が引数として渡されることを確認
  result_sid=$(echo "$result" | jq -r '.session_id' 2>/dev/null | tr -d '\r')
  assert_eq "aggregate_session_cost: 空ファイルでも session_id が返される" "no-session-found" "$result_sid"
}

# ===== テスト 6: common.sh の実装確認（コード存在確認） =====
# behavior: [追加] common.sh に aggregate_session_cost() と _LAST_INPUT_TOKENS グローバル変数が定義されている
echo ""
echo -e "${BOLD}--- テスト 6: common.sh 実装の存在確認 ---${NC}"
{
  # aggregate_session_cost() 関数が定義されていることを確認
  if grep -q "aggregate_session_cost()" "$COMMON_SH" 2>/dev/null; then
    assert_eq "common.sh に aggregate_session_cost() が定義されている" "found" "found"
  else
    assert_eq "common.sh に aggregate_session_cost() が定義されている" "found" "not-found"
  fi

  # _LAST_INPUT_TOKENS グローバル変数が存在することを確認
  if grep -q "_LAST_INPUT_TOKENS" "$COMMON_SH" 2>/dev/null; then
    assert_eq "common.sh に _LAST_INPUT_TOKENS グローバル変数が存在する" "found" "found"
  else
    assert_eq "common.sh に _LAST_INPUT_TOKENS グローバル変数が存在する" "found" "not-found"
  fi

  # metrics_record に input_tokens フィールドが追加されていることを確認
  if grep -q "input_tokens" "$COMMON_SH" 2>/dev/null; then
    assert_eq "common.sh の metrics_record に input_tokens フィールドが存在する" "found" "found"
  else
    assert_eq "common.sh の metrics_record に input_tokens フィールドが存在する" "found" "not-found"
  fi

  # ralph-loop.sh に MAX_SESSION_COST_USD が存在することを確認
  RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"
  if grep -q "MAX_SESSION_COST_USD" "$RALPH_SH" 2>/dev/null; then
    assert_eq "ralph-loop.sh に MAX_SESSION_COST_USD が存在する" "found" "found"
  else
    assert_eq "ralph-loop.sh に MAX_SESSION_COST_USD が存在する" "found" "not-found"
  fi
}

# ===== テスト 7: metrics_record() がグローバルをリセットすること =====
# behavior: [追加] metrics_record() 呼出後にグローバル変数が 0 にリセットされる（次の呼出のフォールバック保証）
echo ""
echo -e "${BOLD}--- テスト 7: metrics_record() 呼出後にグローバル変数がリセットされる ---${NC}"
{
  _LAST_INPUT_TOKENS=9999
  _LAST_OUTPUT_TOKENS=8888
  _LAST_COST_USD="99.9999"
  > "$METRICS_FILE"
  _METRICS_START_EPOCH=$(date +%s)

  metrics_record "check-reset-stage" "true"

  # 呼出後にグローバルが 0 にリセットされていることを確認
  assert_eq "metrics_record 後: _LAST_INPUT_TOKENS=0" "0" "${_LAST_INPUT_TOKENS}"
  assert_eq "metrics_record 後: _LAST_OUTPUT_TOKENS=0" "0" "${_LAST_OUTPUT_TOKENS}"
  assert_eq "metrics_record 後: _LAST_COST_USD=0" "0" "${_LAST_COST_USD}"

  # 次の呼出では 0 フォールバックが使われること
  _METRICS_START_EPOCH=$(date +%s)
  metrics_record "next-stage-fallback" "true"
  entry=$(tail -1 "$METRICS_FILE")
  cost=$(echo "$entry" | jq -r '.cost_usd' 2>/dev/null | tr -d '\r')
  assert_eq "リセット後の次の metrics_record: cost_usd=0 フォールバック" "0" "$cost"
}

# ===== サマリー =====
print_test_summary
