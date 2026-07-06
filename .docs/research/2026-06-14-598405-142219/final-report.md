# AI動画 自動生成ワークフロー — 最終リサーチレポート

**リサーチID:** `2026-06-14-598405-142219`
**生成日:** 2026-06-14
**テーマ:** 生成層と組立層を分離する AI 動画生成パイプライン（make-video 連携）
**最終判定:** 🟢 **GO（条件付き整合 / DIRECT・validate）**

---

## 1. エグゼクティブサマリー

本リサーチは、**「生成層」（Runway / fal / Kling / Veo / Suno 等の AI 生成）と「組立層」（make-video の純 bash + ffmpeg）を `scenarios/<id>/inputs/` の MP4/WAV だけを接点として分離する**パイプラインを、ロックされた前提のもとで再検証し GO/NO-GO を出すものです。

5＋αの視点（technical / cost / risk / alternatives / environment_compat / compliance）を横断した結論は **GO**。**実 API 課金ゼロのダミー fixtures ドライランで「組立契約面 + 3点機械ゲート + 正規化/保存アダプタ」の構造検証を先に行う**のが最も価値が高く、かつ低コストで実行可能と判断されました。

> **全視点に共通して現れた構造:** 「仕様値を固定するだけでは不十分。境界に *正規化ステージ* と *統一保存アダプタ* を必ず置く」必要がある。これが本リサーチ最大の設計上の発見です。

価格・モデル採否・BGM・第三者プロキシ・Seedance などの**高リスク要素はすべて実素材生成フェーズ（本スコープ外）へ繰延**し、2026-06 価格は参照値として確定します。

---

## 2. 調査スコープと前提

### ロックされた決定事項（調査対象外・最終確定）

| # | ロック決定 | 内容 |
|---|-----------|------|
| ① | 純 bash + ffmpeg 堅持 | make-video コアは純 bash+ffmpeg。AI 生成統合は **make-video の外** に置く |
| ② | 接点は MP4/WAV のみ | 生成層↔組立層の唯一の接点は `scenarios/<id>/inputs/` の MP4/WAV |
| ③ | 実課金ゼロ検証 | 実 API 課金を一切発生させず、ダミー/fixtures でドライラン検証 |
| ④ | qualified 表記 | 888Hz 等はスピリチュアル伝統に基づくと明示し、科学的効果として断定しない |
| ⑤ | 3点必須ゲート | 組立層の必須ゲートは **(1) output 存在 (2) 音声トラック有無 (3) 最低尺** の3点 |

### 調査の境界

- **深さ:** 各社公式ページ・一次情報（料金/利用規約/公式ドキュメント/公式リポジトリ）に基づく価格・プラン・ライセンス・導入手順の再確認まで。実装・実課金・実素材の品質評価は行わない。
- **広さ:** 7つの未決事項（価格検証 / モデルルーティング / ローカル保存 MCP / Runway Explore / HyperFrames の Windows 実在性 / Suno 商用権・自動化コスト / 生成層設置場所）に限定。

---

## 3. 視点別 主要知見

### 3.1 技術的実現性（confidence: **high**）

- MP4/WAV を契約面とした分離は**技術的に堅牢に成立**する。ただし FFmpeg concat demuxer（高速・ストリームコピー）が使えるのは、映像（コーデック/プロファイル/解像度/fps）と音声（AAC/LC/44.1kHz/stereo/fltp）が**完全一致したときだけ**。
- 生成 AI 出力やスマホ素材は **VFR・GOP途中カット・タイムスタンプ不整合**を含みやすく、ストリームコピーでは A/V 同期ズレ・尺崩れが発生する。→ **取り込み時に再エンコード + CFR 強制（`-vsync cfr` / `+genpts`）する正規化ステージが必須。**
- ローカル自動保存型の fal 系 MCP（`DOWNLOAD_PATH` / `SAVE_MEDIA_DIR`）は**実在**するが、固定ディレクトリ保存のため `scenarios/<id>/inputs/` への動的着地には**薄いアダプタ層**が要る。Runway は URL 返却型（24-48h 失効）。→ **両型を吸収する統一保存アダプタを1枚噛ませる。**
- `lavfi`（testsrc / anullsrc / sine）+ `ffprobe` で **3点ゲートを実 API 課金ゼロで決定論的に通過可能**（ロック決定 ②④ を直接裏付け）。

