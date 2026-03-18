# ブラウザ自動化リサーチ (2026-03-08)

調査対象: MoneyPrinterV2、x-auto-agent、および x-auto-agent を上回るブラウザ自動化リポジトリ群

---

## 1. MoneyPrinterV2 概要

**GitHub:** https://github.com/FujiwaraChoki/MoneyPrinterV2

| 項目 | 詳細 |
|------|------|
| Stars | ~14,900+ |
| Forks | ~1,500+ |
| 言語 | Python 95.7%, Shell 4.3% |
| ライセンス | AGPL-3.0 |
| Python要件 | 3.12 必須 |
| コミット数 | 107 (main) |
| 貢献者 | 14人 |
| 最終更新 | 2026-03-03（supply chain 脆弱性修正） |

### 4つの主要機能

1. **YouTube Shorts 自動生成** — LLM スクリプト生成 → AI 画像生成 → TTS → MoviePy 動画組立 → 字幕 → YouTube アップロード
2. **Twitter Bot** — CRON スケジューリング、アカウント管理、自動ツイート
3. **Affiliate Marketing** — Amazon アフィリエイト連携、Twitter 配信、ピッチ自動生成
4. **Local Business Outreach** — Google Maps スクレイピング → SMTP コールドメール

### アーキテクチャ

```
src/
├── main.py           # CLI メニューインターフェース（5択メニュー）
├── classes/
│   ├── YouTube.py    # YouTube Shorts 自動化
│   ├── Twitter.py    # Twitter Bot
│   ├── Tts.py        # Text-to-Speech
│   ├── AFM.py        # Affiliate Marketing
│   └── Outreach.py   # ビジネスアウトリーチ
├── llm_provider.py   # LLM モデル選択（Ollama/GPT-4/GPT-3.5）
├── config.py         # 設定読込
├── utils.py          # ユーティリティ
├── cache.py          # キャッシュ管理
├── cron.py           # スケジューリング
├── constants.py      # 定数
├── status.py         # ステータス管理
└── art.py            # ASCII アート表示
```

### 外部依存・API

| カテゴリ | サービス/ライブラリ |
|----------|---------------------|
| LLM | Ollama（ローカル）, Google Generative AI |
| 画像生成 | Prodia（AI画像モデル） |
| TTS | KittenTTS (v0.8.1) |
| STT | AssemblyAI, faster-whisper (Whisper ローカル) |
| 動画編集 | MoviePy, Pillow, ImageMagick |
| 字幕 | srt_equalizer |
| ブラウザ自動化 | Selenium, undetected_chromedriver, webdriver_manager |
| メール | yagmail (SMTP) |
| スクレイピング | Google Maps Scraper |

### 設定（config.json）の主要キー

- `ollama_base_url` / `ollama_model` — ローカル LLM
- `nanobanana2_api_key` — Google Generative AI
- `firefox_profile` — YouTube ログイン用
- `tts_voice` — TTS 音声選択
- `assembly_ai_api_key` — STT 用
- `imagemagick_path` — 動画処理
- `threads` — マルチスレッド数
- `is_for_kids` — YouTube コンテンツ分類
- SMTP 設定（メールアウトリーチ用）

---

## 2. MoneyPrinterV2 技術評価

### 総合: C+ (実用プロトタイプレベル)

### 各カテゴリ評価

| カテゴリ | 評価 | コメント |
|---------|------|---------|
| アイデア・コンセプト | **A** | 自動収益化パイプラインとして市場ニーズを捉えている |
| アーキテクチャ | **B-** | モジュール分割はあるが CLI 設計が古い |
| 依存関係管理 | **D** | ピンなし・非標準依存・lockfile なし |
| テスト・CI | **F** | ゼロ |
| セキュリティ | **D+** | 平文認証・TOS 違反リスク・サプライチェーン既出 |
| ドキュメント | **C-** | 最低限の README のみ |
| メンテナンス | **B** | 直近でアクティブに修正中 |

### 依存関係管理の問題（最も深刻）

