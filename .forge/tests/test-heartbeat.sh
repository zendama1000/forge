#!/bin/bash
# test-heartbeat.sh — ハートビート + effort 連動 timeout 吸収テスト
# heartbeat の生成/更新に加え、effort 連動タイムアウト倍率（apply_effort_timeout）が
# 長時間応答を kill ループせず吸収し、heartbeat が継続することを検証する。
# 使い方: bash .forge/tests/test-heartbeat.sh
set -uo pipefail

source "$(dirname "$0")/test-helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# common.sh 読み込み（apply_effort_timeout / resolve_agent_effort を取り込む）
# common.sh が source 時に参照しうる前提変数を最小定義（set -u 対策、test-run-claude-effort.sh と同形）
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
RESEARCH_DIR="test"
json_fail_count=0
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/.forge/lib/common.sh"

echo -e "${BOLD}=== ハートビート + effort 連動 timeout テスト ===${NC}"

# ===== セットアップ =====
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# update_heartbeat に必要な変数
HEARTBEAT_FILE="${TMPDIR_BASE}/heartbeat.json"
task_count=5
investigation_count=2
START_SECONDS=$((SECONDS - 120))  # 2分前開始を模擬

# 関数定義を直接用意（ralph-loop.sh から抽出は依存が多いため）
update_heartbeat() {
  local current_task="${1:-}"
  local elapsed_sec=$((SECONDS - START_SECONDS))
  local elapsed_min=$((elapsed_sec / 60))
  jq -n \
    --arg loop "ralph" \
    --arg task "$current_task" \
    --argjson tc "$task_count" \
    --argjson ic "$investigation_count" \
    --arg elapsed "${elapsed_min}m" \
    --arg ts "$(date -Iseconds)" \
    '{loop: $loop, current_task: $task, task_count: $tc,
     investigation_count: $ic, elapsed: $elapsed, heartbeat_at: $ts}' \
    > "${HEARTBEAT_FILE}.tmp" 2>/dev/null && mv "${HEARTBEAT_FILE}.tmp" "$HEARTBEAT_FILE"
}

# ===== テスト 1: heartbeat.json 生成 =====
echo ""
echo "--- テスト: heartbeat.json 生成 ---"
update_heartbeat "task-mvp-01"
assert_eq "ファイル存在" "yes" "$([ -f "$HEARTBEAT_FILE" ] && echo yes || echo no)"

