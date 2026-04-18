#!/bin/bash
# test-long-encode-nohup.sh — nohup-encoder.sh の Layer 1 / Layer 2 テスト
#
# 使い方: bash .forge/tests/test-long-encode-nohup.sh
#
# 必須テスト振る舞い（required_behaviors）:
#   1. validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に置換した
#      関数名 validate_render_output が定義されていること
#
# 追加検証（L2-006 E2E: nohup + progress file 分離）:
#   - start_long_encode が nohup + & + stdin切断 で detached 起動する（grep）
#   - start_long_encode が progress/pid file を書き出す
#   - 親シェル終了後も子プロセスが継続する（プロセス分離検証）
#   - read_encode_progress が status/percent を返す
#   - wait_for_encode が status=completed で正常終了する
#   - wait_for_encode が max_wait 経過で timeout 返す
#   - is_encode_running が alive/exited を判定する
#   - stop_encode が走行中プロセスを停止する
#   - validate_render_output のエラーコード（1/2/3/4/5）が契約通り
#
# 設計:
#   ffmpeg/ffprobe に依存せず決定的に動くよう、Mock ffprobe を /tmp に生成し
#   PATH 先頭に差し込む。テスト用「エンコード」は bash subshell で sleep + file write。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${PROJECT_ROOT}/.forge/lib/nohup-encoder.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_pass() { echo -e "  ${GREEN}OK${NC} $1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
_fail() {
  echo -e "  ${RED}FAIL${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1))
}

echo ""
echo -e "${BOLD}=== nohup-encoder.sh テスト ===${NC}"
echo ""

# ---- preflight ----
if [ ! -f "$LIB" ]; then
  echo -e "${RED}ERROR: library not found: $LIB${NC}"
  exit 2
fi
for tool in jq bash kill sleep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: required tool not found: $tool${NC}"
    exit 2
  fi
done

# ---- fixtures / mocks ----
WORK_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t nohup-enc)
MOCK_BIN="${WORK_TMP}/mock-bin"
mkdir -p "$MOCK_BIN"

# Mock ffprobe: 正しい mp4（サイズ>=1024）なら codec=h264 出力、それ以外は exit 1
cat > "${MOCK_BIN}/ffprobe" <<'MOCK'
#!/bin/bash
# ファイルパスは最後の非 - 引数（簡易パーサ）
file=""
for a in "$@"; do
  case "$a" in -*) ;; *) file="$a" ;; esac
done
if [ -z "$file" ] || [ ! -f "$file" ]; then exit 1; fi
case "$file" in
  *.txt|*.bad) exit 1 ;;
esac
sz=$(wc -c <"$file" 2>/dev/null | tr -d ' ')
if [ "${sz:-0}" -lt 512 ]; then exit 1; fi
echo "h264"
echo "1920"
echo "1080"
exit 0
MOCK
chmod +x "${MOCK_BIN}/ffprobe"

PATH="${MOCK_BIN}:${PATH}"
export PATH

# shellcheck disable=SC1090
source "$LIB"

# ============================================================================
# [1] behavior: validate_render_output 関数定義（required_behavior）
# ============================================================================
echo -e "${BOLD}[1] validate_render_output 関数定義${NC}"

# behavior: validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に置換した関数名 validate_render_output が定義されていること
if declare -F validate_render_output >/dev/null 2>&1; then
  _pass "behavior: validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に置換した関数名 validate_render_output が定義されていること"
else
  _fail "behavior: validate_render_output が定義されていない"
fi

# grep でも確認（source できない環境の回帰防止）
if grep -Eq '^[[:space:]]*validate_render_output[[:space:]]*\(\)' "$LIB"; then
  _pass "[追加] nohup-encoder.sh のソースに validate_render_output 関数定義が存在"
else
  _fail "[追加] ソース内の validate_render_output 関数定義未検出"
fi

# ffprobe / size_threshold / status 3 要素を参照
if grep -q 'ffprobe' "$LIB" \
   && grep -Eq 'size_threshold|actual_size' "$LIB" \
   && grep -Eq 'status.*completed|status.*succeeded|job_status' "$LIB"; then
  _pass "[追加] validate_render_output が ffprobe/size_threshold/status を参照"
else
  _fail "[追加] ffprobe/size/status 参照キーワード不足"
fi
echo ""

