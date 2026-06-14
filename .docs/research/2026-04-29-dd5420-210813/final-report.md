# money-literacy 教材 Web アプリ MVP 技術スタック決定 — 最終リサーチレポート

- **Research ID**: `2026-04-29-dd5420-210813`
- **テーマ**: 成人向け金融リテラシー教材として、架空銀行 UI で残高・取引履歴・日付を自由編集できる家計シミュレーター（完全クライアントサイド・ローカルストレージ永続化・Educational Sample ウォーターマーク常時表示・複数銀行 UI 切替対応・PC/モバイル フルレスポンシブ）
- **モード**: validate（locked decisions 11 件を維持しつつ未決事項を調査）
- **最終判定**: **GO（Primary 採用推奨）**

---

## 1. エグゼクティブサマリー

| 項目 | 結論（Primary） |
|---|---|
| **FW** | **React 18 + TypeScript** |
| **ビルド** | **Vite 5/6**（v8 は今回見送り） |
| **CSS / テーマ** | **Tailwind CSS v4 + DaisyUI v5** + `data-theme` + CSS カスタムプロパティ |
| **状態管理** | **Zustand**（`persist` middleware + version=1） |
| **ストレージ** | **localStorage 直**（`createJSONStorage` ＋ try-catch） |
| **ルーティング** | **React Router**（history mode） + `404.html` フォールバック |
| **テスト** | **Vitest**（L1/L2） + **Playwright**（L3） |
| **ホスティング** | **Vercel**（Primary） / Netlify（Fallback） / GitHub Pages（最終手段） |
| **テーマ UX** | 3 アーキタイプ（みらい銀行=メガ型／コスモス銀行=地方型／つばさ銀行=ネオ型）＋ホーム画面タイル切替＋300ms カラークロスフェード |
| **ウォーターマーク** | 4 層防御（fixed overlay ＋ banner ＋ MutationObserver ＋ CSP frame-ancestors） |
| **想定実装期間** | 2-3 週間相当 |

**Fallback 案**: Svelte 5 (SvelteKit + adapter-static) + Tailwind v4 + DaisyUI v5 + Runes ストア + idb-keyval + Netlify。Implementer のハルシネーションが連発した場合、または bundle 200KB 超で TTI が許容できない場合のみ切替。

---

## 2. 調査計画（Investigation Plan）

### 2.1 スコープと境界

- **深さ**: 各未決事項について 3-5 候補に絞り、本プロジェクト制約に基づく定量/定性比較を実施。推奨 1 案 + フォールバック 1 案を提示。
- **広さ**: open_questions 12 件を全カバー。中核は **FW × ビルド × CSS × 状態管理 × テーマ機構** の 5 点。
- **対象外**: locked decisions 11 件（ウォーターマーク常時表示・架空銀行名のみ・3 画面構成・localStorage のみ・PNG/PDF エクスポート不実装・JSON エクスポート/URL 共有/プリセット同梱は MVP 外・完全クライアントサイド・money-literacy 配置・ハーネス本体不変更等）は議題化禁止。

### 2.2 調査視点

| 種別 | ID | フォーカス |
|---|---|---|
| 固定 | technical | 技術的実現性 |
| 固定 | cost | コスト・リソース |
| 固定 | risk | リスク・失敗モード |
| 固定 | alternatives | 代替案・競合 |
| 動的 | misuse_prevention | 悪用防止と教材安全性（ウォーターマーク堅牢性） |
| 動的 | theme_ux | 複数銀行テーマ切替の UX 設計 |

---

## 3. 視点別の主要発見

### 3.1 technical（技術的実現性）

