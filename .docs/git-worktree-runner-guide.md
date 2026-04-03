# git-worktree-runner (gtr) × Forge Harness ベストプラクティス

Docker マルチインスタンスの代替として、git-worktree-runner を使い
Forge Harness の並列プロジェクト実行を軽量に実現する運用ガイド。

## 前提

- **gtr**: CodeRabbit 製 Bash CLI（`git gtr`）。`git worktree` のラッパー
- **リポジトリ**: https://github.com/coderabbitai/git-worktree-runner
- **要件**: Git 2.17+, Bash 3.2+, Claude Code インストール済み

## なぜ Docker ではなく gtr か

| 観点 | Docker | gtr |
|------|--------|-----|
| セットアップ | Dockerfile + compose + ビルド | `npm i -g git-worktree-runner` |
| 起動 | コンテナ起動 ~数秒 | ほぼ即時（ディレクトリ作成のみ） |
| リソース | コンテナ分のオーバーヘッド | ほぼゼロ |
| Windows パス | MSYS 変換が必要 | ネイティブ、問題なし |
| 状態分離 | ボリュームマウントで分離 | ワークツリーごとに自動分離 |
| 環境分離 | 完全（別プロセス空間） | なし（同一ホスト） |

**トレードオフ**: gtr はプロセス分離がない。ただし Forge Harness のユースケースでは
各ワークツリーが独立した `.forge/state/` を持つため、状態衝突は発生しない。

## インストール

```bash
npm install -g git-worktree-runner

# 確認
git gtr --version
git gtr doctor          # 環境チェック（git, claude 等の検出）
```

## 初期設定

### シェル統合（`cd` サポート）

```bash
# ~/.bashrc または ~/.zshrc に追加
eval "$(git gtr init bash)"    # bash の場合
eval "$(git gtr init zsh)"     # zsh の場合
```

これにより `gtr cd <branch>` でワークツリーに直接移動できるようになる。

### チーム設定（`.gtrconfig`）

Forge Harness リポジトリのルートに `.gtrconfig` を作成:

```ini
[gtr]
    defaultAI = claude

[gtr "copy"]
    # ワークツリー作成時に自動コピーするファイル
    pattern = .env
    pattern = .forge/config/development.json

[gtr "hook"]
    # ワークツリー作成後に自動実行
    postCreate = echo "Worktree ready: $(pwd)"
```

> **注意**: `.env` や API キーを含むファイルは `.gitignore` に入れたまま、
> `.gtrconfig` の `copy.pattern` で新しいワークツリーにコピーする。

## 基本ワークフロー

### 1. プロジェクト用ワークツリーの作成

```bash
# Forge Harness リポジトリで実行
cd ~/Desktop/forge-research-harness-v1

# プロジェクトごとにブランチ+ワークツリーを作成
git gtr new project/fortune-app
git gtr new project/x-auto-agent
git gtr new project/new-saas
```

ワークツリーは親ディレクトリに作成される:
```
Desktop/
├── forge-research-harness-v1/          # メインリポジトリ（ハーネス開発用）
├── forge-research-harness-v1-project-fortune-app/    # ワークツリー A
├── forge-research-harness-v1-project-x-auto-agent/   # ワークツリー B
└── forge-research-harness-v1-project-new-saas/       # ワークツリー C
```

### 2. ワークツリーごとのセットアップ

```bash
# ワークツリーに移動
gtr cd project/fortune-app

# development.json をプロジェクトに合わせて編集
# （.gtrconfig の copy.pattern でコピー済みならベースは揃っている）
vi .forge/config/development.json
# → server.start_command, server.health_check_url を設定
```

### 3. Forge Harness の実行

```bash
# 方法 A: gtr ai で Claude Code を起動し、対話的に /sc:forge
git gtr ai project/fortune-app

# 方法 B: ワークツリー内で直接 forge-flow を実行
gtr cd project/fortune-app
bash .forge/loops/forge-flow.sh "占いサービス" "Alpine.js + Hono" --daemonize

# 方法 C: gtr run でコマンドを直接実行
git gtr run project/fortune-app -- bash .forge/loops/forge-flow.sh "テーマ" "方向性" --daemonize
```

### 4. 並列実行（複数プロジェクト同時）

```bash
# 各ワークツリーで forge-flow を daemonize で起動
git gtr run project/fortune-app   -- bash .forge/loops/forge-flow.sh "テーマA" "方向性A" --daemonize
git gtr run project/x-auto-agent  -- bash .forge/loops/forge-flow.sh "テーマB" "方向性B" --daemonize

# 進捗監視（別ターミナルで）
git gtr run project/fortune-app   -- tail -f .forge/state/forge-flow.log
git gtr run project/x-auto-agent  -- bash .forge/loops/dashboard.sh
```

