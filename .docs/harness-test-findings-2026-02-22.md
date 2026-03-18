# Forge Harness 実地テスト結果 (2026-02-21〜22)

## テーマ
x-auto-agent の実運用レベル改善（UI刷新 + アーキテクチャ整理）

## テスト範囲
Phase 0（壁打ち）→ Phase 1（Research）→ Phase 1.5（Task Planning）→ Phase 2（Development）

## 最終結果: 全フェーズ完了

### Phase 0: 壁打ち — OK
- AskUserQuestion で4つの質問を提示、回答を方向性として整形

### Phase 1: Research — OK（88分）
- Scope Challenger → Researcher(6視点×2巡) → Synthesizer → Devil's Advocate
- 1巡目 CONDITIONAL-GO → 2巡目 GO（フィードバックループ正常動作）
- エラー1件（researcher-alternatives Claude実行エラー、自動リカバリ）

### Phase 1.5: Task Planning — OK
- 3フェーズ / 13タスク生成（mvp:5, core:6, polish:2）

### Phase 2: Development — OK（全13タスク完了）
- **MVP**: 5/5 完了（リトライ: accounts-extract×2）
- **Core**: 6/6 完了（リトライ: knowledge-logs-quality×1）
- **Polish**: 2/2 完了（リトライ: 0）
- 合計リトライ: 3回（全て Investigator 経由で自動復旧）
- テスト結果: 69ファイル / 927 passed / 0 failed

### 成果物の評価
- **アーキテクチャ整理**: 実施済み（モジュール分割、Store導入、auth-manager等）
- **UI刷新**: **未実施** — テーマに含まれていたが、タスクプランに視覚的UI変更が含まれなかった

## 発見した不備と修正

| ID | 種別 | 深刻度 | 内容 | ステータス |
|---|---|---|---|---|
| BUG-001 | CRLF | CRITICAL | detect_dev_phases の jq 出力に \r | 修正済み |
| BUG-002 | CRLF | CRITICAL | 全スクリプト169箇所の jq -r | 修正済み（jq_safe導入） |
| BUG-003 | source | HIGH | 3スクリプトが common.sh 未ソース | 修正済み |
| ISSUE-001 | 機能欠落 | HIGH | forge-flow.sh の --work-dir 未対応 | 修正済み |
| ISSUE-002 | 運用 | MEDIUM | failed→pending 時に fail_count リセット必要 | 記録のみ |
| ISSUE-003 | 設定 | MEDIUM | regression タスクの L1 timeout 不足（120s < vitest 175s） | 手動で200sに修正 |
| ISSUE-004 | スコープ欠落 | HIGH | テーマの一部（UI刷新）がタスクプランに反映されない | 記録のみ |

## ISSUE-004 詳細: テーマのスコープ欠落

- **事象**: テーマ「UI刷新 + アーキテクチャ整理」のうち「UI刷新」が開発タスクに含まれなかった
- **原因**: Phase 1 のリサーチ結論が「API migration first + Alpine.js modular split」となり、
  アーキテクチャ基盤整理を優先する方針が採用された。その結果、Phase 1.5 のタスクプランが
  アーキテクチャ関連タスクのみで構成され、UIの視覚的変更（HTML/CSS/レイアウト）が欠落した
- **影響**: 開発完了後もUIの見た目は変更前と同一。ユーザーの期待と成果物に乖離
- **根本原因の分析**:
  1. リサーチが「まずアーキテクチャを整理すべき」と正しく判断したが、UI刷新を明示的に「次フェーズ」として記録しなかった
  2. タスクプランナーがテーマの全要素をカバーしているか検証するメカニズムがない
  3. Devil's Advocate がスコープカバレッジ（テーマの全要素が計画に含まれるか）をチェックしていない
- **推奨修正**:
  - タスクプランナーに「テーマの全要素がタスクでカバーされているか」の検証ステップを追加
  - 意図的に除外した要素は明示的に記録し、ユーザーに通知する仕組み
  - Devil's Advocate のチェック項目に「テーマスコープカバレッジ」を追加

## 設定変更

- `development.json`: implementer timeout 600→900秒, L1 default 60→200秒
- `task-stack.json`: mvp-regression, core-regression の L1 timeout 120→200秒

## 今後の改善項目（推奨）

### ハーネス品質
1. Phase 1 の所要時間短縮（88分は長い、並列化の余地あり）
2. バックグラウンド実行時の進捗確認手段の改善
3. エラーリカバリの可視化（自動リカバリするが通知がない）
4. fail_count 自動リセットの仕組み（status=failed→pending 時に連動）
5. task-planner が L1 timeout をテスト実行時間に合わせて設定する仕組み
6. phase-control=auto 時のフェーズ遷移改善（core完了後に一旦停止する問題）

### スコープ管理
7. **テーマスコープカバレッジ検証** — テーマの全要素がタスクプランに含まれるかチェック（ISSUE-004対応）
8. 除外要素の明示的記録と通知
9. Devil's Advocate にスコープカバレッジチェックを追加
