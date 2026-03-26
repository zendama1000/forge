#!/bin/bash
# calibration.sh — Few-Shot キャリブレーションサブシステム
# ralph-loop.sh から source される。単独では実行しない。
#
# 前提変数（ralph-loop.sh で定義済み）:
#   PROJECT_ROOT, TASK_STACK

# ===== 定数 =====
CALIBRATION_FILE="${PROJECT_ROOT}/.forge/state/calibration-data.jsonl"

# ===== キャリブレーション事例の記録 =====
# record_calibration_example <evaluator> <task_id> <evaluator_judgment_json> <human_judgment> <human_rationale> <correct_judgment>
# evaluator: "evidence-da" | "qa-evaluator"
record_calibration_example() {
  local evaluator="$1"
  local task_id="$2"
  local evaluator_judgment="$3"
  local human_judgment="$4"
  local human_rationale="$5"
  local correct_judgment="$6"

  mkdir -p "$(dirname "$CALIBRATION_FILE")"

  local cal_id="cal-$(date +%Y%m%d)-$(printf '%03d' $((RANDOM % 1000)))"
  local timestamp
  timestamp=$(date -Iseconds)

  jq -n -c \
    --arg id "$cal_id" \
    --arg eval "$evaluator" \
    --arg tid "$task_id" \
    --arg ts "$timestamp" \
    --argjson ej "$evaluator_judgment" \
    --arg hj "$human_judgment" \
    --arg hr "$human_rationale" \
    --arg cj "$correct_judgment" \
    '{id: $id, evaluator: $eval, task_id: $tid, timestamp: $ts,
      evaluator_judgment: $ej, human_judgment: $hj,
      human_rationale: $hr, correct_judgment: $cj}' \
    >> "$CALIBRATION_FILE"
}

# ===== キャリブレーション事例の取得 =====
# get_calibration_examples <evaluator> <max_count>
# 指定 evaluator の最新 N 件を Few-Shot 形式で stdout に出力。
# データなし時は空文字を返す。
get_calibration_examples() {
  local evaluator="$1"
  local max_count="${2:-3}"

  [ -f "$CALIBRATION_FILE" ] || { echo ""; return 0; }
  [ -s "$CALIBRATION_FILE" ] || { echo ""; return 0; }

  # evaluator でフィルタし、最新 N 件を取得
  local examples
  examples=$(grep "\"evaluator\":\"${evaluator}\"" "$CALIBRATION_FILE" 2>/dev/null | tail -n "$max_count")
  [ -z "$examples" ] && { echo ""; return 0; }

  local output=""
  local idx=0
  while IFS= read -r line; do
    # 不正な JSON 行はスキップ
    jq empty <<< "$line" 2>/dev/null || continue

    idx=$((idx + 1))
    local tid ej_rec ej_conf hj hr cj
    tid=$(jq -r '.task_id // "unknown"' <<< "$line")
    ej_rec=$(jq -r '.evaluator_judgment.recommendation // .evaluator_judgment.verdict // "unknown"' <<< "$line")
    ej_conf=$(jq -r '.evaluator_judgment.confidence // "unknown"' <<< "$line")
    hj=$(jq -r '.human_judgment // "unknown"' <<< "$line")
    hr=$(jq -r '.human_rationale // ""' <<< "$line")
    cj=$(jq -r '.correct_judgment // "unknown"' <<< "$line")

    output="${output}
### 事例 ${idx}（評価者の判断が誤り）
- タスク: ${tid}
- 評価者: ${ej_rec} (confidence: ${ej_conf})
- 人間: ${hj} — \"${hr}\"
- 正解: ${cj}
- 教訓: 上記のようなケースで甘い判定をしないこと
"
  done <<< "$examples"

  if [ -n "$output" ]; then
    echo "## キャリブレーション事例（人間フィードバック）
${output}"
  else
    echo ""
  fi
}

