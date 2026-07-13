#!/bin/bash
# test-model-hot-reload.sh — モデル設定 hot-reload（batch#8 Fix7）
# 対象: ralph-loop.sh の reload_model_config（タスク境界でのモデル系フィールド再読込）
# 使い方: bash .forge/tests/test-model-hot-reload.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log() { echo "$@"; }
jq_safe() { jq "$@" | tr -d '\r'; }

eval "$(extract_all_functions_awk "${PROJECT_ROOT}/.forge/loops/ralph-loop.sh" reload_model_config)"

echo -e "${BOLD}===== test-model-hot-reload.sh — モデル hot-reload =====${NC}"
echo ""

DEV_CONFIG="${TMPDIR}/development.json"
write_config() {
  jq -n --arg impl "$1" --arg inv "$2" \
    '{implementer: {model: $impl}, investigator: {model: $inv},
      evidence_da: {model: "sonnet"}, qa_evaluator: {model: "opus"},
      sprint_contract: {model: "haiku"}, best_of_n: {judge_model: "sonnet"},
      hot_reload: {models: true}}' > "$DEV_CONFIG"
}

# 起動時ロード相当の初期状態
write_config "claude-fable-5" "claude-fable-5"
HOT_RELOAD_MODELS="true"
_HOT_RELOAD_LAST_MTIME=""
IMPLEMENTER_MODEL="claude-fable-5"
INVESTIGATOR_MODEL="claude-fable-5"
EVIDENCE_DA_MODEL="sonnet"
QA_EVALUATOR_MODEL="opus"
SPRINT_CONTRACT_MODEL="haiku"
BEST_OF_N_JUDGE_MODEL="sonnet"

# ===== T1: 初回呼出は mtime 記録のみ（reload しない） =====
echo -e "${BOLD}--- T1: 初回は基準 mtime 記録のみ ---${NC}"
reload_model_config >/dev/null
assert_eq "初回: モデル不変" "claude-fable-5" "$IMPLEMENTER_MODEL"
assert_eq "初回: mtime が記録される" "yes" "$([ -n "$_HOT_RELOAD_LAST_MTIME" ] && echo yes || echo no)"

# ===== T2: config 書換（fable→opus 往復の実運用ケース）→ 次のタスク境界で反映 =====
echo -e "${BOLD}--- T2: 書換が反映される ---${NC}"
write_config "opus" "opus"
_HOT_RELOAD_LAST_MTIME="force-stale"   # mtime 秒粒度の flake 回避（変更検知を確定させる）
# 注意: $(…) はサブシェルで変数更新が親に届かないため、ファイル経由で出力を取る
reload_model_config > "${TMPDIR}/reload-out.txt"
out=$(cat "${TMPDIR}/reload-out.txt")
assert_eq "implementer が opus に切替" "opus" "$IMPLEMENTER_MODEL"
assert_eq "investigator が opus に切替" "opus" "$INVESTIGATOR_MODEL"
assert_contains "切替ログが出る" "hot-reload: IMPLEMENTER_MODEL claude-fable-5 → opus" "$out"
assert_eq "変更のないモデルはログなし・不変 (qa=opus)" "opus" "$QA_EVALUATOR_MODEL"

# ===== T3: mtime 不変なら再読込しない =====
echo -e "${BOLD}--- T3: mtime 不変はスキップ ---${NC}"
jq '.implementer.model = "haiku"' "$DEV_CONFIG" > "${DEV_CONFIG}.new"
mv "${DEV_CONFIG}.new" "$DEV_CONFIG"
_HOT_RELOAD_LAST_MTIME=$(stat -c %Y "$DEV_CONFIG")   # 現 mtime と一致させる = 変更なし扱い
reload_model_config >/dev/null
assert_eq "mtime 一致なら内容が変わっていても再読込しない" "opus" "$IMPLEMENTER_MODEL"

# ===== T4: HOT_RELOAD_MODELS=false で凍結 =====
echo -e "${BOLD}--- T4: 無効化フラグ ---${NC}"
HOT_RELOAD_MODELS="false"
write_config "haiku" "haiku"
_HOT_RELOAD_LAST_MTIME="force-stale"
reload_model_config >/dev/null
assert_eq "false なら凍結" "opus" "$IMPLEMENTER_MODEL"
HOT_RELOAD_MODELS="true"

# ===== T5: 書換途中の不正 JSON → 旧値維持 =====
echo -e "${BOLD}--- T5: 不正 JSON は旧値維持 ---${NC}"
echo '{ broken json' > "$DEV_CONFIG"
_HOT_RELOAD_LAST_MTIME="force-stale"
reload_model_config > "${TMPDIR}/reload-out5.txt"
out=$(cat "${TMPDIR}/reload-out5.txt")
assert_eq "不正 JSON: モデル不変" "opus" "$IMPLEMENTER_MODEL"
assert_contains "不正 JSON: 警告ログ" "不正 JSON" "$out"

# ===== T6: フィールド削除は旧値維持（// empty ガード） =====
echo -e "${BOLD}--- T6: フィールド欠落は旧値維持 ---${NC}"
jq -n '{investigator: {model: "haiku"}, hot_reload: {models: true}}' > "$DEV_CONFIG"
_HOT_RELOAD_LAST_MTIME="force-stale"
reload_model_config >/dev/null
assert_eq "欠落フィールド (implementer): 旧値維持" "opus" "$IMPLEMENTER_MODEL"
assert_eq "存在フィールド (investigator): 反映" "haiku" "$INVESTIGATOR_MODEL"

print_test_summary
exit $?