| 論点 | 結論 | 信頼度 |
|---|---|---|
| MVP 3 画面 × 2-3 銀行を 2-3 週間で実装可能か | React+Vite+Tailwind v4+Zustand で実装可能。Vite v4 はフルビルド 5x 高速、HMR サブ秒。Tailwind v4 はセットアップ簡素化、`tailwind.config.js` 不要 | high |
| テーマ切替 100ms 以内達成 | `data-theme` 属性切替＋CSS 変数で再マウントなしで達成。color/background は repaint のみ（reflow 不要）。**ただし `*` セレクタは style recalculation 2.5x なので `:root` または `html[data-theme]` に限定** | high |
| Zustand persist の同期/非同期 | localStorage は同期 API で OK。version フィールドだけ MVP から導入推奨 | high |
| ウォーターマーク fixed + MutationObserver | 実装事例多数。childList のみ監視・subtree:false で性能影響軽微。CSS 直書換は検知不可（教育用途では許容） | high |
| GitHub Pages サブパス + history router | `vite.config base` ＋ `404.html` に index.html コピー方式が標準解。Netlify/Vercel は `_redirects` / `vercel.json` で対応 | high |
| ハーネス L1/L2/L3 のテスト構成 | Vitest（L1/L2） + Playwright（L3）。Playwright は claude -p 制約と独立 | high |

### 3.2 cost（コスト・リソース）

**学習コスト・事例量 比較**

| FW | npm 週間 DL（2025） | Stack Overflow 使用率 | 学習コスト |
|---|---|---|---|
| React | 約 5,000 万 | 44.7% | 高（JSX + Hooks + 状態管理選定） |
| Vue | 約 740 万 | 17.6% | 中（SFC で直感的） |
| Svelte | 約 206 万 | 7.2% | 中（最小ボイラープレート） |
| Alpine.js | 公開 DL 数不明 | — | 低（属性ベース） |

**バンドルサイズ（gzip）**

| FW + DaisyUI v5 | 想定総 JS |
|---|---|
| React + Vite | 約 80〜130KB |
| Vue + Vite | 約 70〜110KB |
| Svelte + Vite | 約 40〜80KB |
| Alpine.js + DaisyUI（CDN） | 約 50〜90KB |

→ Google 推奨上限 170KB（クリティカルパス）に全 FW がコード分割で収まる。

**1 テーマ追加コスト（スケーラビリティ）**

| 機構 | 変更ファイル | 追加 LOC | 10 銀行累計 |
|---|---|---|---|
| **DaisyUI / CSS 変数** | 1 | 25–45 | 175–360 LOC（推奨） |
| Tailwind config 拡張 | 1〜2 | 25–40 | 同等 |
| CSS Modules | 全 70-80 ファイル | 10-30 / 各 | 数千 LOC（**不適**） |

**1 タスク 1-3 ファイル制約への適合性**: Vue SFC ≥ Svelte > Alpine.js > React。React は TS+テストで 4 ファイル超リスク → task-planner で 1 タスク = 1 コンポーネント + styles に厳格分割。

### 3.3 risk（リスク・失敗モード）

| リスク | 重大度 | 対策 |
|---|---|---|
| OS スクショにウォーターマークが写らない失敗パターン | 高 | `position:fixed` ＋ `<body>` 直下 ＋ `z-index >= 9999` ＋ `pointer-events:none` ＋ `opacity 0.08-0.30` ＋ SSR/インライン埋込（遅延ロード禁止）＋ `@media screen` 明示 |
| localStorage QuotaExceededError によるサイレントロスト | 高 | 全 `setItem` を try-catch ＋ LRU エビクション ＋ `navigator.storage.estimate()` で残量警告 ＋ IndexedDB フォールバック準備 |
| WCAG AA 未達／EAA 2025 違反 | 高 | コントラスト 4.5:1 機械検証 ＋ ARIA ランドマーク ＋ 各テーマ個別 NVDA/VoiceOver 検証 |
| 実銀行 UI への偶発的酷似（商標/フィッシング誤認） | 中 | 架空名・配色は雰囲気インスパイア限定・汎用アイコン（Heroicons）・固定免責バナー |
| CSS 変数衝突／テーマ切替後の旧スタイル残留 | 中 | プレフィックス名前空間 ＋ `@scope` ＋ 切替時の旧属性完全リセット ＋ Playwright で computed style アサート |
| 編集モード×振込モード整合性破綻 | 中 | Single Source of Truth ＋ イミュータブルトランザクション（仕訳帳パターン）＋ 確認ダイアログ |
| Vite v8 Rolldown 移行コスト | 中 | **MVP は Vite 5/6 安定版固定。v8 は別タスク** |
| DaisyUI / Alpine.js のメンテ停止 | 低 | アクティブ開発継続中（DaisyUI v6 が 2026 年内予定） |

