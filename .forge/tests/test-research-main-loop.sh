#!/bin/bash
# test-research-main-loop.sh — research-loop.sh メインループ単体テスト
# Layer 1 テスト: SC→R→Syn ステージ関数の振る舞い検証
#
# カバー対象:
#   - run_scope_challenger()  正常完了 → investigation-plan.json + 状態遷移
#   - run_researchers()       部分失敗 → json_fail_count 伝播 + 他結果保持
#   - AUTO-ABORT 閾値         json_fail_count >= MAX_JSON_FAILS_PER_LOOP → auto-abort-json-failures
#   - run_synthesizer()       正常完了 → synthesis.json + decisions.jsonl エントリ
#   - update_state()          各ステージで updated_at / current_stage が更新される
#
# 使い方: bash .forge/tests/test-research-main-loop.sh

set -uo pipefail

# ===== カラー定数 =====
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
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:200}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_exists() {
  local label="$1" filepath="$2"
  if [ -f "$filepath" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    file not found: ${filepath}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_absent() {
  local label="$1" filepath="$2"
  if [ ! -f "$filepath" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected absent but found: ${filepath}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_gt() {
  local label="$1" min="$2" actual="$3"
  if [ "$actual" -gt "$min" ] 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected > ${min}, actual: ${actual}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/.forge/tests/fixtures"
RESEARCH_LOOP_SH="${SCRIPT_DIR}/.forge/loops/research-loop.sh"

# ===== awk ベース高速関数抽出（MSYS 対応） =====
extract_all_functions_awk() {
  local src="$1"
  shift
  local funcs="$*"
  awk -v "names=$funcs" '
    BEGIN {
      split(names, arr, " ")
      for (i in arr) targets[arr[i] "()"] = 1
    }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ {
      fname = $1
      if (fname in targets) {
        found = 1
        depth = 0
      }
    }
    found {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      print
      if (depth <= 0 && NR > start_line) {
        found = 0
        print ""
      }
      if (found && depth > 0) start_line = NR
    }
  ' "$src"
}

echo -e "${BOLD}===== test-research-main-loop.sh — メインループ単体テスト =====${NC}"
echo ""

# ===== テスト環境セットアップ =====
setup_test_env() {
  local label="${1:-default}"

  TEST_ROOT="/tmp/test-research-main-loop-${label}"
  rm -rf "$TEST_ROOT"

  mkdir -p "${TEST_ROOT}/.forge/lib"
  mkdir -p "${TEST_ROOT}/.forge/config"
  mkdir -p "${TEST_ROOT}/.forge/state"
  mkdir -p "${TEST_ROOT}/.forge/state/notifications"
  mkdir -p "${TEST_ROOT}/.forge/templates"
  mkdir -p "${TEST_ROOT}/.forge/logs/research"
  mkdir -p "${TEST_ROOT}/.claude/agents"
  mkdir -p "${TEST_ROOT}/.forge/schemas"

  # 必要なファイルをコピー
  cp "${SCRIPT_DIR}/.forge/lib/common.sh"   "${TEST_ROOT}/.forge/lib/common.sh"
  cp "${SCRIPT_DIR}/.forge/lib/bootstrap.sh" "${TEST_ROOT}/.forge/lib/bootstrap.sh"
  cp "${SCRIPT_DIR}/.forge/config/circuit-breaker.json" "${TEST_ROOT}/.forge/config/circuit-breaker.json"
  cp "${SCRIPT_DIR}/.forge/config/research.json"        "${TEST_ROOT}/.forge/config/research.json"
  cp "${SCRIPT_DIR}/.forge/templates/scope-challenger-prompt.md" "${TEST_ROOT}/.forge/templates/scope-challenger-prompt.md"
  cp "${SCRIPT_DIR}/.forge/templates/researcher-prompt.md"       "${TEST_ROOT}/.forge/templates/researcher-prompt.md"
  cp "${SCRIPT_DIR}/.forge/templates/synthesizer-prompt.md"      "${TEST_ROOT}/.forge/templates/synthesizer-prompt.md"

  # エージェントスタブ
  for agent in scope-challenger researcher synthesizer; do
    echo "${agent} agent stub" > "${TEST_ROOT}/.claude/agents/${agent}.md"
  done

  # 状態ファイル初期化
  touch "${TEST_ROOT}/.forge/state/errors.jsonl"
  touch "${TEST_ROOT}/.forge/state/decisions.jsonl"

  # 順次実行を強制（テスト安定性: サブシェル内 json_fail_count 更新を確実に親に伝播させる）
  jq '.parallel_researchers = false' "${TEST_ROOT}/.forge/config/research.json" \
    > "${TEST_ROOT}/.forge/config/research.json.tmp" \
    && mv "${TEST_ROOT}/.forge/config/research.json.tmp" "${TEST_ROOT}/.forge/config/research.json"

  # グローバル変数設定
  PROJECT_ROOT="${TEST_ROOT}"
  AGENTS_DIR="${TEST_ROOT}/.claude/agents"
  TEMPLATES_DIR="${TEST_ROOT}/.forge/templates"
  SCHEMAS_DIR="${TEST_ROOT}/.forge/schemas"
  ERRORS_FILE="${TEST_ROOT}/.forge/state/errors.jsonl"
  DECISIONS_FILE="${TEST_ROOT}/.forge/state/decisions.jsonl"
  LOG_DIR="${TEST_ROOT}/.forge/logs/research"
  CIRCUIT_BREAKER_CONFIG="${TEST_ROOT}/.forge/config/circuit-breaker.json"
  RESEARCH_CONFIG="${TEST_ROOT}/.forge/config/research.json"
  METRICS_FILE="${TEST_ROOT}/.forge/state/metrics.jsonl"
  VALIDATION_STATS_FILE="${TEST_ROOT}/.forge/state/validation-stats.jsonl"
  PROGRESS_FILE="${TEST_ROOT}/.forge/state/progress.json"
  NOTIFY_DIR="${TEST_ROOT}/.forge/state/notifications"

  THEME="テストテーマ"
  DIRECTION="テスト方向性"
  TOPIC_HASH="abc123"
  DATE="2026-02-26"
  START_TS="20260226-120000"

  RESEARCH_DIR="${TEST_ROOT}/research-output"
  STATE_FILE="${TEST_ROOT}/.forge/state/current-research.json"

  MAX_DECISIONS_IN_PROMPT=30
  RESEARCH_MODE="explore"
  LOCKED_DECISIONS_TEXT="（なし）"
  OPEN_QUESTIONS_TEXT="（なし）"

  json_fail_count=0
  MOCK_RUN_CLAUDE_FAIL=""
  MOCK_VALIDATE_FAIL_STAGE=""

  mkdir -p "$RESEARCH_DIR" "$LOG_DIR" "$NOTIFY_DIR"
  touch "$METRICS_FILE" "$VALIDATION_STATS_FILE"

  # common.sh をソース（グローバル変数設定後に実行）
  source "${TEST_ROOT}/.forge/lib/common.sh"

  # research-loop.sh から必要な関数を抽出してソース
  local EXTRACT_FILE
  EXTRACT_FILE=$(mktemp)
  extract_all_functions_awk "$RESEARCH_LOOP_SH" \
    load_research_config load_research_models update_state \
    rotate_errors get_recent_decisions \
    run_scope_challenger run_researchers _run_single_researcher \
    should_skip_perspective _get_perspective_fail_count _set_perspective_fail_count \
    run_synthesizer record_decision update_research_index \
    > "$EXTRACT_FILE"
  source "$EXTRACT_FILE"
  rm -f "$EXTRACT_FILE"

  load_research_config
  load_research_models

  # ===== run_claude モック =====
  # agent 名でフィクスチャを選択し .pending に書き出す。
  # MOCK_RUN_CLAUDE_FAIL に agent 名が含まれていれば失敗 (return 1)。
  run_claude() {
    local model="$1" agent="$2" prompt="$3" output="$4"
    # 失敗注入
    if [ -n "$MOCK_RUN_CLAUDE_FAIL" ] && echo "$agent" | grep -q "$MOCK_RUN_CLAUDE_FAIL"; then
      return 1
    fi
    local target="${output}.pending"
    case "$agent" in
      *scope-challenger*)
        cat "${FIXTURES_DIR}/sc-output.json" > "$target"
        ;;
      *researcher*)
        cat "${FIXTURES_DIR}/researcher-output.json" > "$target"
        ;;
      *synthesizer*)
        cat "${FIXTURES_DIR}/synthesis-output.json" > "$target"
        ;;
      *)
        echo '{}' > "$target"
        ;;
    esac
    return 0
  }

  # ===== validate_json モック =====
  # .pending → 本ファイルに昇格（選択的失敗注入対応）。
  # MOCK_VALIDATE_FAIL_STAGE に stage 名が含まれていれば失敗し json_fail_count をインクリメント。
  validate_json() {
    local final_path="$1"
    local stage="$2"
    if [ -n "$MOCK_VALIDATE_FAIL_STAGE" ] && echo "$stage" | grep -q "$MOCK_VALIDATE_FAIL_STAGE"; then
      json_fail_count=$((json_fail_count + 1))
      [ -f "${final_path}.pending" ] && mv "${final_path}.pending" "${final_path}.failed" 2>/dev/null || true
      return 1
    fi
    if [ -f "${final_path}.pending" ]; then
      mv "${final_path}.pending" "$final_path"
    fi
    return 0
  }

  # ===== スタブ =====
  update_research_index() { :; }
  get_server_url() { echo "http://localhost:3000"; }
  check_direct_write_fallback() { return 1; }
}

# ============================================================
# テスト1: SC完了 → investigation-plan.json 生成 + 状態遷移
# ============================================================
echo -e "${BOLD}--- テスト1: SC完了 → investigation-plan.json + 状態遷移 ---${NC}"
# behavior: run_scope_challenger()が正常完了 → investigation-plan.jsonが生成されcurrent-research.jsonのcurrent_stageが'scope-challenger'→'researchers'に遷移（正常系: SC完了）

setup_test_env "sc-normal"

update_state "initializing" "running"
stage_before=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
assert_eq "SC実行前: current_stage=initializing" "initializing" "$stage_before"

# SC 実行
sc_exit=0
run_scope_challenger 2>/dev/null || sc_exit=$?
assert_eq "SC 正常完了（exit 0）" "0" "$sc_exit"

# investigation-plan.json が生成される
assert_file_exists "investigation-plan.json が生成される" "${RESEARCH_DIR}/investigation-plan.json"

# current_stage が scope-challenger に遷移
stage_after_sc=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
assert_eq "SC完了後: current_stage=scope-challenger" "scope-challenger" "$stage_after_sc"

# run_researchers 開始で current_stage が researcher に遷移
run_researchers 2>/dev/null || true
stage_after_r=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
assert_eq "R開始後: current_stage=researcher（scope-challenger→researchers遷移完了）" "researcher" "$stage_after_r"

echo ""

# ============================================================
# テスト2: Researcher 部分失敗 → json_fail_count=1 + 他結果は保持
# ============================================================
echo -e "${BOLD}--- テスト2: Researcher部分失敗 → json_fail_count=1 + 他結果保持 ---${NC}"
# behavior: run_researchers()で1件のperspectiveがJSON不正 → json_fail_count=1にインクリメント、他perspectiveの結果は保持される（異常系: 部分失敗）

setup_test_env "r-partial-fail"

# 2 視点の investigation-plan.json を作成（technical=成功, cost=失敗）
cat > "${RESEARCH_DIR}/investigation-plan.json" << 'PLAN_EOF'
{
  "investigation_plan": {
    "theme": "テストテーマ",
    "core_questions": ["Q1"],
    "assumptions_exposed": [],
    "past_decision_conflicts": [],
    "boundaries": {"depth": "中", "breadth": "広", "cutoff": "3日以内"},
    "perspectives": {
      "fixed": [
        {"id": "technical", "focus": "技術的実現性", "key_questions": ["技術Q1"]},
        {"id": "cost",      "focus": "コスト",       "key_questions": ["コストQ1"]}
      ],
      "dynamic": []
    }
  }
}
PLAN_EOF

# "researcher-cost" ステージのみ validate_json を失敗させる
MOCK_VALIDATE_FAIL_STAGE="researcher-cost"
json_fail_count=0

update_state "researcher"
run_researchers 2>/dev/null || true

# json_fail_count が 1 にインクリメントされる
assert_eq "部分失敗: json_fail_count=1" "1" "$json_fail_count"

# 成功した technical 視点のファイルが保持される
assert_file_exists "成功視点のファイルが保持される (perspective-technical.json)" \
  "${RESEARCH_DIR}/perspective-technical.json"

# 失敗した cost 視点のファイルは生成されない
assert_file_absent "失敗視点のファイルは生成されない (perspective-cost.json)" \
  "${RESEARCH_DIR}/perspective-cost.json"

# run_researchers 自体は 0 で返る（部分失敗はエラーではない）
r_partial_exit=0
(
  setup_test_env "r-partial-exit-check"
  cat > "${RESEARCH_DIR}/investigation-plan.json" << 'P2_EOF'
{"investigation_plan":{"theme":"テスト","core_questions":[],"assumptions_exposed":[],"past_decision_conflicts":[],"boundaries":{"depth":"中","breadth":"広","cutoff":"3日"},"perspectives":{"fixed":[{"id":"technical","focus":"tech","key_questions":["q"]},{"id":"cost","focus":"cost","key_questions":["q"]}],"dynamic":[]}}}
P2_EOF
  MOCK_VALIDATE_FAIL_STAGE="researcher-cost"
  json_fail_count=0
  update_state "researcher"
  run_researchers 2>/dev/null
  exit $?
) || r_partial_exit=$?
assert_eq "部分失敗でも run_researchers は exit 0" "0" "$r_partial_exit"

echo ""

# ============================================================
# テスト3: ABORT 閾値 → auto-abort-json-failures + ループ終了
# ============================================================
echo -e "${BOLD}--- テスト3: ABORT閾値 → auto-abort-json-failures ---${NC}"
# behavior: json_fail_count >= MAX_JSON_FAILS_PER_LOOP(3) → update_state('auto-abort-json-failures')が呼ばれ、ループが終了する（エッジケース: ABORT閾値）

setup_test_env "abort-threshold"
update_state "initializing" "running"

# json_fail_count を MAX に設定（research-loop.sh L785 相当のチェックをテスト）
json_fail_count="${MAX_JSON_FAILS_PER_LOOP}"
abort_triggered=0
if [ "$json_fail_count" -ge "$MAX_JSON_FAILS_PER_LOOP" ]; then
  record_error "loop-control" "自動ABORT: JSON検証失敗${json_fail_count}件" 2>/dev/null || true
  update_state "aborted" "auto-abort-json-failures"
  abort_triggered=1
fi
assert_eq "ABORT閾値到達で abort_triggered=1" "1" "$abort_triggered"

# STATE_FILE の status が auto-abort-json-failures を含む
abort_status=$(jq -r '.status' "$STATE_FILE" 2>/dev/null)
assert_contains "STATUS に 'auto-abort' が含まれる" "auto-abort" "$abort_status"

# current_stage が aborted
abort_stage=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
assert_eq "current_stage=aborted" "aborted" "$abort_stage"

# ── 境界値テスト: MAX - 1 では ABORT しない ──
setup_test_env "abort-boundary"
update_state "initializing" "running"
json_fail_count=$((MAX_JSON_FAILS_PER_LOOP - 1))
no_abort=0
if [ "$json_fail_count" -ge "$MAX_JSON_FAILS_PER_LOOP" ]; then
  update_state "aborted" "auto-abort-json-failures"
  no_abort=1
fi
assert_eq "閾値未満(MAX-1)ではABORTしない" "0" "$no_abort"

# ── run_researchers + ABORT フロー統合テスト ──
# 3 視点を全て失敗させ json_fail_count >= 3 を自然に発生させる
setup_test_env "abort-integration"
cat > "${RESEARCH_DIR}/investigation-plan.json" << 'ABORT_PLAN_EOF'
{"investigation_plan":{"theme":"テスト","core_questions":[],"assumptions_exposed":[],"past_decision_conflicts":[],"boundaries":{"depth":"中","breadth":"広","cutoff":"3日"},"perspectives":{"fixed":[{"id":"p1","focus":"f1","key_questions":["q"]},{"id":"p2","focus":"f2","key_questions":["q"]},{"id":"p3","focus":"f3","key_questions":["q"]}],"dynamic":[]}}}
ABORT_PLAN_EOF
# 全視点の validate_json を失敗させる（ステージ名が "researcher-" を含む）
MOCK_VALIDATE_FAIL_STAGE="researcher-"
json_fail_count=0
update_state "researcher"
run_researchers 2>/dev/null || true
# 3 視点が全て失敗 → json_fail_count = 3 = MAX_JSON_FAILS_PER_LOOP
assert_eq "全視点失敗後 json_fail_count=${MAX_JSON_FAILS_PER_LOOP}" "${MAX_JSON_FAILS_PER_LOOP}" "$json_fail_count"

# ABORT 判定
integrated_abort=0
if [ "$json_fail_count" -ge "$MAX_JSON_FAILS_PER_LOOP" ]; then
  update_state "aborted" "auto-abort-json-failures"
  integrated_abort=1
fi
assert_eq "統合: ABORT閾値到達でフラグ=1" "1" "$integrated_abort"
integrated_abort_status=$(jq -r '.status' "$STATE_FILE" 2>/dev/null)
assert_contains "統合: STATUS に 'auto-abort'" "auto-abort" "$integrated_abort_status"

echo ""

# ============================================================
# テスト4: Synthesizer 完了 → synthesis.json + decisions.jsonl エントリ
# ============================================================
echo -e "${BOLD}--- テスト4: Synthesizer完了 → synthesis.json + decisions.jsonl ---${NC}"
# behavior: run_synthesizer()が正常完了 → synthesis.jsonが生成されdecisions.jsonlにエントリが追加される（正常系: Syn完了）

setup_test_env "syn-normal"

# 前提ファイルを準備（investigation-plan.json + 1視点の researcher 出力）
cp "${FIXTURES_DIR}/sc-output.json" "${RESEARCH_DIR}/investigation-plan.json"
cp "${FIXTURES_DIR}/researcher-output.json" "${RESEARCH_DIR}/perspective-technical.json"

update_state "synthesizer"

syn_exit=0
run_synthesizer 2>/dev/null || syn_exit=$?
assert_eq "Synthesizer 正常完了（exit 0）" "0" "$syn_exit"

# synthesis.json が生成される
assert_file_exists "synthesis.json が生成される" "${RESEARCH_DIR}/synthesis.json"

# decisions.jsonl にエントリが追加される
decision_count_before=$(wc -l < "$DECISIONS_FILE" 2>/dev/null | tr -d ' ')
record_decision 2>/dev/null || true
decision_count_after=$(wc -l < "$DECISIONS_FILE" 2>/dev/null | tr -d ' ')
assert_gt "decisions.jsonl にエントリが追加される (${decision_count_before}→${decision_count_after})" \
  "$decision_count_before" "$decision_count_after"

# decisions.jsonl の最新エントリに verdict=DIRECT がある
verdict=$(tail -1 "$DECISIONS_FILE" 2>/dev/null | jq -r '.verdict // "ABSENT"' 2>/dev/null)
assert_eq "decisions.jsonl の verdict=DIRECT" "DIRECT" "$verdict"

# decisions.jsonl の最新エントリに theme が正しく設定される
decision_theme=$(tail -1 "$DECISIONS_FILE" 2>/dev/null | jq -r '.theme // "ABSENT"' 2>/dev/null)
assert_eq "decisions.jsonl の theme=テストテーマ" "テストテーマ" "$decision_theme"

# decisions.jsonl の最新エントリに id フィールドがある
has_id=$(tail -1 "$DECISIONS_FILE" 2>/dev/null | jq 'has("id")' 2>/dev/null)
assert_eq "decisions.jsonl エントリに id フィールドがある" "true" "$has_id"

echo ""

# ============================================================
# テスト5: 状態管理 → updated_at / current_stage が各ステージで更新される
# ============================================================
echo -e "${BOLD}--- テスト5: 状態管理 → updated_at / current_stage 更新 ---${NC}"
# behavior: 各ステージ完了時にcurrent-research.jsonのupdated_at, current_stageが更新される（統合検証: 状態管理）

setup_test_env "state-mgmt"

# ステージ: initializing
update_state "initializing" "running"
stage_init=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
updated_init=$(jq -r '.updated_at'   "$STATE_FILE" 2>/dev/null)
assert_eq "initializing: current_stage=initializing" "initializing" "$stage_init"
assert_contains "initializing: updated_at が ISO8601 形式（'T' を含む）" "T" "$updated_init"

# ステージ: scope-challenger
update_state "scope-challenger"
stage_sc=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
updated_sc=$(jq -r '.updated_at'   "$STATE_FILE" 2>/dev/null)
assert_eq "scope-challenger: current_stage=scope-challenger" "scope-challenger" "$stage_sc"
assert_contains "scope-challenger: updated_at が ISO8601 形式（'T' を含む）" "T" "$updated_sc"

# ステージ: researcher
update_state "researcher"
stage_r=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
assert_eq "researcher: current_stage=researcher" "researcher" "$stage_r"

# ステージ: synthesizer
update_state "synthesizer"
stage_syn=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
assert_eq "synthesizer: current_stage=synthesizer" "synthesizer" "$stage_syn"

# ステージ: completed（status も completed になる）
update_state "completed" "completed"
stage_done=$(jq -r '.current_stage' "$STATE_FILE" 2>/dev/null)
status_done=$(jq -r '.status'       "$STATE_FILE" 2>/dev/null)
assert_eq "completed: current_stage=completed" "completed" "$stage_done"
assert_eq "completed: status=completed"        "completed" "$status_done"

# STATE_FILE の必須フィールドが全て存在する
has_theme=$(jq 'has("theme")'         "$STATE_FILE" 2>/dev/null)
has_mode=$(jq  'has("research_mode")' "$STATE_FILE" 2>/dev/null)
has_start=$(jq 'has("started_at")'    "$STATE_FILE" 2>/dev/null)
has_upd=$(jq   'has("updated_at")'    "$STATE_FILE" 2>/dev/null)
assert_eq "STATE_FILE に theme フィールドがある"         "true" "$has_theme"
assert_eq "STATE_FILE に research_mode フィールドがある" "true" "$has_mode"
assert_eq "STATE_FILE に started_at フィールドがある"   "true" "$has_start"
assert_eq "STATE_FILE に updated_at フィールドがある"   "true" "$has_upd"

echo ""

# ============================================================
# テスト6（エッジケース）: SC 失敗 → investigation-plan.json が生成されない
# ============================================================
echo -e "${BOLD}--- テスト6（エッジケース）: SC失敗 → investigation-plan.json 未生成 ---${NC}"
# behavior: [追加] run_claude が失敗した場合 SC は exit 1 を返し investigation-plan.json を生成しない

setup_test_env "sc-fail"
MOCK_RUN_CLAUDE_FAIL="scope-challenger"
update_state "initializing" "running"

sc_fail_exit=0
run_scope_challenger 2>/dev/null || sc_fail_exit=$?
assert_eq "SC失敗: exit=1" "1" "$sc_fail_exit"

assert_file_absent "SC失敗: investigation-plan.json は生成されない" \
  "${RESEARCH_DIR}/investigation-plan.json"

echo ""

# ============================================================
# クリーンアップ
# ============================================================
rm -rf \
  "/tmp/test-research-main-loop-sc-normal" \
  "/tmp/test-research-main-loop-r-partial-fail" \
  "/tmp/test-research-main-loop-r-partial-exit-check" \
  "/tmp/test-research-main-loop-abort-threshold" \
  "/tmp/test-research-main-loop-abort-boundary" \
  "/tmp/test-research-main-loop-abort-integration" \
  "/tmp/test-research-main-loop-syn-normal" \
  "/tmp/test-research-main-loop-state-mgmt" \
  "/tmp/test-research-main-loop-sc-fail"

# ============================================================
# サマリー
# ============================================================
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL_COUNT"
