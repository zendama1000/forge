#!/bin/bash
# test-best-of-n.sh — best-of-N（N 候補生成 → L1 判定 → 選択採用）のテスト
# ralph-loop.sh から task_implement_best_of_n を抽出し、task_implement_raw を
# 関数上書きモックで差し替えて候補生成・選択・patch 適用を検証する。
# 使い方: bash .forge/tests/test-best-of-n.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RALPH_LOOP_SH="${PROJECT_ROOT}/.forge/loops/ralph-loop.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export RESEARCH_DIR="test-best-of-n"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMPDIR}/notifications"
json_fail_count=0
touch "$ERRORS_FILE"
mkdir -p "$NOTIFY_DIR"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== 関数抽出（awk） =====
extract_functions() {
  local src="$1"
  shift
  awk -v "names=$*" '
    BEGIN { split(names, arr, " "); for (i in arr) targets[arr[i] "()"] = 1 }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { if ($1 in targets) { found = 1; depth = 0 } }
    found {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      print
      if (depth <= 0 && NR > start_line) { found = 0; print "" }
      if (found && depth > 0) start_line = NR
    }
  ' "$src"
}

EXTRACT_FILE="${TMPDIR}/bon-funcs.sh"
extract_functions "$RALPH_LOOP_SH" task_implement_best_of_n execute_layer1_test bon_judge_select > "$EXTRACT_FILE"
if ! source "$EXTRACT_FILE"; then
  echo "FATAL: 関数抽出 source 失敗" >&2
  exit 1
fi
for fn in task_implement_best_of_n execute_layer1_test bon_judge_select; do
  if ! declare -f "$fn" > /dev/null; then
    echo "FATAL: 関数 ${fn} が抽出できなかった" >&2
    exit 1
  fi
done

# ===== スタブ =====
log() { :; }
metrics_start() { :; }
metrics_record() { :; }
EVENTS_LOG="${TMPDIR}/events.log"
record_task_event() { echo "$2 $3" >> "$EVENTS_LOG"; return 0; }
notify_human() { :; }

# checkpoint restore スタブ: HEAD へ完全リセット（実機の patch+untracked 復元と等価な効果）
task_checkpoint_restore() {
  git -C "$1" checkout -q -- . 2>/dev/null || true
  git -C "$1" clean -fdq 2>/dev/null || true
  return 0
}

# task_implement_raw モック: MOCK_CAND_BEHAVIORS 配列（インデックス=呼出回数）に従う
#   good  → impl.txt に GOOD を書く（L1 pass する実装）
#   bad   → impl.txt に BAD を書く（L1 fail する実装）
#   big   → impl.txt GOOD + extra.txt（diff が大きい pass 実装）
#   error → 実装失敗（return 1、ファイル生成なし）
RAW_CALL_COUNT=0
task_implement_raw() {
  RAW_CALL_COUNT=$((RAW_CALL_COUNT + 1))
  local behavior="${MOCK_CAND_BEHAVIORS[$RAW_CALL_COUNT]:-good}"
  case "$behavior" in
    good)
      echo "GOOD" > "${WORK_DIR}/impl.txt" ;;
    bad)
      echo "BAD" > "${WORK_DIR}/impl.txt" ;;
    big)
      echo "GOOD" > "${WORK_DIR}/impl.txt"
      printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\n' > "${WORK_DIR}/extra.txt" ;;
    error)
      return 1 ;;
  esac
  echo "implemented (${behavior})" > "$_RT_OUTPUT"
  return 0
}

# ===== 環境セットアップヘルパー =====
setup_bon_env() {
  local label="$1"
  WORK_DIR="${TMPDIR}/work-${label}"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  git -C "$WORK_DIR" init -q
  git -C "$WORK_DIR" config user.email "t@t.com"
  git -C "$WORK_DIR" config user.name "T"
  echo "base" > "${WORK_DIR}/base.txt"
  git -C "$WORK_DIR" add -A
  git -C "$WORK_DIR" commit -qm "initial"

  TASK_DIR="${TMPDIR}/task-${label}"
  mkdir -p "$TASK_DIR"
  _RT_OUTPUT="${TASK_DIR}/implementation-output.txt"
  _RT_PROMPT="実装せよ"
  _RT_TASK_JSON='{"task_id": "t-1", "fail_count": 2, "validation": {"layer_1": {"command": "grep -q GOOD impl.txt", "timeout_sec": 30}}}'
  BEST_OF_N=2
  BEST_OF_N_TRIGGER=2
  BEST_OF_N_SELECTION="mechanical"
  L1_DEFAULT_TIMEOUT=30
  RAW_CALL_COUNT=0
  rm -f "$EVENTS_LOG" "$JUDGE_CALLS_LOG"
}