# ============================================================================
# [2] validate_render_output の契約 (戻り値 0/1/2/3/4/5)
# ============================================================================
echo -e "${BOLD}[2] validate_render_output 契約検証${NC}"

OK_VIDEO="${WORK_TMP}/ok.mp4"
SMALL_VIDEO="${WORK_TMP}/small.mp4"
BAD_FILE="${WORK_TMP}/notvideo.txt"
JOBS="${WORK_TMP}/render-jobs.jsonl"

head -c 200000 /dev/urandom > "$OK_VIDEO" 2>/dev/null || \
  dd if=/dev/urandom of="$OK_VIDEO" bs=1024 count=200 >/dev/null 2>&1
head -c 100 /dev/zero > "$SMALL_VIDEO" 2>/dev/null || \
  dd if=/dev/zero of="$SMALL_VIDEO" bs=1 count=100 >/dev/null 2>&1
echo "not a video" > "$BAD_FILE"
jq -cn '{job_id:"job-ok", status:"completed"}' > "$JOBS"
jq -cn '{job_id:"job-bad", status:"failed"}' >> "$JOBS"

# (A) 正常系 — rc=0
rc=0
validate_render_output "$OK_VIDEO" 1024 "job-ok" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then _pass "[追加] validate_render_output: 正常系 → rc=0"
else _fail "[追加] validate_render_output 正常系 rc=$rc 期待=0"; fi

# (B) サイズ不足 — rc=1
rc=0
validate_render_output "$SMALL_VIDEO" 1024 "" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ]; then
  # Mock ffprobe が 512bytes 未満で exit1 → rc=2 になるケースもある
  _pass "[追加] validate_render_output: サイズ/ffprobe 不良 → rc=$rc (1 or 2)"
else _fail "[追加] validate_render_output 不良ファイル rc=$rc 期待=1/2"; fi

# (C) ffprobe 失敗 — rc=2
rc=0
validate_render_output "$BAD_FILE" 1 "" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then _pass "[追加] validate_render_output: 非動画ファイル → rc=2"
else _fail "[追加] validate_render_output 非動画 rc=$rc 期待=2"; fi

# (D) ffprobe 不在 — rc=3（PATH を空にしたサブシェルで真に ffprobe を見つけられない状態）
rc=0
(
  export PATH=""
  # shellcheck disable=SC1090
  source "$LIB"
  validate_render_output "$OK_VIDEO" 1024 "" "$JOBS"
) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 3 ]; then _pass "[追加] validate_render_output: ffprobe 不在 → rc=3"
else _fail "[追加] validate_render_output ffprobe不在 rc=$rc 期待=3"; fi

# (E) RenderJob status != completed — rc=4
rc=0
validate_render_output "$OK_VIDEO" 1024 "job-bad" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then _pass "[追加] validate_render_output: job status=failed → rc=4"
else _fail "[追加] validate_render_output job不一致 rc=$rc 期待=4"; fi

# (F) ファイル不在 — rc=5
rc=0
validate_render_output "${WORK_TMP}/nonexistent.mp4" 1024 "" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 5 ]; then _pass "[追加] validate_render_output: ファイル不在 → rc=5"
else _fail "[追加] validate_render_output 不在 rc=$rc 期待=5"; fi

# (G) 空引数 — rc=5
rc=0
validate_render_output "" 1024 "" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 5 ]; then _pass "[追加] validate_render_output: 空引数 → rc=5"
else _fail "[追加] validate_render_output 空引数 rc=$rc 期待=5"; fi

# (H) [強化/M-003 boundary_change] size == threshold → rc=0 を検証
# behavior: [強化] M-003 対応 — `-lt` → `-le` mutation 検出
# size == threshold のとき原実装は PASS (rc=0) だが、-le に変わると rc=1 になる。
BOUNDARY_VIDEO="${WORK_TMP}/boundary.mp4"
head -c 1024 /dev/urandom > "$BOUNDARY_VIDEO" 2>/dev/null || \
  dd if=/dev/urandom of="$BOUNDARY_VIDEO" bs=1 count=1024 >/dev/null 2>&1
boundary_size=$(wc -c <"$BOUNDARY_VIDEO" 2>/dev/null | tr -d ' ')
if [ "${boundary_size:-0}" -ne 1024 ]; then
  # fallback: truncate or pad to exactly 1024
  head -c 1024 /dev/zero > "$BOUNDARY_VIDEO"
