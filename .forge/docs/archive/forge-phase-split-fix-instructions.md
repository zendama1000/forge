# Forge Phase 1.5 再設計 — 修正指示書

**対象:** `forge-phase-split-design.md`（設計書）の修正と、それに伴う実装ガイダンスの追加
**前提:** 設計書をコードベースと突合した結果、3つの重大矛盾と4つの要修正事項が発見された。本指示書で全7件を解決する。

---

## 修正対象ファイル一覧

### 設計書（直接修正）
- `forge-phase-split-design.md`

### 参照すべき現行コード（修正しない、突合用）
- `.forge/loops/ralph-loop.sh` — 既存Phase 3関数（run_phase3）の確認
- `.forge/loops/forge-flow.sh` — 既存チェックポイントフローの確認
- `.forge/loops/generate-tasks.sh` — 既存タスク生成フローの確認
- `.forge/templates/task-planning-prompt.md` — バックグラウンドプロセス禁止ルールの確認
- `.forge/templates/criteria-generation.md` — 既存スキーマの確認
- `.forge/config/circuit-breaker.json` — 既存設定構造の確認
- `.claude/agents/` — 既存エージェント一覧の確認

---

## 重大①：Phase番号の名前衝突

### 問題
設計書の3段階フェーズ（Phase 1=MVP / Phase 2=主要機能 / Phase 3=仕上げ）と、ralph-loop.sh既存の`run_phase3()`（Layer 2テスト一括実行）が「Phase 3」で衝突する。

### 修正指示

設計書のフェーズ名を**開発フェーズの番号体系**に変更する。既存コードの Phase 1 / Phase 1.5 / Phase 2 / Phase 3 はパイプライン段階を指す用語として維持し、開発フェーズには別の命名を使う。

**設計書全体で以下の置換を行うこと：**

```
旧:                          新:
Phase 1: MVP            →  dev-phase: mvp
Phase 2: 主要機能       →  dev-phase: core
Phase 3: 仕上げ         →  dev-phase: polish
```

具体的には：

1. セクション2（フェーズ制御モード）の表：
   - 「Phase 2後」「Phase 3後」→「core完了後」「polish完了後」

2. セクション3（フェーズ構成）：
   ```
   旧:
   Phase 1: MVP        — 最小限動くもの
   Phase 2: 主要機能    — 機能を一通り揃える
   Phase 3: 仕上げ     — エッジケース対応、UI調整

   新:
   dev-phase: mvp      — 最小限動くもの（E2Eで1フローが動く状態）
   dev-phase: core     — 機能を一通り揃える
   dev-phase: polish   — エッジケース対応、UI調整
   ```

3. セクション5（回帰テスト）：既に `mvp.sh` / `core.sh` / `polish.sh` という命名なので整合している。変更不要。

4. セクション6（フェーズ完了時のフロー）のチェックポイント表示例：
   ```
   旧: Phase 2 (主要機能): Nタスク
   新: core (主要機能): Nタスク
   ```

5. **新規追加: 用語定義セクション（セクション1の末尾に追加）：**
   ```markdown
   ### 用語定義
   - **パイプライン段階（Phase）**: Forgeの処理段階を指す既存用語。
     Phase 1=Research, Phase 1.5=Task Planning, Phase 2=Development（ralph-loop）, Phase 3=統合検証（Layer 2テスト一括実行）。
     これらは変更しない。
   - **開発フェーズ（dev-phase）**: Phase 2（Development）内部でのタスク実行順序を制御する概念。
     本設計で新規導入する。mvp → core → polish の3段階。
     Phase 2の中でdev-phaseが順次実行され、各dev-phase完了時にチェックポイントが入る。
   ```

6. セクション7（改修対象）の `ralph-loop.sh` の改修内容を具体化：
   ```
   旧: フェーズ単位の実行制御（phase_idによるフィルタリング）
   新: dev-phase単位の実行制御（dev_phase_idによるフィルタリング）。
       既存のrun_phase3()（Layer 2統合テスト）は変更せず、dev-phase完了チェックポイントの後に
       既存Phase 3として実行する。
   ```

