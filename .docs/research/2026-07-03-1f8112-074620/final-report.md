# bash ユニットテストフレームワーク比較（bats-core vs shunit2）— Forge Harness 適合性調査

**リサーチ ID:** `2026-07-03-1f8112-074620`
**モード:** explore（参考としての小規模調査 / 採用ロック決定ではない）
**生成日:** 2026-07-03
**テーマ:** bash シェルスクリプト向けユニットテストフレームワークの比較（bats-core vs shunit2、派生候補 ShellSpec を含む）を、Forge Harness のテストスイート改善の参考として調査する

---

## 1. エグゼクティブサマリー

本件は「**bats か shunit2 か**」という二択ではなく、**〔現状維持（custom `test-helpers.sh`）— 部分ハイブリッド — 全面移行〕のスペクトラム上の選択**である。決定を左右するのは一般的な機能比較ではなく、本ハーネス固有の3要因だった。

| # | 決定要因 | 要旨 |
|---|---|---|
| 1 | **Windows/MSYS 生存性**（最重要） | bats-core は Git Bash 上で高確度の具体的失敗を多数抱える。shunit2 は Windows サポートが暗黙的で未検証。ShellSpec のみ Windows を CI で明示テスト。**この軸だけで採否を決めうる。** |
| 2 | **純増分の希薄化** | フレームワークの便益（隔離/discovery/mock/parallel/レポート）の大半は、直近バッチ #5 で投資済みの custom 基盤が既にカバー。純増分は小さい。 |
| 3 | **コストの非対称** | 導入・移行・CI 配線・依存更新は shunit2（単一ファイル vendoring・純 bash・外部依存ゼロ）が明確に軽い。 |

### 最終結論

> **全面移行は現時点で正当化されない。** custom `test-helpers.sh` を backbone として維持しつつ、フレームワーク採否を決める前に**安価な Windows-MSYS PoC（半日〜1日の時間箱）で生存性を実証**する。その結果と「新規テストが手動 `mktemp` 隔離を超える隔離を本当に要するか」の2点を確認できた場合に限り、**新規テストのみに限定した可逆な部分採用**を検討する。

さらに、いずれのフレームワークを採るにせよ、本ハーネス固有の防御価値である **「無機能化テスト検出（assert 数検証）」には native 等価物がなく、grep 監査の上乗せ層として温存が必須**（移行の是非より優先度の高い不変条件）。

---

## 2. 調査の背景とスコープ

### 核心的な問い

- 記述スタイル・アサーション API・setup/teardown・依存/インストール形態・出力形式（TAP/JUnit）・並列実行の各面で bats-core と shunit2 はどう異なるか
- Windows / MSYS2 / Git Bash 環境（本プロジェクトは **CRLF 破損** と **`/tmp` パス分裂**の実害履歴あり）で両者は確実に動くか
- 既存 custom テスト基盤（opt-in ERR trap、assert 数/完了マーカー検証、curated + 自動 discovery）にどうマッピング・共存できるか
- そもそもフレームワーク導入は正当化されるか（単独開発者 + LLM エージェント実行という運用主体での ROI）

### スコープ境界

- **深さ:** 機能マトリクス + Windows/MSYS 互換性 + 移行/共存パスの3層まで。内部実装詳細・網羅的エッジケース・実 PoC 実装は範囲外。
- **広さ:** bats-core と shunit2 を主軸に、ShellSpec 等を「現状維持 or 他選択肢」の観点で軽く言及。
- **過去決定との関係:** 直近バッチ #5（`d-20260612-222522`）で custom テスト基盤に投資済み。本件は explore モードのため直接のブロッキング矛盾ではないが、「既存投資と共存/段階採用できるか」を必須の評価軸に含めた。

### 調査視点（6視点）

| 種別 | ID | 焦点 |
|---|---|---|
| 固定 | `technical` | 技術的実現性 |
| 固定 | `cost` | コスト・リソース |
| 固定 | `risk` | リスク・失敗モード |
| 固定 | `alternatives` | 代替案・競合 |
| 動的 | `windows-msys-compat` | Windows / MSYS2 / Git Bash 環境での運用堅牢性 |
| 動的 | `migration-integration-fit` | 既存 custom テスト基盤との構造的適合・段階採用性 |

> 動的視点2つは、本プロジェクトが CRLF 破損・`/tmp` パス分裂という Windows 固有の実害を繰り返し踏んできた履歴と、opt-in ERR trap・assert 数検証といった固有規約を持つことから、一般的な technical/risk とは別軸として切り出された。

