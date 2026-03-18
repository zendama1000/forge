# Forge Research Harness 設計書 v1.3

**作成日:** 2026-02-10
**最終更新:** 2026-02-11
**ステータス:** v1.3実装済み（フィードバック・チェーン + ABORT閾値）
**目的:** 自律的リサーチループによる意思決定品質の向上

---

## 1. 概要

### 1.1 何を解決するか

人間が手動でリサーチする際の品質上限を突破する。具体的には以下の問題を解消する。

| 問題 | 原因 | 本ハーネスの対策 |
|------|------|-----------------|
| 反論が弱い | 確証バイアス | Devil's Advocate（独立批判者） |
| 代替案が狭い | 知識の境界 | 固定4視点＋動的視点による多角的調査 |
| 根拠が浅い | 時間制約 | Researcher×(4+α)の並行情報収集 |
| 構造が散漫 | 整理不足 | Synthesizer（統合＋矛盾検出） |
| 文脈が消える | 会話間の断絶 | decisions.jsonl（累積的意思決定ログ） |

### 1.2 対象ドメイン

ツール選定、アーキテクチャ判断、市場調査、技術比較 ── ドメイン不問の汎用リサーチ。
初回テストケースはForge自体の設計判断（ブートストラップ）。

### 1.3 設計原則

本設計は以下の思想に基づく。

- **Ralph原則:** 各ステージは独立セッション。完全コンテキストリセット。状態はファイル経由で受け渡す
- **masao.md原則:** 常時ロード最小化、段階的開示、MCP不使用、Hooks/Skillで品質固定
- **Anthropic C Compiler原則:** テストが進行方向を決める、コンテキスト汚染を避ける、並列化は独立タスクが多数ある時のみ有効
- **ChainCrew原則:** Hooksによるコンテキスト注入、状態の外部化、品質ゲート

---

## 2. アーキテクチャ

### 2.1 4段階リサーチループ

```
人間: テーマ + 方向性/制約
  │
  ▼
① Scope Challenger（Opus, 検索なし）
  │ 問い分解 / 前提洗い出し / 過去決定チェック
  │ 調査の深さ・広さ・打ち切り条件を定義
  │ 固定4視点 + 動的視点（最大2）を決定
  │
  ▼
② Researcher × (4+α)視点（Sonnet, 組み込み検索）
  │ [固定] 技術的実現性
  │ [固定] コスト・リソース
  │ [固定] リスク・失敗モード
  │ [固定] 代替案・競合
  │ [動的] Scope Challengerが追加（最大2）
  │ 各視点は独立セッション（相互参照なし）
  │
  ▼
③ Synthesizer（Opus, 検索なし）
  │ 全レポート統合 / 矛盾検出 / 過去決定との整合
  │ 3段階推奨: 最推奨 / 次善 / 撤退
  │
  ▼
④ Devil's Advocate（Opus, 検索はSonnetサブエージェントに委譲）
  │ 前提攻撃 / バイアス検出 / 最悪シナリオ / 機会費用
  │ スコープ検証（浅すぎ？深すぎ？）
  │
  ├── GO → decisions.jsonl記録 → 完了
  ├── CONDITIONAL-GO → ②に戻る（最大3周）
  ├── NO-GO → ①に戻る（最大1回）
  └── ABORT → ループ停止 + 理由記録
```

### 2.2 ループ制御

| パラメータ | 値 | 理由 |
|-----------|-----|------|
| CONDITIONAL-GO最大周回 | 3 | 3周で改善しないなら構造的問題 |
| NO-GO最大周回 | 1 | 問いの再設計は1回で十分。2回以上はテーマ自体の問題 |
| ABORT | 即時停止 | コスト浪費防止。DAが自律判断 |
| Researcher視点数 | 4（固定）+ 0〜2（動的） | コストと網羅性のバランス |

#### フィードバック・チェーン（v1.3追加）

CONDITIONAL-GOループ時、DAのmust_fixフィードバックは以下の3エージェントに注入される。

| エージェント | 注入キー | 注入内容 | 目的 |
|-------------|---------|---------|------|
| Researcher | プロンプト末尾に追記 | must_fix配列 | 重点調査エリアの指示 |
| Synthesizer | `{{DA_FEEDBACK}}` | DA最新フィードバック全文 | feedback_response生成（修正状況の明示） |
| Devil's Advocate | `{{PREVIOUS_DA_FEEDBACK}}` | 前回verdict + must_fix番号付きリスト + 全文 | 前回指摘の修正検証（タスク0） |

