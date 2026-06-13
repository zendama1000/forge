#!/bin/bash
# test-l2-wiring.sh — Layer 2 検証が ralph-loop の「実経路」で配線されていることの行動テスト
#
# 目的: phase3.sh の run_phase3()（= ralph-loop 本流が L2_AUTO_RUN ガード経由で呼ぶ実体）を
#       実際に source して fixture task-stack に対して走らせ、L2 実行経路が配線されているかを
#       挙動レベルで検証する。run_claude はモックしない（L2 実行は claude を介さないため）。
#       進捗 UI 等の非・検証対象副作用のみ stub する。
#
# 隔離: 全成果物は mktemp -d 配下に閉じ込め、実 .forge/state を一切汚染しない。
#       run_phase3 は report を相対パス .forge/state/integration-report.json に書くため、
#       隔離ディレクトリ内へ cd してから実行することでリダイレクトを閉じ込める。
#
# 使い方: bash .forge/tests/test-l2-wiring.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/.forge/tests/fixtures"
COMMON_SH="${SCRIPT_DIR}/.forge/lib/common.sh"
PHASE3_SH="${SCRIPT_DIR}/.forge/lib/phase3.sh"
RALPH_SH="${SCRIPT_DIR}/.forge/loops/ralph-loop.sh"
FIXTURE="${FIXTURES_DIR}/task-stack-l2wiring.json"
REAL_REPORT="${SCRIPT_DIR}/.forge/state/integration-report.json"

# 共通テストヘルパー (assert_eq / assert_contains / PASS_COUNT / print_test_summary / colors)
source "${SCRIPT_DIR}/.forge/tests/test-helpers.sh"

# ===== 被テスト実経路を source（run_claude はモックしない） =====
# shellcheck disable=SC1090
source "$COMMON_SH"
# shellcheck disable=SC1090
source "$PHASE3_SH"

# get_task_json は ralph-loop.sh:506 で定義される単純アクセサ。
# ralph-loop.sh 全体を source すると main ループが走るため、同一実装をミラー定義する。
get_task_json() { jq --arg id "$1" '.tasks[] | select(.task_id == $id)' "$TASK_STACK"; }

# ===== 非・検証対象の副作用のみ stub（L2 実行ロジック本体は stub しない） =====
update_progress() { :; }   # PROGRESS_FILE 書込抑止（set -u 安全 + 実 state 非汚染）
sync_task_stack() { :; }   # 万一 create_l2_fix_task 経路に入っても実ファイル非更新

# ===== 実 .forge/state 汚染検出スナップショット =====
snapshot_real_report() {
  if [ -f "$REAL_REPORT" ]; then
    cksum "$REAL_REPORT" 2>/dev/null
  else
    echo "ABSENT"
  fi
}
REAL_BEFORE="$(snapshot_real_report)"

echo -e "${BOLD}===== test-l2-wiring.sh — L2 実経路配線 行動テスト =====${NC}"
echo ""

# ===== フィクスチャ妥当性 =====
if jq -e . "$FIXTURE" >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} fixture task-stack-l2wiring.json は valid JSON"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} fixture task-stack-l2wiring.json が無効 — 以降検証不能"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  print_test_summary
  exit "$FAIL_COUNT"
fi

# ===== 隔離環境構築（mktemp -d） =====
ISO="$(mktemp -d -t test-l2-wiring-XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$ISO" 2>/dev/null || true' EXIT
mkdir -p "${ISO}/.forge/state"

# fixture を隔離内へコピー（万一の更新も隔離内に閉じ込める）
cp "$FIXTURE" "${ISO}/task-stack.json"

# 最小 development.json: health_check_url を空にして server requires の curl ヘルスチェックを回避し、
# start_l2_server スタブの先で check_l2_requires(server) が通過するようにする。
cat > "${ISO}/development.json" <<'EOF'
{
  "server": {
    "start_command": "echo stub-server-should-not-run",
    "health_check_url": "",
    "startup_timeout_sec": 5
  },
  "layer_2": {
    "auto_run_after_all_tasks": true,
    "setup_commands": []
  },
  "agent_effort": { "implementer": "medium" }
}
EOF

# ===== run_phase3 が要求する環境変数 =====
export TASK_STACK="${ISO}/task-stack.json"
export WORK_DIR="$ISO"
export DEV_CONFIG="${ISO}/development.json"
export L2_DEFAULT_TIMEOUT=30
export L2_MAX_TIMEOUT=60
export L2_FAIL_CREATES_TASK=false
export L3_ENABLED=false
export L2_SERVER_MARKER="${ISO}/server-stub-called.marker"

# ===== start_l2_server を stub（マーカー書出のみ。実サーバーは起動しない） =====
# サーバー起動経路の配線確認用。実 PID は持たないため stop_l2_server は no-op になる。
start_l2_server() {
  printf 'start_l2_server invoked\n' > "$L2_SERVER_MARKER"
  L2_SERVER_PID=""
  return 0
}

# ===== L2 実経路を実行（隔離 cwd 内。report は相対 .forge/state/ に出力される） =====
ISO_REPORT="${ISO}/.forge/state/integration-report.json"
RUN_RC=0
( cd "$ISO" && run_phase3 ) >/dev/null 2>&1 || RUN_RC=$?

