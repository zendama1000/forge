#!/bin/bash
# test-research-e2e-with-classification.sh — SC→R→Syn→DA フロー E2E テスト (モックベース)
#
# 検証する振る舞い:
#   1. error_category フィールドが record_error で付与されるか
#      (timeout / rate_limit / invalid_json / empty_output / unknown)
#   2. 全件失敗→クールダウンリトライ→回復シナリオで json_fail_count がリセットされるか
#   3. AUTO-ABORT シナリオで current-research.json が 'auto-abort-json-failures' になるか
#
# 実際のAPIコールは不要。関数レベルのモックで振る舞いを検証する。
# 使い方: bash .forge/tests/test-research-e2e-with-classification.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-research-e2e-with-classification.sh — SC→R→Syn→DA E2E (モック) =====${NC}"
echo ""

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESEARCH_LOOP="${REAL_ROOT}/.forge/loops/research-loop.sh"

# ===== テスト環境セットアップ =====
PROJECT_ROOT="$(mktemp -d)"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'; rm -rf '$PROJECT_ROOT'" EXIT

mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"
mkdir -p "${PROJECT_ROOT}/.forge/logs/research"
mkdir -p "${PROJECT_ROOT}/.claude/agents"

cp "${REAL_ROOT}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${REAL_ROOT}/.forge/lib/bootstrap.sh" "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"
cp "${REAL_ROOT}/.forge/config/circuit-breaker.json" "${PROJECT_ROOT}/.forge/config/circuit-breaker.json"

# ===== 共通変数 =====
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
VALIDATION_STATS_FILE="${PROJECT_ROOT}/.forge/state/validation-stats.jsonl"
METRICS_FILE="${PROJECT_ROOT}/.forge/state/metrics.jsonl"
PROGRESS_FILE="${PROJECT_ROOT}/.forge/state/progress.json"
RESEARCH_DIR="${PROJECT_ROOT}/research-e2e"
LOG_DIR="${PROJECT_ROOT}/.forge/logs/research"
STATE_FILE="${PROJECT_ROOT}/.forge/state/current-research.json"
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
json_fail_count=0
CLAUDE_TIMEOUT=600

touch "$ERRORS_FILE"
touch "$VALIDATION_STATS_FILE"
touch "$METRICS_FILE"
mkdir -p "$RESEARCH_DIR"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== circuit-breaker 設定 =====
MAX_JSON_FAILS_PER_LOOP=$(jq_safe -r '.research_limits.max_json_fails_per_loop // 3' "$CIRCUIT_BREAKER_CONFIG")
PARALLEL_ALL_FAIL_COOLDOWN_SEC=$(jq_safe -r '.research_limits.parallel_all_fail_cooldown_sec // 30' "$CIRCUIT_BREAKER_CONFIG")
PERSPECTIVE_MAX_CONSECUTIVE_FAILS=$(jq_safe -r '.research_limits.perspective_max_consecutive_fails // 3' "$CIRCUIT_BREAKER_CONFIG")
export COOLDOWN_SEC=0

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
extract_all_functions_awk "$RESEARCH_LOOP" \
  _get_perspective_fail_count \
  _set_perspective_fail_count \
  should_skip_perspective \
  > "$EXTRACT_FILE"
source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} 関数抽出完了"
echo ""

# ===== モック定義 =====
update_state() {
  local stage="$1"
  local status="${2:-running}"
  jq -n \
    --arg status "$status" \
    --arg stage "$stage" \
    --arg updated "$(date -Iseconds)" \
    '{status: $status, current_stage: $stage, updated_at: $updated}' \
    > "$STATE_FILE"
}
update_progress() { :; }
metrics_start() { :; }
metrics_record() { :; }

# ===== 集約ロジック（インライン） =====
_AGG_OUT="${PROJECT_ROOT}/.agg_result"
_RETRY_OUT="${PROJECT_ROOT}/.retry_result"

