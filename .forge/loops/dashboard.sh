#!/bin/bash
# dashboard.sh — Forge Harness ダッシュボード
# 使い方: ./dashboard.sh
#
# Research System + Development System の進捗を表示する

set -euo pipefail

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"

# Watch mode
if [ "${1:-}" = "--watch" ] || [ "${1:-}" = "-w" ]; then
  shift
  TASK_STACK_PATH="${1:-.forge/state/task-stack.json}"
  while true; do
    clear
    bash "$0" "$TASK_STACK_PATH"
    # progress.json 表示
    if [ -f ".forge/state/progress.json" ]; then
      echo -e "\n${BOLD}=== リアルタイム進捗 ===${NC}"
      jq_safe -r '"  Phase: \(.phase)  Stage: \(.stage)\n  Detail: \(.detail)\n  Updated: \(.updated_at)"' \
        .forge/state/progress.json 2>/dev/null
    fi
    sleep 5
  done
  exit 0
fi

# ===== タスクスタックパス（引数 or デフォルト） =====
TASK_STACK_PATH="${1:-.forge/state/task-stack.json}"

# ===== ヘッダー =====
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║           Forge Harness Dashboard v3.2           ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ===== 1. Research System =====
echo -e "${BOLD}=== Research System ===${NC}"
echo ""

if [ -f ".forge/state/current-research.json" ]; then
  local_status=$(jq_safe -r '.status // "不明"' .forge/state/current-research.json 2>/dev/null)
  local_theme=$(jq_safe -r '.theme // "不明"' .forge/state/current-research.json 2>/dev/null)
  local_stage=$(jq_safe -r '.current_stage // "不明"' .forge/state/current-research.json 2>/dev/null)
  local_dir=$(jq_safe -r '.research_dir // "不明"' .forge/state/current-research.json 2>/dev/null)
  local_loops=$(jq_safe -r '.loop_count | "conditional=\(.conditional // 0) nogo=\(.nogo // 0)"' .forge/state/current-research.json 2>/dev/null)

  echo -e "  テーマ:    ${local_theme}"
  echo -e "  ステータス: ${local_status}"
  echo -e "  ステージ:  ${local_stage}"
  echo -e "  ループ:    ${local_loops}"
  echo -e "  出力先:    ${local_dir}"
else
  echo -e "  ${DIM}（リサーチ状態なし）${NC}"
fi

# 直近5件の decisions
echo ""
if [ -f ".forge/state/decisions.jsonl" ] && [ -s ".forge/state/decisions.jsonl" ]; then
  echo -e "  ${BOLD}直近の意思決定:${NC}"
  tail -5 .forge/state/decisions.jsonl | while IFS= read -r line; do
    local_did=$(echo "$line" | jq_safe -r '.id // "?"' 2>/dev/null)
    local_ddec=$(echo "$line" | jq_safe -r '.decision // "?"' 2>/dev/null | cut -c1-60)
    local_dts=$(echo "$line" | jq_safe -r '.timestamp // "?"' 2>/dev/null)
    echo -e "    ${DIM}${local_dts}${NC} [${local_did}] ${local_ddec}"
  done
else
  echo -e "  ${DIM}（意思決定記録なし）${NC}"
fi

# ===== 2. Development System =====
echo ""
echo -e "${BOLD}=== Development System ===${NC}"
echo ""

