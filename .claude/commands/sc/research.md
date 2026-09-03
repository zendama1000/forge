ユーザーが以下のリサーチテーマを調査したい:

$ARGUMENTS

以下の手順で Forge Research Harness を起動せよ:

1. テーマが空なら「リサーチテーマを入力してください」と聞く
2. `.forge/state/current-research.json` を読み、status が "running" なら既存リサーチ実行中と通知して停止
3. バックグラウンドで起動（`.forge/state/research-config.json` があれば `/sc:forge` と同形で渡す）:
   ```bash
   bash .forge/loops/research-loop.sh "テーマ" --research-config .forge/state/research-config.json 2>&1
   ```
4. ユーザーに伝える:
   - 開始したこと
   - 所要時間: 60-90分（実測: Phase 1 約 80 分 — 2026-08 salesletter4.5f）
   - 進捗確認: `.forge/state/current-research.json` の `current_stage`
   - 完了後: `.docs/research/` 配下の `final-report.md`
5. 進捗を定期的に確認し、完了したら結果を報告する
