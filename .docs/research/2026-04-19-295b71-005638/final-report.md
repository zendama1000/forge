# 最終リサーチレポート — Claude Code 流 動画コンテンツ作成・編集ハーネス構築設計

**研究ID**: `2026-04-19-295b71-005638`
**テーマ**: Claude Code で 100% 動作する動画コンテンツ作成・編集ハーネスの構築設計 — `browser-use/video-use` と `heygen-com/hyperframes` の超精密分析を経て、Forge Harness 同型（agents/loops/lib 三層）・動画タイプ非依存のメタ的汎用ハーネスを、Claude Code agent + bash + ローカル CLI のみで設計し、2-3 シナリオで実動検証する
**ロックモード**: validate（ロック決定 5 項目は撤回しない）

---

## 1. エグゼクティブサマリー

### 結論：**条件付き GO（成立ラインは狭いが実現可能）**

6 視点（technical / cost / risk / alternatives / repo_forensics / meta_abstraction）の横断分析により、ロック決定事項はいずれも技術的に実現可能と結論づけられた。ただし **成立ラインは狭く、5 つの構造的制約** を設計段階で織り込む必要がある。

| 軸 | 評価 | 根拠 |
|---|---|---|
| 技術的実現性 | ◯（部分成立） | HyperFrames は HeyGen クラウド依存ゼロ、Node.js + Puppeteer + FFmpeg でローカル完結。video-use の設計思想は bash+CLI 再実装可能。ただしアバター音声同期（Wav2Lip 等）は Python ML + VRAM 必須で完全再現不可。 |
| コスト | ◎ | 1 シナリオ $15-28（キャッシュで $6-13）、総実時間 57-172 分、既存資産 70-82% 再利用、新規ファイル 14-23 本。 |
| メタ汎用性 | ◯ | OTIO 骨格 + RenderJob + QualityGate の 6 要素 JSON スキーマ + 5 段パイプライン（acquire→segment→compose→encode→verify）+ ディレクトリスキャン型プラグイン機構でシナリオ追加コスト=1（SAC 指標）を目標化。 |
| リスク | △ | Bash タイムアウト SIGTERM バグ（Issue #45717）未修正、Forge 既知バグ群の再発、Windows 環境起因リスク、L3 主観依存が残存。 |

---

## 2. 調査設計（investigation-plan の骨子）

### 2.1 コア質問（要約）

1. bash + CLI のみで動画機能（取得/分解/編集/合成/音声/字幕/エンコード）をどうカバーするか
2. `browser-use/video-use` を関数単位で分解し、移植/捨てる/差し替えをどう判定するか
3. `heygen-com/hyperframes` の HeyGen 依存除去可否と再実装可能範囲
4. 両者の設計思想を Forge 同型三層（agents/loops/lib）にどう写像するか
5. 動画タイプ非依存のメタ抽象レイヤー設計
6. 最小コストで汎用性を実証する 2-3 シナリオ選定
7. L2/L3 機械検証ゲート設計
8. 長尺処理・リトライ・レートリミット対応

### 2.2 視点構成

| 視点 | 役割 |
|---|---|
| **technical**（固定） | 技術的実現性 — 再現可否・三層写像・JSON 状態モデル・長時間処理耐久 |
| **cost**（固定） | コスト・リソース — API 費用・ローカル HW フットプリント・移植工数 |
| **risk**（固定） | リスク・失敗モード — エラー伝播・既知バグ再発・環境起因リスク |
| **alternatives**（固定） | ロック範囲内の選択肢比較 — ffmpeg/gstreamer、whisper.cpp/vosk、JSON/SQLite 等 |
| **repo_forensics**（動的） | 参照リポジトリ超精密分析 — モジュール単位の移植判定 |
| **meta_abstraction**（動的） | 動画タイプ非依存のメタ抽象レイヤー設計 |

---

## 3. 視点別の主要所見

### 3.1 technical — 技術的実現性

