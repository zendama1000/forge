# scenario: ai-avatar — agent prompt patch

このファイルは `scenario.json` の `agent_prompt_patch` を人間・エージェント双方に
読みやすい形式で格納した正規ドキュメントです。Implementer / Investigator /
`mock_runner.sh` / 将来の `render.sh` 実装者が参照します。`scenario.json` の
`agent_prompt_patch` 文字列とは **等価な要約** であり、文言が食い違った場合は
`scenario.json` の方を正とすること。

## シナリオ概要

- 種別: `ai_avatar`
- 目的: AI avatar 動画生成の **plugin_interface 雛形**
  - 外部 API（heygen / hyperframes / 自前実装）を差し替え可能なプラグインとして扱う
  - 本雛形では実 API を叩かない（Phase 3+ の接続実装で埋める）
  - 本雛形の L3 は mock_runner.sh による **構造契約の機械検証**
- 出力:
  - 本雛形: `scenarios/ai-avatar/.tmp/mock_status.json`（契約 OK 痕跡）
  - 実装後: `scenarios/ai-avatar/out/output.mp4`（quality_gates で検証）

## plugin_interface 契約

```json
{
  "provider": "mock",
  "supported_providers": ["mock", "heygen", "hyperframes"],
  "required_env": ["AI_AVATAR_PROVIDER", "AI_AVATAR_API_KEY"],
  "optional_env": ["AI_AVATAR_MODEL", "AI_AVATAR_VOICE_ID", "HYPERFRAMES_BIN"],
  "mock_runner": "mock_runner.sh",
  "fallback_strategy": "mock_when_missing_credentials",
  "contract_version": "1.0.0"
}
```

- `provider`: 現在アクティブなプロバイダ。`supported_providers` に含まれる識別子のみ
- `required_env`: プロバイダ切替時に必ず設定すべき環境変数名。scenario.json に値自体を
  書かない（credentials は常に外部注入）
- `mock_runner`: credentials 不在時のフォールバック実行体。**構造契約のみ**検証し、
  実 API を呼ばない。L3-003 のエントリポイント
- `fallback_strategy`: `mock_when_missing_credentials` — 環境変数未設定時に
  mock_runner を呼ぶ戦略

## Implementer 向け制約（ロック決定の要約）

1. **Python / Node.js 直接生成は禁止**: `bash` + `jq` + `ffmpeg` のみ。hyperframes CLI は
   optional 依存扱いで、Node.js 22+ が未検出なら mock にフォールバック
2. **API key ハードコード禁止**: credentials は必ず環境変数経由。`scenario.json` や
   `mock_runner.sh` にリテラルで書いてはいけない
3. **実 API 呼出はスコープ外**: 本タスクは雛形構築まで。heygen / hyperframes 接続は
   Phase 3+ の別タスク
4. **HTTP サーバー不要**: `server.start_command = none` のレンダ専用シナリオ
5. **副作用は WORK_DIR 側に限定**: ハーネス本体（`.forge/`, `.claude/`）は触らない
6. **決定的契約検証**: mock_runner.sh は同じ `scenario.json` に対して同じ結果を返す
   （ネットワーク依存の randomness を混ぜない）

## 入力探索の優先順位（将来の render.sh が実装する）

1. `scenarios/ai-avatar/inputs/script.txt` — 原稿（必須）
2. `scenarios/ai-avatar/inputs/avatar.json` — 外観設定（任意）
3. `scenarios/ai-avatar/inputs/reference_voice.wav` — ボイスクローン用（任意）

## provider 切替フロー（設計書としての宣言）

1. `AI_AVATAR_PROVIDER` を参照し `supported_providers` のいずれかに合致するか確認
2. 該当プロバイダの `required_env` が全て set されているか検査
3. **全て満たす場合**: 実 API 呼出層（Phase 3+）へディスパッチ
4. **不足がある場合**: `fallback_strategy` に従い `mock_runner.sh` を呼び契約検証のみ
5. mock_runner は `.tmp/mock_status.json` に契約 OK 痕跡を残し exit 0

## 品質ゲート（`scenario.json` の `quality_gates`）

- `output_exists`: `out/output.mp4` が存在（blocking、Phase 3+ で実装）
- `duration_ge_minimum`: 動画尺が 3 秒以上（blocking、Phase 3+ で実装）
- `video_stream_present`: 映像ストリーム存在（blocking、Phase 3+ で実装）
- `plugin_contract_ok`: plugin_interface が provider + required_env[] + mock_runner を
  宣言していること（blocking、**本雛形で既に満たす**）

## 参考: Layer 3 受入テスト（research-criteria L3-003）

L3 では次の 2 コマンドで end-to-end の構造検証を行う（ハーネスが自動実行する）:

```bash
# 1. plugin_interface 宣言の構造検証
jq -e '.plugin_interface.provider and (.plugin_interface.required_env|type=="array") and .plugin_interface.mock_runner' \
  scenarios/ai-avatar/scenario.json

# 2. mock_runner 実行（credentials 無しでも exit 0）
bash scenarios/ai-avatar/$(jq -r '.plugin_interface.mock_runner' scenarios/ai-avatar/scenario.json)
```

どちらも exit 0 となることが合格条件。実 API への到達性は Phase 3+ の別 L3 で検証する。
