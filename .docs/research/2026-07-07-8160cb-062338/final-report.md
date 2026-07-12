# 統合デスクトップツール（xboard型）アンチ検知ブラウザ自動化基盤 — リサーチ最終レポート

**リサーチID:** `2026-07-07-8160cb-062338`　**モード:** validate（検証）　**生成日:** 2026-07-07

---

## エグゼクティブサマリー

本リサーチは、**外部アンチ検知ブラウザ × 表示埋め込み × プロキシ/指紋永続 × Claude Agent SDK 自然言語操作**を統合するデスクトップツール（xboard型）の実現性を、6視点（技術・コスト・リスク・代替案・アンチ検知/指紋・運用性/段階検証）から検証したものです。X/Twitter を最初の適用例とします。

結論を一言でいえば、**「技術的には成立するが、決定的リスクは技術ではなく X の規約/法にある」**です。

| 観点 | 判定 | 要点 |
|---|---|---|
| 技術的実現性 | ⭕ 成立（PoC 前提） | Chromium+patchright+CDP screencast が最も直線的。ただし screencast 経路は要実機検証 |
| 推奨アーキ | Electron + 表示A(screencast) + patchright 主軸 | ブラウザ抽象レイヤ（Chromium=CDP / Firefox=Juggler）を最初に立てる |
| 最大の構造的トレードオフ | ⚠ ステルス ↔ 観測性 | 観測に使う CDP 計装そのものが最大の検出シグナル |
| 決定的リスク | 🔴 規約/法（技術で局所化不能） | X 2026-01 ToS が自動化を全面禁止・$15k/1M投稿の損害賠償＋提訴実績 |
| 前回失敗（三重苦）の回避策 | 疎結合設計＋段階検証＋二段観測 | 3課題を1ツールで同時解決しない |

---

## 1. リサーチの前提

### 1.1 テーマ

ブラウザ操作を含むコンピューター操作の統合デスクトップツール（xboard型）。汎用アンチ検知ブラウザ自動化基盤をコアに、複数タブ管理・プロキシ↔プロファイル紐付け・指紋/Cookie/セッション永続・多アカウント並列を備え、**Claude Agent SDK による自然言語→ブラウザ実操作エージェント**を最終ゴールとする。X/Twitter 運用を最初の適用例とする。

### 1.2 ロックされた決定事項（調査対象外・変更不可）

1. **最終ゴール** = Claude Agent SDK による自然言語→ブラウザ実操作エージェント（MVP の自動化粒度のみ調査で決定）
2. **アンチ検知を必須要件**とし、専用アンチ検知ブラウザ（patchright/Camoufox 系）を**外部プロセス**で用いる
3. **汎用ブラウザ自動化基盤をコア**とし、X/Twitter を最初の適用例とする

> これらの代替探索は禁止。alternatives 視点もロック範囲内の選択肢比較に限定。

### 1.3 6つの未決事項（調査スコープ）

1. 表示アーキ3方式（A: screencast埋め込み / B: docking / C: Electron BrowserView 再挑戦）の比較
2. デスクトップの器（Electron / Tauri / 純外部ウィンドウ制御）
3. アンチ検知ブラウザスタック（patchright / Camoufox / nodriver / rebrowser-patches）
4. プロキシ↔プロファイル永続化・指紋一貫性設計
5. Claude Agent SDK 配線型（computer use / CDP・AXツリー / MCP）
6. MVP スコープと自動化粒度

### 1.4 検証された主要な前提（assumptions）

- 外部アンチ検知ブラウザが CDP 経由で「映像取得」と「Input 注入」の**両方**を安定提供できるか（特に Camoufox=Firefox の CDP 非対応懸念）
- CDP 接続そのものが bot 検知シグナルとして露出しないか
- screencast 埋め込みが複数タブ×複数プロファイル同時でも実用 FPS で成立するか
- IP・指紋・Cookie の三者が矛盾なく永続・紐付けできるか
- 多アカウント並列が規約/法令上の許容範囲か、相関検知を回避できるか

---

## 2. 視点別サマリー

### 2.1 技術的実現性（technical）

**核心は「Chromium系は成立、Firefox系は非対称」という構造。**

