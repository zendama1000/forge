#!/bin/bash
# test-research-e2e.sh — research-loop.sh リニアフロー E2E テスト (30 assertions)
# research-loop.sh の関数を抽出し、run_claude をモックで差替えてメインフロー相当を実行。
# DA ループが存在しないことを構造的に証明する。
# 使い方: bash .forge/tests/test-research-e2e.sh

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

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/.forge/tests/fixtures"
RESEARCH_LOOP_SH="${SCRIPT_DIR}/.forge/loops/research-loop.sh"

# ===== awk ベースの高速関数抽出 =====
# extract_function_v2 の while + echo | tr | wc パターンは MSYS で極端に遅いため
# awk で一括抽出する。
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

echo -e "${BOLD}===== test-research-e2e.sh — リニアフロー E2E テスト =====${NC}"
echo ""

# ===== E2E テスト環境セットアップ =====
setup_e2e_env() {
  local config_file="${1:-}"
  local test_label="${2:-default}"

  E2E_ROOT="/tmp/test-research-e2e-${test_label}"
  rm -rf "$E2E_ROOT"

  mkdir -p "${E2E_ROOT}/.forge/lib"
  mkdir -p "${E2E_ROOT}/.forge/config"
  mkdir -p "${E2E_ROOT}/.forge/state"
  mkdir -p "${E2E_ROOT}/.forge/state/notifications"
  mkdir -p "${E2E_ROOT}/.forge/templates"
  mkdir -p "${E2E_ROOT}/.forge/logs/research"
  mkdir -p "${E2E_ROOT}/.claude/agents"

  cp "${SCRIPT_DIR}/.forge/lib/common.sh" "${E2E_ROOT}/.forge/lib/common.sh"
  cp "${SCRIPT_DIR}/.forge/lib/bootstrap.sh" "${E2E_ROOT}/.forge/lib/bootstrap.sh"
  cp "${SCRIPT_DIR}/.forge/config/circuit-breaker.json" "${E2E_ROOT}/.forge/config/circuit-breaker.json"
  cp "${SCRIPT_DIR}/.forge/config/research.json" "${E2E_ROOT}/.forge/config/research.json"
  cp "${SCRIPT_DIR}/.forge/templates/scope-challenger-prompt.md" "${E2E_ROOT}/.forge/templates/scope-challenger-prompt.md"
  cp "${SCRIPT_DIR}/.forge/templates/researcher-prompt.md" "${E2E_ROOT}/.forge/templates/researcher-prompt.md"
  cp "${SCRIPT_DIR}/.forge/templates/synthesizer-prompt.md" "${E2E_ROOT}/.forge/templates/synthesizer-prompt.md"

  if [ -f "${SCRIPT_DIR}/.forge/templates/criteria-generation.md" ]; then
    cp "${SCRIPT_DIR}/.forge/templates/criteria-generation.md" "${E2E_ROOT}/.forge/templates/criteria-generation.md"
  else
    echo "{{SYNTHESIS}} {{THEME}} {{RESEARCH_ID}} {{SERVER_URL}}" > "${E2E_ROOT}/.forge/templates/criteria-generation.md"
  fi

  for agent in scope-challenger researcher synthesizer; do
    echo "${agent} agent" > "${E2E_ROOT}/.claude/agents/${agent}.md"
  done

  touch "${E2E_ROOT}/.forge/state/errors.jsonl"
  touch "${E2E_ROOT}/.forge/state/decisions.jsonl"

  # 順次実行を強制（MSYS の並列サブシェル FD 問題を回避）
  jq '.parallel_researchers = false' "${E2E_ROOT}/.forge/config/research.json" \
    > "${E2E_ROOT}/.forge/config/research.json.tmp" \
    && mv "${E2E_ROOT}/.forge/config/research.json.tmp" "${E2E_ROOT}/.forge/config/research.json"

  # グローバル変数設定
  PROJECT_ROOT="$E2E_ROOT"
  AGENTS_DIR="${E2E_ROOT}/.claude/agents"
  TEMPLATES_DIR="${E2E_ROOT}/.forge/templates"
  ERRORS_FILE="${E2E_ROOT}/.forge/state/errors.jsonl"
  CLAUDE_TIMEOUT=600
  json_fail_count=0
  RESEARCH_DIR="${E2E_ROOT}/research-output"
  STATE_FILE="${E2E_ROOT}/.forge/state/current-research.json"
  DECISIONS_FILE="${E2E_ROOT}/.forge/state/decisions.jsonl"
  LOG_DIR="${E2E_ROOT}/.forge/logs/research"
  CIRCUIT_BREAKER_CONFIG="${E2E_ROOT}/.forge/config/circuit-breaker.json"
  RESEARCH_CONFIG="${E2E_ROOT}/.forge/config/research.json"
  THEME="テストテーマ"
  DIRECTION="テスト方向性"
  TOPIC_HASH="abc123"
  DATE="2026-02-26"
  START_TS="20260226-120000"
  METRICS_FILE="${E2E_ROOT}/.forge/state/metrics.jsonl"
  VALIDATION_STATS_FILE="${E2E_ROOT}/.forge/state/validation-stats.jsonl"
  PROGRESS_FILE="${E2E_ROOT}/.forge/state/progress.json"
  NOTIFY_DIR="${E2E_ROOT}/.forge/state/notifications"
  CLAUDE_CALL_LOG="${E2E_ROOT}/claude-calls.log"
  MAX_DECISIONS_IN_PROMPT=30

  # 失敗注入変数の初期化
  MOCK_FAIL_STAGE=""
  MOCK_VALIDATE_FAIL_STAGE=""

  mkdir -p "$RESEARCH_DIR" "$LOG_DIR" "$NOTIFY_DIR"
  touch "$CLAUDE_CALL_LOG"

  source "${E2E_ROOT}/.forge/lib/common.sh"

  # awk で高速一括抽出
  local EXTRACT_FILE=$(mktemp)
  extract_all_functions_awk "$RESEARCH_LOOP_SH" \
    load_research_config load_research_models update_state \
    rotate_errors get_recent_decisions \
    run_scope_challenger run_researchers run_synthesizer \
    generate_criteria generate_final_report \
    record_decision update_research_index \
    > "$EXTRACT_FILE"

  source "$EXTRACT_FILE"
  rm -f "$EXTRACT_FILE"

  load_research_config
  load_research_models

  # Research Config パース
  RESEARCH_MODE="explore"
  LOCKED_DECISIONS_TEXT="（なし）"
  OPEN_QUESTIONS_TEXT="（なし）"
  if [ -n "$config_file" ] && [ -f "$config_file" ]; then
    RESEARCH_MODE=$(jq_safe -r '.mode // "explore"' "$config_file")
    LOCKED_DECISIONS_TEXT=$(jq_safe -r '
      .locked_decisions // [] |
      map("- \(.decision) (理由: \(.reason))") | join("\n")
    ' "$config_file")
    OPEN_QUESTIONS_TEXT=$(jq_safe -r '
      .open_questions // [] |
      map("- \(.)") | join("\n")
    ' "$config_file")
    [ -z "$LOCKED_DECISIONS_TEXT" ] && LOCKED_DECISIONS_TEXT="（なし）"
    [ -z "$OPEN_QUESTIONS_TEXT" ] && OPEN_QUESTIONS_TEXT="（なし）"
  fi

  # run_claude モック: .pending に書出し（実コード準拠）+ prompt ログ
  # generate_final_report は validate_json を呼ばないため、agent="" の場合は直接書出し
  run_claude() {
    local model="$1" agent="$2" prompt="$3" output="$4"
    local log_file="${5:-}" disallowed="${6:-}" stage_timeout="${7:-}"
    echo "$(date +%s)|${model}|${agent}|${output}" >> "$CLAUDE_CALL_LOG"

    # 失敗注入: MOCK_FAIL_STAGE にマッチしたら失敗
    if [ -n "$MOCK_FAIL_STAGE" ] && echo "$agent" | grep -q "$MOCK_FAIL_STAGE"; then
      return 1
    fi

    # agent が空の場合（final report）は .pending ではなく直接出力
    local target="${output}.pending"
    [ -z "$agent" ] && target="$output"

    case "$agent" in
      *scope-challenger*)
        cat "${FIXTURES_DIR}/sc-output.json" > "$target"
        ;;
      *researcher*)
        cat "${FIXTURES_DIR}/researcher-output.json" > "$target"
        ;;
      *synthesizer*)
        if echo "$output" | grep -q "criteria"; then
          cat "${FIXTURES_DIR}/criteria-output.json" > "$target"
        elif echo "$output" | grep -q "synthesis"; then
          cat "${FIXTURES_DIR}/synthesis-output.json" > "$target"
        else
          echo "# テストレポート" > "$target"
        fi
        ;;
      *)
        echo "# レポート" > "$target"
        ;;
    esac

    echo "$prompt" > "${output}.prompt-log"
    return 0
  }

  # validate_json モック: .pending → 本ファイル昇格（失敗注入対応）
  validate_json() {
    local final_path="$1"
    local stage="$2"

    # 失敗注入: ステージ名マッチで失敗 + json_fail_count インクリメント
    if [ -n "$MOCK_VALIDATE_FAIL_STAGE" ] && echo "$stage" | grep -q "$MOCK_VALIDATE_FAIL_STAGE"; then
      json_fail_count=$((json_fail_count + 1))
      [ -f "${final_path}.pending" ] && mv "${final_path}.pending" "${final_path}.failed"
      return 1
    fi

    if [ -f "${final_path}.pending" ]; then
      mv "${final_path}.pending" "$final_path"
    fi
    return 0
  }

  # スタブ
  update_research_index() { :; }
  get_server_url() { echo "http://localhost:3000"; }
}

