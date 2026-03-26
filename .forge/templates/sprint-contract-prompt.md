## Sprint Contract: タスク実行可能性評価

### タスク定義

{{TASK_JSON}}

### 評価指示

あなたは Implementer（実装者）の視点で、このタスクの実行可能性を評価してください。

以下の観点で判定すること:
1. **タスクスコープ**: 1つの実装セッションで完了可能か
2. **テスト定義**: Layer 1 テストコマンドは具体的で実行可能か
3. **依存関係**: 前提条件は満たされているか
4. **曖昧性**: タスク定義に曖昧な点がないか
5. **required_behaviors**: 検証可能な形で定義されているか

### プロジェクトコンテキスト

{{CONTEXT}}

## 判定基準

- `achievable`: タスクはそのまま実行可能
- `needs_adjustment`: 以下のいずれかに該当:
  - テストコマンドが不正確・実行不能
  - required_behaviors が曖昧すぎて検証不能
  - スコープが広すぎて1セッションで完了困難
  - 依存関係が未解決

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "feasibility": "achievable | needs_adjustment",
  "issues": [
    {
      "type": "scope | test_definition | dependency | ambiguity",
      "description": "問題の説明",
      "suggestion": "修正案"
    }
  ],
  "adjustments": "needs_adjustment の場合: タスク定義への具体的修正提案",
  "auto_adjustable": true
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
