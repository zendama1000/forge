#!/bin/bash
# bad-render-loop.sh — 構文エラーを意図的に注入した fixture。
# test-render-loop-syntax.sh が bash -n 非0 を期待するためのサンプル。
# DO NOT EXECUTE: この fixture は実行用ではなく、構文チェック専用。
set -euo pipefail

validate_render_output() {
  # 'then' と 'done' を欠いた構造 — bash -n で syntax error になる
  if [ -z "$1" ]
    echo "missing-then"
  fi
  while true
    echo "missing-do"
  # 'done' も未記述
}
