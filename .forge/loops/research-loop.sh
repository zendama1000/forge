#!/bin/bash
# research-loop.sh v2.0 - Forge Research Harness オーケストレーター
# 使い方: ./research-loop.sh "テーマ" ["方向性"] [--research-config <file>] [--dry-run-sample]
#
# v2.0変更点: DA削除、リニアフロー化（SC→R→Syn→criteria→report）、research-config対応。
# v3.3変更点: advisory DA 復活（SC→R→Syn→DA[advisory]→criteria→report）。
#   DA に拒否権はなく、CRITICAL（証拠つき反証）時のみ再調査を最大1回。判定はハーネスが導出。
# 設計書: forge-architecture-v3.2.md
# Ralph原則: 各ステージは独立セッション。完全コンテキストリセット。状態はファイル経由。

set -euo pipefail

# ===== 異常終了時クリーンアップ（B2: stuck state 防止） =====
_cleanup_on_exit() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ -f "${STATE_FILE:-}" ]; then
    local current_status
    current_status=$(jq_safe -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
    if [ "$current_status" = "running" ]; then
      jq --arg ts "$(date -Iseconds)" \
        '.status = "interrupted" | .updated_at = $ts | .exit_code = '"$exit_code" \
        "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ 異常終了検出（exit=$exit_code）— current-research.json を interrupted に更新" >&2
    fi
  fi
}
trap _cleanup_on_exit EXIT

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"
source "${PROJECT_ROOT}/.forge/lib/probe-env.sh"

# ===== コマンド依存チェック =====
check_dependencies claude jq md5sum timeout

# ===== パス定数 =====
AGENTS_DIR=".claude/agents"
TEMPLATES_DIR=".forge/templates"
SCHEMAS_DIR=".forge/schemas"

# ===== エージェント・テンプレート存在チェック =====
for agent in scope-challenger researcher synthesizer; do
  if [ ! -f "${AGENTS_DIR}/${agent}.md" ]; then
    echo -e "${RED}[ERROR] エージェント定義が見つかりません: ${AGENTS_DIR}/${agent}.md${NC}" >&2
    exit 1
  fi
done
for tmpl in scope-challenger-prompt researcher-prompt synthesizer-prompt; do
  if [ ! -f "${TEMPLATES_DIR}/${tmpl}.md" ]; then
    echo -e "${RED}[ERROR] テンプレートが見つかりません: ${TEMPLATES_DIR}/${tmpl}.md${NC}" >&2
    exit 1
  fi
done

# ===== --dry-run-sample モード =====
# プロンプト再チューニング検証 + スキーマ適合サンプル出力（Claude 呼び出しなし・状態ファイル無変更）
# 検証内容:
#   1. reasoning_extraction 誘発記述がテンプレート/エージェント定義に存在しないこと
#   2. 安全ゲート強指示（指定ファイル外変更禁止・保護パターン等）が温存されていること
#   3. locked_decisions 由来の非交渉制約がテンプレートに残存していること
#   4. テンプレートがプレースホルダ残存なくレンダリングできること
#   5. researcher / synthesizer スキーマに適合するサンプル出力を生成できること
_dry_run_scan() {
  # $1=pattern, $2...=paths。マッチ行を出力（マッチなしでも exit 0）
  local pattern="$1"; shift
  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$@" 2>/dev/null || true
  else
    grep -RInE "$pattern" "$@" 2>/dev/null || true
  fi
}

run_dry_run_sample() {
  local fail=0
  echo "=== research-loop dry-run-sample（プロンプト再チューニング検証）==="

  # --- 1. reasoning_extraction 誘発記述: 0件であること ---
  local induce_hits
  induce_hits=$(_dry_run_scan 'thinking_mode|思考過程をログ|推論を説明' "$TEMPLATES_DIR" "$AGENTS_DIR")
  if [ -n "$induce_hits" ]; then
    echo "✗ reasoning_extraction 誘発記述を検出（除去が必要）:" >&2
    echo "$induce_hits" >&2
    fail=1
  else
    echo "✓ reasoning_extraction 誘発記述: 0件（refusal 誘発リスクなし）"
  fi

  # --- 2. 安全ゲート強指示: 1件以上残存していること（誤削除防止） ---
  local safety_hits safety_count
  safety_hits=$(_dry_run_scan '変更禁止|変更してはならない|保護パターン' "$TEMPLATES_DIR" "$AGENTS_DIR")
  safety_count=$(printf '%s' "$safety_hits" | grep -c . || true)
  if [ "${safety_count:-0}" -ge 1 ]; then
    echo "✓ 安全ゲート強指示: ${safety_count}件 残存（指定ファイル外変更の自律抑制・保護ファイル等）"
    echo "$safety_hits" | head -5 | sed 's/^/    /'
  else
    echo "✗ 安全ゲート強指示が検出されません（過剰削除の疑い）" >&2
    fail=1
  fi

  # --- 3. locked_decisions 非交渉制約: テンプレートに残存していること ---
  local locked_hits
  locked_hits=$(_dry_run_scan 'ロックされた決定事項|LOCKED_DECISIONS' "$TEMPLATES_DIR")
  if [ -n "$locked_hits" ]; then
    echo "✓ locked_decisions 制約: テンプレートに残存"
  else
    echo "✗ locked_decisions 制約がテンプレートから消失（過剰削除）" >&2
    fail=1
  fi

  # --- 4. テンプレートレンダリング検証（synthesizer） ---
  local rendered
  rendered=$(render_template "${TEMPLATES_DIR}/synthesizer-prompt.md" \
    "INVESTIGATION_PLAN" "（dry-run サンプル調査計画）" \
    "ALL_REPORTS"        "（dry-run サンプルレポート）" \
    "DECISIONS"          "（なし）" \
    "RESEARCH_MODE"      "explore" \
    "LOCKED_DECISIONS"   "（なし）" \
    "DA_FEEDBACK"        "（なし）")
  if printf '%s' "$rendered" | grep -q '{{'; then
    echo "✗ synthesizer-prompt.md に未解決プレースホルダが残存" >&2
    fail=1
  else
    echo "✓ synthesizer-prompt.md レンダリング: プレースホルダ全解決"
  fi

  # --- 5. スキーマ適合サンプル出力（researcher / synthesizer） ---
  local researcher_sample synthesizer_sample
  researcher_sample=$(cat <<'EOF_RESEARCHER'
{
  "perspective_report": {
    "perspective_id": "technical",
    "focus": "dry-run サンプル: 技術的実現可能性の検証",
    "findings": [
      {
        "question": "researcher スキーマに適合する出力を生成できるか",
        "answer": "必須フィールド（perspective_id/focus/findings/summary/gaps）を全て満たす出力を生成できる",
        "evidence": ["dry-run-sample モードによる機械生成サンプル"],
        "confidence": "high",
        "caveats": ["実際の Claude 呼び出しは行っていない"]
      }
    ],
    "summary": "dry-run サンプルレポート（スキーマ適合検証用）",
    "gaps": []
  }
}
EOF_RESEARCHER
)
  synthesizer_sample=$(cat <<'EOF_SYNTHESIZER'
{
  "synthesis": {
    "theme": "dry-run サンプル: プロンプト再チューニング後のスキーマ適合検証",
    "integrated_findings": "再チューニング後のテンプレート/エージェント定義は reasoning_extraction 誘発記述を含まず、安全ゲート強指示と locked_decisions 制約を温存している",
    "contradictions": [],
    "past_decision_alignment": {
      "aligned": ["安全ゲート強指示の温存"],
      "conflicts": []
    },
    "recommendations": {
      "primary": {
        "action": "再チューニング済みプロンプトで運用を継続する",
        "rationale": "誘発記述0件・安全ゲート残存を機械検証済み",
        "risks": ["新規テンプレート追加時に誘発記述が再混入する可能性"]
      },
      "fallback": {
        "action": "誘発記述が再検出された場合は該当箇所のみ除去する",
        "rationale": "全文書き換えは安全ゲート強指示の誤削除リスクがある",
        "trigger": "dry-run-sample の検証 1 が失敗した場合"
      },
      "abort": {
        "rationale": "検証の大半が失敗する場合は再チューニング自体を差し戻す",
        "opportunity_cost": "リサーチループの出力品質改善が遅延する"
      }
    }
  }
}
EOF_SYNTHESIZER
)

  if printf '%s' "$researcher_sample" | jq -e '
      .perspective_report |
      (.perspective_id | type == "string") and
      (.focus | type == "string") and
      (.findings | type == "array" and length >= 1) and
      (.findings[0] | has("question") and has("answer") and has("evidence")
        and (.confidence | IN("high", "medium", "low"))) and
      (.summary | type == "string") and
      (.gaps | type == "array")
    ' >/dev/null 2>&1; then
    echo "✓ researcher サンプル: スキーマ必須フィールド適合"
  else
    echo "✗ researcher サンプルがスキーマに不適合" >&2
    fail=1
  fi

  if printf '%s' "$synthesizer_sample" | jq -e '
      .synthesis |
      (.theme | type == "string") and
      (.integrated_findings | type == "string") and
      (.contradictions | type == "array") and
      (.recommendations.primary | has("action") and has("rationale") and has("risks")) and
      (.recommendations.fallback | has("action") and has("rationale") and has("trigger")) and
      (.recommendations.abort | has("rationale") and has("opportunity_cost"))
    ' >/dev/null 2>&1; then
    echo "✓ synthesizer サンプル: スキーマ必須フィールド適合"
  else
    echo "✗ synthesizer サンプルがスキーマに不適合" >&2
    fail=1
  fi

  echo ""
  echo "--- researcher サンプル出力 ---"
  printf '%s\n' "$researcher_sample"
  echo "--- synthesizer サンプル出力 ---"
  printf '%s\n' "$synthesizer_sample"

  echo ""
  if [ "$fail" -eq 0 ]; then
    echo "=== dry-run-sample: 全検証 PASS ==="
  else
    echo "=== dry-run-sample: 検証 FAIL あり ===" >&2
  fi
  return "$fail"
}

