#!/bin/bash
# test-ux-judgment.sh — UX判定システム（ux-judgment.sh）単体〜配線テスト
#
# 検証対象（ux-judgment-and-calibration-spec.md §3-§7, §9）:
#   - 設定読み込み / phase 別発火設定 / ablation OFF
#   - シナリオ生成の識別子ゲート（文脈遮断の機械検証）+ 再生成
#   - sim-user チャネル（知覚制限 disallowed / トランスクリプトゲート / verdict）
#   - 集約: 全一致 pass / 全一致 fail→fix タスク生成 / 不一致→エスカレーション債務
#   - fix cap / dedup / resolution_criteria 空の機械フィルタ
#   - LLM 集約失敗時の機械フォールバック
#   - P2: レンズ別 accepted-finding rate 集計
#   - 配線存在（dev-phases hook / main loop 続行 / task_finalize hook）
#
# 使い方: bash .forge/tests/test-ux-judgment.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

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
  # herestring を使う: pipefail 下で `echo 大 | grep -q` は grep 早期 exit の
  # SIGPIPE により偽 fail になる（64KB パイプバッファ超過時）。
  # `--` は "--flag" 形式の needle をオプション解釈させないため必須
  if grep -qF -- "$needle" <<< "$haystack"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:300}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== パス設定 =====
HARNESS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="/tmp/test-ux-judgment-$$"

echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$TEST_ROOT"
mkdir -p "${TEST_ROOT}/.forge/lib" "${TEST_ROOT}/.forge/state/notifications" \
  "${TEST_ROOT}/.forge/state/.lock" "${TEST_ROOT}/.forge/logs/development" \
  "${TEST_ROOT}/work"

cp "${HARNESS_ROOT}/.forge/lib/common.sh" "${TEST_ROOT}/.forge/lib/"
cp "${HARNESS_ROOT}/.forge/lib/ux-judgment.sh" "${TEST_ROOT}/.forge/lib/"
cp "${HARNESS_ROOT}/.forge/lib/quality-ledger.sh" "${TEST_ROOT}/.forge/lib/"
cp "${HARNESS_ROOT}/.forge/lib/ablation.sh" "${TEST_ROOT}/.forge/lib/"

trap "rm -rf '$TEST_ROOT'" EXIT

# ===== グローバル変数 =====
PROJECT_ROOT="$TEST_ROOT"
TASK_STACK="${TEST_ROOT}/.forge/state/task-stack.json"
TASK_EVENTS_FILE="${TEST_ROOT}/.forge/state/task-events.jsonl"
DEV_LOG_DIR="${TEST_ROOT}/.forge/logs/development"
AGENTS_DIR="${HARNESS_ROOT}/.claude/agents"
TEMPLATES_DIR="${HARNESS_ROOT}/.forge/templates"
SCHEMAS_DIR="${HARNESS_ROOT}/.forge/schemas"
ERRORS_FILE="${TEST_ROOT}/.forge/state/errors.jsonl"
WORK_DIR="${TEST_ROOT}/work"
RESEARCH_DIR="test-session"
json_fail_count=0
CLAUDE_TIMEOUT=600
DEV_CONFIG="${TEST_ROOT}/.forge/config/development.json"
mkdir -p "${TEST_ROOT}/.forge/config"
cat > "$DEV_CONFIG" << 'JSON'
{
  "server": { "start_command": "none", "health_check_url": "http://localhost:9099" },
  "browser_testing": {
    "enabled": true,
    "playwright_mcp": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"] },
    "headless": true
  }
}
JSON
touch "$ERRORS_FILE" "$TASK_EVENTS_FILE"
echo '{"tasks":[]}' > "$TASK_STACK"

# UX 設定/レンズは実物を使う（設定変更の回帰も検出できる）
UX_JUDGMENT_CONFIG="${HARNESS_ROOT}/.forge/config/ux-judgment.json"
UX_LENSES_DIR="${HARNESS_ROOT}/.forge/lenses"
UX_SCENARIOS_FILE="${TEST_ROOT}/.forge/state/ux-scenarios.json"
ABLATION_CONFIG="${TEST_ROOT}/.forge/config/ablation.json"

if ! source "${TEST_ROOT}/.forge/lib/common.sh"; then
  echo "FATAL: common.sh source 失敗" >&2; exit 1
