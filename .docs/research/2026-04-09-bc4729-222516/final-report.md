# make-salesletter HTTPサーバー → Claude Codeスキル完全移行 リサーチレポート

**Research ID:** `2026-04-09-bc4729-222516`
**調査日:** 2026-04-09
**テーマ:** Express全削除、Phase制御型サブエージェント構成への移行設計

---

## 1. エグゼクティブサマリー

6視点（技術的実現性・コスト・リスク・代替案・生成物品質・保守性）の横断分析の結果、**移行は技術的に実現可能だが、4つの構造的リスクへの事前対策が不可欠**という結論に至った。

推奨構成は **4Phase構成 + ハイブリッド状態管理 + SKILL.mdループ制御**。開発工数はForge Harness利用で **0.5〜1人日（監視工数）** に圧縮見込み。

---

## 2. 調査スコープ

### 2.1 コア質問（7件）

| # | 質問 |
|---|------|
| 1 | 現行4フェーズをPhaseエージェントにどうマッピングするか？ |
| 2 | セクション生成のoverlap_context依存を並列化できるか？ |
| 3 | 非再帰サブエージェント制約下でリライトループをどう実装するか？ |
| 4 | references/ディレクトリの理論ファイル構成・命名規約は？ |
| 5 | 4Dルーブリック評価の信頼性をどう強化するか？ |
| 6 | パイプライン中間状態をどう永続化するか？ |
| 7 | 商品注入は統合フェーズと分離すべきか一体化すべきか？ |

### 2.2 ロック決定事項（変更不可）

1. Express完全削除（HTTPエンドポイント残存不可）
2. references/ディレクトリに理論ファイルを配置
3. Markdown形式で最終出力
4. Agent toolでPhase制御
5. uranai-conceptパターンを踏襲
6. 作業ディレクトリ固定

### 2.3 露出した前提（8件）

| 前提 | リスク |
|------|--------|
| Phase対応仮定 | uranai-conceptは人間対話Phase含む3Phaseであり、全LLM処理の本ケースと構造が本質的に異なる |
| 並列化仮定 | overlap_context（前セクション末尾200文字）が順次依存構造 → 並列化で接続品質が低下する可能性 |
| 理論ファイル静的仮定 | ユーザーが理論を追加・変更した場合のメタフレーム再生成フローが未定義 |
| LLMセルフ評価信頼仮定 | self-enhancement bias（自分の生成物を高く評価する偏り）が未検証 |
| プロンプトサイズ仮定 | 6理論ファイル全文＋メタフレーム＋セクションで数万トークンに達する可能性 |
| 状態管理仮定 | 単一JSONでは大量の中間生成物を管理困難な可能性 |
| リライトループ仮定 | ループ制御をどの層が担うか未決定 |
| In-Memory不要仮定 | ファイルI/O遅延のパフォーマンス影響は未検証 |

---

## 3. 視点別調査結果

### 3.1 技術的実現性（confidence: high）

**結論: 4段パイプラインはAgent tool制約下で実現可能。**

| 項目 | 所見 |
|------|------|
| **非再帰制約の回避** | オーケストレーター→単層サブエージェント委任で回避可能。各Phaseのツールセットはホワイトリストで最小権限化 |
| **セクション並列化** | overlap_context依存は本質的に順次依存。「独立並列生成 → seam adjustment統合」の2段バッチ方式で解決。foreground並列推奨（background並列は権限コールバックバグあり） |
| **状態管理** | 分割ファイル方式推奨。phase-state.jsonがパス参照を持ち、draft/sectionsは外部ファイル化 |
| **理論ファイル注入** | 15-25KBは1Mトークンコンテキストに対して余裕。Phase-Aで全文読込→メタフレーム抽出→以降は要約のみ渡す |

**推奨ツールセット:**

