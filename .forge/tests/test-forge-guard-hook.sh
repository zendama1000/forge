#!/bin/bash
# test-forge-guard-hook.sh — PreToolUse deny hook（.claude/hooks/forge-guard.sh）のテスト（batch#11 R05）
#
# 検証する振る舞い:
#   - Write 系: WORK_DIR 内は許可 / WORK_DIR 外・ハーネス配下・protected_patterns・既存テストは拒否
#   - パス正規化: バックスラッシュ / 相対 / .. / 大小文字差があっても検出（沈黙不発火の防止）
#   - Bash: 破壊的 git / ハーネス側リポジトリ操作 / rm・リダイレクト・sed -i・cp 先の WORK_DIR 外を拒否
#   - フェイルオープン: 不正 JSON・対象外ツール・空入力は exit 0
#   - 拒否は guard-denials.jsonl に 1 行（有効 JSON）
# 使い方: bash .forge/tests/test-forge-guard-hook.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

HOOK="${PROJECT_ROOT}/.claude/hooks/forge-guard.sh"
TMP=$(mktemp -d 2>/dev/null || echo "/tmp/guard-test-$$")
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
# Windows: MSYS は native exe（jq）へ渡す /tmp/… を 8.3 短縮形（BOSSBO~1）に変換する一方、
# 環境変数の /tmp/… は hook 側で cygpath -ml（長い名前）になる。fixture を最初から長形式に揃える
# （本番も run_claude が cygpath -ml で渡す）
if command -v cygpath >/dev/null 2>&1; then TMP=$(cygpath -ml "$TMP"); fi

echo -e "${BOLD}===== test-forge-guard-hook.sh — PreToolUse deny hook =====${NC}"
echo ""

# ===== fixture: WORK_DIR（git repo, tests/a.test.ts を commit） =====
WD="${TMP}/work"
mkdir -p "${WD}/tests" "${WD}/src"
git -C "$WD" init -q
git -C "$WD" config user.email t@t; git -C "$WD" config user.name t
echo "test('a', () => {})" > "${WD}/tests/a.test.ts"
echo "export const x = 1" > "${WD}/src/x.ts"
git -C "$WD" add -A && git -C "$WD" commit -q -m init
BASE=$(git -C "$WD" rev-parse HEAD)
# base 以後に追加された（= 基準 SHA に存在しない）テスト
echo "test('b', () => {})" > "${WD}/tests/later.test.ts"
git -C "$WD" add -A && git -C "$WD" commit -q -m later

# ===== fixture: ハーネス root（実 root は触らない） =====
HR="${TMP}/harness"
mkdir -p "${HR}/.forge/config" "${HR}/.forge/state" "${HR}/.claude/agents" "${HR}/other"
cp "${PROJECT_ROOT}/.forge/config/circuit-breaker.json" "${HR}/.forge/config/circuit-breaker.json"
cp "${PROJECT_ROOT}/.forge/lib/patterns.sh" "${HR}/patterns.sh" 2>/dev/null || true
CB="${HR}/.forge/config/circuit-breaker.json"
LOG="${TMP}/guard-denials.jsonl"
ELSEWHERE="${TMP}/elsewhere"; mkdir -p "$ELSEWHERE"