# ===== 乖離率の計算 =====
# compute_divergence_rate [evaluator]
# evaluator 未指定時は全体。stdout に "diverged/total (rate%)" 形式で出力。
compute_divergence_rate() {
  local evaluator="${1:-}"

  [ -f "$CALIBRATION_FILE" ] || { echo "0/0 (0%)"; return 0; }
  [ -s "$CALIBRATION_FILE" ] || { echo "0/0 (0%)"; return 0; }

  local total diverged
  if [ -n "$evaluator" ]; then
    total=$(grep -c "\"evaluator\":\"${evaluator}\"" "$CALIBRATION_FILE" 2>/dev/null || echo 0)
    # 乖離 = evaluator_judgment と correct_judgment が異なるケース
    diverged=$(grep "\"evaluator\":\"${evaluator}\"" "$CALIBRATION_FILE" 2>/dev/null | while IFS= read -r line; do
      local ej cj
      ej=$(jq -r '.evaluator_judgment.recommendation // .evaluator_judgment.verdict // ""' <<< "$line" 2>/dev/null)
      cj=$(jq -r '.correct_judgment // ""' <<< "$line" 2>/dev/null)
      [ "$ej" != "$cj" ] && echo "1"
    done | wc -l | tr -d ' ')
  else
    total=$(wc -l < "$CALIBRATION_FILE" 2>/dev/null | tr -d ' ')
    diverged=$(while IFS= read -r line; do
      local ej cj
      ej=$(jq -r '.evaluator_judgment.recommendation // .evaluator_judgment.verdict // ""' <<< "$line" 2>/dev/null)
      cj=$(jq -r '.correct_judgment // ""' <<< "$line" 2>/dev/null)
      [ "$ej" != "$cj" ] && echo "1"
    done < "$CALIBRATION_FILE" | wc -l | tr -d ' ')
  fi

  total=${total:-0}
  diverged=${diverged:-0}

  local rate=0
  if [ "$total" -gt 0 ]; then
    rate=$(( diverged * 100 / total ))
  fi
  echo "${diverged}/${total} (${rate}%)"
}

# ===== Reworked タスク自動検出 =====
# detect_reworked_tasks
# completed だったが pending に戻されたタスクを検出し、
# evaluator 結果が存在すればキャリブレーションレコードを自動生成する。
detect_reworked_tasks() {
  [ -f "$TASK_STACK" ] || return 0

  # previous_status == "completed" かつ現在 status == "pending" のタスクを検出
  local reworked_ids
  reworked_ids=$(jq_safe -r '
    .tasks[]? |
    select(.previous_status == "completed" and .status == "pending") |
    .task_id
  ' "$TASK_STACK" 2>/dev/null || true)

  [ -z "$reworked_ids" ] && return 0

  local task_id
  for task_id in $reworked_ids; do
    local task_dir="${DEV_LOG_DIR}/${task_id}"

    # Evidence DA 結果チェック
    if [ -f "${task_dir}/evidence-da-result.json" ]; then
      local da_result
      da_result=$(cat "${task_dir}/evidence-da-result.json" 2>/dev/null)
      if jq empty <<< "$da_result" 2>/dev/null; then
        record_calibration_example "evidence-da" "$task_id" \
          "$da_result" "reject" "タスクが人間により rework に戻された" "pivot"
        log "  [CALIBRATION] Evidence-DA キャリブレーション自動記録: ${task_id}"
      fi
    fi

    # QA Evaluator 結果チェック
    if [ -f "${task_dir}/qa-evaluator-result.json" ]; then
      local qa_result
      qa_result=$(cat "${task_dir}/qa-evaluator-result.json" 2>/dev/null)
      if jq empty <<< "$qa_result" 2>/dev/null; then
        record_calibration_example "qa-evaluator" "$task_id" \
          "$qa_result" "reject" "タスクが人間により rework に戻された" "fail"
        log "  [CALIBRATION] QA Evaluator キャリブレーション自動記録: ${task_id}"
      fi
    fi

    # previous_status をクリア（重複記録防止）
    jq --arg id "$task_id" '
      .tasks |= map(
        if .task_id == $id then del(.previous_status) else . end
      )
    ' "$TASK_STACK" > "${TASK_STACK}.tmp" 2>/dev/null && mv "${TASK_STACK}.tmp" "$TASK_STACK"
  done
}
