# Forge アーキテクチャ設計書 v3.2

**コードネーム:** Forge（鍛冶場）
**設計思想:** 確率論的な世界で、良いものを作れる確率を引き上げるための設計
**作成日:** 2026-02-12
**改訂日:** 2026-02-13（v3.2: Development System具体設計 + Investigator + テスト3層モデル + 全体ワークフロー明文化）
**ベース:** v1.3 research-loop.sh（765行）— 実証済み

---

## 変更履歴

| バージョン | 日付 | 変更内容 |
|-----------|------|---------|
| v3.0 | 2026-02-12 | V2の7機能→2システムへスコープ縮小。V1.3実装との整合性監査で10件修正 |
| v3.1 | 2026-02-12 | 外部参考文献15項目 + ハーネス自己発見22項目を統合。フィードバック収束設計・must_fix構造化・観測性拡張・サーキットブレーカー完全化・コンテキスト衛生強化 |
| v3.2 | 2026-02-13 | Development System具体設計。Investigatorエージェント新設。テスト3層モデル（確定的/条件付き/確率的）。implementation-criteria.jsonによるResearch→Development接続。Phase 2→Phase 1逆流パス。全体ワークフロー（Phase 0-4）明文化 |

---

## 目次

1. [設計原則](#1-設計原則)
2. [全体ワークフロー](#2-全体ワークフロー) ← v3.2新設
3. [システム構成](#3-システム構成)
4. [Research System パイプライン](#4-research-system-パイプライン)
5. [Development System パイプライン](#5-development-system-パイプライン) ← v3.2新設
6. [テスト3層モデル](#6-テスト3層モデル) ← v3.2新設
7. [Investigator — 失敗時ミニリサーチ](#7-investigator--失敗時ミニリサーチ) ← v3.2新設
8. [エージェント定義](#8-エージェント定義)
9. [フィードバック収束設計](#9-フィードバック収束設計)
10. [サーキットブレーカー](#10-サーキットブレーカー)
11. [観測性基盤](#11-観測性基盤)
12. [状態ファイルスキーマ](#12-状態ファイルスキーマ)
13. [ロードマップ](#13-ロードマップ)
14. [付録](#14-付録)

---

## 1. 設計原則

### 1.1 収束した5原則

v1.3の実装経験、v2の自己分析、7つの外部参考文献を横断して収束した設計原則。

| # | 原則名 | 由来 | v3.2での適用 |
|---|--------|------|-------------|
| 1 | **コンテキストは有限リソース** | masao.md「常時ロード最小化」, steipete原則1, Ralph「growing file problem」 | CLAUDE.md 50行以内。テンプレート注入量の上限定義。decisions注入を要約化 |
| 2 | **機械で守れることは機械に任せる** | masao.md「Hooksで品質固定」, ccpm「spec-driven」, claude-code-harness「2層スキルゲート」 | validate_json() 3層リカバリ。validate_schema() 新設。Layer 1テスト自動実行 |
| 3 | **フェールセーフに倒す** | Ralph「サーキットブレーカー」, Nishi「念のため確認は害」 | ABORT閾値。サーキットブレーカー外部化。繰越カウンタ。Investigatorによる失敗分析 |
| 4 | **状態はファイルに、判断はLLMに** | Ralph「static prompt, only completion flag changes」, Agent Teams「共有タスクリスト」 | --no-session-persistence。全状態をJSON/JSONL。LLMへの入力は毎回フレッシュ |
| 5 | **WHO（役割）とWHAT（タスク）を分離する** | v1.3実証済み。ccpm「エージェント定義」, claude-code-showcase「Skills定義」 | agents/*.md（役割のみ）+ templates/*-prompt.md（タスク指示のみ）。--system-prompt + stdin |

### 1.2 補助原則

| # | 補助原則 | 発見元 | 適用 |
|---|---------|-------|------|
| 5a | **フィードバックは収束させる** | DA自己確証バイアス発見（da-20260211-123640）| must_fix ID化。繰越カウンタ。balanced注入モード |
| 5b | **観測できないものは改善できない** | errors.jsonl 7→1改善の追跡不能 | validation-stats.jsonl。正規化段階記録。investigation-log.jsonl |
| 5c | **注入量は制御する** | Researcher 6並列×同一feedback = 6倍注入 | フィードバック圧縮。decisions要約注入。Synthesizer選択的読み込み |
| 5d | **検証手段は出力の性質で決まる** | v3.2壁打ち: テスト3層モデルの議論 | Layer 1（確定的）自動、Layer 2（条件付き）分離実行、Layer 3（確率的）人間判断 |
| 5e | **失敗は分類する。停止ではなく診断** | v3.2壁打ち: Investigator設計 | 3回失敗→Investigator起動。scope判定でタスク/基準/リサーチに分岐 |

---

## 2. 全体ワークフロー（v3.2新設）

### 2.1 Phase概観

```
Phase 0        Phase 1           Phase 1.5        Phase 2          Phase 3        Phase 4
人間の問い → Research System → 成功条件定義 → Ralph Loop → 統合検証 → 人間判断
              (SC→R→Syn→DA)    (3層分離)      (Layer 1自動)  (Layer 2)    (Layer 3)
                  │                                  │              │
                  │                                  │              │
                  └──── CONDITIONAL-GO ループ ────┘   └── FAIL ──→ Phase 2
                                                     │
                                            Investigator
                                            scope判定
                                               │
                                    ┌──────────┼──────────┐
                                    ▼          ▼          ▼
                                  "task"   "criteria"  "research"
                                 タスク修正  基準更新   Phase 1差戻し
```

### 2.2 Phase定義

| Phase | 名前 | 目的 | 品質ゲート | 実装状態 |
|-------|------|------|-----------|---------|
| 0 | 問いの設計 | 何を作りたいか / 何を調べたいかを決める | 人間の意思決定 | N/A（人間） |
| 1 | Research System | 「何を作るべきか」「どう作るべきか」を多角的に検証する | DAのverdict（確率的判定） | 実証済み（v1.3） |
| 1.5 | 成功条件定義 | リサーチ結果から3層の合格基準を導出する | 人間の承認 | v3.2設計 |
| 2 | Development System | 成功条件に基づいてコードを生成し、Layer 1で自動検証する | テスト実行（確定的判定） | v3.2設計 |
| 3 | 統合検証 | 個別タスクが通っても全体として動くか検証する | E2E / 実環境テスト（条件付き判定） | v3.2設計 |
| 4 | 人間判断 | ハーネスで判定できない部分を人間が判断する | Layer 3基準（確率的判定） | 将来 |

### 2.3 Phase間の接続

```
Phase 1 出力:
  ├→ final-report.md              （人間向けレポート）
  ├→ decisions.jsonl               （意思決定ログ）
  └→ implementation-criteria.json  （Phase 2への橋渡し）← v3.2新設

Phase 1.5 出力:
  └→ task-stack.json               （タスク分解 + 各タスクのvalidation定義）

Phase 2 出力:
  ├→ 実装コード
  ├→ テストコード（Layer 1 + Layer 2）
  └→ investigation-log.jsonl       （Investigator実行記録）← v3.2新設

Phase 3 出力:
  └→ integration-report.json       （統合検証結果）

Phase 4 出力:
  └→ decisions.jsonl に最終判断を記録
```

### 2.4 逆流パス（v3.2の核心）

通常フローは Phase 0→1→1.5→2→3→4 の順方向。v3.2では逆方向のパスを明示する。

| 逆流元 | 逆流先 | トリガー | 判定者 |
|--------|--------|---------|--------|
| Phase 1 (DA) | Phase 1 Stage 1 | NO-GO verdict | DA（自動） |
| Phase 1 (DA) | Phase 1 Stage 2 | CONDITIONAL-GO verdict | DA（自動） |
| Phase 2 (Investigator) | Phase 2 タスク修正 | scope: "task" | Investigator（自動） |
| Phase 2 (Investigator) | Phase 1.5 基準更新 | scope: "criteria" | Investigator（自動）+ 人間通知 |
| Phase 2 (Investigator) | Phase 1 リサーチ差戻し | scope: "research" | Investigator（自動）+ 人間通知 |
| Phase 3 | Phase 2 タスク追加 | Layer 2テスト失敗 | 自動 |
| Phase 4 | Phase 2 追加タスク | 人間の修正要求 | 人間 |
| Phase 4 | Phase 1 再リサーチ | 人間の方針転換 | 人間 |

---

## 3. システム構成

### 3.1 スコープ

```
┌──────────────────────────────────────────────────────────────────────┐
│                      Forge Harness v3.2                              │
│                                                                      │
│  ┌─────────────────────┐  ┌────────────────────────────────────────┐ │
│  │   Research System    │  │     Development System                 │ │
│  │   (実証済み v1.3)    │  │     (v3.2設計)                         │ │
│  │                     │  │                                        │ │
│  │  SC→R→Syn→DA→Loop  │  │  task-stack + ralph-loop               │ │
│  │                     │  │  + Layer 1/2テスト + Investigator      │ │
│  └─────────┬───────────┘  └──────────┬─────────────────────────────┘ │
│            │                         │                               │
│            │  implementation-        │                               │
│            │  criteria.json          │                               │
│            │  ─────────────────────▶ │                               │
│            │                         │                               │
│            │  ◀─── scope:"research"  │                               │
│            │       (Investigator)    │                               │
│            │                         │                               │
│  ┌─────────┴─────────────────────────┴─────────────────────────────┐ │
│  │              Shared Infrastructure                               │ │
│  │  state/ | agents/ | templates/ | config/ | Hooks                 │ │
│  └──────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 ディレクトリ構造

```
project-root/
├── CLAUDE.md                          # 常時ロード（50行以内）
├── .claude/
│   ├── settings.json                  # Hooks設定
│   ├── agents/                        # エージェント定義（WHO）
│   │   ├── scope-challenger.md
│   │   ├── researcher.md
│   │   ├── synthesizer.md
│   │   ├── devils-advocate.md
│   │   ├── implementer.md             # v3.2: Development System
│   │   └── investigator.md            # v3.2新設: 失敗時ミニリサーチ
│   ├── commands/
│   │   ├── research.md                # /sc:research — リサーチ開始
│   │   ├── plan.md                    # /plan — 計画立案
│   │   ├── work.md                    # /work — 実装開始
│   │   └── status.md                  # /status — 進捗確認
│   ├── skills/
│   │   ├── research/
│   │   │   └── SKILL.md
│   │   └── error-recording/
│   │       └── SKILL.md
│   └── rules/                         # パス固有ルール（最小限）
│       └── security.md
├── .docs/                             # 段階的開示ドキュメント
│   ├── index.md                       # 入口（自動更新）
│   ├── architecture.md                # 本設計書への参照
│   ├── decisions/
│   │   └── YYYY-MM-DD-topic.md
│   └── research/                      # リサーチ結果アーカイブ
│       └── YYYY-MM-DD-{id}-{HHMMSS}/
│           ├── final-report.md
│           ├── implementation-criteria.json  # v3.2新設
│           ├── stage-outputs/
│           └── logs/
├── .forge/                            # ハーネス本体
│   ├── config/
│   │   ├── research.json              # リサーチ設定
│   │   ├── development.json           # 開発設定（v3.2新設）
│   │   └── circuit-breaker.json       # サーキットブレーカー設定
│   ├── state/                         # 実行時状態（.gitignore）
│   │   ├── current-research.json      # Research System 状態
│   │   ├── feedback-queue.json        # フィードバック待ちキュー
│   │   ├── decisions.jsonl            # 意思決定ログ（append-only）
│   │   ├── errors.jsonl               # エラー記録（append-only）
│   │   ├── metrics.jsonl              # 観測性メトリクス
│   │   ├── validation-stats.jsonl     # JSON検証統計
│   │   ├── task-stack.json            # Development System 状態（v3.2具体化）
│   │   └── investigation-log.jsonl    # Investigator実行記録（v3.2新設）
│   ├── templates/                     # プロンプトテンプレート（WHAT — 静的）
│   │   ├── sc-prompt.md               # Scope Challenger タスク
│   │   ├── researcher-prompt.md       # Researcher タスク
│   │   ├── synthesizer-prompt.md      # Synthesizer タスク
│   │   ├── da-prompt.md               # Devil's Advocate タスク
│   │   ├── research-report.md         # レポートテンプレート
│   │   ├── implementer-prompt.md      # Implementer タスク（v3.2新設）
│   │   ├── investigator-prompt.md     # Investigator タスク（v3.2新設）
│   │   └── criteria-generation.md     # 成功条件生成テンプレート（v3.2新設）
│   ├── loops/
│   │   ├── research-loop.sh           # Research System オーケストレータ（765行）
│   │   ├── ralph-loop.sh              # Development System ループ（v3.2設計）
│   │   └── dashboard.sh               # メトリクス集約表示
│   └── logs/                          # 実行ログ（.gitignore）
│       ├── sessions/
│       ├── research/
│       └── development/               # v3.2新設
└── .gitignore                         # .forge/state/, .forge/logs/ を除外
```

V3.1からの差分:
- `.claude/agents/investigator.md` 新設
- `.claude/agents/implementer.md` 具体化（v3.1では将来扱い）
- `.forge/config/development.json` 新設
- `.forge/state/investigation-log.jsonl` 新設
- `.forge/templates/implementer-prompt.md` 新設
- `.forge/templates/investigator-prompt.md` 新設
- `.forge/templates/criteria-generation.md` 新設
- `implementation-criteria.json` リサーチ出力に追加

---

## 4. Research System パイプライン

v3.1から変更なし。詳細は v3.1 §3 を参照。

v3.2での唯一の追加: GOの場合、final-report.mdに加えて `implementation-criteria.json` を生成する。

### 4.1 implementation-criteria.json 生成（v3.2新設）

DAがGOを出した後、Synthesizerの出力を元に成功条件を3層で定義する。

```bash
generate_criteria() {
    local synthesis="$1"
    local report="$2"
    local output="$3"

    local prompt
    prompt=$(render_template ".forge/templates/criteria-generation.md" \
        "SYNTHESIS" "$(cat "$synthesis")" \
        "THEME" "$THEME")

    run_claude ".claude/agents/synthesizer.md" "$prompt" "$output"

    if validate_json "$output" "criteria-generation"; then
        log "INFO" "implementation-criteria.json 生成完了"
    else
        log "WARN" "implementation-criteria.json 生成失敗。手動作成が必要"
    fi
}
```

**生成タイミング:** DA verdict が GO の場合のみ。CONDITIONAL-GO中は生成しない。

---

## 5. Development System パイプライン（v3.2新設）

### 5.1 全体フロー

```
  implementation-criteria.json
          │
          ▼
  ┌───────────────────┐
  │ タスク分解          │ ← 人間 or LLM が task-stack.json を作成
  │ (Phase 1.5)        │
  └────────┬──────────┘
           │
           ▼
  ┌──────────────────────────────────────────────────────────┐
  │ Ralph Loop                                                │
  │                                                          │
  │  ┌──────────────────────────────────────┐                │
  │  │ 1. タスク選択                         │                │
  │  │    task-stack.json から最優先の         │                │
  │  │    未完了タスクを取得                   │                │
  │  └──────────┬───────────────────────────┘                │
  │             │                                            │
  │             ▼                                            │
  │  ┌──────────────────────────────────────┐                │
  │  │ 2. 実装 + Layer 1テスト作成           │                │
  │  │    Implementerがコードとテストを       │                │
  │  │    同一セッションで生成               │                │
  │  │                                      │                │
  │  │    WHO: agents/implementer.md        │                │
  │  │    WHAT: templates/implementer-prompt │                │
  │  └──────────┬───────────────────────────┘                │
  │             │                                            │
  │             ▼                                            │
  │  ┌──────────────────────────────────────┐                │
  │  │ 3. Layer 1 テスト実行（自動・毎回）    │                │
  │  │    コマンド: task.validation.layer_1   │                │
  │  │                                      │                │
  │  │    PASS → タスク完了マーク             │                │
  │  │    FAIL → fail_count++               │                │
  │  └──────┬───────────┬───────────────────┘                │
  │         │           │                                    │
  │      PASS        FAIL                                    │
  │         │           │                                    │
  │         │     fail_count < 3?                             │
  │         │      ┌────┴────┐                               │
  │         │    Yes          No                              │
  │         │      │           │                              │
  │         │      ▼           ▼                              │
  │         │   再実装    ┌──────────────────┐                │
  │         │   (ループ)  │ 4. Investigator  │                │
  │         │             │ (フレッシュ      │                │
  │         │             │  コンテキスト)    │                │
  │         │             └──────┬───────────┘                │
  │         │                    │                            │
  │         │              scope判定                          │
  │         │         ┌────────┼────────┐                    │
  │         │         ▼        ▼        ▼                    │
  │         │      "task"  "criteria" "research"              │
  │         │      タスク   基準更新   Phase 1                │
  │         │      修正              差戻し                   │
  │         │         │        │        │                    │
  │         │         ▼        ▼        ▼                    │
  │         │      再実装  criteria  research-loop            │
  │         │              更新     再実行                    │
  │         │                                                │
  │         ▼                                                │
  │  全タスクPASS → Phase 3（統合検証）へ                      │
  │                                                          │
  │  コンテキスト完全リセット（Ralph原則）: タスク間で毎回実行    │
  └──────────────────────────────────────────────────────────┘
```

### 5.2 ralph-loop.sh — 基本設計

```bash
#!/bin/bash
# .forge/loops/ralph-loop.sh — Development System オーケストレータ

set -euo pipefail

TASK_STACK=".forge/state/task-stack.json"
INVESTIGATION_LOG=".forge/state/investigation-log.jsonl"
CONFIG=".forge/config/development.json"

# 設定読み込み
MAX_TASK_RETRIES=$(jq -r '.max_task_retries // 3' "$CONFIG")
MAX_TOTAL_TASKS=$(jq -r '.max_total_tasks // 50' "$CONFIG")

task_count=0

while true; do
    # サーキットブレーカー
    if [ "$task_count" -ge "$MAX_TOTAL_TASKS" ]; then
        log "WARN" "タスク実行上限(${MAX_TOTAL_TASKS})到達。停止"
        break
    fi

    # 次の未完了タスクを取得
    local next_task
    next_task=$(jq -r '
        .tasks[] | select(.status == "pending" or .status == "failed")
        | select(.fail_count < '"$MAX_TASK_RETRIES"')
        | .task_id
    ' "$TASK_STACK" | head -1)

    # 全タスク完了チェック
    if [ -z "$next_task" ]; then
        local remaining
        remaining=$(jq '[.tasks[] | select(.status != "completed")] | length' "$TASK_STACK")
        if [ "$remaining" -eq 0 ]; then
            log "INFO" "全タスク完了。Phase 3（統合検証）へ"
            break
        else
            log "WARN" "未完了タスクあり(${remaining}件)だが実行可能タスクなし。Investigator要確認"
            break
        fi
    fi

    # タスク実行
    run_task "$next_task"
    task_count=$((task_count + 1))
done
```

### 5.3 run_task() — タスク実行の核

```bash
run_task() {
    local task_id="$1"
    local task_dir=".forge/logs/development/${task_id}"
    mkdir -p "$task_dir"

    # タスク情報を抽出
    local task_json
    task_json=$(jq --arg id "$task_id" '.tasks[] | select(.task_id == $id)' "$TASK_STACK")
    echo "$task_json" > "${task_dir}/task-definition.json"

    # 実装プロンプト生成
    local prompt
    prompt=$(render_template ".forge/templates/implementer-prompt.md" \
        "TASK" "$task_json" \
        "LAYER1_COMMAND" "$(echo "$task_json" | jq -r '.validation.layer_1.command')")

    # 実装実行（コード + テスト生成）
    local output="${task_dir}/implementation-output.txt"
    run_claude ".claude/agents/implementer.md" "$prompt" "$output"

    # Layer 1 テスト実行
    local test_command
    test_command=$(echo "$task_json" | jq -r '.validation.layer_1.command')

    if eval "$test_command" > "${task_dir}/test-output.txt" 2>&1; then
        # PASS
        update_task_status "$task_id" "completed"
        record_metric "task_complete" "$(jq -n --arg id "$task_id" '{task_id: $id, result: "pass"}')"
    else
        # FAIL
        local fail_count
        fail_count=$(jq --arg id "$task_id" '.tasks[] | select(.task_id == $id) | .fail_count' "$TASK_STACK")
        fail_count=$((fail_count + 1))

        # テスト出力を保存
        cp "${task_dir}/test-output.txt" "${task_dir}/fail-${fail_count}.txt"

        if [ "$fail_count" -ge "$MAX_TASK_RETRIES" ]; then
            # Investigator起動
            log "INFO" "タスク ${task_id} が ${fail_count}回失敗。Investigator起動"
            run_investigator "$task_id" "$task_dir"
        else
            # 再試行用に失敗カウント更新
            update_task_fail_count "$task_id" "$fail_count"
            log "INFO" "タスク ${task_id} 失敗(${fail_count}/${MAX_TASK_RETRIES})。再試行"
        fi
    fi
}
```

### 5.4 update_task_status() / update_task_fail_count()

```bash
update_task_status() {
    local task_id="$1"
    local new_status="$2"

    jq --arg id "$task_id" --arg s "$new_status" '
        .tasks |= map(if .task_id == $id then .status = $s | .updated_at = now | todate else . end)
    ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
}

update_task_fail_count() {
    local task_id="$1"
    local count="$2"

    jq --arg id "$task_id" --argjson c "$count" '
        .tasks |= map(if .task_id == $id then .fail_count = $c | .status = "failed" else . end)
    ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"
}
```

---

## 6. テスト3層モデル（v3.2新設）

### 6.1 3層の定義

| Layer | 判定性質 | 例 | 実行タイミング | 実行場所 |
|-------|---------|-----|--------------|---------|
| Layer 1 | **確定的**: 通る/落ちる | ユニットテスト、型チェック、lint、APIが200を返す | Ralph Loop内（毎タスク） | 自動 |
| Layer 2 | **条件付き**: 実環境依存 | E2Eテスト、投稿が実際に公開される、スケジュール実行 | Phase 3（Ralph Loop外） | 自動（重い・不安定） |
| Layer 3 | **確率的**: ビジネス判断 | フォロワー増加、エンゲージメント向上、ユーザー満足度 | Phase 4 | 人間 |

### 6.2 テスト作成のタイミング

steipeteの知見: 「同じコンテキスト内でテストを書かせる」。

```
Implementerの1回の実行で:
  ├→ 実装コード生成
  ├→ Layer 1テストコード生成（同一セッション内）
  └→ Layer 2テストコード生成（同一セッション内。実行はPhase 3で分離）
```

テストコードの作成は同一コンテキスト内で行い、実行タイミングだけをLayerで分離する。これにより、実装の文脈を最もよく理解している状態でテストが書かれる。

### 6.3 Layer別の設計判断

**Layer 1（Ralph Loop内）**
- 速度が最優先。1タスクあたり数秒〜数十秒で完了すること
- 決定的であること。同じ入力で毎回同じ結果
- 失敗時のエラーメッセージが原因特定に十分な情報を含むこと

**Layer 2（Phase 3）**
- 実行環境の準備が必要（テストアカウント、APIキー等）
- 外部サービスの状態に依存。結果が不安定な場合がある
- 失敗時はtask-stack.jsonにタスクとして戻す

**Layer 3（Phase 4）**
- ハーネスの守備範囲外。人間がimplementation-criteria.jsonのLayer 3基準を参照して判断
- 判断結果はdecisions.jsonlに記録

### 6.4 task-stack.json のvalidation定義

```json
{
  "task_id": "T-001",
  "description": "投稿APIクライアント実装",
  "status": "pending",
  "fail_count": 0,
  "validation": {
    "layer_1": {
      "type": "unit_test",
      "command": "npm test -- --filter=post-api",
      "timeout_sec": 60
    },
    "layer_2": {
      "type": "e2e",
      "command": "npm run test:e2e -- --filter=posting",
      "requires": ["TEST_API_KEY", "TEST_ACCOUNT"],
      "optional": true
    },
    "layer_3": {
      "type": "research_criteria",
      "ref": "implementation-criteria.json#layer_3",
      "description": "投稿が適切なタイミングで公開され、エンゲージメントが得られるか"
    }
  }
}
```

---

## 7. Investigator — 失敗時ミニリサーチ（v3.2新設）

### 7.1 設計思想

Phase 2でタスクが繰り返し失敗した場合、「なぜ失敗したか」を自動診断するエージェント。フレッシュなコンテキストで起動する（Ralph原則）。

**なぜフレッシュなコンテキストか:**
- 3回失敗した後のコンテキストは汚れている（Ralphの「ホワイトボードがノイズで埋まった状態」）
- 失敗を重ねたコンテキストの中で調査しても、同じ思考の轍にはまる
- 調査に必要な情報（タスク定義、コード、エラー出力）はファイルに落とせる

**なぜSkillではなくサブエージェントか:**
- 入力と出力が固定できない（毎回違う原因に到達する探索的タスク）
- Web検索やローカルファイル参照など、実装とは異なるツールセットが必要な場合がある

### 7.2 起動フロー

```
同一タスクが3回失敗
    │
    ├→ 失敗コンテキストをファイルに書き出し
    │   task-definition.json  — タスクの目的と検証条件
    │   fail-1.txt           — 1回目のエラー出力
    │   fail-2.txt           — 2回目のエラー出力
    │   fail-3.txt           — 3回目のエラー出力
    │   implementation-output.txt — 最新の実装出力
    │
    ├→ Investigator起動（フレッシュコンテキスト）
    │   WHO: .claude/agents/investigator.md
    │   WHAT: .forge/templates/investigator-prompt.md
    │   入力: 上記ファイル群のパス
    │   出力: investigation-result.json
    │
    └→ scope判定による分岐
        ├→ "task"     — タスク定義自体に問題。修正案を提示し、再実装
        ├→ "criteria" — implementation-criteria.jsonの前提が不正確。基準更新 + 人間通知
        └→ "research" — リサーチの前提が崩壊。Phase 1差戻し + 人間通知
```

### 7.3 run_investigator()

```bash
run_investigator() {
    local task_id="$1"
    local task_dir="$2"

    # 失敗コンテキストを集約
    local context_summary
    context_summary=$(cat <<EOF
## タスク定義
$(cat "${task_dir}/task-definition.json")

## 失敗履歴
### 1回目
$(cat "${task_dir}/fail-1.txt" 2>/dev/null | tail -50 || echo "(なし)")

### 2回目
$(cat "${task_dir}/fail-2.txt" 2>/dev/null | tail -50 || echo "(なし)")

### 3回目
$(cat "${task_dir}/fail-3.txt" 2>/dev/null | tail -50 || echo "(なし)")

## 最新の実装出力（末尾100行）
$(tail -100 "${task_dir}/implementation-output.txt" 2>/dev/null || echo "(なし)")
EOF
)

    # Investigatorプロンプト生成
    local prompt
    prompt=$(render_template ".forge/templates/investigator-prompt.md" \
        "FAILURE_CONTEXT" "$context_summary" \
        "TASK_ID" "$task_id")

    # フレッシュなコンテキストで実行
    local result="${task_dir}/investigation-result.json"
    run_claude ".claude/agents/investigator.md" "$prompt" "$result"

    if ! validate_json "$result" "investigator-${task_id}"; then
        log "ERROR" "Investigator出力のJSON検証失敗。手動確認が必要"
        record_metric "investigation_failed" "$(jq -n --arg id "$task_id" '{task_id: $id}')"
        return 1
    fi

    # scope判定
    local scope
    scope=$(jq -r '.scope' "$result")

    # investigation-log.jsonlに記録
    jq -c --arg id "$task_id" --arg s "$scope" --arg ts "$(date -Iseconds)" \
        '. + {task_id: $id, scope: $s, timestamp: $ts}' \
        "$result" >> "$INVESTIGATION_LOG"

    record_metric "investigation_complete" \
        "$(jq -n --arg id "$task_id" --arg s "$scope" '{task_id: $id, scope: $s}')"

    case "$scope" in
        "task")
            log "INFO" "Investigator判定: タスク修正。修正案を適用して再実装"
            local fix_suggestion
            fix_suggestion=$(jq -r '.recommendation' "$result")
            apply_task_fix "$task_id" "$fix_suggestion"
            ;;
        "criteria")
            log "WARN" "Investigator判定: 成功条件の前提に問題。implementation-criteria.json更新が必要"
            log "WARN" "理由: $(jq -r '.root_cause' "$result")"
            log "WARN" "推奨: $(jq -r '.recommendation' "$result")"
            # 人間通知（将来: Slack/メール連携）
            update_task_status "$task_id" "blocked_criteria"
            ;;
        "research")
            log "WARN" "Investigator判定: リサーチの前提が崩壊。Phase 1差戻し推奨"
            log "WARN" "理由: $(jq -r '.root_cause' "$result")"
            log "WARN" "推奨: $(jq -r '.recommendation' "$result")"
            # 人間通知（将来: Slack/メール連携）
            update_task_status "$task_id" "blocked_research"
            # Ralph Loop停止
            echo "RESEARCH_REMAND" > ".forge/state/loop-signal"
            ;;
        *)
            log "ERROR" "Investigator: 不明なscope '${scope}'。手動確認が必要"
            update_task_status "$task_id" "blocked_unknown"
            ;;
    esac
}
```

### 7.4 apply_task_fix() — タスク修正の適用

```bash
apply_task_fix() {
    local task_id="$1"
    local fix_suggestion="$2"

    # タスク定義にInvestigatorの修正提案を追加
    jq --arg id "$task_id" --arg fix "$fix_suggestion" '
        .tasks |= map(
            if .task_id == $id then
                .investigator_fix = $fix |
                .fail_count = 0 |
                .status = "pending" |
                .retry_after_investigation = true
            else . end
        )
    ' "$TASK_STACK" > "${TASK_STACK}.tmp" && mv "${TASK_STACK}.tmp" "$TASK_STACK"

    log "INFO" "タスク ${task_id} にInvestigator修正案を適用。fail_countリセット"
}
```

### 7.5 Investigatorの限界

Investigatorは万能ではない。以下の限界を認識した上で設計する。

| 限界 | 説明 | 対策 |
|------|------|------|
| 未知の未知 | 「何が分からないか分からない」状態は検出不能 | Phase 3/4での人間発見に依存 |
| scope判定精度 | "task" vs "criteria" vs "research" の分類を間違える可能性 | "criteria"と"research"は人間通知を必須とし、自動で破壊的変更を加えない |
| 調査範囲 | Web検索で到達できない情報（社内ドキュメント、有料API仕様等） | 人間がresearch差戻し後に手動で情報追加 |
| コスト | 失敗タスクごとにLLM 1回分のコスト | Investigator起動は3回失敗後のみ。不要な起動を避ける |

---

## 8. エージェント定義

### 8.1 WHO/WHAT分離の設計

| 層 | 格納先 | 内容 | ロードタイミング |
|----|--------|------|-----------------|
| WHO | `.claude/agents/*.md` | 役割・行動原則・制約 | `--system-prompt` で毎回注入 |
| WHAT | `.forge/templates/*-prompt.md` | タスク指示・入出力形式・プレースホルダ | render_template()でstdinへ |

### 8.2 Research System エージェント

v3.1と同一。Scope Challenger, Researcher, Synthesizer, Devil's Advocateの定義は v3.1 §4.2-4.5 を参照。

### 8.3 Implementer（実装担当）（v3.2新設）

```markdown
# .claude/agents/implementer.md

あなたはImplementerです。タスク定義に基づいて
コードとテストを実装することが役割です。

## 行動原則
1. タスク定義のdescriptionとvalidation.layer_1を最初に読み、
   「何を作るか」と「何をもって完了とするか」を理解する
2. 実装コードとLayer 1テストコードを同一セッション内で生成する
3. Layer 2テストコードも可能な限り同一セッション内で生成する
   （実行はPhase 3で分離される）
4. テストが通ることを確認してから完了とする
5. investigator_fixフィールドがある場合、その修正提案を優先的に適用する

## テスト作成の原則
- テストは実装コードの直後に書く（コンテキストが最も豊かな状態で）
- テスト名は「何を検証するか」を日本語コメントで明記する
- エッジケースを最低1つ含める

## 出力形式
実装コードとテストコードをファイルとして出力すること。
```

### 8.4 Investigator（失敗診断担当）（v3.2新設）

```markdown
# .claude/agents/investigator.md

あなたはInvestigatorです。繰り返し失敗したタスクの
根本原因を診断することが役割です。

## 行動原則
1. 失敗コンテキスト（タスク定義、エラー出力、実装出力）を注意深く読む
2. エラーの表面的な原因ではなく、根本原因を特定する
3. 根本原因がコードの問題か、前提条件の問題かを区別する
4. 必要に応じてWeb検索やローカルファイル参照で追加情報を収集する
5. 推測ではなく証拠に基づいて診断する

## scope判定基準
- "task": コードの実装方法に問題がある。タスク定義は正しい
  例: ロジックのバグ、APIの使い方の誤り、依存ライブラリの不足
- "criteria": implementation-criteria.jsonの前提が不正確
  例: 想定したAPIが存在しない、バージョン互換性の問題、
      ドキュメントに記載のない制限
- "research": リサーチで得た結論が現実と合わない
  例: 選定した技術が要件を満たせない、コスト前提が崩壊、
      競合サービスの仕様変更

## 出力形式
JSON形式でinvestigation-result.jsonを出力すること。

{
  "task_id": "T-XXX",
  "scope": "task | criteria | research",
  "root_cause": "根本原因の説明",
  "evidence": ["証拠1", "証拠2"],
  "recommendation": "推奨する次のアクション",
  "confidence": "high | medium | low"
}
```

---

## 9. フィードバック収束設計

v3.1と同一。詳細は v3.1 §5 を参照。

---

## 10. サーキットブレーカー

### 10.1 Research System サーキットブレーカー

v3.1と同一。詳細は v3.1 §6 を参照。

### 10.2 Development System サーキットブレーカー（v3.2新設）

```json
// .forge/config/circuit-breaker.json に追加
{
  "research_limits": { ... },
  "development_limits": {
    "max_task_retries": 3,
    "max_total_tasks": 50,
    "max_investigations_per_session": 5,
    "max_duration_minutes": 240,
    "task_timeout_sec": 600
  },
  "development_abort_triggers": [
    {
      "name": "investigation_limit",
      "description": "Investigator起動回数上限超過",
      "condition": "investigation_count >= max_investigations_per_session",
      "action": "pause_and_notify"
    },
    {
      "name": "research_remand",
      "description": "InvestigatorがPhase 1差戻しを判定",
      "condition": "loop-signal == RESEARCH_REMAND",
      "action": "stop_loop_and_notify"
    },
    {
      "name": "total_timeout",
      "description": "開発総時間上限超過",
      "condition": "elapsed_minutes >= max_duration_minutes",
      "action": "pause_and_notify"
    },
    {
      "name": "blocked_tasks_majority",
      "description": "過半数のタスクがblocked状態",
      "condition": "blocked_count > total_count / 2",
      "action": "pause_and_notify"
    }
  ]
}
```

**Research Systemとの違い:** Development Systemでは `abort` ではなく `pause_and_notify` を基本とする。コードが途中まで生成されている状態での強制終了は、手戻りが大きいため。

---

## 11. 観測性基盤

### 11.1 Research System 観測性

v3.1と同一。詳細は v3.1 §7 を参照。

### 11.2 Development System 観測性（v3.2追加）

| 計測項目 | 記録先 | 記録タイミング | 実装方法 |
|----------|--------|--------------|---------|
| タスク完了/失敗 | metrics.jsonl | タスク実行後 | run_task()内 |
| タスク実行時間 | metrics.jsonl | タスク完了時 | $SECONDS |
| Investigator起動回数 | metrics.jsonl | Investigator完了時 | run_investigator()内 |
| Investigator scope分布 | investigation-log.jsonl | Investigator完了時 | scope判定後 |
| Layer 1テスト成功率 | metrics.jsonl | テスト実行後 | run_task()内 |
| 全体進捗 | task-stack.json | タスク状態変更時 | update_task_status() |

### 11.3 ダッシュボード拡張

```bash
# dashboard.sh に追加

if [ -f .forge/state/task-stack.json ]; then
    echo ""
    echo "=== Development Metrics ==="
    echo ""

    echo "--- タスク進捗 ---"
    jq '
        .tasks | {
            total: length,
            completed: [.[] | select(.status == "completed")] | length,
            pending: [.[] | select(.status == "pending")] | length,
            failed: [.[] | select(.status == "failed")] | length,
            blocked: [.[] | select(.status | startswith("blocked"))] | length
        } |
        "完了: \(.completed)/\(.total)  待機: \(.pending)  失敗: \(.failed)  ブロック: \(.blocked)"
    ' .forge/state/task-stack.json
fi

if [ -f .forge/state/investigation-log.jsonl ]; then
    echo ""
    echo "--- Investigator統計 ---"
    jq -s '
        {
            total: length,
            scope_task: [.[] | select(.scope == "task")] | length,
            scope_criteria: [.[] | select(.scope == "criteria")] | length,
            scope_research: [.[] | select(.scope == "research")] | length
        } |
        "起動: \(.total)回  task: \(.scope_task)  criteria: \(.scope_criteria)  research: \(.scope_research)"
    ' .forge/state/investigation-log.jsonl
fi
```

---

## 12. 状態ファイルスキーマ

### 12.1 Research System スキーマ

v3.1と同一。decisions.jsonl, feedback-queue.json, current-research.json, metrics.jsonl, validation-stats.jsonl の定義は v3.1 §8 を参照。

### 12.2 implementation-criteria.json（v3.2新設）

Research SystemのGO出力として生成される。Development Systemへの入力。

```json
{
  "research_id": "YYYY-MM-DD-{id}-HHMMSS",
  "theme": "リサーチテーマ",
  "generated_at": "ISO8601",
  "layer_1_criteria": [
    {
      "id": "L1-001",
      "description": "投稿APIクライアントが正常にリクエストを送信できる",
      "test_type": "unit_test",
      "suggested_command": "npm test -- --filter=post-api"
    }
  ],
  "layer_2_criteria": [
    {
      "id": "L2-001",
      "description": "テストアカウントで実際に投稿が公開される",
      "test_type": "e2e",
      "requires": ["TEST_API_KEY", "TEST_ACCOUNT"],
      "suggested_command": "npm run test:e2e -- --filter=posting"
    }
  ],
  "layer_3_criteria": [
    {
      "id": "L3-001",
      "description": "投稿が適切なタイミングで公開され、エンゲージメントが得られるか",
      "evaluation_method": "1週間の運用後、インプレッション数とエンゲージメント率を測定",
      "success_threshold": "業界平均以上のエンゲージメント率"
    }
  ],
  "assumptions": [
    "対象SNSのAPIが現行バージョンで安定していること",
    "テストアカウントのレート制限が開発に十分であること"
  ]
}
```

### 12.3 task-stack.json（v3.2具体化）

```json
{
  "source_criteria": "implementation-criteria.json のパス",
  "created_at": "ISO8601",
  "updated_at": "ISO8601",
  "tasks": [
    {
      "task_id": "T-001",
      "description": "投稿APIクライアント実装",
      "depends_on": [],
      "status": "pending",
      "fail_count": 0,
      "investigator_fix": null,
      "retry_after_investigation": false,
      "validation": {
        "layer_1": {
          "type": "unit_test",
          "command": "npm test -- --filter=post-api",
          "timeout_sec": 60
        },
        "layer_2": {
          "type": "e2e",
          "command": "npm run test:e2e -- --filter=posting",
          "requires": ["TEST_API_KEY"],
          "optional": true
        },
        "layer_3": {
          "type": "research_criteria",
          "ref": "implementation-criteria.json#L3-001"
        }
      },
      "created_at": "ISO8601",
      "updated_at": "ISO8601"
    }
  ]
}
```

### 12.4 investigation-result.json（v3.2新設）

Investigatorの出力。investigation-log.jsonlにも追記される。

```json
{
  "task_id": "T-001",
  "scope": "task | criteria | research",
  "root_cause": "根本原因の説明",
  "evidence": [
    "エラー出力に 'RateLimitError' が3回とも出現",
    "APIドキュメントではfree tierで100 req/dayだが、テスト中に超過した可能性"
  ],
  "recommendation": "テスト環境にレート制限回避用のモックサーバーを導入する",
  "confidence": "high",
  "related_criteria": "L1-001",
  "suggested_task_changes": {
    "description": "投稿APIクライアント実装（モックサーバー使用）",
    "validation_update": "テスト時はモックサーバーに向ける"
  }
}
```

### 12.5 investigation-log.jsonl（v3.2新設）

```jsonl
{"task_id":"T-001","scope":"task","root_cause":"...","confidence":"high","timestamp":"..."}
{"task_id":"T-003","scope":"criteria","root_cause":"...","confidence":"medium","timestamp":"..."}
{"task_id":"T-005","scope":"research","root_cause":"...","confidence":"low","timestamp":"..."}
```

### 12.6 .forge/config/development.json（v3.2新設）

```json
{
  "model": "claude-sonnet-4-20250514",
  "max_turns": 5,
  "max_task_retries": 3,
  "max_total_tasks": 50,
  "investigator": {
    "model": "claude-sonnet-4-20250514",
    "max_turns": 5,
    "enable_web_search": true
  },
  "layer_2": {
    "auto_run_after_all_tasks": true,
    "fail_creates_task": true
  }
}
```

---

## 13. ロードマップ

### V3.1ロードマップ（Research System改善 — 維持）

#### Step 0: 観測性基盤の実装（最優先）

```
□ metrics.jsonl の記録関数を research-loop.sh に組み込む
□ 各ステージの実行時間計測（$SECONDS）
□ validate_json() 内に正規化段階の記録追加（validation-stats.jsonl）
□ サイクル完了時のサマリー記録
□ dashboard.sh の実装
□ ANTHROPIC_LOG=debug の実機検証（トークン記録の可否）
□ index.md 自動更新の実装
```

**完了基準:** dry-runを1回実行し、metrics.jsonl + validation-stats.jsonl にステージ別の実行時間・パース成功率・正規化統計が自動記録される。

#### Step 1: フィードバック収束 + 安全性強化

```
□ must_fix構造化（DA出力フォーマット変更 + jqフィルタ更新）
□ フィードバック注入モード実装（balanced モード）
□ フィードバック圧縮関数 compress_feedback() 実装
□ decisions.jsonl スキーマ改訂（decision_summary分離）
□ decisions注入上限 30→10 変更
□ Researcherテンプレートに {{DECISIONS}} 追加
□ config/research.json 外部化
□ config/circuit-breaker.json 外部化
□ validate_schema() 実装
□ プレフライトチェック実装
□ must_fix繰越カウンタ実装
□ Synthesizer事実突合タスク追加
```

**完了基準:** CONDITIONAL-GOループが「re-execution lottery」ではなく、具体的なmust_fixのIDベースで追跡可能。

#### Step 2: コンテキスト衛生 + エージェント強化

```
□ Researcher agent定義にローカルファイル参照を明記
□ Researcher agent定義にフィードバック受信時の行動原則追加
□ confidence: low 過半数時の警告ログ実装
□ Synthesizer action_summary 必須化
□ Synthesizer contradictions[] 出力追加
□ Researcher findings への source 必須化
```

**完了基準:** 2回目のリサーチで「ローカルファイル読み取り失敗」と「視点間事実不一致の見落とし」が発生しない。

### V3.2ロードマップ（Development System — 新設）

#### Step 3: Research→Development接続

```
□ criteria-generation.md テンプレート作成
□ implementation-criteria.json 生成関数実装
□ generate_criteria() を research-loop.sh の GO パスに組み込む
□ implementation-criteria.json のスキーマ検証
□ 手動でのtask-stack.json作成手順をドキュメント化
```

**完了基準:** リサーチGO後にimplementation-criteria.jsonが自動生成され、3層の成功条件が構造化されている。

#### Step 4: Ralph Loop基本実装

```
□ ralph-loop.sh 実装（タスク選択→実装→Layer 1テスト→結果記録）
□ implementer.md エージェント定義
□ implementer-prompt.md テンプレート作成
□ task-stack.json のCRUD関数群実装
□ Layer 1テスト実行の自動化
□ config/development.json 外部化
□ Development System サーキットブレーカー実装
□ 1タスクのend-to-end実行テスト
```

**完了基準:** task-stack.jsonに1タスクを定義し、ralph-loop.shが実装→テスト→完了マークの一連を自動実行できる。

#### Step 5: Investigator実装

```
□ investigator.md エージェント定義
□ investigator-prompt.md テンプレート作成
□ run_investigator() 実装
□ apply_task_fix() 実装
□ investigation-log.jsonl 記録実装
□ scope判定による3分岐（task/criteria/research）の実装
□ "criteria" / "research" 判定時の人間通知機構
□ Ralph Loop との統合テスト（意図的に失敗するタスクで検証）
```

**完了基準:** 意図的に3回失敗するタスクを作成し、Investigatorが起動→scope判定→適切な分岐が実行される。

#### Step 6: Phase 3統合検証

```
□ Layer 2テスト一括実行スクリプト
□ Layer 2失敗時のtask-stack.json差戻し
□ integration-report.json 生成
□ dashboard.sh へのDevelopment System統計追加
```

**完了基準:** 全タスクLayer 1通過後にLayer 2テストが一括実行され、失敗タスクが自動的にtask-stackに戻される。

---

## 14. 付録

### 14.1 V3.1→V3.2 差分一覧

| カテゴリ | V3.1（現行） | V3.2（目標） | 変更規模 |
|---------|-------------|-------------|---------|
| **全体ワークフロー** | 未定義 | Phase 0-4明文化 + 逆流パス | 新規 |
| **Development System** | 「設計開始」の1行 | ralph-loop.sh + task-stack.json + Layer 1/2/3 | 新規 |
| **Investigator** | 存在しない | agents/investigator.md + 3分岐scope判定 | 新規 |
| **テスト3層モデル** | 未定義 | Layer 1（確定的）/ Layer 2（条件付き）/ Layer 3（確率的） | 新規 |
| **implementation-criteria** | 存在しない | Research GO時に自動生成。3層の成功条件 | 新規 |
| **逆流パス** | Phase 1内のみ（DA→SC, DA→R） | Phase 2→Phase 1.5, Phase 2→Phase 1 追加 | 新規 |
| **サーキットブレーカー** | Research System のみ | Development System 追加（pause_and_notify） | 追加 |
| **観測性** | Research System のみ | investigation-log.jsonl + Development統計 | 追加 |
| **エージェント** | 4体（SC,R,Syn,DA） | 6体（+Implementer, Investigator） | 追加 |
| **テンプレート** | 5個 | 8個（+implementer, investigator, criteria-generation） | 追加 |
| **設計原則** | 5原則 + 3補助原則 | 5原則 + 5補助原則（5d, 5e追加） | 追加 |
| **Research System** | 変更なし | GO時にcriteria生成を追加（唯一の変更） | 小 |
| **CLAUDE.md** | 変更なし | 変更なし | なし |

### 14.2 外部参考文献との対応表（v3.2追加分）

| 参考文献 | 主要な知見 | V3.2での適用箇所 |
|---------|-----------|----------------|
| steipete 5原則 | 「同じコンテキスト内でテストを書かせる」 | §6.2 テスト作成タイミング。Layer 1/2コードは実装と同一セッション |
| Ralph | コンテキスト完全リセット | §7.1 Investigatorをフレッシュコンテキストで起動する根拠 |
| masao.md | Skill vs サブエージェントの判断軸 | §7.1 Investigatorがサブエージェントであるべき理由（探索的タスク） |
| v3.2壁打ち | テストは作りたいサービスごとに方法・基準が異なる | §6 テスト3層モデル。確定的/条件付き/確率的の分離 |
| v3.2壁打ち | 人間レビューは品質ゲートとして当てにできない場合がある | §7 Investigator。Phase 2内での自動診断。Phase 4への過度な依存を回避 |

### 14.3 全エージェント一覧

| エージェント | System | WHO | WHAT | 導入版 |
|-------------|--------|-----|------|--------|
| Scope Challenger | Research | agents/scope-challenger.md | templates/sc-prompt.md | v1.0 |
| Researcher | Research | agents/researcher.md | templates/researcher-prompt.md | v1.0 |
| Synthesizer | Research | agents/synthesizer.md | templates/synthesizer-prompt.md | v1.0 |
| Devil's Advocate | Research | agents/devils-advocate.md | templates/da-prompt.md | v1.0 |
| Implementer | Development | agents/implementer.md | templates/implementer-prompt.md | v3.2 |
| Investigator | Development | agents/investigator.md | templates/investigator-prompt.md | v3.2 |

---

**設計書終了**

本設計書はv1.3 research-loop.sh（765行）の実装コードとの整合性を維持。
Research Systemへの変更はGO時のcriteria生成追加のみ。
Development Systemは新規設計。全変更は.forge/内部ファイルとエージェント定義に閉じる。
CLAUDE.mdへの変更はゼロ。
