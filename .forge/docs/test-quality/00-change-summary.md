# Forge テスト品質改善 — テンプレート改修仕様

## 概要

Forgeのテスト品質を根本的に改善するため、以下のテンプレート・エージェント定義を改修する。
目的は「フィードバックループの信号品質向上」であり、テストが正しく失敗し、
失敗時に正しい情報がInvestigatorに伝わる状態を構造的に保証する。

---

## 設計原則

1. **テスト基準を振る舞いレベルまで具体化する**（criteria-generation）
2. **実装とテストを1タスクに統合し、test -f を禁止する**（task-planning）
3. **Implementerにrequired_behaviorsを渡し、behaviorカバレッジを強制する**（implementer）
4. **Mutation Auditでテストの検出力を客観的に証明する**（新エージェント）
5. **Investigatorにbehaviors + mutation結果を渡し、scope判定精度を上げる**（investigator）

---

## ファイル一覧

### 改修ファイル（4件）

| ファイル | 種類 | 主な変更 |
|---------|------|---------|
| `.forge/templates/criteria-generation.md` | テンプレート(WHAT) | behaviors, false_positive_scenario, mutation_survival_threshold, 粒度ルール追加 |
| `.forge/templates/task-planning-prompt.md` | テンプレート(WHAT) | task_type分類, test -f制限, required_behaviors引き継ぎ, タスク統合ルール |
| `.forge/templates/implementer-prompt.md` | テンプレート(WHAT) | required_behaviors受取, behaviorコメント指示（通常モード専用） |
| `.forge/templates/investigator-prompt.md` | テンプレート(WHAT) | required_behaviors入力, mutation audit context, suggested_behavior_changes |

### 改修ファイル — エージェント定義（2件）

| ファイル | 種類 | 主な変更 |
|---------|------|---------|
| `.claude/agents/implementer.md` | エージェント(WHO) | behavior カバレッジ原則, 2モード（通常/テスト強化）定義 |
| `.claude/agents/investigator.md` | エージェント(WHO) | behavior/mutation awareness, scope判定フロー更新 |

### 新規ファイル（3件）

| ファイル | 種類 | 概要 |
|---------|------|------|
| `.claude/agents/mutation-auditor.md` | エージェント(WHO) | Mutation Auditor 役割定義 |
| `.forge/templates/mutation-auditor-prompt.md` | テンプレート(WHAT) | mutation計画立案指示（行番号ベース + original_hint） |
| `.forge/templates/implementer-strengthen-prompt.md` | テンプレート(WHAT) | テスト強化モード専用テンプレート |

### 未作成（今後必要）

| ファイル | 種類 | 概要 |
|---------|------|------|
| `.forge/loops/mutation-runner.sh` | スクリプト | mutation計画を機械的に実行するbashスクリプト（行番号ベース） |
| `ralph-loop.sh` 改修 | オーケストレーション | audit loop組み込み（Implementer PASS後のMutation Auditor実行） |
| `.forge/config/mutation-audit.json` | 設定 | 閾値・回数制限・スキップ条件の設定値 |
| `implementation-criteria.json` スキーマ変更 | データ | behaviorsフィールド追加 |
| `task-stack.json` スキーマ変更 | データ | required_behaviors, task_type追加 |

### 設計ドキュメント

| ファイル | 概要 |
|---------|------|
| `design-holes.md` | 設計の穴・未解決問題の一覧と全決定事項 |

---

## 各ファイルの変更詳細

### 1. criteria-generation.md

**追加セクション: 「Layer 1 テスト基準の品質ルール」**

現状のテンプレートにはテスト基準の「形式」は定義されていたが、「良いテスト基準とは何か」のガイダンスがなかった。

追加内容:
- behaviors フィールド（必須・最低3項目）: 「操作 → 期待結果」形式の振る舞い定義
- false_positive_scenario フィールド（必須）: 偽陽性シナリオ
- behaviors の粒度ルール（3〜8項目/L1基準、8超は分割、自己チェック指示）
- test_type 別の追加ルール（unit_test, lint, type_check, api_check）
- 具体性の NG/OK 例