---

## 重大②：バックグラウンドプロセス禁止 vs curlテスト

### 問題
task-planning-prompt.md の「プラットフォーム互換ルール」にバックグラウンドプロセス禁止ルールがある：
```
3. **バックグラウンドプロセス禁止**: Layer 1 テストで `&` やプロセス管理を使わないこと
   - NG: `node server.js & sleep 3 && curl localhost:3000 && kill $!`
   - OK: `npx jest --testPathPattern='server'`（テストフレームワーク内でライフサイクル管理）
   - サーバ起動テストは Layer 2 に配置する
```

設計書のexit_criteria例は `curl -sf http://localhost:3000/api/items` だが、サーバーが起動していないとこのテストは実行できない。タスクレベルではバックグラウンドプロセス禁止のためサーバーを起動できない。

### 修正指示

**テストの実行レイヤーを明確に分離する：**

1. **タスクレベル（Layer 1テスト）のルールは変更しない。** バックグラウンドプロセス禁止は維持。タスクレベルのテストは引き続き `test -f`, `npm run build`, `npx vitest run` 等の自己完結テストのみ。

2. **exit_criteriaのautoテストは「フェーズレベルテスト」として別カテゴリにする。** タスクレベルのLayer 1テストとは異なり、フェーズレベルテストはrun-regression.shの管理下でサーバーが起動済みの状態で実行される。

3. **設計書のセクション4（exit_criteria設計）に以下を追加：**

   ```markdown
   ### テスト実行レイヤーの分離

   exit_criteriaのautoテストと、タスク個別のLayer 1テストは別物である。

   | 区分 | 管理者 | サーバー | 禁止事項 | 例 |
   |---|---|---|---|---|
   | タスクLevel Layer 1テスト | ralph-loop | 自己管理（起動不要なテストのみ） | バックグラウンドプロセス禁止 | `test -f`, `npm run build`, `npx vitest run` |
   | dev-phaseレベル exit_criteria (auto) | run-regression.sh | ランナーが事前起動 | なし（curlも可） | `curl -sf localhost:3000/api/items` |

   task-planning-prompt.md の「バックグラウンドプロセス禁止」ルールはタスクレベルLayer 1テストにのみ適用される。
   exit_criteriaのautoテストはrun-regression.shがサーバーを起動した状態で実行するため、curlベースのE2Eテストが書ける。
   ```

4. **セクション6（サーバーライフサイクル管理）の方式Cの表を修正：**

   ```
   旧:
   | タスクレベル（ralph-loop内） | 方式A: 自己完結 | テストスクリプト自身 |

   新:
   | タスクレベル Layer 1（ralph-loop内） | サーバー不要 | テスト自体がサーバーを必要としない設計 |
   ```

   タスクレベルは「自己完結でサーバーを起動/停止する」のではなく、「そもそもサーバーを必要としないテストだけをLayer 1に配置する」が正しい設計。サーバーを要するテストはexit_criteria（フェーズレベル）またはLayer 2に配置する。

