## QA Evaluator: 独立品質評価

### 対象タスク

タスクID: {{TASK_ID}}

### タスク定義

{{TASK_JSON}}

### Required Behaviors（必須動作）

{{REQUIRED_BEHAVIORS}}

### 実装 Diff

{{IMPL_DIFF}}

### テスト出力

{{TEST_OUTPUT}}

{{CALIBRATION_EXAMPLES}}

## 評価ルール

1. **required_behaviors の完全性**: 各 required_behavior が実装 diff に反映されているか1つずつ検証せよ
2. **テストカバレッジ**: 各 required_behavior に対応するテストケースが存在するか検証せよ
3. **エッジケース**: 明らかな境界値・エラーケースの未処理がないか確認せよ
4. **不要な変更**: タスクスコープ外の変更が含まれていないか確認せよ
5. **甘い判定の禁止**: 「テストが通っているから OK」は不十分。テストの質自体を評価せよ

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "verdict": "pass | fail",
  "issues": [
    {
      "severity": "high | medium | low",
      "description": "具体的な問題の説明",
      "location": "該当箇所（ファイル名:行番号 or 関数名）"
    }
  ],
  "coverage_analysis": {
    "covered_behaviors": ["カバーされている required_behavior"],
    "uncovered_behaviors": ["カバーされていない required_behavior"]
  },
  "feedback": "Implementer への具体的な修正指示"
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
