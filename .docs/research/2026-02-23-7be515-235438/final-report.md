# Evolve Harness v1 — 既存プロジェクト改善特化ハーネスの実装

> **リサーチID**: 2026-02-23-7be515-235438
> **DA判定**: **GO**
> **調査視点**: 6視点（技術的実現性 / コスト / リスク / 代替案 / 観測性 / プロジェクト多様性）

---

## 1. エグゼクティブサマリー

Evolve Harness v1 の実装は**技術的に実現可能**だが、**3つの構造的前提条件が未検証**のまま残存している。推奨は **Step 0 ゲート方式**による段階的実装で、3-5h の前提検証を経てから本体開発（25-35h）に進むことで、最大 40h の投資リスクを制御する。

### 主要結論

| 項目 | 結論 |
|------|------|
| 実装言語 | Bash（v1）。common.sh 97% 再利用可能、コスト対効果 4:1〜8:1 |
| エージェント構成 | 3 エージェントパイプライン（Analyzer→Planner→Reviewer） |
| 全体工数 | 30-43h（Step 0: 3-5h + Step 1-3: 27-38h） |
| API コスト | 通常 $2.16/イテレーション、ワーストケース $40.50（5イテレーション全リトライ） |
| 最大リスク | Forge ゼロ仮説未検証（95%CI: 9.4%-99.2%） |
| DA 判定 | GO（must_fix 0件、should_fix 2件、nice_to_have 3件） |

---

## 2. 調査計画

### 2.1 コア質問（5問）

1. **measurement_command の信頼性** — 自動メトリクス計測がどの範囲で信頼できる結果を返せるか
2. **外側ループの収束性** — Goal Evaluator 判定精度が低い場合の振動・偽完了リスク
3. **common.sh の適応戦略** — .forge→.evolve 変換の工数と課題
4. **analysis-loop のアーキテクチャ** — 3段パイプライン vs 単一セッション
5. **コスト・時間消費** — stalled 判定 + max_iterations(5) の実務上の影響

### 2.2 前提条件（10項目）

| ID | 前提 | 検証状況 |
|----|------|----------|
| A1 | 対象プロジェクトにテストスイートが存在する | **要フォールバック設計** — テスト不在時は静的解析のみモードが必要 |
| A2 | measurement_command は冪等かつ決定的 | **要検証** — idempotency 検証関数を Step 0 で確認 |
| A3 | 5回の Outer Loop で大半のゴール達成可能 | **根拠弱** — Self-Refine 論文は逓減収益を実証（改善の大部分はイテレーション 1-2） |
| A4 | 追加タスクが既存成果と矛盾しない | **リスクあり** — cyclic modification の研究知見あり |
| A5 | common.sh 適応は名前空間変更で十分 | **概ね正確** — 97% 再利用可能だが、40% に軽微〜中程度の修正が必要 |
| A6 | Bash + jq で十分な表現力 | **条件付き正** — JSON 規約付き出力なら十分、自由形式テキストでは不十分 |
| A7 | Plan Reviewer は DA ほどの厳密さ不要 | **リスクあり** — 同一モデルの疑似独立性問題 |
| A8 | Goal Evaluator は1回で全メトリクス判定可能 | **条件付き正** — summary 層の設計が必須 |
| A9 | E2E テストなしで品質担保可能 | **要注意** — Forge で同じ課題が指摘済み |
| A10 | measurement_command がタイムアウト内に完了 | **高リスク** — 10 分超テストで circuit-breaker 発動 |

### 2.3 過去決定との衝突

| 決定ID | 衝突内容 | 深刻度 | 対処 |
|--------|----------|--------|------|
| d-20260211-013350 | 観測性教訓が Evolve 仕様書に未反映（metrics.jsonl のみ） | 中 | metrics_record() にトークン概算・stop_reason 追加 |
| d-20260211-013350 | E2E テスト未カバー問題を Evolve でも繰り返すリスク | 低 | テスタブルなインターフェース設計で対応 |
| d-20260210-005 | エージェント毎モデル指定が仕様書に不在 | 低 | analysis.json / outer-loop.json にモデル設定追加 |

---

## 3. 視点別調査結果

### 3.1 技術的実現性

**信頼度: 高** | 主要リスク 3 点を特定

#### measurement_command の出力パース