---

## 3. 候補フレームワーク一覧

| フレームワーク | 記述スタイル | 導入形態 | Windows/MSYS | 特徴 |
|---|---|---|---|---|
| **bats-core** | 独自 DSL（`@test { }`、`.bats`） | 本体 + ヘルパ（bats-support/assert/file）を submodule | ⚠ 落とし穴が集中、公式 CI 明文なし | 運用機能（`$BATS_TEST_TMPDIR` 隔離・並列・TAP/JUnit・timeout）が箱出しで充実 |
| **shunit2** | 純 bash 関数 + `source` | 単一ファイル vendoring（外部依存ゼロ） | ⚠ 暗黙的・未検証、trap 依存にリスク | 統合が最も素直・xUnit 系アサーション・移植性広い |
| **ShellSpec**（fallback） | 独自 DSL（非 pure bash） | パッケージ/インストーラ | ✅ Git bash/msys2/cygwin/WSL を CI で明示テスト | Windows 最堅牢だが学習コスト高、Claude 編集ワークフローとの相性に留保 |

その他の派生候補（`bashunit` は Windows=WSL 前提で Git Bash 対応が不透明、`bash_unit` は strict mode 互換に難、`shpec` は subset 実行非対応、`assert.sh`/`roundup` は情報が薄い）は軽い言及に留めた。

---

## 4. 視点別サマリー

### 4.1 技術的実現性（technical）

| 観点 | shunit2 | bats-core |
|---|---|---|
| 既存 bash + jq + run_claude 統合の素直さ | ✅ 「純 bash + source」で最も溶け込む | △ DSL 配下で「載せる」形 |
| setup/teardown・アサーション | xUnit 系（`setUp`/`oneTimeSetUp`、`assertEquals`/`assertTrue`） | `setup`/`teardown` + `run`ヘルパ（$status/$output）、リッチ assert は拡張前提 |
| `/tmp` 隔離 | ✗ 手動 `mktemp` が必要 | ✅ `$BATS_TEST_TMPDIR` が箱出しで強い |
| TAP/JUnit・並列・timeout | ✗ いずれも無し | ✅ `--tap`/JUnit・`--jobs`・`BATS_TEST_TIMEOUT` |
| POSIX 互換 | ✅ bash/ksh/mksh/zsh | ✗ bash-only |

**要点:** 「既存資産への統合の素直さ・移植性」は shunit2、「テスト隔離と運用機能の箱出し充実度」は bats。ただし本ハーネスは運用層を既に `run-all-tests.sh` で自作済みのため bats の運用機能は増分が限定的。**注意すべき罠:** bats の `run` は jq パイプと相性が悪く（終了コードを飲み込む）、`bats_pipe` かサブシェルでのラップが必要。

### 4.2 コスト・リソース（cost）

| コスト項目 | 有利なフレームワーク |
|---|---|
| 最小導入手数 | **shunit2**（1ファイル vs 複数 submodule） |
| 移行の書き換え粒度 | **shunit2**（アサーション行の置換中心）／bats は `.bats` DSL への構造的リライト |
| 学習コスト | **shunit2**（既存 bash 知識を流用）／bats は DSL 習得が必要 |
| CI 配線・日々の依存更新 | **shunit2**（source するだけ） |
| フレームワークの活性度・将来性 | **bats-core**（v1.11〜v1.13 と定期リリース） |

**要点:** 短期の導入・移行・運用コスト最小化なら shunit2、初期投資と引き換えに長期の保守供給・エコシステム・可読性を取るなら bats、という非対称トレードオフ。単独開発者 + LLM 運用という前提では**コスト面の総和は shunit2 側に傾く**。
※ 実テスト本数・`test-helpers.sh` の依存構造は Web 調査では取得不能のため、移行工数の定量（人時）見積りは未算出（gap）。

### 4.3 リスク・失敗モード（risk）

bats-core の警戒点（確度の高い順）:

1. **Windows/Git Bash 非互換（最優先・確度 high）**
   - パス変換失敗 → `bats-exec-suite: not found`（#424）
   - `/dev/fd/62: No such file or directory`（#256/#323）
   - `run bash -c "... | ..."` のパイプ解析破綻 → status 127
   - file stat 揮発による file-integrity テストの偽陽性
   - CRLF/シェバン破損
   - `--jobs` 並列は GNU parallel 非同梱で実質利用困難
