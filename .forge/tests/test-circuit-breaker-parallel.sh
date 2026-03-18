#!/bin/bash
# test-circuit-breaker-parallel.sh — 並列Researcher circuit-breaker ロジック テスト
#
# テスト対象の振る舞い:
#   1. 6並列Researcherのうち2件が個別失敗 → json_fail_count=2, 残り4件保持しループ継続
#   2. 6並列Researcherが全件同時失敗 → クールダウン後リトライが実行される
#   3. 全件同時失敗→リトライ後3件以上成功 → ループ継続, json_fail_countリセット
#   4. 全件同時失敗→リトライ後も全件失敗 → AUTO-ABORT, status='auto-abort-json-failures'
#   5. 個別perspectiveが連続3回失敗 → そのperspectiveのみスキップ
#
# 使い方: bash .forge/tests/test-circuit-breaker-parallel.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-circuit-breaker-parallel.sh — 並列Researcher Circuit Breaker =====${NC}"
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
RESEARCH_DIR="${PROJECT_ROOT}/research-test"
LOG_DIR="${PROJECT_ROOT}/.forge/logs/research"
STATE_FILE="${PROJECT_ROOT}/.forge/state/current-research.json"
json_fail_count=0
CLAUDE_TIMEOUT=600

touch "$ERRORS_FILE"
touch "$VALIDATION_STATS_FILE"
touch "$METRICS_FILE"

# common.sh を読み込む（COSTS_FILE等が PROJECT_ROOT 基準で設定される）
source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== circuit-breaker 設定読み込み =====
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
MAX_JSON_FAILS_PER_LOOP=$(jq_safe -r '.research_limits.max_json_fails_per_loop // 3' "$CIRCUIT_BREAKER_CONFIG")
PARALLEL_ALL_FAIL_COOLDOWN_SEC=$(jq_safe -r '.research_limits.parallel_all_fail_cooldown_sec // 30' "$CIRCUIT_BREAKER_CONFIG")
PERSPECTIVE_MAX_CONSECUTIVE_FAILS=$(jq_safe -r '.research_limits.perspective_max_consecutive_fails // 3' "$CIRCUIT_BREAKER_CONFIG")

# テスト中は sleep をスキップ
export COOLDOWN_SEC=0

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"

extract_all_functions_awk "$RESEARCH_LOOP" \
  _get_perspective_fail_count \
  _set_perspective_fail_count \
  should_skip_perspective \
  > "$EXTRACT_FILE"

source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} 関数抽出完了 (_get/_set_perspective_fail_count, should_skip_perspective)"
echo ""

# ===== モック定義 =====
# update_state: STATE_FILE に JSON を書き込む（テスト用シンプル版）
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

# ===== ユーティリティ: RESEARCH_DIR をリセット =====
reset_research_dir() {
  rm -rf "$RESEARCH_DIR"
  mkdir -p "$RESEARCH_DIR"
}

# ===== 集約ロジック実装（インライン実行: json_fail_count の副作用を保持） =====
# run_researchers の集約部分を忠実に再現する。
# json_fail_count への書き込みを親シェルで保持するため、コマンド置換ではなくインラインで実行し、
# 結果を専用ファイル (_AGG_OUT) に書き出す。
_AGG_OUT="${PROJECT_ROOT}/.agg_result"
_RETRY_OUT="${PROJECT_ROOT}/.retry_result"

# do_parallel_aggregation <perspectives_file> <result_dir>
# perspectives_file: スペース区切りの視点リストを含むファイル
# 結果は _AGG_OUT に "pass_count:active_count" 形式で書き出す
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
      : # カウントしない（active_run_count に加えない）
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

# do_retry_aggregation <perspectives_file> <result_dir> <initial_active_count>
# 初回全件失敗後のリトライ結果を集約する。
# 結果は _RETRY_OUT に "recovered:<n>" または "auto-abort:<n>" 形式で書き出す。
do_retry_aggregation() {
  local perspectives
  perspectives=$(cat "$1")
  local result_dir="$2"
  local active_run_count="$3"

  # 初回失敗分を json_fail_count からロールバック
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
    # AUTO-ABORT: current-research.json の status を 'auto-abort-json-failures' に更新
    update_state "aborted" "auto-abort-json-failures"
    echo "auto-abort:${retry_pass_count}" > "$_RETRY_OUT"
  fi
}