**推奨**: 規約付き JSON 優先 + regex フォールバックの 2 段階

```
measurement_command → stdout
  ├─ JSON 出力 → jq でパース（推奨パス）
  ├─ テキスト出力 → grep -oP で数値抽出（フォールバック）
  └─ パース失敗 → LLM に解釈委譲（最終手段）
```

- jq は `jq empty` で構文検証、`-e` で存在確認、`//` でデフォルト値フォールバックが標準化されている
- Windows Git Bash では jq パース前に `tr -d '\r'` が必須

#### 非 JSON 出力の .pending 昇格問題

Forge で発見された根本原因（run_claude の .pending パターンが JSON 前提）に対し、3 アプローチを評価:

| アプローチ | 概要 | メリット | デメリット |
|-----------|------|----------|-----------|
| A: 二重出力規約 | テキスト + JSON ラッパー同時出力 | run_claude パターン維持 | LLM 出力制御依存 |
| **B: 明示的昇格** | 呼出元で .pending → 本ファイル手動コピー | **最小変更、Forge 対称性維持** | 呼出箇所ごとに記述が必要 |
| C: 出力タイプ引数 | `run_claude <prompt> <file> [json\|text]` | 最も設計的に明示的 | common.sh の変更必要 |

**推奨**: v1 ではアプローチ B（最小変更）、将来的にアプローチ C への移行を検討。

#### コンテキスト窓超過リスク

1000+ ファイルのプロジェクトで analysis-result.json は **50 万〜200 万トークン**に達する可能性あり（Claude 標準コンテキスト窓 200K）。

**対策**:
- summary / detail の 2 レベル構造を採用
- Planner には summary 層（優先度上位 50 ファイル）のみ渡す
- detail へは参照パスで誘導

#### 改善カテゴリの体系化（DA MF-001 対応）

| カテゴリ | 測定可能性 | 主要ツール | v1 スコープ |
|----------|-----------|-----------|------------|
| Security | Yes | Semgrep / Snyk / Bandit | **必須** |
| Readability | Yes | radon / SonarQube（循環的複雑度） | **必須** |
| Test Coverage | Conditional（テスト存在前提） | coverage.py / nyc / Jest | **必須** |
| Technical Debt | Yes | SonarQube SQALE | **必須** |
| Performance | Conditional（実行環境必要） | hyperfine / perf | 条件付き |
| Accessibility | Conditional（Web のみ） | Lighthouse / axe | 条件付き |
| Maintainability / Reliability | Yes | SonarQube | v2 以降 |

**デフォルト優先順位**: Security[BLOCKER] > Test Coverage > Performance[FAST FOLLOW] > Readability > Technical Debt[NIT]

#### measurement_command 副作用ミティゲーション（DA MF-002 対応）

3 層防御設計:

1. **git stash スナップショット**: `git stash push -u -m 'safety: before measurement'` → 実行 → `git stash pop`
2. **idempotency 検証**: 初回のみ 2 回実行、5% 以上の差異で WARN + human_check（`--verify-idempotency` で opt-in）
3. **--dry-run オプション**: measurement_command を実行せずコマンド文字列をログ出力

#### Windows CRLF 問題

Evolve でも**確実に再発**する高リスク箇所:

| 箇所 | リスク | 対策 |
|------|--------|------|
| measurement_command の stdout 取得 | `\r` 混入で jq パースエラー | `$(command \| tr -d '\r')` ラッパー関数 |
| ファイルからの値比較 | `[[ $status == 'done' ]]` 失敗 | `safe_capture()` を common.sh に追加 |
| シェバン行 | `/bin/bash\r: bad interpreter` で即死 | `.gitattributes` で `*.sh text eol=lf` 強制 |

---

### 3.2 コスト・リソース

**信頼度: 中〜高** | 全体工数 30-43h、API コスト $10-50/プロジェクト

#### 工数内訳

| カテゴリ | 項目 | 工数 | 比率 |
|----------|------|------|------|
| エージェント設計 | 5 新規エージェント × (agent.md + prompt.md) | 12.5h | 36% |
| スクリプト適応 | common.sh + ralph-loop.sh + outer-loop.sh | 9.5h（実質 11-14h※） | 32% |
| テスト・統合 | E2E オーケストレーター + ユニットテスト | 5-8h | 22% |
| **前提検証** | **Step 0 ゲート（Forge 検証 + 観測性 + 安全性）** | **3-5h** | **10%** |
| **合計** | | **30-43h** | |