- `requirements.txt` の大半がバージョン未指定 → 環境再現不可
- `kittentts` が GitHub の直接 wheel URL 指定 — PyPI 外で脆弱
- 2026-03-03 に supply chain poisoning vulnerability を修正 — 外部 ZIP が攻撃対象に
- Issue の大半が `ModuleNotFoundError` / `ImportError` — MoviePy、distutils 等のバージョン不整合
- lockfile（`poetry.lock` / `pip-compile`）不在

### テスト・CI

- テストファイルが存在しない（`tests/` ディレクトリなし）
- 14 件の Open Issue のほぼ全てが「動かない」系

### セキュリティ

- `config.json` に API キー・SMTP パスワードを直書き（`.env` 未対応）
- YouTube アップロードが Selenium + `undetected_chromedriver` — YouTube TOS 違反リスク
- Firefox プロファイルパスを設定ファイルに記載 — 漏洩時にセッション乗っ取り可能
- Songs.zip を外部 URL から取得 → サプライチェーン脆弱性として顕在化済み

### Issue パターン分析（Open 14件）

```
依存関係・インストール不具合   ████████  6件 (43%)
ブラウザ自動化の破損          ███       3件 (21%)
外部サービス停止             ██        2件 (14%)
ランタイムエラー             ██        2件 (14%)
機能要望                    █         1件 (7%)
```

---

## 3. MoneyPrinterV2 ブラウザ自動化評価

### YouTube アップロード — D

**実装方式:** Selenium + Firefox プロファイル（ログイン済み）でブラウザ操作

```
ログイン済みFirefoxプロファイル読込
  → youtube.com/upload を開く
  → ファイルピッカーにパス送信
  → title/description テキストボックスに入力
  → 「次へ」ボタン3回クリック
  → 公開設定 → 完了
```

| 問題 | 深刻度 | 詳細 |
|------|--------|------|
| YouTube API 未使用 | 高 | YouTube Data API v3 が公式手段。ブラウザ自動化は TOS 違反で BAN 対象 |
| DOM セレクタ依存 | 高 | `ytcp-uploads-file-picker`、`ytcp-video-row` — YouTube UI 変更で即壊れる |
| 認証なし | 中 | ログインロジックがゼロ。セッション切れで完全停止 |
| anti-detection ゼロ | 高 | UA変更なし、遅延ランダム化なし、proxy なし、viewport 固定 |
| エラーハンドリング | 高 | bare `except:` で全例外握りつぶし → `return False` のみ |
| ハードコード `time.sleep()` | 中 | 固定待機。ネットワーク遅延に非適応 |

### Twitter 投稿 — D+

```
ログイン済みFirefoxプロファイル読込
  → x.com/compose/post を開く
  → テキストエリアに send_keys()
  → 投稿ボタンをクリック
```

- X/Twitter API v2 未使用
- セレクタのカスケード式フォールバック（2-3段階）— UI 変更への応急処置的対応
- `time.sleep(2)` 固定

### Google Maps Outreach — C+（相対的に最もまとも）

```
Go scraper バイナリをDL・ビルド
  → niche指定でスクレイピング実行（timeout 300秒）
  → CSV出力をパース → メールアドレスを正規表現抽出 → yagmail で送信
```

- 外部ツール委譲で責務分離（良）
- ZIP 展開時のパストラバーサル防止（良）
- subprocess タイムアウト制御（良）
- Go 依存で環境構築ハードル高（弱）

### 横断的な構造問題

1. **公式 API を使わない設計** — TOS 違反 + 脆弱なスクレイパーの組み合わせ
2. **Firefox プロファイル前提の認証** — セッション管理なし、2FA/CAPTCHA 未対応
3. **anti-detection の完全欠如** — UA ローテーション、リクエスト間隔ランダム化、Proxy、Canvas/WebGL 対策、Headless 検出回避、Cookie 管理 — 全て未実装
4. **`undetected_chromedriver` が requirements にあるが未使用** — Firefox + 通常 Selenium を使用

---

## 4. x-auto-agent 概要

**パス:** `C:\Users\bossbot1000tdump\Desktop\x-auto-agent`

AI 駆動の X(Twitter) 自動化 CLI ツール。Claude Sonnet 4 でツイート生成し、Patchright でブラウザ自動化。

### ステージ構成