これにより、DAの指摘がループ内で確実に追跡・修正される「フィードバック・チェーン」が形成される。

### 2.3 モデル配置とコスト最適化

```
                    判断の複雑さ    検索量    推奨モデル    理由
① Scope Challenger:    高          なし      Opus        問いの設計は高度な推論
② Researcher:          中          多い      Sonnet      テンプレ駆動の情報収集
③ Synthesizer:         高          なし      Opus        矛盾検出・統合は高度な推論
④ Devil's Advocate:    高          少し      Opus        批判的判断は最高品質が必要
   └─ DA検索委譲:       低          中        Sonnet      裏取りは単純作業
```

**コスト構造の核心:** 検索コスト（入力トークン膨張）の80%以上がSonnetセッションに集中する。
Opusセッション（SC, Syn, DA本体）では検索が走らないため、高い入力トークン単価の影響を最小化。

### 2.4 Web検索戦略

| ステージ | 検索 | 手段 | 理由 |
|---------|------|------|------|
| Scope Challenger | なし | — | 内部分析のみ。外部情報は先入観のリスク |
| Researcher | 集中的 | Claude Code組み込み検索 | 情報収集が本業。MCP不要でmasao.md整合 |
| Synthesizer | なし | — | 統合のみ。追加検索は役割逸脱 |
| Devil's Advocate | 限定的 | Sonnetサブエージェントに委譲 | 裏取り目的のみ。DA本体のOpusコンテキストを汚さない |

---

## 3. 各ステージ詳細

### 3.1 ① Scope Challenger

**モデル:** Opus  
**検索:** なし  
**入力:** 人間が提供するテーマ＋方向性/制約（ハイブリッド入力）  
**出力:** 構造化された調査計画

#### 責務

1. **問いの分解:** 曖昧なテーマを回答可能な問いに変換する
2. **前提の洗い出し:** 暗黙の仮定を明示化する（「本当にXは必要か？」）
3. **過去決定との照合:** decisions.jsonlを参照し、矛盾する過去決定がないか確認
4. **調査境界の定義:** 深さ・広さ・打ち切り条件を設定
5. **視点の割り当て:** 固定4視点＋動的視点（最大2、追加理由の明示が必須）

#### 動的視点の追加条件

動的視点はゲート付き。Scope Challengerは以下を満たす場合のみ追加できる。

- **差別化:** 固定4視点ではカバーできない観点であることを説明
- **必要性:** この視点がなければ意思決定に盲点が生じる理由を明示
- **上限:** 最大2。超える場合はテーマの分割を検討

#### 出力フォーマット

```json
{
  "investigation_plan": {
    "theme": "テーマ名",
    "core_questions": ["問い1", "問い2", "..."],
    "assumptions_exposed": ["前提1", "前提2"],
    "past_decision_conflicts": ["conflict1 or null"],
    "boundaries": {
      "depth": "どこまで深掘りするか",
      "breadth": "どこまで広げるか",
      "cutoff": "何が分かったら打ち切るか"
    },
    "perspectives": {
      "fixed": [
        {"id": "technical", "focus": "技術的実現性", "key_questions": ["..."]},
        {"id": "cost", "focus": "コスト・リソース", "key_questions": ["..."]},
        {"id": "risk", "focus": "リスク・失敗モード", "key_questions": ["..."]},
        {"id": "alternatives", "focus": "代替案・競合", "key_questions": ["..."]}
      ],
      "dynamic": [
        {"id": "dynamic_1", "focus": "...", "justification": "固定4視点との差別化理由", "key_questions": ["..."]}
      ]
    }
  }
}
```

### 3.2 ② Researcher

**モデル:** Sonnet  
**検索:** Claude Code組み込み検索（集中的に使用）  
**入力:** Scope Challengerの調査計画（該当視点部分のみ）  
**出力:** 視点別レポート

#### 責務

1. **情報収集:** 割り当てられた視点のkey_questionsに回答する情報を集める
2. **構造化:** テンプレートに従って発見を整理する
3. **独立実行:** 他の視点のレポートは参照しない（バイアス防止）