# ===== E2E フロー実行 =====
# research-loop.sh L625-669 に忠実なメインフロー
run_e2e_flow() {
  update_state "initializing" "running"
  rotate_errors

  run_scope_challenger || {
    update_state "scope-challenger" "failed"
    return 1
  }

  json_fail_count=0
  run_researchers || {
    update_state "researcher" "failed"
    return 1
  }

  # ABORT 閾値チェック（research-loop.sh L647-652 相当）
  if [ "$json_fail_count" -ge "$MAX_JSON_FAILS_PER_LOOP" ]; then
    record_error "loop-control" "自動ABORT: JSON検証失敗${json_fail_count}件"
    update_state "aborted" "auto-abort-json-failures"
    return 1
  fi

  run_synthesizer || {
    update_state "synthesizer" "failed"
    return 1
  }

  record_decision || true
  generate_criteria || true
  generate_final_report || true
  update_state "completed" "completed"
  return 0
}

# ========================================================================
# テストA: explore モード（config なし）
# ========================================================================
echo -e "${BOLD}===== テストA: explore モード（config なし） =====${NC}"

setup_e2e_env "" "explore"
EXPLORE_ROOT="$E2E_ROOT"
EXPLORE_RESEARCH_DIR="$RESEARCH_DIR"
EXPLORE_STATE_FILE="$STATE_FILE"
EXPLORE_DECISIONS_FILE="$DECISIONS_FILE"
EXPLORE_CALL_LOG="$CLAUDE_CALL_LOG"
e2e_exit=0
run_e2e_flow 2>/dev/null || e2e_exit=$?