### 3.4 alternatives（代替案・競合）

**FW 適合度ランキング**

| 順位 | FW | 強み | 弱み |
|---|---|---|---|
| 1 | **Svelte 5 (SvelteKit)** | adapter-static でネイティブ SSG・Runes・bundle 最軽量・svelte-themer 成熟 | Runes 構文 2024 導入で事例薄・shadcn-svelte は非公式移植 |
| 2 | **React + Vite** | エコシステム最大・Implementer 安定生成・shadcn/ui 公式対応 | bundle やや重・1-3 ファイル制約に注意 |
| 3 | Vue 3 | DX スムーズ・SFC | エコシステム React より小 |
| 4 | SolidJS | 最速ランタイム（Signals 3ms vs Zustand 12ms） | SSG エコ未成熟・永続化プラグイン不在 |
| 5 | Preact | 3KB 最軽量 | 独自エコシステム制限 |

**ビルドツール**: Vite が `base` 設定一行でサブパス対応・公式デプロイガイド完備で最摩擦少。

**CSS**: Tailwind v4（表現力）＋ DaisyUI v5（テーマ実装最低コスト）が現実解。UnoCSS はビルド速度優先時のみ。

**状態管理永続化成熟度**: Zustand `persist` > Jotai `atomWithStorage` > Pinia (Vue 専用) > Signals 各種（自前実装必要）。

**類似 OSS**: 純粋な「教育用 × 架空銀行 × シミュレーター」OSS は **存在せず**。Actual Budget（IndexedDB パターン参考）、Firefly III（仕訳帳 UI 参考）。差別化軸は明確。

### 3.5 misuse_prevention（悪用防止と教材安全性）

**4 層防御（MVP 必須構成）**

| 層 | 内容 | 効果 |
|---|---|---|
| 1 | `<body>` 直下 `position:fixed` + `z-index 9999` + `pointer-events:none` + `opacity 0.08-0.15` のタイル状『EDUCATIONAL SAMPLE』オーバーレイ | OS スクショに確実に映る |
| 2 | 全ページ固定ヘッダ警告バナー（高コントラスト警告色＋『架空銀行シミュレーター｜教材専用サンプル｜EDUCATIONAL SAMPLE』） | スクロール耐性・誤認防止 |
| 3 | MutationObserver で `<body>` 直下のみ `childList:true` + `attributes:true` 監視、削除/属性改竄を検知して自動再挿入 | DevTools 削除への抑止 |
| 4 | `Content-Security-Policy: frame-ancestors 'none'` + `X-Frame-Options: DENY` + JS frame-busting（`window.top !== window.self`） | iframe 埋込攻撃の遮断 |

**重要な実装制約**: 親要素に `transform / filter / opacity / will-change / contain` があると `position:fixed` がスタッキングコンテキストに閉じ込められ z-index が無効化 → React `Portal` で `<body>` 直下に強制レンダー。

**架空性表示の推奨文言**:
> 「このサービスは架空の銀行を模したシミュレーターです。教材専用のサンプルであり、実在する金融機関とは一切関係ありません。実際の個人情報・金融情報を入力しないでください。」

**MVP に組み込まないもの**: ウォーターマーク解除試行を検知して教育演出するメタ機能（学習主目的から外れ ROI 低）。

### 3.6 theme_ux（複数銀行テーマ切替 UX）

**3 アーキタイプ設計**