fi
rc=0
validate_render_output "$BOUNDARY_VIDEO" 1024 "" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[強化/M-003] 境界: size == threshold (1024 == 1024) → rc=0 (-lt→-le mutation 検出)"
else
  _fail "[強化/M-003] 境界 size==threshold rc=$rc 期待=0 (size=$(wc -c <"$BOUNDARY_VIDEO" | tr -d ' '))"
fi

# (I) [強化/M-003 boundary 下側] size == threshold - 1 → rc=1 を検証
# 境界のすぐ下は原実装/変異後ともに rc=1。原実装動作の固定アサーションとして追加。
UNDER_VIDEO="${WORK_TMP}/under.mp4"
head -c 1023 /dev/urandom > "$UNDER_VIDEO" 2>/dev/null || \
  dd if=/dev/urandom of="$UNDER_VIDEO" bs=1 count=1023 >/dev/null 2>&1
# ensure ffprobe mock passes (needs >=512)
rc=0
validate_render_output "$UNDER_VIDEO" 1024 "" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
  _pass "[強化/M-003] 境界: size == threshold-1 (1023 < 1024) → rc=1"
else
  _fail "[強化/M-003] 境界 size=threshold-1 rc=$rc 期待=1"
fi

# (J) [強化/M-004 return_value] ffprobe PASS かつ size 不足 → rc=1 必須
# behavior: [強化] M-004 対応 — size 不足分岐の `return 1` → `return 0` mutation 検出
# 既存 (B) は 100 bytes で ffprobe fail (rc=2) となり size 分岐を通らない。
# 800 bytes は ffprobe mock の >=512 を満たし、size_threshold=2000 に不足 → rc=1。
SIZE_FAIL_VIDEO="${WORK_TMP}/size_fail.mp4"
head -c 800 /dev/urandom > "$SIZE_FAIL_VIDEO" 2>/dev/null || \
  dd if=/dev/urandom of="$SIZE_FAIL_VIDEO" bs=1 count=800 >/dev/null 2>&1
rc=0
validate_render_output "$SIZE_FAIL_VIDEO" 2000 "" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
  _pass "[強化/M-004] ffprobe PASS / size 不足 → rc=1 必須 (return 1 → return 0 mutation 検出)"
else
  _fail "[強化/M-004] ffprobe通過+size不足 rc=$rc 期待=1 (rc=0 なら mutation 生存, rc=2 なら ffprobe で脱落)"
fi

# (K) [強化/M-004] size 不足時は必ず rc != 0 — 0 は絶対許容しない
rc=0
validate_render_output "$SIZE_FAIL_VIDEO" 2000 "" "$JOBS" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  _pass "[強化/M-004] size 不足時 rc != 0 を確約 (PASS 化 mutation を許さない)"
else
  _fail "[強化/M-004] size 不足で rc=0 になった — mutation が生存している"
fi
echo ""

# ============================================================================
# [3] nohup 分離設計の静的検証 (grep)
# ============================================================================
echo -e "${BOLD}[3] nohup + progress file 設計の静的検証${NC}"

# nohup + & + stdin 切断が揃っている
if grep -Eq 'nohup[[:space:]]' "$LIB"; then
  _pass "[追加] nohup 使用を検出"
else _fail "[追加] nohup 未使用"; fi

if grep -Eq '</dev/null' "$LIB"; then
  _pass "[追加] stdin 切断 (</dev/null) を検出 — SIGHUP 遮断設計"
else _fail "[追加] stdin 切断未検出"; fi

if grep -Eq '&[[:space:]]*$|& *#' "$LIB" || grep -Eq 'nohup.*&' "$LIB"; then
  _pass "[追加] 背景実行 (&) を検出"
else _fail "[追加] 背景実行未検出"; fi

if grep -Eq 'disown' "$LIB"; then
  _pass "[追加] disown による job table 切り離しを検出"
else _fail "[追加] disown 未使用（親 shell 終了時の job 送信リスク）"; fi

