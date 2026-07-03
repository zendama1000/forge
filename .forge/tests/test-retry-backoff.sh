#!/bin/bash
# test-retry-backoff.sh — retry_with_backoff() 指数バックオフテスト
# 使い方: bash .forge/tests/test-retry-backoff.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-retry-backoff.sh — 指数バックオフリトライ =====${NC}"
echo ""

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_SH="${REAL_ROOT}/.forge/lib/common.sh"
RESEARCH_LOOP_SH="${REAL_ROOT}/.forge/loops/research-loop.sh"
RALPH_LOOP_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'" EXIT

extract_all_functions_awk "$COMMON_SH" retry_with_backoff is_retryable_exit > "$EXTRACT_FILE"

# テスト中の log() は no-op（出力抑制）
log() { :; }

source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} retry_with_backoff / is_retryable_exit 抽出完了"
echo ""

# ===== テスト1: 指数バックオフ計算（常に失敗） =====
# behavior: retry_with_backoff() に max_retries=3 backoff_sec=1 を渡し、常に失敗するコマンドを実行 → sleep呼出が 1秒・2秒・4秒の順で行われる（正常系: 指数バックオフ計算）
echo -e "${BOLD}--- テスト1: 指数バックオフ計算（常に失敗） ---${NC}"
{
  SLEEP_LOG=()
  sleep() { SLEEP_LOG+=("$1"); }
  _always_fail_1() { return 1; }

  retry_with_backoff 3 1 _always_fail_1
  T1_RC=$?

  assert_eq "全失敗時のexitコードは1" "1" "$T1_RC"
  assert_eq "sleep呼出1回目は1秒" "1" "${SLEEP_LOG[0]:-NOT_CALLED}"
  assert_eq "sleep呼出2回目は2秒" "2" "${SLEEP_LOG[1]:-NOT_CALLED}"
  assert_eq "sleep呼出3回目は4秒" "4" "${SLEEP_LOG[2]:-NOT_CALLED}"
  assert_eq "sleep呼出合計は3回" "3" "${#SLEEP_LOG[@]}"
}
unset -f sleep
echo ""

# ===== テスト2: 早期成功時の短絡 =====
# behavior: retry_with_backoff() に max_retries=3 を渡し、2回目で成功するコマンドを実行 → 即座にexit 0で戻り、残りのリトライを実行しない（正常系: 早期成功時の短絡）
echo -e "${BOLD}--- テスト2: 2回目で成功（早期短絡） ---${NC}"
{
  SLEEP_LOG=()
  sleep() { SLEEP_LOG+=("$1"); }
  T2_ATTEMPT_COUNT=0
  _succeed_on_second() {
    T2_ATTEMPT_COUNT=$((T2_ATTEMPT_COUNT + 1))
    if [ "$T2_ATTEMPT_COUNT" -ge 2 ]; then
      return 0
    fi
    return 1
  }

  retry_with_backoff 3 1 _succeed_on_second
  T2_RC=$?

  assert_eq "2回目成功時のexitコードは0" "0" "$T2_RC"
  assert_eq "コマンド呼出回数は2回" "2" "$T2_ATTEMPT_COUNT"
  assert_eq "sleep呼出は1回のみ" "1" "${#SLEEP_LOG[@]}"
  assert_eq "sleep値は1秒（指数バックオフ最初のリトライ）" "1" "${SLEEP_LOG[0]:-NOT_CALLED}"
}
unset -f sleep
echo ""

# ===== テスト3: 全リトライ失敗 =====
# behavior: retry_with_backoff() に max_retries=3 を渡し、全回失敗するコマンドを実行 → exit 1で戻る（異常系: 全リトライ失敗）
echo -e "${BOLD}--- テスト3: 全リトライ失敗 → exit 1 ---${NC}"
{
  T3_CALL_COUNT=0
  sleep() { :; }
  _always_fail_3() {
    T3_CALL_COUNT=$((T3_CALL_COUNT + 1))
    return 1
  }

  retry_with_backoff 3 1 _always_fail_3
  T3_RC=$?

  assert_eq "全リトライ失敗のexitコードは1" "1" "$T3_RC"
  # max_retries=3 → 1初回 + 3リトライ = 4回呼び出し
  assert_eq "コマンド呼出合計は4回（1初回+3リトライ）" "4" "$T3_CALL_COUNT"
}
unset -f sleep
echo ""

