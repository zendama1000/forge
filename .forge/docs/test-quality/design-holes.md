# Forge テスト品質改善 — 設計の穴・未解決問題一覧（決定版）

## 前提

本ドキュメントは「Forge テスト品質改善 テンプレート改修仕様」（00-change-summary.md）の設計レビューで発見された穴・未解決問題をまとめたもの。各問題に対する決定事項を記載済み。

関連ファイル:
- 設計仕様: `00-change-summary.md`
- テンプレートドラフト: `criteria-generation.md`, `task-planning-prompt.md`, `implementer-prompt.md`, `investigator-prompt.md`, `mutation-auditor-prompt.md`
- エージェント定義ドラフト: `mutation-auditor.md`, `implementer.md`, `investigator.md`

---

## 穴1: mutation-runner.sh の original 文字列マッチング（重大度: 高）

### 問題

Mutation Planner（LLMエージェント）が出力する `original` フィールドは、mutation-runner.sh がファイル内で文字列検索して置換するために使う。LLMの出力が実コードと1文字でもズレると mutant を適用できず error になる。

### 具体的なズレパターン

```
1. インデント: LLMが4スペースで出力、実コードは2スペース
2. セミコロン: LLMが省略、実コードにはある（またはその逆）
3. 引用符: LLMがシングルクォート、実コードはダブルクォート
4. 空白: 行末の空白、演算子前後の空白の有無
5. 改行: LLMが1行で出力、実コードは複数行にまたがる
6. コメント: 実コードに行末コメントがあるがLLMが省略
```

### ✅ 決定: 行番号ベース + original_hint 検証（折衷案）

**方式:**
- Planner は `line_start` / `line_end` で対象行を指定する
- `original_hint` フィールドを出力する（検証用。マッチングには使用しない）
- mutation-runner.sh は `sed -n` で実際の行を取得し、mutant で置換する
- original_hint と実際の行を簡易比較し、まったく無関係なら warning + skip

**出力スキーマ:**
```json
{
  "id": "M-001",
  "line_start": 42,
  "line_end": 42,
  "original_hint": "return c.json({ userId: user.id }, 201)",
  "mutant": "return c.json({ userId: user.id }, 200)",
  "rationale": "..."
}
```

**採用理由:** 上位互換構造。後からどちらにも倒せる。
- 完全一致が有効と判明 → original_hint をマッチング用に昇格するだけ
- 行番号だけで十分と判明 → original_hint の検証を外すだけ
- 完全一致で始めて後から行番号に移行 → runner + prompt + agent の3ファイル書き直し

**error_rate の定義:**
- 「line_start:line_end が範囲外」「対象行が空行/コメントのみ」「original_hint と実際の行がまったく無関係」の検出率
- 閾値: 0.40（現状維持）

**REPLAN 時の改善:** 前回の error 情報（どの mutant が失敗し、実際の行内容が何だったか）を Planner に渡す。

**影響するドラフト:**
- `mutation-auditor-prompt.md`: 出力スキーマ変更、行番号付き IMPL_CODE 指示追加
- `mutation-auditor.md`: 「original 完全一致」→「行番号正確性 + original_hint」に変更

---

## 穴2: 複数ファイルにまたがるタスク（重大度: 中）

### 問題

mutation-auditor-prompt.md は `{{IMPL_CODE}}` として単一ファイルの実装コードを想定している。しかし実際のタスクは複数ファイルを生成することがある。

### ✅ 決定: 案B（メインファイルのみ mutation、依存はコンテキスト）+ Phase 2 で観測

**方式:**
- Planner には全ファイルを渡すが、mutate するのはメインファイルのみ
- 依存ファイルはコンテキスト情報として渡す
- `{{IMPL_CODE}}` を `{{IMPL_FILES}}` に変更し、複数ファイル対応のフォーマットにする

**採用理由:**
- task-planning-prompt.md の改修で「1タスク = 1責務」の粒度指針が入り、複数ファイル問題の発生頻度自体が下がる見込み
- 依存ファイル側のバグは Layer 2（統合テスト）のカバー範囲
- Phase 2 の観測データで、新フローで複数ファイルタスクがどの程度発生するか確認してから最終判断

**今決めなくていいこと:** 5ファイル以上のタスクの扱い。Phase 2 で確認。

---

## 穴3: テスト実行時間の膨張（重大度: 中）

### 問題

15 mutant × テスト実行（各30秒想定）= 7.5分/タスク。implementation系30タスクで225分追加。