do_parallel_aggregation() {
  local perspectives
  perspectives=$(cat "$1")
  local result_dir="$2"
  local pass_round_count=0
  local active_run_count=0
  for perspective in $perspectives; do
    local status="fail"
    [ -f "${result_dir}/${perspective}.status" ] && status=$(cat "${result_dir}/${perspective}.status")
    if [ "$status" = "pass" ]; then
      pass_round_count=$((pass_round_count + 1))
      active_run_count=$((active_run_count + 1))
      _set_perspective_fail_count "$perspective" 0
    elif [ "$status" = "skipped" ]; then
      :
    else
      active_run_count=$((active_run_count + 1))
      json_fail_count=$((json_fail_count + 1))
      local new_fail_count
      new_fail_count=$(( $(_get_perspective_fail_count "$perspective") + 1 ))
      _set_perspective_fail_count "$perspective" "$new_fail_count"
    fi
  done
  echo "${pass_round_count}:${active_run_count}" > "$_AGG_OUT"
}

do_retry_aggregation() {
  local perspectives
  perspectives=$(cat "$1")
  local result_dir="$2"
  local active_run_count="$3"
  json_fail_count=$((json_fail_count - active_run_count))
  local retry_pass_count=0
  for perspective in $perspectives; do
    local r_status="fail"
    [ -f "${result_dir}/${perspective}.status" ] && r_status=$(cat "${result_dir}/${perspective}.status")
    [ "$r_status" = "skipped" ] && continue
    if [ "$r_status" = "pass" ]; then
      retry_pass_count=$((retry_pass_count + 1))
      _set_perspective_fail_count "$perspective" 0
    else
      json_fail_count=$((json_fail_count + 1))
      local retry_fail_count
      retry_fail_count=$(( $(_get_perspective_fail_count "$perspective") + 1 ))
      _set_perspective_fail_count "$perspective" "$retry_fail_count"
    fi
  done
  if [ "$retry_pass_count" -ge 3 ]; then
    json_fail_count=0
    echo "recovered:${retry_pass_count}" > "$_RETRY_OUT"
  else
    update_state "aborted" "auto-abort-json-failures"
    echo "auto-abort:${retry_pass_count}" > "$_RETRY_OUT"
  fi
}

# ===================================================================
echo -e "${BOLD}===== Part E1: error_category 付与確認 =====${NC}"
# ===================================================================
echo -e "${BOLD}--- E1-1: classify_error_category — timeout (exit_code 124) ---${NC}"

# exit code 124 → "timeout"
cat1=$(classify_error_category "Claude実行エラー" "124")
assert_eq "E1-1: exit_code=124 → timeout" "timeout" "$cat1"

# メッセージに "timeout" → "timeout"
cat2=$(classify_error_category "タイムアウト（600秒）" "")
assert_eq "E1-2: message contains 'timeout' → timeout" "timeout" "$cat2"

# 429 / rate_limit
cat3=$(classify_error_category "429 Too Many Requests" "")
assert_eq "E1-3: 429 → rate_limit" "rate_limit" "$cat3"

cat4=$(classify_error_category "rate_limit exceeded" "")
assert_eq "E1-4: rate_limit in message → rate_limit" "rate_limit" "$cat4"

# 不正なJSON
cat5=$(classify_error_category "出力が不正なJSON" "")
assert_eq "E1-5: 不正なJSON → invalid_json" "invalid_json" "$cat5"

# 空出力
cat6=$(classify_error_category "出力が空" "")
assert_eq "E1-6: 空出力 → empty_output" "empty_output" "$cat6"

# 不明
cat7=$(classify_error_category "Claude実行エラー" "1")
assert_eq "E1-7: unknown error → unknown" "unknown" "$cat7"

echo ""

# ===================================================================
echo -e "${BOLD}--- E1-2: record_error が error_category を付与するか ---${NC}"