- Stage 1 (MVP): 手動ツイート生成・投稿 ✓
- Stage 2 (Scheduler): スケジュール自動投稿 ✓
- Stage 3 (Multi-account): 複数アカウント管理 ✓
- Stage 4 (Auto-engagement): モニタリング・リプライ・DM ✓

### アーキテクチャ

```
x-auto-agent/
├── src/
│   ├── main.js              # CLI エントリ
│   ├── agent.js             # ツイート生成 (Claude Agent SDK)
│   ├── reply-agent.js       # リプライ生成
│   ├── dm-agent.js          # DM 生成
│   ├── browser.js           # Patchright 自動化 (1,536行)
│   ├── browser-pool.js      # マルチアカウント管理
│   ├── account.js           # アカウント設定 + env 解決
│   ├── scheduler.js         # Cron スケジューリング
│   ├── monitor.js           # タイムライン監視
│   ├── engagement.js        # エンゲージメント制御
│   ├── selectors.js         # DOM セレクタ定義（集中管理）
│   └── stealth.js           # Anti-detection ユーティリティ
├── config/
│   ├── settings.yaml        # グローバル設定
│   ├── accounts.yaml        # アカウント定義
│   ├── schedules.yaml       # Cron スケジュール
│   ├── engagement.yaml      # 監視ポリシー
│   └── sessions/            # セッション保存 (git-ignored)
├── data/                    # 状態永続化
├── logs/                    # 実行ログ
├── tests/                   # テスト（限定的）
├── .docs/                   # 設計ドキュメント・ADR
├── .env / .env.example      # シークレット管理
├── package.json / package-lock.json
└── ecosystem.config.js      # PM2 設定
```

### 依存関係（Production: 5パッケージのみ）

```json
{
  "@anthropic-ai/claude-agent-sdk": "^0.1.0",
  "dotenv": "^17.2.3",
  "node-cron": "^4.2.1",
  "patchright": "^1.57.0",
  "yaml": "^2.3.0"
}
```

---

## 5. MoneyPrinterV2 vs x-auto-agent 比較

### 総合評価

| | MoneyPrinterV2 | x-auto-agent |
|---|---|---|
| 総合 | **C+** | **B+** |
| 目的 | 多チャンネル収益自動化 | X(Twitter) 特化 |
| 規模 | Python ~2,000行 / 9モジュール | Node.js ~5,868行 / 12モジュール |

### ブラウザ自動化比較

| 観点 | MoneyPrinterV2 (D) | x-auto-agent (A-) |
|------|-------|--------|
| ライブラリ | Selenium + Firefox | Patchright（Playwright fork、anti-detection 内蔵） |
| UA 偽装 | なし | 固定だが現実的な Chrome UA + locale/timezone 一致 |
| 入力模倣 | `send_keys()` 一括 | `humanType()` 1文字ずつ 50-150ms ランダム間隔 |
| クリック模倣 | `.click()` | `humanClickElement()` バウンディングボックス内ランダムオフセット |
| マウス挙動 | なし | ベジェ曲線 5-15ステップ |
| スクロール | なし | `humanScroll()` ステップ分割 + ランダム遅延 |
| 待機戦略 | `time.sleep()` 固定 | `randomDelay(min, max)` ランダム |
| SlowMo | なし | 50ms/操作 |
| Headless検出 | 考慮なし | Patchright 内部対策済み |

### セレクタ戦略比較

| 観点 | MoneyPrinterV2 | x-auto-agent |
|------|-------|--------|
| 管理方式 | コード内ハードコード | `selectors.js` 集中管理 |
| フォールバック | Twitter のみ 2-3 段階 | 全操作で3段階（data-testid → role → contenteditable） |
| 安定性 | YouTube `ytcp-*` 内部タグ依存 | `data-testid` 優先（比較的安定） |

### 認証・セッション管理比較

| 観点 | MoneyPrinterV2 (D) | x-auto-agent (B+) |
|------|-------|--------|
| 方式 | Firefox プロファイルパス平文 | auth_token Cookie インジェクション + セッション永続化 |
| セッション切れ | 対応なし | 自動検出 → 手動ログインフォールバック → 新トークン表示 |
| 永続化 | なし | `storageState()` で Cookie/localStorage を JSON 保存 |
| マルチアカウント | なし | `accounts.yaml` + `BrowserPool` |
| 認証情報保護 | config.json 平文 | .env + ログ内マスク |

