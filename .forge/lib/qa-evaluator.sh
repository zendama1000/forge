#!/bin/bash
# qa-evaluator.sh — 独立 QA Evaluator サブシステム
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   AGENTS_DIR, TEMPLATES_DIR, SCHEMAS_DIR, DEV_LOG_DIR, TASK_STACK, WORK_DIR
#   QA_EVALUATOR_ENABLED, QA_EVALUATOR_MODEL, QA_EVALUATOR_TIMEOUT, QA_MAX_FAILURES

# ===== 実装 diff 収集 =====
# QA Evaluator に渡す実装 diff を収集する（単体テスト可能なよう関数化）。
# - intent-to-add(-N) で新規 repo / 未コミット・未追跡ファイルも diff に可視化する
# - lockfile（数千行）が行キャップを埋めて本質ファイルを隠すのを除外する
# - キャップは 2000 行（多ファイルタスクで中核実装ファイルが切り落とされ QA が
#   「未確認」で誤 fail するのを防ぐ。例: impl-session-api の diff は 1220 行で
#   500 では session-manager.ts が切れていた）
# - 第 2 引数 base（省略可、batch#11 R04）: タスク基準 SHA を渡すと `git diff <base>` で commit 済みの
#   変更も視野に入る。Investigator 指示「green 即コミット」→ QA「実装 diff が空」の誤 fail（4.5f で 2/13、
#   人間介入 1 件）を塞ぐ。省略時 / HEAD / 無効 SHA は従来の作業ツリー diff
qa_collect_impl_diff() {
  local work_dir="$1"
  local base="${2:-}"
  local impl_diff="（diff 取得不可）"
  if [ -n "$work_dir" ] && git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    git -C "$work_dir" add -A -N 2>/dev/null || true
    if [ -n "$base" ] && [ "$base" != "HEAD" ] && git -C "$work_dir" cat-file -e "${base}^{commit}" 2>/dev/null; then
      impl_diff=$(git -C "$work_dir" diff "$base" -- . ':(exclude)package-lock.json' ':(exclude)*.lock' 2>/dev/null | head -2000 || echo "（diff 取得不可）")
    else
      impl_diff=$(git -C "$work_dir" diff -- . ':(exclude)package-lock.json' ':(exclude)*.lock' 2>/dev/null | head -2000 || echo "（diff 取得不可）")
      [ -z "$impl_diff" ] && impl_diff=$(git -C "$work_dir" diff HEAD 2>/dev/null | head -2000 || echo "（差分なし）")
    fi
    # intent-to-add（add -N）を index に残さない（レビュー 2026-09-03: 残ると次 attempt の .untracked から
    # 漏れ、復帰時に quarantine へ誤送りされる）
    git -C "$work_dir" reset -q 2>/dev/null || true
  fi
  printf '%s' "$impl_diff"
}

