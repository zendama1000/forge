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
# ===== orphan detector: 新規ファイルの被参照チェック =====
# detect_orphan_files <work_dir> <phase_id>
# dev-phase 中に新規追加された非テスト・非設定ファイルが、他のどのファイルからも
# 参照されていない場合に warning + 台帳記録する（「新設ファイルが consumer から
# 配線されず死蔵したまま完了報告」の実害 2026-05-22 への恒久対処）。常に rc=0
detect_orphan_files() {
  local work_dir="$1"
  local phase_id="$2"

  git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1 || return 0

  # ベースコミット: 直近の dev-phase 完了コミット（S7 auto-commit）。
  # 不在時（初フェーズ等）は初回コミットをベースにする
  local base
  base=$(git -C "$work_dir" log --grep='forge: dev-phase .* completed' -n 1 --format='%H' 2>/dev/null | tr -d '\r')
  if [ -z "$base" ]; then
    base=$(git -C "$work_dir" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1 | tr -d '\r')
  fi
  [ -z "$base" ] && return 0

  # 新規ファイル = base 以降の追加分 + untracked（auto-commit の前に呼ばれる想定）
  local new_files
  new_files=$( { git -C "$work_dir" diff --name-only --diff-filter=A "$base" 2>/dev/null; \
                 git -C "$work_dir" ls-files --others --exclude-standard 2>/dev/null; } | tr -d '\r' | sort -u)
  [ -z "$new_files" ] && return 0

  # allowlist（basename の fnmatch）: エントリポイント/設定/ドキュメント/テストは被参照不要
  local allowlist
  allowlist=$(jq_safe -r '(.orphan_detector.allowlist_patterns //
    ["*.md","*.json","*.yml","*.yaml","*.toml","*.lock","*.test.*","*.spec.*","*.e2e.*","index.*","main.*","*.config.*","*.d.ts",".*"]) | .[]' \
    "${DEV_CONFIG:-/nonexistent}" 2>/dev/null)

  local orphans="" f base_name stem
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    base_name=$(basename "$f")
    local _skip=false pat
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      case "$base_name" in ($pat) _skip=true; break ;; esac
    done <<< "$allowlist"
    [ "$_skip" = "true" ] && continue
    # 拡張子を除いた stem で被参照を検索（自分自身を除く。--untracked で未追跡 consumer も対象）
    stem="${base_name%.*}"
    [ -z "$stem" ] && continue
    if ! git -C "$work_dir" grep --untracked -l -F "$stem" -- . 2>/dev/null | tr -d '\r' | grep -v -F "$f" | head -1 | grep -q .; then
      orphans="${orphans}${orphans:+, }${f}"
    fi
  done <<< "$new_files"

  if [ -n "$orphans" ]; then
    log "  ⚠ orphan detector: 被参照ゼロの新規ファイル: ${orphans}"
    notify_human "warning" "orphan ファイル検出 (dev-phase: ${phase_id})" \
      "新規ファイルがどこからも参照されていない（配線漏れ/死蔵の可能性）: ${orphans}"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "orphan_file" "phase-${phase_id}" \
        "被参照ゼロの新規ファイル（配線漏れの可能性）: ${orphans}"
    fi
  fi
  return 0
}

