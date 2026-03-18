#!/bin/bash
# generate-tasks.sh — Phase 1.5: Implementation Criteria → Task Stack 変換
# 使い方: ./generate-tasks.sh <implementation-criteria.json> [output-path]
#
# implementation-criteria.json: Phase 1 の Research System が生成した成功条件
# output-path: 生成する task-stack.json のパス（デフォルト: .forge/state/task-stack.json）
#
# 設計書: forge-architecture-v3.2.md §4.5

set -euo pipefail

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"

# ===== dev-phase テストスクリプト生成 =====
# task-stack.json の .phases[].exit_criteria[type=auto] から
# .forge/state/phase-tests/{phase_id}.sh を機械的に生成する
generate_phase_test_scripts() {
  local task_stack="$1"
  local output_dir=".forge/state/phase-tests"

  # phases 配列が存在するかチェック
  local phase_count
  phase_count=$(jq '.phases // [] | length' "$task_stack" 2>/dev/null || echo 0)
  if [ "$phase_count" -eq 0 ]; then
    log "  phases 配列なし — テストスクリプト生成をスキップ"
    return 0
  fi

  mkdir -p "$output_dir"

  # phase 一覧を抽出
  local phases
  phases=$(jq_safe -r '.phases[].id' "$task_stack" 2>/dev/null)

  for phase_id in $phases; do
    local script="${output_dir}/${phase_id}.sh"
    {
      echo "#!/bin/bash"
      echo "# Auto-generated exit_criteria tests for dev-phase: ${phase_id}"
      echo "# Generated at: $(date -Iseconds)"
      echo "set -e"
      echo ""
    } > "$script"

    # exit_criteria の type=auto を抽出してテストコマンドに変換
    jq_safe -r --arg pid "$phase_id" '
      .phases[] | select(.id == $pid) |
      .exit_criteria[]? | select(.type == "auto") |
      "echo \"  Testing: \(.description)\" && \(.command) && echo \"  ✓ PASS\" || { echo \"  ✗ FAIL: \(.description)\"; exit 1; }"
    ' "$task_stack" >> "$script"

    chmod +x "$script"
    log "  テストスクリプト生成: ${script}"
  done
}