# ===== テスト4: max_retries=0 =====
# behavior: retry_with_backoff() に max_retries=0 を渡す → コマンドを1回も実行せずexit 1で戻る（エッジケース: リトライ0回）
echo -e "${BOLD}--- テスト4: max_retries=0（コマンド未実行） ---${NC}"
{
  T4_EXEC_COUNT=0
  sleep() { :; }
  _count_exec_4() {
    T4_EXEC_COUNT=$((T4_EXEC_COUNT + 1))
    return 0
  }

  retry_with_backoff 0 1 _count_exec_4
  T4_RC=$?

  assert_eq "max_retries=0のexitコードは1" "1" "$T4_RC"
  assert_eq "コマンドは1回も実行されない" "0" "$T4_EXEC_COUNT"
}
unset -f sleep
echo ""

# ===== テスト5: research-loop.sh 統合確認 =====
# behavior: research-loop.shの run_claude() 呼出箇所（SC・Researcher・Synthesizer・DA）で retry_with_backoff() が使用されている（統合確認: grep -c で1箇所以上）
echo -e "${BOLD}--- テスト5: research-loop.sh 統合確認 ---${NC}"
{
  T5_COUNT=$(grep -c "retry_with_backoff" "$RESEARCH_LOOP_SH" 2>/dev/null || echo "0")
  T5_AT_LEAST_ONE=$([ "$T5_COUNT" -ge 1 ] && echo "1" || echo "0")
  assert_eq "research-loop.shにretry_with_backoff呼出が1箇所以上" "1" "$T5_AT_LEAST_ONE"
  # 具体的な箇所数も表示
  echo -e "    （検出箇所数: ${T5_COUNT}）"
}
echo ""

# ===== テスト6: ralph-loop.sh 統合確認 =====
# behavior: ralph-loop.shの run_claude() 呼出箇所（Implementer・Investigator）で retry_with_backoff() が使用されている（統合確認: grep -c で1箇所以上）
echo -e "${BOLD}--- テスト6: ralph-loop.sh 統合確認 ---${NC}"
{
  T6_COUNT=$(grep -c "retry_with_backoff" "$RALPH_LOOP_SH" 2>/dev/null || echo "0")
  T6_AT_LEAST_ONE=$([ "$T6_COUNT" -ge 1 ] && echo "1" || echo "0")
  assert_eq "ralph-loop.shにretry_with_backoff呼出が1箇所以上" "1" "$T6_AT_LEAST_ONE"
  echo -e "    （検出箇所数: ${T6_COUNT}）"
}
echo ""

# ===== テスト追加: バックオフ値の正確性検証（base=2） =====
# behavior: [追加] backoff_sec=2 の場合の指数計算が正しい（2→4→8）
echo -e "${BOLD}--- テスト追加: backoff_sec=2 の指数バックオフ ---${NC}"
{
  SLEEP_LOG=()
  sleep() { SLEEP_LOG+=("$1"); }
  _always_fail_ex() { return 1; }

  retry_with_backoff 3 2 _always_fail_ex
  TEX_RC=$?

  assert_eq "backoff_sec=2 sleep1回目は2秒" "2" "${SLEEP_LOG[0]:-NOT_CALLED}"
  assert_eq "backoff_sec=2 sleep2回目は4秒" "4" "${SLEEP_LOG[1]:-NOT_CALLED}"
  assert_eq "backoff_sec=2 sleep3回目は8秒" "8" "${SLEEP_LOG[2]:-NOT_CALLED}"
}
unset -f sleep
echo ""