#### 実行方式

**Phase 1:** 順次実行（各視点は別セッション、完全コンテキストリセット）

```
SC出力 → R1(技術) → R2(コスト) → R3(リスク) → R4(代替案) → [R5(動的)] → [R6(動的)]
         ↑各セッション間でコンテキスト完全リセット（Ralph原則）
         ↑前のResearcherの結果は読まない（独立性担保）
```

**Phase 5以降:** 並列実行（Docker × N、Anthropic C Compiler方式）

#### 出力フォーマット

```json
{
  "perspective_report": {
    "perspective_id": "technical",
    "focus": "技術的実現性",
    "findings": [
      {
        "question": "調査した問い",
        "answer": "発見の要約",
        "evidence": ["情報源1", "情報源2"],
        "confidence": "high|medium|low",
        "caveats": ["注意点"]
      }
    ],
    "summary": "この視点からの総合所見",
    "gaps": ["調べきれなかった点"]
  }
}
```

### 3.3 ③ Synthesizer

**モデル:** Opus  
**検索:** なし  
**入力:** 全Researcherレポート＋Scope Challengerの調査計画＋decisions.jsonl  
**出力:** 統合レポート＋3段階推奨

#### 責務

1. **統合:** 全視点のレポートを横断的に分析
2. **矛盾検出:** 視点間で食い違う発見を特定（例: 技術的には容易だがコストが高い）
3. **過去決定との整合:** decisions.jsonlとの一貫性を検証
4. **3段階推奨の生成:**
   - **最推奨（Primary）:** 最も証拠が強い選択肢
   - **次善（Fallback）:** 最推奨が失敗した場合の代替
   - **撤退（Abort）:** 「やらない」選択肢

#### 出力フォーマット

```json
{
  "synthesis": {
    "theme": "テーマ名",
    "integrated_findings": "統合された分析",
    "contradictions": [
      {
        "between": ["perspective_id_1", "perspective_id_2"],
        "description": "矛盾の内容",
        "resolution": "解釈・優先判断"
      }
    ],
    "past_decision_alignment": {
      "aligned": ["一貫している過去決定"],
      "conflicts": ["矛盾する過去決定と理由"]
    },
    "recommendations": {
      "primary": {"action": "...", "rationale": "...", "risks": ["..."]},
      "fallback": {"action": "...", "rationale": "...", "trigger": "いつ切り替えるか"},
      "abort": {"rationale": "やらない理由", "opportunity_cost": "やらないことのコスト"}
    }
  }
}
```

### 3.4 ④ Devil's Advocate

**モデル:** Opus（検索はSonnetサブエージェントに委譲）  
**検索:** 限定的（裏取りのみ、Sonnetサブエージェント経由）  
**入力:** Synthesizerの統合レポート＋全Researcherの個別レポート（元データアクセス権）  
**出力:** Verdict＋フィードバック

#### 責務

1. **前提攻撃:** 推奨の根底にある前提を攻撃する
2. **バイアス検出:** 確証バイアス、生存者バイアス、権威バイアスを特定
3. **最悪シナリオ:** 推奨を実行した場合の最悪の結果を描く
4. **機会費用:** 推奨に時間/リソースを投じることで失われるものを算出
5. **スコープ検証:** 調査が浅すぎないか？深すぎないか？

#### 独立性の担保

- **プロンプトレベル:** 「Synthesizerの推奨に同意する義務はない。推奨を覆すことがあなたの仕事である」を明記
- **元データアクセス:** Researcherの個別レポートを直接読める。Synthesizerが都合よく統合している可能性を検証
- **検索の委譲:** 裏取りが必要な場合、DA自身は検索せずSonnetサブエージェントに委譲。DA本体のOpusコンテキストを清潔に保つ

#### Verdict定義

| Verdict | 意味 | 次のアクション |
|---------|------|---------------|
| GO | 推奨は十分な品質 | decisions.jsonl記録 → 完了 |
| CONDITIONAL-GO | 特定の追加調査/修正が必要 | ②Researcherに戻る（最大3周） |
| NO-GO | 問いの立て方自体に問題 | ①Scope Challengerに戻る（最大1回） |
| ABORT | リサーチ自体が不要/有害 | ループ停止 + 理由記録 |

#### 出力フォーマット