**追加フィールド: phases[].mutation_survival_threshold**

dev-phase ごとの mutation audit 閾値。mvp: 0.40, core: 0.30, polish: 0.20

**出力スキーマ変更:**
```diff
  "layer_1_criteria": [
    {
      "id": "L1-001",
      "description": "...",
      "test_type": "...",
+     "behaviors": ["操作 → 期待結果", ...],
+     "false_positive_scenario": "...",
      "suggested_command": "..."
    }
  ]
```

### 2. task-planning-prompt.md

**主要変更: タスク統合ルール**

現状: 実装タスクとテスト作成タスクが分離されていた。
改修: 「実装とテストの統合」を分解手順に追加。1タスク = 実装 + テスト。

**主要変更: task_type 分類と validation ルール**

新フィールド task_type (setup / implementation / documentation) を追加。
implementation タスクでは test -f のみの validation を禁止。

```diff
  "tasks": [
    {
+     "task_type": "setup | implementation | documentation",
      "validation": {
        "layer_1": {
          "command": "...",  // implementation では test -f 禁止
        }
      },
+     "required_behaviors": ["criteria の behaviors から引き継ぎ"]
    }
  ]
```

**主要変更: required_behaviors 引き継ぎルール**

criteria の behaviors をタスクに紐付ける具体的な手順とルールを追加。
全 behaviors がいずれかのタスクに割り当てられていること（漏れ禁止）。

**削除:**
```diff
- validation.layer_1.command は必須。テストが書けない場合は
- `bash -c "test -f <生成ファイル>"` のような存在確認でもよい
```

### 3. implementer-prompt.md（通常モード）

**追加セクション: 「必須テスト振る舞い」**

新テンプレート変数 `{{REQUIRED_BEHAVIORS}}` を追加。
task-stack.json の required_behaviors がここに注入される。

**追加: behavior カバレッジルール**

```
// behavior: 正しいメールとパスワードでサインアップ → 201 + userId返却
test('should return 201 with userId on valid signup', async () => {
  ...
});
```

各テストケースに `// behavior:` コメントを付与する指示を追加。

**追加: テスト品質ルール**

- アサーションの具体性ルール（NG: toBeTruthy() / OK: toBe(201)）
- ステータスコードの数値検証必須
- レスポンスボディのキーフィールド検証
- エラーレスポンスの二重検証（ステータス + メッセージ）

### 4. implementer-strengthen-prompt.md（テスト強化モード・新規）

Mutation Audit で FAIL 判定後に使用されるテンプレート。

テンプレート変数:
- `{{TASK_JSON}}`: タスク定義
- `{{LAYER1_COMMAND}}`: テスト実行コマンド
- `{{REQUIRED_BEHAVIORS}}`: 必須テスト振る舞い
- `{{MUTATION_FEEDBACK}}`: surviving mutant 情報
- `{{CONTEXT}}`: 追加コンテキスト

制約:
- 実装コード変更不可
- テストコードのみ修正
- surviving mutant に対応するアサーションを追加

**設計判断:** render_template() は bash parameter expansion ベースで `{{#if}}` 条件分岐をサポートしていない。そのため通常モードとテスト強化モードを別テンプレートに分割し、ralph-loop.sh 側でモードに応じたテンプレートを選択する。

### 5. investigator-prompt.md

**追加入力: required_behaviors, mutation audit context**

新テンプレート変数:
- `{{REQUIRED_BEHAVIORS}}`: criteria 由来の振る舞い定義
- `{{MUTATION_AUDIT_CONTEXT}}`: Mutation Audit の結果（該当する場合）

**追加: 診断手順の拡張**

手順3「必須テスト振る舞いと照合する」を追加:
- behavior カバレッジ確認
- behavior 定義自体の問題特定

手順4「Mutation Audit 結果を考慮する」を追加:
- surviving mutant の原因分析（フレームワーク制約 / behavior不十分 / 能力限界）

**追加: scope判定フローチャートの拡張**

behavior 定義の問題を criteria スコープとして判定するフローを追加。

**追加: 出力フィールド suggested_behavior_changes**