> ※DA 指摘により、common.sh 適応は 1-2h → 3-5h に上方修正（run_claude/validate_json/metrics_record の実質修正を含む）

#### API コスト概算（Claude Sonnet 4.5: 入力 $3/M, 出力 $15/M）

| コンポーネント | 1 回あたり | 内訳 |
|---------------|-----------|------|
| Implementer | $0.165 | ~15K 入力 + ~8K 出力 |
| Goal Evaluator | $0.075 | ~10K 入力 + ~3K 出力 |
| Task Generator | $0.105 | ~10K 入力 + ~5K 出力 |

| シナリオ | 1 イテレーション | 5 イテレーション（max） |
|----------|-----------------|----------------------|
| 通常（12 タスク、リトライなし） | $2.16 | **$10.80** |
| ワーストケース（全タスク 3 回リトライ） | $8.10 | **$40.50** |

#### CI/ビルド時間の影響

| Layer 1 テスト時間 | 12 タスク実行 | 5 イテレーション合計 | circuit-breaker(240 分) |
|-------------------|-------------|---------------------|----------------------|
| < 1 分 | 12 分 | **110 分（1.8h）** | 完走可能 |
| 10 分 | 120 分 | **650 分（10.8h）** | **4h で発動、完走不能** |

**教訓**: Layer 1 テストを数秒〜数十秒スケールに収めることが設計上必須。

#### common.sh 適応のコスト対効果

```
346 行中:
├─ 直接再利用: 208 行（60%）— ログ、テンプレート、依存確認等
├─ 軽微修正: 138 行（40%）— パス変更 + run_claude/validate_json/metrics_record 拡張
└─ 不要関数: 0 行
→ 適応コスト 3-5h vs 新規作成 4-8h = コスト対効果 1.5:1〜2.5:1
```

---

### 3.3 リスク・失敗モード

**信頼度: 高** | 5 つの主要リスクカテゴリを特定

#### リスクマトリクス

| リスク | 深刻度 | 発生確率 | ミティゲーション |
|--------|--------|----------|---------------|
| **measurement_command 副作用**（DB 変更、ポート占有） | 致命的 | 中 | 3 層防御（git stash / idempotency / dry-run） |
| **Plan Reviewer NO-GO 復帰パス未定義** | 高 | 中 | 反復キャップ 3 回 + 人間エスカレーション |
| **regression breaker 誤判定**（一時的低下 vs 真の退行） | 中 | 高 | 複合メトリクス（数値 + 変更ファイル数） |
| **cyclic modification**（タスク間の打消し） | 中 | 低〜中 | 前イテレーション完了タスク一覧を参照 |
| **stalled 判定 false positive**（離散メトリクス） | 中 | 中 | 小数点以下精度保持 + 補助指標 |

#### Forge ゼロ仮説検証スキップ（DA MF-003 対応）

**統計的問題**: n=3, k=2 の GO 率 p̂=0.667

- **Clopper-Pearson 法 95% CI**: 9.4% 〜 99.2%（「GO 率が 9.4%」の可能性を排除できない）
- **損益分岐点**: P(Forge 劣位) > 11% なら検証する価値あり
- **検証コスト**: 2-3h + $5-20 API 代
- **Evolve 投資総額**: 27-40h

**結論**: Step 0 に Forge 簡易検証（2-3h）を組み込む。Go 判定後のみ Step 1 以降に進行。

---

### 3.4 代替案・競合

**信頼度: 高** | 4 つの比較軸を調査

#### 既存 CI/CD ゲートとの差別化

| 軸 | CI/CD ゲート | Evolve |
|----|-------------|--------|
| 測定層 | ルールに還元できる問題のみ | **ゴール宣言（自然言語）から LLM が測定戦略を動的設計** |
| 改善層 | pass/fail 判定のみ（ブロック機能） | **反復改善ループ** |
| セマンティック評価 | 修正コストの重み付き評価 | **可読性・設計品質の意味的評価** |

GitHub Agentic Workflows（2026-02 技術プレビュー）は概念的に同方向だが、現時点で機能重複は少ない。

