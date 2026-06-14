# 最終リサーチレポート: 自己改修バッチ #2-B

**研究 ID**: `2026-04-25-12d9a2-190342`
**生成日時**: 2026-04-25
**モード**: validate（ロック決定確定済み）

## 1. リサーチテーマ

`ralph-loop.sh` と `forge-flow.sh` の終了サマリに、未完5状態 (`pending` / `in_progress` / `blocked_criteria` / `blocked_investigation` / `failed`) の残存検出と赤字 WARNING ブロックを追加し、**反復上限到達時の「正常終了」の罠**を可視化する。

### 制約（ロック決定）

- exit code 不変・PushNotification 不使用・`progress.json` 拡張禁止
- 改修対象は `ralph-loop.sh` / `forge-flow.sh` の終了サマリ部のみ
- メインループ・フェーズオーケストレーション関数は不変
- 既存 83 テスト 100% PASS 維持
- `jq_lines` / `jq_safe` 活用、ANSI tty ガード必須

---

## 2. 結論サマリ（推奨アクション）

| 項目 | 推奨 |
|------|------|
| **改修可否** | ✅ 実施推奨（5視点全てで実現可能性 validated） |
| **主改修箇所** | `ralph-loop.sh` の `print_summary()` (L1457-1505) への追記 |
| **副改修** | `forge-flow.sh` L576-587 に機械可読プレフィックスのみ追記 |
| **新規テスト** | `test-print-summary-unfinished.sh` 1本 + fixtures 5種以上 |
| **想定工数** | コード +30〜50行 / テスト 120〜150行、合計 半日未満 |
| **リスクレベル** | 低（既存先例 L1485-1504 をテンプレートとして踏襲可能） |

---

## 3. 視点別調査結果

### 3.1 技術的実現性（technical）

| 調査項目 | 発見事項 |
|---------|---------|
| 終了サマリの構造 | `ralph-loop.sh` L1457-1505 に独立関数 `print_summary()` あり。`forge-flow.sh` L576-587 はインライン展開のみ |
| jq 一括集計 | 単一 jq 呼出で Object 返却、`startswith("blocked")` で `blocked_criteria` / `blocked_investigation` を統合可能 |
| jq_safe / jq_lines | 実装は同一 (`jq "$@" \| tr -d '\r'`)。新規ロジックにそのまま流用可能 |
| ANSI ガード | 専用ヘルパーは未存在。既存先例 L1496 は `${RED:-$'\e[31m'}` フォールバックパターン |
| テスト構造 | `extract_all_functions_awk` + `source` + `2>&1` キャプチャ + `assert_contains` パターンで実現 |

**重要発見**: `print_summary()` の出力は全て **stderr**。テストでは `2>&1` での stderr キャプチャが必須。

### 3.2 コスト・リソース（cost）

| 項目 | 見積もり |
|------|---------|
| `ralph-loop.sh` 警告ブロック追加 | +15〜25 行 |
| `forge-flow.sh` 警告ブロック追加 | +15〜25 行 |
| 新規テストファイル | 120〜150 行 |
| fixtures（5種） | +50〜80 行 |
| 改修工数 | 30〜60 分（パターン熟知者） |
| テスト工数 | 2〜3 時間 |
| 既存テスト影響評価 | run-all-tests.sh 1回（15〜30分） |
| Phase 2 ランタイム影響 | jq 1〜2回追加 → **0.033%未満**（無視可） |

**重要事実**: `print_summary` を grep / wc -l 検査する既存テストは **ゼロ件**。新規行追加による false positive リスクなし。

### 3.3 リスク・失敗モード（risk）

#### ⚠ 重大リスク2点

1. **ANSI エスケープの `forge-flow.log` 汚染（実証済み）**
   - `common.sh` が tty 判定なしで色変数を無条件定義
   - daemonize の `2>&1` リダイレクトで全て混入
   - 実証: `archive/20260415-225935/forge-flow.log:247` に `^[[0;31m^[[1m⚠ 行動検証未完了...^[[0m` 確認済み
   - 後段の grep 解析で誤動作の懸念

