# リサーチ最終レポート

**リサーチID**: 2026-04-13-362c69-215826
**生成日**: 2026-04-13
**テーマ**: make-jikok/templates に配置する自己啓発ブログ writer/reviser/critic エージェント向け運用ドキュメント10本の最適ラインナップ確定と、ソース6本の深リサーチ・既存3本との相互補完性・倫理境界設計を含む執筆方針の策定

---

## エグゼクティブサマリー

本リサーチは、既存 `make-jikok/templates/` の 3 本（style-guide.md / blacklist.md / originality-tactics.md）を改変せず、ソース 6 本（complete-transformation-theory / content-business-theory / cult-belief-formation / enhanced-content-business-theory / value-first-content-strategy / practical_application_framework）を翻訳・再構成した **新規 10 本** を追加するための設計指針を 6 視点（technical / cost / risk / alternatives / ethics_boundary / agent_routing）から調査し、以下の収束点を得た。

- **設計原理**: 3 次元マトリクス（コンテンツタイプ × 読者ジャーニー × 機能）でラインナップを導出し、ロール別メタデータ（`[writer:必須 | reviser:条件付き | critic:参照不要]`）をファイル冒頭に付与するハイブリッド方式が最適。
- **倫理境界**: 「受け手の **認識論的自律性（epistemic autonomy）** を強化するか剥奪するか」が単一基準。BITE モデル + Cialdini の「実在/捏造」区分で 12 項目チェックリストを設計可能。
- **アーキテクチャ**: 既存 3 本 + 新規 `ethics-guardrails-checklist.md` を Tier 1 常時参照（プロンプトキャッシュ対象）、残り 9 本を Tier 2/3 の RAG 動的取得に分離。
- **判定**: 6 視点は primary 推奨（10 本独立構成）に収束し、撤退条件の同時成立可能性は低い。→ **GO**。

---

## 1. リサーチ設計

### 1.1 中核問い（10 件）
1. ソース 6 本の知見のうち、自己啓発ブログ執筆に転用可能なものと商用セールス依存で転用困難なものの切り分け
2. 既存 3 本がカバーしていない主題領域と、それを埋める 10 本のタイトル・役割・主題の最適組合せ
3. 主要フレームワーク（教育型マーケ 6 要素・CREDENCE 8 段階・価値多層変容・アイデンティティ再定義・7:2:1 黄金比率・共鳴説得）の優先度付け
4. cult-belief-formation.md の技法群の許容域（欲求喚起）と禁止域（カルト操作）の具体例対照による定式化
5. 新規 10 本共通の倫理ガードレールフォーマット設計
6. 既存ポリシー（陳腐フレーズ禁止・権威偽装禁止）とソース資料推奨表現の衝突調停
7. 章構成テンプレ・分量配分・NG/OK 対照表個数・チェックリスト項目数の標準値
8. writer/reviser/critic の参照ルーティング（必須/状況依存/参照不要）
9. 参照頻度最大のハブドキュメントと依存関係マップ
10. 2026 年時点の類似スタイルガイド群との差別化ポイント

### 1.2 境界
| 軸 | 内容 |
|---|---|
| 深さ | ソース 6 本は全文精読、既存 3 本は章構造・ルール項目まで完全分解、類似市場は表層比較、倫理境界は BITE / Lifton 等の学術裏付けまで |
| 広さ | ソース 6 本 + 既存 3 本 + 類似テンプレ表層調査 + 学術的倫理枠組み。範囲外: プロジェクト本体改変・既存 3 本改訂・販売促進ベクトル転用 |
| カットオフ | 10 本ラインナップ・章構成テンプレ・倫理ガードレール共通フォーマット・ルーティング確定時点 |

---

## 2. 視点別サマリー

### 2.1 technical（技術的実現性）
- **意味損失識別基準**: FRAME フレームワークの **theory of change（変化のメカニズム）** 保持可否が単一判断軸。臨床/統計依存・マルチメカニズム構造・熟練判断必須の技法は翻訳で本質を失いやすい。
- **10 本導出の分類軸**: ファセット型（コンテンツタイプ × 読者ジャーニー × 機能）× 階層型のハイブリッド。NN/G の「3〜4 階層以内」制約を守る。
- **相互参照記法**: YAML frontmatter（permalink 方式）+ wikilink + スラグ化ルール統一 + 相対パス規約。暗黙ターゲット禁止。
- **分量比率（8KB〜20KB）**: 理論 20–30% / 具体例 30–40% / NG-OK 対照表 15–20% / チェックリスト 10–15%（既存 3 本の実績から帰納的最適化が最善）。
- **見出し構造の機械抽出**: 5 ステップ（構造解析 → 命名慣習抽出 → 文体粒度計測 → テンプレ生成 → リンター検証）で既存 3 本との整合を自動化可能。

