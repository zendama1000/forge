# make-tweet アカウント切替機能 実装計画リサーチレポート

**リサーチID**: `2026-04-17-bcb3f8-070312`
**生成日**: 2026-04-17
**モード**: validate（ロック決定の撤回は推奨しない、実装経路の具体化）
**最終判定**: **GO**（Phase 1.5 タスク分解への引継ぎ準備完了）

---

## 1. エグゼクティブサマリー

make-tweet プロジェクトに以下の要件でアカウント切替機能を追加する実装計画を、6視点（technical/cost/risk/alternatives/migration_safety/cli_ux_consistency）で検証した。

- `accounts/<name>/genres/<g>/` 階層導入
- 既存 `genres/` データの無損失移行
- `refs` 二系統（account.yaml.refs[] + accounts/<name>/refs/）サポート
- CLI 後方互換 + `--account` フラグ / `account` サブコマンド
- Claude Code skill との整合（独自状態を持たない read-only 参照）
- 品質低下禁止（カバレッジ閾値ゲート）

**結論**: 全8ロック決定と整合する3フェーズ（MVP / Core / Polish）実装計画が確立。新規依存は最小限（`write-file-atomic` + `graceful-fs` のみ、Zod は fallback 時のみ）で実現可能。

---

## 2. 調査範囲（Investigation Plan）

### 2.1 コアクエスチョン（10項目）

| # | 項目 | 扱い |
|---|---|---|
| 1 | 既存 genres/ → accounts/default/ 移行のコマンド化要否 | 解決：migration サブコマンド + 3段ゲート |
| 2 | refs[] と refs/ ディレクトリの読込順・マージ規則・サイズ上限 | 解決：refs/ 優先 → yaml.refs[] 後勝ち、soft-cap 150KB |
| 3 | current_account の永続化形式 | 解決：`accounts/.current` 単一ファイル方式（git HEAD 準拠） |
| 4 | account.yaml のスキーマとバリデーション戦略 | 解決：手書き config-validation.ts 拡張（新規依存ゼロ） |
| 5 | account rm の要否 | **Polish 以降に延期**（MVP/Core 対象外） |
| 6 | ジャンル共有 refs とアカウント共有 refs の共存要否 | **out-of-scope 宣言**（MVP ではアカウント refs のみ） |
| 7 | Claude Code skill 側の切替 UX | 解決：Dynamic Context Injection で read-only 参照 |
| 8 | GENRES_DIR 前提テストの書き換え戦略 | 解決：5ファイル改修 + setupAccount() fixtures |
| 9 | lib/ シグネチャの扱い（path-arg vs context object） | 解決：path-arg 維持（現行設計が parameterized 済み） |
| 10 | default_account のブートストラップ動作 | 解決：migration コマンド経由で明示生成 |

### 2.2 境界（Boundaries）

- **Depth**: 実装に踏み込める粒度の設計判断まで決定（スキーマ案、CLI フラグ仕様、マージ規則、移行手順、テスト戦略）
- **Breadth**: make-tweet 内部の CLI / lib / tests / skill 境界に閉じる
- **Cutoff**: ロック決定8項目は疑問視・代替提案禁止。新規依存は『不要』を第一候補

---

## 3. 視点別サマリー

### 3.1 Technical（技術的実現性）

| 論点 | 結論 | 信頼度 |
|---|---|---|
| パス解決 | ESM下で `import.meta.url` + `fileURLToPath` + `path.join` を `src/lib/paths.ts` に集約 | high |
| スキーマ検証 | Zod を使う場合は `.extend()` パターン、v4 では `.merge()` は deprecated | high |
| current_account ポインタ | `accounts/.current` 単一ファイル + `write-file-atomic`。**Windows EPERM（Defender/Search Indexer ロック）が既知未修正**のため `graceful-fs` リトライ必須 | high |
| refs マージ順 | 「account 固有 > global」原則で一貫させれば先勝ち/後勝ちどちらでも可 | medium |
| CLI フラグ解決順 | Commander.js/yargs で `flag > env` はフレームワーク層、`.current > default` はアプリ層の二段構成 | high |

### 3.2 Cost（工数・リソース）

| 項目 | 見積工数 | 備考 |
|---|---|---|
| GENRES_DIR → ACCOUNTS_DIR テスト改修（5ファイル） | **9〜14h** | `cli-e2e.test.ts` の setupGenre() 45箇所が最大負荷 |
| fixtures 再設計 | 2〜3h | setupAccount() + accounts/<name>/genres/ ヘルパー |
| lib/ path-arg 維持案 | **2〜4h** | ほぼ無改修 |
| lib/ context object 案 | 11〜19h | 維持案の 3〜5倍（差分 9〜15h） |
| refs soft-cap + warn 実装 | 2〜4h | シンプル、新規依存なし |
| account rm + ローカルバックアップ | 3〜4h 追加 | Polish 以降に延期 |

