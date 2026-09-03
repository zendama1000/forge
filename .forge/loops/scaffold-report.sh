#!/bin/bash
# scaffold-report.sh — スキャフォールド削減の棚卸しレポート（読み取り専用・LLM 呼出なし）
#
# 原則:「ハーネスの全コンポーネントは『モデルが単独でできないこと』への仮説をエンコード
# している。モデルリリースごとに外して load-bearing か確かめよ」(Anthropic 2026-03)。
# 本スクリプトは state の実測データから「発火していない＝非荷重候補」を機械的に列挙する。
#
# 使い方: bash .forge/loops/scaffold-report.sh
# 運用: モデル更新（model id 変更）毎に実行し、候補は ablation.sh トグルで OFF 実験 →
#       品質不変を確認してから削除する（即削除しない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${PROJECT_ROOT}/.forge/state"

VALIDATION_STATS="${STATE_DIR}/validation-stats.jsonl"
METRICS="${STATE_DIR}/metrics.jsonl"
TASK_EVENTS="${STATE_DIR}/task-events.jsonl"
LESSONS="${STATE_DIR}/lessons-learned.jsonl"
COSTS="${STATE_DIR}/costs.jsonl"
ABLATION_CFG="${PROJECT_ROOT}/.forge/config/ablation.json"

BOLD='\033[1m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BOLD}=============================================================${NC}"
echo -e "${BOLD} Scaffold Report — 非荷重コンポーネント棚卸し ($(date +%Y-%m-%d))${NC}"
echo -e "${BOLD}=============================================================${NC}"

# ===== 1. JSON 修復段の発火分布（validation-stats.jsonl） =====
echo -e "\n${BOLD}[1] JSON 修復段の発火分布${NC}"
if [ -s "$VALIDATION_STATS" ]; then
  jq -rs 'group_by(.recovery_level) | map("  \(.[0].recovery_level // "unknown"): \(length)件") | .[]' \
    "$VALIDATION_STATS" 2>/dev/null || echo "  （パース不能）"
  total=$(wc -l < "$VALIDATION_STATS" | tr -d ' ')
  for level in fence extraction failed; do
    hits=$(grep -c "\"recovery_level\":\"${level}\"" "$VALIDATION_STATS" 2>/dev/null) || hits=0
    if [ "$hits" -eq 0 ]; then
      echo -e "  ${YELLOW}→ 削減候補: 修復段 '${level}' は全 ${total} 件中 0 発火（constrained decoding 導入後は非荷重の可能性）${NC}"
    fi
  done
else
  echo "  （データなし: ${VALIDATION_STATS}）"
fi