# ===== 引数チェック =====
_RESEARCH_CONFIG_FILE=""
_DRY_RUN_SAMPLE=false
_positional_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --research-config=*) _RESEARCH_CONFIG_FILE="${1#*=}"; shift ;;
    --research-config)   _RESEARCH_CONFIG_FILE="$2"; shift 2 ;;
    --dry-run-sample)    _DRY_RUN_SAMPLE=true; shift ;;
    *)                   _positional_args+=("$1"); shift ;;
  esac
done
set -- "${_positional_args[@]}"

if [ "$_DRY_RUN_SAMPLE" = true ]; then
  run_dry_run_sample
  exit $?
fi

if [ $# -lt 1 ]; then
  echo "使い方: $0 \"テーマ\" [\"方向性\"] [--research-config <file>] [--dry-run-sample]" >&2
  exit 1
fi

THEME="$1"
DIRECTION="${2:-}"

# Research Config 読み込み（Phase 0 で生成、locked/open の分類）
RESEARCH_MODE="explore"
LOCKED_DECISIONS_TEXT="（なし）"
OPEN_QUESTIONS_TEXT="（なし）"
if [ -n "$_RESEARCH_CONFIG_FILE" ] && [ -f "$_RESEARCH_CONFIG_FILE" ]; then
  RESEARCH_MODE=$(jq_safe -r '.mode // "explore"' "$_RESEARCH_CONFIG_FILE")
  LOCKED_DECISIONS_TEXT=$(jq_safe -r '
    .locked_decisions // [] |
    map("- \(.decision) (理由: \(.reason))") | join("\n")
  ' "$_RESEARCH_CONFIG_FILE")
  OPEN_QUESTIONS_TEXT=$(jq_safe -r '
    .open_questions // [] |
    map("- \(.)") | join("\n")
  ' "$_RESEARCH_CONFIG_FILE")
  [ -z "$LOCKED_DECISIONS_TEXT" ] && LOCKED_DECISIONS_TEXT="（なし）"
  [ -z "$OPEN_QUESTIONS_TEXT" ] && OPEN_QUESTIONS_TEXT="（なし）"
  log "Research Config: mode=${RESEARCH_MODE}, locked=${LOCKED_DECISIONS_TEXT:0:50}..."
fi

TOPIC_HASH=$(echo "$THEME" | md5sum | cut -c1-6)
DATE=$(date +%Y-%m-%d)
START_TS=$(date +%Y%m%d-%H%M%S)
RESEARCH_DIR=".docs/research/${DATE}-${TOPIC_HASH}-${START_TS##*-}"
STATE_FILE=".forge/state/current-research.json"
DECISIONS_FILE=".forge/state/decisions.jsonl"
ERRORS_FILE=".forge/state/errors.jsonl"
LOG_DIR=".forge/logs/research"
HEARTBEAT_FILE=".forge/state/heartbeat.json"
_RESEARCH_START_EPOCH=$(date +%s)

# ===== 設定読み込み（circuit-breaker.json からフォールバック付き） =====
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"

load_research_config() {
  if [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
    MAX_JSON_FAILS_PER_LOOP=$(jq_safe -r '.research_limits.max_json_fails_per_loop // 3' "$CIRCUIT_BREAKER_CONFIG")
    CLAUDE_TIMEOUT=$(jq_safe -r '.research_limits.claude_timeout_sec // 600' "$CIRCUIT_BREAKER_CONFIG")
    MAX_DECISIONS_IN_PROMPT=$(jq_safe -r '.research_limits.max_decisions_in_prompt // 30' "$CIRCUIT_BREAKER_CONFIG")
    PARALLEL_ALL_FAIL_COOLDOWN_SEC=$(jq_safe -r '.research_limits.parallel_all_fail_cooldown_sec // 30' "$CIRCUIT_BREAKER_CONFIG")
    PERSPECTIVE_MAX_CONSECUTIVE_FAILS=$(jq_safe -r '.research_limits.perspective_max_consecutive_fails // 3' "$CIRCUIT_BREAKER_CONFIG")
  else
    log "⚠ circuit-breaker.json が見つかりません。デフォルト値を使用"
    MAX_JSON_FAILS_PER_LOOP=3
    CLAUDE_TIMEOUT=600
    MAX_DECISIONS_IN_PROMPT=30
    PARALLEL_ALL_FAIL_COOLDOWN_SEC=30
    PERSPECTIVE_MAX_CONSECUTIVE_FAILS=3
  fi
}

# G3: research.json からモデル・ツール・タイムアウト設定を読み込む
RESEARCH_CONFIG="${PROJECT_ROOT}/.forge/config/research.json"

load_research_models() {
  if [ -f "$RESEARCH_CONFIG" ]; then
    MODEL_SC=$(jq_safe -r '.models.scope_challenger // "opus"' "$RESEARCH_CONFIG")
    MODEL_RESEARCHER=$(jq_safe -r '.models.researcher // "sonnet"' "$RESEARCH_CONFIG")
    MODEL_SYNTHESIZER=$(jq_safe -r '.models.synthesizer // "opus"' "$RESEARCH_CONFIG")
    MODEL_CRITERIA=$(jq_safe -r '.models.criteria_generation // "opus"' "$RESEARCH_CONFIG")
    MODEL_REPORT=$(jq_safe -r '.models.final_report // "opus"' "$RESEARCH_CONFIG")

    TOOLS_SC=$(jq_safe -r '.disallowed_tools.scope_challenger // "WebSearch WebFetch"' "$RESEARCH_CONFIG")
    TOOLS_RESEARCHER=$(jq_safe -r '.disallowed_tools.researcher // ""' "$RESEARCH_CONFIG")
    TOOLS_SYNTHESIZER=$(jq_safe -r '.disallowed_tools.synthesizer // "WebSearch WebFetch"' "$RESEARCH_CONFIG")

    TIMEOUT_SC=$(jq_safe -r '.timeouts.scope_challenger_sec // 300' "$RESEARCH_CONFIG")
    TIMEOUT_RESEARCHER=$(jq_safe -r '.timeouts.researcher_sec // 600' "$RESEARCH_CONFIG")
    TIMEOUT_SYNTHESIZER=$(jq_safe -r '.timeouts.synthesizer_sec // 600' "$RESEARCH_CONFIG")
    TIMEOUT_CRITERIA=$(jq_safe -r '.timeouts.criteria_generation_sec // 900' "$RESEARCH_CONFIG")
    # batch#11 R19a: 最終レポートは従来 timeout 未指定（CLAUDE_TIMEOUT 既定 600 秒）で、
    # 全 perspective を読む 80 分級リサーチでは途中 kill されていた
    TIMEOUT_REPORT=$(jq_safe -r '.timeouts.final_report_sec // 1200' "$RESEARCH_CONFIG")

    PARALLEL_RESEARCHERS=$(cfg_bool "$RESEARCH_CONFIG" '.parallel_researchers' true)

    # Devil's Advocate（advisory）
    MODEL_DA=$(jq_safe -r '.models.devils_advocate // "opus"' "$RESEARCH_CONFIG")
    TOOLS_DA=$(jq_safe -r '.disallowed_tools.devils_advocate // "WebSearch WebFetch"' "$RESEARCH_CONFIG")
    TIMEOUT_DA=$(jq_safe -r '.timeouts.devils_advocate_sec // 600' "$RESEARCH_CONFIG")
    # 注意: `// true` は false を true に化けさせるため `!= false` 形式で読む
    DA_ENABLED=$(jq_safe -r '.devils_advocate.enabled != false' "$RESEARCH_CONFIG")
    DA_MAX_RERESEARCH=$(jq_safe -r '.devils_advocate.max_reresearch_rounds // 1' "$RESEARCH_CONFIG")
  else
    log "⚠ research.json が見つかりません。デフォルト値を使用"
    MODEL_SC="opus"; MODEL_RESEARCHER="sonnet"; MODEL_SYNTHESIZER="opus"
    MODEL_CRITERIA="opus"; MODEL_REPORT="opus"
    TOOLS_SC="WebSearch WebFetch"; TOOLS_RESEARCHER=""
    TOOLS_SYNTHESIZER="WebSearch WebFetch"
    TIMEOUT_SC=300; TIMEOUT_RESEARCHER=600; TIMEOUT_SYNTHESIZER=600; TIMEOUT_CRITERIA=900
    TIMEOUT_REPORT=1200
    PARALLEL_RESEARCHERS=true
    MODEL_DA="opus"; TOOLS_DA="WebSearch WebFetch"; TIMEOUT_DA=600
    DA_ENABLED=true; DA_MAX_RERESEARCH=1
  fi
}

load_research_config
load_research_models

# ===== 設定スキーマ検証（起動時） =====
_RL_SCHEMAS_DIR="${PROJECT_ROOT}/.forge/schemas"
if ! validate_config "${CIRCUIT_BREAKER_CONFIG}" "${_RL_SCHEMAS_DIR}/circuit-breaker.schema.json"; then
  echo -e "${RED}[ERROR] circuit-breaker.json スキーマ検証失敗${NC}" >&2
  exit 1
fi
if ! validate_config "${RESEARCH_CONFIG}" "${_RL_SCHEMAS_DIR}/research.schema.json"; then
  echo -e "${RED}[ERROR] research.json スキーマ検証失敗${NC}" >&2
  exit 1
fi
unset _RL_SCHEMAS_DIR

# ループ制御カウンタ
json_fail_count=0

# ===== ディレクトリ準備 =====
mkdir -p "$RESEARCH_DIR" "$LOG_DIR" ".forge/state"

# ===== 状態ファイル初期化（存在しない場合のみ） =====
if [ ! -f "$ERRORS_FILE" ]; then
  touch "$ERRORS_FILE"
fi
if [ ! -f "$DECISIONS_FILE" ]; then
  touch "$DECISIONS_FILE"
fi

# ===== ユーティリティ関数 =====
# log(), now_ts(), render_template(), run_claude(), validate_json(),
# record_error(), check_dependencies() は common.sh から提供

# jqで安全にJSON生成（シェル変数の特殊文字をエスケープ）
# started_atはリサーチ開始時刻を保持（上書きしない）
update_state() {
  local stage="$1"
  local status="${2:-running}"
  jq -n \
    --arg status "$status" \
    --arg theme "$THEME" \
    --arg research_dir "$RESEARCH_DIR" \
    --arg stage "$stage" \
    --arg mode "$RESEARCH_MODE" \
    --arg started "$START_TS" \
    --arg updated "$(date -Iseconds)" \
    '{
      status: $status,
      theme: $theme,
      research_dir: $research_dir,
      current_stage: $stage,
      research_mode: $mode,
      started_at: $started,
      updated_at: $updated
    }' > "$STATE_FILE"
  update_research_heartbeat "$stage"
}

# ステージ別の stale 閾値（分）: 各ステージの retry 包絡 (timeout×3attempts)/60 + 5分マージン。
# 固定 15 分では正常な単一ステージ（researcher 600s×3 等）が誤検知されるため自己申告型にする
#（2026-07 batch#8 Fix4。monitor.sh が heartbeat.json の stale_threshold_min を読む）
_stage_threshold_min() {
  local t
  case "$1" in
    scope-challenger*)    t="${TIMEOUT_SC:-300}" ;;
    researcher*)          t="${TIMEOUT_RESEARCHER:-600}" ;;
    synthesizer*)         t="${TIMEOUT_SYNTHESIZER:-600}" ;;
    criteria*)            t="${TIMEOUT_CRITERIA:-900}" ;;
    report*|final-report*) t="${TIMEOUT_REPORT:-1200}" ;;
    devils-advocate*|da*) t="${TIMEOUT_DA:-600}" ;;
    *)                    t=600 ;;
  esac
  case "$t" in ''|*[!0-9]*) t=600 ;; esac
  # criteria_generation_sec は 0（無制限）設定があり得る → 閾値も実質無効化（24h）
  if [ "$t" -eq 0 ]; then
    echo 1440
  else
    echo $(( t * 3 / 60 + 5 ))
  fi
}

