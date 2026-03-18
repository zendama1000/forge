# Forge Phase 1.5 再設計：dev-phase分割方式 設計書

**作成日:** 2026-02-16
**更新日:** 2026-02-16（修正指示書 全7件適用済み）
**前提文書:** forge-template-quality-discussion-summary.md

---

## 1. 設計の背景と目的

### 解決する問題
- テスト基準（Layer 1）が曖昧で、「テストは通るが品質が低い」実装が生まれる
- 中間出力（criteria → task-stack）の確認ポイントが不十分で、人間が介入できない
- MVPが成立する前に詳細機能の実装が走り、統合問題が後半で噴出する

### 設計方針
- dev-phase分割によるMVP優先構成
- auto / human_check の2層exit_criteriaによる品質担保
- 人間介入モードの切り替え可能な設計

### 用語定義

- **パイプライン段階（Phase）**: Forgeの処理段階を指す既存用語。
  Phase 1=Research, Phase 1.5=Task Planning, Phase 2=Development（ralph-loop）, Phase 3=統合検証（Layer 2テスト一括実行）。
  これらは変更しない。
- **開発フェーズ（dev-phase）**: Phase 2（Development）内部でのタスク実行順序を制御する概念。
  本設計で新規導入する。mvp → core → polish の3段階。
  Phase 2の中でdev-phaseが順次実行され、各dev-phase完了時にチェックポイントが入る。

### パイプライン全体フロー

```
Phase 1: Research
  └→ research-loop.sh

Phase 1.5: Task Planning
  └→ generate-tasks.sh
    └→ 後処理: phase-tests/*.sh 生成

Phase 2: Development（ralph-loop.sh）
  ├→ dev-phase: mvp
  │    ├→ タスク実行（各タスクのLayer 1テスト）
  │    ├→ exit_criteria autoテスト（run-regression.sh mvp）
  │    ├→ checklist具体化（checklist-concretize-prompt.md）
  │    └→ チェックポイント（--phase-control依存）
  ├→ dev-phase: core
  │    ├→ タスク実行（各タスクのLayer 1テスト）
  │    ├→ exit_criteria autoテスト（run-regression.sh core）← mvp回帰含む
  │    ├→ checklist具体化
  │    └→ チェックポイント
  └→ dev-phase: polish
       ├→ タスク実行（各タスクのLayer 1テスト）
       ├→ exit_criteria autoテスト（run-regression.sh polish）← mvp+core回帰含む
       ├→ checklist具体化
       └→ チェックポイント

Phase 3: 統合検証（既存 run_phase3）
  └→ Layer 2テスト一括実行
    └→ 失敗時: fix task生成 → Phase 2に戻る（既存ロジック）
```

重要: dev-phaseのexit_criteria autoテストとPhase 3のLayer 2テストは別物。
- exit_criteria auto: dev-phaseレベルの統合確認（サーバー起動状態でcurlベース）
- Phase 3 Layer 2: タスクレベルのlayer_2定義に基づく統合テスト（既存ロジック）

---

## 2. フェーズ制御モード

### 3つのモード

```bash
forge-flow.sh --phase-control=auto        # 全dev-phase自動
forge-flow.sh --phase-control=checkpoint   # dev-phase間で必ず止まる
forge-flow.sh --phase-control=mvp-gate     # mvp完了時だけ止まる（デフォルト）
```

| モード | mvp後 | core完了後 | polish完了後 | 用途 |
|---|---|---|---|---|
| auto | 自動 | 自動 | 自動 | 夜間実行、信頼度が高い場合 |
| checkpoint | 停止 | 停止 | 停止 | 慎重に進めたい場合 |
| mvp-gate | 停止 | 自動 | 自動 | 通常運用（デフォルト） |

### チェックポイントでの人間アクション

```
[1] 続行（次dev-phaseへ自動進行）
[2] 確認してから続行（ブラウザで動作を目視確認 → y/nで続行）
[3] 次dev-phaseのタスク内容・テスト基準を表示して確認
[4] 中断（サーバー起動したまま終了、手動で触れる状態）
```

### 設計原則
- レビューの要否はForge自体の成熟度に依存する
- 「レビューを入れられる構造」にしておき、運用で外す
- [1]を選ぶだけで事実上の自動と同じ