# エラーを記録
record_error "researcher-market" "出力が空"
record_error "researcher-tech" "タイムアウト（600秒）"
record_error "researcher-competitive" "429 Too Many Requests"

# ERRORS_FILE の内容を確認
empty_cat=$(grep "researcher-market" "$ERRORS_FILE" | jq_safe -r '.error_category' 2>/dev/null | head -1)
assert_eq "E1-8: market error → empty_output category" "empty_output" "$empty_cat"

timeout_cat=$(grep "researcher-tech" "$ERRORS_FILE" | jq_safe -r '.error_category' 2>/dev/null | head -1)
assert_eq "E1-9: tech error → timeout category" "timeout" "$timeout_cat"

rate_cat=$(grep "researcher-competitive" "$ERRORS_FILE" | jq_safe -r '.error_category' 2>/dev/null | head -1)
assert_eq "E1-10: competitive error → rate_limit category" "rate_limit" "$rate_cat"

echo ""

# ===================================================================
echo -e "${BOLD}===== Part E2: クールダウンリトライ→回復シナリオ =====${NC}"
# ===================================================================
echo -e "${BOLD}--- E2: 全件失敗→クールダウン→4件回復→json_fail_countリセット ---${NC}"

RESULT_DIR_E2="${RESEARCH_DIR}/.researcher-results-e2"
mkdir -p "$RESULT_DIR_E2"
PERSPECTIVES_E2="p1 p2 p3 p4 p5 p6"
echo "$PERSPECTIVES_E2" > "${PROJECT_ROOT}/.plist_e2"

# フェーズ1: 全件失敗
for p in $PERSPECTIVES_E2; do
  echo "fail" > "${RESULT_DIR_E2}/${p}.status"
done
json_fail_count=0
do_parallel_aggregation "${PROJECT_ROOT}/.plist_e2" "$RESULT_DIR_E2"
agg_line=$(cat "$_AGG_OUT")
pass_cnt="${agg_line%%:*}"
active_cnt="${agg_line##*:}"

assert_eq "E2-1: 全件失敗: pass_count=0" "0" "$pass_cnt"
assert_eq "E2-2: 全件失敗: active_count=6" "6" "$active_cnt"

# 全件同時失敗フラグ確認
full_fail="false"
[ "$active_cnt" -gt 0 ] && [ "$pass_cnt" -eq 0 ] && full_fail="true"
assert_eq "E2-3: 全件同時失敗フラグ=true" "true" "$full_fail"

# クールダウン: COOLDOWN_SEC=0 でスキップ
_cooldown="${COOLDOWN_SEC:-${PARALLEL_ALL_FAIL_COOLDOWN_SEC}}"
sleep "$_cooldown"  # COOLDOWN_SEC=0 なので実質即時

# フェーズ2: リトライ後4件回復
echo "pass" > "${RESULT_DIR_E2}/p1.status"
echo "pass" > "${RESULT_DIR_E2}/p2.status"
echo "pass" > "${RESULT_DIR_E2}/p3.status"
echo "pass" > "${RESULT_DIR_E2}/p4.status"
echo "fail" > "${RESULT_DIR_E2}/p5.status"
echo "fail" > "${RESULT_DIR_E2}/p6.status"

do_retry_aggregation "${PROJECT_ROOT}/.plist_e2" "$RESULT_DIR_E2" "$active_cnt"
retry_line=$(cat "$_RETRY_OUT")
retry_verdict="${retry_line%%:*}"
retry_pass_n="${retry_line##*:}"

assert_eq "E2-4: リトライ後回復 verdict=recovered" "recovered" "$retry_verdict"
assert_eq "E2-5: リトライ後回復 pass_count=4" "4" "$retry_pass_n"
assert_eq "E2-6: 回復後 json_fail_countリセット=0" "0" "$json_fail_count"

echo ""