| アーキタイプ | 仮称 | プライマリカラー | レイアウト | コーナー | タイポ |
|---|---|---|---|---|---|
| メガバンク型 | みらい銀行 | 濃紺 × 深紅 | 高密度 | 鋭角（≤4px） | 明朝/ゴシック混在・レギュラー |
| 地方銀行型 | コスモス銀行 | 暖色ブルー | 中密度 | 中（8-12px） | ゴシック・穏やか |
| ネオバンク型 | つばさ銀行 | 鮮やかシグネチャー1色 | ミニマル | 大角丸（16-24px） | ラウンドサンセリフ・大 |

**UX 仕様**

- **切替 UI 配置**: ホーム画面タイル選択（教材として「選ぶ行為自体が学習」になる）。サイドナビ／設定画面内は不適。
- **切替速度**: 150-300ms カラークロスフェード（Doherty Threshold 内）。ゼロ秒は教材文脈ではコンテキスト切替認知が薄れる。
- **データ設計**: **銀行ごと独立シナリオ**保持（銀行間差異の体感が教育価値）。
- **モバイル/PC 差別化**: モバイル＝色＋カード形状で識別、デスクトップ＝サイドナビ＋広いヘッダで色帯強調。
- **参照可能情報源**: ブランドカラー DB（SchemeColor / Encycolorpedia）、Figma Community 無料 UI キット、UX 分析ブログ。**禁止**: 実銀行スクショの直接模倣・実在銀行名の使用。

---

## 4. 視点間の対立と解決（Synthesizer 統合）

| 対立 | 内容 | 解決 |
|---|---|---|
| technical vs alternatives | React 推奨 vs Svelte 5 推奨 | **Implementer の安定生成が成功率を支配**（事例量比 25:1）。Primary=React、Fallback=Svelte 5 |
| cost vs alternatives | 1-3 ファイル制約は Vue/Svelte 有利 vs React 事例優位 | task-planner で 1 タスク = 1 コンポーネント + styles に厳格分割、テストは別タスク化で対処 |
| misuse_prevention vs technical | CSP frame-ancestors 必須（Vercel/Netlify 優位）vs GitHub Pages 検討 | **Primary=Vercel**（vercel.json で headers 設定可）。GitHub Pages は CSP カスタムヘッダ不可で最終手段 |
| risk vs misuse_prevention | 「完全防御不可・抑止」温度差 | OS スクショ映り込み + 一般攻撃者抑止までで打ち止め。DevTools 操作攻撃は scope 外明示 |
| alternatives vs cost | Tailwind v4 / UnoCSS vs DaisyUI 推奨 | DaisyUI は Tailwind v4 プラグインのため**両立**。Primary=Tailwind v4 + DaisyUI v5 |

---

## 5. Primary 推奨スタック（実装ガイド）

### 5.1 技術構成

```
React 18 + TypeScript
├─ Vite 5/6（base 設定でサブパス対応）
├─ Tailwind CSS v4 + DaisyUI v5
│   ├─ data-theme: mirai / cosmos / tsubasa
│   └─ :root[data-theme=...] スコープ（* セレクタ禁止）
├─ Zustand（persist middleware）
│   ├─ name: 'money-literacy-store'
│   ├─ version: 1
│   ├─ storage: createJSONStorage(() => localStorage)
│   └─ try-catch で QuotaExceededError ハンドリング
├─ React Router（history mode）
├─ Vitest（L1/L2）
└─ Playwright（L3 / Chromium）
```

### 5.2 ウォーターマーク 4 層防御（実装テンプレ）

```tsx
// React Portal で <body> 直下に強制レンダー
ReactDOM.createPortal(
  <>
    <div data-watermark-banner style={{
      position:'fixed', top:0, left:0, width:'100%',
      backgroundColor:'#FF6F00', color:'#fff', zIndex:10000,
      pointerEvents:'none'
    }}>架空銀行シミュレーター｜教材専用サンプル｜EDUCATIONAL SAMPLE</div>
    <div data-watermark-overlay style={{
      position:'fixed', inset:0, zIndex:9999,
      pointerEvents:'none', opacity:0.10,
      backgroundImage:'repeating-linear-gradient(-30deg, ... EDUCATIONAL SAMPLE ...)'
    }}/>
  </>,
  document.body
);

// MutationObserver で改竄復元
new MutationObserver(() => {
  if (!document.querySelector('[data-watermark-overlay]')) {
    /* 再挿入 */
  }
}).observe(document.body, { childList: true, attributes: true, subtree: false });
```