### 5. 完了後のクリーンアップ

```bash
# 個別削除
git gtr rm project/fortune-app

# マージ済みブランチのワークツリーを一括削除（GitHub CLI 必要）
git gtr clean --merged

# 一覧確認
git gtr list
```

## 状態分離の仕組み

git worktree では各ワークツリーが独立したワーキングツリーを持つ。
`.git/` ディレクトリのみが共有される。

```
メインリポジトリ (.git/ を保持)
  └── .git/worktrees/
        ├── project-fortune-app/     # ワークツリー参照
        └── project-x-auto-agent/    # ワークツリー参照

ワークツリー A (独立したファイルツリー)
  ├── .forge/state/          ← 独立（task-stack.json 等が競合しない）
  ├── .forge/config/         ← 独立（development.json をプロジェクト別に設定可）
  ├── .forge/logs/           ← 独立
  ├── .docs/research/        ← 独立（リサーチ結果が混ざらない）
  └── ...

ワークツリー B (独立したファイルツリー)
  ├── .forge/state/          ← 独立
  ├── .forge/config/         ← 独立
  └── ...
```

`concurrent-execution-design.md` で指摘されていた `.forge/state/` の衝突問題は、
ワークツリーを使うことで**設計変更なしに自動的に解決される**。

## 注意事項

### ブランチ管理

- ワークツリーはブランチと 1:1 対応。同じブランチを複数のワークツリーで使えない
- プロジェクト用ブランチは `project/` プレフィックスで統一すると管理しやすい
- メインリポジトリ（master）はハーネス開発専用に保つ

### コミットとマージ

- 各ワークツリーのコミットはすべて同一リポジトリの履歴に入る
- プロジェクト成果物をハーネスに混ぜたくない場合は **orphan ブランチ** を使う:
  ```bash
  git checkout --orphan project/isolated-app
  git rm -rf .
  # → このブランチは master と履歴を共有しない
  git gtr new project/isolated-app   # 既存ブランチからワークツリー作成
  ```

### --work-dir との使い分け

| 方式 | 用途 |
|------|------|
| gtr ワークツリー | ハーネスごとプロジェクトを分離（推奨） |
| `--work-dir` | ハーネスは1つ、作業先だけ変える（状態共有リスクあり） |
| Docker | 完全なプロセス分離が必要な場合（CI/CD、他人の環境等） |

### Windows 固有

- ワークツリーのパスにスペースや日本語を含めない
- シンボリックリンクの権限が必要な場合がある（Developer Mode を有効にする）
- Git Bash の `eval "$(git gtr init bash)"` は `.bashrc` に追加

### リソース管理

- `--daemonize` した forge-flow はホストプロセスとして動作する
- 並列数はマシンスペックと API レートリミットに依存
- 同時に 2-3 プロジェクトが現実的な上限（Anthropic API の並列制限）

## コマンドリファレンス（よく使うもの）

```bash
# === ワークツリー管理 ===
git gtr new <branch>              # 作成
git gtr list                      # 一覧
git gtr rm <branch>               # 削除
git gtr clean --merged            # マージ済み一括削除
gtr cd <branch>                   # 移動（シェル統合必要）

# === 実行 ===
git gtr ai <branch>               # Claude Code を起動
git gtr ai <branch> -- -p "cmd"   # Claude Code にプロンプトを渡す
git gtr run <branch> -- <cmd>     # 任意コマンドを実行
git gtr editor <branch>           # エディタで開く

# === 設定 ===
git gtr config list               # 設定一覧
git gtr doctor                    # 環境診断

# === 進捗監視（gtr run 経由） ===
git gtr run <branch> -- bash .forge/loops/dashboard.sh
git gtr run <branch> -- tail -f .forge/state/forge-flow.log
git gtr run <branch> -- jq '.tasks[] | {task_id, status}' .forge/state/task-stack.json
```

## Docker からの移行手順

1. `npm install -g git-worktree-runner`
2. シェル統合を設定（`.bashrc` に `eval` 追加）
3. 既存の Docker インスタンスを停止: `./forge-docker.sh stopall`
4. プロジェクトごとにワークツリーを作成: `git gtr new project/<name>`
5. `development.json` をプロジェクトに合わせて編集
6. `git gtr ai project/<name>` で Claude Code を起動し作業開始

Docker 関連ファイル（`Dockerfile`, `docker-compose.yml`, `forge-docker.sh`, `docker-entrypoint.sh`）は
gtr 移行後も残しておいて問題ない（CI/CD やリモート環境では引き続き有用）。
