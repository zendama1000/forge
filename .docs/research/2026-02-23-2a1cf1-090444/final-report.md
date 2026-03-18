# x-auto-agent UI ビジュアルリデザイン — 最終リサーチレポート

> **リサーチID**: 2026-02-23-2a1cf1-090444
> **テーマ**: Alpine.js→Next.js 全画面フルリデザイン、UIフレームワーク・コンポーネントライブラリ・デザインシステム選定
> **DA判定**: **GO**（条件付き）

---

## 1. エグゼクティブサマリー

本リサーチは x-auto-agent の UI ビジュアルリデザインについて、6つの視点（技術・コスト・リスク・代替案・UX一貫性・デザイントークン）から多角的に調査を実施した。

### 最重要結論

**Alpine.js→Next.js 全面移行は現時点で不要。Alpine.js 環境内でのビジュアルリデザインを推奨する。**

| 項目 | Next.js フルリデザイン | Alpine.js 環境内改善（推奨） |
|------|----------------------|---------------------------|
| 推定工数（7画面） | 190〜330h | 不要（MVP3画面で対応） |
| 推定工数（MVP3画面） | 110〜170h | **60〜100h** |
| 学習コスト | 高（React + App Router + shadcn/ui） | **低（DaisyUI = Tailwindプラグイン）** |
| 移行リスク | 高（技術的非互換・ビッグバン移行） | **低（既存コードベースへの追加）** |
| SSR恩恵 | 限定的（内製ツールにSEO不要） | — |
| 過去決定との整合性 | **3件の過去決定と矛盾** | 全決定と整合 |

この結論は **6視点中5視点が独立して支持** しており、本リサーチで最も証拠強度の高い発見である。

---

## 2. 調査の背景と前提

### 2.1 コアクエスチョン

1. Next.js 14 + Tailwind CSS 基盤で7画面のフルリデザインに最適なコンポーネントライブラリは何か
2. ダッシュボード系UIに特化したコンポーネントライブラリの選定基準と候補
3. 7画面間のビジュアル一貫性とナビゲーション設計の実現方法
4. 既存API（localhost:3847）とNext.js App Router の接続パターン設計
5. 既存Alpine.js版のUI/UX問題点の特定と優先課題

### 2.2 過去決定との矛盾（調査開始時に検出）

本リサーチのテーマ設定自体が、過去3件の決定と矛盾していた。

| 決定ID | 内容 | 矛盾の深刻度 |
|--------|------|-------------|
| d-20260222-223515 | 「フルリデザインは現時点で着手しない」 | **Critical** |
| d-20260221-135800 | Phase A→B→C 順序（UI技術判断はPhase C） | High |
| d-20260213-213837 | 公式API移行先行の推奨 | High |

> テーマ「Alpine.js→Next.js全画面フルリデザイン」は Phase C を飛び越えて Next.js 採用を前提としており、調査計画（SC）自体にフレーミングバイアスが存在していた。

---

## 3. 現状UIの問題点分析

`ux_coherence` 視点が `public/index.html`（2268行, 119KB）の実コード分析を実施し、**7カテゴリの具体的問題** を特定した。

### 3.1 問題一覧

| # | カテゴリ | 問題 | 深刻度 |
|---|---------|------|--------|
| 1 | カラースキーム | `bg-gray-900/800/700` の3段階グレーのみ。セクション間に視覚的差異なし。全カードが `bg-gray-800 rounded-lg p-4 mb-4` の単調な繰り返し | 高 |
| 2 | タイポグラフィ | `text-xl/lg/sm/xs` が混在、`font-bold/semibold/normal` が体系なく使用。`text-gray-100/400/500` のセマンティクスが不一致 | 中 |
| 3 | レイアウト・情報密度 | 10+セクションが単一縦スクロールに積み重なり、タブ/パネル切替なし。固定256px幅サイドバーが小画面でコンテンツ圧迫 | 高 |
| 4 | コンポーネント | ボタンスタイルが全箇所でインライン定義（クラス文字列の重複）。デザイントークン未定義 | 中 |
| 5 | ステータス表示 | 2x2px の色ドットがステータスの唯一指標。**アクセシビリティ違反**（色盲対応なし、ARIAラベルなし） | 高 |
| 6 | 通知システム | `saveMessage` を div で表示する独自実装。トースト/スナックバーUI なし | 低 |
| 7 | 技術的負債 | ESMモジュール分割済みだが index.html がモノリシック。Alpine ストア設定あるが主要ロジックはインラインスクリプトに残存 | 中 |