if [ -f "$TASK_STACK_PATH" ]; then
  # タスク進捗
  local_total=$(jq '.tasks | length' "$TASK_STACK_PATH" 2>/dev/null || echo 0)
  local_completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$TASK_STACK_PATH" 2>/dev/null || echo 0)
  local_pending=$(jq '[.tasks[] | select(.status == "pending")] | length' "$TASK_STACK_PATH" 2>/dev/null || echo 0)
  local_failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$TASK_STACK_PATH" 2>/dev/null || echo 0)
  local_in_progress=$(jq '[.tasks[] | select(.status == "in_progress")] | length' "$TASK_STACK_PATH" 2>/dev/null || echo 0)
  local_blocked=$(jq '[.tasks[] | select(.status | startswith("blocked"))] | length' "$TASK_STACK_PATH" 2>/dev/null || echo 0)

  # プログレスバー
  if [ "$local_total" -gt 0 ]; then
    local_pct=$((local_completed * 100 / local_total))
    local_bar_len=30
    local_filled=$((local_pct * local_bar_len / 100))
    local_empty=$((local_bar_len - local_filled))
    local_bar=""
    for ((i=0; i<local_filled; i++)); do local_bar="${local_bar}█"; done
    for ((i=0; i<local_empty; i++)); do local_bar="${local_bar}░"; done
    echo -e "  進捗: [${GREEN}${local_bar}${NC}] ${local_pct}% (${local_completed}/${local_total})"
  else
    echo -e "  進捗: ${DIM}（タスクなし）${NC}"
  fi

  echo -e "  完了: ${GREEN}${local_completed}${NC}  待機: ${local_pending}  実行中: ${CYAN}${local_in_progress}${NC}  失敗: ${RED}${local_failed}${NC}  blocked: ${YELLOW}${local_blocked}${NC}"

  # 要注意タスク（failed + blocked）
  local_attention_tasks=$(jq_safe -r '
    .tasks[] |
    select(.status == "failed" or (.status | startswith("blocked"))) |
    "    [\(.task_id)] \(.status) (fail_count=\(.fail_count // 0)) — \(.description // "?" | .[0:50])"
  ' "$TASK_STACK_PATH" 2>/dev/null)

  if [ -n "$local_attention_tasks" ]; then
    echo ""
    echo -e "  ${BOLD}要注意タスク:${NC}"
    echo "$local_attention_tasks"
  fi
else
  echo -e "  ${DIM}（タスクスタックなし）${NC}"
fi

# ===== 3. Investigator統計 =====
echo ""
echo -e "${BOLD}=== Investigator統計 ===${NC}"
echo ""

if [ -f ".forge/state/investigation-log.jsonl" ] && [ -s ".forge/state/investigation-log.jsonl" ]; then
  local_inv_total=$(wc -l < .forge/state/investigation-log.jsonl | tr -d ' ')
  local_scope_task=$(jq -s '[.[] | select(.scope == "task")] | length' .forge/state/investigation-log.jsonl 2>/dev/null || echo 0)
  local_scope_criteria=$(jq -s '[.[] | select(.scope == "criteria")] | length' .forge/state/investigation-log.jsonl 2>/dev/null || echo 0)
  local_scope_research=$(jq -s '[.[] | select(.scope == "research")] | length' .forge/state/investigation-log.jsonl 2>/dev/null || echo 0)

  echo -e "  起動回数: ${local_inv_total}"
  echo -e "  scope分布: task=${local_scope_task}  criteria=${local_scope_criteria}  research=${local_scope_research}"

  # confidence 分布
  local_conf_high=$(jq -s '[.[] | select(.confidence == "high")] | length' .forge/state/investigation-log.jsonl 2>/dev/null || echo 0)
  local_conf_med=$(jq -s '[.[] | select(.confidence == "medium")] | length' .forge/state/investigation-log.jsonl 2>/dev/null || echo 0)
  local_conf_low=$(jq -s '[.[] | select(.confidence == "low")] | length' .forge/state/investigation-log.jsonl 2>/dev/null || echo 0)
  echo -e "  確信度:    high=${local_conf_high}  medium=${local_conf_med}  low=${local_conf_low}"

  # 直近5件
  echo ""
  echo -e "  ${BOLD}直近の調査:${NC}"
  tail -5 .forge/state/investigation-log.jsonl | while IFS= read -r line; do
    local_itid=$(echo "$line" | jq_safe -r '.task_id // "?"' 2>/dev/null)
    local_iscope=$(echo "$line" | jq_safe -r '.scope // "?"' 2>/dev/null)
    local_iconf=$(echo "$line" | jq_safe -r '.confidence // "?"' 2>/dev/null)
    local_icause=$(echo "$line" | jq_safe -r '.root_cause // "?" | .[0:50]' 2>/dev/null)
    echo -e "    [${local_itid}] scope=${local_iscope} conf=${local_iconf} — ${local_icause}"
  done
else
  echo -e "  ${DIM}（Investigator実行記録なし）${NC}"
fi

# ===== 4. 通知 =====
echo ""
echo -e "${BOLD}=== 通知 ===${NC}"
echo ""

local_notify_dir=".forge/state/notifications"
if [ -d "$local_notify_dir" ]; then
  local_unack=$(find "$local_notify_dir" -name "*.json" -exec jq_safe -r 'select(.acknowledged == "false") | .id' {} \; 2>/dev/null | wc -l | tr -d ' ')
  if [ "$local_unack" -gt 0 ]; then
    echo -e "  ${YELLOW}未確認通知: ${local_unack}件${NC}"
    find "$local_notify_dir" -name "*.json" -exec jq_safe -r 'select(.acknowledged == "false") | "    [\(.level)] \(.message)"' {} \; 2>/dev/null | head -5
  else
    echo -e "  ${DIM}（未確認通知なし）${NC}"
  fi
else
  echo -e "  ${DIM}（通知なし）${NC}"
fi

# ===== 5. Phase 3: 統合検証結果 =====
echo ""
echo -e "${BOLD}=== Phase 3: 統合検証 ===${NC}"
echo ""

if [ -f ".forge/state/integration-report.json" ]; then
  local_p3_status=$(jq_safe -r '.status // "不明"' .forge/state/integration-report.json 2>/dev/null)
  local_p3_pass=$(jq_safe -r '.summary.pass // 0' .forge/state/integration-report.json 2>/dev/null)
  local_p3_fail=$(jq_safe -r '.summary.fail // 0' .forge/state/integration-report.json 2>/dev/null)
  local_p3_skip=$(jq_safe -r '.summary.skip // 0' .forge/state/integration-report.json 2>/dev/null)
  local_p3_ts=$(jq_safe -r '.generated_at // "不明"' .forge/state/integration-report.json 2>/dev/null)

  local_status_color="${GREEN}"
  if [ "$local_p3_status" = "fail" ]; then
    local_status_color="${RED}"
  fi

  echo -e "  ステータス: ${local_status_color}${local_p3_status}${NC}"
  echo -e "  結果: pass=${GREEN}${local_p3_pass}${NC}  fail=${RED}${local_p3_fail}${NC}  skip=${local_p3_skip}"
  echo -e "  実行日時: ${local_p3_ts}"
else
  echo -e "  ${DIM}（統合検証未実行）${NC}"
fi

# ===== 6. ハートビート =====
echo ""
echo -e "${BOLD}=== ハートビート ===${NC}"
echo ""

if [ -f ".forge/state/heartbeat.json" ]; then
  local_hb_task=$(jq_safe -r '.current_task // "不明"' .forge/state/heartbeat.json 2>/dev/null)
  local_hb_tc=$(jq_safe -r '.task_count // 0' .forge/state/heartbeat.json 2>/dev/null)
  local_hb_ic=$(jq_safe -r '.investigation_count // 0' .forge/state/heartbeat.json 2>/dev/null)
  local_hb_elapsed=$(jq_safe -r '.elapsed // "不明"' .forge/state/heartbeat.json 2>/dev/null)
  local_hb_at=$(jq_safe -r '.heartbeat_at // "不明"' .forge/state/heartbeat.json 2>/dev/null)

  # 経過秒数を計算（ハング検出用）
  local_hb_epoch=$(date -d "$local_hb_at" +%s 2>/dev/null || echo 0)
  local_now_epoch=$(date +%s)
  local_hb_age_sec=$(( local_now_epoch - local_hb_epoch ))
  local_hb_age_min=$(( local_hb_age_sec / 60 ))

  echo -e "  現在のタスク: ${local_hb_task}"
  echo -e "  タスク実行数: ${local_hb_tc}  Investigator: ${local_hb_ic}"
  echo -e "  経過時間:     ${local_hb_elapsed}"
  echo -e "  最終更新:     ${local_hb_at}"
  if [ "$local_hb_age_min" -ge 15 ]; then
    echo -e "  ${RED}⚠ 最終ハートビートから${local_hb_age_min}分経過（ハングの可能性）${NC}"
  elif [ "$local_hb_age_min" -ge 5 ]; then
    echo -e "  ${YELLOW}△ 最終ハートビートから${local_hb_age_min}分経過${NC}"
  fi
else
  echo -e "  ${DIM}（ハートビートなし — ralph-loop 未実行）${NC}"
fi

# ===== 7. 直近イベント =====
echo ""
echo -e "${BOLD}=== 直近イベント ===${NC}"
echo ""

if [ -f ".forge/state/task-events.jsonl" ] && [ -s ".forge/state/task-events.jsonl" ]; then
  local_evt_total=$(wc -l < .forge/state/task-events.jsonl | tr -d ' ')
  echo -e "  総イベント数: ${local_evt_total}"
  echo ""
  echo -e "  ${BOLD}直近10件:${NC}"
  tail -10 .forge/state/task-events.jsonl | while IFS= read -r line; do
    local_etid=$(echo "$line" | jq_safe -r '.task_id // "?"' 2>/dev/null)
    local_eevt=$(echo "$line" | jq_safe -r '.event // "?"' 2>/dev/null)
    local_ets=$(echo "$line" | jq_safe -r '.timestamp // "?" | .[11:19]' 2>/dev/null)
    local_edet=$(echo "$line" | jq_safe -r '.detail | to_entries | map("\(.key)=\(.value)") | join(" ") | .[0:40]' 2>/dev/null)
    echo -e "    ${DIM}${local_ets}${NC} [${local_etid}] ${local_eevt} ${local_edet}"
  done
else
  echo -e "  ${DIM}（イベントログなし）${NC}"
fi

# ===== 8. コスト追跡 =====
echo ""
echo -e "${BOLD}=== コスト追跡 ===${NC}"
echo ""

local_costs_file=".forge/state/costs.jsonl"
if [ -f "$local_costs_file" ] && [ -s "$local_costs_file" ]; then
  local_total_cost=$(jq -s '[.[].cost_usd | tonumber] | add // 0' "$local_costs_file" 2>/dev/null || echo 0)
  local_invocations=$(wc -l < "$local_costs_file" | tr -d ' ')
  local_total_input=$(jq -s '[.[].input_tokens] | add // 0' "$local_costs_file" 2>/dev/null || echo 0)
  local_total_output=$(jq -s '[.[].output_tokens] | add // 0' "$local_costs_file" 2>/dev/null || echo 0)
  printf "  累計コスト: \$%.2f (%s 回の API 呼出)\n" "$local_total_cost" "$local_invocations"
  printf "  トークン: input=%s  output=%s\n" "$local_total_input" "$local_total_output"

  # モデル別内訳
  local_model_breakdown=$(jq -s 'group_by(.model) | map({model: .[0].model, count: length, cost: ([.[].cost_usd | tonumber] | add)}) | sort_by(-.cost)' "$local_costs_file" 2>/dev/null || echo "[]")
  local_model_count=$(echo "$local_model_breakdown" | jq 'length' 2>/dev/null || echo 0)
  if [ "$local_model_count" -gt 0 ]; then
    echo -e "  ${BOLD}モデル別:${NC}"
    echo "$local_model_breakdown" | jq -r '.[] | "    \(.model): \(.count)回 $\(.cost | . * 100 | round / 100)"' 2>/dev/null
  fi
else
  echo -e "  ${DIM}（コストデータなし）${NC}"
fi

echo ""
echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