| Phase | 許可ツール | 理由 |
|-------|------------|------|
| Phase-A（メタフレーム抽出） | Read, Grep, Glob, WebSearch | 読み取り専用 |
| Phase-B（セクション生成） | Read, Write | 参照読取＋出力書込 |
| Phase-C（統合） | Read, Write, Edit | セクション読取＋統合＋seam編集 |
| Phase-D（評価） | Read, Grep, Glob | 読み取り専用 |

### 3.2 コスト・リソース（confidence: medium〜high）

**結論: Agent toolオーバーヘッドは無視できないが、キャッシュ＋モデルルーティングで制御可能。**

| 項目 | 数値・所見 |
|------|-----------|
| **Agent toolオーバーヘッド** | 最適化前: ~50Kトークン/回、アイソレーション最適化後: ~5Kトークン/回 |
| **プロンプトキャッシュ** | 最大90%削減（0.1x読出し価格）。TTL 5分、最小キャッシュサイズ 2,048トークン |
| **モデル価格比較** | Opus: $5/$25 (入/出)、Sonnet: $3/$15、Haiku: $1/$5（/MTok） |
| **開発工数** | 手動: 2.5〜4.5人日 → Forge Harness利用: 0.5〜1人日（監視） |

**推奨モデルルーティング:**

| Phase | モデル | 理由 |
|-------|--------|------|
| Phase-A（メタフレーム抽出） | Opus | メタ認知・構造把握に高精度が必要 |
| Phase-B/C（生成・統合） | Sonnet | コスト対効果のバランス |
| Phase-D（形式チェック） | Haiku | 単純な比較・スコア付け |
| Phase-D（意味評価） | Sonnet | 品質判定に一定の推論力が必要 |

### 3.3 リスク・失敗モード（confidence: high）

**結論: 4つのリスク全てに具体的証拠が存在し、移行前の対策設計が必須。**

#### リスク一覧

| # | リスク | 深刻度 | 根拠 |
|---|--------|--------|------|
| R1 | **品質デグレーション** | 高 | SKILL.md指示遵守率70〜90%（コード100%との対比）。JSON出力形式崩れ（markdown fence付き、フィールド欠損等）が既知問題 |
| R2 | **状態破損** | 高 | 現行post-write-verify.shはwarning-only（async:true, exit 0常時）。Claude Code自身の.claude.json破損がGitHub issue複数報告（#29051, #29395, #28842） |
| R3 | **リライトループ暴走** | 中 | LLM self-enhancement bias実証済み（arxiv 2404.13076）。ループ制御をLLM指示に依存するとスコア非収束リスク |
| R4 | **理論ファイル欠損** | 中 | 検知タイミングがPhase-A実行時まで遅延。現行の即時バリデーション（POST /api/theory/upload → HTTP 400）が失われる |

#### 連鎖リスク構造

```
JSON品質劣化 → 評価スコア不安定 → ループ制御誤動作 → 状態ファイル破損
```

各段階での防御層（JSONスキーマ検証、multi-eval平均化、maxTurnsハードリミット、atomic write）の設計時組込みが必要。

### 3.4 代替案比較（confidence: medium〜high）

#### Phase構成の比較

| 構成 | メリット | デメリット | 評価 |
|------|---------|-----------|------|
| **(A) 4Phase（推奨）** | 既存実装からの移行コスト最小。単一責任原則充足。部分リトライ粒度確保 | 中庸ゆえに品質最大化ではない | **採用** |
| (B) 3Phase統合 | API呼出し削減、レイテンシ低下 | 各フェーズの責任肥大、部分再実行困難 | コスト最重視時のフォールバック |
| (C) 5Phase分離 | 各フェーズ責任最小化、並列化・部分リトライ容易 | API呼出し増、オーケストレーション複雑度増 | WritingPath研究は品質面で支持するが過剰 |

#### リライトループ実装方式の比較

| 方式 | メリット | デメリット | 評価 |
|------|---------|-----------|------|
| **(A) SKILL.mdループ制御（推奨）** | オーケストレーターパターン準拠、閾値・上限を外部制御 | SKILL.md条件分岐はLLM判断依存（再現性低） | **採用**（maxTurns併用） |
| (B) Phase内自己ループ | コンポーネント最少 | ストップ条件バグ、コンテキスト肥大化リスク | 非推奨 |
| (C) 専用リライトPhase | LangChain/AWS推奨パターン準拠、責任分離明確 | Phase数増加、コスト増 | 将来検討 |