### 2.2 cost（コスト・リソース）
- **トークン予算**: 10 本 × 8–20KB ≈ 出力 20K–51K トークン。Sonnet 4.6 ($3/$15) でフルコンテキスト実行時 **$2.5–$3.5** / RAG 最適化時 **$1.0–$1.5**。
- **コンテキスト圧迫**: 13 本合計 260KB ≈ 66,560 トークン（Claude 200K の 33%）。プロンプトキャッシング + RAG で **85–95% 削減** が現実的。
- **差分取込み最小化**: セクション単位 ID 付与 + 構造化出典注記（`<!-- source: URL, retrieved: DATE -->`）+ モジュール型設計。
- **整合性検証**: markdown-link-check（GitHub Actions 週次実行）で手動コストほぼゼロ。
- **本数のコスト感度**: RAG+キャッシュ適用後は 7〜12 本でコスト差 **$0.3–$0.8** に収束。本数は影響小。

### 2.3 risk（リスク・失敗モード）
3 層の失敗モードが確認された。

| 層 | 失敗モード | 対策 |
|---|---|---|
| 表層 | 陳腐フレーズ混入 | cliché 検出ツール + プレパブリッシュゲート（blacklist 語直接登録）+ 引用ブロック独立スキャン |
| 構造 | 説得技法の操作転用・商用ベクトル残留 | 許容域/禁止域の対照表必須化 + 三基準チェック（透明性・自律性・相互利益）+ 構造的商用パターン検出 |
| 境界侵犯 | カルト技法の記事化 | BITE モデル NG 辞書 + 「【解説目的】/【使用禁止】」二重ラベリング + セマンティック類似度 + 人間レビュー三層防御 |

### 2.4 alternatives（代替案・競合）
- **分類軸選択**: (A) 機能別 / (B) 工程別 / (C) 読者心理フロー のいずれも単一軸で全ロール最適化は不可能。**ロール別メタデータ付与** が実装優先度として最も高い。
- **既存スタイルガイドとの差別化 4 領域**: (1) AI エージェントロール別テンプレ、(2) 自己啓発ジャンル感情アーク、(3) 独自性検証チェックリスト、(4) critic 向けルーブリック。いずれも note / Google / Microsoft ガイド未カバー。
- **追加文献**: エンパシーライティング（中野巧）等の体系化メソッドに限定して追加するのが有益。
- **既存 3 本改変 vs 新規 10 本独立**: 後方互換性・責任分離・Open/Closed Principle の観点で **独立補完が優位**。
- **独立 vs 統合**: LLM 研究のコンテキストロット問題（中間部精度 30% 低下）+ モジュラー設計の 60% トークン削減から **独立ファイル案が強く支持**。

### 2.5 ethics_boundary（倫理境界）
6 技法領域すべてで、許容/禁止の境界は「**認識論的自律性の保存**」に収束。

| 技法 | 許容域 | 禁止域 |
|---|---|---|
| 常識破壊 | 証拠提示・問い直し促進・代替見解承認 | 思考停止クリシェ・ローデッド・ランゲージ |
| アイデンティティ再定義 | 自律性強化・既存関係との継続性維持 | アイデンティティ融合・関係放棄圧力 |
| 希少性・選別感 | 実在する限定性の開示・任意参加 | 人工的緊急性・インサイダー依存 |
| 段階的情報開示 | 各ステップ独立価値・離脱容易 | サンクコスト誤謬・認知的ロックイン |
| コミュニティ帰属 | 共通関心の内集団形成・外部批判を情報として扱う | us vs them・外部情報源の信頼失墜 |

**統合倫理チェックリスト（12 項目）**:
- A. 情報透明性（3 項目）: 根拠明示 / 反論認容 / 利益相反開示
- B. 思考操作検査（3 項目）: 懐疑の否定的再フレーミング不在 / 思考停止クリシェ不在 / 代替視点参照可
- C. アイデンティティ・関係（3 項目）: 既存関係否定不在 / 自己価値の帰属条件付け不在 / 離脱容易
- D. 希少性・感情（3 項目）: 実在希少性 / 外部批判者敵視不在 / サンクコスト煽り不在

**判定ロジック**: 禁止 1 件以上 → 全体 NO / 要レビュー 3 件以上 → 人間判定 / 全 YES → 自動許容。

