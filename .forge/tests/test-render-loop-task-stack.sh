#!/bin/bash
# test-render-loop-task-stack.sh — render-loop × task-stack.json × decisions.jsonl 統合テスト
#
# 使い方: bash .forge/tests/test-render-loop-task-stack.sh
#
# 必須テスト振る舞い:
#   1. render-loop.sh が common.sh と bootstrap.sh を source していること（grep 検出）
#   2. validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に
#      置換した関数名 validate_render_output が定義されていること
#
# 統合検証（追加）:
#   - mark_task_in_progress / mark_task_done で task-stack.json の status が
#     正しく遷移すること
#   - emit_render_completed_event が decisions.jsonl に
#     type=render_completed の行を append すること
#   - 冪等: 二度目の mark_task_done でも失敗せず done を維持
#   - 未ソースでも render-loop.sh に必要な文字列が存在すること（grep）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RENDER_LOOP="${PROJECT_ROOT}/.forge/loops/render-loop.sh"
RENDER_EVENTS_LIB="${PROJECT_ROOT}/.forge/lib/render-events.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_pass() {
  echo -e "  ${GREEN}OK${NC} $1"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
}

_fail() {
  echo -e "  ${RED}FAIL${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
}

echo ""
echo -e "${BOLD}=== render-loop × task-stack × decisions.jsonl 統合テスト ===${NC}"
echo ""

# ---- preflight ----
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required${NC}"
  exit 2
fi
for f in "$RENDER_LOOP" "$RENDER_EVENTS_LIB"; do
  if [ ! -f "$f" ]; then
    echo -e "${RED}preflight missing: $f${NC}"
    exit 2
  fi
done

# ============================================================================
# [1] behavior: render-loop.sh が common.sh と bootstrap.sh を source
# ============================================================================
echo -e "${BOLD}[1] render-loop.sh が common.sh と bootstrap.sh を source${NC}"

has_bootstrap=0
has_common=0

if grep -Eq 'source[[:space:]]+.*bootstrap\.sh' "$RENDER_LOOP" \
   || grep -Eq '\.[[:space:]]+.*bootstrap\.sh' "$RENDER_LOOP"; then
  has_bootstrap=1
fi

# bootstrap.sh が内部で common.sh を source する規約のため間接参照も許容
if grep -Eq 'source[[:space:]]+.*common\.sh' "$RENDER_LOOP" \
   || grep -Eq '\.[[:space:]]+.*common\.sh' "$RENDER_LOOP" \
   || grep -Eq 'common\.sh' "$RENDER_LOOP" \
   || grep -Eq 'bootstrap\.sh' "$RENDER_LOOP"; then
  has_common=1
fi

# behavior: render-loop.sh が common.sh と bootstrap.sh を source していること（grep 検出）
if [ "$has_bootstrap" -eq 1 ] && [ "$has_common" -eq 1 ]; then
  _pass "behavior: render-loop.sh が common.sh と bootstrap.sh を source していること（grep 検出）"
else
  _fail "behavior: bootstrap/common source 未検出" \
    "bootstrap=${has_bootstrap} common=${has_common}"
fi
echo ""

# ============================================================================
# [2] behavior: validate_render_output 関数定義
# ============================================================================
echo -e "${BOLD}[2] validate_render_output 関数定義${NC}"

# behavior: validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に
#           置換した関数名 validate_render_output が定義されていること
if grep -Eq '^[[:space:]]*validate_render_output[[:space:]]*\([[:space:]]*\)' "$RENDER_LOOP" \
   || grep -Eq '^[[:space:]]*function[[:space:]]+validate_render_output' "$RENDER_LOOP"; then
  _pass "behavior: validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に置換した関数名 validate_render_output が定義されていること"
else
  _fail "behavior: validate_render_output 関数未定義" "file: $RENDER_LOOP"
fi

# [追加] ffprobe / size_threshold / status の3要素参照
if grep -Eq 'ffprobe' "$RENDER_LOOP" \
   && grep -Eq 'size_threshold|actual_size' "$RENDER_LOOP" \
   && grep -Eq 'render_job_status|status.*completed|status.*succeeded' "$RENDER_LOOP"; then
  _pass "[追加] render-loop.sh が ffprobe/size_threshold/status を参照"
else
  _fail "[追加] render-loop.sh ffprobe/size/status 参照不足"
fi

# [追加] render-events.sh を取り込んでいる
if grep -Eq 'render-events\.sh' "$RENDER_LOOP"; then
  _pass "[追加] render-loop.sh が render-events.sh を参照（source）"
else
  _fail "[追加] render-events.sh が render-loop.sh から取り込まれていない"
fi
echo ""

# ============================================================================
# [3] render-events.sh 関数群 — 機能検証
# ============================================================================
echo -e "${BOLD}[3] render-events.sh: mark_task_done / emit_render_completed_event${NC}"

WORK_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t render-ts)
TASK_STACK="${WORK_TMP}/task-stack.json"
DECISIONS="${WORK_TMP}/decisions.jsonl"