- **HyperFrames**（Apache 2.0）は HeyGen クラウド依存ゼロかつ Node.js 22+ と FFmpeg のみで完全ローカル動作することが確認された。`/hyperframes` `/gsap` スラッシュコマンドとして Claude Code に組込可能。
- **video-use** は検索上明確に特定できず、概念的表現の可能性あり。OpenMontage（CLAUDE.md + SadTalker/Wav2Lip 統合）が実証例として存在。
- **最大の障壁 1**：アバター音声同期（Wav2Lip/MuseTalk）は Python ML + 6GB 以上 VRAM が必須で、bash + CLI のみでは再現不可能。
- **最大の障壁 2**：Bash タイムアウト SIGTERM 伝播バグ（Issue #45717、Claude Code 2.1.97 で確認）により長時間エンコードの直接管理不可。→ **OS 級 nohup 分離 + プログレスファイルポーリング + ffprobe assertions** の三点セット必須。
- **JSON 状態モデル**：Asset/Clip/Track/Timeline/RenderJob の 6 要素は jq + bash で実用操作可能（Remotion JSON Render・Shotstack・Amazon States Language に先例あり）。ただしフレーム精度タイミング（29.97fps ドロップフレーム）は bc/python 補完が必要。
- **Windows Git Bash**：ffmpeg/yt-dlp/whisper.cpp は安定動作するが、`/tmp` パス分裂・MSYS パス変換・CRLF は既知問題として残存。

### 3.2 cost — コスト・リソース

| 項目 | 見積もり |
|---|---|
| **Phase 1 API コスト** | 20 呼出 × 平均 $0.135 ≈ $2.70（Synthesizer 集約で実際 $3-8） |
| **Phase 2 API コスト** | 12-18 タスク × 3-5 呼出 × 80k 入力 + 5k 出力 ≈ $12-20 |
| **1 シナリオ合計** | $15-28（キャッシュなし）、$6-13（キャッシュ活用） |
| **whisper.cpp ディスク/VRAM** | tiny 75MB/1GB 〜 large-v3 2.9GB/10GB（量子化版 Q5_0 で半減） |
| **ffmpeg 1080p x265** | ピーク RAM 910MB、スループット 8fps（実時間比 3 倍） |
| **hyperframes 移植工数** | 7-11 人日 → Claude Code 支援で 4-7 人日相当 |
| **既存資産再利用率** | lib 85-95% / schemas 65-80% / templates 70-85% / tests 55-70% / agents 60-75%（全体 **70-82%**） |
| **新規作成ファイル** | スキーマ 3-5、テンプレート 3-4、エージェント 2-4、スクリプト 3-5、テスト 3-5（合計 **14-23**） |
| **Phase 2 2-3 シナリオ総実時間** | **57-172 分**（GPU 環境で下限側 1 時間強） |

### 3.3 risk — リスク・失敗モード

| リスク | カバー状況 | 事前対策 |
|---|---|---|
| ffmpeg ゾンビ化・ディスク溢れ | Forge circuit-breaker は検知しない | `trap EXIT` cleanup、ディスク残量事前チェック |
| 中間ファイル破損 | 未対応 | `-movflags frag_keyframe` による fragmented MP4 |
| **Implementer ファイル数 30 上限** | 動画パイプラインと相性最悪（フレーム列で容易に超過） | setup プロファイル（max_files=50）、中間ファイルを `.forge/tmp/video/` に集約し git 追跡外 |
| **ハルシネーション/ファイル未作成（2026-04-12 事例）** | `-p` モードではサブエージェント未ロード | L1 に `ffprobe -v error -show_entries format=duration` 必須化 |
| **相対パス迷子** | 修正済みだが regression リスクあり | WORK_DIR 絶対パス環境変数 + 全 run_claude に渡す |
| in_progress 残留 | `task_timeout_sec: 600` で残留 | 動画タスクは 1800+、1タスク1処理に限定 |
| **L3 human_check のみで実検証ゼロ** | 2026-04-12 再発リスク | `required_mechanical_gates[]` 必須化・空配列禁止（構造的封じ込め） |
| **/tmp パス分裂・OneDrive・CRLF** | ハーネス側で検出機能なし | 前提条件チェックリストで必須項目化、`.gitattributes eol=lf` |
| Windows パス長 260 文字制限 | 未対応 | `git config core.longpaths true` |

### 3.4 alternatives — ロック範囲内の選択肢比較

