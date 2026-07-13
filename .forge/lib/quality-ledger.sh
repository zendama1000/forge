#!/bin/bash
# quality-ledger.sh — 品質債務台帳サブシステム
# ralph-loop.sh から source される。単独では実行しない。
#
# 原則: 「ゲートは劣化してよいが、黙って劣化してはならない」
# ゲートの劣化（auto-pass / warn 化 / skip / 環境起因の繰延）を機械可読な台帳
# (.forge/state/quality-debts.jsonl) に必ず記録し、print_summary /
# integration-report / dashboard / PHASE4-HANDOFF.md で表面化する。
#
# 前提変数（任意）: PROJECT_ROOT, DEV_CONFIG, WORK_DIR, TEMPLATES_DIR, FORGE_SESSION_ID
# 依存関数（common.sh）: log, now_ts, jq_safe, render_template, acquire_lock, release_lock

QUALITY_LEDGER_FILE="${QUALITY_LEDGER_FILE:-${PROJECT_ROOT:-.}/.forge/state/quality-debts.jsonl}"

# ===== 債務記録 =====
# record_quality_debt <type> <task_id> <detail> [extra_json]
# type 語彙: qa_auto_pass | deferred_test | env_blocked | warn_gate | l3_skip |
#            orphan_file | fix_cap_reached | weak_validation | walking_skeleton_missing
# extra_json: 任意の追加フィールド（例: {"command":"npm run e2e","test_id":"L3-001"}）
# 常に rc=0（graceful — 台帳書き込み失敗で本処理を止めない）
record_quality_debt() {
  local debt_type="${1:-unknown}"
  local task_id="${2:-}"
  local detail="${3:-}"
  local extra_json="${4:-}"

  # detail サニタイズ: 制御文字除去（タブ/改行は保持しない — 1行 JSON のため）+ 2000字キャップ
  detail=$(printf '%s' "$detail" | tr -d '\000-\037' | head -c 2000)

  local ledger="$QUALITY_LEDGER_FILE"
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true

  # extra_json が不正な JSON なら無視（台帳の JSONL 整合性を守る）
  if [ -n "$extra_json" ] && ! jq empty <<< "$extra_json" 2>/dev/null; then
    extra_json=""
  fi
  [ -z "$extra_json" ] && extra_json="{}"

  local entry
  entry=$(jq -n -c \
    --arg id "qd-$(now_ts)-$$-${RANDOM}" \
    --arg type "$debt_type" \
    --arg task "$task_id" \
    --arg detail "$detail" \
    --arg sid "${FORGE_SESSION_ID:-}" \
    --arg ts "$(date -Iseconds)" \
    --argjson extra "$extra_json" \
    '{id:$id, type:$type, task_id:$task, detail:$detail, session_id:$sid, created_at:$ts, resolved:false} + $extra' 2>/dev/null)
  [ -z "$entry" ] && return 0

  local _lock_dir
  _lock_dir="$(dirname "$ledger")/.lock/quality-debts.lock"
  acquire_lock "$_lock_dir" 2>/dev/null || true
  printf '%s\n' "$entry" >> "$ledger" 2>/dev/null || true
  release_lock "$_lock_dir" 2>/dev/null || true

  log "  [QUALITY-DEBT] type=${debt_type} task=${task_id:--} — 台帳記録"
  return 0
}

# ===== 債務解消（2026-07 batch#8 Fix3） =====
# 台帳は resolve 経路がないと蓄積のみで数ランで WARN が狼少年化し
# 「黙って劣化しない」の核心が死ぬ — 解消・セッション分離をここで担う。
# 全書換は record と同一ロックで直列化し、jq 失敗時（破損行等）は原本を保全する。

# resolve_quality_debt <debt_id> [resolution_note] — id 指定で resolve（冪等・常に rc=0）
resolve_quality_debt() {
  local debt_id="${1:-}"
  local note="${2:-}"
  [ -n "$debt_id" ] || return 0
  local ledger="$QUALITY_LEDGER_FILE"
  { [ -f "$ledger" ] && [ -s "$ledger" ]; } || return 0

  local _lock_dir
  _lock_dir="$(dirname "$ledger")/.lock/quality-debts.lock"
  acquire_lock "$_lock_dir" 2>/dev/null || true
  if jq -c --arg id "$debt_id" --arg note "$note" --arg ts "$(date -Iseconds)" \
       'if .id == $id and .resolved != true
        then .resolved = true | .resolved_at = $ts | .resolution = $note
        else . end' "$ledger" > "${ledger}.tmp" 2>/dev/null; then
    mv "${ledger}.tmp" "$ledger" 2>/dev/null || rm -f "${ledger}.tmp" 2>/dev/null
  else
    rm -f "${ledger}.tmp" 2>/dev/null
  fi
  release_lock "$_lock_dir" 2>/dev/null || true
  return 0
}

