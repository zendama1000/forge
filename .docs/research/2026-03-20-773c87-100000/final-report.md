# L3受入テストへのエージェント連鎖E2E検証追加 — リサーチレポート

| 項目 | 内容 |
|------|------|
| リサーチID | `2026-03-20-773c87-100000` |
| 日付 | 2026-03-20 |
| テーマ | L3受入テストにエージェント連鎖E2E検証を追加 — Claude Codeエージェントが対話的にファイル生成する利用フローを自動検証する仕組みの設計と実装 |
| 判定 | **DIRECT**（実装設計レベルまで具体化） |
| 視点数 | 6（固定4 + 動的2） |

---

## 1. エグゼクティブサマリー

Forge Harness の L3 受入テスト層に、複数エージェントが順次ファイルを生成する「エージェント連鎖フロー」を自動検証する新戦略 `agent_flow` を追加する設計調査を実施した。6視点の横断分析により、以下の設計判断が高い証拠強度で収束した。

### 収束した設計判断（6点）

1. **新戦略 `agent_flow` を分離追加**（5/6視点支持） — `cli_flow` 拡張ではなく独立戦略として追加。変更量は3-4箇所・約5行
2. **ファイルベースのコンテキスト受渡し**（5/6視点支持） — 既存 `run_claude()` / `.pending` パターンと完全互換
3. **タイムアウトの2層設計**（4/6視点支持） — ステップ単位300s + チェーン全体900s
4. **Phase-level 実行**（4/6視点支持） — フェーズ完了時に一括実行。コスト4倍削減 + 偽陰性回避
5. **ハイブリッド検証構造**（5/6視点支持） — 構造検証を内包 + LLM judge 整合性評価を外出し
6. **`coherence_checks` スキーマの新規設計** — ペアワイズ/E2E切替可能な汎用整合性チェック定義

### コスト見積もり

| 構成 | 1テスト | 12タスクセッション |
|------|---------|-------------------|
| 全Sonnet・分離なし | $0.94 | $11.25（per-task） |
| モデル混合・分離なし | $0.68 | $2.04（phase-level） |
| 全Sonnet・4層分離あり | $0.23 | $0.54（phase-level） |

実装工数: **21-36時間（約3-5日）**

---

## 2. 調査計画

### 2.1 コア質問（7問）

| ID | 質問 |
|----|------|
| Q1 | `cli_flow` 拡張 vs 新戦略 `agent_flow` 追加 — どちらが合理的か |
| Q2 | ステップ定義フォーマット — マルチエージェント順次実行を記述する汎用スキーマ設計 |
| Q3 | `claude -p` の制約を踏まえたステップ間コンテキスト受渡し方式 |
| Q4 | コスト制御設計 — `L3_MAX_JUDGE_CALLS_PER_SESSION=20` との按分 |
| Q5 | エージェント連鎖の失敗時リカバリ戦略 |
| Q6 | `llm_judge` 連携による3段階検証の実装構造 |
| Q7 | uranai-concept 3エージェント連鎖仕様の L3 テスト定義への落とし込み |

### 2.2 前提条件（8項目）

| ID | 前提 | リスク |
|----|------|--------|
| A1 | `claude -p` 3回順次呼出の安定動作 | レートリミット・部分状態残留 |
| A2 | エージェント出力がファイルベースで受渡し可能 | stdout直接出力パターンとの非互換 |
| A3 | L3テストの per-task 実行タイミングが適切 | フェーズレベルテストの方が自然な可能性 |
| A4 | `L3_DEFAULT_TIMEOUT=120s` で3エージェント連鎖が完了 | 480秒超の可能性 |
| A5 | `claude -p` に `--agent-file` オプションが存在 | **存在しない**（調査で判明） |
| A6 | enum拡張がスキーマ後方互換を壊さない | 問題なし（確認済み） |
| A7 | uranai-concept 3エージェントが実装済み | Step 0 GO判定が前提 |
| A8 | `llm_judge` がチェーン全体の整合性を評価可能 | SOTAでも55%の一貫性 |

