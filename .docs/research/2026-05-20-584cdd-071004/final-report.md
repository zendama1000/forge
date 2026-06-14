# 健全ブランド設計 Claude Code スキル — 最終リサーチレポート

**リサーチ ID**: `2026-05-20-584cdd-071004`
**生成日**: 2026-05-20
**判定**: **GO (Primary 推奨案で Phase 1.5 へ進行)**

---

## 1. テーマと前提

**テーマ**: 雨宮純『カルト・ブランディング』の 6 セオリーを基盤に、**健全な**ブランド設計を提案する Claude Code スキル/エージェント。

**構成方針 (ロック済)**:
- orchestrator + 6 セオリー専門エージェント + ethics-reviewer の **7-8 体構成**
- **ハイブリッドナレッジ**: orchestrator が起動時に原本書籍 md を Read + 各セオリーエージェントは `references/theory-*.md` を Read
- **MVP 範囲**: 健全 3 セオリー (族・象徴・信念) は能動提案 / 危険 3 セオリー (敵・儀式・カリスマ) は警告のみ
- **技術スタック**: Claude Code agent (.md) のみ。HTTP サーバー / Node.js / package.json は禁止
- **出力先**: `brand-design-agent/` (git 初期化済 commit `dd8ae89`)

## 2. 調査スコープ

固定 4 視点 (technical / cost / risk / alternatives) + 動的 2 視点 (ethics / ux) の **6 視点 × 6 未決事項** を横断調査。

| 未決事項 | 内容 |
|---|---|
| 出力フォーマット | 単一 md / セオリー分割 / 対話 Q&A |
| 領域線引き | 健全/グレー/危険の機械判定ルール |
| ガードレール方式 | 事後一段 / プロンプト埋込 / 併用 |
| オーケストレーション | 順次 / 並列 / 反復 |
| 入力スキーマ | 項目数と粒度 |
| Assertions 設計 | 機械的検証手段 |

---

## 3. 視点別の要点

### 3.1 技術視点 (technical)

| 観点 | 知見 |
|---|---|
| サブエージェント呼出 | `claude -p` モードでは **subagent chain が動作しない** (2026-04-12 実地検証済)。対話モードで Task ツール経由なら動作するが、L3 自動検証は限定的 |
| 書籍 md のトークン消費 | 1244 行 ≒ **約 43,540 tokens** (推定)。Sonnet/Opus 4.6/4.7 の 1M コンテキスト窓に対し **約 4.4%** で収容可 |
| references 参照 | `@import` / 相対パスとも信頼性高。再帰 5 段階制限あり |
| Write 権限 | CWD 配下の `content/` であればデフォルト OK。`Bash(mkdir:*)` の許可は Issue #17321 で既知バグあり → **Write の中間ディレクトリ自動作成に委譲**が安定 |

**最大の技術的制約**: L3 `agent_flow` strategy は `human_check` + 成果物 grep/wc 検証へ降格が必須。

### 3.2 コスト視点 (cost)

| 項目 | 試算 (Sonnet 4.6、月 600 セッション) |
|---|---|
| フルロード (キャッシュなし) | 約 **$59.40/月** |
| 要約のみ (キャッシュなし) | 約 **$13.50/月** |
| フルロード (5分キャッシュあり) | **約 $5.94/月** |
| 要約 (5分キャッシュあり) | 約 $1.35/月 |

→ **プロンプトキャッシュ有効化が最大のコスト低減レバー**。フルロード vs 要約の差は実質 $4.59/月に縮小し、ハイブリッドナレッジ案のコスト懸念は事実上解消。

**Phase 2 タスク数概算**: 積極バンドリングで 12-13 タスク、品質安定性を踏まえると **15-18 タスク**が推奨レンジ。

### 3.3 リスク視点 (risk)

5 つの主要失敗モードが文献+プロジェクト実績で確認された。

| # | 失敗モード | 根拠 | 信頼度 |
|---|---|---|---|
| 1 | 警告専用エージェントの role drift / semantic drift で肯定的提案を生成 | arxiv 2601.04170 (Agent Drift), Trend Micro (Sockpuppeting), OWASP LLM01 | high |
| 2 | 原本 md 読込失敗時のサイレント縮退 | Galileo / Chroma 研究 | medium |
| 3 | 悪用意図検知の婉曲表現バイパス | arxiv 2505.18556 (Intent Manipulation) | medium |
| 4 | セオリー横断矛盾で orchestrator が無限ループ (MAST `Infinite Loop` パターン) | NeurIPS 2025 MAST taxonomy, "Bag of Agents" 17x エラー率 | high |
| 5 | Implementer 30 ファイル制限超過でロールバック | プロジェクト実績 (2026-03-04 事例) | high |

