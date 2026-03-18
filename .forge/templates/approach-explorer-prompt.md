## 元のテーマ

{{ORIGINAL_THEME}}

## リサーチで設計された調査計画（概要）

{{INVESTIGATION_PLAN_SUMMARY}}

## 実装で得た知見

### 動作した部分
{{WHAT_WORKS}}

### 根本的障壁
{{FUNDAMENTAL_BARRIER}}

### 試みた回避策
{{ATTEMPTED_WORKAROUNDS}}

## Investigator診断ログ

{{INVESTIGATION_LOG}}

## タスク

上記プロジェクトは実装フェーズでアプローチの根本的限界に到達しました。

### 分析手順

1. **上位問題の再定義**
   - テーマに含まれる手段（how）を除去し、目的（what/why）を抽出する
   - ユーザーが本当に解きたい問題は何か

2. **代替アプローチの探索**
   - Web検索で関連技術・手法・ツールを調査する
   - 既存技術の新しい組み合わせを積極的に検討する
   - 以下の3軸で探索する:
     a. 技術の組み替え: 同じ目的を別の技術で実現
     b. 分割と再結合: 問題を分割し、部分ごとに最適な手段を組み合わせ
     c. 制約の転換: 制約を受け入れて別の価値を生む

3. **実装知見の転用分析**
   - 「動作した部分」が各候補でどの程度再利用できるか評価する

4. **各候補の実現可能性評価**
   - 技術的実現性、コスト、リスク、開発工数を具体的に見積もる
   - 元のアプローチと同じ壁にぶつかるリスクがないか検証する

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "upper_problem": {
    "original_theme": "ユーザーが渡したテーマ",
    "redefined_problem": "手段を除去した上位問題の定義",
    "core_constraints": ["外せない制約1", "制約2"],
    "negotiable_constraints": ["交渉可能な制約1（元のテーマでは前提だったが本当に必要か）"]
  },
  "current_approach_assessment": {
    "what_worked": "実装で動作した部分のまとめ",
    "fundamental_limit": "なぜこのアプローチでは解決できないか",
    "reusable_assets": ["新アプローチに転用可能な資産1", "資産2"]
  },
  "alternative_approaches": [
    {
      "id": "alt-1",
      "name": "アプローチ名",
      "description": "概要説明",
      "key_technologies": ["技術A", "技術B"],
      "novelty": "既存技術のどの組み合わせが新しいか",
      "feasibility": {
        "technical": "high | medium | low",
        "evidence": "実現可能性の根拠",
        "risks": ["主要リスク1", "リスク2"],
        "same_wall_risk": "元のアプローチと同じ壁にぶつかるリスクの評価"
      },
      "cost_estimate": {
        "development_effort": "概算工数",
        "running_cost": "月間運用コスト概算"
      },
      "reuse_from_current": "現在の実装から転用できる部分",
      "information_sources": ["調査した情報源URL"]
    }
  ],
  "comparison_matrix": {
    "criteria": ["実現可能性", "コスト", "元障壁の回避", "実装転用度", "長期安定性"],
    "scores": {
      "alt-1": [1, 2, 3, 2, 3],
      "alt-2": [3, 1, 3, 1, 2]
    },
    "score_legend": "1=低, 2=中, 3=高"
  },
  "recommendation": {
    "primary": "alt-X",
    "rationale": "推奨理由",
    "next_steps": ["次にやるべきこと1", "ステップ2"]
  }
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