# run_claude モック（bon_judge_select 用）: MOCK_JUDGE_BEHAVIOR に従う
#   select-N → {"selected": N} を .pending に書く
#   fail     → return 1（judge 実行エラー）
# 呼出カウントは変数でなくファイルに記録する
# （bon_judge_select は $(...) サブシェル内で走るため変数増分は親に伝播しない）
MOCK_JUDGE_BEHAVIOR="select-1"
JUDGE_CALLS_LOG="${TMPDIR}/judge-calls.log"
judge_call_count() { [ -f "$JUDGE_CALLS_LOG" ] && wc -l < "$JUDGE_CALLS_LOG" | tr -d ' ' || echo 0; }
run_claude() {
  echo "judge" >> "$JUDGE_CALLS_LOG"
  local out="$4"
  case "$MOCK_JUDGE_BEHAVIOR" in
    fail)
      return 1 ;;
    select-*)
      echo "{\"selected\": ${MOCK_JUDGE_BEHAVIOR#select-}, \"reason\": \"mock judge\"}" > "${out}.pending"
      return 0 ;;
  esac
  return 1
}

echo -e "${BOLD}===== test-best-of-n.sh — best-of-N 候補生成/選択 =====${NC}"

# ===================================================================
echo -e "\n${YELLOW}Test 1: 候補1=fail / 候補2=pass → 候補2採用${NC}"
# ===================================================================
setup_bon_env "t1"
declare -A MOCK_CAND_BEHAVIORS=([1]="bad" [2]="good")
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "候補2の実装が適用されている" "GOOD" "$(cat "${WORK_DIR}/impl.txt" 2>/dev/null)"
assert_eq "selected=2 がイベント記録される" "1" "$(grep -c '"selected": 2' "$EVENTS_LOG" 2>/dev/null)"
assert_eq "implementation-output が採用候補のもの" "implemented (good)" "$(cat "$_RT_OUTPUT" 2>/dev/null)"
assert_eq "apply_ok=true がイベント記録される（batch#11 R02）" "1" "$(grep -c '"apply_ok": true' "$EVENTS_LOG" 2>/dev/null)"

# ===================================================================
echo -e "\n${YELLOW}Test 2: 両候補 pass → diff 最小（候補1）採用${NC}"
# ===================================================================
setup_bon_env "t2"
declare -A MOCK_CAND_BEHAVIORS=([1]="good" [2]="big")
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "diff 最小の候補1が採用（extra.txt なし）" "false" "$([ -f "${WORK_DIR}/extra.txt" ] && echo true || echo false)"
assert_eq "selected=1 がイベント記録される" "1" "$(grep -c '"selected": 1' "$EVENTS_LOG" 2>/dev/null)"

# ===================================================================
echo -e "\n${YELLOW}Test 3: 両候補 fail → それでも選択して続行（後段が判定）${NC}"
# ===================================================================
setup_bon_env "t3"
declare -A MOCK_CAND_BEHAVIORS=([1]="bad" [2]="bad")
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0（通常フローへ流す）" "0" "$rc"
assert_eq "選択候補の patch は適用される" "BAD" "$(cat "${WORK_DIR}/impl.txt" 2>/dev/null)"
sel_line=$(grep "best_of_n_completed" "$EVENTS_LOG" 2>/dev/null | head -1)
if echo "$sel_line" | grep -q '"selected": 0'; then
  assert_eq "selected は 0 ではない（有効候補あり）" "nonzero" "zero"
else
  assert_eq "selected は 0 ではない（有効候補あり）" "nonzero" "nonzero"
fi

