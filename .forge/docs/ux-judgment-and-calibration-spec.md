# UX判定システム + キャリブレーション修復 設計仕様書

**作成日:** 2026-07-20
**目的:** 「たたき台→実践レベル」ギャップの主成分であるUX品質を、機械ゲート＋較正済みLLM判定で改善する
**ステータス:** 設計確定・実装指示書
**前提リポジトリ:** forge-research-harness-v1

---

## 0. 背景と設計判断の要約

本仕様は以下の議論・検証を経て確定した。

1. 人手修正の主成分は「UX・見た目・使い勝手」（ユーザー確認済み）
2. Evolve仕様書（.forge/state/evolve-harness-spec.md）のメトリクスベース外側ループはUX品質に刺さらないため、本仕様を優先する。ただし外側ループの骨格（評価→未達→タスク生成）は本仕様のジャッジループに転用する
3. キャリブレーション配管はコード検証の結果、下流（Few-Shot注入）は正常・上流（データ収集）が二重に死んでいることを確認済み（詳細は §2）
4. UX判定は「証拠の直交性」を軸に3チャネル構成とし、ペルソナ多様化は美観チャネル内に限定する
5. レンズ枚数は事前固定せず accepted-finding rate による実測プルーニングで管理する

### 適用する設計原則（既存原則との対応）

| 原則 | 本仕様での適用 |
|---|---|
| 機械で守れることは機械に | 模擬ユーザーの「初見らしさ」をプロンプト演技でなくツール制限で強制 |
| 観測できないものは改善できない | 乖離率・レンズ別採択率を dashboard に常時表示 |
| 黙って劣化してはならない | エスカレーション未裁定は quality-debt に記録 |
| フィードバックは収束させる | must_fix 上限3件・resolution_criteria 必須・調停役による矛盾解消 |
| 状態はファイルに、判断はLLMに | 判定結果・裁定・レンズ統計はすべて JSONL |

---

## 1. 全体構成

```
                    ┌─ 美観ジャッジ（レンズ2枚まで） ─┐
  対象UI ──観測──┤   模擬ユーザー（行動証拠）        ├──→ 集約器 ──┬─ 全員一致 → 自動処理（合格 or fixタスク）
                    └─ 構造検査（DOM/a11y/機械）      ┘              └─ 不一致  → 人間エスカレーション
                                                                            │
                          Few-Shot注入 ←── calibration-data.jsonl ←── 裁定記録
```

発火はdev-phase連動の段階制（§5）。人間の裁定はキャリブレーションデータとして蓄積され、
評価器のFew-Shotに注入される（既存配線を利用）。

---

## 2. P0: キャリブレーション配管修復（最優先・依存元）

### 2.1 検証済みの現状

- `lib/calibration.sh` の記録・注入・乖離率計算は実装済み
- `lib/evidence-da.sh` / `lib/qa-evaluator.sh` は `get_calibration_examples` を呼び `{{CALIBRATION_EXAMPLES}}` に注入する配線済み
- **切断①:** 手動記録の入口が存在しない（人間の実修正は task-stack の状態を触らない）
- **切断②:** `detect_reworked_tasks` は `.previous_status == "completed"` を条件とするが、`ralph-loop.sh` の `update_task_status` は previous_status を書かない。ハーネス内に書き込み箇所なし → 検出は構造的 no-op
- **切断③:** データ0件でも無警告で空注入され、無較正であることが観測不能
- 結果: `.forge/state/calibration-data.jsonl` は存在しない（0件）

### 2.2 修理タスク

#### P0-1: previous_status の記録

`ralph-loop.sh` の `update_task_status()` の jq フィルタを変更:

```
.tasks |= map(
  if .task_id == $id then
    .previous_status = .status |
    .status = $s |
    .updated_at = (now | todate) |
    if $s == "pending" then .fail_count = 0 else . end
  else . end
)
```

注意: `detect_reworked_tasks` は記録後に `del(.previous_status)` する既存実装のため、
重複記録防止は既に担保されている。

#### P0-2: 手動フィードバックコマンド新設

`.forge/loops/feedback.sh`（薄いCLIラッパー）:

```
用法: bash .forge/loops/feedback.sh <task-id> <verdict> "<理由>"
  verdict: reject | accept-with-notes
```

動作:
1. `${DEV_LOG_DIR}/<task-id>/evidence-da-result.json` / `qa-evaluator-result.json` /
   `ux-judgment-result.json`（§4）が存在すれば、それぞれの evaluator 名で
   `record_calibration_example` を呼ぶ
2. evaluator 結果が1つも無い場合も `evaluator: "human-direct"` として記録する
   （後続の傾向分析に使うため捨てない）
3. 記録件数を stdout に表示する

CLAUDE.md の起動方法セクションに1行追記すること。

#### P0-3: 乖離率の表示配線

- `dashboard.sh` に `compute_divergence_rate` の出力を追加（全体 + evaluator別）
- `ralph-loop.sh` の `print_summary()` にも1行追加
- calibration-data.jsonl が0件の場合は「⚠ 較正データ0件 — 評価器は無較正」と明示表示する
  （切断③の観測性対策。存在しないことを黙らせない）