`grep_absent` は意味論的言い換え (例: 「~を検討する価値がある」) を捕捉できないため **literal 層単体では不十分**。

### 3.4 代替案視点 (alternatives) — 各問いの推奨

| 未決事項 | 採用案 | 根拠 |
|---|---|---|
| 出力フォーマット | **(A) 単一統合 brand-design.md** | brand.md / DESIGN.md 業界標準パターンと一致 |
| オーケストレーション | **(B) 並列呼出 + 統合** | 階層型 F1=0.921 @ 1.4× コストで Pareto 最適 (arxiv 2603.22651) |
| ガードレール | **(C) 両者併用** | 多段防御で攻撃成功率 20-30% → 0% (arxiv 2509.14285)、Meta "Agents Rule of Two" |
| ナレッジ参照 | **(B) 担当章のみ Read** | トークン効率と専門精度のバランス、TeaRAG 等の支持 |
| 警告提示 | **(B) inline + (A) 別セクション** | labeling fatigue 回避と文脈提供の両立 |

### 3.5 倫理視点 (ethics)

学術的に確立された 3 フレームワークが直接利用可能:

1. **BITE モデル** (Steven Hassan) — Behavior / Information / Thought / Emotional 4 次元
2. **Lifton 8 基準** — Milieu Control, Mystical Manipulation, Loading the Language ほか
3. **MentalManip データセット** (ACL 2024) — ガスライティング / 罪悪感誘発 等 5 分類

**「説明するが提案しない」境界の機械判定** (4 基準):
- 出力動詞分析 (命令形/二人称推奨形の検出)
- ターゲット指定の有無 (実在グループの特定)
- 手法の問題性の明示 (操作的であることを文中で明言)
- 代替提案の存在

**警告文言の最小要素**: 「**なぜ危険か**」+「**健全な代替アプローチ**」の 2 要素 (4 要素全載は理想だが必須ではない)。

**累積カルト特性の集約判定**: BITE 4 次元 × Lifton 8 基準のクロスチェックで閾値判定 (BITE 2 次元以上 or Lifton 3 基準以上 → 中リスク / BITE 3 次元以上 or Lifton 5 基準以上 → 高リスク)。

### 3.6 UX 視点 (ux)

| 項目 | 推奨値 / 設計 |
|---|---|
| 入力ヒアリング項目数 | **5 問以内** (完走率: 1-3問 83% / 4-8問 65% / 9-14問 56% / 15問+ 42%) |
| 出力構成 | コア = ブランド設計案 + 末尾 = 3-5 項目のアクションサマリー |
| 専門用語 | 平易表現をデフォルト + 括弧内補足 (例: 「核心的な使命 (ブランドパーパス)」) |
| 初心者/改善者モード | 1 問の自己申告 + プロンプト内部分岐 (UI 単一) |
| ethics-reviewer 介入時 | **ソフトモデレーション** (理由説明 + 代替案提示) |

平易言語 vs ジャーゴンの読解テスト: 80% vs 50%、1 時間後の保持量 34 ポイント vs 12 ポイント。

---

## 4. 視点間の矛盾とその統合解決

| # | 対立 | 解決方針 |
|---|---|---|
| 1 | alternatives (並列+統合推奨) vs risk (Bag of Agents 17x エラー警告) | MVP は並列+統合を採用しつつ、orchestrator に **優先順位ルール**(健全 1/3/4 > 警告 2/5/6) + **Council Mode 型統合プロトコル** + **最大反復回数制限**を明示実装 |
| 2 | alternatives (担当章のみ Read 推奨) vs ロック決定 (orchestrator 一度読込) | **2 層構造を維持**: 各エージェントは `references/theory-*.md` を読み、原本ニュアンスは orchestrator 経由で取得 |
| 3 | ethics (grep_absent 有効) vs risk (literal だと言い換え捕捉不可) | **三層 defense-in-depth**: layer 1 = grep_absent literal / layer 2 = ethics-reviewer LLM / layer 3 = 各エージェントプロンプト埋込 |
| 4 | cost (非同期推奨で遅延ゼロ) vs risk (同期事後レビュー必須) | MVP は **同期事後レビュー** (2-8 秒遅延を許容、安全性優先)。非同期化は Post-MVP 課題 |

