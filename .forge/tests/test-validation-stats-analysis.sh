#!/bin/bash
# test-validation-stats-analysis.sh — バリデーション統計分析 ユニットテスト
# 対象: .forge/lib/common.sh の record_validation_stat() stage/was_schema_mode フィールド,
#       run_claude() FORGE_SCHEMA_MODE エクスポート, aggregate_validation_stats()
# 実行方法: bash .forge/tests/test-validation-stats-analysis.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-validation-stats-analysis.sh — バリデーション統計分析 =====${NC}"
echo ""

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_SH="${REAL_ROOT}/.forge/lib/common.sh"

# ===== セットアップ =====
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_ROOT="$TMP_DIR"
RESEARCH_DIR="test-vstats"
ERRORS_FILE="${TMP_DIR}/errors.jsonl"
VALIDATION_STATS_FILE="${TMP_DIR}/validation-stats.jsonl"
mkdir -p "${TMP_DIR}/.forge/state"

touch "$ERRORS_FILE" "$VALIDATION_STATS_FILE"

# common.sh から必要な関数を抽出してロード
EXTRACT_FILE="${TMP_DIR}/_funcs.sh"
extract_all_functions_awk "$COMMON_SH" \
  record_validation_stat \
  aggregate_validation_stats \
  jq_safe \
  log \
  > "$EXTRACT_FILE"

source "$EXTRACT_FILE"

# log を no-op（テスト出力を汚さない）
log() { :; }

# ===== テスト 1: stage フィールドが記録される =====
# behavior: validate_json()がvalidation-stats.jsonlに書き込むエントリにstageフィールドが含まれる（正常系: ステージ識別）
echo ""
echo -e "${BOLD}--- テスト 1: stage フィールドが validation-stats.jsonl エントリに含まれる ---${NC}"
{
  FORGE_SCHEMA_MODE="false"
  > "$VALIDATION_STATS_FILE"

  record_validation_stat "researcher" "crlf"

  entry=$(tail -1 "$VALIDATION_STATS_FILE")
  stage_val=$(echo "$entry" | jq -r '.stage // "MISSING"' 2>/dev/null | tr -d '\r')

  assert_eq "stage フィールドが 'researcher' として記録される" "researcher" "$stage_val"

  # recovery_level も確認（既存フィールド保全）
  rl_val=$(echo "$entry" | jq -r '.recovery_level // "MISSING"' 2>/dev/null | tr -d '\r')
  assert_eq "recovery_level フィールドが 'crlf' として記録される" "crlf" "$rl_val"
}

# ===== テスト 2: FORGE_SCHEMA_MODE=true → was_schema_mode=true =====
# behavior: run_claude()で--json-schemaを使用した場合 → validation-stats.jsonlエントリにwas_schema_mode=trueが記録される（正常系: スキーマモード識別）
echo ""
echo -e "${BOLD}--- テスト 2: FORGE_SCHEMA_MODE=true → was_schema_mode=true ---${NC}"
{
  FORGE_SCHEMA_MODE="true"
  export FORGE_SCHEMA_MODE
  > "$VALIDATION_STATS_FILE"

  record_validation_stat "researcher" "crlf"

  entry=$(tail -1 "$VALIDATION_STATS_FILE")
  wsm=$(echo "$entry" | jq -r 'if has("was_schema_mode") then (.was_schema_mode | tostring) else "MISSING" end' 2>/dev/null | tr -d '\r')

  assert_eq "FORGE_SCHEMA_MODE=true → was_schema_mode=true" "true" "$wsm"
}

# ===== テスト 3: FORGE_SCHEMA_MODE=false → was_schema_mode=false =====
# behavior: run_claude()で--json-schemaを使用しなかった場合 → was_schema_mode=falseが記録される（正常系: 非スキーマモード識別）
echo ""
echo -e "${BOLD}--- テスト 3: FORGE_SCHEMA_MODE=false → was_schema_mode=false ---${NC}"
{
  FORGE_SCHEMA_MODE="false"
  export FORGE_SCHEMA_MODE
  > "$VALIDATION_STATS_FILE"

  record_validation_stat "synthesizer" "extraction"

  entry=$(tail -1 "$VALIDATION_STATS_FILE")
  wsm=$(echo "$entry" | jq -r 'if has("was_schema_mode") then (.was_schema_mode | tostring) else "MISSING" end' 2>/dev/null | tr -d '\r')

  assert_eq "FORGE_SCHEMA_MODE=false → was_schema_mode=false" "false" "$wsm"
}