### 2.3 調査視点

| 視点 | 焦点 | 種別 |
|------|------|------|
| technical | 既存L3インフラとの統合設計 | 固定 |
| cost | `claude -p` 実呼出の API 費用と実行時間 | 固定 |
| risk | エージェント連鎖テスト固有の障害パターン | 固定 |
| alternatives | ロック決定範囲内での設計選択肢比較 | 固定 |
| agent_execution_model | `claude -p` サブプロセスの実行特性 | 動的 |
| chain_coherence | エージェント間コンテキスト連鎖整合性の定義・測定・検証手法 | 動的 |

---

## 3. 視点別調査結果

### 3.1 技術的実現性（technical）

**結論: 既存L3インフラとの統合は低コストで実現可能**

| 調査項目 | 結果 | 信頼度 |
|----------|------|--------|
| T1: `cli_flow` 拡張 vs 分離 | `execute_l3_agent_flow()` として分離が必須。`cli_flow` への追加は35行→数百行に膨張しSRP違反 | 高 |
| T2: `steps` スキーマ設計 | `definition.properties` に `steps`（optional）を追加するだけで後方互換維持。6フィールド構成 | 高 |
| T3: `run_claude()` 互換性 | 9引数シグネチャでステップごと呼出に完全対応。`work_dir` 共有 + `output/log` 分離パターン確立済み | 高 |
| T4: `filter_l3_tests` 分類 | `requires` フィールドベースのため新カテゴリ追加は任意。`agent_flow` は `immediate` 分類で既存に収まる | 高 |
| T5: `claude -p` 実行モード | `--agent-file/-a` は**存在しない**。正式手段は `--agent <name>` と `--agents JSON`。Forge は `--system-prompt` 経由で代替実装済み | 高 |

**ステップ定義の最小スキーマ:**

```
steps[].{
  step_id: string,        // ステップ識別子
  agent_file: string,     // .claude/agents/ 相対パス
  model: string,          // haiku/sonnet/opus
  prompt_template: string, // {{prev_output}} 変数展開対応
  expected_outputs: [],    // ファイル存在・スキーマ検証定義
  context_from_steps: [],  // 依存する前ステップの step_id
  timeout_sec: number      // 省略時は L3_DEFAULT_TIMEOUT 継承
}
```

**ディスパッチャ変更量:**

| 変更箇所 | 変更内容 | 行数 |
|----------|----------|------|
| `task-stack.schema.json` strategy enum | `agent_flow` 追加 | 1行 |
| `criteria.schema.json` strategy_type enum | `agent_flow` 追加 | 1行 |
| `common.sh` `execute_l3_test()` case文 | `agent_flow)` 分岐追加 | 1行 |
| `test-l3-acceptance.sh` EXPECTED_ENUM | `agent_flow` 追加 | 1行 |

### 3.2 コスト・リソース（cost）

**結論: 最大のコストドライバーは50Kトークンのサブプロセスオーバーヘッド**

#### API費用詳細（1テストケース = 5呼出: 3エージェント + 2 judge）

| 構成 | 入力コスト | 出力コスト | 合計 |
|------|-----------|-----------|------|
| 全Sonnet・分離なし | $0.825 | $0.113 | **$0.94** |
| モデル混合（Sonnet×3+Haiku×2）・分離なし | $0.56 | $0.12 | **$0.68** |
| 全Sonnet・4層分離あり | $0.12 | $0.113 | **$0.23** |

- 50Kトークンオーバーヘッド（CLAUDE.md・MCPツール定義の再注入）が実際の業務トークン（2-5K）の10倍以上
- 4層サブプロセス分離で約80%削減可能（ただし本設計のスコープ外）

#### カウンタ設計

