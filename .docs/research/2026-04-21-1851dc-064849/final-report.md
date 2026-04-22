# make-video v2 ブラッシュアップ — リサーチ最終レポート

**Research ID**: `2026-04-21-1851dc-064849`
**生成日**: 2026-04-21
**テーマ**: make-video v2 における「編集深化 × 依存方針再評価 × スコープ抑制」の3軸統合判定と最重要1-2論点の絞り込み

---

## 1. エグゼクティブサマリー

6視点（固定4 + 動的2）を横断した結果、**6視点すべてが一致して支持する唯一の解**が浮かび上がった。

| 項目 | 判定 |
|---|---|
| **v2 最重要1件** | 無音境界自動カット（silence-cut シナリオ追加） |
| **依存方針** | **A（純粋 bash 堅持）** を v2 スコープ内で継続 |
| **v2 DoD** | 「silence-cut シナリオが既存 4 シナリオと同等品質で動作する」の 1 項目のみ |
| **残り 6 論点** | v3 候補 / 恒久スコープ外 / 外部委譲 の 3 カテゴリに明示分類 |
| **品質ゲート** | `shellcheck -S error` + `shellmetrics` で CC ≤ 10 を CI 監視 |
| **Fallback** | 純 bash 実装が等価 Python 実装の 3 倍超コード量になった時点で方針 B（シナリオ局所許可）へ段階的シフト |

---

## 2. 調査計画（Investigation Plan）

### 2.1 コア質問

1. 7論点のうち、v1 到達点を最も改善し実装コストとスコープ抑制を両立できる『最重要1-2件』はどれか
2. 編集機能3候補（無音カット / Editor sub-agent / 波形可視化）のうち、SAC=1・bash 中心・シナリオ局所性と最も整合する『最初の1つ』はどれか
3. 依存方針 A/B/C のいずれが make-video の本質に最も合うか
4. 選定した組合せで SAC=1 原則を破らずに実装可能か
5. 『動画ハーネス』と『動画作成シナリオ集』のどちらに本質を置くべきか

### 2.2 晒された暗黙前提

- 3軸（編集深化・依存方針・スコープ抑制）はトレードオフ関係にあり同時最大化不可
- video-use 機能移植が常に価値を持つという前提
- 編集機能3候補は相互排他（実は包含関係あり）
- improvements を『積む』方向が正解という前提（逆に『削る v2』の可能性）

### 2.3 境界

- **ロック範囲**（変更不可）: v1 ベース継続 / Forge 三層維持 / SAC=1 原則維持
- **打ち切り条件**: 最重要1-2論点の実装計画具体化、7論点全てに『今やる/後回し/スコープ外』判定、依存方針 A/B/C 判定根拠の両論併記が揃った時点

---

## 3. 視点別サマリー（6 Perspectives）

### 3.1 技術視点（technical）

| 編集機能候補 | SAC=1 準拠 | 必要依存 |
|---|---|---|
| 無音境界カット | **完全準拠** | ゼロ（bash + awk + ffmpeg concat demuxer、2 パス） |
| 波形可視化（静的 PNG） | 完全準拠 | ゼロ（ffmpeg showwavespic のみ） |
| 波形可視化（インタラクティブ） | 非準拠 | Node.js（peaks.js / wavesurfer.js） |
| Editor sub-agent | 最小例外必要 | curl + scenario.json に `api_key_env` 追加 |

- `silenceremove` は音声専用フィルタ。**映像込みの無音カットは 2 パス実装**（silencedetect → awk 解析 → concat demuxer）が必須
- video-use 由来機能は **whisper.cpp（C++ CLI）で Python 不要化可能**
- 依存方針 B を選ぶ場合、scenario.json の `requires: {tools, python_packages, min_ffmpeg_version}` + direnv/venv + サブシェル実行が最小構成

### 3.2 コスト視点（cost）

| 候補 | タスク数 | dev_phase | 備考 |
|---|---|---|---|
| 無音境界カット | **3〜4** | 1 | 最低コスト、依存ゼロ |
| 波形可視化（静的） | 1〜3 | 1 | ffmpeg のみ |
| 波形可視化（インタラクティブ） | 5〜8 | 2〜3 | Node.js 依存で急増 |
| Editor sub-agent | 6〜8 | 2 | 最高コスト、依存追加誘発 |

