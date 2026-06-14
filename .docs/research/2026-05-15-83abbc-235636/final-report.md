# Kindle (Windows) + PDF/EPUB 本文抽出 Python CLI エージェント 最終リサーチレポート

**Research ID**: `2026-05-15-83abbc-235636`
**作成日**: 2026-05-16
**出力先プロジェクト**: `C:\Users\bossbot1000tdump\Desktop\kindle-readear`

---

## 1. エグゼクティブサマリー

Kindle for PC (Windows) と既存 PDF/EPUB から章構造付き本文テキストを抽出する Python CLI エージェントの実装方式を、6 視点（technical / cost / risk / alternatives / legal_compliance / ocr_quality_engineering）で並列調査した。結論は以下に強く収束した。

| 領域 | Primary | Fallback |
|---|---|---|
| Kindle 抽出経路 | **AHK+OCR（スクリーンキャプチャ）** | 旧版固定 + 別経路（PDF/EPUB） |
| OCR エンジン | **PaddleOCR PP-OCRv5（ローカル）** | Azure Computer Vision（opt-in） |
| ページめくり自動化 | **pyautogui**（GitHub 実証例最多） | pywinauto（UIA 経路） |
| PDF/EPUB パーサ | **PyMuPDF + ebooklib** | pdfplumber（表抽出用） |
| LLM 補正 | **Claude Haiku + Batch API** | Ollama + Qwen2.5-VL-7B（オフライン） |
| ステート管理 | **SQLite（WAL）+ ページ別ファイルツリー** | （JSON は採用しない） |
| 出力形式 | **Markdown（章=##）+ JSON サイドカー** | プレーン txt はバックアップのみ |
| 運用形態 | **個人利用・非配布・クローズドツール** | （配布形態は採用しない） |

**最大の構造リスク**: 2026-06-30 のレガシー Kindle for PC 廃止。後継 Microsoft Store 版が TPM 2.0 ベース強化 DRM を搭載した場合、スクリーンキャプチャ自体が機能停止する可能性がある。MVP/Core はこの期限内に完成させる。

**Calibre+DeDRM 経路は不採用**: 2025-02 の USB ダウンロード廃止、2025-04 以降購入書籍の新 DRM、2026-03 の旧 Kindle への新 DRM 強制配信により事実上閉鎖済み。DMCA 1201 違反明確 + アカウント BAN リスク。

---

## 2. テーマと前提条件

### 2.1 調査テーマ
> Kindle (Windows版) と既存 PDF/EPUB から本文テキストを章構造付きで抽出する Python CLI 自動化エージェントの実装方式選定

### 2.2 ロックされた決定事項（壁打ち Phase 0 由来・調査対象外）

- 対象: Kindle (Windows) + PDF/EPUB の3系統
- 実装形態: Python CLI
- OS: Windows 11 専用
- パイプライン中心: LLM は OCR 補正と章整形のみ
- 出力: 章構造付きテキストファイル（Markdown）
- 出力先: `C:\Users\bossbot1000tdump\Desktop\kindle-readear`
- ハーネス本体は不変

### 2.3 主要 Open Questions

1. Kindle 抽出経路の選定（AHK+OCR / Calibre+DeDRM / ハイブリッド）
2. OCR エンジンの選定（日本語縦書き・ルビ耐性）
3. ページめくり自動化ライブラリ
4. PDF/EPUB パーサの振り分け
5. LLM 補正の費用対効果
6. 中断/再開ステート管理方式
7. Kindle 表示設定と最終ページ検出
8. 個人バックアップ立て付けの法的表現

---

## 3. 6 視点リサーチサマリー

### 3.1 Technical（技術的実現性）

| 論点 | 結論 | 確信度 |
|---|---|---|
| Kindle for PC キャプチャ可否 | レガシー v2.9.x は mss/PIL.ImageGrab で安定動作。BitBlt はGPU 加速 OFF で回避可。2026-06-30 で廃止予定 | medium |
| ページめくり自動化 | GitHub 実証例は **pyautogui が最多**（zatoima 他）。AHK v2/pywinauto は Kindle 特化例が少ない | medium |
| 縦書き OCR 精度 | PaddleOCR PP-OCRv5: 85-93%、Tesseract: 60-70%。F1=0.938 vs 0.797 | medium |
| PDF 画像/テキスト自動判別 | PyMuPDF `get_text('blocks')` で image_area/text_area 比較が標準 | **high** |
| ローカル LLM 補正の閾値 | olmOCR-2-7B (Qwen2.5-VL-7B base) が英語で Claude/GPT-4o 相当。日本語縦書き専用ベンチは未整備 | low |
| SQLite チェックポイント | `(job_id, book_id, page_no)` PK + status enum + WAL モードが標準 | **high** |
| 最終ページ検出 | **ハッシュ重複検知が最堅牢**（kindleOCRer 等で実証） | medium |

