# セッション総括 2026-03-26

## 実施内容

本セッションでは2つの主要作業を実施した。

1. **x-auto-agent 自律性強化の全Phase実装**
2. **forge ハーネスの開発ワークフロー改善検討**

---

## 1. x-auto-agent 自律エージェント化

### 背景

x-auto-agent は「スケジュール駆動のツイート自動投稿ツール」だった。YAMLに書かれた時間・テーマに従い機械的に投稿するだけで、自律的な判断能力がなかった。目標は「一人の人間が目的と軸を持ちながら多様な動きをする」エージェントへの変革。

### 設計判断（壁打ちで確定済み）

- dot-automationの設計思想を参考にしつつ、x-auto-agent上で独自実装
- 軸の定義は「メタフレーム資料」（ペルソナ + 運用戦略の統合MD文書）
- 知識源はタイムライン + トレンド + 外部情報（RSS、ニュースAPI、メモ等）
- ブラウザ自動化ベース（Patchright）を維持（API不要の強みを活かす）
- DECIDE（行動選択）とGENERATE（内容生成）は2回のAPI呼び出しに分離
- トピック分類はDECIDEの出力に含めることで追加コストなし

### 実装した全Phase

#### Phase 0: 基盤（メタフレーム + メモリ）

| ファイル | 内容 |
|---|---|
| `src/metaframe.js` | MD形式のペルソナ定義を読み込み、システムプロンプトに注入 |
| `config/metaframe.md` | テンプレート。セクション: 私は誰か / 軸 / 話し方 / 興味 / やらないこと / 目的 / ターゲット |
| `src/memory.js` | 2層記憶。短期(JSONL 50件ローテ) + 長期(JSON: トピック疲労、関係性、エンゲージメントスコア、日次サマリー) |
| `config/settings.yaml` | `autonomy`セクション追加（energy_curve、日次上限、最小間隔、ループ間隔） |
| `src/agent.js` | メタフレーム + メモリ + 外部情報のコンテキスト注入。`generateContent()`汎用生成API追加 |

**メモリ設計のポイント:**
- トピック疲労: 投稿時 +0.2、時間経過 -0.1/時間、0.7超でプロンプト警告
- 関係性: replied/liked レコードから日次集約、30日未インタラクションで自動削除
- 日次サマリー: 90日で自動削除

#### Phase 1: 認知ループ（コア自律性）

| ファイル | 内容 |
|---|---|
| `src/cognitive-loop.js` | 7段階ループ: PERCEIVE → REMEMBER → DECIDE → GENERATE → ACT → REFLECT → SLEEP |
| `src/scheduler.js` | 認知ループのラッパーに改修。デフォルトで認知ループモード、`--legacy`で従来cron駆動 |

**認知ループの動作:**
1. **PERCEIVE** — timeline-reader + knowledge-sources から外部情報取得
2. **REMEMBER** — memory.js から直近10件 + トピック疲労 + 関係性を取得
3. **DECIDE** — Claude API 1回目。行動メニュー（post_thought / reply / quote_tweet / like / browse / rest）から選択。出力にtopicフィールド含む
4. **GENERATE** — Claude API 2回目。選んだ行動のコンテンツを生成
5. **ACT** — browser.js経由で実行
6. **REFLECT** — memory.jsに結果記録、トピック疲労更新、関係性記録
7. **SLEEP** — ガウス分布の自然な間隔（エネルギーカーブに基づく）

**安全装置（ハード制限）:**
- DECIDEでLLMが投稿系アクションを選んでも、日次上限到達時・最小間隔未達時は強制的にrestに変更
- `data/{account}/pause` ファイルで即時停止（キルスイッチ）
- 監査ログ `data/{account}/actions.jsonl` に全判断根拠を記録

#### Phase 2: 知覚システム

| ファイル | 内容 |
|---|---|
| `src/timeline-reader.js` | ホームTLスクレイプ（直近20ツイート + トレンド）。5分メモリキャッシュ + ファイルキャッシュフォールバック |
| `src/knowledge-sources.js` | RSS / ローカルファイル / Web APIのプラグイン式情報取得。簡易RSSパーサー内蔵（依存なし） |
| `config/sources.yaml` | 外部情報ソース定義テンプレート |
| `src/engagement.js` | 認知ループ統合メソッド追加（`executeReplyFromLoop`, `executeLikeFromLoop`） |

#### Phase 3: 適応行動（学習）

| ファイル | 内容 |
|---|---|
| `src/analytics.js` | 6時間ごとにブラウザで直近ツイートのエンゲージメント指標を収集 → 長期記憶の engagement_scores を更新 |

**指標:** likes * 2 + retweets * 3 + replies * 1.5 のスコアをトピック別に移動平均で蓄積。

#### Phase 4: ステルス強化