- **推奨: 別カウンタ**（`L3_MAX_AGENT_CALLS` と `L3_JUDGE_CALL_COUNT` を分離管理）
- 共有カウンタ（上限20）では12タスクセッションで4ケースしか実行できない
- 別カウンタでも `L3_MAX_JUDGE_CALLS=24` 以上が必要（12タスク×2 judge）

#### 実行頻度別コスト比較（12タスク・3フェーズセッション）

| 実行レベル | 全Sonnet・分離なし | モデル混合・分離なし | 全Sonnet・分離あり |
|-----------|-------------------|--------------------|--------------------|
| per-task（60呼出） | $11.25 | $8.16 | $2.79 |
| phase-level（15呼出） | $2.93 | $2.04 | $0.54 |
| **コスト比** | **3.8倍** | **4.0倍** | **5.2倍** |

#### 実装工数

| 作業項目 | 推定時間 |
|----------|---------|
| スキーマ変更 | 2-4h |
| `common.sh` 関数追加 | 4-10h |
| テストスクリプト作成 | 4-8h |
| `development.json` 設定追加 | 1-2h |
| uranai-concept 用テスト定義 | 4-12h |
| **合計** | **15-36h** |

### 3.3 リスク・失敗モード（risk）

**結論: 最も深刻なのはレートリミット部分状態（R1）とタイムアウト不整合（R3）**

| ID | リスク | 深刻度 | 対策 |
|----|--------|--------|------|
| R1 | レートリミット連鎖失敗 — ステップ1完了・ステップ2失敗の部分状態残留 | **高** | チェックポイントファイル + 冪等設計（完了済みステップスキップ） |
| R2 | LLM出力の非決定性による flaky test | 中 | 構造検証（決定論的）+ judge閾値を保守的に設定（0.6/5.0=3.0）。N-of-M再試行は設定可能にし初期は無効 |
| R3 | タイムアウト設計の不整合 — `L3_DEFAULT_TIMEOUT=120s` では3ステップ+judge=240-450秒に不足 | **高** | ステップ単位300s + チェーン全体900sの2層設計。`task_planner.timeout_sec=0` の知見を援用 |
| R4 | ステップ間ファイル衝突（将来の並列化リスク） | 低 | テスト用隔離ディレクトリ（`l3-agent-{test_id}/`）。現行は順次実行のため即時リスク低 |
| R5 | `task_run_l3_test` のper-task配置がagent_flowに不適切 | 中 | Phase-level実行をデフォルトとする。agent_flowは「フェーズ全体の成果物評価」 |

### 3.4 設計選択肢比較（alternatives）

#### AL1: 戦略配置

| 案 | スキーマ変更量 | 後方互換 | テスト記述の自然さ | **判定** |
|----|--------------|---------|------------------|---------|
| (a) `cli_flow` 拡張 | 1フィールド追加 | 完全 | 低（意図が曖昧） | - |
| **(b) 新戦略 `agent_flow`** | **enum追加 + 新関数** | **完全** | **高（明示的）** | **採用** |
| (c) requires依存連鎖 | 最大（ループ再設計） | 困難 | 中 | 棄却 |

#### AL2: コンテキスト受渡し

| 案 | `run_claude()` 互換 | デバッグ容易性 | 技術リスク | **判定** |
|----|---------------------|--------------|-----------|---------|
| **(a) ファイルベース** | **完全一致** | **高（ファイル残留）** | **低** | **採用** |
| (b) stdout捕捉 | 非互換 | 低 | 高（パイプバッファ65KB制限） | 棄却 |
| (c) 共有JSONコンテキスト | 部分的 | 中 | 中（肥大化リスク） | - |

#### AL3: 検証層構造

| 案 | 既存再利用 | カウンタ管理 | 部分スキップ | **判定** |
|----|-----------|------------|------------|---------|
| (a) 全内包 | 不可 | 複雑（二重カウント） | 不可 | - |
| (b) 完全分離 | 高 | 既存管理 | 可能 | - |
| **(c) ハイブリッド** | **高** | **既存管理** | **部分的** | **採用** |

