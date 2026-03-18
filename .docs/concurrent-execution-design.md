# Forge Harness 並行実行（マルチプロジェクト）設計書

## 1. 現状分析

### 1.1 結論

Forge Harness v3.2 は **シングルプロジェクト・シーケンシャル実行** を前提とした設計。
並行実行のための排他制御・状態分離は一切存在しない。
ただし、変更箇所は局所的であり、改修の難易度は **中程度**。

### 1.2 有利な前提条件（既に実装済み）

| 既存機構 | 並行実行への寄与 |
|---|---|
| `--work-dir` パラメータ | ファイル変更先は既に分離可能 |
| `run_claude()` の `work_dir` 引数 | Claude CLI の実行ディレクトリを制御済み |
| リサーチディレクトリのタイムスタンプ命名 | `.docs/research/{date}-{hash}-{time}/` で事実上衝突しない |
| 各ループが独立プロセス（`nohup`） | OS レベルでは既に並行実行可能 |
| `RESEARCH_DIR` 変数によるセッション識別 | メトリクス/エラーに既にセッション情報が含まれる |

---

## 2. 衝突ポイント完全リスト

### 2.1 状態ファイル衝突（Critical — 並行実行で即データ破損）

以下の全ファイルが `.forge/state/` に固定パスで配置されており、2つのインスタンスが同時に読み書きすると破損する。

| ファイル | 定義箇所 | 用途 | 衝突の深刻度 |
|---|---|---|---|
| `task-stack.json` | forge-flow.sh:134, ralph-loop.sh:331 | タスク定義・状態の正本 | **致命的** — jq による read-modify-write が競合 |
| `current-research.json` | research-loop.sh:94 | リサーチ進捗状態 | **致命的** — ステータス上書き |
| `flow-state.json` | forge-flow.sh:269,285,379 | フェーズ進捗・resume 情報 | **致命的** — resume が別プロジェクトのデータを参照 |
| `forge-flow.log` | forge-flow.sh:143 | フロー全体のログ | 中 — 混在するが読めなくなるだけ |
| `loop-signal` | ralph-loop.sh:44 | RESEARCH_REMAND/APPROACH_PIVOT シグナル | **致命的** — 別プロジェクトのシグナルを誤読 |
| `heartbeat.json` | ralph-loop.sh:45 | デーモン監視用 | 低 — 上書きされるが機能は維持 |
| `progress.json` | common.sh:849 | リアルタイム進捗 | 低 — dashboard 表示が混在 |
| `errors.jsonl` | research-loop.sh:96, ralph-loop.sh:43 | エラー追記ログ | 中 — 追記は安全だがデータ混在 |
| `decisions.jsonl` | research-loop.sh:95 | 判断履歴 | 中 — 同上 |
| `investigation-log.jsonl` | ralph-loop.sh:42 | 調査ログ | 中 — 同上 |
| `metrics.jsonl` | common.sh:389 | パフォーマンス計測 | 低 — 追記、データ混在のみ |
| `validation-stats.jsonl` | common.sh:278 | JSON 修復統計 | 低 — 同上 |
| `lessons-learned.jsonl` | common.sh:295, ralph-loop.sh:151 | 過去の失敗パターン | 低 — 追記、クロスプロジェクトでむしろ有益 |
| `task-events.jsonl` | common.sh:366, ralph-loop.sh:155 | タスクイベントソーシング | 中 — session フィールドで区別可能だが混在 |
| `approach-barriers.jsonl` | ralph-loop.sh:145 | アプローチ限界記録 | 高 — セッション開始時にクリアされる |
| `research-config.json` | ralph-loop.sh:135 | locked decisions | 高 — プロジェクト固有データ |
| `integration-report.json` | phase3.sh:131 | Phase 3 統合テスト結果 | 高 — 上書き |
| `server.pid` | dev-phases.sh:308,317,371,381 | サーバープロセス管理 | **致命的** — 別プロジェクトのサーバーを kill |
| `phase-tests/*.sh` | generate-tasks.sh, dev-phases.sh:271 | dev-phase 回帰テスト | 高 — ファイル名が phase ID 依存（衝突可能性あり） |
| `checkpoints/` | common.sh:531 | Git checkpoint（task_id.patch 等） | 中 — task_id がユニークなら衝突しない |
| `notifications/` | common.sh:431 | 人間通知 | 低 — タイムスタンプ命名で衝突しにくい |

### 2.2 設定ファイル衝突（High — プロジェクト固有設定が共有）