fi
if ! source "${TEST_ROOT}/.forge/lib/quality-ledger.sh"; then
  echo "FATAL: quality-ledger.sh source 失敗" >&2; exit 1
fi
if ! source "${TEST_ROOT}/.forge/lib/ux-judgment.sh"; then
  echo "FATAL: ux-judgment.sh source 失敗" >&2; exit 1
fi
QUALITY_LEDGER_FILE="${TEST_ROOT}/.forge/state/quality-debts.jsonl"

# ===== 共通スタブ =====
MOCK_NOTIFY_CALLS=()
notify_human() { MOCK_NOTIFY_CALLS+=("$1|$2"); }
validate_json() { jq empty "$1" > /dev/null 2>&1; }
metrics_start() { :; }
metrics_record() { :; }
sync_task_stack() { :; }
ensure_server_running() { return "${MOCK_SERVER_RC:-0}"; }
SERVER_LC_REASON=""
MOCK_SERVER_RC=0

DEV_PHASES=(mvp core polish)
CURRENT_DEV_PHASE="polish"

echo -e "  ${GREEN}✓${NC} テスト環境作成完了"

# ========================================================================
# Group 1: 設定読み込み / phase 設定 / ablation
# ========================================================================
echo -e "\n${BOLD}===== Group 1: 設定 / phase 設定 / ablation =====${NC}"

load_ux_judgment_config 2>/dev/null
assert_eq "実 config で enabled=true" "true" "$UX_JUDGMENT_ENABLED"
assert_eq "max_lenses は 2 上限" "2" "$UX_MAX_LENSES"

assert_eq "mvp: structural=per_task" "per_task" "$(ux_phase_setting mvp structural)"
assert_eq "mvp: aesthetic=off" "off" "$(ux_phase_setting mvp aesthetic)"
assert_eq "core: sim_user=phase_exit" "phase_exit" "$(ux_phase_setting core sim_user)"
assert_eq "polish: aesthetic=phase_exit" "phase_exit" "$(ux_phase_setting polish aesthetic)"

# フォールバック: 未知 phase 名 → 最終 phase なら polish 設定を継承
DEV_PHASES=(foundation ui-layer final-polish)
assert_eq "未知 phase（最終）→ polish 設定" "phase_exit" "$(ux_phase_setting final-polish aesthetic)"
assert_eq "未知 phase（中間）→ core 設定" "off" "$(ux_phase_setting ui-layer aesthetic)"
assert_eq "未知 phase（中間）→ core sim_user" "phase_exit" "$(ux_phase_setting ui-layer sim_user)"
DEV_PHASES=(mvp core polish)

# ablation OFF
cat > "$ABLATION_CONFIG" << 'JSON'
{"experiment_name": "t", "enabled": true, "components": {"ux_judgment": false}}
JSON
source "${TEST_ROOT}/.forge/lib/ablation.sh"
apply_ablation_overrides 2>/dev/null
assert_eq "ablation で ux_judgment=false → 無効化" "false" "$UX_JUDGMENT_ENABLED"

# 無効時は phase_exit が一切発火しない（受入基準: ablation.json で一切発火しない）
rm -rf "${DEV_LOG_DIR}/ux-polish"
run_ux_judgment_phase_exit "polish" 2>/dev/null
assert_eq "無効時は出力ディレクトリも作られない" "false" \
  "$([ -d "${DEV_LOG_DIR}/ux-polish" ] && echo true || echo false)"

UX_JUDGMENT_ENABLED=true

# ========================================================================
# Group 1.5: run_claude の MCP config 絶対化（監査 A-1 — mock 定義前に実物で検証）
# ========================================================================
echo -e "\n${BOLD}===== Group 1.5: MCP config 絶対化（A-1） =====${NC}"

# 相対パスの MCP config + work_dir 指定で DRY RUN → CMD に絶対パスが出ることを確認
mkdir -p "${TEST_ROOT}/mcpwork"
echo '{"mcpServers":{}}' > "${TEST_ROOT}/rel-mcp.json"
a1_out=$(
  cd "$TEST_ROOT" || exit 1
  export FORGE_DRY_RUN=1
  export _RC_MCP_CONFIG="rel-mcp.json"
  run_claude "sonnet" "" "p" "${TEST_ROOT}/a1-out.json" "${TEST_ROOT}/a1-log.log" \
    "" 60 "${TEST_ROOT}/mcpwork" 2>/dev/null
)
assert_contains "MCP config が cd 前に絶対化される" "--mcp-config ${TEST_ROOT}/rel-mcp.json" "$a1_out"
assert_contains "strict-mcp-config も付与される" "--strict-mcp-config" "$a1_out"
unset _RC_MCP_CONFIG