- `agent_flow` 内に `expected_outputs[]` による構造検証を内包（`verify_command` パターン踏襲）
- `coherence_checks[]` による LLM judge 評価は外部で実行、`L3_JUDGE_CALL_COUNT` で管理

#### AL4: テスト実行レベル

| 案 | フィードバック速度 | コスト | 意味的適切性 | **判定** |
|----|------------------|-------|------------|---------|
| (a) per-task | 高速 | 4倍高 | 低（連鎖テストが単一タスクに不自然に紐付く） | Fallback |
| **(b) phase-level** | **フェーズ完了時** | **低** | **高（CI/CDのE2Eテストパターンと一致）** | **採用** |

### 3.5 `claude -p` 実行特性（agent_execution_model）

**結論: 終了コードは2値のみ。エラー分類には `stream-json` 解析が必要**

| 調査項目 | 結果 | 信頼度 |
|----------|------|--------|
| AE1: エージェント指定 | `--agent-file/-a` は**存在しない**。正式手段: `--agent <name>`（frontmatter name解決）/ `--agents JSON`（インライン定義）。run_claude() の `--system-prompt` パターンとは非互換（tools/model制約が効かない） | 高 |
| AE2: 出力構造 | `--output-format json` はJSONオブジェクト**配列**。`result` イベントに `result/is_error/session_id` 等。Write ツールはディスクに直接書込、stdout には成功/失敗ステータスのみ | 高 |
| AE3: 順次呼出安定性 | 1呼出あたり**8-12内部API呼出**でRPM消費大。429時は自動リトライ（`api_retry` イベント発行）。ステップ間 `sleep 2` + 指数バックオフが必要 | 中 |
| AE4: 終了コード | `exit 0`（成功）/ `exit 1`（汎用失敗）の**2値のみ**。rate_limit vs auth_failure の区別は `stream-json` の `api_retry.error` フィールドまたは `result.subtype` 解析が必要 | 中 |

### 3.6 連鎖整合性の定義・測定・検証（chain_coherence）

**結論: ハイブリッドアプローチ（構造的フィルタ + LLM judge）がベストプラクティス**

#### 整合性評価の3アプローチ比較

| アプローチ | コスト | 精度 | 適用場面 |
|-----------|-------|------|---------|
| Structural（キーワード/正規表現/埋込類似度） | 低 | 表層的 | 高速フィルタ、明らかな不整合排除 |
| LLM judge（G-Eval方式 CoT 評価） | 高 | 意味的 | 深層整合性評価（ただしSOTAでも55%一貫性） |
| **ハイブリッド（推奨）** | **中** | **高** | **構造フィルタ → 曖昧ケースのみ LLM judge** |

#### `judge_criteria` 設計

- **ペアワイズ整合性**（step1→step2, step2→step3）: 局所的ドリフト検出、開発/デバッグ用
- **E2E整合性**（入力意図→最終出力）: ユーザー意図達成度評価、最終判定用
- **推奨**: 両方を設計し `scope` フィールドで切替

#### `coherence_checks` 汎用スキーマ（提案）

```json
{
  "source_step": "step-1",
  "target_step": "step-2",
  "check_type": "structural | semantic | hybrid",
  "method": "keyword_match | embedding_sim | llm_judge | regex",
  "criteria": {
    "description": "評価内容の説明",
    "rubric": "スコアリング基準",
    "threshold": 0.7
  },
  "scope": "pairwise | end_to_end",
  "weight": 1.0
}
```

#### LLM judge プロンプト推奨構造（5セクション）

1. `task_description` — エージェントチェーンの目的・役割説明
2. `grading_guidelines` — 整合性判定基準・スコア定義
3. `evaluation_inputs` — 全ステップの入出力（ラベル付き構造化）
4. `evaluation_steps` — CoT でLLMが自動生成
5. `output_format` — `{score: 1-5, reasoning: string, specific_evidence: string}`

