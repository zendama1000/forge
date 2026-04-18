# Scenario Authoring Guide

Video Harness のシナリオ追加・編集ガイド。`scenarios/<id>/scenario.json` の宣言的定義だけで
`render-loop` / Phase 3 品質ゲート / LLM judge を連動させる「SAC=1（Single Action Cost = 1）」
プラグイン機構の使い方をまとめる。

- 単一情報源スキーマ: [`.forge/schemas/scenario-schema.json`](../../.forge/schemas/scenario-schema.json)
- 最小テンプレート: [`.forge/templates/scenario-minimal.json`](../../.forge/templates/scenario-minimal.json)
- バリデータ: [`.forge/lib/scenario-validator.sh`](../../.forge/lib/scenario-validator.sh)
- スキャナ: [`.forge/lib/scenario-scanner.sh`](../../.forge/lib/scenario-scanner.sh)

---

## 1. SAC=1 プラグイン原則

新しいシナリオ（スライドショー、AIアバター、スクリーン録画、字幕合成 など）を追加するとき、
**ハーネス側のコード変更は禁止**。やることは 1 ディレクトリ追加だけ。

```
scenarios/
  <your-id>/
    scenario.json         # 必須: シナリオ定義（本ガイドの対象）
    agent_prompt_patch.md # 任意: agent 注入テキストを別ファイルで管理する場合
    inputs/               # 任意: このシナリオが参照する入力ファイル
    out/                  # 実行時: 成果物の書き出し先
```

`render-loop.sh` 起動時に `scenario-scanner.sh` が `scenarios/` 配下を **物理スキャン**し、
dispatch テーブルを持たずに自動で検出・実行する。設定ファイルへの登録は一切不要。

### SAC=1 の違反例（やらないこと）

| 違反 | 正しい形 |
|---|---|
| `scenarios/<id>/` 追加 + ハーネス共通設定に `"<id>"` を登録 | ディレクトリ追加だけで完了する |
| ディレクトリ名と `scenario.json.id` の不一致 | 必ず一致させる（scanner が rc=2 で拒否） |
| `quality_gates.required_mechanical_gates` 空配列 | 最低 1 件の機械ゲートを必須で定義する |
| `agent_prompt_patch` にオブジェクト/配列を入れる | **文字列のみ**（スキーマが文字列に限定） |

---

## 2. scenario.json スキーマ表

必須フィールド・型・検証ルールを一覧化。詳細は
[scenario-schema.json](../../.forge/schemas/scenario-schema.json) を参照。

### 2.1 トップレベル

| フィールド | 必須 | 型 | 値の制約 | 目的 |
|---|:---:|---|---|---|
| `id` | ✅ | string | `^[A-Za-z0-9][A-Za-z0-9_-]*$` / ディレクトリ名と一致 | シナリオ識別子 |
| `type` | ✅ | string | enum（下表参照） | dispatch 用のシナリオ種別 |
| `version` |   | string | semver 推奨 / 既定 `"1.0.0"` | 定義バージョン |
| `description` |   | string | 1〜2 行の説明 | 人間向け概要 |
| `input_sources` | ✅ | array | 0 件以上（空配列可） | 必要な入力ファイルの宣言 |
| `quality_gates` | ✅ | object | 後述 | Phase 3 統合検証の機械ゲート |
| `agent_prompt_patch` | ✅ | **string** | 文字列のみ（オブジェクト/配列禁止）| Implementer/Investigator への追加指示 |

> `additionalProperties: true` なので、シナリオ独自のメタ（`intent` / `expected_duration_sec` 等）を
> 追加してもスキーマは通る。`llm_judge.criteria[]` のような拡張もここで受け付ける。

### 2.2 `type` enum

scenario-scanner が検出時に抽出し、dispatch テーブルで使われる。enum 外の値は
`scenario-validator` が拒否する（rc=1）。

| 値 | 用途 |
|---|---|
| `image_slideshow` | 画像ディレクトリ → 動画（ffmpeg concat demuxer） |
| `video_edit` | 動画編集（トリミング・結合・エフェクト） |
| `ai_avatar` | AI アバター（TTS + 合成） |
| `screen_record` | 画面録画 |
| `subtitle_overlay` | 字幕合成 |
| `audio_sync` | 音声同期 |

### 2.3 `input_sources[]`

```json
{
  "type": "image_dir",
  "path": "inputs/images",
  "glob": "*.{jpg,jpeg,png}",
  "required": true,
  "description": "スライドに使う画像"
}
```

| フィールド | 必須 | 型 | 制約 |
|---|:---:|---|---|
| `type` | ✅ | string | enum: `image_dir` / `video_file` / `audio_file` / `text_file` / `subtitle_file` / `script_file` / `config_file` |
| `path` |   | string | `scenarios/<id>/` からの相対パス推奨 |
| `glob` |   | string | `image_dir` 等でファイル絞り込み |
| `required` |   | boolean | 既定 `true`。`false` は任意入力（無ければスキップ） |
| `description` |   | string | 人間向け説明 |

### 2.4 `quality_gates`