# ========================================================================
# Group 2: シナリオ生成 — 識別子ゲート + 再生成
# ========================================================================
echo -e "\n${BOLD}===== Group 2: シナリオ生成（文脈遮断） =====${NC}"

CRITERIA_FILE="${TEST_ROOT}/.forge/state/criteria.json"
cat > "$CRITERIA_FILE" << 'JSON'
{
  "criteria": [
    {"id": "C-1", "description": "SessionManager がログイン状態を保持する", "files": ["session-manager.ts"]},
    {"id": "C-2", "description": "fortuneCard コンポーネントが運勢を表示する"}
  ]
}
JSON

# 漏出ありシナリオ
cat > "$UX_SCENARIOS_FILE" << 'JSON'
{"scenarios": [{"scenario_id": "UX-S-001", "user_goal": "SessionManager でログインする", "entry_url": "/", "action_budget": 10, "viewport": "mobile", "success_signal": "ログインできた"}]}
JSON
matched=$(ux_scenarios_identifier_gate "$UX_SCENARIOS_FILE" "$CRITERIA_FILE")
assert_contains "識別子漏出を検出する" "SessionManager" "$matched"

# クリーンなシナリオ
cat > "$UX_SCENARIOS_FILE" << 'JSON'
{"scenarios": [{"scenario_id": "UX-S-001", "user_goal": "今日の運勢が気になってサイトに来た。見たいものを見る", "entry_url": "/", "action_budget": 10, "viewport": "mobile", "success_signal": "運勢の内容をユーザーが確認できた"}]}
JSON
matched=$(ux_scenarios_identifier_gate "$UX_SCENARIOS_FILE" "$CRITERIA_FILE")
assert_eq "クリーンなシナリオは pass" "" "$matched"

# 再生成: 1回目漏出 → 2回目クリーン
rm -f "$UX_SCENARIOS_FILE"
MOCK_CLAUDE_CALL_COUNT=0
run_claude() {
  MOCK_CLAUDE_CALL_COUNT=$((MOCK_CLAUDE_CALL_COUNT + 1))
  local out="$4"
  if [ "$MOCK_CLAUDE_CALL_COUNT" -eq 1 ]; then
    echo '{"scenarios":[{"scenario_id":"UX-S-001","user_goal":"fortuneCard を見る","entry_url":"/","action_budget":10,"viewport":"mobile","success_signal":"見えた"}]}' > "$out"
  else
    echo '{"scenarios":[{"scenario_id":"UX-S-001","user_goal":"今日の運勢を知りたい","entry_url":"/","action_budget":10,"viewport":"mobile","success_signal":"運勢を確認できた"}]}' > "$out"
  fi
  return 0
}
run_ux_scenario_generator 2>/dev/null
assert_eq "漏出 → 再生成される（2回呼出）" "2" "$MOCK_CLAUDE_CALL_COUNT"
assert_eq "最終シナリオはクリーン" "" "$(ux_scenarios_identifier_gate "$UX_SCENARIOS_FILE" "$CRITERIA_FILE")"

# criteria 不在 → skip + 債務
rm -f "$UX_SCENARIOS_FILE" "$QUALITY_LEDGER_FILE"
_saved_criteria="$CRITERIA_FILE"
CRITERIA_FILE="/nonexistent-criteria-$$.json"
run_ux_scenario_generator 2>/dev/null
rc=$?
assert_eq "criteria 不在 → rc=2" "2" "$rc"
assert_contains "criteria 不在は債務記録" "deferred_test" "$(cat "$QUALITY_LEDGER_FILE" 2>/dev/null)"
CRITERIA_FILE="$_saved_criteria"

# ========================================================================
# Group 2.5: criteria fingerprint による再利用制御（監査 A-3）
# ========================================================================
echo -e "\n${BOLD}===== Group 2.5: シナリオ fingerprint（A-3） =====${NC}"