# ===== 成果物コンテキスト収集（batch#10 Stage3 — qa_diff_scope_blindness 根治） =====
# 作業ツリー diff だけでは、リトライで既にコミット済みの成果物が視野から消え、
# 「実装 Diff が空」を根拠にした誤 fail が起きる（football-core で実測 → 人間が覆した）。
# 直近コミット一覧 + タスク定義が参照する実在ファイルの内容を追加提示し、
# Evaluator が「コミット済みの現実」に対してテスト監査できるようにする。
# 使い方: qa_collect_artifact_context <work_dir> <task_json>
qa_collect_artifact_context() {
  local work_dir="$1"
  local task_json="${2:-}"
  { [ -n "$work_dir" ] && git -C "$work_dir" rev-parse --git-dir >/dev/null 2>&1; } || return 0

  echo "### 直近コミット（このタスクの過去試行の成果を含み得る）"
  git -C "$work_dir" log --oneline -5 2>/dev/null || echo "（履歴なし）"

  # タスク JSON 中の文字列から work_dir に実在するファイルパスを抽出（最大6・各250行）
  [ -n "$task_json" ] || return 0
  local paths p shown=0
  paths=$(printf '%s' "$task_json" | jq -r '[.. | strings] | unique | .[]' 2>/dev/null | \
    grep -E '^[A-Za-z0-9_./-]+\.[A-Za-z0-9]{1,6}$' | grep -v '^\.\.' | head -40 || true)
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ -f "${work_dir}/${p}" ] || continue
    [ "$shown" -ge 6 ] && break
    shown=$((shown + 1))
    echo ""
    echo "### 成果物: ${p}（先頭250行）"
    head -250 "${work_dir}/${p}" 2>/dev/null || true
  done <<< "$paths"
  return 0
}

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
  # jq_safe: Windows Git Bash で \r が混入すると -ge 比較が壊れるため必須
  local qa_fail_count
  qa_fail_count=$(jq_safe -r --arg id "$task_id" \
    '.tasks[] | select(.task_id == $id) | .qa_fail_count // 0' "$TASK_STACK" 2>/dev/null || echo 0)
  case "$qa_fail_count" in (*[!0-9]*|"") qa_fail_count=0 ;; esac
  if [ "$qa_fail_count" -ge "${QA_MAX_FAILURES:-2}" ]; then
    log "  ⚠ QA Evaluator: 失敗上限到達（${qa_fail_count}/${QA_MAX_FAILURES}）— auto-pass"
    # 黙って劣化しない: auto-pass は品質未確認のまま通過するため台帳に残す
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "qa_auto_pass" "$task_id" \
        "QA 失敗上限到達（${qa_fail_count}/${QA_MAX_FAILURES}）による auto-pass — 品質未確認のまま通過"
    fi
    return 0
  fi

  log "  QA Evaluator 起動: task=${task_id}"

  # 実装 diff + 成果物コンテキストを収集（後者はコミット済み成果物への視野 — batch#10）
  local impl_diff artifact_ctx
  # QA の diff 視野をタスク基準 SHA からにする（batch#11 R04。task_base_ref は common.sh）
  local _qa_base="HEAD"
  if type task_base_ref &>/dev/null && [ -n "${WORK_DIR:-}" ]; then
    _qa_base=$(task_base_ref "$task_id" "$WORK_DIR" 2>/dev/null || echo HEAD)
  fi
  impl_diff=$(qa_collect_impl_diff "${WORK_DIR:-}" "$_qa_base")
  artifact_ctx=$(qa_collect_artifact_context "${WORK_DIR:-}" "$task_json" 2>/dev/null || true)
  if [ -n "$artifact_ctx" ]; then
    impl_diff="${impl_diff}

${artifact_ctx}"
  fi

  # テスト出力を収集
  local test_output="（テスト出力なし）"
  if [ -f "${task_dir}/test-output.txt" ]; then
    test_output=$(tail -200 "${task_dir}/test-output.txt")
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
  local _qa_rc=0
  run_claude "${QA_EVALUATOR_MODEL:-opus}" "${AGENTS_DIR}/qa-evaluator.md" \
    "$prompt" "$output" "$log_file" "WebSearch,WebFetch,Bash" "${QA_EVALUATOR_TIMEOUT:-300}" "" \
    "${SCHEMAS_DIR}/qa-evaluator.schema.json" || _qa_rc=$?
  if [ "$_qa_rc" -ne 0 ]; then
    metrics_record "qa-evaluator-${task_id}" "false"
    # 黙って劣化しない（batch#11 R04）: 実行エラーの pass は上限到達 auto-pass と同様に台帳へ残す
    #（4.5f では 2/39 が無記録で pass していた）
    log "  ⚠ QA Evaluator 実行エラー(exit=${_qa_rc}) — 未評価のまま pass（品質債務 qa_execution_error）"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "qa_execution_error" "$task_id" \
        "QA Evaluator 実行エラー(exit=${_qa_rc}) により未評価のまま pass"
    fi
    return 0
  fi
  metrics_record "qa-evaluator-${task_id}" "true"

  # JSON 検証
  if ! validate_json "$output" "qa-evaluator-${task_id}"; then
    log "  ⚠ QA Evaluator JSON検証失敗 — 未評価のまま pass（品質債務 qa_invalid_output）"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "qa_invalid_output" "$task_id" \
        "QA Evaluator の出力 JSON が不正で未評価のまま pass"
    fi
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
