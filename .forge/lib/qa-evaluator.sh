#!/bin/bash
# qa-evaluator.sh — 独立 QA Evaluator サブシステム
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   AGENTS_DIR, TEMPLATES_DIR, SCHEMAS_DIR, DEV_LOG_DIR, TASK_STACK, WORK_DIR
#   QA_EVALUATOR_ENABLED, QA_EVALUATOR_MODEL, QA_EVALUATOR_TIMEOUT, QA_MAX_FAILURES

# ===== QA Evaluator 実行 =====
# success path 上のブロッキングゲート。
# verdict=pass → return 0, verdict=fail → return 1
# graceful degradation: エラー時は return 0 (pass)
run_qa_evaluator() {
  local task_id="$1"
  local task_dir="$2"
  local task_json="$3"

  # 無効なら即 pass
  if [ "${QA_EVALUATOR_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # エージェント/テンプレート不在 → graceful pass
  if [ ! -f "${AGENTS_DIR}/qa-evaluator.md" ] || \
     [ ! -f "${TEMPLATES_DIR}/qa-evaluator-prompt.md" ]; then
    log "  ⚠ QA Evaluator: エージェント/テンプレート不在 — スキップ (pass)"
    return 0
  fi

  # QA 失敗カウントチェック（無限ループ防止）
  local qa_fail_count
  qa_fail_count=$(jq --arg id "$task_id" \
    '.tasks[] | select(.task_id == $id) | .qa_fail_count // 0' "$TASK_STACK" 2>/dev/null || echo 0)
  if [ "$qa_fail_count" -ge "${QA_MAX_FAILURES:-2}" ]; then
    log "  ⚠ QA Evaluator: 失敗上限到達（${qa_fail_count}/${QA_MAX_FAILURES}）— auto-pass"
    return 0
  fi

  log "  QA Evaluator 起動: task=${task_id}"

  # 実装 diff を収集
  local impl_diff="（diff 取得不可）"
  if [ -n "${WORK_DIR:-}" ] && git -C "$WORK_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    impl_diff=$(git -C "$WORK_DIR" diff HEAD~1 2>/dev/null | head -500 || echo "（diff 取得不可）")
    [ -z "$impl_diff" ] && impl_diff=$(git -C "$WORK_DIR" diff 2>/dev/null | head -500 || echo "（差分なし）")
  fi

  # テスト出力を収集
  local test_output="（テスト出力なし）"
  if [ -f "${task_dir}/test-output.txt" ]; then
    test_output=$(tail -100 "${task_dir}/test-output.txt")
  fi

  # required_behaviors を抽出
  local required_behaviors
  required_behaviors=$(echo "$task_json" | jq_safe -r '.required_behaviors // [] | to_entries | map("- \(.value)") | join("\n")' 2>/dev/null)
  [ -z "$required_behaviors" ] && required_behaviors="（required_behaviors 未定義）"

  # キャリブレーション事例を取得
  local cal_examples=""
  if type get_calibration_examples &>/dev/null; then
    cal_examples=$(get_calibration_examples "qa-evaluator" 3)
  fi
  [ -z "$cal_examples" ] && cal_examples="（キャリブレーションデータなし — デフォルト判定基準を使用）"

  # プロンプト生成
  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/qa-evaluator-prompt.md" \
    "TASK_ID"              "$task_id" \
    "TASK_JSON"            "$task_json" \
    "IMPL_DIFF"            "$impl_diff" \
    "TEST_OUTPUT"          "$test_output" \
    "REQUIRED_BEHAVIORS"   "$required_behaviors" \
    "CALIBRATION_EXAMPLES" "$cal_examples"
  )

  local ts
  ts=$(now_ts)
  local output="${task_dir}/qa-evaluator-result.json"
  local log_file="${DEV_LOG_DIR}/qa-eval-${task_id}-${ts}.log"

  # 実行（別セッション — Ralph 原則: fresh context）
  export _RC_CONTEXT_STRATEGY="${CONTEXT_STRATEGY_QA_EVALUATOR:-reset}"
  metrics_start
  if ! run_claude "${QA_EVALUATOR_MODEL:-opus}" "${AGENTS_DIR}/qa-evaluator.md" \
    "$prompt" "$output" "$log_file" "WebSearch,WebFetch,Bash" "${QA_EVALUATOR_TIMEOUT:-300}" "" \
    "${SCHEMAS_DIR}/qa-evaluator.schema.json"; then
    metrics_record "qa-evaluator-${task_id}" "false"
    log "  ⚠ QA Evaluator 実行エラー — スキップ (pass)"
    return 0
  fi
  metrics_record "qa-evaluator-${task_id}" "true"

  # JSON 検証
  if ! validate_json "$output" "qa-evaluator-${task_id}"; then
    log "  ⚠ QA Evaluator JSON検証失敗 — スキップ (pass)"
    return 0
  fi

  # task-stack.json に QA 結果を追記
  if [ -f "$TASK_STACK" ] && [ -f "$output" ]; then
    local qa_result
    qa_result=$(cat "$output" 2>/dev/null)
    if [ -n "$qa_result" ] && jq empty <<< "$qa_result" 2>/dev/null; then
      jq --arg id "$task_id" --argjson qa "$qa_result" '
        .tasks |= map(
          if .task_id == $id then
            .qa_evaluator_result = $qa
          else . end
        )
      ' "$TASK_STACK" > "${TASK_STACK}.tmp" 2>/dev/null && mv "${TASK_STACK}.tmp" "$TASK_STACK"
    fi
  fi

  # verdict 抽出
  local verdict
  verdict=$(jq_safe -r '.verdict // "pass"' "$output" 2>/dev/null)

  log "  QA Evaluator 完了: verdict=${verdict}"

  if [ "$verdict" = "pass" ]; then
    return 0
  fi

  # verdict=fail: QA feedback をファイルに保存（次回 Implementer に注入）
  local feedback
  feedback=$(jq_safe -r '.feedback // ""' "$output" 2>/dev/null)
  local issues
  issues=$(jq_safe -r '.issues[]? | "- [\(.severity // "medium")] \(.description // .issue // "")"' "$output" 2>/dev/null)
  echo "${feedback}

指摘事項:
${issues}" > "${task_dir}/qa-evaluator-feedback.txt"

  # qa_fail_count をインクリメント
  local new_qa_fail_count=$((qa_fail_count + 1))
  local _lock_dir
  _lock_dir="$(dirname "${TASK_STACK}")/.lock/task-stack.lock"
  acquire_lock "$_lock_dir" 2>/dev/null || true
  jq --arg id "$task_id" --argjson c "$new_qa_fail_count" '
    .tasks |= map(
      if .task_id == $id then
        .qa_fail_count = $c
      else . end
    )
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" 2>/dev/null && mv "${TASK_STACK}.tmp" "$TASK_STACK"
  release_lock "$_lock_dir" 2>/dev/null || true

  record_task_event "$task_id" "qa_evaluator_fail" "{\"qa_fail_count\":${new_qa_fail_count}}"

  return 1
}