# fingerprint 刻印ヘルパー（fixture 用）
stamp_scenarios_fp() {
  local fp
  fp=$(md5sum "$CRITERIA_FILE" | cut -d' ' -f1)
  jq --arg fp "$fp" '. + {criteria_fingerprint: $fp}' "$UX_SCENARIOS_FILE" \
    > "${UX_SCENARIOS_FILE}.tmp" && mv "${UX_SCENARIOS_FILE}.tmp" "$UX_SCENARIOS_FILE"
}

cat > "$UX_SCENARIOS_FILE" << 'JSON'
{"scenarios": [{"scenario_id": "UX-S-001", "user_goal": "今日の運勢を知りたい", "entry_url": "/", "action_budget": 10, "viewport": "mobile", "success_signal": "運勢を確認できた"}]}
JSON

MOCK_CLAUDE_CALL_COUNT=0
run_claude() {
  MOCK_CLAUDE_CALL_COUNT=$((MOCK_CLAUDE_CALL_COUNT + 1))
  echo '{"scenarios":[{"scenario_id":"UX-S-001","user_goal":"新しく生成されたゴール","entry_url":"/","action_budget":10,"viewport":"mobile","success_signal":"確認できた"}]}' > "$4"
  return 0
}

# 一致 → 再利用（生成なし）
stamp_scenarios_fp
run_ux_scenario_generator 2>/dev/null
assert_eq "fingerprint 一致 → 再利用（生成なし）" "0" "$MOCK_CLAUDE_CALL_COUNT"

# 不一致（別プロジェクトの残骸を模擬）→ 再生成 + 新 fingerprint 刻印
jq '.criteria_fingerprint = "deadbeef-stale"' "$UX_SCENARIOS_FILE" \
  > "${UX_SCENARIOS_FILE}.tmp" && mv "${UX_SCENARIOS_FILE}.tmp" "$UX_SCENARIOS_FILE"
run_ux_scenario_generator 2>/dev/null
assert_eq "fingerprint 不一致 → 再生成される" "1" "$MOCK_CLAUDE_CALL_COUNT"
assert_eq "再生成後に現 criteria の fingerprint が刻印される" \
  "$(md5sum "$CRITERIA_FILE" | cut -d' ' -f1)" \
  "$(jq -r '.criteria_fingerprint' "$UX_SCENARIOS_FILE")"

# fingerprint 欠落（旧形式）→ 再生成
jq 'del(.criteria_fingerprint)' "$UX_SCENARIOS_FILE" \
  > "${UX_SCENARIOS_FILE}.tmp" && mv "${UX_SCENARIOS_FILE}.tmp" "$UX_SCENARIOS_FILE"
run_ux_scenario_generator 2>/dev/null
assert_eq "fingerprint 欠落 → 再生成される" "2" "$MOCK_CLAUDE_CALL_COUNT"

# ========================================================================
# Group 3: sim-user チャネル
# ========================================================================
echo -e "\n${BOLD}===== Group 3: sim-user チャネル =====${NC}"

# 知覚制限 disallowed-tools の構築
disallowed=$(ux_sim_user_disallowed_tools)
assert_contains "a11y snapshot が禁止される" "mcp__playwright__browser_snapshot" "$disallowed"
assert_contains "DOM evaluate が禁止される" "mcp__playwright__browser_evaluate" "$disallowed"
assert_contains "ref ベース click が禁止される" "mcp__playwright__browser_click" "$disallowed"
assert_contains "コードベース遮断（Read）" "Read" "$disallowed"
assert_contains "コードベース遮断（Bash）" "Bash" "$disallowed"

# シナリオを用意（fingerprint 付き — A-3 の再生成トリガを回避）
cat > "$UX_SCENARIOS_FILE" << 'JSON'
{"scenarios": [{"scenario_id": "UX-S-001", "user_goal": "今日の運勢を知りたい", "entry_url": "/", "action_budget": 10, "viewport": "mobile", "success_signal": "運勢を確認できた"}]}
JSON
stamp_scenarios_fp

# MCP config 生成をスタブ（npx 存在に依存しない）
ux_build_mcp_config() { echo '{"mcpServers":{}}' > "$1"; }

out_dir="${DEV_LOG_DIR}/ux-test-sim"
mkdir -p "$out_dir"

