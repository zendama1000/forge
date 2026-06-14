# リサーチ最終レポート

**テーマ**: make-tweet への『ムンク。式 33→1,000フォロワー4日間ノウハウ』統合
**スコープ**: 投稿パターン理論ドキュメント追加 + longform プロンプト強化の **2点のみ**（CLI 拡張のみ・後方互換維持）
**Research ID**: `2026-05-01-166355-215210`
**判定**: ✅ **GO**（最小差分・後方互換完全維持で実装可能）

---

## 1. エグゼクティブサマリー

6視点（Technical / Cost / Risk / Alternatives / Compatibility Audit / Knowledge Fidelity）の調査により、ロックされた 2 点スコープが **TypeScript 実装 5〜12 行 + テスト 5〜10 行 + 理論 .md 1 本** という極めて小さい差分で完結することが確認された。

| 確定事項 | 内容 |
|---|---|
| **理論ファイル配置** | 外部理論ディレクトリ（既存 6 理論と同階層）+ `--theory` フラグ経由 |
| **longform 強化** | `prompt-builder.ts` の `buildIntro()` / `buildOutputRules()` の `case 'longform'` への直接追記 |
| **`generate.md`** | **無変更**（6 エージェント並列モードへの混入は抽象化喪失リスクで却下）|
| **副次要素**（Week 段階・動画キャプション等）| 理論 .md 内の参考セクションに留め、コード化しない |

最大の発見は、**`refs-merger.ts` の soft-cap が既に 97.8% 消費済み（146,632 / 150 × 1024 bytes）** という事実であり、これにより `accounts/<name>/refs/` への直接配置は除外された。

---

## 2. 調査計画（Investigation Plan）

### 2.1 コア質問 6 件
1. ムンク。理論 .md の配置場所（共通 `refs/` / `accounts/<name>/refs/` / 新設）
2. 6 エージェント並列生成への統合方式（7 体目追加 / 既存マージ / `--theory` 単独）
3. `prompt-builder.ts` longform への 4 要素注入の最小差分設計
4. X 固有リッチメディア（引用＋動画）のテキスト CLI 表現
5. ムンク。理論と既存 6 理論の重複・競合の機械的検出
6. 運用行動指針・Week 段階アドバイスの本スコープでの扱い

### 2.2 視点配置

| 区分 | 視点 ID | 焦点 |
|---|---|---|
| 固定 | technical | 技術的実現性 |
| 固定 | cost | コスト・リソース |
| 固定 | risk | リスク・失敗モード |
| 固定 | alternatives | 代替案・競合（ロック範囲内） |
| 動的 | compatibility_audit | 既存資産との後方互換監査 |
| 動的 | knowledge_fidelity | ムンク。式ノウハウの忠実度・解釈精度 |

---

## 3. 視点別の主要発見

### 3.1 Technical（技術的実現性）— confidence: high

- **`refs-merger.ts` 仕様**: 2 段階ロード（Stage1: `accounts/<name>/refs/` 自動スキャン、Stage2: `account.yaml` の `refs[]`）+ 後勝ちマージ + soft-cap 150KB
- **`prompt-builder.ts` longform 分岐**: 4 関数に分散（`buildIntro` L193-205, `loadSampleSection` L228-275, `buildOutputRules` L309-321, `buildClosing` L330）
- **3 要素注入のフック点**:
  - 「タイトル全力」→ `buildIntro()` の `case 'longform'` に 1 行追加
  - 「1000 字推奨」→ 既存 L312 の表現強化のみ（既に実装あり）
  - 「興味駆動」→ `buildOutputRules()` の `case 'longform'` に 1 行追加
- **`generate.md` の 6 エージェント構成**: パス直書き方式（glob/設定ファイル不使用）、規約変更最小は理論ファイル入替

### 3.2 Cost（コスト・リソース）— confidence: high

| 項目 | 規模 |
|---|---|
| TypeScript 実装変更 | 5〜12 行 |
| テスト追加 | 5〜10 行 |
| 理論 .md 新規作成 | 50〜200 行（マークダウン） |
| **既存テスト破壊** | **0 件**（toContain ベースのため追加破壊なし） |
| LLM トークンコスト増分 | 0〜+16.7%（統合方式次第） |

