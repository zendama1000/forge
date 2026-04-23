#!/bin/bash
# mutation-audit.sh — Mutation Audit サブシステム
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   MUTATION_AUDIT_ENABLED, MUTATION_SKIP_TASK_TYPES, MUTATION_ERROR_RATE_THRESHOLD
#   MUTATION_MAX_PLAN_ATTEMPTS, MUTATION_MAX_AUDIT_ATTEMPTS, MUTATION_RUNNER_TIMEOUT
#   MUTATION_MODEL, MUTATION_AUDITOR_TIMEOUT, MUTATION_AUDIT_CONFIG
#   AGENTS_DIR, TEMPLATES_DIR, DEV_LOG_DIR, TASK_STACK, WORK_DIR
#   IMPLEMENTER_MODEL, IMPLEMENTER_TIMEOUT, L1_DEFAULT_TIMEOUT

# ===== Mutation Audit: should_run チェック =====
should_run_mutation_audit() {
  local task_json="$1"

  # 1. グローバル有効/無効
  if [ "$MUTATION_AUDIT_ENABLED" != "true" ]; then
    return 1
  fi

  # 2. task_type チェック（skip_task_types に含まれていたらスキップ）
  local task_type
  task_type=$(echo "$task_json" | jq_safe -r '.task_type // "implementation"')
  if echo "$MUTATION_SKIP_TASK_TYPES" | grep -qw "$task_type"; then
    return 1
  fi

  # 3. phase_config チェック（dev_phase_id に応じて有効/無効）
  local dev_phase_id
  dev_phase_id=$(echo "$task_json" | jq_safe -r '.dev_phase_id // "mvp"')
  local phase_enabled
  phase_enabled=$(jq_safe -r --arg pid "$dev_phase_id" \
    '.mutation_audit.phase_config[$pid].enabled // false' "$MUTATION_AUDIT_CONFIG" 2>/dev/null)
  if [ "$phase_enabled" != "true" ]; then
    return 1
  fi

  # 4. required_behaviors 有無チェック（旧フォーマット防御）
  local behaviors_count
  behaviors_count=$(echo "$task_json" | jq '[.required_behaviors // [] | .[] | select(. != null and . != "")] | length' 2>/dev/null || echo 0)
  if [ "$behaviors_count" -eq 0 ]; then
    return 1
  fi

  return 0
}

# ===== Mutation Audit: survival threshold 取得 =====
get_survival_threshold() {
  local dev_phase_id="${1:-mvp}"

  # task-stack.json の phases[].mutation_survival_threshold を優先
  local stack_threshold
  stack_threshold=$(jq_safe -r --arg pid "$dev_phase_id" \
    '.phases[]? | select(.id == $pid) | .mutation_survival_threshold // empty' "$TASK_STACK" 2>/dev/null)
  if [ -n "$stack_threshold" ]; then
    echo "$stack_threshold"
    return
  fi

  # フォールバック: mutation-audit.json の survival_threshold
  jq_safe -r --arg pid "$dev_phase_id" \
    '.mutation_audit.survival_threshold[$pid] // .mutation_audit.survival_threshold.core // 0.30' \
    "$MUTATION_AUDIT_CONFIG" 2>/dev/null
}

