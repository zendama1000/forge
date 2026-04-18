# make-tweet CLI 実用的改修 リサーチレポート

> **リサーチID**: 2026-04-15-2358ce-225938
> **対象**: make-tweet CLI（TypeScript ESM, 9モジュール, ~600行, 60+テスト）
> **スコープ**: デッドコード削除・リファクタ・UX改善・バグ修正

---

## 1. 調査概要

TypeScript ESM ベースのツイート生成 CLI（9モジュール）に対し、以下6つの視点から並列リサーチを実施した。

| 視点 | フォーカス |
|------|-----------|
| **技術的実現性** (technical) | デッドコード検出手法の信頼性、リファクタの安全性、エッジケース修正の実装難易度 |
| **コスト** (cost) | 改修の工数対効果、テスト維持コスト、変更範囲の最小化 |
| **リスク** (risk) | リグレッション発生シナリオ、デッドコード誤削除、データ破損リスク |
| **代替アプローチ** (alternatives) | リファクタ戦略、検出手法、UX改善手段の選択肢比較 |
| **CLI UX** (cli-ux) | コマンドの発見容易性、エラー時の導線、引数の直感性 |
| **コード衛生** (code-hygiene) | モジュール境界の明確さ、命名一貫性、エラーハンドリングパターンの統一性 |

---

## 2. 主要発見事項

### 2.1 デッドコード

- **削除可能量**: ~83行（全体の約14%）
  - `genre.ts` の `createGenre` / `validateGenreName` / `GenreError`（~53行） — cli.ts から未参照
  - `sample-selection.ts` 全体（~30行） — src/ 内の参照ゼロ、テストのみが参照
- **探索コスト**: grep + import-trace で約1.5時間。9モジュール規模では手動確認で十分な精度が得られる
- **検出ツール**: knip が最適だが、偽陽性リスク（Angular事例で39%）があるため、小規模プロジェクトでは grep ベースのクロスチェックが実用的

> **要確認**: `selectSamples` は「`prompt-builder.ts` が呼ぶべきなのに呼んでいない」設計バグの可能性がある。削除前にユーザー確認が必須。

### 2.2 JSONL 処理の重複

- `history.ts` と `queue.ts` の `atomicAppendLine` 関数（各61行）が**完全重複**（tmp ファイル名プレフィックス以外同一）
- 共通化で ~83行削減可能
- **安全な共通化戦略**: 低レベル操作（append/read）のみ共通化し、per-file-path キュー状態管理は各モジュールに残す
- **既存テストの書き換えコスト: ゼロ**（19ユニットテスト + 2統合テストが公開 API 経由のみ）

### 2.3 CLI UX の問題点（4件）

| # | 問題 | 重大度 |
|---|------|--------|
| 1 | `--help` フラグ未実装（全コマンド） | 高 |
| 2 | エラー時の次アクション導線なし（genre 未存在時に list 提案なし） | 高 |
| 3 | `--refs`（dir）と `--ref`（text）が 's' 1文字差で型が全く異なる + `--refs` 不存在=警告 / `--theory` 不存在=エラー の非対称挙動 | 中 |
| 4 | `queue` コマンドにバリデーション処理が**皆無**（280文字超過・重複・NGパターン全て無検査） | 高 |

**高ROI修正**: `--count` / `--limit` の NaN サイレントフォールバック修正（30分）、genre エラーへの list 提案追加（30分）

### 2.4 エラーハンドリングの不統一

4パターンが混在:

1. **カスタム Error クラス throw** — `genre.ts: GenreError`
2. **return 値バリデーション** — `config-validation.ts: ValidationResult` / `tweet-validation.ts: TweetValidationResult`（同一形状で別型名）
3. **ネイティブ Error throw** — `queue.ts`, `sample-selection.ts`, `prompt-builder.ts`
4. **console.error + silent skip** — `history.ts`, `queue.ts` の JSONL パースエラー

`ValidationResult` と `TweetValidationResult` が同一形状で別型定義されている点が最大の非一貫性。

### 2.5 Windows 対応

| 問題 | 深刻度 | 修正工数 |
|------|--------|----------|
| CRLF 残留バグ（`split('\n')` で `\r` が残る） | **実在するバグ** | 15分 |
| atomic rename の EPERM リスク | copyFileSync フォールバック実装済み | 対応不要 |
| `samples-parser.ts` の BOM/CRLF 対応 | 未確認（現状実装の確認が先） | 要調査 |
| Windows CI 構築（GitHub Actions） | 過剰投資 | 3-4時間（非推奨） |

### 2.6 過剰 export（4件）