### 5.3 ホスティング設定（`vercel.json`）

```json
{
  "headers": [{
    "source": "/(.*)",
    "headers": [
      { "key": "X-Frame-Options", "value": "DENY" },
      { "key": "Content-Security-Policy", "value": "frame-ancestors 'none'" }
    ]
  }],
  "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }]
}
```

---

## 6. リスクと緩和策（Primary 採用時）

| # | リスク | 緩和策 |
|---|---|---|
| 1 | Tailwind v4 + DaisyUI v5 の v3/v4 時代コードが Implementer ハルシネーション源 | task-planner プロンプトに v4/v5 構文の例示を明示埋込 |
| 2 | Vite v8 Rolldown 移行コスト | MVP は Vite 5/6 安定版固定、v8 は別タスク |
| 3 | MutationObserver は `observer.disconnect()` でバイパス可能 | 許容（locked decision が完全防御を要求していない） |
| 4 | GitHub Pages 採用時に CSP カスタムヘッダ不可 | Primary=Vercel、GitHub Pages は Fallback で JS frame-busting のみ |
| 5 | DaisyUI デフォルトテーマ AA 境界ギリギリ | 各銀行テーマ色定義時に WebAIM contrast checker 4.5:1 機械検証を **L1-004** で必須化 |
| 6 | React + TS + テストで 1 タスク 4 ファイル超 | task-planner で 1 タスク = 1 コンポーネント + styles のみ・hooks/tests は別タスク化を assertions で強制 |
| 7 | localStorage QuotaExceededError 時のデータロスト | setItem を try-catch でラップ・警告 UI 表示・IndexedDB フォールバックは後続フェーズ |
| 8 | 親要素 transform 等で `position:fixed` がスタッキングに閉じ込められる | React Portal で `<body>` 直下強制レンダー＋ L3 で親要素チェック |

---

## 7. Fallback 案

**Svelte 5 (SvelteKit + adapter-static) + Tailwind v4 + DaisyUI v5 + Runes ストア + idb-keyval + svelte-routing + Vitest + Playwright + Netlify (`_headers`)**

**切替トリガー**:
- (a) Implementer が React+Tailwind v4+DaisyUI v5 で **3 タスク連続ハルシネーション** & is_correct=false
- (b) Phase 2 回帰テストで **bundle > 200KB** が継続し 3G 想定で TTI > 5s
- (c) DaisyUI v5 のテーマ API が複数銀行同時切替に致命的制約

---

## 8. Phase 1.5 で生成された実装基準（implementation-criteria.json）概要

### 8.1 Layer 1（ファイル構造・型・lint・unit test）

| ID | 概要 | 実行コマンド |
|---|---|---|
| L1-001 | TypeScript / ESLint / Vite build 通過 | `npm run typecheck && npm run lint && npm run build` |
| L1-002 | Zustand persist ストア（localStorage 同期 + version + Quota ハンドリング） | `npx vitest run src/store/__tests__/store.test.ts` |
| L1-003 | ウォーターマーク 4 層構造（DOM 配置・Portal・MutationObserver 復元） | `npx vitest run src/components/Watermark/__tests__/Watermark.test.tsx` |
| L1-004 | data-theme 切替・CSS 変数解決・WCAG AA コントラスト機械検証 | `npx vitest run src/theme/__tests__/theme.test.ts` |
| L1-005 | 残高計算・取引ソート・日付編集の純関数 | `npx vitest run src/lib/__tests__/finance.test.ts` |
| L1-006 | エントリポイント・ルーティング・vercel.json・404.html 存在検証 | `test -f` 系 + `jq -e` |

### 8.2 Layer 2（統合テスト）

