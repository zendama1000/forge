# Forge Harness v3.2 実地テスト報告書

**テーマ**: 宗教生成AIウェブサービス（架空宗教の世界観一括生成）
**実施日**: 2026-02-15
**テスト範囲**: Phase 0 → Phase 1 → Phase 1.5 → Phase 2 → SDK連携
**最終結果**: Phase 2 完了（56/56タスク）、Claude Agents SDK連携実装済み

---

## 発見された不備一覧

| # | 重大度 | フェーズ | 分類 | 概要 |
|---|--------|----------|------|------|
| 1 | HIGH | 1.5 | 出力形式 | Task Planner が JSON ではなく Markdown を出力 |
| 2 | HIGH | 1.5 | リカバリ | validate_json 3層回復が Task Planner 出力に対して機能しない |
| 3 | MEDIUM | 2 | 引数設計 | ralph-loop.sh の引数順序が直感的でない |
| 4 | HIGH | 2 | 状態管理 | 中断後の in_progress タスクが再実行をブロック |
| 5 | HIGH | 2 | 環境依存 | bash -c 実行で node_modules/.bin が PATH に含まれない |
| 6 | MEDIUM | 2 | テスト生成 | Jest 構文で生成されたテストが Vitest 環境で失敗 |
| 7 | LOW | 2 | テスト生成 | 実装ファイル未作成のままテスト実行を試行 |
| 8 | MEDIUM | 2 | 環境依存 | eslint も同様に command not found |
| 9 | LOW | 2 | 依存管理 | workspace 依存が package.json に未宣言 |

---

## 詳細

### #1 [HIGH] Phase 1.5: Task Planner が Markdown を出力

**場所**: `generate-tasks.sh` → Claude 呼び出し
**症状**: `implementation-criteria.json` を入力として Task Planner に渡すと、期待される JSON 形式ではなく Markdown 形式（```json ブロックを含むテキスト）が返される。4回連続で再現。
**影響**: Phase 1.5 が完全にスタックし、手動で task-stack.json を生成する必要があった。
**根本原因**: Task Planner プロンプトの出力形式指定が弱い。Claude が自然言語で「説明」してから JSON を出力するパターンに陥る。
**推奨修正**:
- プロンプトに `outputFormat` 相当の強制指定を追加
- Claude Agents SDK の `outputFormat: { type: "json_schema" }` を使用してプログラム的に JSON 出力を強制
- フォールバックとして、Markdown 内の ```json ブロックを抽出するパーサーを強化

### #2 [HIGH] Phase 1.5: validate_json リカバリ不足

**場所**: `.forge/lib/common.sh` → `validate_json()`
**症状**: 3層リカバリ（CRLF除去 → コードフェンス除去 → ブレース抽出）が、Task Planner の複雑な出力パターン（説明文 + JSON + 説明文）に対して機能しない。
**影響**: #1 と合わせて Phase 1.5 が完全失敗。
**推奨修正**:
- 最後の `{...}` ブロックを正規表現で抽出する4層目を追加
- JSON 部分が複数行にまたがるケースへの対応強化

### #3 [MEDIUM] Phase 2: ralph-loop.sh 引数順序の混乱

**場所**: `ralph-loop.sh` 引数パース
**症状**: `ralph-loop.sh <task-stack> [criteria] [working-dir]` の順序だが、呼び出し時に working-dir を2番目に渡してしまい、criteria として解釈された。
**影響**: 実行開始に失敗。手動で引数修正が必要だった。
**推奨修正**:
- 名前付き引数（`--work-dir=...`）の採用
- 引数バリデーション強化（JSON ファイルかディレクトリかの型チェック）

### #4 [HIGH] Phase 2: in_progress タスクが再実行をブロック

**場所**: `ralph-loop.sh` → タスク選択ロジック
**症状**: 前回の実行が中断（Ctrl+C）した際、`init-monorepo` タスクが `in_progress` のまま残り、次回実行時にそのタスクを再取得しようとして無限ループ（既に完了しているが status が更新されていない）。
**影響**: 手動で `jq` を使って全タスクを `pending` にリセットする必要があった。
**備考**: `_cleanup_on_exit` トラップが存在するが、`EXIT` シグナルでのみ動作し、`SIGINT` での中断時に `in_progress → interrupted` 変換が不完全だった可能性。
**推奨修正**:
- 起動時に `in_progress` タスクを自動検出し、`pending` にリセットするウォームアップ処理を追加
- `trap _cleanup_on_exit EXIT INT TERM` でシグナルカバレッジを拡大