# ===== コマンドサニタイズ =====
sanitize_task_commands() {
  local task_file="$1"
  local fixes=0

  # (1) bare ツール名に npx プレフィックス付与
  #     vitest, jest, tsc, eslint, prettier, playwright を検出
  #     既に npx/pnpm/yarn/bunx で始まる場合はスキップ
  local patched
  patched=$(jq '
    def npx_prefix:
      if test("^\\s*(npx|pnpm|yarn|bunx|node_modules)") then .
      elif test("^\\s*(vitest|jest|tsc|eslint|prettier|playwright)\\b") then
        gsub("^(?<ws>\\s*)(?<cmd>vitest|jest|tsc|eslint|prettier|playwright)"; "\(.ws)npx \(.cmd)")
      else . end;

    .tasks |= [.[] |
      if .validation.layer_1.command then
        .validation.layer_1.command |= npx_prefix
      else . end
    ] |
    if .phases then
      .phases |= [.[] |
        if .exit_criteria then
          .exit_criteria |= [.[] |
            if .command then .command |= npx_prefix else . end
          ]
        else . end
      ]
    else . end
  ' "$task_file") || { log "⚠ npx プレフィックス適用失敗"; return 0; }

  # 変更があったか確認
  local orig_cmds new_cmds
  orig_cmds=$(jq -r '[.tasks[].validation.layer_1.command // empty] | join("\n")' "$task_file")
  new_cmds=$(echo "$patched" | jq -r '[.tasks[].validation.layer_1.command // empty] | join("\n")')
  if [ "$orig_cmds" != "$new_cmds" ]; then
    fixes=$((fixes + 1))
    log "  ✓ bare ツール名に npx プレフィックスを付与"
  fi

  echo "$patched" > "${task_file}.tmp" && mv "${task_file}.tmp" "$task_file"

  # (2) {{PLACEHOLDER}} 検出 → エラー
  local placeholders
  placeholders=$(jq -r '
    [.tasks[].validation.layer_1.command // empty |
     scan("\\{\\{[A-Z_]+\\}\\}")
    ] | flatten | unique | join(", ")
  ' "$task_file")

  if [ -n "$placeholders" ]; then
    log "✗ 未置換プレースホルダ検出: ${placeholders}"
    log "  タスクのバリデーションコマンドに {{PLACEHOLDER}} が残存しています"
    exit 1
  fi

  # (3) Windows パス正規化: testPathPattern 内のパスをファイル名のみに変換
  jq '
    def normalize_test_path:
      gsub("--testPathPattern\\s+[^\\s]*\\/(?<leaf>[^\\s/]+)"; "--testPathPattern \(.leaf)");

    .tasks |= [.[] |
      if .validation.layer_1.command then
        .validation.layer_1.command |= normalize_test_path
      else . end
    ]
  ' "$task_file" > "${task_file}.tmp" && mv "${task_file}.tmp" "$task_file"

  if [ "$fixes" -gt 0 ]; then
    log "  コマンドサニタイズ: ${fixes} 件の修正を適用"
  else
    log "  コマンドサニタイズ: 修正不要"
  fi
}

# ===== コマンド依存チェック =====
check_dependencies claude jq

# ===== パス定数 =====
AGENTS_DIR=".claude/agents"
TEMPLATES_DIR=".forge/templates"
SCHEMAS_DIR=".forge/schemas"
ERRORS_FILE=".forge/state/errors.jsonl"

# common.sh が使う変数
RESEARCH_DIR="phase1.5-$(date +%Y%m%d-%H%M%S)"
json_fail_count=0

# ===== 引数チェック =====
if [ $# -lt 1 ]; then
  echo "使い方: $0 <implementation-criteria.json> [output-path] [working-directory]" >&2
  exit 1
fi

CRITERIA_FILE="$1"
OUTPUT_PATH="${2:-.forge/state/task-stack.json}"
WORK_DIR="${3:-$PROJECT_ROOT}"

if [ ! -f "$CRITERIA_FILE" ]; then
  echo -e "${RED}[ERROR] implementation-criteria.json が見つかりません: ${CRITERIA_FILE}${NC}" >&2
  exit 1
fi

# ===== エージェント・テンプレート存在チェック =====
if [ ! -f "${AGENTS_DIR}/task-planner.md" ]; then
  echo -e "${RED}[ERROR] エージェント定義が見つかりません: ${AGENTS_DIR}/task-planner.md${NC}" >&2
  exit 1
fi
if [ ! -f "${TEMPLATES_DIR}/task-planning-prompt.md" ]; then
  echo -e "${RED}[ERROR] テンプレートが見つかりません: ${TEMPLATES_DIR}/task-planning-prompt.md${NC}" >&2
  exit 1
fi

# ===== ディレクトリ準備 =====
mkdir -p "$(dirname "$OUTPUT_PATH")" ".forge/logs/phase1.5" ".forge/state"

# ===== 設定読み込み =====
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"
if [ -f "$DEV_CONFIG" ]; then
  PLANNER_MODEL=$(jq_safe -r '.task_planner.model // "opus"' "$DEV_CONFIG")
  PLANNER_TIMEOUT=$(jq_safe -r '.task_planner.timeout_sec // 600' "$DEV_CONFIG")
else
  log "⚠ development.json が見つかりません。デフォルト値を使用"
  PLANNER_MODEL="opus"
  PLANNER_TIMEOUT=600
fi

CLAUDE_TIMEOUT="$PLANNER_TIMEOUT"

# SERVER_URL 取得（common.sh の get_server_url を使用）
SERVER_URL=$(get_server_url "$DEV_CONFIG")

# ===== エラーファイル初期化 =====
if [ ! -f "$ERRORS_FILE" ]; then
  touch "$ERRORS_FILE"
fi

# ===== criteria 内容を抽出 =====
log "=========================================="
log "Phase 1.5: タスクスタック生成 開始"
log "criteria: ${CRITERIA_FILE}"
log "出力先:   ${OUTPUT_PATH}"
log "作業DIR:  ${WORK_DIR}"
log "=========================================="

CRITERIA_CONTENT=$(cat "$CRITERIA_FILE")
THEME=$(jq_safe -r '.theme // "不明"' "$CRITERIA_FILE" 2>/dev/null || echo "不明")
ASSUMPTIONS=$(jq_safe -r '.assumptions // [] | join("\n- ")' "$CRITERIA_FILE" 2>/dev/null || echo "（なし）")

# L1 デフォルトタイムアウト値
L1_DEFAULT_TIMEOUT_VAL="200"
if [ -f "$DEV_CONFIG" ]; then
  L1_DEFAULT_TIMEOUT_VAL=$(jq_safe -r '.layer_1_test.default_timeout_sec // 200' "$DEV_CONFIG")
fi

# L2 criteria 抽出
L2_CRITERIA_CONTENT="(layer_2_criteria なし)"
L2_CRITERIA_COUNT=$(jq '.layer_2_criteria // [] | length' "$CRITERIA_FILE" 2>/dev/null || echo 0)
if [ "$L2_CRITERIA_COUNT" -gt 0 ]; then
  L2_CRITERIA_CONTENT=$(jq -c '.layer_2_criteria' "$CRITERIA_FILE")
fi
L2_DEFAULT_TIMEOUT_VAL="120"
if [ -f "$DEV_CONFIG" ]; then
  L2_DEFAULT_TIMEOUT_VAL=$(jq_safe -r '.layer_2.default_timeout_sec // 120' "$DEV_CONFIG")
fi

# L3 criteria 抽出
L3_CRITERIA_CONTENT="(layer_3_criteria なし)"
L3_CRITERIA_COUNT=$(jq '.layer_3_criteria // [] | length' "$CRITERIA_FILE" 2>/dev/null || echo 0)
if [ "$L3_CRITERIA_COUNT" -gt 0 ]; then
  L3_CRITERIA_CONTENT=$(jq -c '.layer_3_criteria' "$CRITERIA_FILE")
fi

# ===== プロンプト生成 =====
PROMPT=$(render_template "${TEMPLATES_DIR}/task-planning-prompt.md" \
  "CRITERIA_CONTENT"   "$CRITERIA_CONTENT" \
  "THEME"              "$THEME" \
  "ASSUMPTIONS"        "$ASSUMPTIONS" \
  "CRITERIA_PATH"      "$CRITERIA_FILE" \
  "WORK_DIR"           "$WORK_DIR" \
  "L1_DEFAULT_TIMEOUT" "$L1_DEFAULT_TIMEOUT_VAL" \
  "SERVER_URL"         "$SERVER_URL" \
  "L2_CRITERIA"        "$L2_CRITERIA_CONTENT" \
  "L2_DEFAULT_TIMEOUT" "$L2_DEFAULT_TIMEOUT_VAL" \
  "L3_CRITERIA"        "$L3_CRITERIA_CONTENT"
)

# ===== Claude 実行（リトライ付き） =====
MAX_PLANNER_RETRIES=3
planner_attempt=0

while [ "$planner_attempt" -lt "$MAX_PLANNER_RETRIES" ]; do
  planner_attempt=$((planner_attempt + 1))
  TS=$(now_ts)
  OUTPUT_FILE=".forge/logs/phase1.5/planning-output-${TS}.json"
  LOG_FILE=".forge/logs/phase1.5/planning-${TS}.log"

  log "Task Planner 実行中...（試行 ${planner_attempt}/${MAX_PLANNER_RETRIES}）"
  # Task Planner はプロンプト内の criteria だけを読んで JSON を stdout に出力する。
  # Write/Edit 系を禁止しないと Opus がファイルに直接書き込もうとして失敗する。
  # Task を禁止しないと Haiku サブエージェントを起動してタイムアウトする。
  metrics_start
  if ! run_claude "$PLANNER_MODEL" "${AGENTS_DIR}/task-planner.md" \
    "$PROMPT" "$OUTPUT_FILE" "$LOG_FILE" "Write,Edit,MultiEdit,NotebookEdit,Task" "$PLANNER_TIMEOUT" "" \
    "${SCHEMAS_DIR}/task-stack.schema.json"; then
    metrics_record "task-planner" "false"
    log "✗ Task Planner 実行エラー（試行 ${planner_attempt}）"
    continue
  fi
  metrics_record "task-planner" "true"

  if validate_json "$OUTPUT_FILE" "task-planner"; then
    break
  fi

  # フォールバック: Claude が Write ツールで OUTPUT_PATH に直接書き込んだ場合を検出
  if check_direct_write_fallback "$OUTPUT_PATH" "task-planner"; then
    cp "$OUTPUT_PATH" "$OUTPUT_FILE"
    break
  fi

  log "✗ JSON検証失敗（試行 ${planner_attempt}/${MAX_PLANNER_RETRIES}）"
done

if [ "$planner_attempt" -ge "$MAX_PLANNER_RETRIES" ]; then
  if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
    # 最終フォールバック: OUTPUT_PATH に直接書き込みがあれば利用
    if check_direct_write_fallback "$OUTPUT_PATH" "task-planner-final"; then
      cp "$OUTPUT_PATH" "$OUTPUT_FILE"
    else
      log "✗ Task Planner が${MAX_PLANNER_RETRIES}回失敗。中断"
      exit 1
    fi
  fi
fi

# ===== L1 criteria 網羅チェック（リトライゲート） =====
# criteria の全 L1 ID がタスクの l1_criteria_refs でカバーされているか検証
# 欠落がある場合、欠落情報をプロンプトに追記してリトライする
validate_l1_coverage() {
  local task_file="$1"
  local criteria_file="$2"

  # criteria から全 L1 ID を抽出
  local all_l1_ids
  all_l1_ids=$(jq -r '[.layer_1_criteria[].id] | sort | .[]' "$criteria_file" 2>/dev/null)
  if [ -z "$all_l1_ids" ]; then
    log "⚠ criteria に layer_1_criteria がありません — L1 網羅チェックをスキップ"
    return 0
  fi

  # タスクから参照されている全 L1 ID を抽出
  local covered_l1_ids
  covered_l1_ids=$(jq -r '[.tasks[].l1_criteria_refs // [] | .[]] | unique | sort | .[]' "$task_file" 2>/dev/null)

  # 差分を計算
  local missing_ids=""
  for l1_id in $all_l1_ids; do
    if ! echo "$covered_l1_ids" | grep -qx "$l1_id"; then
      missing_ids="${missing_ids}${missing_ids:+, }${l1_id}"
    fi
  done

  if [ -n "$missing_ids" ]; then
    log "✗ L1 criteria 網羅チェック失敗: 未カバー = ${missing_ids}"
    echo "$missing_ids"
    return 1
  fi

  local total_l1
  total_l1=$(echo "$all_l1_ids" | wc -l | tr -d ' ')
  log "✓ L1 criteria 網羅チェック通過: ${total_l1} 件全てカバー済み"
  return 0
}

# ===== スキーマ検証 =====
log "スキーマ検証中..."

# .tasks 配列が存在するか
TASKS_COUNT=$(jq '.tasks | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
if [ "$TASKS_COUNT" -eq 0 ]; then
  log "✗ スキーマ検証失敗: .tasks 配列が空または存在しません"
  exit 1
fi

# 各タスクに必須フィールドがあるか
INVALID_TASKS=$(jq_safe -r '
  [.tasks[] |
    select(
      (.task_id | length) == 0 or
      (.description | length) == 0 or
      (.validation.layer_1 == null)
    ) |
    .task_id // "(task_id なし)"
  ] | join(", ")
' "$OUTPUT_FILE" 2>/dev/null)

if [ -n "$INVALID_TASKS" ]; then
  log "✗ スキーマ検証失敗: 必須フィールド不足のタスク: ${INVALID_TASKS}"
  exit 1
fi

# depends_on の参照先が存在するか
ORPHAN_DEPS=$(jq_safe -r '
  . as $root |
  [.tasks[] | .depends_on // [] | .[] |
    . as $dep |
    if ([$root.tasks[] | .task_id] | index($dep)) == null then $dep else empty end
  ] | unique | join(", ")
' "$OUTPUT_FILE" 2>/dev/null)

if [ -n "$ORPHAN_DEPS" ]; then
  log "⚠ 存在しない depends_on 参照: ${ORPHAN_DEPS}（続行しますが確認してください）"
fi

# dev_phase_id 存在チェック（警告のみ、blocking しない）
MISSING_PHASE_ID=$(jq_safe -r '
  [.tasks[] | select(.dev_phase_id == null or .dev_phase_id == "") | .task_id] | join(", ")
' "$OUTPUT_FILE" 2>/dev/null)

if [ -n "$MISSING_PHASE_ID" ]; then
  log "⚠ dev_phase_id が未設定のタスク: ${MISSING_PHASE_ID}（実行時は mvp として扱います）"
fi

# 低タイムアウト警告
LOW_TIMEOUT_TASKS=$(jq_safe -r '
  [.tasks[] |
    select(.task_type == "implementation") |
    select(.validation.layer_1.timeout_sec != null) |
    select(.validation.layer_1.timeout_sec < 60) |
    "\(.task_id)(timeout=\(.validation.layer_1.timeout_sec)s)"
  ] | join(", ")
' "$OUTPUT_FILE" 2>/dev/null)

if [ -n "$LOW_TIMEOUT_TASKS" ]; then
  log "⚠ 低タイムアウト警告: ${LOW_TIMEOUT_TASKS}（テストフレームワーク実行には60秒以上を推奨）"
fi


# implementation タスクの test -f 単体禁止チェック（機械ゲート）
# implementation タスクにテストフレームワークなしの validation が入っている場合は exit 1 でブロックする
TEST_F_ONLY_TASKS=$(jq_safe -r '
  [.tasks[] |
    select(.task_type == "implementation") |
    select(
      (.validation.layer_1.command // "") |
      test("(vitest|jest|pytest|playwright|tsc|mocha|ava|tap)\\b") | not
    ) |
    select(
      (.validation.layer_1.command // "") |
      test("test\\s+-[fd]|bash\\s+-c")
    ) |
    .task_id
  ] | join(", ")
' "$OUTPUT_FILE" 2>/dev/null)

if [ -n "$TEST_F_ONLY_TASKS" ]; then
  log "✗ implementation タスクに test -f 単体の validation を検出: ${TEST_F_ONLY_TASKS}"
  log "  implementation タスクにはテストフレームワーク実行コマンド（vitest/jest/pytest 等）が必須です"
  exit 1
fi
log "  ✓ test -f 単体チェック: 問題なし"
# L2 テスト定義の妥当性チェック
if [ "$L2_CRITERIA_COUNT" -gt 0 ]; then
  L2_TASKS_COUNT=$(jq_safe '[.tasks[] | select(.validation.layer_2.command != null)] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  if [ "$L2_TASKS_COUNT" -eq 0 ]; then
    log "⚠ layer_2_criteria が ${L2_CRITERIA_COUNT} 件あるが、Layer 2 テスト定義タスクが 0 件"
  else
    log "✓ Layer 2 テスト定義: ${L2_TASKS_COUNT} タスク"
  fi
fi

# L3 テスト定義の妥当性チェック
if [ "$L3_CRITERIA_COUNT" -gt 0 ]; then
  L3_TASKS_COUNT=$(jq_safe '[.tasks[] | select(.validation.layer_3 != null) | select(.validation.layer_3 | length > 0)] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  if [ "$L3_TASKS_COUNT" -eq 0 ]; then
    log "⚠ layer_3_criteria が ${L3_CRITERIA_COUNT} 件あるが、Layer 3 テスト定義タスクが 0 件"
  else
    log "✓ Layer 3 テスト定義: ${L3_TASKS_COUNT} タスク"
  fi

  # L3 strategy バリデーション: 不正な strategy 値を検出
  INVALID_L3_STRATEGIES=$(jq_safe -r '
    [.tasks[].validation.layer_3? // [] | .[] |
     select(.strategy | test("^(structural|api_e2e|llm_judge|cli_flow|context_injection)$") | not) |
     "\(.id // "unknown")(\(.strategy // "null"))"
    ] | join(", ")
  ' "$OUTPUT_FILE" 2>/dev/null)

  if [ -n "$INVALID_L3_STRATEGIES" ]; then
    log "⚠ 不正な L3 strategy 検出: ${INVALID_L3_STRATEGIES}"
  fi

  # L3 llm_judge テストに judge_criteria が定義されているか
  MISSING_JUDGE_CRITERIA=$(jq_safe -r '
    [.tasks[].validation.layer_3? // [] | .[] |
     select(.strategy == "llm_judge") |
     select(.definition.judge_criteria == null or (.definition.judge_criteria | length == 0)) |
     .id // "unknown"
    ] | join(", ")
  ' "$OUTPUT_FILE" 2>/dev/null)

  if [ -n "$MISSING_JUDGE_CRITERIA" ]; then
    log "⚠ llm_judge L3 テストに judge_criteria が未定義: ${MISSING_JUDGE_CRITERIA}"
  fi
fi

# スコープカバレッジ検証
COVERAGE_COMPLETE=$(jq_safe -r '.scope_coverage.coverage_complete // "null"' "$OUTPUT_FILE" 2>/dev/null)
if [ "$COVERAGE_COMPLETE" = "false" ]; then
  UNMAPPED=$(jq_safe -r '[.scope_coverage.theme_elements[]? | select(.mapped_tasks | length == 0) | .element] | join(", ")' "$OUTPUT_FILE" 2>/dev/null)
  log "⚠ スコープカバレッジ不完全: 未マッピング要素: ${UNMAPPED}"
  notify_human "warning" "テーマ要素の一部がタスクにマッピングされていません" "未マッピング: ${UNMAPPED}"
fi

# 除外要素の通知
EXCLUDED_COUNT=$(jq '[.excluded_elements // [] | .[]] | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
if [ "$EXCLUDED_COUNT" -gt 0 ]; then
  EXCLUDED_SUMMARY=$(jq_safe -r '[.excluded_elements[] | "- \(.element): \(.reason)"] | join("\n")' "$OUTPUT_FILE" 2>/dev/null)

  # 監査証跡ファイル
  jq -c '.excluded_elements // []' "$OUTPUT_FILE" > ".forge/state/excluded-elements.json"

  log "=========================================="
  log "除外要素（${EXCLUDED_COUNT}件）:"
  log "${EXCLUDED_SUMMARY}"
  log "=========================================="

  notify_human "info" "タスク計画で${EXCLUDED_COUNT}件の要素を除外" "$EXCLUDED_SUMMARY"
fi

# ===== L1 criteria 網羅チェック =====
MISSING_L1=""
if ! MISSING_L1=$(validate_l1_coverage "$OUTPUT_FILE" "$CRITERIA_FILE"); then
  log "L1 criteria 未カバー検出 — 補強プロンプトで再生成を試みます"

  # 欠落した L1 の詳細情報を抽出
  MISSING_L1_DETAILS=""
  for l1_id in $(echo "$MISSING_L1" | tr ', ' '\n' | grep -v '^$'); do
    detail=$(jq -r --arg id "$l1_id" '.layer_1_criteria[] | select(.id == $id) | "- \(.id): \(.description)"' "$CRITERIA_FILE" 2>/dev/null)
    MISSING_L1_DETAILS="${MISSING_L1_DETAILS}${detail}\n"
  done

  # 補強プロンプトを追加して再実行
  RETRY_SUPPLEMENT="

## 重要: 前回の生成で以下の L1 criteria がタスクにマッピングされていませんでした。
## これらを必ず含むタスクを生成してください。各タスクの l1_criteria_refs に対応 ID を記録してください。

未カバーの L1 criteria:
$(echo -e "$MISSING_L1_DETAILS")

前回の生成結果（参考・修正元として使用可）:
$(cat "$OUTPUT_FILE")
"
  AUGMENTED_PROMPT="${PROMPT}${RETRY_SUPPLEMENT}"

  log "L1 補強リトライ実行中..."
  TS=$(now_ts)
  RETRY_OUTPUT=".forge/logs/phase1.5/planning-output-l1retry-${TS}.json"
  RETRY_LOG=".forge/logs/phase1.5/planning-l1retry-${TS}.log"

  metrics_start
  if run_claude "$PLANNER_MODEL" "${AGENTS_DIR}/task-planner.md" \
    "$AUGMENTED_PROMPT" "$RETRY_OUTPUT" "$RETRY_LOG" "Write,Edit,MultiEdit,NotebookEdit,Task" "$PLANNER_TIMEOUT" "" \
    "${SCHEMAS_DIR}/task-stack.schema.json"; then
    metrics_record "task-planner-l1retry" "true"

    if validate_json "$RETRY_OUTPUT" "task-planner-l1retry" || \
       check_direct_write_fallback "$OUTPUT_PATH" "task-planner-l1retry"; then
      [ -f "$OUTPUT_PATH" ] && [ ! -f "$RETRY_OUTPUT" ] && cp "$OUTPUT_PATH" "$RETRY_OUTPUT"

      # 再チェック
      if validate_l1_coverage "$RETRY_OUTPUT" "$CRITERIA_FILE" > /dev/null 2>&1; then
        OUTPUT_FILE="$RETRY_OUTPUT"
        TASKS_COUNT=$(jq '.tasks | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
        log "✓ L1 補強リトライ成功: 全 L1 criteria カバー済み"
      else
        log "⚠ L1 補強リトライ後も未カバーあり — 現状の結果で続行（手動確認推奨）"
        notify_human "warning" "L1 criteria の一部がタスクにマッピングされていません" "未カバー: ${MISSING_L1}"
      fi
    fi
  else
    metrics_record "task-planner-l1retry" "false"
    log "⚠ L1 補強リトライ失敗 — 現状の結果で続行"
    notify_human "warning" "L1 criteria の一部がタスクにマッピングされていません" "未カバー: ${MISSING_L1}"
  fi
fi

# ===== phases 上書き: criteria の phases を機械的に引き継ぐ =====
# Task Planner が独自の exit_criteria を生成する場合があるため、
# criteria の phases（正しい SERVER_URL を含む）を強制的に上書きする。
CRITERIA_PHASES=$(jq -c '.phases // []' "$CRITERIA_FILE" 2>/dev/null || echo "[]")
CRITERIA_PHASES_COUNT=$(echo "$CRITERIA_PHASES" | jq 'length' 2>/dev/null || echo 0)

if [ "$CRITERIA_PHASES_COUNT" -gt 0 ]; then
  jq --argjson phases "$CRITERIA_PHASES" '.phases = $phases' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" \
    && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
  log "✓ phases を criteria から機械的に引き継ぎ（${CRITERIA_PHASES_COUNT} phases）"
else
  log "⚠ criteria に phases がありません。Task Planner 出力をそのまま使用"
fi

# ===== コマンドサニタイズ =====
log "コマンドサニタイズ中..."
sanitize_task_commands "$OUTPUT_FILE"

# ===== 出力 =====
cp "$OUTPUT_FILE" "$OUTPUT_PATH"
log "✓ task-stack.json 生成完了: ${OUTPUT_PATH}"
log "  タスク数: ${TASKS_COUNT}"

# タスク数超過警告
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
if [ -f "$CIRCUIT_BREAKER_CONFIG" ]; then
  MAX_TOTAL_TASKS=$(jq_safe -r '.development_limits.max_total_tasks // 50' "$CIRCUIT_BREAKER_CONFIG")
  if [ "$TASKS_COUNT" -gt "$MAX_TOTAL_TASKS" ]; then
    log "⚠ タスク数(${TASKS_COUNT})が circuit-breaker 上限(${MAX_TOTAL_TASKS})を超過"
    log "  Ralph Loop が途中停止する可能性があります"
  fi
fi

# ===== 後処理: dev-phase テストスクリプト生成 =====
log "dev-phase テストスクリプト生成中..."
generate_phase_test_scripts "$OUTPUT_PATH"

# ===== Locked Decision Assertions をフェーズテストに注入 =====
_RC=".forge/state/research-config.json"
if [ -f "$_RC" ]; then
  _has=$(jq '[.locked_decisions//[]|.[].assertions//[]|length]|add//0' "$_RC" 2>/dev/null)
  if [ "${_has:-0}" -gt 0 ]; then
    for _script in .forge/state/phase-tests/*.sh; do
      [ -f "$_script" ] || continue
      cat >> "$_script" <<'ASSERT_EOF'

# === Locked Decision Assertions (auto-injected) ===
echo "  Locked Decision Assertions 検証中..."
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh" 2>/dev/null || true
if type validate_locked_assertions &>/dev/null; then
  _rpt=$(validate_locked_assertions ".forge/state/research-config.json" "${WORK_DIR:-.}" "phase-test")
  if [ $? -ne 0 ]; then echo "  ✗ FAIL: Assertions 違反"; echo "$_rpt"; exit 1; fi
  echo "  ✓ PASS: Locked Decision Assertions"
fi
ASSERT_EOF
    done
    log "✓ Locked Decision Assertions をフェーズテストに注入"
  fi
fi

log "=========================================="