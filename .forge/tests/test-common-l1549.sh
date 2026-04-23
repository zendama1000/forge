#!/bin/bash
# test-common-l1549.sh — common.sh L1549 付近の `jq -r | while read` → `jq_lines` 置換検証
#
# 検証項目 (5):
#   (a) パターン消失: common.sh 内で `jq -r` の直後に `| while read` が続く行が消えている
#   (b) jq_lines 呼出存在: common.sh に jq_lines 呼出が最低1箇所ある
#   (c) jq_safe 呼出温存: 既存 jq_safe 呼出が残っている（置換対象外）
#   (d) tr -d '\r' 残存: 意図的な raw jq + 手動 tr -d '\r' 行が健在
#   (e) validate_l1_coverage 契約: fixture 入力での出力が expected と diff 一致
#
# 使い方: bash .forge/tests/test-common-l1549.sh
# exit 0: 全5項目 PASS / exit 1: 1つでも失敗

# set -u は意図的に無効: common.sh を source した際の内部変数参照を許容するため
# また bash 4.3 以前では empty array の "${arr[@]}" が unbound 扱いになるのを回避する

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_SH="${PROJECT_ROOT}/.forge/lib/common.sh"
FIXTURES_DIR="${PROJECT_ROOT}/.forge/tests/fixtures"

PASS=0
FAIL=0
FAIL_MESSAGES=()

assert_pass() {
  PASS=$((PASS + 1))
  echo "  ✓ $1"
}

assert_fail() {
  FAIL=$((FAIL + 1))
  FAIL_MESSAGES+=("$1")
  echo "  ✗ $1"
}

echo "=== test-common-l1549.sh ==="
echo "Target: ${COMMON_SH}"
echo ""

# 前提: common.sh が存在するか
if [ ! -f "$COMMON_SH" ]; then
  echo "FATAL: common.sh が見つかりません: ${COMMON_SH}"
  exit 1
fi

# -----------------------------------------------------------------------------
# (a) パターン消失: `jq -r` + `| while read` が common.sh から消えている
# behavior: 検出すべきでないパターン: common.sh 内で 'jq -r' の直後に '| while read' が続く行が validate_l1_coverage / process_criteria 系関数の本体から消えている
# -----------------------------------------------------------------------------
echo "[a] パターン消失チェック (jq -r ... | while read)"
# 同一行で jq -r が直接 | while read に接続している行のみを検出（jq_safe/jq_lines は除外）
if grep -nE '(^|[^a-zA-Z_])jq[[:space:]]+-r[^|]*\|[[:space:]]*while[[:space:]]+read' "$COMMON_SH" | grep -v '^[[:space:]]*#' >/dev/null 2>&1; then
  matches=$(grep -nE '(^|[^a-zA-Z_])jq[[:space:]]+-r[^|]*\|[[:space:]]*while[[:space:]]+read' "$COMMON_SH" | grep -v '^[[:space:]]*#' | head -5)
  assert_fail "(a) raw 'jq -r ... | while read' パターンが残存: ${matches}"
else
  assert_pass "(a) raw 'jq -r ... | while read' パターンは消失済み"
fi

# -----------------------------------------------------------------------------
# (b) jq_lines 呼出存在: common.sh に jq_lines が最低1箇所使われている
# behavior: 検出すべきパターン: common.sh に 'jq_lines' の呼出が最低1箇所存在する
# -----------------------------------------------------------------------------
echo "[b] jq_lines 呼出存在チェック"
# 関数定義 `jq_lines()` 以外の呼出行をカウント
jq_lines_call_count=$(grep -cE '(^|[^a-zA-Z_])jq_lines[[:space:]]+-' "$COMMON_SH" 2>/dev/null || echo 0)
if [ "$jq_lines_call_count" -ge 1 ]; then
  assert_pass "(b) jq_lines 呼出 ${jq_lines_call_count} 箇所検出"
else
  assert_fail "(b) jq_lines 呼出が1箇所も見つからない"
fi

# behavior: 検出すべきパターン: common.sh に 'jq_lines()' の関数定義が1箇所のみ存在する
echo "[b2] jq_lines 関数定義が1箇所のみ存在することを確認"
jq_lines_def_count=$(grep -cE '^jq_lines\(\)[[:space:]]*\{' "$COMMON_SH" 2>/dev/null || echo 0)
if [ "$jq_lines_def_count" -eq 1 ]; then
  assert_pass "(b2) jq_lines() 関数定義がちょうど1箇所存在"
else
  assert_fail "(b2) jq_lines() 関数定義の数が不正: ${jq_lines_def_count} (期待: 1)"
fi