| ファイル | 問題 |
|---|---|
| `development.json` → `server.start_command` | 1つしかない。プロジェクトAは `npm run dev` (port 3000)、プロジェクトBは `python manage.py runserver` (port 8000) などの共存不可 |
| `development.json` → `server.health_check_url` | 同上。ポート・パスがプロジェクト依存 |
| `development.json` → モデル/タイムアウト設定 | 共有でも問題ないが、プロジェクト別に変えたい場合がある |
| `circuit-breaker.json` → `protected_patterns` | プロジェクト固有の保護パターンが必要な場合がある |

### 2.3 ログディレクトリ衝突（Low — 混在するが壊れない）

| ディレクトリ | 問題 |
|---|---|
| `.forge/logs/research/` | ファイル名がタイムスタンプ＋ステージ名なので衝突しにくい |
| `.forge/logs/development/` | ファイル名が task_id 依存。task_id がプロジェクト間でユニークなら安全 |

### 2.4 排他制御不在（Critical）

- `flock` なし
- PID ファイルによるシングルトン保証なし
- `.lock` ファイルなし
- `mkdir` によるアトミックロックパターンなし
- `task-stack.json` の jq read-modify-write は非アトミック（`.tmp` + `mv` はあるが排他ではない）

---

## 3. 改修設計

### 3.1 アーキテクチャ方針

**セッション ID ベースの状態ネームスペース化** を採用する。

```
.forge/state/                      # 現在（フラット・共有）
.forge/state/{session_id}/         # 改修後（セッション別に分離）
```

- `session_id` = `{date}-{pid}` (例: `20260313-12345`)
- forge-flow.sh が生成し、下流（research-loop, generate-tasks, ralph-loop）に `--session-id` で伝搬

### 3.2 改修レイヤー

改修を3段階に分け、各段階で段階的に並行実行能力を獲得する。

---

#### Layer 1: 状態ディレクトリ分離（最小 MVP — これだけで並行実行可能）

**変更量: 小（5ファイル, 各数行）**

| ファイル | 変更内容 |
|---|---|
| **forge-flow.sh** | `SESSION_ID` 生成、`STATE_DIR=".forge/state/${SESSION_ID}"`、`--session-id` を下流に伝搬 |
| **research-loop.sh** | `--session-id` 引数受取、`STATE_FILE` / `ERRORS_FILE` 等のパスを `STATE_DIR` 基準に変更 |
| **ralph-loop.sh** | `--session-id` 引数受取、全 `.forge/state/` ハードコードを `STATE_DIR` 変数に置換 |
| **common.sh** | `VALIDATION_STATS_FILE`, `LESSONS_FILE`, `TASK_EVENTS_FILE`, `METRICS_FILE`, `NOTIFY_DIR`, `CHECKPOINT_DIR`, `PROGRESS_FILE` の初期化を `STATE_DIR` 変数に依存させる（`${STATE_DIR:-${PROJECT_ROOT:-.}/.forge/state}` 形式でフォールバック） |
| **generate-tasks.sh** | `phase-tests/` 出力先を `STATE_DIR` 内に変更 |

**具体的な変更イメージ:**

```bash
# forge-flow.sh（追加）
SESSION_ID="${SESSION_ID:-$(date +%Y%m%d)-$$}"
STATE_DIR=".forge/state/${SESSION_ID}"
mkdir -p "$STATE_DIR"
export SESSION_ID  # 子プロセスに伝搬

# forge-flow.sh（変更）
LOOP_SIGNAL_FILE="${STATE_DIR}/loop-signal"
TASK_STACK="${STATE_DIR}/task-stack.json"
FLOW_LOG="${STATE_DIR}/forge-flow.log"
```

```bash
# common.sh（変更 — フォールバック付き）
_STATE_DIR="${STATE_DIR:-${PROJECT_ROOT:-.}/.forge/state}"
VALIDATION_STATS_FILE="${_STATE_DIR}/validation-stats.jsonl"
LESSONS_FILE="${_STATE_DIR}/lessons-learned.jsonl"
TASK_EVENTS_FILE="${_STATE_DIR}/task-events.jsonl"
METRICS_FILE="${_STATE_DIR}/metrics.jsonl"
NOTIFY_DIR="${_STATE_DIR}/notifications"
CHECKPOINT_DIR="${_STATE_DIR}/checkpoints"
PROGRESS_FILE="${_STATE_DIR}/progress.json"
```

```bash
# ralph-loop.sh（変更 — STATE_DIR は bootstrap or --session-id で設定済み前提）
INVESTIGATION_LOG="${STATE_DIR}/investigation-log.jsonl"
ERRORS_FILE="${STATE_DIR}/errors.jsonl"
LOOP_SIGNAL_FILE="${STATE_DIR}/loop-signal"
HEARTBEAT_FILE="${STATE_DIR}/heartbeat.json"
APPROACH_BARRIERS_FILE="${STATE_DIR}/approach-barriers.jsonl"
LESSONS_FILE="${STATE_DIR}/lessons-learned.jsonl"
TASK_EVENTS_FILE="${STATE_DIR}/task-events.jsonl"
CANONICAL_TASK_STACK="${STATE_DIR}/task-stack.json"
```