# behavior: layer_2 未定義のタスク → L2 実行がスキップされエラーにならない（エッジケース）
assert_eq "run_phase3 がエラー終了しない (exit 0)" "0" "$RUN_RC"

# ===== report 生成確認 =====
if [ -f "$ISO_REPORT" ]; then
  echo -e "  ${GREEN}✓${NC} integration-report.json が隔離ディレクトリに生成された"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} integration-report.json 未生成 — 以降の検証不能"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  print_test_summary
  exit "$FAIL_COUNT"
fi

# behavior: layer_2.command に無害コマンド（echo ok）を持つ fixture task-stack で L2 実行経路を起動 → コマンドが実際に実行され成功記録される
l2_pass=$(jq -r '.layer_2.pass' "$ISO_REPORT" | tr -d '\r')
assert_eq "L2 pass 件数 == 1 (echo ok タスクが成功記録)" "1" "$l2_pass"

pass_result=$(jq -r '.layer_2.results[] | select(.task_id=="task-l2-pass") | .result' "$ISO_REPORT" | tr -d '\r')
assert_eq "task-l2-pass の result == pass" "pass" "$pass_result"

# 実行された物的証拠: L2 command が WORK_DIR にサイドエフェクトファイルを残す
executed_content=""
[ -f "${ISO}/l2-executed.txt" ] && executed_content="$(tr -d '\r\n' < "${ISO}/l2-executed.txt")"
assert_eq "L2 command が実際に実行された (サイドエフェクトファイル内容)" "executed" "$executed_content"

# behavior: layer_2.command が exit 1 を返す fixture → L2 失敗として検出・記録される（失敗経路の配線確認）
l2_fail=$(jq -r '.layer_2.fail' "$ISO_REPORT" | tr -d '\r')
assert_eq "L2 fail 件数 == 1 (exit 1 タスクが失敗記録)" "1" "$l2_fail"

fail_result=$(jq -r '.layer_2.results[] | select(.task_id=="task-l2-fail") | .result' "$ISO_REPORT" | tr -d '\r')
assert_eq "task-l2-fail の result == fail" "fail" "$fail_result"

fail_output=$(jq -r '.layer_2.results[] | select(.task_id=="task-l2-fail") | .output' "$ISO_REPORT")
assert_contains "L2 失敗出力がキャプチャされ記録される (L2-FAILMSG)" "L2-FAILMSG" "$fail_output"

# behavior: layer_2 未定義のタスク → L2 実行がスキップされエラーにならない（エッジケース）
undef_in_results=$(jq -r '[.layer_2.results[] | select(.task_id=="task-l2-undefined")] | length' "$ISO_REPORT" | tr -d '\r')
assert_eq "layer_2 未定義タスクは L2 結果に出現しない (収集対象外)" "0" "$undef_in_results"

l2_skip=$(jq -r '.layer_2.skip' "$ISO_REPORT" | tr -d '\r')
assert_eq "L2 skip 件数 == 0 (未定義は収集前に除外されエラーなし)" "0" "$l2_skip"

# behavior: start_l2_server スタブが呼ばれたことをマーカーファイルで確認 → サーバー起動経路が配線されている
if [ -f "$L2_SERVER_MARKER" ]; then
  echo -e "  ${GREEN}✓${NC} start_l2_server 経路が配線されマーカー生成 (server requires → 起動経路)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} start_l2_server マーカー未生成 — サーバー起動経路が未配線"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# behavior: テスト成果物が隔離ディレクトリ（mktemp -d）内のみに生成され、実 .forge/state を汚染しない
REAL_AFTER="$(snapshot_real_report)"
assert_eq "実 .forge/state/integration-report.json が変化しない (汚染なし)" "$REAL_BEFORE" "$REAL_AFTER"

# behavior: テスト成果物が隔離ディレクトリ（mktemp -d）内のみに生成され、実 .forge/state を汚染しない
report_under_iso="no"
case "$ISO_REPORT" in "$ISO"/*) report_under_iso="yes" ;; esac
assert_eq "生成された report が mktemp 隔離ディレクトリ配下に存在" "yes" "$report_under_iso"

# ===== 静的配線検査 [追加]: ralph-loop 本流から run_phase3 へ到達可能であること =====
# behavior: [追加] ralph-loop.sh が phase3.sh を source している
if grep -qE 'source .*\.forge/lib/phase3\.sh' "$RALPH_SH"; then
  echo -e "  ${GREEN}✓${NC} [追加] ralph-loop が phase3.sh を source"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} [追加] ralph-loop が phase3.sh を source していない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# behavior: [追加] ralph-loop が L2_AUTO_RUN=true ガード直下で run_phase3 を呼ぶ（本流配線）
if grep -A3 'L2_AUTO_RUN.*=.*"true"' "$RALPH_SH" 2>/dev/null | grep -q 'run_phase3'; then
  echo -e "  ${GREEN}✓${NC} [追加] L2_AUTO_RUN=true ガード直下で run_phase3 が呼ばれる"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} [追加] L2_AUTO_RUN=true ガード直下で run_phase3 が呼ばれない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

print_test_summary