# ========================================================================
# Group 1: リニアフロー構造 (6 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 1: リニアフロー構造 ---${NC}"

# 1. 実行完了（exit 0）
assert_eq "実行完了（exit 0）" "0" "$e2e_exit"

# 2. claude-calls.log のエントリ数確認
call_count=$(wc -l < "$EXPLORE_CALL_LOG" 2>/dev/null | tr -d ' ')
if [ "$call_count" -ge 6 ]; then
  assert_eq "claude-calls 件数 >= 6" "sufficient" "sufficient"
else
  assert_eq "claude-calls 件数 >= 6" "sufficient" "only_${call_count}"
fi

# 3. scope-challenger 呼出しが最初
first_call=$(head -1 "$EXPLORE_CALL_LOG" 2>/dev/null)
assert_contains "最初の呼出しが SC" "scope-challenger" "$first_call"

# 4. researcher 呼出しが SC の後
rest_calls=$(tail -n +2 "$EXPLORE_CALL_LOG" 2>/dev/null)
assert_contains "SC 後に researcher" "researcher" "$rest_calls"

# 5. synthesizer 呼出しが researcher の後
last_researcher_line=$(grep -n "researcher" "$EXPLORE_CALL_LOG" | tail -1 | cut -d: -f1)
first_synth_line=$(grep -n "synthesizer" "$EXPLORE_CALL_LOG" | head -1 | cut -d: -f1)
if [ -n "$last_researcher_line" ] && [ -n "$first_synth_line" ] && [ "$first_synth_line" -gt "$last_researcher_line" ]; then
  assert_eq "Syn が R の後" "ordered" "ordered"
else
  assert_eq "Syn が R の後" "ordered" "unordered(R=${last_researcher_line:-?},S=${first_synth_line:-?})"
fi

# 6. devils-advocate への呼出しが 0 件
da_count=$(grep -c "devils-advocate" "$EXPLORE_CALL_LOG" 2>/dev/null) || da_count=0
assert_eq "DA 呼出し 0 件" "0" "$da_count"

echo ""

# ========================================================================
# Group 2: 出力ファイル検証 (5 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 2: 出力ファイル検証 ---${NC}"

# 7. investigation-plan.json が生成される
assert_eq "investigation-plan.json 生成" "true" "$([ -f "${EXPLORE_RESEARCH_DIR}/investigation-plan.json" ] && echo true || echo false)"

