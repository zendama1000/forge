# x-auto-agent 実運用レベル改善リサーチレポート

> **調査テーマ**: x-auto-agent の実運用レベル改善（UI刷新 + アーキテクチャ整理）
> **調査日**: 2026-02-21
> **調査ID**: 2026-02-21-479641-124218
> **DA判定**: GO（Must Fix なし）

---

## 目次

1. [エグゼクティブサマリー](#1-エグゼクティブサマリー)
2. [調査設計](#2-調査設計)
3. [実コード調査で判明した事実](#3-実コード調査で判明した事実)
4. [6視点の調査結果](#4-6視点の調査結果)
5. [統合分析（Synthesis）](#5-統合分析synthesis)
6. [Devil's Advocate レビュー](#6-devils-advocate-レビュー)
7. [推奨アクション](#7-推奨アクション)
8. [残存ギャップと次のアクション](#8-残存ギャップと次のアクション)

---

## 1. エグゼクティブサマリー

### 結論

**フルリデザインは不要かつ高リスク。Alpine.js ES Modules分割による段階的改善を推奨。**

- フレームワーク移行前に、まずAlpine.js内でのファイル分割（ビルドステップ不要）で保守性を改善
- d-20260213-213837（公式API移行）の方針確定を待ってからUI刷新スコープを決定
- browser.jsのリファクタリングはAPI移行後に存続するモジュールのみ先行実施

### 核心的発見

| # | 発見 | 信頼度 |
|---|------|--------|
| 1 | **HTMXは一切使用されていない**（hx-*ディレクティブ=0件）。SSEは命令的EventSource APIで実装済み | High |
| 2 | index.htmlは**単一x-data="app()"スコープに47プロパティ・36メソッド**が集約（Alpine.jsコミュニティ推奨閾値10の4.7倍） | High |
| 3 | SSEブロードキャスト機構はserver/services/state.jsに実装されており、**UIフレームワーク移行と完全独立** | High |
| 4 | 「6視点中5視点がAPI移行先行を支持」は**過大カウント**。明示的推奨は2視点のみ | High |
| 5 | browser.js(58KB)は**単一XBrowserクラス**で6つの責務グループが混在。API移行による50%削減が最も蓋然性が高い | Medium |

---

## 2. 調査設計

### コアクエスション（5問）

1. 121KB単一HTMLのUX課題はフレームワーク移行でしか解決できないのか？Alpine.js+HTMXのまま分割では不十分か？
2. browser.js(58KB)の責務分割はどのレベルまで必要か？公式API移行後に大部分が不要になるのでは？
3. UI刷新とアーキテクチャ整理の「バランス型」並行は、相互依存による手戻りリスクをどう管理するか？
4. 現行アーキテクチャは実際にどの程度「根本改善」が必要か？
5. d-20260213-213837（公式API移行）との整合性をどう確保するか？

### 検出された前提バイアス（7件）

| # | 前提 | 検証結果 |
|---|------|----------|
| 1 | 「フルリデザイン」が必要 | **否定**: 問題は121KBモノリスの保守性であり、Alpine.js自体の限界ではない |
| 2 | 「アーキテクチャ全体再設計」が必要 | **否定**: 問題はbrowser.js+engagement.jsの肥大化に局所化 |
| 3 | 「ビルドステップ導入」が純粋にメリット | **条件付き**: 個人プロジェクトではCDNゼロビルドも意図的戦略 |
| 4 | 「モダンFW移行」が最優先 | **否定**: API移行でUIの前提が変わる。先にAPI方針確定が必要 |
| 5 | 「バランス型」が最適 | **否定**: UIとアーキテクチャは依存関係があり独立並行は困難 |
| 6 | 「既存60+テストで回帰検証は十分」 | **未確認**: UI層テストカバレッジはほぼゼロの可能性 |
| 7 | 「Stage5未完成だから作り直す」 | **否定**: d-20260211-212744のStrangler Patternと矛盾 |

### 過去決定との衝突（3件）

| 決定ID | 衝突内容 | 深刻度 | 解決策 |
|--------|----------|--------|--------|
| d-20260213-213837 | API移行+HITL方針が確定済み。ブラウザ自動化前提でUIフルリデザインすると手戻り | **High** | API移行スコープ確定後にUI設計。API非依存部分のみ先行 |
| d-20260211-212744 | Strangler Pattern原則と「フルリデザイン」は直接矛盾 | Medium | 段階的改善（Alpine.js分割→必要に応じてFW移行）を採用 |
| d-20260211-013350 | 観測性基盤を最優先とする決定。観測性なしに改善効果測定が不可能 | Medium | UI刷新前に現行の観測性が十分か検証 |

---

## 3. 実コード調査で判明した事実

### index.html（121KB / 2,260行）

```
構成:
├── CDN依存: Alpine.js + Tailwind CSS のみ（HTMXなし）
├── x-data スコープ: 1個（単一 app() 関数）
├── 状態プロパティ: 47個
├── メソッド: 36個（async 30 + sync 6）
├── x-if: 49件
├── x-show: 4件
├── Alpine.js ディレクティブ総数: 214件以上
└── app()関数: L1024〜L2258（約1,234行のJS）
```

**深刻度順のDX課題:**
1. **コンポーネント影響範囲把握の困難さ**（最深刻）: 全状態がグローバル共有、変更がアプリ全体に波及
2. **差分レビューの困難さ**: すべての変更が1ファイルに集中
3. **エディタ応答速度低下**: 2,260行HTMLでIntelliSense遅延の閾値に近い

### browser.js（58KB / 1,853行）

```
構成:
├── 単一クラス: export class XBrowser (L47-1853)
├── ファクトリ関数: createBrowser(), createBrowserForAccount()
├── import依存: patchright, selectors.js, stealth.js, circuit-breaker.js, retry.js, errors.js
│
├── 責務グループ:
│   (A) ブラウザライフサイクル: launch/close/dismissOverlays
│   (B) セッション永続化: loadSession/saveSession ← API移行後も存続
│   (C) 認証管理: injectAuthToken/getAuthToken/isLoggedIn/ensureLoggedIn ← API移行後も存続
│   (D) ツイート操作: postTweet/_postTweetImpl/verifyPostSuccess/postReply ← API移行で廃棄候補
│   (E) DM操作: sendDM/_sendDMImpl/navigateToDM/getUnreadDMs/replyToDM ← API移行で廃棄候補
│   └── (F) フォロー: followUser/verifyFollowSuccess ← API移行で廃棄候補
```

### SSEブロードキャスト機構

| 項目 | 実装場所 | 内容 |
|------|----------|------|
| SSEクライアント管理 | server/services/state.js (L44) | `const sseClients = new Set()` |
| ブロードキャスト関数 | server/services/state.js (L297-410) | broadcastActivity / broadcastError / broadcastBrowserStatus / broadcastStatusUpdate |
| クライアント接続 | public/index.html (L1098) | `new EventSource('/api/events')` |
| SSEルート | server/routes/events.js (L19) | `text/event-stream` ヘッダー設定 |

**重要**: SSEはサーバー側のres.write()による純粋なHTTPストリーミングであり、**UIフレームワーク移行とは完全に独立**。WebSocket移行も不要。

---

## 4. 6視点の調査結果

### 4.1 技術的実現性（Technical）

| 問い | 結論 | 信頼度 |
|------|------|--------|
| SSEを維持できるFWは？ | **全FWで等価に移行可能**。HTMXは使われておらず、EventSource APIは標準JS | High |
| browser.jsの最適な分割境界は？ | セッション永続化(B)→認証管理(C)の順で抽出。Facadeパターン推奨 | High |
| Express+新UIの最適統合パターンは？ | **(a) Express APIサーバー+SPA分離**が最高互換性 | High |
| SSE機構はFW移行後も利用可能か？ | **完全に維持可能**。WebSocket移行は不要 | High |
| Alpine.js状態管理の移行先は？ | Vue: Piniaが最も自然なマッピング。React: Zustand推奨 | High |

### 4.2 コスト・リソース（Cost）

| 項目 | 見積もり | 備考 |
|------|----------|------|
| フルリデザイン（UI+アーキテクチャ同時） | 138〜484時間 | 週10-20hで3.5〜12ヶ月 |
| d-20260213-213837のPhase 2 | 38〜84時間 | 観測性→メモリリーク→テスト→API統合 |
| Alpine.js維持+分割リファクタ | **学習コスト: ゼロ** | 既存技術の延長 |
| モダンFW学習コスト | Vue: 1-2週間、Svelte: 6週間、React: 最大 | 個人PJでのROIは低い |
| Vite導入 | 数時間（初期） | 保守はWebpackより大幅に低い |
| Strangler Patternオーバーヘッド | 全体工数の20-40%増 | Alpine.js+SPA混在はDOMコンフリクトリスク |

**API移行タイミングとUI刷新コストの関係:**
- API移行**後**にUI刷新 → API仕様確定でUIスコープが明確化し効率的
- API移行**前**にUI刷新 → 手戻りリスクあり（管理されないAPI変更が統合障害の40%を引き起こす）

**browser.js削減率シナリオ別工数影響:**

| シナリオ | 削減内容 | Phase C/D工数変動 | 蓋然性 |
|----------|----------|-------------------|--------|
| 20%削減 | stealth/cookie管理のみAPI化 | ネット △2-4h | 低 |
| **50%削減** | **書き込み操作全てAPI化** | **ネット △0〜+25h** | **最高（d-20260213-213837と整合）** |
| 80%削減 | 認証トークン取得以外全てAPI化 | ネット △20-44h | 低 |

### 4.3 リスク・失敗モード（Risk）

| リスク | 深刻度 | 対応状況 |
|--------|--------|----------|
| **仕様消失**: フルリライトで未完成機能の仕様が失われる | High | 現行UIの動作仕様が文書化されていない。big-bang-rewriteの典型的失敗パターン |
| **UI層テスト不在**: UI層テストカバレッジがほぼゼロ | High | FW移行時のUI回帰テストが皆無 |
| **ブラウザ自動化UI廃棄**: API移行後にbrowser-stream/session管理/stealth設定等が不要に | Medium | 50%削減シナリオで推定3-4画面が廃棄対象 |
| **E2Eテスト不安定**: PatchrightのCI環境安定性（58%のCI失敗がflakiness由来） | Medium | API移行でヘッドレスブラウザ依存が根本解消 |
| **regression bug**: engagement.js/monitor.jsリファクタ中の品質低下 | Medium | integration test 3件では不十分 |

**「6視点中5視点がAPI移行先行を支持」の正確な分析:**
- 5視点が支持したのは「**要件再定義（API移行を含む）の合理性**」
- 「**API移行を最優先で先行実施すること**」への支持とは区別すべき

### 4.4 代替案・競合（Alternatives）

#### フレームワーク比較表（4軸評価）

| FW | SSEサポート | Express統合 | テスト成熟度 | バンドルサイズ(min+gzip) |
|----|-------------|-------------|--------------|--------------------------|
| React+Vite | EventSource (多数ガイドあり) | 高（CORS+プロキシ設定のみ） | 最高（Jest 35M DL/週） | 約42.2KB（最大） |
| Vue3+Vite | EventSource（可能） | 高（Viteプロキシ経由） | 高（Vitest推奨） | Reactよりやや小 |
| Svelte+SvelteKit | sveltekit-sse専用ライブラリ | 中（独自サーバー層と競合リスク） | 中（Vitest対応可） | 最小クラス（~3KB） |
| SolidJS | solidjs-useフック | 中（単独なら可） | 低〜中 | ~7KB（ベンチマーク1位） |
| **HTMX強化（Alpine.js維持）** | **hx-ext='sse'標準** | **最高（ビルド不要）** | **中（E2E主体）** | **<30KB（ビルド生成物なし）** |

#### 代替アプローチ比較

| アプローチ | メリット | リスク |
|-----------|----------|--------|
| **Alpine.js ESM分割** | 学習コストゼロ、ビルド不要、段階的 | 単一スコープ49 x-if依存の分割困難さ |
| **局所リファクタリング**（browser.js+engagement.jsのみ） | 最小侵襲、リスク局所化 | API移行後に再作業の可能性 |
| **OpenAPI+UIリポジトリ分離** | 長期的に最も持続可能 | 初期オーバーヘッド高い |
| **API移行先行→後からUI刷新** | スコープ縮小で効率的 | API移行完了時期の不確定性がUI着手をブロック |

### 4.5 開発体験・保守性（Developer Experience）

**現行構成のDX定量データ:**

| 指標 | 現行値 | コミュニティ推奨閾値 | 超過率 |
|------|--------|----------------------|--------|
| x-dataプロパティ数 | 47個 | 10個（コミュニティ経験則※） | 4.7倍 |
| メソッド数（単一スコープ） | 36個 | - | - |
| x-if（条件分岐） | 49件 | - | - |
| HTML行数 | 2,260行 | - | IntelliSense遅延閾値付近 |

> ※ 「10プロパティ推奨」の出典はryangjchandler.co.uk（コミュニティブログ）であり、Alpine.js公式ドキュメントではない点に注意

**ビルドステップ導入の費用便益:**
- ViteのHMR: 50ms以内に変更反映（CDNフルリロード: 数百ms〜数秒）
- 短期（6ヶ月）: ビルドコストが上回る可能性
- 長期（1年以上）: HMR・TypeScript補完・コンポーネントテストの恩恵が上回る
- **中間選択肢**: Alpine.js ES Modules分割はビルドステップ不要でコンポーネント境界を導入可能

**ゼロ仮説「現行で12ヶ月の機能開発が遂行可能」:**
- 定量的実測データ（エディタ応答・バグ修正時間・スコープバグ頻度）は取得不可能
- 構造的には維持可能だが余裕は限界的
- **条件**: 追加機能≦5件かつ各プロパティ追加≦3件なら維持可能

### 4.6 移行戦略・段階的実行計画（Migration Path）

**推奨移行戦略: Modified Big Bang with Rollback Gate**

| 戦略 | 適合度 | 理由 |
|------|--------|------|
| Big Bang（一括置換） | 中 | 42ファイル規模なら可能だが本番稼働中は致命的リスク |
| **Modified Big Bang + Rollback Gate** | **高** | SSE部分のみ並行稼働、残りはフェーズ移行 |
| Strangler Pattern | 中 | facade維持コストが42ファイル規模では過剰な可能性 |
| Parallel Run | 低 | 個人PJでは運用コスト過剰 |

**段階的移行のUI領域優先順位:**

| 順位 | 領域 | 依存度 | 理由 |
|------|------|--------|------|
| 1 | **設定管理画面（YAML CRUD）** | 最低 | Request-Responseのみ、SSE非依存、ロールバック容易 |
| 2 | ログビューア | 低 | 読み取り専用（リアルタイム更新がなければ） |
| 3 | スケジュール管理 | 中 | 実行エンジンとの依存あり |
| 4 | リアルタイムステータス | 最高 | SSE強依存、接続管理の複雑さ |

**クリティカルパス上のブロッカー:**
1. SSEエンドポイント仕様変更（リアルタイムUI即時破壊）
2. 認証/セッション管理変更（全UI機能をブロック）
3. YAMLスキーマ変更（設定管理API破壊）

**Feature Parity Checkpoint（垂直スライス方式）:**

| CP | 内容 | 完了条件 |
|----|------|----------|
| CP1 | 設定の読み書きサイクル | YAML CRUDが新UIで完結 |
| CP2 | ログ参照 | ログ検索・フィルタが新UIで可能 |
| CP3 | スケジュール管理 | 設定・変更・削除が新UIで完結 |
| CP4 | リアルタイムステータス | SSE統合完了、ステータス表示 |
| CP5 | 全操作完結 | 旧UIなしで全操作可能（切替完了） |

---

## 5. 統合分析（Synthesis）

### API移行先行の合意度（修正後）

| カテゴリ | 視点 | 内容 |
|----------|------|------|
| **明示的推奨** | cost | API移行後UI刷新でコスト効率15-40%改善 |
| **明示的推奨** | alternatives | 逆順アプローチの合理性を調査問いとして設定し確認 |
| 間接的示唆 | risk | ブラウザ自動化固有UI廃棄リスクの警告（API先行の積極推奨ではない） |
| 間接的示唆 | migration_path | APIコントラクト安定化がクリティカルパス上のブロッカー（依存関係定義） |
| 言及なし | technical | SSEのUI非依存性を論じ、実装順序には言及なし |
| 言及なし | developer_experience | ビルドステップ費用便益を論じ、API移行順序には言及なし |

### 視点間の矛盾と解決

| 矛盾 | 視点間 | 解決 |
|-------|--------|------|
| Modified Big Bang vs Strangler Pattern | migration_path vs d-20260211-212744 | Strangler原則を維持し、ロールバックゲートを各フェーズに適用 |
| Alpine.js分割=低リスク vs Strangler 20-40%増 | alternatives vs cost | 「Alpine.js内分割」と「FW間移行」の混同。同一FW内構造改善にはStranglerオーバーヘッド不適用 |
| 12ヶ月維持は限界的 vs 定量検証が必要 | developer_experience vs cost | 低コスト改善（Alpine.js分割）は実測不在でも合理的。高コスト改善（FW移行）は実測が前提 |
| 局所リファクタはリスク局所化 vs API移行後に再作業 | alternatives vs risk | API移行後も存続するモジュール（セッション永続化・認証管理）のみ先行分割 |
| x-if依存で分割困難 vs ES Modules分割は実現可能 | technical vs alternatives | 2段階: (1)メソッドの物理的ファイル分割（スコープ維持）→(2)Alpine.store()で状態分離 |

### 過去決定との整合性

| 決定 | 整合状況 |
|------|----------|
| d-20260213-213837（API移行） | **完全整合**: API移行を前提条件として尊重。Phase 0差し戻し判断に一致 |
| d-20260211-212744（Strangler Pattern） | **整合**: Alpine.js分割→必要に応じてFW移行の段階的アプローチ |
| d-20260211-013350（観測性優先） | **整合**: Phase 2の(1)が観測性基盤を最初に配置 |

---

## 6. Devil's Advocate レビュー

### 判定: GO（Must Fix なし）

前回フィードバック（MF-001〜004）の解決状況:

| ID | 内容 | 状態 |
|----|------|------|
| MF-001 | 実コードベース調査の欠落 | **解決**: technical/DX視点が実コード調査実施、Explore検証で裏付け |
| MF-002 | browser.js削減率3段階シナリオ分析 | **解決**: risk/cost視点が実コードベースの行番号付きで分析 |
| MF-003 | ゼロ仮説の定量的検証 | **解決**: 実測不可能の理由と、仮定に基づく判断であることを明示 |
| MF-004 | 合意度の正確なカウント | **解決**: 3視点が独立検証し一致。明示的2/間接的2/言及なし2 |

### 残存する前提への攻撃（Should Fix）

| # | 前提 | 弱点 | 影響 |
|---|------|------|------|
| 1 | Alpine.js ESM分割は「学習コストゼロ」 | 引用文献は複数x-dataスコープ前提。**単一巨大スコープ+49 x-if依存での成功事例が0件** | Phase A(20-40h)が楽観的。最悪40-60h |
| 2 | 47プロパティは閾値の4.7倍超過 | 出典はAlpine.js公式ではなくコミュニティブログ。**権威バイアス** | 改善の「緊急度」根拠が弱体化 |
| 3 | Phase Aは API移行非依存で即時実施可能 | browser操作除外後の実効スコープは~18メソッド。**投資対効果が過大評価の可能性** | 縮小スコープでのDX改善効果が不明 |
| 4 | ファイル分割のみでDXが有意に改善 | 根本問題は「全状態のグローバル共有」。**メソッド分割だけでは解決しない** | 「分かれたが認知負荷は変わらない」リスク |

### 検出されたバイアス

| 種類 | 内容 | 深刻度 |
|------|------|--------|
| **権威バイアス** | 「4.7倍超過」出典をAlpine.js公式と誤帰属（実際はコミュニティブログ） | Medium |
| **確認バイアス** | Alpine.js分割の「成功事例」が全て小規模x-dataスコープ前提。巨大単一スコープの事例なし | Medium |
| **アンカリングバイアス** | Phase A(20-40h)の根拠が未提示。49 x-if+this相互参照のリスク未反映 | Low |

### 最悪シナリオ

> Phase A着手(20-40h見積もり) → thisコンテキスト共有問題で分割メソッドが壊れる → x-ifバインディング12-15件が動作不全 → デバッグに追加20-30h → 最終50-70h投入して「ファイルは分かれたがDXは大して変わらない」→ 同時期にAPI移行が進行しbrowser操作UIが廃棄、分割対象の30%が無駄に。

**機会費用**: Phase A(20-40h)をd-20260213-213837のPhase 2に充当すれば、観測性基盤(4-8h)+メモリリーク修正(2-4h)+テスト基盤(8-16h)=14-28hが完了し、残りでAPI統合の設計開始が可能。

---

## 7. 推奨アクション

### Primary: Phase-gated 段階的改善

```
Phase A (即時・API非依存)     Phase B (API確定後)      Phase C (人間判断)
        20-40h                   24-56h                   判断次第
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Alpine.js ESM分割│     │ API統合+UI調整   │     │ FW移行の要否判断 │
│ Alpine.store()  │ ──→ │ 廃棄UIの削除     │ ──→ │ 移行する場合:    │
│ browser.js部分  │     │ API操作UI追加    │     │   Express+SPA分離│
│ 分割(B)(C)のみ  │     │                  │     │   YAML CRUDから  │
└─────────────────┘     └──────────────────┘     └──────────────────┘
```

#### Phase A: 即時実施・API移行非依存（20-40h）

| タスク | 内容 | 工数目安 |
|--------|------|----------|
| **POC実施**（DA推奨） | knowledge関連4メソッドをAlpine.data()で分離し技術検証 | 2-4h |
| index.html ESM分割 | app()の36メソッドを機能グループ別にファイル分割。Import Maps使用 | 10-20h |
| Alpine.store()導入 | グローバル共有プロパティ（accounts/selectedAccountId等）をstore化 | 4-8h |
| browser.js部分分割 | **API移行後も存続するモジュールのみ**: SessionStorage + AuthManager抽出 | 4-8h |

**対象ファイル分割案:**
- `accounts.js` — fetchAccounts, selectAccount, fetchAccountStatus
- `persona.js` — fetchPersona, savePersona, fetchFramework, saveFramework
- `knowledge.js` — fetchKnowledge, saveNewKnowledge, deleteKnowledge, saveEditKnowledge, uploadKnowledgeFile
- `logs.js` — fetchActivityLogs, loadMoreLogs, changeLogFilter
- `quality.js` — fetchQualitySettings, addNgWord, removeNgWord
- `browser-ui.js` — openBrowserWindow, closeBrowserWindow, navigateBrowserTo, checkBrowserStatus（※API移行で廃棄候補）

#### Phase B: API移行スコープ確定後（API統合16-40h + UI調整8-16h）

- d-20260213-213837のPhase 2(6)「公式API統合+残存ブラウザ自動化のモジュール分割」実施後
- 廃棄されたブラウザ操作UIを削除（postTweet/sendDM/followUser関連）
- API操作UIを追加
- index.htmlのコード量が実質的に削減（50%削減シナリオ）

#### Phase C: UI技術判断（人間判断、Phase B完了後）

Phase B完了後のスリム化されたindex.htmlに基づき:
- **FW移行する場合**: Express+SPA分離パターン(a)を採用。設定管理画面を最初の移行対象
- **維持する場合**: Alpine.js+ES Modules構成を継続

### Fallback: Vue 3 + Vite 段階的ページ移行

**発動条件:**
1. POCで1件でもx-ifバインディング破壊が発生
2. app()内のthis相互依存により3つ以上の機能グループで分割不可能
3. 分割完了後もDX改善が開発者体感で不十分

**内容:** Vite+Vue 3 SFCによる段階的ページ移行。Express+SPA分離。設定管理画面(YAML CRUD)を最初のCP。

**Vue 3選択理由:** x-dataプロパティ→Piniaのstate、x-dataメソッド→Piniaのactionsへのマッピングが最も自然。学習コスト約1-2週間。

### Abort条件

以下が**すべて**成立する場合、UI刷新自体を中止しd-20260213-213837のPhase 2のみに集中:

1. 開発者が現行DXに重大な不満を持っていない
2. 今後12ヶ月の追加機能≦5件、各プロパティ追加≦3件
3. API移行で80%削減が実現し、モノリスHTMLが自然に縮小

---

## 8. 残存ギャップと次のアクション

### 未解決ギャップ

| # | ギャップ | 影響 | 解決方法 |
|---|---------|------|----------|
| 1 | **エディタ応答・バグ修正時間・スコープバグ頻度の実測値** | ゼロ仮説の最終判定に必要 | 開発者ヒアリングまたはGitログ分析 |
| 2 | **d-20260213-213837の具体的API移行スコープ** | browser.js削減率の確定に必要 | API移行の詳細設計フェーズで確定 |
| 3 | **Alpine.js ESM分割のPOC未実施** | 技術的実現可能性の最終確認 | Phase A着手前にknowledge関連4メソッドで実証(2-4h) |
| 4 | **browser.js/engagement.jsの実装状態** | 設計段階のみか部分実装済みかで戦略が変わる | x-auto-agentコードベースの直接確認 |
| 5 | **SvelteKit+Express統合の実地検証データ** | Fallback候補の実現性 | Fallback発動時に調査で足りる |
| 6 | **TypeScript段階的導入（JSDoc型注釈のみ）の有効性** | ビルド不要の型安全性向上 | 中間パスとして別途調査可能 |

### 推奨される次のアクション

1. **開発者判断**: 現行DXの体感評価（abort条件の判定）
2. **POC実施**: knowledge関連4メソッドのAlpine.data()分離テスト（2-4h）
3. **API移行スコープ確認**: d-20260213-213837の詳細設計を参照し、browser.js削減率を確定
4. **Phase A/Phase 2の優先順序決定**: 観測性基盤をPhase Aに先行させるオプションも検討

---

> **調査品質**: 6視点（固定4+動的2）の独立調査 + Devil's Advocate 2ラウンド（MF-001〜004全件解決）+ 実コードベース検証済み
>
> **信頼度の分布**: High: 5件 / Medium: 多数 / Low: 3件（browser.js削減率シナリオ・ゼロ仮説検証・新機能追加時間比較）
