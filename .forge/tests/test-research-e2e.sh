#!/bin/bash
# test-research-e2e.sh — research-loop.sh advisory DA フロー E2E テスト
# research-loop.sh の関数を抽出し、run_claude をモックで差替えてメインフロー相当を実行。
# DA が advisory 1 パス（+ CRITICAL 時のみ再調査最大1回）であり、
# 旧 GO/NO-GO 無限ループが存在しないことを構造的に証明する。
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

# ===== 共通ヘルパー読込（enable_err_trap / disable_err_trap を提供） =====
# source 失敗時は即座に非0 exit で死ぬ（サイレント死 / PASS 偽装の防止）。
# behavior: 依存ライブラリの source パスを一時的に壊して実行 → exit 非0 で即死（exit 0 で PASS 偽装しない）
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! source "${TESTS_DIR}/test-helpers.sh"; then
  echo "FATAL: test-helpers.sh の source に失敗しました: ${TESTS_DIR}/test-helpers.sh" >&2
  exit 1
fi

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
  cp "${SCRIPT_DIR}/.forge/templates/devils-advocate-prompt.md" "${E2E_ROOT}/.forge/templates/devils-advocate-prompt.md"

  if [ -f "${SCRIPT_DIR}/.forge/templates/criteria-generation.md" ]; then
    cp "${SCRIPT_DIR}/.forge/templates/criteria-generation.md" "${E2E_ROOT}/.forge/templates/criteria-generation.md"
  else
    echo "{{SYNTHESIS}} {{THEME}} {{RESEARCH_ID}} {{SERVER_URL}}" > "${E2E_ROOT}/.forge/templates/criteria-generation.md"
  fi

  for agent in scope-challenger researcher synthesizer devils-advocate; do
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
  # SCHEMAS_DIR: research-loop.sh の抽出関数（run_claude 呼出時に
  # "${SCHEMAS_DIR}/*.schema.json" を参照）が set -u 下で「unbound variable」となり、
  # run_e2e_flow の 2>/dev/null にマスクされてサイレント死する根本原因。実スキーマ
  # ディレクトリにバインドして bound 状態を保証する（run_claude はモックのため未読込）。
  SCHEMAS_DIR="${SCRIPT_DIR}/.forge/schemas"
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

  # advisory DA 用の初期化
  MOCK_DA_FIXTURE="da-output-clean.json"
  MOCK_DA_FIXTURE_R2=""
  DA_ROUNDS=0
  DA_CRITICAL_OPEN=0
  DA_REFOCUS_TEXT=""

  mkdir -p "$RESEARCH_DIR" "$LOG_DIR" "$NOTIFY_DIR"
  touch "$CLAUDE_CALL_LOG"

  # ERR trap を有効化: source/抽出フェーズの予期せぬ失敗を file:line 付きで stderr に可視化する。
  # behavior: 新ヘルパー関数が最低1つの修復対象テストから実際に source/呼出されている → grep で被参照が確認できる（死蔵防止）
  enable_err_trap

  # behavior: 依存ライブラリの source パスを一時的に壊して実行 → exit 非0 で即死（exit 0 で PASS 偽装しない）
  if ! source "${E2E_ROOT}/.forge/lib/common.sh"; then
    echo "FATAL: common.sh の source に失敗しました (${test_label}): ${E2E_ROOT}/.forge/lib/common.sh" >&2
    exit 1
  fi

  # awk で高速一括抽出
  local EXTRACT_FILE=$(mktemp)
  # 注: run_researchers は private helper（_run_single_researcher /
  # should_skip_perspective / _get_perspective_fail_count /
  # _set_perspective_fail_count）に依存する。これらを抽出しないと
  # 「command not found」で全 researcher が失敗し、フロー全体が失敗扱いになる
  # （サイレント死後に顕在化した 15 assertion 失敗の根本原因）。必ず併せて抽出する。
  extract_all_functions_awk "$RESEARCH_LOOP_SH" \
    load_research_config load_research_models update_state \
    rotate_errors get_recent_decisions \
    run_scope_challenger run_researchers run_synthesizer \
    _run_single_researcher should_skip_perspective \
    _get_perspective_fail_count _set_perspective_fail_count \
    run_devils_advocate_advisory _demote_unevidenced_criticals \
    _da_critical_count inject_da_findings_into_criteria \
    generate_criteria generate_final_report \
    record_decision update_research_index \
    > "$EXTRACT_FILE"

  if ! source "$EXTRACT_FILE"; then
    echo "FATAL: research-loop.sh 抽出関数の source に失敗しました (${test_label})" >&2
    rm -f "$EXTRACT_FILE"
    exit 1
  fi
  rm -f "$EXTRACT_FILE"

  # セットアップ完了。以降の E2E フローは非0 リターン経路を検証するため ERR trap を解除する。
  disable_err_trap

  load_research_config
  load_research_models

  # PARALLEL_RESEARCHERS を確実に false（順次実行）へ上書きする。
  # research.json に parallel_researchers=false を書いても load_research_config の
  # jq 式 '.parallel_researchers // true' が false を「空」とみなし true へフォールバック
  # するため、設定だけでは順次実行にならない（jq の // は null だけでなく false も空扱い）。
  # 順次実行は MSYS の並列サブシェル FD 問題を回避し、Group 7（JSON ABORT）の
  # json_fail_count 集計と "aborted" 判定をメインシェルで決定的にする。
  PARALLEL_RESEARCHERS=false

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
      *devils-advocate*)
        # 呼出しは既にログ済みのため件数は今回分を含む（round1=1, round2=2）
        local _da_call_n
        _da_call_n=$(grep -c "devils-advocate" "$CLAUDE_CALL_LOG" 2>/dev/null) || _da_call_n=0
        if [ "$_da_call_n" -ge 2 ] && [ -n "${MOCK_DA_FIXTURE_R2:-}" ]; then
          cat "${FIXTURES_DIR}/${MOCK_DA_FIXTURE_R2}" > "$target"
        else
          cat "${FIXTURES_DIR}/${MOCK_DA_FIXTURE:-da-output-clean.json}" > "$target"
        fi
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

  # ③.5 advisory DA（research-loop.sh メインループの DA ブロックと同一ロジック）
  DA_VERDICT="DIRECT"
  DA_ROUNDS=0
  DA_CRITICAL_OPEN=0
  DA_REFOCUS_TEXT=""
  if [ "${DA_ENABLED:-false}" = "true" ]; then
    run_devils_advocate_advisory 1
    DA_ROUNDS=1
    _da_file="${RESEARCH_DIR}/devils-advocate.json"
    if [ ! -s "$_da_file" ]; then
      DA_VERDICT="ADVISORY-SKIPPED"
    else
      _da_critical=$(_da_critical_count "$_da_file")
      if [ "$_da_critical" -gt 0 ] && [ "${DA_MAX_RERESEARCH:-1}" -ge 1 ]; then
        mkdir -p "${RESEARCH_DIR}/round1"
        cp "${RESEARCH_DIR}"/perspective-*.json "${RESEARCH_DIR}/synthesis.json" \
           "${RESEARCH_DIR}/round1/" 2>/dev/null || true
        rm -rf "${RESEARCH_DIR}/.perspective-fails"
        DA_REFOCUS_TEXT=$(jq -r '[.devils_advocate.findings[]?
          | select(.severity == "CRITICAL")
          | "- [\(.id)] \(.description)\n  解消条件: \(.resolution_criteria)"] | join("\n")' "$_da_file" 2>/dev/null || echo "")
        _da_feedback_for_syn=$(cat "$_da_file")
        json_fail_count=0
        if run_researchers; then
          run_synthesizer "$_da_feedback_for_syn" || {
            cp "${RESEARCH_DIR}/round1/synthesis.json" "${RESEARCH_DIR}/synthesis.json" 2>/dev/null || true
          }
        else
          cp "${RESEARCH_DIR}/round1/"*.json "${RESEARCH_DIR}/" 2>/dev/null || true
        fi
        DA_REFOCUS_TEXT=""
        run_devils_advocate_advisory 2
        DA_ROUNDS=2
        DA_CRITICAL_OPEN=$(_da_critical_count "${RESEARCH_DIR}/devils-advocate-r2.json")
        if [ "$DA_CRITICAL_OPEN" -gt 0 ]; then
          DA_VERDICT="FORCED-CONDITIONAL-GO"
        else
          DA_VERDICT="ADVISORY-GO"
        fi
      else
        DA_VERDICT="ADVISORY-GO"
      fi
    fi
  fi

  record_decision "$DA_VERDICT" || true
  generate_criteria || true
  inject_da_findings_into_criteria || true
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