---

## 3. dev-phase構成

### 3段階dev-phase

```
dev-phase: mvp      — 最小限動くもの（E2Eで1フローが動く状態）
dev-phase: core     — 機能を一通り揃える
dev-phase: polish   — エッジケース対応、UI調整
```

### MVP定義の決定方法
- criteria-generationが自動提案する
- checkpointモード: チェックポイントで人間が確認・修正可能
- autoモード: 自動提案をそのまま採用

---

## 4. exit_criteria 設計

### 2層構造

各dev-phaseのexit_criteriaは **auto**（機械判定）と **human_check**（人間確認）の2層。

```json
{
  "phase": "mvp",
  "goal": "最小限のAPIとフロントが連携して動く",
  "exit_criteria": [
    {
      "type": "auto",
      "description": "APIがレスポンスを返す",
      "command": "curl -sf http://localhost:3000/api/items",
      "expect": "HTTP 200 + JSON配列"
    },
    {
      "type": "auto",
      "description": "フロントエンドがビルドできる",
      "command": "npm run build",
      "expect": "exit code 0"
    },
    {
      "type": "human_check",
      "description": "CRUD操作がブラウザ上で完結することを確認",
      "level": "A"
    }
  ]
}
```

### テスト実行レイヤーの分離

exit_criteriaのautoテストと、タスク個別のLayer 1テストは別物である。

| 区分 | 管理者 | サーバー | 禁止事項 | 例 |
|---|---|---|---|---|
| タスクLevel Layer 1テスト | ralph-loop | サーバー不要（起動不要なテストのみ） | バックグラウンドプロセス禁止 | `test -f`, `npm run build`, `npx vitest run` |
| dev-phaseレベル exit_criteria (auto) | run-regression.sh | ランナーが事前起動 | なし（curlも可） | `curl -sf localhost:3000/api/items` |

task-planning-prompt.md の「バックグラウンドプロセス禁止」ルールはタスクレベルLayer 1テストにのみ適用される。
exit_criteriaのautoテストはrun-regression.shがサーバーを起動した状態で実行するため、curlベースのE2Eテストが書ける。

### human_checkの2段階具体化

```
Stage 1 (criteria-generation時点):
  レベルA — 機能ベースの確認項目
  例: "TodoのCRUD操作がブラウザ上で完結することを確認"

Stage 2 (dev-phase完了後、実装済みコードを読んで具体化):
  レベルB — 操作手順ベースのchecklist
  例:
    1. http://localhost:3000 を開く
    2. 入力欄に「テスト」と入力して「追加」を押す
    3. リストに「テスト」が表示される
    4. リロードして「テスト」が残っている
```

- Stage 1: criteria-generation.md が生成
- Stage 2: **新規テンプレート checklist-concretize-prompt.md** + **新規エージェント checklist-verifier.md** が生成
- Stage 2の実行タイミング: **dev-phase完了時**。mvp完了時は特に詳細に生成

### implementation-criteria.json のスキーマ拡張

既存の layer_1/2/3_criteria はタスクレベルの成功条件定義として維持する。
phases 配列はdev-phaseレベルの統合確認として新規追加する。

```json
{
  "research_id": "...",
  "theme": "...",
  "generated_at": "...",

  "layer_1_criteria": [ ... ],
  "layer_2_criteria": [ ... ],
  "layer_3_criteria": [ ... ],
  "assumptions": [ ... ],

  "phases": [
    {
      "id": "mvp",
      "goal": "最小限のE2Eフローが1つ動く状態",
      "scope_description": "どの機能がMVPに含まれるかの説明",
      "criteria_refs": ["L1-001", "L1-002"],
      "exit_criteria": [
        {
          "type": "auto",
          "description": "APIが1つ以上動作しレスポンスを返す",
          "command": "curl -sf http://localhost:3000/api/items | jq '.items | length > 0'",
          "expect": "exit code 0"
        },
        {
          "type": "human_check",
          "description": "ブラウザからAPIが呼べてデータが表示されることを確認",
          "level": "A"
        }
      ]
    },
    {
      "id": "core",
      "goal": "主要機能が一通り動作する",
      "scope_description": "...",
      "criteria_refs": ["L1-003", "L1-004", "L1-005"],
      "exit_criteria": [ ... ]
    },
    {
      "id": "polish",
      "goal": "エッジケースで壊れず見た目が整っている",
      "scope_description": "...",
      "criteria_refs": ["L1-006", "L1-007"],
      "exit_criteria": [ ... ]
    }
  ]
}
```

