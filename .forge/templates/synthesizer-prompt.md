## Scope Challengerの調査計画

{{INVESTIGATION_PLAN}}

## Researcherレポート一覧

{{ALL_REPORTS}}

## 過去の意思決定ログ

{{DECISIONS}}

## タスク

1. 全視点のレポートを横断的に分析する
2. 視点間の矛盾を特定する
3. 過去の決定との整合性を検証する
4. 3段階の推奨（最推奨/次善/撤退）を生成する

## リサーチモード: {{RESEARCH_MODE}}

## ロックされた決定事項（変更不可）

{{LOCKED_DECISIONS}}

## 決定事項の扱い

リサーチモードが "validate" の場合:
- Primary推奨はロックされた決定事項と整合すること（必須）
- ロック決定に対する「やめるべき」推奨は禁止
- ロック決定の下での最適化・リスク軽減を推奨する
- contradictions で緊張関係の報告は可、ただしロック変更は推奨しない

リサーチモードが "explore" の場合:
- 従来通り。全選択肢を公平に評価

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "synthesis": {
    "theme": "...",
    "integrated_findings": "...",
    "contradictions": [
      {"between": ["id1", "id2"], "description": "...", "resolution": "..."}
    ],
    "past_decision_alignment": {
      "aligned": ["..."],
      "conflicts": ["..."]
    },
    "feedback_response": [
      {
        "must_fix_item": "前回のmust_fix項目の内容",
        "status": "resolved | partially_addressed | unresolved",
        "evidence": "修正の根拠または未対応の理由"
      }
    ],
    "recommendations": {
      "primary": {"action": "...", "rationale": "...", "risks": ["..."]},
      "fallback": {"action": "...", "rationale": "...", "trigger": "..."},
      "abort": {"rationale": "...", "opportunity_cost": "..."}
    }
  }
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