2. **`print_summary()` 内の jq が全て raw jq**
   - `count_tasks_by_status()` (L562-564) と blocked 集計 (L1466-1467) は `jq_safe` 経由ではない
   - Windows jq 1.7.1 の CRLF 退行リスクが残存
   - 表示用のみのため致命傷ではないが、ログ文字化けの可能性

#### その他リスク

| シナリオ | 影響 | 緩和策 |
|---------|------|-------|
| Phase 1.5 失敗で `task-stack.json` 不在 | 設計上 ralph-loop.sh は呼ばれないため低リスク | 起動時 L118 のチェックで担保 |
| 実行中 `tasks` キー破損 | `set -eEuo pipefail` で abort | `// {tasks:[]}` デフォルトまたは `?` 演算子 |
| ダッシュボードとの二重表示 | 厳密重複なし。`completed_with_gaps` ステータスとの混乱可能性 | 本バッチ対象外（情報共有のみ） |

### 3.4 代替案・選択肢（alternatives）

| 設計選択 | 推奨案 | 根拠 |
|---------|-------|------|
| 文面言語 | **(C) 日英併記** | 既存 L1496「⚠ 行動検証未完了（BEHAVIORAL TESTS MISSING）」の先例 |
| 状態別表示 | **(B) カウント + 代表タスクID 上位3〜5件** | 視認性とログサイズのバランス |
| tty ガード | **(D) `[ -t 1/2 ]` AND `$NO_COLOR` 組合せ** | no-color.org 準拠、CI ログ汚染回避 |
| テスト構造 | **(A) 単体関数 source 呼び出し型** | `test-ralph-engine.sh` の確立パターン |
| 挿入位置 | **(A) サマリ直後に追記** | 既存 L1485-1504 の先例を踏襲 |

### 3.5 可視性・発見可能性（observability）

#### 設計指針

- **silent on success**: 未完0件時は警告ブロック非表示（Unix 哲学・CLIG・既存実装と整合）
- **3層構造の踏襲**: RED+BOLD 見出し / bullet 列挙 / YELLOW 矢印で対処hint
- **機械可読プレフィックス併記必須**: `[WARN] UNFINISHED_TASKS=N pending=X in_progress=Y blocked_criteria=Z blocked_investigation=W failed=V`
- **視覚的強調**: 区切り線 + 空行2行で囲む（`echo ''` 1行のみは不十分）

#### grep パターン設計

```bash
# 警告検出
grep -E '\[WARN\] UNFINISHED_TASKS=[1-9]' forge-flow.log

# ANSI 混入検出（CI ログ汚染チェック）
grep -P '\x1b\[' forge-flow.log
```

---

## 4. 矛盾点と解決方針

| 視点間の対立 | 解決方針 |
|-------------|---------|
| risk vs technical（既存 raw jq の修正範囲） | 新規追加分のみ `jq_safe` 経由で記述。既存 raw jq には触らない（ロック決定遵守） |
| risk vs alternatives（tty ガードの実装方式） | 新規警告ブロック内に**ローカル変数**で tty ガードを実装。`common.sh` のグローバル `RED/BOLD/NC` は使わない。stderr ベース (`[ -t 2 ]`) で daemonize と整合 |
| observability vs alternatives（機械可読行の挿入位置） | 3層構造の直前または直後に固定プレフィックス1行を `log()` 経由で追加。両立可能 |
| cost vs risk（83テスト数値の根拠） | `run-all-tests.sh` 実行で実態確認。新規テストは命名規約 `test-*.sh` で自動収集 |

---

## 5. 実装計画（Implementation Criteria）

### Phase: MVP

機械可読プレフィックス1行を出力する最小実装。

- 対象: `L1-002`, `L1-004`
- 内容: `jq_safe` で5状態合計集計 → `[WARN] UNFINISHED_TASKS=N ...` を `log()` 経由で1行出力
- 終了条件: with-pending → grep PASS / all-done → silent

### Phase: Core

視覚警告ブロック（3層構造）+ tty ガード追加。

- 対象: `L1-001`, `L1-003`, `L1-005`, `L2-001`, `L2-002`
- 内容: RED+BOLD 見出し / bullet / YELLOW 矢印 + ローカル変数 tty ガード
- 終了条件: `test-print-summary-unfinished.sh` 全 PASS / `run-all-tests.sh` 全 PASS / 非tty環境で ANSI 不検出