```json
{
  "required_mechanical_gates": [
    { "id": "output_exists", "command": "test -f output.mp4", "expect": "exit 0", "blocking": true }
  ],
  "human_checks": [
    { "id": "visual_review", "description": "色ずれが無いか目視確認" }
  ]
}
```

| フィールド | 必須 | 型 | 制約 |
|---|:---:|---|---|
| `required_mechanical_gates` | ✅ | array | **最低 1 件必須（空配列禁止）** |
| `required_mechanical_gates[].id` | ✅ | string | ゲート識別子 |
| `required_mechanical_gates[].command` | ✅ | string | shell コマンド（exit code で評価） |
| `required_mechanical_gates[].description` |   | string | 人間向け |
| `required_mechanical_gates[].expect` |   | string | 期待結果（既定 `exit 0`）|
| `required_mechanical_gates[].blocking` |   | boolean | 既定 `true`。`false` は警告扱い |
| `human_checks[]` |   | array | Phase 4 目視レビュー項目 |

機械ゲートは `run-quality-gates.sh` が Phase 3 で一括実行する。**blocking=true が 1 つでも FAIL
したらシナリオ全体が FAIL**。ffprobe ベースの検査（duration / stream 有無 / 解像度）を最低
1 つは含めることを推奨。

### 2.5 `agent_prompt_patch`

Implementer/Investigator にシナリオ固有の制約をテキストで注入する。
**文字列限定**（スキーマが object/array を拒否）。

典型的な内容:

- 使う技術・禁じる技術（例: `ffmpeg のみ使用、Python 生成禁止`）
- 解像度・コーデック・ビットレートの固定値
- HTTP API 呼び出し禁止などの locked_decisions 補強
- 入出力パスのハードコード指示（`out/output.mp4`）

長文になる場合は `scenarios/<id>/agent_prompt_patch.md` に切り出し、scenario.json では
`"agent_prompt_patch": "詳細は agent_prompt_patch.md を参照してください。"` のように参照する
運用も可。

---

## 3. プラグイン追加ガイド（手順）

### 3.1 最小手順（5 ステップ）

1. **テンプレートをコピー**
   ```bash
   mkdir -p scenarios/my-scenario
   cp .forge/templates/scenario-minimal.json scenarios/my-scenario/scenario.json
   ```
2. **`id` をディレクトリ名と一致させる**
   ```bash
   jq '.id = "my-scenario"' scenarios/my-scenario/scenario.json > tmp && \
     mv tmp scenarios/my-scenario/scenario.json
   ```
3. **`type` / `input_sources` / `quality_gates` / `agent_prompt_patch` を編集**
4. **バリデート**
   ```bash
   bash .forge/lib/scenario-validator.sh scenarios/my-scenario/scenario.json
   # → "INFO: scenario validation passed: ..." を確認
   ```
5. **スキャン確認**
   ```bash
   bash .forge/lib/scenario-scanner.sh scenarios --ids
   # → 一覧に "my-scenario" が表示されることを確認
   ```

### 3.2 チェックリスト

追加前に以下が全て `YES` になっていること。

- [ ] ディレクトリ名 == `scenario.json.id`
- [ ] `type` が enum のいずれか
- [ ] `input_sources[].type` が全て enum のいずれか
- [ ] `quality_gates.required_mechanical_gates` に 1 件以上のゲート
- [ ] 各ゲートに `id` と `command` が存在
- [ ] `agent_prompt_patch` が文字列（object/array ではない）
- [ ] `scenario-validator.sh` が exit 0 を返す
- [ ] `scenario-scanner.sh --ids` に自分のシナリオが出る

### 3.3 よくあるハマりどころ

| 症状 | 原因 | 対処 |
|---|---|---|
| scanner の rc=2、「consistency error」 | ディレクトリ名と `.id` 不一致 | どちらかを修正して一致させる |
| validator「enum violation at .type」 | enum 外の値を入れた | スキーマの enum から選ぶ、または enum 追加をハーネス側にリクエスト |
| Phase 3 が常に PASS（実体検証されていない） | `quality_gates` に機械ゲートが無い / blocking=false のみ | blocking=true の ffprobe ゲートを最低 1 件追加 |
| Implementer が意図と違う実装をする | `agent_prompt_patch` が空 / 曖昧 | 禁則・固定値・優先順を明記する |
| `input_sources[].required=true` なのに CI で落ちる | 入力ファイルがリポジトリ外 | `inputs/` に fixture を置くか、`required: false` にして動的生成する実装にする |

---

## 4. 既存シナリオ参照例

- [`scenarios/slideshow/scenario.json`](../../scenarios/slideshow/scenario.json) — 静止画スライドショー（3 入力源 + 3 機械ゲート）
- [`scenarios/ai-avatar/scenario.json`](../../scenarios/ai-avatar/scenario.json) — AI アバター生成
- [`scenarios/screen-recording/scenario.json`](../../scenarios/screen-recording/scenario.json) — スクリーン録画

---

## 5. 関連ドキュメント

- [assertions-reference.md](assertions-reference.md) — 機械ゲートで使える assertion 型の完全リファレンス
- [long-encode-pattern.md](long-encode-pattern.md) — 10 分超エンコード時の nohup 分離パターン