### 3.2 改善優先順位

1. **情報アーキテクチャ再設計** — 10+セクション縦スクロール → サイドバーナビ+メインパネル構造
2. **ダッシュボード画面統合** — 運用制御と状態表示をヒーローゾーンに統合、fold above 内に5-6要素
3. **デザイントークン確立** — カラーシステム・タイポグラフィ・スペーシングの体系化
4. **ログ画面構造化** — 適切なテーブル構造+インタラクティブフィルタリング

---

## 4. 各視点の調査結果

### 4.1 技術視点（technical）

#### Next.js 14 App Router の主要制約

| 制約 | 詳細 |
|------|------|
| WebSocket | Custom Server 必須（App Router ネイティブ非対応）。Vercel デプロイ不可 |
| Server Actions | **ミューテーション専用**（データ取得には非推奨） |
| セキュリティ | CVE-2025-29927: Middleware 単独の認証依存は脆弱。DAL での検証必須 |

#### データフェッチパターン比較

| パターン | メリット | デメリット |
|----------|---------|-----------|
| Server Component → Express 直接 | 最速、公式推奨 | ビルド時プリレンダリングで問題の場合あり |
| Route Handlers 経由プロキシ | CORS不要、URL隠蔽 | 余分なHTTPラウンドトリップ |
| Server Actions | 型付きRPC、DX良好 | GET非推奨（ミューテーション専用） |
| クライアント直接フェッチ | 最もシンプル | CORS設定必要、バックエンドURL露出 |

#### コンポーネントライブラリ比較

| ライブラリ | Tailwind互換 | バンドル | TypeScript | 特記事項 |
|-----------|-------------|---------|-----------|---------|
| **shadcn/ui** | ネイティブ | 最小（コピペ方式） | First-class | 2025年デファクト。ただし Radix→Base UI 移行中 |
| MUI | 非ネイティブ（競合） | 100-200KB gzip | 強力 | 企業向け高機能。Tailwind との併用にコスト |
| Mantine | 併用可能 | 中 | 完全対応 | 120+コンポーネント。独自CSS-in-JSとの競合注意 |
| Radix UI | 完全互換 | 最小 | 対応 | ヘッドレス。メンテナンス低下リスク |

#### フレームワーク非依存オプション（DA対応で追加調査）

Alpine.js + Tailwind CSS によるビジュアル改善は**技術的に十分実現可能**:

- **Pines**: Alpine.js + Tailwind 専用UIライブラリ
- **Penguin UI**: Alpine.js + Tailwind コンポーネントライブラリ
- **TailAdmin**: Alpine.js + Tailwind v4 対応ダッシュボードテンプレート

> これらは前回リサーチで未検討だった選択肢であり、Next.js移行なしでもスターターキット効果を得られる。

---

### 4.2 コスト視点（cost）

#### 工数見積もり比較

| シナリオ | 推定工数 | 備考 |
|---------|---------|------|
| 7画面 Next.js フルリデザイン | 190〜330h | フレームワーク移行含む |
| 7画面 Alpine.js 内リデザイン | 133〜231h | FW移行コストなし |
| **3画面 MVP Alpine.js** | **60〜100h** | アカウント選択+ダッシュボード+設定 |
| Phase A のみ（ESM分割） | 20〜40h | ビジュアル改善なし |

#### コンポーネントライブラリの学習・メンテナンスコスト

| ライブラリ | 学習コスト | カスタマイズコスト | FW依存 |
|-----------|-----------|------------------|--------|
| **DaisyUI** | **低**（セマンティッククラス） | **低**（CSSプラグイン） | **なし** |
| shadcn/ui | 中〜高（TS + Radix理解必要） | 中（コード所有） | React必須 |
| Radix UI | 高（ヘッドレス、全スタイリング自前） | 高 | React必須 |

#### デザインシステム構築の投資対効果

- フルデザインシステム（80〜150h）は7画面規模では**費用対効果が出にくい**
- **CSS変数 + DaisyUIテーマ機能による「軽量デザイントークン」** が現実的

#### 最大のコスト削減要因

> **フレームワーク移行の有無が最大変数**。Alpine.js + DaisyUI/Tailwind は Next.js 移行比で工数 **30〜50%削減**。

---

### 4.3 リスク視点（risk）

#### 5つの重大リスク

