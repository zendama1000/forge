#!/bin/bash
# test-silent-death-sample.sh — サイレント死サンプル fixture
# 用途: run-all-tests.sh の完了マーカー検証（PASSED: N/M パース）の動作確認用。
# .forge/tests/test-zz-silent.sh としてコピーして注入すると、
# ランナーがこのテストを FAIL（完了マーカー欠落）として計上することを検証できる。
#
# 再現パターン: source 失敗（ヘルパー不在）で途中死するが、
# `|| true` により exit 0 で終了 → exit code だけでは検出不能なサイレント死。

set -uo pipefail

echo "silent-death-sample: setting up..."

# 存在しないヘルパーを source → 失敗するが握りつぶす（途中死の再現）
source "$(dirname "$0")/nonexistent-helper-for-silent-death.sh" 2>/dev/null || true

# 本来ここで assert 群と「ALL PASSED: N/M」サマリーが出力されるはずだが、
# source 失敗により一切実行されない想定。完了マーカーを出力せずに exit 0 する。
exit 0
