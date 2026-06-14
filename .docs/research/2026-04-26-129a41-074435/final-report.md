# 最終レポート: ralph-loop.sh Layer別 timeout_sec 動的読み取り化（自己改修バッチ #3, validate モード）

**Research ID**: `2026-04-26-129a41-074435`
**生成日**: 2026-04-26
**モード**: validate（ロック決定変更不可）
**最終判定**: GO（実態整合修正版・primary 推奨）

---

## 1. エグゼクティブサマリー

当初の改修プラン（execute_layer1_test / execute_layer2_regression / execute_layer3 の **3関数を一律にワンライナー注入で修正**）は、**実コードの構造と一致しないことが判明**した。technical / cost 両視点が独立に同一結論へ到達している。

| 項目 | 当初プランの想定 | 実態 |
|------|-----------------|------|
| **L1** | 200s ハードコードを動的化 | **既に対処済み**（`L992` で jq_safe 経由で読み取り済み） |
| **L2** | `execute_layer2_regression()` を修正 | **関数自体が存在しない**。L2 は dev-phases.sh のフェーズスクリプト実行モデル |
| **L3** | `execute_layer3()` のタイムアウトを動的化 | `task_run_l3_test()` (L1064) が `${L3_DEFAULT_TIMEOUT:-120}` をハードコードで渡しており、ここが**真の修正ターゲット** |

**推奨アクション**: ロック決定の精神（timeout_sec 動的化）を維持しつつ、空振りする L1/L2 のコード修正を強行せず透明化。修正規模は**実コード 2-3 行＋schema 3 エントリ＋プロンプト 500-800 文字＋テスト ~140 行**と最小侵襲で完遂可能。

---

## 2. 4視点の主要発見

### 2.1 Technical（技術視点）

| 観点 | 発見 | Confidence |
|------|------|-----------|
| L1 構造 | `execute_layer1_test()` は ralph-loop.sh `L741-745` の 5行 primitive。timeout は `$2` で受ける既存設計。呼び出し元 `task_run_l1_test()` の `L992` で `jq_safe -r '.validation.layer_1.timeout_sec // $L1_DEFAULT_TIMEOUT'` を実行済み | high |
| L2 構造 | `execute_layer2_regression()` は **存在しない**（grep no match）。L2 回帰は `handle_dev_phase_completion()` (dev-phases.sh `L292-296`) がフェーズスクリプト `{phase_id}.sh` を bash で直接実行 | high |
| L3 構造 | `task_run_l3_test()` (`L1064`) が `${L3_DEFAULT_TIMEOUT:-120}` をハードコード。per-test の timeout_sec は読まれていない。注入箇所は `execute_l3_test()` ではなく**呼び出し元ループ内** | high |
| schema | layer_1.required=[command,expect]、layer_2.properties=[command,expect]（required なし）、layer_3 items は `steps[].timeout_sec` のみ type:number で既存 | high |
| プロンプト | task-planning-prompt.md `L225-238` に既に L1 timeout_sec ガイドラインテーブル（vitest:120-200, test-f:10 等）が存在。L2/L3 用は未定義 | high |

### 2.2 Cost（コスト視点）

| 修正対象 | 工数 | 備考 |
|---------|------|------|
| L1 コード | **0-1 行** | 既に対処済み。テスト追加のみ |
| L3 コード | **2-3 行** | `task_run_l3_test()` ループ内のインライン置換 |
| L2 コード | **0 行** | 関数不在。schema/プロンプトのみ対応 |
| schema 拡張 | **3 エントリ** | layer_1 / layer_2 / layer_3 items への optional 追加 |
| 新規テスト | **~140 行** | フィクスチャ 30-40 行含む。既存 `task-stack-sample.json` 流用可 |
| プロンプト追記 | **500-800 文字** | +150-200 トークン（コスト影響無視できる水準） |
| common.sh 改変 | **不要** | ロック範囲遵守 |

### 2.3 Risk（リスク視点）

| リスク | 重要度 | 対策 |
|-------|--------|------|
| jq の `// 200` フォールバック未到達（空文字列 `""`、文字列型数値 `"300"` は truthy） | **HIGH** | 整数バリデーション `[[ "$timeout_sec" =~ ^[0-9]+$ ]]` を追加 |
| Windows native jq.exe の CRLF 混入で `bash 算術エラー` | **HIGH** | 既存 `jq_safe` / `jq_lines` ヘルパー経由（前回 #2-B 実績） |
| Task Planner LLM の過剰解釈（必須化誤解、文字列型出力） | medium | スキーマ型制約 + 整数バリデーションで実害防止 |
| L2/L3 暗黙 timeout の変更による退行 | medium | L2 関数不在のため L1/L3 限定で影響範囲は局所 |
| OS 非互換（macOS BSD timeout、bash 3.2、Windows CRLF） | high | テストは GNU 互換機能のみに限定 |

### 2.4 Alternatives（代替案視点）