2. **保守（bus factor 実質1・確度 high）** — 2024-11 に主要メンテナが減速・凍結懸念を公表（Discussion #1023）。ただし 2025 年も v1.12（2025-05）/v1.13（2025-11）と約半年間隔でリリース継続。「今日は能動的、明日は脆弱」というテールリスク。
3. **DSL ロックイン（確度 medium）** — `@test` 独自構文だが、`function_name { # @test }` の valid-bash 代替構文・shellcheck/shfmt 対応・bats-backports で緩和可能。中身は素 bash のため撤退コストは相対的に低い。
4. **既存 lint/機械ゲートとの干渉・二重化（確度 low）** — 一般論からの推論に留まり、ハーネス固有の実挙動は未検証。

### 4.4 代替案・競合（alternatives）

- フレームワークの純増分（isolation/discovery/mock/parallel/標準レポート）は、`test-helpers.sh` の既存カバー範囲に強く依存する。
- 「Bash `[[ ]]` で十分・**ツールより規律（discipline）**」という反証も同程度に強い。
- 「フレームワーク不要が妥当となる条件」= 対象が **小規模・モジュール化済み・高度機能不要・規律維持可能・既存 discovery で代替済み**という低要求域に留まる限り。→ **本ハーネスはこの低要求域に該当**。
- ハイブリッド共存は BATS の `bin/test` ラッパ + TAP/JUnit 接続という定石で技術的に成立するが、二重書式・二重ランナーの保守負担を伴う。

### 4.5 Windows / MSYS2 / Git Bash 運用堅牢性（windows-msys-compat）

**3フレームワーク間に明確な序列がある。**

| フレームワーク | Windows 対応の厚み |
|---|---|
| **ShellSpec** | 最堅牢。Git bash/msys2/cygwin/busybox-w32/WSL を GitHub Actions CI で**明示テスト**、シェル組込み依存の移植性設計 |
| **bats-core** | 「動作する」とされるが issue に落とし穴が集中（libexec PATH、/dev/fd、Cygwin bash ハング、パイプ解析破綻）。公式 Windows CI の明文なし |
| **shunit2** | 暗黙的サポート。クリーンアップ/レポートを EXIT/INT/TERM **trap に強依存**する設計が MSYS 上で潜在リスク |

**全フレームワーク横断の最大共通リスク = CRLF/シェバン破綻**（`/bin/bash^M: bad interpreter`）。対策として **`.gitattributes` の `*.sh text eol=lf` 強制が必須級の前提**。次点が MSYS パス変換（`MSYS_NO_PATHCONV=1` / `//` プレフィックスで回避）と `BATS_TMPDIR` の非隔離によるラン間汚染（#226/#283）。

**既存運用制約との整合:** OneDrive 外配置・ツール系統統一は、純 bash テストが一時ファイル操作を MSYS bash 系統に閉じられる限り**むしろ整合的**。逆に OneDrive 配下はパスのスペース/日本語/特殊文字が MSYS パス変換破綻を招くため、既存方針が妥当。

### 4.6 既存基盤との構造的適合・段階採用性（migration-integration-fit）

| 既存機構 | フレームワークでの再現性 |
|---|---|
| opt-in ERR trap | △ bats は常時 `errexit`（opt-in ではなく強制） |
| 完了マーカー/終了コード | ✅ TAP + 終了コード + `--count` で代替可 |
| **assert 数検証（無機能化テスト検出）** | ✗ **native 等価物なし。むしろ bats の `run` が「$status 未チェックで黙って成功する no-op テスト」を新規に生む** |
| discovery（curated + DISCOVERY_EXCLUDE） | ✅ `bats -r`/`--filter-tags` とラッパー層で共存可能（option A） |
| 関数 source + PATH スタブ + `/tmp` 隔離（配線テスト） | ✅ むしろ `$BATS_TEST_TMPDIR` で隔離強化。test-l2-wiring 型はクリーンに移植可 |

**可逆性:** 据え置いた既存資産は**完全に可逆**、`.bats` へ書き換えた分は**非対称**（戻すには再書き換えが必要）。valid-bash `#@test` 形式で書けば可逆性を緩和できる。

**推奨構成:** 「新規のみ framework + legacy 据え置き + トップランナー（`run-all-tests.sh`）が両方集約」が最も低リスク。

---

## 5. 視点間の矛盾とその解決