# ===== 2. ステージ別 呼出数/成功率/コスト（metrics.jsonl） =====
echo -e "\n${BOLD}[2] ステージ別 呼出数 / parse 成功率 / コスト${NC}"
if [ -s "$METRICS" ]; then
  jq -rs '
    group_by(.stage // "unknown")
    | map({stage: (.[0].stage // "unknown"),
           calls: length,
           ok: ([.[] | select(.parse_success == true or .parse_success == "true")] | length),
           cost: ([.[] | .cost_usd // 0] | add)})
    | sort_by(-.calls)
    | .[] | "  \(.stage): \(.calls)回, 成功\(.ok), $\(.cost * 100 | round / 100)"
  ' "$METRICS" 2>/dev/null | head -20 || echo "  （パース不能）"
else
  echo "  （データなし: ${METRICS}）"
fi
if [ -s "$COSTS" ]; then
  echo "  （costs.jsonl も存在: $(wc -l < "$COSTS" | tr -d ' ')件 — dashboard.sh 参照）"
fi

# ===== 3. コンポーネント × イベント発火の突合（task-events.jsonl vs ablation トグル） =====
echo -e "\n${BOLD}[3] ablation トグル対象コンポーネント × イベント発火${NC}"
echo "  コンポーネント            発火数   判定"
echo "  ----------------------- ------- ---------------------------"
# 計数の正 (batch#10 Stage1 修正):
#   1) task-events.jsonl は .event フィールドの ERE 一致で数える（行全体 grep は
#      "fix_source":"investigator" 等の誤ヒットで investigat が 2 倍計上されていた）
#   2) metrics.jsonl の .stage プレフィックスも併読する — mutation/evidence 系は
#      task-events に書かず metrics のみに記録するため、旧実装は 45 回稼働した
#      コンポーネントを「0 発火＝削減候補」と誤判定していた（2026-08-02 実測）
report_component() {
  local name="$1" event_re="$2" stage_re="${3:-}" note="${4:-}"
  local ev_count=0 st_count=0
  if [ -s "$TASK_EVENTS" ] && [ -n "$event_re" ]; then
    ev_count=$(jq -r '.event // ""' "$TASK_EVENTS" 2>/dev/null | grep -cE "^(${event_re})$") || ev_count=0
  fi
  if [ -s "$METRICS" ] && [ -n "$stage_re" ]; then
    st_count=$(jq -r '.stage // ""' "$METRICS" 2>/dev/null | grep -cE "^(${stage_re})") || st_count=0
  fi
  local count=$((ev_count + st_count))
  if [ -z "$event_re" ] && [ -z "$stage_re" ]; then
    printf '  %-24s %7s  %s\n' "$name" "-" "${note:-イベント記録なし — ablation 実験でのみ判定可}"
  elif [ "$count" -eq 0 ]; then
    printf '  %-24s %7d  削減候補（0 発火 — ablation OFF 実験を推奨）\n' "$name" "$count"
  else
    printf '  %-24s %7d  稼働中（events=%d metrics=%d）\n' "$name" "$count" "$ev_count" "$st_count"
  fi
}
if [ -s "$TASK_EVENTS" ] || [ -s "$METRICS" ]; then
  report_component "mutation_audit"      "mutation_.*"                    "mutation-auditor-|strengthen-"
  report_component "evidence_da"         "evidence_da.*"                  "evidence-da-"
  report_component "investigator"        "investigator_invoked"           "investigator-"
  report_component "qa_evaluator"        "qa_evaluator.*"                 "qa-evaluator-"
  report_component "sprint_contract"     "contract.*"                     "sprint-contract-"
  report_component "layer_3_tests"       "l3_test_completed"              "l3-judge-"
  report_component "l2_regression_tests" "l2_regression.*|l2fix.*"        ""
  report_component "best_of_n"           "best_of_n_completed"            "bon-judge-"
  report_component "dev_phase_gating"    "phase_completed|phase_advanced" ""
  report_component "priming"             "" "" "イベント記録なし — ablation 実験でのみ判定可"
  report_component "lessons_learned"     "" "" "$([ -s "$LESSONS" ] && echo "lessons $(wc -l < "$LESSONS" | tr -d ' ')件 蓄積" || echo "lessons 0件")"
else
  echo "  （データなし: ${TASK_EVENTS} / ${METRICS}）"
fi
if [ -f "$ABLATION_CFG" ]; then
  abl_enabled=$(jq -r '.enabled // false' "$ABLATION_CFG" 2>/dev/null)
  echo "  （ablation.json: enabled=${abl_enabled} — OFF 実験は enabled=true + 対象 component=false で実施）"
fi

# ===== 4. 運用注記 =====
echo -e "\n${BOLD}[4] 運用注記${NC}"
echo "  - 削減候補は即削除しない: ablation.sh トグルで OFF 実験 → フル回帰 + 実タスクで品質不変を確認してから削除"
echo "  - 0 発火は「不要」ではなく「このデータ期間で非荷重」の意味。保険型ゲート（保護パターン等）は発火ゼロが正常"
echo "  - 実行タイミング: モデル更新（model id 変更）毎、および自己改修バッチの定例項目として"

exit 0