| 項目 | Chromium/patchright | Firefox/Camoufox |
|---|---|---|
| 映像取得 | CDP `Page.startScreencast`（base64 JPEG/PNG フレーム）で成立見込み（confidence: **medium**） | raw CDP 不可。Playwright `page.screencast`(v1.59+)/recordVideo を **Juggler 経由**で代替 |
| Input 注入 | CDP Input ドメインで成立（confidence: **high**） | Juggler 実装の Input を Playwright API 経由で送出 |
| 配線設計 | CDP 前提で直線的 | CDP 前提が使えず、抽象レイヤ必須 |

**最大の実装リスク:** 座標系/DPR/screencast スケールの割り戻し。CDP Input は CSS ピクセルだが screencast フレームは device ピクセル。Anthropic Computer Use と同型の座標変換帳簿管理が必須。

**並列 screencast:** base64-per-frame 転送・CDP chattiness・JPEG エンコード CPU・プロファイル毎プロセスのメモリが乗算ボトルネック。**監視用途の低〜中FPS なら並列実用域だが、多数プロファイルで滑らかな高FPSは非現実的。**

**Agent SDK 3配線:** computer-use（ピクセル/XGA上限/座標スケール要）・CDP+AXツリー（構造化/ビジョン不要/低コスト）・MCP（標準ツールプロトコル/内部はAX方式）。**併用可能**であり、単一択一は誤り。

### 2.2 コスト・リソース（cost）

**3つのコストドライバが相互に増幅する。**

| ドライバ | 高コスト側 | 低コスト側 |
|---|---|---|
| API/トークン | computer-use（スクショ毎ターン累積再送で線形〜二次膨張、**Opus高effortで$3-8/task、1000タスク/日で月$20k-80k規模**） | Playwright MCP/CLI（実行$0、約1/4トークン） |
| プロキシ | モバイル $2-15/GB、専用4G $50-200/IP/月 | DC 最安 $0.5-1/IP/月、静的住宅 $5-7/月 |
| OSS保守 | nodriver（AGPL-3.0＋高移行工数）、rebrowser（実質放棄・ライセンス不明） | patchright（Apache-2.0、月次更新、ドロップイン） |

**推奨配分:** `80% Playwright / 15% MCP / 5% computer-use` のハイブリッド分割。**「器の選択」が最大のコストレバー。** マルチアカウントは帯域が小さいため「$/GB」ではなく「信頼できるIP単位/月」で予算化すべき。実効コストは「価格÷成功率」で評価する。

緩和策: プロンプトキャッシュ（90%off）・Batch API（50%off）・古いスクショのトリム（直近1-2枚）・低解像度化。

### 2.3 リスク・失敗モード（risk）

**「技術的検知回避リスク」と「規約・法的リスク」の二層構造で、後者が前者を上書きする。**

**技術面の二大失敗モード:**
1. **CDP `Runtime.enable` リーク** — 「2025-2026で最も信頼できる単一の bot 検知シグナル」。V8 が 2025-05 に古典技法を無効化したが、prototype-chain Proxy 技法は依然生存
2. **チェーンBAN** — 1プロファイルの1ミス（WebRTC IP漏洩等）がデバイス指紋に紐付き、**正常な全アカウントを一括BAN**（50アカウントなら50全滅）

**OSS保守健全性:** patchright（最健全）＞ nodriver（活発だがAGPL）＞ Camoufox（メンテ移管直後で性能低下）＞ rebrowser（実質停止）。

**🔴 決定的リスク（法）:** X の 2026-01 ToS はブラウザ自動化/スクレイピングを「いかなる形態・目的でも」事前書面同意なしに全面禁止。**違反時の予定損害賠償 = 24時間あたり100万投稿につき $15,000**、提訴実績あり。サーバ側AI検知は一夜で更新可能なため、**どれだけステルス品質を上げてもクライアント側で戦略寿命を保証できない。**

### 2.4 代替案・競合（alternatives）

**表示アーキ三択（アンチ検知ロック下）:**

| 案 | 評価 | 理由 |
|---|---|---|
| **A: screencast埋め込み** | ⭕ 実務推奨 | 別プロセスで実ブラウザ起動、アンチ検知と両立容易・実装単純。ただし低FPS |
| B: docking（reparent） | △ フィデリティ最高 | Electron に正規APIなし（issue #10547）、Windows で SetParent 脆弱 |
| **C: BrowserView 再挑戦** | ❌ 非推奨 | **Electron 内蔵 Chromium ≠ 実パッチ済みブラウザ** ゆえ原理的に不適合＝前回失敗ルートの再来 |