### 3.2 コスト・リソース（confidence: **high**）

- 2026-06 主要価格は一次ソース（fal.ai / suno.com / Runway 公式）で裏付け済み。
- **Runway Explore Mode のクレジット非消費・無制限は現時点でも成立**し、量産ドラフトを金銭ゼロ化できる。ただし **720p 上限・低優先キュー（1本5〜20分）・Veo 除外・Max（$76/月）契約前提**で「無料は固定費の上に乗る」。
- シーン別ルーティング（同条件で **5〜40 倍の単価差**）はコスト合理性が高い。ヒーロー＝高単価、量産ドラフト＝無料/低単価の配分が妥当。

### 3.3 リスク・失敗モード（confidence: **high**）

- **ローカル完結のドライランは Runway アカウント停止リスクなし**（停止トリガーは「モデレーション拒否の累積」「Web UI スクレイピング」であり、正規 API 利用ではない）。ロック決定 ② と整合。
- **二大震源:**
  1. **揮発 URL** — 出力 URL は 24-48h で失効・再取得不能。**task ID を冪等キーにした即時ダウンロード保存**が必須。
  2. **依存陳腐化** — モデルが月次で sunset（Gen-4 Aleph が 2026-07-30 sunset の報あり）。**モデル ID ハードコード回避 + アダプタ層 + フォールバック**が必須。
- 実素材限定の失敗モード（SAFETY 非リトライ＆返金なし、`BAD_OUTPUT.01`、`ASSET.INVALID`、アップスケール尺短縮）は **L1 では露見せず、L2/L3 行動検証 + ゴールデンサンプルでしか捕捉不能**。ハーネス既知の「ダミー緑 ≠ 動作保証」教訓と一致。

### 3.4 代替案・競合（confidence: medium〜high）

- **動画モデル:** Kling 3.0 抽象 b-roll の代替は Seedance 2.0（大気感）/ Luma Ray 2（カメラワーク）/ Wan 2.6（オープン・最安）。
- **ローカル保存:** **fal 型が再現性・冪等性で優位**（`X-Fal-Object-Lifecycle` ヘッダで無期限化、`request_id` ベース冪等性、後追い結果取得）。Runway 型は常に取得ウィンドウ内 DL が前提。
- **生成層設置:** `fal-ai-community/skills`（genmedia CLI + model-routing + fal-workflow）という**強い実運用前例**あり。ただし別ディレクトリ / 別ハーネスとの優劣は当ハーネス内部設計依存で Web 情報の射程外。
- **BGM（重要）:** Suno 以外に同一 fal 生成層上で **ElevenLabs Music / MiniMax Music 2.5 / Stable Audio / Lyria 3** が利用可能。いずれも正規 API 完備、ElevenLabs と Stable Audio は **licensed 学習データで商用権がクリーン**。

### 3.5 Windows 環境互換（confidence: high/medium）

- HyperFrames 導入（`npx skills add heygen-com/hyperframes`）は **Node 22+ と FFmpeg で実在**するが、**Windows 実機成功の一次証拠は限定的**（公開事例は macOS）。
- 落とし穴4点：① skills CLI の symlink が Developer Mode/管理者なしで **EPERM**（`--copy` で回避）、② **Git LFS 詰まり**（`GIT_LFS_SKIP_SMUDGE=1` 必須）+ FFmpeg/Chrome の手動 PATH、③ **環境変数注入の OS 依存**（fal `FAL_KEY` 伝播失敗 Issue #477）、④ **OneDrive 配下の git/node_modules 破損** と Git Bash MSYS のパス自動変換/CRLF。
- これらは harness MEMORY でも既知教訓。**OneDrive 外配置・ツール系統統一・システム環境変数化**を前提条件化すれば再現性は確保可能。