### エラーハンドリング比較

| 観点 | MoneyPrinterV2 (D-) | x-auto-agent (B) |
|------|-------|--------|
| 例外処理 | bare `except:` → `return False` | 構造化 try/catch + エラー種別別処理 |
| リトライ | なし | 3回リトライ、30分間隔 |
| メモリ管理 | なし | heapUsed 400MB 超で自動再起動 |
| セッション寿命 | 管理なし | 6時間で自動再起動 |
| デバッグ支援 | なし | エラー時スクリーンショット自動保存 |
| 連続エラー制御 | なし | `consecutive_error_threshold: 3` で自動停止 |
| シャットダウン | なし | SIGINT/SIGTERM ハンドリング |

### 全カテゴリ比較表

| カテゴリ | MPV2 | x-auto-agent |
|---------|------|-------------|
| ブラウザ自動化 | D | **A-** |
| セレクタ管理 | D+ | **B+** |
| 認証・セッション | D | **B+** |
| エラーハンドリング | D- | **B** |
| アーキテクチャ | C | **A-** |
| 依存関係管理 | D | **B+** |
| セキュリティ | D+ | **B** |
| テスト | F | **C-** |
| ドキュメント | C- | **B+** |
| コンセプト | **A** | B+ |

---

## 6. x-auto-agent を上回るブラウザ自動化リポジトリ TOP 8

### x-auto-agent の現状（比較基準 = 3）

| 評価軸 | x-auto-agent の現状 |
|--------|-------------------|
| Anti-detection | Patchright（Playwright JS レイヤーパッチ） |
| 人間挙動模倣 | Bezier曲線 5-15ステップ、ランダムオフセットクリック |
| フィンガープリント管理 | Patchright デフォルト（固定 UA/locale/timezone） |
| CAPTCHA 突破 | なし |
| Proxy 管理 | なし |
| セレクタ自己修復 | 3段フォールバック（静的） |

---

### #1. Camoufox — 最も根本的に強い

- **GitHub:** https://github.com/daijro/camoufox
- **Stars:** 5.9K | **言語:** C++ / Python | **メンテナンス:** アクティブ

**x-auto-agent との決定的な差:** Patchright は Playwright の JS/CDP レイヤーをパッチするが、Camoufox は **Firefox の C++ ソースコード自体を改変**。JS が実行される前にフィンガープリント偽装が完了するため、JS ベースのボット検出では原理的に検出不可能。

| 評価軸 | x-auto-agent | Camoufox | 評価 |
|--------|-------------|----------|------|
| Anti-detection | JS レベル CDP パッチ | **C++ ソースレベル**。CDP が存在しない（Firefox は Juggler） | **5** |
| フィンガープリント | 固定値 | **BrowserForge 統合**: navigator/WebGL/WebRTC/screen/fonts/audio/timezone を内部整合性保って偽装 | **5** |
| 人間挙動 | Bezier (JS) | C++ レベルのマウス移動アルゴリズム内蔵 | **4** |

**弱点:** Firefox ベース → Chromium 非互換。Python ラッパーのみ（Node.js 不可）。

---

### #2. CloakBrowser — 最も移行しやすい

- **GitHub:** https://github.com/CloakHQ/CloakBrowser
- **Stars:** 205 | **言語:** C++ (Chromium fork) | **メンテナンス:** アクティブ

**x-auto-agent との決定的な差:** **Chromium 自体に 26 個の C++ パッチ**。Playwright API 互換のため、コードほぼ無変更でブラウザバイナリだけ差替可能。

| 評価軸 | x-auto-agent | CloakBrowser | 評価 |
|--------|-------------|-------------|------|
| Anti-detection | JS パッチ | **26個の C++ ソースパッチ**: Canvas/WebGL/Audio/Fonts/GPU/CDP 除去 | **5** |
| フィンガープリント | 固定 | Canvas, WebGL, AudioContext, GPU, screen, plugins — バイナリレベル | **5** |
| CAPTCHA | なし | **reCAPTCHA v3 スコア 0.9**（人間レベル）、Cloudflare Turnstile 通過 | **4** |