# ===================================================================
echo -e "\n${YELLOW}Test 4: 候補1=実装失敗 / 候補2=pass → 候補2採用（skip 耐性）${NC}"
# ===================================================================
setup_bon_env "t4"
declare -A MOCK_CAND_BEHAVIORS=([1]="error" [2]="good")
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "候補2が採用される" "GOOD" "$(cat "${WORK_DIR}/impl.txt" 2>/dev/null)"
assert_eq "selected=2" "1" "$(grep -c '"selected": 2' "$EVENTS_LOG" 2>/dev/null)"

# ===================================================================
echo -e "\n${YELLOW}Test 5: 全候補実装失敗 → selected=0 で通常フローへ${NC}"
# ===================================================================
setup_bon_env "t5"
declare -A MOCK_CAND_BEHAVIORS=([1]="error" [2]="error")
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "selected=0 がイベント記録される" "1" "$(grep -c '"selected": 0' "$EVENTS_LOG" 2>/dev/null)"
assert_eq "作業ツリーはベース状態のまま" "false" "$([ -f "${WORK_DIR}/impl.txt" ] && echo true || echo false)"

# ===================================================================
echo -e "\n${YELLOW}Test 6a: judge タイブレーク — L1 同値タイで judge が候補2を選択${NC}"
# ===================================================================
setup_bon_env "t6a"
declare -A MOCK_CAND_BEHAVIORS=([1]="good" [2]="big")
BEST_OF_N_SELECTION="judge"
MOCK_JUDGE_BEHAVIOR="select-2"
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "judge が1回呼ばれる" "1" "$(judge_call_count)"
assert_eq "judge 選択の候補2（diff 大）が採用される" "true" "$([ -f "${WORK_DIR}/extra.txt" ] && echo true || echo false)"
assert_eq "selected=2 がイベント記録される" "1" "$(grep -c '"selected": 2' "$EVENTS_LOG" 2>/dev/null)"
assert_eq "selection=judge がイベント記録される" "1" "$(grep -c '"selection": "judge"' "$EVENTS_LOG" 2>/dev/null)"

# ===================================================================
echo -e "\n${YELLOW}Test 6b: judge 失敗 → 機械選択（diff 最小）へフォールバック${NC}"
# ===================================================================
setup_bon_env "t6b"
declare -A MOCK_CAND_BEHAVIORS=([1]="good" [2]="big")
BEST_OF_N_SELECTION="judge"
MOCK_JUDGE_BEHAVIOR="fail"
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "フォールバックで diff 最小の候補1が採用" "false" "$([ -f "${WORK_DIR}/extra.txt" ] && echo true || echo false)"
assert_eq "selection=mechanical がイベント記録される" "1" "$(grep -c '"selection": "mechanical"' "$EVENTS_LOG" 2>/dev/null)"

# ===================================================================
echo -e "\n${YELLOW}Test 6c: judge がリスト外の番号を返す → フォールバック（暴走防御）${NC}"
# ===================================================================
setup_bon_env "t6c"
declare -A MOCK_CAND_BEHAVIORS=([1]="good" [2]="big")
BEST_OF_N_SELECTION="judge"
MOCK_JUDGE_BEHAVIOR="select-5"
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "リスト外応答は無効 → diff 最小の候補1が採用" "false" "$([ -f "${WORK_DIR}/extra.txt" ] && echo true || echo false)"
assert_eq "selection=mechanical がイベント記録される" "1" "$(grep -c '"selection": "mechanical"' "$EVENTS_LOG" 2>/dev/null)"

# ===================================================================
echo -e "\n${YELLOW}Test 6d: L1 が判別できる場合は judge を呼ばない（機械的証拠優先）${NC}"
# ===================================================================
setup_bon_env "t6d"
declare -A MOCK_CAND_BEHAVIORS=([1]="bad" [2]="good")
BEST_OF_N_SELECTION="judge"
MOCK_JUDGE_BEHAVIOR="select-1"
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "judge は呼ばれない（L1 で判別済み）" "0" "$(judge_call_count)"
assert_eq "L1 pass の候補2が採用される" "GOOD" "$(cat "${WORK_DIR}/impl.txt" 2>/dev/null)"
assert_eq "selection=mechanical がイベント記録される" "1" "$(grep -c '"selection": "mechanical"' "$EVENTS_LOG" 2>/dev/null)"

