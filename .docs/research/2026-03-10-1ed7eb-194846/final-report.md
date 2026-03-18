# タロット占いWebアプリ開発 リサーチ最終レポート

> **リサーチID**: `2026-03-10-1ed7eb-194846`
> **テーマ**: Next.js App Router + OpenAI互換LLM抽象化層 + 4種スプレッド + Ollama/qwen3.5:27b最適化
> **生成日**: 2026-03-10

---

## 目次

1. [調査概要](#1-調査概要)
2. [コア調査項目と結論](#2-コア調査項目と結論)
3. [視点別調査結果](#3-視点別調査結果)
4. [視点間の矛盾と解決](#4-視点間の矛盾と解決)
5. [過去決定との整合性](#5-過去決定との整合性)
6. [統合推奨事項](#6-統合推奨事項)
7. [実装基準（成功条件）](#7-実装基準成功条件)
8. [フェーズ計画](#8-フェーズ計画)
9. [リスクと未解決事項](#9-リスクと未解決事項)

---

## 1. 調査概要

### 1.1 調査テーマ

Next.js App Router + OpenAI互換LLM抽象化層によるタロット占いWebアプリ（uranai-2）の技術選定。Ollama/qwen3.5:27bをプライマリLLMとし、4種スプレッド（ワンオラクル・スリーカード・ヘキサグラム・ケルト十字）に対応する。

### 1.2 コア調査項目（5問）

| # | 調査項目 | 核心 |
|---|---------|------|
| Q1 | LLMクライアント実装方式 | openai SDK vs fetch vs vercel/ai SDK、Ollama互換性 |
| Q2 | JSON出力安定化戦略 | format:json + jsonrepair + Zodリトライの最適組み合わせ |
| Q3 | カードアニメーション | CSS 3D Transform vs GSAP vs Framer Motion |
| Q4 | SSEストリーミング | Runtime選択、Vercelタイムアウト制約、Ollama互換性 |
| Q5 | レート制限 | Upstash vs Vercel WAF vs in-memory |

### 1.3 調査視点（6視点）

| 視点 | フォーカス | 信頼度 |
|------|----------|--------|
| technical | 技術的実現性 | High |
| local_llm_compat | Ollama/qwen3.5固有の互換性制約 | Medium-High |
| risk | リスク・失敗モード | High |
| alternatives | ロック範囲内での代替案比較 | High |
| deploy_topology | Vercel+Ollamaトポロジー整合性 | High |
| cost | コスト・リソース | Medium |

### 1.4 露出された暗黙の前提（8件）

1. **Vercel＋Ollamaの物理的矛盾**: Vercelからlocalhost接続は不可能。開発環境=Ollama、本番=クラウドLLMの環境分離が未定義
2. **OllamaのOpenAI互換APIが完全互換**: 実際にはJSON mode、streaming chunk形式、thinkingモード制御に差異あり
3. **qwen3.5:27bの日本語品質が実用水準**: IFEval 95.0は鑑定文品質を保証しない
4. **thinkingモードOFF制御の確実性**: qwen3.5:27bでの具体的な無効化パラメータの実効性が未確認
5. **ケルト十字のローカル生成レイテンシ**: ハイエンドGPUでも2分超過の可能性
6. **SSEストリーミングのUX改善余地**: JSON完全取得後パース制約下では実質「生成中…」表示に限定
7. **小アルカナ56枚のLLM一括生成品質**: スート間・ナンバー間での品質一貫性が未保証
8. **プロンプトテンプレートのfs.readFile**: Next.js App Routerのビルド体系との整合が未検討

---

## 2. コア調査項目と結論

### Q1: LLMクライアント実装 → **vercel/ai SDK + createOpenAICompatible**

| 候補 | バンドルサイズ(gzip) | Ollama互換 | テスタビリティ | プロバイダー切替 |
|------|---------------------|-----------|--------------|----------------|
| **(a) openai SDK + baseURL** | 34–130 kB※ | ○ (実績最多) | MSW / vi.fn() | 手動切替 |
| **(b) fetch + 自前ラッパー** | 0 kB | ○ | vi.fn() (最容易) | 自前実装 |
| **(c) vercel/ai SDK** ★推奨 | **19.5 kB** | ○ (ollama-ai-provider) | **組込テストヘルパー** | **25+プロバイダー統一IF** |
| **(d) ollama-js** | — | ◎ (ネイティブ) | 独自 | 抽象化要 |

※openai SDKのバンドルサイズは情報源により34.3 kB〜129.5 kBと大きな乖離あり

**決定理由**: バンドルサイズ最軽量、環境変数1本でOllama⇔OpenRouter切替、Next.js/React Streamingとの最高親和性。ロック決定「client.tsに依存閉じ込め」を`createOpenAICompatible`で完全充足。

### Q2: JSON安定化 → **3層防御（GBNF + jsonrepair + Zodリトライ）**

```
Layer 1: format:json (GBNF grammar-constrained decoding)
  ├─ <think>タグを確率-∞で自動抑制 → thinkingモード汚染リスクを構造的に解消
  └─ + think:false APIパラメータ（二重防御）
         ↓ (JSON不正の場合)
Layer 2: jsonrepair v3.13+ (依存ゼロ、515KB unpacked)
  └─ 末尾截断・クォート欠損・コンマ誤配置を >95% 修復
         ↓ (修復失敗の場合)
Layer 3: Zodスキーマ検証 + max 3回リトライ
  └─ temperature=0 で決定論的出力を強制
```

**重要発見**: format:jsonのGBNFは`<think>`タグを含む無効トークンを自動抑制する。これにより、risk視点が指摘した`<think>`タグJSON汚染リスクはformat:json使用時に**構造的に解消**される。

**partial-jsonはv1スコープから除外**: 2年間更新なし（npm 123プロジェクト）のメンテリスク、JSON完全取得後パース制約下で出番が限定的。

### Q3: アニメーション → **CSS 3D Transform（単体フリップ）+ GSAP（シャッフル）**

| 用途 | 技術 | バンドル | 理由 |
|------|------|---------|------|
| カードフリップ | CSS 3D Transform + @keyframes | **0 kB** | Server Component対応、Tailwind arbitrary valuesで実装可 |
| シャッフル・展開 | GSAP timeline | **+23 kB** | Timeline.staggerで複雑シーケンス制御、Flip Pluginで位置計算自動化 |

**注意**: モバイルSafariで`transform-style: preserve-3d`の多要素同時適用はクラッシュリスクあり。preserve-3dは単体カードフリップに限定し、シャッフル演出はGSAPに委ねる。`will-change`はアニメーション直前付与・完了後除去。

### Q4: SSE + Runtime → **Node.js Runtime + Fluid Compute（300秒）**

| Runtime | タイムアウト | TTFT制約 | fs対応 | 推奨度 |
|---------|-----------|---------|-------|--------|
| Edge Runtime | 300秒 (streaming) | **25秒以内に初回送信必須** | ✗ | ✗ |
| **Node.js + Fluid Compute** ★ | **300秒** | **なし** | **✓** | **◎** |
| Node.js (Fluid Computeなし) | 10秒 (デフォルト) | なし | ✓ | △ |

**決定理由**: Edge Runtimeの25秒TTFT制約はOllamaのコールドスタート+27Bモデル初回推論で超過リスクが高い。Node.js Runtimeは`fs.readFile`（プロンプトテンプレート読み込み）も利用可能で技術的に整合。`maxDuration`を明示設定（300秒）すること。

**SSE実装パターン**:
- `ReadableStream` + `request.signal.addEventListener('abort')` で切断検知
- 必須ヘッダ: `Content-Type: text/event-stream`, `X-Accel-Buffering: no`, `Cache-Control: no-cache,no-transform`
- keep-alive: 30秒毎に `: keepalive\n\n` 送信

### Q5: レート制限 → **@upstash/ratelimit + Upstash Redis**

| 候補 | Serverless対応 | 無料枠 | 状態管理 |
|------|---------------|--------|---------|
| **(a) @upstash/ratelimit** ★推奨 | ◎ (HTTPベース) | **500K cmd/月** | 分散Redis |
| (b) Vercel WAF | ○ | Pro以上必須 | Vercel内完結 |
| (c) next-rate-limit | — | — | 信頼できる情報なし |
| (d) 自前Map + setInterval | ✗ | — | **冷起動で状態消失** |

**重要更新**: 無料枠は旧10,000 req/dayから**500,000 commands/月**に拡大済み。EVALSHA 1回=1コマンド課金のため、月50万チェック（日1.67万）が可能。Fixed Windowアルゴリズム推奨。

---

## 3. 視点別調査結果

### 3.1 技術的実現性（technical）

| 項目 | 結論 | 信頼度 |
|------|------|--------|
| T1: openai SDK Ollama互換性 | baseURL差し替えで基本動作。thinkingモードは非透過的（extra_body必要） | Medium |
| T2: CSS 3D Transform安定性 | Chrome/Firefox安定。**モバイルSafariにpreserve-3dクラッシュ・バグ群あり** | High |
| T3: Next.js SSE実装 | ReadableStream + abort listenerパターンが確立 | High |
| T4: Ollama streaming互換性 | chunk形式はOpenAI準拠。`data:[DONE]`実装済み。`stream_options`指定でusage返却 | High |
| T5: fs.readFile on Vercel | Node.js Runtimeで動作。`outputFileTracingIncludes`設定が必須。`process.cwd()`使用 | High |

**最大の懸念**: モバイルSafariのCSS 3D transform不安定性（クラッシュリスク、backface-visibilityの-webkit-プレフィックス必要）

### 3.2 Ollama/qwen3.5:27b互換性（local_llm_compat）

| 項目 | 結論 | 信頼度 |
|------|------|--------|
| LC1: format:json安定性 | GBNFで動作、`<think>`タグ自動抑制。ただしtool callingバグ群は別問題 | Medium |
| LC2: thinkingモード無効化 | **`think:false` APIパラメータが唯一の信頼手段**。/no_thinkはqwen3.5非サポート、Modelfile設定も不可 | High |
| LC3: streaming応答互換性 | SSE基本互換。**全チャンクにrole:assistant重複**（#7626）→ `client.beta.chat.completions.stream`が破損。基本stream iteratorは正常 | High |
| LC4: 並行リクエスト | NUM_PARALLEL=1が実質的。同時リクエストはFIFOキューでシリアル化。27Bモデルでは複数ユーザーのレイテンシが顕著に増大 | Medium |

### 3.3 リスク・失敗モード（risk）

| リスク | 深刻度 | 対策 |
|--------|--------|------|
| R1: JSON修復失敗 | **中** | 構造的破壊は<5%。format:json + jsonrepair + Zodリトライの3層で対応 |
| R2: Vercelタイムアウト | **高** | Edge 25秒TTFT制約 → Node.js Runtime + Fluid Compute（300秒、TTFT制約なし）で回避 |
| R3: `<think>`タグ汚染 | **高→低** | format:jsonのGBNFが自動抑制 + think:false二重防御で**構造的に解消** |
| R4: モバイルSSE不安定 | **中** | iOS Safari バックグラウンドでSSE停止。visibilitychange監視 + keep-alive + サーバーサイド結果保持で対策 |
| R5: openai SDK互換性破壊 | **低** | 基本chat.completions.createは安定。Ollama側が「実験的」と警告 |

### 3.4 代替案比較（alternatives）

各Q1〜Q5について3〜5候補を比較（詳細は上記「コア調査項目と結論」セクション参照）。

### 3.5 デプロイトポロジー（deploy_topology）

#### MVP段階の現実的な選択肢

| 構成 | 本番適性 | LLMコスト | 制約 |
|------|---------|----------|------|
| **(a) Vercel + OpenRouter** | ◎ (最も実用的) | 従量課金 | Hobby plan商用利用禁止 → **Pro $20/月必須** |
| (b) VPS + Docker + Ollama | ○ (運用負荷あり) | **$0** | CPU推論: 3–15 tok/s (遅い) |
| (c) Vercel + ngrok/Tunnel | ✗ (開発専用) | $0 | URL不安定、SLA保証なし |

**結論**: MVP = localhost開発環境でOllamaプライマリ。Vercelデプロイ時はclient.tsの環境変数切替でOpenRouter等クラウドLLMフォールバック。d-20260306-220822の「ローカル開発環境限定をPhase 1」方針を踏襲。

#### Vercel Hobbyプラン容量試算

| メトリクス | 制限 | 1,000 DAU試算 | 枯渇DAU |
|-----------|------|-------------|---------|
| Function Invocations | 100万/月 | 9万 (9%) | ~1.1万 |
| Fast Data Transfer | 100 GB/月 | 900 MB (0.9%) | ~33万 |
| Active CPU | 4 CPU-hrs/月 | ほぼゼロ※ | — |

※LLM呼び出しはI/O待ちのためCPU消費がほぼゼロ

**最大の障壁は商用利用禁止**。技術的制約ではなく利用規約が先にボトルネックになる。

### 3.6 コスト・リソース（cost）

| 項目 | 結論 |
|------|------|
| C1: バンドルサイズ | Vercel 50MB/関数に対しどの選択肢も0.37%以下。直接脅威なし |
| C2: JSON修復ライブラリ | jsonrepair: 依存ゼロ、515KB、アクティブメンテ。partial-json: 2年更新なし→リスク |
| C3: アニメーション工数 | フリップ単体: CSS-only 1–2h。シャッフル込み: GSAP 4–8h vs CSS-only 16–24h |
| C4: Upstash無料枠 | 500K cmd/月（旧10K/dayから大幅改善）。~500 MAU規模まで無料運用可 |
| C5: 実装工数 | 最小構成 7–15h、フル構成 15–30h（d-20260304-005644の48–92hはスコープが広い可能性） |

---

## 4. 視点間の矛盾と解決

### 矛盾1: Runtime選択（technical × risk × deploy_topology）

| 視点 | 主張 |
|------|------|
| technical | Edge Runtime + ReadableStreamパターンを推奨 |
| risk | Edge 25秒TTFT制約が**最重大リスク** |
| deploy_topology | Node.js Runtimeの方が安全（TTFT制約なし） |

**→ 解決**: **Node.js Runtime + Fluid Compute**を採用。Edge Runtimeの25秒制約はOllamaコールドスタート+27B初回推論で超過リスクが高い。fs.readFile（テンプレート読込）もNode.jsでのみ動作。d-20260306-220822の判断を支持。

### 矛盾2: thinkingモード無効化（local_llm_compat × risk）

| 視点 | 主張 |
|------|------|
| local_llm_compat | qwen3.5は`/no_think`非サポート。`think:false`が唯一の信頼手段 |
| risk | `enable_thinking=True` + `/no_think`付加が最も安全 |

**→ 解決**: local_llm_compatを優先。riskの`/no_think`推奨はvllm環境のQwen3系検証に基づき、Ollama+qwen3.5には適用不可。さらにformat:jsonのGBNFが`<think>`タグを自動抑制するため、JSON出力用途では**format:json + think:false**の二重防御で十分。

### 矛盾3: クライアントSDK選択（alternatives × technical）

| 視点 | 主張 |
|------|------|
| alternatives | vercel/ai SDK最推奨（軽量・テストヘルパー・プロバイダー統一） |
| technical | openai SDK + baseURL差し替えの実績を重視 |

**→ 解決**: vercel/ai SDKをPrimary、openai SDKをFallbackとして保持。vercel/ai SDKの`ollama-ai-provider`がOllamaのroleフィールド重複バグを透過処理する点が決め手。

### 矛盾4: Vercel + Ollamaの物理的矛盾（ロック決定同士）

「Vercelデプロイ」と「Ollama+qwen3.5プライマリ」は物理的に矛盾（Vercelからlocalhost接続不可）。

**→ 解決**: ロック決定を変更せず段階的に解決。MVP段階はlocalhost環境でOllamaプライマリ。Vercelデプロイ時はclient.tsの環境変数切替でクラウドLLMフォールバック。vercel/ai SDKのプロバイダー抽象化で最小コスト実装可能。

### 矛盾5: Ollama streaming互換性の評価差異（local_llm_compat × technical）

| 視点 | 主張 |
|------|------|
| technical | 「chunk形式はOpenAI準拠、data:[DONE]実装済み」（高互換性） |
| local_llm_compat | 「全チャンクにrole:assistant重複」「tools+streaming時にストリーミング不動作」 |

**→ 解決**: 矛盾ではなく補完関係。基本text generation streamingは互換だが高度な機能に非互換あり。本プロジェクトはtool callingを使用しないため影響限定的。`client.beta.chat.completions.stream`は回避し、vercel/ai SDKの`streamText`を使用。

### 矛盾6: partial-jsonのメンテリスク（alternatives × cost）

**→ 解決**: v1スコープから除外。format:json（GBNF）がプライマリ防御として機能するため、partial-jsonが必要になるケースはJSON完全取得後パース制約下でさらに限定的。メンテリスク顕在化時はjsonrepair単体で代替可能。

---

## 5. 過去決定との整合性

### 整合する決定

| 過去決定 | 本リサーチとの関係 |
|---------|------------------|
| d-20260304-005644: GSAP + CSS 3D Transform | 4視点で再確認。preserve-3d単体限定の詳細化を追加 |
| d-20260304-005644: jsonrepair + Zod + リトライ | format:json GBNFがプライマリ防御として追加され強化 |
| d-20260304-005644: @upstash/ratelimit | 全視点一致。唯一のVercel Serverless対応ステートフル制限 |
| d-20260306-220822: Gate方式段階的検証 | deploy_topology, local_llm_compatの発見がGate 0検証項目を具体化 |
| d-20260306-220822: ローカル開発限定Phase 1 | deploy_topology DT1の結論と完全一致 |
| d-20260306-220822: Node.js Runtime変更 | risk, deploy_topology, technicalの3視点が直接支持 |

### 要更新の決定

| 過去決定 | 変更内容 |
|---------|---------|
| d-20260304-005644: Edge Runtime SSE | **Node.js Runtime**に変更（d-20260306-220822で変更済みだが記述未更新） |
| d-20260304-005644: Upstash 10,000 req/day | **500,000 commands/月**に更新（大幅改善） |
| d-20260304-005644: partial-json使用 | v1スコープから除外（メンテリスク、format:json優先化で不要度上昇） |
| d-20260304-005644: openai SDK中心の議論 | **vercel/ai SDK**を主要候補に追加（当時未評価の可能性） |

---

## 6. 統合推奨事項

### 6.1 Primary推奨

d-20260306-220822のGate 0実機検証を前提条件とし、Gate 0 GO後に実装開始。

| 領域 | 選定 | 根拠 |
|------|------|------|
| クライアント | vercel/ai SDK + @ai-sdk/openai-compatible + ollama-ai-provider | 軽量(19.5KB)、プロバイダー抽象化、テストヘルパー内蔵 |
| JSON安定化 | format:json + think:false → jsonrepair → Zodリトライ(3回) | GBNF自動抑制でthinking汚染を構造的解消 |
| アニメーション | CSS 3D Transform(フリップ) + GSAP(シャッフル) | preserve-3d単体限定でSafariクラッシュ回避 |
| SSE/Runtime | Node.js Runtime + Fluid Compute (maxDuration=300s) | TTFT制約なし、fs.readFile利用可 |
| レート制限 | @upstash/ratelimit + Fixed Window | 500K cmd/月無料、EVALSHA 1cmd課金 |
| デプロイ | MVP=localhost、Vercel時=OpenRouterフォールバック | 環境変数LLM_PROVIDERで切替 |
| 並行制御 | FIFOリクエストキュー（同時実行=1） | NUM_PARALLEL=1前提 |
| モバイルSSE | visibilitychange監視 + keep-alive(30s) + サーバーサイド結果保持 | iOS Safari バックグラウンド問題対策 |

### 6.2 Fallback計画

**トリガー条件**: 以下のいずれかで発動
1. ollama-ai-providerでstreaming応答パースエラー率 > 5%
2. vercel/ai SDKがOllamaのformat:jsonパラメータを透過的に渡せないことが判明
3. Gate 0実機検証でvercel/ai SDK経由のOllama接続に再現性のある不具合を検出

**Fallback先**: openai SDK v5 + baseURL差し替え方式。client.tsのインターフェースは維持し内部実装のみ差し替え。テストはMSWでHTTPレベルインターセプトに切替。

### 6.3 中止条件（ABORT）

以下が**複合的**に成立した場合、uranai-2プロジェクト自体の中止を検討:

1. Gate 0でqwen3.5:27bの日本語品質がGPT-4比50%未満
2. 3層防御でもJSON出力安定率が80%未満
3. TTFT > 10秒かつ tok/s < 5でケルト十字生成が5分超過

**最悪ケース損失**: Gate 0の4–8h工数のみ。uranai-1の実装資産は90%以上再利用可能。

---

## 7. 実装基準（成功条件）

### Layer 1: 自動テスト（11項目）

| ID | テスト内容 | 種別 | 主なチェック項目 |
|----|----------|------|----------------|
| L1-001 | TypeScript型チェック | type_check | `npx tsc --noEmit` exit 0 |
| L1-002 | LLMクライアント抽象化層 | unit_test | プロバイダー生成、format:json+think:false設定、エラーハンドリング |
| L1-003 | タロットカードDB整合性 | unit_test | 78枚、Major 22/Minor 56、全フィールド存在、ID一意 |
| L1-004 | スプレッドアルゴリズム | unit_test | 4種の枚数・ポジション・重複排除、isReversed分布 |
| L1-005 | JSON安定化パイプライン | unit_test | 正常JSON/修復/thinkタグ除去/Zodバリデーション/リトライ |
| L1-006 | 鑑定APIルート | api_check | POST 200(SSE), 400(バリデーション), 405(GET) |
| L1-007 | レートリミッター | unit_test | 制限チェック、429レスポンス、IP抽出 |
| L1-008 | プロンプトテンプレート | unit_test | ファイル読込、変数展開、4スプレッド分テンプレート存在 |
| L1-009 | SSEレスポンスビルダー | unit_test | data:フォーマット、[DONE]、keep-alive、abort処理 |
| L1-010 | リクエストキュー | unit_test | FIFO順序、同時実行=1、タイムアウト、容量超過 |
| L1-011 | ESLint + Prettier | lint | errors 0、フォーマット準拠 |

### Layer 2: 統合テスト（6項目）

| ID | テスト内容 | 前提条件 |
|----|----------|---------|
| L2-001 | Ollama LLM統合 | Ollama + qwen3.5:27b稼働 |
| L2-002 | E2E鑑定フロー | App + Ollama + Upstash |
| L2-003 | SSEストリーミングE2E | App + Ollama |
| L2-004 | Upstashレート制限統合 | App + Upstash |
| L2-005 | プロバイダー切替 | Ollama + OpenRouter API Key |
| L2-006 | 並行リクエストキューイング | App + Ollama (NUM_PARALLEL=1) |

### Layer 3: 人間評価（5項目）

| ID | 評価対象 | 合格基準 |
|----|---------|---------|
| L3-001 | 日本語鑑定文品質 | 4観点平均3.5/5.0以上、全項目3.0以上 |
| L3-002 | カードアニメーション | 55fps以上維持、モバイルSafariクラッシュなし |
| L3-003 | ダーク+ゴールドUIテーマ | WCAG AAコントラスト比準拠 |
| L3-004 | モバイルレスポンシブ | 320px〜428px崩れなし、タッチ44x44px以上 |
| L3-005 | 総合UXフロー | 致命的な導線断絶なし |

---

## 8. フェーズ計画

### Phase MVP: ワンオラクル E2Eフロー

**ゴール**: 1枚引きの鑑定フローがブラウザで動作する状態

| スコープ | 対応基準 |
|---------|---------|
| client.ts（vercel/ai SDK + Ollama接続） | L1-002, L2-001 |
| 78枚タロットカード静的JSONデータベース | L1-003 |
| ワンオラクル（1枚引き）スプレッドロジック | L1-004 |
| POST /api/fortune（SSEストリーミング）+ GET /api/cards | L1-006, L1-009 |
| JSON安定化パイプライン基礎 | L1-005 |
| 最小限UI（質問入力→カード表示→鑑定文ストリーミング） | — |
| Node.js Runtime設定 | — |

**自動Exit Criteria**: tscコンパイル、カードDB 78枚、1枚引きAPI 200、不正スプレッド400、ESLint通過
**人間確認**: ブラウザで1枚引き鑑定フロー動作確認

### Phase Core: 4種スプレッド + 基盤機能

**ゴール**: 全スプレッド・レート制限・キュー・テンプレートが動作する状態

| スコープ | 対応基準 |
|---------|---------|
| 残り3スプレッド追加 | L1-004, L2-002 |
| プロンプトテンプレートシステム | L1-008 |
| @upstash/ratelimitミドルウェア | L1-007, L2-004 |
| リクエストキュー（FIFO、同時実行=1） | L1-010, L2-006 |
| SSE keep-alive（30秒毎） | L1-009, L2-003 |
| スプレッドレイアウト表示 | — |

**自動Exit Criteria**: 4スプレッド全200、405/400エラー、全ユニットテスト通過
**人間確認**: 4種レイアウト表示、ケルト十字のSSEストリーミング段階表示

### Phase Polish: アニメーション + UI仕上げ

**ゴール**: アニメーション・エラーハンドリング・モバイル対応が完了

| スコープ | 対応基準 |
|---------|---------|
| GSAPシャッフル・展開アニメーション | L3-002 |
| CSS 3Dカードフリップ（preserve-3d単体限定） | L3-002 |
| visibilitychange監視 + SSE再接続 | L3-004 |
| エラー画面（接続失敗・タイムアウト・レート制限） | — |
| ダーク+ゴールドテーマ仕上げ | L3-003 |
| モバイルレスポンシブ（320px〜428px） | L3-004 |

**自動Exit Criteria**: tsc + vitest + ESLint通過、エラーレスポンス、next build成功
**人間確認**: アニメーション動作（Safariクラッシュなし）、テーマ統一感、スマホ操作性、バックグラウンド復帰時の結果保持

---

## 9. リスクと未解決事項

### 9.1 残存リスク

| リスク | 影響度 | 対策状況 |
|--------|--------|---------|
| ollama-ai-providerがサードパーティ製 → Ollama API変更追従遅延 | 中 | openai SDKフォールバック計画あり |
| format:json GBNFのパフォーマンス低下幅が未定量 | 中 | Gate 0で実測予定 |
| Fluid ComputeがHobby planで無料利用可能かの公式未確認 | 低 | MVP=localhost（影響なし） |
| NUM_PARALLEL=1でのユーザーシリアル化 | 高 | リクエストキュー + 待機UI。トラフィック増でUX劣化 |
| partial-json除外でストリーミング部分パース不可 | 低 | JSON完全取得後パース制約下で影響限定的 |
| Hobby plan商用利用禁止 | 高 | サービス公開時はPro($20/月)必須 |

### 9.2 調査ギャップ（未取得データ）

- openai SDK v5のgzip後バンドルサイズの正確な値（34.3 kB vs 129.5 kBの乖離未解消）
- format:json + qwen3.5:27bの成功率・失敗率の実測データ
- Ollama #7626（roleフィールド重複）のPR #7722マージ状況
- qwen3.5:27bのNUM_PARALLEL=1時の実スループット・レイテンシ
- CSS 3D Transform 10枚以上同時アニメーションのモバイルSafari実測FPS
- Upstash EVALSHA課金モデル（Luaスクリプト内コマンドの別カウント有無）
- Vercel Fluid ComputeのHobby planでの利用条件・追加課金有無
- iOS Safari 17.5以降のSSE互換性問題修正状況

### 9.3 前提条件

本レポートの推奨事項は以下を前提とする:

1. Gate 0（d-20260306-220822）の実機検証がGO判定済み
2. Ollamaがlocalhost:11434で稼働、qwen3.5:27bモデルがロード済み
3. format:json指定時にOllamaがGBNF grammar-constrained decodingを使用
4. OLLAMA_NUM_PARALLEL=1が実質的な制約
5. 開発・テストはlocalhost環境のみ（Vercelデプロイは本スコープ外）
6. 78枚タロットカードを静的JSONファイルで管理
7. Node.js Runtime + Fluid Compute使用時にTTFT制約がない

---

*本レポートは6視点（technical, local_llm_compat, risk, alternatives, deploy_topology, cost）の調査結果を統合し、Forge Research Harness v3.2により生成されました。*
