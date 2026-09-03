#!/bin/bash
# test-validation-dsl.sh — 検証 DSL「validation v2」インタープリタ単体テスト（batch#8 Stage3）
# 対象: .forge/lib/validation-dsl.sh（executor / セレクタ / 全 verb / run_layer_checks）
# 使い方: bash .forge/tests/test-validation-dsl.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log() { :; }
source "${PROJECT_ROOT}/.forge/lib/validation-dsl.sh"

# 債務記録スタブ（raw_shell / deferred の記録を検証）
QUALITY_LEDGER_FILE="${TMPDIR}/debts.jsonl"
record_quality_debt() {
  printf '{"type":"%s","task_id":"%s","detail":"%s"}\n' "$1" "$2" "$3" >> "$QUALITY_LEDGER_FILE"
}

echo -e "${BOLD}===== test-validation-dsl.sh — v2 インタープリタ =====${NC}"
echo ""

WD="${TMPDIR}/work"
mkdir -p "${WD}/src" "${WD}/node_modules/.bin"
echo 'export const PatchrightDriver = 1;' > "${WD}/src/index.ts"
touch "${WD}/marker.txt"

# ===== T1: run_workdir_cmd の argv 忠実性 =====
echo -e "${BOLD}--- T1: run_workdir_cmd argv 忠実性 ---${NC}"
cat > "${WD}/argdump.sh" <<'EOF'
#!/bin/bash
echo "argc=$#"
for a in "$@"; do echo "arg=[$a]"; done
EOF
chmod +x "${WD}/argdump.sh"
out=$(run_workdir_cmd 30 "$WD" bash argdump.sh 'a b' '$(danger)' '*' '--flag=v')
assert_contains "空白入り引数が 1 引数のまま" "arg=[a b]" "$out"
assert_contains "\$() がリテラルのまま（シェル再解釈なし）" 'arg=[$(danger)]' "$out"
assert_contains "グロブが展開されない" 'arg=[*]' "$out"
assert_contains "--flag=value 形式が保持される" "arg=[--flag=v]" "$out"
assert_contains "引数個数が正確" "argc=4" "$out"

rc=0
run_workdir_cmd 1 "$WD" sleep 5 >/dev/null 2>&1 || rc=$?
assert_eq "timeout で rc=124" "124" "$rc"
out=$(run_workdir_cmd 30 "$WD" pwd)
assert_contains "cwd が work_dir になる" "work" "$out"

# ===== T2: run_workdir_shell（legacy 意味論） =====
echo -e "${BOLD}--- T2: run_workdir_shell ---${NC}"
rc=0
out=$(run_workdir_shell 30 "$WD" 'test -f marker.txt && echo SHELL_OK') || rc=$?
assert_eq "legacy 複合コマンドが動く" "0" "$rc"
assert_contains "出力取得" "SHELL_OK" "$out"

# ===== T3: file_exists =====
echo -e "${BOLD}--- T3: file_exists ---${NC}"
rc=0; out=$(execute_check '{"layer":1,"verb":"file_exists","paths":["marker.txt","src/index.ts"]}' "$WD") || rc=$?
assert_eq "存在 → rc=0" "0" "$rc"
rc=0; out=$(execute_check '{"layer":1,"verb":"file_exists","paths":["marker.txt","nope.txt"]}' "$WD") || rc=$?
assert_eq "欠損 → rc=1" "1" "$rc"
assert_contains "欠損パスが FAIL 行に載る" "nope.txt" "$out"
rc=0; out=$(execute_check '{"layer":1,"verb":"file_exists","paths":["src/"]}' "$WD") || rc=$?
assert_eq "末尾 / はディレクトリ判定 → rc=0" "0" "$rc"
rc=0; out=$(execute_check '{"layer":1,"verb":"file_exists","paths":["/etc/passwd"]}' "$WD") || rc=$?
assert_eq "絶対パス → rc=2 (CONFIG)" "2" "$rc"
rc=0; out=$(execute_check '{"layer":1,"verb":"file_exists","paths":["../escape"]}' "$WD") || rc=$?
assert_eq ".. → rc=2" "2" "$rc"
rc=0; out=$(execute_check '{"layer":1,"verb":"file_exists","paths":["src/*.ts"]}' "$WD") || rc=$?
assert_eq "グロブ → rc=2" "2" "$rc"
rc=0; out=$(execute_check '{"layer":1,"verb":"file_exists"}' "$WD") || rc=$?
assert_eq "paths なし → rc=2" "2" "$rc"