⚠ **隠れコスト**: `refs-merger.ts` の **soft-cap 150KB が現在 146,632 bytes（97.8%）消費済み**。`accounts/<name>/refs/` 経由の追加は確実に truncation 発生。

### 3.3 Risk（リスク・失敗モード）— confidence: high〜medium

| リスク | 確度 | 緩和策 |
|---|---|---|
| **Context Rot**（Chroma 2025）— 1000 トークン以下から劣化開始 | 高 | ムンク。理論を 5〜15KB に凝縮、`--theory` 単独利用 |
| longform 文字数指示の single/thread への副作用漏れ | 中 | `switch(tweetType)` で完全分岐、case 内追記なら漏れなし |
| 既存 6 理論との指示衝突（短文 vs 長文）| 高（10〜13% 見逃し）| `--theory` 単独適用で並列を回避 |
| **動画前提キャプションのテキスト単独投稿混入** | 中 | 理論 .md から動画参照句（『動画の通り』等）を排除 |
| **Week 段階アドバイスのステージドリフト** | 高 | 状態管理なしのコード注入は見送り、docs/参考のみ |

### 3.4 Alternatives（代替案・競合）— confidence: high〜medium

| 設計決定 | 採用案 | 却下理由 |
|---|---|---|
| Q1: 理論ファイル配置 | **外部理論ディレクトリ + `--theory`** | `accounts/<name>/refs/` は soft-cap 超過必発 |
| Q2: 6 エージェント統合方式 | **`--theory` 単独適用** | 7 体目追加は配分式 `floor(count/6)` 改修必須でスコープ拡張 |
| Q3: longform 強化形態 | **`prompt-builder.ts` への直接追記** | 案 C（理論 .md 側吸収）は locked_assertion『grep_present: タイトル\|title』を不充足 |
| Q4: X リッチメディア表現 | **理論 .md 内の参考セクション** | 新 ContentType `'video'` 追加はスコープ超過 |
| Q5: Week 段階・運用指針 | **docs/ への .md 化のみ** | プロンプト末尾追加はステージドリフト誘発 |

### 3.5 Compatibility Audit（後方互換監査）— confidence: high

- **データ層完全保護**: `appendHistory()` / `appendQueue()` は変更スコープ外 → `history.jsonl` / `queue.jsonl` フォーマット不変
- **回帰テスト最小セット 7 ファイル**: `cli-args` / `cli-help` / `cli-content-type-args` / `backward-compat.e2e` / `cli-e2e` / `history-jsonl` / `queue-operations`
- ⚠ **既知バグ発見**: `prompt-builder.ts` L113 の `fs.readdir()` 結果が **未ソート**（OS 依存順序）。理論追加前に `mdFiles.sort()` 1 行追加で修正必須。
- **2 段階責任分離**: Phase A（理論 .md 追加後）vitest 全件パス必須 → Phase B（コード改修後）CLI 契約テスト群全件パス必須

### 3.6 Knowledge Fidelity（ノウハウ忠実度）— confidence: low〜medium

- ❌ **ムンク。本人の一次情報源未特定**（X 投稿・note・有料コンテンツがクローズドコミュニティ内である可能性）
- 一般 X 戦略文献からの裏付け:
  - **イーロン優遇文脈**: X Premium ビジネスモデルと長文機能の経済的接続が確認
  - **タイトル重要性**: 冒頭 50〜140 字で「さらに表示」クリック判断
  - **引用ポスト効果**: いいねの 27 倍フォロワー外に到達（note.com/mono01）
- 4 要素プロンプト翻訳セット（要約版）:

| 要素 | 翻訳キー |
|---|---|
| タイトル全力 | 冒頭で価値・対象・意外性を宣言（"さらに表示" クリックの唯一の理由） |
| 1000 字以上 | X 内完結型コンテンツ × 滞在時間アルゴリズム恩恵の最小実用閾値 |
| 興味深いタイトル | 価値提供フェーズの信頼蓄積（『失敗する理由』型の逆張り） |
| 本質的テーマ | 作者の真正な好奇心によるコンテンツ密度保証 |