#### 3 エージェント vs 単一エージェント

| 構成 | メリット | デメリット |
|------|----------|-----------|
| 3 エージェント | Anthropic 研究で 90.2% 性能向上 | トークン 15 倍、エラー伝播リスク |
| 単一エージェント | デバッグ容易、コスト低 | 深度不足 |
| **2 エージェント（推奨候補 v2）** | **バランス型** | **未検証** |

**v1 判断**: 3 エージェント採用。Plan Reviewer に「計画の最大の弱点を 3 つ特定せよ」等の強制反証探索指示を含め、疑似独立性問題を緩和。

#### 収束戦略の比較

| 戦略 | 概要 | 実装実績 |
|------|------|----------|
| **固定上限 + stalled 検知**（現行） | max_iterations=5, 2 イテレーション停滞で停止 | Forge で実績あり |
| スライディングウィンドウ改善率 | 直近 N 世代の改善量監視 | 最適化分野のみ |
| 曲率ベース停止 | 二次微分がゼロ近傍で停止 | 最適化分野のみ |
| 部分完了許容 | must-have / nice-to-have の 2 層分類 | 実装例なし |

**v1 判断**: 現行方式 + 複合メトリクス補助で開始し、実測データで判断。

#### Bash vs TypeScript/Python

| 観点 | Bash | TypeScript |
|------|------|-----------|
| Forge 知識再利用 | common.sh 直接利用 | 再実装 4-8h |
| 型安全性 | なし | ハルシネーション伝播防止 |
| CRLF / パス問題 | 固有の落とし穴あり | 解消 |
| エコシステム | Unix pipe composability | LangGraph 1.0（2025-10 安定版） |
| AI エージェント適合性 | Shell scripting +206% 成長（Octoverse） | Web スケールで優位 |

**v1 判断**: Bash。v2 以降で TypeScript 移行を検討（関数インターフェースを文書化）。

---

### 3.5 観測性・計測基盤

**信頼度: 高** | goal-progress.jsonl 単体では不十分

#### 追加すべきデータポイント（5 フィールド）

| フィールド | 用途 | カテゴリ |
|-----------|------|----------|
| `cost_usd` | 累積コスト可視化 | コスト |
| `token_breakdown` | input/output/cache 分解 | コスト |
| `metric_delta` | 前イテレーション比絶対変化 | 停滞検知 |
| `consecutive_no_improvement` | 連続非改善回数 | 停滞検知 |
| `iteration_duration_ms` | イテレーション所要時間 | 診断 |

#### Claude 呼び出し観測性（DA MF-004 対応）

ANTHROPIC_LOG=debug には**重大バグ 3 件**が確認済み:

| Issue | 内容 | 影響 |
|-------|------|------|
| #157 | stdout 汚染により SDK プロトコル破壊 | JSON パース失敗 |
| #16093 | 無限ログループで 200GB+ 消費 | ディスク枯渇 |
| #4859 | --debug/--verbose が stderr でなく stdout に出力 | 出力混入 |

**観測手段の優先順位**（Step 0 で検証）:

| 優先度 | 手段 | 取得可能データ |
|--------|------|---------------|
| 1（推奨） | OTel (`CLAUDE_CODE_ENABLE_TELEMETRY=1`) | duration_ms, input/output_tokens, cost_usd |
| 2 | `--output-format stream-json` | usage + stop_reason |
| 3（要検証） | `--debug-file` | 詳細ログ（バグ再現性確認後のみ） |
| 4（フォールバック） | `~/.claude/projects/` JSONL 事後解析 | usage フィールド |

#### measurement_command の記録設計

```
measurement_status（PASS/FAIL/TIMEOUT/ERROR）
   ×
metric_achieved（true/false/null）
```

- `measurement_status=ERROR, metric_achieved=null` → **計測不能**（Goal Evaluator に通知）
- `measurement_status=PASS, metric_achieved=false` → **メトリクス未達**（通常処理）
- `exit_code=124` → **TIMEOUT**（FAIL と区別して記録）

---

### 3.6 プロジェクト多様性への適応力

**信頼度: 高** | 3 つの核心課題を特定

#### テスト不在プロジェクトへのフォールバック

