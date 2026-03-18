#!/bin/bash
# mutation-runner.sh — Mutation計画をメカニカルに実行するスクリプト（LLM呼び出しなし）
# 使い方: mutation-runner.sh <mutation-plan.json> <work-dir> <output-file> [timeout-per-mutant]
#
# mutation-plan.json: Mutation Auditor が生成した計画
# work-dir: テスト実行の作業ディレクトリ
# output-file: 結果を出力するJSONファイルパス
# timeout-per-mutant: 各mutantのテスト実行タイムアウト秒（デフォルト: 60）

set -uo pipefail

# ===== 共通初期化 =====
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"
LOG_PREFIX="[mutation-runner]"

# ===== 引数チェック =====
if [ $# -lt 3 ]; then
  echo "使い方: $0 <mutation-plan.json> <work-dir> <output-file> [timeout-per-mutant]" >&2
  exit 1
fi

MUTATION_PLAN="$1"
WORK_DIR="$2"
OUTPUT_FILE="$3"
TIMEOUT_PER_MUTANT="${4:-60}"

if [ ! -f "$MUTATION_PLAN" ]; then
  echo -e "${RED}[ERROR] mutation-plan.json が見つかりません: ${MUTATION_PLAN}${NC}" >&2
  exit 1
fi

if [ ! -d "$WORK_DIR" ]; then
  echo -e "${RED}[ERROR] 作業ディレクトリが見つかりません: ${WORK_DIR}${NC}" >&2
  exit 1
fi

# ===== バックアップ復元（安全対策: trap EXIT） =====
_restore_all_backups() {
  local backup_files
  backup_files=$(find "$WORK_DIR" -name '*.mutation-backup' -type f 2>/dev/null)
  if [ -n "$backup_files" ]; then
    while IFS= read -r backup; do
      local original="${backup%.mutation-backup}"
      if [ -f "$backup" ]; then
        mv "$backup" "$original"
        log "復元: ${original}"
      fi
    done <<< "$backup_files"
  fi
}
trap _restore_all_backups EXIT INT TERM

# ===== 起動時: 残存バックアップファイルの復元チェック =====
log "起動時バックアップ復元チェック..."
_restore_all_backups

# ===== 計画データ読み込み =====
TASK_ID=$(jq_safe -r '.task_id // "unknown"' "$MUTATION_PLAN")
TEST_COMMAND=$(jq_safe -r '.test_command // ""' "$MUTATION_PLAN")
MUTANT_COUNT=$(jq '.mutants | length' "$MUTATION_PLAN")

if [ -z "$TEST_COMMAND" ]; then
  log "テストコマンドが未定義。中断"
  jq -n --arg tid "$TASK_ID" '{
    task_id: $tid,
    total: 0, killed: 0, survived: 0, errors: 0,
    survival_rate: 0, error_rate: 1.0,
    verdict: "REPLAN",
    verdict_reason: "テストコマンドが未定義",
    results: [], surviving_mutants: []
  }' > "$OUTPUT_FILE"
  exit 0
fi

log "タスクID: ${TASK_ID}"
log "テストコマンド: ${TEST_COMMAND}"
log "mutant数: ${MUTANT_COUNT}"
log "タイムアウト/mutant: ${TIMEOUT_PER_MUTANT}秒"

# ===== 結果変数 =====
killed=0
survived=0
errors=0
results_json="[]"
surviving_json="[]"
total_lines=0
test_result_status=""
test_output=""
test_exit_code=0