### #5 [HIGH] Phase 2: bash -c で node_modules/.bin が PATH にない

**場所**: `ralph-loop.sh` → `execute_layer1_test()`
**症状**: テスト検証コマンド `bash -c "cd '$WORK_DIR' && vitest run ..."` を実行すると `vitest: command not found`。新しいシェルセッションでは `node_modules/.bin` が PATH に含まれない。
**影響**: 6つのテストタスクが全て `blocked_criteria`（最大3リトライ）で失敗。手動で全テストコマンドに `npx` プレフィックスを付与して修正。
**推奨修正**:
- `execute_layer1_test()` 内で `export PATH="$WORK_DIR/node_modules/.bin:$PATH"` を明示的に設定
- または全コマンドに `npx` を自動付与するラッパー

### #6 [MEDIUM] Phase 2: Jest 構文のテスト生成

**場所**: Implementer エージェントによるテスト生成
**症状**: プロジェクトが Vitest を使用しているにもかかわらず、一部のテストファイルが Jest 構文（`jest.fn()`, `jest.spyOn()` 等）で生成された。
**影響**: 3つのテストファイルを手動で Vitest 構文（`vi.fn()`, `vi.spyOn()`）に移行。
**推奨修正**:
- Implementer プロンプトに「プロジェクトのテストフレームワークを確認してから生成せよ」の指示を追加
- `package.json` の devDependencies をコンテキストとして渡す

### #7 [LOW] Phase 2: 実装なしでテスト実行

**場所**: タスクスタック依存順序
**症状**: テスト実行タスクが、対応する実装ファイル作成タスクより先に実行された（dependency-graph.ts, disclaimer.ts が未作成）。
**影響**: テスト失敗 → 手動で実装ファイルを作成。
**推奨修正**:
- task-stack.json に `depends_on` フィールドの厳密な依存グラフを定義
- ralph-loop.sh のタスク選択ロジックで依存解決を実装

### #8 [MEDIUM] Phase 2: eslint command not found

**場所**: `ralph-loop.sh` → lint/format 検証タスク
**症状**: #5 と同じ根本原因。`eslint` コマンドが bash -c 内で見つからない。
**影響**: lint/format タスクが `blocked_criteria` で失敗。`npx eslint` に修正して解決。
**推奨修正**: #5 と同一

### #9 [LOW] Phase 2: workspace 依存の未宣言

**場所**: `apps/api/package.json`
**症状**: `@religion-worldbuilder/shared` への workspace 依存が宣言されていなかったため、pnpm が node_modules にシンボリックリンクを作成せず、vitest のモジュール解決が失敗。
**影響**: orchestrator テストが `ERR_MODULE_NOT_FOUND` で失敗。vitest config に `resolve.alias` を追加し、package.json に `workspace:*` 依存を宣言して解決。
**推奨修正**:
- Implementer エージェントがモノレポ構造を認識し、cross-package import 時に workspace 依存を自動宣言する仕組み

---

## 統計サマリー

| 指標 | 値 |
|------|-----|
| Phase 1 所要時間 | 約70分（6視点 + 3条件ループ） |
| Phase 1.5 試行回数 | 4回失敗 → 手動生成 |
| Phase 2 タスク総数 | 56 |
| Phase 2 実行ラウンド | 4回 |
| 第1ラウンド完了数 | 18/56 |
| 第2ラウンド完了数 | 48/56（手動テスト修正後） |
| 第3ラウンド完了数 | 52/56 |
| 第4ラウンド完了数 | 56/56 |
| 手動介入回数 | 7回 |
| 最終テスト数 | 302 passing（API全体） |

---

## 重大度別の推奨対応優先度

### 即時対応（HIGH x 3）
1. **#5 PATH問題**: `execute_layer1_test()` に PATH 設定を追加（1行修正）
2. **#4 in_progress ブロック**: 起動時リセット処理を追加（10行程度）
3. **#1+#2 Task Planner JSON 出力**: outputFormat 強制 or プロンプト改善

### 次リリース（MEDIUM x 3）
4. **#3 引数順序**: 名前付き引数の導入
5. **#6 Jest/Vitest 混在**: Implementer プロンプト改善
6. **#8 eslint PATH**: #5 と同一修正で解決

### バックログ（LOW x 2）
7. **#7 依存順序**: タスク依存グラフの厳密化
8. **#9 workspace 依存**: モノレポ認識の改善
