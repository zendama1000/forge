#!/bin/bash
# dev-phases.sh — 開発フェーズ管理サブシステム（mvp/core/polish 遷移）
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   TASK_STACK, WORK_DIR, PROJECT_ROOT
#   AGENTS_DIR, TEMPLATES_DIR, DEV_LOG_DIR, DEV_CONFIG
#   PHASE_CONTROL, SAFETY_AUTO_REVERT_ON_REGRESSION, SAFETY_AUTO_COMMIT_PER_PHASE
#   CHECKLIST_VERIFIER_MODEL, CHECKLIST_VERIFIER_TIMEOUT
#   IMPLEMENTER_TIMEOUT
#   HAS_DEV_PHASES, DEV_PHASES, CURRENT_DEV_PHASE (session vars, mutated by this module)

# ===== dev-phase 検出 =====
detect_dev_phases() {
  # Ablation guard
  if [ "${ABLATION_DEV_PHASE_GATING_ENABLED:-true}" != "true" ]; then
    HAS_DEV_PHASES=false
    return 0
  fi

  local phase_count
  phase_count=$(jq '.phases // [] | length' "$TASK_STACK" 2>/dev/null || echo 0)

  if [ "$phase_count" -eq 0 ]; then
    HAS_DEV_PHASES=false
    return 0
  fi

  HAS_DEV_PHASES=true

  # phases 配列から ID 一覧を取得
  local phase_ids
  phase_ids=$(jq_safe -r '.phases[].id' "$TASK_STACK" 2>/dev/null)
  DEV_PHASES=()
  for pid in $phase_ids; do
    DEV_PHASES+=("$pid")
  done

  # 最初の「未完了タスクがある」dev-phase を CURRENT_DEV_PHASE に設定
  # （中断→再開時に、完了済み dev-phase をスキップする）
  CURRENT_DEV_PHASE=""
  for pid in "${DEV_PHASES[@]}"; do
    local incomplete
    incomplete=$(jq --arg pid "$pid" '
      [.tasks[] |
        select((.dev_phase_id // "mvp") == $pid) |
        select(.status != "completed")
      ] | length
    ' "$TASK_STACK" 2>/dev/null || echo 0)
    if [ "$incomplete" -gt 0 ]; then
      CURRENT_DEV_PHASE="$pid"
      break
    fi
  done

  # 全 dev-phase 完了済みの場合は空のまま（メインループで Phase 3 へ直行）
  if [ -z "$CURRENT_DEV_PHASE" ]; then
    log "  全 dev-phase のタスクが完了済み"
  fi

  # checklist_verifier のモデル設定読み込み
  if [ -f "$DEV_CONFIG" ]; then
    CHECKLIST_VERIFIER_MODEL=$(jq_safe -r '.checklist_verifier.model // "sonnet"' "$DEV_CONFIG")
    CHECKLIST_VERIFIER_TIMEOUT=$(jq_safe -r '.checklist_verifier.timeout_sec // 300' "$DEV_CONFIG")
  fi

  log "dev-phase 検出: ${DEV_PHASES[*]} (現在: ${CURRENT_DEV_PHASE})"
}

# ===== dev-phase: checklist 具体化 =====
# human_check のレベルA をレベルB（操作手順付きchecklist）に変換する
run_checklist_concretize() {
  local phase_id="$1"

  # テンプレートとエージェントの存在チェック
  if [ ! -f "${TEMPLATES_DIR}/checklist-concretize-prompt.md" ] || \
     [ ! -f "${AGENTS_DIR}/checklist-verifier.md" ]; then
    log "  ⚠ checklist-concretize テンプレート/エージェントが見つかりません。スキップ"
    return 0
  fi

  # phase の goal と human_check 項目を抽出
  local phase_goal
  phase_goal=$(jq_safe -r --arg pid "$phase_id" \
    '.phases[] | select(.id == $pid) | .goal // "不明"' "$TASK_STACK" 2>/dev/null)

  local human_checks
  human_checks=$(jq_safe -r --arg pid "$phase_id" '
    .phases[] | select(.id == $pid) |
    [.exit_criteria[]? | select(.type == "human_check") | .description] |
    to_entries | map("- \(.value)") | join("\n")
  ' "$TASK_STACK" 2>/dev/null)

  if [ -z "$human_checks" ]; then
    log "  human_check 項目なし。checklist具体化をスキップ"
    return 0
  fi

  # 完了タスク一覧
  local completed_tasks
  completed_tasks=$(jq_safe -r --arg pid "$phase_id" '
    [.tasks[] |
      select(.status == "completed") |
      select((.dev_phase_id // "mvp") == $pid) |
      "- \(.task_id): \(.description)"
    ] | join("\n")
  ' "$TASK_STACK" 2>/dev/null)

  # プロンプト生成
  local prompt
  prompt=$(render_template "${TEMPLATES_DIR}/checklist-concretize-prompt.md" \
    "DEV_PHASE_ID"      "$phase_id" \
    "DEV_PHASE_GOAL"    "$phase_goal" \
    "HUMAN_CHECK_ITEMS" "$human_checks" \
    "COMPLETED_TASKS"   "$completed_tasks" \
    "WORK_DIR"          "$WORK_DIR"
  )

  local ts
  ts=$(now_ts)
  local output="${DEV_LOG_DIR}/checklist-${phase_id}-${ts}.md"
  local log_file="${DEV_LOG_DIR}/checklist-${phase_id}-${ts}.log"

  log "  checklist 具体化実行中 (${phase_id})..."
  metrics_start
  if run_claude "$CHECKLIST_VERIFIER_MODEL" "${AGENTS_DIR}/checklist-verifier.md" \
    "$prompt" "$output" "$log_file" "" "$CHECKLIST_VERIFIER_TIMEOUT" "$WORK_DIR"; then
    metrics_record "checklist-verifier-${phase_id}" "true"
    log "  ✓ checklist 生成完了: ${output}"
  else
    metrics_record "checklist-verifier-${phase_id}" "false"
    log "  ⚠ checklist 生成失敗（続行）"
  fi
}

# ===== dev-phase チェックポイント表示 =====
show_dev_phase_checkpoint() {
  local phase_id="$1"

  # フェーズ情報
  local phase_goal
  phase_goal=$(jq_safe -r --arg pid "$phase_id" \
    '.phases[] | select(.id == $pid) | .goal // "不明"' "$TASK_STACK" 2>/dev/null)

  # タスク進捗
  local phase_total phase_completed
  phase_total=$(jq --arg pid "$phase_id" \
    '[.tasks[] | select((.dev_phase_id // "mvp") == $pid)] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  phase_completed=$(jq --arg pid "$phase_id" \
    '[.tasks[] | select((.dev_phase_id // "mvp") == $pid) | select(.status == "completed")] | length' "$TASK_STACK" 2>/dev/null || echo 0)

  # 完了タスク一覧
  local completed_list
  completed_list=$(jq_safe -r --arg pid "$phase_id" '
    .tasks[] |
    select((.dev_phase_id // "mvp") == $pid) |
    select(.status == "completed") |
    "       ✓ \(.task_id): \(.description)"
  ' "$TASK_STACK" 2>/dev/null)

  # 残り dev-phase
  local remaining_phases=""
  local found_current=false
  for dp in "${DEV_PHASES[@]}"; do
    if [ "$found_current" = "true" ]; then
      local dp_goal dp_count
      dp_goal=$(jq_safe -r --arg pid "$dp" '.phases[] | select(.id == $pid) | .goal // ""' "$TASK_STACK" 2>/dev/null)
      dp_count=$(jq --arg pid "$dp" '[.tasks[] | select((.dev_phase_id // "mvp") == $pid)] | length' "$TASK_STACK" 2>/dev/null || echo 0)
      remaining_phases="${remaining_phases}       ${dp} (${dp_count}タスク): ${dp_goal}\n"
    fi
    if [ "$dp" = "$phase_id" ]; then
      found_current=true
    fi
  done

  # チェックポイント最新 checklist ファイル
  local latest_checklist
  latest_checklist=$(ls -t "${DEV_LOG_DIR}/checklist-${phase_id}-"*.md 2>/dev/null | head -1)

  echo -e "" >&2
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}" >&2
  echo -e "${BOLD}${CYAN}  [${phase_id}] dev-phase 完了${NC}" >&2
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}" >&2
  echo -e "  タスク: ${phase_completed}/${phase_total}" >&2
  echo -e "  目標: ${phase_goal}" >&2
  echo -e "" >&2
  echo -e "  完了タスク:" >&2
  echo -e "${completed_list}" >&2

  if [ -n "$latest_checklist" ] && [ -f "$latest_checklist" ]; then
    echo -e "" >&2
    echo -e "  human_check (操作手順): ${latest_checklist}" >&2
  fi

  if [ -n "$remaining_phases" ]; then
    echo -e "" >&2
    echo -e "  残り dev-phase:" >&2
    echo -e "${remaining_phases}" >&2
  fi

  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}" >&2
  echo -e "  [1] 続行  [2] 目視確認後続行  [3] 次phase内容表示  [4] 中断" >&2

  local choice
  read -t 60 -r choice 2>/dev/null || { choice="1"; log "  (非対話/タイムアウト — 自動続行)"; }

  case "$choice" in
    1)
      log "→ 続行"
      return 0
      ;;
    2)
      echo -e "  目視確認後、Enter で続行 / 'q' で中断: " >&2
      local confirm
      read -r confirm 2>/dev/null || confirm=""
      if [ "$confirm" = "q" ] || [ "$confirm" = "Q" ]; then
        log "目視確認後に中断"
        return 1
      fi
      return 0
      ;;
    3)
      # 次 dev-phase のタスク内容表示
      local next_phase=""
      local found=false
      for dp in "${DEV_PHASES[@]}"; do
        if [ "$found" = "true" ]; then
          next_phase="$dp"
          break
        fi
        if [ "$dp" = "$phase_id" ]; then
          found=true
        fi
      done

      if [ -n "$next_phase" ]; then
        echo -e "" >&2
        echo -e "  次 dev-phase: ${next_phase}" >&2
        jq_safe -r --arg pid "$next_phase" '
          .tasks[] |
          select((.dev_phase_id // "mvp") == $pid) |
          "    - \(.task_id): \(.description)"
        ' "$TASK_STACK" >&2 2>/dev/null
      else
        echo -e "  次の dev-phase はありません" >&2
      fi

      echo -e "" >&2
      echo -e "  [1] 続行  [4] 中断: " >&2
      local choice2
      read -t 60 -r choice2 2>/dev/null || { choice2="1"; log "  (非対話/タイムアウト — 自動続行)"; }
      if [ "$choice2" = "4" ]; then
        return 1
      fi
      return 0
      ;;
    4)
      log "チェックポイントで中断"
      return 1
      ;;
    *)
      log "→ 続行（デフォルト）"
      return 0
      ;;
  esac
}

# ===== dev-phase 完了ハンドラ =====
handle_dev_phase_completion() {
  local phase_id="$1"

  log ""
  log "========== dev-phase [${phase_id}] 完了処理 =========="

  # 1. 回帰テスト実行
  # generate-tasks.sh が生成するスクリプト名は {phase_id}.sh（例: mvp.sh, core.sh）
  local regression_script=".forge/state/phase-tests/${phase_id}.sh"
  if [ -f "$regression_script" ]; then
    log "回帰テスト実行: ${phase_id}"
    local regression_output=""
    if ! regression_output=$(bash "$regression_script" "$phase_id" --keep-server --work-dir "$WORK_DIR" 2>&1); then
      log "✗ 回帰テスト失敗: ${phase_id}"

      # Evidence-DA: 回帰テスト失敗の事前評価
      local _phase_da_dir="${DEV_LOG_DIR}/phase-da-${phase_id}"
      mkdir -p "$_phase_da_dir"
      echo "$regression_output" > "${_phase_da_dir}/regression-output.txt"
      run_evidence_da "phase-${phase_id}" "$_phase_da_dir" "regression_failure" "" "" "$regression_output"

      # S5: 回帰テスト失敗時の自動ロールバック
      if [ "$SAFETY_AUTO_REVERT_ON_REGRESSION" = "true" ] && [ "$WORK_DIR" != "$PROJECT_ROOT" ]; then
        # 現在の dev-phase の最後に完了したタスクの checkpoint を探して復帰
        local last_completed_task
        last_completed_task=$(jq_safe -r --arg pid "$phase_id" '
          [.tasks[] |
            select((.dev_phase_id // "mvp") == $pid) |
            select(.status == "completed")
          ] | last | .task_id // empty
        ' "$TASK_STACK" 2>/dev/null)
        if [ -n "$last_completed_task" ]; then
          log "  [SAFETY] 回帰テスト失敗 — タスク ${last_completed_task} 実行前の状態に自動復帰"
          task_checkpoint_restore "$WORK_DIR" "$last_completed_task"
          notify_human "warning" "回帰テスト失敗: 自動ロールバック実行済み" \
            "dev-phase: ${phase_id}\n復帰ポイント: タスク ${last_completed_task} 実行前"
        fi
      fi

      if [ "$PHASE_CONTROL" = "auto" ]; then
        # auto mode: 警告のみで続行
        notify_human "warning" "dev-phase [${phase_id}] 回帰テスト失敗（auto: 続行）" \
          "run-regression.sh が失敗。テスト結果を確認してください。"
        log "  制御モード: auto — 回帰テスト失敗を警告として続行"
        # サーバー PID クリーンアップ
        local pid_file=".forge/state/server.pid"
        if [ -f "$pid_file" ]; then
          kill "$(cat "$pid_file")" 2>/dev/null || true
          rm -f "$pid_file"
        fi
        # return 1 しない → 続行
      else
        notify_human "critical" "dev-phase [${phase_id}] 回帰テスト失敗" \
          "run-regression.sh が失敗しました。テスト結果を確認してください。"
        local pid_file=".forge/state/server.pid"
        if [ -f "$pid_file" ]; then
          kill "$(cat "$pid_file")" 2>/dev/null || true
          rm -f "$pid_file"
        fi
        return 1
      fi
    fi
  else
    log "  回帰テストスクリプトなし — スキップ"
  fi

  # 2. S7: dev-phase 完了時の自動 git commit
  if [ "$SAFETY_AUTO_COMMIT_PER_PHASE" = "true" ] && [ "$WORK_DIR" != "$PROJECT_ROOT" ]; then
    if git -C "$WORK_DIR" rev-parse --git-dir > /dev/null 2>&1; then
      local changes_to_commit
      changes_to_commit=$(git -C "$WORK_DIR" status --porcelain 2>/dev/null | head -1)
      if [ -n "$changes_to_commit" ]; then
        local completed_in_phase
        completed_in_phase=$(jq --arg pid "$phase_id" \
          '[.tasks[] | select((.dev_phase_id // "mvp") == $pid) | select(.status == "completed")] | length' \
          "$TASK_STACK" 2>/dev/null || echo 0)
        git -C "$WORK_DIR" add -A 2>/dev/null && \
        git -C "$WORK_DIR" commit -m "forge: dev-phase ${phase_id} completed - ${completed_in_phase} tasks" 2>/dev/null && \
        log "  ✓ [SAFETY] dev-phase [${phase_id}] の成果を git commit しました" || \
        log "  ⚠ [SAFETY] git commit に失敗（続行）"
      fi
    fi
  fi

  # 3. checklist 具体化
  run_checklist_concretize "$phase_id"

  # 4. PHASE_CONTROL に応じてチェックポイント表示/スキップ
  local show_checkpoint=false
  case "$PHASE_CONTROL" in
    "auto")
      log "  制御モード: auto — チェックポイントスキップ"
      ;;
    "checkpoint")
      show_checkpoint=true
      ;;
    "mvp-gate")
      if [ "$phase_id" = "mvp" ]; then
        show_checkpoint=true
      else
        log "  制御モード: mvp-gate — mvp以外のチェックポイントスキップ"
      fi
      ;;
  esac

  if [ "$show_checkpoint" = "true" ]; then
    if ! show_dev_phase_checkpoint "$phase_id"; then
      # サーバー PID クリーンアップ
      local pid_file=".forge/state/server.pid"
      if [ -f "$pid_file" ]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
      fi
      return 1
    fi
  fi

  # 5. サーバー PID クリーンアップ
  local pid_file=".forge/state/server.pid"
  if [ -f "$pid_file" ]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
  fi

  return 0
}

# ===== dev-phase 進行 =====
# 現在のdev-phaseの次のdev-phaseに進む。全完了なら空文字を返す。
advance_dev_phase() {
  local found=false
  for dp in "${DEV_PHASES[@]}"; do
    if [ "$found" = "true" ]; then
      CURRENT_DEV_PHASE="$dp"
      log "→ 次の dev-phase: ${CURRENT_DEV_PHASE}"
      return 0
    fi
    if [ "$dp" = "$CURRENT_DEV_PHASE" ]; then
      found=true
    fi
  done
  # 全 dev-phase 完了
  CURRENT_DEV_PHASE=""
  return 0
}