**器:** screencast方式なら **Electron**（CDP/Node実績・描画一貫性）、軽量/sidecar志向なら Tauri（<10MB・RAM 30-50MB）。

**アンチ検知スタック:** nodriver（bypass最大）/ Camoufox（ステルス最大）/ **patchright（DX・保守最良）** / rebrowser（最弱・stale）。**単一の絶対王者は存在しない。**

**最大の横断リスク:** 「ステルス最強の Camoufox=Firefox」が「Chrome中心の表示・配線・SDK連携」と噛み合わない。

### 2.5 アンチ検知・指紋一貫性・BAN耐性（anti_detection_fingerprint）

**三者（IP・指紋・Cookie）整合は達成可能だが、達成コストと担保主体がスタックで二分される。**

- **Camoufox** = geoip 自動整合＋エンジンレベル一貫指紋で**内的一貫性を最も低コストに実現**。ただし Firefox 形状は X 実ユーザー（Chromium優勢）に対し母集団異常になり得る
- **patchright/nodriver** = 自動化プロトコル層ステルスに特化。**指紋スプーファを内包せず**、TZ/canvas/WebGL 整合・Cookie隔離は自前実装が必要

**逆説的利点:** CDP `Input.dispatch` は OSレベルで `isTrusted=true` を生む＝JS `dispatchEvent`（`isTrusted=false`＝即バレ）より遥かに安全。ただし人間の運動特性を欠くため X/Arkose の行動エントロピー採点では素の合成入力は依然検知。

**X/Arkose Titan は「自動化署名」ではなく「人間固有エントロピーの欠如」と行動相関・同一マシン指紋相関を見に来る。** 単一ツールで全レイヤは満たせず、**Camoufox(指紋) × proxy 1:1(IP/相関) × 行動シミュレーション(Arkose対策) の重ね掛けが構造的に必須。**

### 2.6 運用性・段階的検証可能性（operability_incremental_validation）

**「きれいに独立検証できる軸」と「同時解決を強いる軸」が混在する。**

- **埋め込み・自動化は分離可能** — 自動化ロジックを安定インタフェース背後に隠せば、ステルス/プロキシを差替え部品化でき段階投入できる（三重苦回避）
- **⚠ ステルス ↔ 観測性だけは同一 CDP 層を奪い合う「第2の結合」** — 観測に使う CDP 計装（トレース/スクショ）そのものが最大の検出シグナル

**段階検証設計（Layer-Isolated Evaluation, arXiv 2606.11686）:** 決定論的スキャフォールドを No-LLM 回帰ハーネスでゲート化し、非決定論の NL 層だけ統計/人間/LLM-judge で検証。

| MVP段階 | 検証 | コスト |
|---|---|---|
| 第1段: 人手UI | 純決定論（L1/L2） | 安価・高再現性 |
| 第2段: 定型フロー自動化 | 決定論スキャフォールドを Pytest 等で回帰ロック | 中 |
| 第3段: フル自然言語 | 複数反復・統計評価・人間/LLM-judge 必須 | 最高 |

**解決策:** ステルス↔観測性は**二段観測（開発時=高観測CDPトレース / 本番=OSレベル画面録画等 CDP非依存観測）**で残余結合を解消。

---

## 3. 視点間の対立と統合結論

Synthesis は6視点を2系統（Chromium+CDP系統 / Firefox+Camoufox系統）へ収斂させ、5つの対立を解消しました。

| 対立 | 内容 | 統合結論 |
|---|---|---|
| alternatives × technical | Camoufox の可視化可否 | 「raw CDP は不可」で一致。Juggler/Playwright screencast で映像取得は成立するが **CDP前提の配線は再利用不可 → ブラウザ抽象レイヤが必須要件** |
| anti_detection × alternatives | 主軸を Camoufox（指紋）か patchright（統合容易性）か | 最適化軸が異なり単一勝者なし。**MVP速度優先で patchright を初期主軸、X本番臨界パスで Camoufox を並行PoC実測比較** |
| cost × risk | computer-use はコスト膨張要因か検出回避利点か | 擬似対立。**ハイブリッド配線（DOM/AX既定＋vision補完を検出感応箇所に限定）が両立解** |
| anti_detection × risk | CDP Input(trusted) は安全か検知されるか | 必要条件と十分条件の差。**(1)CDP(trusted)既定＋(2)人間的運動特性付加＋(3)行動時間分散の三層** |
| operability × risk | 分離可能性 vs 結合リスク | 実は同じ結論を別方向から。**疎結合が正解。ステルス↔観測のみ二段観測で対処** |

