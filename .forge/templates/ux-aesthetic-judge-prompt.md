# 美観ジャッジ実行

以下のレンズ定義に従って、対象 UI の視覚品質を評価せよ。

## レンズ定義（この原則のみで判定する）

{{LENS_DEFINITION}}

## 対象

- エントリ URL: {{ENTRY_URL}}
- 確認するビューポート: {{VIEWPORTS}}
  （browser_resize で切り替え、各ビューポートでスクリーンショットを撮ること）
- 参考: このプロダクトの代表的なユーザーゴール
{{SCENARIOS_SUMMARY}}

## 手順

1. エントリ URL を開き、各ビューポートでスクリーンショットを撮る
2. ナビゲーションで到達できる主要画面（最大5画面）を巡回し、同様に確認する
3. レンズの各原則に照らして評価する。破壊的操作は行わない

## キャリブレーション（人間裁定の事例 — 判定の厳しさをこれに較正せよ）

{{CALIBRATION_EXAMPLES}}

## 出力

以下のスキーマの JSON のみを出力すること。must_fix は重要度順で
**最大 {{MAX_MUST_FIX}} 件**。各件の resolution_criteria は検証可能な記述
（px・個数・具体的状態）で書くこと。反証不能な記述は集約器がリジェクトする。

```json
{
  "lens_id": "{{LENS_ID}}",
  "verdict": "pass | fix_needed",
  "must_fix": [
    {
      "title": "...",
      "description": "（どの画面のどの要素が、レンズのどの原則に反するか）",
      "severity": "high | medium | low",
      "resolution_criteria": "（何を満たせば解決か — 検証可能に）"
    }
  ],
  "observations": ["（must_fix に満たない所見）"]
}
```