handle_dev_phase_completion() {
  local phase_id="$1"

  log ""
  log "========== dev-phase [${phase_id}] 完了処理 =========="

  # 0. セットアップコマンド実行（依存解決・ビルド等）
  local _setup_cmds
  _setup_cmds=$(jq_safe -r '.layer_2.setup_commands // [] | .[]' "$DEV_CONFIG" 2>/dev/null)
  if [ -n "$_setup_cmds" ]; then
    local _setup_dir="${WORK_DIR:-$PROJECT_ROOT}"
    log "  セットアップコマンド実行中..."
    while IFS= read -r _scmd; do
      log "    実行: ${_scmd}"
      if ! (cd "$_setup_dir" && eval "$_scmd") >> "${DEV_LOG_DIR}/setup-commands.log" 2>&1; then
        log "    ⚠ セットアップ失敗: ${_scmd}（続行）"
      fi
    done <<< "$_setup_cmds"
    log "  ✓ セットアップ完了"
  fi

  # 1. 回帰テスト実行
  # generate-tasks.sh が生成するスクリプト名は {phase_id}.sh（例: mvp.sh, core.sh）
  # 絶対パス化: cd "$WORK_DIR" で実行するため相対だと解決不能になる
  local regression_script="${PROJECT_ROOT}/.forge/state/phase-tests/${phase_id}.sh"
  if [ -f "$regression_script" ]; then
    log "回帰テスト実行: ${phase_id}"

    # サーバーライフサイクル: スクリプトがサーバーを要するなら到達可能性を保証する
    # （従来は誰も起動せず connection refused → 回帰失敗の誤検知が構造化していた）
    local _srv_needed _srv_rc=0
    _srv_needed=$(phase_test_requires_server "$regression_script")
    if [ "$_srv_needed" = "server" ]; then
      ensure_server_running || _srv_rc=$?
      if [ "$_srv_rc" -eq 2 ]; then
        log "  ⚠ 回帰テスト: サーバー環境不足（${SERVER_LC_REASON}）— server 依存の失敗は繰延扱い"
        if type record_quality_debt &>/dev/null; then
          record_quality_debt "env_blocked" "phase-${phase_id}" \
            "回帰テストがサーバーを要するが環境不足: ${SERVER_LC_REASON}" \
            "{\"command\":\"bash .forge/state/phase-tests/${phase_id}.sh --work-dir .\"}"
        fi
      elif [ "$_srv_rc" -ne 0 ]; then
        notify_human "critical" "dev-phase [${phase_id}] サーバー起動失敗" \
          "${SERVER_LC_REASON}\nhealth code: ${SERVER_LC_LAST_CODE}"
      fi
    fi

    local regression_output=""
    # cwd 修正: 生成スクリプト内の相対パス（scripts/e2e 等）が WORK_DIR 基準で解決されるようにする
    if ! regression_output=$( (cd "$WORK_DIR" && bash "$regression_script" "$phase_id" --keep-server --work-dir "$WORK_DIR") 2>&1); then

      # 環境起因の失敗（サーバー環境不足が判明済み or 出力に環境系エラー署名）は
      # block/ロールバックせず deferred として台帳に記録して続行する（futile ループの根絶）
      local _env_failure=false
      if [ "$_srv_rc" -eq 2 ]; then
        _env_failure=true
      elif type is_environmental_failure &>/dev/null && is_environmental_failure "$regression_output"; then
        _env_failure=true
      fi
      if [ "$_env_failure" = "true" ]; then
        log "  ⚠ 回帰テスト失敗は環境起因 — deferred として続行（fix タスクなし）"
        if type record_quality_debt &>/dev/null; then
          record_quality_debt "deferred_test" "phase-${phase_id}" \
            "回帰テストを環境起因失敗として繰延: $(printf '%s' "$regression_output" | tail -c 300 | tr -d '\000-\037')" \
            "{\"command\":\"bash .forge/state/phase-tests/${phase_id}.sh --work-dir .\"}"
        fi
        teardown_server
      else

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

      local regression_policy
      regression_policy=$(jq_safe -r '.safety.regression_failure_policy // "block"' "$DEV_CONFIG" 2>/dev/null)

      if [ "$PHASE_CONTROL" = "auto" ] || [ "$regression_policy" = "warn_and_continue" ]; then
        # auto mode or warn_and_continue policy: 警告のみで続行
        notify_human "warning" "dev-phase [${phase_id}] 回帰テスト失敗（${regression_policy}: 続行）" \
          "run-regression.sh が失敗。テスト結果を確認してください。"
        log "  制御モード/ポリシー: ${PHASE_CONTROL}/${regression_policy} — 回帰テスト失敗を警告として続行"
        # 黙って劣化しない: warn 化した回帰失敗を台帳に残す
        if type record_quality_debt &>/dev/null; then
          record_quality_debt "warn_gate" "phase-${phase_id}" \
            "回帰テスト失敗を ${regression_policy} ポリシーで警告のみ続行 — フェーズ品質未保証"
        fi
        # サーバークリーンアップ（所有分のみ停止 — 外部所有は触らない）
        teardown_server
        # return 1 しない → 続行
      else
        notify_human "critical" "dev-phase [${phase_id}] 回帰テスト失敗" \
          "run-regression.sh が失敗しました。テスト結果を確認してください。"
        teardown_server
        return 1
      fi
      fi
    fi
  else
    log "  回帰テストスクリプトなし — スキップ"
  fi

  # 1.5. orphan detector: 新規ファイルの被参照チェック（auto-commit 前 — untracked も対象）
  detect_orphan_files "$WORK_DIR" "$phase_id"

  # 1.6. UX 判定（phase_exit 発火 — ux-judgment-and-calibration-spec §5）
  # fix タスクが生成された場合、main ループが phase 続行を検出して advance しない。
  # 常に rc=0（advisory 統合 — 判定失敗で dev ループをブロックしない）
  if type run_ux_judgment_phase_exit &>/dev/null; then
    run_ux_judgment_phase_exit "$phase_id" || true
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
      # サーバークリーンアップ（所有分のみ停止）
      teardown_server
      return 1
    fi
  fi

  # 5. サーバークリーンアップ（所有分のみ停止）
  teardown_server

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