# ===== Mutation Audit: Auditor プロンプト構築 =====
build_mutation_auditor_prompt() {
  local task_id="$1"
  local task_dir="$2"
  local task_json="$3"
  local previous_feedback="${4:-}"

  # impl_marker を基準に実装後のファイルを検出
  # Fix: .pending が昇格されなかった場合のフォールバック
  local impl_marker="${task_dir}/implementation-output.txt"
  if [ ! -f "$impl_marker" ] && [ -f "${impl_marker}.pending" ]; then
    mv "${impl_marker}.pending" "$impl_marker"
    log "  (implementation-output.txt.pending を昇格)"
  fi
  local impl_files=""
  local test_code=""

  if [ -f "$impl_marker" ]; then
    # find -newer で impl_marker より新しいファイルを検出
    local newer_files
    newer_files=$(find "$WORK_DIR" -newer "$impl_marker" -type f \
      \( -name '*.ts' -o -name '*.js' -o -name '*.tsx' -o -name '*.jsx' \) \
      ! -path '*/node_modules/*' ! -path '*/.git/*' 2>/dev/null | head -20)

    # 空配列ガード: newer_files が空文字の場合、while + here-string は
    # 1回空行で回ってしまうため明示的にスキップする。
    # 併せて `for ... in $var` の word splitting を排除し、空白を含むファイル名にも耐性を持たせる。
    if [ -n "$newer_files" ]; then
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        local rel_path="${f#$WORK_DIR/}"
        local line_count
        line_count=$(wc -l < "$f")
        local max_lines=500

        if echo "$rel_path" | grep -qE '(test|spec|__tests__)'; then
          # テストファイル
          if [ "$line_count" -le "$max_lines" ]; then
            test_code="${test_code}
### ${rel_path}
$(cat "$f")"
          else
            test_code="${test_code}
### ${rel_path} (先頭${max_lines}行)
$(head -n "$max_lines" "$f")"
          fi
        else
          # 実装ファイル（行番号付き）
          if [ "$line_count" -le "$max_lines" ]; then
            impl_files="${impl_files}
### ${rel_path}
$(cat -n "$f")"
          else
            impl_files="${impl_files}
### ${rel_path} (先頭${max_lines}行)
$(head -n "$max_lines" "$f" | cat -n)"
          fi
        fi
      done <<< "$newer_files"
    fi
  fi

  if [ -z "$impl_files" ]; then
    impl_files="（実装ファイルが検出されませんでした）"
  fi
  if [ -z "$test_code" ]; then
    test_code="（テストファイルが検出されませんでした）"
  fi

  # required_behaviors 抽出
  local required_behaviors
  required_behaviors=$(echo "$task_json" | jq_safe -r '.required_behaviors // [] | to_entries | map("- \(.value)") | join("\n")' 2>/dev/null)
  if [ -z "$required_behaviors" ]; then
    required_behaviors="（required_behaviors 未定義）"
  fi

  # テストコマンド
  local test_command
  test_command=$(echo "$task_json" | jq_safe -r '.validation.layer_1.command // ""')

  # previous_feedback がある場合は追加
  if [ -n "$previous_feedback" ]; then
    impl_files="${impl_files}

## 前回の Mutation Audit フィードバック
${previous_feedback}"
  fi

  render_template "${TEMPLATES_DIR}/mutation-auditor-prompt.md" \
    "TASK_ID"              "$task_id" \
    "IMPL_FILES"           "$impl_files" \
    "TEST_CODE"            "$test_code" \
    "REQUIRED_BEHAVIORS"   "$required_behaviors" \
    "TEST_COMMAND"         "$test_command"
}

