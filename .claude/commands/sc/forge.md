ユーザーが以下のテーマで Forge Harness（エンドツーエンド: リサーチ → 開発）の実行を希望している:

$ARGUMENTS

## Phase 0: 壁打ち（必須）

ハーネス起動前に、以下の手順でユーザーと最重要事項を確認せよ:

1. テーマが空なら「テーマを入力してください」と聞く
2. テーマの内容を分析し、実装に入る前に確認すべき重要事項を特定する
3. AskUserQuestion で以下を確認する（テーマに応じて質問を自動生成）:
   - **必ず含める項目**: UIの有無（Webアプリ/CLI/API/ライブラリ等、成果物の形態）
   - **テーマに応じて含める項目の例**:
     - スコープ（何を含め、何を含めないか）
     - 技術スタック（言語・FW・インフラ）
     - 優先度（MVP の範囲）
     - 制約（時間・コスト・環境・互換性）
     - 既存コードベースとの関係
4. 回答を「方向性」としてまとめる

## Phase 0.5: 決定分類（壁打ち完了後、ハーネス起動前に実施）

壁打ちで得たユーザーの全回答を分析し、以下の手順で分類する:

1. **分類**: 各回答を以下のいずれかに分類する
   - **locked_decisions**: ユーザーが明確に決定した事項（技術選定、スコープ制限、必須要件など）
   - **open_questions**: まだ調査・比較が必要な未決事項
2. **確認**: AskUserQuestion で分類結果をユーザーに提示し、正しいか確認する
   - 「以下の分類で合っていますか？」形式で提示
   - ユーザーが修正した場合は反映する
3. **research-config.json 生成**: `.forge/state/research-config.json` に書き出す
   ```json
   {
     "mode": "validate または explore",
     "locked_decisions": [
       {"decision": "決定内容", "reason": "決定理由"}
     ],
     "open_questions": ["未決の問い1", "未決の問い2"],
     "generated_at": "ISO8601タイムスタンプ"
   }
   ```
4. **mode 判定ルール**:
   - locked_decisions が1件以上 → `"validate"`（固定事項を尊重しつつ未決事項を調査）
   - locked_decisions が0件 → `"explore"`（全てオープンに調査）

## Phase 1以降: ハーネス起動

壁打ち + 決定分類 完了後:

1. `.forge/state/current-research.json` を読み、status が "running" なら既存リサーチ実行中と通知して停止
2. 壁打ち結果を「方向性」引数として整形する
3. ハーネスを **--daemonize** フラグ付きで起動（600s タイムアウト回避）:
   ```bash
   bash .forge/loops/forge-flow.sh "テーマ" "壁打ちで合意した方向性" --research-config .forge/state/research-config.json --daemonize
   ```
   起動すると PID とログパスが出力される。
4. ユーザーに伝える:
   - デーモンとして開始したこと
   - 所要時間目安: Phase 1（15-25分）+ Phase 1.5（5-10分）+ Phase 2（テーマによる）
   - 進捗確認方法
5. 進捗監視（推奨: 自動監視を提案する）:
   - ユーザーに `/loop 5m /sc:monitor` の実行を提案する（異常時のみ報告する軽量モニター）
   - レートリミット自動復旧も必要なら `/loop 5m /sc:monitor --auto-recover` を提案する
   - 手動確認したい場合:
     - `bash .forge/loops/dashboard.sh` でフルダッシュボード表示
     - `cat .forge/state/progress.json` で現在のフェーズ/ステージ確認
     - `tail -20 .forge/state/forge-flow.log` で直近のログ確認
   - 完了判定: `jq -r '.status' .forge/state/current-research.json` が "completed" になれば Phase 1 完了
6. 完了したら結果を報告する