# [強化/M-008 call_remove] disown を確実に検出する構造チェック
# behavior: [強化] M-008 対応 — `disown` 呼出削除を検出
# nohup + & の直後に disown が配置されているか確認。同一関数内で nohup と disown が
# 共起し、nohup より後ろに disown がある構造を静的検証する。
nohup_line=$(grep -n -E '^[[:space:]]*nohup[[:space:]]' "$LIB" | head -1 | cut -d: -f1)
disown_line=$(grep -n -E '^[[:space:]]*disown[[:space:]]' "$LIB" | head -1 | cut -d: -f1)
if [ -n "$nohup_line" ] && [ -n "$disown_line" ] && [ "$disown_line" -gt "$nohup_line" ]; then
  _pass "[強化/M-008] nohup(行${nohup_line}) → disown(行${disown_line}) の順序で共起（call_remove mutation 検出）"
else
  _fail "[強化/M-008] nohup→disown の共起構造が崩れている (nohup=${nohup_line:-none} disown=${disown_line:-none})"
fi

# disown が PID 変数を引数に取っているか（bare `disown` だと直近の job しか対象にならない問題）
if grep -Eq 'disown[[:space:]]+"?\$pid"?|disown[[:space:]]+"?\$\{pid\}"?|disown[[:space:]]+%[0-9]+' "$LIB"; then
  _pass "[強化/M-008] disown が PID/jobspec 引数付きで呼ばれている"
else
  _fail "[強化/M-008] disown の引数が不明確（PID を明示して渡すべき）"
fi

# progress file 更新 API の定義
for fn in start_long_encode read_encode_progress wait_for_encode is_encode_running; do
  if declare -F "$fn" >/dev/null 2>&1; then
    _pass "[追加] 関数 $fn が定義されている"
  else _fail "[追加] 関数 $fn 未定義"; fi
done
echo ""

# ============================================================================
# [4] start_long_encode / wait_for_encode E2E（短時間シミュレーション）
# ============================================================================
echo -e "${BOLD}[4] start_long_encode + wait_for_encode E2E${NC}"

OUTPUT="${WORK_TMP}/encoded.mp4"
PROGRESS="${WORK_TMP}/encoded.progress"
LOG="${WORK_TMP}/encoded.log"
PIDFILE="${WORK_TMP}/encoded.pid"

# Mock encoder: 2秒後に progress=completed と output file を書く
cat > "${MOCK_BIN}/mock-encoder" <<'ENC'
#!/bin/bash
out="$1"; progress="$2"; size="${3:-200000}"
for i in 25 50 75; do
  sleep 0.3
  printf 'status=running\npercent=%d\n' "$i" > "$progress"
done
# 出力ファイル作成
head -c "$size" /dev/urandom > "$out" 2>/dev/null || dd if=/dev/urandom of="$out" bs=1024 count=200 >/dev/null 2>&1
printf 'status=completed\npercent=100\nended_at=%s\n' "$(date -Iseconds)" > "$progress"
exit 0
ENC
chmod +x "${MOCK_BIN}/mock-encoder"

rc=0
start_long_encode "$OUTPUT" "$PROGRESS" "$LOG" "$PIDFILE" \
  "${MOCK_BIN}/mock-encoder" "$OUTPUT" "$PROGRESS" 200000 || rc=$?
if [ "$rc" -eq 0 ]; then _pass "[追加] start_long_encode rc=0"
else _fail "[追加] start_long_encode rc=$rc"; fi

if [ -f "$PIDFILE" ] && [ -s "$PIDFILE" ]; then
  _pass "[追加] pid file が書き出された: $(cat "$PIDFILE")"
else _fail "[追加] pid file が空/不在"; fi

if [ -f "$PROGRESS" ] && grep -q "status=started" "$PROGRESS"; then
  _pass "[追加] progress file に初期 status=started が書き込まれた"
else _fail "[追加] progress file 初期状態未記録"; fi

# ポーリング完了
rc=0
wait_for_encode "$PROGRESS" "$OUTPUT" 15 1 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then _pass "[追加] wait_for_encode 完了検出 (rc=0)"
else _fail "[追加] wait_for_encode rc=$rc 期待=0"; fi

# 成果物確認
if [ -f "$OUTPUT" ] && [ "$(wc -c <"$OUTPUT" | tr -d ' ')" -ge 100000 ]; then
  _pass "[追加] output file が期待サイズ以上 ($(wc -c <"$OUTPUT" | tr -d ' ') bytes)"
else _fail "[追加] output file サイズ不足/不在"; fi

# progress file に completed
if grep -q "status=completed" "$PROGRESS"; then
  _pass "[追加] progress file に status=completed 記録"
