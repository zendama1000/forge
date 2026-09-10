# Pinterest 画像自動ダウンローダー CLI（ppp-downlorder）実装方式リサーチ — 最終レポート

- **リサーチ ID**: `2026-09-10-1cf16b-070732`
- **テーマ**: gallery-dl をラップした Pinterest 画像自動ダウンローダー CLI の実装方式決定（実装言語・呼出方式 / 保存構造 / 重複排除 / 新着差分 / 定期実行 / cookie / レート制御 / メタデータ / 既知 issue / オフライン検証 の 10 領域）
- **構成**: Scope Challenger → 6 視点並列リサーチ（固定4 + 動的2）→ Synthesis → Devil's Advocate 2 ラウンド → 実装成功条件
- **検証環境**: Windows 11 Pro 26200 / gallery-dl **1.32.11**（`uv tool install` 済み・実機実測あり）

---

## ⚠ 最初に読むべき警告 — この成果物はそのまま実装フェーズへ渡せない

Devil's Advocate ラウンド 2 が **機械的に確認した事実**:

| 項目 | 状態 |
|---|---|
| `synthesis.json` の md5 | round1 と**完全一致**（`cd7bd1e6…`）= 1 バイトも更新されていない |
| 6 視点レポートの md5 | **全て変化**。各視点が「[DA-001 対応]」finding を新設し**実機検証まで実施** |
| `synthesis.feedback_response` | **空配列** `[]` |
| DA round1 の指摘 7 件 | **7 件すべて未解消**（`resolved: false`） |

つまり **再調査は実行されたが、その結果が Synthesis に取り込まれていない**。以下の本文では、Synthesis（＝ round1 相当）の結論と、round2 で実測された反証を**両方**併記する。実装着手前に、後述「実装前に必ず決着させる 4 点」の解決が必要。

---

## 1. エグゼクティブサマリ

### 1.1 5〜6 視点が完全収斂した中核判断（異議なし・即採用可）

| # | 決定 | 根拠 |
|---|---|---|
| A | **Python 3.13 + subprocess** で薄いラッパーを実装 | Node は gallery-dl の Python 依存を消せず SQLite ネイティブモジュール問題を追加するだけ。Python API import は公式 API 不在（issue #642 が 6 年 open）・設定がモジュールグローバル・GPLv2 派生物リスク |
| B | **archive-format の明示固定は必須要件**（最適化ではない） | 4 視点が独立に `pinterest.py` の同一欠陥を発見: 基底は `{id}{media_id\|page_id}` だが Board/Section/RelatedBoard だけ `{board[id]}_{id}` に上書き。**既定のままだと同一ピンが所属ボードごとに再 DL される**（round2 で実機再現済み） |
| C | **ハーメティック設定**（`--config-ignore` + プロジェクト `config.json` を `-c` + 可変スカラーのみ `-o`） | `%APPDATA%/gallery-dl/config.json` の既定探索がユーザー環境で挙動を静かに変える。`schtasks.exe` の 255 文字制限とも整合 |
| D | **定期実行 = schtasks 登録サブコマンド + 単発実行モードのハイブリッド** | 常駐スケジューラは再起動・スリープに最弱、工数も 200〜400 LOC vs 50〜120 LOC。APScheduler 自身が「デーモンでもサービスでもない／未実行分の記憶なし」と公式に自認。先行事例 = resticprofile |
| E | **cookie は cookies.txt 主・ブラウザ抽出（実質 Firefox のみ）補助** | 作者 mikf が #6162 で「Chrome の App-Bound Encryption により Windows では恒久的に壊れる見込み」と明言。実機でも Chrome/Edge とも DB ロック（PermissionError）+ v20 鍵で復号不能を確認 |

### 1.2 最重要の発見 — 脅威は「落ちること」ではなく「成功したフリで静かに劣化すること」

risk / operability / testability の 3 視点が**独立に**同じ結論へ到達した。gallery-dl の Pinterest 経路には **exit 0 のまま中身が欠ける経路が 5 本以上**存在する。

| 経路 | 実体 | 検知可能性 |
|---|---|---|
| archive がファイル実体を見ない | `job.py:431` で `archive.check()` がファイル存在チェック**より先**に走る。記録済み ID のファイルが削除・0 バイト・破損でも**永久に再取得されない** | ラッパーの `reconcile` でのみ検知可 |
| ページング握り潰し | `PinterestAPI._pagination` がカーソル取得を `try/except KeyError: return` で囲む → API 形状変化で**1 ページ目だけ取って正常終了**。警告もログも出ない | 件数ベースライン / カナリアでのみ |
| 0 件成功 | `exception.py` に「0 ファイル」を表す終了コードが存在せず、空結果は **exit 0** | 外部でのみ |
| fallback の偽装成功 | fallback URL が成功すると低解像度の代替物が本命と同名で `archive.add` される（Codeberg #102）。`extractor.*.fallback=false` で失敗を失敗として鳴らせる | 設定で対処可 |
| `--simulate` の地雷 | skip イベント下で 1 バイトも落とさずに**全件を済み扱い**にできる。ドライラン実装時の致命的地雷 | 負テストで固定 |
| cookie の fail-open（round2 新発見） | 壊れた cookies.txt（CRLF が最終フィールドに CR を残す / BOM が domain を汚す）が**警告すら出ないまま cookie 無しで走る**。exit 16 も出ない | fail-closed 化が必須 |

> **帰結**: ラッパーの主価値は「ダウンロード制御」ではなく **「ランタイム台帳 + 実体照合 + 異常検知」** にある。撤退案（gallery-dl 素の運用）で失われるのはダウンロード機能ではなく **「壊れたことに気づく能力」**。

---

## 2. 調査の前提

### 2.1 ロック済み決定（再検討対象外）

CLI 形態（GUI/Web UI なし） / gallery-dl ラップの採用 / 公式 Pinterest API v5 と自作スクレイパーの不採用 / 4 入力単位（board・search・user・pin）の全対応 / Windows 11 前提 / cookie 対応必須 / cookie 非コミット / 実通信テストの deferred 可＋オフライン L2 必須

### 2.2 露出された暗黙前提（11 件のうち特に重要な 4 件）