**criteria_refs**: phasesの各dev-phaseが既存のlayer_X_criteriaのどのIDに対応するかを紐付ける。
task-planningはこの紐付けを使い、各タスクにdev_phase_idを割り当てる。

---

## 5. 回帰テスト設計

### テストスクリプトの保存構造

```
.forge/state/phase-tests/
  mvp.sh              ← mvp dev-phaseのautoテスト群
  core.sh             ← core dev-phaseのautoテスト群
  polish.sh           ← polish dev-phaseのautoテスト群
  run-regression.sh   ← 指定dev-phaseまでの累積実行
```

### 生成タイミング

1. criteria-generation.md がphases配列（exit_criteriaのautoテスト含む）を生成 → implementation-criteria.json
2. task-planning はphase情報をそのまま task-stack.json に引き継ぐ
3. generate-tasks.sh の後処理で、task-stack.json内のphases[].exit_criteria[type=auto] から
   フェーズ別テストスクリプトを機械的に生成する

LLMにシェルスクリプトを直接書かせない。JSONの構造化データから決定論的に変換する。

### generate-tasks.sh 後処理: テストスクリプト生成

generate-tasks.sh の末尾に、task-stack.json の phases 配列から
.forge/state/phase-tests/{phase_id}.sh を生成するステップを追加する。

```bash
generate_phase_test_scripts() {
  local task_stack="$1"
  local output_dir=".forge/state/phase-tests"
  mkdir -p "$output_dir"

  local phases
  phases=$(jq -r '.phases[]?.id // empty' "$task_stack" 2>/dev/null)

  for phase_id in $phases; do
    local script="${output_dir}/${phase_id}.sh"
    echo "#!/bin/bash" > "$script"
    echo "# Auto-generated exit_criteria tests for dev-phase: ${phase_id}" >> "$script"
    echo "set -e" >> "$script"
    echo "" >> "$script"

    jq -r --arg pid "$phase_id" '
      .phases[] | select(.id == $pid) |
      .exit_criteria[]? | select(.type == "auto") |
      "echo \"  Testing: \(.description)\" && \(.command) && echo \"  ✓ PASS\" || { echo \"  ✗ FAIL: \(.description)\"; exit 1; }"
    ' "$task_stack" >> "$script"

    chmod +x "$script"
  done
}
```

### run-regression.sh の動作

```bash
#!/bin/bash
# run-regression.sh — dev-phaseレベルのexit_criteriaテスト実行
# サーバーライフサイクルを管理し、各dev-phaseのautoテストを累積実行する

phases=("mvp" "core" "polish")
target="${1:-mvp}"
SERVER_PID=""

cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; }
trap cleanup EXIT

start_server() {
  local start_cmd
  start_cmd=$(jq -r '.server.start_command // "npm start"' .forge/config/development.json)
  local health_url
  health_url=$(jq -r '.server.health_check_url // "http://localhost:3000"' .forge/config/development.json)
  local max_wait=30

  eval "$start_cmd &"
  SERVER_PID=$!

  for i in $(seq 1 $max_wait); do
    if curl -sf "$health_url" > /dev/null 2>&1; then
      echo "Server ready (${i}s)"
      return 0
    fi
    sleep 1
  done
  echo "Server failed to start within ${max_wait}s"
  return 1
}

start_server || exit 1

for phase in "${phases[@]}"; do
  test_file=".forge/state/phase-tests/${phase}.sh"
  [ -f "$test_file" ] || continue
  echo "=== Running $phase exit_criteria tests ==="
  bash "$test_file"
  if [ $? -ne 0 ]; then
    echo "FAIL: $phase exit_criteria test failed"
    exit 1
  fi
  [ "$phase" = "$target" ] && break
done
echo "All exit_criteria tests passed"
```

### 回帰テストの累積ルール