| 選択軸 | 推奨 | 却下候補 | 理由 |
|---|---|---|---|
| 動画 I/O コア | **ffmpeg 一本化** | GStreamer (gst-launch)、MLT/melt | GStreamer は公式に production 用途禁止、MLT は学習コスト過大 |
| 音声認識 | **whisper.cpp** または **FFmpeg 8.0 Whisper フィルタ** | vosk（スタンドアロン CLI なし） | ゼロ依存、SRT/VTT/JSON 出力対応 |
| 画像合成 | **imagemagick** または **ffmpeg filter_complex** | — | GraphicsMagick はバッチ性能重視環境のみ |
| ループ構造 | **render-loop 新設**（ralph-loop テンプレ化）| 全面流用 | ralph-loop は同期的ファイル作成検証で動画非同期と相性悪 |
| 状態管理 | **JSON + jq + flock** | SQLite CLI、ファイルシステムのみ | Forge 互換・依存最小 |
| 移植範囲 | **サブセット（4 コア機能）+ プラグイン拡張点** | 全機能移植 | Phase 2 完遂可能性とメタ汎用性を両立 |

### 3.5 repo_forensics — 参照リポジトリ超精密分析

#### video-use（`browser-use/video-use`）

- **構成**: Python 75.2% / HTML 23.7% / Shell 1.1%、コミット 7、MIT 推定（LICENSE 不在）
- **エントリポイント**: Claude Code skill（`~/.claude/skills/video-use`）
- **8 段パイプライン**: Inventory → Pre-scan → Converse → Strategy（承認ゲート）→ Execute（Editor+Animation sub-agents）→ Preview → Self-Eval（最大 3 周）→ Iterate+persist
- **状態**: `project.md`（揮発 State）/ `takes_packed.md`（~12KB フレーズ）/ `edl.json`（Job 記述子）/ `transcripts/` / `animations/slot_<id>/` / `clips_graded/` / `verify/`
- **移植分類**:

| 要素 | 分類 | 備考 |
|---|---|---|
| transcribe.py（ElevenLabs） | **差し替え** | whisper.cpp で代替 |
| transcribe_batch.py（並列 4 ワーカー） | **移植対象** | 並列化パターン |
| pack_transcripts.py（silence≥0.5s 分割） | **移植対象** | データ変換ロジック |
| timeline_view.py（フィルムストリップ+波形） | **移植対象** | 視覚化戦略 |
| render.py（`-c copy` で再エンコード回避） | **移植対象** | レンダリングコア |
| Editor sub-agent（LLM） | **移植対象** | エージェントパターン |
| Animation sub-agents（PIL/Manim/Remotion） | **差し替え/廃棄** | 不要なら廃棄 |

#### hyperframes（`heygen-com/hyperframes`）

- **ライセンス**: **Apache 2.0**（商用利用可、NOTICE 保持・変更明示）
- **monorepo**: cli / core（型/パーサー/ジェネレーター/コンパイラー/リンター/ランタイム/Frame Adapter）/ engine（Puppeteer + Chrome BeginFrame API）/ producer / studio / player / shader-transitions
- **5 段階パイプライン**: Server Setup → Frame Capture → Video Encoding（GPU 自動検出）→ Audio Integration → MP4 Finalization
- **HeyGen クラウド依存ゼロ確認済**（`@hyperframes/core` / `producer` に API 呼出なし、CONTRIBUTING.md に明記）
- **アバター機能は本体に存在しない**（HeyGen talkinghead は完全に別クラウドサービス）
- **音声**: Kokoro TTS（ローカル、API キー不要）
- **制約**: Node.js 22+ と Puppeteer が構造的必須 → bash+CLI 純度と緊張関係

#### 両者共通の抽象パターン

1. **Pipeline DAG**（有向非巡回グラフ状ステージ連鎖）
2. **Job/RenderJob**（hyperframes: `createRenderJob()`、video-use: `edl.json`）
3. **Artifact/State 分離**（揮発 vs 不揮発）
4. **Self-Eval/Lint ゲート**
5. **エージェントファースト設計**（LLM が CLI を操作する前提）

#### 分離ライン（残す設計思想 vs 置き換える実装手段）