- 依存追加（Python/Node）は **恒久運用コスト**（Docker +200〜500MB、CI +2〜3 分/ビルド、ユーザーセットアップ +15〜30 分）が支配的で、一時実装コストより大きい
- スコープ抑制により **全論点実装比で工数 80〜90% 削減** 可能
- video-use 3 機能: 「ゼロ（外部参照のみ）= 0 タスク」が最低コスト、全移植は 10〜16 タスク + Python 依存確定

### 3.3 リスク視点（risk）

| リスク | 発現条件 | 早期警告指標 |
|---|---|---|
| Leaky Abstractions（方針 C） | 外部依存多層化 | バージョン差異で Forge シェル呼出失敗 |
| 機能天井（方針 A） | 大規模 CI/CD 相当機能 | 分岐爆発、CC 上昇 |
| SAC=1 形骸化 | render.sh に `--mode=` フラグ増殖 | CC > 10、NPath Complexity 急増 |
| Second-System Effect | v1 で断念した機能の一斉投入 | Code Churn 週次 2 倍、CC > 20、Maintainability Index < 20 |
| 部分実装化（hyperframes/AI 統合） | v2 同時投入 | `-p` モードで L3 自動テスト不可（既知制約） |

- 業界調査: 自動化失敗の **62% が依存不一致起因**（ロック決定 A の根拠）
- 後付けコスト: 要件時 1 倍 → 実装後 2.5 倍 → プロダクション後 1000 倍（古典）
- 防止策: `shellmetrics` の CI 組込、`edit_handler.sh` としての委譲分割、CC ≤ 10 固定

### 3.4 代替案視点（alternatives）

| 項目 | 推奨案 | 次善案 | 却下案 |
|---|---|---|---|
| 編集機能優先順位 | **無音カット先行**（即効性） | 波形可視化（UX） | Editor sub-agent 先行（コスト高） |
| 依存方針 | A（純粋 bash） | B（シナリオ局所） | C（全面解禁、Leaky） |
| video-use 扱い | **外部参照のみ** | 1つだけ移植（無音カット or Whisper.cpp） | 全移植 |
| v2 アイデンティティ | **シナリオ集 → 共通抽出後ハーネス化** | ハーネス先行 | — |
| hyperframes | **v2 スコープ外**（役割層が違う） | optional シナリオ化 | — |
| 長尺動画対応 | **スコープ外宣言** | チャンク分割シナリオ追加 | text-to-video 延長（設計崩壊） |

- 2026 年ハーネスエンジニアリング知見: **ツール 17→2 本削減でベンチマーク成功率 80%→100%、実行時間 3.5 倍速、トークン 37% 削減**。早期抽象化は過剰工学
- `video-use`（browser-use/video-use）も**先頭機能として無音カットを採用**、その実証

### 3.5 純度 vs 機能性視点（purity_vs_capability）

**純度を犠牲にしてよい定量閾値**:

| 軸 | 閾値 |
|---|---|
| コード量 | 純 bash が等価 Python の **3 倍超** |
| 行数 | Google Shell Style Guide: **100 行超または非自明制御フロー** |
| 再現性影響 | 自動化失敗 62% が依存起因（OneUptime 2026） |
| 互換性シグナル | lib 層 / loop 層への他言語混入時点 |

- `grep -r 'python\|node\|ruby' lib/ loops/` がゼロヒット = 純度維持指標
- 『薄いラッパ』を破壊する機能: ステート管理、LLM インライン推論、多段依存チェーン、コンテンツ意味解析
- Anthropic は **モデル改善に伴いハーネス機能を定期削除**（産業トレンドとしてのハーネス薄型化）

### 3.6 スコープ規律視点（scope_discipline）

**MoSCoW + DoD 最小化フレーム**:

| カテゴリ | 該当例 | 再検討条件 |
|---|---|---|
| Must（v2 DoD） | 無音カット 1 件 | — |
| Won't（v3 候補） | Editor sub-agent / 波形可視化 / 長尺対応 | 月次レビュー or 独立要望 3 件以上 |
| 恒久スコープ外 | hyperframes | 役割層が異なるため v3 でも別プロジェクト扱い |
| 外部委譲 | video-use 3 機能 | ユーザー側で video-use 参照 |

**再検討トリガー 3 種**:
1. 時間: 月次/四半期定例レビュー
2. 需要: 独立ユーザー要望 **3 件以上**
3. 前提変化: ビジネス優先度・リソース・技術前提のいずれか