| 対立視点 | 対立の内容 | 解決 |
|---|---|---|
| technical vs cost | bats の運用機能 高評価 ↔ shunit2 の低コスト 高評価で結論が逆に見える | 評価軸の重み付けの差。運用層は既に自作済みのため bats の増分は小。残る差は「隔離の堅牢さ（bats）」vs「統合の素直さ・最小コスト（shunit2）」に収斂し、本文脈では shunit2 寄り |
| technical vs windows-msys-compat | `$BATS_TEST_TMPDIR` は「手動隔離より堅牢」↔「親 BATS_TMPDIR 非自動クリーン・Windows 解決先未特定」 | 両立。Linux では原理的に強い隔離だが、Windows 実環境での実測確認まで**隔離便益は条件付き** |
| cost vs risk | bats は「定期リリースで将来性優位」↔「bus factor 1 で中〜高リスク」 | 両者とも事実として整合（「少人数で辛うじて継続」）。全面移行には割引、可逆な部分採用にはほぼ無影響 |
| alternatives vs technical | テーマは bats vs shunit2 の二択 ↔ ShellSpec が Windows 生存性で最優位 | ShellSpec を第三の有効候補として公平に俎上に。ただし DSL コストは bats 級のため fallback に留める |
| alternatives vs migration-fit | framework はテスト品質を上げる ↔ assert 数検証で**後退**する | framework はアサーション表現力・レポートを向上させる一方、「テストが実際に検証しているか」では後退。**assert 数検証を上乗せ層として温存が必須**という条件付きで両立 |

---

## 6. 推奨（Primary / Fallback / Abort）

### 6.1 Primary（第一推奨）

> **全面移行はしない。** custom `test-helpers.sh` を backbone として維持しつつ、framework 採否の判断前に**時間箱（半日〜1日）の Windows-MSYS PoC** を実施する。

PoC は本ハーネスの実環境（Git Bash/MSYS、CRLF、`/tmp` 系統、jq パイプ、claude -p 非モックの配線テスト1本）で、以下を課す:

- (a) `.gitattributes` に `*.sh text eol=lf` を強制
- (b) `MSYS_NO_PATHCONV` / `//` プレフィックスでパス変換破綻を回避
- (c) `--jobs` は使わない（GNU parallel 非同梱）
- (d) `/dev/fd` プロセス置換と `BATS_TMPDIR` の Windows 解決先を実測
- (e) `run` + jq は `bats_pipe` かサブシェルでラップ
- (f) `$status` を必ず明示チェック

**判断基準:** PoC の合否と「新規テストが手動 `mktemp` 隔離を超える隔離を本当に要するか」の2点で、初めて部分採用の是非を判断する。

**根拠:** 採否を単独で決めうる軸が Windows/MSYS 生存性であり、そこが bats 最弱・shunit2 未検証という状況で framework を先に確定するのは、本プロジェクトが CRLF/パス分裂で繰り返し踏んできた失敗モードそのもの。まず安価に生存性を実証する順序が最もリスク調整後リターンが高い。

**残存リスク:**
- PoC が「概ね動く」と出ても、別種失敗（file stat 揮発による偽陽性、並列非使用でのテスト時間増）が実運用で顕在化しうる
- custom 基盤の維持継続は、標準 TAP/JUnit レポートやコミュニティ保守アサーションを得られない機会損失を伴う
- PoC の実行者が LLM エージェントの場合、`run`/`$status` の罠で「黙って成功する」テストを生む二次リスク → **assert 数検証の上乗せ層で機械的に捕捉が必要**

### 6.2 Fallback（条件付き次善策）

PoC で framework が MSYS 上で生存し、かつ新規の配線/振る舞いテストに手動隔離を超える要件があると確認できた場合に限り、**「新規テストのみ framework 採用 + legacy 据え置き + `run-all-tests.sh` を上位ラッパとして両方集約（option A 共存）」**の段階採用へ進む。

- 統合の素直さ・最小コストを優先 → **shunit2** を単一ファイル vendoring で純 bash ユニットテストに
- テスト毎隔離の堅牢さを優先 → **bats** を配線テストに
- bats が Windows PoC で落ち ShellSpec が通る場合 → DSL 学習コストを受容して **ShellSpec** を配線テスト層に

いずれも共通条件: (1) assert 数検証を grep 監査として温存、(2) bats は valid-bash `#@test` 形式で可逆性を確保、(3) `.gitattributes eol=lf` と `MSYS_NO_PATHCONV` を前提化、(4) `--jobs` 無効。

**トリガー:** PoC が対象 framework の MSYS/Git Bash 上での生存を実証し、かつ新規テストに `$BATS_TEST_TMPDIR` 級の自動隔離が実利をもたらすと判断できた時点。逆に PoC 失敗、または手動 `mktemp` 隔離で十分なら Abort へ回帰。