### 3.2 Cost（コスト・リソース）

| 項目 | コスト/工数 |
|---|---|
| クラウド OCR（Google Vision / Azure / Document AI） | **$0.45/冊（300p）で横並び** |
| Google Drive OCR | 無料だが縦書き不可で実用外 |
| Claude API 補正（300p, 150K in + 150K out） | Haiku $0.90 / Sonnet $2.70 / Opus $4.50（**Batch API で 50%引**） |
| OpenAI GPT-4o 補正 | $1.90/冊（Batch で $0.95） |
| ローカル LLM (Ollama) | $0 だが GPU 必須 + 83 分/冊 |
| Tesseract セットアップ | ~50MB / 15-30 分 |
| PaddleOCR セットアップ | ~738MB（paddlepaddle 含む） / 30-60 分 |
| Calibre+DeDRM 旧 Kindle 入手 | 中古市場依存・noDRM 保守継続性なし |
| SQLite vs JSON 開発工数差 | SQLite が +20-30%。ただし標準ライブラリ |

### 3.3 Risk（リスク・失敗モード）

- **法務**: DeDRM は **DMCA 1201 直接違反**（フェアユース抗弁不可: Universal v. Corley）。AHK+OCR は技術的に DRM を解除しないが Amazon ToS の自動アクセス禁止条項に抵触するグレー。
- **DRM 強化タイムライン**:
  - 2025-02-26: USB ダウンロード廃止
  - 2025-04-22: 旧 Kindle for PC からの新刊取得不可
  - 2026-03: 旧型 Kindle にも新 DRM 強制配信
  - 2026-06-30: レガシー Kindle for PC 廃止予定
- **OCR×LLM のセマンティック・ハルシネーション**: ベースラインで 23.8% 誤り、最良で 4.2% 残存。固有名詞・数値で深刻化。**エントロピーベース confidence + クロスバリデーション + 元画像字句チェック**で検出。
- **Kindle for PC オートアップデート**: ファイアウォール/レジストリでブロック可能だが新刊取得不可化の副作用。
- **クラウド OCR/LLM 送信**: 著作権・GDPR・データ保持の三重リスク。EDPB 2025-04 ガイダンス参照。
- **縦書き・ルビ・脚注**: 本文混入で検索性低下。AZW3 が必要（MOBI 不可）。

### 3.4 Alternatives（代替案・競合）