```
mvp完了時:    mvp.sh のみ実行
core完了時:   mvp.sh → core.sh を順次実行
polish完了時: mvp.sh → core.sh → polish.sh を順次実行
```

---

## 6. サーバーライフサイクル管理

### 方式C: ハイブリッド

| レイヤー | 方式 | サーバー管理者 |
|---|---|---|
| タスクレベル Layer 1（ralph-loop内） | サーバー不要 | テスト自体がサーバーを必要としない設計 |
| dev-phaseレベル（ralph-loop内） | 方式B: ランナー管理 | run-regression.sh |
| 人間チェックポイント | 起動したまま停止 | ralph-loop.sh |

### dev-phase完了時のフロー

```
1. run-regression.sh がサーバーを起動
2. 前dev-phaseまでの回帰テスト実行
3. 当dev-phaseのautoテスト実行
4. checklist具体化テンプレート実行（サーバー起動中だが不要）
5. サーバー起動したままチェックポイントに入る
6. チェックポイント表示:
   ═══════════════════════════════════════════
     [dev-phase名] dev-phase 完了
   ═══════════════════════════════════════════
     実行タスク: N/M
     成功: X  失敗: Y  スキップ: Z

     dev-phase目標: "..."

     完了したこと:
       ✓ task-001: ...
       ✓ task-002: ...

     auto テスト結果:
       ✓ curl ... → 200
       ✓ npm run build → 成功

     回帰テスト結果:
       ✓ mvp: 全テスト通過

     human_check (操作手順):
       □ http://localhost:3000 を開く
       □ 入力欄に「テスト」と入力して「追加」を押す
       □ リストに「テスト」が表示される
       □ リロードして「テスト」が残っている

     残りdev-phase:
       core (主要機能): Nタスク - ...
       polish (仕上げ): Nタスク - ...
   ═══════════════════════════════════════════
     [1] 続行  [2] 目視確認→続行  [3] 次dev-phase内容表示  [4] 中断

7. 人間が選択
   [1] or [2] → サーバー停止 → 次dev-phaseへ
   [3] → 次dev-phaseのタスク・テスト基準を表示 → 再度選択
   [4] → サーバー起動したまま終了（人間が手動で触れる状態）
```

### forge-flow.sh チェックポイント拡張

Phase 1.5（generate-tasks.sh）完了後のチェックポイント表示を以下に拡張する：

```
╔══════════════════════════════════════════════════╗
║       Phase 2 開始前チェックポイント              ║
╚══════════════════════════════════════════════════╝
  タスクスタック: .forge/state/task-stack.json

  dev-phase構成:
    mvp (3タスク):   「最小限のAPIとフロントが連携して動く」
      exit_criteria: curl API → 200, npm build → success
      human_check:   CRUD操作がブラウザ上で完結すること
    core (3タスク):  「機能を一通り揃える」
      exit_criteria: PUT/DELETE API → success, バリデーション → 400
      human_check:   完了/削除/エラー表示の動作確認
    polish (2タスク): 「エッジケースで壊れず見た目が整う」
      exit_criteria: 404レスポンス, 回帰テスト全通過
      human_check:   エラー画面、大量データ、モバイル幅の確認

  フェーズ別テストスクリプト:
    ✓ .forge/state/phase-tests/mvp.sh (3 tests)
    ✓ .forge/state/phase-tests/core.sh (4 tests)
    ✓ .forge/state/phase-tests/polish.sh (2 tests)

  制御モード: mvp-gate（mvp完了後に停止）

  30秒以内に Enter で続行 / 'q' で中断
```

---

## 7. 改修対象の全体像

### 新規作成

| ファイル | 種別 | 内容 |
|---|---|---|
| checklist-verifier.md | エージェント定義 | 実装済みコードを読み、dev-phaseのhuman_checkをレベルBの操作手順checklistに具体化する役割 |
| checklist-concretize-prompt.md | テンプレート | 実装済みコードを読んでhuman_checkをレベルBに具体化 |
| run-regression.sh | シェルスクリプト | dev-phase回帰テストの累積実行（サーバーライフサイクル管理付き） |
| .forge/state/phase-tests/ | ディレクトリ | dev-phase別テストスクリプト格納 |

