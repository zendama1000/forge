# 円卓会議エージェント MVP 最小仕様確定 — 最終リサーチレポート

**リサーチ ID**: `2026-05-18-d70590-004224`
**モード**: validate（ロック決定維持・未決論点の解決）
**生成日**: 2026-05-18

---

## 1. テーマと範囲

Claude Code サブスクリプション内で完結する円卓会議エージェント（人間1名 + AI 3体: **A1 推論系 / A2 創発系 / A3 構造系**）を `.claude/agents` + `.claude/commands` + `bash` の3点セットで対話的に実装する。設計書 `circular-table-council-design.md` をロック決定として尊重し、**未決7論点**を validate モードで解決して **MVP=1セッション完走** を満たす最小実装仕様を確定する。

### ロック決定（変更不可）

- 円卓 UX（人間=能動参加者、観察者ではない）
- Claude Code サブスクリプション内完結（外部 API 直接呼出禁止）
- `.claude/agents` + `.claude/commands` + `bash` 3点セット
- 3エージェント構成 A1/A2/A3
- 共通コア3項目（Toulmin / distance / uncertainty）
- 部分匿名化（agent_id と uncertainty_level は隠す、フレーム情報は表示）
- β+γ ハイブリッド状態管理（state.json + transcript.jsonl）
- セットα進行ルール（AI ターン数=2 固定）
- 出力先 `Desktop/enntaku-brain`
- MVP=1セッション完走
- 対話モード前提（`claude -p` モードはサブエージェントロード不可のため）

### 未決の7論点

1. state.json スキーマ
2. state-updater 実装方式
3. 議論終了条件
4. output.md 構造
5. A1/A2/A3 system prompt 設計
6. スラッシュコマンド設計
7. machine gate（フォーマット強制）+ 議題セットアップフロー

---

## 2. 視点別調査サマリー

固定4視点 + 動的2視点の計6視点で並列調査し、7論点すべてに対し Forge Harness の machine gate 哲学（**決定論的 / jq ベース / LLM compliance 最小化**）と整合する解が浮上した。

| 視点 | 焦点 | 結論の要旨 |
|---|---|---|
| **technical** | Claude Code 対話モード + Task ツール + bash + jq の実装可能性 | 4論点すべて実装可能。`validate_json` 3層リカバリ + `jq_safe` 流用が現実解 |
| **cost** | サブスクリプション枠内のトークン消費 / レートリミット | **state-updater の LLM 委任は Pro 枠の 57〜290% を消費し1セッション破綻**。pure jq 化が必須 |
| **risk** | 7論点の破綻シナリオと既知バグからの予防 | リトライ無限ループ($127→$47,000 事例)、Windows 非アトミック書込、identity bias の3点に集約 |
| **alternatives** | ロック範囲内での2-3案比較 | 5論点すべてで Forge machine gate 哲学準拠の案が最有力 |
| **human_in_the_loop_ux** | 人間が「参加」する対話 UX | サブコマンド方式 + 対話型 onboarding + frame=human パススルーで認知負荷最小 |
| **harness_pattern_transfer** | Forge 既存資産の転用可否 | `jq_lines` 無改変流用、`validate_json` 関数切り出し、`validate_locked_assertions` 骨格流用が可能 |

---

## 3. 論点別 最終判断

### 論点1: state.json スキーマ

**採用**: 軽量構造 + 6教訓を最初から実装。

| フィールド | 型 | 用途 |
|---|---|---|
| `schema_version` | string | 後方互換性管理（MVP は "v1" 固定） |
| `open_issues[]` | array | 未解決論点（重複排除あり） |
| `resolved_items[]` | array | 解決済み論点 |
| `turn_count` | number | ターン数（整数防御 `// 0 \| tonumber`） |
| `current_relay` | string | 次の発言者（A1/A2/A3/human） |
| `distance_trend[]` | array | distance 履歴 |
| `frame_history[]` | array | frame_main 履歴 |
| `status` | enum | pending / in_progress / completed / blocked |
| `updated_at` | ISO8601 string | stale 検出用 |

