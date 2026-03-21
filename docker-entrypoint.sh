#!/bin/bash
set -euo pipefail

HARNESS_DIR="/workspace/harness"

# GitHub token → clone URL に認証を埋め込む
if [ -n "${GITHUB_TOKEN:-}" ]; then
    HARNESS_REPO="https://${GITHUB_TOKEN}@github.com/zendama1000/forge.git"
    echo "[forge-docker] GitHub token detected — push enabled"
else
    HARNESS_REPO="${FORGE_REPO:-https://github.com/zendama1000/forge.git}"
    echo "[forge-docker] No GitHub token — read-only mode"
fi

# Clone or update harness (shallow clone for speed)
if [ ! -d "$HARNESS_DIR/.git" ]; then
    echo "[forge-docker] Cloning harness ..."
    git clone --depth 1 "$HARNESS_REPO" "$HARNESS_DIR"
else
    echo "[forge-docker] Updating harness ..."
    git -C "$HARNESS_DIR" pull --ff-only 2>/dev/null || echo "[forge-docker] Pull skipped (offline or conflict)"
fi

# Create work directory if not mounted
mkdir -p /workspace/work

# Configure git for harness operations
git config --global user.email "${GIT_EMAIL:-forge@docker}"
git config --global user.name "${GIT_USER:-forge-harness}"
git config --global --add safe.directory '*'

# コンテナ終了時にハーネス変更を検出・提案
check_harness_changes() {
    local changes
    changes=$(git -C "$HARNESS_DIR" diff --name-only HEAD 2>/dev/null) || return 0
    # 未追跡の新規ファイル（_0 バックアップ等を除外）
    local untracked
    untracked=$(git -C "$HARNESS_DIR" ls-files --others --exclude-standard \
        -- '.forge/loops/' '.forge/lib/' '.forge/templates/' '.forge/schemas/' \
           '.forge/config/' '.forge/tests/' '.claude/' 'CLAUDE.md' 2>/dev/null) || true

    local all_changes="${changes}${untracked}"
    [ -z "$all_changes" ] && return 0

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⚠  ハーネスに未コミットの変更があります"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [ -n "$changes" ] && echo "$changes" | sed 's/^/  M /'
    [ -n "$untracked" ] && echo "$untracked" | sed 's/^/  ? /'
    echo ""

    # 非対話モード（tty なし）ではメッセージのみ
    if [ ! -t 0 ]; then
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            echo "push するには exit 前に: git -C $HARNESS_DIR add -A && git -C $HARNESS_DIR commit -m 'msg' && git -C $HARNESS_DIR push"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    fi

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        local answer=""
        read -p "コミットして push しますか？ [y/N]: " answer < /dev/tty 2>/dev/null || answer="n"
        if [[ "${answer:-n}" =~ ^[Yy] ]]; then
            local msg=""
            read -p "コミットメッセージ: " msg < /dev/tty 2>/dev/null || msg=""
            # shallow clone を unshallow にしてから push
            git -C "$HARNESS_DIR" fetch --unshallow 2>/dev/null || true
            git -C "$HARNESS_DIR" add -A
            git -C "$HARNESS_DIR" commit -m "${msg:-update from docker}"
            git -C "$HARNESS_DIR" push && echo "✅ push 完了" || echo "❌ push 失敗"
        else
            echo "⚠  変更は破棄されます（コンテナ終了時に消失）"
        fi
    else
        echo "GITHUB_TOKEN が未設定のため push できません。"
        echo "変更を保存するには、exit する前に以下を実行:"
        echo "  cd $HARNESS_DIR"
        echo "  git diff > /workspace/work/harness-changes.patch"
        echo ""
        echo "ホスト側で復元:"
        echo "  cd forge-research-harness-v1 && git apply projects/harness-changes.patch"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
trap check_harness_changes EXIT

cd "$HARNESS_DIR"

echo "[forge-docker] Ready. Harness: $HARNESS_DIR | Work: /workspace/work"
"$@"