**結論**: lib/ は現行パス引数設計を維持、テスト改修を独立タスクに切り出す。

### 3.3 Risk（失敗モード）

| リスク | 対策 |
|---|---|
| 自動移行で `genres/` 破壊 | dry-run + 自動バックアップ + 確認プロンプトの3段ゲート |
| `--account` 未指定時の暗黙 default 書込事故 | 破壊的操作に『対象アカウント: X で実行します [y/N]』+ `-y` バイパス |
| refs マージでの機密混入（OWASP LLM01） | allowlist デフォルト拒否 + シークレットフィルタ（`*.env`, `*secret*`, `*credential*`, `*token*`） |
| `GENRES_DIR` 依存の regress 見落とし | vitest `coverage.all:true` + `coverage.include` 明示 + CI 閾値ゲート |
| `accounts/.current` の git 汚染 | `.gitignore` に明示追加 + `git rm --cached` 手順を README に記載 |

### 3.4 Alternatives（代替案比較）

| 選択肢 | 採用 | 理由 |
|---|---|---|
| current_account 保存: `accounts/.current` / `.accountrc` / yaml active フラグ / env | **accounts/.current** | git HEAD 最忠実、atomic write 可 |
| refs マージ: yaml.refs[]先 / refs/先 / 明示 order | **refs/ 先 → yaml.refs[] 後勝ち** | ディレクトリ配置は最も固有性高、業界標準の後勝ち準拠 |
| スキーマ検証: 手書き / Zod / JSON Schema+AJV | **手書き拡張** | 新規依存最小ロック決定に合致、Zod v4 mini は fallback |
| lib/ API: path-arg / context obj / overload | **path-arg 維持** | 現行 parameterized 済み、工数対効果最良 |
| 移行手段: サブコマンド / 起動時自動検出 / README のみ | **migration サブコマンド** | 事故率・実装コストのバランス最良 |

### 3.5 Migration Safety（移行安全）

| 論点 | 結論 |
|---|---|
| バックアップ | `.backup-YYYYMMDD/` 自動作成 → ユーザー承認プロンプト（デフォルト N）→ 実行 |
| 冪等性検出 | `migration-state.json` の `schema_version` フィールド（Flyway/Alembic 方式）> マーカーファイル |
| 部分移行検出 | 旧パス `genres/` と新パス `accounts/default/genres/` の両存在 + `status:in_progress` フラグ |
| path resolver 互換シム | 一括移行で完全置換可能なら**不要**。移行完了と同時に参照先を切替 |
| `history.jsonl` / `queue.jsonl` | `accounts/default/` 配下へ移動。queue.jsonl は停止中に実施 |

### 3.6 CLI UX Consistency（kubectl 風整合性）

| 設計原則 | 採用パターン |
|---|---|
| コマンド動詞 | `account use`（永続切替）/ `list`（テーブル+*）/ `current`（単一行）/ `init`（対話型） |
| 機械可読出力 | `-o json` フラグ（kubectl 準拠）、`--no-headers` でスクリプト連携 |
| 解決優先順位 | `--account flag` > `$MAKE_TWEET_ACCOUNT` > `accounts/.current` > `'default'` の4層 |
| Claude Code skill 連携 | Dynamic Context Injection `!$(tsx src/cli.ts account current)` で read-only 参照、skill 独自状態は持たない |
| 未知アカウント時のエラー | **エラー + 一覧 + did-you-mean（fuzzy match） + `account init` 誘導**の4段階 |

---

## 4. 矛盾点と解決（Contradictions）

| 視点間 | 論点 | 解決 |
|---|---|---|
| cost ↔ technical | lib/ API 設計（path-arg vs context） | path-arg 維持が Primary。新規 accounts 関連 lib 関数のみ context 対応シグネチャで設計し将来移行の余地を残す |
| alternatives ↔ technical | refs マージ順（先勝ち vs 後勝ち） | 「refs/ 最優先 → yaml.refs[] 後勝ち（後読み上書き）」に統一 |
| risk ↔ cost | 移行 UX の厳格性 | 移行コマンドは 3段ゲート必須（risk採用）、account rm は MVP 外（cost の優先度判断採用） |
| migration_safety ↔ risk | `migration-state.json` を git 管理するか | 役割分離：`migration-state.json` は git 管理、`accounts/.current` は .gitignore |

---

## 5. 推奨実装計画（3フェーズ）

### 5.1 MVP フェーズ