**Forge 実地バグからの6教訓**:
1. `schema_version` を最初から付与（task-stack.json で欠落 → 構造変更時に苦労）
2. 全数値フィールドに `// 0 | tonumber` の整数防御（2026-04-25 L1 timeout バグの再発防止）
3. 列挙型を網羅定義（stale `in_progress` 検出のため）
4. null と欠損を区別（`// [] // {} // null // "unknown"`）
5. 全 jq 読取に `tr -d '\r'`（Windows jq 1.7.1 CRLF 問題）
6. `updated_at` を全可変レコードに付与

### 論点2: state-updater 実装方式

**採用**: **(b) pure jq + ルールベース**（3視点で同時に最適評価）。

| 方式 | 機能 | 複雑度 | コスト | MVP適合 |
|---|---|---|---|---|
| (a) Task サブエージェント委任 | 高（意味的判定可） | 高 | **Pro 枠の 57〜290%** | 低 |
| **(b) pure jq + ルールベース** | 中（決定論的） | 低 | **実質ゼロ** | **高 ◎** |
| (c) ハイブリッド | 最高（拡張余地大） | 中 | 中 | 中 |

**根拠**:
- **cost**: 状態更新10〜15回で LLM 委任は Pro 枠（~44K tok/window）の 57〜290% を消費し1セッション破綻。pure jq なら実質ゼロ
- **alternatives**: jq は Safe / Deterministic / Declarative / LLM-friendly の4特性。Forge の `validate_json + .pending` パターンと完全一致
- **harness_pattern_transfer**: 状態更新は決定論的イベント（発言者交代・ターン増加・ステータス変更）で LLM 推論を要さない

**Fallback**: 意味的判定が必要になった場合のみ、`state-classifier agent`（Read-only）を Task ツール経由で呼ぶハイブリッド(c)へ部分移行。state-updater 関数を最初から「jq 部分 + LLM 部分」の2段階構造に設計。

### 論点3: 議論終了条件

**採用**: **(d) ターン数上限 OR /council end 人間宣言**。

| 案 | 評価 | 採否 |
|---|---|---|
| (a) ターン数上限のみ | 体験悪い（合意後も強制終了） | × |
| (b) 人間宣言のみ | ハードリミット不在、トークン枯渇リスク | × |
| (c) 自動収束判定 | **false-positive リスク高**（Synthesizer sycophancy → consensus illusion） | × |
| **(d) (a) OR (b)** | AutoGen / MS Agent Framework の事実上標準 | **◎** |
| (e) (a) OR (b) OR (c) | (c)の実装コストが MVP に不釣り合い | × |

**根拠（risk）**: arXiv 2509.23055 "Peacemaker or Troublemaker" — Synthesizer 役が sycophant 化すると `open_issues` クリアは consensus illusion の産物になる。自動収束は危険。

**ターン数上限デフォルト**: 10（設定可）。

### 論点4: output.md 構造

**採用**: **II+III ハイブリッド**（構造化サマリー + transcript ダンプ参照）。

LLM Council（llm-council.xyz）の業界実装パターン（result.json + transcript_path 分離）を参照。MVP では output.md 単一ファイル内で「上部=要約、下部=transcript 参照」の2層構造で開始。

**必須セクション**:
- `## 結論`
- `## 未解決論点`
- `## 論点別サマリー`
- `## 発言者分布`
- 末尾: `transcript.jsonl` への参照

### 論点5: A1/A2/A3 system prompt

各 `.md` システムプロンプト末尾に明記:

```
Return ONLY a valid JSON object with EXACTLY these fields:
{frame_main, frame_sub, claim_md, warrant_md, counter_md,
 distance, uncertainty_type, body_md}.
First character must be `{`, last must be `}`.
No explanation, no markdown, no preamble.
```

**Few-shot 例**: 1〜2例固定（cost: TTL 5分短縮で過剰例はトークン無駄）。

**identity bias / over-confident cascade 抑制（risk findings）**:
- 例内エージェントは **Agent-A / Agent-B 中性ラベル**化
- 自信表現（「明らかに」「間違いなく」「絶対に」）を例から**排除**
- **意見変更（counter_md で自説修正）を含む例を1件必須**

### 論点6: スラッシュコマンド設計

**採用**: サブコマンド方式 **`/council {start|say|pass|end}`**（CLI 業界標準 + Forge 名前空間規約と整合）。