# 完遂 → pass
MOCK_SIM_OUTPUT='{"scenario_id":"UX-S-001","completed":true,"actions_taken":4,"shortest_path_estimate":3,"expectation_violations":[],"hesitations":[],"backtracks":0,"transcript_path":"t"}'
MOCK_SIM_LOG=""
run_claude() {
  echo "$MOCK_SIM_OUTPUT" > "$4"
  [ -n "$MOCK_SIM_LOG" ] && echo "$MOCK_SIM_LOG" > "$5"
  return 0
}
run_ux_sim_user_channel "test-sim" "$out_dir" 2>/dev/null
assert_eq "全シナリオ完遂 → verdict=pass" "pass" \
  "$(jq -r '.verdict' "${out_dir}/sim-user-results.json")"

# 未完遂 → fail
MOCK_SIM_OUTPUT='{"scenario_id":"UX-S-001","completed":false,"actions_taken":10,"expectation_violations":[{"step":2,"expected":"一覧が出る","actual":"白画面"}],"hesitations":[],"backtracks":2,"abort_reason":"予算超過"}'
run_ux_sim_user_channel "test-sim" "$out_dir" 2>/dev/null
assert_eq "未完遂あり → verdict=fail" "fail" \
  "$(jq -r '.verdict' "${out_dir}/sim-user-results.json")"
assert_eq "摩擦イベントが集計される" "1" \
  "$(jq -r '.friction.expectation_violations' "${out_dir}/sim-user-results.json")"

# トランスクリプトゲート: 禁止ツール使用検出 → invalid → verdict=skip（有効結果0件）
rm -f "$QUALITY_LEDGER_FILE"
MOCK_SIM_OUTPUT='{"scenario_id":"UX-S-001","completed":true,"actions_taken":2}'
MOCK_SIM_LOG='{"type":"tool_use","name":"mcp__playwright__browser_snapshot","input":{}} tool_use browser_snapshot"'
run_ux_sim_user_channel "test-sim" "$out_dir" 2>/dev/null
assert_eq "知覚制限違反 → 結果 invalid（verdict=skip）" "skip" \
  "$(jq -r '.verdict' "${out_dir}/sim-user-results.json")"
assert_contains "違反は債務記録される" "warn_gate" "$(cat "$QUALITY_LEDGER_FILE" 2>/dev/null)"
MOCK_SIM_LOG=""

# ========================================================================
# Group 4: 集約（verdict 突合 / fix タスク / エスカレーション）
# ========================================================================
echo -e "\n${BOLD}===== Group 4: 集約 =====${NC}"

agg_dir="${DEV_LOG_DIR}/ux-agg-test"
mkdir -p "$agg_dir"
echo '{"tasks":[]}' > "$TASK_STACK"

# 全チャネル pass
echo '{"verdict":"pass","summary":{"violations_total":0}}' > "${agg_dir}/structural-result.json"
echo '{"results":[],"verdict":"pass"}' > "${agg_dir}/sim-user-results.json"
echo '{"lenses":[],"verdict":"pass"}' > "${agg_dir}/aesthetic-results.json"
run_ux_aggregation "agg-test" "$agg_dir" 2>/dev/null
assert_eq "全チャネル pass → verdict=pass" "pass" \
  "$(jq -r '.verdict' "${agg_dir}/ux-judgment-result.json")"
assert_eq "pass では fix タスクなし" "0" "$(jq '.tasks | length' "$TASK_STACK")"

# 全チャネル fail → fix（LLM 集約をモック）
echo '{"verdict":"fail","summary":{"violations_total":3}}' > "${agg_dir}/structural-result.json"
echo '{"results":[],"verdict":"fail"}' > "${agg_dir}/sim-user-results.json"
echo '{"lenses":[{"lens_id":"lens-taste","valid":true,"verdict":"fix_needed","must_fix":[]}],"verdict":"fail"}' > "${agg_dir}/aesthetic-results.json"
run_claude() {
  echo '{"verdict":"fix","must_fix":[
    {"title":"主ボタンのコントラスト不足","description":"CTA が背景に沈む","resolution_criteria":"コントラスト比 4.5 以上にする","origin_channel":"structural"},
    {"title":"ナビの迷い","description":"一覧への導線が2つある","resolution_criteria":"導線を1つに統一","origin_channel":"aesthetic","origin_lens":"lens-taste"},
    {"title":"criteria空の項目","description":"x","resolution_criteria":"","origin_channel":"aesthetic"}
  ],"rejected_items":[],"contradictions":[]}' > "$4"
  return 0
}
run_ux_aggregation "agg-test" "$agg_dir" 2>/dev/null
assert_eq "全チャネル fail → verdict=fix" "fix" \
  "$(jq -r '.verdict' "${agg_dir}/ux-judgment-result.json")"