---

## 5. Primary 推奨アクション

### 5.1 実装方針 10 項

1. **出力フォーマット**: 単一統合 `brand-design.md` (avoid-section を同一ファイル内に分離配置 + inline 注意喚起の二段構成)
2. **オーケストレーション**: 並列呼出 + orchestrator 統合 (Council Mode 型、調停ルールを `orchestrator.md` に明文化)
3. **ガードレール**: 三層 defense-in-depth (grep_absent literal + ethics-reviewer LLM + 各エージェントプロンプト内禁止事項埋込)
4. **ナレッジ参照**: 2 層構造 (orchestrator が原本 md + `references/`、各エージェントは担当章のみ参照)
5. **入力**: 5 問以内 (業種・ターゲット・価値観・規模・新規/既存)
6. **出力**: 専門用語の平易化 (括弧内補足) + 末尾アクションサマリー 3-5 項目
7. **ethics-reviewer**: 同期事後レビュー (MVP は安全性優先)
8. **Assertions**: `file_exists` (7-8 agent + skill + references) + `grep_present` (警告 4 要素) + `grep_absent` (警告系に肯定動詞なし)
9. **タスク分割**: 15-18 タスク (各エージェントを独立タスク化、references は 2-3 タスクに分散)
10. **L3 検証**: `claude -p` 不可制約より `human_check` + 成果物 grep/wc 検証に降格

### 5.2 残存リスクと対処

| リスク | 対処 |
|---|---|
| セオリー横断矛盾で orchestrator 無限ループ | 調停ルール明文化 + `max_iterations` 制限 |
| Implementer 30 ファイル制限超過 | タスク粒度 1-3 ファイルに分割、references を複数タスクに分散 |
| `claude -p` L3 不動作 | `human_check` + 成果物 grep/wc 検証で代替、L1 は機械実行可 |
| 警告エージェントの semantic drift 見逃し | grep_absent + ethics-reviewer LLM の二段防御 |
| 原本 md 読込失敗時のサイレント縮退 | `orchestrator.md` 冒頭で明示的エラー停止ルールを記述 |
| 同期 ethics-reviewer の 2-8 秒遅延 | Post-MVP の非同期化候補として残す |
| 日本語悪用意図検出データ不足 | MVP 運用後のログ分析でフィードバックループ構築 |

### 5.3 フォールバック (切替トリガー)

並列+統合で品質劣化や無限ループが頻発した場合、**順次呼出 (A) に切替**: orchestrator がセオリー 1→3→4 (健全) → 2/5/6 (警告) → ethics-reviewer の固定順序で実行。所要時間は約 2 倍に伸びるが品質安定性とデバッグ容易性が向上。

**切替トリガー条件**:
- Phase 2/3 で orchestrator 統合段の矛盾検出が 3 回以上連続発生
- ethics-reviewer fail 率が 30% 超過
- MAST パターン (Infinite Loop / role 拒否) のログが観測される
- 統合出力がセオリー単体出力より明確に品質劣化

---

## 6. 実装基準 (implementation-criteria) サマリ

### 6.1 Layer 1 (構造検証) — 7 項目