| コマンド | 用途 | 実装ポイント |
|---|---|---|
| `/council start` | 議題セットアップ | 対話型ガイド質問 3〜5問 → topic.md 自動生成。`--file` でバイパス可 |
| `/council say` | 人間発言 | frame=human 固定 + 全文パススルー（claim_md 抽出は post-MVP） |
| `/council pass` | AI ターン進行 | **単一 skill.md 内で Task ツールで A1→A2→A3 を順次起動**。複数 slash コマンド連鎖は不可制約のため |
| `/council end` | 終了 + output 生成 | state.status="completed" + output.md 生成 |

`/show-state` `/undo` 等の細分化は post-MVP に倒す（`cat .forge/state/council.json` で代替可）。

### 論点7: machine gate

**採用**: **(a) JSON Schema + jq** + **(c) プロンプトテンプレ強制** の2層構造（業界コンセンサス）。

**実装**:
1. Forge `validate_json()` の3層リカバリ（CRLF除去 → コードフェンス除去 → ブレース抽出）をそのまま流用
2. 後段に `jq_safe -e '[.frame_main, .frame_sub, .claim_md, .warrant_md, .counter_md, .distance, .uncertainty_type, .body_md] | all(. != null)'` を追加
3. **リトライ上限3回** + **circuit breaker（連続3ターン失敗で /council end 提案）**
4. **必須フィールド欠落** → ターン skip + transcript に `schema_fail` 記録
5. **オプション欠落** → デフォルト補完 + `default_filled: true` フラグ付加

**根拠（risk）**: GPT-4 旧モデルではスキーマ強制なしでコンプライアンス率40%未満。再帰エージェントループで週 $127 → $47,000 に急騰した事例あり。3回リトライ + circuit breaker は業界慣行。

---

## 4. ロック決定との整合性

### 整合（10項目）

- `.claude/agents + .claude/commands + bash` 3点セットで7論点すべて実装可能
- state-updater pure jq → β+γ ハイブリッド state + harness 流儀と一致
- 終了条件 (d) → セットα「AI ターン数=2固定」と整合
- machine gate 2層 → 「harness 経験を直接転用」と整合
- `/council` サブコマンド方式 → Forge `/sc:` プレフィックス規約と整合
- transcript.jsonl append-only → decisions.jsonl と同型
- 出力先 `Desktop/enntaku-brain` → MEMORY.md「OneDrive 管理下での開発禁止」原則と整合
- 対話モード前提 → `claude -p` サブエージェント不可制約を回避
- Few-shot 1〜2例 + 中性ラベル + 自信表現排除 → Wu et al. 2025 過剰自信カスケード防止と整合
- MVP では Investigator 相当を実装せずリトライ+エラーメッセージで代替

### 矛盾と解決

| 矛盾 | 内容 | 解決 |
|---|---|---|
| risk ↔ ロック決定 | Choi et al. 2025: **部分匿名化は積極的に誤解を招き、完全パイプライン匿名化が必須**。ロックは部分匿名化 | validate モードのためロック維持。リスク緩和最大化（中性ラベル / 自信表現排除 / 意見変更例必須 / IBC 測定は post-MVP） |
| risk ↔ alternatives | 終了条件で risk は自動収束を明確否定、alternatives は post-MVP 拡張余地として言及 | MVP は (d) で完全一致。post-MVP は「自動終了」ではなく「人間への終了提案」として両懸念に同時対応 |
| cost ↔ ロック決定 | Max20 推奨（~$200/月）が現実的最小プラン示唆。ロックはプラン階層を指定せず | (a) AI ターン=2固定、(b) pure jq state、(c) transcript 20ターン上限 の組合せで Pro/Max5 でも 50〜80K tok 以内に収まる見込み |

---

## 5. 主要リスクと緩和策

| リスク | 緩和策 |
|---|---|
| **コスト爆発**（再帰ループで $127→$47K の事例） | リトライ上限3回 + circuit breaker + ターン skip + state に schema_fail 記録 |
| **state.json/transcript.jsonl 整合性破壊**（Windows EPERM、OneDrive sync 競合） | アトミック書込（tmp+mv）必須、起動時整合性チェック、OneDrive 管理外パス必須 |
| **identity bias / over-confident cascade**（部分匿名化の限界） | Few-shot 中性ラベル化 + 自信表現排除 + 意見変更例 1件必須 + IBC 実測 post-MVP |
| **Windows 環境固有問題**（jq 1.7.1 CRLF / `/tmp` 二重実体 / OneDrive） | `jq_lines()` 全 jq 読取に適用、`.council/` は OneDrive 管理外パス固定 |
| **1コマンド内 A1→A2→A3 順次 Task 呼出のタイムアウト** | 各 Task 呼出に明示的タイムアウト + リトライ + state.json 中間保存で復旧可能性担保 |
| **transcript 一括読込が 20ターン超で Max5 枠超過** | 20ターン上限を運用ガイドに明記、段階的サマリーは post-MVP |
| **新規 `run_subagent_via_task` 実装パターン未確定** | SDK ドキュメントが薄いため実装試行 → 実測ベースで調整 |