---

## 4. 統合分析（Synthesis）

### 4.1 視点間の矛盾と解決

| 矛盾 | 視点 | 解決策 |
|------|------|--------|
| テスト実行レベル | cost（ハイブリッド提案）vs risk（phase-level推奨） | **phase-level をデフォルト**。agent_flow は「フェーズ全体の成果物連鎖評価」であり risk の論理的整合性が優先。コスト削減（4倍）も同方向 |
| Judge モデル選択 | cost（Haiku で75%削減）vs chain_coherence（強力モデル必要） | **`check_type` で分離**。structural は機械的でモデル不要。coherence 評価は Sonnet（デフォルト）、コスト最適化時のみ Haiku に手動降格 |
| エージェント指定方法 | alternatives（`--system-prompt` で可能）vs agent_execution_model（`--agent <name>` が正式） | **Phase 1 は現行 `--system-prompt` パターン維持**。`run_claude()` シグネチャ変更不要。`--agent <name>` 対応は将来の別施策 |
| Flaky test 対策 | risk（3回実行推奨）vs cost（3倍コスト増） | **構造検証は1回（決定論的）。judge 評価も1回をデフォルト**、閾値を保守的に設定。N-of-M は設定可能にし実測データ蓄積後に判断 |
| 検証層構造 | alternatives（完全分離推奨）vs chain_coherence（統合スキーマ提案） | **ハイブリッド採用**: `expected_outputs[]`（構造検証）と `coherence_checks[]`（整合性定義）の両方を agent_flow 定義内に持たせる |
| レートリミット対策 | technical（逐次実行で問題なし）vs risk（部分状態管理が必要） | **チェックポイント + 冪等設計の2層**。`.pending` パターンの延長。ステップ間 `sleep 2` で RPM 消費緩和 |

### 4.2 過去決定との整合

| 過去決定 | 整合状態 |
|----------|---------|
| d-20260315-112817: Phase A-D 最適化計画 | **整合** — Phase A 完了後に本テーマ着手が最適順序 |
| d-20260318-121506: uranai-concept 設計 | **整合（依存あり）** — Step 0 GO 判定が前提条件 |
| d-20260211-212744: Strangler Pattern | **整合** — 既存5戦略を変更せず enum 追加 + 新関数で増設 |
| d-20260211-013350: 観測性最優先 | **整合** — agent_flow メトリクスを `metrics.jsonl` に記録する設計を初期から組込 |

**順序緊張**: Phase A の `error_category` 追加が未完了だと agent_flow のレートリミット失敗が `unknown` のまま記録され診断性が低下する。致命的ではないが、Phase A 完了後の着手を推奨。

---

## 5. 推奨設計

### 5.1 Primary: agent_flow 新戦略追加（phase-level実行・ハイブリッド検証）

#### 実装ステップ

| 順序 | 作業 | 推定時間 | 依存 |
|------|------|---------|------|
| 0 | d-20260315-112817 Phase A 完了を待つ | - | 外部 |
| 0 | d-20260318-121506 Step 0 GO 判定確認 | - | 外部 |
| 1 | スキーマ拡張（enum追加 + `steps[]`/`coherence_checks[]` フィールド） | 2-4h | - |
| 2 | `development.json` 拡張（`agent_flow_timeout=900`, `max_agent_calls=30`, `judge_model_coherence=sonnet`, `coherence_retry_count=1`） | 1-2h | - |
| 3 | `execute_l3_agent_flow()` 基本実装（逐次実行・ファイルベース受渡し・チェックポイント・構造検証・coherence評価呼出） | 8-12h | 1, 2 |
| 4 | `handle_dev_phase_completion()` に phase-level L3テスト注入（回帰テスト後・auto_commit前） | 3-5h | 3 |
| 5 | uranai-concept 用テスト定義（3ステップ定義 + coherence_checks + judge_criteria） | 4-8h | 3 |
| 6 | `test-l3-agent-flow.sh` テストケース追加 | 3-5h | 3, 4 |
| | **合計** | **21-36h** | |