#### 品質評価強化の比較

| 方式 | 効果 | コスト影響 | 評価 |
|------|------|----------|------|
| (A) 現行ルーブリック維持 | なし | なし | 不十分 |
| **(B+C) 多次元ルーブリック＋複数回評価（推奨）** | RMSE 2倍改善（LLM-Rubric研究） | 2〜3倍 | **採用**（Phase-Dのみ適用） |
| (D) 機械的キーワードチェック | 決定論的・高速 | 最小 | 補助として採用 |

#### 状態永続化方式の比較

| 方式 | メリット | デメリット | 評価 |
|------|---------|-----------|------|
| (A) phase-state.json単一 | シンプル | 大ファイル化、並列書込み競合、クラッシュ時破損リスク高 | 非推奨 |
| (B) 完全分割 | 部分再実行容易 | ライフサイクル管理複雑 | 過剰 |
| **(C) ハイブリッド（推奨）** | メタデータはJSON、大きな生成物は個別ファイル | 設計が必要 | **採用** |

### 3.5 生成物品質（confidence: high〜medium）

**結論: 品質リスクは「情報の構造化粒度」に集中。**

| 項目 | 所見 |
|------|------|
| **プロンプトチェーン分断** | ファイル永続化は構造化JSONで実装すれば品質向上要因になりうる。ただしoverlap_contextをraw textで保存するとセクション間継続性が最も毀損される |
| **理論反映度の定量化** | regex＋LLM-as-judgeハイブリッドで機械検証可能。ハルシネーション率65.2%→1.6%削減の実証あり |
| **AIDA5バンド配分** | 固定比率（8/22/35/20/15%）は出発点として合理的。商品特性（価格帯・関与度）に応じた動的調整に理論的根拠あり |

**overlap_contextの推奨構造:**
```json
{
  "prior_summary": "直前段落の要約（50-200文字）",
  "tone": "文体・トーンの記述",
  "open_points": ["未解決の論点1", "未解決の論点2"]
}
```

### 3.6 保守性・拡張性（confidence: high）

**結論: git diff可読性は向上するが、テストパラダイムが根本的に変わる。**