---

## 6. 横断的設計指針

- **新規ヘルパー** `run_subagent_via_task` が必要（`run_claude` は CLI -p 専用で流用不可）。Task 返値はメモリ上のため `.pending` 昇格は不要だが、JSON 回復ロジックは関数切り出しで流用
- **`validate_locked_assertions`** の骨格は流用、ただし JSON フィールド検証は `grep_present` で false positive リスクがあるため新型 `jq_path_exists` アサーション型を追加推奨
- **transcript.jsonl** は decisions.jsonl と同型 append-only。書込・読取両方に `tr -d '\r'` 必須
- **Windows 環境前提**: `jq_lines()` 無改変流用、`.council/` は OneDrive 管理外
- **セッション再開**: 軽量ログ保存のみ MVP に含め、フルステート復元は Phase 2-3 に倒す
- **Investigator 相当**: MVP 不要。将来拡張用フック（`handle_gate_violation` 等）をスタブで用意

---

## 7. 実装基準（Layer 別）

### Layer 1（単体検証）— 10基準

| ID | 概要 |
|---|---|
| L1-001 | state.json が schema_version + 8必須フィールド + 型 + enum 検証に通る |
| L1-002 | 全 jq 読取が CRLF 除去 + `// 0 \| tonumber` 整数防御を適用 |
| L1-003 | machine gate（validate_json 3層 + jq_safe 8フィールド検証）が決定的に動作 |
| L1-004 | state-updater が turn_count/relay/frame_history/status を pure jq で決定的更新 |
| L1-005 | transcript.jsonl が append-only かつ各行独立 JSON、CRLF 除去後に全件読込可 |
| L1-006 | `/council` スラッシュコマンドが必須サブコマンド4種を持ち禁止パターン不在 |
| L1-007 | A1/A2/A3 .md が JSON 出力強制 + 8フィールド明示 + 中性ラベル few-shot + 意見変更例 |
| L1-008 | circuit breaker（連続3ターン失敗で blocked）+ リトライ上限3回が機能 |
| L1-009 | `/council start` 対話型ガイド 3〜5問 → topic.md 生成、`--file` バイパス対応 |
| L1-010 | セッションディレクトリ `.council/session-YYYYMMDD-HHMMSS/` 4ファイル初期化 |

### Layer 2（統合 / E2E）— 5基準

| ID | 概要 |
|---|---|
| L2-001 | `/council pass` 1回で A1→A2→A3 Task 起動 + state/transcript 更新が E2E 動作 |
| L2-002 | `/council start → say → pass×2 → end` 1セッション完走 + II+III output.md 生成 |
| L2-003 | Pro/Max5 想定で 1セッション完走可（**累積トークン 80K 未満**） |
| L2-004 | Windows + jq 1.7.1 で CRLF/EPERM/OneDrive 競合なく動作 |
| L2-005 | Task ツール経由サブエージェント呼出のタイムアウト + リトライ復旧 |

### Layer 3（行動検証）— 6基準

| ID | 戦略 | 概要 |
|---|---|---|
| L3-001 | structural | state.json 8フィールドの型/enum/ISO8601 全条件検証 |
| L3-002 | structural | transcript 直近3 AI 発言が 8必須フィールド完備 |
| L3-003 | cli_flow | `/council` 4サブコマンド完全 CLI フロー → 4アーティファクト生成 |
| L3-004 | structural | output.md が5必須見出し + transcript 参照 + 500文字以上 |
| L3-005 | llm_judge | A1/A2/A3 のフレーム多様性 + 中性ラベル + 議論前進をスコア ≥0.7 |
| L3-006 | context_injection | human 発言が AI 次ターン counter_md/warrant_md/body_md に参照される |

---

## 8. フェーズ計画

