#!/bin/bash
# test-plan-gate.sh — Phase 1.5 計画ゲート（generate-tasks.sh）ユニットテスト
#
# 対象:
#   - validate_command_allowlist        : 環境前提コマンド allowlist 検証（gate a）
#   - validate_locked_decision_mapping  : locked_decision → locked_decision_refs マッピング（gate b）
#   - detect_heuristic_conflicts        : grep ヒューリスティック矛盾検出（gate c）
#   - run_plan_gate_with_retry          : hard-fail リトライ orchestration（gate a/b 用）
#   - run_heuristic_gate_with_retry     : critical-warning-continue orchestration（gate c 用）
#
# 設計: ゲート関数は generate-tasks.sh 内に定義されており（ライブラリ未分離）、
#       test-assertions.sh と同様に sed で関数定義のみを抽出して source する。
#       LLM 再生成は stub コールバックに差し替えて決定的に検証する。
#
# 使い方: bash .forge/tests/test-plan-gate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_SCRIPT="${SCRIPT_DIR}/../loops/generate-tasks.sh"

# ===== テスト環境セットアップ（test-assertions.sh に準拠） =====
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export ERRORS_FILE="${TMPDIR}/errors.jsonl"
export RESEARCH_DIR="test-plan-gate"
json_fail_count=0
mkdir -p "${TMPDIR}/.forge/config"
echo '{"assertions":{"enabled":true}}' > "${TMPDIR}/.forge/config/development.json"
export PROJECT_ROOT="$TMPDIR"

# common.sh（jq_safe / log / notify_human）→ test-helpers.sh（assert_* / print_test_summary）
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/test-helpers.sh"

# notify_human の出力をサンドボックスに隔離
NOTIFY_DIR="${TMPDIR}/notifications"
mkdir -p "$NOTIFY_DIR"

# ===== ゲート関数を抽出して source =====
# batch#10 Stage4: validate_impl_test_commands / validate_requires_satisfiable /
# validate_v2_checks は .forge/lib/validation-gates.sh へ移設（生成時と執筆後の共用）
VG_SCRIPT="${SCRIPT_DIR}/../lib/validation-gates.sh"
GATE_FUNCS_FILE="${TMPDIR}/gate-funcs.sh"
: > "$GATE_FUNCS_FILE"
GATE_FN_NAMES=(
  validate_command_allowlist
  validate_locked_decision_mapping
  detect_heuristic_conflicts
  validate_server_consistency
  validate_walking_skeleton
  run_plan_gate_with_retry
  run_heuristic_gate_with_retry
)
VG_FN_NAMES=(
  validate_impl_test_commands
  validate_requires_satisfiable
  validate_v2_checks
)
for fn in "${GATE_FN_NAMES[@]}"; do
  sed -n "/^${fn}() {/,/^}/p" "$GEN_SCRIPT" >> "$GATE_FUNCS_FILE"
  echo "" >> "$GATE_FUNCS_FILE"
done
for fn in "${VG_FN_NAMES[@]}"; do
  sed -n "/^${fn}() {/,/^}/p" "$VG_SCRIPT" >> "$GATE_FUNCS_FILE"
  echo "" >> "$GATE_FUNCS_FILE"
done
GATE_FN_NAMES+=("${VG_FN_NAMES[@]}")

extraction_ok=1
for fn in "${GATE_FN_NAMES[@]}"; do
  grep -q "^${fn}() {" "$GATE_FUNCS_FILE" || extraction_ok=0
done
if [ "$extraction_ok" -ne 1 ]; then
  echo -e "  ${RED}✗${NC} ゲート関数の抽出に失敗（generate-tasks.sh に定義が見つからない）"
  echo ""
  echo -e "${RED}${BOLD}FAILED: 1/1${NC}"
  exit 1
fi
# shellcheck disable=SC1090
source "$GATE_FUNCS_FILE"

# ===== ローカル assert ヘルパー（PASS_COUNT/FAIL_COUNT を共有） =====
assert_rc() {
  local label="$1" expected="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expected" ]; then
    echo -e "  ${GREEN}✓${NC} ${label} (rc=${rc})"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected rc: ${expected}"
    echo -e "    actual rc:   ${rc}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== JSON fixture ヘルパー =====
mkjson() {
  local path="${TMPDIR}/fx-${RANDOM}-${RANDOM}.json"
  printf '%s\n' "$1" > "$path"
  echo "$path"
}

echo ""
echo -e "${BOLD}=== Phase 1.5 計画ゲート ユニットテスト ===${NC}"
echo ""

# ===== 共有 fixture =====
# research-config: node 禁止（denied_commands）+ LD-001/LD-002（マッピング検証用）
RC_LOCKED=$(mkjson '{
  "mode":"validate",
  "locked_decisions":[
    {"id":"LD-001","decision":"bash + jq のみ。Node.js は使用しない","reason":"node非依存","command_policy":{"denied_commands":["node"]}},
    {"id":"LD-002","decision":"テストは決定的","reason":"再現性"}
  ]
}')

