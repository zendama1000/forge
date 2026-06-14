#!/bin/bash
# run-all-tests.sh — 全テストスイート一括実行ランナー
# 各テストを独立サブプロセスで実行し、結果を集約する。
# 使い方: bash .forge/tests/run-all-tests.sh
#
# 検証層:
#   1. exit code（非0 → FAIL）
#   2. 完了マーカーのパース（exit 0 でも以下は FAIL = サイレント死の遮断）
#      - 完了マーカーが出力に存在しない（source 失敗等による途中死）
#      - アサーション総数が 0（PASSED: 0/0 等）
#   3. 存在しないテストファイルは MISSING として明示報告（黙ってスキップしない）
#
# 認識する完了マーカー形式（ANSI カラー除去後にパース、最後の一致を採用）:
#   A) "PASSED: N/M"          — test-helpers.sh print_test_summary / ALL PASSED: N/M 系
#   B) "N/M PASSED"           — test-safety.sh の Test Summary 系
#   C) "PASS: N  FAIL: M"     — qa-evaluator 系（総数 = N + M）

set -uo pipefail

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ===== テストスイート一覧（実行順: 速い→遅い） =====
TEST_SUITES=(
  "${SCRIPT_DIR}/test-config-integrity.sh"
  "${SCRIPT_DIR}/test-research-config.sh"
  "${SCRIPT_DIR}/test-validate-json.sh"
  "${SCRIPT_DIR}/test-safety.sh"
  "${SCRIPT_DIR}/test-evidence-da.sh"
  "${SCRIPT_DIR}/test-priming.sh"
  "${SCRIPT_DIR}/test-lessons.sh"
  "${SCRIPT_DIR}/test-events.sh"
  "${SCRIPT_DIR}/test-heartbeat.sh"
  "${SCRIPT_DIR}/test-ralph-engine.sh"
  "${SCRIPT_DIR}/test-print-summary-unfinished.sh"
  "${SCRIPT_DIR}/test-research-e2e.sh"
  "${SCRIPT_DIR}/test-monitor.sh"
  "${SCRIPT_DIR}/test-rate-limit-recovery.sh"
  "${SCRIPT_DIR}/test-calibration.sh"
  "${SCRIPT_DIR}/test-sprint-contract.sh"
  "${SCRIPT_DIR}/test-qa-evaluator.sh"
  "${SCRIPT_DIR}/test-ablation.sh"
  "${SCRIPT_DIR}/test-context-strategy.sh"
  "${SCRIPT_DIR}/test-run-claude-effort.sh"
  "${SCRIPT_DIR}/test-browser-integration.sh"
  "${SCRIPT_DIR}/test-plan-gate.sh"
  "${SCRIPT_DIR}/test-l2-wiring.sh"
  "${SCRIPT_DIR}/test-full-regression-guard.sh"
)

# ===== 自動検出の除外リスト =====
# SCRIPT_DIR 直下の test-*.sh のうち、長時間/環境依存/手動実行/ライブラリのため
# ランナー一括実行から除外するもの（curated リストにも含まれていないもの）。
DISCOVERY_EXCLUDE=(
  "test-helpers.sh"
  "test-assertions.sh"
  "test-ralph-functions.sh"
  "test-circuit-breaker-parallel.sh"
  "test-config-schema-validation.sh"
  "test-error-classification.sh"
  "test-l3-agent-flow.sh"
  "test-l3-acceptance.sh"
  "test-metrics-cost-tracking.sh"
  "test-preflight-check.sh"
  "test-preflight-integration.sh"
  "test-ralph-retry-e2e.sh"
  "test-research-e2e-with-classification.sh"
  "test-research-main-loop.sh"
  "test-retry-backoff.sh"
  "test-run-task-decomposition.sh"
  "test-sanitize-commands.sh"
  "test-scaffold-agent.sh"
  "test-task-state-locking.sh"
  "test-trace-id.sh"
  "test-trace-id-e2e.sh"
  "test-validation-stats-analysis.sh"
  "test-init-session-state.sh"
  "test-common-l1549.sh"
  "test-jq-lines.sh"
  "test-mutation-audit-quoting.sh"
  "test-mutation-audit-spaces.sh"
  "test-timeout-sec.sh"
)

# ===== 自動検出: SCRIPT_DIR 直下の未登録 test-*.sh を末尾に追加 =====
# 新規追加・一時注入されたテストが黙って素通りしないようにする。
for f in "${SCRIPT_DIR}"/test-*.sh; do
  [ -f "$f" ] || continue
  fname=$(basename "$f")
  excluded=0
  for e in "${DISCOVERY_EXCLUDE[@]}"; do
    if [ "$fname" = "$e" ]; then excluded=1; break; fi
  done
  [ "$excluded" -eq 1 ] && continue
  listed=0
  for s in "${TEST_SUITES[@]}"; do
    if [ "$(basename "$s")" = "$fname" ]; then listed=1; break; fi
  done
  [ "$listed" -eq 1 ] && continue
  TEST_SUITES+=("$f")
done

# ===== マーカーパース =====

# ANSI エスケープシーケンスを除去する
strip_ansi() {
  sed -e $'s/\033\\[[0-9;]*m//g'
}