| フェーズ | ゴール | 含む criteria | mutation 閾値 |
|---|---|---|---|
| **mvp** | `/council start → pass × 1 → end` 最小1セッション完走 + 4アーティファクト生成 | L1-001/005/006/007/009/010 | 0.4 |
| **core** | machine gate（8フィールド検証 + 3層リカバリ + リトライ3回 + circuit breaker）+ state-updater 主要ロジック | L1-002/003/004/008 | 0.3 |
| **polish** | Few-shot 精緻化 + output.md II+III ハイブリッド + エッジケース防御 | L1-007 | 0.2 |

---

## 9. 推奨アクション（Primary）

MVP を以下の最小仕様で実装する:

1. **ディレクトリ**: `.council/session-YYYYMMDD-HHMMSS/` 配下に `topic.md / transcript.jsonl / state.json / output.md`
2. **state-updater**: pure jq + ルールベース、LLM 委任ゼロ
3. **終了条件**: ターン数上限（デフォルト10、設定可）OR `/council end` 人間宣言
4. **output.md**: II+III ハイブリッド（上部サマリー + 下部 transcript 参照）
5. **A1/A2/A3 prompt**: 末尾に「Return ONLY JSON {8 フィールド}」明記 + 1〜2 例の中性ラベル few-shot
6. **スラッシュコマンド**: `/council {start|say|pass|end}` 1本サブコマンド方式。`/council pass` は単一 skill.md 内で Task ツール A1→A2→A3 順次起動
7. **machine gate**: `validate_json()` 3層リカバリ流用 + `jq_safe -e` 8フィールド検証 + リトライ3回 + circuit breaker + 必須欠落はターン skip + オプション欠落はデフォルト補完
8. **`/council start`**: 対話型ガイド 3〜5問 → topic.md 自動生成 + `--file` バイパス
9. **人間発言**: frame=human 固定 + 全文パススルー（claim_md 抽出は post-MVP）
10. **Forge 既存資産流用**: `jq_lines()` 無改変、`validate_json()` の JSON 回復ロジック関数切り出し、`validate_locked_assertions` 骨格 + 新型 `jq_path_exists` 追加、`record_transcript_entry` を decisions.jsonl パターンで実装

### Fallback（部分移行）

pure jq state-updater で複雑な状態遷移が記述困難になった場合、**ハイブリッド (c)** に部分移行:

- 状態の構造検証 / 数値カウント / ステータス遷移 → jq 継続
- エッジケース推論（open_issues の意味的重複判定 / resolved_items 抽出）のみ → Task サブエージェント（state-classifier agent）に委任
- state-classifier は **Read-only** 設計、JSON 返値のみ。bash 側で jq により state.json に統合

**トリガー**: (1) jq 表現が 50行超 / (2) frame_history の構造分析で jq 制約がボトルネック化 / (3) ユーザーテストで「状態が論点を取りこぼす」フィードバック3回以上。

---

## 10. ギャップと未確定事項

- Task ツールの prompt 文字列の最大長（トークン制限）が不明
- 1コマンド内 A1→A2→A3 順次実行の応答時間 / タイムアウト挙動が未実測
- `validate_json()` 内部のグローバル変数依存（`ERRORS_FILE` 等）の切り離しコストが不明
- Claude Code -p モードのトークン課金がサブスク枠に対しどう計上されるか不明
- JSONL `token_usage.input_tokens` の 100〜174倍過小計上バグの影響で実消費の事後計測が困難
- 部分匿名化 IBC 実測値（Choi et al. 2025 知見の実機影響度）は post-MVP 課題
- `run_subagent_via_task` ヘルパーの同期 / タイムアウト / リトライ設計は実装試行 → 実測ベース調整

---

## 11. 結論

5視点すべてで Forge Harness の **machine gate 哲学**（決定論的 / jq ベース / LLM compliance 最小化）と整合する解が浮上した。MVP は決定論的・機械的に検証可能なシンプル実装を優先し、収束検出・undo・Investigator・フルステート復元等の高度機能は post-MVP に留保する方針が evidence で支持される。撤退は実質的選択肢ではなく、Primary 推奨を実装し問題発生時に Fallback へ部分移行するのが合理的経路である。

**判定**: **GO**（validate モード、ロック決定 12項目すべてと整合、Phase 1.5 へ進行可）