### 6.3 Abort（撤退＝現状維持）

いずれの framework も採用せず、custom `test-helpers.sh` を継続改善する（xUnit 風アサーションヘルパ・`mktemp` 隔離ヘルパの薄い追加、assert 数検証・完了マーカーの強化）。

本ハーネスは「小規模・モジュール化済み・単独開発 + LLM 運用・既存 discovery で代替済み」という **framework 不要が妥当となる低要求域**に該当。実課題（サイレント死・NULL 検出漏れ・CRLF 破損・機械ゲート素通り）の根本原因は framework の不在ではなく**テスト規律/ゲート設計側**であり、これは #5 が既に対処済み。

**機会費用:** 標準 TAP/JUnit レポート、箱出しのテスト毎隔離、コミュニティ保守アサーション、xUnit 経験者のオンボーディング容易性を放棄する。ただし CI マトリクスを持たない単独メンテナのリサーチハーネスでは価値が低く、機会費用は限定的。

### 過去決定との整合

- **整合:** バッチ #5 の custom 基盤投資を温存し、回帰保護を先行させる #5 の順序原理と一致。MEMORY.md の Windows 実害履歴とも符合。「全コンポーネントはモデル欠陥への仮説」原則（実在の欠陥を実証的に解消する場合のみ追加）とも整合。
- **緊張関係:** framework 全面移行は #5 で構築した assert 数検証・ERR trap・完了マーカー層を陳腐化させ投資と競合。bats の `run` は #5 が根絶しようとした「サイレント死/無機能化テスト」を再導入する方向に働く。→ Primary が全面移行を採らないことで回避。

---

## 7. リスク指摘（Devil's Advocate — R1）

> DA 判定: **CRITICAL 反証なし**。Primary は保守的・可逆・PoC 先行のヘッジ済み推奨であり「これに従うと失敗する」という証拠つき反証は成立しない。ただし実装前に対処すべき2点を指摘。

| ID | 深刻度 | 指摘 | 解消条件 |
|---|---|---|---|
| **DA-001** | **HIGH** | Synthesis 自身が「Windows/MSYS 生存性が採否を単独で決めうる決定軸」と明言しながら、その軸で**最弱と断定された bats-core を PoC 初手に据え、証拠最強の ShellSpec を fallback に落としている**。結果、(a) 最も落ちやすい候補で PoC を始めるため「framework は MSYS で動かない」という結論にバイアスしやすく、(b) 証拠最強の ShellSpec と、もう一方の shunit2（Windows 未検証）が初回 PoC に含まれず、複数回 PoC を要して「安価さ」という前提が崩れうる | PoC 対象選定の根拠を明示（bats を先に検証する理由 = テーマ主候補の go/no-go、ShellSpec を初回に含める/含めない判断、shunit2 の位置づけ）。あるいは Primary を「ShellSpec を含む複数候補を同一 PoC で並行検証」へ修正 |
| **DA-002** | **MEDIUM** | 「framework の純増分は #5 の custom 基盤でカバー済みで小さい」という Primary の主要根拠は、**現行 `test-helpers.sh`/`run-all-tests.sh` の実装を直接確認していない**（2視点が明示留保）。decision log #5 の投資記録を代理証拠に確度高く断定しており、確度が源データの支える以上に高く提示されている（推奨自体は他根拠でも成立） | 実 `test-helpers.sh`/`run-all-tests.sh` を読み、isolation/discovery/reporting の既存カバレッジを列挙して実装ベースで裏付ける（未カバー領域があれば framework 便益を再評価） |

### 未解決の不確実性（DA unknowns）

- bats のリリース履歴に視点間の日付不整合あり（cost: v1.12=2024-05/v1.13=2024-11 ↔ risk: v1.12=2025-05-18/v1.13=2025-11-07）。Synthesis は risk 側を採用。Primary の是非には影響しない
- shunit2 の trap 依存クリーンアップ/レポートが MSYS 上で実際に破綻するかは、リスク推論に留まり実障害報告を取得できていない
- `BATS_TMPDIR`/`mktemp` が Windows(MSYS) で `/tmp` を AppData\Temp のどこへ解決するかの実挙動は未確認（複数視点共通の gap）

---

## 8. 実装計画（PoC）

DA の指摘を踏まえ、`implementation-criteria.json` として **bats-core を主候補とする時間箱 PoC**（半日〜1日、explore モードの参考実証）が具体化されている。