# research-config: HTTP 禁止（ヒューリスティック検出用）
RC_HTTP=$(mkjson '{
  "mode":"validate",
  "locked_decisions":[
    {"id":"LD-001","decision":"HTTP API は使用禁止。Claude Code スキルのみで実装する","reason":"スキル化方針"},
    {"id":"LD-002","decision":"成果物は content/ 配下に出力","reason":"規約"}
  ]
}')

# research-config: 位置採番（明示 id なし → LD-1, LD-2）
RC_NOID=$(mkjson '{"locked_decisions":[{"decision":"方針A"},{"decision":"方針B"}]}')

# task-stack: 許可コマンドのみ + 全 locked マッピング済み
TASKS_CLEAN=$(mkjson '{"tasks":[
  {"task_id":"t1","validation":{"layer_1":{"command":"bash tests/test-merge.sh"}},"locked_decision_refs":["LD-001"]},
  {"task_id":"t2","validation":{"layer_1":{"command":"jq -e \".ok\" out.json"},"layer_2":{"command":"bash tests/integration-merge.sh"}},"locked_decision_refs":["LD-002"]}
]}')

# task-stack: node 使用（gate a 違反）。refs は両方カバー（gate a を単独検証）
TASKS_NODE=$(mkjson '{"tasks":[
  {"task_id":"t1","validation":{"layer_1":{"command":"node scripts/merge.js"}},"locked_decision_refs":["LD-001","LD-002"]}
]}')

# task-stack: LD-002 未マッピング（gate b 違反）。コマンドは許可内（gate b を単独検証）
TASKS_UNMAPPED=$(mkjson '{"tasks":[
  {"task_id":"t1","validation":{"layer_1":{"command":"bash tests/test-merge.sh"}},"locked_decision_refs":["LD-001"]}
]}')

# task-stack: curl 使用（gate c ヒューリスティック検出用）。node は無し
TASKS_CURL=$(mkjson '{"tasks":[
  {"task_id":"t1","validation":{"layer_1":{"command":"curl -s http://localhost:3000/health | jq -e \".ok\""}},"locked_decision_refs":["LD-001","LD-002"]}
]}')

# 位置採番マッピング用 task-stack
TASKS_NOID_OK=$(mkjson '{"tasks":[{"task_id":"t1","locked_decision_refs":["LD-1","LD-2"]}]}')
TASKS_NOID_MISS=$(mkjson '{"tasks":[{"task_id":"t1","locked_decision_refs":["LD-1"]}]}')

# ===== stub LLM 再生成コールバック（決定的） =====
STUB_REGEN_CALLS=0
stub_regen_node()     { STUB_REGEN_CALLS=$((STUB_REGEN_CALLS + 1)); cp "$TASKS_NODE" "$1"; return 0; }
stub_regen_unmapped() { STUB_REGEN_CALLS=$((STUB_REGEN_CALLS + 1)); cp "$TASKS_UNMAPPED" "$1"; return 0; }
stub_regen_curl()     { STUB_REGEN_CALLS=$((STUB_REGEN_CALLS + 1)); cp "$TASKS_CURL" "$1"; return 0; }
stub_regen_clean()    { STUB_REGEN_CALLS=$((STUB_REGEN_CALLS + 1)); cp "$TASKS_CLEAN" "$1"; return 0; }

# ============================================================================
# [A] gate(a): コマンド allowlist 検証
# ============================================================================
echo -e "${BOLD}[A] 環境前提コマンド allowlist 検証${NC}"

# behavior: allowlist 内コマンドのみの L1/L2 command を持つ task-stack 出力 → ゲート PASS で続行
assert_rc "allowlist 内コマンドのみ → PASS(0)" 0 validate_command_allowlist "$TASKS_CLEAN" "$RC_LOCKED"

# behavior: allowlist 外コマンド（例: node を禁止した locked 下で node 使用）を含む出力 → 補強リトライ要求、2回失敗後 hard fail（exit 非0、warning 続行しない）
assert_rc "node 禁止下で node 使用 → 違反(1)" 1 validate_command_allowlist "$TASKS_NODE" "$RC_LOCKED"
viol_out=$(validate_command_allowlist "$TASKS_NODE" "$RC_LOCKED" 2>/dev/null || true)
assert_contains "違反詳細に denied 'node' を含む" "denied 'node'" "$viol_out"
assert_contains "違反詳細に該当コマンドを含む" "node scripts/merge.js" "$viol_out"

# エッジ: research-config 不在 → スキップ(0)
assert_rc "research-config 不在 → スキップ(0)" 0 validate_command_allowlist "$TASKS_NODE" "/nonexistent.json"
# エッジ: research-config 引数空 → スキップ(0)
assert_rc "research-config 空文字 → スキップ(0)" 0 validate_command_allowlist "$TASKS_NODE" ""
# エッジ: denied_commands 未定義 → スキップ(0)
RC_NOPOLICY=$(mkjson '{"locked_decisions":[{"id":"LD-001","decision":"x","reason":"y"}]}')
assert_rc "denied_commands 未定義 → スキップ(0)" 0 validate_command_allowlist "$TASKS_NODE" "$RC_NOPOLICY"
# エッジ: node_modules は node 単語境界で誤検出しない
TASKS_NODEMOD=$(mkjson '{"tasks":[{"task_id":"t1","validation":{"layer_1":{"command":"ls node_modules/.bin"}},"locked_decision_refs":["LD-001","LD-002"]}]}')
assert_rc "node_modules は誤検出しない → PASS(0)" 0 validate_command_allowlist "$TASKS_NODEMOD" "$RC_LOCKED"