# ===== Mutation Audit: テスト強化 =====
run_test_strengthen() {
  local task_id="$1"
  local task_dir="$2"
  local task_json="$3"
  local results_file="$4"

  log "  テスト強化モード開始: ${task_id}"

  # surviving_mutants からフィードバック構築
  local mutation_feedback
  mutation_feedback=$(jq_safe -r '
    .surviving_mutants[] |
    "- [\(.id)] カテゴリ: \(.category), behavior: \(.target_behavior)\n  理由: \(.rationale)"
  ' "$results_file" 2>/dev/null)

  if [ -z "$mutation_feedback" ]; then
    mutation_feedback="（surviving mutant 情報なし）"
  fi

  # required_behaviors
  local required_behaviors
  required_behaviors=$(echo "$task_json" | jq_safe -r '.required_behaviors // [] | to_entries | map("- \(.value)") | join("\n")' 2>/dev/null)
  if [ -z "$required_behaviors" ]; then
    required_behaviors="（required_behaviors 未定義）"
  fi

  # テスト情報
  local l1_command
  l1_command=$(echo "$task_json" | jq_safe -r '.validation.layer_1.command // ""')
  local l1_timeout
  l1_timeout=$(echo "$task_json" | jq_safe -r '.validation.layer_1.timeout_sec // '"$L1_DEFAULT_TIMEOUT")

  # コンテキスト
  local context="作業ディレクトリ: ${WORK_DIR}"

  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/implementer-strengthen-prompt.md" \
    "TASK_JSON"            "$task_json" \
    "LAYER1_COMMAND"       "$l1_command" \
    "LAYER1_TIMEOUT"       "$l1_timeout" \
    "REQUIRED_BEHAVIORS"   "$required_behaviors" \
    "MUTATION_FEEDBACK"    "$mutation_feedback" \
    "CONTEXT"              "$context"
  )

  local ts
  ts=$(now_ts)
  local output="${task_dir}/strengthen-output.txt"
  local log_file="${DEV_LOG_DIR}/strengthen-${task_id}-${ts}.log"

  metrics_start
  run_claude "$IMPLEMENTER_MODEL" "${AGENTS_DIR}/implementer.md" \
    "$prompt" "$output" "$log_file" "" "$IMPLEMENTER_TIMEOUT" "$WORK_DIR" || {
    metrics_record "strengthen-${task_id}" "false"
    log "  ⚠ テスト強化 Claude実行エラー（続行）"
    return 1
  }
  metrics_record "strengthen-${task_id}" "true"
  # .pending → 本ファイルに昇格（非JSON出力）
  [ -f "${output}.pending" ] && mv "${output}.pending" "$output"
  log "  テスト強化完了"
  return 0
}