# -----------------------------------------------------------------------------
# (c) jq_safe 呼出温存: 既存の jq_safe 呼出が残っている
# behavior: エッジケース: jq_safe の既存呼出は温存されている（置換対象外）
# -----------------------------------------------------------------------------
echo "[c] jq_safe 呼出温存チェック"
jq_safe_call_count=$(grep -cE '(^|[^a-zA-Z_])jq_safe[[:space:]]+-' "$COMMON_SH" 2>/dev/null || echo 0)
if [ "$jq_safe_call_count" -ge 5 ]; then
  assert_pass "(c) jq_safe 呼出 ${jq_safe_call_count} 箇所温存（期待: >=5）"
else
  assert_fail "(c) jq_safe 呼出が想定より少ない: ${jq_safe_call_count} (期待: >=5)"
fi

# -----------------------------------------------------------------------------
# (d) tr -d '\r' 残存: 意図的な raw jq + 手動 tr -d '\r' 行が健在
# behavior: 検出すべきでないパターン: 意図的な raw jq 呼出（手動 tr -d '\r' 付き）が誤って削除されていないこと（L586/L612/L613/L1455 付近の 'tr -d' が健在）
# -----------------------------------------------------------------------------
echo "[d] tr -d '\\r' 残存チェック"
# 'tr -d' の出現回数で健在性を確認（jq_safe / jq_lines の定義 2 箇所 + その他 raw 使用箇所）
tr_d_r_count=$(grep -cE "tr[[:space:]]+-d[[:space:]]+'\\\\r'" "$COMMON_SH" 2>/dev/null || echo 0)
if [ "$tr_d_r_count" -ge 10 ]; then
  assert_pass "(d) tr -d '\\r' 出現数 ${tr_d_r_count} 件（期待: >=10）"
else
  assert_fail "(d) tr -d '\\r' 出現数が想定より少ない: ${tr_d_r_count} (期待: >=10)"
fi

# 追加: get_relevant_lessons 内の jq -r ... | tr -d が健在か（L599/L625/L626 相当）
echo "[d2] raw jq + tr -d '\\r' パイプパターン健在チェック"
raw_jq_tr_count=$(grep -cE "jq[[:space:]]+-r[^|]*\|[[:space:]]*tr[[:space:]]+-d[[:space:]]+'\\\\r'" "$COMMON_SH" 2>/dev/null || echo 0)
if [ "$raw_jq_tr_count" -ge 1 ]; then
  assert_pass "(d2) 'jq -r ... | tr -d \\r' パターン ${raw_jq_tr_count} 箇所健在"
else
  assert_fail "(d2) 'jq -r ... | tr -d \\r' パターンが全滅（誤って削除された可能性）"
fi

# -----------------------------------------------------------------------------
# (e) validate_l1_coverage 契約: fixture 入力での出力が expected と diff 一致
# behavior: [追加] fixture を使った契約互換性検証 — validate_l1_coverage の stdout が期待値と完全一致
# -----------------------------------------------------------------------------
echo "[e] validate_l1_coverage 契約互換性チェック (fixture diff)"

for f in criteria-sample.json task-stack-sample.json expected-l1-coverage.txt; do
  if [ ! -f "${FIXTURES_DIR}/${f}" ]; then
    assert_fail "(e) fixture が見つからない: ${FIXTURES_DIR}/${f}"
  fi
done

# common.sh を source して validate_l1_coverage を呼ぶ
# log() が stderr に出すため、stdout のみキャプチャ
ACTUAL_OUT="$(mktemp 2>/dev/null || echo "/tmp/test-common-l1549-actual-$$")"

# サブシェルで実行し、PROJECT_ROOT 汚染を避ける
(
  set +u  # common.sh 内部の未定義変数参照を許容
  # shellcheck disable=SC1090
  source "$COMMON_SH"
  validate_l1_coverage \
    "${FIXTURES_DIR}/task-stack-sample.json" \
    "${FIXTURES_DIR}/criteria-sample.json"
) > "$ACTUAL_OUT" 2>/dev/null

# 期待値と diff
if diff -u "${FIXTURES_DIR}/expected-l1-coverage.txt" "$ACTUAL_OUT" > /dev/null 2>&1; then
  assert_pass "(e) validate_l1_coverage 出力が expected と一致"
else
  diff_output=$(diff -u "${FIXTURES_DIR}/expected-l1-coverage.txt" "$ACTUAL_OUT" 2>&1 | head -20)
  assert_fail "(e) validate_l1_coverage 出力が expected と不一致:
${diff_output}"
fi

rm -f "$ACTUAL_OUT"

# -----------------------------------------------------------------------------
# サマリ
# -----------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -eq 0 ]; then
  echo "✓ All assertions passed"
  exit 0
else
  echo "✗ Failures:"
  for msg in "${FAIL_MESSAGES[@]}"; do
    echo "  - $msg"
  done
  exit 1
fi