| ID | 検証内容 | テストタイプ |
|---|---|---|
| L1-001 | `SKILL.md` の存在と必須セクション (## 入力 / ## 出力 / ## オーケストレーション) | lint |
| L1-002 | 8 体のエージェント `.md` 存在 + フロントマター + 400 文字以上 | api_check |
| L1-003 | 警告系 3 ファイルに肯定動詞 (推奨/活用/取り入れる/導入する/おすすめ) が出現しない | lint |
| L1-004 | `ethics-reviewer.md` に BITE / Lifton 参照 + チェックリスト 5 項目以上 | lint |
| L1-005 | `references/theory-*.md` 6 ファイル + `INDEX.md` 存在、各 300 文字以上 | api_check |
| L1-006 | `orchestrator.md` に調停ルール (優先順位/最大反復/原本失敗時停止/事後レビュー) 明文化 | lint |
| L1-007 | 各セオリーエージェントに統一出力フォーマット (4 要素: 手法名 / 典型例 / なぜ危険(有効) / 健全代替) | lint |

### 6.2 Layer 2 (結合検証) — 3 項目

| ID | 検証内容 |
|---|---|
| L2-001 | Claude Code がスキルディレクトリを認識可能 |
| L2-002 | 各エージェント `.md` がフロントマター `name:` 一意 |
| L2-003 | 原本書籍 md が WORK_DIR 配下に配置 + 参照パスから到達可能 |

### 6.3 Layer 3 (行動検証) — 5 項目

| ID | strategy | success_threshold | blocking |
|---|---|---|---|
| L3-001 | structural | 必須セクション 4 つ全部 hit + 1500 文字以上 + アクション 3-5 項目 | ○ |
| L3-002 | structural | 6 セオリー全セクション + 警告系に「代替/健全/alternative」共起 | ○ |
| L3-003 | llm_judge | 4 観点平均 0.75 以上、警告系の role drift 単独で 0.80 以上 | ○ |
| L3-004 | agent_flow | ethics-reviewer が drift サンプルを reject + 理由 + 代替を出力 | - |
| L3-005 | agent_flow | エッジケース入力 (排他コミュニティ) で警告 + 健全代替 + 矛盾なし完了 | - |

### 6.4 開発フェーズ (3 段階)

| Phase | 目標 | Mutation 閾値 |
|---|---|---|
| **mvp** | orchestrator + 健全系 1 体 (tribalism) + 警告系 1 体 (enemy) + ethics-reviewer の最小 4 体構成で E2E 1 フロー動作 | 0.40 |
| **core** | 6 セオリー全実装、orchestrator 調停動作、ガードレール三層稼働 | 0.30 |
| **polish** | 矛盾入力エッジケースで安定着地、ethics-reviewer drift 検出、UX 要件 (5問/平易化/アクション 3-5) 整備 | 0.20 |

---

## 7. 主なギャップ (要追加調査または運用観測)

- Windows (Git Bash/MSYS) 環境での `expect` スクリプトによる interactive mode 擬似自動化の実動作未確認
- 日本語テキストでのトークン数は推定値であり、API token-counting で実測が望ましい
- `additionalDirectories` の Read/Write 不整合バグ (Issue #29013) が現バージョンで修正済みか未確認
- ブランドデザイン特定ドメインでの A/B 比較実験データなし (ベンチマークは金融・コード生成等)
- 日本語コンテキストでの悪用意図検出精度の研究データ不足 (既存研究の多くは英語)
- BITE/Lifton 閾値 (BITE 2 次元以上=中リスク 等) はフレームワーク論理からの導出で実証根拠なし

---

## 8. 判定

**GO — Primary 推奨案で Phase 1.5 へ進行**。

- 技術的実現性 (technical): ✅ 制約は既知で代替策あり
- コスト許容性 (cost): ✅ プロンプトキャッシュで月 $6 程度に収まる
- 倫理学術裏付け (ethics): ✅ BITE / Lifton / MentalManip で十分に裏付けあり
- UX 設計可能性 (ux): ✅ 5 問入力 + 平易化 + アクションサマリーで実用可能
- リスク対処性 (risk): ✅ 5 主要失敗モードに対し三層防御 + 調停ルール + タスク分割で構造的に低減

過去の決定事項との衝突なし。代替投資先 (他の自己改修バッチ、uranai-concept 拡張) と比較しても、本テーマ独自の戦略価値 (起業家・マーケター向け健全ブランド設計支援 + カルト的手法への気づき提供) が独立した社会的意義を持つため、アボートではなく **Primary 推奨を進めるべき**と結論する。

---

## 付録: 参照ファイル一覧

- `investigation-plan.json` — 調査計画 (6 視点 × 6 未決事項)
- `perspective-technical.json` — 技術的実現性
- `perspective-cost.json` — コスト・リソース
- `perspective-risk.json` — リスク・失敗モード
- `perspective-alternatives.json` — 代替案比較
- `perspective-ethics.json` — 倫理ガードレール設計
- `perspective-ux.json` — ユーザー体験
- `synthesis.json` — 6 視点統合と矛盾解決
- `implementation-criteria.json` — L1/L2/L3 検証基準 + 3 フェーズ exit_criteria