### ✅ 決定: 案C + 案E（dev-phase ごと制御 + timeout 60秒、mvp は OFF）

**mutation-audit.json の設定:**
```json
{
  "runner_timeout_per_mutant_sec": 60,
  "skip_task_types": ["setup", "documentation"],
  "phase_config": {
    "mvp": { "enabled": false },
    "core": { "enabled": true },
    "polish": { "enabled": true }
  }
}
```

**採用理由:**
- mvp は「まず動くものを作る」フェーズ。テスト品質の厳密な検証は core 以降で十分。mvp OFF で実行時間がほぼ半減
- timeout 60秒: 1タスクのテストが30秒以上かかる場合、テスト自体が重すぎるという指標
- 典型ケース: 15 mutant × 5秒 = 75秒/タスク。問題にならない
- 並列化（案B）は複雑性が高すぎる。Phase 3 で実行時間が問題になったら検討

---

## 穴4: Implementerのテスト強化モードの有効性（重大度: 中）

### 問題

surviving mutant 情報を渡して Implementer にテスト強化させるが、全てのケースでテスト修正だけで対応できるわけではない。

### ✅ 決定: 案B（Investigator エスカレーション）

**方式:**
- audit loop 2回 FAIL → Investigator に surviving mutant 情報 + 「テスタビリティ問題の可能性」フラグを渡す
- Investigator が判定:
  - scope="task": テスト手法を変えれば検出可能（モック戦略の変更等）
  - scope="criteria": behavior 定義が曖昧 or テスト不能 → behavior 修正提案

**採用理由:**
- 既存の Investigator の scope 判定フローに自然に乗る
- ドラフトの investigator-prompt.md にすでに「Mutation Audit 結果を考慮する」セクションがあり、追加改修が小さい
- 案A（実装変更許可）はスコープクリープの温床
- 案C（カテゴリ除外）は mutation audit の信頼性を損なう

**survival_rate 計算からの除外は行わない。** 除外を始めると「除外カテゴリを増やせば survival_rate が下がる」という抜け道ができる。

---

## 穴5: behaviors の粒度問題（重大度: 低〜中）

### 問題

criteria-generation が出す behaviors の粒度が統一されない可能性。

### ✅ 決定: 案A + 案C（項目数範囲 3〜8 + 自己チェック指示）

**criteria-generation.md に追加するテキスト:**
```
### behaviors の粒度ルール
- 1つの L1 基準あたり 3〜8 項目が目安
- 8項目を超える場合は L1 基準を分割すること
- 出力後、以下を自己チェックせよ:
  (1) 各 behavior が1つの操作→結果ペアに対応していること
  (2) 正常系・異常系・エッジケースが各1つ以上含まれていること
  (3) 同じ検証を言い換えただけの重複がないこと
```

**採用理由:**
- ドラフトの criteria-generation.md にはすでに「操作 → 期待結果の形式」「最低構成」「NG/OK例」が入っている
- これ以上の粒度定義（案B）を追加するとプロンプトが冗長になりルール見落としリスクが上がる
- 上限（8項目）+ 自己チェックの組み合わせで十分な制御が効く

---

## 穴6: 既存 task-stack.json との互換性（重大度: 中）

### 問題

改修後の task-planning は `task_type` と `required_behaviors` を出力するが、既存の task-stack.json にはこれらのフィールドがない。

### ✅ 決定: 案C（新プロジェクトから新フロー）+ 最低限フォールバック

**方式:**
- 既存プロジェクトは旧フローで走り切らせる
- 新プロジェクトから新テンプレートで criteria-generation → task-planning を通す
- ralph-loop.sh に最低限の防御コードを追加:

```bash
local task_type=$(echo "$task_json" | jq -r '.task_type // empty')
local has_behaviors=$(echo "$task_json" | jq 'has("required_behaviors")')
if [ -z "$task_type" ] || [ "$has_behaviors" = "false" ]; then
  log "  mutation audit skip: 新フォーマット未対応タスク"
  return 0
fi
```

**採用理由（実データに基づく）:**
- 既存 task-stack.json: 56タスク全てに task_type / required_behaviors / dev_phase_id / phases がゼロ
- 後付けで behaviors を追加するのは中途半端（criteria-generation からの一貫したデータフローが前提）
- フォールバック分岐を大量に入れるとコードの複雑性が増しバグの温床になる
- 防御コード2行で旧フォーマットでも壊れない

---

## 議題A: exit_criteria の expect フィールド未使用（重大度: 中）

