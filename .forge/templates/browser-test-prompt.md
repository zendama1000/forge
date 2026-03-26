## Browser Test: ライブページ検証

### テスト ID

{{TEST_ID}}

### テスト指示

{{INSTRUCTIONS}}

### 作業ディレクトリ

{{WORK_DIR}}

## 実行手順

1. Playwright MCP を使用して指定された操作を実行してください
2. 各操作の結果を検証してください
3. 全ステップの結果を JSON で出力してください

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "verdict": "pass | fail",
  "steps": [
    {
      "action": "実行した操作",
      "expected": "期待結果",
      "actual": "実際の結果",
      "passed": true
    }
  ],
  "failure_reason": "fail の場合: 失敗理由",
  "screenshots": ["取得したスクリーンショットのパス"]
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
