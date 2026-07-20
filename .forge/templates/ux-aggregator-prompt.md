# UX 判定の集約・調停

3チャネルの UX 評価結果を統合し、実行可能な統合 must_fix（最大 {{MAX_MUST_FIX}} 件）を出力せよ。

## チャネル別結果

### 構造検査（非LLM・機械検査）

```json
{{STRUCTURAL_RESULT}}
```

### 模擬ユーザー（行動証拠）

```json
{{SIM_USER_RESULTS}}
```

### 美観ジャッジ（レンズ別）

```json
{{AESTHETIC_RESULTS}}
```

## 処理規則

1. resolution_criteria が反証不能な must_fix は rejected_items に落とす（理由付き）
2. 矛盾する指摘は、模擬ユーザーの摩擦証拠・構造検査の機械的違反を優先根拠に
   **1方向に調停**する。contradictions に調停内容を記録する
3. 複数チャネルの同一問題は1件に統合（origin_channel は証拠の強い方: structural > sim_user > aesthetic）
4. 統合 must_fix は重要度順で最大 {{MAX_MUST_FIX}} 件。優先: 機械的違反 > 完遂阻害 > 美観
5. チャネル結果に無い問題を新規指摘しない
6. 美観チャネル由来の項目には origin_lens（元レンズ名）を必ず記録する

## キャリブレーション（人間裁定の事例 — 判定の厳しさをこれに較正せよ）

{{CALIBRATION_EXAMPLES}}

## 出力

以下のスキーマの JSON のみを出力すること:

```json
{
  "verdict": "pass | fix",
  "must_fix": [
    {
      "title": "...",
      "description": "...",
      "resolution_criteria": "...",
      "origin_channel": "aesthetic | sim_user | structural",
      "origin_lens": "（aesthetic 由来の場合のみ）"
    }
  ],
  "rejected_items": [{"title": "...", "reason": "..."}],
  "contradictions": [{"summary": "...", "resolution": "..."}]
}
```