### 3.6 商用利用権・コンプライアンス（confidence: high/medium）

- **最も安全:** HyperFrames（Apache 2.0、商用・再配布制約なし。FFmpeg 別ライセンスのみ留意）。
- **公式有料プラン正規利用なら**、Suno Pro/Premier・Runway 有料・Veo 有料・Kling 有料はいずれも商用・YouTube 収益化が可能。
- **重大リスク2点:**
  1. **第三者プロキシ（AceDataCloud 等）経由の Suno/動画自動化＝上流 ToS 違反**。プロキシが謳う商用権は法的裏付けが脆弱。
  2. **Seedance 2.0 ＝ MPA・大手スタジオと cease-and-desist 係争中**で商用安全性が現時点で **low**。
- 横断留意点：Veo の SynthID 常時付与・除去禁止、YouTube 2026 の合成メディア開示ラベル義務、Suno の人間著作性要件と Sony 未和解訴訟。
- **888Hz 表記（ロック決定 ④）は qualified 明示で YouTube 収益化要件と整合。**

---

## 4. 2026-06 価格参照表（一次ソース確定値）

> 本スコープでは**参照値**として確定するのみ（実課金なし）。二次ブログの乖離値は採用しない。

### 動画生成（fal.ai 公式 / 秒単価）

| モデル | 単価（音声 off〜on / tier） | 備考 |
|--------|---------------------------|------|
| Kling v3 Standard | $0.084 〜 $0.126 /s | — |
| Kling v3 Pro | $0.112 〜 $0.196 /s | voice control 時 $0.196 |
| Veo 3.1 Standard | $0.20 〜 $0.40 /s | 4K は $0.40/$0.60 |
| Veo 3.1 Fast | $0.10 〜 $0.15 /s | Runway Explore 対象外 |
| Seedance 2.0 | $0.30 〜 $0.68 /s | 1080p 音声込で $0.682。**MPA 係争中** |

### Runway（プラン / クレジット）

| プラン | 価格（年払） | クレジット | 備考 |
|--------|------------|-----------|------|
| Free | $0 | 125cr（一回限り） | — |
| Standard | $12/月 | 625cr | — |
| Pro | $28/月 | 2,250cr | — |
| Max | **$76/月** | 9,500cr | 旧 Unlimited 後継。**Explore 無制限の前提** |

消費レート：Gen-4.5 = 25cr/s、Gen-4 Turbo = 5cr/s。**Explore Mode = 720p・クレジット非消費・無制限**（低優先キュー）。

### 音楽生成

| サービス | 価格 | 権利 |
|----------|------|------|
| Suno Pro | $8/月（年払）/2,500cr | 商用可（**第三者プロキシ自動化は ToS 違反**） |
| Suno Premier | $24/月（年払）/10,000cr | 商用可 + Studio |
| MiniMax Music 2.5 | $0.035/track（最安） | ロイヤリティフリー |
| Stable Audio 2.5 | $0.20/audio（最大190秒） | licensed データ・クリーン |
| ElevenLabs Music | $0.80/分 | licensed データ・クリーン |

> ⚠️ **不採用値:** Kling「$0.029/s」「Veo 3.1 Vertex $0.75/s」は旧 tier/旧 Veo 3 の値で、公式値と乖離するため採用しない。

---

## 5. 視点間の矛盾と解決

