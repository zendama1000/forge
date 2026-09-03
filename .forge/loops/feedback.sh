#!/bin/bash
# feedback.sh — 人間フィードバック手動記録 CLI（P0-2: キャリブレーション配管の手動入口）
#
# 用法: bash .forge/loops/feedback.sh <task-id> <verdict> "<理由>" [--no-requeue] [--correct <judgment>]
#   verdict: reject | accept-with-notes
#   --correct <judgment>: 評価器が本来出すべきだった判定を明示（例: QA の fail を覆して完了確定した時は
#     `accept-with-notes --correct pass`）。省略時の既定は reject=evaluator 別の既定表 /
#     accept-with-notes=評価器自身の判定（乖離なし）— batch#11 R18a
#
# 動作:
#   1. ${DEV_LOG_DIR}/<task-id>/ の evaluator 結果 (evidence-da-result.json /
#      qa-evaluator-result.json / ux-judgment-result.json) が存在すれば、
#      それぞれの evaluator 名で record_calibration_example を呼ぶ
#   2. evaluator 結果が1つも無い場合も evaluator="human-direct" として記録する
#   3. 記録件数を stdout に表示する
#   4. reject 時はタスクを pending に差戻す（--no-requeue で抑止可）
#   5. UX 判定の未裁定債務 (ux_disagreement) を裁定として解消する（§6）

set -euo pipefail

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"

# ===== 引数パース =====
NO_REQUEUE=false
CORRECT_OVERRIDE=""
_positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-requeue) NO_REQUEUE=true; shift ;;
    --correct=*) CORRECT_OVERRIDE="${1#*=}"; shift ;;
    --correct)
      if [ $# -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" == -* ]]; then
        echo "[ERROR] --correct には判定値が必要です（例: --correct pass）" >&2; exit 1
      fi
      CORRECT_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      echo "用法: bash .forge/loops/feedback.sh <task-id> <verdict> \"<理由>\" [--no-requeue] [--correct <judgment>]"
      echo "  verdict: reject | accept-with-notes"
      echo "  --correct <judgment>: 評価器が本来出すべきだった判定（pass/fail/continue/pivot/escalate 等）を明示"
      exit 0 ;;
    -*) echo "不明なオプション: $1" >&2; exit 1 ;;
    *) _positional+=("$1"); shift ;;
  esac
done

if [ ${#_positional[@]} -lt 3 ]; then
  echo "用法: bash .forge/loops/feedback.sh <task-id> <verdict> \"<理由>\" [--no-requeue] [--correct <judgment>]" >&2
  echo "  verdict: reject | accept-with-notes" >&2
  exit 1
fi

TASK_ID="${_positional[0]}"
VERDICT="${_positional[1]}"
RATIONALE="${_positional[2]}"

case "$VERDICT" in
  reject|accept-with-notes) ;;
  *)
    echo "[ERROR] verdict は reject | accept-with-notes のいずれか（指定値: ${VERDICT}）" >&2
    exit 1 ;;
esac

# ===== 前提変数（calibration.sh / quality-ledger.sh が参照） =====
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"

source "${PROJECT_ROOT}/.forge/lib/calibration.sh"
source "${PROJECT_ROOT}/.forge/lib/quality-ledger.sh"

# ===== 記録 =====
recorded=$(record_feedback_for_task "$TASK_ID" "$VERDICT" "$RATIONALE" "${CORRECT_OVERRIDE:-}")
echo "キャリブレーション記録: ${recorded} 件 → ${CALIBRATION_FILE}${CORRECT_OVERRIDE:+（correct_judgment=${CORRECT_OVERRIDE} に上書き）}"

# ===== reject 時: タスクを pending に差戻す =====
# previous_status="completed" を明示的に書くことで detect_reworked_tasks の重複記録を
# 発生させない（本コマンドが既に記録済みのため rework_detected マーカーも追記する）
if [ "$VERDICT" = "reject" ] && [ "$NO_REQUEUE" != "true" ] && [ -f "$TASK_STACK" ]; then
  current_status=$(jq_safe -r --arg id "$TASK_ID" \
    '.tasks[] | select(.task_id == $id) | .status // ""' "$TASK_STACK" 2>/dev/null)
  if [ "$current_status" = "completed" ]; then
    jq --arg id "$TASK_ID" '
      .tasks |= map(
        if .task_id == $id then
          .status = "pending" | .fail_count = 0 |
          del(.previous_status) |
          .updated_at = (now | todate)
        else . end
      ) | .updated_at = (now | todate)
    ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
    TASK_EVENTS_FILE="${PROJECT_ROOT}/.forge/state/task-events.jsonl"
    record_task_event "$TASK_ID" "rework_detected" '{"source":"feedback.sh"}'
    record_task_event "$TASK_ID" "status_changed" '{"new_status":"pending"}'
    echo "タスク差戻し: ${TASK_ID} → pending（ralph-loop 再起動で再実行される）"
  elif [ -n "$current_status" ]; then
    echo "（status=${current_status} のため差戻しスキップ — completed のみ対象）"
  fi
fi

# ===== UX 未裁定債務の解消（§6: エスカレーション裁定） =====
resolve_quality_debts_matching "$TASK_ID" "ux_disagreement" "" "human feedback: ${VERDICT} — ${RATIONALE}"

exit 0
