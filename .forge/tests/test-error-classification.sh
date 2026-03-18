#!/bin/bash
# test-error-classification.sh — record_error() の error_category 自動分類テスト
# 検証対象: .forge/lib/common.sh の classify_error_category() / record_error()
#
# 実行方法: bash .forge/tests/test-error-classification.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

COMMON_SH="$SCRIPT_DIR/../lib/common.sh"

# ===== セットアップ =====
TMP_DIR=$(mktemp -d)
ERRORS_FILE="$TMP_DIR/errors.jsonl"
RESEARCH_DIR="test-research-dir"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# common.sh から classify_error_category・record_error を抽出してロード
eval "$(extract_all_functions_awk "$COMMON_SH" "classify_error_category" "record_error")"

# helper: ERRORS_FILE をリセットして record_error を呼び出し、末尾エントリを返す
run_and_get_last() {
  local stage="$1"
  local message="$2"
  > "$ERRORS_FILE"
  record_error "$stage" "$message"
  tail -1 "$ERRORS_FILE"
}

echo "=== test-error-classification.sh ==="
echo ""
echo "--- カテゴリ分類テスト ---"

# behavior: record_error() に stage='researcher' message='timeout after 600s' を渡す → errors.jsonlの末尾エントリに error_category='timeout' が含まれる（正常系: タイムアウト分類）
result=$(run_and_get_last "researcher" "timeout after 600s")
assert_contains \
  "timeout分類: error_category=timeout が含まれる" \
  '"error_category":"timeout"' \
  "$result"

# behavior: record_error() に stage='synthesizer' message='出力が不正なJSON' を渡す → error_category='invalid_json' が含まれる（正常系: JSON不正分類）
result=$(run_and_get_last "synthesizer" "出力が不正なJSON")
assert_contains \
  "invalid_json分類: error_category=invalid_json が含まれる" \
  '"error_category":"invalid_json"' \
  "$result"

# behavior: record_error() に stage='researcher' message='429 Too Many Requests' を渡す → error_category='rate_limit' が含まれる（正常系: レートリミット分類）
result=$(run_and_get_last "researcher" "429 Too Many Requests")
assert_contains \
  "rate_limit分類: error_category=rate_limit が含まれる" \
  '"error_category":"rate_limit"' \
  "$result"

# behavior: record_error() に stage='researcher' message='出力が空' を渡す → error_category='empty_output' が含まれる（正常系: 空出力分類）
result=$(run_and_get_last "researcher" "出力が空")
assert_contains \
  "empty_output分類: error_category=empty_output が含まれる" \
  '"error_category":"empty_output"' \
  "$result"

# behavior: record_error() に stage='unknown' message='予期しないエラーパターン xyz123' を渡す → error_category='unknown' が含まれる（エッジケース: 未知パターンのフォールバック）
result=$(run_and_get_last "unknown" "予期しないエラーパターン xyz123")
assert_contains \
  "unknown分類: 未知パターンは error_category=unknown にフォールバックする" \
  '"error_category":"unknown"' \
  "$result"

echo ""
echo "--- 後方互換性テスト ---"

# behavior: record_error() の出力がstage, message, research_dir, timestamp, resolution フィールドを維持する → 既存フォーマットとの後方互換性を保証（回帰検証）
result=$(run_and_get_last "researcher" "test backward compat error")
assert_contains "後方互換性: stage フィールドが維持される"        '"stage":'        "$result"
assert_contains "後方互換性: message フィールドが維持される"      '"message":'      "$result"
assert_contains "後方互換性: research_dir フィールドが維持される" '"research_dir":' "$result"
assert_contains "後方互換性: timestamp フィールドが維持される"    '"timestamp":'    "$result"
assert_contains "後方互換性: resolution フィールドが維持される"   '"resolution":'   "$result"

echo ""
echo "--- エッジケース追加テスト ---"

# [追加] 終了コード 124 (timeout コマンド終了) → timeout 分類
result=$(run_and_get_last "researcher" "process killed")
ERRORS_FILE_BAK="$ERRORS_FILE"
> "$ERRORS_FILE"
record_error "researcher" "process killed" "124"
exit_code_result=$(tail -1 "$ERRORS_FILE")
assert_contains \
  "[追加] 終了コード124: error_category=timeout に分類される" \
  '"error_category":"timeout"' \
  "$exit_code_result"

# [追加] rate_limit パターン: rate_limit 文字列を含むメッセージ
result=$(run_and_get_last "synthesizer" "error: rate_limit exceeded")
assert_contains \
  "[追加] rate_limit文字列: error_category=rate_limit に分類される" \
  '"error_category":"rate_limit"' \
  "$result"

# [追加] 複数エントリが ERRORS_FILE に追記されることを確認
> "$ERRORS_FILE"
record_error "stage_a" "timeout error"
record_error "stage_b" "429 error"
record_error "stage_c" "xyz"
line_count=$(wc -l < "$ERRORS_FILE" | tr -d ' ')
assert_eq \
  "[追加] 複数エラー記録: ERRORS_FILE に3行追記される" \
  "3" \
  "$line_count"

print_test_summary