| カテゴリ | 1位 | 2位 | 不採用 |
|---|---|---|---|
| Kindle 抽出 | **AHK+OCR** | ハイブリッド | Calibre+DeDRM（陳腐化） |
| OCR | **PaddleOCR PP-OCRv5**（無料）/ Azure CV（精度） | Tesseract | Google Drive OCR（縦書き不可） |
| ページめくり | **AHK v2** / pywinauto（堅牢性） | — | pyautogui（座標脆弱） |
| PDF/EPUB | **PyMuPDF 単独** | PyMuPDF+ebooklib | pdfminer.six（最遅） |
| LLM | **Claude Haiku** | Ollama（無料） | — |
| ステート | **SQLite + ファイルツリー** | — | JSON 単独 |
| 出力 | **Markdown(##)** | JSON サイドカー併用 | プレーン txt |

> 注: alternatives 視点は pyautogui を脆弱と評価したが、technical 視点では GitHub 実証例最多のため首位。後述 3.7 の矛盾解消で **pyautogui を Primary** に決定。

### 3.5 Legal Compliance（規約・法的）

- **日本著作権法 30 条 1 項 2 号**: DRM 回避を伴う私的複製は違法。ただし「技術的保護手段の回避」は「信号の除去・改変」と定義されており、**スクリーンショットは形式上該当しない**との解釈が有力（確定判例なし）。
- **Amazon Kindle Store ToU**: 「bypass, modify, defeat, or otherwise circumvent any DRM ... or **other content protection or features**」と広く規定。OCR 自動化も射程に入りうる。
- **DMCA 1201**: フェアユースは抗弁にならない（Universal v. Corley）。配布は刑事重罪化のリスク。
- **GitHub 公開の線引き**: DeDRM 同梱は明確に幇助、AHK 単独はリスク低。ただし「Kindle DRM 回避」目的の明示は幇助評価を高める。
- **最小リスク構成**: 個人利用 + 非配布 + クローズドツール + 起動時免責文言 + Amazon ToS 自己確認 + 人間操作に近いペース。

### 3.6 OCR Quality Engineering

| 工程 | 推奨手法 |
|---|---|
| DPI 調整 | Kindle スクショ 72-96 DPI → **OpenCV 2-4倍アップスケール** → 300 DPI 相当 |
| 前処理 | グレースケール → **Otsu/適応的二値化** → ノイズ除去（NlMeansDenoising）→ アップスケール（INTER_CUBIC/LANCZOS4） |
| 評価 | VJRODa / NDLOCR データセット。商業 CER≤1%、学術≤3-5%、参照≤10% が実務目安 |
| ルビ・脚注分離 | **連結成分解析 + フォントサイズ閾値**（本文の 40-60% 以下は除去）。高精度要なら Surya / YOLO |
| LLM 補正トリガ | per-word confidence < **0.7-0.9**。Tesseract `image_to_data()` 利用 |
| ページまたぎ語 | spaCy + GiNZA で改行補正。縦書きは文節境界推定が必要 |

Llama 2 後補正で CER 54.51% 削減実績あり（ただし英語歴史文書）。日本語印刷物への適用事例は限定的。

### 3.7 視点間の主な矛盾と解消方針

| 矛盾箇所 | 内容 | 解消 |
|---|---|---|
| alt vs tech | ページめくり: alt は AHK/pywinauto 推奨、tech は pyautogui 実証最多 | **pyautogui Primary + pywinauto Fallback**。DPI/座標正規化で弱点緩和 |
| alt vs cost vs risk | OCR エンジン: 精度 vs サイズ vs プライバシー | **PaddleOCR PP-OCRv5 固定**（ローカル・縦書き対応）。Azure CV は opt-in |
| alt vs cost vs tech | LLM: クラウド vs ローカル | **Claude Haiku Primary + Ollama Fallback** |
| cost vs alt | ステート: JSON 簡単 vs SQLite 堅牢 | **SQLite（進捗）+ ファイルツリー（本文）** |
| legal vs risk | AHK+OCR の評価温度差 | 補完関係。法務リスクは低、Amazon ToS リスクは別個に存在 |

---

## 4. 推奨実装スタック（Primary）

### 4.1 アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────┐
│ Python CLI: kindle-extract {pdf|epub|kindle} ...            │
└─────────────────────────────────────────────────────────────┘
       │                  │                       │
       ▼                  ▼                       ▼
  [PDF 経路]         [EPUB 経路]            [Kindle 経路]
  PyMuPDF            ebooklib               pyautogui
  画像/テキスト       TOC + nav.xhtml         + mss/PIL.ImageGrab
  自動判別                                   + ハッシュ重複検知
       │                  │                       │
       │ (画像PDFの場合)  │                       ▼
       ▼                  │                  OpenCV 前処理
  OpenCV 前処理 ─────────────────────────►   (2-4×UP→Otsu→denoise)
       │                                          │
       ▼                                          ▼
       ┌──────────────────────────────────────────┐
       │     PaddleOCR PP-OCRv5（縦書き対応）       │
       └──────────────────────────────────────────┘
                          │
                          ▼
       per-word confidence < 0.8 → Claude Haiku 補正
                          │
                          ▼
       章境界検出（LLM）/ TOC 一致確認（PyMuPDF/ebooklib）
                          │
                          ▼
        Markdown（章=##） + JSON サイドカー（chapters[]）
                          │
                          ▼
       SQLite (jobs/books/pages WAL) + ページ別ファイルツリー
```

### 4.2 採用理由（Rationale）

1. ロック決定 6 項目すべてと整合（Kindle+PDF/EPUB、Python CLI、Windows 11、Markdown 出力、ハーネス分離）
2. DeDRM 経路は 2025-2026 の Amazon DRM 強化で実用不能化が確定
3. PaddleOCR PP-OCRv5 は日本語縦書きを公式改善対象とした唯一の主要 OSS
4. pyautogui は GitHub 実証例が最多で Python 統合が最も自然
5. Claude Haiku は日本語品質・コスト・ハルシネーション率の 3 軸で最良
6. SQLite + ファイルツリーは再開不能リスクを最小化しつつ標準ライブラリのみで完結

### 4.3 残存リスクと緩和

| リスク | 緩和策 |
|---|---|
| 2026-06-30 レガシー版廃止 → キャプチャ機能停止 | **MVP/Core を期限内完成**。旧版固定（FW ブロック + updates フォルダ削除） |
| Kindle for PC 強制アップデートで UI 破綻 | ファイアウォール + アップデートフォルダ削除 + バージョン固定 |
| PaddleOCR ルビ・脚注混入 | 連結成分解析 + フォントサイズ閾値で前処理除去 |
| Claude セマンティック・ハルシネーション | constrained decoding + 元画像字句一致チェック + 高 confidence 誤りの ECE |
| pyautogui の DPI/マルチモニタずれ | 起動時に DPI/ウィンドウ位置正規化、検知時に pywinauto に切替 |
| Amazon 自動化検知 | 人間操作に近い間隔 + 深夜大量バッチ回避 |
| Ollama 日本語縦書き精度未検証 | Primary は Claude Haiku 固定、ローカル切替は opt-in |

### 4.4 Fallback トリガと切替先

| Primary | Fallback | トリガ |
|---|---|---|
| pyautogui | pywinauto | 連続3ページの座標ズレ or DPI 検知失敗 |
| PaddleOCR | Azure Computer Vision | 10ページ平均 confidence < 0.6 or CER > 5% |
| Claude Haiku | Ollama + Qwen2.5-VL-7B | 429/529 を5回連続 or `--offline` フラグ |
| レガシー Kindle for PC | 旧版固定 + PDF/EPUB 経路への退避 | 2026-06-30 以降 or 強制更新で3冊連続失敗 |
| 章境界 LLM 検出 | PyMuPDF/ebooklib TOC | LLM 章数 が原書 TOC ±20% を超える乖離 |

### 4.5 中止（Abort）条件

以下 3 つのみ。OCR 精度不足・LLM コスト・実装工数は Fallback で対応可能で Abort には該当しない。

1. 2026-06-30 廃止後、後継アプリの強化 DRM でキャプチャ完全停止 + 旧版固定も新刊取得不可で実用性喪失
2. ユーザーが個人利用・非配布の運用条件を逸脱（GitHub 公開・他者配布）
3. ユーザーが Kindle 書籍の所有権を持たない/他者書籍を意図

---

## 5. 実装基準（Layer 1/2/3）

### 5.1 Layer 1（ユニットテスト・9 件）

| ID | 対象モジュール | 概要 |
|---|---|---|
| L1-001 | PDF 抽出 (PyMuPDF) | 画像/テキスト判別、暗号化/破損/0p 例外 |
| L1-002 | EPUB 抽出 (ebooklib) | TOC nav 優先、縦書き flag、章タイトル付与 |
| L1-003 | OCR 前処理 (OpenCV) | scale=2 アップ、Otsu、決定論性 |
| L1-004 | SQLite ステートストア | WAL、upsert 冪等性、再開性 |
| L1-005 | Markdown ライタ | ##、サイドカー JSON、特殊文字エスケープ |
| L1-006 | CLI 引数パーサ | subcommand、--offline、-j 0 reject |
| L1-007 | 信頼度フィルタ | 閾値境界、None 安全側、空入力 |
| L1-008 | ページハッシュ重複検知 | perceptual hash、1pixel 差耐性 |
| L1-009 | lint/type-check | ruff + mypy + bandit (B307/B602) |

### 5.2 Layer 2（統合・E2E・5 件）

| ID | 概要 | 必須リソース |
|---|---|---|
| L2-001 | PaddleOCR 縦書き CER ≤ 5% | PP-OCRv5 + sample_vertical_jp.png/.gold.txt |
| L2-002 | Claude Haiku Batch API 補正 | ANTHROPIC_API_KEY + ネット接続 |
| L2-003 | PDF 100p E2E、TOC ±20% | sample_text_pdf.pdf/.toc.json |
| L2-004 | pyautogui 5p 連続キャプチャ | Windows 11 + Kindle for PC 起動 |
| L2-005 | 100p 中 50p 中断→再開 | sample_text_pdf_100p.pdf + SQLite |

### 5.3 Layer 3（受入・5 件）

| ID | strategy | 成功閾値 |
|---|---|---|
| L3-001 | cli_flow（PDF パイプライン） | exit 0 + chapters 乖離 ≤ 20% + ## 行数==JSON chapters |
| L3-002 | cli_flow（EPUB 章一致） | exit 0 + 章タイトル一致率 ≥ 90% |
| L3-003 | structural（スキーマ適合） | 全フィールド 100% + word_count > 0 |
| L3-004 | context_injection（全文検索） | search.db に chapter_id 1 件以上ヒット |
| L3-005 | llm_judge（品質判定） | 平均スコア ≥ 0.75（文意・章境界・固有名詞・非ハルシネーション） |

### 5.4 フェーズ計画

| Phase | Goal | criteria_refs | Mutation Survival 閾値 |
|---|---|---|---|
| **mvp** | テキスト埋込 PDF 1 冊で章付き MD + JSON 生成 | L1-001/004/005/006/009, L2-003, L3-001/003 | 0.4 |
| **core** | EPUB + 画像 PDF + Kindle スクショ + 中断再開 全動作 | L1-002/003/007/008, L2-001/002/004/005, L3-002/004 | 0.3 |
| **polish** | ルビ・脚注分離 + ハルシネーション緩和 + LLM 判定通過 | L3-005 | 0.2 |

各フェーズに `human_check`（level A）として、目視確認項目を含む。

---

## 6. ギャップと残存不確実性

調査で埋め切れなかった主な情報ギャップ。実装段階で実測補完が必要。

- **2026-07 以降の Windows 11 専用 Kindle アプリ（TPM 2.0 強化 DRM）でのキャプチャ可否** — 2026-06-30 廃止までに検証不可
- **ルビ認識の PaddleOCR vs Tesseract 定量ベンチマーク** — 自前テスト必要
- **Ollama (Qwen2.5-VL-7B 等) の日本語縦書き OCR 補正精度ベンチ** — 公開データなし
- **AHK v2 を Kindle for PC に適用した実証 GitHub コード** — 不在
- **VJRODa/NDLOCR 上の 2025-2026 主要モデル CER 一覧** — 単一ソースに未整理
- **Kindle for PC フォント/行間/テーマ変更の OCR 精度寄与の定量実験** — 文献未発見
- **日本国内 AHK+OCR スクリーンキャプチャ事案の判例** — 存在せず解釈の余地大
- **Amazon ToS「content protection or features」が OCR 自動化を含むかの公式解釈** — 非公表
- **Claude Batch API の実際のターンアラウンド中央値** — 上限 24h のみ公表

---

## 7. 結論

リサーチ 6 視点は「**AHK+OCR（pyautogui + PaddleOCR PP-OCRv5）を主軸とし、PDF/EPUB は PyMuPDF+ebooklib で別パス、LLM 補正は Claude Haiku Batch API、ステートは SQLite+ファイルツリー、出力は Markdown(##)+JSON サイドカー、個人利用・非配布・クローズドツール運用**」という方針で強く収束した。Calibre+DeDRM は陳腐化が確定済みで採用不可、クラウド OCR/LLM は既定無効・opt-in 設計でプライバシーリスクを運用上回避する。

最大の構造リスクは 2026-06-30 のレガシー Kindle for PC 廃止であり、**MVP/Core はこの期限内に完成させる**ことが Phase 計画の前提となる。実装基準は L1×9 / L2×5 / L3×5 で整備済み、3 フェーズ（mvp/core/polish）に割り当て済み。Phase 2（Ralph Loop）への移行準備が整った状態。

---

## 8. 主要エビデンス（抜粋）

- TextMuncher Blog — Kindle DRM Removal 2026 / Amazon Kindle Loopholes 2025
- ebook-reader.com — Amazon Breaking DRM Removal on Older Kindles (2026-03)
- PaddleOCR Docs — PP-OCRv5 縦書き日本語改善
- arxiv 2511.15059 — Qwen2.5-VL 縦書き日本語多モーダル評価
- arxiv 2502.01205 — OCR Post-Correction with LLMs: No Free Lunches
- arxiv 2207.03960 / 2209.04460 — ルビ分離 / 図版キャプション分離
- VJRODa / NDLOCR / JaPOC — 縦書き日本語 OCR 評価データセット
- Anthropic Pricing — Claude Haiku 4.5 / Batch API 50% 引
- DMCA 1201 / Universal v. Corley — 米国法判例
- 日本著作権法 30 条 1 項 2 号 / 文化庁ガイドライン
- Amazon Kindle Store Terms of Use
- PyMuPDF / PyMuPDF4LLM Docs
- kindleOCRer / auto-screenshot-ripper / KindleBookExporter（GitHub 実装参考）