5. **セクション5（回帰テスト設計）のrun-regression.sh にサーバー起動/停止を組み込む：**

   ```bash
   #!/bin/bash
   # run-regression.sh — dev-phaseレベルのexit_criteriaテスト実行
   # サーバーライフサイクルを管理し、各dev-phaseのautoテストを累積実行する
   
   phases=("mvp" "core" "polish")
   target="${1:-mvp}"
   SERVER_PID=""
   
   cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; }
   trap cleanup EXIT
   
   # サーバー起動（プロジェクト固有のstartコマンドを実行）
   start_server() {
     local start_cmd
     start_cmd=$(jq -r '.server.start_command // "npm start"' .forge/config/development.json)
     local health_url
     health_url=$(jq -r '.server.health_check_url // "http://localhost:3000"' .forge/config/development.json)
     local max_wait=30
     
     eval "$start_cmd &"
     SERVER_PID=$!
     
     # ヘルスチェック待機
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

6. **development.json に server セクションを追加する設計を記載：**

   ```json
   {
     "server": {
       "start_command": "npm start",
       "health_check_url": "http://localhost:3000/api/health",
       "startup_timeout_sec": 30
     }
   }
   ```

   この設定はcriteria-generationが生成するか、task-planningが生成するか、手動設定するかは未決定として注記する（セクション8に追加）。

---

## 重大③：フェーズ別テストスクリプトの生成方法

### 問題
設計書は「task-planningがフェーズ別テストスクリプトを生成する」としているが、generate-tasks.shは**JSON 1ファイルだけを出力する設計**。task-planning-prompt.mdも「出力はJSON形式のみ」と厳格に指定しており、.shファイルの生成方法が未定義。

### 修正指示

**JSON→シェルスクリプト変換をgenerate-tasks.shの後処理として実装する。** task-planningのLLM出力はJSONのまま維持し、シェルスクリプトへの変換は決定論的な処理にする。

1. **設計書セクション5（回帰テスト設計）の「生成タイミング」を修正：**

   ```markdown
   ### 生成タイミング
   
   1. criteria-generation.md がphases配列（exit_criteriaのautoテスト含む）を生成 → implementation-criteria.json
   2. task-planning はphase情報をそのまま task-stack.json に引き継ぐ
   3. generate-tasks.sh の後処理で、task-stack.json内のphases[].exit_criteria[type=auto] から
      フェーズ別テストスクリプトを機械的に生成する
   
   LLMにシェルスクリプトを直接書かせない。JSONの構造化データから決定論的に変換する。
   ```

2. **generate-tasks.shに追加する後処理のロジック（設計書に記載）：**

   ```markdown
   ### generate-tasks.sh 後処理: テストスクリプト生成

   generate-tasks.sh の末尾に、task-stack.json の phases 配列から
   .forge/state/phase-tests/{phase_id}.sh を生成するステップを追加する。

   変換ロジック:
   ```
   ```bash
   # generate-tasks.sh に追加する後処理
   generate_phase_test_scripts() {
     local task_stack="$1"
     local output_dir=".forge/state/phase-tests"
     mkdir -p "$output_dir"
     
     # task-stack.json からphase一覧を抽出
     local phases
     phases=$(jq -r '.phases[]?.id // empty' "$task_stack" 2>/dev/null)
     
     for phase_id in $phases; do
       local script="${output_dir}/${phase_id}.sh"
       echo "#!/bin/bash" > "$script"
       echo "# Auto-generated exit_criteria tests for dev-phase: ${phase_id}" >> "$script"
       echo "# Generated at: $(date -Iseconds)" >> "$script"
       echo "set -e" >> "$script"
       echo "" >> "$script"
       
       # exit_criteria の type=auto を抽出してテストコマンドに変換
       jq -r --arg pid "$phase_id" '
         .phases[] | select(.id == $pid) | 
         .exit_criteria[]? | select(.type == "auto") |
         "echo \"  Testing: \(.description)\" && \(.command) && echo \"  ✓ PASS\" || { echo \"  ✗ FAIL: \(.description)\"; exit 1; }"
       ' "$task_stack" >> "$script"
       
       chmod +x "$script"
       log "  テストスクリプト生成: ${script}"
     done
   }
   ```

3. **セクション7（改修対象）の generate-tasks.sh を改修対象に追加：**

   ```
   | generate-tasks.sh | 後処理追加: task-stack.json からフェーズ別テストスクリプトを機械的に生成 |
   ```

---

## 要修正①：implementation-criteria.json スキーマのlayers vs phases整理

### 問題
現在のスキーマは `layer_1_criteria` / `layer_2_criteria` / `layer_3_criteria` の3層構造。設計書が追加する `phases[].exit_criteria` との関係が未定義。

### 修正指示

**両方残す。役割が異なるため。**

1. **設計書セクション4の末尾に「スキーマ関係の定義」を追加：**

   ```markdown
   ### implementation-criteria.json のスキーマ拡張

   既存の layer_1/2/3_criteria はタスクレベルの成功条件定義として維持する。
   phases 配列はdev-phaseレベルの統合確認として新規追加する。

   ```json
   {
     "research_id": "...",
     "theme": "...",
     "generated_at": "...",
     
     // 既存: タスクレベルの成功条件（task-planningが各タスクのLayer 1/2テストに分解）
     "layer_1_criteria": [ ... ],
     "layer_2_criteria": [ ... ],
     "layer_3_criteria": [ ... ],
     "assumptions": [ ... ],
     
     // 新規: dev-phaseレベルの統合確認
     "phases": [
       {
         "id": "mvp",
         "goal": "最小限のE2Eフローが1つ動く状態",
         "scope_description": "どの機能がMVPに含まれるかの説明",
         "criteria_refs": ["L1-001", "L1-002"],  // layer_1_criteriaのIDを参照
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
   ```