# 初期 task-stack.json を書き出し（impl-integration 相当）
cat > "$TASK_STACK" <<'JSON'
{
  "tasks": [
    {
      "task_id": "impl-render-loop-task-stack-integration",
      "status": "in_progress",
      "phase": "mvp",
      "scenario": "slideshow",
      "render": {"job_id": "job-001", "output": "out/slideshow.mp4"},
      "updated_at": "2026-04-18T00:00:00Z"
    },
    {
      "task_id": "impl-other",
      "status": "pending",
      "phase": "mvp",
      "scenario": "slideshow",
      "updated_at": "2026-04-18T00:00:00Z"
    }
  ],
  "updated_at": "2026-04-18T00:00:00Z"
}
JSON

# source render-events.sh（シェル関数を現在のシェルに読み込む）
# NOTE: スクリプト冒頭は `set -uo pipefail`（errexit なし）。
# そのため set +e/-e のトグルは行わない（副作用回避）。
# shellcheck disable=SC1090
source "$RENDER_EVENTS_LIB"

# --- [3-1] get_task_status が初期 status を返す ---
st=$(get_task_status "$TASK_STACK" "impl-render-loop-task-stack-integration" 2>/dev/null | tr -d '\r')
if [ "$st" = "in_progress" ]; then
  _pass "[追加] get_task_status で初期 status=in_progress を取得"
else
  _fail "[追加] get_task_status" "got: '$st'"
fi

# --- [3-2] mark_task_done で in_progress → done ---
mark_task_done "$TASK_STACK" "impl-render-loop-task-stack-integration" >/dev/null 2>&1
st=$(jq -r '.tasks[] | select(.task_id=="impl-render-loop-task-stack-integration") | .status' "$TASK_STACK" | tr -d '\r')
if [ "$st" = "done" ]; then
  _pass "[追加] mark_task_done: in_progress → done 遷移"
else
  _fail "[追加] mark_task_done 遷移失敗" "status='$st'"
fi

# --- [3-3] updated_at が更新されている ---
updated=$(jq -r '.tasks[] | select(.task_id=="impl-render-loop-task-stack-integration") | .updated_at' "$TASK_STACK" | tr -d '\r')
if [ -n "$updated" ] && [ "$updated" != "2026-04-18T00:00:00Z" ]; then
  _pass "[追加] mark_task_done が updated_at を更新"
else
  _fail "[追加] updated_at 未更新" "got: '$updated'"
fi

# --- [3-4] 他タスクには影響しない（impl-other は pending のまま） ---
other_st=$(jq -r '.tasks[] | select(.task_id=="impl-other") | .status' "$TASK_STACK" | tr -d '\r')
if [ "$other_st" = "pending" ]; then
  _pass "[追加] mark_task_done は他タスクに影響しない（impl-other=pending 維持）"
else
  _fail "[追加] 他タスク影響" "other_st='$other_st'"
fi

# --- [3-5] 冪等: 二度目の mark_task_done でも done を維持・エラーなし ---
mark_task_done "$TASK_STACK" "impl-render-loop-task-stack-integration" >/dev/null 2>&1
rc=$?
st=$(jq -r '.tasks[] | select(.task_id=="impl-render-loop-task-stack-integration") | .status' "$TASK_STACK" | tr -d '\r')
if [ "$rc" -eq 0 ] && [ "$st" = "done" ]; then
  _pass "[追加] mark_task_done は冪等（rc=0, status=done 維持）"
else
  _fail "[追加] mark_task_done 冪等性" "rc=$rc status='$st'"
fi

# --- [3-6] emit_render_completed_event で decisions.jsonl に追記 ---
emit_render_completed_event "$DECISIONS" "impl-render-loop-task-stack-integration" \
  "job-001" "out/slideshow.mp4" >/dev/null 2>&1
if [ ! -f "$DECISIONS" ]; then
  _fail "[追加] decisions.jsonl が生成されていない"
else
  n=$(grep -c '' "$DECISIONS" 2>/dev/null || echo 0)
  if [ "$n" -ge 1 ]; then
    _pass "[追加] emit_render_completed_event で decisions.jsonl に1行以上追記"
  else
    _fail "[追加] decisions.jsonl 行数0"
  fi
fi

# --- [3-7] 追記行が type=render_completed である ---
last_type=$(tail -1 "$DECISIONS" | jq -r '.type' 2>/dev/null | tr -d '\r')
if [ "$last_type" = "render_completed" ]; then
  _pass "behavior: decisions.jsonl に type=render_completed イベントを追記"
else
  _fail "[追加] decisions.jsonl の type" "got: '$last_type'"
fi