- Steve Jobs 型スコープ宣言: **「X に集中するため Y はしない」対形式**で明文化
- 『中間状態（両方ちょっとずつ）』は複数の製品戦略文献（Mind the Product 他）が**最悪解**と警告
- 『削る v2』（Addition by Subtraction）は HBR・Fast Company が支持する正当戦略

---

## 4. 視点間の矛盾と解消（Contradictions）

| 矛盾 | 内容 | 解消方針 |
|---|---|---|
| alternatives vs cost | Editor sub-agent を長期優位で推す vs 最高コストで非現実的 | **無音カット先行**採用。Editor sub-agent は v3 候補 + 再検討トリガー（AI 連携要望 3 件以上）付与 |
| alternatives vs cost | video-use「1 つだけ移植」 vs「ゼロ（外部参照）」 | **外部参照のみ**採用。無音カットは v2 独自実装で既に満たされる |
| purity_vs_capability vs scope_discipline | 3 倍閾値で部分的 B 移行示唆 vs 中間状態禁止で単極化要求 | v2 スコープ内は A 堅持で完結（矛盾発生せず）。3 倍閾値は **v3 以降の B 移行判定基準**として保留 |
| risk vs alternatives | hyperframes/AI 同時投入は中途半端化リスク vs hyperframes は差別化要素 | v2 は hyperframes を **恒久スコープ外に近い v3 候補**扱い、役割層が編集と異なるため独立 |

---

## 5. 統合推奨（Synthesis Recommendations）

### 5.1 Primary（主推奨）

**アクション**:
- v2 最重要 1 件 = **無音境界自動カット シナリオ追加**
- 依存方針 = **A（純粋 bash 堅持）** 継続
- 変更箇所を以下 3 点に限定:
  1. 新規シナリオ `scenarios/silence-cut/` 追加
  2. `render.sh` 内で silencedetect → awk 解析 → concat demuxer の 2 パス実装
  3. SAC=1 を守るため編集ロジックは `silence-cut/render.sh` 内に閉じ込める
- 残 6 論点（Editor sub-agent、波形可視化、hyperframes、長尺対応、AI 統合、video-use 3 機能）は **3 カテゴリに明示分類** + 再検討トリガー設定
- v2 DoD: 「silence-cut が 4 シナリオ同等品質で動作」の 1 項目のみ
- 品質ゲート: `shellmetrics` による CC ≤ 10 監視を CI 組込

**根拠**: technical (SAC=1 完全準拠) / cost (最低 3〜4 タスク/1 dev_phase) / alternatives (即効性) / risk (委譲 + CC 監視で形骸化予防) / purity_vs_capability (A 堅持で再現性最大化) / scope_discipline (DoD 最小化で完遂確率最大化) ——**6 視点全てが支持する唯一の解**

**残存リスク**:
- ffmpeg パラメータ（dB 閾値・最小無音長）がコンテンツ種別で大きく変わる → チューニング工数
- 2 パス処理の awk 動的生成で `render.sh` が CC > 10 超過リスク → 委譲分割で閉じ込め
- 『ffmpeg ラッパーに過ぎない』と評価される可能性 → v2 完了時に v3 候補ロードマップを明示
- 先送り判断ミス時のコスト跳ね上がり（2.5x〜）→ 月次レビューで検知

### 5.2 Fallback（段階的退路）

**トリガー**（いずれか 1 つ発生）:
- `render.sh` の CC > **15**
- silencedetect 出力パース失敗率が検証 10 本で **> 20%**
- 2 パス処理の awk 実装が **> 200 行**

**アクション**: 依存方針を **B（シナリオ局所許可）** に段階的シフト
- `scenario.json` に `requires: {tools, python_packages, min_ffmpeg_version}` 追加
- `silence-cut/` dir 内で direnv/venv 相当の局所化（`PATH=$SCENARIO_DIR/bin:$PATH`）
- **他シナリオへの波及は禁止**、silence-cut のみの局所例外として運用

### 5.3 Abort（撤退条件）

v1 実利用データ収集の結果、**『improvements を積む v2』より『削る v2』が実利用価値を生む**と判明した場合、v2 を撤退して v1 の使用率低機能削除 + `scenario.json` スキーマ簡素化に転換。撤退の機会コストは『1 シナリオ追加の遅延』に限定され構造的損失は小さい。