| ファイル | 変更内容 |
|---|---|
| `src/stealth.js` | ガウス分布遅延（uniform→gaussian）、タイポ注入（5%確率で隣接キー誤入力→修正）、ベジェ曲線マウス移動、`browseNaturally()`（30-120秒の自然な閲覧セッション） |

### レビューで発見・修正した不備

実装後の精査で以下5点を発見し修正:

1. **日次上限・最小間隔のハード制限が欠如** — LLMの判断をプロンプトで頼んでいるだけで、無視されたら投稿が通る状態だった。DECIDE後にオーバーライドする安全装置を追加。
2. **`startPeriodicAnalytics()`の呼び出し漏れ** — analytics.jsに関数はあるが、cognitive-loop.jsから起動されていなかった。ループ開始時に起動、シャットダウン時に停止するよう修正。
3. **未使用import** — cognitive-loop.jsで`generateTweet`, `generateQuoteTweet`, `buildMetaframePrompt`がimportされたまま未使用。削除。
4. **`perception.trends`の型不整合** — timeline-readerが`string[]`を返すが、decide()のプロンプトに文字列として注入していた。`join(", ")`で明示的に文字列化。
5. **engagement.jsのクラス構文エラー** — 認知ループ統合メソッドがクラスの閉じ括弧の外に配置されていた。クラス内に移動。

### CLIの変更

| コマンド | 内容 |
|---|---|
| `npm run agent` | 認知ループ開始（新デフォルト） |
| `npm run agent:dry` | ドライラン（実際の投稿なし） |
| `npm run scheduler` | レガシーcronモード（`--legacy`付き） |
| `node src/scheduler.js --account <id>` | アカウント指定 |

### コミット

- `de96771` — 16 files changed, +2615/-281 lines
- `main`ブランチにプッシュ済み

---

## 2. forge ハーネスの開発ワークフロー改善

### 課題

ハーネス自体の改修中に破壊してしまうリスクがあり、コンテナで作業しようとしていたが、ハーネスの更新頻度が高く、毎回コンテナを再構築するのは非効率。

### 検討した選択肢

| 手法 | メリット | デメリット |
|---|---|---|
| **Git worktree（素）** | コンテナ不要、数秒で再構築 | npm install等は手動 |
| **Docker + volume mount** | 完全隔離 | セットアップ重い、ブラウザ操作に不向き |
| **Dev Containers (Cursor拡張)** | IDE統合 | 拡張機能の追加インストール必要、リビルドコスト |
| **git-worktree-runner (gtr)** | worktreeの利便性を大幅向上 | 追加ツールのインストール必要 |

### 結論: git-worktree-runner (gtr) を採用

`coderabbitai/git-worktree-runner` は素のgit worktreeを以下の点で改善する:

- **簡略コマンド**: `git gtr new dev1` で作成、`git gtr rm dev1` で削除
- **postCreateフック**: worktree作成時に `npm install` 等を自動実行
- **エディタ統合**: `--editor` でCursorが自動で開く
- **AI統合**: `--ai claude` でClaude Codeと連携
- **`.gtrconfig`**: 設定をリポジトリに含められる（チーム共有可能）
- **シェル補完**: Bash/Zsh/Fish対応

### 推奨セットアップ手順

```bash
# 1. gtrインストール（Git Bash上で）
git clone https://github.com/coderabbitai/git-worktree-runner.git
cd git-worktree-runner
./install.sh

# 2. forgeリポジトリで初期設定
cd /path/to/forge
git gtr config set gtr.editor.default cursor
git gtr config add gtr.hook.postCreate "pnpm install"

# 3. 日常の使い方
git gtr new dev1              # 作業コピー作成 → pnpm install自動 → Cursor起動
# 壊したら:
git gtr rm dev1 --force       # 削除
git gtr new dev1              # 数秒で再作成

# 4. 成果のプッシュ（worktree内で通常のgit操作）
cd /path/to/dev1
git add -A && git commit -m "fix: ..."
git push origin dev1-branch
```

### 運用上の注意

- 同じブランチを複数のworktreeで同時チェックアウトできない → ブランチを分ける
- worktreeはリポジトリの`.git`を共有する → コミット履歴は共通
- `git worktree list` で全worktreeの状態を確認可能
- 不要になったworktree情報は `git worktree prune` で掃除

---

## 次のアクション

### x-auto-agent

1. `config/metaframe.md` を実際のアカウントに合わせてカスタマイズ
2. `npm run agent:dry` で認知ループのドライラン → 行動選択ログで判断の質を検証
3. 数日稼働後、`data/{account}/memory-long.json` でトピックローテーション・エンゲージメントスコア蓄積を確認

### forge

1. git-worktree-runner をローカルにインストール
2. `.gtrconfig` をforgeリポジトリに追加してコミット（`postCreate: "pnpm install"`）
3. 改修作業は `git gtr new` で作ったworktreeで実施する運用に移行