# ===== テスト 4: aggregate_validation_stats() stage別のfailed率を集計 =====
# behavior: aggregate_validation_stats()関数がstage別のfailed率をJSON出力する → {stage: 'researcher', total: N, failed: M, failed_rate: M/N}（正常系: 集計）
echo ""
echo -e "${BOLD}--- テスト 4: aggregate_validation_stats() stage別集計 ---${NC}"
{
  STATS_FILE="${TMP_DIR}/test4-stats.jsonl"
  > "$STATS_FILE"

  # テストデータ: researcher = 1 crlf + 1 failed → total=2, failed=1, failed_rate=0.5
  jq -n -c \
    '{stage: "researcher", recovery_level: "crlf", was_schema_mode: false, research_dir: "test", timestamp: "2026-01-01T00:00:00+00:00", session_id: "s1", call_id: "1"}' \
    >> "$STATS_FILE"
  jq -n -c \
    '{stage: "researcher", recovery_level: "failed", was_schema_mode: false, research_dir: "test", timestamp: "2026-01-01T00:00:01+00:00", session_id: "s1", call_id: "2"}' \
    >> "$STATS_FILE"

  result=$(aggregate_validation_stats "$STATS_FILE")

  stage_val=$(echo "$result" | jq -r '.[0].stage // "MISSING"' 2>/dev/null | tr -d '\r')
  total_val=$(echo "$result" | jq -r '.[0].total // "MISSING"' 2>/dev/null | tr -d '\r')
  failed_val=$(echo "$result" | jq -r '.[0].failed // "MISSING"' 2>/dev/null | tr -d '\r')
  failed_rate_val=$(echo "$result" | jq -r '.[0].failed_rate // "MISSING"' 2>/dev/null | tr -d '\r')

  assert_eq "stage フィールドが 'researcher'" "researcher" "$stage_val"
  assert_eq "total が 2" "2" "$total_val"
  assert_eq "failed が 1" "1" "$failed_val"
  assert_eq "failed_rate が 0.5" "0.5" "$failed_rate_val"
}

# ===== テスト 5: 空ファイル → [] =====
# behavior: 空のvalidation-stats.jsonlに対してaggregate_validation_stats()を呼出 → 空のJSON配列[]を返す（エッジケース: データなし）
echo ""
echo -e "${BOLD}--- テスト 5: 空ファイルに対して aggregate_validation_stats() → [] ---${NC}"
{
  EMPTY_FILE="${TMP_DIR}/empty-stats.jsonl"
  touch "$EMPTY_FILE"

  result=$(aggregate_validation_stats "$EMPTY_FILE")

  assert_eq "空ファイル → [] を返す" "[]" "$result"

  # ファイルが存在しない場合も [] を返す
  NONEXIST_FILE="${TMP_DIR}/nonexistent-stats.jsonl"
  result2=$(aggregate_validation_stats "$NONEXIST_FILE")
  assert_eq "存在しないファイル → [] を返す" "[]" "$result2"
}

# ===== テスト 6: run_claude() に FORGE_SCHEMA_MODE エクスポートが実装されている =====
# behavior: [追加] run_claude() の json_schema_file 指定時に FORGE_SCHEMA_MODE=true が設定される（コード存在確認）
echo ""
echo -e "${BOLD}--- テスト 6: run_claude() に FORGE_SCHEMA_MODE エクスポートが存在する ---${NC}"
{
  # common.sh に FORGE_SCHEMA_MODE の設定コードが存在するか確認
  if grep -q "FORGE_SCHEMA_MODE" "$COMMON_SH" 2>/dev/null; then
    assert_eq "FORGE_SCHEMA_MODE が common.sh に存在する" "found" "found"
  else
    assert_eq "FORGE_SCHEMA_MODE が common.sh に存在する" "found" "not-found"
  fi

  # export FORGE_SCHEMA_MODE が存在するか確認
  if grep -q "export FORGE_SCHEMA_MODE" "$COMMON_SH" 2>/dev/null; then
    assert_eq "export FORGE_SCHEMA_MODE が common.sh に存在する" "found" "found"
  else
    assert_eq "export FORGE_SCHEMA_MODE が common.sh に存在する" "found" "not-found"
  fi

  # _rc_use_schema の値を FORGE_SCHEMA_MODE に代入するコードが存在するか
  if grep -q 'FORGE_SCHEMA_MODE="\$_rc_use_schema"' "$COMMON_SH" 2>/dev/null; then
    assert_eq "FORGE_SCHEMA_MODE=\$_rc_use_schema の代入が存在する" "found" "found"
  else
    assert_eq "FORGE_SCHEMA_MODE=\$_rc_use_schema の代入が存在する" "found" "not-found"
  fi
}

