# kindle-extract 実戦投入レベル化 リサーチ最終レポート

- **テーマ**: kindle-extract を実戦投入レベルに引き上げる (Kindle 取込 UX + OCR/本文品質)
- **リサーチ ID**: 2026-05-17-280464-113255
- **生成日**: 2026-05-17
- **モード**: validate（ロックされた決定事項 9 項目を前提に深掘り）
- **判定**: **GO（条件付き）** — 既知リスクの多層防御を前提として実装に進む

---

## 1. エグゼクティブサマリー

6 視点（technical / cost / risk / alternatives / ux_skill_integration / measurement_and_acceptance）の統合により、**ロック範囲内で「実用読書レベル」(CER<2% / 章ズレ<5% / 修正<30 分) 達成の道筋は明確**であることが確認された。意思決定に効く核となる結論は以下の 3 点。

| 層 | 推奨アプローチ | 主な根拠 |
|---|---|---|
| **Claude Code 統合** | Monitor ツール (v2.1.98+) + Python が `progress.json` をアトミック書込みする **push 型シグナリング**。サブコマンド 4 分割 (`/sc:kindle:start/:status/:resume/:result`) を **task 型**で配置 | UX/技術/コスト全視点で一致。tail -f や毎ターン評価型 reference スキルは破綻リスクが高い |
| **OCR/補正パイプライン** | PaddleOCR PP-OCRv5 (300DPI + バイラテラル + CLAHE + deskew + 固定座標クロップ) → 段落束ねで 10 ページ/Task の **ハイブリッド LLM 補正** → Markdown | 純 vision-LLM 比 60-70% トークン削減、Max5 サブスクで 200 頁を 20 Task で完走可能 |
| **品質ゲート** | jiwer/dinglehopper で **CER (文字単位)** 計測、L2 fixture (青空文庫縦書き 10-20 ページ) で **fail-fast**、章ズレは「章タイトル F1 + 章数差分」の複合指標 | 日本語は単語境界がなく WER 不適、L2 で前倒し検出することで Phase 2 ロールバック判断が自動化可能 |

横断的に押さえるべき**重大リスク 4 件**:

1. **Claude Code Bash ツール SIGTERM 伝播バグ (Issue #45717 未修正)** — 長時間処理がセッションごと吹き飛ぶ
2. **Kindle for PC アップデートによる Legacy 仕様破壊** (2025 年に 3 件の前例あり)
3. **phash 単独によるページめくり判定の脆弱性**
4. **consent ゲートの自動 'YES' 化リスク**

いずれも既知の緩和策が存在するため、多層防御を実装すれば残存リスクは中程度。

---

## 2. 視点別の主要発見

### 2.1 technical — 技術的実現性

| 論点 | 結論 | confidence |
|---|---|---|
| Claude スキル × Python 長時間パイプライン | Monitor ツール（割り込み駆動）+ JSON 状態ファイル + tail -F が最も安定。ポーリングはトークン消費過大で非推奨 | high |
| PaddleOCR 前処理 | 300 DPI + バイラテラル/CLAHE + deskew + PP-OCRv5_server_det/rec、信頼度 det_db_thresh=0.2〜0.3 | high |
| ヘッダ/フッタ除去 | **OCR 前の固定座標クロッピング**が Kindle for PC Legacy の一貫レイアウトには最堅牢 | high |
| 章検出 | TOC ナビ > 大きいフォント検出 + 見出しヒューリスティック > LLM (エッジケース限定) の 3 層構成。スクリーンショット起点なので TOC は限定的 | medium |
| ルビ記法 | HTML `<ruby>` タグが最広互換だが Markdown 標準は未確立。**独自 `{本文|ルビ}` 記法 + Pandoc 変換**が現実解 | medium |
| Resume 状態 | **JSON (軽量メタ) + SQLite (OCR キャッシュ・phash・MD 中間) のハイブリッド**。LangGraph SqliteSaver が検証済みパターン | high |
| ページめくり失敗判別 | **phash (imagehash) + ノンブル OCR + 連続一致カウンタ**の多重シグナリング、Hamming 距離 <5〜10 で同一判定 | high |
| LLM 補正粒度 | **段落単位 (日本語 ~100 OCR ワード / ~300 サブワード)**、オーバーラップウィンドウ付与 | high |

### 2.2 cost — コスト・リソース

- **サブスクリプション試算**: 各 Task サブエージェントは独立 200K トークン、20 Task × 10 ページ = ~30K トークン/Task。**Max5 ($100/月) でギリギリ、Max20 ($200/月) で余裕**。ローカル OCR → LLM 補正のハイブリッドで純 vision-LLM 比 60-70% 削減
- **PaddleOCR スループット**: 最適化 CPU (Intel Xeon) で ~3.74 秒/ページ、最悪 (Windows i7) で ~60 秒/ページ。**30 分で 200 ページ = 9 秒/ページ要求**なので CPU 環境では 4-8 スレッド並列が現実的
- **SQLite OCR キャッシュ**: 200 ページ規模で <5MB、小 BLOB (<14KB) ではファイルシステム比 35% 高速。問題なし
- **CI fixture**: JPEG 圧縮 10-20 サンプルで ~2-8MB、L1+L2 合計 3-12 分
- **L3 人手検証**: 10% サンプリング (20 ページ) CER + 章見出し全確認 + 自動 diff の組合せで 60 分以内が実現可能
- **進捗 I/O コスト**: 200 行の JSON 書込みは LLM 待ち時間比 100-1000 倍小さく、ボトルネックにならない

### 2.3 risk — リスク・失敗モード

| リスク | 緩和策 | severity |
|---|---|---|
| Claude Code Bash SIGTERM 伝播バグ (Issue #45717) | checkpoint.json 必須 + nohup/setsid 系で子プロセス分離。Windows では setsid 等価機能限定的 | **高** |
| Kindle for PC 仕様変更 (2025: USB 廃止/KFX v2/Canvas 化) | 起動時バージョン fingerprint + 期待要素テンプレートマッチ + graceful stop | **高** |
| PaddleOCR ルビ・縦書き誤認 → LLM ハルシネーション | 信頼度 <0.7 を `[OCR_LOW_CONF]` プレースホルダー化 + 原文同梱プロンプト + 文字数差 X% 超で原文採用 fallback | 中 |
| phash 同一判定の false positive/negative | 連続一致カウンタ N=3 + ノンブル OCR + 総ページ数上限の多重シグナリング | 中 |
| 既存 pdf/epub/index/search 回帰 | スナップショットテスト + JSON Schema バリデーション + CI ゲート | 中 |
| 早期品質ゲート未達検出 | L2 fixture 10 ページで CER>2% なら即時 fail-fast、200 ページ無駄処理を防止 | 中 |
| consent ゲート自動 'YES' 化 | isatty 検出 + `CI=true` 等の環境変数封鎖 + SKILL.md NEVER 節の 3 層 | **高** |
| ヘッダ/フッタ過剰削除 | 削除文字数 >10%/ページで警告、複数ページ反復パターンのみ除去、white-list 保護 | 中 |

### 2.4 alternatives — 代替案比較

| 領域 | 採用案 | 主な競合 | 根拠 |
|---|---|---|---|
| OCR エンジン | **PaddleOCR PP-OCRv5** (ロック決定) | Manga-OCR (CER 14.4%/縦書き特化)、Tesseract (最軽量だが精度低)、Surya/dots.ocr (GPU 推奨) | ロック制約。Manga-OCR は L2 未達時の **ルビ専用ストリーム fallback** として温存 |
| 章検出 | **ルールベース + LLM の組合せ** | TOC ナビ単独、フォントサイズ単独 | スクリーンショット起点で DOM 不可、複数手法の組合せが構造認識前処理 + LLM で偽陽性削減 |
| ルビ記法 | **独自 `{本文|ルビ}` 記法** | Pandoc Lua フィルタ、Obsidian `[漢字]{かんじ}` | LLM 補正容易性 + EPUB/HTML 変換確立済み (furigana4epub/rubyann) のバランス最良 |
| 進捗 UX | **Monitor ツール + 状態ファイル** | tail -f、cat ポーリング | Monitor は v2.1.98 (2026-04-09) で追加、メインスレッド非ブロック |
| Resume 状態 | **SQLite + JSON ハイブリッド** | 単一 JSON、SQLite 単独 | ACID 保証 + Claude Read 親和性両立 |
| consent | **起動時必須 (ロック決定)** | セッション TTL、別ステート+TTL | ロック決定の最厳格解釈に従う |
| LLM 補正粒度 | **段落束ね / 10 ページ/Task** | ページ単位、章単位 | technical 推奨 (段落) と cost 試算の中間。Task 呼出を 200 ページあたり 20 程度に抑制 |

### 2.5 ux_skill_integration — Claude Code スキル化 UX

「Claude 画面から離れさせない」「プル型ポーリングよりプッシュ型ファイルシグナリング」「NEVER 節での明示ガード」の 3 原則。

- **サブコマンド 4 分割** (`/sc:kindle:start, :status, :resume, :result`) を task 型で定義 → 評価ごとのトークンコストゼロ
- **進捗確認経路**: Python が `progress.json` をアトミック書込み (tmp→rename) → `/sc:kindle:status` 起動時に Claude が 1 回 Read。tail を ! で打たせる方式は対話中断リスク
- **consent UX vs 安全性**: ロック決定『起動時 1 回必須』に従う。SKILL.md に `NEVER proceed if the user has not typed exactly "YES"` を明示
- **Resume**: kindle-state.json から last_page を読み Python 再起動、冪等設計で重複処理を吸収
- **完了確認**: 目次 + 各章冒頭 100 文字の **構造化サマリー → progressive disclosure**。エクスプローラ起動は OS 差異あり既定にしない

### 2.6 measurement_and_acceptance — 品質ゲート計測

- **GT (正解 Markdown)**: 青空文庫等の著作権フリー縦書きテキストを Kindle に取り込み → スクリーンショット fixture 化。RETAS 自動アライメントで補完
- **CER 採用根拠**: 日本語は単語境界がないため WER 不適。Levenshtein 距離ベースで `CER = (I+D+S)/N`、jiwer/dinglehopper で自動計算
- **章ズレ指標**: 「章タイトル検出 F1 (jaro-winkler ファジーマッチ)」+「章数差分」の複合
- **30 分修正計測**: 直接計測困難。**CER × 総文字数 ≒ 推定修正文字数** をプロキシ指標 + L3 human_check で補完
- **PaddleOCR CI 再現性**: CPU 専用モード固定 + Docker バージョンピン + 閾値ベースアサーション (CER<2% など微小非決定性を吸収)
- **Ralph Loop ゲート組込み**: criteria.json の `validation.layer_2.command` に CER 評価スクリプトを指定、exit code で合否判定し未達は前フェーズロールバック

---

## 3. 視点間の矛盾と調整

| 矛盾 | 結論 |
|---|---|
| OCR エンジン: alternatives 「Manga-OCR > PaddleOCR」 vs technical 「PP-OCRv5 が縦書き対応で +13pt」 | **PP-OCRv5 を主エンジン (ロック確定)** + Manga-OCR を**ルビ専用ストリームの fallback** に温存する 2 段構成 |
| LLM 補正粒度: technical 「段落 (~100 OCR ワード)」 vs alternatives 「ページ単位 (500-1000 トークン)」 | **段落束ね = 1 Task あたり 10 ページ相当**を渡し、内部で段落単位チャンク化する**ハイブリッド** (cost 試算と整合) |
| consent: risk 「毎回手動 + 厳格防御」 vs ux 「セッション TTL (1 回)」 | ロック決定『起動時 consent 必須』の**最厳格解釈**に従い**起動 1 回 + 3 層防御** (isatty + 環境変数封鎖 + SKILL.md NEVER) |
| GT 作成: measurement 「Kindle ePub RETAS アライメント (法的グレー)」 vs alternatives 不明示 | ロック決定『DRM 解除なし』に厳密に従い、**青空文庫経由のみ**。RETAS は青空文庫テキスト ↔ OCR 出力間で活用 |

---

## 4. 推奨実装方針

### 4.1 Primary（Phase 1.5 で 18-25 タスクに分解）

| 層 | 構成要素 |
|---|---|
| **(a) スキル層** | `.claude/commands/sc/kindle/{start,status,resume,result}.md` を task 型で配置。`:start` は consent ゲート → Bash で Python パイプライン起動 → Monitor で stdout シグナリング。`:status` は progress.json を Read。`:resume` は kindle-state.json から last_page を読み Python 再起動。`:result` は MD の目次+各章冒頭 100 文字を構造化サマリー化 |
| **(b) OCR パイプライン** | 300 DPI + 固定座標クロップ + バイラテラル/CLAHE/deskew → PP-OCRv5_server_det + server_rec (CPU では mobile_rec) + det_db_thresh=0.2/box_thresh=0.5。信頼度<0.7 領域は `[OCR_LOW_CONF]` プレースホルダー |
| **(c) LLM 補正** | 段落束ねで 10 ページ/Task の並列 Task 呼出。プロンプトに OCR 原文を必ず同梱、『原文逸脱禁止』NEVER 節を明示。文字数差 X% 超過時は原文採用 fallback |
| **(d) ルビ** | 独自 `{本文|ルビ}` 記法で出力、最終段で Pandoc Lua フィルタにより HTML `<ruby>` 変換オプション提供 |
| **(e) 章検出** | フォントサイズヒューリスティック + 章番号正規表現 + LLM (エッジケース限定) の 3 層 |
| **(f) Resume** | SQLite (OCR キャッシュ/phash 履歴/MD 中間) + JSON (current_page_index/session メタ) ハイブリッド。phash 終端判定は連続一致カウンタ N=3 + ノンブル OCR + 最大ページ数上限の多重シグナリング |
| **(g) 品質ゲート** | L1: ファイル存在検証 / L2: 青空文庫 fixture 10-20 ページで jiwer CER<2% アサーション (fail-fast) / L3: 実 1 冊で 10% サンプリング CER + 章タイトル F1 + 修正タイマー計測。assertions 機構で各 locked_decision に file_exists/grep_absent ルール付与 |
| **(h) 長時間処理保護** | Bash SIGTERM 伝播バグ (Issue #45717) 対策として子プロセスを nohup/setsid 系で分離、checkpoint.json を 1 ページ毎にアトミック書込み。Kindle for PC バージョン fingerprint + UI 要素テンプレートマッチによる graceful stop を起動時に実施 |

### 4.2 Fallback（Primary 不成立時）

- OCR を **Hybrid 2 エンジン化**: 本文は PaddleOCR PP-OCRv5、ルビ・縦書き難所は Manga-OCR で別ストリーム抽出 → 後段マージ
- LLM 補正粒度を **段落束ねからページ単位 (500-1000 トークン) に粗化**、Task 呼出を 200 ページあたり 20 → 10 に半減
- consent を起動時 1 回 + checkpoint resume 時の再確認なしに simplify

**Trigger**:
- L2 fixture で 3 連続イテレーション CER>2%
- Max5 サブスクで週次上限超過警告が 2 回以上
- phash 終端判定の誤検出が 200 頁本で 5 回超

### 4.3 Abort（推奨しない）

ロック決定により abort は推奨しない。ただし以下 3 条件いずれかが発生時のみ Phase 4 人間判断で「現行品質で停止 → 将来再評価」を選択可:

1. Amazon が Kindle for PC Legacy のスクリーンキャプチャ自体を OS API レベルで遮断
2. Claude Code Task ツールがサブスクで実用上利用不能になる
3. PP-OCRv5 + Manga-OCR fallback でも CER<2% が物理的に達成不能

---

## 5. 実装基準 (criteria) 概観

### 5.1 Layer 1 (単体テスト) — 10 件

| ID | 内容 |
|---|---|
| L1-001 | スキル 4 分割ファイルの存在 + フロントマター + NEVER 節 |
| L1-002 | OCR 前処理ユニット (deskew/CLAHE/バイラテラル/固定クロップ) |
| L1-003 | progress.json アトミック書込み (tmp+rename) |
| L1-004 | ルビ `{本文|ルビ}` パーサ/バリデータ (空ルビ・ネスト検出) |
| L1-005 | 章検出ヒューリスティック (F1≥0.8) |
| L1-006 | consent ゲート (TTY/env/大文字 YES 3 軸) |
| L1-007 | SQLite + JSON ハイブリッド state 初期化 |
| L1-008 | mypy --strict + ruff チェック |
| L1-009 | jiwer ベース CER 計測ヘルパ |
| L1-010 | checkpoint.json アトミック + .bak fallback |

### 5.2 Layer 2 (統合/E2E) — 6 件

| ID | 内容 |
|---|---|
| L2-001 | 青空文庫 fixture 10-20 ページで CER<2% (fail-fast) |
| L2-002 | Resume E2E (SIGTERM → 再開、中断なし版と CER<0.5% 一致) |
| L2-003 | phash 終端判定 (同一 3 連続で発火、4 枚目で非発火) |
| L2-004 | Kindle for PC バージョン fingerprint + graceful stop |
| L2-005 | Mock LLM で原文逸脱検出 (record-replay) |
| L2-006 | progress 行 stdout 出力 + tail 検知 |

### 5.3 Layer 3 (受入) — 6 件

| ID | strategy | 内容 |
|---|---|---|
| L3-001 | structural | MD 構造 (H1/H2/H3 + ルビ + Schema) 検証、章数差≤1 / ルビ不正 0 |
| L3-002 | cli_flow | スキル 4 分割 CLI シーケンス (start→status→result) ドライラン |
| L3-003 | context_injection | checkpoint.json を 5 秒ポーリング、単調増加 + 完了到達 |
| L3-004 | llm_judge | MD 冒頭 2000 文字を Task ツール評価 4 軸、平均 ≥0.75 / ruby_correctness ≥0.8 |
| L3-005 | api_e2e | start → status → resume(SIGTERM) → result の CLI 一連、CER<2% + 章数差≤1 |
| L3-006 | cli_flow | consent 自動化バイパス防止 (security regression) |

### 5.4 フェーズ分割

| Phase | Goal | Mutation Survival 閾値 |
|---|---|---|
| **mvp** | 青空文庫 3-5 ページで :start → Python → result.md 生成の E2E が 1 本通る最小状態 | 0.40 |
| **core** | 10-20 ページで CER<2% / 章ズレ≤1 / ルビ valid を達成し、Resume と phash 終端が機能 | 0.30 |
| **polish** | 実 1 冊 200 ページで CER<2% / 章ズレ<5% / 修正<30 分 + consent バイパス防止 + LLM judge ≥0.75 | 0.20 |

---

## 6. 主要な未解決課題 (gaps)

横断的に視点を見渡した結果、以下が**実装中に実測で詰める必要がある領域**:

1. **PP-OCRv5 の日本語縦書き小説 (印刷フォント) 実精度**: 公開ベンチマーク無し。L2 で実測必須
2. **phash Hamming 距離の最適閾値**: アプリ固有のため Kindle for PC での実測キャリブレーションが必要
3. **Claude Code スキル `:` 名前空間**: ディレクトリ構造 `.claude/commands/sc/kindle/start.md` で動作するかの公式確認未取得
4. **大規模 Markdown 章一覧 Read のトークン消費実測**: grep 系軽量化の有効性が未確認
5. **Anthropic Max5/Max20 週次上限の具体値**: 公式非公開。200 ページ全量処理の抵触リスク定量評価不可
6. **30 分閾値の根拠**: どの文字数・難易度の本を想定しているか未定義のため妥当性検証困難
7. **ルビ記法読書ツール互換性**: 2026 年時点の主要 EPUB ビューワ (Kindle/Apple Books/Kobo) でのレンダリング挙動が未確認
8. **Windows 環境 setsid 等価機能**: SIGTERM 伝播バグ緩和策の Windows 適用性

---

## 7. 結論

- **GO 判定**: ロック決定 9 項目すべてと整合する実装方針が確立。6 視点で技術的成立性が確認され、コスト試算で Max5 サブスク内 200 頁完走が現実的
- **既知リスク 4 件**は緩和策が存在し、多層防御で残存リスクは中程度
- **次アクション**: Phase 1.5 (generate-tasks) を起動し、上記 L1×10 / L2×6 / L3×6 を 3 フェーズ (mvp/core/polish) に分解
- **不確実性が残る項目** (PP-OCRv5 縦書き実精度、phash 閾値、週次上限抵触) は **L2 fixture と polish の実 1 冊検証で early-detect**し、必要に応じて Fallback 構成 (Manga-OCR ハイブリッド) に切替

---

## 付録: 参照したリサーチ成果物

- `investigation-plan.json` — 7 core questions + 4 fixed perspectives + 2 dynamic perspectives
- `perspective-technical.json` — 8 findings, summary confidence: high
- `perspective-cost.json` — 6 findings, summary confidence: medium-high
- `perspective-risk.json` — 8 findings, summary confidence: medium-high
- `perspective-alternatives.json` — 7 findings, summary confidence: medium-high
- `perspective-ux_skill_integration.json` — 5 findings, summary confidence: high
- `perspective-measurement_and_acceptance.json` — 6 findings, summary confidence: high
- `synthesis.json` — 統合所見 + 矛盾 4 件 + ロック整合 8 件 + Primary/Fallback/Abort 推奨
- `implementation-criteria.json` — L1×10 / L2×6 / L3×6 + 3 phase (mvp/core/polish)