```json
{
  "devils_advocate": {
    "feedback_id": "da-YYYYMMDD-HHMMSS-{topic_hash}",
    "verdict": "GO|CONDITIONAL-GO|NO-GO|ABORT",
    "assumption_attacks": [
      {"assumption": "攻撃した前提", "weakness": "弱点", "impact": "覆された場合の影響"}
    ],
    "biases_detected": [
      {"type": "confirmation|survivorship|authority|...", "evidence": "根拠", "severity": "high|medium|low"}
    ],
    "worst_case_scenario": "最悪シナリオの記述",
    "opportunity_cost": "機会費用の記述",
    "scope_assessment": {
      "too_shallow": ["深掘りすべき点"],
      "too_deep": ["不要に深い点"],
      "missing": ["調査されていない領域"]
    },
    "feedback": {
      "must_fix": ["必須修正事項"],
      "should_fix": ["推奨修正事項"],
      "nice_to_have": ["あれば良い改善"]
    }
  }
}
```

---

## 4. 状態管理

### 4.1 ファイル構成

```
.forge/
├── state/
│   ├── decisions.jsonl          # 累積的意思決定ログ（全テーマ）
│   ├── feedback-queue.json      # DAフィードバック（ループ制御用）
│   ├── errors.jsonl             # 調査失敗ログ（ローテーションあり）
│   └── current-research.json    # 現在実行中のリサーチ状態
├── templates/
│   ├── scope-challenger-prompt.md
│   ├── researcher-prompt.md
│   ├── synthesizer-prompt.md
│   └── devils-advocate-prompt.md
├── loops/
│   └── research-loop.sh         # オーケストレーションスクリプト
└── logs/
    └── research/                # セッションログ

.claude/
└── agents/
    ├── scope-challenger.md
    ├── researcher.md
    ├── synthesizer.md
    └── devils-advocate.md

.docs/
└── research/
    ├── YYYY-MM-DD-{topic}/
    │   ├── investigation-plan.json    # SC出力
    │   ├── perspective-technical.json  # R出力
    │   ├── perspective-cost.json
    │   ├── perspective-risk.json
    │   ├── perspective-alternatives.json
    │   ├── perspective-dynamic-*.json  # 動的視点（0〜2）
    │   ├── synthesis.json              # Syn出力
    │   ├── devils-advocate.json        # DA出力
    │   └── final-report.md            # 人間向け最終レポート
    └── index.md                       # リサーチ一覧
```

### 4.2 decisions.jsonl

意思決定の累積ログ。全テーマ横断で蓄積し、Scope ChallengerとSynthesizerが過去決定との整合を確認する。

```jsonl
{"id":"d-20260210-001","theme":"Forge Research Harness設計","decision":"4段階ループ採用","rationale":"品質最優先の要件に対し、単一視点では確証バイアスが回避できない","alternatives_considered":["3段階(DA省略)","5段階(Pre-Research追加)"],"verdict":"GO","timestamp":"2026-02-10T08:00:00Z"}
```

### 4.3 feedback-queue.json

DAのフィードバック管理。verdict判定にはfeedback_idでフィルタする（`.queue[-1]`は使わない）。

```json
{
  "queue": [
    {
      "feedback_id": "da-20260210-080000-abc123",
      "source": "devils-advocate",
      "verdict": "CONDITIONAL-GO",
      "loop_count": 1,
      "must_fix": ["コスト試算の前提値が楽観的"],
      "timestamp": "2026-02-10T08:00:00Z"
    }
  ],
  "max_retained": 20
}
```

**verdict読み取り（安全な方法）:**

```bash
# ✗ 危険（最後のエントリが対象とは限らない）
VERDICT=$(jq -r '.queue[-1].verdict' feedback-queue.json)

# ✓ 安全（feedback_idでフィルタ）
VERDICT=$(jq -r --arg fid "$FEEDBACK_ID" \
  '[.queue[] | select(.feedback_id == $fid)] | last | .verdict' \
  feedback-queue.json)
```

### 4.4 errors.jsonl ローテーション

調査失敗（情報源アクセス不可、矛盾データ等）を記録。解決済みエントリはアーカイブする。