| 矛盾 | 内容 | 解決 |
|------|------|------|
| alternatives ↔ cost | Kling 単価が約8倍乖離（$0.029 vs $0.224）、Veo 3.1 を $0.75 とする記事 | **cost（一次ソース）採用。** $0.029/$0.75 は旧 tier/誤記として不採用 |
| alternatives ↔ compliance | alternatives は Seedance を有力代替に、compliance は MPA 係争で安全性 low | **両立（矛盾でない）。** fixtures 検証なので採否は設計に影響せず。実素材フェーズで係争を必須ゲートに引き継ぎ、採用は**保留** |
| cost ↔ compliance | cost は Suno プロキシをコスト構造として整理、compliance は ToS 違反で高リスク | **BGM は fixtures で代替。** 実素材フェーズでは ElevenLabs/MiniMax/Stable Audio（正規 API・クリーン権利）を優先 |
| technical ↔ environment_compat | technical は HyperFrames Windows 対応を肯定、env は実機証拠なし | **補完的。** HyperFrames は任意レイヤ。Windows 検証が失敗しても純 ffmpeg lavfi で3点ゲートは成立 |
| alternatives ↔ risk | URL 失効を「24-48h or 14日」併存 vs「24-48h 保守的」 | **risk の保守的見解採用。** 24h 以内 DL 完了基準で設計 |

---

## 6. 推奨アクション

### ✅ Primary（推奨）— 組立層ドライラン検証ハーネスを構築

ロック決定の枠内で、以下6点の構成を実装する：

1. **生成層は make-video 外**（別ディレクトリ or Claude Code スキル層、`fal-ai-community/skills` を前例参照）に配置し、接点を `scenarios/<id>/inputs/` の MP4/WAV に限定。混入は **`grep_absent` assertion で機械検出**。
2. **正規化ステージを必須化** — 契約値（H.264 / 解像度 / fps / AAC / 44.1kHz / stereo / profile=LC）へ取り込み時に再エンコード + CFR 強制し、VFR・タイムスタンプ不整合を吸収。
3. **統一保存アダプタ層** — fal ローカル保存型と Runway URL 返却型（task ID キーの即時冪等 DL、24h 以内完了基準、`download_status` 追跡）を「取得→inputs/ 着地」に正規化。モデル ID/単価は設定外出し + フォールバック。
4. **ダミー fixtures 検証** — `ffmpeg lavfi`（testsrc + anullsrc/sine、`-shortest`/`-t` 必須）で契約値準拠のダミー MP4/WAV を生成し、`ffprobe` で3点ゲートを JSON/CSV スクリプト化して通過（**実 API 課金ゼロ**）。
5. **Windows 前提条件を明文化** — OneDrive 外配置・ツール系統統一・`MSYS_NO_PATHCONV`/CRLF 対策・`FAL_KEY` システム環境変数化。
6. **2026-06 公式価格を参照値として文書化** — 実課金検証・モデル/BGM/プロキシ採否は実素材生成フェーズへ繰延。

**根拠:** 全4ロック決定と整合。技術視点が high confidence で契約面分離 + lavfi/ffprobe ゲートの成立を裏付け、リスク視点が「ローカル完結ドライラン＝停止リスクなし」を確認。最高リスクの設計仮説（境界契約の整合性・機械ゲートの素通り防止）を**実課金ゼロで先に検証**でき、高リスク要素はすべて実素材フェーズに分離できる。

### ⚠️ Primary のリスク

- ダミーで通る3点ゲートは「存在・音声有・最低尺」の**構造保証のみ**。実素材の品質崩れ・A/V 同期ズレ・ルーティング不適は捕捉不能（L1 の本質的限界）。→ 実素材フェーズで L2/L3 行動検証 + ゴールデンサンプル QA を別途必須化。
- HyperFrames 等の Node/Chrome 依存を含めると、Windows 固有障害（symlink EPERM・LFS 詰まり・CRLF・パス迷子）が再発しドライラン再現性を損なう恐れ。
- 正規化ステージ（CFR 再エンコード）を契約に内包し忘れると、VFR/中途 GOP で concat 時に尺崩れ・同期ズレ。
- 実素材フェーズへ繰延した要素（Seedance 係争・Suno プロキシ ToS 違反・モデル月次 sunset・Veo SynthID/開示ラベル）を未解決のまま進めると、収益化停止・アカウント剥奪・設計破綻に転じうる。**繰延項目を実フェーズの必須ゲートとして引き継ぐこと。**

### 🔄 Fallback