# ===== T4: grep_ref =====
echo -e "${BOLD}--- T4: grep_ref ---${NC}"
rc=0; execute_check '{"layer":1,"verb":"grep_ref","pattern":"PatchrightDriver","paths":["src/index.ts"]}' "$WD" >/dev/null || rc=$?
assert_eq "パターン存在 → rc=0" "0" "$rc"
rc=0; execute_check '{"layer":1,"verb":"grep_ref","pattern":"NoSuchSymbol","paths":["src/index.ts"]}' "$WD" >/dev/null || rc=$?
assert_eq "パターン不在 → rc=1" "1" "$rc"
rc=0; execute_check '{"layer":1,"verb":"grep_ref","pattern":"NoSuchSymbol","paths":["src/index.ts"],"expect_absent":true}' "$WD" >/dev/null || rc=$?
assert_eq "expect_absent + 不在 → rc=0" "0" "$rc"
rc=0; execute_check '{"layer":1,"verb":"grep_ref","pattern":"PatchrightDriver","paths":["src/"]}' "$WD" >/dev/null || rc=$?
assert_eq "ディレクトリ再帰 grep → rc=0" "0" "$rc"
rc=0; execute_check '{"layer":1,"verb":"grep_ref","pattern":"x","paths":["missing.ts"]}' "$WD" >/dev/null || rc=$?
assert_eq "paths 欠損ファイル → rc=1 (FAIL)" "1" "$rc"

# ===== T5: run_test（runner マップ、PATH スタブで実行検証） =====
echo -e "${BOLD}--- T5: run_test ---${NC}"
STUB_BIN="${TMPDIR}/stub-bin"
mkdir -p "$STUB_BIN"
cat > "${STUB_BIN}/npx" <<EOF
#!/bin/bash
printf '%s' "\$*" > "${TMPDIR}/npx-args.txt"
[ "\${STUB_EXIT:-0}" = "0" ] || exit "\${STUB_EXIT}"
EOF
chmod +x "${STUB_BIN}/npx"
rc=0
out=$(PATH="${STUB_BIN}:$PATH" execute_check '{"layer":1,"verb":"run_test","runner":"vitest","args":["src/a.test.ts"]}' "$WD") || rc=$?
assert_eq "vitest → rc=0" "0" "$rc"
assert_eq "npx vitest run + args が argv で渡る" "vitest run src/a.test.ts" "$(cat "${TMPDIR}/npx-args.txt" 2>/dev/null)"
rc=0
out=$(PATH="${STUB_BIN}:$PATH" execute_check '{"layer":1,"verb":"run_test","runner":"vitest","args":["run","src/b.test.ts"]}' "$WD") || rc=$?
assert_eq "args=[run, …] の二重化は argv でも落ちる（batch#11 R13）" "vitest run src/b.test.ts" "$(cat "${TMPDIR}/npx-args.txt" 2>/dev/null)"
rc=0
out=$(PATH="${STUB_BIN}:$PATH" STUB_EXIT=3 execute_check '{"layer":1,"verb":"run_test","runner":"tsc"}' "$WD") || rc=$?
assert_eq "runner 失敗 → rc=1 に正規化" "1" "$rc"
assert_contains "exit code が出力に載る" "exit=3" "$out"
rc=0; execute_check '{"layer":1,"verb":"run_test","runner":"mocha"}' "$WD" >/dev/null || rc=$?
assert_eq "未知 runner → rc=2" "2" "$rc"

# ===== T6: http_check（curl スタブ） =====
echo -e "${BOLD}--- T6: http_check ---${NC}"
cat > "${STUB_BIN}/curl" <<'EOF'
#!/bin/bash
# -o <file> を探して body を書く / stdout に status
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && printf '%s' "${STUB_BODY:-{\"ok\":true}}" > "$out"
printf '%s' "${STUB_STATUS:-200}"
EOF
chmod +x "${STUB_BIN}/curl"
rc=0
out=$(PATH="${STUB_BIN}:$PATH" execute_check '{"layer":2,"verb":"http_check","url":"http://localhost:3001/api/health"}' "$WD") || rc=$?
assert_eq "200 → rc=0" "0" "$rc"
rc=0
out=$(PATH="${STUB_BIN}:$PATH" STUB_STATUS=404 execute_check '{"layer":2,"verb":"http_check","url":"http://localhost:3001/x"}' "$WD") || rc=$?
assert_eq "404 (expect 200) → rc=1" "1" "$rc"
rc=0
out=$(PATH="${STUB_BIN}:$PATH" execute_check '{"layer":2,"verb":"http_check","url":"http://h/x","body_jq":".ok == true"}' "$WD") || rc=$?
assert_eq "body_jq 成立 → rc=0" "0" "$rc"
rc=0
out=$(PATH="${STUB_BIN}:$PATH" STUB_BODY='{"ok":false}' execute_check '{"layer":2,"verb":"http_check","url":"http://h/x","body_jq":".ok == true"}' "$WD") || rc=$?
assert_eq "body_jq 不成立 → rc=1" "1" "$rc"
# base URL 導出
DEV_CONFIG="${TMPDIR}/dev.json"
echo '{"server":{"health_check_url":"http://localhost:3001/api/health"}}' > "$DEV_CONFIG"
rc=0
out=$(PATH="${STUB_BIN}:$PATH" execute_check '{"layer":2,"verb":"http_check","url_path":"/api/users"}' "$WD") || rc=$?
assert_eq "url_path + health_check_url 由来 base → rc=0" "0" "$rc"
assert_contains "導出 URL が正しい" "http://localhost:3001/api/users" "$out"
DEV_CONFIG="${TMPDIR}/empty.json"
echo '{}' > "$DEV_CONFIG"
rc=0; execute_check '{"layer":2,"verb":"http_check","url_path":"/x"}' "$WD" >/dev/null || rc=$?
assert_eq "base 導出不能 → rc=2" "2" "$rc"