| 設計選択 | 推奨 | 理由 |
|---------|------|------|
| Q1: ヘルパー化 vs インライン | **インライン** | L3 修正は 1 箇所のみ。ヘルパーのメリット薄 |
| Q2: ガイドライン形式 | **表 + example ハイブリッド** | 既存テンプレートが採用済み・LLM 精度に最良 |
| Q3: schema 範囲制約 | **minimum=10 / maximum=3600** | ロック決定整合。test-f:10 を不当拒否しない |
| Q4: フィクスチャ配置 | **既存フラット配置に追加** | 既存テストランナーと完全整合 |
| Q5: ガイドライン重複 | **詳細を prompt に集約・planner.md は原則** | SSOT パターン・既存構造維持 |

---

## 3. 視点間の矛盾と解決策

### 矛盾 1: ロック決定（3関数前提）vs 実コード（L2 関数不在）

- **technical / cost** が「`execute_layer2_regression()` は存在しない」と独立報告
- **解決**: validate モードのため決定は変更せず、「該当関数が存在しないため変更なし」と**明示透明化**。L2 は schema + プロンプトのみ対応し、実行時接続は別バッチへ委譲

### 矛盾 2: alternatives（ヘルパー化推奨）vs risk（共通化による退行警告）

- **解決**: L3 修正対象は 1 箇所のみ。インライン展開で十分。common.sh 改変はロック決定で禁止のため private ヘルパーは ralph-loop.sh 内に局所定義する案も今回は不採用

### 矛盾 3: ロック決定 3 段階（60-120 / 600-1800 / 1800-3600）vs 既存テーブル（test-f:10）

- **解決**: 「**大分類（ロック決定3段階）→ 細目（既存テーブル）**」の階層構造で併記。schema の minimum:10 はロック決定（10-3600）に整合しているため矛盾なし

### 矛盾 4: risk（空文字列・型違い警告）vs cost（境界テスト不明示）

- **解決**: 新規テストを 3 ケース → **5 ケース（明示・フォールバック・範囲外・型違い・空文字列）** に拡張。整数バリデーション `[[ "$timeout_sec" =~ ^[0-9]+$ ]]` を防御コードとして追加

---

## 4. 推奨実装プラン（Primary）

### 4.1 ファイル別変更

| ファイル | 変更内容 | 行数 |
|---------|---------|------|
| `ralph-loop.sh` | L1064 の `${L3_DEFAULT_TIMEOUT:-120}` を `jq_safe` ベースに置換 + L1/L3 両所に整数バリデーション追加 | +5-7 行 |
| `task-stack.schema.json` | layer_1 / layer_2 / layer_3 items に `timeout_sec` (type:number, min:10, max:3600, optional) 追加 | +3 エントリ |
| `task-planning-prompt.md` | L225-238 を「大分類3段階 → 細目テーブル」階層に拡張、L2/L3 セクション追加、ハードコード `120` を `(ガイドライン参照)` に統一 | +500-700 文字 |
| `task-planner.md` | timeout_sec 原則の追記（SSOT として最小限） | +100 文字 |
| `test-timeout-sec.sh` | 新規。fixtures + 5 ケース assertion | ~140 行 |
| `run-all-tests.sh` | 新規テスト登録（1 行） | +1 行 |
| 新規 fixtures | `task-stack-with-timeout.json` / `task-stack-out-of-range.json` / `task-stack-wrong-type.json` | ~40 行 |

### 4.2 dev_phase 構成

| Phase | 目的 | 主要 criteria |
|-------|------|--------------|
| **MVP** | schema 追加 + 既存 L1 挙動の characterization test | L1-001, L1-002, L1-005 |
| **Core** | L3 動的読み取り修正本体 + 整数バリデーション防御 | L1-003, L1-006, L1-005 |
| **Polish** | プロンプト追記 + 全体テスト + MEMORY 更新 | L1-004, L1-005, L1-006 |

### 4.3 主要 L1 criteria（6 件）

| ID | 種別 | 内容 |
|----|------|------|
| L1-001 | unit_test | schema が timeout_sec を optional/number/min:10/max:3600 で受理（既存 23 fixture 後方互換） |
| L1-002 | unit_test | task_run_l1_test() の characterization test（明示・フォールバック・null・空文字列・文字列型の 5 ケース） |
| L1-003 | unit_test | task_run_l3_test() ループの修正本体検証（5 ケース + 連続呼出独立性） |
| L1-004 | lint | プロンプト追記（3段階大分類 + 細目テーブル + L2/L3 セクション + CRLF 混入なし） |
| L1-005 | unit_test | 既存 14 テストスイート + 新規 1 = 15 本全 PASS（退行なし） |
| L1-006 | lint | 整数バリデーション防御コードが L1 / L3 両所に存在 + bash 構文エラーなし |

---

## 5. 残存リスクと対応

