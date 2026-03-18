## 調査対象タスク

タスクID: {{TASK_ID}}

## 失敗コンテキスト

{{FAILURE_CONTEXT}}

## 関連する成功条件（implementation-criteria.json 抜粋）

{{CRITERIA_EXCERPT}}

## 必須テスト振る舞い（criteria 由来）

{{REQUIRED_BEHAVIORS}}

## Mutation Audit 結果

{{MUTATION_AUDIT_CONTEXT}}

## Layer 3 受入テスト失敗コンテキスト

{{L3_FAILURE_CONTEXT}}

L3 テスト失敗の場合:
- strategy (structural/api_e2e/llm_judge/cli_flow/context_injection) に応じた分析を行う
- llm_judge 失敗: スコアと judge_criteria を確認し、出力品質の問題箇所を特定する
- api_e2e 失敗: API 連鎖のどのステップで破綻したかを特定する
- structural 失敗: 出力の構造がスキーマに適合しない原因を特定する

## Evidence-Driven DA 分析結果

{{EVIDENCE_DA_CONTEXT}}

DA の推奨がある場合:
- "pivot" → scope="approach" を検討
- "continue" → 参考情報として扱う（DA は advisory）
- "escalate" → scope="criteria" or "research" を検討

## タスク

上記のタスクは{{MAX_RETRIES}}回連続で失敗しました。根本原因を診断してください。

### 診断手順

1. **エラー出力を分析する**
   - 全回の失敗出力を比較し、共通パターンを特定する
   - エラーメッセージの表面的な意味だけでなく、根本的な原因を推測する

2. **タスク定義と照合する**
   - タスク定義の description と validation が矛盾していないか確認する
   - 前提条件（depends_on、環境変数等）が満たされているか確認する

3. **必須テスト振る舞いと照合する**
   - テストコードが required_behaviors の各項目をカバーしているか確認する
   - behavior の定義自体が曖昧または不正確でないか確認する
   - テスト失敗が「behavior 定義の問題」か「実装コードの問題」かを区別する

4. **Mutation Audit 結果を考慮する（該当する場合）**
   - Mutation Audit のコンテキストがある場合、surviving mutant 情報を確認する
   - Implementer がテスト強化を試みたが改善しなかった場合:
     - テストフレームワークの制約で該当アサーションが書けないのか
     - behavior 定義が不十分で何をテストすべきか不明確なのか
     - Implementer の能力限界なのか
   を区別する

5. **scope判定を行う**
   - エラーが実装コード内で完結するなら → `"task"`
   - 外部仕様の前提が違うなら → `"criteria"`
   - テスト振る舞い定義が不十分・不正確なら → `"criteria"` （behavior 修正を推奨）
   - リサーチの結論が現実と乖離しているなら → `"research"`
   - 同種の障壁がアプローチ全体に波及し、回避策がないなら → `"approach"`

6. **具体的な推奨を策定する**
   - scope が "task" の場合: 修正の具体的な方向性を提案する
   - scope が "criteria" の場合: どの前提条件が不正確かを特定する。behavior の修正が必要な場合は具体的な修正案を含める
   - scope が "research" の場合: どのリサーチ結論が崩壊したかを特定する
   - scope が "approach" の場合: アプローチのどの前提が根本的限界に達したかを特定し、実装で得た知見（何が動いて何が動かないか）を明確に記述する

### 判定の原則

- 証拠がない推測は避ける
- 複数の原因候補がある場合、最も証拠が多いものを選ぶ
- confidence は正直に付与する（根拠が薄い場合は "low" とする）
- scope に迷った場合は "task" をデフォルトとする（最も安全）

### "approach" 判定の慎重な使用

"approach" は最も重い判定であり、プロジェクトのアプローチ転換を示唆する。以下の全てを満たす場合のみ判定すること:
- 障壁がこのタスク固有ではなく、アプローチ全体に波及する
- 技術的回避策を検討した上で、原理的に困難と判断できる
- 証拠（エラーログ、公式ドキュメント、外部情報）が存在する

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "task_id": "{{TASK_ID}}",
  "scope": "task | criteria | research | approach",
  "root_cause": "根本原因の説明",
  "evidence": [
    "証拠1: エラー出力の具体的な引用",
    "証拠2: タスク定義との矛盾点"
  ],
  "recommendation": "推奨する次のアクション",
  "confidence": "high | medium | low",
  "related_criteria": "関連するcriteria ID（L1-XXX等）。不明な場合はnull",
  "suggested_task_changes": {
    "description": "修正後のタスク説明（scope=taskの場合のみ）",
    "validation_update": "テスト条件の修正案（必要な場合のみ）"
  },
  "suggested_behavior_changes": {
    "add": ["追加すべき behavior（scope=criteriaでbehavior修正が必要な場合のみ）"],
    "remove": ["削除すべき behavior（同上）"],
    "modify": [{"from": "変更前 behavior", "to": "変更後 behavior"}]
  },
  "approach_context": {
    "what_works": "実装で動作確認できた部分（scope=approachの場合のみ。それ以外では省略可）",
    "fundamental_barrier": "回避不能と判断した障壁の具体的説明（scope=approachの場合のみ）",
    "attempted_workarounds": "試みた回避策とその結果（scope=approachの場合のみ）"
  }
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