```bash
# 100行超過時のローテーション
MAX_ERRORS=100
if [ "$(wc -l < .forge/state/errors.jsonl)" -gt "$MAX_ERRORS" ]; then
  # resolution が non-null（解決済み）をアーカイブへ移動
  jq -c 'select(.resolution != null)' .forge/state/errors.jsonl \
    >> .forge/logs/research/errors-archive.jsonl
  # resolution が null（未解決）だけ残す
  jq -c 'select(.resolution == null)' .forge/state/errors.jsonl \
    > .forge/state/errors.jsonl.tmp
  mv .forge/state/errors.jsonl.tmp .forge/state/errors.jsonl
fi
```

#### ABORT暫定閾値（v1.3追加）

DAのABORT判定に加え、システムレベルの自動ABORTを導入。

| 条件 | 閾値 | アクション |
|------|------|-----------|
| 同一ループ内JSON検証失敗 | 3件以上 | 自動ABORT（`auto-abort-json-failures`） |
| DAのverdict | ABORT | 即時停止（既存） |

`json_fail_count`はwhileループ各イテレーション開始時にリセット。`validate_json()`内で失敗時にインクリメント。

---

## 5. オーケストレーション

### 5.1 research-loop.sh 概要

Ralph方式のbash whileループ。各ステージを別セッションで起動し、完全コンテキストリセットを保証する。