### 2.3 P0 受入基準（no-op防止のためend-to-end必須）

```
□ タスクを completed → pending に手動変更 → ralph-loop 1周後に
  calibration-data.jsonl に evidence-da または qa-evaluator のレコードが存在する
□ feedback.sh 実行 → レコード追記 → 次回 evidence-da 実行時の実プロンプト
  （dev-logs内の保存プロンプト）に「キャリブレーション事例」セクションが出現する
□ dashboard.sh の出力に乖離率が表示される（0件時は警告表示）
```

---

## 3. P1: 模擬ユーザー（Sim-User）

### 3.1 エージェント構成（2体）

#### ux-scenario-generator（文脈遮断層）

- 入力: implementation-criteria.json
- 出力: `.forge/state/ux-scenarios.json`
- 役割: criteria をユーザー語彙のゴールに変換する。実装用語（コンポーネント名・
  機能ID・ファイル名・「〜ボタン」等の答え）を含めてはならない
- 機械ゲート: 生成後、criteria 内の識別子・コンポーネント名との照合 grep を行い、
  一致があればリジェクト→再生成（max 2回、失敗時は quality-debt 記録して続行）

ux-scenarios.json スキーマ:

```json
{
  "scenarios": [
    {
      "scenario_id": "UX-S-001",
      "user_goal": "今日の運勢が気になってこのサイトに来た。見たいものを見る",
      "entry_url": "/",
      "action_budget": 10,
      "viewport": "mobile|desktop",
      "success_signal": "運勢の内容を確認できた状態（ユーザー主観で判断）"
    }
  ]
}
```

#### ux-sim-user（実行体）

- コンテキスト: 毎回フレッシュ（context_strategy: reset）。criteria・task-stack・
  実装コードへのアクセス禁止
- **知覚制限（本仕様の核心）:** スクリーンショットのみで操作する。
  アクセシビリティツリー取得系ツールは disallowed に設定する。
  実装時に Playwright MCP の公開ツール一覧を確認し、read/snapshot系ツール名を
  特定して disallowed_tools に列挙すること（要検証事項 §8-1）
- 行動プロトコル（テンプレートに明記）:
  1. 各アクション前に「何が起こると期待するか」を1行宣言する
  2. アクション後、期待とのズレを expectation_violation として記録する
  3. クリック候補が複数あり決めきれない場合は hesitation として記録し、
     視覚的に最も目立つものを選ぶ
  4. action_budget を超えたら未完遂として終了する
  5. 最初の判断はスクロールなしの初期表示範囲のみで行う

出力 `${task_dir}/sim-user-result.json`:

```json
{
  "scenario_id": "UX-S-001",
  "completed": true,
  "actions_taken": 6,
  "shortest_path_estimate": 3,
  "expectation_violations": [{"step": 2, "expected": "...", "actual": "..."}],
  "hesitations": [{"step": 4, "candidates": ["...", "..."]}],
  "backtracks": 1,
  "transcript_path": "..."
}
```

### 3.2 位置づけの明文化（テンプレートとレポート双方に記載）

- 絶対値（完遂率）は信用しない。用途は (a) 修正前後の相対比較 (b) 摩擦イベントの検出
- 実ユーザーテストの代替ではなく、実ユーザーに見せる前の下限フィルタである
- LLM模擬ユーザーは実在ユーザーより過剰に成功し過剰に従順である（既知の限界）

---

## 4. P1: 美観ジャッジ・構造検査・集約器

### 4.1 美観ジャッジ（ux-aesthetic-judge）

- 入力: 対象画面のスクリーンショット群（browser-test 基盤で取得）+ レンズ定義
- レンズはコード埋め込みでなくデータとして管理: `.forge/lenses/*.md`
  - `lens-taste.md`（バー上げ役。ジョブズ的な妥協排除・シンプルさ・細部の質感。
    ただし名前でなく操作可能な原則で記述する: 「1画面1主役」「装飾でなく階層で導く」等）
  - `lens-usability.md`（保守役。ノーマン的なアフォーダンス・エラー耐性・認知負荷）
- 同一証拠チャネル内のレンズは**2枚を上限**とする（相関による逓減のため）
- 出力制約（re-execution lottery 防止・必須）:
  - must_fix は重要度順**上位3件まで**
  - 各件に resolution_criteria（何を満たせば解決か、検証可能な記述）必須
  - resolution_criteria が反証不能（「もっと感動的に」等）の場合、集約器がリジェクトする

### 4.2 構造検査（ux-structural-check）

- 可能な限り非LLM化する: コントラスト比・タップ領域サイズ・フォーカス順序・
  ビューポート横断のレイアウト崩れ（既存 visual-regression スナップショット活用）
- 実装は既存 `lib/browser-test.sh` の拡張とし、新規ファイル乱立を避ける

### 4.3 集約器（ux-aggregator）