**後方互換性:** `SESSION_ID` 未指定時は `STATE_DIR=".forge/state"` にフォールバック → 既存の動作を完全維持。

---

#### Layer 2: 設定オーバーライド（プロジェクト固有設定の分離）

**変更量: 中（3ファイル + 新設定スキーマ）**

`forge-flow.sh` に `--dev-config` パラメータを追加し、プロジェクト固有の `development.json` を指定可能にする。

```bash
# 使い方
forge-flow.sh "テーマ" "方向性" --work-dir /path/to/project \
  --dev-config /path/to/project/.forge-dev.json
```

**または:** criteria / research-config にプロジェクト固有のサーバー設定を埋め込む方式（MEMORY.md に既に候補として記録済み）。

| ファイル | 変更内容 |
|---|---|
| **forge-flow.sh** | `--dev-config` 引数パース、下流に伝搬 |
| **ralph-loop.sh** | `--dev-config` 受取、`DEV_CONFIG` パスを上書き |
| **dev-phases.sh** | `server.pid` のパスを `STATE_DIR` 内に変更（複数サーバー共存対応） |

**server.pid 問題（Layer 2 で必須修正）:**

現在 `.forge/state/server.pid` が固定パス。並行実行すると:
1. プロジェクトAのサーバー PID を記録
2. プロジェクトBが同パスに上書き
3. Phase 完了時にプロジェクトAが誤った PID を kill

```bash
# dev-phases.sh（変更）
local pid_file="${STATE_DIR}/server.pid"   # 現在: ".forge/state/server.pid"
```

---

#### Layer 3: 安全性強化（任意だが推奨）

**変更量: 小（2ファイル）**

| 機構 | 変更内容 |
|---|---|
| **二重起動検出** | forge-flow.sh 起動時に `STATE_DIR/forge.pid` を作成、終了時に削除。同一セッションIDでの重複起動を防止 |
| **ポート衝突検出** | preflight_check でサーバーポートが既に使用中でないか確認 |
| **セッション一覧** | `dashboard.sh --list` で全アクティブセッションを表示 |

```bash
# forge-flow.sh（追加）
PID_FILE="${STATE_DIR}/forge.pid"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "ERROR: セッション ${SESSION_ID} は既に実行中 (PID=$(cat "$PID_FILE"))" >&2
  exit 1
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT
```

---

## 4. 影響範囲の全ファイルリスト

### 変更が必要なファイル

| # | ファイル | Layer | 変更内容 |
|---|---|---|---|
| 1 | `.forge/loops/forge-flow.sh` | L1 | SESSION_ID 生成、STATE_DIR 設定、--session-id 伝搬 |
| 2 | `.forge/loops/research-loop.sh` | L1 | --session-id 受取、状態パス変数化 |
| 3 | `.forge/loops/ralph-loop.sh` | L1 | --session-id 受取、状態パス変数化 |
| 4 | `.forge/loops/generate-tasks.sh` | L1 | phase-tests 出力先を STATE_DIR に変更 |
| 5 | `.forge/lib/common.sh` | L1 | 状態ファイルパスの STATE_DIR 依存化 |
| 6 | `.forge/lib/dev-phases.sh` | L1+L2 | phase-tests 参照先・server.pid パス変更 |
| 7 | `.forge/lib/phase3.sh` | L1 | integration-report.json パス変更 |
| 8 | `.forge/lib/investigation.sh` | — | 変更不要（ralph-loop.sh の変数を参照するため自動追従） |
| 9 | `.forge/lib/evidence-da.sh` | — | 変更不要（同上） |
| 10 | `.forge/lib/mutation-audit.sh` | — | 変更不要（同上） |
| 11 | `.forge/lib/priming.sh` | — | 変更不要（状態ファイル不使用） |
| 12 | `.forge/lib/bootstrap.sh` | — | 変更不要 |
| 13 | `.forge/loops/dashboard.sh` | L3 | --list 対応、セッション別表示 |
| 14 | `.forge/state/phase-tests/run-regression.sh` | L1 | `PID_FILE` パスを STATE_DIR 基準に |

### 変更不要（自動追従）

- `investigation.sh` — ralph-loop.sh で定義した `$INVESTIGATION_LOG`, `$LOOP_SIGNAL_FILE`, `$APPROACH_BARRIERS_FILE` を参照するだけ
- `evidence-da.sh` — 同上
- `mutation-audit.sh` — 同上
- `priming.sh` — 状態ファイルを読み書きしない
- `.claude/agents/*.md` — エージェント定義は状態ファイルに依存しない

---