# ===== テスト7: 非リトライ対象 exit code（予算超過 21）の即打ち切り =====
# behavior: コマンドが exit 21（RC_EXIT_BUDGET_EXCEEDED）で失敗 → リトライせず即座に 21 で返る（呼出1回・sleep 0回）
echo -e "${BOLD}--- テスト7: 予算超過 (exit 21) → リトライなしで即打ち切り ---${NC}"
{
  SLEEP_LOG=()
  sleep() { SLEEP_LOG+=("$1"); }
  T7_CALL_COUNT=0
  _budget_exceeded_7() {
    T7_CALL_COUNT=$((T7_CALL_COUNT + 1))
    return 21
  }

  retry_with_backoff 3 1 _budget_exceeded_7
  T7_RC=$?

  assert_eq "exit code は元の 21 が保持される" "21" "$T7_RC"
  assert_eq "コマンド呼出は1回のみ（リトライなし）" "1" "$T7_CALL_COUNT"
  assert_eq "sleep は1回も呼ばれない" "0" "${#SLEEP_LOG[@]}"
}
unset -f sleep
echo ""

# ===== テスト8: 非リトライ対象 exit code（引数エラー 2）の即打ち切り =====
# behavior: コマンドが exit 2（run_claude 引数エラー）で失敗 → リトライせず即座に 2 で返る
echo -e "${BOLD}--- テスト8: 引数エラー (exit 2) → リトライなしで即打ち切り ---${NC}"
{
  SLEEP_LOG=()
  sleep() { SLEEP_LOG+=("$1"); }
  T8_CALL_COUNT=0
  _arg_error_8() {
    T8_CALL_COUNT=$((T8_CALL_COUNT + 1))
    return 2
  }

  retry_with_backoff 3 1 _arg_error_8
  T8_RC=$?

  assert_eq "exit code は元の 2 が保持される" "2" "$T8_RC"
  assert_eq "コマンド呼出は1回のみ（リトライなし）" "1" "$T8_CALL_COUNT"
  assert_eq "sleep は1回も呼ばれない" "0" "${#SLEEP_LOG[@]}"
}
unset -f sleep
echo ""

# ===== テスト9: リトライ対象 exit code（その他）は従来どおりリトライする =====
# behavior: exit 3（分類外）で失敗し続ける → 従来どおり全リトライを消化して exit 1 で返る（回帰確認）
echo -e "${BOLD}--- テスト9: 分類外の失敗 (exit 3) は従来どおりリトライ ---${NC}"
{
  SLEEP_LOG=()
  sleep() { SLEEP_LOG+=("$1"); }
  T9_CALL_COUNT=0
  _transient_fail_9() {
    T9_CALL_COUNT=$((T9_CALL_COUNT + 1))
    return 3
  }

  retry_with_backoff 3 1 _transient_fail_9
  T9_RC=$?

  assert_eq "全リトライ失敗時の exit code は 1（後方互換）" "1" "$T9_RC"
  assert_eq "コマンド呼出合計は4回（1初回+3リトライ）" "4" "$T9_CALL_COUNT"
  assert_eq "sleep は3回呼ばれる" "3" "${#SLEEP_LOG[@]}"
}
unset -f sleep
echo ""

# ===== テスト10: リトライ途中で非リトライ対象に遷移 → その時点で打ち切り =====
# behavior: 1回目 exit 1（リトライ対象）→ 2回目 exit 21（予算超過）→ 2回目で打ち切り 21 を返す
echo -e "${BOLD}--- テスト10: リトライ途中の予算超過でも打ち切る ---${NC}"
{
  SLEEP_LOG=()
  sleep() { SLEEP_LOG+=("$1"); }
  T10_CALL_COUNT=0
  _fail_then_budget_10() {
    T10_CALL_COUNT=$((T10_CALL_COUNT + 1))
    if [ "$T10_CALL_COUNT" -eq 1 ]; then
      return 1
    fi
    return 21
  }

  retry_with_backoff 3 1 _fail_then_budget_10
  T10_RC=$?

  assert_eq "exit code は 21" "21" "$T10_RC"
  assert_eq "コマンド呼出は2回（初回+リトライ1回で打ち切り）" "2" "$T10_CALL_COUNT"
  assert_eq "sleep は1回のみ" "1" "${#SLEEP_LOG[@]}"
}
unset -f sleep
echo ""

# ===== サマリー =====
print_test_summary