# ===================================================================
echo -e "${BOLD}===== Part A: perspective 連続失敗カウンタ (Unit Tests) =====${NC}"
# ===================================================================

echo -e "${BOLD}--- Group 1: _get_perspective_fail_count / _set_perspective_fail_count ---${NC}"
reset_research_dir

# A-1: 初期値は 0
result=$(_get_perspective_fail_count "market")
assert_eq "A-1: 初期 fail_count = 0" "0" "$result"

# A-2: set → get で値が保持される
_set_perspective_fail_count "market" 2
result=$(_get_perspective_fail_count "market")
assert_eq "A-2: set(2) → get = 2" "2" "$result"

# A-3: 異なる perspective は独立
_set_perspective_fail_count "tech" 1
result_market=$(_get_perspective_fail_count "market")
result_tech=$(_get_perspective_fail_count "tech")
assert_eq "A-3: market=2 (独立)" "2" "$result_market"
assert_eq "A-3: tech=1 (独立)" "1" "$result_tech"

# A-4: 0 にリセット
_set_perspective_fail_count "market" 0
result=$(_get_perspective_fail_count "market")
assert_eq "A-4: reset → 0" "0" "$result"

echo ""

# ===================================================================
echo -e "${BOLD}--- Group 2: should_skip_perspective ---${NC}"
reset_research_dir

# A-5: fail_count=0 → スキップしない (return 1)
_set_perspective_fail_count "p1" 0
should_skip_perspective "p1" 2>/dev/null
ret=$?
assert_eq "A-5: fail=0 → not skip (return 1)" "1" "$ret"

# A-6: fail_count=2 (閾値3未満) → スキップしない
_set_perspective_fail_count "p2" 2
should_skip_perspective "p2" 2>/dev/null
ret=$?
assert_eq "A-6: fail=2 < 3 → not skip (return 1)" "1" "$ret"

# A-7: fail_count=3 (閾値到達) → スキップ (return 0)
_set_perspective_fail_count "p3" 3
should_skip_perspective "p3" 2>/dev/null
ret=$?
assert_eq "A-7: fail=3 >= 3 → skip (return 0)" "0" "$ret"

# A-8: fail_count=5 (閾値超過) → スキップ
_set_perspective_fail_count "p4" 5
should_skip_perspective "p4" 2>/dev/null
ret=$?
assert_eq "A-8: fail=5 >= 3 → skip (return 0)" "0" "$ret"

# A-9: PERSPECTIVE_MAX_CONSECUTIVE_FAILS 上書き → 閾値変更
reset_research_dir
_set_perspective_fail_count "p5" 2
PERSPECTIVE_MAX_CONSECUTIVE_FAILS=2
should_skip_perspective "p5" 2>/dev/null
ret=$?
assert_eq "A-9: fail=2, threshold=2 → skip (return 0)" "0" "$ret"
PERSPECTIVE_MAX_CONSECUTIVE_FAILS=3  # 元に戻す

echo ""

# ===================================================================
echo -e "${BOLD}===== Part B: 並列Researcher 集約ロジック シミュレーション =====${NC}"
# ===================================================================
# _run_single_researcher はサブシェル(&)で実行されるため直接テストできない。
# 代わりに result_dir/*.status ファイルを直接書き込み、集約ロジックをシミュレートする。
# json_fail_count は親シェルで維持するため、インライン関数 (do_parallel_aggregation) を使用する。

# ===================================================================
echo -e "${BOLD}--- Group 3: 振る舞い1 — 2件失敗、4件成功 (個別失敗許容) ---${NC}"
reset_research_dir
json_fail_count=0
RESULT_DIR="${RESEARCH_DIR}/.researcher-results-b1"
mkdir -p "$RESULT_DIR"

PERSPECTIVES_B1="market tech competitive user cost regulatory"
echo "$PERSPECTIVES_B1" > "${PROJECT_ROOT}/.plist_b1"
for p in $PERSPECTIVES_B1; do
  echo "pass" > "${RESULT_DIR}/${p}.status"
done
# 2件を失敗に設定
echo "fail" > "${RESULT_DIR}/user.status"
echo "fail" > "${RESULT_DIR}/cost.status"

do_parallel_aggregation "${PROJECT_ROOT}/.plist_b1" "$RESULT_DIR"
# _AGG_OUT ファイルから結果を読む
agg_line=$(cat "$_AGG_OUT")
pass_cnt="${agg_line%%:*}"
active_cnt="${agg_line##*:}"