# ===================================================================
echo -e "\n${YELLOW}Test 6e: selection=mechanical（既定）では judge を一切呼ばない${NC}"
# ===================================================================
setup_bon_env "t6e"
declare -A MOCK_CAND_BEHAVIORS=([1]="good" [2]="big")
MOCK_JUDGE_BEHAVIOR="select-2"
rc=0
task_implement_best_of_n "t-1" "$TASK_DIR" > /dev/null 2>&1 || rc=$?
assert_eq "return 0" "0" "$rc"
assert_eq "judge は呼ばれない（mechanical）" "0" "$(judge_call_count)"
assert_eq "diff 最小の候補1が採用" "false" "$([ -f "${WORK_DIR}/extra.txt" ] && echo true || echo false)"

# ===================================================================
echo -e "\n${YELLOW}Test 5b: task_dir が相対パス（本番と同じ DEV_LOG_DIR 相対）でも patch 適用が成功する（batch#11 R02）${NC}"
# 本番では task_dir=".forge/logs/development/<id>"（PROJECT_ROOT 相対）で、git -C "$WORK_DIR" apply が
# WORK_DIR 基準で解決して ENOENT になっていた（2 案件通算 9/9）。絶対化後は cwd=PROJECT_ROOT で成功する。
# ===================================================================
setup_bon_env "t5b"
declare -A MOCK_CAND_BEHAVIORS=([1]="bad" [2]="good")
_saved_pwd=$(pwd); _saved_root="$PROJECT_ROOT"
cd "$TMPDIR"; PROJECT_ROOT="$TMPDIR"
REL_TASK_DIR="task-rel-5b"; mkdir -p "$REL_TASK_DIR"
_RT_OUTPUT="${REL_TASK_DIR}/implementation-output.txt"
rc=0
task_implement_best_of_n "t-5b" "$REL_TASK_DIR" > /dev/null 2>&1 || rc=$?
cd "$_saved_pwd"; PROJECT_ROOT="$_saved_root"
assert_eq "相対 task_dir でも return 0" "0" "$rc"
assert_eq "相対 task_dir でも候補2の実装が適用される（ENOENT 再発防止）" "GOOD" "$(cat "${WORK_DIR}/impl.txt" 2>/dev/null)"
assert_eq "apply 失敗イベント（best_of_n_apply_failed）は出ない" "0" "$(grep -c 'best_of_n_apply_failed' "$EVENTS_LOG" 2>/dev/null)"
assert_eq "apply_ok=true が記録される" "1" "$(grep -c '"apply_ok": true' "$EVENTS_LOG" 2>/dev/null)"

# ===================================================================
echo -e "\n${YELLOW}Test 6: 配線の静的確認${NC}"
# ===================================================================
WIRED=$(grep -c "task_implement_best_of_n" "$RALPH_LOOP_SH" 2>/dev/null) || WIRED=0
if [ "$WIRED" -ge 2 ]; then
  assert_eq "run_task に best-of-N 分岐が配線されている" "wired" "wired"
else
  assert_eq "run_task に best-of-N 分岐が配線されている" "wired" "refs=${WIRED}"
fi
CFG_ENABLED=$(jq -r '.best_of_n.enabled' "${PROJECT_ROOT}/.forge/config/development.json" 2>/dev/null)
CFG_N=$(jq -r '.best_of_n.n' "${PROJECT_ROOT}/.forge/config/development.json" 2>/dev/null)
assert_eq "config に best_of_n.n=2" "2" "$CFG_N"
if [ "$CFG_ENABLED" = "true" ] || [ "$CFG_ENABLED" = "false" ]; then
  assert_eq "config に best_of_n.enabled (boolean)" "boolean" "boolean"
else
  assert_eq "config に best_of_n.enabled (boolean)" "boolean" "missing"
fi

# ===== サマリー =====
TOTAL=$((PASS + FAIL))
echo ""
echo -e "${BOLD}=========================================${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL}/${TOTAL}${NC}"
fi
echo -e "${BOLD}=========================================${NC}"

exit "$FAIL"