| シンボル | ファイル | 状況 |
|----------|----------|------|
| `GenreConfig` | prompt-builder.ts | モジュール内部のみ使用、外部参照ゼロ |
| `AppendInput` | history.ts | 外部 import なし |
| `AppendQueueInput` | queue.ts | 外部 import なし |
| `selectSamples` | sample-selection.ts | CLI パイプライン未統合（設計バグの可能性） |

### 2.7 命名規則

- ファイル名（kebab-case）・関数名（camelCase verb+noun）・型名（PascalCase）は全体的に**一貫**
- 例外:
  - `ValidationResult` vs `TweetValidationResult` — prefix 有無の非対称
  - `AppendInput` vs `AppendQueueInput` — Queue 有無の非対称
- エラーメッセージ言語: lib 内=英語、cli.ts ユーザー向け=日本語（一貫した分離）

---

## 3. 視点間の矛盾と解決

| 対立視点 | 論点 | 解決策 |
|----------|------|--------|
| risk vs alternatives | 改修フェーズの順序 | **バグ修正を最初のフェーズに**。ベースライン確立後にデッドコード削除→リファクタ→UX改善 |
| technical vs cost | デッドコード検出手法の信頼性 | 9モジュール規模では **grep 手動確認で十分**。knip は補助的にクロスチェック |
| risk vs cost | JSONL 共通化のリスク評価 | **スキーマは一切変更しない**制約を明示。低レベル操作のみ共通化で両立 |
| code-hygiene vs cost | selectSamples の扱い | **ユーザー確認前の削除は禁止**。設計意図を確認してから判断 |
| alternatives vs technical | util.parseArgs() の評価 | ロック決定に基づき **util.parseArgs() を第一選択**。5サブコマンド規模なら十分 |

---

## 4. 推奨アクション

### 4.1 推奨: リスク順4フェーズの段階的改修（合計 ~8.5時間）

```
Phase A (バグ修正, ~2h)
  → Phase B (デッドコード削除, ~1.5h)
    → Phase C (構造リファクタ, ~3h)
      → Phase D (UX改善, ~2h)
```

各フェーズ完了時に全テスト通過を確認してから次フェーズに進む。

#### Phase A: バグ修正（MVP, ~2時間）

| 修正内容 | 対象ファイル | 工数 |
|----------|-------------|------|
| CRLF 残留バグ修正（`split('\n')` 後の `\r` 除去） | history.ts, queue.ts | 15分 |
| `--count` の NaN/0/負数サイレントフォールバック → エラー化 | cli.ts | 30分 |
| `--refs` 不存在ディレクトリの警告 → エラー（`--theory` と対称化） | cli.ts | 30分 |
| テストケース追加 | history-jsonl.test.ts, queue-operations.test.ts, cli-args.test.ts | 45分 |

**検証基準**: L1-001, L1-002, L1-003, L1-010, L1-011

#### Phase B+C: デッドコード削除 + 構造リファクタ（Core, ~4.5時間）

| 作業内容 | 対象ファイル | 工数 |
|----------|-------------|------|
| `createGenre` / `validateGenreName` / `GenreError` の export 除去 | genre.ts | 1時間 |
| `sample-selection.ts` の削除または統合（ユーザー確認後） | sample-selection.ts, prompt-builder.ts | 30分 |
| `atomicAppendLine` + `writeQueues` を共有モジュールに抽出 | 新規 atomic-write.ts, history.ts, queue.ts | 2時間 |
| テスト更新・共通化テスト追加 | 複数テストファイル | 1時間 |

**検証基準**: L1-004, L1-005, L1-006, L1-010, L1-011, L2-002

#### Phase D: UX 改善（Polish, ~2時間）

| 改善内容 | 対象ファイル | 工数 |
|----------|-------------|------|
| `queue` コマンドに `validateTweet()` 追加 | cli.ts | 30分 |
| 全サブコマンドに `--help` フラグ対応 | cli.ts | 30分 |
| genre 未存在エラーに list コマンド提案追加 | cli.ts | 15分 |
| エラーメッセージの一貫性向上（問題説明 + 次アクション） | cli.ts | 45分 |

**検証基準**: L1-007, L1-008, L1-009, L1-010, L1-011, L2-004

### 4.2 フォールバック: Phase A + B のみ実施（~3.5時間）

Phase C/D でリスクが顕在化した場合、または工数制約がある場合のミニマムプラン。

- バグ修正3件 + デッドコード~83行削減で最小限の品質改善を達成
- JSONL 共通化と UX 改善は次回イテレーションに延期

**トリガー条件**:
- Phase A でテストの予期しない失敗が3件以上
- selectSamples が設計バグと判明し prompt-builder.ts 改修が必要
- ユーザーが工数4時間以内の制約を指定