| # | リスク | 深刻度 | 信頼度 |
|---|--------|--------|--------|
| 1 | **API移行未完了との並行進行** — APIコントラクト変更がUI成果を無効化 | Critical | 中 |
| 2 | **7画面同時開発の認知負荷超過** — 個人開発者の上限（1〜3作業単位）を2〜7倍超過 | High | 高 |
| 3 | **Radix UI メンテナンス低下** — 共同創設者が「最後の手段でしか使わない」と発言。shadcn/ui は Base UI 移行開始（2025年6月） | High | 高 |
| 4 | **Alpine.js→Next.js 技術的非互換** — ディレクティブ構文のSSRパースエラー、ビッグバン移行の失敗率+70% | Medium | 中 |
| 5 | **スコープクリープ** — ソフトウェアプロジェクトの33〜51%が経験 | Medium | 高 |

#### リスク重複時の影響

> API未確定 × 7画面 × 認知負荷 が重複する場合、個人プロジェクトとしての**失敗確率は有意に高い**。

#### 最優先の緩和策

1. 段階的スコープ絞り込み（まず2〜3画面）
2. API仕様の先行確定

---

### 4.4 代替案視点（alternatives）

#### 核心的知見: 二項対立の誤り

> 「Alpine.js CSS改善 vs Next.js フルリデザイン」という二項対立は**誤ったフレーミング**。

実際には以下の選択肢が存在する:

| レベル | 内容 | FW移行 |
|--------|------|--------|
| CSS変更のみ | 配色刷新、タイポグラフィ調整、カード視覚スタイル改善 | 不要 |
| Markup変更 | サイドバーアイコン追加、セクション階層化、タブUI追加、ナビ構造変更 | 不要 |
| FW移行必須 | コンポーネント分割による保守性改善、Reactエコシステム活用、SSR最適化 | 必要 |

#### Alpine.js エコシステム内の未検討リソース

- **TailAdmin** — Alpine.js + Tailwind v4 ダッシュボードテンプレート
- **Penguin UI** — Alpine.js + Tailwind UIコンポーネントライブラリ
- **Pines** — Alpine.js + Tailwind UIライブラリ

#### Strangler Pattern の適用限界

x-auto-agent は SPA に近い構造（サイドバー+メインパネル、実質1ページ内の7セクション）であり、**URL ベースの段階的移行は自然な切り分け単位がない**。Alpine.js + React の同一ページ共存は技術的に困難。

#### 前回推定の撤回

> 前回の「Alpine.js CSS改善で60-80%達成可能」は**根拠なき数値として撤回・無効**。ビジュアル目標が定義されない限り、達成率の算出は不可能。

---

### 4.5 UX一貫性・情報設計視点（ux_coherence）

#### 現状の根本問題: 情報アーキテクチャの欠如

10+セクションが無差別に単一縦スクロールに積み重なり、ユーザータスクに応じた**優先度付け・グルーピングが存在しない**。

#### 推奨IA構造

```
サイドバーナビゲーション
├── ダッシュボード（ステータス+制御統合） ← 最上位
├── 監視（アクティビティログ+メトリクス）
├── 設定（ペルソナ・フレームワーク・品質）
└── ナレッジ（ナレッジベース管理）
```

#### ダッシュボード画面の推奨レイアウト

| ゾーン | 内容 | 位置 |
|--------|------|------|
| ヒーロー | アカウントステータス + 主要制御ボタン | Fold above 上部 |
| メトリクス | 今日の投稿数・アクション数カード | 中段 |
| 詳細操作 | ブラウザ制御・即時投稿 | 展開可能エリア |

#### CRUD画面のUXパターン判定

| 画面 | 推奨パターン | 理由 |
|------|-------------|------|
| ペルソナ設定 | インライン編集（現行維持） | フィールド数3〜5項目、頻繁な編集 |
| ナレッジ管理 | スライドオーバー（Drawer） | 文脈保持しやすい |
| NGワード管理 | バルクアクション対応テーブル | 批量操作が必要 |

---

### 4.6 デザイントークン・ビジュアル言語視点（design_token）

#### Tailwind v4 デザイントークン体系

推奨は **3層アーキテクチャ**（セマンティック層を飛ばさないことが保守性の鍵）:

```
Base層     → 生の値（--blue-500: #3b82f6）
Semantic層 → 文脈依存名（--color-primary: var(--blue-500)）
Component層→ コンポーネント固有（--btn-bg: var(--color-primary)）
```