# ===== T7: effect_smoke =====
echo -e "${BOLD}--- T7: effect_smoke ---${NC}"
rc=0
out=$(execute_check '{"layer":1,"verb":"effect_smoke","argv":["bash","-c","echo SMOKE && touch produced.txt"],"expect":{"exit_code":0,"stdout_contains":"SMOKE","creates_files":["produced.txt"]}}' "$WD") || rc=$?
assert_eq "exit+stdout+生成物 全成立 → rc=0" "0" "$rc"
rc=0
out=$(execute_check '{"layer":1,"verb":"effect_smoke","argv":["bash","-c","exit 7"],"expect":{"exit_code":7}}' "$WD") || rc=$?
assert_eq "expect.exit_code=7 一致 → rc=0" "0" "$rc"
rc=0
out=$(execute_check '{"layer":1,"verb":"effect_smoke","argv":["true"],"expect":{"creates_files":["never-made.txt"]}}' "$WD") || rc=$?
assert_eq "生成物なし → rc=1" "1" "$rc"

# ===== T8: raw_shell（実行 + weak_validation 債務） =====
echo -e "${BOLD}--- T8: raw_shell ---${NC}"
: > "$QUALITY_LEDGER_FILE"
_V2_TASK_ID="task-raw"
rc=0
out=$(execute_check '{"layer":1,"verb":"raw_shell","id":"R1","shell":"test -f marker.txt","reason":"verb 未対応の検証"}' "$WD") || rc=$?
assert_eq "raw_shell 成功 → rc=0" "0" "$rc"
assert_eq "weak_validation 債務が記録される" "1" "$(grep -c weak_validation "$QUALITY_LEDGER_FILE")"
execute_check '{"layer":1,"verb":"raw_shell","id":"R1","shell":"test -f marker.txt","reason":"r"}' "$WD" >/dev/null
assert_eq "同一 task+check は債務 1 回だけ（dedup）" "1" "$(grep -c weak_validation "$QUALITY_LEDGER_FILE")"
rc=0; execute_check '{"layer":1,"verb":"raw_shell","reason":"shell なし"}' "$WD" >/dev/null || rc=$?
assert_eq "shell 欠落 → rc=2" "2" "$rc"

# ===== T9: 未知 verb =====
rc=0; execute_check '{"layer":1,"verb":"teleport"}' "$WD" >/dev/null || rc=$?
assert_eq "未知 verb → rc=2" "2" "$rc"

# ===== T10: セレクタ =====
echo -e "${BOLD}--- T10: セレクタ ---${NC}"
TASK='{"task_id":"T1","validation":{"layer_1":{"command":"legacy"},"checks":[
  {"layer":1,"verb":"file_exists","paths":["a"]},
  {"layer":2,"verb":"http_check","url_path":"/h"},
  {"layer":2,"verb":"run_test","runner":"vitest","deferred":true}
]}}'
assert_eq "v2_checks_for_layer(1) が 1 件" "1" "$(v2_checks_for_layer "$TASK" 1 | jq 'length')"
assert_eq "v2_checks_for_layer(3) は空配列" "[]" "$(v2_checks_for_layer "$TASK" 3)"
task_layer_is_v2 "$TASK" 1 && r="yes" || r="no"
assert_eq "task_layer_is_v2(1)=yes" "yes" "$r"
task_layer_is_v2 "$TASK" 3 && r="yes" || r="no"
assert_eq "task_layer_is_v2(3)=no" "no" "$r"
checks_require_server "$TASK" 2 && r="yes" || r="no"
assert_eq "checks_require_server(2)=yes（http_check 暗黙）" "yes" "$r"
LEGACY_ONLY='{"validation":{"layer_1":{"command":"npx vitest run"}}}'
task_layer_is_v2 "$LEGACY_ONLY" 1 && r="yes" || r="no"
assert_eq "legacy-only タスクは v2 でない" "no" "$r"

