# scenario: slideshow — agent prompt patch

このファイルは `scenario.json` の `agent_prompt_patch` を人間・エージェント双方に
読みやすい形式で格納した正規ドキュメントです。Implementer / Investigator /
render.sh の設計者が参照します。`scenario.json` の `agent_prompt_patch` 文字列とは
**等価な要約**であり、文言が食い違った場合は `scenario.json` の方を正とすること。

## シナリオ概要

- 種別: `image_slideshow`
- 目的: 静止画ディレクトリから `ffmpeg concat demuxer` で MVP スライドショー mp4 を生成
- 出力: `scenarios/slideshow/out/output.mp4`
- 解像度: 1920x1080 (padding 前提、black-bar で aspect 維持)
- 再生時間: 20-40 秒 (画像 6 枚 × 5 秒 = 30 秒を既定)
- 映像: H.264 (libx264) + yuv420p
- 音声: BGM ファイル (`inputs/bgm.mp3`) が存在する場合のみ AAC 192kbps で合成、
  無い場合は無音トラックを追加しない (`-an`)

## Implementer 向け制約 (ロック決定の要約)

1. **Python / Node.js 不可**: bash + ffmpeg + ffprobe + imagemagick (convert) + jq のみで完結させる
2. **HTTP サーバー不要**: `server.start_command` は `none` を前提としたレンダ専用シナリオ
3. **Claude Code Bash SIGTERM バグ (Issue #45717) 対策**: 長時間エンコード時は
   `nohup` + progress file で分離することが望ましい (MVP 段階では 30 秒程度なので省略可)
4. **副作用は WORK_DIR 側に限定**: ハーネス本体 (`.forge/`, `.claude/`) は触らない
5. **決定的出力**: 同じ入力で同じ出力を得るため、random seed や timestamp 由来の
   filter は使用しない (固定 fps / 固定 crf)

## 入力探索の優先順位 (render.sh が実装する)

1. `scenarios/slideshow/inputs/images/*.{jpg,jpeg,png}` — 実運用時の本番入力
2. `scenarios/slideshow/assets/*.{jpg,jpeg,png}` — リポジトリ同梱のサンプル
3. 上記いずれも無い場合は `convert -size 1920x1080 xc:<color>` で 6 枚自動生成して `assets/` に配置

## 品質ゲート (`scenario.json` の `quality_gates`)

- `output_exists`: `out/output.mp4` が存在する (blocking)
- `duration_ge_minimum`: 動画長 >= 5 秒 (blocking、実運用では L3 で 20-40s を厳密検証)
- `video_stream_present`: v:0 コーデックが映像ストリームである (blocking)

Phase 3 統合検証では上記に加え、`quality-gate.json` (QualityGate オブジェクト) が
`required_mechanical_gates: ["ffprobe_exists","duration_check","size_threshold"]`
のいずれかを含むことをバリデータで確認すること。