# リサーチ側 heartbeat: ralph の heartbeat.json と同形 + stale_threshold_min。
# update_state（全ステージ遷移で呼ばれる）の末尾から自動更新される
update_research_heartbeat() {
  local stage="$1"
  local elapsed_min=$(( ( $(date +%s) - _RESEARCH_START_EPOCH ) / 60 ))
  jq -n \
    --arg loop "research" \
    --arg task "$stage" \
    --argjson tc 0 \
    --argjson ic 0 \
    --arg elapsed "${elapsed_min}m" \
    --arg ts "$(date -Iseconds)" \
    --argjson th "$(_stage_threshold_min "$stage")" \
    '{loop: $loop, current_task: $task, task_count: $tc,
      investigation_count: $ic, elapsed: $elapsed, heartbeat_at: $ts,
      stale_threshold_min: $th}' \
    > "${HEARTBEAT_FILE}.tmp" 2>/dev/null && mv "${HEARTBEAT_FILE}.tmp" "$HEARTBEAT_FILE"
}

# エラーローテーション（設計書 §4.4）
rotate_errors() {
  [ -f "$ERRORS_FILE" ] || return 0
  local line_count
  line_count=$(wc -l < "$ERRORS_FILE" 2>/dev/null | tr -d ' ')
  line_count=${line_count:-0}
  if [ "$line_count" -gt 100 ]; then
    log "errors.jsonl ローテーション実行（${line_count}行 > 100行）"
    jq -c 'select(.resolution != null)' "$ERRORS_FILE" \
      >> "${LOG_DIR}/errors-archive.jsonl" 2>/dev/null || true
    jq -c 'select(.resolution == null)' "$ERRORS_FILE" \
      > "${ERRORS_FILE}.tmp" 2>/dev/null || true
    mv "${ERRORS_FILE}.tmp" "$ERRORS_FILE"
  fi
}