### フェーズ構成

| フェーズ | ゴール | 主な検証項目 | mutation 生存閾値 |
|---|---|---|---|
| **mvp** | 1本の bats サンプルが緑になり、assert 監査が no-op テストを赤にできる最小 PoC | L1-001（TAP/終了コード）、L1-003（assert 数監査） | 0.4 |
| **core** | CRLF 強制・共存集約が整い、Windows 実機で bats 生存テストと claude -p 配線テストが完走 | L1-002（EOL）、L1-004（共存配線）、L2-001（MSYS 生存性）、L2-002（非モック配線） | 0.3 |
| **polish** | エッジ（BATS_TMPDIR 汚染・--jobs 禁止）に対処し、go/no-go 判断レポートが生成 | L1-005（setup lint）、L2-003（tmpdir 実測）、L3-001〜003（レポート検証） | 0.2 |

### 検証基準の要点

**Layer 1（構造/lint）**
- **L1-001:** bats PoC が終了コードと TAP を決定的に返す。`run` の `$status` を明示チェックしなければ検証にならないことを担保
- **L1-002:** `.gitattributes` の EOL 強制 + 作業ツリーに CR 残存なしを静的検証（CRLF 実害履歴への対策）
- **L1-003:** **assert 数検証の上乗せ層** — `.bats` を grep 監査し @test 内にアサーションが1つ以上あるか。framework に native 等価物がないため必須
- **L1-004:** `run-all-tests.sh` 共存配線（option A）。legacy `.sh` と新規 framework テストを1回で discovery・集約し、失敗が全体 exit code へ伝播
- **L1-005:** `--jobs`/`-j` を使わないこと・bats vendoring 済み・`/dev/fd` 直接使用の警告を静的検証

**Layer 2（実環境）**
- **L2-001:** Windows Git Bash/MSYS 実機での bats 生存性（**PoC 本体・決定軸**）。libexec PATH(#424)・CRLF・run+jq(status 127 回避)・一時ディレクトリ・file stat 揮発を実測
- **L2-002:** framework 経由の claude -p 非モック配線テスト1本。`$status`/出力捕捉が MSYS 上で機能するか
- **L2-003:** `BATS_TMPDIR`/`$BATS_TEST_TMPDIR` の Windows 解決先とラン間汚染（#226/#283）の実測。本ハーネスの `/tmp` 系統分裂問題への該当有無を判定

**Layer 3（判断レポート検証）**
- **L3-001**（blocking, structural）: `decision.json` のスキーマ適合を jq で機械検証（checklist 6項目 + 各 verdict + go_no_go + reversibility が非null）
- **L3-002**（blocking, cli_flow）: PoC ランナーが TAP・監査・判断レポートの3成果物を生成
- **L3-003**（non-blocking, llm_judge, 閾値 0.8）: レポートの論理的健全性を L3 Judge が採点（Windows 生存性を決定軸にしているか / assert 数検証を温存しているか / 全面移行を推さず可逆な結論か / 証拠と結論が整合しているか）

> **注:** 本タスクに HTTP サーバー/API は関与しないため、exit_criteria の auto 検証は curl ではなく bash テスト実行で行う。

---

## 9. 残るギャップ・今後の課題

- 現行 `test-helpers.sh`/`run-all-tests.sh` の実装（isolation/discovery/reporting の自前カバレッジ）を一次確認できておらず、「純増分が小さい」の定量判定は未実施（→ **DA-002** の解消作業）
- Windows/MSYS 上での bats/shunit2 の実挙動（GNU parallel 依存の `--jobs`、CRLF 感受性、`BATS_TMPDIR` の解決先）は Web 情報では確証できず、**PoC での実測が必須**
- shunit2 に bats-assert/bats-file 相当のリッチアサーション拡張が存在するかは調べきれていない
- 実プロジェクトのテスト本数が不明で移行工数（人時）の定量見積りは未算出
- 参照した比較ソース（dodie/testing-in-bash, shellspec.info）は評価軸が固定的で、特に shellspec.info は競合作者提供のためバイアス補正の一次裏取りが一部未完

---

## 10. 一言まとめ

**フレームワークは「実在の欠陥を実証的に解消する場合のみ追加する」** という保守姿勢に立つと、本ハーネスの現状は framework 不要が妥当となる低要求域にある。唯一の合理的な次アクションは、**採否を左右する Windows/MSYS 生存性を安価な PoC で先に潰すこと**。全面移行というコミットは、その実測なしには正当化されない。