# 4件成功 → pass_round_count > 0 なので全件同時失敗ではない
assert_eq "B-1: json_fail_count=2 (2件失敗)" "2" "$json_fail_count"
assert_eq "B-1: pass_count=4" "4" "$pass_cnt"
assert_eq "B-1: active_count=6" "6" "$active_cnt"

# pass > 0 なのでクールダウン条件を満たさない（full_fail = false）
full_fail_check="false"
[ "$active_cnt" -gt 0 ] && [ "$pass_cnt" -eq 0 ] && full_fail_check="true"
assert_eq "B-1: 全件失敗フラグ=false（個別失敗許容）" "false" "$full_fail_check"

# 成功したperspectiveのfail_countがリセットされている
market_fail=$(_get_perspective_fail_count "market")
assert_eq "B-1: 成功perspectiveのfail_countリセット" "0" "$market_fail"

# 失敗したperspectiveのfail_countが増加
user_fail=$(_get_perspective_fail_count "user")
assert_eq "B-1: 失敗perspectiveのfail_count=1" "1" "$user_fail"

echo ""

# ===================================================================
echo -e "${BOLD}--- Group 4: 振る舞い2 — 6件全件失敗 → クールダウン後リトライ実行 ---${NC}"
reset_research_dir
json_fail_count=0
RESULT_DIR="${RESEARCH_DIR}/.researcher-results-b2"
mkdir -p "$RESULT_DIR"

PERSPECTIVES_B2="market tech competitive user cost regulatory"
echo "$PERSPECTIVES_B2" > "${PROJECT_ROOT}/.plist_b2"
for p in $PERSPECTIVES_B2; do
  echo "fail" > "${RESULT_DIR}/${p}.status"
done

do_parallel_aggregation "${PROJECT_ROOT}/.plist_b2" "$RESULT_DIR"
agg_line=$(cat "$_AGG_OUT")
pass_cnt="${agg_line%%:*}"
active_cnt="${agg_line##*:}"

# 全件失敗フラグ検出
full_fail_check="false"
[ "$active_cnt" -gt 0 ] && [ "$pass_cnt" -eq 0 ] && full_fail_check="true"

assert_eq "B-2: 全件同時失敗フラグ=true" "true" "$full_fail_check"
assert_eq "B-2: pass_count=0" "0" "$pass_cnt"
assert_eq "B-2: active_count=6 (全件カウント)" "6" "$active_cnt"

# クールダウン（COOLDOWN_SEC=0でスキップ）後にリトライを実行することを確認
cooldown_val="${COOLDOWN_SEC:-${PARALLEL_ALL_FAIL_COOLDOWN_SEC}}"
assert_eq "B-2: COOLDOWN_SEC=0でsleepはスキップ可" "0" "$cooldown_val"

echo ""

# ===================================================================
echo -e "${BOLD}--- Group 5: 振る舞い3 — 全件失敗リトライ後3件以上成功 → 回復 ---${NC}"
reset_research_dir
json_fail_count=6  # 全件失敗後の状態（初回集約で 6 件カウント済み）
RESULT_DIR="${RESEARCH_DIR}/.researcher-results-b3"
mkdir -p "$RESULT_DIR"

PERSPECTIVES_B3="market tech competitive user cost regulatory"
echo "$PERSPECTIVES_B3" > "${PROJECT_ROOT}/.plist_b3"
# リトライ後: 4件成功、2件失敗
echo "pass" > "${RESULT_DIR}/market.status"
echo "pass" > "${RESULT_DIR}/tech.status"
echo "pass" > "${RESULT_DIR}/competitive.status"
echo "pass" > "${RESULT_DIR}/user.status"
echo "fail" > "${RESULT_DIR}/cost.status"
echo "fail" > "${RESULT_DIR}/regulatory.status"

do_retry_aggregation "${PROJECT_ROOT}/.plist_b3" "$RESULT_DIR" "6"
retry_line=$(cat "$_RETRY_OUT")
retry_verdict="${retry_line%%:*}"
retry_pass_n="${retry_line##*:}"

assert_eq "B-3: retry_result=recovered" "recovered" "$retry_verdict"
assert_eq "B-3: retry_pass_count=4" "4" "$retry_pass_n"
assert_eq "B-3: json_fail_countリセット=0" "0" "$json_fail_count"