> Tailwind v4 では `@theme` 指令による CSS-first 定義が標準。**フレームワーク非依存**（Alpine.js でも適用可能）。

#### ダーク/ライトモード対応

| 方式 | 特徴 | 推奨度 |
|------|------|--------|
| メディアクエリ | システム設定追従、JS不要 | 基本 |
| クラスベース（`darkMode:'class'`） | ユーザー切替可能 | **推奨** |
| data-theme属性 | CSS変数と組み合わせ、最も柔軟 | 高機能 |

#### ビジュアルリファレンス

運用ツール系ダッシュボードに共通するデザインパターン:

| サービス | 特徴 |
|----------|------|
| **Vercel** | 純粋な黒白、装飾なし、タイポグラフィ・スペーシングのみ。APCA コントラスト基準 |
| **Linear** | Orbiter独自デザインシステム（Radix上構築）、8pxグリッド、ニュートラルカラー基調 |
| **Grafana/Datadog** | 大型ステータスインジケーター、タイル/テーブル+スパークライン、多彩な可視化 |

**共通パターン**: 限定的カラー使用（ステータス色のみ意味を持たせる）、情報密度優先、ダーク背景での眼精疲労軽減、ハイパーミニマリズム

#### ライブラリ別テーマオーバーライド特性

| ライブラリ | オーバーライド柔軟性 | 保守性 | 特記 |
|-----------|---------------------|--------|------|
| **shadcn/ui** | 最高（コード所有） | 高（ただしアップストリーム追従は手動） | CSS変数でテーマ制御 |
| **DaisyUI** | 中（35テーマ内蔵+CSS変数切替） | 高（依存ゼロ、プラグインのみ） | ランタイムテーマ切替が最もシンプル |
| Radix UI | 自由（ヘッドレス） | 低（全スタイリング自前） | スタイリングコスト最大 |

---

## 5. 統合分析（Synthesis）

### 5.1 最重要発見

#### 発見1: フレーミングバイアスの確認と是正

SCの調査計画が「Alpine.js→Next.js全画面フルリデザイン」と極端にフレーミングしたことにより、コスト・リスクが自動的に過大評価される構造が生まれた。**6視点中5視点が独立してフレームワーク非依存のビジュアル改善オプションの有効性を認めた。**

#### 発見2: Next.js 移行の正当性問題

| 問題 | 視点 |
|------|------|
| 内製ツールにSSR恩恵が限定的 | cost |
| Alpine.js→Next.js の技術的非互換性 | risk |
| ビッグバンリライトの失敗率 +70% | risk |
| WebSocket に Custom Server 必須 | technical |

#### 発見3: デザイントークンはフレームワーク非依存

Tailwind v4 `@theme` 指令による CSS-first デザイントークン体系は Alpine.js 環境でも適用可能。DaisyUI のランタイムテーマ切替・ダークモード対応も同様。

### 5.2 視点間の矛盾と解決

| 矛盾 | 視点間 | 解決 |
|-------|--------|------|
| Next.js 詳細調査 vs Alpine.js内改善で十分 | technical ↔ alternatives | Alpine.js 改善を第一選択。Next.js 知見は Phase C の材料として温存 |
| 3層デザイントークン推奨 vs 費用対効果の限界 | design_token ↔ cost | 軽量アプローチ採用（Base+Semantic 2層のみ） |
| IA再設計でmarkup大規模変更 vs CSS変更で完結主張 | ux_coherence ↔ alternatives | IA改善はCSS変更のみでは不可能だが、FW移行も不要。Alpine.js 内で markup 変更 |
| shadcn/ui を2025年デファクト評価 vs Radix メンテナンス低下リスク | technical ↔ risk | コード所有で既存影響は遮断。ただし Alpine.js 選択でこのリスク自体を回避 |
| 7画面全改善推奨 vs 3画面MVPで工数削減 | ux_coherence ↔ cost | MVP3画面で初期スコープ限定。7画面はロードマップとして保持 |

---

## 6. 推奨アクション

### 6.1 Primary: Alpine.js 環境内ビジュアルリデザイン

> **d-20260221-135800 Phase A 拡張版** として実施

**スコープ**: MVP3画面（アカウント選択 + 操作ダッシュボード + 設定）
**推定工数**: 60〜100h
**技術スタック**: Alpine.js + Tailwind CSS + DaisyUI + Vite最小構成（**React/Next.js 移行なし**）

