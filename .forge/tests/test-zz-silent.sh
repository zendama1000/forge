#!/bin/bash
# test-zz-silent.sh — NEUTRALIZED STRAY（silent-death メタテスト用スクラッチ枠）
#
# 正本: サイレント死サンプルの本体は .forge/tests/fixtures/test-silent-death-sample.sh。
#   silent-death メタテスト（criteria L2/L3）は、その正本を本ファイル名
#   (.forge/tests/test-zz-silent.sh) へ一時的に cp →
#   run-all-tests.sh が「完了マーカー欠落」で FAIL することを確認 → rm する設計のため、
#   本ファイルは「通常は存在しない」のが正しい状態。
#
# 経緯: 過去の cp→rm メタテストが rm 前に中断され、本ファイルが stray として残留した。
#   run-all-tests.sh の自動検出（test-*.sh 末尾追加）が本ファイルを拾い、
#   完了マーカーを出さない silent サンプルとして FAIL 計上 → スイート全体が赤になっていた。
#   本実行環境ではファイル削除ができないため、削除の代替として「合格マーカーを出力する
#   無害なプレースホルダ」へ中和する。メタテストは依然 cp で本内容を上書きし rm するため、
#   silent-death 検出の挙動は不変（cp 後は正本 silent サンプルが走り、想定どおり FAIL する）。
#
# 検証: 正本フィクスチャが fixtures/ に存在することを1点だけ確認する（自己無撞着性ガード）。
#   print_test_summary で完了マーカー "ALL PASSED: N/M" を必ず出力し、
#   run-all-tests.sh のサイレント死検出に引っかからない（exit 0 + マーカーあり + assert>=1）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-zz-silent.sh（中和済みプレースホルダ） =====${NC}"
echo ""

CANON_FIXTURE="${SCRIPT_DIR}/fixtures/test-silent-death-sample.sh"
if [ -f "$CANON_FIXTURE" ]; then
  assert_eq "正本 silent-death フィクスチャが fixtures/ に存在する" "yes" "yes"
else
  assert_eq "正本 silent-death フィクスチャが fixtures/ に存在する" "yes" "no(absent)"
fi

print_test_summary
exit $?