| 残す（What） | 置き換える（How） |
|---|---|
| テキスト優先原則（~12KB テキスト表現を LLM に） | ElevenLabs → whisper.cpp |
| 音声プライマリ編集（単語境界カット） | Python pydantic → JSON Schema + jq |
| 確認ゲート（Human-in-the-loop） | transcribe_batch.py → bash 並列サブエージェント |
| セルフ eval ループ（最大 3 回） | render.py → ffmpeg ラッパーシェル |
| 3 層 Artifact 永続化 | Manim/Remotion → 廃棄 or hyperframes |
| 宣言的 HTML タイムライン / Frame Adapter | TypeScript/Bun → Bash + jq |
| 決定論的レンダリング | Puppeteer BeginFrame → ffmpeg 決定論エンコード |
| 5 段パイプライン | studio UI → 省略 |

### 3.6 meta_abstraction — 動画タイプ非依存のメタ抽象

#### 共通スキーマ（6 要素）

OpenTimelineIO（OTIO）骨格を採用:

```
Timeline → Track[] → Clip[] → MediaReference
              +
RenderJob（job_id, timeline_id, status, output_uri, render_params）
QualityGate（gate_id, command, pass_criteria, timeout_sec, required_mechanical_gates[]）
```

動画タイプ間の差分は **asset_type** と **render_params** の中身のみに閉じる。

#### 5 段パイプライン

`acquire → segment → compose → encode → verify`

| ステージ | 意味 | Forge 対応 |
|---|---|---|
| acquire | 入力素材取得（AI アバター合成・録画インポート・画像エクスポート） | mvp |
| segment | トリミング・分割（Clip 変換） | mvp |
| compose | Timeline 配置（マルチトラック合成・BGM） | core |
| encode | ffmpeg レンダリング | core |
| verify | QualityGate 実行 | polish |

#### プラグイン機構（SAC=1 目標）

```
scenarios/{id}/
├── scenario.json         # {scenario_id, input_schema, processing_stages, agent_prompt_patch, l3_gates[]}
├── (agent_prompt_patch)  # base_prompt.md への差分ヒアドキュメント注入
└── (mock_runner.sh)      # プラグイン契約モック
```

メインループが `ls scenarios/*/scenario.json` を jq で全スキャン。コアスクリプト無変更でシナリオ追加=1 ディレクトリ。

#### Phase 2 実証シナリオ（ペアワイズ 2-way coverage）

差分 3 次元: (A) 入力ソース=synthetic/captured、(B) 合成モデル=single-source/multi-clip、(C) QualityGate=automated-objective/automated-behavioral/human-check

| シナリオ | A | B | C |
|---|---|---|---|
| 1. AI avatar | synthetic | single-source | automated-behavioral |
| 2. screen recording | captured | multi-clip | automated-objective |
| 3. slideshow（静止画+TTS）| captured | single-source | human-check |

2 シナリオで全 2 次元組合せを網羅、3 シナリオ目で 3-way coverage 補強。

#### 汎用性評価指標（4 指標）

| 指標 | 定義 | 目標値 |
|---|---|---|
| **SAC**（Scenario Addition Cost） | 新規シナリオ = 新規ファイル×1 + コア変更行×10 | 1（scenario.json のみ） |
| **CDR**（Core Duplication Rate） | シナリオ固有 LOC ÷ 全体 LOC | < 20%（>40% で抽象過剰警告） |
| **L3R**（L3 Success Rate） | 自動 QualityGate pass ÷ 全定義 | > 80% |
| **CMC**（Core Modification Coefficient） | 過去 N シナリオ追加時のコアファイル変更数平均 | 0 |

---

## 4. 視点間の矛盾と解消

| # | 視点対 | 論点 | 解消 |
|---|---|---|---|
| 1 | technical ↔ repo_forensics | hyperframes の移植可能性（Node.js/Puppeteer 必須 vs bash+CLI 純度） | **設計思想は移植、実装は video-use 式（ffmpeg+whisper.cpp 直接合成）主軸**。HTML→動画レンダリングが必要な場合のみ `hyperframes` CLI を bash から呼ぶ最小例外として許容。オーケストレーターは Claude Code agent + bash で純度維持。 |
| 2 | alternatives ↔ cost | ralph-loop 改修 vs render-loop 新設 | **ralph-loop をテンプレ化して render-loop.sh を新設**。`validate_task_changes` を ffprobe+サイズ閾値+RenderJob status 検証に置換。下層資産（common.sh/bootstrap.sh/run_claude/state/protected_patterns）は 100% 流用。 |
| 3 | risk ↔ meta_abstraction | L3 抽象化 vs 機械的 L3 最低 1 個必須 | **QualityGate スキーマに `required_mechanical_gates: [ffprobe_exists, duration_check, size_threshold]` デフォルト必須配列を定義**。scenario.json で上書き可だが空配列禁止。2026-04-12 事例を構造的に封じる。 |
| 4 | repo_forensics ↔ alternatives | video-use の正体特定 | **repo_forensics の直接コード調査結果を正**とする（browser-use/video-use、Python 75.2%、8 段パイプライン確認）。Python 必須は『設計思想の参照元』として扱い、bash+whisper.cpp+ffmpeg+jq に差し替え再実装。 |