**最大の利点:** `npm install cloakbrowser` でドロップインリプレース。

---

### #3. Ghost Cursor — マウス挙動で圧勝

- **GitHub:** https://github.com/Xetera/ghost-cursor
- **Playwright版:** https://github.com/reaz1995/ghost-cursor-playwright
- **Stars:** 1.5K | **言語:** TypeScript | **メンテナンス:** アクティブ

**x-auto-agent との決定的な差:** x-auto-agent の Bezier 曲線は「滑らかだが機械的」。Ghost Cursor は **Fitts の法則** を実装し、遠い標的への **オーバーシュート＋修正** を自動生成。

| 挙動 | x-auto-agent | Ghost Cursor |
|------|-------------|-------------|
| 速度変化 | 一定 | **Fitts の法則**: 距離大 → 初速早く減速、標的小 → 接近時に減速 |
| オーバーシュート | なし | **遠い標的で自動発生** → 修正移動（人間の自然な挙動） |
| 軌跡対称性 | Bezier で対称になりがち | **非対称制御点**で合成感を排除 |
| ステップ数 | 固定 5-15 | **距離に応じて動的調整** |

**導入コスト:** `npm install ghost-cursor-playwright` → `stealth.js` のマウス関数を差替。

---

### #4. Botright — CAPTCHA 突破で唯一無二

- **GitHub:** https://github.com/Vinyzu/Botright
- **Stars:** 944 | **言語:** Python | **メンテナンス:** アクティブ

**x-auto-agent との決定的な差:** **無料 AI ベースの CAPTCHA 解決**。有料サービス不要、CV モデル（CLIP 等）使用。

| CAPTCHA 種別 | 成功率 |
|-------------|--------|
| hCaptcha | ~90% |
| reCAPTCHA v2 | 50-80% |
| GeeTest v3/v4 | 対応 |

| 評価軸 | x-auto-agent | Botright | 評価 |
|--------|-------------|---------|------|
| CAPTCHA | なし | **CV/AI ベース、無料** | **5** |
| フィンガープリント | 固定 | **実 Chrome からスクレイピングした本物のフィンガープリント DB** + 自動ローテーション | **4** |
| Anti-detection | Patchright | 実 Chromium + 自前フィンガープリント | **4** |

**弱点:** Python のみ。Node.js 移植が必要。

---

### #5. Stagehand — セレクタ自己修復で次世代

- **GitHub:** https://github.com/browserbase/stagehand
- **Stars:** 21.4K | **言語:** TypeScript | **メンテナンス:** アクティブ (v3.6.1, 2026-02)

**x-auto-agent との決定的な差:** 静的フォールバックではなく **LLM セマンティック要素発見**。DOM が変わっても自然言語で要素を再特定。

```typescript
// x-auto-agent: DOM変更で壊れる
await page.$('[data-testid="tweetTextarea_0"]');

// Stagehand: DOM変更に自動適応
await stagehand.act("ツイート入力欄にテキストを入力する");
```

| 評価軸 | x-auto-agent | Stagehand | 評価 |
|--------|-------------|----------|------|
| セレクタ自己修復 | 3段静的フォールバック | **LLM セマンティック発見** + キャッシュ + 自動再発見 | **5** |
| 分散実行 | なし | **Browserbase クラウド**でスケーリング | **4** |
| Anti-detection | Patchright | 特化していない | **2** |

**弱点:** Anti-detection は弱い。Browserbase クラウド依存。

---

### #6. rebrowser-patches — CDP リーク特化

- **GitHub:** https://github.com/rebrowser/rebrowser-patches
- **Stars:** 1.3K | **言語:** JS/TS | **メンテナンス:** アクティブ (2025-05)

Patchright と同じ `Runtime.Enable` リーク対策だが、**3 つのアプローチ**を環境変数で切替可能（addBinding / alwaysIsolated / enableDisable）。Patchright に上乗せして使える補完的パッチ。sourceURL 難読化 + utility world ネーミングも含む。