# 6. devils-advocate への呼出しが 1 件（advisory 1 パス。CRITICAL なしなら再調査しない）
da_count=$(grep -c "devils-advocate" "$EXPLORE_CALL_LOG" 2>/dev/null) || da_count=0
assert_eq "DA 呼出し 1 件（advisory 1 パス）" "1" "$da_count"

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

# 15. decisions.jsonl の verdict が "ADVISORY-GO"（DA 有効・CRITICAL なし）
verdict=$(tail -1 "$EXPLORE_DECISIONS_FILE" 2>/dev/null | jq -r '.verdict // "ABSENT"' 2>/dev/null)
assert_eq "verdict=ADVISORY-GO" "ADVISORY-GO" "$verdict"

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

# ========================================================================
# Group 9: advisory DA — CRITICAL → 再調査1回 → 強制続行 (9 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 9: DA CRITICAL → 再調査1回 → 強制続行 ---${NC}"
setup_e2e_env "" "da-critical"
MOCK_DA_FIXTURE="da-output-critical.json"
MOCK_DA_FIXTURE_R2="da-output-critical.json"   # round2 でも未解消のまま

e2e_exit_dac=0
run_e2e_flow 2>/dev/null || e2e_exit_dac=$?

# 31. CRITICAL 残存でも完走する（拒否権なし = 強制続行）
assert_eq "CRITICAL 残存でも完走（exit 0）" "0" "$e2e_exit_dac"

