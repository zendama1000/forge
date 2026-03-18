# Forge Harness v3.2 技術的評価レビュー

**日付**: 2026-03-08
**対象**: forge-research-harness-v1 コードベース全体
**分析規模**: 8,158行 / 81関数 / 23ファイル / 25バグ

---

## 目次

1. [全体メトリクス](#1-全体メトリクス)
2. [5つの構造的原因](#2-5つの構造的原因)
3. [バグ25件 完全カタログ](#3-バグ25件-完全カタログ)
4. [根本原因分布・修正パターン分布](#4-根本原因分布修正パターン分布)
5. [アンチパターン一覧（26件）](#5-アンチパターン一覧26件)
6. [アーキテクチャ依存グラフ](#6-アーキテクチャ依存グラフ)
7. [テストカバレッジ詳細](#7-テストカバレッジ詳細)
8. [設定値の冗長・矛盾](#8-設定値の冗長矛盾)
9. [総合評価と改善優先順位](#9-総合評価と改善優先順位)

---

## 1. 全体メトリクス

| メトリクス | 値 |
|-----------|-----|
| コード行数 | 8,158行（23 `.sh` ファイル） |
| 関数数 | 81 |
| グローバル変数数 | ~110 |
| 設定値数 | 61（4 JSON ファイル） |
| テストカバレッジ | **43%**（35/81 関数） |
| 記録済みバグ | 25件 |
| 設計改善で予防可能だったバグ | **84%**（21/25） |

### ディレクトリ別コード行数

| ディレクトリ | ファイル数 | 行数 |
|-------------|-----------|------|
| `.forge/lib/` | 7 | 2,439 |
| `.forge/loops/` | 6 | 2,822 |
| `.forge/tests/` | 10 | 2,897 |
| **合計** | **23** | **8,158** |

### 大規模ファイル

| ファイル | 行数 | 役割 |
|---------|------|------|
| `ralph-loop.sh` | 949 | 開発オーケストレーター（最高複雑度） |
| `common.sh` | 867 | 共有ユーティリティ |
| `research-loop.sh` | 685 | リサーチオーケストレーター |
| `test-research-e2e.sh` | 565 | リサーチ E2E テスト |

### ファイル別関数数

| ファイル | 関数数 |
|---------|--------|
| `common.sh` | 26 |
| `ralph-loop.sh` | 18 |
| `research-loop.sh` | 13 |
| `phase3.sh` | 6 |
| `dev-phases.sh` | 5 |
| `mutation-audit.sh` | 5 |
| `investigation.sh` | 4 |
| `evidence-da.sh` | 1 |
| その他（forge-flow, generate-tasks, mutation-runner, dashboard） | 各1 |

### グローバル変数分布

| ファイル | 変数数 | 主な内容 |
|---------|--------|---------|
| `ralph-loop.sh` | ~35 | パス定数、設定値、セッションカウンタ |
| `research-loop.sh` | ~25 | パス定数、モデル名、状態 |
| `generate-tasks.sh` | ~22 | パス定数、テンプレート |
| `forge-flow.sh` | ~15 | フロー状態 |
| `common.sh` | 12 | カラー定数、ファイルパス |

### エラー抑制量

| パターン | 出現数 |
|---------|--------|
| `2>/dev/null` | 203 |
| `\|\| true` | 36 |
| 合計エラー抑制箇所 | ~208 |

### エラーイベント（`errors.jsonl` より）

| エラー種別 | 件数 |
|-----------|------|
| `Claude実行エラー`（エージェントプロセスクラッシュ） | 57 |
| `出力が不正なJSON` | 24 |
| `出力が空` | 6 |
| `Investigator実行エラー` | 4 |
| `自動ABORT` | 1 |
| **合計** | **92** |

### バリデーション回復統計（`validation-stats.jsonl` より）

| 回復レベル | 件数 | 意味 |
|-----------|------|------|
| `crlf` | 230 | CRLF 改行正規化（Windows） |
| `extraction` | 67 | 周囲テキストから JSON 抽出 |
| `fence` | 26 | マークダウンコードフェンスから JSON 抽出 |
| `failed` | 22 | 回復不能なバリデーション失敗 |

---

## 2. 5つの構造的原因

### 構造的原因 1: LLM 出力への過剰信頼（バグの48%）

25件中12件が「LLM が生成したコマンド/出力をそのまま使用」に起因する。

- `vitest`/`tsc` が `npx` プレフィックスなしで生成（8タスクに影響）
- ポート番号のハードコーディング（1件）
- テンプレート変数の未置換（2件）
- ファイル作成のハルシネーション（1タスクで7回発生）

MEMORY.md に「LLMの指示遵守は機械的バリデーション/上書きで担保すべき」と記載済みだが、LLM 生成コマンド全体への体系的サニタイズ層は**未実装**。

### 構造的原因 2: 暗黙的グローバル変数依存（God Object + 110変数）

各モジュールが期待するグローバル変数数:
```
investigation.sh   : 17変数
mutation-audit.sh  : 11変数
dev-phases.sh      : 12変数
```

ヘッダコメントに「前提変数」が記載されているが、**実行時検証はゼロ**。未定義変数は空文字列に暗黙変換される。

`CLAUDE_TIMEOUT` は5ファイル・17箇所で「保存→変更→復元」パターンで使用されるが、早期 return 時に復元をスキップしてグローバル状態を破壊するリスクがある。

`common.sh`（867行・26関数）は8つ以上の責務ドメインを持つ **God Object**。

### 構造的原因 3: 単一出力チャネル設計（`.pending` パイプライン）

```
run_claude() -> stdout -> .pending -> validate_json -> 最終ファイル
```

この設計は「Claude CLI は常に JSON を stdout に出力する」と仮定している。実際には:
- Write ツールがファイルを直接書き込む（Bug I1）
- 非 JSON 出力が `.pending` から昇格されない（Bug I2）
- 作業ディレクトリ不一致でファイルが間違った場所に作成される（Bug E7）

同一パイプライン設計から3件の異なるバグが発生。

### 構造的原因 4: 後付けの Windows 互換性（バグの32%）

| 問題 | 件数 |
|------|------|
| パス区切り（`/` vs `\`） | 2 |
| `/tmp` パス解決の不一致 | 1 |
| シンボリックリンク権限（EPERM） | 1 |
| CRLF 正規化（毎回発生） | 230回 |
| `local` キーワードの動作差異 | 1 |

`validation-stats.jsonl` は230回の CRLF 回復イベントを記録しており、**ほぼ全ての LLM 出力で改行正規化が必要**。

### 構造的原因 5: テストカバレッジの偏り

- **テスト済み**: 純粋関数（`validate_json`, `get_next_task`, `check_circuit_breakers` 等）
- **未テスト**: オーケストレーション関数（`run_task`, `main`, `run_investigator`, `handle_dev_phase_completion` 等）

バグの80%が E2E 実行で発見されており、**システムは事実上プロダクションでのみテストされている**。オーケストレーション関数は最も複雑でバグが多いが、ユニットテストはゼロ。

---

## 3. バグ25件 完全カタログ

### データソース

| ソース | レコード数 |
|--------|-----------|
| バグレポート（`harness-bug-report-20260301.md`） | 7件 |
| 調査ログ（`investigation-log.jsonl`） | 52エントリ / 30タスク |
| エラーログ（`errors.jsonl`） | 92イベント |
| バリデーション統計（`validation-stats.jsonl`） | 346回復イベント |
| `MEMORY.md` | ~15件（非公式記録） |

---

### カテゴリ 1: 環境不一致（8件 / 32%）

#### Bug E1: Windows パス区切りが Jest testPathPattern を破壊
- **根本原因**: Jest の `testPathPattern` がフォワードスラッシュ（`models/doctrine`）を使用するが、Windows はバックスラッシュ（`models\doctrine`）に解決し、0件マッチ
- **発見方法**: E2E テスト（自動 L1 バリデーション失敗）
- **修正種別**: 機械的ゲート（パスベースパターンをファイル名のみパターンに書き換え）
- **予防可能**: **Yes** — コマンドサニタイザーがパス区切りを正規化すれば防止可能

#### Bug E2: `vitest` / `tsc` / `eslint` が PATH にない
- **根本原因**: バリデーションコマンドが `vitest`/`tsc`/`eslint` を直接使用するが、`node_modules/.bin` にローカルインストールされており PATH に不在
- **発見方法**: E2E テスト（`command not found`）
- **修正種別**: 設定変更（`npx vitest`/`pnpm tsc` に変更）
- **予防可能**: **Yes** — `generate-tasks.sh` の後処理で既知ツール名に `npx` を付与すれば防止可能
- **備考**: **データセット全体で最も頻出のバグクラス**（8タスク・11調査エントリ）

#### Bug E3: Windows シンボリックリンク EPERM
- **根本原因**: Claude Code の Task ツールがサブエージェント通信にシンボリックリンクを使用。Windows は管理者権限が必要
- **発見方法**: クラッシュ（実行時 EPERM）
- **修正種別**: コード再構築（Windows では Task ツールを回避）
- **予防可能**: **Yes** — プラットフォーム能力チェックで防止可能

#### Bug E4: `{{FAILURE_CONTEXT}}` テンプレートプレースホルダ未置換
- **根本原因**: バリデーションコマンド内のテンプレート変数が実行前に置換されず、不正なシェル構文に
- **発見方法**: E2E テスト（bash 構文エラー）
- **修正種別**: 機械的ゲート（実行前プレースホルダ検出）
- **予防可能**: **Yes** — `{{...}}` パターンの事前スキャンで防止可能

#### Bug E5: Git Bash コンテキストで `bash: command not found`
- **根本原因**: ハーネス実行コンテキストの PATH に bash バイナリの場所が未含有
- **発見方法**: E2E テスト（command not found）
- **修正種別**: 設定変更（PATH 調整）
- **予防可能**: **Yes** — 環境ブートストラップ検証で防止可能

#### Bug E6: Windows `/tmp` パス乖離（Bash vs Node.js）
- **根本原因**: Bash (MSYS) は `/tmp` → `C:\Users\...\AppData\Local\Temp\` にマッピング、Node.js の Read/Write ツールは `/tmp` → `C:\tmp\`（リテラル）にマッピング
- **発見方法**: 手動観察（一方のツールで書いたファイルが他方で不可視）
- **修正種別**: 設定変更（同一ツール系統で write/read を統一）
- **予防可能**: **Yes** — 絶対パスの一貫使用またはプラットフォーム検出で防止可能

#### Bug E7: `run_claude()` に work_dir パラメータ欠落
- **根本原因**: `bootstrap.sh` が `cd "$PROJECT_ROOT"` を実行するが、WORK_DIR ≠ PROJECT_ROOT の場合に Implementer が誤ったディレクトリで動作
- **発見方法**: E2E テスト（ファイルが間違った場所に作成）
- **修正種別**: コード再構築（`run_claude()` に第8引数 `work_dir` を追加、7箇所修正）
- **予防可能**: **Yes** — `--work-dir` はアーキテクチャで明示的にサポートされており、初期設計に含めるべきだった

#### Bug E8: `research-loop.sh` L872 で `local` が関数外で使用
- **根本原因**: Bash の `local` 変数宣言がファイルスコープに配置
- **発見方法**: E2E テスト（bash エラー）
- **修正種別**: コード再構築（通常の変数代入に変更）
- **予防可能**: **Yes** — ShellCheck または `bash -n` で静的検出可能

---

### カテゴリ 2: 設定ドリフト（4件 / 16%）

#### Bug C1: `development.json` のサーバー設定がプロジェクト非連動
- **根本原因**: `development.json` はハーネス共有設定。対象プロジェクト切替時に前プロジェクトの `start_command`/`health_check_url` が残留
- **発見方法**: E2E テスト（回帰テストで誤ったサーバーが起動）
- **修正種別**: 設定変更（`servers[]` 配列を追加、ただし根本的ドリフト問題にはアーキテクチャ変更が必要）
- **予防可能**: **Yes** — プロジェクト固有サーバー設定は criteria/task-stack に置くべき

#### Bug C2: `task_planner.timeout_sec` が Opus モデルに不十分
- **根本原因**: デフォルト 600s は Opus に不足（初回 API 呼出でコンテキスト構築 + autocompact に ~9分）
- **発見方法**: E2E テスト（Phase 1.5 で9回連続失敗）
- **修正種別**: 設定変更（600 → 1800）
- **予防可能**: **部分的** — モデル別タイムアウトデフォルトは事前設定可能だが、正確なタイミングはプロンプトサイズに依存

#### Bug C3: SC タイムアウト不足
- **根本原因**: Scope Challenger タイムアウト 300s が不足
- **発見方法**: E2E テスト（タイムアウト）
- **修正種別**: 設定変更（300 → 600、`research.json`）
- **予防可能**: **部分的** — 保守的な初期デフォルト + モデルベース自動スケーリングで緩和可能

#### Bug C4: `TIMEOUT_CRITERIA` 変数未定義・未渡し
- **根本原因**: `load_research_models()` が `TIMEOUT_CRITERIA` を定義せず、`generate_criteria()` が `run_claude` に渡さず
- **発見方法**: E2E テスト（タイムアウトまたは未定義変数）
- **修正種別**: コード再構築（変数定義と引渡しを追加）
- **予防可能**: **Yes** — タイムアウトを必要とする関数は空/未定義値で明示的に失敗すべき

---

### カテゴリ 3: 統合ギャップ（5件 / 20%）

#### Bug I1: `run_claude` stdout キャプチャ vs Write ツール直接書込み
- **根本原因**: `run_claude()` は stdout を `.pending` にキャプチャするが、Claude CLI は Write ツールでファイルを直接書き込むことがある（stdout をバイパス）。stdout にはサマリーのみ含まれ、`validate_json()` が拒否
- **発見方法**: サイレント失敗（task-stack.json は正しく生成されたがハーネスが失敗を報告）
- **修正種別**: 機械的ゲート（`check_direct_write_fallback()` を追加、OUTPUT_PATH での直接書込みを検出）
- **予防可能**: **Yes** — デュアル出力チャネル設計（stdout vs ツール書込み）は予見すべきだった

#### Bug I2: 非 JSON 出力の `.pending` ファイル未昇格
- **根本原因**: `run_claude()` は `.pending` に書出し、`validate_json()` が有効な JSON を最終パスに昇格。ただし非 JSON 出力（実装テキスト等）は `validate_json` を通らず昇格されない
- **発見方法**: サイレント失敗（mutation auditor が `implementation-output.txt` を検出不能）
- **修正種別**: 機械的ゲート（呼出し元での昇格追加、`.pending` フォールバック）
- **予防可能**: **Yes** — `.pending` → 昇格パイプラインは JSON 専用を仮定。全出力タイプへの一般化で防止可能

#### Bug I3: 作業ディレクトリ不一致（ハーネス vs 対象プロジェクト）
- **根本原因**: Ralph loop は `forge-research-harness-v1/` で実行されるが、対象プロジェクトは別パス。criteria がパスを指定するが実行環境が無視
- **発見方法**: E2E テスト（`package.json` の ENOENT）
- **修正種別**: コード再構築（`--work-dir` パラメータを `run-regression.sh` と `ralph-loop.sh` に追加）
- **予防可能**: **Yes** — `--work-dir` は初期設計から第一級パラメータであるべきだった

#### Bug I4: Task Planner によるフェーズテストのポートハードコーディング
- **根本原因**: Task Planner が criteria の phases を継承せず、ポート 3000 をハードコードした独自 `exit_criteria` を生成
- **発見方法**: E2E テスト（テストが誤ったポートに接続）
- **修正種別**: 機械的ゲート（`generate-tasks.sh` で phases を機械的に上書き、LLM 依存を排除）
- **予防可能**: **Yes** — フェーズレベル設定は機械的に継承すべきであり、LLM に再生成させるべきでない

#### Bug I5: Implementer がエントリポイント更新を漏らす
- **根本原因**: Implementer がルートファイルを作成するが `index.ts` への import/mount 文を追加しない
- **発見方法**: 手動観察（API ルートで 404）
- **修正種別**: プロンプト変更（「常に既存エントリポイントと統合せよ」指示を追加）
- **予防可能**: **部分的** — HTTP リクエストを送信する L1 テストで機械的に検出可能だが、LLM 統合ギャップはプロンプト駆動開発に固有

---

### カテゴリ 4: バリデーション欠如（3件 / 12%）

#### Bug V1: `in_progress` タスクステータスが放置
- **根本原因**: タスクステータス更新とメトリクス記録がアトミックでない。mutation-auditor 完了後もタスクステータスが `completed` に更新されない
- **発見方法**: 手動観察（ループ終了後もタスクが `in_progress` のまま）
- **修正種別**: 機械的ゲート（ループ終了時に `check_stale_in_progress()` を追加）
- **予防可能**: **Yes** — ステータス遷移は保証付きクリーンアップパターン（trap/finally 相当）で包むべき

#### Bug V2: Implementer のファイル作成ハルシネーション
- **根本原因**: Implementer エージェントが「8/8テスト通過」「ファイル作成済み」と報告するが、実際には Write ツールを呼び出していない。プロンプト強化では修正不能な持続的 LLM ハルシネーション
- **発見方法**: E2E テスト（`validate_l1_file_refs()` ゲートで検出、2026-03-08 追加）
- **修正種別**: 機械的ゲート（L1 テスト実行前にファイル存在を検証）
- **予防可能**: **Yes** — ファイル存在検証は標準的な事前テストゲートとして初期実装すべきだった

#### Bug V3: バリデーションコマンドの vitest `--grep` 構文エラー
- **根本原因**: バリデーションコマンドが `-- --grep "pattern"` を使用するが vitest はこれをフィルタとして認識しない
- **発見方法**: E2E テスト（フィルタされたサブセットではなく全テストが実行）
- **修正種別**: 設定変更（vitest フィルタ構文を修正）
- **予防可能**: **Yes** — バリデーションコマンドはタスク割当て前にドライラン検証すべき

---

### カテゴリ 5: 暗黙的前提（3件 / 12%）

#### Bug A1: `forge-flow.sh` が Bash ツール 600s タイムアウトを超過
- **根本原因**: Forge flow は全フェーズを逐次実行するが、Claude Code の Bash ツールには 600s（10分）のハード上限
- **発見方法**: クラッシュ（プロセス kill）
- **修正種別**: 設定変更（`--daemonize` 使用にドキュメント更新、フェーズ個別実行）
- **予防可能**: **Yes** — 600s プラットフォーム制限はアーキテクチャフェーズから文書化すべきだった

#### Bug A2: Implementer のファイル数がセットアップ/UI タスクでハードリミット超過
- **根本原因**: 3つの複合要因: (1) Implementer がタスクスコープ外のファイル（設定、テスト等）も変更 (2) 未コミットファイルがタスク間で累積 (3) UI タスクは本質的に多ファイル変更が必要
- **発見方法**: E2E テスト（ハードリミット違反で自動ロールバック）
- **修正種別**: プロンプト変更 + 設定変更（タスク粒度ガイドライン。タスク単位コミットは提案済み未完全実装）
- **予防可能**: **Yes** — タスク単位 auto-commit とチェックポイントベース差分カウント（累積除外）で解消可能

#### Bug A3: `retry_after_investigation` フラグが破壊的ループを生成
- **根本原因**: `retry_after_investigation: true` がタスク JSON に残存すると、ralph-loop が Investigator 修正後に Implementer を再実行するが、Implementer のハルシネーションが Investigator の修正を上書き
- **発見方法**: E2E テスト（7回の調査サイクル後に無限ループ検出）
- **修正種別**: コード再構築（フラグ管理の修正が必要）
- **予防可能**: **Yes** — リトライフラグは N 回で自動クリアすべき、または Investigator の修正をコミット後に Implementer を再実行すべき

---

### カテゴリ 6: 状態管理（2件 / 8%）

#### Bug S1: 新規プロジェクトの前提条件が強制されない
- **根本原因**: Ralph loop は git リポジトリ（`git rev-parse` チェック）と `node_modules/` 入り `.gitignore` を必要とするが、これらの前提条件が自動的にチェック/作成されない
- **発見方法**: クラッシュ（即時中断）
- **修正種別**: 機械的ゲート（チェックリスト文書化。プリフライトチェックとして自動化すべき）
- **予防可能**: **Yes** — `forge-flow.sh` または `ralph-loop.sh` でのプリフライト検証ステップ

#### Bug S2: Playwright バージョン不一致
- **根本原因**: Implementer が無効なネストコンテキストで `test.describe()` を使用する E2E テストを生成
- **発見方法**: E2E テスト（Playwright が起動時にクラッシュ）
- **修正種別**: プロンプト変更（implementer プロンプトに構造ルールを追加）
- **予防可能**: **部分的** — `npx playwright test --list` ドライランゲートで構文エラーを機械的に検出可能

---

## 4. 根本原因分布・修正パターン分布

### 根本原因分布

```
環境不一致         ████████  32% (8件)
統合ギャップ       █████     20% (5件)
設定ドリフト       ████      16% (4件)
バリデーション欠如 ███       12% (3件)
暗黙的前提         ███       12% (3件)
状態管理           ██         8% (2件)
```

### 修正パターン分布

```
機械的ゲート追加   █████████  36% (9件)
設定値変更         ███████    28% (7件)
コード構造変更     ██████     24% (6件)
プロンプト変更     ███        12% (3件)
```

**プロンプト変更は最も効果が低い修正種別**（12%）。

### 発見方法分布

| 発見方法 | 件数 | 割合 |
|---------|------|------|
| E2E テスト（自動 L1/回帰） | 20 | 80% |
| 手動観察 | 3 | 12% |
| クラッシュ | 2 | 8% |

### 予防可能性

| 設計改善で予防可能？ | 件数 | 割合 |
|-------------------|------|------|
| **Yes** | 21 | 84% |
| **部分的** | 4 | 16% |
| **No** | 0 | 0% |

---

## 5. アンチパターン一覧（26件）

### Finding 1: `run_claude` の8引数ポジショナルパラメータ
- **場所**: `common.sh:72`
- **影響**: 呼出し側が解読不能。どの引数がどのパラメータに対応するか、位置を数えなければ判別不可

### Finding 2: `CLAUDE_TIMEOUT` グローバル変更パターン
- **場所**: 5ファイル・17参照箇所（`evidence-da.sh:56-67`, `investigation.sh:282,292,295`, `mutation-audit.sh:258,264,269`, `dev-phases.sh:119,129`）
- **影響**: 「保存→変更→復元」パターンは保存と復元の間で早期 return するとグローバル状態を破壊

### Finding 3: `2>/dev/null` が203回使用
- **場所**: コードベース全体
- **影響**: 診断情報の廃棄。特に `common.sh:98` と `common.sh:109` は Claude CLI の全 stderr を抑制 — レートリミットエラー、警告、診断がサイレントに消失

### Finding 4: `|| true` が36回使用
- **場所**: コードベース全体
- **影響**: エラー隠蔽。特に `common.sh:447-451` の git チェックポイント操作 — git が失敗するとチェックポイントが空になり、restore が全ファイルを削除（データ損失リスク）

### Finding 5: PID ファイル管理コードの4重複
- **場所**: `dev-phases.sh:309-313`, `dev-phases.sh:319-323`, `dev-phases.sh:371-376`, `dev-phases.sh:382-386`
- **影響**: 4箇所に逐語的に複製。変更リスクと、2プロセスが同時に read/kill/delete を試みた場合の競合状態

### Finding 6: デッドコード — `TASK_TIMEOUT` と `FEEDBACK_FILE`
- **場所**: `ralph-loop.sh:160`（`TASK_TIMEOUT`）、`research-loop.sh:95`（`FEEDBACK_FILE`）
- **影響**: `TASK_TIMEOUT` は `circuit-breaker.json` から代入されるがどこにも参照されない。`FEEDBACK_FILE` は代入後に未使用。意図の混乱を招く

### Finding 7: `eval "$cmd"` が JSON 設定コマンドを実行
- **場所**: `phase3.sh:79`
- **影響**: コードインジェクションリスク。`development.json` のセットアップコマンドが `eval` で評価される。設定が改竄された場合、任意コード実行

### Finding 8: `RESEARCH_DIR` 変数が3ファイルで異なる意味
- **場所**: `common.sh:9`, `ralph-loop.sh:47`, `research-loop.sh:93`, `generate-tasks.sh:67`
- **影響**: `common.sh` では「エラー記録のコンテキスト識別子」、`ralph-loop.sh` では `"dev-session-20260308-120000"` のような文字列ラベル、`research-loop.sh` では `".docs/research/..."` のような実ディレクトリパス。`common.sh` を source するスクリプトによって意味が完全に異なる

### Finding 9: 並列リサーチャーがロックなしで共有 METRICS_FILE に書込み
- **場所**: `research-loop.sh:366-375,385`
- **影響**: リサーチャーが `&` でバックグラウンドプロセスとして起動され、各々が `$METRICS_FILE` に同時書込みの可能性。シェルの `>>` 追記は複数行出力でアトミックでない。同時完了で JSONL 行が破損する可能性

### Finding 10: タイムアウト値が複数箇所で矛盾するデフォルト
- **詳細**:

| タイムアウト | circuit-breaker.json | development.json | コードデフォルト |
|------------|---------------------|------------------|----------------|
| Claude タイムアウト | `claude_timeout_sec: 600` | （モデル経由で暗黙的） | `common.sh:79 fallback 600` |
| タスクタイムアウト | `task_timeout_sec: 600` | `implementer.timeout_sec: 900` | — |
| L1 テストタイムアウト | — | `default_timeout_sec: 200` | `ralph-loop.sh:176 fallback 60` |

- `TASK_TIMEOUT`（circuit-breaker.json の 600）は `ralph-loop.sh:160` でロードされるが**実際には使用されない** — 実際のタスクタイムアウトは `development.json` の `implementer.timeout_sec` から

### Finding 11: `development_abort_triggers` 配列はドキュメント専用
- **場所**: `circuit-breaker.json:31-62`
- **影響**: 5エントリの condition/action が含まれるが**コードで一切パースされない**。実際のサーキットブレーカーロジックは `ralph-loop.sh:684-725` にハードコード。設定に偽装されたドキュメント

### Finding 12: サーバー設定がプロジェクト非連動
- **場所**: `development.json:29-33`
- **影響**: `start_command: "npm run dev"` と `health_check_url: "http://localhost:3001"` はハーネス全体の設定であり、対象プロジェクト変更時に適応しない

### Finding 13: `common.sh` は God Object
- **場所**: `common.sh`（867行・26関数）
- **影響**: 17の責務ドメインが1ファイルに集約:
  1. ロギング（`log`, `now_ts`）
  2. テンプレートレンダリング（`render_template`）
  3. CRLF ハンドリング（`jq_safe`）
  4. Claude CLI ラッピング（`run_claude`, `check_direct_write_fallback`）
  5. JSON バリデーション — 4層回復（`validate_json`）
  6. エラー追跡（`record_error`, `resolve_errors`）
  7. メトリクス（`metrics_start`, `metrics_record`, `record_validation_stat`）
  8. 依存関係チェック（`check_dependencies`）
  9. 人間通知（`notify_human`）
  10. Git 安全性（`safe_work_dir_check`）
  11. Git チェックポイント（`task_checkpoint_create`, `task_checkpoint_restore`）
  12. ファイル変更検証（`validate_task_changes`）
  13. ロック済みアサーション検証（`validate_locked_assertions`）
  14. 進捗追跡（`update_progress`）
  15. サーバー URL 抽出（`get_server_url`, `config_get`）
  16. テストファイル検証（`validate_l1_file_refs`）
  17. リトライロジック（`retry_with_backoff`）

### Finding 14: `ralph-loop.sh` がオーケストレーションとデータアクセスを混在
- **場所**: `ralph-loop.sh`
- **影響**: メインオーケストレーションループとデータアクセス関数（`get_next_task`, `get_task_json`, `update_task_status`, `update_task_fail_count`, `count_tasks_by_status`, `sync_task_stack`）を含有。`task-stack.sh` として分離可能

### Finding 15: `http://localhost:3000` フォールバックのハードコード
- **場所**: `common.sh:770`（`get_server_url()` デフォルト）、`phase3.sh:92`
- **影響**: `development.json` が不在でサーバーが必要な場合、ハードコードされた仮定がサイレントに適用

### Finding 16: Node.js エコシステム前提のハードコード
- **場所**:
  - `ralph-loop.sh:505`: `PATH="$WORK_DIR/node_modules/.bin:$PATH"`
  - `phase3.sh:222`: 同上
  - `mutation-runner.sh:153`: 同上
  - `mutation-audit.sh:87-89`: `find ... -name '*.ts' -o -name '*.js' -o -name '*.tsx' -o -name '*.jsx'`
- **影響**: ハーネスは汎用リサーチ+開発システムとして宣伝されているが、開発ループに深い Node.js/TypeScript 前提が組み込まれている

### Finding 17: ロックなし PID ファイル管理
- **場所**: `dev-phases.sh:309-313,319-323,371-376,382-386`
- **影響**: サーバー PID クリーンアップブロックが4箇所に逐語的複製。2プロセスが同時に read/kill/delete を試みた場合、一方が `|| true` でサイレントに失敗

### Finding 18: 並列リサーチャーの `>> $METRICS_FILE` 無調整
- （Finding 9 と同一。アンチパターン追跡用に別記）

### Finding 19: 並行書込み中の非アトミック状態ファイル読取り
- **場所**: `ralph-loop.sh:866-872`
- **影響**: メインループが書き込んだ直後に `jq` で `task-stack.json` を読取り。シェルスクリプトにはトランザクショナル読取りがなく、部分的に書き込まれた `.tmp` ファイルが破損として読まれる可能性

### Finding 20: `_vj_promote` と `_vj_cleanup` の内部関数がグローバルスコープに漏洩
- **場所**: `common.sh:156-158`
- **影響**: `validate_json()` 内で定義された `_vj_promote()` と `_vj_cleanup()` が `$_vj_pending` と `$file` をクロージャ。bash では関数定義はグローバルスコープ — 再帰呼出し時に名前衝突のリスク

### Finding 21: 変数シャドーイング — `RESEARCH_DIR` がスクリプト間で異なる意味
- （Finding 8 と同一。アンチパターン追跡用に別記）

### Finding 22: `CIRCUIT_BREAKER_CONFIG` が3箇所で同一定義
- **場所**: `ralph-loop.sh:150`, `forge-flow.sh:104`, `generate-tasks.sh:323`
- **影響**: 全て同一（`"${PROJECT_ROOT}/.forge/config/circuit-breaker.json"`）だが独立にハードコード。パス変更時に3ファイルの更新が必要

### Finding 23: デッドコード — `TASK_TIMEOUT` 未使用
- **場所**: `ralph-loop.sh:160`
- **影響**: `circuit-breaker.json` から代入されるがコードベースのどこにも参照されない

### Finding 24: デッドコード — `FEEDBACK_FILE` 未使用
- **場所**: `research-loop.sh:95`
- **影響**: 宣言後に参照なし

### Finding 25: PID ファイルクリーンアップの4重複
- （Finding 5・17 と同一。重複追跡用に分類）

### Finding 26: `run_claude` サブシェルでの不整合なエラーハンドリング
- **場所**: `common.sh:94-106`
- **影響**: `work_dir` 指定時、エラーはサブシェル内でキャッチ。しかし `local exit_code=$?` は `||` ブロック内でサブシェル式全体の終了コードをキャプチャし、特定のコマンドのものではない。`cd` 失敗（return 1）と Claude CLI 一般失敗の終了コードが同一で区別不能

---

## 6. アーキテクチャ依存グラフ

### ソースチェーン

```
bootstrap.sh
  sources -> common.sh

全ループスクリプトが bootstrap.sh を source:
  forge-flow.sh      -> bootstrap.sh -> common.sh
  ralph-loop.sh      -> bootstrap.sh -> common.sh
                        then sources:
                          -> mutation-audit.sh
                          -> investigation.sh
                          -> dev-phases.sh
                          -> phase3.sh
                          -> evidence-da.sh
  research-loop.sh   -> bootstrap.sh -> common.sh
  generate-tasks.sh  -> bootstrap.sh -> common.sh
  mutation-runner.sh  -> bootstrap.sh -> common.sh
  dashboard.sh       -> bootstrap.sh -> common.sh
```

### データフロー — ファイルベース状態バス（`.forge/state/`）

| ファイル | 目的 | 読取り側 | 書込み側 |
|---------|------|---------|---------|
| `task-stack.json` | 中央タスクレジストリ | ralph-loop, generate-tasks, phase3, investigation, dev-phases | ralph-loop, generate-tasks, investigation |
| `current-research.json` | リサーチ状態 | forge-flow | research-loop |
| `flow-state.json` | レジューム状態 | forge-flow | forge-flow |
| `loop-signal` | フェーズ間シグナリング（RESEARCH_REMAND, APPROACH_PIVOT） | investigation.sh | investigation.sh |
| `errors.jsonl` | エラーログ | 全ステージ | 全ステージ via `record_error()` |
| `metrics.jsonl` | タイミングメトリクス | dashboard | 全ステージ via `metrics_record()` |
| `decisions.jsonl` | リサーチ判断 | — | research-loop |
| `investigation-log.jsonl` | Investigator 結果 | — | investigation.sh |
| `approach-barriers.jsonl` | アプローチピボットコンテキスト | — | investigation.sh |
| `progress.json` | ダッシュボード用リアルタイム進捗 | dashboard | ralph-loop |
| `notifications/*.json` | 人間通知キュー | ユーザー | common.sh via `notify_human()` |
| `server.pid` | バックグラウンドサーバー PID | dev-phases | dev-phases |
| `checkpoints/{task_id}.*` | Git チェックポイント（patch, untracked, ref） | ralph-loop（restore） | ralph-loop（create） |

### プロセス間通信パターン

1. **ファイルシグナリング**: `loop-signal` ファイルを `check_loop_signal()` で読取り/削除（`investigation.sh:337-354`）
2. **jq 経由の状態変更**: `task-stack.json` は `jq ... > .tmp && mv .tmp` パターンでアトミック更新（例: `ralph-loop.sh:360-371`）
3. **サブプロセス呼出し**: `forge-flow.sh` が `research-loop.sh`, `generate-tasks.sh`, `ralph-loop.sh` を `bash` で呼出し（行249, 279, 352）

### Claude CLI 呼出しサイト（13箇所）

| ファイル | 行 | エージェント |
|---------|-----|------------|
| `ralph-loop.sh` | 548 | Implementer |
| `research-loop.sh` | 264 | Scope Challenger |
| `research-loop.sh` | 344 | Researcher |
| `research-loop.sh` | 469 | Synthesizer |
| `research-loop.sh` | 524 | Criteria |
| `research-loop.sh` | 568 | Report |
| `investigation.sh` | 114 | Investigator |
| `investigation.sh` | 284 | Approach Explorer |
| `mutation-audit.sh` | 209 | Strengthen |
| `mutation-audit.sh` | 260 | Mutation Auditor |
| `dev-phases.sh` | 121 | Checklist Verifier |
| `evidence-da.sh` | 59 | Evidence DA |
| `generate-tasks.sh` | 173 | Task Planner |

---

## 7. テストカバレッジ詳細

### テストスイート一覧

| テストファイル | アサーション数 | カバー範囲 |
|-------------|-------------|-----------|
| `test-ralph-engine.sh` | 27 | サーキットブレーカー、タスクライフサイクル、get_next_task、handle_task_pass/fail |
| `test-validate-json.sh` | 18 | validate_json 全層、.pending ライフサイクル、エラー記録 |
| `test-assertions.sh` | 24 | Locked Decision Assertions + L1 ファイル参照検証 |
| `test-safety.sh` | ~25 | S1-S7 安全メカニズム（git チェック、チェックポイント、ロールバック、保護ファイル） |
| `test-evidence-da.sh` | ~20 | Evidence-DA サブシステム |
| `test-config-integrity.sh` | ~10 | 設定ファイルスキーマ検証 |
| `test-research-config.sh` | ~15 | リサーチ設定パース |
| `test-research-e2e.sh` | ~20 | リサーチループ E2E（Claude CLI 必要） |
| `test-helpers.sh` | 0（ライブラリ） | 共有テストユーティリティ |
| `run-all-tests.sh` | 0（ランナー） | テストオーケストレータ |

### テスト済み 35関数

**`test-ralph-engine.sh` より**: `check_circuit_breakers`, `get_next_task`, `get_task_json`, `update_task_status`, `update_task_fail_count`, `count_tasks_by_status`, `handle_task_pass`, `handle_task_fail`, `load_development_config`, `sync_task_stack`, `check_loop_signal`

**`test-validate-json.sh` より**: `validate_json`, `record_error`, `record_validation_stat`

**`test-assertions.sh` より**: `validate_locked_assertions`, `validate_l1_file_refs`

**`test-safety.sh` より**: `safe_work_dir_check`, `task_checkpoint_create`, `task_checkpoint_restore`, `validate_task_changes`

**その他テストファイルより**: `test-evidence-da.sh`, `test-config-integrity.sh`, `test-research-config.sh` で追加の関数がカバーされ合計35に到達

### 未テスト 46関数（重要度順）

| 関数 | ファイル | リスクレベル |
|------|---------|------------|
| `run_claude` | `common.sh:72` | **HIGH** — コア LLM ラッパー、8パラメータ、サブシェルロジック、タイムアウト処理 |
| `run_task` | `ralph-loop.sh:509` | **HIGH** — メインタスク実行オーケストレーター、7関数を呼出し |
| `main`（ralph） | `ralph-loop.sh:782` | **HIGH** — メインループ、dev-phase 遷移、Phase 3 リトライ |
| `build_implementer_prompt` | `ralph-loop.sh:398` | **HIGH** — ロック済みアサーション付き複雑なプロンプト構築 |
| `run_investigator` | `investigation.sh:15` | **HIGH** — 失敗診断、スコープルーティングロジック |
| `run_approach_explorer` | `investigation.sh:220` | **HIGH** — 代替アプローチ探索 |
| `run_mutation_audit` | `mutation-audit.sh:223` | **HIGH** — 複数試行監査ループ |
| `build_mutation_auditor_prompt` | `mutation-audit.sh:68` | **HIGH** — `find -newer` によるファイル検出 |
| `run_test_strengthen` | `mutation-audit.sh:158` | **HIGH** — テスト強化サブループ |
| `handle_dev_phase_completion` | `dev-phases.sh:265` | **HIGH** — 回帰テスト + auto-commit + チェックポイント UI |
| `detect_dev_phases` | `dev-phases.sh:14` | MEDIUM — task-stack からのフェーズ検出 |
| `run_phase3` | `phase3.sh:125` | **HIGH** — フル L2 統合テスト |
| `run_scope_challenger` | `research-loop.sh:231` | MEDIUM — リサーチ SC ステージ |
| `run_researchers` | `research-loop.sh:288` | MEDIUM — 並列/逐次リサーチャー実行 |
| `run_synthesizer` | `research-loop.sh:422` | MEDIUM — リサーチ統合 |
| `generate_criteria` | `research-loop.sh:493` | MEDIUM — criteria 生成 |
| `render_template` | `common.sh:43` | MEDIUM — テンプレートレンダリング（全プロンプト構築で使用） |
| `check_direct_write_fallback` | `common.sh:127` | MEDIUM — Write ツールフォールバック検出 |
| `resolve_errors` | `common.sh:233` | LOW — エラー解決追跡 |
| `notify_human` | `common.sh:331` | LOW — 通知システム |
| `get_server_url` | `common.sh:767` | LOW — サーバー URL 抽出 |
| `check_stale_in_progress` | `ralph-loop.sh:730` | LOW — 放置状態の回復 |

その他 ~24 関数が未テストであり合計46に到達。

### カバレッジ要約

- **テスト済み**: 純粋関数・データアクセス関数（リーフ層）
- **未テスト**: オーケストレーション関数・プロンプト構築関数（コア層）
- **見積もり**: 関数の ~43% に直接テストカバレッジ
- **致命的ギャップ**: コアオーケストレーション関数（main ループ, `run_task`, フェーズ遷移）はユニットテスト**完全ゼロ**

---

## 8. 設定値の冗長・矛盾

### 設定ファイル概要

| ファイル | リーフ設定値数 | 目的 |
|---------|-------------|------|
| `circuit-breaker.json` | 15 | リミット、安全トリガー、保護パターン |
| `development.json` | 21 | モデル選択、タイムアウト、安全性、L1/L2 設定、サーバー |
| `mutation-audit.json` | 12 | ミューテーションテスト設定 |
| `research.json` | 13 | リサーチモデル/ツール/タイムアウト設定 |
| **合計** | **61** | |

### 具体的な冗長・矛盾

#### タイムアウト値の多重定義と矛盾デフォルト

| タイムアウト | circuit-breaker.json | development.json | コードデフォルト |
|------------|---------------------|------------------|----------------|
| Claude タイムアウト | `claude_timeout_sec: 600` | （モデル経由で暗黙的） | `common.sh:79 fallback 600` |
| タスクタイムアウト | `task_timeout_sec: 600` | `implementer.timeout_sec: 900` | — |
| L1 テストタイムアウト | — | `default_timeout_sec: 200` | `ralph-loop.sh:176 fallback 60` |

`TASK_TIMEOUT`（circuit-breaker.json: 600）は `load_development_config()` でロードされるが、**実際のタスクタイムアウトは `development.json` の `implementer.timeout_sec` が使用される**。

#### ドキュメント偽装設定

`circuit-breaker.json:31-62` の `development_abort_triggers` は5エントリの condition/action を含むが、**コードでは一切パースされない**。実際のサーキットブレーカーロジックは `ralph-loop.sh:684-725` にハードコード。

#### プロジェクト非連動サーバー設定

`development.json:29-33` の `start_command` と `health_check_url` はハーネス全体の設定。対象プロジェクト変更時に自動更新されない。

#### パス定数の3重複

`CIRCUIT_BREAKER_CONFIG` が `ralph-loop.sh:150`, `forge-flow.sh:104`, `generate-tasks.sh:323` で同一パスを独立にハードコード。

---

## 9. 総合評価と改善優先順位

### 総合評価

**Forge Harness は「動作する概念実証」から「運用可能なツール」への移行段階にある。**

設計ビジョン — 自律リサーチ → タスク分解 → 実装 → テスト → 調査ループ — は野心的であり、システムは能力を実証している（18タスクのエンドツーエンド完了）。しかし、コードは有機的に成長し、以下の構造的負債を抱えている:

1. **信頼境界の不在**: LLM 出力とシェルコマンド実行の間にサニタイザーがない
2. **契約の曖昧性**: 関数間依存がグローバル変数コメントで記述され、実行時の強制はゼロ
3. **テスト偏重**: リーフ関数はテスト済み、コアオーケストレーション関数は未テスト
4. **後付けプラットフォームサポート**: Windows 問題は体系的にではなく個別に対処

**バグの84%** が設計改善で予防可能と分類される。現在のパッチ蓄積パターンはコード複雑性を増加させ、次のバグを招く。

### 体系的パターン

| パターン | バグ割合 | 説明 |
|---------|---------|------|
| LLM 生成コマンドは信頼できない | 48% | bare ツール名、パス区切り、構文エラー、プレースホルダ未置換、ポートハードコード |
| `.pending` パイプラインは JSON 専用・単一チャネル前提 | 12% | Write ツール直接書込み、非JSON 出力、作業ディレクトリ不一致 |
| プラットフォーム可搬性は第一級の関心事でなかった | 20% | パス区切り、シンボリックリンク権限、PATH 差異、`/tmp` 解決 |
| 設定は動的であるべき場所で静的 | 16% | タイムアウト、サーバー設定、モデル固有パラメータ |
| Implementer ハルシネーションはプロンプトエンジニアリングで解決不能 | 8% | 1タスクで7回発生、複数ラウンドの調査+強化を経て、機械的ゲートが必要 |
| 未コミット状態の累積がカスケード障害を引き起こす | 8% | フェーズ単位コミットで完了タスクの変更が次タスクの差分カウントに漏洩 |

### 改善優先順位

#### Priority 1: 即時対応（HIGH リスク軽減）

| # | 対策 | 対象 Finding | 期待効果 |
|---|------|------------|---------|
| 1 | `CLAUDE_TIMEOUT` をグローバル状態から除去 | F2 | `run_claude` は既にパラメータ7でタイムアウトを受取り。全 save/mutate/restore パターンを明示的引渡しに置換 |
| 2 | 必須グローバル変数のガードアサーション追加 | F7 | 各 source されるモジュールの先頭で必須グローバルを検証（例: `[[ -n "${TASK_STACK:-}" ]] \|\| { log "TASK_STACK required"; exit 1; }`） |
| 3 | LLM 生成コマンドのサニタイズ層追加 | E1,E2,E4,V3 | (a) bare ツール名に `npx` 付与 (b) パス区切り正規化 (c) テンプレートプレースホルダ検証 (d) コマンド構文検証 |
| 4 | `run_task`, `main`, `run_investigator` のテスト追加 | F13,F14 | 最も複雑なオーケストレーション関数のテストカバレッジゼロを解消 |

#### Priority 2: 構造改善（MEDIUM 技術的負債削減）

| # | 対策 | 対象 Finding | 期待効果 |
|---|------|------------|---------|
| 5 | `common.sh` を分割 | F13 | 少なくとも: `logging.sh`, `claude-cli.sh`, `json-validation.sh`, `git-safety.sh`, `notifications.sh` |
| 6 | タスク単位コミット（フェーズ単位→タスク単位） | A2 | 未コミットファイル累積問題の解消、各タスクの差分を分離 |
| 7 | `run_claude()` 出力契約の再設計 | I1,I2 | stdout と期待出力ファイルパスの両方をチェック、JSON/非JSON 両対応 |
| 8 | PID クリーンアップのヘルパー関数抽出・重複排除 | F5,F17 | `dev-phases.sh` の4重複を解消 |

#### Priority 3: 設定整理（LOW 保守性向上）

| # | 対策 | 対象 Finding | 期待効果 |
|---|------|------------|---------|
| 9 | デッドコード除去 | F6,F23,F24 | `TASK_TIMEOUT`, `FEEDBACK_FILE`, `development_abort_triggers` 配列を除去 |
| 10 | 動的設定解決 | C1,F10,F12 | タイムアウト・サーバー設定・ツールパスを対象プロジェクトの `package.json` と選択モデルから導出 |
| 11 | `CIRCUIT_BREAKER_CONFIG` パスの一元化 | F22 | 3箇所のハードコードを `common.sh` の単一定義に統合 |
| 12 | `eval` の除去 | F7 | `phase3.sh:79` の `eval "$cmd"` を安全なコマンド実行パターンに置換 |

---

*Generated: 2026-03-08 | Scope: forge-research-harness-v1 full codebase analysis*