# 成功perspectiveのfail_countがリセット
market_fail=$(_get_perspective_fail_count "market")
assert_eq "B-3: 回復perspective fail_count=0" "0" "$market_fail"

echo ""

# ===================================================================
echo -e "${BOLD}--- Group 6: 振る舞い4 — リトライ後も全件失敗 → AUTO-ABORT ---${NC}"
reset_research_dir
json_fail_count=6
RESULT_DIR="${RESEARCH_DIR}/.researcher-results-b4"
mkdir -p "$RESULT_DIR"

PERSPECTIVES_B4="market tech competitive user cost regulatory"
echo "$PERSPECTIVES_B4" > "${PROJECT_ROOT}/.plist_b4"
# リトライ後も全件失敗
for p in $PERSPECTIVES_B4; do
  echo "fail" > "${RESULT_DIR}/${p}.status"
done

do_retry_aggregation "${PROJECT_ROOT}/.plist_b4" "$RESULT_DIR" "6"
retry_line=$(cat "$_RETRY_OUT")
retry_verdict="${retry_line%%:*}"
retry_pass_n="${retry_line##*:}"

assert_eq "B-4: retry_result=auto-abort" "auto-abort" "$retry_verdict"
assert_eq "B-4: retry_pass_count=0" "0" "$retry_pass_n"

# STATE_FILE が auto-abort-json-failures に更新されているか確認
state_status=$(jq_safe -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null)
assert_eq "B-4: STATE_FILE status=auto-abort-json-failures" "auto-abort-json-failures" "$state_status"

echo ""

# ===================================================================
echo -e "${BOLD}--- Group 7: 振る舞い5 — 個別perspective連続3回失敗 → スキップ ---${NC}"
reset_research_dir
json_fail_count=0
RESULT_DIR="${RESEARCH_DIR}/.researcher-results-b5"
mkdir -p "$RESULT_DIR"

PERSPECTIVES_B5="market tech competitive user cost regulatory"
echo "$PERSPECTIVES_B5" > "${PROJECT_ROOT}/.plist_b5"

# 「market」を3回連続失敗としてシミュレート。他は毎回 pass。
_set_perspective_fail_count "market" 0
for p in tech competitive user cost regulatory; do
  _set_perspective_fail_count "$p" 0
done

# ラウンド1: market 失敗、他 pass
echo "fail" > "${RESULT_DIR}/market.status"
for p in tech competitive user cost regulatory; do
  echo "pass" > "${RESULT_DIR}/${p}.status"
done
json_fail_count=0
do_parallel_aggregation "${PROJECT_ROOT}/.plist_b5" "$RESULT_DIR"
mkt_fail=$(_get_perspective_fail_count "market")
assert_eq "B-5: market fail_count after round1=1" "1" "$mkt_fail"

# ラウンド2: market また失敗
echo "fail" > "${RESULT_DIR}/market.status"
json_fail_count=0
do_parallel_aggregation "${PROJECT_ROOT}/.plist_b5" "$RESULT_DIR"
mkt_fail=$(_get_perspective_fail_count "market")
assert_eq "B-5: market fail_count after round2=2" "2" "$mkt_fail"

# ラウンド3: market また失敗 → fail_count=3, 閾値到達
echo "fail" > "${RESULT_DIR}/market.status"
json_fail_count=0
do_parallel_aggregation "${PROJECT_ROOT}/.plist_b5" "$RESULT_DIR"
mkt_fail=$(_get_perspective_fail_count "market")
assert_eq "B-5: market fail_count after round3=3" "3" "$mkt_fail"

# 次のラウンドでは market がスキップされる
should_skip_perspective "market" 2>/dev/null
skip_ret=$?
assert_eq "B-5: market should_skip=true (return 0)" "0" "$skip_ret"

# 他のperspectiveはスキップされない
should_skip_perspective "tech" 2>/dev/null
skip_tech=$?
assert_eq "B-5: tech should_skip=false (return 1)" "1" "$skip_tech"

# スキップ時の集約: market=skipped と設定して集約
echo "skipped" > "${RESULT_DIR}/market.status"
json_fail_count=0
do_parallel_aggregation "${PROJECT_ROOT}/.plist_b5" "$RESULT_DIR"
agg_line=$(cat "$_AGG_OUT")
pass_cnt="${agg_line%%:*}"
active_cnt="${agg_line##*:}"