# run_hook <json> [ALLOW_TEST_EDITS] [WORK_DIR override ("-" = unset)] → echo exit code, stderr to $ERR
ERR="${TMP}/err.txt"
run_hook() {
  local json="$1" allow="${2:-false}" wd="${3:-$WD}"
  if [ "$wd" = "-" ]; then wd=""; fi
  printf '%s' "$json" | FORGE_GUARD_WORK_DIR="$wd" FORGE_GUARD_HARNESS_ROOT="$HR" \
    FORGE_GUARD_CB_CONFIG="$CB" FORGE_GUARD_BASE_REF="$BASE" FORGE_GUARD_LOG="$LOG" \
    FORGE_GUARD_ALLOW_TEST_EDITS="$allow" FORGE_GUARD_TASK_ID="t-1" bash "$HOOK" 2>"$ERR"
  echo $?
}
wjson() { jq -cn --arg t "${2:-Write}" --arg p "$1" --arg cwd "$WD" '{tool_name:$t,tool_input:{file_path:$p,content:"x"},cwd:$cwd}'; }
bjson() { jq -cn --arg c "$1" --arg cwd "$WD" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'; }
last_reason() { tail -1 "$LOG" 2>/dev/null | jq -r '.reason' 2>/dev/null; }

# Windows 形式（バックスラッシュ）の WORK_DIR
if command -v cygpath >/dev/null 2>&1; then WD_WIN=$(cygpath -w "$WD"); else WD_WIN=$(printf '%s' "$WD" | sed 's#/#\\#g'); fi

# ========================================================================
echo -e "${BOLD}--- Group 1: Write 系（WORK_DIR 内は許可） ---${NC}"
# ========================================================================
assert_eq "WORK_DIR 内の src/x.ts（絶対パス）→ 許可" "0" "$(run_hook "$(wjson "${WD}/src/x.ts")")"
assert_eq "WORK_DIR 内の相対パス src/y.ts（cwd=WORK_DIR）→ 許可" "0" "$(run_hook "$(wjson "src/y.ts")")"
assert_eq "新規テスト tests/new.test.ts（基準 SHA に無い）→ 許可" "0" "$(run_hook "$(wjson "tests/new.test.ts")")"
assert_eq "基準 SHA 以後に追加されたテスト tests/later.test.ts → 許可（HEAD ではなく base_ref 基準）" "0" "$(run_hook "$(wjson "${WD}/tests/later.test.ts")")"
assert_eq "Edit ツールでも同じ規則（src/x.ts → 許可）" "0" "$(run_hook "$(wjson "${WD}/src/x.ts" Edit)")"
assert_eq "対象外ツール（Read）→ 許可" "0" "$(run_hook "$(jq -cn --arg p "${HR}/.forge/state/x" '{tool_name:"Read",tool_input:{file_path:$p}}')")"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: Write 系の拒否（正規化を含む） ---${NC}"
# ========================================================================
: > "$LOG"
rc=$(run_hook "$(wjson "${WD}/tests/a.test.ts")")
assert_eq "既存テスト tests/a.test.ts（POSIX パス）→ 拒否" "2" "$rc"
assert_contains "拒否理由が test_sanctity" "test_sanctity" "$(last_reason)"
assert_contains "stderr にモデル向けの理由がある" "既存のテストファイルは改変禁止" "$(cat "$ERR")"

rc=$(run_hook "$(wjson "${WD_WIN}\\tests\\a.test.ts")")
assert_eq "既存テスト（バックスラッシュ Windows パス）→ 拒否（正規化）" "2" "$rc"
rc=$(run_hook "$(wjson "src/../tests/a.test.ts")")
assert_eq "既存テスト（相対 + .. 経由）→ 拒否（正規化）" "2" "$rc"
rc=$(run_hook "$(wjson "${WD}/tests/a.test.ts" MultiEdit)")
assert_eq "MultiEdit でも既存テストは拒否" "2" "$rc"
assert_eq "ALLOW_TEST_EDITS=true → 既存テストも許可" "0" "$(run_hook "$(wjson "${WD}/tests/a.test.ts")" true)"

: > "$LOG"
rc=$(run_hook "$(wjson "${WD}/.env")")
assert_eq "protected_patterns（.env*）→ 拒否" "2" "$rc"
assert_contains "拒否理由が protected_pattern" "protected_pattern" "$(last_reason)"
rc=$(run_hook "$(wjson "${WD}/.forge/state/task-stack.json")")
assert_eq "WORK_DIR 配下の .forge/**（protected_patterns に追加済）→ 拒否" "2" "$rc"
rc=$(run_hook "$(wjson "${WD}/node_modules/x/index.js")")
assert_eq "node_modules/** → 拒否" "2" "$rc"

: > "$LOG"
rc=$(run_hook "$(wjson "${HR}/.forge/state/task-stack.json")")
assert_eq "ハーネス root の .forge/state → 拒否" "2" "$rc"
assert_contains "拒否理由が harness_protected" "harness_protected" "$(last_reason)"
rc=$(run_hook "$(wjson "${HR}/.claude/agents/implementer.md")")
assert_eq "ハーネス root の .claude/agents → 拒否" "2" "$rc"
rc=$(run_hook "$(wjson "${HR}/CLAUDE.md")")
assert_eq "ハーネス root の CLAUDE.md → 拒否" "2" "$rc"
# 大小文字差: Windows 形式（C:/…）に変換してから大文字化（/TMP は MSYS マウントとして解決できないため）
if command -v cygpath >/dev/null 2>&1; then HR_UP=$(cygpath -m "$HR" | tr '[:lower:]' '[:upper:]'); else HR_UP=$(printf '%s' "$HR" | tr '[:lower:]' '[:upper:]'); fi
rc=$(run_hook "$(wjson "${HR_UP}/.FORGE/lib/common.sh")")
assert_eq "ハーネス配下（大文字化したパス）→ 拒否（大小文字を無視して比較）" "2" "$rc"

: > "$LOG"
rc=$(run_hook "$(wjson "${ELSEWHERE}/x.ts")")
assert_eq "WORK_DIR 外（別ディレクトリ）→ 拒否" "2" "$rc"
assert_contains "拒否理由が outside_work_dir" "outside_work_dir" "$(last_reason)"
rc=$(run_hook "$(wjson "${HR}/other/notes.md")")
assert_eq "ハーネス root 配下（非保護領域）も WORK_DIR 外として拒否" "2" "$rc"
rc=$(run_hook "$(wjson "../elsewhere/y.ts")")
assert_eq "相対パスで WORK_DIR を抜ける（../）→ 拒否" "2" "$rc"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: WORK_DIR 未設定（ハーネス保護のみ） ---${NC}"
# ========================================================================
assert_eq "WORK_DIR 未設定 + ハーネス .forge → 拒否" "2" "$(run_hook "$(wjson "${HR}/.forge/x.json")" false -)"
assert_eq "WORK_DIR 未設定 + ハーネス root の非保護領域 → 許可" "0" "$(run_hook "$(wjson "${HR}/other/notes.md")" false -)"
assert_eq "WORK_DIR 未設定 + 任意の場所 → 許可（WORK_DIR 系検査はスキップ）" "0" "$(run_hook "$(wjson "${ELSEWHERE}/z.ts")" false -)"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 4: Bash — 破壊的 git / ハーネス側リポジトリ ---${NC}"
# ========================================================================
: > "$LOG"
for c in "git reset --hard HEAD~1" "git checkout -- ." "git clean -fd" "git push origin main" "git stash" \
         "git rebase -i HEAD~3" "git restore src/x.ts" "git switch main" \
         "npm test && git reset --hard" "git -C sub checkout -- ." "git --no-pager reset --soft HEAD~1" \
         "cd src; git checkout -- x.ts"; do
  assert_eq "拒否: ${c}" "2" "$(run_hook "$(bjson "$c")")"
done
assert_contains "拒否理由が git_destructive" "git_destructive" "$(last_reason)"
for c in "git -C ${HR} commit -m x" "git --git-dir=${HR}/.git status" "git --work-tree=${HR} add -A"; do
  assert_eq "拒否（ハーネス側リポジトリ）: ${c}" "2" "$(run_hook "$(bjson "$c")")"
done
for c in "npx vitest run" "git commit -m 'feat: x'" "git add -A" "git status" "git log --oneline | head -5" \
         "git diff HEAD" "git -C ${WD} commit -m x" "npm run build && npm test" "node --test tests/" \
         "echo 'git reset' > notes.txt" "cat ${HR}/.forge/state/phase-tests/t.sh"; do
  assert_eq "許可: ${c}" "0" "$(run_hook "$(bjson "$c")")"
done
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 5: Bash — rm / リダイレクト / sed -i / cp・mv / tee ---${NC}"
# ========================================================================
: > "$LOG"
assert_eq "rm -rf <harness>/.forge/state → 拒否" "2" "$(run_hook "$(bjson "rm -rf ${HR}/.forge/state")")"
assert_contains "拒否理由が harness_protected" "harness_protected" "$(last_reason)"
assert_eq "rm -rf ../elsewhere → 拒否（WORK_DIR 外）" "2" "$(run_hook "$(bjson "rm -rf ../elsewhere")")"
assert_eq "rm -rf .git → 拒否" "2" "$(run_hook "$(bjson "rm -rf .git")")"
assert_eq "rm -rf . → 拒否（WORK_DIR 自身）" "2" "$(run_hook "$(bjson "rm -rf .")")"
assert_eq "rm -rf ${WD} → 拒否（WORK_DIR 自身・絶対）" "2" "$(run_hook "$(bjson "rm -rf ${WD}")")"
assert_eq "rm -rf node_modules → 許可" "0" "$(run_hook "$(bjson "rm -rf node_modules")")"
assert_eq "rm -rf dist && npm run build → 許可" "0" "$(run_hook "$(bjson "rm -rf dist && npm run build")")"
assert_eq "rm -f src/tmp.ts → 許可" "0" "$(run_hook "$(bjson "rm -f src/tmp.ts")")"

assert_eq "echo x > <harness>/.forge/state/task-stack.json → 拒否" "2" "$(run_hook "$(bjson "echo x > ${HR}/.forge/state/task-stack.json")")"
assert_eq "echo x >> ../elsewhere/log.txt → 拒否" "2" "$(run_hook "$(bjson "echo x >> ../elsewhere/log.txt")")"
assert_eq "echo x > out.txt → 許可" "0" "$(run_hook "$(bjson "echo x > out.txt")")"
assert_eq "cmd > /dev/null 2>&1 → 許可" "0" "$(run_hook "$(bjson "npm test > /dev/null 2>&1")")"
assert_eq "cmd 2>/dev/null | tee build.log → 許可" "0" "$(run_hook "$(bjson "npm run build 2>/dev/null | tee build.log")")"
assert_eq "cmd &> ../elsewhere/all.log → 拒否" "2" "$(run_hook "$(bjson "npm test &> ../elsewhere/all.log")")"

assert_eq "sed -i on <harness>/.forge/lib/common.sh → 拒否" "2" "$(run_hook "$(bjson "sed -i 's/a/b/' ${HR}/.forge/lib/common.sh")")"
assert_eq "sed -i on src/x.ts → 許可" "0" "$(run_hook "$(bjson "sed -i 's/a/b/' src/x.ts")")"
assert_eq "sed -n（読取）on harness → 許可" "0" "$(run_hook "$(bjson "sed -n '1,5p' ${HR}/.forge/lib/common.sh")")"

assert_eq "cp src/x.ts <harness>/.claude/agents/x.md → 拒否（コピー先）" "2" "$(run_hook "$(bjson "cp src/x.ts ${HR}/.claude/agents/x.md")")"
assert_eq "cp <harness>/.forge/state/phase-tests/t.sh ./t.sh → 許可（コピー元は読取）" "0" "$(run_hook "$(bjson "cp ${HR}/.forge/state/phase-tests/t.sh ./t.sh")")"
assert_eq "mv src/a.ts ../elsewhere/ → 拒否" "2" "$(run_hook "$(bjson "mv src/a.ts ../elsewhere/")")"
assert_eq "tee <harness>/CLAUDE.md → 拒否" "2" "$(run_hook "$(bjson "echo x | tee ${HR}/CLAUDE.md")")"
assert_eq "chmod +x <harness>/forge-gtr.sh → 拒否" "2" "$(run_hook "$(bjson "chmod +x ${HR}/forge-gtr.sh")")"
assert_eq "chmod +x scripts/run.sh → 許可" "0" "$(run_hook "$(bjson "chmod +x scripts/run.sh")")"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 6: フェイルオープンとログ ---${NC}"
# ========================================================================
rc=$(printf '%s' 'not json at all' | FORGE_GUARD_WORK_DIR="$WD" FORGE_GUARD_HARNESS_ROOT="$HR" bash "$HOOK" 2>"$ERR"; echo $?)
assert_eq "不正 JSON → 許可（exit 0）" "0" "$rc"
assert_contains "不正 JSON は stderr に警告" "不正 JSON" "$(cat "$ERR")"
rc=$(printf '' | FORGE_GUARD_WORK_DIR="$WD" bash "$HOOK" 2>/dev/null; echo $?)
assert_eq "空入力 → 許可" "0" "$rc"
rc=$(printf '%s' '{"hook_event_name":"PreToolUse"}' | FORGE_GUARD_WORK_DIR="$WD" bash "$HOOK" 2>/dev/null; echo $?)
assert_eq "tool_name 無し → 許可" "0" "$rc"
rc=$(printf '%s' '{"tool_name":"Write","tool_input":{}}' | FORGE_GUARD_WORK_DIR="$WD" bash "$HOOK" 2>/dev/null; echo $?)
assert_eq "file_path 無し → 許可" "0" "$rc"

: > "$LOG"
run_hook "$(wjson "${HR}/.forge/x")" >/dev/null
assert_eq "拒否ログが 1 行" "1" "$(wc -l < "$LOG" | tr -d ' ')"
assert_eq "拒否ログが有効 JSON で tool/reason/task を持つ" "Write|harness_protected|t-1" "$(jq -r '[.tool,.reason,.task] | join("|")' "$LOG" 2>/dev/null)"
run_hook "$(bjson "git reset --hard")" >/dev/null
assert_eq "Bash の拒否ログはコマンドを target に持つ" "Bash: git reset --hard" "$(tail -1 "$LOG" | jq -r '.target')"
echo ""

print_test_summary