else _fail "[追加] progress completed 未記録"; fi

# read_encode_progress 出力
out=$(read_encode_progress "$PROGRESS")
if echo "$out" | grep -q "status=completed"; then
  _pass "[追加] read_encode_progress が status=completed を返す"
else _fail "[追加] read_encode_progress 出力: $out"; fi
echo ""

# ============================================================================
# [5] is_encode_running / stop_encode / タイムアウト
# ============================================================================
echo -e "${BOLD}[5] is_encode_running / stop_encode / timeout${NC}"

# 既に終了した PID → is_encode_running = 1
rc=0
is_encode_running "$PIDFILE" || rc=$?
if [ "$rc" -eq 1 ]; then _pass "[追加] is_encode_running: 終了済み PID → rc=1"
else _fail "[追加] is_encode_running 終了後 rc=$rc"; fi

# 長時間走る mock を起動 → stop_encode で止める
LONG_OUT="${WORK_TMP}/long.mp4"
LONG_PROG="${WORK_TMP}/long.progress"
LONG_LOG="${WORK_TMP}/long.log"
LONG_PID="${WORK_TMP}/long.pid"

cat > "${MOCK_BIN}/mock-longrunner" <<'LONG'
#!/bin/bash
progress="$1"
for i in $(seq 1 60); do
  printf 'status=running\npercent=%d\n' "$i" > "$progress"
  sleep 1
done
LONG
chmod +x "${MOCK_BIN}/mock-longrunner"

start_long_encode "$LONG_OUT" "$LONG_PROG" "$LONG_LOG" "$LONG_PID" \
  "${MOCK_BIN}/mock-longrunner" "$LONG_PROG" >/dev/null 2>&1
sleep 1

# 生存確認
rc=0
is_encode_running "$LONG_PID" || rc=$?
if [ "$rc" -eq 0 ]; then _pass "[追加] is_encode_running: 走行中 PID → rc=0（プロセス分離成功）"
else _fail "[追加] is_encode_running 走行中 rc=$rc"; fi

# wait_for_encode タイムアウト
rc=0
wait_for_encode "$LONG_PROG" "$LONG_OUT" 3 1 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then _pass "[追加] wait_for_encode: timeout → rc=4"
else _fail "[追加] wait_for_encode timeout rc=$rc 期待=4"; fi

# stop_encode
rc=0
stop_encode "$LONG_PID" || rc=$?
sleep 1
rc2=0
is_encode_running "$LONG_PID" || rc2=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 1 ]; then
  _pass "[追加] stop_encode でプロセス停止 (rc=0, 以降 is_encode_running=1)"
else _fail "[追加] stop_encode rc=$rc running_after=$rc2"; fi

# 存在しない progress file
rc=0
read_encode_progress "${WORK_TMP}/nonexistent.progress" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 5 ]; then _pass "[追加] read_encode_progress: 不在ファイル → rc=5"
else _fail "[追加] read_encode_progress 不在 rc=$rc 期待=5"; fi

# 空引数
rc=0
start_long_encode "" "" "" "" "" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then _pass "[追加] start_long_encode: 空引数 → rc=2"
else _fail "[追加] start_long_encode 空引数 rc=$rc 期待=2"; fi

# [強化/M-013 exception_remove] 存在しない PID への stop_encode は rc=1 必須
# behavior: [強化] M-013 対応 — `kill -TERM ... || return 1` の `|| return 1` 削除 mutation 検出
# 死んだ/存在しない PID に対する stop_encode がエラーを伝播するか検証。
# mutation 後は kill -TERM 失敗を無視し常に rc=0 を返す。
# 1) 一度実行して終了したプロセスの PID — 確実に dead
bash -c 'exit 0' &
dead_pid_1=$!
wait "$dead_pid_1" 2>/dev/null || true
# reap 待機（OS が PID を解放するまでの猶予は取らない — dead ステータスで十分）
DEAD_PID_FILE_1="${WORK_TMP}/dead_reaped.pid"
echo "$dead_pid_1" > "$DEAD_PID_FILE_1"
# kill -0 で本当に dead か確認してからテスト
if kill -0 "$dead_pid_1" 2>/dev/null; then
  # 稀に PID が再利用された場合はスキップ（該当テストは信頼できない）
  _pass "[強化/M-013] skip: PID $dead_pid_1 が再利用された（テスト不可）"