2. **セクション8（未決定事項）の項目2を解決済みに変更し、上記スキーマに置き換える。**

---

## 要修正②：checklist-concretizeのエージェント定義（WHO）

### 問題
新規テンプレート checklist-concretize-prompt.md は設計書に記載されているが、それを実行するエージェント定義（.claude/agents/*.md）が未定義。

### 修正指示

1. **新規エージェント `checklist-verifier.md` を `.claude/agents/` に作成する方針とする。**

   理由:
   - 既存のinvestigatorは「失敗原因分析」が役割。checklist具体化は別の能力（実装コードを読んでUI操作手順に変換する）が必要。
   - WHO/WHAT分離の原則に従い、新しい役割には新しいエージェントを割り当てる。
   - エージェントファイルは軽量（システムプロンプトのみ）なので追加コストは小さい。

2. **設計書セクション7（改修対象）の新規作成表に追加：**

   ```
   | checklist-verifier.md | エージェント定義 | 実装済みコードを読み、フェーズのhuman_checkをレベルBの操作手順checklistに具体化する役割 |
   ```

3. **設計書セクション7の「変更なし」セクションから以下の記述を修正：**

   ```
   旧: 全agentファイル (.claude/agents/) | WHO定義は変更不要
   新: 既存agentファイル (.claude/agents/) | 既存のWHO定義は変更不要。checklist-verifier.md のみ新規追加
   ```

4. **セクション8（未決定事項）の項目1を解決済みに変更：**

   ```
   旧: checklist-concretize-prompt.md の具体的な内容: エージェント定義（WHO）は既存のものを使うか、新設するか
   新: （解決済み）新規エージェント checklist-verifier.md を作成する
   ```

---

## 要修正③：既存ralph-loop.sh Phase 3（Layer 2テスト）との統合

### 問題
ralph-loop.sh の run_phase3() は全タスク完了後にLayer 2テストを一括実行し、失敗時にfix taskを生成して再ループする仕組み。dev-phase分割を入れると、この既存Phase 3がいつ走るのかが不明。

### 修正指示

**既存Phase 3（Layer 2統合テスト）は最終dev-phase（polish）完了後に実行する。**

1. **設計書に「パイプライン全体フロー図」をセクション1の後（セクション1.5相当）に追加：**

   ```markdown
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
   ```

2. **ralph-loop.sh の改修内容を具体化（セクション7）：**

   ```
   旧: ralph-loop.sh | dev-phase単位の実行制御（dev_phase_idによるフィルタリング）
   
   新: ralph-loop.sh | 以下の改修:
     a. メインループのget_next_task()にdev_phase_idフィルタを追加。
        現在のdev-phaseに属するタスクのみを実行対象とする。
     b. 現在のdev-phase内の全タスク完了時に、
        run-regression.sh → checklist-concretize → チェックポイント を実行する
        dev-phase完了処理関数を新設。
     c. 全dev-phase完了後に既存run_phase3()を実行（変更なし）。
     d. dev-phase情報はtask-stack.jsonのトップレベルphasesから読み取る。
   ```

---

## 要修正④：forge-flow.sh とgenerate-tasks.shの間のデータフロー

### 問題
フェーズ分割に伴い、forge-flow.shの既存チェックポイント（タスク数表示→Enter待ち）では情報が不足する。フェーズ構成の確認が必要。

### 修正指示

1. **forge-flow.shの Phase 1.5 完了後チェックポイントを拡張する設計を記載：**

   ```markdown
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

   この表示により、人間はPhase 2実行前にdev-phase構成、テスト内容、制御モードを確認できる。
   ```

2. **forge-flow.shの改修内容を具体化（セクション7）：**

   ```
   旧: forge-flow.sh | --phase-control フラグ、フェーズ間チェックポイント、サーバー管理

   新: forge-flow.sh | 以下の改修:
     a. --phase-control=auto|checkpoint|mvp-gate 引数パース追加
     b. Phase 1.5完了後チェックポイント拡張（dev-phase構成表示）
     c. ralph-loop.sh への --phase-control 引数引き渡し
     d. circuit-breaker.json の flow_limits に phase_control_default を追加
   ```

3. **circuit-breaker.json の拡張設計：**

   ```json
   "flow_limits": {
     "max_research_remands": 2,
     "human_checkpoint_timeout_sec": 30,
     "phase_control_default": "mvp-gate"
   }
   ```

---

## セクション8（未決定事項）の更新

上記修正により以下の項目が解決される。設計書のセクション8を更新すること。

### 解決済みに変更

```
項目1: （解決）新規エージェント checklist-verifier.md を作成
項目2: （解決）phases配列のスキーマ定義確定（要修正①で記載）
```

### 内容更新

```
項目3: task-stack.json の dev_phase_id 割り当てロジック
  → criteria_refs を使い、タスクの依存する layer_X_criteria が
    どのdev-phaseに属するかで自動判定する。
    task-planning-prompt.md にこのロジックの指示を追加。

項目4: autoモード時のhuman_checkの扱い
  → ログに記録するが停止しない。
    checklist具体化ステップは実行する（ログ用）が、チェックポイントはスキップ。

項目5: dev-phase間でのタスク移動
  → 移動しない。MVPタスクが失敗しinvestigatorがblocked判定した場合、
    既存のblocked_investigation/blocked_criteriaフローに従う。
    dev-phase内の未完了タスクがある場合、次のdev-phaseには進まない。
```

### 新規追加

```
項目6: development.json の server セクション（start_command, health_check_url）を
  誰が設定するか（criteria-generation自動生成 / task-planning自動生成 / 手動設定）

項目7: dev-phaseの exit_criteria autoテスト失敗時のフロー
  - 選択肢A: そのdev-phaseのタスクに差し戻す（どのタスクかの特定が必要）
  - 選択肢B: 人間に通知して中断
  - 選択肢C: investigatorを起動して原因分析
  現時点では選択肢Bを採用し、将来的にA/Cへ発展させる。
```

---

## 最終チェックリスト

設計書修正完了後、以下を確認すること：

- [ ] 「Phase 1」「Phase 2」「Phase 3」がパイプライン段階としてのみ使われている
- [ ] 「dev-phase」が開発フェーズとしてのみ使われている
- [ ] exit_criteriaのautoテストとタスクLevel Layer 1テストの区別が明確
- [ ] バックグラウンドプロセス禁止ルールとcurlテストの矛盾が解消されている
- [ ] テストスクリプト生成がLLM出力ではなくJSON→sh変換として定義されている
- [ ] phases配列とlayer_X_criteriaの関係がcriteria_refsで紐付けられている
- [ ] checklist-verifier.md が新規作成一覧に含まれている
- [ ] 既存run_phase3()の実行タイミングが明確
- [ ] forge-flow.shのチェックポイント表示にdev-phase構成が含まれている
- [ ] セクション8の未決定事項が最新化されている
- [ ] セクション7の改修対象にgenerate-tasks.shが含まれている
