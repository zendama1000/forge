#!/bin/bash
# test-quality-ledger.sh — quality-ledger.sh 単体テスト
# 使い方: bash .forge/tests/test-quality-ledger.sh

set -uo pipefail

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

# ===== テスト集計 =====
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    needle not found: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="/tmp/test-quality-ledger-$$"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$PROJECT_ROOT"
mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/templates"
mkdir -p "${PROJECT_ROOT}/work"

# 必要な共通関数のスタブ（render_template は実実装と同挙動）
cat > "${PROJECT_ROOT}/.forge/lib/stub-common.sh" << 'STUB'
log() { echo "[LOG] $1" >&2; }
now_ts() { date +%Y%m%d-%H%M%S; }
jq_safe() { jq "$@" | tr -d '\r'; }
acquire_lock() { return 0; }
release_lock() { :; }
render_template() {
  local file="$1"; shift
  local content
  content=$(cat "$file")
  while [ $# -ge 2 ]; do
    local key="$1" value="$2"; shift 2
    local escaped_value="${value//&/\\&}"
    content="${content//\{\{${key}\}\}/$escaped_value}"
  done
  printf '%s' "$content"
}
STUB

source "${PROJECT_ROOT}/.forge/lib/stub-common.sh"

# ファイルをコピー
cp "${SCRIPT_DIR}/.forge/lib/quality-ledger.sh" "${PROJECT_ROOT}/.forge/lib/" 2>/dev/null || true
cp "${SCRIPT_DIR}/.forge/templates/phase4-handoff.md" "${PROJECT_ROOT}/.forge/templates/" 2>/dev/null || true

TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
WORK_DIR="${PROJECT_ROOT}/work"
DEV_CONFIG="${PROJECT_ROOT}/.forge/development.json"
echo '{"server":{"start_command":"npm start","health_check_url":"http://localhost:3001"}}' > "$DEV_CONFIG"

QUALITY_LEDGER_FILE="${PROJECT_ROOT}/.forge/state/quality-debts.jsonl"
source "${PROJECT_ROOT}/.forge/lib/quality-ledger.sh"

echo -e "${BOLD}===== テスト実行 =====${NC}"

# --- Test 1: record → 有効な JSONL エントリ ---
echo -e "\n${BOLD}[1] record_quality_debt が有効な JSONL を書く${NC}"
record_quality_debt "qa_auto_pass" "task-01" "QA 上限到達で auto-pass"
result=$?
assert_eq "record は rc=0" "0" "$result"
assert_eq "台帳ファイルが作成される" "true" "$([ -f "$QUALITY_LEDGER_FILE" ] && echo true || echo false)"
line_count=$(wc -l < "$QUALITY_LEDGER_FILE" | tr -d ' ')
assert_eq "エントリが 1 行" "1" "$line_count"
valid=$(jq -r 'select(.type=="qa_auto_pass" and .task_id=="task-01" and .resolved==false) | "ok"' "$QUALITY_LEDGER_FILE" | tr -d '\r')
assert_eq "type/task_id/resolved が正しい" "ok" "$valid"

# --- Test 2: extra_json のマージ ---
echo -e "\n${BOLD}[2] extra_json がマージされる${NC}"
record_quality_debt "deferred_test" "task-02" "実ブラウザ依存で繰延" '{"command":"npm run e2e","test_id":"L3-001"}'
cmd=$(jq -r 'select(.task_id=="task-02") | .command' "$QUALITY_LEDGER_FILE" | tr -d '\r')
assert_eq "extra_json の command がマージされる" "npm run e2e" "$cmd"

# --- Test 3: 不正な extra_json は無視して記録は成功 ---
echo -e "\n${BOLD}[3] 不正 extra_json は無視${NC}"
record_quality_debt "env_blocked" "task-03" "detail" '{broken json'
result=$?
assert_eq "不正 extra でも rc=0" "0" "$result"
entry3=$(jq -r 'select(.task_id=="task-03") | .type' "$QUALITY_LEDGER_FILE" | tr -d '\r')
assert_eq "エントリ自体は記録される" "env_blocked" "$entry3"

# --- Test 4: detail サニタイズ（制御文字除去 + キャップ） ---
echo -e "\n${BOLD}[4] detail サニタイズ${NC}"
long_detail=$(printf 'x%.0s' $(seq 1 3000))
record_quality_debt "warn_gate" "task-04" "$(printf 'bad\001ctrl\ttab\nnewline')${long_detail}"
d_len=$(jq -r 'select(.task_id=="task-04") | .detail | length' "$QUALITY_LEDGER_FILE" | tr -d '\r')
assert_eq "detail が 2000 字以下" "true" "$([ "$d_len" -le 2000 ] && echo true || echo false)"
has_ctrl_ok=$(jq -r 'select(.task_id=="task-04") | .detail | startswith("badctrltabnewline")' "$QUALITY_LEDGER_FILE" | tr -d "\r")
assert_eq "制御文字が除去される" "true" "$has_ctrl_ok"

# --- Test 5: summarize 集計 ---
echo -e "\n${BOLD}[5] summarize_quality_debts${NC}"
summary=$(summarize_quality_debts)
total=$(echo "$summary" | jq -r '.total' | tr -d '\r')
unresolved=$(echo "$summary" | jq -r '.unresolved' | tr -d '\r')
qa_count=$(echo "$summary" | jq -r '.by_type.qa_auto_pass' | tr -d '\r')
assert_eq "total=4" "4" "$total"
assert_eq "unresolved=4" "4" "$unresolved"
assert_eq "by_type.qa_auto_pass=1" "1" "$qa_count"

# --- Test 6: 台帳不在時はゼロ集計 ---
echo -e "\n${BOLD}[6] 台帳不在でゼロ集計${NC}"
summary_empty=$(summarize_quality_debts "/nonexistent/ledger.jsonl")
assert_eq "不在時 total=0" "0" "$(echo "$summary_empty" | jq -r '.total' | tr -d '\r')"

# --- Test 7: list_quality_debts フィルタ ---
echo -e "\n${BOLD}[7] list_quality_debts${NC}"
all_lines=$(list_quality_debts | wc -l | tr -d ' ')
assert_eq "全件リスト=4行" "4" "$all_lines"
filtered=$(list_quality_debts "deferred_test")
assert_contains "type フィルタが効く" "task-02" "$filtered"
filtered_lines=$(echo "$filtered" | grep -c . || true)
assert_eq "フィルタ後=1行" "1" "$filtered_lines"

# --- Test 8: PHASE4-HANDOFF 生成 ---
echo -e "\n${BOLD}[8] generate_phase4_handoff${NC}"
generate_phase4_handoff "$WORK_DIR"
result=$?
assert_eq "handoff 生成は rc=0" "0" "$result"
assert_eq "PHASE4-HANDOFF.md が生成される" "true" "$([ -f "${WORK_DIR}/PHASE4-HANDOFF.md" ] && echo true || echo false)"
handoff=$(cat "${WORK_DIR}/PHASE4-HANDOFF.md" 2>/dev/null)
assert_contains "繰延テストが載る" "task-02" "$handoff"
assert_contains "手動手順に command が載る" "npm run e2e" "$handoff"
assert_contains "サーバー起動手順が載る" "npm start" "$handoff"
assert_contains "サマリーに未解決件数" "未解決債務: 4 件" "$handoff"
assert_eq "プレースホルダ残留なし" "0" "$(grep -c '{{' "${WORK_DIR}/PHASE4-HANDOFF.md" || true)"

# --- Test 9: 債務ゼロなら handoff を生成しない ---
echo -e "\n${BOLD}[9] 債務ゼロで handoff 非生成${NC}"
rm -f "${WORK_DIR}/PHASE4-HANDOFF.md"
empty_ledger="${PROJECT_ROOT}/.forge/state/empty.jsonl"
: > "$empty_ledger"
generate_phase4_handoff "$WORK_DIR" "$empty_ledger"
assert_eq "債務ゼロでは生成されない" "false" "$([ -f "${WORK_DIR}/PHASE4-HANDOFF.md" ] && echo true || echo false)"

# --- Test 10: 空白入りパスでも動作 ---
echo -e "\n${BOLD}[10] 空白入りパス${NC}"
space_dir="${PROJECT_ROOT}/dir with space"
mkdir -p "$space_dir"
_saved_ledger="$QUALITY_LEDGER_FILE"
QUALITY_LEDGER_FILE="${space_dir}/quality debts.jsonl"
record_quality_debt "orphan_file" "task-05" "空白パステスト"
result=$?
assert_eq "空白パスでも rc=0" "0" "$result"
assert_eq "空白パスに記録される" "1" "$(jq -s 'length' "${space_dir}/quality debts.jsonl" | tr -d '\r')"
QUALITY_LEDGER_FILE="$_saved_ledger"

# ===== クリーンアップ =====
rm -rf "$PROJECT_ROOT"

# ===== 結果 =====
echo ""
echo -e "${BOLD}=========================================="
echo -e "  quality-ledger テスト結果"
echo -e "==========================================${NC}"
echo -e "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}SOME TESTS FAILED${NC}"
  exit 1
fi