```bash
#!/bin/bash
# research-loop.sh - Forge Research Harness Orchestrator
# Usage: ./research-loop.sh "テーマ" "方向性/制約"

set -euo pipefail

THEME="$1"
DIRECTION="${2:-}"
TOPIC_HASH=$(echo "$THEME" | md5sum | cut -c1-6)
DATE=$(date +%Y-%m-%d)
RESEARCH_DIR=".docs/research/${DATE}-${TOPIC_HASH}"
STATE_FILE=".forge/state/current-research.json"
FEEDBACK_FILE=".forge/state/feedback-queue.json"

MAX_CONDITIONAL_LOOPS=3
MAX_NOGO_LOOPS=1
conditional_count=0
nogo_count=0

mkdir -p "$RESEARCH_DIR"

# ===== ① Scope Challenger =====
run_scope_challenger() {
  local PROMPT_FILE=".forge/templates/scope-challenger-prompt.md"
  local OUTPUT="${RESEARCH_DIR}/investigation-plan.json"
  local LOG=".forge/logs/research/sc-${DATE}-${TOPIC_HASH}.log"

  claude --model opus \
         --agent .claude/agents/scope-challenger.md \
         -p "$(cat "$PROMPT_FILE") THEME: $THEME DIRECTION: $DIRECTION" \
         --output "$OUTPUT" \
         &> "$LOG"
}

# ===== ② Researcher (順次実行) =====
run_researchers() {
  local PLAN="${RESEARCH_DIR}/investigation-plan.json"
  local PERSPECTIVES=$(jq -r '.investigation_plan.perspectives | (.fixed + .dynamic) | .[].id' "$PLAN")

  for PERSPECTIVE in $PERSPECTIVES; do
    local FOCUS=$(jq -r --arg p "$PERSPECTIVE" \
      '.investigation_plan.perspectives | (.fixed + .dynamic) | .[] | select(.id == $p) | .focus' "$PLAN")
    local QUESTIONS=$(jq -c --arg p "$PERSPECTIVE" \
      '.investigation_plan.perspectives | (.fixed + .dynamic) | .[] | select(.id == $p) | .key_questions' "$PLAN")
    local OUTPUT="${RESEARCH_DIR}/perspective-${PERSPECTIVE}.json"
    local LOG=".forge/logs/research/r-${PERSPECTIVE}-${DATE}-${TOPIC_HASH}.log"

    # 各Researcherは別セッション（Ralph原則: 完全リセット）
    claude --model sonnet \
           --agent .claude/agents/researcher.md \
           --allowedTools "web_search" \
           -p "$(cat .forge/templates/researcher-prompt.md) PERSPECTIVE: $FOCUS QUESTIONS: $QUESTIONS" \
           --output "$OUTPUT" \
           &> "$LOG"
  done
}

# ===== ③ Synthesizer =====
run_synthesizer() {
  local OUTPUT="${RESEARCH_DIR}/synthesis.json"
  local LOG=".forge/logs/research/syn-${DATE}-${TOPIC_HASH}.log"

  claude --model opus \
         --agent .claude/agents/synthesizer.md \
         -p "$(cat .forge/templates/synthesizer-prompt.md) RESEARCH_DIR: $RESEARCH_DIR" \
         --output "$OUTPUT" \
         &> "$LOG"
}

# ===== ④ Devil's Advocate =====
run_devils_advocate() {
  local FEEDBACK_ID="da-$(date +%Y%m%d-%H%M%S)-${TOPIC_HASH}"
  local OUTPUT="${RESEARCH_DIR}/devils-advocate.json"
  local LOG=".forge/logs/research/da-${DATE}-${TOPIC_HASH}.log"

  claude --model opus \
         --agent .claude/agents/devils-advocate.md \
         -p "$(cat .forge/templates/devils-advocate-prompt.md) RESEARCH_DIR: $RESEARCH_DIR FEEDBACK_ID: $FEEDBACK_ID" \
         --output "$OUTPUT" \
         &> "$LOG"

  # verdictをfeedback-queueに記録
  local VERDICT=$(jq -r '.devils_advocate.verdict' "$OUTPUT")
  local MUST_FIX=$(jq -c '.devils_advocate.feedback.must_fix' "$OUTPUT")

  jq --arg fid "$FEEDBACK_ID" \
     --arg v "$VERDICT" \
     --arg cc "$conditional_count" \
     --argjson mf "$MUST_FIX" \
     '.queue += [{"feedback_id": $fid, "source": "devils-advocate", "verdict": $v, "loop_count": ($cc|tonumber), "must_fix": $mf, "timestamp": now|todate}]' \
     "$FEEDBACK_FILE" > "${FEEDBACK_FILE}.tmp"
  mv "${FEEDBACK_FILE}.tmp" "$FEEDBACK_FILE"

  echo "$VERDICT"
}

# ===== メインループ =====
echo "[$(date)] Research started: $THEME"

# 初回: Scope Challenger
run_scope_challenger

while true; do
  # Researcher
  run_researchers

  # Synthesizer
  run_synthesizer

  # Devil's Advocate
  VERDICT=$(run_devils_advocate)

  case "$VERDICT" in
    "GO")
      echo "[$(date)] ✓ GO - Recording decision"
      # decisions.jsonlに記録
      jq -n --arg theme "$THEME" \
            --arg decision "$(jq -r '.synthesis.recommendations.primary.action' "${RESEARCH_DIR}/synthesis.json")" \
            --arg rationale "$(jq -r '.synthesis.recommendations.primary.rationale' "${RESEARCH_DIR}/synthesis.json")" \
            '{id: "d-\(now|strftime("%Y%m%d"))-\(now|todate|split("T")[1]|split(":")[0:2]|join(""))", theme: $theme, decision: $decision, rationale: $rationale, verdict: "GO", timestamp: (now|todate)}' \
            >> .forge/state/decisions.jsonl
      # 最終レポート生成（Opus）
      claude --model opus \
             -p "Generate a human-readable final report in Japanese from: ${RESEARCH_DIR}" \
             --output "${RESEARCH_DIR}/final-report.md" \
             &> /dev/null
      echo "[$(date)] ✓ Research complete"
      break
      ;;

    "CONDITIONAL-GO")
      conditional_count=$((conditional_count + 1))
      if [ "$conditional_count" -ge "$MAX_CONDITIONAL_LOOPS" ]; then
        echo "[$(date)] ✗ Max CONDITIONAL-GO loops reached ($MAX_CONDITIONAL_LOOPS)"
        echo "[$(date)] Recording best-effort result"
        break
      fi
      echo "[$(date)] ↻ CONDITIONAL-GO (${conditional_count}/${MAX_CONDITIONAL_LOOPS}) - Returning to Researcher"
      # ②に戻る（SCはスキップ）
      ;;

    "NO-GO")
      nogo_count=$((nogo_count + 1))
      if [ "$nogo_count" -ge "$MAX_NOGO_LOOPS" ]; then
        echo "[$(date)] ✗ Max NO-GO loops reached ($MAX_NOGO_LOOPS)"
        break
      fi
      echo "[$(date)] ↻ NO-GO (${nogo_count}/${MAX_NOGO_LOOPS}) - Returning to Scope Challenger"
      run_scope_challenger
      ;;

    "ABORT")
      echo "[$(date)] ✗ ABORT - Research deemed unnecessary/harmful"
      echo "[$(date)] Reason: $(jq -r '.devils_advocate.feedback.must_fix[0]' "${RESEARCH_DIR}/devils-advocate.json")"
      break
      ;;

    *)
      echo "[$(date)] ✗ Unknown verdict: $VERDICT"
      break
      ;;
  esac
done
```

