#!/bin/bash
# phase3.sh — Layer 2 統合テストサブシステム
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   TASK_STACK, WORK_DIR, DEV_CONFIG
#   L2_DEFAULT_TIMEOUT, L2_MAX_TIMEOUT, L2_FAIL_CREATES_TASK

# ===== Phase 3 ヘルパー: 構造化 requires チェック =====
# requires の各エントリを構造化プレフィックスで判定する
# 形式: "server" | "env:VAR" | "cmd:NAME" | "file:PATH" | "VAR"（後方互換: 環境変数）
# 戻り値: 0=OK, 1=NG（skip_reason をセット）
check_l2_requires() {
  local requires_json="$1"
  skip_reason=""

  local req_list
  req_list=$(echo "$requires_json" | jq_safe -r '.[]' 2>/dev/null)

  for req in $req_list; do
    case "$req" in
      server)
        # サーバーが必要 — 呼び出し元で起動管理
        # ここではヘルスチェックのみ（server_http_code でコード別に診断を区別）
        local health_url
        health_url=$(jq_safe -r '.server.health_check_url // ""' "$DEV_CONFIG" 2>/dev/null)
        if [ -n "$health_url" ]; then
          local _hc_code
          _hc_code=$(server_http_code "$health_url")
          case "$_hc_code" in
            2*|3*) : ;;
            000)
              skip_reason="サーバーが応答しない（connection refused: ${health_url}）"
              return 1
              ;;
            *)
              skip_reason="サーバー health check が HTTP ${_hc_code}（${health_url} — health_check_url 設定を確認）"
              return 1
              ;;
          esac
        fi
        ;;
      env:*)
        local var_name="${req#env:}"
        if [ -z "$(printenv "$var_name" 2>/dev/null)" ]; then
          skip_reason="環境変数 ${var_name} が未設定"
          return 1
        fi
        ;;
      cmd:*)
        local cmd_name="${req#cmd:}"
        if ! command -v "$cmd_name" > /dev/null 2>&1; then
          skip_reason="コマンド ${cmd_name} が見つからない"
          return 1
        fi
        ;;
      file:*)
        local file_path="${req#file:}"
        if [ ! -f "${WORK_DIR}/${file_path}" ]; then
          skip_reason="ファイル ${file_path} が見つからない"
          return 1
        fi
        ;;
      *)
        # 後方互換: プレフィックスなし = 環境変数
        if [ -z "$(printenv "$req" 2>/dev/null)" ]; then
          skip_reason="環境変数 ${req} が未設定"
          return 1
        fi
        ;;
    esac
  done
  return 0
}

# ===== Phase 3 ヘルパー: L2 環境セットアップ =====
# development.json の layer_2.setup_commands[] を順次実行
# 戻り値: 0=成功, 1=失敗
setup_l2_environment() {
  local setup_commands
  setup_commands=$(jq_safe -r '.layer_2.setup_commands // [] | .[]' "$DEV_CONFIG" 2>/dev/null)

  if [ -z "$setup_commands" ]; then
    return 0
  fi

  log "  L2 環境セットアップ実行中..."
  while IFS= read -r cmd; do
    log "    実行: ${cmd}"
    if ! (cd "$WORK_DIR" && eval "$cmd") 2>&1; then
      log "  ✗ L2 セットアップ失敗: ${cmd}"
      return 1
    fi
  done <<< "$setup_commands"
  log "  ✓ L2 環境セットアップ完了"
  return 0
}

# ===== Phase 3 ヘルパー: サーバー起動 =====
# server-lifecycle.sh の薄いラッパ（関数名は既存テスト stub 互換のため維持）。
# rc=0: 到達可能 / rc=1: 起動失敗 or 環境不足（環境不足時は L2_SERVER_DEFERRED=true + 台帳記録）
start_l2_server() {
  local rc=0
  ensure_server_running || rc=$?
  if [ "$rc" -eq 0 ]; then
    L2_SERVER_PID="${SERVER_LC_PID:-}"
    return 0
  fi
  L2_SERVER_PID=""
  if [ "$rc" -eq 2 ]; then
    L2_SERVER_DEFERRED=true
    log "  L2 サーバー: 環境不足 — ${SERVER_LC_REASON}"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "env_blocked" "phase3-server" \
        "Phase 3 がサーバーを要するが環境不足: ${SERVER_LC_REASON}"
    fi
  else
    log "  ✗ L2 サーバー起動失敗 — ${SERVER_LC_REASON}"
  fi
  return 1
}

# ===== Phase 3 ヘルパー: サーバー停止 =====
# 所有サーバーのみ停止（外部所有は触らない — server-lifecycle.sh に委譲）
stop_l2_server() {
  teardown_server
  L2_SERVER_PID=""
}

# ===== per-task L3 実行数（イベントログから） =====
# per-task（immediate）L3 は Phase 2 中に実行されるため、Phase 3 のカウンタには
# 現れない。task-events.jsonl の l3_test_completed から実行数を合算する。常に rc=0
_count_per_task_l3_executed() {
  local ev_file="${TASK_EVENTS_FILE:-}"
  local n=0
  if [ -n "$ev_file" ] && [ -f "$ev_file" ]; then
    n=$(jq -s '[.[] | select(.event == "l3_test_completed") | ((.detail.pass // 0) + (.detail.fail // 0))] | add // 0' "$ev_file" 2>/dev/null | tr -d '\r')
  fi
  case "$n" in (*[!0-9]*|"") n=0 ;; esac
  printf '%s' "$n"
  return 0
}

