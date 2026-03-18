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
        # ここではヘルスチェックのみ
        local health_url
        health_url=$(jq_safe -r '.server.health_check_url // ""' "$DEV_CONFIG" 2>/dev/null)
        if [ -n "$health_url" ] && ! curl -sf "$health_url" > /dev/null 2>&1; then
          skip_reason="サーバーが応答しない（${health_url}）"
          return 1
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
start_l2_server() {
  local start_cmd health_url max_wait
  start_cmd=$(jq_safe -r '.server.start_command // "npm start"' "$DEV_CONFIG")
  health_url=$(jq_safe -r '.server.health_check_url // "http://localhost:3000"' "$DEV_CONFIG")
  max_wait=$(jq_safe -r '.server.startup_timeout_sec // 30' "$DEV_CONFIG")

  log "  L2 サーバー起動: ${start_cmd} (dir: ${WORK_DIR})"
  (cd "$WORK_DIR" && eval "$start_cmd") &
  L2_SERVER_PID=$!

  for i in $(seq 1 "$max_wait"); do
    if curl -sf "$health_url" > /dev/null 2>&1; then
      log "  ✓ L2 サーバー起動完了 (${i}秒, PID: ${L2_SERVER_PID})"
      return 0
    fi
    sleep 1
  done

  log "  ✗ L2 サーバー起動タイムアウト (${max_wait}秒)"
  kill "$L2_SERVER_PID" 2>/dev/null || true
  wait "$L2_SERVER_PID" 2>/dev/null || true
  L2_SERVER_PID=""
  return 1
}

# ===== Phase 3 ヘルパー: サーバー停止 =====
stop_l2_server() {
  if [ -n "${L2_SERVER_PID:-}" ]; then
    log "  L2 サーバー停止 (PID: ${L2_SERVER_PID})"
    kill "$L2_SERVER_PID" 2>/dev/null || true
    wait "$L2_SERVER_PID" 2>/dev/null || true
    L2_SERVER_PID=""
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
  local l2_results="[]"
  L2_SERVER_PID=""

  # 全 completed タスクから layer_2.command 定義ありを収集
  local tasks_with_l2
  tasks_with_l2=$(jq_safe -r '
    .tasks[] |
    select(.status == "completed") |
    select(.validation.layer_2.command != null) |
    .task_id
  ' "$TASK_STACK" 2>/dev/null)

  if [ -z "$tasks_with_l2" ]; then
    log "  Layer 2 テスト定義のあるタスクがありません"
    jq -n '{
      phase: 3,
      status: "no_tests",
      summary: {pass: 0, fail: 0, skip: 0},
      results: [],
      generated_at: (now | todate)
    }' > "$report_file"
    return 0
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

    # 構造化 requires チェック
    local skip_reason=""
    if ! check_l2_requires "$l2_requires_json"; then
      log "  SKIP: ${task_id} — ${skip_reason}"
      l2_skip=$((l2_skip + 1))
      l2_results=$(echo "$l2_results" | jq --arg id "$task_id" --arg reason "$skip_reason" \
        '. += [{task_id: $id, result: "skip", reason: $reason}]')
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
    else
      local exit_code=$?
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
  done

  # ===== Layer 3 受入テスト（サーバー依存分） =====
  local l3_pass=0 l3_fail=0 l3_skip=0 l3_results="[]"

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
          l3_blocking=$(echo "$l3_test" | jq_safe -r '.blocking // true')

          log "  L3 [${l3_id}] task=${task_id} strategy=${l3_strategy}"

          local l3_output l3_exit=0
          l3_output=$(execute_l3_test "$l3_test" "$WORK_DIR" "${L3_DEFAULT_TIMEOUT:-120}" 2>&1) || l3_exit=$?

          if [ "$l3_exit" -eq 0 ]; then
            log "  ✓ L3 PASS: ${l3_id}"
            l3_pass=$((l3_pass + 1))
            l3_results=$(echo "$l3_results" | jq --arg id "$l3_id" --arg tid "$task_id" \
              '. += [{test_id: $id, task_id: $tid, result: "pass"}]')
          elif [ "$l3_exit" -eq 2 ]; then
            log "  ⚠ L3 SKIP: ${l3_id}"
            l3_skip=$((l3_skip + 1))
            l3_results=$(echo "$l3_results" | jq --arg id "$l3_id" --arg tid "$task_id" \
              '. += [{test_id: $id, task_id: $tid, result: "skip"}]')
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

          j=$((j + 1))
        done
      done

      log "  Layer 3 結果: pass=${l3_pass} fail=${l3_fail} skip=${l3_skip}"
    fi
  fi

  # サーバー停止（起動した場合）
  stop_l2_server

  # integration-report.json 生成
  local status="pass"
  if [ "$l2_fail" -gt 0 ] || [ "$l3_fail" -gt 0 ]; then
    status="fail"
  fi

  jq -n \
    --arg status "$status" \
    --argjson l2_pass "$l2_pass" \
    --argjson l2_fail "$l2_fail" \
    --argjson l2_skip "$l2_skip" \
    --argjson l2_results "$l2_results" \
    --argjson l3_pass "$l3_pass" \
    --argjson l3_fail "$l3_fail" \
    --argjson l3_skip "$l3_skip" \
    --argjson l3_results "$l3_results" \
    '{
      phase: 3,
      status: $status,
      layer_2: {pass: $l2_pass, fail: $l2_fail, skip: $l2_skip, results: $l2_results},
      layer_3: {pass: $l3_pass, fail: $l3_fail, skip: $l3_skip, results: $l3_results},
      summary: {
        l2: {pass: $l2_pass, fail: $l2_fail, skip: $l2_skip},
        l3: {pass: $l3_pass, fail: $l3_fail, skip: $l3_skip}
      },
      generated_at: (now | todate)
    }' > "$report_file"

  log "Phase 3 結果: L2(pass=${l2_pass} fail=${l2_fail} skip=${l2_skip}) L3(pass=${l3_pass} fail=${l3_fail} skip=${l3_skip})"
  log "レポート → ${report_file}"
}

# ===== Layer 2 失敗時の差戻しタスク生成 =====
create_l2_fix_task() {
  local original_task_id="$1"
  local fail_output="$2"

  local fix_task_id="${original_task_id}-l2fix-$(date +%H%M%S)"
  local original_desc
  original_desc=$(jq_safe -r --arg id "$original_task_id" \
    '.tasks[] | select(.task_id == $id) | .description // "不明"' "$TASK_STACK")

  # 元タスクの validation + dev_phase_id をコピーし、新タスクとして追加
  local original_validation
  original_validation=$(jq --arg id "$original_task_id" \
    '.tasks[] | select(.task_id == $id) | .validation // {}' "$TASK_STACK")
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
      l2_fix_for: $orig_id,
      created_at: (now | todate),
      updated_at: (now | todate)
    }] |
    .updated_at = (now | todate)
  ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
  sync_task_stack

  log "  Layer 2 差戻しタスク追加: ${fix_task_id} (dev_phase: ${original_dev_phase})"
}

# ===== Layer 3 失敗時の差戻しタスク生成 =====
create_l3_fix_task() {
  local original_task_id="$1"
  local l3_test_id="$2"
  local fail_output="$3"

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
