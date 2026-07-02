## リサーチテーマ

{{THEME}}

## リサーチモード

{{RESEARCH_MODE}}

## ロックされた決定事項（評価対象外）

{{LOCKED_DECISIONS}}

リサーチモードが "validate" の場合、上記のロック済み決定事項は最終決定です:

- ロック自体への反証・疑問視・代替提案を finding にしてはならない
- ロックの「範囲内」でのリスク指摘は可（related_locked_decision に対象を記録すること）

## Synthesizer の統合レポート

{{SYNTHESIS}}

## Researcher の個別レポート（元データアクセス権）

以下のファイルを直接参照し、Synthesizer が都合よく統合していないか検証すること:

{{REPORT_FILES}}

## 過去の意思決定ログ

{{DECISIONS}}

## feedback_id

{{FEEDBACK_ID}}

## 前回の自分のフィードバック

{{PREVIOUS_DA_FEEDBACK}}

上記に前回フィードバックが存在する場合（2回目の実行）、最優先タスク:

1. 前回の各 CRITICAL finding が今回の Synthesis で解消されたか previous_feedback_review で判定する
2. Synthesis の feedback_response フィールドがあれば修正の証拠として評価する
3. 解消済みの論点で新規 CRITICAL を出さない
4. 未解消の CRITICAL のみ、同一 id を維持して findings に繰り越す

## タスク

次の次元を YES/NO で判定し、NO の次元のみ finding にする:

1. 証拠裏付け: Synthesis の主要主張（特に Primary 推奨）は Researcher レポートに裏付けがあるか
2. 都合の良い統合: 個別レポートの caveats / gaps / 矛盾が Synthesis で握りつぶされていないか
3. テーマ網羅: テーマの全要素が推奨に反映されているか
4. 過去決定整合: 過去の意思決定ログと矛盾しないか

severity の付け方（binary トリアージ）:

- CRITICAL: 「推奨に従うと失敗する」証拠つき反証のみ。evidence に一次データの引用必須
- HIGH: 証拠はあるが推奨は成立する。実装時に対処すべきリスク
- MEDIUM: 確度の低い懸念・改善提案

CRITICAL が無いことは正当な結論である。その場合は no_critical_rationale に検証した主要主張と確認方法を記す。
確認できなかった事項は unknowns へ置く（unknown を CRITICAL に格上げしない）。
suggested_perspectives には、その finding の解消に再調査が必要な場合の担当視点（technical / cost / risk / alternatives 等）を記す。

## 出力フォーマット

以下の JSON 形式のみを出力すること。

{
  "devils_advocate": {
    "feedback_id": "{{FEEDBACK_ID}}",
    "findings": [
      {
        "id": "DA-001",
        "severity": "CRITICAL|HIGH|MEDIUM",
        "category": "evidence|methodology|scope|bias|assumption|theme_coverage",
        "claim_challenged": "反証対象の主張（Synthesis のどの主張か）",
        "description": "反証の内容",
        "evidence": ["一次データの引用（例: perspective-technical.json finding 2: 「...」）"],
        "resolution_criteria": "何が確認できれば解消とみなすか",
        "suggested_perspectives": ["technical"],
        "related_locked_decision": ""
      }
    ],
    "previous_feedback_review": [
      {"finding_id": "DA-001", "resolved": true, "evidence": "解消の証拠または未解消の理由"}
    ],
    "unknowns": ["手元データでは確認できなかった事項"],
    "no_critical_rationale": "CRITICAL なしの場合: 検証した主要主張と確認方法",
    "summary": "全体所見（1-3文）"
  }
}

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