### 2.6 agent_routing（ルーティング設計）
- **writer フェーズ別最小参照集合**:
  - 企画: スタイルガイド + スコープ定義 + 成功条件（3 点）
  - ドラフト: スタイルガイド + アウトライン + 参照リソース 2–3 点
  - 推敲: スタイルガイド + 品質チェックリスト + 陳腐フレーズ禁止リスト
- **reviser 参照順序**: 構成 → 表現 → 独自性 → 倫理（構造修正を後段で覆い隠さない）
- **critic 5 違反カテゴリとマッピング**: 陳腐フレーズ / 権威偽装 / 倫理逸脱 / 構成破綻 / 独自性欠落 ごとに固有ドキュメントをマッピング
- **メタデータタグ標準化**: `[writer:必須 | reviser:条件付き | critic:参照不要]` の YAML frontmatter or インライン記法
- **3 層アーキテクチャ**:
  - Tier 1: 全エージェント常時参照 = スタイルガイド + 品質基準 + 倫理ポリシー
  - Tier 2: 役割固有
  - Tier 3: 特化局面（エキスパート知識）

---

## 3. 視点間の矛盾と解消

| 対立 | 内容 | 解消策 |
|---|---|---|
| agent_routing ↔ risk | reviser の「倫理を末尾配置」vs「倫理は全段階で二重検出」 | reviser は `構成→表現→独自性→倫理` を基本順序とし、倫理チェックリスト 12 項目は writer 推敲 + critic の双方で独立実行する **倫理二重検出** を採用 |
| alternatives ↔ technical | 10 本全独立 vs 3 次元マトリクスで統合可能 | **独立ファイル原則を基軸**とし、同一ジャーニー × 同一機能の場合のみ統合を検討（例: 感情曲線 + Before-After → 「変容の見せ方」） |
| ethics_boundary ↔ risk | 静的 12 項目チェック vs 意図・構造・文脈の三次元 | **三段階防御**: 12 項目チェック（1 層）→ セマンティック類似度（2 層）→ 人間 / critic エージェントの BITE モデル照合（3 層） |
| cost ↔ agent_routing | RAG 最適化で 2–3 本のみ参照 vs Tier 1 常時参照 | Tier 1（既存 3 本 + 新規 `ethics-guardrails-checklist.md`）をプロンプトキャッシュで固定常時ロード、Tier 2/3 は RAG 動的取得の併用 |
| technical ↔ ethics_boundary | theory of change 保持 vs 認識論的自律性保存 | **ダブルゲート方式**: ゲート 1（theory of change 保持）→ ゲート 2（自律性を強化/中立な技法のみ採用）。両ゲート通過技法のみ記事技法として提示 |

---

## 4. 推奨ラインナップ（Primary 案）

### 4.1 新規 10 本

| # | ファイル名 | 主題 | Tier | 対象エージェント | フェーズ |
|---|---|---|---|---|---|
| 1 | `article-structure-blueprint.md` | 記事全体構造・読者ジャーニー | Tier 2 | writer 必須 | MVP |
| 2 | `hook-and-intro-design.md` | フック / 導入設計 | Tier 2 | writer 必須 | MVP |
| 3 | `emotional-arc-and-beforeafter.md` | 感情曲線・Before-After 対比 | Tier 2 | writer + reviser | Core |
| 4 | `case-and-example-crafting.md` | 具体例・ケース構築 | Tier 2 | writer 必須 | Core |
| 5 | `ethical-persuasion-toolkit.md` | Cialdini 系説得技法の倫理的運用 | Tier 2 | writer + critic | Core |
| 6 | `reader-identity-invocation.md` | 読者アイデンティティ呼びかけ設計 | Tier 2 | writer | Polish |
| 7 | `transformation-narrative-translation.md` | 価値多層変容のブログ翻訳 | Tier 3 | writer 状況依存 | Polish |
| 8 | `framework-embedding-patterns.md` | CREDENCE 等フレームの記事内応用 | Tier 3 | writer 状況依存 | Polish |
| 9 | `ethics-guardrails-checklist.md` | 統合倫理チェックリスト 12 項目 | **Tier 1 昇格** | 全エージェント常時 | MVP |
| 10 | `critic-violation-catalog.md` | 違反パターン図鑑 | Tier 2 | critic 必須 | Core |

### 4.2 共通規約（10 本全て必須）

各ファイルは以下を装備する。

- **YAML frontmatter**: `permalink / audience / tier / type / related / sources`
- **4 メタセクション（H2 固定）**:
  - `## 関連ドキュメント`
  - `## 対象エージェント`
  - `## 倫理ガードレール`
  - `## 出典注記`
- **許容域 / 禁止域の対照表**（最低 3 行）
- **Cialdini 実在/捏造区分** と **BITE モデル照合** の記述