```json
"suggested_behavior_changes": {
  "add": ["追加すべき behavior"],
  "remove": ["削除すべき behavior"],
  "modify": [{"from": "変更前", "to": "変更後"}]
}
```

### 6. mutation-auditor.md（新規エージェント）

Mutation Auditor の役割定義（WHO）。
- mutation 対象カテゴリの優先度順定義
- 行番号の正確性ルール
- original_hint の検証用途の説明
- behavior カバレッジ保証
- mutation の多様性ルール

### 7. mutation-auditor-prompt.md（新規テンプレート）

Mutation Auditor のタスク指示（WHAT）。

テンプレート変数:
- `{{TASK_ID}}`: タスクID
- `{{IMPL_FILES}}`: 実装コード（行番号付き、複数ファイル対応）
- `{{TEST_CODE}}`: テストコード
- `{{REQUIRED_BEHAVIORS}}`: 必須テスト振る舞い
- `{{TEST_COMMAND}}`: テスト実行コマンド

**設計判断（穴1対応）: 行番号ベース + original_hint 方式**

Planner は `line_start` / `line_end` で対象行を指定する。`original_hint` は検証用に対象行の内容をコピーするが、mutation-runner.sh がマッチングに使用するわけではない。

出力スキーマ:
```json
{
  "task_id": "...",
  "source_files": ["実装コードのファイルパス"],
  "mutate_target": "mutation対象のメインファイルパス",
  "test_command": "...",
  "mutants": [
    {
      "id": "M-001",
      "category": "return_value | condition_negate | exception_remove | boundary_change | guard_remove | call_remove",
      "target_behavior": "対応する必須テスト振る舞い（該当しない場合は null）",
      "file": "変更対象のファイルパス",
      "line_start": 42,
      "line_end": 42,
      "original_hint": "対象行の内容（検証用）",
      "mutant": "変更後の文字列",
      "rationale": "この mutation が検出されるべき理由"
    }
  ],
  "behavior_coverage": {
    "振る舞い定義1": ["M-001", "M-003"],
    "振る舞い定義2": ["M-002"]
  }
}
```

---

## データフロー（改修後）

```
Phase 1.5a: criteria-generation
  出力: L1基準 + behaviors + false_positive_scenario
  ※レベル2（振る舞い）まで具体化
  ※behaviors 粒度ルール: 3〜8項目/L1基準

Phase 1.5b: task-planning
  入力: criteria（behaviors付き）
  出力: タスク定義 + required_behaviors + task_type
  ※test -f 禁止、タスク統合

Phase 2: Ralph Loop
  ┌────────────────────────────────────────┐
  │                                        │
  │  Implementer（通常モード）              │
  │    テンプレート: implementer-prompt.md  │
  │    入力: タスク + required_behaviors    │
  │    出力: 実装 + テスト（behaviorコメント付き）│
  │    validation: テスト実行              │
  │      │                                 │
  │      ├ FAIL → retry (max 3) → Investigator │
  │      │                                 │
  │      ├ PASS ↓                          │
  │      │                                 │
  │  ※ task_type が setup/documentation    │
  │    または mvp フェーズ → skip to 完了   │
  │      │                                 │
  │  Mutation Planner (LLM)                │
  │    入力: 実装(行番号付き) + テスト + behaviors │
  │    出力: mutation-plan.json            │
  │      │                                 │
  │  Mutation Runner (bash)                │
  │    入力: mutation-plan.json            │
  │    処理: sed -n で対象行取得 →         │
  │          mutant で置換 → テスト → 復元 │
  │    検証: original_hint と実際の行の簡易比較 │
  │    出力: mutation-results.json         │
  │      │                                 │
  │  Verdict (bash)                        │
  │      │                                 │
  │      ├ PASS → タスク完了 ✓             │
  │      ├ REPLAN → Planner再実行 (max 2)  │
  │      └ FAIL → Implementer(テスト強化)  │
  │          テンプレート: implementer-strengthen-prompt.md │
  │          (audit loop max 2)            │
  │          └ FAIL×2 → Investigator       │
  │            （テスタビリティ問題フラグ付き）│
  │                                        │
  └────────────────────────────────────────┘
```