### 4.3 撤退基準

- grep で実際のデッドコードが ~20行以下と判明した場合
- JSONL 共通化でスキーマ変更が不可避と判明した場合
- 改修全体の工数が規模に対して過大と判断される場合

**撤退時の機会損失**: いずれの問題も現状で致命的障害は発生しておらず、撤退の実害は限定的。

---

## 5. 技術的推奨事項

| 項目 | 推奨 | 根拠 |
|------|------|------|
| デッドコード検出 | grep + import-trace 手動確認 | 9モジュール規模では knip の設定コスト > 手動コスト |
| JSONL 共通化 | ジェネリクス型パラメタ化 | 型安全性と DRY の両立。パース層はジェネリクス、処理層はドメイン別 |
| CLI 引数パース | `util.parseArgs()`（Node.js v18.3+ 組み込み） | 依存追加なし。サブコマンド非対応だが switch/case で補完可能 |
| エラークラス設計 | 2層カスタム Error（ApplicationError→ドメイン別） | 9モジュール規模で過不足ない粒度。instanceof 型ガードと組合せ可能 |
| Windows CRLF | `line.replace(/\r$/, '')` 追加 | 15分で修正完了。CI 構築は不要 |

---

## 6. リスク一覧

| リスク | 深刻度 | 対策 |
|--------|--------|------|
| `selectSamples` の設計意図確認前に削除 → 必要な機能喪失 | 高 | ユーザー確認を必須ゲートとする |
| `atomicAppendLine` 共通化で直列化保証が破壊される | 中 | 低レベル操作のみ共通化、キュー状態管理は各モジュールに残す |
| `util.parseArgs()` 移行で既存シェルスクリプト呼び出しが壊れる | 中 | 引数インターフェースの互換性維持、内部実装のみ変更 |
| 改修範囲超過（テスト10ファイル以上の変更） | 低 | スコープ超過時は打ち切り |
| `samples-parser.ts` の BOM/CRLF 二重処理 | 低 | 修正前に現状実装を確認 |

---

## 7. 実装基準（Layer 1/2/3）

### Layer 1: ユニットテスト基準（11項目）

| ID | 内容 | フェーズ |
|----|------|----------|
| L1-001 | CRLF 安全な JSONL 行パース | MVP |
| L1-002 | `--count` 引数の不正値拒否 | MVP |
| L1-003 | `--refs` と `--theory` の非対称エラーハンドリング修正 | MVP |
| L1-004 | `genre.ts` からデッドコード3シンボルの export 除去 | Core |
| L1-005 | `sample-selection.ts` のデッドコード判定と処理 | Core |
| L1-006 | `atomicAppendLine` 共通モジュール化 | Core |
| L1-007 | `queue` コマンドのツイートバリデーション追加 | Polish |
| L1-008 | `--help` フラグの全サブコマンド対応 | Polish |
| L1-009 | ジャンル未存在エラーのアクション提案 | Polish |
| L1-010 | TypeScript strict モードコンパイル成功 | 全フェーズ |
| L1-011 | 既存テストスイート回帰（全件PASS） | 全フェーズ |

### Layer 2: 統合テスト基準（4項目）

| ID | 内容 | フェーズ |
|----|------|----------|
| L2-001 | CLI E2E フロー（list→prompt→save→queue→history） | 全フェーズ |
| L2-002 | 共通 atomicAppendLine 並行書き込み安全性 | Core |
| L2-003 | Windows 環境での atomic rename フォールバック | Core |
| L2-004 | CLI 引数パース全パターン E2E | Polish |

### Layer 3: 構造検証・フロー検証（5項目）

| ID | 内容 | ブロッキング |
|----|------|-------------|
| L3-001 | CLI フルワークフロー（save→history→prompt 連携） | Yes |
| L3-002 | デッドコード除去の構造検証（unused export = 0件） | Yes |
| L3-003 | JSONL 共通モジュールのアーキテクチャ検証 | Yes |
| L3-004 | CLI エラーUX完全性（全エラーパスでアクション提案） | No |
| L3-005 | スキーマフィールド互換性（改修前後で完全互換） | Yes |

---

## 8. 前提条件

- Node.js >= 18.3（`util.parseArgs` 利用可能）
- TypeScript ESM (`type: module`) + tsx 実行環境
- 既存テストスイート（unit 9ファイル + integration 1ファイル）が改修前に全件 PASS
- JSONL 共通化はスキーマ（フィールド名・型）を一切変更しない
- 依存パッケージの追加は最小限（`util.parseArgs()` を第一選択）
- `selectSamples` の削除/統合はユーザー確認後に判断
