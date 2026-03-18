#!/bin/bash
# monitor.sh — Forge Harness 異常検出モニター
# 使い方: bash .forge/loops/monitor.sh [--auto-recover]
#
# 全チェック結果を JSON でstdoutに出力。正常時は status="ok"、異常時は status="anomalies"。
# /sc:monitor スラッシュコマンドから呼ばれることを想定。
# /loop 5m /sc:monitor で定期実行可能。

set -euo pipefail

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"

# ===== 引数解析 =====
AUTO_RECOVER=false
for arg in "$@"; do
  case "$arg" in
    --auto-recover) AUTO_RECOVER=true ;;
  esac
done

# ===== 定数 =====
STATE_DIR="${PROJECT_ROOT}/.forge/state"
HEARTBEAT_FILE="${STATE_DIR}/heartbeat.json"
PROGRESS_FILE="${STATE_DIR}/progress.json"
TASK_STACK="${STATE_DIR}/task-stack.json"
ERRORS_FILE="${STATE_DIR}/errors.jsonl"
NOTIFY_DIR="${STATE_DIR}/notifications"
SNAPSHOT_FILE="${STATE_DIR}/monitor-snapshot.json"
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"

# ===== 出力用配列 =====
ANOMALIES="[]"
CHANGES="[]"
RECOVERABLE_ACTIONS="[]"

# JSON 配列に要素を追加するヘルパー
add_anomaly() {
  local severity="$1" type="$2" message="$3" detail="${4:-}"
  ANOMALIES=$(echo "$ANOMALIES" | jq -c --arg s "$severity" --arg t "$type" --arg m "$message" --arg d "$detail" \
    '. + [{"severity":$s,"type":$t,"message":$m,"detail":$d}]')
}

add_change() {
  local type="$1" message="$2"
  CHANGES=$(echo "$CHANGES" | jq -c --arg t "$type" --arg m "$message" \
    '. + [{"type":$t,"message":$m}]')
}

add_recovery() {
  local type="$1" description="$2" command="$3"
  RECOVERABLE_ACTIONS=$(echo "$RECOVERABLE_ACTIONS" | jq -c --arg t "$type" --arg d "$description" --arg c "$command" \
    '. + [{"type":$t,"description":$d,"command":$c}]')
}

# ===== 稼動チェック =====
# heartbeat も progress も task-stack もない → 未稼動
if [ ! -f "$HEARTBEAT_FILE" ] && [ ! -f "$PROGRESS_FILE" ] && [ ! -f "$TASK_STACK" ]; then
  jq -n -c '{status:"not_running",summary:"Forge Harness 未稼動",anomalies:[],changes:[],recoverable_actions:[],checked_at:(now|todate)}'
  exit 0
fi

# ===== 基本情報収集 =====
current_phase=$(jq_safe -r '.phase // "unknown"' "$PROGRESS_FILE" 2>/dev/null || echo "unknown")
current_stage=$(jq_safe -r '.stage // "unknown"' "$PROGRESS_FILE" 2>/dev/null || echo "unknown")
progress_pct=$(jq_safe -r '.progress_pct // 0' "$PROGRESS_FILE" 2>/dev/null || echo "0")

completed_count=0
total_count=0
blocked_count=0
failed_count=0
in_progress_count=0

if [ -f "$TASK_STACK" ]; then
  completed_count=$(jq_safe '[.tasks[] | select(.status=="completed")] | length' "$TASK_STACK" 2>/dev/null || echo "0")
  total_count=$(jq_safe '.tasks | length' "$TASK_STACK" 2>/dev/null || echo "0")
  blocked_count=$(jq_safe '[.tasks[] | select(.status | startswith("blocked"))] | length' "$TASK_STACK" 2>/dev/null || echo "0")
  failed_count=$(jq_safe '[.tasks[] | select(.status=="failed")] | length' "$TASK_STACK" 2>/dev/null || echo "0")
  in_progress_count=$(jq_safe '[.tasks[] | select(.status=="in_progress")] | length' "$TASK_STACK" 2>/dev/null || echo "0")
fi

# 経過時間
elapsed="不明"
if [ -f "$HEARTBEAT_FILE" ]; then
  elapsed=$(jq_safe -r '.elapsed // "不明"' "$HEARTBEAT_FILE" 2>/dev/null || echo "不明")
fi

# サマリー構築
if [ "$total_count" -gt 0 ]; then
  pct=$((completed_count * 100 / total_count))
  summary="Phase ${current_phase}: ${completed_count}/${total_count} 完了 (${pct}%), 経過 ${elapsed}"