#### 実施内容

| # | 内容 | 根拠視点 |
|---|------|---------|
| 1 | **情報アーキテクチャ再設計** — 10+セクション縦スクロール → サイドバーナビ + メインパネル構造 | ux_coherence |
| 2 | **デザイントークン導入** — CSS変数ベースの軽量トークン（Base+Semantic 2層）+ DaisyUI セマンティッククラス + ダーク/ライトモード | design_token + cost |
| 3 | **ダッシュボード画面統合** — 運用制御+状態表示をヒーローゾーンに統合、ステータス表示のアクセシビリティ改善 | ux_coherence |
| 4 | **カラーシステム刷新** — bg-gray 単調パレット → ニュートラルベース + ステータス色のみ意味を持たせるシステム | ux_coherence + design_token |
| 5 | **Alpine.js コンポーネント化** — Alpine.data() による論理分割 + TailAdmin/Penguin UI/Pines パターン活用 | alternatives + technical |

#### 推奨の根拠

- **過去3決定と完全整合**（d-20260222-223515, d-20260221-135800, d-20260213-213837）
- **工数30〜50%削減**（Next.js 移行比、cost視点）
- **API移行リスク回避**（APIコントラクト変更による廃棄リスクゼロ、risk視点）
- **認知負荷管理可能**（3画面 × 改善 < 7±2の上限内、risk視点）
- **Radix/shadcn/uiエコシステムリスク完全回避**（risk視点）
- **特定された7カテゴリの問題はすべてFW移行なしで改善可能**（ux_coherence視点）

#### 既知のリスク

- Alpine.js の構造的上限（TypeScript非対応、テスト容易性の限界）は改善されない
- DaisyUI + Alpine.js の大規模ダッシュボード実績データが不足
- CDN版Tailwind → Viteビルドパイプライン導入が前提条件として追加
- ビジュアル目標の完了基準（Definition of Done）を事前定義すべき

### 6.2 Fallback: Phase A のみ先行完了

**トリガー条件**（いずれか発生時）:
1. Primary 開始後 20h 時点で 3画面中1画面も IA再設計が完了していない
2. Alpine.js の x-data 単一スコープ制約がサイドバーナビ構造をブロック
3. Phase B（API移行）が先に完了し UIコード量が50%以上削減された

**内容**: Phase A（ESM分割のみ、20〜40h）を完了後、Phase B（API移行）→ Phase C（UI技術判断）の順序に従う。Phase C では本リサーチの Next.js 知見を判断材料として活用。

### 6.3 Abort: UIリデザイン中止

**全条件同時成立時**:
1. API移行が未着手 or 初期段階（完了まで3ヶ月以上）
2. API移行によりUIの50%以上が廃棄見込み
3. 現状UIで運用上の致命的問題が未発生

→ d-20260213-213837 の API移行に全リソースを集中。

---

## 7. Devil's Advocate 評価

### 7.1 判定: GO

前回指摘の Must Fix 3件（MF-001〜003）はすべて解決済み。

| ID | 指摘内容 | 状態 |
|----|---------|------|
| MF-001 | 現状UIの視覚的分析が欠如 | **解決** — ux_coherence が7カテゴリの問題を特定 |
| MF-002 | 「60-80%達成可能」が根拠なき数値 | **解決** — 撤回済み、3層分類で代替 |
| MF-003 | SC のフレーミングバイアス | **解決** — 5視点がFW非依存改善を独立評価 |

### 7.2 残存する弱点

#### 研究非対称バイアス（Medium severity）

拒否されたスタック（Next.js + shadcn/ui）には technical 視点が5つの詳細調査を実施。一方、**推奨スタック（Alpine.js + DaisyUI）に対する同等深度の技術調査は存在しない**。推奨を支持する判断材料の方が拒否の判断材料より薄いという逆転現象。

#### 前提リスク

| 前提 | リスク | 影響度 |
|------|--------|--------|
| Alpine.js x-data がサイドバーナビ構造を許容 | **未検証**。Fallback トリガーに設定されている | 高 |
| DaisyUI + Alpine.js がダッシュボードに十分な表現力 | 大規模実績データなし | 中 |
| 60-100h で完了 | 2268行 HTML の構造変更コスト未反映 | 中 |
| Vite 導入は低コスト | 既存 Express 構成との統合方法未調査 | 低〜中 |