### 改修

| ファイル | 改修内容 |
|---|---|
| criteria-generation.md | phases定義 + 各dev-phaseのexit_criteria（auto + human_check レベルA）の生成指示追加 |
| task-planning-prompt.md | dev-phase分割でのタスク構成指示、MVP優先順序、dev_phase_id割り当て |
| generate-tasks.sh | 後処理追加: task-stack.json からdev-phase別テストスクリプトを機械的に生成。dev_phase_id存在チェック（警告のみ） |
| implementation-criteria.json (schema) | phases配列の追加 |
| task-stack.json (schema) | dev_phase_id フィールド追加（各タスクがどのdev-phaseに属するか）+ phases配列の引き継ぎ |
| forge-flow.sh | --phase-control引数パース追加、Phase 1.5完了後チェックポイント拡張（dev-phase構成表示）、ralph-loop.shへの--phase-control引数引き渡し |
| ralph-loop.sh | dev-phase単位の実行制御（dev_phase_idによるフィルタリング）。既存のrun_phase3()（Layer 2統合テスト）は変更せず、全dev-phase完了後に既存Phase 3として実行する |
| circuit-breaker.json | flow_limits に phase_control_default 追加 |
| development.json | checklist_verifier セクション追加、server セクション追加 |

### 変更なし

| ファイル | 理由 |
|---|---|
| researcher-prompt.md | Phase 1.5の改修スコープ外（領域Bで別途対応） |
| devils-advocate-prompt.md | Phase 1.5の改修スコープ外（領域Cで別途対応） |
| implementer-prompt.md | タスクレベルの動作は変更なし |
| investigator-prompt.md | 役割変更なし |
| 既存agentファイル (.claude/agents/) | 既存のWHO定義は変更不要。checklist-verifier.md のみ新規追加 |

---

## 8. 未決定事項

### 解決済み

1. ~~checklist-concretize-prompt.md の具体的な内容~~: **（解決）** 新規エージェント checklist-verifier.md を作成
2. ~~implementation-criteria.json のphases配列の詳細スキーマ~~: **（解決）** phases配列のスキーマ定義確定（セクション4に記載）

### 更新済み

3. **task-stack.json の dev_phase_id 割り当てロジック**: criteria_refs を使い、タスクの依存する layer_X_criteria がどのdev-phaseに属するかで自動判定する。task-planning-prompt.md にこのロジックの指示を追加済み。
4. **autoモード時のhuman_checkの扱い**: ログに記録するが停止しない。checklist具体化ステップは実行する（ログ用）が、チェックポイントはスキップ。
5. **dev-phase間でのタスク移動**: 移動しない。MVPタスクが失敗しinvestigatorがblocked判定した場合、既存のblocked_investigation/blocked_criteriaフローに従う。dev-phase内の未完了タスクがある場合、次のdev-phaseには進まない。

### 新規

6. **development.json の server セクション**: start_command, health_check_url を誰が設定するか（criteria-generation自動生成 / task-planning自動生成 / 手動設定）は未決定。現時点では手動設定。
7. **dev-phaseの exit_criteria autoテスト失敗時のフロー**: 現時点では人間に通知して中断（選択肢B）を採用。将来的にタスク差し戻し（A）やinvestigator起動（C）への発展を検討。

---

## 9. 他領域との関係（見捨てない問題）

本設計書はPhase 1.5（領域A）に集中しているが、以下は別途対応が必要。

### 領域B: Phase 1 リサーチ品質
- P5（検索戦略欠如）: researcher-prompt.md への検索ガイダンス追加
- P7（アクション不足）: 最終レポート生成の専用テンプレート化
- P6（入力肥大化）: Synthesizer入力の中間要約

### 領域C: エージェントのタスク設計
- P4（タスク詰め込み）: DAの9タスク→2段階分割
- P2（few-shot不在）: 判定フェーズ優先でfew-shot追加
- P1（形式偏重）: 思考ガイダンスの比率改善
- SCの固定4視点問題: テーマ適応的な視点選択

### 横断的な未解決の問い
- P3（CoT）の実際の効果検証
- MF-001（Forge存続判断）
- few-shotの投資対効果