# 8. perspective-*.json が生成される（1件以上）
perspective_count=$(ls "${EXPLORE_RESEARCH_DIR}"/perspective-*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$perspective_count" -ge 1 ]; then
  assert_eq "perspective-*.json >= 1" "exists" "exists"
else
  assert_eq "perspective-*.json >= 1" "exists" "none"
fi

# 9. synthesis.json が生成される
assert_eq "synthesis.json 生成" "true" "$([ -f "${EXPLORE_RESEARCH_DIR}/synthesis.json" ] && echo true || echo false)"

# 10. implementation-criteria.json が生成される
assert_eq "implementation-criteria.json 生成" "true" "$([ -f "${EXPLORE_RESEARCH_DIR}/implementation-criteria.json" ] && echo true || echo false)"

# 11. final-report.md が生成される
assert_eq "final-report.md 生成" "true" "$([ -f "${EXPLORE_RESEARCH_DIR}/final-report.md" ] && echo true || echo false)"

echo ""

# ========================================================================
# Group 3: 状態管理 (4 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 3: 状態管理 ---${NC}"

# 12. current-research.json の status が "completed"
state_status=$(jq -r '.status' "$EXPLORE_STATE_FILE" 2>/dev/null)
assert_eq "status=completed" "completed" "$state_status"

# 13. current-research.json に research_mode フィールドがある
has_mode=$(jq -r 'has("research_mode")' "$EXPLORE_STATE_FILE" 2>/dev/null)
assert_eq "research_mode フィールド存在" "true" "$has_mode"

# 14. decisions.jsonl にエントリが追記される
decision_count=$(wc -l < "$EXPLORE_DECISIONS_FILE" 2>/dev/null | tr -d ' ')
if [ "$decision_count" -ge 1 ]; then
  assert_eq "decisions.jsonl にエントリ" "exists" "exists"
else
  assert_eq "decisions.jsonl にエントリ" "exists" "empty"
fi

# 15. decisions.jsonl の verdict が "DIRECT"
verdict=$(tail -1 "$EXPLORE_DECISIONS_FILE" 2>/dev/null | jq -r '.verdict // "ABSENT"' 2>/dev/null)
assert_eq "verdict=DIRECT" "DIRECT" "$verdict"

echo ""

# ========================================================================
# Group 4: Research Config 連携 (5 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 4: Research Config 連携 ---${NC}"

# 16. config なし → RESEARCH_MODE=explore で完走
state_mode=$(jq -r '.research_mode' "$EXPLORE_STATE_FILE" 2>/dev/null)
assert_eq "config なし → mode=explore" "explore" "$state_mode"

# explore モードの SC プロンプトログを保存
EXPLORE_SC_PROMPT_LOG="${EXPLORE_RESEARCH_DIR}/investigation-plan.json.prompt-log"

# テストB: validate モード
echo -e "${BOLD}--- テストB: validate モード ---${NC}"
setup_e2e_env "${FIXTURES_DIR}/research-config-validate.json" "validate"
e2e_exit_v=0
run_e2e_flow 2>/dev/null || e2e_exit_v=$?

# 17. validate config を渡す → 完走
assert_eq "validate モードで完走" "0" "$e2e_exit_v"

# 18. validate モード → SC プロンプトに locked decisions テキストが含まれる
SC_PROMPT_LOG="${RESEARCH_DIR}/investigation-plan.json.prompt-log"
if [ -f "$SC_PROMPT_LOG" ]; then
  sc_prompt=$(cat "$SC_PROMPT_LOG")
  assert_contains "validate: SC に locked decisions" "Alpine.js" "$sc_prompt"
else
  assert_eq "validate: SC prompt-log 存在" "exists" "missing"
fi

# 19. validate モード → Syn プロンプトに locked decisions テキストが含まれる
SYN_PROMPT_LOG="${RESEARCH_DIR}/synthesis.json.prompt-log"
if [ -f "$SYN_PROMPT_LOG" ]; then
  syn_prompt=$(cat "$SYN_PROMPT_LOG")
  assert_contains "validate: Syn に locked decisions" "Alpine.js" "$syn_prompt"
else
  assert_eq "validate: Syn prompt-log 存在" "exists" "missing"
fi

# 20. explore モード → SC プロンプトに "（なし）" が含まれる
if [ -f "$EXPLORE_SC_PROMPT_LOG" ]; then
  sc_prompt_e=$(cat "$EXPLORE_SC_PROMPT_LOG")
  assert_contains "explore: SC に（なし）" "（なし）" "$sc_prompt_e"
else
  assert_eq "explore: SC prompt-log 存在" "exists" "missing"
fi

echo ""

# ========================================================================
# Group 5: SC 失敗パス (3 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 5: SC 失敗パス ---${NC}"
setup_e2e_env "" "sc-fail"
MOCK_FAIL_STAGE="scope-challenger"

e2e_exit_sc=0
run_e2e_flow 2>/dev/null || e2e_exit_sc=$?

# 21. SC 失敗 → exit ≠ 0
assert_eq "SC 失敗 → exit ≠ 0" "1" "$e2e_exit_sc"

# 22. STATE_FILE status = "failed"
sc_fail_status=$(jq -r '.status' "$STATE_FILE" 2>/dev/null)
assert_eq "SC 失敗 → status=failed" "failed" "$sc_fail_status"

# 23. researcher 呼出し 0 件（SC で停止）
researcher_count=$(grep -c "researcher" "$CLAUDE_CALL_LOG" 2>/dev/null) || researcher_count=0
assert_eq "SC 失敗 → researcher 未呼出" "0" "$researcher_count"

echo ""

# ========================================================================
# Group 6: Syn 失敗パス (2 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 6: Syn 失敗パス ---${NC}"
setup_e2e_env "" "syn-fail"
MOCK_FAIL_STAGE="synthesizer"

e2e_exit_syn=0
run_e2e_flow 2>/dev/null || e2e_exit_syn=$?

# 24. Syn 失敗 → exit ≠ 0
assert_eq "Syn 失敗 → exit ≠ 0" "1" "$e2e_exit_syn"

# 25. STATE_FILE status = "failed"
syn_fail_status=$(jq -r '.status' "$STATE_FILE" 2>/dev/null)
assert_eq "Syn 失敗 → status=failed" "failed" "$syn_fail_status"

echo ""

# ========================================================================
# Group 7: JSON ABORT 閾値 (3 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 7: JSON ABORT 閾値 ---${NC}"
setup_e2e_env "" "json-abort"
MOCK_VALIDATE_FAIL_STAGE="researcher"

e2e_exit_abort=0
run_e2e_flow 2>/dev/null || e2e_exit_abort=$?

# 26. JSON ABORT → exit ≠ 0
assert_eq "JSON ABORT → exit ≠ 0" "1" "$e2e_exit_abort"

# 27. STATE_FILE に "abort" を含む status
abort_status=$(jq -r '.status' "$STATE_FILE" 2>/dev/null)
assert_contains "JSON ABORT → status に abort" "abort" "$abort_status"

# 28. synthesizer 呼出し 0 件（ABORT で停止）
syn_after_abort=$(grep -c "synthesizer" "$CLAUDE_CALL_LOG" 2>/dev/null) || syn_after_abort=0
assert_eq "JSON ABORT → synthesizer 未呼出" "0" "$syn_after_abort"

echo ""

# ========================================================================
# Group 8: Stuck State 回復 (2 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 8: Stuck State 回復 ---${NC}"
setup_e2e_env "" "stuck"

# 事前に status=running の STATE_FILE を作成（前回クラッシュを模擬）
jq -n '{"status":"running","theme":"前回テーマ","updated_at":"2026-02-25T12:00:00+09:00"}' \
  > "$STATE_FILE"

# stuck state 検出ロジック（research-loop.sh L614-623 相当）
_prev_status=$(jq_safe -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
if [ "$_prev_status" = "running" ]; then
  jq --arg ts "$(date -Iseconds)" \
    '.status = "interrupted" | .updated_at = $ts' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

# 29. stuck state → interrupted に更新
stuck_status=$(jq -r '.status' "$STATE_FILE" 2>/dev/null)
assert_eq "stuck state → interrupted" "interrupted" "$stuck_status"

# 30. interrupted 後に通常フローが完走
e2e_exit_stuck=0
run_e2e_flow 2>/dev/null || e2e_exit_stuck=$?
assert_eq "stuck 回復後 → 完走" "0" "$e2e_exit_stuck"

echo ""

# ===== クリーンアップ =====
rm -rf "/tmp/test-research-e2e-explore" "/tmp/test-research-e2e-validate" \
       "/tmp/test-research-e2e-sc-fail" "/tmp/test-research-e2e-syn-fail" \
       "/tmp/test-research-e2e-json-abort" "/tmp/test-research-e2e-stuck"

# ========================================================================
# サマリー
# ========================================================================
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED: ${PASS_COUNT}/${TOTAL}${NC}"
else
  echo -e "${RED}${BOLD}FAILED: ${FAIL_COUNT}/${TOTAL}${NC}"
fi
echo -e "==========================================${NC}"

exit "$FAIL_COUNT"