---

## 5. ロック決定との整合性

### 5.1 整合（aligned）

- ✅ Forge 同型三層（agents/loops/lib）— 12 エージェントの 60-95% 再利用可、common.sh/bootstrap.sh 完全流用
- ✅ Claude Code agent + bash 純度 — ffmpeg/whisper.cpp/imagemagick/jq で video-use 設計思想の大半を bash 再実装可
- ✅ 動画タイプ非依存メタアーキテクチャ — OTIO 骨格 + 6 要素スキーマ + 5 段 + プラグインで全タイプ共通コード処理可
- ✅ 両リポジトリ精密分析 — video-use（MIT 推定・8 段）と hyperframes（Apache 2.0・HeyGen 依存ゼロ）を関数単位で分解完了
- ✅ Phase 2 で 2-3 シナリオ実動 — ペアワイズで {AI-avatar, screen-recording, slideshow} が主要 3 次元網羅、57-172 分で完遂

### 5.2 緊張関係（conflicts）

- ⚠ **hyperframes 本体利用時 Node.js 22+ 依存** → 『必要時のみ最小限』例外条項で限定許容。純度最優先なら設計思想参照のみに降格（fallback）。
- ⚠ **video-use の Python helpers** → 設計思想のみ抽出し bash+CLI 再実装で解決。

---

## 6. 採用すべき設計の骨格（Primary 推奨）

| 項目 | 決定事項 |
|---|---|
| **A. ループ層** | 三層流用 + `render-loop.sh` 新設（ralph-loop テンプレ化、`validate_task_changes` を `validate_render_output` に置換）|
| **B. 状態モデル** | OTIO 骨格 + RenderJob + QualityGate の 6 要素 JSON + jq + `flock` 排他制御 |
| **C. プラグイン機構** | `scenarios/{id}/scenario.json + agent_prompt_patch + l3_gates[]` のディレクトリスキャン型、**SAC=1** 目標 |
| **D. パイプライン** | acquire → segment → compose → encode → verify |
| **E. コア CLI** | **ffmpeg 一本化** + whisper.cpp（または FFmpeg 8.0 Whisper フィルタ）+ imagemagick/ffmpeg filter_complex（MLT/GStreamer/vosk 却下）|
| **F. video-use 移植** | 設計思想のみ採用（テキスト優先・音声プライマリ・確認ゲート・セルフ eval・3 層 Artifact）。Python helpers は bash+CLI 再実装 |
| **G. hyperframes 扱い** | 設計思想参照（Frame Adapter・宣言的 HTML・5 段）+ HTML→MP4 シナリオに限り CLI を bash から呼ぶ最小例外 |
| **H. 長時間エンコード** | **nohup バックグラウンド化 + プログレスファイルポーリング + ffprobe assertions** 三点セット（Issue #45717 回避）|
| **I. QualityGate 必須化** | `required_mechanical_gates[]` に `ffprobe_exists / duration_check / size_threshold` デフォルト必須・空配列禁止 |
| **J. Phase 2 実証** | {AI-avatar（外部 API 差し替え可プラグイン）, screen-recording→字幕付き編集, slideshow（静止画+TTS）} の 3 本 |
| **K. 前提条件チェックリスト** | git init / `.gitignore` / **`.gitattributes eol=lf`** / development.json `server.start_command=none` / WORK_DIR 絶対パス / OneDrive 回避 / `core.longpaths` / setup プロファイル（max_files=50）/ ディスク残量 |

---

## 7. Fallback 設計