| 項目 | 現行（TypeScript） | 移行後（.md） |
|------|-------------------|---------------|
| **プロンプト管理** | コード内テンプレートリテラル（共配置） | .claude/agents/*.md（git diff可読性向上） |
| **テスト** | vitest ユニットテスト（決定論的） | 決定論テスト（TS関数）＋LLM eval（pass@k） |
| **理論ファイル追加** | APIアップロード＋コード修正 | references/配置＋Dynamic Context Injection |

**テスト戦略の二層分離:**

| 層 | 対象 | 手法 | 実行頻度 |
|---|------|------|---------|
| 第1層 | 決定論的ロジック（TypeScript純粋関数） | vitest ユニットテスト | 毎コミット |
| 第2層 | エージェントパイプライン挙動 | LLM-as-judge + pass@k | マージ時/nightly |

**理論ファイル自動認識の設計:**
- SKILL.mdに `!`ls ${CLAUDE_SKILL_DIR}/references/*.md`` を組み込む（Dynamic Context Injection）
- これにより references/ にファイル追加するだけで次回実行時に自動認識

---

## 4. 視点間の矛盾と解決

| # | 対立する視点 | 矛盾の内容 | 解決策 |
|---|-------------|-----------|--------|
| 1 | technical ↔ risk | 技術的には動作するが、SKILL.md遵守率70-90%でJSON品質が劣化 | JSONスキーマバリデーション層＋自動リトライ（max 2回）を追加 |
| 2 | cost ↔ alternatives | API呼出し最小化（3Phase志向）vs フェーズ細分化（5Phase志向） | 4Phase採用。コスト制御はキャッシュ＋モデルルーティングで対応 |
| 3 | technical ↔ content_quality | 並列生成は技術的に可能だが、overlap_context無しで品質劣化 | 構造化メタデータで保存＋統合フェーズでseam adjustment |
| 4 | alternatives ↔ risk | 専用リライトPhase推奨 vs LLMループカウンタ信頼性問題 | SKILL.mdがループ制御（A案）＋maxTurnsハードリミット＋multi-eval |
| 5 | cost ↔ content_quality | 品質評価Haiku化 vs 多次元評価（2-3倍コスト増） | Sonnet 2回評価を標準。Haikuは形式チェックのみ |
| 6 | risk ↔ maintainability | 状態破損の高リスク vs 保守性視点でのatomic write未言及 | atomic write（tmp+mv）を移行の前提条件として実装 |

---

## 5. 推奨設計（Primary）

### 5.1 全体アーキテクチャ

```
SKILL.md（オーケストレーター）
  │
  ├─→ [Pre-flight] references/必須ファイル確認 + phase-state.jsonレジューム判定
  │
  ├─→ Phase-A（sl-phase-a.md / Opus）
  │     理論ファイル全文読込 → 構造化メタフレーム抽出
  │     出力: state/metaframe.json
  │
  ├─→ Phase-B（sl-phase-b.md / Sonnet）
  │     アウトライン生成 → セクション並列生成（独立生成）
  │     出力: state/outline.json, state/sections/section-{01..N}.md
  │
  ├─→ Phase-C（sl-phase-c.md / Sonnet）
  │     セクション統合 + 商品情報注入 + Seam Adjustment
  │     出力: state/draft.md
  │
  ├─→ Phase-D（sl-phase-d.md / Sonnet+Haiku）
  │     4Dルーブリック評価（2回平均化）+ regex理論キーワードチェック
  │     出力: state/evaluation.json
  │
  └─→ [ループ制御] スコア < 閾値 → Phase-C再実行（max 2回）
        安全網: maxTurnsハードリミット
```

### 5.2 状態管理（ハイブリッド方式）

```
state/
├── phase-state.json     ← メタデータ + パス参照（軽量）
├── metaframe.json       ← Phase-A出力（構造化JSON）
├── outline.json         ← Phase-B出力（アウトライン）
├── sections/
│   ├── section-01.md    ← 各セクション個別ファイル
│   ├── section-02.md
│   └── ...
├── draft.md             ← Phase-C出力（統合テキスト, 2万文字超）
└── evaluation.json      ← Phase-D出力（4Dスコア）
```

全状態ファイル書込みに **tmp+mv アトミック置換パターン** を適用。

### 5.3 品質評価設計

- **4Dルーブリック維持:** 構造（30点）/ 理論反映度（25点）/ 可読性（20点）/ CTA効果（25点）
- **2回評価平均化:** Sonnetで2回実行し分散を低減（LLM-Rubric研究: RMSE 2倍改善）
- **regex補助チェック:** 理論キーワード出現率を機械的に検証
- **Haikuの用途限定:** 形式チェック（JSONスキーマ検証）のみ

### 5.4 防御層設計

| 層 | 対象リスク | 機構 |
|----|----------|------|
| 第1層 | JSON品質劣化 | スキーマバリデーション + 自動リトライ（max 2回） |
| 第2層 | 評価スコア偏り | 2回評価平均化 + regex補助 |
| 第3層 | ループ暴走 | SKILL.md内明示的カウンタ + maxTurnsハードリミット |
| 第4層 | 状態破損 | atomic write（tmp+mv） |
| 第5層 | 理論ファイル欠損 | pre-flightバリデーション（スキル起動直後） |

---

## 6. フォールバック計画

### 6.1 フォールバック構成（3Phase簡略化）

| Phase | 内容 |
|-------|------|
| Phase-A | 準備: メタフレーム＋アウトライン |
| Phase-B | 生成: セクション順次生成＋統合＋商品注入 |
| Phase-C | 評価＋リライト（phase内ループ max 2回） |

- セクション並列化を断念（全て順次処理）
- 品質評価は4Dルーブリック1回のみ
- 状態管理は phase-state.json + draft.md の最小分割

### 6.2 フォールバック切替トリガー

| # | 条件 |
|---|------|
| 1 | セクション間seam quality（人間評価）が現行比で明確に劣化 |
| 2 | JSONスキーマ検証リトライ2回超過が全実行の20%以上 |
| 3 | リライトループがmax_turns到達（品質未達のまま打切り）が全実行の50%以上 |

### 6.3 中止条件

- Agent toolの制約がAnthropicの方針変更で大幅に厳格化された場合
- SKILL.md指示遵守率の構造的改善が見込めず、フォールバックでもJSON安定性が許容水準に達しない場合
- キャッシュ＋ルーティング適用後もAPIコストが現行パイプラインの5倍以上

---

## 7. 実装基準（Implementation Criteria）

### 7.1 Layer 1（静的検証 — 12件）

| ID | 検証内容 | テスト種別 |
|----|---------|-----------|
| L1-001 | SKILL.mdエントリポイント構造（4Phase指示・DCI・ループ制御・プリフライト） | lint |
| L1-002 | Phaseサブエージェント定義4体（sl-phase-a〜d.md）の存在と入出力定義 | lint |
| L1-003 | references/理論ファイル整合性（1本以上、各5000バイト以上） | unit_test |
| L1-004 | 状態管理JSONスキーマ定義（phase-state, metaframe, outline, evaluation） | unit_test |
| L1-005 | Phase出力JSONスキーマ検証ロジック＋自動リトライ（max 2回） | unit_test |
| L1-006 | Express/Honoコード完全削除（ルート・起動コード・依存パッケージ） | api_check |
| L1-007 | アトミックライトパターン実装（tmp→mv） | unit_test |
| L1-008 | プリフライトバリデーション（必須ファイル確認・レジューム判定） | unit_test |
| L1-009 | リライトループ機械的制御（カウンタ永続化・max 2回・閾値判定） | unit_test |
| L1-010 | 品質ルーブリック4D定義（構造30/理論25/可読20/CTA25） | unit_test |
| L1-011 | overlap_context構造化ストレージ（prior_summary/tone/open_points） | unit_test |
| L1-012 | モデルルーティング設定（A→Opus, B/C→Sonnet, D→Sonnet/Haiku） | lint |

### 7.2 Layer 2（統合テスト — 8件）

| ID | 検証内容 | 前提条件 |
|----|---------|---------|
| L2-001 | Agent Tool E2Eフロー（SKILL.md → Phase-A呼出し → metaframe受信） | API Key, Claude Code環境 |
| L2-002 | Phase-Aメタフレーム抽出精度（理論6ファイルからの構造化抽出） | API Key, 理論ファイル6本 |
| L2-003 | Phase-Bセクション並列生成（5-8セクション, naming convention準拠） | API Key, Phase-A完了 |
| L2-004 | Phase-C統合＋商品注入＋Seam Adjustment（draft.md ≥ 20000文字） | API Key, Phase-B完了 |
| L2-005 | Phase-D多次元品質評価（4Dスコア × 2回評価 → evaluation.json） | API Key, Phase-C完了 |
| L2-006 | リライトループ収束テスト（閾値未達→再実行→再評価サイクル） | API Key, Phase-C/D完了 |
| L2-007 | 中断復帰テスト（Phase-B途中中断→phase-state.json基づく再開） | API Key, 中断シミュレーション |
| L2-008 | Dynamic Context Injectionランタイム（新規理論ファイル自動認識） | Claude Code環境 |

### 7.3 Layer 3（E2E・品質評価 — 6件）

| ID | 検証内容 | ブロッキング |
|----|---------|-------------|
| L3-001 | フルパイプラインE2E（4Phase完走、全中間ファイル生成、draft ≥ 20000文字） | **Yes** |
| L3-002 | 出力構造完全性（ヘッドライン・本文5セクション以上・CTA・追伸・AIDA配分±10%） | **Yes** |
| L3-003 | トーン一貫性判定（LLM-judge, 閾値0.7） | No |
| L3-004 | 理論反映度判定（LLM-judge + regex, 閾値0.7） | No |
| L3-005 | 状態ファイル整合性チェーン（パス参照先全実在、current_phaseとファイル群の整合） | **Yes** |
| L3-006 | セクション接続品質/Seam Quality（LLM-judge, 閾値0.6） | No |

### 7.4 開発フェーズ

| フェーズ | ゴール | 対象基準 |
|---------|--------|---------|
| **MVP** | SKILL.md骨格 + Phase-A単独動作 + Express完全削除 | L1-001,002,003,006 / L2-001,002 |
| **Core** | 4Phase全パイプラインE2E + 品質評価ループ + 状態管理 + アトミックライト | L1-004,005,007,009,010,011,012 / L2-003,004,005,006 |
| **Polish** | エラー耐性強化 + 動的拡張性 + 中断復帰 | L1-005,008 / L2-007,008 |

---

## 8. 残存ギャップ・未調査事項

| # | ギャップ | 影響 |
|---|---------|------|
| 1 | TypeScript system prompt vs MD形式間のJSON出力失敗率の定量ベンチマーク | 移行前A/Bテストが必要 |
| 2 | overlap_context有無でのseam quality差の定量データ | 並列化設計の品質保証に影響 |
| 3 | Claude CodeのSIGINT（Ctrl+C）受信時にPostToolUseフックを実行するかの公式仕様 | 状態破損対策の信頼性に影響 |
| 4 | Dynamic Context Injectionが.claude/agents/*.mdでも同等に動作するか | Phase エージェント内での理論ファイル参照方法に影響 |
| 5 | Windows環境でのrename() EPERM問題（Claude Code自身のissue #28842として未解決） | atomic write パターンの信頼性に影響 |
| 6 | 日本語テキスト20KBの正確なトークン数 | コスト見積もり精度に影響 |
| 7 | 現行14ユニットテストの内訳（純粋TS関数 vs エージェント挙動テスト） | vitest継続可能割合の見積もりに影響 |
| 8 | LLMセルフ評価スコアの分布データ（日本語セールスコピー文脈でのself-enhancement bias強度） | 品質評価設計の最適化に影響 |

---

## 9. エビデンス出典（主要）

### 学術論文・研究
- WritingPath: 5フェーズフルパイプラインの品質優位性（arxiv 2404.13919）
- LLM-Rubric: 多次元アンサンブル評価でRMSE 2倍改善（arxiv 2501.00274, ACL 2024）
- Self-Refine: 反復的自己フィードバックで5-40%品質向上（arxiv 2303.17651）
- LLM Evaluators自己バイアス実証（arxiv 2404.13076）
- CaveAgent: 中間状態のコンテキスト分離（arxiv 2601.01569）
- AdaRubric: タスク適応的ルーブリック（arxiv 2603.21362）

### 公式ドキュメント・技術ガイド
- Anthropic: サブエージェント設計、Agent SDK権限管理、プロンプトキャッシュ、モデル選択ガイド
- AWS: Evaluator-Reflect-Refineループパターン
- MindStudio: SKILL.mdアーキテクチャ（プロセス/コンテキスト分離）
- LangChain: Reflection Agents（ジェネレーター/リフレクター分離）

### プロジェクト内部参照
- `.docs/research/2026-04-06-3f0ec9-172414/final-report.md` — uranai-concept移行レポート（SKILL.md遵守率70-90%、5つの情報損失リスク）
- `src/services/pipeline-service.ts` — 現行リライトループ実装
- `src/services/metaframe-service.ts`, `section-service.ts` — 現行プロンプト設計
- `.claude/hooks/post-write-verify.sh` — 現行write検証フック（warning-only）
- GitHub Issues #29051, #29395, #28842 — Claude Code並行書込み破損報告