# 32. DA 呼出しがちょうど 2 件（round1 + round2。3回目は構造的に存在しない）
da_count_c=$(grep -c "devils-advocate" "$CLAUDE_CALL_LOG" 2>/dev/null) || da_count_c=0
assert_eq "DA 呼出し 2 件（再調査は最大1回）" "2" "$da_count_c"

# 33. synthesizer エージェント呼出しが 3 件（Syn×2 + criteria×1）
syn_count_c=$(grep -c "synthesizer" "$CLAUDE_CALL_LOG" 2>/dev/null) || syn_count_c=0
assert_eq "Syn 再実行（synthesizer 呼出 3 件）" "3" "$syn_count_c"

# 34. verdict = FORCED-CONDITIONAL-GO
verdict_c=$(tail -1 "$DECISIONS_FILE" 2>/dev/null | jq -r '.verdict // "ABSENT"' 2>/dev/null)
assert_eq "verdict=FORCED-CONDITIONAL-GO" "FORCED-CONDITIONAL-GO" "$verdict_c"

# 35. decisions.jsonl に da_rounds=2 / da_critical_open>=1
da_rounds_c=$(tail -1 "$DECISIONS_FILE" 2>/dev/null | jq -r '.da_rounds // 0' 2>/dev/null)
assert_eq "da_rounds=2" "2" "$da_rounds_c"
da_open_c=$(tail -1 "$DECISIONS_FILE" 2>/dev/null | jq -r '.da_critical_open // 0' 2>/dev/null)
if [ "$da_open_c" -ge 1 ] 2>/dev/null; then
  assert_eq "da_critical_open >= 1" "open" "open"
else
  assert_eq "da_critical_open >= 1" "open" "zero"
fi

# 36. round1 成果物が退避されている
assert_eq "round1/synthesis.json 退避" "true" "$([ -f "${RESEARCH_DIR}/round1/synthesis.json" ] && echo true || echo false)"

# 37. criteria に da_risk_notes が伝搬されている
has_notes=$(jq -r 'has("da_risk_notes")' "${RESEARCH_DIR}/implementation-criteria.json" 2>/dev/null)
assert_eq "criteria に da_risk_notes 伝搬" "true" "$has_notes"

# 38. 再調査 Researcher プロンプトに重点再調査指示（DA_REFOCUS_TEXT 注入）
refocus_hit=$(grep -l "重点再調査指示" "${RESEARCH_DIR}"/perspective-*.json.prompt-log 2>/dev/null | wc -l | tr -d ' ')
if [ "$refocus_hit" -ge 1 ]; then
  assert_eq "Researcher に重点再調査指示注入" "injected" "injected"
else
  assert_eq "Researcher に重点再調査指示注入" "injected" "missing"
fi

echo ""