| ID | 概要 |
|---|---|
| L2-001 | Vitest 一括実行＋カバレッジ |
| L2-002 | Vite dev server ポート 3001 起動＋主要ルート 200 確認 |
| L2-003 | Playwright E2E 基本シナリオ（テーマ切替・取引追加・ウォーターマーク） |

### 8.3 Layer 3（行動検証 / Playwright E2E）

| ID | 概要 | strategy | blocking |
|---|---|---|---|
| L3-001 | 3 銀行切替で data-theme 更新＋独立データ保持 | api_e2e | ✅ |
| L3-002 | ウォーターマーク 4 層改竄復元・computed style 検証 | api_e2e | ✅ |
| L3-003 | 編集モード×振込フォーム両経路の SSoT 整合＋リロード後復元 | api_e2e | ✅ |
| L3-004 | エクスポート JSON が JSON Schema に適合 | structural | ✅ |
| L3-005 | 3 テーマの視覚識別性＋商標回避＋AA 観察を LLM 判定 ≥ 0.70 | llm_judge | ❌ |
| L3-006 | QuotaExceededError 擬似発生時のグレースフルデグラデーション | api_e2e | ✅ |

### 8.4 開発フェーズ（task-stack 生成基準）

| Phase | ゴール | mutation 閾値 | 主な criteria |
|---|---|---|---|
| **mvp** | 1 銀行で残高表示・取引追加・永続化が E2E 動作＋ウォーターマーク 4 層常駐 | 0.4 | L1-001/002/003/005/006, L2-002, L3-002/003 |
| **core** | 3 銀行切替＋独立データ保持＋直接編集＋エクスポート | 0.3 | L1-004/005, L2-001/003, L3-001/003/004/006 |
| **polish** | PC/モバイル全幅破綻なし＋WCAG AA＋ウォーターマーク改竄耐性 | 0.2 | L1-003/004/006, L2-003, L3-002/005 |

---

## 9. 残された Gap・要追加検証

| 領域 | Gap |
|---|---|
| 性能 | テーマ切替 100ms 以内・MutationObserver 再描画オーバーヘッドの定量ベンチマーク未取得 |
| バンドル | Vite スターターの transitive 依存数は推定値。`npm ls --all` で実測推奨 |
| Tailwind v4 | `*` セレクタ vs `:root` の style recalculation 比較は旧情報ベース |
| OS スクショ | Windows / macOS / iOS / Android 各 OS での実機ウォーターマーク映り込み検証なし |
| 法務 | 日本の銀行法・金融商品取引法における架空銀行シミュレーターの免責表示義務、UI トレードドレス保護の専門家確認は scope 外 |
| GitHub Pages | `<meta http-equiv>` による CSP の frame-ancestors 有効性（MDN ではサポートされないと示唆） |
| 教育効果 | 「複数銀行 UI 教材」に特化した学習効果測定の一次研究は未発見 |
| Svelte 5 | Runes 構文での実アプリビルド時間ベンチマーク 2025 年時点で薄い |
| 永続化 | Signals 系（SolidJS/Preact）の localStorage 永続化専用ライブラリ未確認 |

---

## 10. 結論

本リサーチは固定 4 視点 + 動的 2 視点（misuse_prevention, theme_ux）の合計 6 視点で money-literacy 教材 Web アプリの MVP 技術スタックを評価した。**locked decisions 11 件すべてと整合（conflicts ゼロ）** し、すべての視点で high〜medium 信頼度の根拠が得られた。

**Primary 推奨**: React 18 + TypeScript + Vite 5/6 + Tailwind v4 + DaisyUI v5 + Zustand + React Router + Vitest + Playwright + Vercel ホスティング、ウォーターマーク 4 層防御、3 アーキタイプによる視覚差別化。

実装は MVP（1 銀行 + ウォーターマーク 4 層）→ Core（3 銀行独立 + 編集 + エクスポート + Quota）→ Polish（WCAG AA + レスポンシブ + 改竄耐性 + LLM 判定）の 3 フェーズで進行可能。所要 2-3 週間相当、ハーネス Phase 2（Ralph Loop）に直接投入できる粒度の実装基準が整備済み。