**注意:** 上記は設計意図を示す擬似コード。Claude Codeの`--agent`、`--output`等のフラグは実装時に正式APIを確認する必要がある。

### 5.2 セッション間のデータフロー

```
① SC → investigation-plan.json → ②に渡す
② R  → perspective-*.json      → ③に渡す
③ Syn → synthesis.json          → ④に渡す
④ DA → devils-advocate.json    → ループ制御に使う
                                → feedback-queue.jsonに記録
                                → GOならdecisions.jsonlに記録
```

各セッションは**ファイルのみ**を介してデータを受け渡す。コンテキスト内にデータを蓄積しない（Ralph原則）。

---

## 6. Forge v2.0との統合

### 6.1 既存アーキテクチャとの関係

本リサーチハーネスはForge v2.0の**リサーチ部分のみ**を独立設計したもの。コーディング系（task-manager.sh、Red Team review等）とは分離して運用する。

```
Forge v2.0 全体構成:
├── コーディングハーネス（既存）
│   ├── task-manager.sh
│   ├── Red Team review
│   └── quality gates
└── リサーチハーネス（本設計）← ここが今回
    ├── research-loop.sh
    ├── 4段階ループ
    └── decisions.jsonl
```

### 6.2 共有するコンポーネント

| コンポーネント | 共有方法 |
|---------------|---------|
| decisions.jsonl | 共有。コーディング側の設計判断もここに蓄積 |
| feedback-queue.json | 共有フォーマット。sourceフィールドで識別 |
| errors.jsonl | 共有。ローテーション仕組みも共通 |
| .forge/templates/ | リサーチ専用テンプレートを追加 |
| .claude/agents/ | リサーチ専用エージェント定義を追加 |

### 6.3 Forge v2.0レビュー指摘事項の反映

| # | 指摘 | 対応 |
|---|------|------|
| #4 | errors.jsonl append-onlyで破綻 | ローテーション追加（§4.4） |
| #9 | Red Team独立性が不十分 | DAプロンプトで独立性明示＋元データアクセス権（§3.4） |
| #10 | verdict判定の`.queue[-1]`が脆弱 | feedback_idでフィルタ（§4.3） |

---

## 7. Phase計画

### Phase 1（現在の設計範囲）

- 4段階ループの順次実行
- 各ステージは手動起動（research-loop.shのテスト）
- decisions.jsonlへの記録開始
- 初回テスト: Forge自体の設計判断

### Phase 2

- research-loop.shの完全自動化
- エラーハンドリングの強化
- コスト計測の仕組み導入

### Phase 5以降

- Researcher並列実行（Docker × N）
- 動的視点の自動提案
- 複数リサーチの並行実行

---

## 8. 参考文献と設計根拠

| 参考 | 影響を受けた設計判断 |
|------|---------------------|
| Ralph（snarktank/ralph） | 完全コンテキストリセット、静的プロンプト、ファイル経由の状態管理 |
| masao.md | CLAUDE.MD最小化、段階的開示、MCP不使用、Hooks/Skill優先 |
| Anthropic C Compiler | 並列化戦略（独立タスクのみ）、テスト駆動の進行制御、コンテキスト汚染回避 |
| ChainCrew（ZAICO） | Hooks活用パターン、3層アーキテクチャ、品質ゲート設計 |
| Agent Teams（令和トラベル） | Red Team独立レビュー、write/broadcastパターン、エージェント間通信 |
| steipete（AIネイティブ5原則） | コンテキストは有限資源、エージェントは誘導が必要、サイクルを回す |

---

## 9. v1.2 dry-runレトロスペクティブ

### 9.1 成功した設計判断

| 判断 | 結果 |
|------|------|
| Ralph原則（独立セッション） | 各ステージが他のコンテキストに汚染されず、独立した品質を維持 |
| 固定4視点 + 動的視点 | テストテーマでも適切な視点分割が自動生成された |
| feedback-queue.json設計 | feedback_idフィルタにより安全なverdict読み取りが実現 |
| validate_json() 3層防御 | CRLF、コードフェンス、前後テキストの3種類の問題を段階的に処理 |