```
Code Analyzer: テスト不在を検出
  ├─ 静的解析のみモード（cyclomatic complexity, duplication, code smells）
  ├─ テストカバレッジ項目を N/A としてスキップ
  ├─ 動的品質指標（パフォーマンス、race conditions）は提案対象外
  └─ 改善提案に「テストスイート作成」を優先度高として含める（ブートストラップ戦略）
```

#### measurement_command 標準化の 3 層アーキテクチャ

| 層 | 役割 | 例 |
|----|------|-----|
| 検出層 | 言語・FW 自動検出 | package.json → Node.js / pyproject.toml → Python |
| アダプター層 | 言語別デフォルトテンプレート | `npm test` / `pytest` / `go test` |
| オーバーライド層 | プロジェクト固有設定 | ユーザー定義コマンド |

出力フォーマットは **SARIF（Static Analysis Results Interchange Format）** を採用し、下流処理を標準化。

#### monorepo / polyglot 対応

- **SARIF v2.1.0**（OASIS 標準）を基底スキーマとして採用
- 共通フィールド（言語横断） + 言語固有拡張フィールド（oneOf/anyOf）のハイブリッド構造
- SonarQube が 35+ 言語を単一フォーマットで処理している実績あり

---

## 4. 視点間の矛盾と解決

| 矛盾 | 視点間 | 解決 |
|-------|--------|------|
| 観測性の一次手段 | 観測性 vs 技術 | OTel を一次、--debug-file は三次（バグ検証後のみ） |
| 実装言語 | 代替案 vs コスト | v1 は Bash（97% 再利用）。v2 で TypeScript 検討 |
| 停滞判定 | リスク vs 技術 | 複合メトリクスに拡張（数値 + 変更ファイル数 + 新規テスト数） |
| analysis-result サイズ | 多様性 vs 技術 | SARIF ベース + summary/detail 2 層構造 |
| エージェントコスト | 代替案 vs コスト | 3 エージェント採用（analysis-loop は 1 回のみ、コスト影響限定） |
| ゼロ仮説検証 | cost/risk/alternatives vs roadmap | リサーチ結果を優先、Step 0 に検証組込み |

---

## 5. 推奨実装計画

### Step 0: 前提検証（3-5h）— Go/No-Go ゲート

| タスク | 内容 | 所要時間 | Go 条件 |
|--------|------|----------|---------|
| **(a) Forge ゼロ仮説検証** | 1 テーマで Forge vs Opus 直接投入を 5 軸 rubric で比較 | 2-3h | スコア > 8.0/25 |
| **(b) 観測性手段検証** | OTel / stream-json / --debug-file の動作確認 | 30 分-1h | いずれか 1 つ以上で token 情報取得成功 |
| **(c) measurement_command 安全性** | git stash ラッパー + idempotency 確認 | 30 分-1h | ラッパー正常動作、2 回実行で同一結果 |

### Step 1: 基盤構築（12-15h）— Step 0 全 PASS 後のみ

1. **リポジトリ作成・ディレクトリ構造**（1h）
2. **common.sh 適応**（3-5h）
   - .forge → .evolve パス変更
   - 観測性拡張（metrics_record に cost_usd, token_breakdown, stop_reason 追加）
   - safe_measure() ラッパー（git stash + timeout + status/achieved 分離）
   - safe_capture()（CRLF 対策）
3. **5 新規エージェント設計**（7-8h）
   - Code Analyzer(Sonnet), Improvement Planner(Opus), Plan Reviewer(Opus), Goal Evaluator(Opus), Task Generator(Opus)
   - v1 必須 4 カテゴリをプロンプトに明示
4. **設定ファイル**（1-2h）
   - analysis.json / outer-loop.json / circuit-breaker.json / development.json

### Step 2: ループ実装（8-12h）

1. **analysis-loop.sh**（3-4h）— 3 エージェントパイプライン、NO-GO 復帰パス（3 回差戻し→人間エスカレーション）
2. **ralph-loop.sh 適応**（2-3h）— --work-dir 必須化、while-case-shift パターン
3. **outer-loop.sh**（3-5h）— 5 サーキットブレーカー + 複合メトリクス停滞判定 + goal-progress.jsonl 5 フィールド追加

### Step 3: 統合・検証（5-8h）