# behavior: allowlist 外コマンド（例: node を禁止した locked 下で node 使用）を含む出力 → 補強リトライ要求、2回失敗後 hard fail（exit 非0、warning 続行しない）
echo -e "${BOLD}  [A-retry] hard-fail リトライ orchestration${NC}"
TF=$(mkjson '{}'); cp "$TASKS_NODE" "$TF"
STUB_REGEN_CALLS=0; rc=0
run_plan_gate_with_retry validate_command_allowlist "$TF" "$RC_LOCKED" 2 stub_regen_node "command-allowlist" >/dev/null 2>&1 || rc=$?
assert_eq "2回リトライ後も違反 → hard fail(rc=1)" "1" "$rc"
assert_eq "補強リトライが2回呼ばれる" "2" "$STUB_REGEN_CALLS"

# behavior: allowlist 内コマンドのみの L1/L2 command を持つ task-stack 出力 → ゲート PASS で続行
echo -e "${BOLD}  [A-retry] リトライ成功 orchestration${NC}"
TF2=$(mkjson '{}'); cp "$TASKS_NODE" "$TF2"
STUB_REGEN_CALLS=0; rc=0
run_plan_gate_with_retry validate_command_allowlist "$TF2" "$RC_LOCKED" 2 stub_regen_clean "command-allowlist" >/dev/null 2>&1 || rc=$?
assert_eq "リトライ1回で解消 → PASS(rc=0)" "0" "$rc"
assert_eq "補強リトライは1回のみ" "1" "$STUB_REGEN_CALLS"
assert_rc "成功後 task_file は違反なし(0)" 0 validate_command_allowlist "$TF2" "$RC_LOCKED"

# ============================================================================
# [B] gate(b): locked_decision → locked_decision_refs マッピング
# ============================================================================
echo ""
echo -e "${BOLD}[B] locked_decision マッピング検証${NC}"

# behavior: 全 locked が最低1タスクにマッピングされた出力 → PASS
assert_rc "全 locked マッピング済み → PASS(0)" 0 validate_locked_decision_mapping "$TASKS_CLEAN" "$RC_LOCKED"

# behavior: locked_decisions の1件がどのタスクの locked_decision_refs にもマッピングされない出力 → 欠落 locked の詳細付き補強リトライ→2回失敗で hard fail
assert_rc "LD-002 未マッピング → 違反(1)" 1 validate_locked_decision_mapping "$TASKS_UNMAPPED" "$RC_LOCKED"
miss_out=$(validate_locked_decision_mapping "$TASKS_UNMAPPED" "$RC_LOCKED" 2>/dev/null || true)
assert_contains "欠落 ID LD-002 を出力" "LD-002" "$miss_out"
assert_contains "欠落 locked の詳細テキストを出力" "テストは決定的" "$miss_out"
assert_not_contains "マッピング済み LD-001 は欠落報告に含めない" "LD-001:" "$miss_out"

# エッジ: locked_decisions 未定義 → スキップ(0)
RC_NOLOCK=$(mkjson '{"open_questions":["x"]}')
assert_rc "locked_decisions 未定義 → スキップ(0)" 0 validate_locked_decision_mapping "$TASKS_UNMAPPED" "$RC_NOLOCK"
# エッジ: 位置採番（明示 id なし）→ LD-1/LD-2 でマッピング判定
assert_rc "位置採番 LD-1/LD-2 全カバー → PASS(0)" 0 validate_locked_decision_mapping "$TASKS_NOID_OK" "$RC_NOID"
assert_rc "位置採番 LD-2 欠落 → 違反(1)" 1 validate_locked_decision_mapping "$TASKS_NOID_MISS" "$RC_NOID"
noid_out=$(validate_locked_decision_mapping "$TASKS_NOID_MISS" "$RC_NOID" 2>/dev/null || true)
assert_contains "位置採番欠落 ID LD-2 を出力" "LD-2" "$noid_out"

# behavior: locked_decisions の1件がどのタスクの locked_decision_refs にもマッピングされない出力 → 欠落 locked の詳細付き補強リトライ→2回失敗で hard fail
echo -e "${BOLD}  [B-retry] hard-fail リトライ orchestration${NC}"
TF3=$(mkjson '{}'); cp "$TASKS_UNMAPPED" "$TF3"
STUB_REGEN_CALLS=0; rc=0
run_plan_gate_with_retry validate_locked_decision_mapping "$TF3" "$RC_LOCKED" 2 stub_regen_unmapped "locked-mapping" >/dev/null 2>&1 || rc=$?
assert_eq "2回リトライ後も未マッピング → hard fail(rc=1)" "1" "$rc"
assert_eq "補強リトライが2回呼ばれる(b)" "2" "$STUB_REGEN_CALLS"

