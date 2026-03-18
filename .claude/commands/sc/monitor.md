Forge Harness Monitor が起動された。以下の手順でシステム状態を診断し、異常のみを報告せよ。

引数: $ARGUMENTS

## 手順

1. モニタースクリプトを実行する:
   ```bash
   bash .forge/loops/monitor.sh
   ```

2. 出力の JSON レポートを解析し、`status` フィールドで分岐する:

   - **`"ok"`**: 1行サマリーのみ出力する（例: 「正常稼動中 — Phase 2: 5/12 完了 (42%), 経過 23m」）。`changes` があればそれも1行で追記する
   - **`"anomalies"`**: 各異常を severity 順に箇条書きで報告する。推奨アクションも提示する
   - **`"completed"`**: 完了を報告する（例: 「全12タスク完了」）
   - **`"not_running"`**: 「Forge Harness 未稼動」と報告する

3. `$ARGUMENTS` に `--auto-recover` が含まれる場合:
   - レポートの `recoverable_actions[]` に記載された各アクションを確認する
   - 各アクションの `command` を bash で実行する
   - 実行結果を報告する（例: 「blocked_investigation の2タスクを pending にリセットしました」）
   - `--auto-recover` がなければ、`recoverable_actions` がある場合は「`--auto-recover` で自動復旧可能」と提示するのみ

4. 出力ルール:
   - 正常時は極力短く（1行）
   - 異常時のみ詳細を表示する
   - `/loop` で定期実行される前提のため、毎回フルダッシュボードを出さないこと
   - フルダッシュボードが必要なら `bash .forge/loops/dashboard.sh` を案内する