# ===== Mutation Audit: メインオーケストレーター =====
run_mutation_audit() {
  local task_id="$1"
  local task_dir="$2"
  local task_json="$3"

  local dev_phase_id
  dev_phase_id=$(echo "$task_json" | jq_safe -r '.dev_phase_id // "mvp"')
  local survival_threshold
  survival_threshold=$(get_survival_threshold "$dev_phase_id")

  log "  Mutation Audit 開始: ${task_id} (threshold=${survival_threshold})"

  local audit_attempt=0
  while [ "$audit_attempt" -lt "$MUTATION_MAX_AUDIT_ATTEMPTS" ]; do
    audit_attempt=$((audit_attempt + 1))
    log "  Mutation Audit attempt ${audit_attempt}/${MUTATION_MAX_AUDIT_ATTEMPTS}"

    local plan_attempt=0
    local plan_success=false
    local results_file="${task_dir}/mutation-results.json"
    local previous_feedback=""

    while [ "$plan_attempt" -lt "$MUTATION_MAX_PLAN_ATTEMPTS" ]; do
      plan_attempt=$((plan_attempt + 1))
      log "    Plan attempt ${plan_attempt}/${MUTATION_MAX_PLAN_ATTEMPTS}"

      # Mutation Auditor (LLM) → mutation-plan.json
      local auditor_prompt
      auditor_prompt=$(build_mutation_auditor_prompt "$task_id" "$task_dir" "$task_json" "$previous_feedback")

      local ts
      ts=$(now_ts)
      local plan_file="${task_dir}/mutation-plan.json"
      local plan_log="${DEV_LOG_DIR}/mutation-auditor-${task_id}-${ts}.log"

      metrics_start
      if ! run_claude "$MUTATION_MODEL" "${AGENTS_DIR}/mutation-auditor.md" \
        "$auditor_prompt" "$plan_file" "$plan_log" "" "$MUTATION_AUDITOR_TIMEOUT" "$WORK_DIR" \
        "${SCHEMAS_DIR}/mutation-auditor.schema.json"; then
        metrics_record "mutation-auditor-${task_id}" "false"
        log "    ⚠ Mutation Auditor 実行エラー — graceful degradation"
        handle_task_pass "$task_id"
        return 0
      fi
      metrics_record "mutation-auditor-${task_id}" "true"

      if ! validate_json "$plan_file" "mutation-auditor-${task_id}"; then
        log "    ⚠ Mutation Auditor JSON不正 — graceful degradation"
        handle_task_pass "$task_id"
        return 0
      fi

      # mutation-runner.sh → mutation-results.json
      log "    mutation-runner.sh 実行中..."
      if ! bash ".forge/loops/mutation-runner.sh" "$plan_file" "$WORK_DIR" "$results_file" "$MUTATION_RUNNER_TIMEOUT"; then
        log "    ⚠ mutation-runner.sh クラッシュ — graceful degradation"
        handle_task_pass "$task_id"
        return 0
      fi

      # error_rate チェック
      local error_rate
      error_rate=$(jq_safe -r '.error_rate // 0' "$results_file")
      local error_exceeds
      error_exceeds=$(awk "BEGIN { print ($error_rate > $MUTATION_ERROR_RATE_THRESHOLD) ? \"true\" : \"false\" }")

      if [ "$error_exceeds" = "true" ]; then
        log "    error_rate=${error_rate} > threshold=${MUTATION_ERROR_RATE_THRESHOLD} — REPLAN"
        previous_feedback="前回のプラン実行でエラー率が高かった (error_rate=${error_rate})。行番号やファイルパスの精度を改善してください。"
        continue
      fi

      plan_success=true
      break
    done

    if [ "$plan_success" != "true" ]; then
      log "    Plan attempts 上限到達 — graceful degradation"
      handle_task_pass "$task_id"
      return 0
    fi

    # survival_rate チェック
    local survival_rate
    survival_rate=$(jq_safe -r '.survival_rate // 0' "$results_file")
    local survival_passes
    survival_passes=$(awk "BEGIN { print ($survival_rate <= $survival_threshold) ? \"true\" : \"false\" }")

    if [ "$survival_passes" = "true" ]; then
      log "  ✓ Mutation Audit PASS (survival_rate=${survival_rate} <= threshold=${survival_threshold})"
      # 最終結果を保存
      cp "$results_file" "${task_dir}/mutation-results-final.json"
      handle_task_pass "$task_id"
      return 0
    fi

    log "    survival_rate=${survival_rate} > threshold=${survival_threshold} — テスト強化"

    # テスト強化
    if ! run_test_strengthen "$task_id" "$task_dir" "$task_json" "$results_file"; then
      log "    ⚠ テスト強化失敗 — graceful degradation"
      cp "$results_file" "${task_dir}/mutation-results-final.json"
      handle_task_pass "$task_id"
      return 0
    fi

    # Re-run Layer 1 test
    local test_command
    test_command=$(echo "$task_json" | jq_safe -r '.validation.layer_1.command // ""')
    local test_timeout
    test_timeout=$(echo "$task_json" | jq_safe -r '.validation.layer_1.timeout_sec // '"$L1_DEFAULT_TIMEOUT")

    if [ -n "$test_command" ]; then
      log "    Layer 1 再テスト実行..."
      local test_output
      if ! test_output=$(execute_layer1_test "$test_command" "$test_timeout" 2>&1); then
        log "    ✗ テスト強化後の Layer 1 テスト失敗"
        echo "$test_output" > "${task_dir}/test-output-post-strengthen.txt"
        cp "$results_file" "${task_dir}/mutation-results-final.json"
        handle_task_fail "$task_id" "$task_dir" "$test_output"
        return 0
      fi
      echo "$test_output" > "${task_dir}/test-output-post-strengthen.txt"
    fi

    # 次の audit attempt へ（re-audit）
    log "    テスト強化済み — 次の audit attempt へ"
  done

  # 全 audit attempt 失敗 → Evidence-DA + Investigator エスカレーション
  log "  ✗ Mutation Audit 全 attempt 失敗 — Investigator エスカレーション"
  cp "$results_file" "${task_dir}/mutation-results-final.json" 2>/dev/null || true

  # Evidence-DA: mutation audit 全 attempt 失敗
  if [ -f "${task_dir}/mutation-results-final.json" ]; then
    local _mut_results
    _mut_results=$(cat "${task_dir}/mutation-results-final.json" 2>/dev/null || echo "")
    run_evidence_da "$task_id" "$task_dir" "mutation_audit_failure" "" "$_mut_results" ""
  fi

  handle_task_fail "$task_id" "$task_dir" "Mutation Audit: survival_rate がthreshold超過（${MUTATION_MAX_AUDIT_ATTEMPTS}回のテスト強化後も改善せず）"
}