# 出力から完了マーカーをパースし、アサーション総数を stdout に返す。
# マーカーが見つからない場合は "none" を返す。
parse_assert_total() {
  local clean="$1" m

  # 形式A: "PASSED: N/M"（ALL PASSED: N/M を含む）
  m=$(printf '%s\n' "$clean" | grep -Eo 'PASSED: *[0-9]+/[0-9]+' | tail -1) || true
  if [ -n "$m" ]; then
    echo "${m##*/}"
    return 0
  fi

  # 形式B: "N/M PASSED"（test-safety.sh の Test Summary 系）
  m=$(printf '%s\n' "$clean" | grep -Eo '[0-9]+/[0-9]+ +PASSED' | tail -1) || true
  if [ -n "$m" ]; then
    m="${m%% *}"        # "N/M"
    echo "${m#*/}"
    return 0
  fi

  # 形式C: "PASS: N  FAIL: M"（総数 = N + M）
  m=$(printf '%s\n' "$clean" | grep -Eo 'PASS: *[0-9]+ +FAIL: *[0-9]+' | tail -1) || true
  if [ -n "$m" ]; then
    local p_cnt f_cnt
    p_cnt=$(printf '%s' "$m" | grep -Eo 'PASS: *[0-9]+' | grep -Eo '[0-9]+') || p_cnt=0
    f_cnt=$(printf '%s' "$m" | grep -Eo 'FAIL: *[0-9]+' | grep -Eo '[0-9]+') || f_cnt=0
    echo $((p_cnt + f_cnt))
    return 0
  fi

  echo "none"
}

echo -e "${BOLD}===== Forge Harness Test Runner =====${NC}"
echo -e "  実行日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

suite_pass=0
suite_fail=0
suite_missing=0
results=()
start_time=$SECONDS

for test_file in "${TEST_SUITES[@]}"; do
  suite_name=$(basename "$test_file")

  if [ ! -f "$test_file" ]; then
    # 黙ってスキップせず、missing として明示報告する
    echo -e "  ${RED}MISSING${NC}  ${suite_name}  (テストファイル不在: ${test_file})"
    suite_missing=$((suite_missing + 1))
    results+=("MISSING:${suite_name}")
    continue
  fi

  echo -e "  ${BOLD}RUN${NC}   ${suite_name}"
  suite_start=$SECONDS

  # 独立サブプロセスで実行（PROJECT_ROOT を渡す）
  output=$(cd "$PROJECT_ROOT" && bash "$test_file" 2>&1)
  exit_code=$?

  elapsed=$((SECONDS - suite_start))

  if [ "$exit_code" -ne 0 ]; then
    echo -e "  ${RED}FAIL${NC}  ${suite_name}  (exit=${exit_code}, ${elapsed}s)"
    # 失敗時は最後の数行を表示
    echo "$output" | tail -20 | sed 's/^/    /'
    suite_fail=$((suite_fail + 1))
    results+=("FAIL:${suite_name}")
    continue
  fi

  # exit 0 でも完了マーカーを検証する（サイレント死の遮断）
  clean_output=$(printf '%s\n' "$output" | strip_ansi)
  assert_total=$(parse_assert_total "$clean_output")

  if [ "$assert_total" = "none" ]; then
    echo -e "  ${RED}FAIL${NC}  ${suite_name}  (exit=0 だが完了マーカー欠落 — サイレント死の疑い, ${elapsed}s)"
    echo "$output" | tail -20 | sed 's/^/    /'
    suite_fail=$((suite_fail + 1))
    results+=("FAIL:${suite_name} (marker-missing)")
  elif [ "$assert_total" -eq 0 ]; then
    echo -e "  ${RED}FAIL${NC}  ${suite_name}  (exit=0 だがアサーション総数 0 — サイレント死の疑い, ${elapsed}s)"
    echo "$output" | tail -20 | sed 's/^/    /'
    suite_fail=$((suite_fail + 1))
    results+=("FAIL:${suite_name} (zero-asserts)")
  else
    echo -e "  ${GREEN}PASS${NC}  ${suite_name}  (asserts=${assert_total}, ${elapsed}s)"
    suite_pass=$((suite_pass + 1))
    results+=("PASS:${suite_name}")
  fi
done

total_elapsed=$((SECONDS - start_time))
total_suites=$((suite_pass + suite_fail + suite_missing))

echo ""
echo -e "${BOLD}=========================================="
echo -e "  結果サマリー"
echo -e "==========================================${NC}"
for r in "${results[@]}"; do
  status="${r%%:*}"
  name="${r#*:}"
  case "$status" in
    PASS)    echo -e "  ${GREEN}✓${NC} ${name}" ;;
    FAIL)    echo -e "  ${RED}✗${NC} ${name}" ;;
    MISSING) echo -e "  ${RED}?${NC} ${name} (missing)" ;;
  esac
done
echo ""
echo -e "  PASS: ${suite_pass}  FAIL: ${suite_fail}  MISSING: ${suite_missing}  Total: ${total_suites}  (${total_elapsed}s)"
echo ""

if [ "$suite_fail" -eq 0 ] && [ "$suite_missing" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL TEST SUITES PASSED (${suite_pass}/${total_suites} suites)${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}SOME TEST SUITES FAILED (fail=${suite_fail}, missing=${suite_missing} / ${total_suites})${NC}"
  exit 1
fi