### 4.3 章構成テンプレ（標準比率）

| ブロック | 比率 | 分量目安（8–20KB） |
|---|---|---|
| 理論記述 | 20–30% | 1.6–6.0KB |
| 具体例・ナラティブ | 30–40% | 2.4–8.0KB |
| NG/OK 対照表 | 15–20% | 1.2–4.0KB |
| チェックリスト | 10–15% | 0.8–3.0KB |

---

## 5. 実装基準（implementation-criteria.json 抜粋）

### 5.1 Layer 1（機械検証・自動）

| ID | 主な検証内容 |
|---|---|
| L1-001 | 13 本存在 + 既存 3 本の SHA256 不変 + ケバブケース命名 |
| L1-002 | YAML frontmatter のスキーマ適合（permalink / audience / tier / type / related / sources） |
| L1-003 | 4 メタセクション H2 存在 |
| L1-004 | 許容域/禁止域対照表（最低 2 列 + データ行 3 以上） |
| L1-005 | `ethics-guardrails-checklist.md` に BITE 4 カテゴリ × 3 項目 = 12 チェックボックス |
| L1-006 | blacklist.md 禁止語の混入チェック（コードブロック / 対照表禁止列 / 【解説目的】引用は除外） |
| L1-007 | 相互参照リンクの実在チェック |
| L1-008 | 分量 8KB–20KB（`ethics-checklist` は 6KB 下限、`violation-catalog` は 25KB 上限許容） |
| L1-009 | `ethical-persuasion-toolkit.md` に Cialdini 原則 4 つ以上 + 実在/捏造ラベル対必須 |
| L1-010 | `critic-violation-catalog.md` に違反 15 件以上 + 4 フィールド（違反型/検出シグナル/修正提案/関連 Tier1） |
| L1-011 | 対象エージェントセクションに writer / reviser / critic の 3 値マッピング |

### 5.2 Layer 2（統合検証）

| ID | 内容 |
|---|---|
| L2-001 | frontmatter の audience と本文『対象エージェント』の整合 |
| L2-002 | related の双方向参照整合性 |
| L2-003 | markdown-link-check 全リンク到達 |
| L2-004 | セマンティック類似度による blacklist 言い換え検出 |
| L2-005 | 総トークン数が Claude 200K の 40% 以内 |

### 5.3 Layer 3（行動検証）

| ID | 戦略 | 検証内容 |
|---|---|---|
| L3-001 | structural | 13 本の frontmatter + H2 + テーブル + 3 値の構造適合 100% |
| L3-002 | api_e2e | writer エージェントの企画→ドラフト→推敲で参照ドキュメント集合が期待と一致 |
| L3-003 | llm_judge | 4 軸（敬体・分析トーン・対照表・既存整合）平均 ≥ 0.75、最低軸 ≥ 0.65 |
| L3-004 | llm_judge | safe/borderline/violation の 3 サンプルで倫理判定が期待と一致（3/3） |
| L3-005 | agent_flow | critic-bench 10 サンプルで recall ≥ 0.80、precision ≥ 0.70、F1 ≥ 0.75 |
| L3-006 | cli_flow | writer CLI フロー出力に「倫理ガードレール判定」セクションが生成される |
| L3-007 | context_injection | reviser の参照順序 + 倫理二重検出が動作ログで確認（blocking: false） |

### 5.4 フェーズ

| フェーズ | 目標 | 生成対象 | 閾値 |
|---|---|---|---|
| MVP | writer 企画フェーズ動作最小構成 | #1, #2, #9（3 本） | mutation 0.4 |
| Core | 全 10 本完成 + 参照ルーティング機能 | 残り #3–#8, #10（7 本） | mutation 0.3 |
| Polish | 双方向参照 + セマンティック + critic 実機 | （拡充のみ） | mutation 0.2 |

---

## 6. Fallback / Abort

### Fallback（8 本圧縮案）
`Primary` 達成困難な場合に以下へ切替：
- #3 `emotional-arc-and-beforeafter` + #6 `reader-identity-invocation` → 「変容の見せ方」に統合
- #7 `transformation-narrative-translation` + #8 `framework-embedding-patterns` → 「フレームワーク翻訳ガイド」に統合

**切替トリガー**:
1. Task Planner で 10 本分がトークン予算超過
2. 既存 3 本の機械抽出で Tier 1 基盤知識が想定より網羅的 → 新規候補 3–4 本が実質重複
3. MVP 完了時点で累積トークン消費が予算の 50% 突破
4. ユーザーからの本数削減明示要請