assert_eq "fix タスクが生成される（criteria 空は除外され2件）" "2" \
  "$(jq '[.tasks[] | select(.task_id | startswith("ux-fix-"))] | length' "$TASK_STACK")"
assert_eq "origin_lens が保存される" "lens-taste" \
  "$(jq -r '[.tasks[] | select(.origin_lens != null)] | first | .origin_lens' "$TASK_STACK")"
assert_eq "タスク生成フラグが立つ" "true" "$UX_JUDGMENT_TASKS_CREATED"
assert_contains "ux_fix_created イベントに origin_lens" '"origin_lens":"lens-taste"' \
  "$(cat "$TASK_EVENTS_FILE")"
assert_contains "fix タスクに resolution_criteria が引き継がれる" "resolution_criteria" \
  "$(jq -r '.tasks[0].investigator_fix' "$TASK_STACK")"

# dedup: 同一タイトルの pending fix は再生成しない
run_ux_aggregation "agg-test" "$agg_dir" 2>/dev/null
assert_eq "dedup: 同一 must_fix で増殖しない" "2" \
  "$(jq '[.tasks[] | select(.task_id | startswith("ux-fix-"))] | length' "$TASK_STACK")"

# 不一致 → エスカレーション（record_and_continue）
rm -f "$QUALITY_LEDGER_FILE"
MOCK_NOTIFY_CALLS=()
echo '{"verdict":"pass"}' > "${agg_dir}/structural-result.json"
echo '{"results":[],"verdict":"fail"}' > "${agg_dir}/sim-user-results.json"
echo '{"lenses":[],"verdict":"pass"}' > "${agg_dir}/aesthetic-results.json"
run_ux_aggregation "agg-test" "$agg_dir" 2>/dev/null
assert_eq "不一致 → verdict=escalated" "escalated" \
  "$(jq -r '.verdict' "${agg_dir}/ux-judgment-result.json")"
assert_eq "escalated フラグ" "true" "$(jq -r '.escalated' "${agg_dir}/ux-judgment-result.json")"
assert_contains "ux_disagreement 債務が記録される" "ux_disagreement" \
  "$(cat "$QUALITY_LEDGER_FILE" 2>/dev/null)"
assert_eq "人間通知が出る" "1" "${#MOCK_NOTIFY_CALLS[@]}"

# fix cap: 上限到達で生成拒否 + 債務
echo '{"tasks":[]}' > "$TASK_STACK"
for i in 1 2 3 4 5 6; do
  jq --arg id "ux-fix-agg-test-${i}-000000" \
    '.tasks += [{task_id: $id, description: ("UX修正: 既存" + $id), status: "completed"}]' \
    "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
done
rm -f "$QUALITY_LEDGER_FILE"
created=$(create_ux_fix_tasks "agg-test" \
  '[{"title":"新規","description":"x","resolution_criteria":"y を z にする","origin_channel":"aesthetic","origin_lens":"lens-taste"}]' 2>/dev/null)
assert_eq "cap 到達 → 生成 0 件" "0" "$created"
assert_contains "fix_cap_reached 債務" "fix_cap_reached" "$(cat "$QUALITY_LEDGER_FILE" 2>/dev/null)"

# ========================================================================
# Group 5: LLM 集約失敗時の機械フォールバック
# ========================================================================
echo -e "\n${BOLD}===== Group 5: 集約フォールバック =====${NC}"

