# UX シナリオ生成

以下の implementation-criteria を、実装知識ゼロの模擬ユーザーに与える
「ユーザー語彙のゴール」に変換せよ。

## Criteria

```json
{{CRITERIA_JSON}}
```

## パラメータ

- エントリ URL のベース: {{ENTRY_URL}}
- 生成するシナリオ数: 最大 {{MAX_SCENARIOS}} 件
- entry_url はベース URL からの相対パス（通常 "/"）で書く

{{REJECTED_TERMS_NOTE}}

## 出力形式

以下のスキーマに準拠した JSON のみを出力すること:

```json
{
  "scenarios": [
    {
      "scenario_id": "UX-S-001",
      "user_goal": "（動機と目的のみ。操作手順・実装用語は禁止）",
      "entry_url": "/",
      "action_budget": 10,
      "viewport": "mobile",
      "success_signal": "（ユーザー主観で完遂と判断できる状態）"
    }
  ]
}
```

禁止事項（違反すると機械ゲートでリジェクトされ再生成になる）:
- criteria 内のコンポーネント名・機能ID・ファイル名・識別子を user_goal / success_signal に含めること
- 「〜ボタンを押す」「〜画面へ遷移」のような達成手段の記述
