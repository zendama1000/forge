#!/bin/bash
# test-scaffold-report.sh — スキャフォールド棚卸しレポートのテスト
# fixture jsonl で (1) 0 発火修復段が候補に載る (2) ファイル不在で exit 0
# (3) コンポーネント突合表が出力される、を検証する。
# 使い方: bash .forge/tests/test-scaffold-report.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_SH="${PROJECT_ROOT}/.forge/loops/scaffold-report.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected} / actual: ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo -e "${BOLD}===== test-scaffold-report.sh =====${NC}"

# ===== fixture 環境（PROJECT_ROOT 構造を模倣し、スクリプトをコピーして相対解決させる） =====
FAKE_ROOT="${TMPDIR}/fake-root"
mkdir -p "${FAKE_ROOT}/.forge/loops" "${FAKE_ROOT}/.forge/state" "${FAKE_ROOT}/.forge/config"
cp "$REPORT_SH" "${FAKE_ROOT}/.forge/loops/scaffold-report.sh"

# validation-stats: crlf のみ発火（fence/extraction/failed は 0）
cat > "${FAKE_ROOT}/.forge/state/validation-stats.jsonl" <<'EOF'
{"stage":"synthesizer","recovery_level":"crlf","was_schema_mode":true}
{"stage":"researcher","recovery_level":"crlf","was_schema_mode":true}
EOF

# metrics: 2 ステージ
cat > "${FAKE_ROOT}/.forge/state/metrics.jsonl" <<'EOF'
{"stage":"implementer-t1","parse_success":true,"cost_usd":0.5}
{"stage":"implementer-t1","parse_success":false,"cost_usd":0.3}
{"stage":"synthesizer","parse_success":true,"cost_usd":1.2}
EOF

# task-events: investigator は発火、mutation は 0
cat > "${FAKE_ROOT}/.forge/state/task-events.jsonl" <<'EOF'
{"task_id":"t-1","event":"investigation_started"}
{"task_id":"t-1","event":"best_of_n_completed"}
EOF

echo '{"enabled": false, "components": {}}' > "${FAKE_ROOT}/.forge/config/ablation.json"

echo -e "\n${BOLD}Test 1: fixture データでの全セクション出力${NC}"
out=$(bash "${FAKE_ROOT}/.forge/loops/scaffold-report.sh" 2>&1)
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_contains "0 発火の修復段 fence が削減候補に載る" "削減候補: 修復段 'fence'" "$out"
assert_contains "crlf の発火数が出る" "crlf: 2件" "$out"
assert_contains "metrics のステージ集計が出る" "synthesizer: 1回" "$out"
assert_contains "コンポーネント突合表が出る" "mutation_audit" "$out"
assert_contains "0 発火コンポーネントが削減候補になる" "削減候補（0 発火" "$out"
assert_contains "発火済み investigator は稼働中" "稼働中" "$out"
assert_contains "best_of_n の発火がカウントされる" "best_of_n" "$out"
assert_contains "運用注記（即削除しない）" "即削除しない" "$out"

echo -e "\n${BOLD}Test 2: state ファイル全不在でも exit 0（graceful）${NC}"
FAKE_EMPTY="${TMPDIR}/fake-empty"
mkdir -p "${FAKE_EMPTY}/.forge/loops"
cp "$REPORT_SH" "${FAKE_EMPTY}/.forge/loops/scaffold-report.sh"
out2=$(bash "${FAKE_EMPTY}/.forge/loops/scaffold-report.sh" 2>&1)
rc2=$?
assert_eq "exit 0" "0" "$rc2"
assert_contains "データなし表示" "データなし" "$out2"

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
