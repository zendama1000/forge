#!/bin/bash
# test-l3-timeout-runtime.sh — Layer 2 e2e
# task_run_l3_test() の修正が「実行時に」 layer_3[].timeout_sec を読み取り、
# execute_l3_test の timeout 引数として確実に渡ることを e2e で検証する。
#
# 使い方:
#   bash .forge/tests/e2e/test-l3-timeout-runtime.sh
#
# 設計: --l3-dynamic セクションを実コード経路で起動し、
# 期待値（dynamic 動的読み取り＋fallback の挙動）を満たすことを最終 stamp とする。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
TEST_TIMEOUT_SH="${SCRIPT_DIR}/.forge/tests/test-timeout-sec.sh"

if [ ! -f "$TEST_TIMEOUT_SH" ]; then
  echo "ERROR: test-timeout-sec.sh not found: $TEST_TIMEOUT_SH" >&2
  exit 1
fi

# Capture file は固定パス（L3-002 verify_command との連動）
CAPTURE_FILE="/tmp/captured-args.txt"
rm -f "$CAPTURE_FILE" 2>/dev/null || true

echo "===== L2 e2e: L3 dynamic timeout runtime propagation ====="

# 1) --l3-dynamic を --capture 付きで実行
if ! bash "$TEST_TIMEOUT_SH" --l3-dynamic --capture "$CAPTURE_FILE"; then
  echo "✗ --l3-dynamic が失敗"
  exit 1
fi

# 2) capture file に 5 件の timeout_sec= 行があること
if [ ! -f "$CAPTURE_FILE" ]; then
  echo "✗ capture file 未生成: $CAPTURE_FILE"
  exit 1
fi

CAPTURE_COUNT=$(grep -c '^timeout_sec=' "$CAPTURE_FILE" 2>/dev/null || echo 0)
if [ "$CAPTURE_COUNT" -ne 5 ]; then
  echo "✗ capture 数が 5 でない: $CAPTURE_COUNT"
  echo "--- captured contents ---"
  cat "$CAPTURE_FILE"
  exit 1
fi
echo "✓ capture 5/5 行確認"

# 3) timeout_sec=600 が少なくとも1件存在すること（layer_3.timeout_sec=600 → 600 propagate）
if ! grep -q '^timeout_sec=600$' "$CAPTURE_FILE"; then
  echo "✗ timeout_sec=600 が capture に存在しない（dynamic 読み取りが効いていない）"
  echo "--- captured contents ---"
  cat "$CAPTURE_FILE"
  exit 1
fi
echo "✓ timeout_sec=600 propagate 確認"

# 4) 多入力 [60, 300, 1800] が個別に伝播すること
for v in 60 300 1800; do
  if ! grep -q "^timeout_sec=${v}\$" "$CAPTURE_FILE"; then
    echo "✗ timeout_sec=${v} が capture に存在しない（multi-entry の連続独立性が効いていない）"
    echo "--- captured contents ---"
    cat "$CAPTURE_FILE"
    exit 1
  fi
done
echo "✓ multi-entry [60, 300, 1800] 個別伝播確認"

# 5) フォールバック (timeout_sec=120) が unset case で記録されていること
if ! grep -q '^timeout_sec=120$' "$CAPTURE_FILE"; then
  echo "✗ timeout_sec=120 (fallback) が capture に存在しない"
  echo "--- captured contents ---"
  cat "$CAPTURE_FILE"
  exit 1
fi
echo "✓ unset → 120 fallback 確認"

echo ""
echo "===== L2 e2e: ALL PASSED ====="
exit 0