#### 主要設定値

| 設定 | 値 | 根拠 |
|------|---|------|
| `L3_AGENT_FLOW_TIMEOUT` | 900s | 3ステップ×300s のバッファ |
| `L3_MAX_AGENT_CALLS` | 30 | judge カウンタと独立管理 |
| `L3_JUDGE_MODEL_COHERENCE` | sonnet | coherence 評価の信頼性確保 |
| `L3_COHERENCE_RETRY_COUNT` | 1 | 初期は1回、実測後に調整 |
| ステップ間 sleep | 2s | RPM 消費緩和 |
| 合格閾値（coherence） | 3.0/5.0 | 保守的設定、実測後に調整 |

#### リスク

- d-20260318-121506 Step 0 ABORT 時 → 代替として既存 Forge エージェント3体（Researcher→Synthesizer→DA）の疑似連鎖テストで設計検証
- `claude -p` 3回連続呼出で40-60 API呼出 → Tier 1 の 50RPM 上限に抵触する可能性。ステップ間 `sleep 2` で緩和
- coherence 評価の LLM judge 精度 → SOTA でも55%一貫性。初期閾値を緩く設定し実測データで調整
- `handle_dev_phase_completion()` auto モードとの競合 → blocking 制御の追加改修が必要（+2-3h）

### 5.2 Fallback: per-task 配置

`handle_dev_phase_completion()` 改修が複雑化した場合の代替。agent_flow テストをフェーズ最終タスクの `validation.layer_3` に配置し、既存 `task_run_l3_test()` パスで実行。設計・スキーマは Primary と同一だが実行トリガーが per-task。

**発動条件**: (1) auto モード改修に3日以上、(2) Phase D(9) との統合で大幅再設計が必要、(3) 改修後に回帰テスト成功率低下

### 5.3 ABORT 条件

以下のいずれかに該当する場合は中止:

1. d-20260318-121506 Step 0 ABORT かつ代替実証対象も確保不能
2. `claude -p` 3回連続呼出の実測で50%以上がレートリミット/タイムアウト失敗
3. Phase A-D 計画とのリソース競合で信頼性基盤改善が圧迫される
4. 1セッションあたりの L3 テスト API コストが $15 超過

**中止時の機会損失**: 手動テスト工数 2-4h/変更 × 年間10-20変更 = **20-80h/年の継続的コスト**

---

## 6. 実装基準（Implementation Criteria）

### 6.1 L1 基準（ユニットテスト — 10項目）

| ID | 内容 | テストファイル |
|----|------|--------------|
| L1-001 | strategy enum に `agent_flow` 追加、両スキーマ間で一致 | `test-l3-agent-flow.sh` |
| L1-002 | `definition` に `steps[]`/`coherence_checks[]` サブスキーマ追加 | 同上 |
| L1-003 | `development.json` に設定追加、`load_l3_config()` が読込 | 同上 |
| L1-004 | `execute_l3_agent_flow()` がステップ逐次実行・コンテキスト受渡し・エラーハンドリング | 同上 |
| L1-005 | チェックポイント記録・再実行時スキップ（冪等性） | 同上 |
| L1-006 | `expected_outputs` に基づくファイル存在・JSONスキーマ検証 | 同上 |
| L1-007 | `coherence_checks` の `check_type` 別ディスパッチ、カウンタ独立管理 | 同上 |
| L1-008 | `filter_l3_tests()` に `phase_level` モード追加 | 同上 |
| L1-009 | `execute_l3_test()` ディスパッチャに `agent_flow` 分岐追加、既存回帰なし | 同上 |
| L1-010 | `handle_dev_phase_completion()` に agent_flow テスト注入（回帰テスト後・auto_commit前） | 同上 |

