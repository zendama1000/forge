#!/bin/bash
# evidence-da.sh — Evidence-Driven DA サブシステム
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   AGENTS_DIR, TEMPLATES_DIR, DEV_LOG_DIR, TASK_STACK
#   EVIDENCE_DA_ENABLED, EVIDENCE_DA_MODEL, EVIDENCE_DA_TIMEOUT, EVIDENCE_DA_FAIL_THRESHOLD

# ===== Evidence-Driven DA 実行 =====
# advisory（助言的）— 常に return 0。開発ループをブロックしない。
run_evidence_da() {
  local task_id="$1"
  local task_dir="$2"
  local trigger_reason="${3:-unknown}"
  local test_failures="${4:-}"
  local mutation_results="${5:-}"
  local regression_results="${6:-}"

  # 無効なら即 return
  if [ "${EVIDENCE_DA_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # エージェント/テンプレート不在でも即 return（graceful degradation）
  if [ ! -f "${AGENTS_DIR}/evidence-da.md" ] || [ ! -f "${TEMPLATES_DIR}/dev-da-prompt.md" ]; then
    log "  ⚠ Evidence-DA: エージェント/テンプレート不在 — スキップ"
    return 0
  fi

  log "  Evidence-DA 起動: task=${task_id} trigger=${trigger_reason}"

  # タスク定義を取得
  local task_definition="（タスク定義取得不可）"
  if [ -f "$TASK_STACK" ]; then
    task_definition=$(jq --arg id "$task_id" '.tasks[]? | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null || echo "（タスク定義取得不可）")
  fi

  # プロンプト生成
  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/dev-da-prompt.md" \
    "TASK_ID"              "$task_id" \
    "TRIGGER_REASON"       "$trigger_reason" \
    "TEST_FAILURES"        "${test_failures:-（なし）}" \
    "MUTATION_RESULTS"     "${mutation_results:-（なし）}" \
    "REGRESSION_RESULTS"   "${regression_results:-（なし）}" \
    "TASK_DEFINITION"      "$task_definition"
  )

  local ts
  ts=$(now_ts)
  local output="${task_dir}/evidence-da-result.json"
  local log_file="${DEV_LOG_DIR}/evidence-da-${task_id}-${ts}.log"

  # 実行
  metrics_start
  if ! run_claude "${EVIDENCE_DA_MODEL:-sonnet}" "${AGENTS_DIR}/evidence-da.md" \
    "$prompt" "$output" "$log_file" "WebSearch,WebFetch" "${EVIDENCE_DA_TIMEOUT:-300}" "$WORK_DIR" \
    "${SCHEMAS_DIR}/evidence-da.schema.json"; then
    metrics_record "evidence-da-${task_id}" "false"
    log "  ⚠ Evidence-DA 実行エラー — スキップ（advisory）"
    return 0
  fi
  metrics_record "evidence-da-${task_id}" "true"

  # JSON 検証
  if ! validate_json "$output" "evidence-da-${task_id}"; then
    log "  ⚠ Evidence-DA JSON検証失敗 — スキップ（advisory）"
    return 0
  fi

  # task-stack.json に結果を追記
  if [ -f "$TASK_STACK" ] && [ -f "$output" ]; then
    local da_result
    da_result=$(cat "$output" 2>/dev/null)
    if [ -n "$da_result" ]; then
      jq --arg id "$task_id" --argjson da "$da_result" '
        .tasks |= map(
          if .task_id == $id then
            .evidence_da_result = $da
          else . end
        )
      ' "$TASK_STACK" > "${TASK_STACK}.tmp" 2>/dev/null && mv "${TASK_STACK}.tmp" "$TASK_STACK"
    fi
  fi

  # recommendation 抽出
  local recommendation
  recommendation=$(jq_safe -r '.recommendation // "continue"' "$output" 2>/dev/null)

  log "  Evidence-DA 完了: recommendation=${recommendation}"

  # escalate の場合のみ人間通知
  if [ "$recommendation" = "escalate" ]; then
    local escalation_reason
    escalation_reason=$(jq_safe -r '.escalation_reason // "詳細不明"' "$output" 2>/dev/null)
    notify_human "warning" "Evidence-DA: escalate推奨 (task=${task_id})" \
      "理由: ${escalation_reason}\n詳細: ${output}"
  fi

  return 0
}