# ===== テスト 7: 複数ステージの集計 =====
# behavior: [追加] 複数ステージのデータに対して aggregate_validation_stats() → 各ステージが独立して集計される
echo ""
echo -e "${BOLD}--- テスト 7: 複数ステージの集計 ---${NC}"
{
  MULTI_FILE="${TMP_DIR}/multi-stats.jsonl"
  > "$MULTI_FILE"

  # researcher: 3 entries, 1 failed
  jq -n -c '{stage: "researcher", recovery_level: "crlf", was_schema_mode: false}' >> "$MULTI_FILE"
  jq -n -c '{stage: "researcher", recovery_level: "crlf", was_schema_mode: false}' >> "$MULTI_FILE"
  jq -n -c '{stage: "researcher", recovery_level: "failed", was_schema_mode: false}' >> "$MULTI_FILE"

  # synthesizer: 2 entries, 0 failed
  jq -n -c '{stage: "synthesizer", recovery_level: "fence", was_schema_mode: true}' >> "$MULTI_FILE"
  jq -n -c '{stage: "synthesizer", recovery_level: "extraction", was_schema_mode: false}' >> "$MULTI_FILE"

  result=$(aggregate_validation_stats "$MULTI_FILE")
  count=$(echo "$result" | jq 'length' 2>/dev/null | tr -d '\r')

  researcher_total=$(echo "$result" | jq -r '[.[] | select(.stage == "researcher")] | .[0].total' 2>/dev/null | tr -d '\r')
  researcher_failed=$(echo "$result" | jq -r '[.[] | select(.stage == "researcher")] | .[0].failed' 2>/dev/null | tr -d '\r')
  synthesizer_failed=$(echo "$result" | jq -r '[.[] | select(.stage == "synthesizer")] | .[0].failed' 2>/dev/null | tr -d '\r')
  synthesizer_total=$(echo "$result" | jq -r '[.[] | select(.stage == "synthesizer")] | .[0].total' 2>/dev/null | tr -d '\r')

  assert_eq "集計結果が 2 ステージ" "2" "$count"
  assert_eq "researcher total=3" "3" "$researcher_total"
  assert_eq "researcher failed=1" "1" "$researcher_failed"
  assert_eq "synthesizer total=2" "2" "$synthesizer_total"
  assert_eq "synthesizer failed=0" "0" "$synthesizer_failed"
}

# ===== テスト 8: FORGE_SCHEMA_MODE 未設定 → was_schema_mode=false =====
# behavior: [追加] FORGE_SCHEMA_MODE 未設定時 → was_schema_mode=false（エッジケース: 環境変数未設定）
echo ""
echo -e "${BOLD}--- テスト 8: FORGE_SCHEMA_MODE 未設定 → was_schema_mode=false ---${NC}"
{
  unset FORGE_SCHEMA_MODE 2>/dev/null || true
  > "$VALIDATION_STATS_FILE"

  record_validation_stat "sc" "crlf"

  entry=$(tail -1 "$VALIDATION_STATS_FILE")
  wsm=$(echo "$entry" | jq -r 'if has("was_schema_mode") then (.was_schema_mode | tostring) else "MISSING" end' 2>/dev/null | tr -d '\r')

  assert_eq "FORGE_SCHEMA_MODE 未設定 → was_schema_mode=false" "false" "$wsm"

  # 後続のために復元
  export FORGE_SCHEMA_MODE="false"
}

# ===== テスト 9: aggregate_validation_stats() の出力が有効な JSON 配列 =====
# behavior: [追加] aggregate_validation_stats() の出力が jq でパース可能な有効な JSON 配列
echo ""
echo -e "${BOLD}--- テスト 9: aggregate_validation_stats() 出力が有効な JSON 配列 ---${NC}"
{
  DATA_FILE="${TMP_DIR}/test9-stats.jsonl"
  > "$DATA_FILE"

  jq -n -c '{stage: "sc", recovery_level: "crlf", was_schema_mode: false}' >> "$DATA_FILE"
  jq -n -c '{stage: "sc", recovery_level: "failed", was_schema_mode: true}' >> "$DATA_FILE"
  jq -n -c '{stage: "da", recovery_level: "fence", was_schema_mode: false}' >> "$DATA_FILE"

  result=$(aggregate_validation_stats "$DATA_FILE")

  # jq でパース可能か確認
  if echo "$result" | jq empty 2>/dev/null; then
    assert_eq "出力が有効な JSON" "valid" "valid"
  else
    assert_eq "出力が有効な JSON" "valid" "invalid: ${result}"
  fi

  # 配列であることを確認
  is_array=$(echo "$result" | jq 'if type == "array" then "yes" else "no" end' 2>/dev/null | tr -d '"\r')
  assert_eq "出力が JSON 配列" "yes" "$is_array"

  # was_schema_mode フィールドが記録されていることを確認（sc ステージ）
  sc_stats=$(echo "$result" | jq -r '[.[] | select(.stage == "sc")] | .[0]' 2>/dev/null)
  sc_total=$(echo "$sc_stats" | jq -r '.total // "MISSING"' 2>/dev/null | tr -d '\r')
  assert_eq "sc total=2 (was_schema_mode 混在でも集計される)" "2" "$sc_total"
}

# ===== サマリー =====
print_test_summary