1. **evolve-flow.sh** E2E オーケストレーター（2-3h）
2. **generate-tasks.sh 適応** + ベースライン測定（1-2h）
3. **dashboard.sh 拡張**（1h）— outer-loop メトリクス推移表示
4. **シェル関数ユニットテスト**（1-2h）

---

## 6. フォールバック・中止条件

### Step 0 不通過時の切替パス

| シナリオ | トリガー | 対応 |
|----------|----------|------|
| **A: Forge 検証 No-Go** | rubric スコア < 6.0/25 | Evolve 中止。Claude 直接利用パターンに切替 |
| **B: 観測性手段全不通過** | OTel・stream-json・JSONL 全滅 | リアルタイム観測を除去、バッチ事後解析にダウングレード |
| **C: 安全性確保困難** | git stash ラッパー失敗 or 10%+ 乖離 | measurement_command を read-only 操作のみに制限 |

### 中止条件（3 項目）

1. Forge ≤ 単体 Opus が証明された場合（基盤崩壊）
2. measurement_command の JSON パースが 50% 以上失敗する場合
3. common.sh 適応コストが新規作成コストを上回る場合（可能性低: 97% 再利用可能）

### 機会損失

Evolve 30-43h を以下に充当可能:
- **Forge Tier 1-3 ギャップ解消**（14h）— Research System 品質向上
- **x-auto-agent API 移行**（16-40h）— 運用リスク根本解消
- **Forge Development System 完成**（16h+）— ralph-loop/Investigator 完全実装

ただし Evolve は「**既存プロジェクト改善の自動化**」という代替不可能な価値提案を持つ。

---

## 7. DA（Devil's Advocate）評価

### 判定: **GO**

**must_fix 0 件** — 前回 DA フィードバック（MF-001〜004）はすべて解決済み。

### should_fix（2 件）

| # | 内容 |
|---|------|
| 1 | **E2E 受入テスト基準の具体化**: 対象プロジェクト候補 2-3 パターン、改善ゴール例、合格判定基準を定義すること |
| 2 | **circuit-breaker 発動後の状態回復手順**: 中断時 git stash 保全、goal-progress.jsonl に中断理由記録、再開時 continue/restart 選択可能にする引数設計 |

### nice_to_have（3 件）

| # | 内容 |
|---|------|
| 1 | common.sh 適応工数の上方修正（1-2h → 3-5h）を全体見積もりに反映 |
| 2 | Evolve 固有の Phase 0（壁打ち）ワークフロー概要設計 |
| 3 | 6 視点の gaps 31 件を一覧化し v1/v2/不要のトリアージ実施 |

### 前提攻撃

| 前提 | 弱点 | 影響度 |
|------|------|--------|
| common.sh 97% 再利用 | 実質 40% に修正必要（run_claude/validate_json/metrics_record） | 低（結論不変） |
| Step 0(a) 1 テーマ検証で十分 | n=1 は「明らかな失敗排除」でしかなく統計的有意性なし | 中 |
| 3 エージェントで品質保証 | 同一モデルのバイアス共有、分析品質チェック機構不在 | 中 |
| circuit-breaker で投資リスク制御 | 「停止する機構」であり「安全に停止する機構」ではない | 中 |

### 検出バイアス

| バイアス | 深刻度 | 内容 |
|----------|--------|------|
| アンカリング | 低 | Forge 実績（36/36 テスト）が Evolve 成功を予測する転移可能性は未検証 |
| 埋没コスト | 低 | common.sh 346 行への投資が Bash 継続の主要根拠に |
| **網羅性の幻想** | **中** | 7 セクションで網羅的に見えるが、6 視点合計 **31 件の未調査事項**が散在 |

### ワーストケースシナリオ

Step 0 全 PASS 後に 35h 投入。E2E 統合時に以下の複合障害:
1. Code Analyzer が summary 層でも 50K トークン超を出力 → Planner のコンテキスト圧迫
2. Plan Reviewer が同一モデルバイアスで分析品質問題を見逃し GO 判定
3. measurement_command の JSON 規約不遵守で regex フォールバックが 60% 失敗 → 5 イテレーション全て「計測不能」
4. circuit-breaker 発動後、回復手順未設計で変更が git 上に残留

**結果**: 40h + $10-50 消費、対象プロジェクトに未検証の変更が残留、手動復旧が必要。

---

## 8. 過去決定との整合性

### 整合（7 件）