HyperFrames 等の外部 Node/Chrome 依存を**ドライラン最小スコープから除外**し、純 ffmpeg lavfi + ffprobe のみで組立契約面と3点ゲートを検証する。生成層は最も決定論的な「別ディレクトリの bash/ffmpeg スクリプト + 設定駆動アダプタ」に寄せ、Claude Code スキル群はオプション扱い。

- **トリガー:** `npx hyperframes doctor` / `browser ensure` / `render` が文書化済み回避策適用後も Windows 実機で失敗、または fal/Runway MCP の `FAL_KEY` 伝播（#477）等の認証障害が解消できない場合。

### ❌ Abort（非推奨）

撤退（分離アーキテクチャ自体を構築しない）は**非推奨**。validate モードかつロック決定済みで本来的に選択肢外。撤退すべき条件（契約面分離が不成立・ドライランに実課金が不可避・3点ゲートが構造検証不能）はいずれも**反証済み**。撤退すると MP4/WAV 契約面という最大の設計資産を失い、将来の実素材フェーズで de-risking コストが数倍に膨らむ。

---

## 7. 実装基準（implementation-criteria）の概要

GO 判定に基づき、3フェーズ・Layer 1/2/3 の検証基準が生成済み。

### フェーズ構成

| フェーズ | ゴール | 主要基準 | mutation 閾値 |
|---------|--------|---------|--------------|
| **mvp** | ダミー fixture 1本で 生成→3点ゲート の最小1フローが課金ゼロで通る | L1-001, L1-002 | 0.4 |
| **core** | 正規化・統一保存アダプタ・SCOPE 境界を加え全工程 E2E が動作 | L1-003〜005, L2-001, L2-002 | 0.3 |
| **polish** | 異常入力で理由付き失敗、設定外出し・参照ドキュメント整備 | L1-006 | 0.2 |

### Layer 1 基準（ユニット / lint・6本）

| ID | 内容 | 偽陽性シナリオ（防止対象） |
|----|------|--------------------------|
| L1-001 | lavfi で契約値準拠ダミー MP4/WAV を決定論的生成（`-t`/`-shortest` 必須） | `touch` で 0 バイトプレースホルダを置くだけ |
| L1-002 | ffprobe による3点機械ゲート（存在・音声・最低尺） | `test -f` のみで pass、JSON を実際に検査しない |
| L1-003 | 境界正規化ステージ（再エンコード + CFR 強制） | `-c copy` で実際は再エンコードせず素通り |
| L1-004 | 統一保存アダプタ（fal 型 / Runway URL 型を inputs/ 着地に正規化） | モック化して inputs/ へ書かず success を返す |
| L1-005 | SCOPE 境界の grep_absent（make-video 配下に生成コード混入なし） | grep パターンが狭すぎて import 形式を取りこぼす |
| L1-006 | モデル ID/単価の設定外出し + レポート規定フォーマット | config 存在のみ確認、本体のハードコードを見ない |

### Layer 2 / Layer 3（行動検証）

- **L2-001:** ダミー fixtures による全工程 E2E（fixture 生成 → 正規化 → 3点ゲート → concat）課金ゼロ。
- **L2-002 / L3-003:** Runway URL 返却型アダプタを `localhost:3001` モックサーバで統合検証（task ID 冪等性・`download_status` 追跡）。※このモックは検証専用スキャフォールド（make-video 外）であり、ロック決定 ① の HTTP 排除と矛盾しない。
- **L3-001:** gate-report.json の規定スキーマ適合（`overall_pass` が全 input の AND と一致）。
- **L3-002:** ドライラン CLI フロー受入（最終 MP4 が契約値準拠 + 3点ゲート通過）。
- **L3-004（llm_judge, 非ブロッキング）:** ドキュメント完全性（2026-06 価格表・Windows 前提・繰延ゲート・「ダミー緑≠動作保証」注記・888Hz qualified 表記）。閾値 0.8。
- **L3-005（非ブロッキング）:** 設定駆動の疎結合動作（新規 fixture/モデル追加がコード変更なしで反映）。

---

## 8. 過去決定との整合

