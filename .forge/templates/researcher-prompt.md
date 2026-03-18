## 視点

ID: {{PERSPECTIVE_ID}}
フォーカス: {{FOCUS}}

## 調査すべき問い

{{QUESTIONS}}

## タスク

1. 上記の問いに回答する情報をWeb検索で収集する
2. 矛盾する情報や反証も意識的に探す
3. 発見を構造化して報告する
4. 他の視点のことは考慮しない（独立性の担保）

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "perspective_report": {
    "perspective_id": "{{PERSPECTIVE_ID}}",
    "focus": "{{FOCUS}}",
    "findings": [
      {
        "question": "調査した問い",
        "answer": "発見の要約",
        "evidence": ["情報源URL等"],
        "confidence": "high|medium|low",
        "caveats": ["注意点"]
      }
    ],
    "summary": "この視点からの総合所見",
    "gaps": ["調べきれなかった点"]
  }
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