> **過去決定との整合:** 本推奨は「高リスク軸を安価な PoC で先行検証してから全面コミット」という過去決定（d-20260703 / d-20260614 / d-20260612）のパターンと一貫。ロック決定にも全面整合（矛盾ゼロ）。

---

## 4. 推奨アクション

### 4.1 Primary（推奨） — PoC先行の段階アーキ

1. **器=Electron、表示=A(screencast)** を採用。**Chromium=CDP / Firefox=Juggler を隠蔽する「ブラウザ抽象レイヤ」を最初に立てる**
2. **アンチ検知の初期主軸=patchright**（Chromium・CDP screencast/Input 両立・保守最良）。patchright が非内包の**指紋硬化層を必須付加**（1:1プロキシ↔プロファイル＋固有canvas/WebGL/audio＋Cookie/user-data-dir完全分離＋人間的入力運動特性＋行動時間分散）。ステルス臨界パス（X投稿系）では **Camoufox を並行PoC**で実測比較
3. **SDK配線=ハイブリッド**（CDP/AXツリー既定＋computer-use を検出感応/canvas箇所の vision フォールバックに限定、キャッシュ/Batch/スクショトリムでコスト緩和）
4. **MVP粒度=段階到達**: 第1段 人手UI → 第2段 定型フロー自動化(L2回帰ロック) → 第3段 フル自然言語(統計/人間/LLM-judge)
5. **観測性=二段**（開発時CDPトレース / 本番OSレベル画面録画）

**根拠:** ロック3件を全面遵守しつつ、全視点が一致指摘する2つの構造的失敗モード（三重苦の再発＝単一障害点、ステルス↔観測性トレードオフ）を疎結合＋段階検証＋二段観測で直接無力化する。

**Primary のリスク:**

- patchright の自前指紋硬化層の品質が不足すると X(Arkose Titan)の「人間エントロピー欠如」検知で早期BANし得る
- CDP アタッチ自体が検出面を増やすかは本調査で直接実測できておらず（**要PoC**）
- 多プロファイル並列 screencast の乗算ボトルネックで滑らかな高FPSは非現実的
- computer-use を安易に多用すると月$20k-80k規模へ膨張
- OSS依存の追随ラグ（単一/少人数メンテナ、V8 のような一夜の前提変化）
- 1プロファイルの1ミスによる連鎖BAN（1:1隔離は必要条件だが十分条件ではない）

### 4.2 Fallback（切替） — Camoufox 系統へ

**トリガー:** PoC で patchright+自前指紋層が X 本番検知で BAN率/アカウント寿命が閾値を下回る、または CDP アタッチ/screencast が検出シグナルとして露出することが実測された場合。もしくは自前指紋層の生成・維持コストが Camoufox の内的一貫指紋より明確に割高と判明した場合。

**アクション:** 主軸を Camoufox 系統へ切替。表示は raw CDP screencast を捨て Playwright(Juggler) screencast/recordVideo または computer-use 中心へ。ブラウザ抽象レイヤの Firefox=Juggler 経路を本経路に昇格。入力注入を OSレベル(CDP-Patches/pyautogui)へ切替。**ブラウザ抽象レイヤを最初に立てておけば切替コストは Firefox経路の昇格に限定される。**

### 4.3 Abort（撤退） — 部分撤退が最小機会費用

**決定的リスクは技術ではなく規約/法にある。** X の 2026-01 ToS は自動化を全面禁止し、$15k/1M投稿の損害賠償＋提訴実績を持ち、サーバ側検知は一夜更新可能。法的リスクは技術で局所化不能。