| # | 項目 | 備考 |
|---|---|---|
| 1 | `src/lib/paths.ts` 新設 | `getAccountDir` / `getGenreDir` / `getAccountRefsDir` |
| 2 | `account.yaml` スキーマ（手書き拡張） | name 必須 / description/refs/default_theory/default_count/tags 任意 / version フィールド |
| 3 | `accounts/.current` 単一ファイル方式 | `write-file-atomic` + `graceful-fs` リトライ、`.gitignore` 追加 |
| 4 | 解決チェーン4層 | `commander.js` `.env()` で CLI/env 層、null coalescing chain でファイル/default 層 |
| 5 | account サブコマンド4点 | use / list（テーブル+* / -o json）/ current（単一行）/ init（対話型） |
| 6 | 未知アカウント時のエラー4段階 | エラー + 一覧 + did-you-mean + init 誘導 |
| 7 | `account migrate` コマンド | `--dry-run` デフォルト有効 + `.backup-YYYYMMDD/` + 確認プロンプト + `-y/--yes` + `migration-state.json` |
| 8 | refs マージ実装 | `accounts/<name>/refs/` 優先 → `account.yaml.refs[]` 後勝ち、soft-cap 150KB、allowlist シークレットフィルタ |
| 9 | 破壊的操作の確認プロンプト | generate / post / enqueue 未指定時、`-y` バイパス |
| 10 | Claude Code skill 連携 | Dynamic Context Injection `!$(tsx src/cli.ts account current)` |

### 5.2 Core フェーズ

| # | 項目 |
|---|---|
| 11 | 既存 vitest 5ファイル改修（setupGenre → setupAccount、推定 9〜14h） |
| 12 | `vitest.config` に `coverage.all:true` + `coverage.include` + CI カバレッジ閾値ゲート |
| 13 | 新規 accounts 系ユニットテスト（path resolver / schema / fallback chain / migration 冪等性 / refs マージ / シークレットフィルタ） |

### 5.3 Polish フェーズ

| # | 項目 |
|---|---|
| 14 | `account rm` サブコマンド（`.accounts-trash/YYYYMMDD-<name>/` 方式、新規依存ゼロ） |
| 15 | `--output=json` / `--no-headers` オプション |
| 16 | README + CLI `--help` で優先順位・移行手順の明示ドキュメント化 |

---

## 6. 受入基準（Implementation Criteria）

### 6.1 Layer 1（ユニットテスト・型チェック・lint）: 11項目

| ID | 内容 | 検証コマンド |
|---|---|---|
| L1-001 | `src/lib/paths.ts` の ESM パス解決 + パストラバーサル阻止 | `npx vitest run src/lib/paths.test.ts` |
| L1-002 | `account.yaml` スキーマ検証（手書き拡張） | `npx vitest run src/lib/config-validation.test.ts` |
| L1-003 | 解決チェーン4層の優先順位 | `npx vitest run src/cli/resolve-account.test.ts` |
| L1-004 | `accounts/.current` の atomic write + EPERM リトライ | `npx vitest run src/lib/current-account.test.ts` |
| L1-005 | account サブコマンド4点の kubectl 風 UX | `npx vitest run src/cli/commands/account.test.ts` |
| L1-006 | refs マージ規則 + シークレットフィルタ + soft-cap | `npx vitest run src/lib/refs-merger.test.ts` |
| L1-007 | migration 3段ゲート + 冪等性 | `npx vitest run src/cli/commands/migrate.test.ts` |
| L1-008 | 破壊的操作の確認プロンプト + `-y` バイパス | `npx vitest run src/cli/confirm-prompt.test.ts` |
| L1-009 | TypeScript strict 型チェック通過 | `npx tsc --noEmit` |
| L1-010 | 既存 vitest 改修 + coverage 閾値 | `npx vitest run --coverage` |
| L1-011 | ESLint 通過 + `.gitignore` に `accounts/.current` | `npx eslint src/ && grep ...` |

### 6.2 Layer 2（統合・E2E）: 5項目

| ID | 内容 |
|---|---|
| L2-001 | 複数アカウント並列運用（init → use → generate/post がアカウントごとに独立） |
| L2-002 | migration E2E（既存 genres/ → accounts/default/ へデータ損失なく移行） |
| L2-003 | Windows/macOS/Linux 3OS で atomic write 動作 |
| L2-004 | Claude Code skill の Dynamic Context Injection 動作 |
| L2-005 | 後方互換（`--account` なしで default 解決 + 確認プロンプト） |

### 6.3 Layer 3（受入・構造検証・LLM judge）: 7項目

| ID | strategy | 内容 |
|---|---|---|
| L3-001 | structural | `account list -o json` のスキーマ検証 + テーブル * マーク検証 |
| L3-002 | cli_flow | init → use → generate → history → current のアカウント分離フロー |
| L3-003 | cli_flow | migration 3段ゲート + 冪等性 + rollback |
| L3-004 | context_injection | skill が accounts/.current を読み独自状態を持たない |
| L3-005 | llm_judge | 未知アカウントエラーメッセージの4段階（閾値 0.80） |
| L3-006 | structural | refs soft-cap warn + シークレット非混入 |
| L3-007 | cli_flow | 確認プロンプト + `-y` + 非TTY環境の挙動マトリクス |