- 「新着」が機械的に判定可能 — **Pinterest の返却順が作成日時順である保証はない**（5 視点いずれも一次情報を確認できず）
- 重複の同一性判定単位はピン ID で十分 — **同一画像の別ピン再投稿を重複とみなさない割り切りが暗黙に入っている**（→ DA-001 の火種）
- 「重複排除」と「新着差分取得」は同一メカニズムで兼用できる — 前者は再保存の回避、後者は走査の早期打ち切りで**要件としては別物**
- 個人用途の DL は Pinterest 利用規約・robots.txt 上の許容範囲 — **明文の確認をしていない**（→ risk 視点が反証）

---

## 3. 視点別の調査結果

### 3.1 technical — 技術的実現性

要件の大半は gallery-dl のオプション表現力の内側に収まる（実機 1.32.11 で直接検証）。

- **ネイティブに成立**: 保存構造・命名（subcategory 別 `directory`/`filename`）、Windows の禁止文字・末尾ドット・260 文字制限（`path-restrict auto` / `path-strip auto` / `path-extended` の `\\?\` 付与）、新着差分の早期打ち切り（`--download-archive` + `-A N`、実測で 1 件 skip → 即停止）、archive の保存先移動耐性（`entry TEXT PRIMARY KEY` の単一列でパス非依存）
- **ラッパーが埋めるべき差分は 4 点**:
  1. archive-format が subcategory 依存で不統一 → **明示統一が事実上必須**
  2. 別ピン ID の同一画像を実測再現（後述 §5）
  3. cookie 取得が本機で実際に失敗（Chrome/Edge とも DB ロック + v20 非対応）。**warning で続行する仕様のため fail-fast 化が必要**
  4. `--date-after` 系の日付打ち切りは Pinterest で効かない（`created_at` が文字列で date キー未設定）→ 差分制御は archive + `-A N` か full scan の二択
- **呼出方式**: 実運用例の gallery-dl-server ですら「設定がグローバル変数で並行 DL が問題」として multiprocessing で別プロセス分離している。wall-clock タイムアウトと確実な中断は subprocess でしか担保できない（`.part` 既定 true のおかげで kill しても完成ファイルは壊れない。ただし `archive-mode: memory` は避ける）

### 3.2 cost — コスト・リソース

**コスト構造は「開発工数」ではなく「時間（レート制御）」が支配的**。

| 指標 | 実測値（1.32.11 / Windows 11 / 2026-09-10） |
|---|---|
| 抽出レート | 25 ピン/API コール |
| 100 ピン metadata 抽出 | `sleep-request=0` で 4.1〜4.7 秒 / `=1.5` で 8.27 秒 |
| DL 込み | 12 ピン・10.88 MB で 6.0 秒 |
| 再実行（全件 skip） | 4.32s → **1.46s** |
| 画像容量 | round1: 平均 0.89 MB / 中央値 0.27 MB（PNG 3 件が総量の 73%）／round2: 中央値 105 KB・JPEG 平均 150 KB ← **食い違いあり（DA-005）** |
| メタデータ JSON | 10.6 KB/件 = バイト影響 **1.2%**。ただし**ファイル数が 2 倍** |
| archive SQLite | 36 bytes/エントリ（10 万件で 3.6 MB）= 無視できる |
| プロセス起動 | 0.36〜0.84 秒 = sleep に比べ無視できる |
| dHash 計算 | 10.7〜40.8 ms/枚（1 万枚で 2〜7 分の一度きり） |

- 500 ピン初回全取得: round1 ≒ 29 分 / round2 ≒ 17〜40 分（**いずれも 12 件実測からの線形外挿**）
- 継続コスト: gallery-dl は 6 か月で 12〜14 本リリース（月 2.7 本）。**月次 bump + スモークで 15〜60 分、年数回の破壊対応（半日規模）**
- 言語選択は初期セットアップコストでは差がつかない（`uv tool install gallery-dl` は 6 パッケージ・12 MB・161 ms）

### 3.3 risk — リスク・失敗モード

- **ban リスクは既定値そのものが問題**: `pinterest.py` に既定のリクエスト間隔が**一切ない**（`sleep-request` 既定値テーブルに pinterest の記載なし = 0。instagram は 6〜12 秒）。無設定運用は内部 API の無間隔連打になる → **最大かつ最も修正容易な発見**
- **重複排除の 2 種の誤りは非対称**: archive は追記のみで「未取得」を表現できず、一度済み扱いになると**永久欠損**。過剰再取得は帯域を払えば回復するが、取りこぼしは自己修復しない
- **cookie は risk transfer**: ペナルティを IP からアカウントへ移す。#5532 では gallery-dl の search スクレイプで本アカウントと予備アカウントが凍結された（Twitter/X 事例）
- **法務**: Pinterest ToS は自動的手段によるデータ取得を明示禁止（express prior permission がない限り）。robots.txt は `User-agent: * → Disallow: /`。判例は「CFAA では守られるが契約では守られない」に収束（hiQ は CFAA で勝ち契約で敗訴し $500k・恒久差止・コーパス破棄／Meta v Bright Data はログオフ公開データについて Bright Data 勝訴）。**cookie を付けた瞬間に「自分が受諾した契約を破っている」側に確定する**
- **日本法**: 2021-01 施行の改正著作権法 §30(1)(iv) により、違法アップロードされた静止画をそうと知りながら DL する行為は私的利用でも違法（「軽微＝低画質・ごく一部」は除外）。**原寸一括アーカイブは軽微の除外に当たらない**
- **セキュリティ**: cookies.txt は MFA を素通りする bearer 資格情報。Chrome の App-Bound Encryption はまさにその読み出しを止めるために導入されたので、手動エクスポートは OS の保護を自ら外す行為

### 3.4 alternatives — 代替案比較

| 選択問題 | 結論 |
|---|---|
| 言語 × 呼出方式（4 組合せ） | **Python + subprocess** が 5 軸中 3 軸で明確優位。CLI が唯一の文書化された契約、`exception.py` の code 定数で失敗を機械分類可、境界が argv/stdout/exit code の 1 点なのでオフライン fixture が素直 |
| 重複排除 3 案 | 単独最小 = archive のみ、実質十分 = **archive + 事後ハッシュ**。ただし `archive-format={filename}` という**中間ティア**が存在（§5） |
| 定期実行 2 案 | ハイブリッドは「妥当」ではなく**唯一の素直な構成**（単発実行モードがなければ登録もテストもできない） |
| cookie 2 案 | 排他ではない。gallery-dl 自身が `--cookies-export` / `cookies-update` でブラウザ抽出 → cookies.txt の橋渡しを持つ。ただし Windows では優先順位が逆転し **cookies.txt が第一候補** |
| 保存構造 | ソース種別＋所有者を上位に置く安定骨格 + **ファイル名に pin ID を必ず含める** + JSON サイドカー索引。`{board[name]}` をパスに使うと Pinterest 側の改名で**旧ディレクトリが孤児化**（キーは board[id] なので再取得されず旧名フォルダが残置） |
| 設定ファイル vs `-o` | 二択ではなく「既定探索を `--config-ignore` で切りラッパー所有の設定 1 本を `-c`」= **ハーメチック実行が再現性の必要条件**。Windows のシェル別クォート差異も回避 |

- gallery-dl 内蔵の hash post-processor 経由は **issue #6843 が cant-fix でクローズ**されており構造的に不可能

### 3.5 operability（動的視点） — 無人定期実行の運用ライフサイクル

gallery-dl は素材をかなり持っている（ビット OR の終了コード 4/8/16/32/64/128、`handle_url` の `status |= 4` により部分失敗が黙って成功にならない、`.part` + archive による再開）。**ラッパーが担うべき責務は 5 つに絞られる**:

1. **多重起動防止 3 層** — Global Mutex（OS 排他ファイルロック）+ タスクスケジューラの `IgnoreNew` + 実行間隔以下の `ExecutionTimeLimit`。archive は SQLite 単一ライタで `database is locked` が実害として報告済みのため必須
2. **終了コードの再解釈層** — exit 4 に HttpError と NotFoundError が同居するため、コードだけでは環境起因/コンテンツ起因を分離できない
3. **実行台帳** — 1 実行 1 行の JSONL（新規/スキップ/失敗/所要時間/終了コード/gallery-dl バージョン）
4. **ログの日次分割と保持** — gallery-dl にローテーションは無い。**公式サンプル conf の `mode: "w"` をそのまま使うと履歴が毎回消える**
5. **壊れたソースの一時隔離 + 定期再検査** — 404 は恒久とは限らないので永久無効化はしない

**人間介入が必須になる境界**: cookie 失効（16）・設定不整合（32）・ディスク不足（128）・bot チャレンジ（8）→「通知して当日は諦める」が正しい。**「そもそも実行されなかった」だけは自己監視で検出不能**なので dead man's switch が要る。

**Windows 固有の地雷（いずれも静かに壊れる）**: `output.logfile` の既定 mode が `w` / `RotatingFileHandler` の rollover で `PermissionError [WinError 32]` / Session 0 実行ではトースト通知が出ない / `ExecutionTimeLimit` の既定が 72 時間 / **AC 電源条件が既定 ON でノート PC では実行が黙って飛ぶ**。

**footgun（公式ドキュメント明記）**: `errorfile` を `-I/--input-file-comment` または `-x/--input-file-delete` と組み合わせると**入力ファイルの「全」URL がコメント/削除される** → ソース台帳は自前で持ち、実行ごとに一時 input-file を生成すること。

### 3.6 testability（動的視点） — オフライン検証可能性

- **真のオフライン化はプロセス境界のスタブでしか達成できない**（`--simulate` も `--dump-json` もネットワークを使う）。gallery-dl 自身の `test_downloader.py` がローカル HTTP サーバ + FakeJob で同じ問題を解いており参照実装になる
- **観測は archive DB とファイルツリーの二重**。片方だけでは過剰スキップか取りこぼしのどちらかが観測できない
- **過剰スキップの最悪ケース（round2 新発見）**: `archive.check` が算出キーを kwdict にキャッシュし `add` が再利用する一方、formatter の欠損フィールドは文字列 `"None"` に潰れる。→ **archive-format にタイポや DL 後フィールドを書くと全キーが定数化し、2 件目以降が無警告で全 skip される（ライブラリ全体が静かに空になる）**。逆にこれは「N 件から N 個の distinct キーが出る」「キーに `None` が現れない」の純関数テスト 2 本で完全に封じられる
- **Windows 経路**: `test_path.py` の手法（`os.sep` と `WINDOWS` 定数の 2 個を monkeypatch）に倣えばテーブル駆動で全件オフライン検証可。実 FS が要るのは 260 超パスとドライブ跨ぎ（EXDEV モック注入）だけ。**自動切り詰めは gallery-dl に無く、拡張長パスでも各コンポーネント 255 バイト制限が残る**ため、日本語・絵文字ボード名にはバイトスライス（`{foo[b0:200]}` 等）が必要。予約デバイス名（CON/PRN/NUL/COM1-9/LPT1-9、`NUL.txt` も NUL 扱い）は `path-restrict` 既定で除去されずラッパー責務
- **陳腐化検知の三段構え**: バージョン厳密固定（`--version` を assert）+ 無通信の `--list-extractors` / `-E` ゴールデン + network タグ隔離の実通信スモーク（失敗は品質債務に記録）
- **注意**: `--print prepare` の `{_path}` は前回パスを返すバグ（#4083）。書かれたファイルの取得は**ファイルツリー実体観測を正**とする

---

## 4. 視点間の矛盾と解消（7 件）

| # | 対立 | 解消 |
|---|---|---|
| 1 | **早期打ち切り `abort:N` の採否**<br>cost: `abort:3` で 1.46s→1.31s、追加実装ゼロ ↔ technical/risk/operability: 取得順が新→旧で連続していることに依存、#8396 の混入で連続が途切れる | **既定 OFF（全走査）**、per-source の opt-in に留める。有効化は「そのソースで逆時系列性を実測確認した場合のみ」+ 交互配置フィクスチャの負テスト常設。<br>⚠ **DA-002 が反証（未解消）**: 判断が「時間」軸のみで、cost 自身が律速と認定した「リクエスト量＝ban 露出」軸で比較していない |
| 2 | **メタデータサイドカー既定 ON/OFF**<br>cost: ファイル数 2 倍が実コスト ↔ risk: 来歴がなければ汚染が不可逆 | **既定 ON**。非対称性が決め手（OFF の損失 = 汚染の判別不能 + 修復に ban リスク再支払い ≫ ON のコスト +1.2%）。緩和として**画像ツリーと分離した meta 側ツリー**に書き同期対象から除外可能に。**保存先は OneDrive 配下に置かない** |
| 3 | **429 ハンドリングの実態**<br>cost: 429 ハンドリング無し ↔ risk: `sleep-429` 既定 60 秒 + retries 4 で吸収され静かに絞られる ↔ operability: ドキュメント上曖昧 | 3 者は層の違いを見ており実測なしには確定不能。**どちらでも壊れない側に倒す**: `retry-codes` に 429 明示追加 + 指数バックオフ + ラッパー側の連続失敗上限（gallery-dl の actions に N 回停止カウンタが無いことは #7199 で確認済）+ ログからの検知記録。実挙動確認は Phase 4 繰延 |
| 4 | **呼出方式のイベント粒度**<br>technical: `register_hooks` がピン単位イベント ↔ alternatives: CLI 側に `-j`/`--print-to-file`/`-e` が揃い import 不要 | **subprocess 採用**。粒度差は実用上埋まる。決め手は (1) gallery-dl に全体 wall-clock 上限が無く hard timeout は `subprocess.run(timeout=)` が圧倒的に簡単 (2) 「入力単位ごとに 1 プロセス」が exit code のビット OR 合成問題を解消し CLI 契約を実装前に固定可能にする。<br>※ python ポストプロセッサは自作モジュールを gallery-dl プロセス内に import させるため GPL 上は import 方式と同位置。既定では使わない |
| 5 | **cookie の常用方針**<br>operability: 秘密ボード・All Pins はログイン必須 ↔ risk: cookie 付与でリスクが非対称に増大 | 実装はするが**常時付与はしない**。ソース登録レコードごとに `auth: none \| cookie` を持たせ**既定 none（匿名）**。公開ボード・検索・公開ユーザーは匿名、cookie は非公開ボード等にのみ。`cookies-select: random/rotate`（複数アカウント回転）は典型的 ban 回避パターンとみなされるため**不採用** |
| 6 | **自前 SQLite/JSON 履歴の要否**<br>cost/alternatives: 中間案で十分（80〜150 LOC） ↔ operability: 台帳・quarantine・ブレーカ・run サマリと要求が大きい | 矛盾ではなく**責務境界の問題**。「**重複排除の権威 = gallery-dl archive**」「**ランタイム状態の権威 = 自前台帳**」と分離し、**自前台帳は dedup 判定に一切使わない**。例外は reconcile（archive エントリ集合 vs 実ファイル由来キー集合の照合）のみ |
| 7 | **フィクスチャの取得元**<br>cost: 実機実通信で計測 ↔ testability: 実通信はオフラインテストの入力源にならず「録画して固定する対象」 | 両立する。cost の実測は「初期録画」そのもの。手順: (1) 実通信 1 回で 4 入力単位の `-j` 出力・ファイルツリー・archive DB を凍結（実施日と版を記録） (2) L2 は偽 gallery-dl で再生し二重観測で assert (3) 陳腐化は `--list-extractors` ゴールデン + `--version` 厳密一致 (4) 実通信スモークは network タグ隔離 |

---

## 5. リスク指摘（Devil's Advocate 2 ラウンド）

### 5.1 CRITICAL

#### DA-008 — Synthesis が再調査結果を取り込んでいない（プロセス欠陥）

`synthesis.json` は round1 と md5 完全一致・`feedback_response` は空。6 視点は全て更新され実機検証済み。**Primary に従うと実害が出る点が少なくとも 3 つ**（内容重複 / cookie の fail-open / archive キー定数化による無警告全 skip）。

> **解消条件**: round2 の 6 視点を入力に Synthesis を再生成し、md5 が変化していること + `feedback_response` に逐条応答が入っていること。

#### DA-001 — 「同一画像」要件の未充足が未開示のまま確定している

- **locked decision の文言は「同一ピン/同一画像は再ダウンロードしない」**。Primary が採る `{id}{media_id|page_id}` は pin ID 由来なので**後半（同一画像）を満たさない**
- `synthesis.json` 全文に「同一画像」「内容重複」「ハッシュ」の語が **0 件**（alternatives は 7 件）→ **要件縮小がユーザーにも Phase 1.5 にも開示されないまま確定**
- **round2 の実機再現**: 同一ボード内の別ピン 2 件（`424605071145711021` / `424605071145708386`）が同一 `orig_url`・同一 `image_signature` を持ち、既定設定で**両方 DL され落ちた 2 ファイルの MD5 が完全一致**（`bfaf8089…`）

**解決策も実測済み — コスト 0 の中間ティアが存在する**:

| ティア | 手段 | 効果 | コスト |
|---|---|---|---|
| T0 | 既定のまま | 同一ピンですら**跨ボードで二重取得**される | — |
| T1 | `-o archive-format="{filename}"` | `{filename}` = Pinterest の `image_signature`。`archive.check` は **DL 前**に kwdict で判定するため、別 subcategory 経由の同一画像を **HTTP リクエスト前に skip**（実測: archive 行は 1 件のみ、出力ディレクトリすら作られない）。帯域も ban リスクも払わない | **設定 1 行 = 0 円** |
| T2 | DL 後の知覚ハッシュ第 2 パス（dHash → pHash） | 「同じ絵柄を再アップロード/再エンコードした別バイト列」のみが固有領域。実測: #8597 の同一絵柄 jpg（162 KB）と png（4.4 MB）は dHash/pHash とも完全一致 = **27 倍の容量差** | 80〜150 LOC + Pillow/imagehash、10.7〜40.8 ms/枚 |
| T3 | 自前 SQLite + BK-tree 全件索引 | 10 万枚規模から | 高コスト・不要 |

**T1 に伴う、Synthesis が扱っていない結合条件**:
- `{filename}` キーにすると同一画像は**最初に走った 1 ボードにしか実体が落ちない** → ボード別フォルダ構成と素朴には両立しない（両立には フラット content-addressed 実体 + 索引 + NTFS ハードリンクによるビュー生成が必要）
- 動画ピンでは `{filename}` が m3u8 の hash になり静止画 signature と別系統
- **archive-format は後から変えられない**（変更＝過去 entry と別キー空間＝全件再 DL）。**初回起動前に確定させないと不可逆**
- `image_signature` はローカルファイルの MD5 と一致しない（実測: sig `e7a24502…` vs MD5 `bfaf8089…`）→ **ディスク上のファイルから archive を再構築できない**
- `aggregated_pin_data[id]` は同一 signature の 2 ピンで別値だったため同一性キーとして不安定

### 5.2 HIGH

| ID | 指摘 | 解消条件 |
|---|---|---|
| **DA-002** | `abort:N` 不採用が「時間」軸のみで決着。cost 自身が「律速は時間ではなくボット判定リスク」と結論し、round2 では「`--download-archive` + `-A` 併用で 1 ソース 10〜60 秒」「毎時実行は ban 露出を増やすだけの無駄」と明示。全走査を既定にすると**登録ソース全件の全ページを毎回叩き続ける**（20 ソースで 10〜15 分 vs abort:3 で 2〜3 分） | (a) 1 サイクル想定 API リクエスト数の上限設計 (b) 許容根拠または不明の明示 (c) 縮退手段（頻度低減 / per-source abort / 分散実行）+ 取りこぼし条件（並べ替え済みボード・中断の穴・`--date-after` 不可）の両軸評価 |
| **DA-003** | **保存構造・ファイル命名・source_id 導出が Primary に無い**（synthesis 内 `filename` 0 件 / `base-directory` 0 件）。単なる記述漏れではなく **Primary の柱を崩す** — reconcile はファイル名から archive キーを逆算できることに依存し、その成立条件は「既定 `filename_fmt` を変更しないこと」。実装者が可読性のためテンプレートを変えた瞬間に reconcile が原理的に成立しなくなる | (a) directory 骨格（可変名 vs 安定 ID/slug）とボード改名時の孤児化の扱い (b) ファイル名規約 +「reconcile 成立条件として変更禁止」の明記 (c) 4 入力単位から衝突しない source_id 導出規則 (d) コンポーネント 255 バイト切り詰めの実装位置 |
| **DA-004** | 正規化キー `{id}{media_id\|page_id}` の**キー縮退**。両方欠けるピンでは `{id}` だけに縮退。加えて round2 で「欠損フィールド → `"None"` 潰れ → 全キー定数化 → 2 件目以降が無警告で全 skip」という**最悪の取りこぼし**が判明。逆方向として board の `{board[id]}_{id}` は media_id を欠くため carousel/story pin の 2 枚目以降が落ちない可能性 | (a) 静止画/カルーセル/動画の各メディア種で distinct キーが出ることの純関数テスト 2 本（distinct 件数一致 / キーに `"None"` が現れない）を成功条件に (b) 異種メディアのフォールバック式または種別分岐方針の明記 |
| **DA-009** | **cookie の fail-open 2 種**。壊れた cookies.txt（CRLF / BOM）と `--cookies-from-browser` の失敗は、いずれも **exit 16 を出さずに「公開分だけ取れて正常終了」**する。Primary は exit 16 検知に依存しているため機能しない → **非公開ボードが静かに空のまま定期実行が回り続ける** | cookie 指定ありのソースで実効性（読込成功 + 認証済みレスポンス）を検証し満たさなければ中断する **fail-closed ガード** + その負テスト（壊れた cookies.txt / BOM / CRLF で exit≠0）をオフライン L2 に |
| **DA-010** | **subprocess 固定が検証到達ティアを制約する**。重複排除の権威を gallery-dl プロセス内部（archive）に置いているため、プロセス境界でスタブすると「重複排除が実際に効くか」は**オフラインで一切検証できず、検証できるのは argv 構築だけ**。偽 gallery-dl は archive を書かないので「archive DB とファイルツリーの二重観測」は成立しない | (a) subprocess 固定下でオフライン検証可能な範囲の明示（キー生成の純関数テスト + 録画 kwdict からのキー算出） (b) archive DB 観測を成立させる手段の具体化、または二重観測の主張を撤回して代替不変条件に差し替え |
| **DA-005** | 時間・容量数値の基盤が不安定。round1 の「実測 500 ピン ≒ 29 分」は 12 件からの線形外挿。round2 は別レンジ（17〜40 分）を出し「**無認証の resource API は 403 で実ランできず所要時間はすべて算術推定**」と明記。画像サイズ分布も round1/round2 で食い違う | (a) 実測点（件数・経路・日付・版）と外挿部分の区別 (b) round1/round2 レンジの併記 (c) 判断の決め手として使えるかの明示 |

### 5.3 MEDIUM

- **DA-006 — 4 入力単位 → gallery-dl subcategory の対応表が未定義**。pinterest extractor は board/section/user/allpins/created/pin/search/related-pin/related-board/pinit の 10 サブカテゴリを持ち、「ユーザー」は user（ボード一覧）／allpins／created のいずれとも解釈でき、それぞれ `directory_fmt` も出力集合も異なる（#2452 は user と board の subcategory 解決がずれた実例）。この割り当てが決まらないと **per-unit CLI 契約も初期録画対象も確定しない**
- **DA-007 — reconcile の是正側が設計に無い**。検知はできるが直せない。archive にキーがあり実ファイルが無い場合、再取得には archive エントリの削除が必要だが、既存ファイル群から archive を再構築する公式手段がない（#6920）。加えて `image_signature` ≠ ローカル MD5 のため逆算の前提はより限定的

### 5.4 未解決事項（open questions — Phase 4 繰延）

1. リピンで `image_signature` が**異なるユーザー間でも**不変か（確認できたのは同一アカウントが同一アセットを 2 ピンにしたケースのみ）— **T1 案の効き幅がここに懸かる**
2. round1 cost の「実測」と round2 の「無認証 resource API は 403 で実ランできず」の食い違いの原因（環境差 / cookie 有無 / Pinterest 側変動）
3. Pinterest の定量的レート制限閾値（何 req/分で 429・解除までの時間）— 3 視点とも一次情報を取得できず
4. cookie 失効時に BoardFeed が 403 を返すか 200+部分結果を返すか（後者なら silent 経路が 1 本増える）
5. 並べ替え済みボードで `-A N` が実際に新着を取りこぼすかの再現実験
6. gallery-dl の exit code の公式定義（exit 64 の意味を含む。公式文書が無く `exception.py` からの逆算のみ・#2208 未回答）
7. #8396（無関係ピン混入）の root cause と `--filter` で予防可能か
8. Pinterest ToS の準拠法・管轄の日本居住ユーザーへの適用、および改正著作権法 §30(1)(iv) の適用判例

---

## 6. 上流リスクと前提の訂正

### 6.1 gallery-dl 上流の不安定性

- 2026-03 の FAKKU DMCA を受け **2026-04-05 に開発拠点を Codeberg へ移転**（GitHub は CI 等の非中核用途のみ）→ GitHub の issue 番号・raw URL に依存した自動化は今後腐り、Codeberg 側は独自連番（#102 等）で**参照の二重管理**が発生
- リリース頻度: 1.32.0（2026-04-24）〜1.32.11（2026-09-04）で 12 本 = **月 2.7 本**。破壊的変更はマイナー版に集中（1.32.0 で `image-*`/`chapter-*` → `file-*`/`child-` 改名、`date-format` 削除、非推奨オプション使用時のエラー化）
- **第三者情報サイト（gallery-dl.com 等）には誤情報がある**（`--update` を増分フラグと誤説明。実際は `-U/--update` = 自己アップデート）→ 実装時にこれらを典拠にしない運用ルールが必要

### 6.2 既知 issue の前提訂正（Phase 0 の記載は事実誤認）

| issue | Phase 0 の理解 | 実体 |
|---|---|---|
| **#8597** | 「png が jpg 拡張子で保存される」 | ❌ 誤り。実体は「**より大きい PNG 版が存在するのに JPG を選ぶ**」画質選択の enhancement（open, 報告者自身が PNG は稀と記載）。拡張子自体は `pathfmt.fix_extension()` がヘッダを見て補正する |
| **#8396** | ボードに無関係なピンが混入 | ⚠ より深刻。混入ピンが**正当な pin id・正当なディレクトリ・正当な archive キー**で入るため**事後判別不能** |
| **#9240** | （未認識） | AI アップスケール版を掴む（92 KB の原本が 4 MB に）。`external-issue` ラベル = 上流では直せない可能性 |
| **Codeberg #102** | （未認識） | fallback を full image として保存 |
| **#8081** | （未認識） | `/originals/` が 403 のとき低解像度が同名で残る |

> **決定的な設計判断は「来歴を残すか」**。metadata サイドカーを最初から書いていれば全ての汚染が機械的に選別・再取得可能（**可逆**）。書かなければ**全再クロール（= ban リスクの再支払い）以外に修復手段がない**。→ 対策の焦点は「拡張子補正」ではなく「サイドカーによる来歴記録」に移す。

---

## 7. 推奨アクション（Synthesis の Primary / Fallback / Abort）

### 7.1 Primary — Python 3.13 + subprocess の薄いラッパー（8 点の中核設計）

| # | 設計 |
|---|---|
| 1 | **入力単位ごとに gallery-dl プロセスを 1 個起動**し `subprocess.run(timeout=)` で hard timeout（`.part` 既定 true / `archive-mode` は既定の `file` を維持） |
| 2 | **ハーメティック実行** — `--config-ignore` + 同梱 `config.json`（`-c`）+ 可変スカラーのみ `-o`。schtasks の 255 文字制限とも整合 |
| 3 | **archive-prefix / archive-format の明示指定**でピン単位キーに正規化し board/section の上書きを無効化 ⚠ **DA-001 により再考が必要** |
| 4 | **新着差分は `abort:N` を使わず archive による全走査 skip**、abort は per-source opt-in ⚠ **DA-002 により再考が必要** |
| 5 | **レート制御は設定欠如で起動しない fail-fast** + 初期値 `sleep-request 1.0-1.5` / `sleep 2.0-3.0` / `retries 5` / `timeout 30` / `sleep-429` 指数バックオフ / `parallel 1`、`retry-codes` に 429 明示追加、ラッパー側にも連続失敗上限付きバックオフ |
| 6 | **cookie はソース単位 opt-in（既定 none = 匿名）** — cookies.txt 主・Firefox 補助、`cookies-update` でセッション延長、保存先ツリー外の権限制限ディレクトリ + `.gitignore` + pre-commit 検査、`cookies-select` の random/rotate は不採用 ⚠ **DA-009 の fail-closed ガード追加が必要** |
| 7 | **状態の責務分離** — dedup 権威 = gallery-dl archive / ランタイム権威 = 自前台帳（source 登録・quarantine・1 実行 1 行の JSONL）+ **reconcile コマンド** ⚠ **DA-007 の是正側が未設計** |
| 8 | **メタデータ JSON サイドカーは既定 ON**、保存先ツリーと分離した meta 側に書く |

**運用面**: schtasks 登録サブコマンド + 単発実行モード（.bat ラッパー / `PYTHONUTF8=1` / `IgnoreNew` + OS 排他ロック + `ExecutionTimeLimit` ≤ 実行間隔 / AC 電源条件と `StartWhenAvailable` の明示設定）、自前列挙型の終了コード（**0**=全成功 / **1**=部分失敗 / **2**=設定 / **3**=環境起因 retryable / **4**=認証起因 human_required / **5**=全滅、未知は必ず unknown 分類）、異常検知（**新規 0 かつスキップ 0 = fail** / 新規 0 かつスキップ多数 = 正常 / ベースライン逸脱 / カナリア URL / dead man's switch）、per-source サーキットブレーカ（**同一実行内で他に成功があるときのみ trip** するグローバル障害ガード付き・自動削除せず quarantine 記録）、`extractor.*.fallback=false`、`archive-event` は既定の `file` のみ（**skip を絶対に含めない**）、`--simulate` は archive 書込経路を通さないことを負テストで固定。

### 7.2 Fallback — 二段構成への切替

`-j/--dump-json` で一覧を取得 → 自前台帳で差分集合を計算 → 未取得ピンのみを個別 URL / `--range` で DL。同時に dedup 権威を archive から自前台帳へ移し、実ファイル実体の有無を判定に組み込む。スケジューラ側の副次 fallback は「登録を諦めて手順書 + 生成済み .xml/.bat を出力するだけ」に降格。

**切替 trigger**（いずれか）:
1. reconcile が不一致を 2 回以上検出
2. 「新規 0 かつスキップ 0」が同一ソースで 2 回連続
3. 実通信スモークで #8396 型混入または返却順の非時系列性が再現
4. archive-format 明示固定後も入力単位跨ぎの重複 DL が実測された
5. 取得件数がベースライン中央値の 50% 未満の実行が 2 回連続
6. （スケジューラ）自己登録が Windows 11 実機で権限・証明書・AV いずれかで 2 回失敗

### 7.3 Abort — 撤退案（採らない）

gallery-dl を `config.json` + 素の schtasks + 薄い .bat のみで運用する案。合理性は 3 点あるが**採らない**。失われるのは「ダウンロード機能」ではなく **「壊れたことに気づく能力」** — reconcile / 件数ベースライン / カナリア / dead man's switch / サイドカー来歴 / source_id 抽象と quarantine / 環境起因と認証起因を分離した終了コード / ハーメティック実行、そして errorfile と `-I`/`-x` の組合せによる**ソース登録リストの黙った破壊**を踏む確率が高い。

---

## 8. 実装成功条件（`implementation-criteria.json`）

生成日時: 2026-09-10 07:35 JST ／ Layer 1: 13 件・Layer 2: 6 件・Layer 3: 8 件・フェーズ 3 段

### 8.1 フェーズ構成

| Phase | ゴール | 範囲 | Mutation 閾値 |
|---|---|---|---|
| **mvp** | スタブ再生で 1 ソースの単発実行が E2E に成立し、**ファイル・archive・run 台帳の 3 系統**に観測可能な副作用が残る | CLI 骨格（`run --once`）、ソース台帳読込、ハーメティック argv ビルダー、archive キー正規化、`--print-to-file` サマリパース、偽 gallery-dl と録画再生の検証基盤、保存先ツリーと meta 分離の決定。cookie / schtasks / reconcile / 異常検知は含まない | 0.4 |
| **core** | 差分取得・状態管理・異常検知・終了コード分類・fail-closed ガードが揃い、**静かな劣化を検知して修復できる** | 全走査 skip による新着差分、台帳と dedup 権威の責務分離、`reconcile --repair`、異常判定ルール、自前列挙型終了コード、サーキットブレーカ、危険設定 fail-closed ガード | 0.3 |
| **polish** | Windows 固有エッジで壊れず、定期実行登録と秘密非混入が機械的に担保され、**繰延した検証が台帳に残る** | パスサニタイズ、schtasks 登録サブコマンド（XML + .bat）、多重起動の排他ロック、秘密 lint、cookie の opt-in 経路、実行サマリと README、L2-001〜006 の実行または品質債務としての繰延記録 | 0.2 |

### 8.2 Walking Skeleton（各フェーズ必須の E2E シナリオ 1 本）

- **mvp**: 偽 gallery-dl を注入した `run --once` が公開ボード相当ソースを処理 → 画像ファイル数・archive entry 集合・`runs.jsonl` 最終行の new/skipped/failed が**録画期待値と一致**（L3-001）
- **core**: 初回 run → 2 回目 run（new=0 / skipped>0 / ファイル集合不変）→ **画像 1 件削除 + 1 件 0 バイト化** → 通常 run では復旧しないことを確認（**負テスト**）→ reconcile が missing 2 件を検出して非 0 終了 → `--repair` で復元 → 最終 reconcile が `status=consistent` / exit 0（L3-003 + L3-004）
- **polish**: 日本語 400 バイト級ボード名 + 予約デバイス名 + 禁止文字を含むソースで run → パス安全化して保存成功 → 同一 state-dir への二重起動が排他ロックで拒否 → 3 回連続失敗で quarantine 化 → 成功で復帰 → `schedule install --dry-run` が妥当な XML/.bat を出力 → 秘密 lint が exit 0

### 8.3 Layer 1（オフライン単体・13 件）

| ID | 内容 |
|---|---|
| L1-001 | argv ビルダーがハーメティックかつ shell を経由しないリスト形式 |
| L1-002 | archive キー正規化が入力単位を跨いで同一ピンに同一キーを与える |
| L1-003 | Windows パスサニタイズをプラットフォーム分岐定数の monkeypatch でテーブル駆動全件検証 |
| L1-004 | `--print-to-file` の after/skip/error をパースし new/skipped/failed を決定論的に集計 |
| L1-005 | 「新規 0 かつスキップ 0 = 抽出破綻」と「新規 0 かつスキップ多数 = 新着なし」を分離 |
| L1-006 | 終了コード分類器（0〜5）が環境起因と認証起因を必ず別コードにし、**未知コードを成功に落とさない** |
| L1-007 | per-source quarantine + **全ソース同時失敗では trip しない**グローバル障害ガード |
| L1-008 | **dedup 権威が archive のみ**で自前台帳が dedup 判定に使われない（責務分離の負テスト） |
| L1-009 | reconcile が archive エントリ集合と実ファイル由来キー集合を突き合わせる |
| L1-010 | 危険設定への fail-closed ガード（archive-event に skip / fallback=true / rate 未設定 / `--simulate` 時の archive 書込） |
| L1-011 | schtasks XML ビルダーが 255 文字制限と既定値地雷（72h / AC 電源）を明示上書き |
| L1-012 | 秘密 lint が実混入を検出しダミー fixture を誤検出しない |
| L1-013 | 偽 gallery-dl の録画再生がネットワーク遮断下で成立し、argv 検査と録画 miss の明示 fail を行う |

### 8.4 Layer 2（実バイナリ・実環境依存・6 件 — 多くは Phase 4 繰延）

| ID | 内容 | 繰延 |
|---|---|---|
| L2-001 | gallery-dl 版の厳密一致（1.32.11）+ 無通信 `--list-extractors` ゴールデン差分ゼロ（**陳腐化カナリア**） | バイナリ不在時のみ env_blocked |
| L2-002 | 実通信スモーク: 4 入力単位に対し低件数・sleep 明示で `-j` 抽出 1 回 → 録画 fixture 更新 | ✅ deferred 可 |
| L2-003 | 429 の実挙動確認（汎用リトライ層で吸収 vs `AbortExtraction` 即中断） | ✅ deferred 可（意図的な高頻度アクセスは行わない） |
| L2-004 | schtasks 実登録ラウンドトリップ（登録 → `/Run` → JSONL 追記確認 → `/Delete`） | 要タスク登録権限 |
| L2-005 | 実 FS 経路（260 超パス / 255 バイト/コンポーネント / 予約デバイス名 / EXDEV） | 別ボリューム無い場合はモック降格 |
| L2-006 | cookie 実経路（cookies.txt 取得成功 → `cookies-update` 更新 → 失効時 exit 4 分類） | ✅ deferred 可（人手による cookie 準備が前提） |

### 8.5 Layer 3（行動検証・8 件）

| ID | 戦略 | blocking | 閾値 |
|---|---|---|---|
| L3-001 | cli_flow | ✅ | 全ステップ exit 0 かつ 3 系統の観測値が録画期待値と完全一致 |
| L3-002 | structural | ✅ | run 履歴 JSONL が全行スキーマ適合・行数 == 実行回数 |
| L3-003 | cli_flow | ✅ | 2 回目 exit 0 / new=0 / skipped>0 / ファイル集合ハッシュ一致 / **argv に `--abort` 不在** |
| L3-004 | cli_flow | ✅ | 静かな劣化を reconcile が検出し `--repair` で再取得。**通常 run では再取得されないことも負テストで固定** |
| L3-005 | structural | ✅ | 抽出破綻 2 変種とも exit != 0（**exit 0 での通過は即 fail**） |
| L3-006 | cli_flow | ✅ | 危険設定 3 種すべてで exit 2 かつ**生成ファイル 0 件** |
| L3-007 | structural | ✅ | schtasks dry-run 出力が全構造チェック合格（TaskRun < 255 文字 / `DisallowStartIfOnBatteries=false` / `StartWhenAvailable=true` / `MultipleInstancesPolicy=IgnoreNew` / .bat に `PYTHONUTF8=1`） |
| L3-008 | llm_judge | ❌ | 0.80 — 運用者向け出力が「静かな劣化に人間が気づいて対処できる」水準 |

### 8.6 環境前提

- 環境能力プローブは `cmd:node` / `cmd:npm` / `cmd:npx` / `display` / `network` のみ報告し **`cmd:python` / `cmd:gallery-dl` のタグを持たない** → mvp 最初の exit_criteria で `python --version` / `gallery-dl --version` を機械検証、不在なら env_blocked として繰延し人間判断へ
- WORK_DIR に Node の `package.json` が存在するが**本 CLI では一切使わない**。正典のテストコマンドは `python -m pytest`
- Layer 1 は全てオフライン（socket 遮断下）で完走すること

---

## 9. 次アクションの推奨

### 9.1 実装前に必ず決着させる 4 点（順序付き）

| 優先 | 事項 | 理由 |
|---|---|---|
| **P0** | **archive キーを内容署名系（`{filename}` 等）にするか pin ID 系に留めるか**を、選択理由・異種メディアのフォールバック式・「ボード別フォルダとの両立方針」込みで確定する。pin ID 系に留めるなら「**内容重複は非対応**」を要件縮小として明示宣言し再評価トリガを残す | **後から変更不能**（変更＝全件再 DL）。locked decision の「同一画像」に直結。DA-001 CRITICAL |
| **P0** | **Synthesis を round2 の 6 視点を入力に再生成**する（`feedback_response` に逐条応答を入れる） | 現 Synthesis は round1 のままで、実測された反証を 1 件も含まない。DA-008 CRITICAL |
| **P1** | **保存構造・ファイル命名規約・source_id 導出規則**を確定し、「reconcile 成立条件としてファイル名テンプレートを変更しない」旨を明記 | reconcile が原理的に成立しなくなる。DA-003 HIGH |
| **P1** | **4 入力単位 → gallery-dl subcategory の対応表**を確定（「ユーザー」= user / allpins / created のどれか、section・pin.it の扱い） | per-unit CLI 契約も初期録画対象も決まらない。DA-006 MEDIUM だが全体のブロッカー |

### 9.2 設計に追加すべき事項

- **cookie の fail-closed ガード**（cookie 指定ありのソースで実効性を検証し、満たさなければ中断）+ 壊れた cookies.txt / BOM / CRLF の負テスト（DA-009）
- **archive キーの妥当性検査 2 本**（distinct 件数一致 / キーに `"None"` が現れない）を成功条件に組み込む（DA-004）
- **reconcile の是正側**（不一致時の archive エントリ削除 + 再取得、ドライラン、誤削除防止）と負テスト、および archive のバックアップ方針（保存先と同時に退避）（DA-007）
- **`abort:N` / 全走査の既定選択**を「リクエスト量＝ban 露出」軸でも評価し、1 サイクル想定 API リクエスト数の上限設計と縮退手段を記載（DA-002）
- **subprocess 固定下でオフライン検証できる範囲の明示**、または「archive DB とファイルツリーの二重観測」の主張を代替不変条件に差し替え（DA-010）
- **数値の出典表記の是正** — 実測点（件数・経路・日付・版）と外挿の区別、round1/round2 レンジの併記（DA-005）

### 9.3 Phase 4（人間判断）に必ず上げる事項

1. **Pinterest ToS 違反リスクの受容可否** — 自動的手段によるデータ取得を明示禁止、robots.txt は `Disallow: /`。cookie 付与は「受諾済み契約を破っている」側に位置を確定させる
2. **改正著作権法 §30(1)(iv) の適用リスク** — 違法アップロード静止画の原寸一括 DL は私的利用でも違法となりうる（判例・行政見解は未確認）
3. **アカウント凍結リスク** — #5532 では本アカウントと予備アカウントが同時凍結された前例
4. 繰延された L2-002 / L2-003 / L2-004 / L2-005 / L2-006 の実行可否

### 9.4 運用前提として織り込むべきコスト

- gallery-dl の**月次 bump とスモークで 15〜30 分**、**年数回の Pinterest 側破壊対応で半日規模**
- 保存先を **OneDrive 配下に置かない**（同期コスト + EXDEV 報告。MEMORY の CRITICAL ルールとも整合）
- メタデータサイドカー既定 ON により**ファイル数が 2 倍**（1 万ピンで 2 万ファイル）

---

## 付録: 成果物ファイル一覧

| ファイル | 内容 |
|---|---|
| `investigation-plan.json` | 12 の core question・11 の暗黙前提・6 視点の定義 |
| `perspective-technical.json` | 技術的実現性（finding 6 件・全 high） |
| `perspective-cost.json` | コスト・リソース（finding 6 件・実機実測データ） |
| `perspective-risk.json` | リスク・失敗モード（finding 7 件） |
| `perspective-alternatives.json` | 代替案比較（finding 6 件） |
| `perspective-operability.json` | 無人運用ライフサイクル（動的視点・finding 6 件） |
| `perspective-testability.json` | オフライン検証可能性（動的視点・finding 6 件） |
| `synthesis.json` | 統合結論（**round1 のまま・要再生成**）・矛盾 7 件・Primary/Fallback/Abort |
| `devils-advocate.json` | DA round1（CRITICAL 1 / HIGH 3 / MEDIUM 3） |
| `devils-advocate-r2.json` | DA round2（CRITICAL 2 / HIGH 6 / MEDIUM 2、**round1 の 7 件すべて未解消**） |
| `implementation-criteria.json` | L1 13 / L2 6 / L3 8・3 フェーズ・前提 18 件 |
| `round1/` | round1 時点の各成果物（md5 比較に使用） |
