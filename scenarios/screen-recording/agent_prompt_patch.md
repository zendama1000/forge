# scenario: screen-recording — agent prompt patch

このファイルは `scenario.json` の `agent_prompt_patch` を人間・エージェント双方に
読みやすい形式で格納した正規ドキュメントです。Implementer / Investigator /
`render.sh` の設計者が参照します。`scenario.json` の `agent_prompt_patch` 文字列とは
**等価な要約**であり、文言が食い違った場合は `scenario.json` の方を正とすること。

## シナリオ概要

- 種別: `screen_record`
- 目的: 既存 mp4 入力 → 音声抽出 → whisper.cpp ないし ffmpeg 8.0+ Whisper フィルタで書起こし
  → srt 字幕生成 → ffmpeg `subtitles` フィルタで焼込 → 任意トリムを行う
- 出力:
  - `scenarios/screen-recording/out/subtitles.srt`（書起こし字幕、サイズ >100 B）
  - `scenarios/screen-recording/out/output.mp4`（字幕焼込後、H.264 + AAC）
- 解像度: 入力に依存（既定は 1280x720）
- 音声: AAC 128 kbps、入力音声を保持

## Implementer 向け制約（ロック決定の要約）

1. **Python / Node.js 不可**: `bash` + `ffmpeg` + `ffprobe` + `.forge/lib/transcribe.sh` + `jq` のみで完結させる
2. **HTTP サーバー不要**: `server.start_command = none` のレンダ専用シナリオ
3. **書起こしは `.forge/lib/transcribe.sh` を呼ぶ**: whisper.cpp / ffmpeg_whisper のバックエンド選択は
   transcribe.sh の検出ロジックに委譲する。レンダ側でバックエンドを直接叩かない
4. **副作用は WORK_DIR 側に限定**: ハーネス本体（`.forge/`, `.claude/`）は触らない
5. **決定的出力**: 同じ入力で同じ出力を得るため、random seed や timestamp 由来の
   フィルタは使用しない（固定 fps / 固定 crf）
6. **字幕焼込は `subtitles` フィルタ**: `drawtext` での直接描画は禁止。`force_style` で
   `FontSize`, `Outline`, `Shadow` を指定して視認性を担保
7. **モデル未配置でも落ちない**: whisper モデルが存在しない環境では transcribe.sh が stub SRT を
   返すので、render 側はそれをそのまま焼き込めるようにすること（stub でも 100 B 以上になるよう
   render 側で最低限のパディングを付与する）

## 入力探索の優先順位（render.sh が実装する）

1. `scenarios/screen-recording/inputs/input.mp4` — 実運用時の本番入力
2. `scenarios/screen-recording/assets/sample.mp4` — リポジトリ同梱のサンプル
3. 上記いずれも無い場合は `ffmpeg -f lavfi -i color=... -f lavfi -i sine=...` で
   10 秒・1280x720 のサンプル mp4 を `assets/sample.mp4` に自動生成

## 字幕源の優先順位（render.sh が実装する）

1. `scenarios/screen-recording/inputs/subtitles.srt` — 人手で用意した字幕があれば再利用
2. 無ければ入力動画から `ffmpeg -vn -ac 1 -ar 16000 -c:a pcm_s16le` で
   `.tmp/audio.wav` を抽出 → `.forge/lib/transcribe.sh` で `out/subtitles.srt` を生成

## 任意トリム

- 環境変数 `TRIM_START` / `TRIM_DURATION` が指定された場合のみトリムを適用
- `ffmpeg -ss "$TRIM_START" -i <input> -t "$TRIM_DURATION" ...` の順序で `-ss` は `-i` の前
- 指定が無い場合はトリムせずに入力全体を字幕焼込する

## 品質ゲート（`scenario.json` の `quality_gates`）

- `output_exists`: `out/output.mp4` が存在（blocking）
- `srt_nonempty`: `out/subtitles.srt` のサイズが 100 B 超（blocking）
- `video_and_audio_streams_present`: 出力 mp4 が映像 + 音声の 2 ストリーム以上を含む（blocking）
- `duration_ge_minimum`: 出力動画が 3 秒以上（blocking）

Phase 3 統合検証では上記に加え、`quality-gate.json`（QualityGate オブジェクト）が
`required_mechanical_gates: ["ffprobe_exists","duration_check","size_threshold"]`
のいずれかを含むことをバリデータで確認する。

## 参考: Layer 3 受入テスト

L3 では次の 1 コマンドで end-to-end を検証する（ハーネスが自動実行する）:

```bash
bash .forge/loops/render-loop.sh scenarios/screen-recording
# verify
test -s scenarios/screen-recording/out/subtitles.srt \
  && [ $(wc -c < scenarios/screen-recording/out/subtitles.srt | tr -d ' ') -gt 100 ] \
  && ffprobe -v error scenarios/screen-recording/out/output.mp4 -show_streams -of json \
       | jq -e '.streams | length >= 2'
```