### 7.3 DA からの Should Fix 提案

1. **推奨スタックの統合実現性検証** — Alpine.js x-data + サイドバーナビの POC、DaisyUI v5 + Tailwind v4 互換性確認、Vite + Express 統合パターン
2. **工数見積もりの内訳明示** — Vite導入、2268行HTML構造変更、DaisyUI学習・カスタマイズの各コスト
3. **MVP完了基準の事前定義** — 7カテゴリの問題のうちMVPで対処するもの/しないものを明確化

### 7.4 未カバー領域

本リサーチで調査されなかった領域:

- **インタラクションデザイン** — ホバー状態、トランジション/アニメーション、ローディング/エラー/エンプティ状態
- **レスポンシブデザイン** — モバイル対応要件の確認
- **競合UI分析** — Buffer, Hootsuite 等の類似ツールとの比較

---

## 8. 次のアクション

| 優先度 | アクション | 備考 |
|--------|-----------|------|
| 1 | API移行（d-20260213-213837）の進捗状況を確認 | Abort 判断の前提条件 |
| 2 | Alpine.js x-data + サイドバーナビ構造の POC 実施 | Fallback トリガーの早期検証 |
| 3 | DaisyUI + Tailwind v4 + Vite の最小構成セットアップ | 推奨スタックの技術検証 |
| 4 | MVP3画面の完了基準（Definition of Done）を定義 | スコープクリープ防止 |
| 5 | Primary 推奨の実施開始 | 上記1-4の確認後 |

---

## 付録: 調査ソース一覧

### 技術視点
- [Next.js App Router - Server/Client Components](https://nextjs.org/docs/app/getting-started/server-and-client-components)
- [Next.js Route Handlers](https://nextjs.org/docs/app/getting-started/route-handlers)
- [Next.js Authentication Guide](https://nextjs.org/docs/app/guides/authentication)
- [TanStack Virtual](https://tanstack.com/virtual/latest)
- [Pines (Alpine.js + Tailwind)](https://devdojo.com/pines)
- [Penguin UI](https://www.penguinui.com/)

### コスト視点
- [UI/UX Design Cost - UX4Sight](https://ux4sight.com/blog/ui-ux-design-cost)
- [DaisyUI vs shadcn](https://www.subframe.com/tips/daisyui-vs-shadcn)
- [Next.js: When Not to Use It](https://medium.com/@annasaaddev/the-dark-side-of-next-js-when-not-to-use-it-506e0d94d920)
- [ROI of Design Systems](https://www.netguru.com/blog/roi-design-systems)

### リスク視点
- [API Contracts - Evil Martians](https://evilmartians.com/chronicles/api-contracts-and-everything-i-wish-i-knew-a-frontend-survival-guide)
- [Radix UI Future - shadcn/ui Risk](https://mashuktamim.medium.com/is-your-shadcn-ui-project-at-risk-a-deep-dive-into-radixs-future-91af267c4bec)
- [React 19 Security Vulnerability](https://react.dev/blog/2025/12/11/denial-of-service-and-source-code-exposure-in-react-server-components)
- [Big Bang Rewrite Risks](https://scalablehuman.com/2023/10/14/why-a-big-bang-rewrite-of-a-system-is-a-bad-idea-in-software-development/)

### 代替案視点
- [TailAdmin](https://tailadmin.com/)
- [Strangler Pattern for Frontend](https://medium.com/@felipegaiacharly/strangler-pattern-for-frontend-865e9a5f700f)
- [Incremental vs Big Bang Migration](https://medium.com/@navidbarsalari/incremental-migration-evolving-without-breaking-production-edf679769918)

### UX一貫性視点
- [Sidebar Menu UX Best Practices 2025](https://uiuxdesigntrends.com/best-ux-practices-for-sidebar-menu-in-2025/)
- [UX Strategies for Real-Time Dashboards](https://www.smashingmagazine.com/2025/09/ux-strategies-real-time-dashboards/)
- [Dashboard Design Principles](https://www.uxpin.com/studio/blog/dashboard-design-principles/)

### デザイントークン視点
- [Tailwind CSS v4 Theme](https://tailwindcss.com/docs/theme)
- [shadcn/ui Theming](https://ui.shadcn.com/docs/theming)
- [Vercel Design Guidelines](https://vercel.com/design/guidelines)
- [Linear UI Redesign](https://linear.app/now/how-we-redesigned-the-linear-ui)
