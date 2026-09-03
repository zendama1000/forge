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

    # 乖離あり（評価者の判断 ≠ 正解）と注記のみ（accept-with-notes 等）で見出しを変える
    local case_label="評価者の判断が誤り" lesson="上記のようなケースで甘い判定をしないこと"
    if [ "$ej_rec" = "$cj" ]; then
      case_label="人間注記あり"
      lesson="判定は正しかったが、人間の注記の観点を今後の判定に織り込むこと"
    fi

    output="${output}
### 事例 ${idx}（${case_label}）
- タスク: ${tid}
- 評価者: ${ej_rec} (confidence: ${ej_conf})
- 人間: ${hj} — \"${hr}\"
- 正解: ${cj}
- 教訓: ${lesson}
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
    # grep -c は no-match でも "0" を stdout に出して exit 1 する — || echo 0 だと
    # "0\n0" の二重出力になり後続の数値比較が壊れるため || true でガード
    total=$(grep -c "\"evaluator\":\"${evaluator}\"" "$CALIBRATION_FILE" 2>/dev/null || true)
    case "$total" in (*[!0-9]*|"") total=0 ;; esac
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

# ===== 人間フィードバックの記録（feedback.sh / detect_reworked_tasks 共用） =====
# record_feedback_for_task <task_id> <human_judgment> <human_rationale>
# ${DEV_LOG_DIR}/<task_id>/ に evaluator 結果 (evidence-da / qa-evaluator /
# ux-judgment) が存在すれば各 evaluator 名で記録する。
# 1つも無い場合も evaluator="human-direct" として記録する（傾向分析用に捨てない — P0-2）。
# stdout: 記録件数
# record_feedback_for_task <task_id> <human_judgment> <rationale> [correct_override]
# correct_override（batch#11 R18a）: 非空なら全 evaluator の correct_judgment をこの値にする。
# 背景: accept-with-notes の既定は「評価器自身の判定 = 正解」で、人間が QA の fail を覆して完了確定
# した事例（4.5f cal-20260821-274）が乖離 0 として記録され、較正が逆向きに働いていた。
record_feedback_for_task() {
  local task_id="$1"
  local human_judgment="$2"
  local human_rationale="$3"
  local correct_override="${4:-}"
  local task_dir="${DEV_LOG_DIR:-.forge/logs/development}/${task_id}"
  local recorded=0

  local evaluator result_file result correct
  for evaluator in evidence-da qa-evaluator ux-judgment; do
    result_file="${task_dir}/${evaluator}-result.json"
    [ -f "$result_file" ] || continue
    result=$(cat "$result_file" 2>/dev/null)
    jq empty <<< "$result" 2>/dev/null || continue

    # correct_judgment: --correct 上書きが最優先。無ければ reject 時は evaluator 別の
    # 「本来出すべきだった判定」、accept-with-notes 時は evaluator 自身の判定（乖離なし・注記のみ蓄積）
    if [ -n "$correct_override" ]; then
      correct="$correct_override"
    elif [ "$human_judgment" = "reject" ]; then
      case "$evaluator" in
        evidence-da) correct="pivot" ;;
        *)           correct="fail" ;;
      esac
    else
      correct=$(jq -r '.recommendation // .verdict // "unknown"' <<< "$result" 2>/dev/null)
    fi

    record_calibration_example "$evaluator" "$task_id" \
      "$result" "$human_judgment" "$human_rationale" "$correct"
    log "  [CALIBRATION] ${evaluator} キャリブレーション記録: ${task_id} (${human_judgment})"
    recorded=$((recorded + 1))
  done

  if [ "$recorded" -eq 0 ]; then
    local direct_correct="${correct_override:-$human_judgment}"
    record_calibration_example "human-direct" "$task_id" \
      '{"recommendation":"none"}' "$human_judgment" "$human_rationale" "$direct_correct"
    log "  [CALIBRATION] human-direct キャリブレーション記録: ${task_id} (${human_judgment})"
    recorded=1
  fi

  echo "$recorded"
}

# ===== Reworked タスク自動検出 =====
# detect_reworked_tasks
# completed だったが pending に戻されたタスクを検出し、evaluator 結果が存在すれば
# キャリブレーションレコードを自動生成する。検出は2経路（P0-1）:
#   A) .previous_status == "completed"（update_task_status 経由の差戻し）
#   B) task-events.jsonl の最終 status_changed が completed（人間が raw jq で
#      .status のみ書き換えた場合 — 運用ガイドの手動復旧手順はこちらの経路になる）
# 重複記録防止: A は del(.previous_status)、B は rework_detected イベントを最終
# completed イベントより後に追記することで担保する。
detect_reworked_tasks() {
  [ -f "$TASK_STACK" ] || return 0

  local events_file="${TASK_EVENTS_FILE:-${PROJECT_ROOT:-.}/.forge/state/task-events.jsonl}"

  local pending_ids
  pending_ids=$(jq_safe -r '.tasks[]? | select(.status == "pending") | .task_id' \
    "$TASK_STACK" 2>/dev/null || true)
  [ -z "$pending_ids" ] && return 0

  local task_id
  for task_id in $pending_ids; do
    local reworked=false
    local prev
    prev=$(jq_safe -r --arg id "$task_id" \
      '.tasks[] | select(.task_id == $id) | .previous_status // ""' "$TASK_STACK" 2>/dev/null)

    if [ "$prev" = "completed" ]; then
      reworked=true
    elif [ -f "$events_file" ] && [ -s "$events_file" ]; then
      # 経路B: このタスクの最終 status_changed が completed で、それより後に
      # rework_detected が無い場合のみ検出。created_at より古いイベント（別スタック
      # の同名タスク残骸）は無視する
      local created_at
      created_at=$(jq_safe -r --arg id "$task_id" \
        '.tasks[] | select(.task_id == $id) | .created_at // ""' "$TASK_STACK" 2>/dev/null)
      local is_reworked
      is_reworked=$(jq_safe -s -r --arg tid "$task_id" --arg ca "$created_at" '
        [ .[] | select(.task_id == $tid) |
          select($ca == "" or ((.timestamp // "") >= $ca)) ] as $evs |
        [ $evs | to_entries[] |
          select(.value.event == "status_changed" and
                 (.value.detail.new_status // "") == "completed") | .key ] as $completed_idx |
        if ($completed_idx | length) == 0 then "false" else
          ($completed_idx | max) as $lastc |
          ([ $evs | to_entries[] |
             select(.value.event == "rework_detected") | .key |
             select(. > $lastc) ] | length) as $nr |
          (if $nr == 0 then "true" else "false" end)
        end
      ' "$events_file" 2>/dev/null || echo "false")
      [ "$is_reworked" = "true" ] && reworked=true
    fi

    [ "$reworked" = "true" ] || continue

    log "  [CALIBRATION] rework 検出: ${task_id}（completed → pending）"
    record_feedback_for_task "$task_id" "reject" "タスクが人間により rework に戻された" > /dev/null

    # 重複記録防止マーカー（経路B用）
    if type record_task_event &>/dev/null; then
      record_task_event "$task_id" "rework_detected" '{}'
    fi

    # previous_status をクリア（経路A用の重複記録防止）
    jq --arg id "$task_id" '
      .tasks |= map(
        if .task_id == $id then del(.previous_status) else . end
      )
    ' "$TASK_STACK" > "${TASK_STACK}.tmp" 2>/dev/null && mv "${TASK_STACK}.tmp" "$TASK_STACK"
  done
}
