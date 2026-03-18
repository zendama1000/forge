# Forge Harness 実地テスト 2回目 — Findings

**日時**: 2026-02-22 16:15〜17:50
**テーマ**: x-auto-agent の UI 刷新
**ハーネスバージョン**: v3.2

## 検証ポイント結果

| # | 改善項目 | 結果 | 詳細 |
|---|---------|------|------|
| 1 | notify_human が common.sh から動作 | **OK** | info/critical 通知が正常生成。`n-20260222-170050.json` (info: 除外6件), `n-20260222-173040.json` (critical: 回帰テスト失敗) |
| 2 | fail_count 自動リセット | **OK (コード確認)** | `ralph-loop.sh:385` pending時リセット、`:1130` Investigator修正時リセット。impl-alpine-store が fail_count=1→completed で動作確認 |
| 3 | エラーリカバリ可視化 | **部分OK** | validation-stats.jsonl に recovery_level 記録あり (crlf/failed)。ただし DA が不正JSON で失敗したため fence/extraction 経路の通知は未確認 |
| 4 | L1 timeout ガイダンス | **OK** | task-stack の timeout_sec が 10/60/120 と適切に分散 |
| 5 | auto フェーズ遷移 | **未検証** | checkpoint モードで実行。auto モード時は検証していない |
| 6 | progress.json | **OK** | リアルタイム更新確認 (research/80% → development/41%)。dashboard.sh も正常表示 |
| 7 | スコープカバレッジ | **OK** | task-stack に `scope_coverage` フィールド存在。10要素全てが tasks にマッピング |
| 8 | 除外要素記録 | **OK** | `excluded_elements` 6件記録。notify_human で info 通知も生成 |
| 9 | DA スコープ検証 | **OK** | DA 出力に `theme_coverage` 存在 (10要素中8カバー、2未カバー) |
| 10 | Researcher 並列化 | **OK** | 6 perspective ファイルが並列生成 (technical, alternatives, cost, migration_path, risk, ux_architecture) |

## 発見された問題

### P1: DA が Windows 環境で不正 JSON を出力 (Critical)

**症状**: DA エージェントが `devils-advocate.json.pending` に出力したが、3層リカバリ後も不正JSONと判定。`validate_json` 失敗。

**原因分析**:
- DA ログに `rg error: nul: ファンクションが間違っています。(os error 1)` が多発
- Windows の `nul` デバイスファイルを rg (ripgrep) が検索しようとしてエラー
- rg エラー自体は直接の原因ではない可能性。DA エージェント (Sonnet) がテキスト混在の出力を生成した可能性が高い
- `.pending` ファイルは `_vj_cleanup()` で削除済みのため、生出力の検証不可

**影響**: forge-flow.sh が Phase 1 で停止 (exit 1)

**対策案**:
1. DA のリトライ機構追加（現状は `echo "ERROR"` → `break` で即停止）
2. `.pending` ファイルを削除前に `.failed` として保存（デバッグ用）
3. Windows 環境で `.rgignore` に `nul` を追加

### P2: DA エラー後のリカバリパスが不在 (High)

**症状**: DA がエラーの場合、research-loop.sh は `break` でループを抜け、forge-flow.sh は `exit 1` で停止。手動リカバリが必要。

**現状コード** (`research-loop.sh:910-914`):
```bash
"ERROR")
  log "✗ ERROR — Devil's Advocate実行に一時障害が発生"
  log "リサーチ結果は保存済み。手動で再実行してください。"
  update_state "error" "da-execution-error"
  break
```

**対策案**:
1. DA に1-2回のリトライを追加
2. リトライ上限到達後、synthesis.json が存在すれば criteria 生成をスキップ実行可能にする

### P3: criteria 生成時にポート番号がテンプレートデフォルト (Medium)

**症状**: exit_criteria の curl コマンドが `http://localhost:3000` を使用。実際の x-auto-agent は `port 3847`。

**原因**: criteria-generation.md テンプレートの例示が `localhost:3000` で、Synthesizer がこれをそのまま使用。リサーチデータにポート情報が含まれていなかった。

**影響**: run-regression.sh の mvp テストが失敗 → ralph-loop が checkpoint モードで停止

**対策案**:
1. criteria テンプレートにプレースホルダー `{{PORT}}` を追加
2. development.json の `server.health_check_url` からポートを推測
3. investigation-plan の段階でプロジェクトの基本情報（ポート等）を収集させる

### P4: forge-flow.sh に Phase 1 部分リカバリ機構がない (Medium)

**症状**: Phase 1 の SC → Researcher → Synthesizer が成功しても DA で失敗すると全てやり直し。

**現状**: `forge-flow.sh:172-175`:
```bash
if ! bash "${LOOPS_DIR}/research-loop.sh" "${RESEARCH_ARGS[@]}"; then
    log "✗ Phase 1 (Research) が異常終了"
    exit 1
fi
```

**対策案**:
1. `--resume` オプション追加 (既存の research_dir を指定して DA ステップから再開)
2. synthesis.json が存在する場合は DA → criteria 生成のみ再実行

### P5: checkpoint モードでの非対話実行時の挙動 (Low)

**症状**: `show_dev_phase_checkpoint` の `read -t 60` が非対話環境で即 timeout → choice="1" (続行) にフォールバック。しかし回帰テスト失敗で `return 1` となり、チェックポイントに到達前に停止。

**備考**: 意図通りの動作（回帰テスト失敗は停止すべき）だが、非対話実行時は `auto` モード相当の挙動も選択肢としてあるとよい。

## Phase 実行サマリ

| Phase | 結果 | 所要時間 | 備考 |
|-------|------|---------|------|
| Phase 0 | 完了 | 2分 | 壁打ち: スコープ/技術/優先度/制約を確認 |
| Phase 1 SC | 完了 | 1分 | investigation-plan.json 生成 |
| Phase 1 Researcher | 完了 | 3分 | 6 perspectives 並列生成 |
| Phase 1 Synthesizer | 完了 | 3分 | synthesis.json (17KB) |
| Phase 1 DA | **失敗** | 5分 | 不正JSON出力。手動リカバリで CONDITIONAL-GO |
| Phase 1 Criteria | 完了 (手動) | 2分 | implementation-criteria.json (L1×5, 3 phases) |
| Phase 1.5 | 完了 | 6分 | task-stack.json (12タスク, scope_coverage, excluded_elements) |
| Phase 2 MVP | **回帰テスト失敗** | 26分 | 5/5 MVP タスク完了。ポート不一致で回帰テスト失敗 |
| Phase 2 Core | 未実行 | - | MVP 回帰テスト失敗で停止 |
| Phase 2 Polish | 未実行 | - | 同上 |
| Phase 3 | 未実行 | - | 同上 |

## 前回テスト (Round 1) との比較

- **改善確認**: notify_human, fail_count リセット, progress.json, scope_coverage, excluded_elements, DA スコープ検証, Researcher 並列化 — 全て動作
- **残存問題**: DA の JSON 出力安定性 (Windows 環境固有の可能性)
- **新規問題**: criteria 生成のポートデフォルト値、DA リトライ機構不在