# ========================================================================
# Group 10: advisory DA — enabled=false で従来動作 (3 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 10: DA 無効時は従来動作（DIRECT） ---${NC}"
setup_e2e_env "" "da-disabled"
DA_ENABLED=false

e2e_exit_dad=0
run_e2e_flow 2>/dev/null || e2e_exit_dad=$?

# 39. 完走
assert_eq "DA 無効でも完走（exit 0）" "0" "$e2e_exit_dad"

# 40. DA 呼出し 0 件
da_count_d=$(grep -c "devils-advocate" "$CLAUDE_CALL_LOG" 2>/dev/null) || da_count_d=0
assert_eq "DA 無効 → 呼出し 0 件" "0" "$da_count_d"

# 41. verdict = DIRECT（従来互換）
verdict_d=$(tail -1 "$DECISIONS_FILE" 2>/dev/null | jq -r '.verdict // "ABSENT"' 2>/dev/null)
assert_eq "verdict=DIRECT（従来互換）" "DIRECT" "$verdict_d"

echo ""

# ========================================================================
# Group 11: advisory DA — パース失敗でも研究は止まらない (4 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 11: DA パース失敗 → ADVISORY-SKIPPED で続行 ---${NC}"
setup_e2e_env "" "da-parse-fail"
MOCK_VALIDATE_FAIL_STAGE="devils-advocate"

e2e_exit_dap=0
run_e2e_flow 2>/dev/null || e2e_exit_dap=$?

# 42. DA パース失敗でも完走（advisory 原則）
assert_eq "DA パース失敗でも完走（exit 0）" "0" "$e2e_exit_dap"

# 43. verdict = ADVISORY-SKIPPED
verdict_p=$(tail -1 "$DECISIONS_FILE" 2>/dev/null | jq -r '.verdict // "ABSENT"' 2>/dev/null)
assert_eq "verdict=ADVISORY-SKIPPED" "ADVISORY-SKIPPED" "$verdict_p"

# 44. json_fail_count が 0 のまま（研究の AUTO-ABORT 閾値へ非混入）
assert_eq "json_fail_count 非混入（0 のまま）" "0" "$json_fail_count"

# 45. status = completed（criteria/report まで生成）
status_p=$(jq -r '.status' "$STATE_FILE" 2>/dev/null)
assert_eq "status=completed" "completed" "$status_p"

echo ""

# ========================================================================
# Group 12: advisory DA — 証拠なし CRITICAL は降格し再調査しない (4 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 12: 証拠なし CRITICAL → HIGH 降格・再調査なし ---${NC}"
setup_e2e_env "" "da-demote"
MOCK_DA_FIXTURE="da-output-critical-no-evidence.json"

e2e_exit_dam=0
run_e2e_flow 2>/dev/null || e2e_exit_dam=$?

# 46. 完走
assert_eq "降格パスで完走（exit 0）" "0" "$e2e_exit_dam"

# 47. DA 呼出し 1 件（降格により再調査が走らない）
da_count_m=$(grep -c "devils-advocate" "$CLAUDE_CALL_LOG" 2>/dev/null) || da_count_m=0
assert_eq "証拠なし CRITICAL → 再調査なし（DA 1 件）" "1" "$da_count_m"

# 48. 出力内で severity=HIGH + demoted_from=CRITICAL
demoted_sev=$(jq -r '.devils_advocate.findings[0].severity' "${RESEARCH_DIR}/devils-advocate.json" 2>/dev/null)
assert_eq "severity が HIGH に降格" "HIGH" "$demoted_sev"
demoted_from=$(jq -r '.devils_advocate.findings[0].demoted_from // "ABSENT"' "${RESEARCH_DIR}/devils-advocate.json" 2>/dev/null)
assert_eq "demoted_from=CRITICAL 記録" "CRITICAL" "$demoted_from"

echo ""

# ===== クリーンアップ =====
rm -rf "/tmp/test-research-e2e-explore" "/tmp/test-research-e2e-validate" \
       "/tmp/test-research-e2e-sc-fail" "/tmp/test-research-e2e-syn-fail" \
       "/tmp/test-research-e2e-json-abort" "/tmp/test-research-e2e-stuck" \
       "/tmp/test-research-e2e-da-critical" "/tmp/test-research-e2e-da-disabled" \
       "/tmp/test-research-e2e-da-parse-fail" "/tmp/test-research-e2e-da-demote"

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
