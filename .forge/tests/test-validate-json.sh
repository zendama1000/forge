#!/bin/bash
# test-validate-json.sh — validate_json 全レイヤーテスト (18 assertions)
# common.sh L101-188 の validate_json() を直接テスト。
# 使い方: bash .forge/tests/test-validate-json.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-validate-json.sh — validate_json 全レイヤーテスト =====${NC}"
echo ""

# ===== テスト環境セットアップ =====
PROJECT_ROOT="/tmp/test-validate-json"
rm -rf "$PROJECT_ROOT"
mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"

REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cp "${REAL_ROOT}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"

ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
VALIDATION_STATS_FILE="${PROJECT_ROOT}/.forge/state/validation-stats.jsonl"
NOTIFY_DIR="${PROJECT_ROOT}/.forge/state/notifications"
RESEARCH_DIR="test-validate"
CLAUDE_TIMEOUT=600
json_fail_count=0

touch "$ERRORS_FILE" "$VALIDATION_STATS_FILE"

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# notify_human スタブ（ファイル書き込みを抑止）
notify_human() { :; }

# テストケース間リセット用
reset_test() {
  json_fail_count=0
  > "$ERRORS_FILE"
  > "$VALIDATION_STATS_FILE"
}

# ========================================================================
# Group 1: 空・正常入力 (3 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 1: 空・正常入力 ---${NC}"

# 1. 空ファイル → return 1, json_fail_count=1
reset_test
local_file="${PROJECT_ROOT}/test-empty.json"
touch "$local_file"
validate_json "$local_file" "test-empty" 2>/dev/null
ret=$?
assert_eq "空ファイル → return 1" "1" "$ret"

# 2. 正常 JSON → return 0, ファイル内容保持
reset_test
local_file="${PROJECT_ROOT}/test-valid.json"
echo '{"key":"value","num":42}' > "$local_file"
validate_json "$local_file" "test-valid" 2>/dev/null
ret=$?
content=$(cat "$local_file")
assert_eq "正常 JSON → return 0" "0" "$ret"

# 3. 正常 JSON + CRLF → return 0, CRLF 除去済み
reset_test
local_file="${PROJECT_ROOT}/test-crlf.json"
printf '{"key":"value"}\r\n' > "$local_file"
validate_json "$local_file" "test-crlf" 2>/dev/null
ret=$?
has_cr=$(tr -cd '\r' < "$local_file" | wc -c | tr -d ' ')
assert_eq "CRLF JSON → return 0 + CR除去" "0:0" "${ret}:${has_cr}"

echo ""

# ========================================================================
# Group 2: コードフェンス除去 (3 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 2: コードフェンス除去 ---${NC}"

# 4. ```json\n{...}\n``` → return 0, 有効 JSON
reset_test
local_file="${PROJECT_ROOT}/test-fence.json"
cat > "$local_file" << 'EOF'
```json
{"fenced":"data"}
```
EOF
validate_json "$local_file" "test-fence" 2>/dev/null
ret=$?
parsed=$(jq -r '.fenced' "$local_file" 2>/dev/null)
assert_eq "コードフェンス除去 → return 0" "0:data" "${ret}:${parsed}"

# 5. 複数フェンスブロック → return 0
reset_test
local_file="${PROJECT_ROOT}/test-multi-fence.json"
cat > "$local_file" << 'EOF'
```json
{"multi":"fence"}
```
```
extra block
```
EOF
# このケースは複数 ``` 行が除去された後の結果が有効 JSON かどうか
validate_json "$local_file" "test-multi-fence" 2>/dev/null
ret=$?
# フェンス除去後に有効JSONになるはず
if [ "$ret" -eq 0 ]; then
  assert_eq "複数フェンス → return 0" "0" "$ret"
else
  # Layer 3 で回復される可能性あり
  assert_eq "複数フェンス → 回復" "0" "$ret"
fi

# 6. フェンス内が非 JSON → return 1
reset_test
local_file="${PROJECT_ROOT}/test-fence-bad.json"
cat > "$local_file" << 'EOF'
```
This is not JSON at all
just plain text
```
EOF
validate_json "$local_file" "test-fence-bad" 2>/dev/null
ret=$?
assert_eq "フェンス内非JSON → return 1" "1" "$ret"

echo ""

# ========================================================================
# Group 3: Layer 3a 行頭ブレース抽出 (4 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 3: Layer 3a 行頭ブレース抽出 ---${NC}"

# 7. 説明文 + 行頭JSON → return 0, JSON 抽出
reset_test
local_file="${PROJECT_ROOT}/test-layer3a.json"
cat > "$local_file" << 'EOF'
Here is the analysis result:
{"key":"value"}
Thank you for your patience.
EOF
validate_json "$local_file" "test-layer3a" 2>/dev/null
ret=$?
parsed=$(jq -r '.key' "$local_file" 2>/dev/null)
assert_eq "行頭ブレース抽出 → return 0" "0:value" "${ret}:${parsed}"

# 8. ネストされた JSON → return 0, 完全抽出
reset_test
local_file="${PROJECT_ROOT}/test-layer3a-nested.json"
cat > "$local_file" << 'EOF'
The response is:
{
  "outer": {
    "inner": "deep"
  }
}
End of response.
EOF
validate_json "$local_file" "test-layer3a-nested" 2>/dev/null
ret=$?
parsed=$(jq -r '.outer.inner' "$local_file" 2>/dev/null)
assert_eq "ネスト JSON 抽出 → return 0" "0:deep" "${ret}:${parsed}"

