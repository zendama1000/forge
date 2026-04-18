## LLM Judge: 動画シナリオ成果物の総合品質評価

シナリオ実行後に生成された `summary.json`（ffprobe 出力 + assertions 結果 + シナリオ意図）を評価し、
0.0-1.0 のスコアと理由を返してください。視覚的な違和感は主観依存のため、
本 judge は **メタデータと意図の整合性** と **機械ゲートの合格状況** に責任を持ちます。

### 対象シナリオ

シナリオID: {{SCENARIO_ID}}

### シナリオ定義（scenario.json 抜粋）

{{SCENARIO_JSON}}

### 成果物サマリ（summary.json）

{{SUMMARY_JSON}}

### 評価基準（judge_criteria）

{{JUDGE_CRITERIA}}

## 評価ルール

1. **意図整合性**: scenario.json の intent/description と output メタデータ（duration/resolution/codec/target_format）が整合しているか
2. **機械ゲート合格**: summary.mechanical_gates_summary が全 PASS か（blocking な FAIL は重大減点）
3. **duration 期待範囲**: scenario.expected_duration_sec ± duration_tolerance_sec に output.duration_sec が収まっているか
4. **フォーマット一致**: scenario.target_format と output ファイル拡張子/codec が一致しているか
5. **エラー/警告の重大性**: summary.errors が空であること、summary.warnings は非致命で許容

scoring rubric:
- 0.9-1.0: 完全合格（全基準をクリア、減点なし）
- 0.7-0.89: 合格（軽微な warning はあるが意図達成）
- 0.5-0.69: 条件付き（主要指標の一部逸脱、再実行推奨）
- 0.0-0.49: 不合格（意図未達 / 機械ゲート失敗 / ファイル破損）

合格閾値は 0.7（success_threshold と一致）。

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "scenario_id": "slideshow",
  "score": 0.85,
  "pass": true,
  "criteria_scores": [
    {
      "criterion": "意図整合性",
      "score": 0.9,
      "rationale": "intent が示す 1920x1080 と output.resolution が一致"
    }
  ],
  "overall_rationale": "主要基準を満たしており合格閾値 0.7 を超過",
  "summary": "合格。軽微な警告のみ。"
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
- score は 0.0-1.0 の数値、pass は boolean（score >= 0.7 のとき true）