### ✅ 決定: スコープ外。別 issue として記録

**理由:**
- exit_criteria は dev-phase 完了時の phase gate で使われ、mutation audit のスコープとは独立
- 現状でも curl の `-sf` で HTTP ステータスの基本チェックはされている
- generate_phase_test_scripts() の改修は forge-flow.sh 系に影響し、ralph-loop.sh 改修とは責務が異なる
- Phase 1 の criteria-generation.md 改修で exit_criteria の品質も間接的に上がる可能性あり。Phase 1 実行後に再評価

---

## 議題B: mutation audit の導入順序（重大度: 中）

### ✅ 決定: 3段階導入（閾値 0.60 で試行）

**Phase 1: テンプレート改修のみ適用**
- criteria-generation.md / task-planning-prompt.md / implementer-prompt.md / implementer.md を適用
- mutation 関連は一切触らない
- 1プロジェクトで実行し観測:
  - test -f only タスクの割合（目標: implementation 系で 0%）
  - behaviors 付き criteria の品質
  - Implementer の behavior コメント遵守率

**Phase 2: mutation audit 閾値 0.60 で試行**
- mutation-runner.sh 新規作成（行番号ベース + original_hint 方式）
- mutation-auditor.md / mutation-auditor-prompt.md 配置
- mutation-audit.json 設定追加
- ralph-loop.sh に `run_mutation_audit()` 追加、FAIL 判定あり（閾値 0.60）
- 1プロジェクトで実行し観測:
  - survival_rate の分布（平均・中央値・最大値）
  - error_rate（行番号ミス率、original_hint 不一致率）
  - audit loop の FAIL→再実行→再audit パスの動作確認
  - Planner の計画品質（behavior カバレッジ達成率）

**Phase 3: 本番閾値で全面適用**
- Phase 2 の観測データに基づいて閾値を設定（暫定: mvp:0.40, core:0.30, polish:0.20）
- Investigator 改修（mutation audit context 対応）を適用

**採用理由:**
- 0.60 は十分緩い閾値。survival rate 60%（mutant の4割しか検出できない）を下回るテストは明らかに甘い
- FAIL 判定を入れることで audit loop 全体の E2E 検証ができる。観測モードだとループの FAIL→再実行パスが未検証のまま Phase 3 に進むリスクがある
- Phase 2 で 0.60 → Phase 3 で本番閾値への変更は config の数値変更のみ

---

## 議題C: コスト見積もり（重大度: 低〜中）

### ✅ 決定: 問題なし

- Planner 追加コスト: $0.30/プロジェクト（軽微）
- 実行時間の方が支配的（穴3で対応済み）
- Phase 2 で実際のコストを計測し、想定と乖離があれば調整

---

## 追加決定事項

### render_template の {{#if}} 非対応問題

**問題:** ドラフトの implementer-prompt.md は `{{#if MODE == "test_strengthen"}}` で分岐しているが、common.sh の render_template() は bash parameter expansion ベースで条件分岐をサポートしていない。

**決定:** ralph-loop.sh 側で分岐し、テンプレートを2つに分割する。
- `implementer-prompt.md` — 通常の実装モード
- `implementer-strengthen-prompt.md` — テスト強化モード

ralph-loop.sh の `run_mutation_audit()` 内で、FAIL 判定後に強化モード用テンプレートを選択して Implementer を再実行する。

---

## 優先度サマリ（更新版）

| # | 問題 | 重大度 | 決定 | 実装前ブロッカー |
|---|------|--------|------|----------------|
| 穴1 | original 文字列マッチング | 高 | 行番号 + original_hint | ✅ 解決 |
| 穴2 | 複数ファイルタスク | 中 | 案B + Phase 2 観測 | No |
| 穴3 | テスト実行時間 | 中 | 案C+E、mvp OFF | No |
| 穴4 | テスト強化モード有効性 | 中 | 案B、Investigator エスカレーション | No |
| 穴5 | behaviors 粒度 | 低〜中 | 案A+C、3〜8項目 | No |
| 穴6 | 既存互換性 | 中 | 案C + 防御コード | ✅ 解決 |
| 議題A | exit_criteria expect | 中 | スコープ外 | No |
| 議題B | 導入順序 | 中 | 3段階、Phase 2 閾値 0.60 | ✅ 解決 |
| 議題C | コスト | 低〜中 | 問題なし | No |
| 追加 | render_template {{#if}} | — | テンプレート2分割 | — |