# ===== テスト 2: JSON 構造検証 =====
echo ""
echo "--- テスト: JSON 構造検証 ---"
loop=$(jq -r '.loop' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
task=$(jq -r '.current_task' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
tc=$(jq -r '.task_count' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
ic=$(jq -r '.investigation_count' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
assert_eq "loop" "ralph" "$loop"
assert_eq "current_task" "task-mvp-01" "$task"
assert_eq "task_count" "5" "$tc"
assert_eq "investigation_count" "2" "$ic"

# ===== テスト 3: elapsed 計算 =====
echo ""
echo "--- テスト: elapsed 計算 ---"
elapsed=$(jq -r '.elapsed' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
assert_contains "elapsed に m を含む" "m" "$elapsed"

# ===== テスト 4: アトミック更新（.tmp → mv） =====
echo ""
echo "--- テスト: アトミック更新 ---"
update_heartbeat "task-mvp-02"
task2=$(jq -r '.current_task' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
assert_eq "更新後のタスク" "task-mvp-02" "$task2"
# .tmp が残っていないことを確認
assert_eq ".tmp 不在" "no" "$([ -f "${HEARTBEAT_FILE}.tmp" ] && echo yes || echo no)"

# ===== テスト 5: effort 連動タイムアウト倍率（正常系） =====
echo ""
echo "--- テスト: effort 連動タイムアウト倍率（正常系） ---"
# behavior: effort=high かつ base timeout_sec=200 → 連動倍率適用後の timeout が base 以上の整数値になる（正常系）
scaled=$(apply_effort_timeout 200 high)
assert_eq "effort=high base=200 → 300 (×1.5 の具体値)" "300" "$scaled"
if [[ "$scaled" =~ ^[0-9]+$ ]] && [ "$scaled" -ge 200 ]; then
  echo -e "  ${GREEN}✓${NC} 倍率適用後の timeout は base(200) 以上の整数 (${scaled})"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} 倍率適用後の timeout が base(200) 以上の整数でない (${scaled})"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# behavior: [強化] M-007 — xhigh 倍率 2.0→1.0 の変異を検出（200×2.0=400 の具体値検証）
assert_eq "effort=xhigh base=200 → 400 (×2.0 の具体値)" "400" "$(apply_effort_timeout 200 xhigh)"
# behavior: [強化] M-010 — max 倍率 3.0→1.0 の変異を検出（200×3.0=600 の具体値検証）
assert_eq "effort=max base=200 → 600 (×3.0 の具体値)" "600" "$(apply_effort_timeout 200 max)"
# behavior: [強化] 後方互換 — effort 未知値/空は倍率 1.0（base そのまま）
assert_eq "effort=medium base=200 → 200 (×1.0 後方互換)" "200" "$(apply_effort_timeout 200 medium)"
assert_eq "effort 空 base=200 → 200 (×1.0 後方互換)" "200" "$(apply_effort_timeout 200 '')"

# ===== テスト 6: timeout_sec=0（無制限）の維持（エッジケース） =====
echo ""
echo "--- テスト: timeout_sec=0（無制限）の維持 ---"
# behavior: timeout_sec=0（無制限）かつ高 effort → 0（無制限）を維持しハングリスクゼロ系を有限化しない（エッジケース）
assert_eq "base=0 effort=high → 0 維持（有限化しない）" "0" "$(apply_effort_timeout 0 high)"
assert_eq "base=0 effort=max → 0 維持（有限化しない）" "0" "$(apply_effort_timeout 0 max)"
# behavior: [強化] M-002 — 0保護ブランチが有限値を返す変異を検出（全高 effort で厳密に文字列 "0"）
assert_eq "base=0 effort=xhigh → 0 維持（有限化しない）" "0" "$(apply_effort_timeout 0 xhigh)"
# behavior: [強化] M-006 — 0チェックガード節（if+printf+return）削除の変異を構造検証で検出
# （ガード削除時は 0*mult=0 で出力が偶然一致しうるため、black-box では検出不能 → grep で実在を検証）
guard_if=$(grep -aF 'if [ "$base" -eq 0 ]' "${PROJECT_ROOT}/.forge/lib/common.sh" >/dev/null 2>&1 && echo yes || echo no)
assert_eq "0チェックガード節 if 文が common.sh に存在" "yes" "$guard_if"
guard_ret=$(grep -aA3 -F 'if [ "$base" -eq 0 ]' "${PROJECT_ROOT}/.forge/lib/common.sh" | grep -aF "printf '0'" >/dev/null 2>&1 && echo yes || echo no)
assert_eq "0チェックガード節内に printf '0' が存在" "yes" "$guard_ret"
# timeout 0 は GNU coreutils で無制限扱い → コマンドは kill されず完走する
rc=0; timeout 0 sleep 1 >/dev/null 2>&1 || rc=$?
assert_eq "timeout 0（無制限）で sleep 1 が完走 (exit 0)" "0" "$rc"

# ===== テスト 7: 長時間応答の吸収（kill されず継続） =====
echo ""
echo "--- テスト: effort 連動 timeout が長時間応答を kill せず吸収 ---"
# behavior: [追加] base=4s では kill される 5s 応答が、effort=high 倍率適用後 (6s) は kill されず完走する（kill ループ吸収）
update_heartbeat "long-task"
hb_before=$(jq -r '.heartbeat_at' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')

scaled_small=$(apply_effort_timeout 4 high)
assert_eq "base=4 effort=high → 6 (×1.5)" "6" "$scaled_small"

# 対照系: base のままでは長時間応答(5s)は kill される（exit 124）
rc_base=0; timeout 4 sleep 5 >/dev/null 2>&1 || rc_base=$?
assert_eq "対照系: base=4s のままでは 5s 応答が kill される (exit 124)" "124" "$rc_base"

# effort 連動適用後: 同じ 5s 応答が kill されず完走（exit 0）
rc_scaled=0; timeout "$scaled_small" sleep 5 >/dev/null 2>&1 || rc_scaled=$?
assert_eq "effort 連動 6s では 5s 応答を kill せず吸収 (exit 0)" "0" "$rc_scaled"

# ===== テスト 8: 長時間応答の吸収後も heartbeat が継続更新される =====
echo ""
echo "--- テスト: heartbeat 継続（kill ループなし） ---"
# behavior: [追加] 長時間応答の吸収後も update_heartbeat が継続し heartbeat_at が前進・current_task が更新される
update_heartbeat "long-task-after"
hb_after=$(jq -r '.heartbeat_at' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
task_after=$(jq -r '.current_task' "$HEARTBEAT_FILE" 2>/dev/null | tr -d '\r')
assert_eq "長時間応答後も current_task が更新される" "long-task-after" "$task_after"
if [ -n "$hb_before" ] && [ -n "$hb_after" ] && [ "$hb_before" != "$hb_after" ]; then
  echo -e "  ${GREEN}✓${NC} heartbeat_at が前進 (${hb_before} → ${hb_after})"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} heartbeat_at が前進していない (before=${hb_before}, after=${hb_after})"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ===== サマリー =====
print_test_summary