ただし **validate モード下では全面 abort は非推奨。** abort の実体は**「X-at-scale の敵対的適用のみを縮退させ、汎用コアと段階検証基盤は残す」部分撤退**が最小機会費用。ロック済みの「汎用ブラウザ自動化基盤+Claude Agent SDK 自然言語操作」というコア資産は、X以外の合法的自動化（社内業務・許諾済みサイト・自社サービス操作）で価値を保持する。X 適用は公式API/ToS許容範囲（自分の投稿予約等）に限定する選択肢もある。

---

## 5. リスク指摘（Devil's Advocate レビュー）

第1ラウンドの証拠ベース反証レビュー（`da-r1-20260707-064010-8160cb`）で **CRITICAL は発見されず**、Primary の段階アーキ・PoC先行・疎結合・二段観測は個別レポートに広く裏付けられていることが確認されました。ただし以下2件の指摘が残ります（いずれも PoC先行構造の中で対処可能）。

| ID | 深刻度 | 指摘 | 解消基準 |
|---|---|---|---|
| **DA-001** | 🟠 HIGH | Synthesis は screencast-A×patchright 配線を「technical が **high 相当**で成立を裏付け」と格上げしているが、technical の当該 finding は実際は **confidence=medium**。high は Input注入（finding 2）のみで、screencast 経路（finding 1・3）は両方 medium。中核前提（patchright が `Page.startScreencast` を無効化せず残すか）は**実機未検証の gap**。この確度インフレが「最も直線的に成立」と誤読させ、最初に潰すべき成立性リスクを過小評価させる恐れ | 「high 相当」表現を medium（要実機検証）へ訂正し、patchright の `Page.startScreencast` 実在/挙動を**第1段PoCの明示ゲート**（不成立なら Juggler 経路へ即切替）として risks に昇格 |
| **DA-002** | 🟡 MEDIUM | Synthesis は computer-use 許容比率を「5-15%」としているが、cost レポートの配分は「**80% Playwright / 15% MCP / 5% computer-use**」で、computer-use は 5%ちょうど・15% は MCP の比率。MCP の 15% を computer-use 側に取り込み上限を3倍に緩めており、コスト膨張規律を希釈 | computer-use 上限を cost 準拠の「**5%程度**」へ訂正し、15% が MCP 配分であることを区別 |

### 未解決の不確実性（unknowns）— いずれも要PoC/一次確認

- patchright/Camoufox/nodriver を **X本番検知に直接当てた BAN率・アカウント寿命の定量データ**（全視点が gap。系統選択の最終根拠は実測待ち）
- patchright の `Page.startScreencast` 実機挙動、Camoufox の Juggler ステルスパッチが screencast 品質に与える影響
- **CDP アタッチ/startScreencast 自体が bot 検知シグナルとして露出するか**（複数視点が「単独検知ベクタとして扱う一次資料なし」と明記、推論の域）
- 多タブ×多プロファイル並列 screencast の実 FPS/入力レイテンシ定量ベンチ
- **X ToS 原文**（$15k/1M投稿・自動化定義・マスBAN時期）の一次確認（現状は二次記事依存）

---

## 6. 実装成功条件（Implementation Criteria）

validate 結果を反映した機械検証可能な成功条件が生成されています（`localhost:3001` の REST API を前提）。

### Layer 1（決定論的・単体/API検証）

| ID | 内容 | テスト種別 |
|---|---|---|
| L1-001 | プロファイル/プロキシ管理API（1:1バインド、専用 user-data-dir、決定的ステータスコード） | api_check |
| L1-002 | プロキシ↔プロファイル **1:1 隔離不変条件**（永続ストア再読込後も維持） | unit_test |
| L1-003 | 指紋設定ジェネレータ（プロファイル間で一意・プロファイル内で決定的、geoip整合） | unit_test |
| L1-004 | ブラウザ抽象レイヤのエンジンルーティング（chromium=CDP / firefox=Juggler、統一インタフェース） | unit_test |
| L1-005 | ハイブリッド配線モードセレクタ＋**vision予算上限キャップ** | unit_test |
| L1-006 | 入力注入セーフティ lint（生 `dispatchEvent` 禁止、CDP Input 強制） | lint |
| L1-007 | 自然言語タスク受付API | api_check |

> 各 L1 には **false_positive_scenario**（例: userDataDir が同一パス共有でも 201 を返す／指紋が全プロファイル固定でも「非null」テストは通過）が定義され、見せかけの合格を防ぐ設計。

### Layer 2（実起動 E2E/統合）