### Abort（Phase 1 再実行）
以下 3 条件が **同時成立** した場合のみ：
- (A) ソース 6 本の商用ベクトル残留が言い換えでも分離不能
- (B) 既存 3 本が新規候補の独自価値領域を 3 本未満に縮退させる
- (C) 倫理 12 項目の自動判定が人手レビューなしで成立しない

現時点のエビデンスでは同時成立可能性は低く、**primary 採用を推奨**。

---

## 7. Locked Decisions との整合性

| Locked 項目 | 整合性 | 根拠視点 |
|---|---|---|
| 出力先 `make-jikok/templates/` | ✅ | alternatives / agent_routing / technical |
| 新規 10 本 ± 1 | ✅ | cost（7–12 本でコスト差 $0.3–0.8 に収束） |
| 分量 8–20KB | ✅ | technical（章構成比率標準と整合） |
| ハイブリッド読者層 | ✅ | agent_routing / technical |
| 敬体・分析的トーン継承 | ✅ | technical（機械抽出手順で実装） |
| 既存 3 本改変不可 | ✅ | alternatives（後方互換・Open/Closed） |
| 欲求喚起 OK / カルト NG の倫理線 | ✅ | ethics_boundary（認識論的自律性 + BITE + Cialdini） |
| 既存ポリシー継承 | ✅ | risk / agent_routing |
| 『関連ドキュメント』節相互参照 | ✅ | agent_routing / technical / cost |
| 『出典注記』節 | ✅ | cost（差分取込コスト最小化）/ risk |
| ケバブケース命名 | ✅ | technical（命名慣習抽出） |

**衝突**: なし。

---

## 8. 残存リスク（recommendations.primary.risks）

1. 既存 3 本の実コンテンツ未精読 → Tier 1 基盤知識の重複範囲が想定とずれる可能性（Phase 1.5 以降で検証）
2. ソース 6 本の実内容未読 → #7 / #8 のマッピング精度に不確実性
3. 倫理 12 項目の自動判定は先行ベンチマーク不在、偽陽性/偽陰性率が未知
4. 日本語陳腐フレーズ検出の標準リソース不在 → blacklist.md の辞書拡張で個別対応が必要
5. writer/reviser/critic 3 エージェント構成への適合は類推ベース、運用投入後の微調整必須
6. 日本語トークン効率は英語の 1.5–2 倍の可能性 → Phase 2 で課金予算上限設定推奨

---

## 9. ギャップ（未解決の調査事項）

| 領域 | ギャップ |
|---|---|
| ソース精読 | 6 本の具体内容（特に complete-transformation-theory / cult-belief-formation）の実精読は Phase 2 で実施 |
| 既存 3 本実装データ | 読了率・参照頻度・ユーザーフィードバックが不明で、帰納的比率最適化は保留 |
| 日本語対応ツール | cliché 検出・セマンティック類似度の日本語実装（kuromoji 等の性能検証）未確認 |
| エージェント環境 | Markdown パーサー・RAG 実装の最終選択が未確定（wiki-link vs MyST vs relative path） |
| 倫理判定 | 12 項目チェックリストの自動判定精度ベンチマークが存在しない |
| 文化的文脈 | 日本語圏固有の集団主義・関係性重視が倫理境界にどう影響するか未調査 |

---

## 10. 判定

**GO（Primary 推奨を採用）**

6 視点のエビデンスが `recommendations.primary` に収束し、locked decisions との衝突はなく、撤退条件の同時成立可能性も低い。Phase 1.5（Task Planner）→ Phase 2（Implementer）へ進めることを推奨する。

---

## 付録: 参考文献（主要出典）

| カテゴリ | 主要出典 |
|---|---|
| 実装科学 | Springer `FRAME` framework、ResearchGate `theory of change` |
| 情報アーキテクチャ | NN/G `Taxonomy 101`、MyST Parser cross-referencing |
| プロンプトキャッシング | Anthropic `prompt-caching docs`、Weaviate RAG chunking |
| リンク検証 | markdown-link-check、linkcheckmd、docsource |
| 倫理・操作境界 | Stanford Encyclopedia `ethics of manipulation`、Lifton 8 criteria、BITE モデル（Hassan）、Cialdini 6 原則 |
| カルト・アイデンティティ | Davenport Psychology、ResearchGate `Identity Fusion`、Freedom of Mind `BITE Model` |
| コンテンツ品質 | ReviewEval、PaperDebugger、llm-cliches キュレーション |
| エージェント設計 | LangChain router-knowledge-base、Agentforce RAG、PaperDebugger orchestrator |
| 日本語ライティング | エンパシーライティング（中野巧）、note 公式テンプレート、PREP/PASONA |