# G8: decisions.jsonl の要約注入（50件超対応）
# 件数が少ない間は原文、多くなったら要約+参照パス
get_recent_decisions() {
  if [ ! -s "$DECISIONS_FILE" ]; then
    return
  fi
  local total_lines
  total_lines=$(wc -l < "$DECISIONS_FILE" 2>/dev/null | tr -d ' ')
  total_lines=${total_lines:-0}

  if [ "$total_lines" -le "$MAX_DECISIONS_IN_PROMPT" ]; then
    # 件数が閾値以下: 全件そのまま
    cat "$DECISIONS_FILE"
  else
    # 件数が閾値超: 要約形式（id, theme, decision, verdict のみ抽出）+ 参照パス
    echo "（${total_lines}件中、直近${MAX_DECISIONS_IN_PROMPT}件を要約表示。原文: ${DECISIONS_FILE}）"
    tail -n "$MAX_DECISIONS_IN_PROMPT" "$DECISIONS_FILE" | jq -c '{id, theme, decision, verdict}' 2>/dev/null
  fi
}

# ===== ① Scope Challenger =====
# 検索なし（設計書 §2.4: 内部分析のみ。外部情報は先入観のリスク）
run_scope_challenger() {
  log "① Scope Challenger 開始"
  update_state "scope-challenger"
  update_progress "research" "scope-challenger" "Scope Challenger 実行中" "10"

  local ts
  ts=$(now_ts)
  local output="${RESEARCH_DIR}/investigation-plan.json"
  local log_file="${LOG_DIR}/sc-${ts}-${TOPIC_HASH}.log"

  # 過去決定コンテキスト
  local decisions=""
  local recent_decisions
  recent_decisions=$(get_recent_decisions)
  if [ -n "$recent_decisions" ]; then
    decisions="直近${MAX_DECISIONS_IN_PROMPT}件:
${recent_decisions}"
  else
    decisions="（なし）"
  fi

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/scope-challenger-prompt.md" \
    "THEME"              "$THEME" \
    "DIRECTION"          "${DIRECTION:-（指定なし。テーマから自律的に判断すること）}" \
    "DECISIONS"          "$decisions" \
    "RESEARCH_MODE"      "$RESEARCH_MODE" \
    "LOCKED_DECISIONS"   "$LOCKED_DECISIONS_TEXT" \
    "OPEN_QUESTIONS"     "$OPEN_QUESTIONS_TEXT"
  )

  # --disallowed-tools: SC は検索禁止（設計書 §2.4）
  metrics_start
  retry_with_backoff 3 1 run_claude "$MODEL_SC" "${AGENTS_DIR}/scope-challenger.md" \
    "$prompt" "$output" "$log_file" "$TOOLS_SC" "$TIMEOUT_SC" "" \
    "${SCHEMAS_DIR}/scope-challenger.schema.json" || {
    _sc_rc=$?
    metrics_record "scope-challenger" false
    record_error "scope-challenger" "Claude実行エラー" "$_sc_rc"
    log "✗ Scope Challenger Claude実行エラー"
    return 1
  }

  if validate_json "$output" "scope-challenger"; then
    metrics_record "scope-challenger" true
  elif check_direct_write_fallback "$output" "scope-challenger"; then
    metrics_record "scope-challenger" true
  else
    metrics_record "scope-challenger" false
    return 1
  fi

  log "✓ Scope Challenger 完了 → ${output}"
  update_progress "research" "scope-challenger-done" "完了" "15"
}

# ===== 視点別連続失敗カウンタ（circuit-breaker parallel） =====
# perspective の連続失敗回数を RESEARCH_DIR 配下のファイルで管理する。
# サブシェル (background &) からも安全に読み書きできるようファイルベースで実装。

_get_perspective_fail_count() {
  local perspective="$1"
  local count_file="${RESEARCH_DIR}/.perspective-fails/${perspective}.count"
  [ -f "$count_file" ] && cat "$count_file" || echo "0"
}

_set_perspective_fail_count() {
  local perspective="$1"
  local count="$2"
  mkdir -p "${RESEARCH_DIR}/.perspective-fails"
  echo "$count" > "${RESEARCH_DIR}/.perspective-fails/${perspective}.count"
}

# perspective をスキップすべきか判定する。
# 連続失敗数が PERSPECTIVE_MAX_CONSECUTIVE_FAILS 以上の場合は 0 を返す。
should_skip_perspective() {
  local perspective="$1"
  local fail_count
  fail_count=$(_get_perspective_fail_count "$perspective")
  [ "$fail_count" -ge "${PERSPECTIVE_MAX_CONSECUTIVE_FAILS:-3}" ] && return 0
  return 1
}