---

## 6. 実装基準（Implementation Criteria）

### 6.1 Layer 1（ユニット・lint 6件）

| ID | 内容 | 代表コマンド |
|---|---|---|
| L1-001 | silence-cut ディレクトリが SAC=1 準拠（scenario.json + render.sh のみ） | `test -f ... && jq -e '.name=="silence-cut"' ...` |
| L1-002 | shellcheck `-S error` で警告ゼロ、disable ≤ 3 件 | `shellcheck -S error scenarios/silence-cut/render.sh` |
| L1-003 | shellmetrics で全関数 CC ≤ 10、総行数 < 250 | `shellmetrics ... \| awk 'NR>1 && $NF+0>10'` |
| L1-004 | 依存方針 A 違反なし（requirements.txt / package.json 新規なし） | `! git diff --name-only origin/main \| grep -E ...` |
| L1-005 | silencedetect パース `.bats` ユニットテスト | `bats scenarios/silence-cut/tests/parse-silence.bats` |
| L1-006 | SCOPE.md に 3 カテゴリ + 6 論点 + 再検討トリガーが存在 | `grep -q '## v3 候補' SCOPE.md && ...` |

### 6.2 Layer 2（統合・E2E 3件）

| ID | 内容 |
|---|---|
| L2-001 | 30s fixture（無音 3 箇所）で render.sh 正常終了、出力 mp4 生成 |
| L2-002 | 既存 4 シナリオ + silence-cut の **5 シナリオ同型動作** |
| L2-003 | 10 本サンプル（講演/会話/環境音/BGM）でパース失敗率 **< 20%** |

### 6.3 Layer 3（受入 4件）

| ID | 戦略 | 成功閾値 |
|---|---|---|
| L3-001 | `cli_flow` | `output.duration < input.duration * 0.95` かつ video=1 / audio=1 |
| L3-002 | `structural` | ffprobe JSON: duration > 0, codec ∈ {h264,hevc} / {aac,mp3,opus} |
| L3-003 | `llm_judge` | Claude 評価 ≥ **0.80**（3 カテゴリ網羅性・トリガー具体性・DoD 最小化・A 明文化・中間状態回避宣言） |
| L3-004 | `api_e2e` | 5/5 シナリオ連続実行で全 pass |

### 6.4 Dev Phases

| Phase | Goal | 対象 L1/L2/L3 | Mutation 閾値 |
|---|---|---|---|
| **mvp** | silence-cut 最小骨格動作、1 本生成 | L1-001, L1-004, L1-005, L2-001, L3-001 | 0.4 |
| **core** | 5 シナリオ同型、パース信頼性検証 | L1-002, L1-005, L2-002, L2-003, L3-002, L3-004 | 0.3 |
| **polish** | 品質ゲート全通過 + SCOPE.md 完備 + エッジケース回帰 | L1-002, L1-003, L1-006, L3-003 | 0.2 |

---

## 7. 結論

**make-video v2 は『1 シナリオ追加（silence-cut）× 純粋 bash 堅持 × DoD 最小化 × 6 論点の明示的先送り』で完結させる**。

この判定は 6 視点すべてが一致して支持する唯一の解であり、ロック決定（v1 延長 / Forge 同型維持 / SAC=1 維持）と完全整合する。Second-System Effect と中間状態リスクを構造的に回避し、v1 の成功パターン（text-to-video が本体変更ゼロで動いた実証）を再適用する。

依存方針 B への漸進的退路は Fallback として定量トリガー（CC > 15 / パース失敗率 > 20% / awk > 200 行）で保持し、『削る v2』への撤退は Abort オプションとして残す。

---

## 8. 残された調査ギャップ（Gaps）

- `Editor sub-agent` の具体仕様（Claude API 型 vs ローカルモデル型）未確定
- `video-use` の `pack_transcripts / transcribe_batch / timeline_view` の正確な関数仕様
- make-video v1 の既存コードベース規模（シナリオ数・render.sh 行数）
- FFmpeg 8.0 Whisper 統合の安定性（transcribe_batch の Python 依存回避可能性）
- Whisper.cpp の 2026 年最新 GPU ベンチマーク
- hyperframes の HeyGen API キー要否（ローカル完結可否）
- Forge 固有の依存追加コスト定量化（development.json / circuit-breaker.json 拡張負担）