---

### #7. Nodriver — WebDriver 完全排除

- **GitHub:** https://github.com/ultrafunkamsterdam/nodriver
- **Stars:** 3.8K | **言語:** Python | **メンテナンス:** 中程度

WebDriver/Selenium を一切使わず **CDP 直接通信**。`navigator.webdriver` 検出を根本排除。Cloudflare バイパス関数 `tab.cf_verify()` 内蔵。

---

### #8. docker-stealthy-auto-browse — 最も偏執的

- **GitHub:** https://github.com/psyb0t/docker-stealthy-auto-browse
- **Stars:** 27 | **言語:** Python | **メンテナンス:** 2024-12

Camoufox + **PyAutoGUI による OS レベル入力シミュレーション**（Docker + Xvfb 内）。ブラウザ API を一切経由せず、OS が生成するマウス/キーボードイベントを使用。ブラウザ内 JS からは **原理的に自動化を検出できない**。

---

## 7. 総合マトリクス（1-5、x-auto-agent = 3）

| リポジトリ | Anti-detection | 人間挙動 | Fingerprint | CAPTCHA | 自己修復 | 導入容易性 |
|-----------|:-:|:-:|:-:|:-:|:-:|:-:|
| x-auto-agent (基準) | 3 | 3 | 3 | 1 | 3 | — |
| **Camoufox** | **5** | 4 | **5** | 1 | 2 | 低（Firefox/Python） |
| **CloakBrowser** | **5** | 3 | **5** | **4** | 2 | **高（ドロップイン）** |
| **Ghost Cursor** | — | **5** | — | — | — | **高（npm install）** |
| **Botright** | 4 | 3 | 4 | **5** | 2 | 低（Python） |
| **Stagehand** | 2 | 3 | 2 | 1 | **5** | 中 |
| rebrowser-patches | 4 | 3 | 3 | 1 | 2 | 高 |
| Nodriver | 4 | 2 | 2 | 1 | 2 | 低（Python） |
| docker-stealthy | **5** | **5** | **5** | 1 | 2 | 低（Docker必須） |

---

## 8. x-auto-agent への推奨統合（コスト対効果順）

| 優先度 | 対象 | 効果 | 工数 |
|--------|------|------|------|
| **1** | **CloakBrowser** | ブラウザバイナリ差替のみで anti-detection 劇的向上、reCAPTCHA 0.9 | 低 |
| **2** | **Ghost Cursor** | `stealth.js` のマウス関数差替。Fitts 法則 + オーバーシュート | 低 |
| **3** | **Stagehand 概念** | セレクタ発見に LLM 導入、X の UI 変更に自動適応 | 中 |
| **4** | **Botright 概念** | CAPTCHA 突破の CV/AI アプローチを移植 | 中〜高 |
| **5** | **Camoufox** | 最高セキュリティ標的向けに Firefox ベースの代替パス | 高 |

**最小工数で最大効果:** CloakBrowser + Ghost Cursor の 2 つで「良い」→「ほぼ検出不能」へ跳躍可能。

---

## Sources

- [MoneyPrinterV2](https://github.com/FujiwaraChoki/MoneyPrinterV2)
- [Camoufox](https://github.com/daijro/camoufox)
- [CloakBrowser](https://github.com/CloakHQ/CloakBrowser)
- [rebrowser-patches](https://github.com/rebrowser/rebrowser-patches)
- [Botright](https://github.com/Vinyzu/Botright)
- [Stagehand](https://github.com/browserbase/stagehand)
- [Ghost Cursor](https://github.com/Xetera/ghost-cursor)
- [ghost-cursor-playwright](https://github.com/reaz1995/ghost-cursor-playwright)
- [Nodriver](https://github.com/ultrafunkamsterdam/nodriver)
- [docker-stealthy-auto-browse](https://github.com/psyb0t/docker-stealthy-auto-browse)
- [AI Sharing Circle - MoneyPrinterV2](https://aisharenet.com/en/moneyprinterv2/)
- [AI Productivity Tools - MoneyPrinterV2](https://www.kdjingpai.com/en/moneyprinterv2/)