### 9.2 失敗/修正が必要だった判断

| 問題 | 根本原因 | 修正（v1.3） |
|------|---------|-------------|
| CONDITIONAL-GO「再実行ガチャ」 | DAフィードバックがResearcherのみに注入。SynとDA自身に未伝達 | フィードバック・チェーン（§2.2） |
| Researcherのスコープ膨張 | 計画遵守制約なし。自律的に問いを拡張 | 計画遵守制約追加（researcher.md） |
| CRLF汚染（Windows/Git Bash） | jqがCRLF出力。ファイル名・JSON双方に影響 | `tr -d '\r'` の網羅的追加 |
| ログファイル0バイト | `claude -p` は stderr に出力しない | `--debug-file` フラグに変更 |

### 9.3 DAの洞察

v1.2 dry-run中にDAが3回CONDITIONAL-GOを出した。各回のmust_fix項目を分析した結果、毎回異なる問題を指摘しており前回指摘の修正検証は一切行われていなかった。
これはDAが「新規批判マシン」として機能し「改善の検証者」として機能していなかったことを示す。v1.3のフィードバック・チェーンでこの構造的欠陥を修正する。

---

## 付録A: 決定事項ログ（本設計プロセス）

本設計書の作成過程で確定した判断の一覧。Claude Code環境構築後にdecisions.jsonlの初期データとなる。

| # | 決定事項 | 選択肢 | 選択 | 理由 |
|---|---------|--------|------|------|
| 1 | ループの複雑さ | 3段階/4段階/5段階 | 4段階 | 品質最優先。DA省略は確証バイアスのリスク |
| 2 | テーマ入力方式 | 完全自律/方向性付き/ハイブリッド | ハイブリッド | 初回は人間が方向性提示、ループ内は自律 |
| 3 | 視点の構成 | 固定のみ/動的のみ/固定+動的 | 固定4+動的最大2 | 安定性と柔軟性の両立 |
| 4 | ABORT判定 | 人間のみ/自律/なし | 自律 | コスト浪費防止。止める判断は重要 |
| 5 | モデル配置 | 全Opus/全Sonnet/混合 | 混合 | Researcher(情報収集)はSonnet、判断系はOpus |
| 6 | Web検索手段 | 組み込み/MCP/API Skill/併用 | 組み込みのみ | masao.md整合。MCP不要 |
| 7 | DA検索方式 | Opus直接/Sonnetサブ/検索なし | Sonnetサブに委譲 | DAのOpusコンテキストを清潔に保つ |
| 8 | Researcher実行 | 順次/並列 | Phase 1順次、Phase 5並列 | 型を固めてから並列化 |
| 9 | 動的視点上限 | なし/2/3 | 最大2 | コスト制御。追加理由の明示が条件 |
| 10 | verdict判定方法 | `.queue[-1]`/feedback_idフィルタ | feedback_idフィルタ | 並行書き込み耐性 |
| 11 | errors.jsonl管理 | append-only/ローテーション | ローテーション | 解決済みをアーカイブ、未解決のみ残す |
| 12 | 初回テストテーマ | — | Forge自体の設計判断 | ブートストラップ（自己参照） |
| 13 | 決定ログ開始時期 | 即時/環境構築後 | Claude Code環境構築後 | 正式なJSONL形式で蓄積開始 |
| 14 | 役割指示の外部化 | agent/heredoc/ハイブリッド | --system-prompt + テンプレート | WHO(役割)とWHAT(タスク)の分離。変更時に1ファイルのみ修正 |
| 15 | フィードバック・チェーン | Researcherのみ/全3エージェント | 全3エージェント | v1.2 dry-runでDAが毎回新規指摘のみ→修正検証不能の問題を解決 |
| 16 | Researcher計画遵守 | 自由探索/計画遵守 | 計画遵守 | key_questionsのみ調査。スコープ膨張を防止 |
| 17 | ABORT暫定閾値 | DAのみ/DA+システム | DA+システム | JSON検証失敗3件で自動ABORT。無限ループ防止 |

---

*本設計書は2026-02-10時点の確定事項を記録したものです。実装フェーズで得られた知見により更新されます。*