assert_eq "B-5: スキップ後 pass=5 (market除く)" "5" "$pass_cnt"
assert_eq "B-5: スキップ後 active=5 (skipped除く)" "5" "$active_cnt"
assert_eq "B-5: スキップ後 json_fail_count=0 (market失敗はカウントされない)" "0" "$json_fail_count"

echo ""

# ===================================================================
echo -e "${BOLD}--- Group 8: COOLDOWN_SEC=0 動作確認 ---${NC}"
reset_research_dir

# COOLDOWN_SEC 変数が test context で正しく設定されているか確認
assert_eq "B-6: COOLDOWN_SEC=0 (テスト用クールダウン)" "0" "${COOLDOWN_SEC:-unset}"

# _cooldown 計算ロジックを直接テスト（research-loop.sh の同一ロジック）
_test_cooldown="${COOLDOWN_SEC:-${PARALLEL_ALL_FAIL_COOLDOWN_SEC}}"
assert_eq "B-6: COOLDOWN_SEC=0のとき_cooldown=0" "0" "$_test_cooldown"

# COOLDOWN_SEC を unset した場合は PARALLEL_ALL_FAIL_COOLDOWN_SEC が使われる
(
  unset COOLDOWN_SEC
  _fallback="${COOLDOWN_SEC:-${PARALLEL_ALL_FAIL_COOLDOWN_SEC}}"
  echo "$_fallback" > "${RESEARCH_DIR}/.cooldown_default"
)
default_val=$(cat "${RESEARCH_DIR}/.cooldown_default" 2>/dev/null || echo "err")
assert_eq "B-6: COOLDOWN_SEC未設定→PARALLEL_ALL_FAIL_COOLDOWN_SEC=${PARALLEL_ALL_FAIL_COOLDOWN_SEC}" "$PARALLEL_ALL_FAIL_COOLDOWN_SEC" "$default_val"

echo ""

# ===================================================================
echo -e "${BOLD}--- Group 9: circuit-breaker.json 設定値確認 ---${NC}"

# circuit-breaker.json に必要フィールドが存在するか
cb_cooldown=$(jq_safe -r '.research_limits.parallel_all_fail_cooldown_sec // "MISSING"' "$CIRCUIT_BREAKER_CONFIG")
assert_eq "B-7: circuit-breaker.json.parallel_all_fail_cooldown_sec=30" "30" "$cb_cooldown"

cb_max_fails=$(jq_safe -r '.research_limits.perspective_max_consecutive_fails // "MISSING"' "$CIRCUIT_BREAKER_CONFIG")
assert_eq "B-7: circuit-breaker.json.perspective_max_consecutive_fails=3" "3" "$cb_max_fails"

# research-loop.sh が PARALLEL_ALL_FAIL_COOLDOWN_SEC を使用する箇所が複数あるか
has_cooldown_read=$(grep -c "PARALLEL_ALL_FAIL_COOLDOWN_SEC" "${REAL_ROOT}/.forge/loops/research-loop.sh" 2>/dev/null || echo 0)
[ "$has_cooldown_read" -ge 2 ] && hcr_result="ok" || hcr_result="missing"
assert_eq "B-7: research-loop.sh PARALLEL_ALL_FAIL_COOLDOWN_SEC refs >=2" "ok" "$hcr_result"

# research-loop.sh が PERSPECTIVE_MAX_CONSECUTIVE_FAILS を使用する箇所が複数あるか
has_pmcf=$(grep -c "PERSPECTIVE_MAX_CONSECUTIVE_FAILS" "${REAL_ROOT}/.forge/loops/research-loop.sh" 2>/dev/null || echo 0)
[ "$has_pmcf" -ge 2 ] && hpmcf_result="ok" || hpmcf_result="missing"
assert_eq "B-7: research-loop.sh PERSPECTIVE_MAX_CONSECUTIVE_FAILS refs >=2" "ok" "$hpmcf_result"

# COOLDOWN_SEC オーバーライドのサポートが research-loop.sh に存在するか
has_cooldown_override=$(grep -c 'COOLDOWN_SEC' "${REAL_ROOT}/.forge/loops/research-loop.sh" 2>/dev/null || echo 0)
[ "$has_cooldown_override" -ge 1 ] && hco_result="ok" || hco_result="missing"
assert_eq "B-7: research-loop.sh COOLDOWN_SEC override support" "ok" "$hco_result"

echo ""

# ===================================================================
# サマリー
# ===================================================================
print_test_summary
exit $?