### 6.2 L2 基準（統合テスト — 3項目）

| ID | 内容 |
|----|------|
| L2-001 | モック `run_claude` による3ステップ連鎖統合テスト（コンテキスト受渡し + expected_outputs + coherence_checks） |
| L2-002 | `handle_dev_phase_completion()` 経由の agent_flow E2E 統合テスト |
| L2-003 | チェックポイント中断→再開シミュレーション（冪等性統合テスト） |

### 6.3 L3 基準（受入テスト — 4項目）

| ID | 戦略 | 内容 | blocking |
|----|------|------|---------|
| L3-001 | structural | 全スキーマ横断の agent_flow 定義整合性 | true |
| L3-002 | cli_flow | モック E2E（3ステップ出力 + checkpoint + expected_outputs検証） | true |
| L3-003 | structural | 既存 L3 テストインフラの回帰テスト | true |
| L3-004 | llm_judge | coherence_checks の出力が l3-judge スキーマ準拠 | false |

### 6.4 フェーズ構成

| フェーズ | ゴール | 対応基準 |
|---------|--------|---------|
| **MVP** | agent_flow 基本実行パスが動作し、モック3ステップのコンテキスト受渡しが成功 | L1-001〜004, L1-009 |
| **Core** | チェックポイント冪等性・構造検証・coherence評価・phase-level実行連携が全て動作 | L1-005〜008, L1-010, L2-001 |
| **Polish** | エッジケース・統合テスト・受入テスト・回帰テスト全通過、本番投入可能品質 | L2-002〜003, L3-001〜004 |

---

## 7. 調査ギャップ（未調査事項）

| 領域 | ギャップ | 影響 |
|------|---------|------|
| 実測データ | `claude -p` 3回連続呼出の RPM 消費量・タイミング | タイムアウト/クールダウン設計の精度 |
| 実測データ | coherence 評価の LLM judge 精度（uranai-concept 固有基準） | 合格閾値の適正値 |
| 実装詳細 | `L3_DEFAULT_TIMEOUT=120` の具体的な実装箇所 | タイムアウト改修の正確な変更量 |
| 実装詳細 | Forge の `claude -p` サブプロセス分離状況 | コスト計算の前提（50K vs 5K オーバーヘッド） |
| 環境固有 | Windows Git Bash での mkdir チェックポイント動作 | チェックポイント実装の安定性 |
| 学術的限界 | JSON→JSON 意味変換の整合性評価に特化した実証研究 | coherence_checks 設計の信頼性 |
| 学術的限界 | ペアワイズ vs E2E 評価の精度/コストトレードオフ定量データ | 評価戦略選択の根拠 |

---

## 8. 参考文献（主要）

### 公式ドキュメント
- [Claude CLI Reference](https://code.claude.com/docs/en/cli-reference)
- [Claude Code Headless Mode](https://code.claude.com/docs/en/headless)
- [Claude API Rate Limits](https://platform.claude.com/docs/en/api/rate-limits)
- [Claude Pricing](https://platform.claude.com/docs/en/about-claude/pricing)

### 学術論文・研究
- NAACL 2025: Non-Determinism of Deterministic LLM Settings
- ContextualJudgeBench (ACL 2025): LLM judge の一貫性評価
- Agentics 2.0 (arXiv 2603.04241): 型付き transducible function composition
- Multi-Agent-as-Judge (Amazon Science 2025): 複数ジャッジ協調評価

### 実践ガイド
- [Anthropic: Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
- [G-Eval: The Definitive Guide](https://www.confident-ai.com/blog/g-eval-the-definitive-guide)
- [Evidently AI: LLM as a Judge](https://www.evidentlyai.com/llm-guide/llm-as-a-judge)
- [Claude Code Subagent Token Overhead Analysis](https://dev.to/jungjaehoon/why-claude-code-subagents-waste-50k-tokens-per-turn-and-how-to-fix-it-41ma)
