#!/bin/bash
# investigation.sh — 障害診断・アプローチ探索サブシステム
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   AGENTS_DIR, TEMPLATES_DIR, DEV_LOG_DIR, TASK_STACK, WORK_DIR
#   INVESTIGATOR_MODEL, INVESTIGATOR_TIMEOUT, CRITERIA_FILE
#   INVESTIGATION_LOG, LOOP_SIGNAL_FILE, APPROACH_BARRIERS_FILE
#   EXPLORER_MODEL, EXPLORER_TIMEOUT, IMPLEMENTER_TIMEOUT
#   MAX_APPROACH_SCOPE_COUNT, MAX_TASK_RETRIES
#   investigation_count, approach_scope_count (session vars, mutated by this module)

# ===== Investigator =====
# 3回失敗したタスクの根本原因を診断する。フレッシュコンテキストで起動（Ralph原則）。
run_investigator() {
  local task_id="$1"
  local task_dir="$2"

  investigation_count=$((investigation_count + 1))
  log "  Investigator 起動（${investigation_count}回目）: タスク ${task_id}"

  # Investigator エージェント存在チェック
  if [ ! -f "${AGENTS_DIR}/investigator.md" ] || [ ! -f "${TEMPLATES_DIR}/investigator-prompt.md" ]; then
    log "  ⚠ Investigator エージェント/テンプレートが見つかりません"
    update_task_status "$task_id" "blocked_investigation"
    return 0
  fi

  # 失敗コンテキストを集約
  local fail_1 fail_2 fail_3 impl_output
  fail_1=$(tail -50 "${task_dir}/fail-1.txt" 2>/dev/null || echo "(なし)")
  fail_2=$(tail -50 "${task_dir}/fail-2.txt" 2>/dev/null || echo "(なし)")
  fail_3=$(tail -50 "${task_dir}/fail-3.txt" 2>/dev/null || echo "(なし)")
  impl_output=$(tail -100 "${task_dir}/implementation-output.txt" 2>/dev/null || echo "(なし)")

  local task_def
  task_def=$(cat "${task_dir}/task-definition.json" 2>/dev/null || echo "{}")

  local context_summary
  context_summary="## タスク定義
${task_def}

## 失敗履歴
### 1回目
${fail_1}

### 2回目
${fail_2}

### 3回目
${fail_3}

## 最新の実装出力（末尾100行）
${impl_output}"

  # criteria 抜粋（あれば）
  local criteria_excerpt="（成功条件ファイルなし）"
  if [ -n "$CRITERIA_FILE" ] && [ -f "$CRITERIA_FILE" ]; then
    criteria_excerpt=$(cat "$CRITERIA_FILE" 2>/dev/null || echo "(読み込み失敗)")
  fi

  # required_behaviors 抽出（task-stack.json から）
  local required_behaviors
  required_behaviors=$(jq_safe -r --arg id "$task_id" '
    .tasks[] | select(.task_id == $id) |
    .required_behaviors // [] | to_entries | map("- \(.value)") | join("\n")
  ' "$TASK_STACK" 2>/dev/null)
  if [ -z "$required_behaviors" ]; then
    required_behaviors="（required_behaviors 未定義）"
  fi

  # Mutation Audit コンテキスト（mutation-results-final.json があれば）
  local mutation_audit_context="（Mutation Audit 結果なし）"
  if [ -f "${task_dir}/mutation-results-final.json" ]; then
    local ma_total ma_killed ma_survived ma_survival_rate
    ma_total=$(jq_safe -r '.total // 0' "${task_dir}/mutation-results-final.json")
    ma_killed=$(jq_safe -r '.killed // 0' "${task_dir}/mutation-results-final.json")
    ma_survived=$(jq_safe -r '.survived // 0' "${task_dir}/mutation-results-final.json")
    ma_survival_rate=$(jq_safe -r '.survival_rate // 0' "${task_dir}/mutation-results-final.json")
    local surviving_details
    surviving_details=$(jq_safe -r '.surviving_mutants[] | "- [\(.id)] \(.category): \(.rationale) (behavior: \(.target_behavior))"' \
      "${task_dir}/mutation-results-final.json" 2>/dev/null)
    mutation_audit_context="total=${ma_total} killed=${ma_killed} survived=${ma_survived} survival_rate=${ma_survival_rate}

Surviving mutants:
${surviving_details:-（なし）}"
  fi

  # Evidence-DA コンテキスト収集
  local evidence_da_context="（Evidence-DA 結果なし）"
  if [ -f "${task_dir}/evidence-da-result.json" ]; then
    evidence_da_context=$(cat "${task_dir}/evidence-da-result.json" 2>/dev/null || echo "(読み込み失敗)")
  fi

  # L3 失敗コンテキスト収集
  local l3_failure_context="（L3 受入テスト失敗情報なし）"
  local l3_files
  l3_files=$(ls "${task_dir}"/l3-*.txt 2>/dev/null || true)
  if [ -n "$l3_files" ]; then
    l3_failure_context=""
    for l3f in $l3_files; do
      local l3_name
      l3_name=$(basename "$l3f" .txt)
      l3_failure_context="${l3_failure_context}--- ${l3_name} ---\n$(cat "$l3f" 2>/dev/null)\n\n"
    done
  fi

  # Investigatorプロンプト生成
  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/investigator-prompt.md" \
    "TASK_ID"                  "$task_id" \
    "FAILURE_CONTEXT"          "$context_summary" \
    "CRITERIA_EXCERPT"         "$criteria_excerpt" \
    "REQUIRED_BEHAVIORS"       "$required_behaviors" \
    "MUTATION_AUDIT_CONTEXT"   "$mutation_audit_context" \
    "L3_FAILURE_CONTEXT"       "$l3_failure_context" \
    "EVIDENCE_DA_CONTEXT"      "$evidence_da_context" \
    "MAX_RETRIES"              "$MAX_TASK_RETRIES"
  )

  local ts
  ts=$(now_ts)
  local result="${task_dir}/investigation-result.json"
  local log_file="${DEV_LOG_DIR}/inv-${task_id}-${ts}.log"

  # フレッシュコンテキストで実行（Web検索許可 / ファイル書き込み禁止 — 診断専用）
  # Investigator はファイルを直接修正しない。修正案は investigator_fix フィールド経由で Implementer に渡す。
  metrics_start
  run_claude "$INVESTIGATOR_MODEL" "${AGENTS_DIR}/investigator.md" \
    "$prompt" "$result" "$log_file" "Write,Edit,MultiEdit,NotebookEdit" "$INVESTIGATOR_TIMEOUT" "$WORK_DIR" \
    "${SCHEMAS_DIR}/investigator.schema.json" || {
    metrics_record "investigator-${task_id}" "false"
    # デバッグログからレートリミット情報を抽出してエラー分類精度を向上
    local _inv_err_detail="Investigator実行エラー"
    if [ -f "$log_file" ]; then
      local _rate_hint
      _rate_hint=$(tail -50 "$log_file" 2>/dev/null | grep -oi "429\|too many requests\|rate.limit\|rate_limit\|overloaded" | head -1 || true)
      [ -n "$_rate_hint" ] && _inv_err_detail="Investigator実行エラー (rate_limit: ${_rate_hint})"
    fi
    record_error "investigator-${task_id}" "$_inv_err_detail"
    log "  ✗ ${_inv_err_detail}"
    update_task_status "$task_id" "blocked_investigation"
    return 0
  }
  metrics_record "investigator-${task_id}" "true"

  if ! validate_json "$result" "investigator-${task_id}"; then
    log "  ✗ Investigator出力のJSON検証失敗。手動確認が必要"
    update_task_status "$task_id" "blocked_investigation"
    return 0
  fi

  # scope判定
  local scope
  scope=$(jq_safe -r '.scope // "task"' "$result")
  local root_cause
  root_cause=$(jq_safe -r '.root_cause // "不明"' "$result")
  local recommendation
  recommendation=$(jq_safe -r '.recommendation // "不明"' "$result")
  local confidence
  confidence=$(jq_safe -r '.confidence // "low"' "$result")

  # investigation-log.jsonl に記録
  jq -c --arg id "$task_id" --arg s "$scope" --arg ts "$(date -Iseconds)" \
    '. + {task_id: $id, scope: $s, timestamp: $ts}' \
    "$result" >> "$INVESTIGATION_LOG"

  # Lessons Learned: 失敗パターンを蓄積
  local lesson_category="other"
  case "$root_cause" in
    *vitest*|*jest*|*mocha*|*test*framework*) lesson_category="test_framework" ;;
    *path*|*パス*|*Windows*|*windows*) lesson_category="path_issue" ;;
    *timeout*|*タイムアウト*) lesson_category="timeout" ;;
    *not\ found*|*未作成*|*存在しない*) lesson_category="hallucination" ;;
    *file*limit*|*ファイル数*) lesson_category="file_limit" ;;
  esac
  record_lesson "$lesson_category" "$root_cause" "$recommendation" "$task_id"

  # イベントソーシング: Investigator 起動記録
  record_task_event "$task_id" "investigator_invoked" \
    "{\"scope\":\"$scope\",\"confidence\":\"$confidence\",\"root_cause\":$(jq -n --arg rc "$root_cause" '$rc')}"

  log "  Investigator判定: scope=${scope}, confidence=${confidence}"
  log "  根本原因: ${root_cause}"

  # scope routing
  case "$scope" in
    "task")
      log "  → タスク修正。修正案を適用して再実装"
      apply_task_fix "$task_id" "$recommendation"
      ;;
    "criteria")
      log "  → 成功条件の前提に問題。人間通知"
      update_task_status "$task_id" "blocked_criteria"
      notify_human "critical" "タスク ${task_id}: 成功条件の前提に問題" \
        "根本原因: ${root_cause}\n推奨: ${recommendation}\n確信度: ${confidence}"
      ;;
    "research")
      log "  → リサーチの前提が崩壊。Phase 1差戻し推奨"
      update_task_status "$task_id" "blocked_research"
      notify_human "critical" "タスク ${task_id}: リサーチ前提の崩壊" \
        "根本原因: ${root_cause}\n推奨: ${recommendation}\n確信度: ${confidence}"
      # RESEARCH_REMAND シグナル発行
      echo "RESEARCH_REMAND" > "$LOOP_SIGNAL_FILE"
      ;;
    "approach")
      approach_scope_count=$((approach_scope_count + 1))
      log "  → アプローチの根本的限界を検出（${approach_scope_count}回目）"
      update_task_status "$task_id" "blocked_approach"

      # approach_context を保存（Approach Explorerの入力に使用）
      jq -c '{what_works: .approach_context.what_works, fundamental_barrier: .approach_context.fundamental_barrier, attempted_workarounds: .approach_context.attempted_workarounds, root_cause: .root_cause, evidence: .evidence}' \
        "$result" >> "$APPROACH_BARRIERS_FILE"

      if [ "$approach_scope_count" -ge "$MAX_APPROACH_SCOPE_COUNT" ]; then
        log "  → approachスコープが${MAX_APPROACH_SCOPE_COUNT}回到達。APPROACH_PIVOTシグナル発行"
        notify_human "critical" "アプローチ転換探索を開始" \
          "根本原因: ${root_cause}\n障壁: $(jq_safe -r '.approach_context.fundamental_barrier // "不明"' "$result")\n確信度: ${confidence}"
        echo "APPROACH_PIVOT" > "$LOOP_SIGNAL_FILE"
      else
        notify_human "warning" "タスク ${task_id}: アプローチ限界の兆候（${approach_scope_count}/${MAX_APPROACH_SCOPE_COUNT}）" \
          "根本原因: ${root_cause}\n推奨: ${recommendation}\n確信度: ${confidence}"
      fi
      ;;
    *)
      log "  ✗ Investigator: 不明なscope '${scope}'。blocked_unknown に設定"
      update_task_status "$task_id" "blocked_unknown"
      notify_human "warning" "タスク ${task_id}: Investigator不明判定" \
        "scope: ${scope}\n根本原因: ${root_cause}"
      ;;
  esac
}

