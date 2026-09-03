#!/bin/bash
# Stop hook: ハーネスの出荷衛生を 3 検査で通知する（常に exit 0、早期 return なし — batch#11 R01）
#   1. ハーネスコードの未コミット変更（.forge/state/ や logs 等の実行時生成物は除外）
#   2. 未追跡のハーネスファイル（新規テスト/lib を追加したまま add し忘れる事故）
#   3. 出荷遅延: origin/master に未反映のまま最終コミットから 7 日超の feature/*（最大 20 本）
#      — batch#10 が 7 週間未マージのまま本番ランに使われた事故（2026-08）の再発防止
# 時間予算: Stop hook の 5 秒制限内（最悪 ~1.5 秒）

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STALE_DAYS="${FORGE_SHIP_STALE_DAYS:-7}"

git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# ---- 1. 未コミット変更 ----
changes=$(git -C "$PROJECT_DIR" diff --name-only HEAD -- \
    '.forge/loops/' '.forge/lib/' '.forge/eval/' '.forge/templates/' '.forge/schemas/' \
    '.forge/config/' '.forge/tests/' '.claude/' 'CLAUDE.md' \
    'Dockerfile' 'docker-entrypoint.sh' 'docker-compose.yml' \
    2>/dev/null || true)
if [ -n "$changes" ]; then
  count=$(printf '%s\n' "$changes" | grep -c . 2>/dev/null || echo 0)
  echo "⚠ ハーネスコードに未コミットの変更が ${count} 件あります。commit → master へ FF → git push を推奨します。" >&2
fi

# ---- 2. 未追跡のハーネスファイル ----
untracked=$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard -- \
    '.forge/loops' '.forge/lib' '.forge/eval' '.forge/tests' '.claude' 2>/dev/null || true)
if [ -n "$untracked" ]; then
  ucount=$(printf '%s\n' "$untracked" | grep -c . 2>/dev/null || echo 0)
  echo "⚠ 未追跡のハーネスファイルが ${ucount} 件あります（git add 忘れ）: $(printf '%s\n' "$untracked" | head -3 | tr '\n' ' ')" >&2
fi

# ---- 3. 出荷遅延（origin/master 未反映 + 7 日超の feature/*）----
if git -C "$PROJECT_DIR" rev-parse --verify -q refs/remotes/origin/master >/dev/null 2>&1; then
  now=$(date +%s)
  stale_list=""
  n=0
  # git 1 回で「origin/master に未マージの feature/*」と最終コミット日時を得る（Windows は spawn が高価）
  while IFS=' ' read -r ref cdate; do
    [ -n "$ref" ] || continue
    n=$((n + 1)); [ "$n" -gt 20 ] && break
    case "$cdate" in (''|*[!0-9]*) continue ;; esac
    age_days=$(( (now - cdate) / 86400 ))
    if [ "$age_days" -gt "$STALE_DAYS" ]; then
      stale_list="${stale_list}${ref}(${age_days}日) "
    fi
  done < <(git -C "$PROJECT_DIR" branch --no-merged refs/remotes/origin/master --list 'feature/*' --format='%(refname:short) %(committerdate:unix)' 2>/dev/null)
  if [ -n "$stale_list" ]; then
    echo "⚠ 出荷遅延: origin/master に未反映のまま ${STALE_DAYS} 日超の feature ブランチ: ${stale_list}— 出荷規則: 作業ブランチ → master へ FF → push → forge-gtr.sh new（既定 base origin/master）" >&2
  fi
fi

exit 0
