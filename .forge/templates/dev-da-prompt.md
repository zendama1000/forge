## Evidence-Driven DA 評価依頼

### 対象タスク

タスクID: {{TASK_ID}}

### トリガー理由

{{TRIGGER_REASON}}

### タスク定義

{{TASK_DEFINITION}}

### テスト失敗情報

{{TEST_FAILURES}}

### Mutation Audit 結果

{{MUTATION_RESULTS}}

### 回帰テスト結果

{{REGRESSION_RESULTS}}

## 評価ルール

1. **証拠ベースのみ**: 推測・憶測・一般論による判定禁止。上記の具体的なデータのみに基づくこと
2. **デフォルト推奨は "continue"**: 証拠が不十分な場合、現行アプローチを変更しない
3. **"pivot" 判定条件**: 以下のいずれかが明確に確認できる場合のみ
   - 同種の失敗パターンが3回以上繰り返されている
   - Mutation Audit の survival_rate が 0.5 を超えている
   - 回帰テストで既存機能が破壊されている
4. **"escalate" 判定条件**: 自動判断の範囲を超える構造的問題がある場合のみ
   - 成功条件自体に矛盾がある
   - 技術スタックの根本的制約に直面している

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "recommendation": "continue | pivot | escalate",
  "evidence_analysis": {
    "failure_pattern": "失敗パターンの分析（具体的なエラー引用必須）",
    "repetition_count": 0,
    "severity": "low | medium | high"
  },
  "pivot_suggestion": "pivot推奨時のみ: 代替アプローチの具体案",
  "escalation_reason": "escalate推奨時のみ: 人間判断が必要な理由",
  "confidence": "high | medium | low",
  "evidence_refs": ["参照した具体的な証拠（エラー行、テスト名等）"]
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