echo '{"verdict":"fail","checks":[{"check":"contrast","viewport":"mobile","pass":false,"violation_count":2,"violations":[{"detail":"コントラスト比 2.1 < 4.5"}]}],"summary":{"violations_total":2}}' > "${agg_dir}/structural-result.json"
echo '{"lenses":[{"lens_id":"lens-usability","valid":true,"verdict":"fix_needed","must_fix":[{"title":"フォーカス不可視","description":"x","severity":"high","resolution_criteria":"focus-visible を全ボタンに付与"}]}],"verdict":"fail"}' > "${agg_dir}/aesthetic-results.json"
run_claude() { return 1; }
fallback=$(ux_run_aggregator_llm "agg-test" "$agg_dir" 2>/dev/null)
assert_contains "フォールバックに構造違反が含まれる" "構造検査違反" "$fallback"
assert_contains "フォールバックに美観 must_fix が含まれる" "フォーカス不可視" "$fallback"
assert_contains "フォールバックでも origin_lens 保持" "lens-usability" "$fallback"
fb_count=$(jq 'length' <<< "$fallback" 2>/dev/null || echo -1)
assert_eq "フォールバックは最大3件" "true" "$([ "$fb_count" -le 3 ] && [ "$fb_count" -ge 1 ] && echo true || echo false)"

# ========================================================================
# Group 6: P2 レンズ採択率
# ========================================================================
echo -e "\n${BOLD}===== Group 6: レンズ採択率（P2） =====${NC}"

rm -f "$TASK_EVENTS_FILE"
touch "$TASK_EVENTS_FILE"
cal_file="${TEST_ROOT}/.forge/state/calibration-data.jsonl"
rm -f "$cal_file"

record_task_event "ux-fix-p-1-000001" "ux_fix_created" '{"origin_lens":"lens-taste","origin_channel":"aesthetic","phase_id":"p"}'
record_task_event "ux-fix-p-2-000002" "ux_fix_created" '{"origin_lens":"lens-taste","origin_channel":"aesthetic","phase_id":"p"}'
record_task_event "ux-fix-p-3-000003" "ux_fix_created" '{"origin_lens":"lens-taste","origin_channel":"aesthetic","phase_id":"p"}'
# 1: completed（stack） 2: completed（events）だが human reject 3: 未完了
cat > "$TASK_STACK" << 'JSON'
{"tasks":[
  {"task_id":"ux-fix-p-1-000001","status":"completed"},
  {"task_id":"ux-fix-p-2-000002","status":"pending"},
  {"task_id":"ux-fix-p-3-000003","status":"pending"}
]}
JSON
record_task_event "ux-fix-p-2-000002" "status_changed" '{"new_status":"completed"}'
echo '{"id":"c1","evaluator":"human-direct","task_id":"ux-fix-p-2-000002","human_judgment":"reject","correct_judgment":"reject"}' > "$cal_file"

rates=$(compute_lens_acceptance_rates "$TASK_EVENTS_FILE" "$cal_file" "$TASK_STACK")
assert_contains "レンズ別 rate が出る" "lens-taste: 1/3" "$rates"
assert_contains "閾値未満は警告表示" "無効化候補" "$rates"

# ========================================================================
# Group 7: 配線存在（dev-phases hook / main loop / task_finalize）
# ========================================================================
echo -e "\n${BOLD}===== Group 7: 配線存在 =====${NC}"

assert_contains "dev-phases に phase_exit フック" "run_ux_judgment_phase_exit" \
  "$(cat "${HARNESS_ROOT}/.forge/lib/dev-phases.sh")"
assert_contains "main ループに phase 続行チェック" "_post_completion_pending" \
  "$(cat "${HARNESS_ROOT}/.forge/loops/ralph-loop.sh")"
assert_contains "task_finalize に per_task フック" "run_ux_structural_per_task" \
  "$(cat "${HARNESS_ROOT}/.forge/loops/ralph-loop.sh")"
assert_contains "ralph-loop が ux-judgment.sh を source" "ux-judgment.sh" \
  "$(cat "${HARNESS_ROOT}/.forge/loops/ralph-loop.sh")"
assert_contains "ablation に ux_judgment トグル" "ux_judgment" \
  "$(cat "${HARNESS_ROOT}/.forge/lib/ablation.sh")"
assert_contains "feedback.sh が ux-judgment-result を記録対象に含む" "ux-judgment" \
  "$(cat "${HARNESS_ROOT}/.forge/lib/calibration.sh")"
assert_contains "browser-test.sh に構造検査ランナー" "execute_structural_check" \
  "$(cat "${HARNESS_ROOT}/.forge/lib/browser-test.sh")"
assert_eq "構造検査 JS が存在" "true" \
  "$([ -f "${HARNESS_ROOT}/.forge/templates/ux-structural-check.js" ] && echo true || echo false)"

# ========================================================================
# サマリー
# ========================================================================
echo ""
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL_COUNT"
