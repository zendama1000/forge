#!/bin/bash
# test-cost-envelope.sh — run_claude エンベロープからのコスト/トークン抽出（batch#11 R07b）
#
# 対象: .forge/lib/common.sh の extract_cost_from_envelope() / metrics_record() / run_claude() の
#       FORGE_KEEP_ENVELOPE、extract_cost_from_debug_log() の negative（2.1.258 形式ログは 0）
# fixture: .forge/tests/fixtures/envelopes/success-haiku-2.1.259.json（実 CLI 2.1.259 の封筒。本文のみ省略）
#
# 背景: 4.5f では 131/131 呼出のコストが 0 だった（debug ログに usage が無い）。batch#10 で全呼出を
# 封筒化したが未出荷・未検証だったため、ここで封筒経路を回帰テストに固定する。
# 使い方: bash .forge/tests/test-cost-envelope.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/cost-env-$$")
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

export ERRORS_FILE="${TMP}/errors.jsonl"
export RESEARCH_DIR="test-cost-envelope"
export CLAUDE_TIMEOUT=10
export NOTIFY_DIR="${TMP}/notifications"
json_fail_count=0
touch "$ERRORS_FILE"
source "${PROJECT_ROOT}/.forge/lib/common.sh"
# 本番 costs.jsonl / metrics.jsonl を汚さない
COSTS_FILE="${TMP}/costs.jsonl"; METRICS_FILE="${TMP}/metrics.jsonl"
: > "$COSTS_FILE"; : > "$METRICS_FILE"
log() { :; }

FX="${SCRIPT_DIR}/fixtures/envelopes/success-haiku-2.1.259.json"

echo -e "${BOLD}===== test-cost-envelope.sh — エンベロープからのコスト抽出 =====${NC}"
echo ""

reset_last() {
  _LAST_INPUT_TOKENS=0; _LAST_OUTPUT_TOKENS=0; _LAST_COST_USD="0"
  _LAST_CACHE_READ_TOKENS=0; _LAST_CACHE_CREATE_TOKENS=0; _LAST_SESSION_ID=""
}

# ========================================================================
echo -e "${BOLD}--- Group 1: 実封筒（success）からの抽出 ---${NC}"
# ========================================================================
assert_eq "fixture が存在する" "true" "$([ -f "$FX" ] && echo true || echo false)"
reset_last; : > "$COSTS_FILE"
extract_cost_from_envelope "$FX" "implementer-t1" "haiku"
assert_eq "_LAST_INPUT_TOKENS = usage.input_tokens (50)" "50" "$_LAST_INPUT_TOKENS"
assert_eq "_LAST_OUTPUT_TOKENS = usage.output_tokens (2491)" "2491" "$_LAST_OUTPUT_TOKENS"
assert_eq "_LAST_COST_USD = total_cost_usd（CLI の計算値をそのまま）" "0.051309799999999996" "$_LAST_COST_USD"
assert_eq "_LAST_CACHE_READ_TOKENS = cache_read_input_tokens (157328)" "157328" "$_LAST_CACHE_READ_TOKENS"
assert_eq "_LAST_CACHE_CREATE_TOKENS = cache_creation_input_tokens (11536)" "11536" "$_LAST_CACHE_CREATE_TOKENS"
assert_eq "_LAST_SESSION_ID = session_id" "68db7e3b-c9e9-478b-b853-e1c3018b6841" "$_LAST_SESSION_ID"
line=$(tail -1 "$COSTS_FILE")
assert_eq "costs.jsonl に 1 行" "1" "$(grep -c . "$COSTS_FILE")"
assert_eq "costs.jsonl が有効 JSON" "true" "$(printf '%s' "$line" | jq -e . >/dev/null 2>&1 && echo true || echo false)"
assert_eq "source=envelope" "envelope" "$(printf '%s' "$line" | jq -r '.source')"
assert_eq "cli_session_id が記録される" "68db7e3b-c9e9-478b-b853-e1c3018b6841" "$(printf '%s' "$line" | jq -r '.cli_session_id')"
assert_eq "cache_read_tokens / cache_create_tokens が数値で記録される" "157328|11536" "$(printf '%s' "$line" | jq -r '"\(.cache_read_tokens)|\(.cache_create_tokens)"')"
assert_eq "num_turns / duration_ms / subtype が記録される" "6|success" "$(printf '%s' "$line" | jq -r '"\(.num_turns)|\(.subtype)"')"
assert_eq "duration_ms は正の数値" "true" "$(printf '%s' "$line" | jq -e '.duration_ms > 0' >/dev/null 2>&1 && echo true || echo false)"
assert_eq "cost_usd は数値型" "number" "$(printf '%s' "$line" | jq -r '.cost_usd | type')"
assert_eq "stage / model が記録される" "implementer-t1|haiku" "$(printf '%s' "$line" | jq -r '"\(.stage)|\(.model)"')"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: total_cost_usd=0 のフォールバック階段 ---${NC}"
# ========================================================================
FX_NOTOTAL="${TMP}/no-total.json"
jq '.total_cost_usd = 0' "$FX" > "$FX_NOTOTAL"
reset_last; : > "$COSTS_FILE"
extract_cost_from_envelope "$FX_NOTOTAL" "s" "haiku"
assert_eq "total_cost_usd=0 → modelUsage[].costUSD の合算を採用" "0.051309799999999996" "$_LAST_COST_USD"