# ===================================================================
echo -e "${BOLD}===== Part E3: AUTO-ABORT シナリオ =====${NC}"
# ===================================================================
echo -e "${BOLD}--- E3: 全件失敗→リトライ後も全件失敗→AUTO-ABORT ---${NC}"

RESULT_DIR_E3="${RESEARCH_DIR}/.researcher-results-e3"
mkdir -p "$RESULT_DIR_E3"
PERSPECTIVES_E3="q1 q2 q3 q4 q5 q6"
echo "$PERSPECTIVES_E3" > "${PROJECT_ROOT}/.plist_e3"

# フェーズ1: 全件失敗
for p in $PERSPECTIVES_E3; do
  echo "fail" > "${RESULT_DIR_E3}/${p}.status"
done
json_fail_count=0
do_parallel_aggregation "${PROJECT_ROOT}/.plist_e3" "$RESULT_DIR_E3"
agg_line=$(cat "$_AGG_OUT")
active_cnt="${agg_line##*:}"

# クールダウン（スキップ）
_cooldown="${COOLDOWN_SEC:-${PARALLEL_ALL_FAIL_COOLDOWN_SEC}}"
sleep "$_cooldown"

# フェーズ2: リトライ後も全件失敗（0件成功）
for p in $PERSPECTIVES_E3; do
  echo "fail" > "${RESULT_DIR_E3}/${p}.status"
done

do_retry_aggregation "${PROJECT_ROOT}/.plist_e3" "$RESULT_DIR_E3" "$active_cnt"
retry_line=$(cat "$_RETRY_OUT")
retry_verdict="${retry_line%%:*}"
retry_pass_n="${retry_line##*:}"

assert_eq "E3-1: AUTO-ABORT verdict" "auto-abort" "$retry_verdict"
assert_eq "E3-2: AUTO-ABORT pass_count=0" "0" "$retry_pass_n"

# current-research.json の status を確認
state_status=$(jq_safe -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null)
assert_eq "E3-3: STATE_FILE status=auto-abort-json-failures" "auto-abort-json-failures" "$state_status"

echo ""

# ===================================================================
echo -e "${BOLD}===== Part E4: 個別perspective連続失敗スキップ→他perspective継続 =====${NC}"
# ===================================================================
echo -e "${BOLD}--- E4: perspective 'bad' が3回失敗→スキップ、他は継続 ---${NC}"

RESULT_DIR_E4="${RESEARCH_DIR}/.researcher-results-e4"
mkdir -p "$RESULT_DIR_E4"
PERSPECTIVES_E4="good1 good2 bad good3"
echo "$PERSPECTIVES_E4" > "${PROJECT_ROOT}/.plist_e4"

# 初期化
for p in $PERSPECTIVES_E4; do
  _set_perspective_fail_count "$p" 0
done

# ラウンド1〜3: bad が連続失敗、good* は成功
for round in 1 2 3; do
  echo "fail" > "${RESULT_DIR_E4}/bad.status"
  for p in good1 good2 good3; do
    echo "pass" > "${RESULT_DIR_E4}/${p}.status"
  done
  json_fail_count=0
  do_parallel_aggregation "${PROJECT_ROOT}/.plist_e4" "$RESULT_DIR_E4"
done

bad_fail=$(_get_perspective_fail_count "bad")
assert_eq "E4-1: bad perspective fail_count=3 (3連続失敗)" "3" "$bad_fail"

# bad はスキップ判定
should_skip_perspective "bad" 2>/dev/null
skip_bad=$?
assert_eq "E4-2: bad should_skip=true (return 0)" "0" "$skip_bad"

# good1 はスキップされない
should_skip_perspective "good1" 2>/dev/null
skip_good1=$?
assert_eq "E4-3: good1 should_skip=false (return 1)" "1" "$skip_good1"

# ラウンド4: bad=skipped、good* は pass
echo "skipped" > "${RESULT_DIR_E4}/bad.status"
for p in good1 good2 good3; do
  echo "pass" > "${RESULT_DIR_E4}/${p}.status"