- 入力: 3チャネルの結果 JSON
- 処理:
  1. resolution_criteria 不備の must_fix をリジェクト
  2. 矛盾する指摘（例: 余白増 vs 密度増）を検出し、1方向に調停した統合 must_fix を出力
  3. verdict 突合: 全チャネル一致 → pass / fix タスク生成（既存 fail_creates_task 配管を利用）
  4. 不一致 → エスカレーション（§6）
- 出力: `${task_dir}/ux-judgment-result.json`（feedback.sh の記録対象に含める）

---

## 5. 発火設計（dev-phase 連動）

新設 `.forge/config/ux-judgment.json`:

```json
{
  "ux_judgment": {
    "enabled": true,
    "applies_to_task_types": ["implementation"],
    "phase_config": {
      "mvp":    { "structural": "per_task", "sim_user": "off",        "aesthetic": "off" },
      "core":   { "structural": "per_task", "sim_user": "phase_exit", "aesthetic": "off" },
      "polish": { "structural": "per_task", "sim_user": "phase_exit", "aesthetic": "phase_exit" }
    },
    "aesthetic": { "max_lenses": 2, "max_must_fix_per_lens": 3, "model": "opus" },
    "sim_user":  { "model": "opus", "timeout_sec": 600 },
    "escalation": { "mode": "record_and_continue", "pause_on_disagreement": false }
  }
}
```

- phase_exit の発火は既存 dev-phases の exit_criteria 評価に統合する
- ablation.json の components に `ux_judgment` を追加し、実験でON/OFF可能にする

---

## 6. エスカレーションとデーモン共存

デフォルトは **record_and_continue**（本仕様の推奨・理由: 非対話デーモン運用と
「黙って劣化しない」の両立）:

1. 不一致検出時、`record_quality_debt "ux_disagreement" <task_id> <要約> <各verdict JSON>` を記録
2. notifications/ に裁定依頼を出力（既存通知機構）
3. フローは continue（当該タスクは暫定 pass 扱い、debt が未解消のまま表面化し続ける）
4. 人間が後から `feedback.sh` で裁定 → calibration 記録 + `resolve_quality_debts_matching` で債務解消

`pause_on_disagreement: true` 設定時は対話モードのみ read 待ち（既存チェックポイントと同形式）。

---

## 7. レンズ実測プルーニング（P2）

- 定義: accepted-finding rate = レンズ起因の fix タスクのうち最終的に completed になり、
  かつ人間 reject（feedback.sh）を受けなかった割合
- 集計元: task-events.jsonl（fix タスクに `origin_lens` フィールドを付与すること）
- dashboard.sh にレンズ別の率を表示
- 運用ルール: 直近10件で率が閾値（初期値 0.5）未満のレンズは無効化候補として警告表示。
  自動無効化はしない（人間判断）
- Ablation 実験候補: 「レンズ2枚×medium effort」vs「レンズ1枚×xhigh effort」

---

## 8. 実装時の要検証事項

1. **Playwright MCP のツール粒度:** スクリーンショットのみ運用のために disallowed に
   すべきツール名（accessibility snapshot / DOM read 系）を実機で列挙・確認する。
   ツール単位制御が不可能な場合は、テンプレートでの使用禁止指示 + トランスクリプト
   grep による事後検証ゲート（使用検出時は結果を invalid 扱い）にフォールバックする
2. **スクリーンショット取得の安定性:** headless 環境でのフォント・レンダリング差異
3. **calibration スキーマの画像拡張は本仕様のスコープ外**（将来課題として明記のみ）

---

## 9. 実装順序と依存関係

```
P0 (キャリブレーション修復)          — 依存なし。最初に実施
 └→ P1-a (scenario-generator + sim-user) — P0 と独立実装可、記録は P0 に依存
 └→ P1-b (structural check 拡張)          — 独立
 └→ P1-c (aesthetic judge + lenses)       — 独立
     └→ P1-d (aggregator + escalation)    — P1-a/b/c の出力スキーマに依存
         └→ P1-e (発火配線 + config)      — dev-phases 統合
             └→ P2 (プルーニング計測)     — 運用データ蓄積後
```

各ステップの受入基準は「コードの存在」ではなく「end-to-end で信号が流れること」を
検証するテストとして書くこと（過去の no-op 教訓: context continuation /
state-updater / previous_status）。P1-e の受入基準例:

```
□ polish フェーズ exit 時に3チャネルすべての結果 JSON が dev-logs に生成される
□ 意図的に矛盾する verdict を fixture で与え、quality-debt と通知が生成される
□ feedback.sh 裁定後、calibration-data.jsonl 追記 + 債務解消の両方が起きる
□ ablation.json で ux_judgment=false にすると一切発火しない
```

---

## 10. 非目標（スコープ外の明記）

- 実ユーザーテストの代替（本システムは下限フィルタ）
- モデル多様性によるジャッジパネル（他社VLM導入は将来検討）
- Evolve Harness のメトリクス外側ループ（本仕様完了後に統合可否を再判断）
- calibration への画像添付（スキーマ拡張は別仕様）