| 整合点 | 内容 |
|--------|------|
| ✅ | harness 教訓「L1=ファイル構造のみは動作を保証しない」 ⇔ risk の「ダミー緑≠動作保証、実素材失敗は L2/L3 でしか捕捉不能」と**完全一致** |
| ✅ | harness MEMORY「OneDrive 管理下での開発禁止」「MSYS /tmp 差異・CRLF・ツール系統統一」 ⇔ environment_compat の Windows 互換リスクと**直接一致** |
| ✅ | harness の機械ゲート重視（計画ゲート・L1 網羅チェック・assertions 機構）⇔ ロック決定 ④（3点機械ゲート）・ffprobe 決定論検証と整合 |
| ✅ | harness の locked_decision assertions（file_exists/grep_absent）⇔ ロック決定 ①（make-video 配下への混入を grep_absent で機械検出）に**流用可能** |

> **衝突:** 過去30件の意思決定ログは全て Forge Harness 自己改修に関するもので、本テーマとの明示的衝突はなし。ただし Windows 固有障害（jq CRLF・nested bash -c 変数破壊・パス迷子）が bash/Node 混在実装で再発しうるため、設計時に予防的対処が必要。

---

## 9. 残課題・繰延項目（実素材フェーズの必須ゲート）

実素材生成フェーズ（本スコープ外）へ引き継ぐ必須ゲート：

- **揮発 URL:** 24h 以内ダウンロード完了・task ID キー冪等保存。
- **モデル月次 sunset:** モデル ID ハードコード回避 + アダプタ + フォールバック（Gen-4 Aleph が 2026-07-30 sunset の報あり）。
- **Seedance 2.0:** MPA 係争中につき採用**保留**。
- **Suno 第三者プロキシ:** 上流 ToS 違反で**非推奨**。ElevenLabs / MiniMax / Stable Audio（正規 API・クリーン権利）を優先。
- **Veo:** SynthID 常時付与・除去禁止、YouTube 開示ラベル対応。
- **L1 ダミー緑の限界:** 実素材の品質崩れ・A/V 同期・ルーティング適正は未保証。実素材 QA は L2/L3 行動検証 + ゴールデンサンプルとして別フェーズで必須化。

### 主要な情報ギャップ（一次ソース未確認）

- AceDataCloud 固有の正確な単価・最低チャージ額（ログイン/JS レンダリングで非公開）。
- Gen-4 Aleph 等の正確な sunset 日付（公式 changelog で一次確認できず、第三者情報と矛盾）。
- HyperFrames の Windows 実機成功/失敗の一次ログ。
- 各モデル公式 ToS 原文（権利帰属・帰属表記義務・補償条項）の直接精読。
- 日本国内（地域固有）の収益化・著作権・景表法的観点（Web 検索が US 中心で未カバー）。

---

## 10. まとめ

| 項目 | 結論 |
|------|------|
| **判定** | 🟢 GO（条件付き整合） |
| **最重要設計原則** | 仕様値固定だけでは不十分。境界に**正規化ステージ**と**統一保存アダプタ**を必ず置く |
| **本スコープで検証するもの** | 組立契約面 + 3点機械ゲート + 正規化/保存アダプタの**構造**（実課金ゼロ） |
| **本スコープで検証しないもの** | 実素材の品質・A/V 同期・ルーティング最適性・実課金・モデル/BGM/プロキシ採否 |
| **最大のリスク** | 揮発 URL（24h 失効）と依存陳腐化（月次 sunset）。アダプタ層 + フォールバックで疎結合化 |
| **コンプライアンス要注意** | 第三者プロキシ（ToS 違反）と Seedance 2.0（MPA 係争）は切り分けて扱う |
| **次フェーズ** | mvp → core → polish の3フェーズで実装。繰延項目を実素材フェーズの必須ゲートとして引き継ぐ |

---

*本レポートは `.docs/research/2026-06-14-598405-142219/` 配下の investigation-plan / 6 perspective / synthesis / implementation-criteria を統合して生成。*
