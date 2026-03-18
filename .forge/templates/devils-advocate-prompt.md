## リサーチテーマ

{{THEME}}

テーマの全要素がリサーチでカバーされているか検証してください。

## Synthesizerの統合レポート

{{SYNTHESIS}}

## Researcherの個別レポート（元データアクセス権）

以下のファイルを直接参照し、Synthesizerが都合よく統合していないか検証してください:

{{REPORT_FILES}}

## feedback_id

{{FEEDBACK_ID}}

## 前回の自分のフィードバック

{{PREVIOUS_DA_FEEDBACK}}

上記が存在する場合、最優先タスクとして:
1. 前回の各must_fix項目（id付き）が今回のSynthesisで修正されているか検証する
2. Synthesisの `feedback_response` フィールドを確認し、修正の証拠を評価する
3. 未解決のmust_fix項目は今回のmust_fixに繰り越す（carry_count を +1 して同一idを維持。新規指摘より優先）
4. 繰り越し項目の related_perspectives はそのまま引き継ぐ

verdictの判定基準に追加:
- 前回must_fixの過半数が未解決の場合、GOは不可
- carry_count >= 2 の項目が存在する場合、構造的問題の可能性を明示すること

## タスク

0. 【CONDITIONAL-GOループ時のみ】前回must_fixの修正状況を検証する
1. 推奨の前提を攻撃する
2. 確証バイアス、生存者バイアス等を検出する
3. 最悪シナリオを描く
4. 機会費用を算出する
5. 調査スコープが適切か検証する
6. テーマの全要素がリサーチ推奨でカバーされているか検証する
   - テーマを要素に分解し、各要素のカバー状況を scope_assessment.theme_coverage に記録
   - 未カバー要素は must_fix に追加する

## Verdict基準

- GO: 推奨は十分な品質
- CONDITIONAL-GO: 特定の追加調査/修正が必要（must_fixに具体的に記載）
- NO-GO: 問いの立て方自体に問題
- ABORT: リサーチ自体が不要/有害

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "devils_advocate": {
    "feedback_id": "{{FEEDBACK_ID}}",
    "verdict": "GO|CONDITIONAL-GO|NO-GO|ABORT",
    "previous_feedback_review": [
      {"must_fix_item": "前回の指摘内容", "resolved": true, "evidence": "修正の証拠または未修正の理由"}
    ],
    "assumption_attacks": [
      {"assumption": "...", "weakness": "...", "impact": "..."}
    ],
    "biases_detected": [
      {"type": "...", "evidence": "...", "severity": "high|medium|low"}
    ],
    "worst_case_scenario": "...",
    "opportunity_cost": "...",
    "scope_assessment": {
      "too_shallow": ["..."],
      "too_deep": ["..."],
      "missing": ["..."],
      "theme_coverage": {
        "theme_elements": ["element1", "element2"],
        "covered": ["element1"],
        "uncovered": ["element2"]
      }
    },
    "feedback": {
      "must_fix": [
        {
          "id": "MF-001",
          "category": "evidence|methodology|scope|bias|assumption",
          "description": "具体的な修正内容",
          "resolution_criteria": "この条件を満たせば解決とみなす",
          "related_perspectives": ["technical", "cost"],
          "carry_count": 0
        }
      ],
      "should_fix": ["..."],
      "nice_to_have": ["..."]
    }
  }
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