# ===== タスク修正適用 =====
apply_task_fix() {
  local task_id="$1"
  local fix_suggestion="$2"

  jq --arg id "$task_id" --arg fix "$fix_suggestion" '
    .tasks |= map(
      if .task_id == $id then
        .investigator_fix = $fix |
        .fail_count = 0 |
        .status = "pending" |
        .updated_at = (now | todate)
      else . end
    ) |
    .updated_at = (now | todate)
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
  sync_task_stack

  log "  タスク ${task_id} にInvestigator修正案を適用。fail_countリセット"
  record_task_event "$task_id" "fix_applied" "{\"fix_source\":\"investigator\"}"
}

# ===== Approach Explorer =====
# アプローチの根本的限界に到達した際、代替アプローチを探索する。
run_approach_explorer() {
  log ""
  log "=========================================="
  log "Approach Explorer 起動"
  log "=========================================="

  # エージェント・テンプレート存在チェック
  if [ ! -f "${AGENTS_DIR}/approach-explorer.md" ] || [ ! -f "${TEMPLATES_DIR}/approach-explorer-prompt.md" ]; then
    log "  ⚠ Approach Explorer エージェント/テンプレートが見つかりません"
    notify_human "critical" "Approach Explorer 起動失敗" \
      "エージェント/テンプレートが存在しません。手動で代替アプローチを検討してください。"
    return 0
  fi

  # 元テーマの取得（investigation-plan から）
  local original_theme="(不明)"
  local plan_summary="(調査計画なし)"
  local latest_plan
  latest_plan=$(find .docs/research -name 'investigation-plan.json' -type f 2>/dev/null | sort -r | head -1)
  if [ -n "$latest_plan" ] && [ -f "$latest_plan" ]; then
    original_theme=$(jq_safe -r '.investigation_plan.theme // "(不明)"' "$latest_plan")
    plan_summary=$(jq_safe -r '[
      "Core Questions: " + ([.investigation_plan.core_questions[]?] | join("; ")),
      "Boundaries: " + (.investigation_plan.boundaries.depth // ""),
      "Cutoff: " + ([.investigation_plan.boundaries.cutoff[]?] | join("; "))
    ] | join("\n")' "$latest_plan")
  fi

  # approach-barriers.jsonl から障壁情報を収集
  local what_works="(情報なし)"
  local fundamental_barrier="(情報なし)"
  local attempted_workarounds="(情報なし)"
  local barriers_file="$APPROACH_BARRIERS_FILE"
  if [ -f "$barriers_file" ] && [ -s "$barriers_file" ]; then
    what_works=$(jq -rs '[.[].what_works // empty] | unique | join("\n")' "$barriers_file")
    fundamental_barrier=$(jq -rs '[.[].fundamental_barrier // empty] | unique | join("\n")' "$barriers_file")
    attempted_workarounds=$(jq -rs '[.[].attempted_workarounds // empty] | unique | join("\n")' "$barriers_file")
  fi

  # investigation-log.jsonl から関連診断ログ
  local inv_log="(診断ログなし)"
  if [ -f "$INVESTIGATION_LOG" ]; then
    inv_log=$(tail -20 "$INVESTIGATION_LOG")
  fi

  # プロンプト生成
  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/approach-explorer-prompt.md" \
    "ORIGINAL_THEME"             "$original_theme" \
    "INVESTIGATION_PLAN_SUMMARY" "$plan_summary" \
    "WHAT_WORKS"                 "$what_works" \
    "FUNDAMENTAL_BARRIER"        "$fundamental_barrier" \
    "ATTEMPTED_WORKAROUNDS"      "$attempted_workarounds" \
    "INVESTIGATION_LOG"          "$inv_log"
  )

  local ts
  ts=$(now_ts)
  local result="${DEV_LOG_DIR}/approach-exploration-${ts}.json"
  local log_file="${DEV_LOG_DIR}/approach-exploration-${ts}.log"

  # Opusで実行（創造的思考が必要）
  metrics_start
  if run_claude "$EXPLORER_MODEL" "${AGENTS_DIR}/approach-explorer.md" \
    "$prompt" "$result" "$log_file" "" "$EXPLORER_TIMEOUT" "$WORK_DIR" \
    "${SCHEMAS_DIR}/approach-explorer.schema.json"; then
    metrics_record "approach-explorer" "true"
  else
    metrics_record "approach-explorer" "false"
    log "  ✗ Approach Explorer 実行エラー"
    notify_human "critical" "Approach Explorer 実行失敗" \
      "手動で代替アプローチを検討してください。"
    return 0
  fi

  if ! validate_json "$result" "approach-explorer"; then
    log "  ✗ Approach Explorer 出力のJSON検証失敗"
    notify_human "critical" "Approach Explorer 出力が不正" \
      "ファイル: ${result}。手動で確認してください。"
    return 0
  fi

  # 結果表示
  local primary_alt
  primary_alt=$(jq_safe -r '.recommendation.primary // "なし"' "$result")
  local rationale
  rationale=$(jq_safe -r '.recommendation.rationale // ""' "$result")
  local upper_problem
  upper_problem=$(jq_safe -r '.upper_problem.redefined_problem // ""' "$result")
  local num_alternatives
  num_alternatives=$(jq '.alternative_approaches | length' "$result")

  echo -e "" >&2
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}" >&2
  echo -e "${BOLD}${CYAN}  Approach Explorer 結果${NC}" >&2
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}" >&2
  echo -e "  上位問題: ${upper_problem}" >&2
  echo -e "  代替アプローチ: ${num_alternatives}件" >&2
  echo -e "  推奨: ${primary_alt}" >&2
  echo -e "  理由: ${rationale}" >&2
  echo -e "" >&2

  # 各候補の概要表示
  jq_safe -r '.alternative_approaches[] | "  [\(.id)] \(.name) — 実現性: \(.feasibility.technical)"' "$result" >&2 2>/dev/null

  echo -e "" >&2
  echo -e "  詳細: ${result}" >&2
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}" >&2
  echo -e "  人間の判断が必要です。" >&2
  echo -e "  推奨アプローチで新規リサーチを開始するか、現行アプローチを継続するか判断してください。" >&2

  log "Approach Explorer 完了。結果: ${result}"
}

# ===== ループシグナル検出 =====
check_loop_signal() {
  if [ -f "$LOOP_SIGNAL_FILE" ]; then
    local signal
    signal=$(cat "$LOOP_SIGNAL_FILE" | tr -d '\r\n')
    if [ "$signal" = "RESEARCH_REMAND" ]; then
      log "✗ RESEARCH_REMAND シグナル検出 — ループ停止"
      rm -f "$LOOP_SIGNAL_FILE"
      return 0
    fi
    if [ "$signal" = "APPROACH_PIVOT" ]; then
      log "✗ APPROACH_PIVOT シグナル検出 — Approach Explorer 起動"
      rm -f "$LOOP_SIGNAL_FILE"
      run_approach_explorer
      return 0
    fi
  fi
  return 1
}