| ID | 内容 |
|---|---|
| L2-001 | patchright(Chromium) 実起動＋プロキシ＋CDP screencast フレーム受信（**表示Aの成立性検証＝DA-001の第1段ゲート**） |
| L2-002 | 指紋ステルス検証（bot.sannysoft/CreepJS 等で閾値以下、patchright+自前層 vs Camoufox 実測比較） |
| L2-003 | screencast 埋め込み E2E（Electron 描画＋実測FPS記録） |
| L2-004 | Firefox/Camoufox 並行 PoC（Juggler screencast/recordVideo で mp4 生成、fallback系統の成立性） |
| L2-005 | Claude Agent SDK 自然言語タスク E2E（ハイブリッド配線） |
| L2-006 | プロキシ漏洩/WebRTC IPガード（外向きIP==プロキシIP、WebRTC実IP非漏洩） |

### Layer 3（行動検証・受入）

| ID | 戦略 | 内容 | blocking |
|---|---|---|---|
| L3-001 | api_e2e | フルフロー受入（プロキシ作成→プロファイル→セッション→NLタスク→結果取得） | ✅ |
| L3-002 | structural | プロファイル/指紋の構造検証（userDataDir・canvasSeed の一意性） | ✅ |
| L3-003 | llm_judge | 自然言語タスク解釈の忠実度（閾値0.8、破壊的操作/vision濫用の検出） | — |
| L3-004 | cli_flow | 定型フロー自動化のCLI模擬（成果物生成の機械検証） | ✅ |
| L3-005 | context_injection | プロファイル設定の反映検証（プロキシ更新→次回起動構成に反映） | ✅ |

### 開発フェーズ（3段階、Mutation 生存閾値を段階的に厳格化）

| フェーズ | ゴール | Mutation生存閾値 |
|---|---|---|
| **mvp** | 1プロファイル+1プロキシで実Chromium起動→Electron埋め込み→1つのNLタスクがE2Eで通る | 0.4 |
| **core** | 複数プロファイル/タブを1:1プロキシ隔離+自前指紋硬化で並列管理、Firefox経路+vision フォールバック含む主要機能 | 0.3 |
| **polish** | エッジケース耐性、入力注入lint の CI 組込、vision予算キャップ実効化、フルNL の LLM judge 受入 | 0.2 |

> X 本番の敵対的スケールは**全フェーズ範囲外**（後段ゲートへ繰延）。

---

## 7. 結論と次アクション

**技術的には「Chromium+patchright+CDP screencast+Electron+ハイブリッド配線」で成立する見込みが高く、前回の三重苦は「疎結合設計＋段階検証＋二段観測＋ブラウザ抽象レイヤ」で回避できます。** ただし2つの留意が必須です。

1. **screencast-A の成立性は medium（未実機検証）** — patchright の `Page.startScreencast` 実在を **PoC第1段の明示ゲート**とし、不成立なら Juggler 経路へ即切替（DA-001）
2. **決定的リスクは法** — X の 2026-01 ToS 全面禁止＋$15k/1M＋提訴実績は技術で局所化不能。**汎用コアは残し、X-at-scale の敵対的適用のみ縮退させる部分撤退**を前提に据える

**推奨する次アクション（安価な PoC を先行、実課金/法務判断は後段ゲートへ繰延）:**

1. ブラウザ抽象レイヤ（Chromium=CDP / Firefox=Juggler）の骨格を先に立てる
2. **PoC-A:** patchright の `Page.startScreencast` 実機挙動を確認（DA-001 ゲート）
3. **PoC-B:** patchright+自前指紋硬化層 vs Camoufox の指紋ステルスを bot 検知サイトで実測（L2-002/L2-004）
4. **PoC-C:** CDP アタッチ/screencast が検出面を増やすか実測（unknowns の最重要項目）
5. computer-use 比率を **5%程度**に規律付け（DA-002 訂正済み）
6. X 本番 BAN 検証・実プロキシ課金・法務判断は後段ゲートで受容可否を人間判断

---

*本レポートは Forge Harness Research System により生成された investigation-plan / 6 perspective / synthesis / devils-advocate / implementation-criteria を統合したものです。数値・主張の多くは二次情報に基づく推論を含み、太字で示した項目は実機PoC/一次確認による検証が前提です。*