else
  rc=0
  stop_encode "$DEAD_PID_FILE_1" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    _pass "[強化/M-013] stop_encode: dead PID ($dead_pid_1) → rc=1 必須 (|| return 1 削除 mutation 検出)"
  else
    _fail "[強化/M-013] stop_encode dead PID rc=$rc 期待=1 (rc=0 なら mutation 生存)"
  fi
fi

# 2) 決して存在しないような高位 PID で再検証
DEAD_PID_FILE_2="${WORK_TMP}/dead_high.pid"
# 4194303 は Linux default pid_max の一つ下。git-bash/MSYS 環境でも未使用。
echo "4194303" > "$DEAD_PID_FILE_2"
if kill -0 4194303 2>/dev/null; then
  _pass "[強化/M-013] skip: PID 4194303 が稀に存在（テスト不可）"
else
  rc=0
  stop_encode "$DEAD_PID_FILE_2" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    _pass "[強化/M-013] stop_encode: 高位未使用 PID (4194303) → rc=1 必須"
  else
    _fail "[強化/M-013] stop_encode 未使用 PID rc=$rc 期待=1"
  fi
fi

# 3) stop_encode は rc != 0 を確約（dead PID で 0 を返してはならない）
rc=0
stop_encode "$DEAD_PID_FILE_2" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  _pass "[強化/M-013] stop_encode: dead PID で rc != 0 を確約（成功化 mutation を不可視化しない）"
else
  _fail "[強化/M-013] stop_encode が dead PID に対し rc=0 を返した — || return 1 削除 mutation 生存"
fi
echo ""

# ============================================================================
# [6] 親プロセス終了後の継続性（nohup 分離の核心検証）
# ============================================================================
echo -e "${BOLD}[6] 親シェル終了後も子プロセスが継続する${NC}"

DETACH_OUT="${WORK_TMP}/detach.mp4"
DETACH_PROG="${WORK_TMP}/detach.progress"
DETACH_LOG="${WORK_TMP}/detach.log"
DETACH_PID="${WORK_TMP}/detach.pid"

# 親を bash -c で起動して即 exit。子は mock-encoder（2秒スリープ後に出力）。
bash -c "
  source '$LIB'
  start_long_encode '$DETACH_OUT' '$DETACH_PROG' '$DETACH_LOG' '$DETACH_PID' \
    '${MOCK_BIN}/mock-encoder' '$DETACH_OUT' '$DETACH_PROG' 180000 >/dev/null 2>&1
  exit 0
" &
parent_pid=$!
wait "$parent_pid" 2>/dev/null || true
# 親が exit した直後、子 PID が生存しているか
if [ -f "$DETACH_PID" ]; then
  child_pid=$(tr -d ' \r\n' < "$DETACH_PID")
  if kill -0 "$child_pid" 2>/dev/null; then
    _pass "[追加] 親シェル終了後も子プロセス (pid=$child_pid) が継続 — nohup 分離成功"
  else
    # 既に完了している可能性もあるので output 確認
    sleep 2
    if [ -f "$DETACH_OUT" ] && grep -q "status=completed" "$DETACH_PROG" 2>/dev/null; then
      _pass "[追加] 親終了後に子が完走（progress=completed, 出力ファイル生成）"
    else
      _fail "[追加] 子プロセスが親終了と共に消失した" "pid=$child_pid"
    fi
  fi
else
  _fail "[追加] detach pid file 未生成"
fi

# 最終的にエンコード完了まで待つ
wait_for_encode "$DETACH_PROG" "$DETACH_OUT" 10 1 >/dev/null 2>&1 || true
if [ -f "$DETACH_OUT" ] && [ "$(wc -c <"$DETACH_OUT" 2>/dev/null | tr -d ' ')" -ge 1000 ]; then
  _pass "[追加] 親プロセス終了後も最終的に出力ファイルが生成された"
else _fail "[追加] 親終了後、出力ファイル未生成"; fi
echo ""

# ---- cleanup ----
# 念のため残っているバックグラウンドを全て止める
for pf in "$PIDFILE" "$LONG_PID" "$DETACH_PID"; do
  [ -f "$pf" ] && stop_encode "$pf" >/dev/null 2>&1 || true
done
rm -rf "$WORK_TMP"

# ---- summary ----
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