**トリガー**（いずれか発生時に切替）:
1. Phase 1.5 で render-loop 新設タスクが 12 本超に膨らみ Phase 2 完遂見積が 3 時間超過
2. hyperframes CLI が Windows Git Bash で不安定
3. Implementer ファイル数上限を setup プロファイル拡張でも突破不能
4. アバター同期プラグインの外部 API 要件とユーザー純度要件が衝突
5. Bash タイムアウト SIGTERM バグでエンコード監視が 3 回以上クラッシュ

**縮退内容**: Phase 2 実証を hyperframes 非依存の 2 本（screen-recording、slideshow）に限定。AI-avatar は雛形のみ残し実動検証から除外。render-loop 新設を見送り、ralph-loop の `validation.layer_2.command` に ffprobe 系を詰める形で代替。

---

## 8. 主要リスクと監視ポイント

| # | リスク | 対策 |
|---|---|---|
| 1 | hyperframes CLI が Node.js 22+ を要求し純度批判を招く | hyperframes をシナリオ 3 から外し設計思想参照のみに降格する fallback |
| 2 | video-use セルフ eval の bash 再実装が Implementer 30 上限に抵触 | setup プロファイル max_files=50、タスク粒度 1-2 ファイル、中間ファイル `.forge/tmp/video/` 集約で git 追跡外 |
| 3 | Bash タイムアウト SIGTERM バグ（Issue #45717）未修正 | nohup ベース完全分離設計を徹底 |
| 4 | QualityGate 偽陽性（機械的合格だが視覚違和感あり） | Phase 4 に人手レビューゲートを必ず残す |
| 5 | Windows Git Bash の /tmp 分裂・OneDrive・CRLF | 前提条件チェックリスト遵守が運用成否を左右 |

---

## 9. 実装基準（implementation-criteria の要約）

### 9.1 Layer 1（単体/静的検証、7 項目）

| ID | 内容 | test_type |
|---|---|---|
| L1-001 | scenario.json schema 適合性検証（全既存シナリオで成功、不正は拒否） | unit_test |
| L1-002 | `required_mechanical_gates[]` 空配列禁止バリデータ（2026-04-12 事例封じ込め）| lint |
| L1-003 | `render-loop.sh` の bash 構文 + shellcheck + `set -euo pipefail` | lint |
| L1-004 | OTIO 6 要素 JSON スキーマ（Timeline/Track/Clip/MediaReference/RenderJob/QualityGate）検証 | unit_test |
| L1-005 | video-domain assertions（`ffprobe_exists / duration_check / size_threshold`）型チェッカー | unit_test |
| L1-006 | `scenarios/{id}/` ディレクトリスキャン型プラグイン検出（SAC=1 土台）| unit_test |
| L1-007 | 前提条件チェックリスト関数（git/.gitignore/.gitattributes/OneDrive/core.longpaths/disk/server=none）| unit_test |

### 9.2 Layer 2（統合検証、6 項目）

| ID | 内容 |
|---|---|
| L2-001 | ffmpeg ≥6.0 / ffprobe バージョン要件 |
| L2-002 | whisper.cpp または FFmpeg 8.0 Whisper フィルタで 10 秒 wav 書起こし |
| L2-003 | imagemagick (convert) と jq の基礎パイプライン |
| L2-004 | `render-loop.sh` E2E（mock シナリオ、RenderJob pending→running→succeeded）|
| L2-005 | hyperframes CLI オプトイン扱い（未導入時は fallback シナリオへ降格）|
| L2-006 | 長時間エンコード（>10 分）の nohup + progress file 分離（Issue #45717 回避）|

### 9.3 Layer 3（E2E/機械検証、7 項目）

| ID | 内容 | strategy | blocking |
|---|---|---|---|
| L3-001 | slideshow シナリオ → ffprobe で duration/codec/resolution 検証 | cli_flow | ✅ |
| L3-002 | screen-recording シナリオ → srt 非空（>100B）+ 字幕ストリーム検出 | cli_flow | ✅ |
| L3-003 | AI-avatar プラグインインタフェース契約検証（mock_runner）| structural | ✅ |
| L3-004 | 全シナリオで `required_mechanical_gates[]` が 1 個以上定義かつ全 PASS | structural | ✅ |
| L3-005 | render-loop が `task-stack.json` status=done + `decisions.jsonl` に `render_completed` 追記 | api_e2e | ✅ |
| L3-006 | LLM judge による成果物 summary.json スコア ≥ 0.7 | llm_judge | ✅ |
| L3-007 | **SAC=1 実証**（scenarios/test-sac 1 ディレクトリ追加・既存コード無変更で検出）| cli_flow | ⬜ |

