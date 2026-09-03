#!/bin/bash
# test-forge-gtr-new.sh — forge-gtr.sh new の base 既定（origin/master）と未 push 警告（batch#11 R01）
#
# PATH 先頭に gtr シムを置き、forge-gtr.sh が `gtr new <branch> --from <ref> --yes` を渡すことを検証する。
# シムは受け取った引数を記録し、実際に `git worktree add` して resolve_wt が解決できるようにする。
# 一時リポジトリに forge-gtr.sh をコピーして実行する（本番ハーネスにワークツリー/ブランチを作らない）。
# 使い方: bash .forge/tests/test-forge-gtr-new.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/gtr-new-$$")
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo -e "${BOLD}===== test-forge-gtr-new.sh — forge-gtr.sh new の base 既定 =====${NC}"
echo ""

# ===== 一時ハーネス repo =====
HR="${TMP}/harness"
mkdir -p "${HR}/.forge/state"
git -C "$HR" init -q -b master
git -C "$HR" config user.email t@t; git -C "$HR" config user.name t
cp "${PROJECT_ROOT}/forge-gtr.sh" "${HR}/forge-gtr.sh"
echo "base" > "${HR}/README.md"
git -C "$HR" add -A && git -C "$HR" commit -q -m base
git -C "$HR" tag v1
git -C "$HR" update-ref refs/remotes/origin/master HEAD
# master を origin/master より 1 コミット先行させる（未 push 状態）
echo "ahead" >> "${HR}/README.md"; git -C "$HR" commit -q -am ahead

# ===== gtr シム =====
SHIM="${TMP}/bin"; mkdir -p "$SHIM"
cat > "${SHIM}/gtr" <<'SH'
#!/bin/bash
# gtr new <branch> [--from <ref>] [--yes] [--no-fetch] を記録して git worktree add で代替する
printf '%s\n' "$*" >> "${GTR_SHIM_LOG}"
[ "$1" = "new" ] || exit 0
branch="$2"; shift 2
from=""
while [ $# -gt 0 ]; do
  case "$1" in --from) from="$2"; shift 2 ;; *) shift ;; esac
done
root=$(git rev-parse --show-toplevel)
dir="$(dirname "$root")/$(basename "$root")-$(echo "$branch" | tr '/' '-')"
git worktree add -q -b "$branch" "$dir" "${from:-HEAD}" >/dev/null 2>&1
SH
chmod +x "${SHIM}/gtr"
export GTR_SHIM_LOG="${TMP}/gtr-args.log"

run_new() {  # run_new <args...> → stdout+stderr を $OUT に、exit code を echo
  : > "$GTR_SHIM_LOG"
  PATH="${SHIM}:$PATH" bash "${HR}/forge-gtr.sh" new "$@" > "${TMP}/out.txt" 2>&1
  echo $?
}

# ========================================================================
echo -e "${BOLD}--- Group 1: 既定 base は origin/master ---${NC}"
# ========================================================================
rc=$(run_new alpha)
assert_eq "new alpha → exit 0" "0" "$rc"
assert_contains "gtr new に --from origin/master --yes が渡る" "new project/alpha --from origin/master --yes" "$(cat "$GTR_SHIM_LOG")"
assert_eq "ワークツリーのブランチは origin/master から切られる（ahead コミットを含まない）" "true" \
  "$(git -C "$HR" rev-parse project/alpha 2>/dev/null | grep -q "$(git -C "$HR" rev-parse refs/remotes/origin/master)" && echo true || echo false)"
assert_contains "master が origin/master より先行していれば警告" "origin/master より" "$(cat "${TMP}/out.txt")"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 2: --base で上書き / FORGE_GTR_NO_FETCH ---${NC}"
# ========================================================================
rc=$(run_new beta --base v1)
assert_eq "new beta --base v1 → exit 0" "0" "$rc"
assert_contains "--base v1 が --from v1 に渡る" "new project/beta --from v1 --yes" "$(cat "$GTR_SHIM_LOG")"
: > "$GTR_SHIM_LOG"
rc=$(FORGE_GTR_NO_FETCH=1 run_new gamma)
assert_contains "FORGE_GTR_NO_FETCH=1 で --no-fetch" "--no-fetch" "$(cat "$GTR_SHIM_LOG")"
echo ""

# ========================================================================
echo -e "${BOLD}--- Group 3: master と origin/master が一致していれば警告なし ---${NC}"
# ========================================================================
git -C "$HR" update-ref refs/remotes/origin/master master
rc=$(run_new delta)
assert_eq "exit 0" "0" "$rc"
assert_not_contains "先行なしなら警告しない" "origin/master より" "$(cat "${TMP}/out.txt")"
assert_contains "usage に base 既定の記載" "origin/master" "$(bash "${HR}/forge-gtr.sh" help 2>&1 | grep -i 'new <name>' | head -1)"
echo ""

git -C "$HR" worktree prune 2>/dev/null || true
print_test_summary