### Phase: Polish

エッジケース耐性 + daemonize E2E 検証。

- 対象: `L3-001`, `L3-002`, `L3-003`
- 内容: `tasks` キー欠如 / 空配列 / 巨大タスク数の null-safe ガード
- 終了条件: malformed fixture でも graceful degradation / forge-flow daemonize で警告記録確認

### 受入基準まとめ

| Layer | 基準 ID | 検証内容 |
|-------|--------|---------|
| L1 | L1-001 | 視覚警告ブロックが stderr に出力される |
| L1 | L1-002 | 機械可読プレフィックス `[WARN] UNFINISHED_TASKS=N ...` の正確性 |
| L1 | L1-003 | tty ガードによる ANSI 制御（リダイレクト時は ANSI なし） |
| L1 | L1-004 | 新規追加部に raw jq が含まれず `jq_safe` / `jq_lines` を使用 |
| L1 | L1-005 | 既存 83 テスト全 PASS 維持 |
| L2 | L2-001 | daemonize 経由で `forge-flow.log` から grep 抽出可能 + ANSI 非混入 |
| L2 | L2-002 | tty 有/無で警告内容（カウント数値）が一致 |
| L3 | L3-001 | 出力構造の3層 + 機械可読行の併記検証 |
| L3 | L3-002 | 反復上限到達 fixture で exit 0 + 警告出力 |
| L3 | L3-003 | 全完了 fixture で silent on success |

---

## 6. 必要な fixtures

| ファイル名 | 内容 | 用途 |
|-----------|------|------|
| `task-stack-with-pending.json` | pending=2 残存 | L1-001 / MVP exit |
| `task-stack-with-failed.json` | failed=1 残存 | L1-001 |
| `task-stack-with-blocked.json` | blocked_criteria=1, blocked_investigation=1 | 内訳表示の検証 |
| `task-stack-mixed-unfinished.json` | pending=2, failed=1 | L1-002 |
| `task-stack-all-done.json` | 全 completed | silent on success 検証 |
| `task-stack-empty-tasks.json` | tasks=[] | エッジケース |
| `task-stack-malformed.json` | tasks キー欠如 | null-safe 検証 |
| `task-stack-iteration-limit.json` | pending + in_progress + failed 混在 | L2/L3 統合検証 |

---

## 7. 残存ギャップ・要確認事項

- `interrupted` 状態を `print_summary()` のカウント対象に含めるかの設計判断
- `forge-flow.sh` から `task-stack.json` へのパスが work_dir 切替時に常に解決可能か
- Windows Git Bash (MSYS) における `[ -t 2 ]` の実動作（プロジェクトは Windows 上で運用）
- `CALIBRATION_FILE` を使うブランチの fixture 設計
- `test-coverage-gaps.sh`（`run-all-tests.sh` 30行目に列挙されているが実体不在）の扱い
- 「83テスト」の正確な内訳（ファイル数47本との差異 → アサーション総数の集計と推定）

---

## 8. 採否の判断（GO / NO-GO）

**判定: GO（実施推奨）**

### 採用理由

1. 5視点全てで高い確信度の validation が得られた
2. 既存先例（`BEHAVIORAL TESTS MISSING` 警告ブロック）が確立されており、踏襲することでリスクと工数が最小化
3. 過去の自己改修バッチ #2-A（2026-04-24、Windows 互換性バッチ 83/83 PASS 達成）で同種の改修パターンの実績あり
4. 撤退の機会費用が大きい:
   - ユーザーが `forge-flow` 完了通知を見て「成功」と誤認するリスクが継続
   - sc:monitor / dashboard.sh での後続自動検知の素地が作られない
   - 自己改修バッチの2回目実証機会の逸失
   - 既存警告ブロックとの設計一貫性が実現されないまま終わる

### 注意事項

- `forge-flow.sh` への追記は二重表示リスク回避のため**機械可読プレフィックスのみ**とする（fallback 案）
- 既存 raw jq 部（`count_tasks_by_status` / L1466 blocked 集計）の修正は**本バッチのスコープ外**（別バッチで対応）
- `common.sh` の ANSI 無条件定義の根本修正は**本バッチのスコープ外**（ロック決定によりライブラリ改修禁止）