FX_MULTI="${TMP}/multi-model.json"
jq '.total_cost_usd = 0 | .modelUsage = {"a": {"costUSD": 0.01}, "b": {"costUSD": 0.02}}' "$FX" > "$FX_MULTI"
reset_last
extract_cost_from_envelope "$FX_MULTI" "s" "haiku"
assert_eq "複数モデルの costUSD は合算される（0.01 + 0.02）" "true" "$(awk "BEGIN{exit !($_LAST_COST_USD > 0.029 && $_LAST_COST_USD < 0.031)}" && echo true || echo false)"

FX_NOCOST="${TMP}/no-cost.json"
jq '.total_cost_usd = 0 | .modelUsage[].costUSD = 0' "$FX" > "$FX_NOCOST"
reset_last; : > "$COSTS_FILE"
extract_cost_from_envelope "$FX_NOCOST" "s" "haiku"
# haiku 単価 1.0 / 5.0 per 1M: (50*1.0 + 2491*5.0)/1e6 = 0.012505 → %.4f
assert_eq "両方 0 → 単価表で概算（haiku: 0.0125）" "0.0125" "$_LAST_COST_USD"
assert_eq "概算でも costs.jsonl に記録される" "1" "$(grep -c . "$COSTS_FILE")"

FX_EMPTY="${TMP}/empty-usage.json"
jq '.total_cost_usd = 0 | .modelUsage = {} | .usage.input_tokens = 0 | .usage.output_tokens = 0' "$FX" > "$FX_EMPTY"
reset_last; : > "$COSTS_FILE"
rc=0; extract_cost_from_envelope "$FX_EMPTY" "s" "haiku" || rc=$?
assert_eq "トークンもコストも 0 → return 0（不成立）" "0" "$rc"
assert_eq "不成立時は costs.jsonl に書かない" "0" "$(grep -c . "$COSTS_FILE")"
assert_eq "不成立時は _LAST_* を更新しない" "0|0|0|" "${_LAST_INPUT_TOKENS}|${_LAST_OUTPUT_TOKENS}|${_LAST_COST_USD}|${_LAST_SESSION_ID}"

FX_BUDGET="${TMP}/budget.json"
jq '.subtype = "error_max_budget_usd" | .is_error = true' "$FX" > "$FX_BUDGET"
reset_last; : > "$COSTS_FILE"
extract_cost_from_envelope "$FX_BUDGET" "s" "haiku"
assert_eq "subtype=error_max_budget_usd でもコストは記録される（失敗呼出の消費）" "1" "$(grep -c . "$COSTS_FILE")"
assert_eq "subtype が台帳に残る" "error_max_budget_usd" "$(tail -1 "$COSTS_FILE" | jq -r '.subtype')"