| リスク | トリガー条件 | 対応 |
|-------|-------------|------|
| L2 コード変更見送りへの信頼性疑義 | ユーザーが「ロック決定空振り」と解釈 | 報告書で **L2 関数不在＋別バッチ委譲** を明示透明化 |
| Task Planner プロンプト混乱 | LLM が timeout_sec を誤型出力 | 整数バリデーション + 200s フォールバックで実害防止。サンプリング検証推奨 |
| OS 非互換（macOS BSD / bash 3.2） | CI で fail | テストは GNU 互換機能のみに限定 |
| schema 階層・型不整合 | layer_3 items の top-level timeout_sec と steps[].timeout_sec が type 不統一 | **type:integer ではなく既存の type:number に統一** |
| Task Planner が timeout_sec を生成しない | 既存 task-stack.json には未存在 | フォールバック 120s 発火を境界テストで保証 |

### Fallback 計画（trigger 該当時）

L3 コード変更でも問題発生時、schema + プロンプト追加 + characterization test のみで完了とし、実コード変更は次回バッチへ委譲。schema/プロンプトは後方互換のため退行リスクほぼゼロ。

### Abort 条件（validate モードのため原則禁止）

例外的に再壁打ち推奨: (1) MEMORY.md の「200s ハードコードバグ」記述自体が古い情報、(2) L2 を per-task に変えるには ralph-loop.sh / dev-phases.sh / generate-tasks.sh の協調変更が必要（ロック範囲外）、(3) L3 修正単独では Task Planner が timeout_sec 生成する動機が薄い場合。

---

## 6. ロック決定との整合性

### 整合 ✅

- 改修対象 4 ファイル限定（ralph-loop.sh / task-stack.schema.json / task-planner.md / task-planning-prompt.md）
- timeout_sec フォールバック 200s 維持（L1 既存実装と一致）
- jq 経由読み取り（jq_safe / jq_lines 使用）で Windows CRLF 回避
- schema に optional / number / min:10 / max:3600 で追加
- 既存テスト 125+ PASS 維持 + 新規テスト追加
- task-planner.md と task-planning-prompt.md にガイドライン追記

### コンフリクト（透明化済み）⚠️

- 「`execute_layer2_regression()` 内の timeout 値読み取り部分のみ変更可」→ **関数不在のため空振り**。schema/プロンプトのみ対応
- 「短時間検証 60-120s」→ プロンプト既存テーブル `test-f:10` と数値矛盾。schema minimum:10 とは整合のため、**「大分類→細目」階層構造で併記**

---

## 7. 完了条件（Phase 3 統合検証）

```bash
# MVP 完了条件
ajv validate -s .forge/schemas/task-stack.schema.json -d .forge/tests/fixtures/task-stack-sample.json
ajv validate -s .forge/schemas/task-stack.schema.json -d .forge/tests/fixtures/task-stack-with-timeout.json
bash .forge/tests/test-timeout-sec.sh --l1-readonly
bash .forge/tests/run-all-tests.sh

# Core 完了条件
bash .forge/tests/test-timeout-sec.sh --l3-dynamic         # 5/5 PASS
bash -n .forge/loops/ralph-loop.sh                         # 構文 OK
bash .forge/tests/test-ralph-functions.sh                  # 44/44 PASS

# Polish 完了条件
bash .forge/tests/test-timeout-sec.sh --prompt-lint
bash .forge/tests/run-all-tests.sh && bash .forge/tests/test-timeout-sec.sh   # 15/15 PASS
# CRLF 混入チェック（全 5 ファイル）
```

---

## 8. 後続バッチ向け申送り事項（MEMORY.md 更新候補）

1. **L1 既対処確認**: `L992` で `.validation.layer_1.timeout_sec` を読み取り済み。MEMORY 記述は古い情報のため更新
2. **L2 別バッチ委譲**: `execute_layer2_regression()` 新規実装 + dev-phases.sh per-task 化は別バッチ
3. **L3 修正完了**: `task_run_l3_test()` ループで動的読み取り（120s フォールバック）
4. **整数バリデーションパターン確立**: `[[ "$var" =~ ^[0-9]+$ ]]` を timeout 系で標準化
5. **`phase3.sh L338` の同一パターン**: ロック対象外のため未修正。次回 `phase3.sh` 改修時に同パターン適用検討

---

## 9. 参考文献（perspective レポートより）

- jq `//` 演算子の挙動: jdriven.com / jqlang/jq#1275, #3098
- Windows jq CRLF 問題: jqlang/jq#92, #3132, #1870 / codegenes.net
- macOS BSD timeout 非互換: dev.to/maple, medium @bredelet
- JSON Schema 後方互換: creekservice.org / yokota.blog / confluent.io
- LLM プロンプト形式効果: arxiv 2503.06926v2 / Lakera Prompt Engineering Guide / Palantir Best Practices
- SSOT 原則: Paligo / Atlassian
- Bash Best Practices: Google Shell Style Guide / Cycle.io

---

**判定**: **GO（primary 推奨）** — 実態整合的な最小侵襲修正で完遂可能。validate モードの制約を遵守しつつ、ロック決定の精神（timeout_sec 動的化）を達成し、空振りする部分は明示透明化する。