# ============================================================================
# [C] gate(c): grep ヒューリスティック矛盾検出
# ============================================================================
echo ""
echo -e "${BOLD}[C] grep ヒューリスティック矛盾検出${NC}"

# behavior: grep ヒューリスティック矛盾検出（例: HTTP 禁止下の curl）のヒット → 1回リトライ後も残存なら critical warning を出力して続行（hard fail しない）
assert_rc "HTTP 禁止下で curl 使用 → 矛盾検出(1)" 1 detect_heuristic_conflicts "$TASKS_CURL" "$RC_HTTP"
conf_out=$(detect_heuristic_conflicts "$TASKS_CURL" "$RC_HTTP" 2>/dev/null || true)
assert_contains "矛盾詳細に HTTP クライアント使用を含む" "HTTP クライアント使用" "$conf_out"
assert_rc "HTTP 禁止下で curl 不使用(bash/jq) → 矛盾なし(0)" 0 detect_heuristic_conflicts "$TASKS_CLEAN" "$RC_HTTP"

# behavior: grep ヒューリスティック矛盾検出（例: HTTP 禁止下の curl）のヒット → 1回リトライ後も残存なら critical warning を出力して続行（hard fail しない）
# NOTE: STUB_REGEN_CALLS を親シェルで観測するため $() ではなくファイルへ stderr を退避する
#       （$() はサブシェル実行となりカウンタ更新が失われるため）。
echo -e "${BOLD}  [C-orch] 1回リトライ後 残存 → critical warning 続行（hard fail しない）${NC}"
rm -f "${NOTIFY_DIR}"/*.json 2>/dev/null || true
TF4=$(mkjson '{}'); cp "$TASKS_CURL" "$TF4"
ERR_C="${TMPDIR}/heur-continue.err"
STUB_REGEN_CALLS=0; rc=0
run_heuristic_gate_with_retry detect_heuristic_conflicts "$TF4" "$RC_HTTP" stub_regen_curl "heuristic-conflict" >/dev/null 2>"$ERR_C" || rc=$?
stderr_out=$(cat "$ERR_C")
assert_eq "残存しても hard fail しない（rc=0 で続行）" "0" "$rc"
assert_eq "ヒューリスティックは1回のみリトライ" "1" "$STUB_REGEN_CALLS"
assert_contains "CRITICAL WARNING を出力" "CRITICAL WARNING" "$stderr_out"
crit_count=$(grep -rl '"level":"critical"' "$NOTIFY_DIR" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "critical 通知が1件作成される" "1" "$crit_count"

# behavior: grep ヒューリスティック矛盾検出（例: HTTP 禁止下の curl）のヒット → 1回リトライ後も残存なら critical warning を出力して続行（hard fail しない）
echo -e "${BOLD}  [C-orch] リトライで矛盾解消 → warning なしで続行${NC}"
rm -f "${NOTIFY_DIR}"/*.json 2>/dev/null || true
TF5=$(mkjson '{}'); cp "$TASKS_CURL" "$TF5"
ERR_R="${TMPDIR}/heur-resolve.err"
STUB_REGEN_CALLS=0; rc=0
run_heuristic_gate_with_retry detect_heuristic_conflicts "$TF5" "$RC_HTTP" stub_regen_clean "heuristic-conflict" >/dev/null 2>"$ERR_R" || rc=$?
stderr_out2=$(cat "$ERR_R")
assert_eq "解消時も rc=0 で続行" "0" "$rc"
assert_eq "解消時リトライは1回" "1" "$STUB_REGEN_CALLS"
assert_contains "解消ログを出力" "リトライで矛盾解消" "$stderr_out2"
assert_not_contains "解消時は CRITICAL WARNING を出さない" "CRITICAL WARNING" "$stderr_out2"

# ============================================================================
# [D] ゲートロジックは jq/grep のみ・LLM 非依存・決定的
# ============================================================================
echo ""
echo -e "${BOLD}[D] jq/grep 機械判定のみ・LLM 非依存・決定的${NC}"

gate_body=$(cat "$GATE_FUNCS_FILE")
# behavior: ゲートロジックが jq/grep の機械判定のみで構成され LLM 呼出を含まない → ゲート実行が数秒で決定的に完了
assert_not_contains "ゲート定義に run_claude 呼出を含まない" "run_claude" "$gate_body"
assert_not_contains "ゲート定義に claude -p 呼出を含まない" "claude -p" "$gate_body"
assert_contains "ゲート定義は jq を使用" "jq" "$gate_body"
assert_contains "ゲート定義は grep を使用" "grep" "$gate_body"

# 決定的: 同一入力で2回実行 → 同一 exit code
rc_a=0; validate_command_allowlist "$TASKS_NODE" "$RC_LOCKED" >/dev/null 2>&1 || rc_a=$?
rc_b=0; validate_command_allowlist "$TASKS_NODE" "$RC_LOCKED" >/dev/null 2>&1 || rc_b=$?
assert_eq "決定的: 同一入力で同一 exit code" "$rc_a" "$rc_b"

# 数秒で完了: 3ゲート連続実行が短時間で終わる（LLM 非依存の確認・緩い上限）
t_start=$SECONDS
validate_command_allowlist "$TASKS_CLEAN" "$RC_LOCKED" >/dev/null 2>&1 || true
validate_locked_decision_mapping "$TASKS_CLEAN" "$RC_LOCKED" >/dev/null 2>&1 || true
detect_heuristic_conflicts "$TASKS_CURL" "$RC_HTTP" >/dev/null 2>&1 || true
t_elapsed=$((SECONDS - t_start))
if [ "$t_elapsed" -lt 30 ]; then
  echo -e "  ${GREEN}✓${NC} 3ゲート連続実行が ${t_elapsed}s で完了（< 30s・LLM 非依存）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} ゲート実行が遅すぎる（${t_elapsed}s）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================================
# [E] 配布 fixture の妥当性（L2/L3 が参照するファイル）
# ============================================================================
echo ""
echo -e "${BOLD}[E] 配布 fixture 妥当性${NC}"

CRIT_FX="${SCRIPT_DIR}/fixtures/criteria-valid.json"
RC_FX="${SCRIPT_DIR}/fixtures/research-config-locked.json"

if jq -e . "$CRIT_FX" >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} criteria-valid.json は妥当な JSON"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} criteria-valid.json が不正な JSON"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
crit_l1=$(jq -r '[.layer_1_criteria[].id] | join(",")' "$CRIT_FX" 2>/dev/null)
assert_contains "criteria-valid.json は L1-008 を含む" "L1-008" "$crit_l1"
crit_l2=$(jq -r '[.layer_2_criteria[].id] | join(",")' "$CRIT_FX" 2>/dev/null)
assert_contains "criteria-valid.json は L2-002 を含む" "L2-002" "$crit_l2"

if jq -e . "$RC_FX" >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} research-config-locked.json は妥当な JSON"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo -e "  ${RED}✗${NC} research-config-locked.json が不正な JSON"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
# 配布 fixture が gate(a) の denied_commands と locked_decisions を備えること
rc_denied=$(jq -r '[.locked_decisions[].command_policy.denied_commands // [] | .[]] | join(",")' "$RC_FX" 2>/dev/null)
assert_contains "research-config-locked.json は node を denied に含む" "node" "$rc_denied"
rc_ld=$(jq -r '[.locked_decisions[].id] | join(",")' "$RC_FX" 2>/dev/null)
assert_contains "research-config-locked.json は LD-001/LD-002 を持つ" "LD-002" "$rc_ld"

# 配布 fixture を実際にゲートへ通す（クリーンな合成 task-stack）
assert_rc "配布 RC で clean task-stack は gate(a) PASS(0)" 0 validate_command_allowlist "$TASKS_CLEAN" "$RC_FX"
assert_rc "配布 RC で clean task-stack は gate(b) PASS(0)" 0 validate_locked_decision_mapping "$TASKS_CLEAN" "$RC_FX"

# ===== 新ゲート: validate_impl_test_commands =====
echo ""
echo -e "${BOLD}--- validate_impl_test_commands（test -f ゲート恒久修正版） ---${NC}"

FX_TESTF=$(mkjson '{"tasks":[
  {"task_id":"impl-a","task_type":"implementation","validation":{"layer_1":{"command":"bash -c \"test -f src/a.ts && echo OK\""}}}
]}')
assert_rc "implementation + test -f 単体 → 違反(1)" 1 validate_impl_test_commands "$FX_TESTF" ""

FX_VITEST=$(mkjson '{"tasks":[
  {"task_id":"impl-b","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run tests/b.test.ts"}}}
]}')
assert_rc "implementation + vitest → PASS(0)" 0 validate_impl_test_commands "$FX_VITEST" ""

FX_ESLINT=$(mkjson '{"tasks":[
  {"task_id":"impl-c","task_type":"implementation","validation":{"layer_1":{"command":"bash -c \"npx eslint src/ && test -f src/c.ts\""}}}
]}')
assert_rc "implementation + eslint 併用 → PASS(0)（検証コマンド許容の拡張）" 0 validate_impl_test_commands "$FX_ESLINT" ""

FX_SETUP=$(mkjson '{"tasks":[
  {"task_id":"setup-a","task_type":"setup","validation":{"layer_1":{"command":"bash -c \"test -f package.json && echo OK\""}}}
]}')
assert_rc "setup + test -f → PASS(0)（task_type 別分岐）" 0 validate_impl_test_commands "$FX_SETUP" ""

FX_REPLACES_OK=$(mkjson '{"tasks":[
  {"task_id":"impl-d","task_type":"implementation","replaces":["old-module"],"validation":{"layer_1":{"command":"bash -c \"! grep -rn old-module src/ && grep -rln new-module src/ | head -1\""}}}
]}')
assert_rc "replaces + grep 配線検証あり → PASS(0)" 0 validate_impl_test_commands "$FX_REPLACES_OK" ""

FX_REPLACES_NG=$(mkjson '{"tasks":[
  {"task_id":"impl-e","task_type":"implementation","replaces":["old-module"],"validation":{"layer_1":{"command":"npx vitest run tests/e.test.ts"}}}
]}')
assert_rc "replaces + grep なし → 違反(1)（配線検証の機械化）" 1 validate_impl_test_commands "$FX_REPLACES_NG" ""

# ===== 新ゲート: validate_server_consistency =====
echo ""
echo -e "${BOLD}--- validate_server_consistency（server 整合 preflight） ---${NC}"

DEV_NONE=$(mkjson '{"server":{"start_command":"none","health_check_url":""}}')
DEV_SET=$(mkjson '{"server":{"start_command":"npm start","health_check_url":"http://localhost:3001"}}')

FX_HTTP=$(mkjson '{"tasks":[
  {"task_id":"impl-api","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run"},"layer_2":{"command":"curl -sf http://localhost:3001/api/health","requires":["server"]}}}
],"phases":[]}')
assert_rc "L2 curl + start_command=none → 違反(1)" 1 validate_server_consistency "$FX_HTTP" "$DEV_NONE"
assert_rc "L2 curl + server 設定済み → PASS(0)" 0 validate_server_consistency "$FX_HTTP" "$DEV_SET"

FX_NOHTTP=$(mkjson '{"tasks":[
  {"task_id":"impl-cli","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run"}}}
],"phases":[]}')
assert_rc "HTTP なし + none → PASS(0)" 0 validate_server_consistency "$FX_NOHTTP" "$DEV_NONE"

FX_EXIT_HTTP=$(mkjson '{"tasks":[],"phases":[
  {"id":"mvp","goal":"g","exit_criteria":[{"type":"auto","description":"d","command":"curl -sf http://localhost:3001/api"}]}
]}')
assert_rc "exit_criteria の curl + none → 違反(1)" 1 validate_server_consistency "$FX_EXIT_HTTP" "$DEV_NONE"

FX_DEFERRED_HTTP=$(mkjson '{"tasks":[
  {"task_id":"impl-def","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run"},"layer_2":{"command":"curl -sf http://localhost:3001/x","requires":["server"],"deferred":true,"deferred_reason":"env"}}}
],"phases":[]}')
assert_rc "deferred:true の L2 curl + none → PASS(0)（意図的繰延は対象外）" 0 validate_server_consistency "$FX_DEFERRED_HTTP" "$DEV_NONE"

# ===== 新ゲート: validate_walking_skeleton =====
echo ""
echo -e "${BOLD}--- validate_walking_skeleton ---${NC}"

FX_WS_ALL=$(mkjson '{"tasks":[],"phases":[
  {"id":"mvp","goal":"g","exit_criteria":[{"type":"auto","kind":"walking_skeleton","description":"d","command":"true"}]},
  {"id":"core","goal":"g","exit_criteria":[{"type":"auto","kind":"walking_skeleton","description":"d","command":"true"},{"type":"auto","kind":"standard","description":"d2","command":"true"}]}
]}')
assert_rc "全 phase に skeleton → PASS(0)" 0 validate_walking_skeleton "$FX_WS_ALL" ""

FX_WS_PARTIAL=$(mkjson '{"tasks":[],"phases":[
  {"id":"mvp","goal":"g","exit_criteria":[{"type":"auto","kind":"walking_skeleton","description":"d","command":"true"}]},
  {"id":"core","goal":"g","exit_criteria":[{"type":"auto","kind":"standard","description":"d","command":"true"}]}
]}')
assert_rc "一部 phase のみ skeleton → hard fail(1)" 1 validate_walking_skeleton "$FX_WS_PARTIAL" ""

FX_WS_LEGACY=$(mkjson '{"tasks":[],"phases":[
  {"id":"mvp","goal":"g","exit_criteria":[{"type":"auto","description":"d","command":"true"}]},
  {"id":"core","goal":"g","exit_criteria":[{"type":"human_check","description":"d","level":"A"}]}
]}')
assert_rc "kind 皆無（legacy criteria）→ warn のみ PASS(0)" 0 validate_walking_skeleton "$FX_WS_LEGACY" ""

FX_WS_NOPHASE=$(mkjson '{"tasks":[]}')
assert_rc "phases なし → PASS(0)" 0 validate_walking_skeleton "$FX_WS_NOPHASE" ""

# ===== 新ゲート: validate_requires_satisfiable =====
echo ""
echo -e "${BOLD}--- validate_requires_satisfiable ---${NC}"

CAPS_FX=$(mkjson '{"probed_at":"t","capabilities":{},"capability_tags":["cmd:node","server","network"]}')

FX_REQ_OK=$(mkjson '{"tasks":[
  {"task_id":"impl-x","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run"},"layer_2":{"command":"curl http://x","requires":["server","cmd:bash"]},"layer_3":[{"id":"L3-x","strategy":"api_e2e","description":"d","definition":{},"requires":["server"]}]}}
]}')
assert_rc "充足可能な requires のみ → PASS(0)" 0 validate_requires_satisfiable "$FX_REQ_OK" "$CAPS_FX"

FX_REQ_NG=$(mkjson '{"tasks":[
  {"task_id":"impl-y","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run"},"layer_3":[{"id":"L3-y","strategy":"cli_flow","description":"d","definition":{},"requires":["cmd:nonexistent-cmd-xyz"]}]}}
]}')
assert_rc "充足不能 cmd + deferred なし → 違反(1)" 1 validate_requires_satisfiable "$FX_REQ_NG" "$CAPS_FX"

FX_REQ_DEFER=$(mkjson '{"tasks":[
  {"task_id":"impl-z","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run"},"layer_3":[{"id":"L3-z","strategy":"cli_flow","description":"d","definition":{},"requires":["cmd:nonexistent-cmd-xyz"],"deferred":true,"deferred_reason":"env"}]}}
]}')
assert_rc "充足不能でも deferred:true → PASS(0)" 0 validate_requires_satisfiable "$FX_REQ_DEFER" "$CAPS_FX"

FX_REQ_BROWSER=$(mkjson '{"tasks":[
  {"task_id":"impl-w","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run"},"layer_3":[{"id":"L3-w","strategy":"browser","description":"d","definition":{},"instructions":"open"}]}}
]}')
assert_rc "browser strategy + browser 能力なし → 違反(1)（暗黙タグ）" 1 validate_requires_satisfiable "$FX_REQ_BROWSER" "$CAPS_FX"

FX_REQ_FILE=$(mkjson '{"tasks":[
  {"task_id":"impl-v","task_type":"implementation","validation":{"layer_1":{"command":"npx vitest run"},"layer_3":[{"id":"L3-v","strategy":"cli_flow","description":"d","definition":{},"requires":["file:will-be-created.txt"]}]}}
]}')
assert_rc "file: は計画時点で対象外 → PASS(0)" 0 validate_requires_satisfiable "$FX_REQ_FILE" "$CAPS_FX"

# ===== サマリー =====

# =====================================================================
# validate_v2_checks（batch#8 Stage3c）
# =====================================================================
echo ""
echo -e "${BOLD}--- validate_v2_checks: v2 構造ゲート ---${NC}"

V2OK="${TMPDIR}/v2-ok.json"
cat > "$V2OK" <<'EOF'
{"tasks": [
  {"task_id": "t-ok", "task_type": "implementation", "validation": {"checks": [
    {"id": "c1", "layer": 1, "verb": "run_test", "runner": "vitest", "args": ["run", "a.test.ts"]},
    {"id": "c2", "layer": 2, "verb": "http_check", "url_path": "/health", "requires": ["server"]}
  ]}}
]}
EOF
rc=0; validate_v2_checks "$V2OK" >/dev/null 2>&1 || rc=$?
assert_eq "正しい v2 checks は PASS" "0" "$rc"

v2_fail_case() {
  local label="$1" json="$2" needle="$3"
  local f="${TMPDIR}/v2-case-$$-${RANDOM}.json"
  printf '%s' "$json" > "$f"
  local rc=0 out
  out=$(validate_v2_checks "$f" 2>/dev/null) || rc=$?
  assert_eq "${label}: 違反検出 (rc=1)" "1" "$rc"
  assert_contains "${label}: 違反内容" "$needle" "$out"
}

v2_fail_case "未知 verb"   '{"tasks":[{"task_id":"t1","validation":{"checks":[{"layer":1,"verb":"teleport"}]}}]}'   "未知 verb"
v2_fail_case "grep_ref の pattern 欠落"   '{"tasks":[{"task_id":"t2","validation":{"checks":[{"layer":1,"verb":"grep_ref","paths":["src/"]}]}}]}'   "pattern がない"
v2_fail_case "run_test の runner 不正"   '{"tasks":[{"task_id":"t3","validation":{"checks":[{"layer":1,"verb":"run_test","runner":"mocha"}]}}]}'   "runner が不正"
v2_fail_case "http_check の url 欠落"   '{"tasks":[{"task_id":"t4","validation":{"checks":[{"layer":2,"verb":"http_check"}]}}]}'   "url/url_path がない"
v2_fail_case "raw_shell の reason 欠落"   '{"tasks":[{"task_id":"t5","validation":{"checks":[{"layer":1,"verb":"raw_shell","shell":"true"}]}}]}'   "reason がない"
v2_fail_case "絶対パス"   '{"tasks":[{"task_id":"t6","validation":{"checks":[{"layer":1,"verb":"file_exists","paths":["/etc/passwd"]}]}}]}'   "絶対パス"
v2_fail_case "未置換プレースホルダ"   '{"tasks":[{"task_id":"t7","validation":{"checks":[{"layer":1,"verb":"raw_shell","shell":"echo {{SERVER_URL}}","reason":"r"}]}}]}'   "プレースホルダ"
v2_fail_case "layer:1 の env 依存 requires"   '{"tasks":[{"task_id":"t8","validation":{"checks":[{"layer":1,"verb":"file_exists","paths":["a"],"requires":["server"]}]}}]}'   "env 依存 requires"
v2_fail_case "L1 検証カバレッジなし"   '{"tasks":[{"task_id":"t9","validation":{"checks":[{"layer":2,"verb":"http_check","url_path":"/x"}]}}]}'   "L1 検証なし"

# 併記は warn のみで PASS
V2DUAL="${TMPDIR}/v2-dual.json"
cat > "$V2DUAL" <<'EOF'
{"tasks": [{"task_id": "t-dual", "validation": {
  "layer_1": {"command": "npx vitest run"},
  "checks": [{"layer": 1, "verb": "run_test", "runner": "vitest"}]}}]}
EOF
rc=0; validate_v2_checks "$V2DUAL" >/dev/null 2>&1 || rc=$?
assert_eq "legacy/v2 併記は warn のみ (PASS)" "0" "$rc"

# validate_impl_test_commands の v2 対応
V2WEAK="${TMPDIR}/v2-weak.json"
cat > "$V2WEAK" <<'EOF'
{"tasks": [{"task_id": "t-weak", "task_type": "implementation", "validation": {
  "checks": [{"layer": 1, "verb": "file_exists", "paths": ["src/a.ts"]}]}}]}
EOF
rc=0; out=$(validate_impl_test_commands "$V2WEAK" 2>/dev/null) || rc=$?
assert_eq "impl の v2 file_exists 単体は違反" "1" "$rc"
assert_contains "違反文言 (実行系 verb なし)" "実行系 verb がない" "$out"

V2REPL="${TMPDIR}/v2-repl.json"
cat > "$V2REPL" <<'EOF'
{"tasks": [{"task_id": "t-repl", "task_type": "implementation", "replaces": ["old-module.ts"], "validation": {
  "checks": [{"layer": 1, "verb": "run_test", "runner": "vitest", "args": ["run", "a.test.ts"]}]}}]}
EOF
rc=0; out=$(validate_impl_test_commands "$V2REPL" 2>/dev/null) || rc=$?
assert_eq "replaces + v2 で grep_ref なしは違反" "1" "$rc"
assert_contains "違反文言 (v2 配線)" "grep_ref 配線検証がない" "$out"

V2GOOD="${TMPDIR}/v2-good.json"
cat > "$V2GOOD" <<'EOF'
{"tasks": [{"task_id": "t-good", "task_type": "implementation", "replaces": ["old-module.ts"], "validation": {
  "checks": [
    {"layer": 1, "verb": "run_test", "runner": "vitest", "args": ["run", "a.test.ts"]},
    {"layer": 1, "verb": "grep_ref", "pattern": "old-module", "paths": ["src/"], "expect_absent": true}
  ]}}]}
EOF
rc=0; validate_impl_test_commands "$V2GOOD" >/dev/null 2>&1 || rc=$?
assert_eq "run_test + grep_ref の v2 impl は PASS" "0" "$rc"

# validate_server_consistency の v2 対応（http_check × start_command=none）
V2HTTP="${TMPDIR}/v2-http.json"
cat > "$V2HTTP" <<'EOF'
{"tasks": [{"task_id": "t-http", "validation": {
  "checks": [{"layer": 2, "verb": "http_check", "url_path": "/api/health"}]}}]}
EOF
DEVNONE="${TMPDIR}/dev-none.json"
echo '{"server": {"start_command": "none"}}' > "$DEVNONE"
rc=0; out=$(validate_server_consistency "$V2HTTP" "$DEVNONE" 2>/dev/null) || rc=$?
assert_eq "v2 http_check × start_command=none は違反" "1" "$rc"
assert_contains "違反タスクが列挙される" "t-http" "$out"

# validate_requires_satisfiable の v2 対応（充足不能 requires が deferred なし）
V2REQ="${TMPDIR}/v2-req.json"
cat > "$V2REQ" <<'EOF'
{"tasks": [{"task_id": "t-req", "validation": {
  "checks": [{"layer": 2, "verb": "run_test", "runner": "vitest", "requires": ["docker"]}]}}]}
EOF
CAPS="${TMPDIR}/caps.json"
echo '{"capability_tags": ["cmd:node", "server"]}' > "$CAPS"
rc=0; out=$(validate_requires_satisfiable "$V2REQ" "$CAPS" 2>/dev/null) || rc=$?
assert_eq "v2 の充足不能 requires (docker) は違反" "1" "$rc"
assert_contains "C2 ラベルで列挙される" "t-req(C2)" "$out"

# deferred:true なら requires 充足ゲートは通る
V2REQD="${TMPDIR}/v2-req-deferred.json"
cat > "$V2REQD" <<'EOF'
{"tasks": [{"task_id": "t-reqd", "validation": {
  "layer_1": {"command": "npx vitest run"},
  "checks": [{"layer": 2, "verb": "run_test", "runner": "vitest", "requires": ["docker"], "deferred": true, "deferred_reason": "docker なし環境"}]}}]}
EOF
rc=0; validate_requires_satisfiable "$V2REQD" "$CAPS" >/dev/null 2>&1 || rc=$?
assert_eq "deferred:true の充足不能 requires は PASS" "0" "$rc"

print_test_summary
exit $?