# ===== 単一 Researcher 実行（サブシェル対応） =====
# 引数: perspective plan result_dir
# result_dir/<perspective>.status に "pass" / "fail" を書出す。
# result_dir/<perspective>.duration に経過秒を書出す。
_run_single_researcher() {
  local perspective="$1"
  local plan="$2"
  local result_dir="$3"
  local _start
  _start=$(date +%s)

  local ts
  ts=$(now_ts)
  local focus
  focus=$(jq_safe -r --arg p "$perspective" '
    .investigation_plan.perspectives |
    ((.fixed // []) + (.dynamic // [])) |
    .[] | select(.id == $p) | .focus
  ' "$plan" | tr -d '\r')

  local questions
  questions=$(jq -c --arg p "$perspective" '
    .investigation_plan.perspectives |
    ((.fixed // []) + (.dynamic // [])) |
    .[] | select(.id == $p) | .key_questions
  ' "$plan" | tr -d '\r')

  local output="${RESEARCH_DIR}/perspective-${perspective}.json"
  local log_file="${LOG_DIR}/r-${perspective}-${ts}-${TOPIC_HASH}.log"

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/researcher-prompt.md" \
    "PERSPECTIVE_ID" "$perspective" \
    "FOCUS"          "$focus" \
    "QUESTIONS"      "$questions"
  )

  # DA 再調査ラウンド: CRITICAL findings の解消を最優先指示として末尾追記
  # （& フォークのサブシェルは親のシェル変数をコピーするため export 不要）
  if [ -n "${DA_REFOCUS_TEXT:-}" ]; then
    prompt="${prompt}

## Devil's Advocate からの重点再調査指示（証拠つき反証への対応）

以下の反証を解消または確定させる情報を最優先で収集すること:

${DA_REFOCUS_TEXT}"
  fi

  # 各Researcherは独立セッション（Ralph原則: 完全リセット）
  # batch#11 R19a: timeout（124）は非リトライ。TIMEOUT_RESEARCHER=1200 のリトライ 3 回は最悪 80 分の
  # 直列待ちになり並列実行の恩恵を打ち消す（1 視点の欠落は Synthesizer が吸収する）
  RETRY_NONRETRYABLE_EXITS="${RETRY_NONRETRYABLE_EXITS:-2 21 22 130 143} 124" \
  retry_with_backoff 3 1 run_claude "$MODEL_RESEARCHER" "${AGENTS_DIR}/researcher.md" \
    "$prompt" "$output" "$log_file" "$TOOLS_RESEARCHER" "$TIMEOUT_RESEARCHER" "" \
    "${SCHEMAS_DIR}/researcher.schema.json" || {
    _rs_rc=$?
    record_error "researcher-${perspective}" "Claude実行エラー" "$_rs_rc"
    log "  ✗ Researcher [${perspective}] Claude実行エラー"
    echo "fail" > "${result_dir}/${perspective}.status"
    echo "$(($(date +%s) - _start))" > "${result_dir}/${perspective}.duration"
    return 0
  }

  if validate_json "$output" "researcher-${perspective}"; then
    echo "pass" > "${result_dir}/${perspective}.status"
  elif check_direct_write_fallback "$output" "researcher-${perspective}"; then
    echo "pass" > "${result_dir}/${perspective}.status"
  else
    echo "fail" > "${result_dir}/${perspective}.status"
  fi
  echo "$(($(date +%s) - _start))" > "${result_dir}/${perspective}.duration"
}

# ===== ② Researcher =====
# 検索あり（設計書 §2.4: 情報収集が本業）
# parallel_researchers=true 時は並列実行、false 時は順次実行
run_researchers() {
  log "② Researcher 開始"
  update_state "researcher"
  update_progress "research" "researcher" "Researcher 実行中" "20"

  local plan="${RESEARCH_DIR}/investigation-plan.json"

  # 視点一覧を取得（固定 + 動的）。tr -d '\r' でCRLF対策。
  local perspectives
  perspectives=$(jq_safe -r '
    .investigation_plan.perspectives |
    ((.fixed // []) + (.dynamic // [])) |
    .[].id
  ' "$plan" | tr -d '\r')

  if [ -z "$perspectives" ]; then
    record_error "researcher" "視点が0個"
    log "✗ 視点が取得できない"
    return 1
  fi

  local result_dir="${RESEARCH_DIR}/.researcher-results"
  mkdir -p "$result_dir"

  # _run_single_researcher は外部関数として定義済み（circuit-breaker parallel 対応）

  local perspective_count=0

  if [ "${PARALLEL_RESEARCHERS:-true}" = "true" ]; then
    log "  (並列実行モード)"
    local pids=()
    for perspective in $perspectives; do
      perspective_count=$((perspective_count + 1))

      # [circuit-breaker] 連続失敗閾値チェック: スキップ
      if should_skip_perspective "$perspective"; then
        log "  ⏭ Researcher [${perspective}] 連続$(_get_perspective_fail_count "$perspective")回失敗 — スキップ"
        echo "skipped" > "${result_dir}/${perspective}.status"
        echo "0" > "${result_dir}/${perspective}.duration"
        continue
      fi

      log "  ② Researcher [${perspective_count}] ${perspective} (background)"
      update_progress "research" "researcher-${perspective}" "[${perspective}]" ""
      _run_single_researcher "$perspective" "$plan" "$result_dir" &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    # 結果集約 [circuit-breaker: 全失敗検出のためにカウント]
    local pass_round_count=0
    local active_run_count=0
    for perspective in $perspectives; do
      local dur=0; [ -f "${result_dir}/${perspective}.duration" ] && dur=$(cat "${result_dir}/${perspective}.duration")
      local status="fail"; [ -f "${result_dir}/${perspective}.status" ] && status=$(cat "${result_dir}/${perspective}.status")
      # metrics.jsonl に記録
      jq -n -c --arg s "researcher-${perspective}" --argjson d "$dur" \
        --argjson ps "$([ "$status" = "pass" ] && echo true || echo false)" \
        --arg rd "${RESEARCH_DIR}" --arg ts "$(date -Iseconds)" \
        '{stage:$s,duration_sec:$d,parse_success:$ps,research_dir:$rd,timestamp:$ts}' >> "$METRICS_FILE"
      if [ "$status" = "pass" ]; then
        pass_round_count=$((pass_round_count + 1))
        active_run_count=$((active_run_count + 1))
        _set_perspective_fail_count "$perspective" 0
        log "  ✓ Researcher [${perspective}] 完了"
      elif [ "$status" = "skipped" ]; then
        log "  ⏭ Researcher [${perspective}] スキップ（連続失敗）"
      else
        active_run_count=$((active_run_count + 1))
        json_fail_count=$((json_fail_count + 1))
        local new_fail_count
        new_fail_count=$(( $(_get_perspective_fail_count "$perspective") + 1 ))
        _set_perspective_fail_count "$perspective" "$new_fail_count"
        log "  ✗ Researcher [${perspective}] 失敗（連続${new_fail_count}回）"
      fi
    done

    # [circuit-breaker] 全並列失敗検出: active 全件失敗 → クールダウン + リトライ
    if [ "$active_run_count" -gt 0 ] && [ "$pass_round_count" -eq 0 ]; then
      local _cooldown="${COOLDOWN_SEC:-${PARALLEL_ALL_FAIL_COOLDOWN_SEC}}"
      log "  ⚠ 全Researcher同時失敗検出（API障害パターン）— ${_cooldown}秒クールダウン後にリトライ"
      sleep "$_cooldown"

      # リトライ: 失敗 perspective を再実行（skipped はそのまま）
      local retry_pids=()
      for perspective in $perspectives; do
        local prev_s="fail"
        [ -f "${result_dir}/${perspective}.status" ] && prev_s=$(cat "${result_dir}/${perspective}.status")
        [ "$prev_s" = "skipped" ] && continue
        rm -f "${result_dir}/${perspective}.status" "${result_dir}/${perspective}.duration"
        log "  ↻ Researcher [${perspective}] リトライ (background)"
        _run_single_researcher "$perspective" "$plan" "$result_dir" &
        retry_pids+=($!)
      done
      for pid in "${retry_pids[@]}"; do wait "$pid" || true; done

      # リトライ結果集約: 初回失敗分を json_fail_count からロールバック
      json_fail_count=$((json_fail_count - active_run_count))
      local retry_pass_count=0
      for perspective in $perspectives; do
        local r_status="fail"
        [ -f "${result_dir}/${perspective}.status" ] && r_status=$(cat "${result_dir}/${perspective}.status")
        [ "$r_status" = "skipped" ] && continue
        if [ "$r_status" = "pass" ]; then
          retry_pass_count=$((retry_pass_count + 1))
          _set_perspective_fail_count "$perspective" 0
          log "  ✓ Researcher [${perspective}] リトライ成功"
        else
          json_fail_count=$((json_fail_count + 1))
          local retry_fail_count
          retry_fail_count=$(( $(_get_perspective_fail_count "$perspective") + 1 ))
          _set_perspective_fail_count "$perspective" "$retry_fail_count"
          log "  ✗ Researcher [${perspective}] リトライ失敗（連続${retry_fail_count}回）"
        fi
      done

      if [ "$retry_pass_count" -ge 3 ]; then
        log "  ✓ クールダウン後回復（${retry_pass_count}件成功）— json_fail_countリセット"
        json_fail_count=0
      else
        log "  ✗ クールダウン後も全件失敗 — AUTO-ABORT"
        record_error "parallel-researcher" "全並列Researcher失敗（クールダウン後リトライも全失敗）"
        update_state "aborted" "auto-abort-json-failures"
        rm -rf "$result_dir"
        return 1
      fi
    fi
  else
    log "  (順次実行モード)"
    for perspective in $perspectives; do
      perspective_count=$((perspective_count + 1))
      log "  ② Researcher [${perspective_count}] 視点: ${perspective}"
      update_progress "research" "researcher-${perspective}" "[${perspective}]" ""

      metrics_start
      _run_single_researcher "$perspective" "$plan" "$result_dir"

      local dur=0; [ -f "${result_dir}/${perspective}.duration" ] && dur=$(cat "${result_dir}/${perspective}.duration")
      local status="fail"; [ -f "${result_dir}/${perspective}.status" ] && status=$(cat "${result_dir}/${perspective}.status")
      if [ "$status" = "pass" ]; then
        metrics_record "researcher-${perspective}" true
        log "  ✓ Researcher [${perspective}] 完了 → ${RESEARCH_DIR}/perspective-${perspective}.json"
      else
        metrics_record "researcher-${perspective}" false
        log "  ✗ Researcher [${perspective}] 失敗"
      fi
    done
  fi

  rm -rf "$result_dir"
  log "✓ Researcher 全視点完了（${perspective_count}視点）"
  update_progress "research" "researcher-done" "全Researcher完了" "50"
}

# ===== ③ Synthesizer =====
# 検索なし（設計書 §2.4: 統合のみ。追加検索は役割逸脱）
# 引数: $1 = DA フィードバック（再調査ラウンド時のみ。省略時は「なし」）
run_synthesizer() {
  local da_feedback="${1:-（なし）}"
  log "③ Synthesizer 開始"
  update_state "synthesizer"
  update_progress "research" "synthesizer" "Synthesizer 実行中" "60"

  local ts
  ts=$(now_ts)
  local output="${RESEARCH_DIR}/synthesis.json"
  local log_file="${LOG_DIR}/syn-${ts}-${TOPIC_HASH}.log"

  # 調査計画を読み込む
  local investigation_plan
  investigation_plan=$(cat "${RESEARCH_DIR}/investigation-plan.json")

  # 全Researcherレポートを結合
  local all_reports=""
  for report_file in "${RESEARCH_DIR}"/perspective-*.json; do
    if [ -f "$report_file" ]; then
      all_reports="${all_reports}
--- $(basename "$report_file") ---
$(cat "$report_file")
"
    fi
  done

  # 過去決定コンテキスト
  local decisions=""
  local recent_decisions
  recent_decisions=$(get_recent_decisions)
  if [ -n "$recent_decisions" ]; then
    decisions="直近${MAX_DECISIONS_IN_PROMPT}件:
${recent_decisions}"
  else
    decisions="（なし）"
  fi

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/synthesizer-prompt.md" \
    "INVESTIGATION_PLAN" "$investigation_plan" \
    "ALL_REPORTS"        "$all_reports" \
    "DECISIONS"          "$decisions" \
    "RESEARCH_MODE"      "$RESEARCH_MODE" \
    "LOCKED_DECISIONS"   "$LOCKED_DECISIONS_TEXT" \
    "DA_FEEDBACK"        "$da_feedback"
  )

  # --disallowed-tools: Synthesizer は検索禁止（設計書 §2.4）
  metrics_start
  retry_with_backoff 3 1 run_claude "$MODEL_SYNTHESIZER" "${AGENTS_DIR}/synthesizer.md" \
    "$prompt" "$output" "$log_file" "$TOOLS_SYNTHESIZER" "$TIMEOUT_SYNTHESIZER" "" \
    "${SCHEMAS_DIR}/synthesizer.schema.json" || {
    _syn_rc=$?
    metrics_record "synthesizer" false
    record_error "synthesizer" "Claude実行エラー" "$_syn_rc"
    log "✗ Synthesizer Claude実行エラー"
    return 1
  }

  if validate_json "$output" "synthesizer"; then
    metrics_record "synthesizer" true
  elif check_direct_write_fallback "$output" "synthesizer"; then
    metrics_record "synthesizer" true
  else
    metrics_record "synthesizer" false
    return 1
  fi

  log "✓ Synthesizer 完了 → ${output}"
  update_progress "research" "synthesizer-done" "完了" "70"
}

# ===== ③.5 Devil's Advocate（advisory・非ブロッキング） =====
# 引数: $1 = round (1|2)。round2 は前回フィードバックを注入し解消検証を最優先させる。
# 出力: round1 → devils-advocate.json / round2 → devils-advocate-r2.json
# 常に return 0（advisory 原則）。失敗時は出力ファイル不在 = CRITICAL 0 扱い。
run_devils_advocate_advisory() {
  local da_round="${1:-1}"
  if [ "${DA_ENABLED:-false}" != "true" ]; then
    log "  DA 無効 (devils_advocate.enabled=false) — スキップ"
    return 0
  fi
  if [ ! -f "${AGENTS_DIR}/devils-advocate.md" ] || [ ! -f "${TEMPLATES_DIR}/devils-advocate-prompt.md" ]; then
    log "  ⚠ DA: エージェント/テンプレート不在 — スキップ（advisory）"
    return 0
  fi
  if [ ! -s "${RESEARCH_DIR}/synthesis.json" ]; then
    log "  ⚠ DA: synthesis.json 不在 — スキップ（advisory）"
    return 0
  fi

  log "③.5 Devil's Advocate 開始 (advisory, round ${da_round})"
  update_state "devils-advocate"
  update_progress "research" "devils-advocate-r${da_round}" "DA round ${da_round}" "72"

  local ts
  ts=$(now_ts)
  local output="${RESEARCH_DIR}/devils-advocate.json"
  if [ "$da_round" -ge 2 ]; then
    output="${RESEARCH_DIR}/devils-advocate-r2.json"
  fi
  local log_file="${LOG_DIR}/da-r${da_round}-${ts}-${TOPIC_HASH}.log"

  local prev_feedback="（初回実行。前回フィードバックなし）"
  if [ "$da_round" -ge 2 ] && [ -s "${RESEARCH_DIR}/devils-advocate.json" ]; then
    prev_feedback=$(cat "${RESEARCH_DIR}/devils-advocate.json")
  fi

  local report_files
  report_files=$(ls "${RESEARCH_DIR}/investigation-plan.json" "${RESEARCH_DIR}"/perspective-*.json 2>/dev/null | sed 's/^/- /' || true)

  local decisions=""
  local recent_decisions
  recent_decisions=$(get_recent_decisions)
  if [ -n "$recent_decisions" ]; then
    decisions="直近${MAX_DECISIONS_IN_PROMPT}件:
${recent_decisions}"
  else
    decisions="（なし）"
  fi

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/devils-advocate-prompt.md" \
    "THEME"                "$THEME" \
    "RESEARCH_MODE"        "$RESEARCH_MODE" \
    "LOCKED_DECISIONS"     "$LOCKED_DECISIONS_TEXT" \
    "SYNTHESIS"            "$(cat "${RESEARCH_DIR}/synthesis.json")" \
    "REPORT_FILES"         "$report_files" \
    "DECISIONS"            "$decisions" \
    "FEEDBACK_ID"          "da-r${da_round}-${ts}-${TOPIC_HASH}" \
    "PREVIOUS_DA_FEEDBACK" "$prev_feedback"
  )

  # DA のパース失敗を研究の AUTO-ABORT 閾値（json_fail_count）に混入させない
  local _saved_fail_count=$json_fail_count
  local da_effort
  da_effort=$(resolve_agent_effort "devils_advocate" "$RESEARCH_CONFIG" 2>/dev/null || echo "")

  metrics_start
  _da_rc=0
  retry_with_backoff 3 1 run_claude "$MODEL_DA" "${AGENTS_DIR}/devils-advocate.md" \
      "$prompt" "$output" "$log_file" "$TOOLS_DA" "$TIMEOUT_DA" "" \
      "${SCHEMAS_DIR}/devils-advocate.schema.json" "$da_effort" || _da_rc=$?
  if [ "$_da_rc" -ne 0 ]; then
    metrics_record "devils-advocate-r${da_round}" false
    record_error "devils-advocate" "Claude実行エラー（advisory — 研究続行）" "$_da_rc"
    log "  ⚠ DA 実行エラー — スキップして続行（advisory）"
    json_fail_count=$_saved_fail_count
    return 0
  fi

  if validate_json "$output" "devils-advocate-r${da_round}" \
     || check_direct_write_fallback "$output" "devils-advocate-r${da_round}"; then
    metrics_record "devils-advocate-r${da_round}" true
  else
    metrics_record "devils-advocate-r${da_round}" false
    log "  ⚠ DA 出力パース失敗 — スキップして続行（advisory）"
    json_fail_count=$_saved_fail_count
    rm -f "$output"
    return 0
  fi
  json_fail_count=$_saved_fail_count

  _demote_unevidenced_criticals "$output"
  log "✓ DA 完了 (round ${da_round}) → ${output}"
  update_progress "research" "devils-advocate-done" "完了" "75"
  return 0
}

# ===== 証拠なし CRITICAL の機械的降格 =====
# evidence が空（または空文字列のみ）の CRITICAL を HIGH に降格する。
# 幻覚的難癖による無駄な再調査ラウンドの機械防御。demoted_from で監査可能。
_demote_unevidenced_criticals() {
  local f="$1"
  [ -s "$f" ] || return 0
  if jq '(.devils_advocate.findings // []) |= map(
        if .severity == "CRITICAL"
           and (([.evidence[]? | select((. | length) > 0)] | length) == 0)
        then .severity = "HIGH" | .demoted_from = "CRITICAL"
        else . end)' "$f" > "${f}.tmp" 2>/dev/null; then
    mv "${f}.tmp" "$f"
  else
    rm -f "${f}.tmp"
  fi
  return 0
}

# ===== CRITICAL findings 件数（ハーネス側の判定材料） =====
# ファイル不在/パース不能は 0 を返す（= advisory スキップ扱い）。
_da_critical_count() {
  local f="$1"
  local n
  if [ ! -s "$f" ]; then
    echo 0
    return 0
  fi
  n=$(jq '[.devils_advocate.findings[]? | select(.severity == "CRITICAL")] | length' "$f" 2>/dev/null | tr -d '\r')
  case "$n" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$n" ;;
  esac
  return 0
}

# ===== DA findings の criteria 伝搬（決定的 jq マージ） =====
# criteria.schema.json は constrained decoding 用のため変更しない
# （additionalProperties 未指定のため後付けフィールドは valid）。
# generate-tasks.sh は criteria 全文をプロンプト注入するため Task Planner へ自動伝搬する。
# da_findings_text — DA findings（r2 優先）を criteria 生成プロンプト用の Markdown 箇条書きにする（batch#11 R19a）。
# 従来は生成後に da_risk_notes として JSON に貼るだけで、criteria 生成モデルは DA の指摘を見ていなかった。
# 出力なし（DA 無効 / findings 0）は空文字。
da_findings_text() {
  local da_file="${RESEARCH_DIR}/devils-advocate-r2.json"
  [ -s "$da_file" ] || da_file="${RESEARCH_DIR}/devils-advocate.json"
  [ -s "$da_file" ] || return 0
  jq -r '
    [.devils_advocate.findings[]? | select(.description != null)] |
    map("- [\(.severity // "?")] \(.id // "-"): \(.description)" +
        (if (.resolution_criteria // "") != "" then "（解消条件: \(.resolution_criteria)）" else "" end)) |
    join("\n")
  ' "$da_file" 2>/dev/null | tr -d '\r' || true
}

inject_da_findings_into_criteria() {
  local criteria="${RESEARCH_DIR}/implementation-criteria.json"
  local da_file="${RESEARCH_DIR}/devils-advocate-r2.json"
  if [ ! -s "$da_file" ]; then
    da_file="${RESEARCH_DIR}/devils-advocate.json"
  fi
  if [ ! -s "$criteria" ] || [ ! -s "$da_file" ]; then
    return 0
  fi
  local notes
  notes=$(jq '[.devils_advocate.findings[]? | {severity, id, description, resolution_criteria}]' "$da_file" 2>/dev/null) || return 0
  if [ -z "$notes" ] || [ "$notes" = "[]" ]; then
    return 0
  fi
  if jq --argjson notes "$notes" \
     '.da_risk_notes = $notes
      | .da_open_questions = [$notes[] | select(.severity != "MEDIUM") | .description]' \
     "$criteria" > "${criteria}.tmp" 2>/dev/null; then
    mv "${criteria}.tmp" "$criteria"
    log "✓ DA findings を criteria に伝搬 ($(echo "$notes" | jq 'length' | tr -d '\r')件: da_risk_notes / da_open_questions)"
  else
    rm -f "${criteria}.tmp"
    log "⚠ DA findings の criteria 伝搬に失敗（続行）"
  fi
  return 0
}

# ===== implementation-criteria.json 生成（v3.2: Research→Development接続） =====
# GO verdict 後に呼び出す。Synthesizer出力から3層の成功条件を導出。
# 失敗時は warn のみ（リサーチ結果自体は保存済み）。
generate_criteria() {
  log "implementation-criteria.json 生成中..."

  local ts
  ts=$(now_ts)
  local synthesis="${RESEARCH_DIR}/synthesis.json"
  local output="${RESEARCH_DIR}/implementation-criteria.json"
  local log_file="${LOG_DIR}/criteria-${ts}-${TOPIC_HASH}.log"
  local research_id="${DATE}-${TOPIC_HASH}-${START_TS##*-}"

  if [ ! -s "$synthesis" ]; then
    log "⚠ synthesis.json が見つかりません。criteria生成をスキップ"
    return 0
  fi

  local synthesis_content
  synthesis_content=$(cat "$synthesis")

  # SERVER_URL 取得（common.sh の get_server_url を使用）
  local server_url
  server_url=$(get_server_url)

  # 環境能力プローブ（Phase 1 時点では WORK_DIR 未確定のため PROJECT_ROOT で実行）
  # walking_skeleton の検証ティア選択（server→curl / browser→UI / なし→CLI）の判断材料
  local env_probe_content
  local _caps_file="${PROJECT_ROOT}/.forge/state/env-capabilities.json"
  if probe_env_capabilities "$PROJECT_ROOT" "$_caps_file" "${PROJECT_ROOT}/.forge/config/development.json"; then
    env_probe_content=$(format_env_probe_for_prompt "$_caps_file")
  else
    env_probe_content="（環境プローブ失敗 — 検証手段は保守的に選定すること）"
  fi

  # DA の指摘（batch#11 R19a）: 生成前に見せる。da_risk_notes の事後付与（inject_da_findings_into_criteria）は据置
  local da_findings_content
  da_findings_content=$(da_findings_text 2>/dev/null || true)
  [ -n "$da_findings_content" ] || da_findings_content="（Devil's Advocate の指摘なし）"

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/criteria-generation.md" \
    "SYNTHESIS"    "$synthesis_content" \
    "THEME"        "$THEME" \
    "RESEARCH_ID"  "$research_id" \
    "SERVER_URL"   "$server_url" \
    "ENV_PROBE"    "$env_probe_content" \
    "DA_FINDINGS"  "$da_findings_content"
  )

  # Synthesizer エージェントを再利用（検索禁止）
  run_claude "$MODEL_CRITERIA" "${AGENTS_DIR}/synthesizer.md" \
    "$prompt" "$output" "$log_file" "WebSearch WebFetch" "$TIMEOUT_CRITERIA" "" \
    "${SCHEMAS_DIR}/criteria.schema.json" || {
    log "⚠ implementation-criteria.json 生成失敗（リサーチ結果自体は保存済み）"
    return 0
  }

  if validate_json "$output" "criteria-generation"; then
    # 基本スキーマ検証: layer_1_criteria の存在チェック
    if jq -e '.layer_1_criteria' "$output" >/dev/null 2>&1; then
      log "✓ implementation-criteria.json → ${output}"
    else
      log "⚠ implementation-criteria.json に layer_1_criteria が含まれていません"
    fi
  elif check_direct_write_fallback "$output" "criteria-generation"; then
    if jq -e '.layer_1_criteria' "$output" >/dev/null 2>&1; then
      log "✓ implementation-criteria.json → ${output}（直接書き込みフォールバック）"
    else
      log "⚠ implementation-criteria.json に layer_1_criteria が含まれていません（直接書き込みフォールバック）"
    fi
  else
    log "⚠ implementation-criteria.json 生成失敗（JSON検証エラー）"
  fi
}

# ===== 最終レポート生成 =====
generate_final_report() {
  log "最終レポート生成中..."

  local ts
  ts=$(now_ts)
  local output="${RESEARCH_DIR}/final-report.md"
  local log_file="${LOG_DIR}/report-${ts}-${TOPIC_HASH}.log"

  local prompt="以下のリサーチ結果から、人間が読みやすい日本語の最終レポートを生成してください。
Markdown形式で、見出し・表・箇条書きを適切に使ってください。

リサーチディレクトリ: ${RESEARCH_DIR}

以下のファイルを全て読み込んでレポートにまとめてください:
- ${RESEARCH_DIR}/investigation-plan.json
- ${RESEARCH_DIR}/perspective-*.json（全ファイル）
- ${RESEARCH_DIR}/synthesis.json
- ${RESEARCH_DIR}/devils-advocate.json / devils-advocate-r2.json（生成されている場合。リスク指摘セクションとして反映）
- ${RESEARCH_DIR}/implementation-criteria.json（生成されている場合）"

  run_claude "$MODEL_REPORT" "" "$prompt" "$output" "$log_file" "" "${TIMEOUT_REPORT:-1200}" || {
    log "⚠ 最終レポート生成失敗（リサーチ結果自体は保存済み）"
    return 0
  }

  log "✓ 最終レポート → ${output}"
}

# ===== decisions.jsonlへの記録（jqで安全にJSON生成） =====
# 引数: $1 = verdict（省略時 DIRECT = DA 無効時の従来互換値）
record_decision() {
  local verdict="${1:-DIRECT}"
  local primary_action
  primary_action=$(jq_safe -r '.synthesis.recommendations.primary.action // "不明"' "${RESEARCH_DIR}/synthesis.json")
  local primary_rationale
  primary_rationale=$(jq_safe -r '.synthesis.recommendations.primary.rationale // "不明"' "${RESEARCH_DIR}/synthesis.json")

  local decision_id="d-$(date +%Y%m%d)-$(date +%H%M%S)"

  jq -n -c \
    --arg id "$decision_id" \
    --arg theme "$THEME" \
    --arg decision "$primary_action" \
    --arg rationale "$primary_rationale" \
    --arg verdict "$verdict" \
    --argjson da_rounds "${DA_ROUNDS:-0}" \
    --argjson da_critical_open "${DA_CRITICAL_OPEN:-0}" \
    --arg timestamp "$(date -Iseconds)" \
    '{id: $id, theme: $theme, decision: $decision, rationale: $rationale, verdict: $verdict, da_rounds: $da_rounds, da_critical_open: $da_critical_open, timestamp: $timestamp}' \
    >> "$DECISIONS_FILE"

  log "✓ 決定記録 → ${DECISIONS_FILE} (${decision_id}, verdict=${verdict})"

  # G4: index.md 自動更新
  update_research_index "$primary_action" "$verdict"
}

# ===== index.md 自動更新（G4） =====
# 引数: $1 = primary action, $2 = verdict（省略時 DIRECT）
update_research_index() {
  local action="${1:-}"
  local verdict_val="${2:-DIRECT}"
  local index_file=".docs/research/index.md"
  if [ ! -f "$index_file" ]; then
    return 0
  fi
  # テーマの | をエスケープ（Markdownテーブル壊れ防止）
  local safe_theme="${THEME//|/\\|}"
  local safe_action="${action//|/\\|}"

  # プレースホルダー行を削除して実データ行を追記
  # テーブルの末尾に追記
  echo "| ${DATE} | ${safe_theme} | ${verdict_val} | [レポート](${RESEARCH_DIR}/final-report.md) |" >> "$index_file"
  log "✓ index.md 更新 → ${index_file}"
}

# ===== メインループ =====
log "=========================================="
log "Forge Research Harness v2.0 開始"
log "テーマ: ${THEME}"
log "方向性: ${DIRECTION:-（なし）}"
log "出力先: ${RESEARCH_DIR}"
log "=========================================="

# B2: 起動時にstuck状態チェック
if [ -f "$STATE_FILE" ]; then
  _prev_status=$(jq_safe -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
  if [ "$_prev_status" = "running" ]; then
    log "⚠ 前回リサーチが running のまま残っています。interrupted に更新して続行。"
    jq --arg ts "$(date -Iseconds)" \
      '.status = "interrupted" | .updated_at = $ts' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
fi

# 初期状態を running に設定
update_state "initializing" "running"

# エラーローテーション
rotate_errors

# 初回: Scope Challenger
run_scope_challenger || {
  log "✗ Scope Challenger 失敗。終了。"
  update_state "scope-challenger" "failed"
  exit 1
}

# ② Researcher
json_fail_count=0
run_researchers || {
  log "✗ Researcher 失敗。終了。"
  update_state "researcher" "failed"
  exit 1
}

# ABORT閾値チェック
if [ "$json_fail_count" -ge "$MAX_JSON_FAILS_PER_LOOP" ]; then
  log "✗ JSON検証失敗が${json_fail_count}件（閾値${MAX_JSON_FAILS_PER_LOOP}） — 自動ABORT"
  record_error "loop-control" "自動ABORT: JSON検証失敗${json_fail_count}件"
  update_state "aborted" "auto-abort-json-failures"
  exit 1
fi

# ③ Synthesizer
run_synthesizer || {
  log "✗ Synthesizer 失敗。終了。"
  update_state "synthesizer" "failed"
  exit 1
}

# ③.5 Devil's Advocate（advisory・拒否権なし）+ CRITICAL 時のみ再調査最大1回
# 制御は直列 if のみ（while ループなし）。旧 GO/NO-GO ループは構造的に復活しない。
DA_VERDICT="DIRECT"          # DA 無効時の従来互換値
DA_ROUNDS=0
DA_CRITICAL_OPEN=0
DA_REFOCUS_TEXT=""
if [ "${DA_ENABLED:-false}" = "true" ]; then
  run_devils_advocate_advisory 1
  DA_ROUNDS=1
  _da_file="${RESEARCH_DIR}/devils-advocate.json"
  if [ ! -s "$_da_file" ]; then
    DA_VERDICT="ADVISORY-SKIPPED"        # DA 実行/パース失敗。研究は続行（advisory）
  else
    _da_critical=$(_da_critical_count "$_da_file")
    if [ "$_da_critical" -gt 0 ] && [ "${DA_MAX_RERESEARCH:-1}" -ge 1 ]; then
      log "⚠ DA: CRITICAL ${_da_critical}件（証拠つき反証）— 再調査ラウンド開始（最大1回）"
      # round1 成果物を退避（DA 前後の差分監査用）
      mkdir -p "${RESEARCH_DIR}/round1"
      cp "${RESEARCH_DIR}"/perspective-*.json "${RESEARCH_DIR}/synthesis.json" \
         "${RESEARCH_DIR}/round1/" 2>/dev/null || true
      # 視点別 circuit-breaker の失敗カウンタをクリア（round1 の失敗による誤スキップ防止）
      rm -rf "${RESEARCH_DIR}/.perspective-fails"
      # CRITICAL findings から再調査指示を構築（_run_single_researcher が末尾注入）
      DA_REFOCUS_TEXT=$(jq -r '[.devils_advocate.findings[]?
        | select(.severity == "CRITICAL")
        | "- [\(.id)] \(.description)\n  解消条件: \(.resolution_criteria)"] | join("\n")' "$_da_file" 2>/dev/null || echo "")
      _da_feedback_for_syn=$(cat "$_da_file")
      json_fail_count=0
      if run_researchers; then
        run_synthesizer "$_da_feedback_for_syn" || {
          log "⚠ Synthesizer 再実行失敗 — round1 の synthesis を復元して続行（advisory）"
          cp "${RESEARCH_DIR}/round1/synthesis.json" "${RESEARCH_DIR}/synthesis.json" 2>/dev/null || true
        }
      else
        log "⚠ Researcher 再実行失敗 — round1 成果物を復元して続行（advisory）"
        cp "${RESEARCH_DIR}/round1/"*.json "${RESEARCH_DIR}/" 2>/dev/null || true
      fi
      DA_REFOCUS_TEXT=""
      run_devils_advocate_advisory 2
      DA_ROUNDS=2
      DA_CRITICAL_OPEN=$(_da_critical_count "${RESEARCH_DIR}/devils-advocate-r2.json")
      # 2回目の結果に関わらず強制続行（完了判定はハーネスが握る）
      if [ "$DA_CRITICAL_OPEN" -gt 0 ]; then
        DA_VERDICT="FORCED-CONDITIONAL-GO"
        log "⚠ DA round2 後も CRITICAL ${DA_CRITICAL_OPEN}件 — 強制続行し criteria にリスク伝搬"
      else
        DA_VERDICT="ADVISORY-GO"
      fi
    else
      DA_VERDICT="ADVISORY-GO"
    fi
  fi
fi

# ④ 決定記録 + criteria + レポート（DA は advisory: 結果に関わらずここに必ず到達）
log "=========================================="
log "✓ リサーチ完了 — 意思決定を記録 (DA verdict: ${DA_VERDICT})"
record_decision "$DA_VERDICT"
generate_criteria
inject_da_findings_into_criteria
generate_final_report
update_state "completed" "completed"
log "✓ リサーチ完了"
log "=========================================="

log "=========================================="
log "Forge Research Harness 終了"
log "=========================================="