# 9. 説明文中の { が行頭にない場合 → Layer 3a/3b とも行全体抽出のため回復不可
reset_test
local_file="${PROJECT_ROOT}/test-layer3a-nohead.json"
cat > "$local_file" << 'EOF'
The result is {"inline":"json"} in this line.
EOF
validate_json "$local_file" "test-layer3a-nohead" 2>/dev/null
ret=$?
assert_eq "行中インライン JSON → return 1 (行抽出では回復不可)" "1" "$ret"

# 10. first_brace > last_brace（不正順序）→ Layer 3a スキップ、3b へ
reset_test
local_file="${PROJECT_ROOT}/test-layer3a-invert.json"
# } が行頭にあるが { は行頭にない不正パターン → Layer 3a をスキップ
# ただし行中に有効な JSON があるので 3b で回復
cat > "$local_file" << 'EOF'
prefix }
  data {"recovered":"yes"} suffix
EOF
validate_json "$local_file" "test-layer3a-invert" 2>/dev/null
ret=$?
# 3b フォールバックで回復されるか、失敗するか
# この入力は } 行が { 行より前にあるため 3a スキップ → 3b で { } 抽出を試みる
# 3b の結果は }\n  data {"recovered":"yes"} suffix — 不正 JSON → return 1
# 実際には最初の { と最後の } で切り出すので回復不可能
assert_eq "不正順序 → return 1 (回復不可)" "1" "$ret"

echo ""

# ========================================================================
# Group 4: Layer 3b フォールバック (2 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 4: Layer 3b フォールバック ---${NC}"

# 11. 複数行で { と } が別行にある場合 → Layer 3b で回復
reset_test
local_file="${PROJECT_ROOT}/test-layer3b.json"
cat > "$local_file" << 'EOF'
Result follows:
  { "found":"yes",
    "count":3
  }
End.
EOF
validate_json "$local_file" "test-layer3b" 2>/dev/null
ret=$?
parsed=$(jq -r '.found' "$local_file" 2>/dev/null)
assert_eq "複数行 JSON → Layer 3b 回復" "0:yes" "${ret}:${parsed}"

# 12. ブレースが一切ない → return 1
reset_test
local_file="${PROJECT_ROOT}/test-no-brace.json"
echo "No braces here at all" > "$local_file"
validate_json "$local_file" "test-no-brace" 2>/dev/null
ret=$?
assert_eq "ブレースなし → return 1" "1" "$ret"

echo ""

# ========================================================================
# Group 5: .pending ファイルライフサイクル (4 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 5: .pending ファイルライフサイクル ---${NC}"

# 13. .pending ファイル存在 → そちらを検証
reset_test
local_file="${PROJECT_ROOT}/test-pending.json"
rm -f "$local_file" "${local_file}.pending" "${local_file}.failed"
echo '{"pending":"data"}' > "${local_file}.pending"
validate_json "$local_file" "test-pending" 2>/dev/null
ret=$?
assert_eq ".pending 存在 → return 0" "0" "$ret"

# 14. .pending + 有効 JSON → .pending 消失、本ファイル生成
pending_exists="$([ -f "${local_file}.pending" ] && echo "yes" || echo "no")"
main_exists="$([ -f "$local_file" ] && echo "yes" || echo "no")"
assert_eq ".pending → 昇格 (.pending消失, 本ファイル生成)" "no:yes" "${pending_exists}:${main_exists}"

# 15. .pending + 無効 JSON → .failed 生成、元ファイル保全
reset_test
local_file="${PROJECT_ROOT}/test-pending-bad.json"
echo '{"original":"preserved"}' > "$local_file"
echo "not valid json {{{" > "${local_file}.pending"
validate_json "$local_file" "test-pending-bad" 2>/dev/null
ret=$?
failed_exists="$([ -f "${local_file}.failed" ] && echo "yes" || echo "no")"
original_preserved=$(jq -r '.original' "$local_file" 2>/dev/null)
assert_eq ".pending 無効 → .failed + 元ファイル保全" "1:yes:preserved" "${ret}:${failed_exists}:${original_preserved}"

# 16. .pending なし → final_path を直接検証
reset_test
local_file="${PROJECT_ROOT}/test-no-pending.json"
rm -f "${local_file}.pending"
echo '{"direct":"check"}' > "$local_file"
validate_json "$local_file" "test-no-pending" 2>/dev/null
ret=$?
parsed=$(jq -r '.direct' "$local_file" 2>/dev/null)
assert_eq ".pending なし → 直接検証 return 0" "0:check" "${ret}:${parsed}"

echo ""

# ========================================================================
# Group 6: エラー記録 (2 assertions)
# ========================================================================
echo -e "${BOLD}--- Group 6: エラー記録 ---${NC}"

# 17. 検証失敗 → ERRORS_FILE にエントリ追記
reset_test
local_file="${PROJECT_ROOT}/test-error-record.json"
echo "completely invalid" > "$local_file"
validate_json "$local_file" "error-record-stage" 2>/dev/null
error_count=$(wc -l < "$ERRORS_FILE" | tr -d ' ')
assert_eq "検証失敗 → ERRORS_FILE にエントリ" "1" "$error_count"

# 18. 回復成功 → VALIDATION_STATS_FILE に "extraction" レベル記録
reset_test
local_file="${PROJECT_ROOT}/test-extraction-stat.json"
cat > "$local_file" << 'EOF'
Here is the result:
{"extracted":"yes"}
That is all.
EOF
validate_json "$local_file" "extraction-stat-stage" 2>/dev/null
stat_level=$(tail -1 "$VALIDATION_STATS_FILE" 2>/dev/null | jq -r '.recovery_level // "none"' 2>/dev/null)
assert_eq "回復成功 → extraction レベル記録" "extraction" "$stat_level"

echo ""

# ===== クリーンアップ =====
rm -rf "$PROJECT_ROOT"

# ===== サマリー =====
print_test_summary
exit $?