# ===== per-mutant 実行 =====
for i in $(seq 0 $((MUTANT_COUNT - 1))); do
  mutant_id=$(jq_safe -r ".mutants[$i].id" "$MUTATION_PLAN")
  category=$(jq_safe -r ".mutants[$i].category // \"unknown\"" "$MUTATION_PLAN")
  target_behavior=$(jq_safe -r ".mutants[$i].target_behavior // \"null\"" "$MUTATION_PLAN")
  target_file=$(jq_safe -r ".mutants[$i].file" "$MUTATION_PLAN")
  line_start=$(jq_safe -r ".mutants[$i].line_start" "$MUTATION_PLAN")
  line_end=$(jq_safe -r ".mutants[$i].line_end" "$MUTATION_PLAN")
  original_hint=$(jq_safe -r ".mutants[$i].original_hint // \"\"" "$MUTATION_PLAN")
  mutant_code=$(jq_safe -r ".mutants[$i].mutant" "$MUTATION_PLAN")
  rationale=$(jq_safe -r ".mutants[$i].rationale // \"\"" "$MUTATION_PLAN")

  log "--- ${mutant_id} (${category}) ---"

  # ファイル存在チェック
  local_file="${WORK_DIR}/${target_file}"
  if [ ! -f "$local_file" ]; then
    log "  ✗ ファイルが見つかりません: ${target_file}"
    errors=$((errors + 1))
    results_json=$(echo "$results_json" | jq --arg id "$mutant_id" \
      '. += [{"id": $id, "status": "error", "detail": "file not found"}]')
    continue
  fi

  # Step 1: ターゲット行取得
  actual_content=$(sed -n "${line_start},${line_end}p" "$local_file")

  # Step 2: original_hint との簡易比較（安全弁）
  if [ -n "$original_hint" ]; then
    # original_hint の主要部分がターゲット行に含まれているかチェック
    # 先頭/末尾の空白を除去して比較
    trimmed_hint=$(echo "$original_hint" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    if [ -n "$trimmed_hint" ] && ! echo "$actual_content" | grep -qF "$trimmed_hint"; then
      log "  ⚠ original_hint 不一致 — スキップ"
      log "    expected: ${trimmed_hint}"
      log "    actual:   $(echo "$actual_content" | head -1)"
      errors=$((errors + 1))
      results_json=$(echo "$results_json" | jq --arg id "$mutant_id" \
        '. += [{"id": $id, "status": "error", "detail": "original_hint mismatch"}]')
      continue
    fi
  fi

  # Step 3: バックアップ
  backup_file="${local_file}.mutation-backup"
  cp "$local_file" "$backup_file"

  # Step 4: 置換（head/printf/tail でsed multi-line回避）
  {
    if [ "$line_start" -gt 1 ]; then
      head -n $((line_start - 1)) "$backup_file"
    fi
    printf '%s\n' "$mutant_code"
    total_lines=$(wc -l < "$backup_file")
    if [ "$line_end" -lt "$total_lines" ]; then
      tail -n +$((line_end + 1)) "$backup_file"
    fi
  } > "$local_file"

  # Step 5: テスト実行
  test_result_status=""
  test_output=""
  if test_output=$(timeout "$TIMEOUT_PER_MUTANT" bash -c "export PATH='${WORK_DIR}/node_modules/.bin:${PATH}' && cd '${WORK_DIR}' && ${TEST_COMMAND}" 2>&1); then
    # テスト PASS → mutant survived（テストが変更を検出できなかった）
    test_result_status="survived"
    survived=$((survived + 1))
    log "  survived (テスト未検出)"
  else
    test_exit_code=$?
    if [ "$test_exit_code" -eq 124 ]; then
      # タイムアウト → error
      test_result_status="error"
      errors=$((errors + 1))
      log "  error (タイムアウト: ${TIMEOUT_PER_MUTANT}秒)"
    else
      # テスト FAIL → mutant killed（テストが変更を検出した）
      test_result_status="killed"
      killed=$((killed + 1))
      log "  killed (テスト検出)"
    fi
  fi

  # Step 6: バックアップ復元
  mv "$backup_file" "$local_file"

  # 結果記録
  results_json=$(echo "$results_json" | jq \
    --arg id "$mutant_id" \
    --arg status "$test_result_status" \
    --arg detail "$category" \
    '. += [{"id": $id, "status": $status, "detail": $detail}]')

  # survived の場合、surviving_mutants に追加
  if [ "$test_result_status" = "survived" ]; then
    surviving_json=$(echo "$surviving_json" | jq \
      --arg id "$mutant_id" \
      --arg cat "$category" \
      --arg behavior "$target_behavior" \
      --arg rat "$rationale" \
      '. += [{"id": $id, "category": $cat, "target_behavior": $behavior, "rationale": $rat}]')
  fi
done

# ===== 集計・Verdict判定 =====
total=$((killed + survived + errors))

# ゼロ除算防止
if [ "$total" -eq 0 ]; then
  survival_rate="0"
  error_rate="1.0"
else
  # bashは浮動小数点演算不可 → awk使用
  survival_rate=$(awk "BEGIN { printf \"%.2f\", $survived / $total }")
  error_rate=$(awk "BEGIN { printf \"%.2f\", $errors / $total }")
fi

log "=== 集計 ==="
log "total=${total} killed=${killed} survived=${survived} errors=${errors}"
log "survival_rate=${survival_rate} error_rate=${error_rate}"

# Verdict: error_rate, survival_threshold は呼び出し元が判定するため、
# ここでは参考情報として出力する。
# 呼び出し元(ralph-loop.sh)が threshold と比較して最終判定を行う。

# ===== 結果出力 =====
jq -n \
  --arg tid "$TASK_ID" \
  --argjson total "$total" \
  --argjson killed "$killed" \
  --argjson survived "$survived" \
  --argjson errors "$errors" \
  --argjson survival_rate "$survival_rate" \
  --argjson error_rate "$error_rate" \
  --argjson results "$results_json" \
  --argjson surviving "$surviving_json" \
  '{
    task_id: $tid,
    total: $total,
    killed: $killed,
    survived: $survived,
    errors: $errors,
    survival_rate: $survival_rate,
    error_rate: $error_rate,
    results: $results,
    surviving_mutants: $surviving
  }' > "$OUTPUT_FILE"

log "結果出力: ${OUTPUT_FILE}"