## 5. 追記ログファイルの扱い

`.jsonl` ファイル（追記専用）は2つの方針がある:

### 方針 A: 完全分離（推奨）
セッション別ディレクトリに配置。各セッションのデータが独立。
```
.forge/state/{session_id}/metrics.jsonl
.forge/state/{session_id}/errors.jsonl
```
- メリット: 完全な分離、クリーンアップ容易
- デメリット: クロスセッション分析に集約が必要

### 方針 B: 共有 + セッション ID タグ
既存の共有ファイルに追記し、各レコードに `session_id` フィールドを付加。
```
.forge/state/metrics.jsonl  ← 全セッション混在
  {"stage":"...", "session":"20260313-12345", ...}
```
- メリット: クロスセッション分析が容易
- デメリット: ファイル肥大化、クリーンアップ困難

**推奨: 方針 A。** `lessons-learned.jsonl` のみ方針 B（クロスプロジェクトの知見蓄積が有益）。

---

## 6. dashboard.sh の拡張

```bash
# セッション一覧表示
dashboard.sh --list
# 出力:
#   SESSION    STATUS   THEME               ELAPSED  TASKS
#   20260313-12345  running  占いサービス開発     23m      12/18
#   20260313-12350  running  ECサイト構築        5m       3/15

# 特定セッション指定
dashboard.sh --session 20260313-12345
```

---

## 7. リスク評価

| リスク | 確率 | 影響 | 対策 |
|---|---|---|---|
| 後方互換性の破壊 | 低 | 中 | `SESSION_ID` 未指定時のフォールバックで既存動作維持 |
| ポート衝突（サーバー） | 高 | 高 | Layer 2 で `--dev-config` によるポート分離必須 |
| Claude API レートリミット | 高 | 高 | 並行セッション数の上限を設定（例: 2-3） |
| ディスク使用量増加 | 中 | 低 | セッション完了後の自動クリーンアップ |
| テストの網羅性不足 | 中 | 中 | 既存テスト（test-ralph-functions.sh 等）に SESSION_ID 設定を追加 |

### 最大の実務リスク: Claude API レートリミット

並行実行で Claude CLI 呼び出しが2倍以上に増加する。Anthropic API のレートリミット（RPM/TPM）に到達する可能性が高い。

**対策候補:**
1. `MAX_CONCURRENT_SESSIONS` 設定（circuit-breaker.json に追加）
2. 並行実行時は片方を低優先モデル（Haiku）に切り替え
3. `forge-flow.sh` 起動時にアクティブセッション数をチェック

---

## 8. 実装優先度

| 優先度 | 項目 | 工数目安 | 効果 |
|---|---|---|---|
| **P0** | Layer 1: STATE_DIR ネームスペース化 | 2-3時間 | 並行実行の基盤（これだけで動作可能） |
| **P1** | Layer 2: server.pid 分離 | 30分 | サーバー kill 事故防止 |
| **P1** | Layer 2: --dev-config パラメータ | 1時間 | プロジェクト別サーバー設定 |
| **P2** | Layer 3: 二重起動検出 | 30分 | 安全性向上 |
| **P2** | Layer 3: dashboard --list | 1時間 | 可観測性向上 |
| **P3** | レートリミット対策 | 1-2時間 | 安定性向上 |

**最小実装（P0 のみ）で並行実行が可能。** P1 は安全なサーバー管理に必須。P2-P3 は運用品質の向上。

---

## 9. テスト計画

### 9.1 ユニットテスト（既存テストの拡張）

- `test-ralph-functions.sh`: `STATE_DIR` 設定済み環境で全関数テスト
- `test-validate-json.sh`: `STATE_DIR` 下のパスで validate_json テスト

### 9.2 並行実行 E2E テスト

```bash
# 2つのセッションを同時起動し、状態ファイルの分離を検証
SESSION_ID=test-a forge-flow.sh "テーマA" "方向A" --work-dir /tmp/project-a --daemonize &
SESSION_ID=test-b forge-flow.sh "テーマB" "方向B" --work-dir /tmp/project-b --daemonize &
wait

# 検証:
# 1. .forge/state/test-a/ と .forge/state/test-b/ が独立して存在
# 2. 各セッションの task-stack.json が互いのデータを含まない
# 3. server.pid が各セッションで別ファイル
# 4. dashboard.sh --list が2セッションを表示
```

---

## 10. まとめ

- **現状:** 並行実行不可。`.forge/state/` が全インスタンスで共有。
- **改修規模:** Layer 1（最小 MVP）で 5ファイル・各数行の変更。後方互換維持可能。
- **最大リスク:** Claude API レートリミットとサーバーポート衝突。
- **推奨:** Layer 1 + Layer 2（P0+P1）を一括実装。3-4時間で完了見込み。