done
json_fail_count=0
do_parallel_aggregation "${PROJECT_ROOT}/.plist_e4" "$RESULT_DIR_E4"
agg_line=$(cat "$_AGG_OUT")
pass_cnt="${agg_line%%:*}"
active_cnt="${agg_line##*:}"

assert_eq "E4-4: スキップ後 pass=3 (good*のみ)" "3" "$pass_cnt"
assert_eq "E4-5: スキップ後 active=3 (skipped除外)" "3" "$active_cnt"
assert_eq "E4-6: スキップ後 json_fail_count=0 (bad失敗カウントなし)" "0" "$json_fail_count"

# 全件失敗フラグが立たないことを確認（skipped を除いた active > 0 かつ pass > 0）
full_fail="false"
[ "$active_cnt" -gt 0 ] && [ "$pass_cnt" -eq 0 ] && full_fail="true"
assert_eq "E4-7: スキップ後も全件失敗フラグ=false (ループ継続)" "false" "$full_fail"

echo ""

# ===================================================================
echo -e "${BOLD}===== Part E5: 設定整合性チェック =====${NC}"
# ===================================================================
echo -e "${BOLD}--- E5: circuit-breaker.json / research-loop.sh の整合確認 ---${NC}"

# research-loop.sh に全件失敗検出のロジックが存在するか
has_all_fail_detect=$(grep -c "parallel_all_failed\|pass_round_count.*-eq.*0\|pass_round_count -eq 0" \
  "${REAL_ROOT}/.forge/loops/research-loop.sh" 2>/dev/null || echo 0)
# 代替: "all 0" パターンを確認
has_zero_check=$(grep -c "pass_round_count" "${REAL_ROOT}/.forge/loops/research-loop.sh" 2>/dev/null || echo 0)
[ "$has_zero_check" -ge 2 ] && e5_pass_check="ok" || e5_pass_check="missing"
assert_eq "E5-1: research-loop.sh に pass_round_count 使用箇所>=2" "ok" "$e5_pass_check"

# AUTO-ABORT の記述が存在するか
has_auto_abort=$(grep -c "auto-abort-json-failures" "${REAL_ROOT}/.forge/loops/research-loop.sh" 2>/dev/null || echo 0)
[ "$has_auto_abort" -ge 1 ] && e5_abort="ok" || e5_abort="missing"
assert_eq "E5-2: research-loop.sh に auto-abort-json-failures 記述あり" "ok" "$e5_abort"

# record_error が error_category を common.sh で生成するか
has_error_cat=$(grep -c "error_category" "${REAL_ROOT}/.forge/lib/common.sh" 2>/dev/null || echo 0)
[ "$has_error_cat" -ge 2 ] && e5_cat="ok" || e5_cat="missing"
assert_eq "E5-3: common.sh に error_category 記述>=2" "ok" "$e5_cat"

# classify_error_category 関数が common.sh に存在するか
has_classify=$(grep -c "classify_error_category" "${REAL_ROOT}/.forge/lib/common.sh" 2>/dev/null || echo 0)
[ "$has_classify" -ge 1 ] && e5_classify="ok" || e5_classify="missing"
assert_eq "E5-4: common.sh に classify_error_category 関数あり" "ok" "$e5_classify"

# _run_single_researcher が result_dir へ status を書き出すロジックがあるか
has_status_write=$(grep -c "\.status" "${REAL_ROOT}/.forge/loops/research-loop.sh" 2>/dev/null || echo 0)
[ "$has_status_write" -ge 3 ] && e5_sw="ok" || e5_sw="missing"
assert_eq "E5-5: research-loop.sh に .status 書き出し>=3箇所" "ok" "$e5_sw"

echo ""

# ===================================================================
# サマリー
# ===================================================================
print_test_summary
exit $?