---

## 4. 矛盾と解決

| 矛盾 | 視点 | 解決策 |
|---|---|---|
| `accounts/<name>/refs/` 配置（最推奨）vs soft-cap 確実超過 | alternatives × cost | **外部理論ディレクトリ + `--theory` フラグ単独利用**で Stage1/Stage2 を回避 |
| 動画前提キャプション設計を理論 .md に書く案 vs 動画参照句のテキスト単独投稿混入リスク | alternatives × risk | 動画関連は『動画と組み合わせる前提のキャプション設計指針』として明示ラベル付け、参照句（『動画の通り』）は排除 |
| 4 要素翻訳の原典忠実度未保証 vs プロンプト具体実装案 | knowledge_fidelity × cost/technical | **ユーザー指定文言を一次情報として扱う**。原典ニュアンスは理論 .md の解説セクションで補強する二層構成 |

---

## 5. 推奨アクション（Primary）

### 5.1 配置
- **新規作成**: `munch-posting-pattern-theory.md` を **既存 6 理論と同じ外部理論ディレクトリ**（`G:/マイドライブ/コンテンツ 価値増強/` または同等）に配置
- **利用**: `--theory` フラグ経由（`refs-merger.ts` を通らないため soft-cap 無関係）
- **ファイル要件**: 2KB〜30KB の凝縮構成、4 要素キーワード網羅、動画参照句なし

### 5.2 longform プロンプト強化
- **`buildIntro()` `case 'longform'`（L193-205）**: 「タイトルは読者の『さらに表示』クリックを決定する。冒頭で価値・対象・意外性を全力で宣言せよ」を 1〜2 行追加
- **`buildOutputRules()` `case 'longform'`（L309-321）**: 既存 L312『1,000〜3,000字推奨』を **『1000字以上必須』** に表現強化、「興味深いタイトル必須・自分自身が本質的に気になるテーマのみ採用」を追記
- **既存バグ修正**: L113 `fs.readdir()` に `mdFiles.sort()` 1 行追加

### 5.3 テスト追加
- `tests/unit/prompt-builder-content-types.test.ts` の longform describe に `toContain('タイトル')` / `toContain('1000字')` / `toContain('興味')` を 5〜10 行追加
- `tests/unit/refs-loader.test.ts` に sort 決定性テスト
- single / thread への副作用漏れ否定アサーション追加

### 5.4 スコープ堅守
- `generate.md` は **変更しない**（6 エージェント並列の理論カード抽出設計を毀損しない）
- Week 段階・動画前提キャプションは理論 .md 内の **参考セクション** に留め、コード追加なし

---

## 6. 実装基準（Implementation Criteria）

### 6.1 Layer 1（Unit / Static）— 8 件

| ID | 内容 |
|---|---|
| L1-001 | longform 分岐に『タイトル』要素注入 |
| L1-002 | 『1000 字』必須要件の明示（『推奨』→『必須\|以上』への表現強化）|
| L1-003 | 『興味』『本質\|気になる』要素の明示 |
| L1-004 | ムンク。理論 .md の存在 + 4 要素網羅 + 動画参照句なし |
| L1-005 | `tsc --noEmit` 通過（strict / ESM 規約遵守） |
| L1-006 | ESLint 通過 |
| L1-007 | 既存 vitest 全件破壊なし（後方互換） |
| L1-008 | `fs.readdir()` 結果の決定論的ソート（既存バグ修正） |

### 6.2 Layer 2（Integration）— 3 件

| ID | 内容 |
|---|---|
| L2-001 | `--theory` 経由でムンク。理論本文の主要キーワードがプロンプト出力に反映 |
| L2-002 | `--theory` なし longform で直接追記分（タイトル/1000/興味）が出力に含まれる |
| L2-003 | single / thread に longform 専用文言（『1000字以上必須』『さらに表示』）混入なし |