reset_last; : > "$COSTS_FILE"
rc=0; extract_cost_from_envelope "${TMP}/nonexistent.json" "s" "haiku" || rc=$?
assert_eq "不在ファイル → return 0、書込なし" "0|0" "${rc}|$(grep -c . "$COSTS_FILE")"
printf 'not json' > "${TMP}/broken.json"
rc=0; extract_cost_from_envelope "${TMP}/broken.json" "s" "haiku" || rc=$?
assert_eq "不正 JSON → return 0、書込なし" "0|0" "${rc}|$(grep -c . "$COSTS_FILE")"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: metrics_record への伝播とリセット ---${NC}"
# ========================================================================
reset_last; : > "$COSTS_FILE"; : > "$METRICS_FILE"
extract_cost_from_envelope "$FX" "implementer-t2" "haiku"
metrics_start
metrics_record "implementer-t2" "true"
m=$(tail -1 "$METRICS_FILE")
assert_eq "metrics.jsonl に cost_usd が伝播" "true" "$(printf '%s' "$m" | jq -e '.cost_usd > 0.05' >/dev/null 2>&1 && echo true || echo false)"
assert_eq "metrics.jsonl に cache_read_tokens / cache_create_tokens" "157328|11536" "$(printf '%s' "$m" | jq -r '"\(.cache_read_tokens)|\(.cache_create_tokens)"')"
assert_eq "metrics.jsonl に cli_session_id" "68db7e3b-c9e9-478b-b853-e1c3018b6841" "$(printf '%s' "$m" | jq -r '.cli_session_id')"
assert_eq "metrics_record 後にキャッシュ / session_id もリセット" "0|0|" "${_LAST_CACHE_READ_TOKENS}|${_LAST_CACHE_CREATE_TOKENS}|${_LAST_SESSION_ID}"
metrics_start; metrics_record "next" "true"
assert_eq "次の metrics_record は cli_session_id 空" "" "$(tail -1 "$METRICS_FILE" | jq -r '.cli_session_id')"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 4: run_claude 経由（sim_claude_exec スタブ）と FORGE_KEEP_ENVELOPE ---${NC}"
# ========================================================================
AGENT="${TMP}/agent.md"; echo "agent" > "$AGENT"
sim_claude_exec() { cp "$FX" "$1"; return 0; }
reset_last; : > "$COSTS_FILE"
OUT1="${TMP}/rc1.txt"
run_claude "haiku" "$AGENT" "p" "$OUT1" "${TMP}/rc1.log" "" 30 "" >/dev/null 2>&1 || true
assert_eq "run_claude 成功: costs.jsonl に source=envelope の 1 行" "1" "$(grep -c '"source":"envelope"' "$COSTS_FILE")"
assert_eq "run_claude 成功: _LAST_COST_USD が封筒の値" "0.051309799999999996" "$_LAST_COST_USD"
assert_eq "run_claude 成功: .pending に result が展開される" "true" "$([ -s "${OUT1}.pending" ] && echo true || echo false)"
assert_eq "既定では .raw-envelope は削除される" "false" "$([ -f "${OUT1}.raw-envelope" ] && echo true || echo false)"
OUT2="${TMP}/rc2.txt"
FORGE_KEEP_ENVELOPE=1 run_claude "haiku" "$AGENT" "p" "$OUT2" "${TMP}/rc2.log" "" 30 "" >/dev/null 2>&1 || true
assert_eq "FORGE_KEEP_ENVELOPE=1 では .raw-envelope が残る" "true" "$([ -f "${OUT2}.raw-envelope" ] && echo true || echo false)"
assert_eq "残った封筒は元の JSON と同一（監査・フィクスチャ採取に使える）" "true" "$(cmp -s "$FX" "${OUT2}.raw-envelope" && echo true || echo false)"
# 失敗呼出（部分封筒）でもコストは記録される
sim_claude_exec() { cp "$FX_BUDGET" "$1"; return 1; }
reset_last; : > "$COSTS_FILE"
OUT3="${TMP}/rc3.txt"
run_claude "haiku" "$AGENT" "p" "$OUT3" "${TMP}/rc3.log" "" 30 "" >/dev/null 2>&1 || true
assert_eq "失敗呼出でも封筒からコストを記録（best-effort）" "1" "$(grep -c '"source":"envelope"' "$COSTS_FILE")"
assert_eq "失敗呼出の既定では .raw-envelope 削除" "false" "$([ -f "${OUT3}.raw-envelope" ] && echo true || echo false)"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 5: debug ログ経路の negative（2.1.258 形式は 0） ---${NC}"
# ========================================================================
LOG258="${TMP}/debug-258.log"
cat > "$LOG258" <<'EOF'
2026-08-02T10:00:00.000Z [DEBUG] Session started: abc
2026-08-02T10:00:01.000Z [DEBUG] Model: claude-haiku-4-5
2026-08-02T10:00:05.000Z [DEBUG] Tool call: Read
2026-08-02T10:00:09.000Z [DEBUG] Stream completed
EOF
reset_last; : > "$COSTS_FILE"
rc=0; extract_cost_from_debug_log "$LOG258" "s" "haiku" >/dev/null 2>&1 || rc=$?
assert_eq "usage の無い debug ログからは 0 トークン（封筒が無いと計器は死ぬ — 封筒優先の根拠）" "0|0" "${_LAST_INPUT_TOKENS}|${_LAST_OUTPUT_TOKENS}"
echo ""

print_test_summary