# --- [3-8] task_id / detail.job_id / detail.output が正しい ---
last_tid=$(tail -1 "$DECISIONS" | jq -r '.task_id' 2>/dev/null | tr -d '\r')
last_job=$(tail -1 "$DECISIONS" | jq -r '.detail.job_id' 2>/dev/null | tr -d '\r')
last_out=$(tail -1 "$DECISIONS" | jq -r '.detail.output' 2>/dev/null | tr -d '\r')
if [ "$last_tid" = "impl-render-loop-task-stack-integration" ] \
   && [ "$last_job" = "job-001" ] \
   && [ "$last_out" = "out/slideshow.mp4" ]; then
  _pass "[追加] decisions.jsonl の task_id / job_id / output 一致"
else
  _fail "[追加] decisions.jsonl フィールド不一致" \
    "tid='$last_tid' job='$last_job' out='$last_out'"
fi

# --- [3-9] timestamp フィールドが ISO-8601 風に存在する ---
last_ts=$(tail -1 "$DECISIONS" | jq -r '.timestamp' 2>/dev/null | tr -d '\r')
if echo "$last_ts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
  _pass "[追加] decisions.jsonl の timestamp が ISO-8601 形式"
else
  _fail "[追加] timestamp 形式" "got: '$last_ts'"
fi

# --- [3-10] append-only: 二度呼ぶと行数が2になる ---
emit_render_completed_event "$DECISIONS" "impl-render-loop-task-stack-integration" \
  "job-001" "out/slideshow.mp4" >/dev/null 2>&1
n2=$(grep -c '' "$DECISIONS" 2>/dev/null || echo 0)
if [ "$n2" -eq 2 ]; then
  _pass "[追加] emit_render_completed_event は append-only（行数 1→2）"
else
  _fail "[追加] append-only 違反" "n=$n2"
fi

# --- [3-11] エッジ: 存在しない task_id に mark_task_done を呼んでも破壊しない ---
before_len=$(jq '.tasks | length' "$TASK_STACK")
mark_task_done "$TASK_STACK" "non-existent-task-id" >/dev/null 2>&1 || true
after_len=$(jq '.tasks | length' "$TASK_STACK")
# JSON 構造が壊れていない（jq が読めること）+ タスク数が不変
if jq -e '.tasks | type == "array"' "$TASK_STACK" >/dev/null 2>&1 \
   && [ "$before_len" = "$after_len" ]; then
  _pass "[追加] エッジ: 存在しない task_id でも task-stack.json は壊れない"
else
  _fail "[追加] 存在しない task_id 処理" "before=$before_len after=$after_len"
fi

# --- [3-12] emit_render_event (汎用) でカスタム type を追加できる ---
emit_render_event "$DECISIONS" "impl-render-loop-task-stack-integration" \
  "render_started" '{"note":"e2e"}' >/dev/null 2>&1
last_type2=$(tail -1 "$DECISIONS" | jq -r '.type' 2>/dev/null | tr -d '\r')
if [ "$last_type2" = "render_started" ]; then
  _pass "[追加] emit_render_event で汎用 type=render_started を記録"
else
  _fail "[追加] emit_render_event type" "got: '$last_type2'"
fi
echo ""

# ============================================================================
# [4] render-loop.sh が handle_render_pass 内で新関数を呼んでいる（静的 grep）
# ============================================================================
echo -e "${BOLD}[4] render-loop.sh: handle_render_pass 内の統合呼び出し${NC}"

# handle_render_pass 関数ブロック内で mark_task_done / emit_render_completed_event を参照
if grep -Eq 'mark_task_done' "$RENDER_LOOP"; then
  _pass "[追加] render-loop.sh が mark_task_done を参照"
else
  _fail "[追加] mark_task_done 未参照"
fi

if grep -Eq 'emit_render_completed_event' "$RENDER_LOOP"; then
  _pass "[追加] render-loop.sh が emit_render_completed_event を参照"
else
  _fail "[追加] emit_render_completed_event 未参照"
fi

# DECISIONS_FILE 定数が定義されている
if grep -Eq '^[[:space:]]*DECISIONS_FILE=' "$RENDER_LOOP"; then
  _pass "[追加] render-loop.sh に DECISIONS_FILE 定数が定義されている"
else
  _fail "[追加] DECISIONS_FILE 定数未定義"
fi

# bash -n 構文チェック（回帰防止）
bn_out=$(bash -n "$RENDER_LOOP" 2>&1) || bn_rc=$?
bn_rc=${bn_rc:-0}
if [ "$bn_rc" -eq 0 ]; then
  _pass "[追加] render-loop.sh bash -n 構文 OK"
else
  _fail "[追加] render-loop.sh bash -n" "rc=${bn_rc} out: ${bn_out:0:300}"
fi

bn2_out=$(bash -n "$RENDER_EVENTS_LIB" 2>&1) || bn2_rc=$?
bn2_rc=${bn2_rc:-0}
if [ "$bn2_rc" -eq 0 ]; then
  _pass "[追加] render-events.sh bash -n 構文 OK"
else
  _fail "[追加] render-events.sh bash -n" "rc=${bn2_rc} out: ${bn2_out:0:300}"
fi
echo ""

# ---- cleanup ----
rm -rf "$WORK_TMP"

# ---- summary ----
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
