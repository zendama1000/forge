## テーマ

{{THEME}}

## 方向性・制約

{{DIRECTION}}

## 過去の意思決定ログ

{{DECISIONS}}

## タスク

1. テーマを回答可能な問いに分解する
2. 暗黙の前提を洗い出す
3. 過去の決定との矛盾がないか確認する
4. 調査の境界（深さ・広さ・打ち切り条件）を定義する
5. 固定4視点に加え、必要なら動的視点（最大2、差別化理由必須）を追加する

## 固定4視点

- technical: 技術的実現性
- cost: コスト・リソース
- risk: リスク・失敗モード
- alternatives: 代替案・競合

## リサーチモード: {{RESEARCH_MODE}}

## ロックされた決定事項（変更不可）

{{LOCKED_DECISIONS}}

## 調査対象の未決事項

{{OPEN_QUESTIONS}}

## 決定事項の扱い

リサーチモードが "validate" の場合:
- ロックされた決定事項は最終決定。疑問視・代替提案禁止
- 調査計画は未決事項の調査に集中する
- boundaries.cutoff に「ロックされた決定事項は調査対象外」と明記する
- alternatives 視点: ロック範囲内での選択肢比較のみ（ロック自体の代替は不可）

リサーチモードが "explore" の場合:
- 全てが調査対象。従来通り

## 出力フォーマット

以下のJSON形式のみを出力してください。説明文は不要です。

```json
{
  "investigation_plan": {
    "theme": "...",
    "core_questions": ["..."],
    "assumptions_exposed": ["..."],
    "past_decision_conflicts": [],
    "boundaries": {"depth": "...", "breadth": "...", "cutoff": "..."},
    "perspectives": {
      "fixed": [
        {"id": "technical", "focus": "技術的実現性", "key_questions": ["..."]},
        {"id": "cost", "focus": "コスト・リソース", "key_questions": ["..."]},
        {"id": "risk", "focus": "リスク・失敗モード", "key_questions": ["..."]},
        {"id": "alternatives", "focus": "代替案・競合", "key_questions": ["..."]}
      ],
      "dynamic": []
    }
  }
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