### 6.3 Layer 3（Behavioral / E2E）— 5 件

| ID | strategy | 内容 | 閾値 |
|---|---|---|---|
| L3-001 | structural | longform 出力に 4 要素キーワード AND 含有 | 4/4 |
| L3-002 | cli_flow | `--theory` 経由でムンク。理論セクション注入 + 出力 ≤ 150KB | 両条件 |
| L3-003 | llm_judge | 実 LLM 生成投稿サンプルの意図整合性 4 観点評価 | 0.70 |
| L3-004 | structural | single/thread への longform 専用語 0 件 | 0 件 |
| L3-005 | structural | `history.jsonl` / `queue.jsonl` データ層スキーマ不変 | 1/1 |

### 6.4 Phase 計画

| Phase | Goal | 主要 criteria | mutation 閾値 |
|---|---|---|---|
| **mvp** | 理論 .md 追加 + longform 4 要素追記、locked_assertion 充足 | L1-001..004, L1-008, L3-001 | 0.40 |
| **core** | vitest テスト追加 + 既存破壊ゼロ + tsc/eslint 通過 + CLI E2E | L1-005..007, L2-001..003, L3-002, L3-004 | 0.30 |
| **polish** | データ層完全保護 + LLM 品質判定 0.70 + ドキュメント整合 | L3-003, L3-005 | 0.20 |

---

## 7. 残存リスクとフォールバック

### 7.1 残存リスク

1. **ムンク。本人の一次情報源未特定** → ユーザー指定文言を原典として扱い、理論 .md で文脈補強
2. **既存 6 理論との同時利用は今回スコープ外**（指示衝突回避のため `--theory` 単独運用）
3. **6 エージェント並列モードへの統合は将来課題**（generate.md 配分式 `floor(count/6)` 改修が必要）

### 7.2 フォールバック計画

Primary の `--theory` 単独運用が運用要求（複数アカウント横断・自動注入）を満たさない場合:

- (a) `accounts/<name>/refs/` 配置 + 既存 refs 整理で 150KB 枠確保
- (b) `softCapBytes` オプション CLI 拡張
- (c) `account.yaml` の `refs[]` で絶対パス個別指定（Stage2、ディレクトリ展開回避）

の 3 手段から選択。

### 7.3 撤退対象

副次要素（Week 段階アドバイス・動画前提キャプション・引用職人マインド・運用姿勢）の **本格コード化は今回見送り**。状態管理機構と動画添付検出機構が整備された段階で別スコープとして再着手する。

---

## 8. 残存ギャップ（情報不足）

| ギャップ | 影響 |
|---|---|
| ムンク。本人の一次情報源（X 投稿・note 等）が特定不能 | 4 要素翻訳ニュアンスの原典忠実度未保証 |
| 既存 6 理論ファイルの実コンテンツ未確認 | ムンク。理論との重複・衝突の定量評価不可 |
| `tests/e2e/content-types.e2e.test.ts` 内容未詳細確認 | longform 強化後の E2E 影響範囲が未確定 |
| `account.yaml` の `refs[]` を CLI が `mergeRefs` に渡すフロー未追跡 | Stage2 注入経路の完全把握なし |
| 日本語ドメインでの ConInstruct 相当衝突検出精度データなし | 指示衝突発生率は英語ベンチマーク推定 |

---

## 9. 結論

ロックされた 2 点スコープは、**最小差分（TS 5〜12 行 + テスト 5〜10 行 + 理論 .md 1 本）で技術的に実現可能**であり、後方互換は完全維持される。最大の落とし穴は `refs-merger.ts` の soft-cap 97.8% 消費だが、外部理論ディレクトリ + `--theory` フラグ経由で完全回避できる。`prompt-builder.ts` L113 の既存バグ（`fs.readdir()` 未ソート）は理論追加前に併せて修正することで、順序非決定性を排除しつつ実装を進められる。

**Primary 推奨を採用し、Phase mvp → core → polish の 3 段階で実装することを推奨する。**