else
  summary="Phase ${current_phase}, stage: ${current_stage}"
fi

# ===== チェック 1: ハング検出 =====
if [ -f "$HEARTBEAT_FILE" ]; then
  hb_at=$(jq_safe -r '.heartbeat_at // ""' "$HEARTBEAT_FILE" 2>/dev/null || true)
  if [ -n "$hb_at" ]; then
    hb_epoch=$(date -d "$hb_at" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    hb_age_min=$(( (now_epoch - hb_epoch) / 60 ))

    if [ "$hb_age_min" -ge 15 ]; then
      hb_task=$(jq_safe -r '.current_task // "不明"' "$HEARTBEAT_FILE" 2>/dev/null || echo "不明")
      add_anomaly "critical" "heartbeat_stale" \
        "ハング疑い: 最終ハートビートから${hb_age_min}分経過" \
        "最終タスク: ${hb_task}"
    fi
  fi
fi

# ===== チェック 2: blocked 過半数 =====
if [ "$total_count" -gt 0 ] && [ "$blocked_count" -gt 0 ]; then
  half=$(( total_count / 2 ))
  if [ "$blocked_count" -gt "$half" ]; then
    add_anomaly "critical" "blocked_majority" \
      "過半数のタスクがblocked状態 (${blocked_count}/${total_count})" \
      "サーキットブレーカー発動条件に該当"
  fi
fi

# ===== チェック 3: blocked タスク (過半数未満) =====
if [ "$blocked_count" -gt 0 ]; then
  blocked_details=$(jq_safe -r '.tasks[] | select(.status | startswith("blocked")) | "\(.task_id): \(.status)"' "$TASK_STACK" 2>/dev/null || true)

  # blocked_investigation のみ recoverable_action を生成
  blocked_inv_count=$(jq_safe '[.tasks[] | select(.status=="blocked_investigation")] | length' "$TASK_STACK" 2>/dev/null || echo "0")

  # 過半数でなければ warning（過半数は上で critical 済み）
  half=$(( total_count / 2 ))
  if [ "$blocked_count" -le "$half" ]; then
    add_anomaly "warning" "blocked_tasks" \
      "blockedタスク: ${blocked_count}件" \
      "$blocked_details"
  fi

  if [ "$blocked_inv_count" -gt 0 ]; then
    add_recovery "reset_blocked_investigation" \
      "blocked_investigation の${blocked_inv_count}タスクを pending にリセット" \
      "jq '(.tasks[] | select(.status==\"blocked_investigation\")).status = \"pending\" | (.tasks[] | select(.status==\"pending\" and .fail_count > 0)).fail_count = 0' \"${TASK_STACK}\" > \"${TASK_STACK}.tmp\" && mv \"${TASK_STACK}.tmp\" \"${TASK_STACK}\""
  fi
fi

# ===== チェック 4: レートリミットエラー =====
if [ -f "$ERRORS_FILE" ] && [ -s "$ERRORS_FILE" ]; then
  # 直近20件のうち rate_limit カテゴリをカウント（1回の jq で処理）
  rate_limit_recent=$(tail -20 "$ERRORS_FILE" 2>/dev/null | \
    grep '"error_category":"rate_limit"' 2>/dev/null | wc -l || echo "0")
  rate_limit_recent=$((rate_limit_recent + 0))  # trim whitespace

  if [ "$rate_limit_recent" -ge 2 ]; then
    add_anomaly "warning" "rate_limit" \
      "直近エラー20件中レートリミット${rate_limit_recent}件" \
      "APIレート回復を待つか、--auto-recover で自動復旧を試行"
  fi
fi

# ===== チェック 5: 未確認通知 =====
if [ -d "$NOTIFY_DIR" ]; then
  # 全通知ファイルを一括処理（1回の jq で集計）
  notify_files=("$NOTIFY_DIR"/n-*.json)
  if [ -f "${notify_files[0]:-}" ]; then
    notify_result=$(cat "$NOTIFY_DIR"/n-*.json 2>/dev/null | \
      jq -s -r '[.[] | select(.acknowledged == "false" and .level != "info")] |
        {count: length, messages: (.[0:5] | map(.message) | join("\n"))}' 2>/dev/null || echo '{"count":0,"messages":""}')
    unacked_count=$(echo "$notify_result" | jq -r '.count' 2>/dev/null || echo "0")
    unacked_messages=$(echo "$notify_result" | jq -r '.messages' 2>/dev/null || true)

    if [ "$unacked_count" -gt 0 ]; then
      add_anomaly "warning" "unacked_notifications" \
        "未確認の通知: ${unacked_count}件" \
        "$unacked_messages"
    fi
  fi
fi

# ===== チェック 6: サーバーヘルスチェック（Phase 2 中のみ） =====
if [ "$current_phase" = "development" ] && [ -f "$DEV_CONFIG" ]; then
  health_url=$(jq_safe -r '.server.health_check_url // ""' "$DEV_CONFIG" 2>/dev/null || true)
  start_cmd=$(jq_safe -r '.server.start_command // ""' "$DEV_CONFIG" 2>/dev/null || true)

  # servers[] 配列もフォールバック
  if [ -z "$health_url" ]; then
    health_url=$(jq_safe -r '.servers[0].health_check_url // ""' "$DEV_CONFIG" 2>/dev/null || true)
    start_cmd=$(jq_safe -r '.servers[0].start_command // ""' "$DEV_CONFIG" 2>/dev/null || true)
  fi

  if [ -n "$health_url" ]; then
    if ! curl -sf -o /dev/null -m 3 "$health_url" 2>/dev/null; then
      add_anomaly "warning" "server_unreachable" \
        "サーバー未応答: ${health_url}" \
        "回帰テスト実行時にテスト全失敗の原因になります"

      if [ -n "$start_cmd" ]; then
        add_recovery "start_server" \
          "サーバーを起動する" \
          "$start_cmd"
      fi
    fi
  fi
fi

# ===== チェック 7: stale in_progress =====
if [ "$in_progress_count" -gt 0 ] && [ -f "$HEARTBEAT_FILE" ]; then
  hb_task=$(jq_safe -r '.current_task // ""' "$HEARTBEAT_FILE" 2>/dev/null || true)
  stale_tasks=$(jq_safe -r --arg hb "$hb_task" \
    '.tasks[] | select(.status=="in_progress" and .task_id != $hb) | .task_id' "$TASK_STACK" 2>/dev/null || true)

  if [ -n "$stale_tasks" ]; then
    add_anomaly "warning" "stale_in_progress" \
      "in_progress のまま残留しているタスクあり" \
      "$stale_tasks"
  fi
fi

# ===== チェック 8: スナップショット差分（フェーズ遷移・タスク完了） =====
if [ -f "$SNAPSHOT_FILE" ]; then
  prev_phase=$(jq_safe -r '.phase // ""' "$SNAPSHOT_FILE" 2>/dev/null || true)
  prev_stage=$(jq_safe -r '.stage // ""' "$SNAPSHOT_FILE" 2>/dev/null || true)
  prev_completed=$(jq_safe -r '.completed // 0' "$SNAPSHOT_FILE" 2>/dev/null || echo "0")

  if [ "$current_phase" != "$prev_phase" ]; then
    add_change "phase_transition" "フェーズ遷移: ${prev_phase} → ${current_phase}"
  elif [ "$current_stage" != "$prev_stage" ]; then
    add_change "stage_transition" "ステージ遷移: ${prev_stage} → ${current_stage}"
  fi

  if [ "$completed_count" -gt "$prev_completed" ]; then
    newly_done=$((completed_count - prev_completed))
    add_change "tasks_completed" "タスク ${newly_done}件 完了（${completed_count}/${total_count}）"
  fi
fi

# スナップショット更新
jq -n -c \
  --arg phase "$current_phase" \
  --arg stage "$current_stage" \
  --argjson completed "$completed_count" \
  --argjson total "$total_count" \
  '{phase:$phase,stage:$stage,completed:$completed,total:$total,checked_at:(now|todate)}' \
  > "${SNAPSHOT_FILE}.tmp" && mv "${SNAPSHOT_FILE}.tmp" "$SNAPSHOT_FILE"

# ===== 完了判定 =====
final_status="ok"
if [ "$total_count" -gt 0 ] && [ "$completed_count" -eq "$total_count" ]; then
  final_status="completed"
  summary="全 ${total_count} タスク完了"
fi

anomaly_count=$(echo "$ANOMALIES" | jq 'length')
if [ "$anomaly_count" -gt 0 ]; then
  final_status="anomalies"
fi

# ===== JSON 出力 =====
jq -n -c \
  --arg status "$final_status" \
  --arg summary "$summary" \
  --argjson anomalies "$ANOMALIES" \
  --argjson changes "$CHANGES" \
  --argjson recoverable_actions "$RECOVERABLE_ACTIONS" \
  '{status:$status,summary:$summary,anomalies:$anomalies,changes:$changes,recoverable_actions:$recoverable_actions,checked_at:(now|todate)}'