| 決定 | 内容 | Evolve への適用 |
|------|------|----------------|
| d-20260210-001 | 4 段階ループ | analysis-loop 3 エージェントが踏襲 |
| d-20260210-003 | 固定 4 + 動的 2 視点 | 本リサーチの 6 視点構成で完全踏襲 |
| d-20260210-005 | 情報収集=Sonnet、判断=Opus | Analyzer=Sonnet、Reviewer/Evaluator=Opus |
| d-20260211-013350 | 観測性最優先 | metrics_record 拡張 + 5 フィールド追加 |
| d-20260211-123943 | Step 0 最優先 | Evolve Step 0 に Forge 検証組込み |
| d-20260211-212744 | Strangler Pattern | common.sh 適応（97% 再利用） |
| d-20260213-213837 | 要件再定義は人間判断 | Phase 0 壁打ちで改善カテゴリ明確化 |

### 衝突（3 件）

| 衝突 | 内容 | 対処 |
|------|------|------|
| d-20260211-013350 教訓未反映 | 観測性欠如が Evolve 仕様書に部分的にしか反映されていない | common.sh 適応時に metrics_record 拡張 |
| forge-gap-roadmap.md vs d-20260211-123943/212744 | ゼロ仮説スキップが Step 0 最優先の原則と矛盾 | リサーチ結果を優先、Step 0 組込み |
| d-20260210-005 未適用 | エージェント毎モデル指定が仕様書に不在 | analysis.json / outer-loop.json に追加 |

---

## 9. 未調査事項（31 件のうち主要なもの）

| 視点 | 未調査事項 | v1 影響度 |
|------|-----------|----------|
| 技術 | Claude SDK --debug-file の実際の出力形式 | **Step 0 で検証** |
| 技術 | コンテキスト分割戦略（chunking、CGRAG 等） | 中（大規模プロジェクト時） |
| コスト | Implementer/Evaluator のトークン消費実測データ | 中（推定値のみ） |
| コスト | outer-loop の実際の収束イテレーション数 | 中（実測必要） |
| リスク | Task Generator の cyclic modification 実例 | 低（理論的リスク） |
| 代替案 | 2 エージェント構成の実証データ | 低（v2 検討事項） |
| 代替案 | GitHub Agentic Workflows との将来的機能重複 | 低（2026-02 時点では重複少） |
| 観測性 | stop_reason の OTel 以外での確実な取得方法 | 中（stream-json で対応可能） |
| 多様性 | partial test suite の段階的フォールバック | 低（v1 では二値判定で十分） |

---

## 10. ソース一覧

### 学術論文・技術レポート
- Self-Refine: Iterative Refinement with Self-Feedback (arxiv 2303.17651)
- CORE: Resolving Code Quality Issues Using LLMs (ACM 2024, Microsoft)
- Hidden Costs of LLM-Based Code Optimization (ASE 2025)
- LLM vs SonarQube Code Quality Comparison (arxiv 2408.07082)

### 公式ドキュメント
- [Claude Platform - Context Windows](https://platform.claude.com/docs/en/build-with-claude/context-windows)
- [Claude Code - Monitoring Usage](https://code.claude.com/docs/en/monitoring-usage)
- [Claude API Pricing](https://platform.claude.com/docs/en/about-claude/pricing)
- [SARIF v2.1.0 Specification](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html)

### GitHub Issues
- [claude-agent-sdk-typescript #157](https://github.com/anthropics/claude-agent-sdk-typescript/issues/157) — ANTHROPIC_LOG=debug stdout 汚染
- [claude-code #16093](https://github.com/anthropics/claude-code/issues/16093) — --debug-file 無限ログ 200GB+
- [claude-code #4859](https://github.com/anthropics/claude-code/issues/4859) — stdout/stderr 混入

### 業界知見
- [Anthropic: Building Effective Agents](https://www.anthropic.com/research/building-effective-agents)
- [Anthropic: Multi-Agent Research System](https://www.anthropic.com/engineering/multi-agent-research-system)
- [GitHub: Agentic Workflows Technical Preview](https://github.blog/changelog/2026-02-13-github-agentic-workflows-are-now-in-technical-preview/)
- [Google Cloud: Agentic AI Design Patterns](https://docs.cloud.google.com/architecture/choose-design-pattern-agentic-ai-system)