---

## 7. リスクとフォールバック

### 7.1 主要リスク

| リスク | 軽減策 |
|---|---|
| Windows EPERM（write-file-atomic 既知バグ） | `graceful-fs` + 指数バックオフ独自実装を fallback |
| `cli-e2e.test.ts` setupGenre() 45箇所改修でファイル数制限超過 | Phase 1.5 でテスト改修を 1〜2ファイル単位に分割、タスクごと auto-commit |
| refs soft-cap 閾値（150KB）が過小 | `account.yaml` にユーザー指定上限フィールドを持たせ上書き可能 |
| `migration-state.json` 破損 → 冪等性喪失 | バックアップに必ず同梱 + 旧/新パス両方検出ロジックでフェイルセーフ |
| Dynamic Context Injection はスナップショット | skill 起動時にアカウント名表示、長時間実行系では先頭で再取得推奨 |

### 7.2 フォールバック発動条件

以下いずれかで Zod v4 mini / 独自 atomic 実装 / テスト段階移行へ切替：

- 手書き `config-validation.ts` が 200行超過 or 型推論が3重ネスト以上で破綻
- `write-file-atomic` + `graceful-fs` でも Windows EPERM が週次以上発生
- Phase 1.5 で `cli-e2e.test.ts` 改修が 30ファイル制限超過かつ分割後も 24h 超

### 7.3 Abort（撤回）判断

**全体 abort は非推奨**（ユーザー明示要求 + 実装経路が 6視点で確立）。
部分 abort として `account rm` と `genres/<g>/refs/` 共存は Polish 以降 or 別途ユーザー要望時に延期。

---

## 8. ロック決定との整合性

| ロック決定 | 整合結果 |
|---|---|
| ESM / TypeScript strict / CLI のみ | 全視点が現行規約内で実現可能な設計を提示 |
| `accounts/<name>/genres/<g>/` 階層 | technical の path resolver 設計と cost のテスト改修見積が整合 |
| 既存 `genres/` → `accounts/default/genres/` 移行 | migration_safety + risk + alternatives で3段ゲートが共通推奨 |
| refs 両系統サポート | マージ規則・LLM コンテキスト上限対策が整理済み |
| history/queue のアカウント内閉じ | パス引数設計との整合を確認、横断閲覧は要件外 |
| CLI 後方互換 + `--account` + サブコマンド | kubectl 風設計と commander.js 実装が整合 |
| `current_account → default` フォールバック | null coalescing chain で実装パターン化、暗黙 default 時の確認プロンプト付与 |
| 品質低下禁止 | vitest `coverage.all` + CI 閾値 + L1ファイル参照検証ゲート |
| コード規約踏襲（新規依存最小） | 全視点が現行シグネチャ維持の方針で設計 |

---

## 9. Phase 1.5 への引渡し事項

1. **locked_decision assertions 注入**（criteria に追加）:
   - `file_exists`: `accounts/.current` 参照箇所
   - `grep_absent`: サーバー関連コード
   - `grep_present`: `write-file-atomic`
2. **テスト改修の独立タスク化**: `cli-e2e.test.ts` の setupGenre() 45箇所は 1〜2ファイル単位に分割
3. **Open questions（未解決 2項目）**:
   - ジャンル共有 `genres/<g>/refs/` 共存要否 → MVP から除外、明示的に out-of-scope 宣言
   - `account rm` 使用頻度想定 → Polish 以降に延期

---

## 10. 参考情報（ギャップとカベアット）

### 10.1 主要な未確認事項

- 既存 `src/lib` の path resolver 実装詳細（再利用性は要コードベース確認）
- `config-validation.ts` が使うバリデーションライブラリの特定（Zod か手書きか）
- `genres/` の具体的なディレクトリ構造・ファイル形式
- `accounts/.current` が現時点でリモートにプッシュ済みか（履歴書き換え要否の判断材料）
- make-tweet の実ユーザー数・運用規模（`account rm` 使用頻度想定の根拠）

### 10.2 外部情報源の信頼度

- **high**: Node.js ESM 仕様、kubectl/AWS CLI/gh CLI の先行事例、OWASP LLM01、Anthropic コンテキストウィンドウ仕様
- **medium**: YAML merge key 業界傾向、Claude Code skill Dynamic Context Injection の詳細動作、did-you-mean の fuzzy match 採用事例

---

**以上、Phase 1.5 タスク分解への引継ぎ準備完了。**