# resolve_quality_debts_matching <task_id> <types_csv> [test_id] [note]
# 該当 task_id + type 群の未解決債務を一括 resolve。test_id 指定時は test_id 一致
# または（l3_skip は test_id なしで記録される実態への carve-out として）type=l3_skip
# の task 単位一致で解消する。常に rc=0
resolve_quality_debts_matching() {
  local task_id="${1:-}"
  local types_csv="${2:-}"
  local test_id="${3:-}"
  local note="${4:-}"
  { [ -n "$task_id" ] && [ -n "$types_csv" ]; } || return 0
  local ledger="$QUALITY_LEDGER_FILE"
  { [ -f "$ledger" ] && [ -s "$ledger" ]; } || return 0

  local _match='(.resolved != true and .task_id == $task
     and ((.type // "") as $t | ($types | split(",")) | index($t) != null)
     and ($tid == "" or (.test_id // "") == $tid or ((.test_id // "") == "" and .type == "l3_skip")))'

  local n
  n=$(jq -s --arg task "$task_id" --arg types "$types_csv" --arg tid "$test_id" \
    "[.[] | select($_match)] | length" "$ledger" 2>/dev/null)
  case "$n" in (*[!0-9]*|"") n=0 ;; esac
  [ "$n" -eq 0 ] && return 0

  local _lock_dir
  _lock_dir="$(dirname "$ledger")/.lock/quality-debts.lock"
  acquire_lock "$_lock_dir" 2>/dev/null || true
  if jq -c --arg task "$task_id" --arg types "$types_csv" --arg tid "$test_id" \
       --arg note "$note" --arg ts "$(date -Iseconds)" \
       "if $_match
        then .resolved = true | .resolved_at = \$ts | .resolution = \$note
        else . end" "$ledger" > "${ledger}.tmp" 2>/dev/null; then
    mv "${ledger}.tmp" "$ledger" 2>/dev/null || rm -f "${ledger}.tmp" 2>/dev/null
    log "  [QUALITY-DEBT] resolve: task=${task_id} types=${types_csv}${test_id:+ test=$test_id} — ${n} 件解消（${note:-pass}）"
  else
    rm -f "${ledger}.tmp" 2>/dev/null
  fi
  release_lock "$_lock_dir" 2>/dev/null || true
  return 0
}

# ===== 債務集計 =====
# summarize_quality_debts [ledger_file] [session_id]
# stdout: {"total":N,"unresolved":N,"by_type":{...}}
#         session_id 指定時は + {"session":{"id":...,"total":N,"unresolved":N}}
# 台帳不在・破損時も必ず有効な JSON を返す（rc=0）
summarize_quality_debts() {
  local ledger="${1:-$QUALITY_LEDGER_FILE}"
  local session_id="${2:-}"
  if [ ! -f "$ledger" ] || [ ! -s "$ledger" ]; then
    if [ -n "$session_id" ]; then
      jq -n -c --arg sid "$session_id" \
        '{total:0,unresolved:0,by_type:{},session:{id:$sid,total:0,unresolved:0}}'
    else
      echo '{"total":0,"unresolved":0,"by_type":{}}'
    fi
    return 0
  fi
  jq_safe -s -c --arg sid "$session_id" '{
    total: length,
    unresolved: (map(select(.resolved != true)) | length),
    by_type: (group_by(.type) | map({key: .[0].type, value: length}) | from_entries)
  } + (if $sid == "" then {} else
    {session: {
      id: $sid,
      total: (map(select(.session_id == $sid)) | length),
      unresolved: (map(select(.session_id == $sid and .resolved != true)) | length)
    }} end)' "$ledger" 2>/dev/null || echo '{"total":0,"unresolved":0,"by_type":{}}'
  return 0
}

# ===== 債務一覧（表示用） =====
# list_quality_debts [type_filter] [ledger_file]
# stdout: "- [type] task_id: detail" 形式の行群（フィルタ一致なし/台帳不在は空出力）
list_quality_debts() {
  local filter_type="${1:-}"
  local ledger="${2:-$QUALITY_LEDGER_FILE}"
  [ -f "$ledger" ] || return 0
  if [ -n "$filter_type" ]; then
    jq_safe -r --arg t "$filter_type" \
      'select(.type == $t) | "- [\(.type)] \(.task_id // "-"): \(.detail // "")"' \
      "$ledger" 2>/dev/null || true
  else
    jq_safe -r '"- [\(.type)] \(.task_id // "-"): \(.detail // "")"' \
      "$ledger" 2>/dev/null || true
  fi
  return 0
}

# ===== PHASE4-HANDOFF.md 生成 =====
# generate_phase4_handoff <work_dir> [ledger_file]
# 未解決債務が 1 件以上あれば <work_dir>/PHASE4-HANDOFF.md を生成する。
# 繰延テスト（deferred_test / env_blocked / l3_skip）の一覧と手動実行手順を含む。
# 常に rc=0
generate_phase4_handoff() {
  local work_dir="${1:-${WORK_DIR:-.}}"
  local ledger="${2:-$QUALITY_LEDGER_FILE}"
  [ -f "$ledger" ] || return 0
  [ -d "$work_dir" ] || return 0

  local summary unresolved
  summary=$(summarize_quality_debts "$ledger" "${FORGE_SESSION_ID:-}")
  unresolved=$(echo "$summary" | jq_safe -r '.unresolved // 0' 2>/dev/null)
  case "$unresolved" in (*[!0-9]*|"") unresolved=0 ;; esac
  if [ "$unresolved" -eq 0 ]; then
    return 0
  fi

  local template="${TEMPLATES_DIR:-${PROJECT_ROOT:-.}/.forge/templates}/phase4-handoff.md"
  if [ ! -f "$template" ]; then
    log "  ⚠ PHASE4-HANDOFF: テンプレート不在 — スキップ"
    return 0
  fi

  local debt_summary
  debt_summary=$(echo "$summary" | jq_safe -r \
    '"未解決債務: \(.unresolved) 件 / 総数 \(.total) 件" +
     (if .session then "（うち今回セッション \(.session.unresolved) 件）" else "" end) + "\n" +
     (.by_type | to_entries | map("- \(.key): \(.value) 件") | join("\n"))' \
    2>/dev/null)
  [ -z "$debt_summary" ] && debt_summary="（集計不可）"

  local deferred_tests
  deferred_tests=$(jq_safe -r \
    'select(.type == "deferred_test" or .type == "env_blocked" or .type == "l3_skip") | "- [\(.type)] \(.task_id // "-"): \(.detail // "")"' \
    "$ledger" 2>/dev/null)
  [ -z "$deferred_tests" ] && deferred_tests="（繰延テストなし）"

  # 手動検証手順: サーバー起動（設定があれば）+ 台帳に command が記録された項目
  local manual_steps=""
  local start_cmd=""
  if [ -n "${DEV_CONFIG:-}" ] && [ -f "${DEV_CONFIG:-/nonexistent}" ]; then
    start_cmd=$(jq_safe -r '.server.start_command // "none"' "$DEV_CONFIG" 2>/dev/null)
  fi
  if [ -n "$start_cmd" ] && [ "$start_cmd" != "none" ] && [ "$start_cmd" != "null" ]; then
    manual_steps="1. サーバー起動: \`cd ${work_dir} && ${start_cmd}\`"$'\n'
  fi
  local cmd_steps
  cmd_steps=$(jq_safe -r --arg wd "$work_dir" \
    'select((.command // "") != "") | "- `cd \($wd) && \(.command)`"' \
    "$ledger" 2>/dev/null)
  if [ -n "$cmd_steps" ]; then
    manual_steps="${manual_steps}${cmd_steps}"
  fi
  [ -z "$manual_steps" ] && manual_steps="（自動抽出できる手順なし — 下記の全債務一覧を参照して個別に検証すること）"

  local debt_list
  debt_list=$(list_quality_debts "" "$ledger")
  [ -z "$debt_list" ] && debt_list="（なし）"

  local content
  content=$(render_template "$template" \
    "GENERATED_AT"   "$(date -Iseconds)" \
    "DEBT_SUMMARY"   "$debt_summary" \
    "DEFERRED_TESTS" "$deferred_tests" \
    "MANUAL_STEPS"   "$manual_steps" \
    "DEBT_LIST"      "$debt_list"
  )
  if [ -n "$content" ]; then
    printf '%s\n' "$content" > "${work_dir}/PHASE4-HANDOFF.md" 2>/dev/null || true
    log "  PHASE4-HANDOFF.md 生成: ${work_dir}/PHASE4-HANDOFF.md（未解決債務 ${unresolved} 件）"
  fi
  return 0
}