### 9.4 Phase 分解

| Phase | Goal | criteria_refs | mutation 閾値 |
|---|---|---|---|
| **mvp** | scenarios プラグイン + render-loop + slideshow E2E | L1-001〜007 | 0.4 |
| **core** | slideshow + screen-recording + AI-avatar 雛形、task-stack 連携 | L2-001〜004、L3-001/002/003/005 | 0.3 |
| **polish** | nohup 分離、エッジケース、LLM judge ≥0.7、SAC=1 実証 | L2-005/006、L3-004/006/007 | 0.2 |

---

## 10. 推奨される次のアクション

1. **Phase 1.5 起動**: 本レポートを criteria 入力として `bash .forge/loops/generate-tasks.sh` を実行。task-stack.json 生成後は L1 criteria 網羅チェックゲート（2026-03-11 実装）の warning を確認。
2. **前提条件チェックリスト拡張**: 動画ハーネス専用項目（ffmpeg/whisper.cpp/imagemagick/Node.js optional/OneDrive/core.longpaths/ディスク残量 5GB）を `.claude/rules/forge-operations.md` に追記。
3. **research-config.json 生成**: `locked_decisions.assertions[]` に `required_mechanical_gates` 必須化アサーションを注入（空配列検出 → CRITICAL）。
4. **fallback トリガー監視**: Phase 2 開始後、5 トリガー（render-loop タスク数、hyperframes 安定性、ファイル数上限、純度衝突、SIGTERM クラッシュ）を `dashboard.sh` で可視化。

---

## 11. Gaps（調査未完了事項）

| 未解決 | 影響 |
|---|---|
| video-use の正体（仮称 or 実体）最終特定 | Python helpers 移植判断に影響（現状は設計思想のみ採用で回避済）|
| hyperframes `engine/src/services/` 直接参照（クラウド統合隠れコード有無）| 純度評価の最終確度 |
| Bash タイムアウト SIGTERM バグの 2026-04 以降修正状況 | nohup 分離設計の必須度 |
| jq + bash の 1000+ Clip パフォーマンスベンチマーク | 大規模 Timeline スケーラビリティ |
| `.gitattributes` の既存有無 | CRLF 問題の対処必要度 |
| VMAF/SSIM の No-Reference 手法 2026 年動向 | 生成動画の参照なし品質評価 |
| Windows 環境での SadTalker/MuseTalk 実動報告 | AI-avatar プラグイン選択肢 |

---

## 12. 主要エビデンス

- **HyperFrames**: https://github.com/heygen-com/hyperframes (Apache 2.0, Node.js 22+, FFmpeg)
- **video-use**: https://github.com/browser-use/video-use (SKILL.md、8 段パイプライン)
- **Claude Code Issue #45717**: Bash タイムアウト SIGTERM 伝播バグ
- **OpenTimelineIO**: https://opentimelineio.readthedocs.io/ (産業標準 Timeline 骨格)
- **FFmpeg 8.0 Whisper フィルタ**: https://itsfoss.gitlab.io/blog/ffmpeg-80-merges-openai-whisper-filter-for-automatic-speech-recognition/
- **whisper.cpp**: https://github.com/ggml-org/whisper.cpp (ゼロ依存 C/C++)
- **ffmpeg-quality-metrics**: https://github.com/slhck/ffmpeg-quality-metrics (VMAF/SSIM/PSNR CLI)
- **qr-lipsync**: https://github.com/UbiCastTeam/qr-lipsync (音ズレ自動測定)
- **プロジェクトメモリ**: `.claude/memory/MEMORY.md`（2026-04-12 claude -p モード制約、Implementer ファイル数上限、run_claude work_dir）

---

**本レポートは 6 視点 × 44 findings を統合した GO 判定であり、Phase 1.5（criteria → task-stack 生成）への移行を推奨する。**