---

## 閾値・設定値（mutation-audit.json）

```json
{
  "mutation_audit": {
    "enabled": true,
    "skip_task_types": ["setup", "documentation"],
    "phase_config": {
      "mvp": { "enabled": false },
      "core": { "enabled": true },
      "polish": { "enabled": true }
    },
    "mutant_count": { "min": 5, "max": 15 },
    "survival_threshold": {
      "mvp": 0.40,
      "core": 0.30,
      "finishing": 0.20
    },
    "error_rate_threshold": 0.40,
    "behavior_coverage_required": 1.0,
    "max_plan_attempts": 2,
    "max_audit_attempts": 2,
    "runner_timeout_per_mutant_sec": 60,
    "model": "sonnet"
  }
}
```

**設計判断:**
- mvp フェーズは mutation audit OFF（「まず動くものを作る」フェーズ。品質検証は core 以降）
- runner_timeout は 60秒（テスト実行が30秒超ならテスト自体が重すぎる指標）
- survival_threshold の mvp 値は Phase 3 有効化後に使用（Phase 2 は 0.60 で試行）

---

## 既存プロジェクトとの互換性

新フィールド（task_type, required_behaviors, dev_phase_id）は既存の task-stack.json に存在しない。

**方針:** 新プロジェクトから新フローを適用。既存プロジェクトは旧フローで走り切らせる。

ralph-loop.sh に最低限の防御コードを追加:
```bash
local task_type=$(echo "$task_json" | jq -r '.task_type // empty')
local has_behaviors=$(echo "$task_json" | jq 'has("required_behaviors")')
if [ -z "$task_type" ] || [ "$has_behaviors" = "false" ]; then
  log "  mutation audit skip: 新フォーマット未対応タスク"
  return 0
fi
```

---

## 導入計画（3段階）

### Phase 1: テンプレート改修のみ適用

対象ファイル:
- criteria-generation.md（behaviors, 粒度ルール, false_positive_scenario）
- task-planning-prompt.md（task_type, test -f 禁止, required_behaviors）
- implementer-prompt.md（通常モード、behavior カバレッジ）
- implementer.md（エージェント定義更新）

mutation 関連は一切触らない。1プロジェクトで実行し観測:
- test -f only タスクの割合（目標: implementation 系で 0%）
- behaviors 付き criteria の品質
- Implementer の behavior コメント遵守率

### Phase 2: mutation audit 閾値 0.60 で試行

対象ファイル:
- mutation-runner.sh（新規、行番号ベース + original_hint 方式）
- mutation-auditor.md / mutation-auditor-prompt.md（配置）
- mutation-audit.json（設定追加）
- ralph-loop.sh（run_mutation_audit() 追加）
- implementer-strengthen-prompt.md（配置）

FAIL 判定あり（閾値 0.60）。1プロジェクトで観測:
- survival_rate の分布（平均・中央値・最大値）
- error_rate（行番号ミス率、original_hint 不一致率）
- audit loop の FAIL→再実行→再audit パスの動作確認
- Planner の計画品質（behavior カバレッジ達成率）

### Phase 3: 本番閾値で全面適用

対象ファイル:
- mutation-audit.json（閾値更新: Phase 2 の観測データに基づく）
- investigator-prompt.md / investigator.md（mutation audit context 対応）

Phase 2 データに基づき閾値を確定（暫定: mvp:0.40, core:0.30, polish:0.20）。

---

## 未実装部分（今後必要）

1. **mutation-runner.sh**: mutation計画を機械的に実行するbashスクリプト（行番号ベース + original_hint 検証）
2. **ralph-loop.sh 改修**: audit loop の組み込み（run_mutation_audit関数、テンプレート選択分岐）
3. **generate-tasks.sh 改修**: task_type, required_behaviors の引き継ぎ処理
4. **forge-flow.sh 改修**: チェックポイントで mutation audit スキップタスクを表示
5. **exit_criteria の expect フィールド活用**: generate_phase_test_scripts() で expect を検証するロジック追加（スコープ外。別 issue として管理）