# fingerprint: キー順非依存の構造比較素材
FP_A=$(v2_layer_fingerprint '{"checks":[{"layer":2,"verb":"http_check","url_path":"/h"}]}' 2)
same=$(jq -n --argjson a "$FP_A" --argjson b '[{"verb":"http_check","layer":2,"url_path":"/h"}]' '$a == $b')
assert_eq "fingerprint はキー順非依存で等価" "true" "$same"
assert_eq "空 layer の fingerprint は []" "[]" "$(v2_layer_fingerprint '{"checks":[]}' 2)"

# render / primary command
summary=$(render_checks_summary "$TASK" 2)
assert_contains "render: http_check 行" "http_check" "$summary"
PRIM='{"validation":{"checks":[{"layer":1,"verb":"run_test","runner":"vitest","args":["run","x.test.ts"]}]}}'
assert_eq "v2_primary_test_command（args[0]=run は base 末尾と重複なので落とす — batch#11 R13）" "npx vitest run x.test.ts" "$(v2_primary_test_command "$PRIM")"
PRIM2='{"validation":{"checks":[{"layer":1,"verb":"run_test","runner":"vitest","args":["x.test.ts"]}]}}'
assert_eq "v2_primary_test_command（重複なしはそのまま）" "npx vitest run x.test.ts" "$(v2_primary_test_command "$PRIM2")"
PRIM3='{"validation":{"checks":[{"layer":1,"verb":"run_test","runner":"jest","args":["run"]}]}}'
assert_eq "v2_primary_test_command（jest の run は base 末尾と違うので残る）" "npx jest run" "$(v2_primary_test_command "$PRIM3")"
assert_eq "run_test なしなら空" "" "$(v2_primary_test_command "$LEGACY_ONLY")"

# ===== T11: run_layer_checks オーケストレーション =====
echo -e "${BOLD}--- T11: run_layer_checks ---${NC}"
: > "$QUALITY_LEDGER_FILE"
requires_entry_satisfiable() { [ "$1" != "docker" ]; }  # docker のみ不足の環境を模擬

ORCH='{"task_id":"T-orch","validation":{"checks":[
  {"id":"c1","layer":1,"verb":"file_exists","paths":["marker.txt"]},
  {"id":"c2","layer":1,"verb":"file_exists","paths":["missing.txt"],"deferred":true,"deferred_reason":"実環境依存"},
  {"id":"c3","layer":2,"verb":"raw_shell","shell":"true","reason":"r","requires":["docker"]},
  {"id":"c4","layer":2,"verb":"file_exists","paths":["marker.txt"]}
]}}'
rc=0
out=$(run_layer_checks "$ORCH" 1 "$WD" 60 "T-orch") || rc=$?
assert_eq "L1: pass + deferred → rc=0" "0" "$rc"
assert_contains "deferred が DEFER 表示される" "DEFER c2" "$out"
assert_eq "deferred_test 債務が記録される" "1" "$(grep -c deferred_test "$QUALITY_LEDGER_FILE")"

rc=0
out=$(run_layer_checks "$ORCH" 2 "$WD" 60 "T-orch") || rc=$?
assert_eq "L2: requires 不足は SKIP + 実行分 pass → rc=0" "0" "$rc"
assert_contains "SKIP 表示" "SKIP c3" "$out"
assert_eq "l2_skip 債務が記録される" "1" "$(grep -c l2_skip "$QUALITY_LEDGER_FILE")"

FAILCASE='{"task_id":"T-f","validation":{"checks":[
  {"id":"f1","layer":1,"verb":"file_exists","paths":["marker.txt"]},
  {"id":"f2","layer":1,"verb":"file_exists","paths":["missing.txt"]}
]}}'
rc=0
out=$(run_layer_checks "$FAILCASE" 1 "$WD" 60 "T-f") || rc=$?
assert_eq "1 件でも fail → rc=1" "1" "$rc"
assert_contains "集約行に fails=1" "fails=1" "$out"

# L1 の requires 不充足は FAIL（defer 経路なし）
L1REQ='{"task_id":"T-r","validation":{"checks":[
  {"id":"r1","layer":1,"verb":"file_exists","paths":["marker.txt"],"requires":["docker"]}
]}}'
rc=0
out=$(run_layer_checks "$L1REQ" 1 "$WD" 60 "T-r") || rc=$?
assert_eq "L1 requires 不充足 → rc=1 (FAIL)" "1" "$rc"
assert_contains "FAIL 理由に defer 不可の明示" "defer" "$out"

print_test_summary
exit $?