# ===== 行動検証カバレッジ計算（定義ベース + 実行実績ベース） =====
# 使い方: compute_test_coverage_gaps [l2_executed] [l3_executed] [l2_deferred] [l3_deferred]
#   引数省略時は定義ベースのみ（後方互換）。
#   引数指定時は「定義されたが1件も実行されていない」偽陰性を明示する
#   （browser-cockpit で 6 e2e が未実行のまま prominence=none になった実害の修正）。
# 戻り値: stdout に JSON 配列（ギャップを示す文字列リスト）を出力
compute_test_coverage_gaps() {
  local l2_executed="${1:-}" l3_executed="${2:-}" l2_deferred="${3:-}" l3_deferred="${4:-}"

  local total l2_count l3_count
  total=$(jq '[.tasks[] | select(.status == "completed")] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  # batch#11 R13: legacy command だけでなく validation v2 の checks[].layer==2/3 も「定義あり」に数える
  # （旧集計は 4.5f の Phase 3 で L2 0/28 を報告していた — 全タスクが v2 checks だった）
  l2_count=$(jq '[.tasks[] | select(.status == "completed") | select((.validation.layer_2.command != null) or ([.validation.checks[]? | select(.layer == 2)] | length > 0))] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  l3_count=$(jq '[.tasks[] | select(.status == "completed") | select((.validation.layer_3 != null and (.validation.layer_3 | length) > 0) or ([.validation.checks[]? | select(.layer == 3)] | length > 0))] | length' "$TASK_STACK" 2>/dev/null || echo 0)

  local l2_pct=0 l3_pct=0
  [ "$total" -gt 0 ] && l2_pct=$((l2_count * 100 / total))
  [ "$total" -gt 0 ] && l3_pct=$((l3_count * 100 / total))

  local gaps
  gaps=$(jq -n --argjson l2 "$l2_count" --argjson l3 "$l3_count" --argjson total "$total" \
    --argjson l2p "$l2_pct" --argjson l3p "$l3_pct" '
    [
      "L2 tests: \($l2) defined / \($total) tasks (\($l2p)%)",
      "L3 tests: \($l3) defined / \($total) tasks (\($l3p)%)"
    ]
  ')
  if [ "$l3_count" -eq 0 ]; then
    gaps=$(echo "$gaps" | jq '. + ["behavioral verification: NOT PERFORMED — L3 (E2E) 未定義のため実装が仕様通り動作するかは未検証"]')
  fi

  # 実行実績ベースの追記（引数が渡された場合のみ。per-task L3 実行も合算）
  case "$l2_executed" in (*[!0-9]*) l2_executed="" ;; esac
  case "$l3_executed" in (*[!0-9]*) l3_executed="" ;; esac
  case "$l2_deferred" in (*[!0-9]*|"") l2_deferred=0 ;; esac
  case "$l3_deferred" in (*[!0-9]*|"") l3_deferred=0 ;; esac
  if [ -n "$l2_executed" ] && [ "$l2_count" -gt 0 ] && [ "$l2_executed" -eq 0 ]; then
    gaps=$(echo "$gaps" | jq '. + ["L2 tests: defined but NEVER EXECUTED — 定義済みだが1件も実行されていない（integration 未検証）"]')
  fi
  if [ -n "$l3_executed" ]; then
    local l3_total_exec=$((l3_executed + $(_count_per_task_l3_executed)))
    if [ "$l3_count" -gt 0 ] && [ "$l3_total_exec" -eq 0 ]; then
      gaps=$(echo "$gaps" | jq '. + ["L3 tests: defined but NEVER EXECUTED — 定義済みだが1件も実行されていない（behavioral 未検証）"]')
    fi
  fi
  if [ "$l2_deferred" -gt 0 ]; then
    gaps=$(echo "$gaps" | jq --argjson n "$l2_deferred" '. + ["L2 deferred: \($n) 件が環境制約で繰延（PHASE4-HANDOFF.md 参照）"]')
  fi
  if [ "$l3_deferred" -gt 0 ]; then
    gaps=$(echo "$gaps" | jq --argjson n "$l3_deferred" '. + ["L3 deferred: \($n) 件が環境制約で繰延（PHASE4-HANDOFF.md 参照）"]')
  fi
  echo "$gaps"
}

# ===== 行動検証カバレッジの警告レベル判定（実行実績ベース） =====
# 使い方: compute_coverage_prominence [l2_executed] [l3_executed]
# 戻り値: "critical" | "medium" | "none"
#   critical: L3 が未定義、または定義済みでも1件も実行されていない = behavioral 欠落
#   medium:   L3 実行済みだが L2 が未定義/未実行 = integration 欠落
#   none:     両方実行実績あり
# 引数省略時は定義ベースのみ（後方互換）
compute_coverage_prominence() {
  local l2_executed="${1:-}" l3_executed="${2:-}"
  local l2_count l3_count
  # batch#11 R13: legacy command だけでなく validation v2 の checks[].layer==2/3 も「定義あり」に数える
  # （旧集計は 4.5f の Phase 3 で L2 0/28 を報告していた — 全タスクが v2 checks だった）
  l2_count=$(jq '[.tasks[] | select(.status == "completed") | select((.validation.layer_2.command != null) or ([.validation.checks[]? | select(.layer == 2)] | length > 0))] | length' "$TASK_STACK" 2>/dev/null || echo 0)
  l3_count=$(jq '[.tasks[] | select(.status == "completed") | select((.validation.layer_3 != null and (.validation.layer_3 | length) > 0) or ([.validation.checks[]? | select(.layer == 3)] | length > 0))] | length' "$TASK_STACK" 2>/dev/null || echo 0)

  case "$l2_executed" in (*[!0-9]*) l2_executed="" ;; esac
  case "$l3_executed" in (*[!0-9]*) l3_executed="" ;; esac

  if [ -n "$l3_executed" ]; then
    local l3_total_exec=$((l3_executed + $(_count_per_task_l3_executed)))
    if [ "$l3_count" -eq 0 ] || [ "$l3_total_exec" -eq 0 ]; then
      echo "critical"
      return 0
    fi
    if [ "$l2_count" -eq 0 ] || { [ -n "$l2_executed" ] && [ "$l2_executed" -eq 0 ]; }; then
      echo "medium"
      return 0
    fi
    echo "none"
    return 0
  fi

  # 後方互換: 定義ベースのみ
  if [ "$l3_count" -eq 0 ]; then
    echo "critical"
  elif [ "$l2_count" -eq 0 ]; then
    echo "medium"
  else
    echo "none"
  fi
}

# ===== Phase 3: 統合検証（Layer 2 テスト一括実行） =====
run_phase3() {
  log "=========================================="
  log "Phase 3: 統合検証（Layer 2 テスト）開始"
  log "=========================================="
  update_progress "integration" "phase3" "統合検証" "95"

  local report_file=".forge/state/integration-report.json"
  local l2_pass=0
  local l2_fail=0
  local l2_skip=0
  local l2_deferred=0
  local l2_results="[]"
  L2_SERVER_PID=""

  # 全 completed タスクから layer_2 定義あり（legacy command または v2 checks）を収集
  local tasks_with_l2
  tasks_with_l2=$(jq_safe -r '
    .tasks[] |
    select(.status == "completed") |
    select(
      (.validation.layer_2.command != null) or
      ([.validation.checks[]? | select(.layer == 2)] | length > 0)
    ) |
    .task_id
  ' "$TASK_STACK" 2>/dev/null)

  # L3(server 依存) の有無も見る — L2 未定義でも L3 があれば Phase 3 は続行する
  # （従来はここで早期 return し、定義済み L3 が一度も実行されないバグがあった）
  local _l3_server_probe=""
  if [ "${L3_ENABLED:-false}" = "true" ]; then
    _l3_server_probe=$(jq_safe -r '
      .tasks[] |
      select(.status == "completed") |
      select(.validation.layer_3 != null) |
      select([.validation.layer_3[] | select((.requires // []) | map(select(. == "server")) | length > 0)] | length > 0) |
      .task_id
    ' "$TASK_STACK" 2>/dev/null)
  fi

  if [ -z "$tasks_with_l2" ] && [ -z "$_l3_server_probe" ]; then
    log "  Layer 2 テスト定義のあるタスクがありません"
    log "  ⚠ 行動検証（L2/L3）未定義 — 実装が仕様通りに動作するかは未検証です"
    local _gaps_json
    _gaps_json=$(compute_test_coverage_gaps)
    jq -n --argjson gaps "$_gaps_json" '{
      phase: 3,
      status: "completed_with_gaps",
      warning_prominence: "critical",
      summary: {pass: 0, fail: 0, skip: 0},
      results: [],
      test_coverage_gaps: $gaps,
      generated_at: (now | todate)
    }' > "$report_file"
    return 0
  fi

  if [ -z "$tasks_with_l2" ]; then
    log "  Layer 2 テスト定義なし — L3(server 依存) セクションへ進む"
  fi

  # L2 環境セットアップ
  if ! setup_l2_environment; then
    log "  ✗ L2 環境セットアップ失敗 — Phase 3 スキップ"
    jq -n '{
      phase: 3,
      status: "setup_failed",
      summary: {pass: 0, fail: 0, skip: 0},
      results: [],
      generated_at: (now | todate)
    }' > "$report_file"
    return 1
  fi

  # サーバー必要性チェック: いずれかのタスクが "server" requires を持つか
  #（v2 checks は http_check 暗黙 server + 明示 requires を checks_require_server で判定）
  local needs_server=false
  for task_id in $tasks_with_l2; do
    local has_server_req
    has_server_req=$(jq_safe -r --arg id "$task_id" '
      .tasks[] | select(.task_id == $id) |
      .validation.layer_2.requires // [] | map(select(. == "server")) | length
    ' "$TASK_STACK" 2>/dev/null || echo 0)
    if [ "$has_server_req" -gt 0 ]; then
      needs_server=true
      break
    fi
    if type checks_require_server &>/dev/null; then
      if checks_require_server "$(get_task_json "$task_id")" 2; then
        needs_server=true
        break
      fi
    fi
  done

  # サーバー起動（必要な場合）
  if [ "$needs_server" = "true" ]; then
    if ! start_l2_server; then
      log "  ✗ L2 サーバー起動失敗 — server requires のテストをスキップ"
    fi
  fi

  for task_id in $tasks_with_l2; do
    local task_json
    task_json=$(get_task_json "$task_id")

    local l2_command
    l2_command=$(echo "$task_json" | jq_safe -r '.validation.layer_2.command')
    local l2_requires_json
    l2_requires_json=$(echo "$task_json" | jq_safe -c '.validation.layer_2.requires // []' 2>/dev/null)
    local l2_timeout
    l2_timeout=$(echo "$task_json" | jq_safe -r ".validation.layer_2.timeout_sec // $L2_DEFAULT_TIMEOUT")

    # タイムアウト上限クランプ
    if [ "$l2_timeout" -gt "$L2_MAX_TIMEOUT" ] 2>/dev/null; then
      l2_timeout="$L2_MAX_TIMEOUT"
    fi
    # effort 連動倍率: agent_effort.implementer に応じて拡張（クランプ後の base に適用、0=無制限は維持）
    l2_timeout=$(apply_effort_timeout "$l2_timeout" "$(resolve_agent_effort implementer "${DEV_CONFIG:-}")")

    # ===== validation v2（batch#8 Stage3）: layer 2 に checks があれば v2 が権威 =====
    # per-check の deferred/SKIP/債務記録は run_layer_checks 内で処理される。
    # タスク単位の集計（l2_results 形状・債務語彙）は legacy と同一を維持する。
    if type task_layer_is_v2 &>/dev/null && task_layer_is_v2 "$task_json" 2; then
      log "  Layer 2 検証実行 (v2 checks): ${task_id}"
      local v2_out v2_rc=0 v2_exec v2_defer
      v2_out=$(run_layer_checks "$task_json" 2 "$WORK_DIR" "$l2_timeout" "$task_id" 2>&1) || v2_rc=$?
      v2_exec=$(printf '%s' "$v2_out" | grep -oE 'executed=[0-9]+' | tail -1 | cut -d= -f2)
      v2_defer=$(printf '%s' "$v2_out" | grep -oE 'deferred=[0-9]+' | tail -1 | cut -d= -f2)
      case "$v2_exec" in (''|*[!0-9]*) v2_exec=0 ;; esac
      case "$v2_defer" in (''|*[!0-9]*) v2_defer=0 ;; esac

      if [ "$v2_rc" -eq 0 ]; then
        if [ "$v2_exec" -eq 0 ] && [ "$v2_defer" -gt 0 ]; then
          log "  ⚠ DEFERRED: ${task_id} — 全 v2 check が繰延"
          l2_deferred=$((l2_deferred + 1))
          l2_results=$(echo "$l2_results" | jq --arg id "$task_id" \
            '. += [{task_id: $id, result: "deferred", reason: "全 v2 check が繰延"}]')
        else
          log "  ✓ PASS: ${task_id} (v2)"
          l2_pass=$((l2_pass + 1))
          l2_results=$(echo "$l2_results" | jq --arg id "$task_id" \
            '. += [{task_id: $id, result: "pass"}]')
          if type resolve_quality_debts_matching &>/dev/null; then
            resolve_quality_debts_matching "$task_id" "deferred_test,env_blocked,l2_skip" "" "L2 v2 pass in phase3"
          fi
        fi
      elif is_environmental_failure "$v2_out"; then
        log "  ⚠ DEFERRED: ${task_id} — 環境起因の失敗（fix タスクなし・台帳記録）"
        l2_deferred=$((l2_deferred + 1))
        l2_results=$(echo "$l2_results" | jq --arg id "$task_id" \
          '. += [{task_id: $id, result: "deferred", reason: "環境起因の失敗"}]')
        if type record_quality_debt &>/dev/null; then
          record_quality_debt "env_blocked" "$task_id" \
            "L2(v2) を環境起因失敗として繰延: $(printf '%s' "$v2_out" | tail -c 300 | tr -d '\000-\037')"
        fi
      else
        log "  ✗ FAIL: ${task_id} (v2)"
        l2_fail=$((l2_fail + 1))
        local v2_sanitized
        v2_sanitized=$(printf '%s' "$v2_out" | tr -d '\000-\010\013\014\016-\037' | head -c 10000)
        l2_results=$(echo "$l2_results" | jq --arg id "$task_id" --arg out "$v2_sanitized" \
          '. += [{task_id: $id, result: "fail", output: $out}]')
        if [ "$L2_FAIL_CREATES_TASK" = "true" ]; then
          create_l2_fix_task "$task_id" "$v2_out"
        fi
      fi
      continue
    fi

    # deferred 指定の L2 は実行せず台帳記録（環境制約の明示繰延）
    local l2_is_deferred
    l2_is_deferred=$(echo "$task_json" | jq_safe -r '.validation.layer_2.deferred // false' 2>/dev/null)
    if [ "$l2_is_deferred" = "true" ]; then
      local l2_def_reason
      l2_def_reason=$(echo "$task_json" | jq_safe -r '.validation.layer_2.deferred_reason // "明示的 deferred 指定"' 2>/dev/null)
      log "  DEFERRED: ${task_id} — ${l2_def_reason}"
      l2_deferred=$((l2_deferred + 1))
      l2_results=$(echo "$l2_results" | jq --arg id "$task_id" --arg reason "$l2_def_reason" \
        '. += [{task_id: $id, result: "deferred", reason: $reason}]')
      if type record_quality_debt &>/dev/null; then
        record_quality_debt "deferred_test" "$task_id" "L2 を繰延: ${l2_def_reason}" \
          "$(jq -n -c --arg c "$l2_command" '{command: $c}')"
      fi
      continue
    fi

    # 構造化 requires チェック
    local skip_reason=""
    if ! check_l2_requires "$l2_requires_json"; then
      log "  SKIP: ${task_id} — ${skip_reason}"
      l2_skip=$((l2_skip + 1))
      l2_results=$(echo "$l2_results" | jq --arg id "$task_id" --arg reason "$skip_reason" \
        '. += [{task_id: $id, result: "skip", reason: $reason}]')
      if type record_quality_debt &>/dev/null; then
        record_quality_debt "l2_skip" "$task_id" "L2 skip: ${skip_reason}" \
          "$(jq -n -c --arg c "$l2_command" '{command: $c}')"
      fi
      continue
    fi

    # テスト実行
    log "  Layer 2 テスト実行: ${task_id} — ${l2_command} (timeout: ${l2_timeout}s)"
    local test_output
    if test_output=$(timeout "$l2_timeout" env PATH="$WORK_DIR/node_modules/.bin:$PATH" bash -c "cd '$WORK_DIR' && $l2_command" 2>&1); then
      log "  ✓ PASS: ${task_id}"
      l2_pass=$((l2_pass + 1))
      l2_results=$(echo "$l2_results" | jq --arg id "$task_id" \
        '. += [{task_id: $id, result: "pass"}]')
      # 過去に繰延/skip された同タスクの L2 債務は実行 PASS で解消（batch#8 Fix3）
      if type resolve_quality_debts_matching &>/dev/null; then
        resolve_quality_debts_matching "$task_id" "deferred_test,env_blocked,l2_skip" "" "L2 pass in phase3"
      fi
    else
      local exit_code=$?
      # 環境起因の失敗は fix タスクを作らず deferred（futile ループの根絶）
      if is_environmental_failure "$test_output"; then
        log "  ⚠ DEFERRED: ${task_id} — 環境起因の失敗（fix タスクなし・台帳記録）"
        l2_deferred=$((l2_deferred + 1))
        l2_results=$(echo "$l2_results" | jq --arg id "$task_id" \
          '. += [{task_id: $id, result: "deferred", reason: "環境起因の失敗"}]')
        if type record_quality_debt &>/dev/null; then
          record_quality_debt "env_blocked" "$task_id" \
            "L2 を環境起因失敗として繰延: $(printf '%s' "$test_output" | tail -c 300 | tr -d '\000-\037')" \
            "$(jq -n -c --arg c "$l2_command" '{command: $c}')"
        fi
      else
        log "  ✗ FAIL: ${task_id} (exit: ${exit_code})"
        l2_fail=$((l2_fail + 1))
        local sanitized_output
        sanitized_output=$(printf '%s' "$test_output" | tr -d '\000-\010\013\014\016-\037' | head -c 10000)
        l2_results=$(echo "$l2_results" | jq --arg id "$task_id" --arg out "$sanitized_output" \
          '. += [{task_id: $id, result: "fail", output: $out}]')

        if [ "$L2_FAIL_CREATES_TASK" = "true" ]; then
          create_l2_fix_task "$task_id" "$test_output"
        fi
      fi
    fi
  done

  # ===== Layer 3 受入テスト（サーバー依存分） =====
  local l3_pass=0 l3_fail=0 l3_skip=0 l3_deferred=0 l3_results="[]"

  if [ "${L3_ENABLED:-false}" = "true" ]; then
    # 全 completed タスクから server requires 付き L3 テストを収集
    local tasks_with_l3_server
    tasks_with_l3_server=$(jq_safe -r '
      .tasks[] |
      select(.status == "completed") |
      select(.validation.layer_3 != null) |
      select([.validation.layer_3[] | select((.requires // []) | map(select(. == "server")) | length > 0)] | length > 0) |
      .task_id
    ' "$TASK_STACK" 2>/dev/null)

    if [ -n "$tasks_with_l3_server" ]; then
      log ""
      log "--- Layer 3 受入テスト（サーバー依存） ---"

      # サーバーが起動していない場合は起動を試みる
      if [ -z "${L2_SERVER_PID:-}" ] || ! kill -0 "$L2_SERVER_PID" 2>/dev/null; then
        if ! start_l2_server; then
          log "  ✗ L3 サーバー起動失敗 — サーバー依存 L3 テストをスキップ"
          tasks_with_l3_server=""
        fi
      fi

      for task_id in $tasks_with_l3_server; do
        local task_json
        task_json=$(get_task_json "$task_id")

        # サーバー依存の L3 テストのみ抽出
        local l3_server_tests l3_server_count
        l3_server_tests=$(filter_l3_tests "$task_json" "server")
        l3_server_count=$(echo "$l3_server_tests" | jq 'length' 2>/dev/null || echo 0)

        local j=0
        while [ "$j" -lt "$l3_server_count" ]; do
          local l3_test l3_id l3_strategy l3_blocking
          l3_test=$(echo "$l3_server_tests" | jq -c ".[$j]")
          l3_id=$(echo "$l3_test" | jq_safe -r '.id')
          l3_strategy=$(echo "$l3_test" | jq_safe -r '.strategy')
          # 注意: `.blocking // true` は false を潰す（ralph-loop.sh の has() 判定と同じ罠）
          l3_blocking=$(echo "$l3_test" | jq_safe -r 'if (.blocking | type) == "boolean" then .blocking else true end')

          log "  L3 [${l3_id}] task=${task_id} strategy=${l3_strategy}"

          # effort 連動倍率: agent_effort.implementer に応じて拡張（0=無制限は維持、結果は base 以上の整数）
          local l3_timeout
          l3_timeout=$(apply_effort_timeout "${L3_DEFAULT_TIMEOUT:-120}" "$(resolve_agent_effort implementer "${DEV_CONFIG:-}")")

          local l3_output l3_exit=0
          l3_output=$(execute_l3_test "$l3_test" "$WORK_DIR" "$l3_timeout" 2>&1) || l3_exit=$?

          if [ "$l3_exit" -eq 0 ]; then
            log "  ✓ L3 PASS: ${l3_id}"
            l3_pass=$((l3_pass + 1))
            l3_results=$(echo "$l3_results" | jq --arg id "$l3_id" --arg tid "$task_id" \
              '. += [{test_id: $id, task_id: $tid, result: "pass"}]')
            # 過去に繰延/skip された同テストの債務は実行 PASS で解消（batch#8 Fix3）
            if type resolve_quality_debts_matching &>/dev/null; then
              resolve_quality_debts_matching "$task_id" "deferred_test,env_blocked,l3_skip" "$l3_id" "L3 pass in phase3"
            fi
          elif [ "$l3_exit" -eq 2 ]; then
            log "  ⚠ L3 SKIP: ${l3_id}"
            l3_skip=$((l3_skip + 1))
            l3_results=$(echo "$l3_results" | jq --arg id "$l3_id" --arg tid "$task_id" \
              '. += [{test_id: $id, task_id: $tid, result: "skip"}]')
            if type record_quality_debt &>/dev/null; then
              record_quality_debt "l3_skip" "$task_id" \
                "L3 [${l3_id}] skip (strategy=${l3_strategy}): $(printf '%s' "$l3_output" | tail -c 200 | tr -d '\000-\037')"
            fi
          else
            # 環境起因の失敗は fix タスクを作らず deferred（futile ループの根絶）
            if is_environmental_failure "$l3_output"; then
              log "  ⚠ L3 DEFERRED: ${l3_id} — 環境起因の失敗（fix タスクなし・台帳記録）"
              l3_deferred=$((l3_deferred + 1))
              l3_results=$(echo "$l3_results" | jq --arg id "$l3_id" --arg tid "$task_id" \
                '. += [{test_id: $id, task_id: $tid, result: "deferred", reason: "環境起因の失敗"}]')
              if type record_quality_debt &>/dev/null; then
                record_quality_debt "env_blocked" "$task_id" \
                  "L3 [${l3_id}] を環境起因失敗として繰延: $(printf '%s' "$l3_output" | tail -c 300 | tr -d '\000-\037')" \
                  "$(jq -n -c --arg t "$l3_id" '{test_id: $t}')"
              fi
            else
              log "  ✗ L3 FAIL: ${l3_id}"
              l3_fail=$((l3_fail + 1))
              local sanitized_l3
              sanitized_l3=$(printf '%s' "$l3_output" | tr -d '\000-\010\013\014\016-\037' | head -c 5000)
              l3_results=$(echo "$l3_results" | jq --arg id "$l3_id" --arg tid "$task_id" --arg out "$sanitized_l3" \
                '. += [{test_id: $id, task_id: $tid, result: "fail", output: $out}]')

              if [ "$l3_blocking" = "true" ] && [ "${L3_FAIL_CREATES_TASK:-true}" = "true" ]; then
                create_l3_fix_task "$task_id" "$l3_id" "$l3_output"
              fi
            fi
          fi

          j=$((j + 1))
        done
      done

      log "  Layer 3 結果: pass=${l3_pass} fail=${l3_fail} skip=${l3_skip} deferred=${l3_deferred}"
    fi
  fi

  # サーバー停止（起動した場合）
  stop_l2_server

  # integration-report.json 生成
  local status="pass"
  if [ "$l2_fail" -gt 0 ] || [ "$l3_fail" -gt 0 ]; then
    status="fail"
  fi

  # 実行実績（pass+fail = 実際に走った数。skip/deferred は未実行）
  local _l2_exec=$((l2_pass + l2_fail))
  local _l3_exec=$((l3_pass + l3_fail))
  local _gaps_json _prom
  _gaps_json=$(compute_test_coverage_gaps "$_l2_exec" "$_l3_exec" "$l2_deferred" "$l3_deferred")
  _prom=$(compute_coverage_prominence "$_l2_exec" "$_l3_exec")

  # Locked Decision Assertions の全件検査（batch#11: 毎タスク後はタスク参照分のみに絞ったので、
  # 最終成果物を前提にした assertion はここで見る）。違反は債務 + gaps + 通知に残す（黙って劣化しない）
  local _ld_violations=0 _ld_report=""
  if [ -n "${RESEARCH_CONFIG:-}" ] && [ -f "${RESEARCH_CONFIG}" ] && type validate_locked_assertions &>/dev/null; then
    if ! _ld_report=$(validate_locked_assertions "$RESEARCH_CONFIG" "$WORK_DIR" "phase3" ""); then
      _ld_violations=$(printf '%s\n' "$_ld_report" | grep -c '^VIOLATION' || true)
      case "$_ld_violations" in (''|*[!0-9]*) _ld_violations=1 ;; esac
      printf '%s\n' "$_ld_report" > ".forge/state/locked-assertion-violations.txt" 2>/dev/null || true
      log "  ✗ Locked Decision Assertions（全件）: ${_ld_violations} 件の違反 → .forge/state/locked-assertion-violations.txt"
      _gaps_json=$(printf '%s' "$_gaps_json" | jq --arg n "$_ld_violations" '. + ["Locked Decision Assertions: \($n) 件の違反（locked-assertion-violations.txt）"]' 2>/dev/null || printf '%s' "$_gaps_json")
      if type record_quality_debt &>/dev/null; then
        record_quality_debt "locked_assertion_violation" "phase3" "Locked Decision Assertions の全件検査で ${_ld_violations} 件の違反" 2>/dev/null || true
      fi
      if type notify_human &>/dev/null; then
        notify_human "warning" "Locked Decision Assertions 違反（統合検証）" "${_ld_violations} 件。詳細: .forge/state/locked-assertion-violations.txt" 2>/dev/null || true
      fi
    else
      log "  ✓ Locked Decision Assertions（全件）通過"
    fi
  fi

  # 品質債務の集約（quality-ledger.sh 読み込み済みの場合）
  local _debts_json='{"total":0,"unresolved":0,"by_type":{}}'
  if type summarize_quality_debts &>/dev/null; then
    _debts_json=$(summarize_quality_debts)
  fi

  jq -n \
    --arg status "$status" \
    --arg prom "$_prom" \
    --argjson l2_pass "$l2_pass" \
    --argjson l2_fail "$l2_fail" \
    --argjson l2_skip "$l2_skip" \
    --argjson l2_deferred "$l2_deferred" \
    --argjson l2_results "$l2_results" \
    --argjson l3_pass "$l3_pass" \
    --argjson l3_fail "$l3_fail" \
    --argjson l3_skip "$l3_skip" \
    --argjson l3_deferred "$l3_deferred" \
    --argjson l3_results "$l3_results" \
    --argjson gaps "$_gaps_json" \
    --argjson debts "$_debts_json" \
    --argjson ld_violations "$_ld_violations" \
    '{
      phase: 3,
      status: $status,
      warning_prominence: $prom,
      layer_2: {pass: $l2_pass, fail: $l2_fail, skip: $l2_skip, deferred: $l2_deferred, results: $l2_results},
      layer_3: {pass: $l3_pass, fail: $l3_fail, skip: $l3_skip, deferred: $l3_deferred, results: $l3_results},
      summary: {
        pass: ($l2_pass + $l3_pass),
        fail: ($l2_fail + $l3_fail),
        skip: ($l2_skip + $l3_skip),
        deferred: ($l2_deferred + $l3_deferred),
        l2: {pass: $l2_pass, fail: $l2_fail, skip: $l2_skip, deferred: $l2_deferred},
        l3: {pass: $l3_pass, fail: $l3_fail, skip: $l3_skip, deferred: $l3_deferred}
      },
      quality_debts: $debts,
      locked_assertion_violations: $ld_violations,
      test_coverage_gaps: $gaps,
      generated_at: (now | todate)
    }' > "$report_file"

  log "Phase 3 結果: L2(pass=${l2_pass} fail=${l2_fail} skip=${l2_skip} deferred=${l2_deferred}) L3(pass=${l3_pass} fail=${l3_fail} skip=${l3_skip} deferred=${l3_deferred})"
  log "レポート → ${report_file}"
}

# ===== Layer 2 失敗時の差戻しタスク生成 =====
create_l2_fix_task() {
  local original_task_id="$1"
  local fail_output="$2"

  # 元タスクの validation + dev_phase_id をコピーし、新タスクとして追加
  local original_validation
  original_validation=$(jq --arg id "$original_task_id" \
    '.tasks[] | select(.task_id == $id) | .validation // {}' "$TASK_STACK")

  # dedup: 同一 origin_task_id + 同一 L2 フィンガープリントの pending fix が既存なら append をスキップ。
  # Phase3→Phase2 リトライでの fix 累積を防止する（completed/failed は対象外: pending のみ dedup）。
  # v2 タスクは layer-2 checks の構造等価で照合（batch#8 Stage3 — 空 command 衝突の防止）
  local l2_command l2_checks_fp="[]"
  l2_command=$(echo "$original_validation" | jq_safe -r '.layer_2.command // ""')
  if type v2_layer_fingerprint &>/dev/null; then
    l2_checks_fp=$(v2_layer_fingerprint "$original_validation" 2)
  fi
  local existing_fix
  if existing_fix=$(l2_fix_pending_duplicate "$TASK_STACK" "$original_task_id" "$l2_command" "$l2_checks_fp"); then
    log "  Layer 2 差戻しタスク重複検出 — append スキップ（既存 pending fix: ${existing_fix}）"
    return 0
  fi

  # origin 毎キャップ: fix 増殖の上限（futile ループの防波堤）
  if ! _fix_cap_allows "$original_task_id" "L2"; then
    return 0
  fi

  local fix_task_id="${original_task_id}-l2fix-$(date +%H%M%S)"
  local original_desc
  original_desc=$(jq_safe -r --arg id "$original_task_id" \
    '.tasks[] | select(.task_id == $id) | .description // "不明"' "$TASK_STACK")

  local original_dev_phase
  original_dev_phase=$(jq_safe -r --arg id "$original_task_id" \
    '.tasks[] | select(.task_id == $id) | .dev_phase_id // "mvp"' "$TASK_STACK")

  jq --arg fix_id "$fix_task_id" \
     --arg orig_id "$original_task_id" \
     --arg desc "Layer 2修正: ${original_desc}" \
     --arg fail_out "$fail_output" \
     --arg dev_phase "$original_dev_phase" \
     --argjson validation "$original_validation" \
     '
    .tasks += [{
      task_id: $fix_id,
      description: $desc,
      task_type: "implementation",
      dev_phase_id: $dev_phase,
      depends_on: [],
      status: "pending",
      fail_count: 0,
      investigator_fix: ("Layer 2テスト失敗出力:\n" + $fail_out),
      retry_after_investigation: false,
      validation: $validation,
      allows_test_edits: true,
      l2_fix_for: $orig_id,
      created_at: (now | todate),
      updated_at: (now | todate)
    }] |
    .updated_at = (now | todate)
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
  sync_task_stack

  log "  Layer 2 差戻しタスク追加: ${fix_task_id} (dev_phase: ${original_dev_phase})"
}

# ===== fix タスク生成の origin 毎キャップ判定 =====
# _fix_cap_allows <origin_task_id> <layer_label>
# 戻り値: 0 = 生成可 / 1 = 上限到達（fix_cap_reached を台帳記録して生成拒否）
_fix_cap_allows() {
  local origin_id="$1"
  local layer_label="$2"
  local cap
  cap=$(jq_safe -r '.development_limits.max_fix_tasks_per_origin // 3' "${CIRCUIT_BREAKER_CONFIG:-/nonexistent}" 2>/dev/null)
  case "$cap" in (*[!0-9]*|"") cap=3 ;; esac
  local current
  current=$(fix_tasks_for_origin_count "$TASK_STACK" "$origin_id")
  if [ "$current" -ge "$cap" ]; then
    log "  ⚠ ${layer_label} 差戻しタスク生成拒否: origin=${origin_id} の fix が上限到達（${current}/${cap}）"
    notify_human "warning" "fix タスク上限到達: ${origin_id}" \
      "同一タスクへの fix が ${cap} 件に達したため生成を停止。人間による調査が必要（futile ループ防止）"
    if type record_quality_debt &>/dev/null; then
      record_quality_debt "fix_cap_reached" "$origin_id" \
        "${layer_label} fix タスクが上限（${cap}）到達 — 以後の fix 生成を停止。人間による調査が必要"
    fi
    return 1
  fi
  return 0
}

# ===== Layer 3 失敗時の差戻しタスク生成 =====
create_l3_fix_task() {
  local original_task_id="$1"
  local l3_test_id="$2"
  local fail_output="$3"

  # dedup: 同一 origin + 同一 L3 テスト ID の pending fix が既存なら append をスキップ
  # （browser-cockpit で dedup 欠如により fix が増殖した実害への対処）
  local existing_l3_fix
  if existing_l3_fix=$(l3_fix_pending_duplicate "$TASK_STACK" "$original_task_id" "$l3_test_id"); then
    log "  Layer 3 差戻しタスク重複検出 — append スキップ（既存 pending fix: ${existing_l3_fix}）"
    return 0
  fi

  # origin 毎キャップ: fix 増殖の上限（futile ループの防波堤）
  if ! _fix_cap_allows "$original_task_id" "L3"; then
    return 0
  fi

  local fix_task_id="${original_task_id}-l3fix-$(date +%H%M%S)"
  local original_desc
  original_desc=$(jq_safe -r --arg id "$original_task_id" \
    '.tasks[] | select(.task_id == $id) | .description // "不明"' "$TASK_STACK")

  local original_validation
  original_validation=$(jq --arg id "$original_task_id" \
    '.tasks[] | select(.task_id == $id) | .validation // {}' "$TASK_STACK")
  local original_dev_phase
  original_dev_phase=$(jq_safe -r --arg id "$original_task_id" \
    '.tasks[] | select(.task_id == $id) | .dev_phase_id // "mvp"' "$TASK_STACK")

  jq --arg fix_id "$fix_task_id" \
     --arg orig_id "$original_task_id" \
     --arg l3_id "$l3_test_id" \
     --arg desc "Layer 3修正: ${original_desc} (${l3_test_id})" \
     --arg fail_out "$fail_output" \
     --arg dev_phase "$original_dev_phase" \
     --argjson validation "$original_validation" \
     '
    .tasks += [{
      task_id: $fix_id,
      description: $desc,
      task_type: "implementation",
      dev_phase_id: $dev_phase,
      depends_on: [],
      status: "pending",
      fail_count: 0,
      investigator_fix: ("Layer 3受入テスト失敗 [" + $l3_id + "] 出力:\n" + $fail_out),
      retry_after_investigation: false,
      validation: $validation,
      allows_test_edits: true,
      l3_fix_for: $orig_id,
      l3_test_id: $l3_id,
      created_at: (now | todate),
      updated_at: (now | todate)
    }] |
    .updated_at = (now | todate)
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
  sync_task_stack

  log "  Layer 3 差戻しタスク追加: ${fix_task_id} (L3: ${l3_test_id}, dev_phase: ${original_dev_phase})"
}
