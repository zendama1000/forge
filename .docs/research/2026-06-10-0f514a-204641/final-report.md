# Fable 5 リリースに伴う Forge Harness 自己改修 — リサーチ最終レポート

**Research ID:** `2026-06-10-0f514a-204641`
**生成日:** 2026-06-10
**ブランチ:** `feature/self-refactor-fable5`
**モード:** validate（ロック決定の下での最適化）
**最終判定:** **GO（条件付き／着手前ゲート必須）**

---

## 1. エグゼクティブサマリー

全12エージェントを **Claude Fable 5（`claude-fable-5`）** に統一する前提で、ハーネスのプロンプト/エージェント定義・CLI オプション・タイムアウト・残存課題を再調整できるかを5視点で調査した。**validate モードの枠内で各視点は高い収束**を示し、以下4点が高確度の共通結論となった。

| # | 結論 | 確度 |
|---|------|------|
| 1 | **過剰指定の除去が最優先**。特に `reasoning_extraction` refusal を誘発する「思考過程をログ出力／推論を説明せよ」系記述の特定・除去 | high |
| 2 | **`--effort low/medium/high/xhigh/max` は正式 CLI フラグ**で `-p` 併用可。`run_claude()` への後方互換追加が可能 | high |
| 3 | **タイムアウトは effort 連動倍率**を既存の動的化実装（自己改修 #3）に載せるのが妥当 | high |
| 4 | **機械ゲート（assertions / l1_criteria_refs / validate_l1_file_refs）はプロンプト変更と独立**で整合性問題なし | high |

一方で **risk 視点は「強指示緩和による安全ゲート遵守低下」「ループ簡素化によるハルシネーション見逃し」「タイムアウト再有限化による kill ループ再発」を高確度で警告**。これらは validate モードかつ確証不足のため**今回バッチから除外し現状維持**とする。

> **本バッチで実装するもの:** ① 過剰指定/reasoning_extraction 除去 ② effort 別最適化 ③ タイムアウト effort 連動 ④ 残存課題は高優先のみ同梱
> **見送るもの:** ループ簡素化（リトライ/Investigator/DA 削減）、安全ゲートを支える強指示の緩和

---

## 2. 調査の前提と境界

### ロック決定（再検討対象外）
- 全12体の Fable 5 統一
- コスト2倍（$10/$50 per MTok）許容
- 成果物は実装変更（ドキュメントのみで止めない）
- `feature/self-refactor-fable5` で直接実行
- コアループは **bash + claude -p を維持**（Workflow 置換しない）

### コア質問（5問）
1. 13テンプレート・12エージェント定義のどの記述をどう再調整すべきか（過剰な強指示の緩和箇所）
2. CLI 新オプション（effort / fast mode）は `-p` で実機利用可能か、どう組み込むか
3. 残存課題4件の修正設計と優先順位、今回バッチの範囲
4. ループ構造を保守的に簡素化できる余地はあるか
5. 各エージェントのタイムアウトを見直す必要があるか

---

## 3. 視点別の主要知見

### 3.1 技術的実現性（technical）— confidence: high

| 論点 | 結論 |
|------|------|
| 強指示の grep 特定・緩和 | 実行可能。公式が「旧モデル向けスキルは Fable 5 に過剰指定で品質を下げうる」と明言。問題は (a) 推論再現・説明を要求する指示、(b) 高 effort で過剰探索を促す指示の2パターン |
| 機械ゲートとの整合 | 整合。3種ゲートはすべてファイル/JSON 層で動作しプロンプトと独立 |
| `--effort` 後方互換追加 | 可能。`run_claude()` 第8引数 `work_dir` 追加と同形で実装可。未指定時はデフォルト適用で非破壊 |
| タイムアウト | Fable 5 は応答時間が大幅増（高 effort で数分〜数時間）。effort 連動倍率（例 low:1x / medium:2x / high:4x / xhigh:8x）が現実的 |

**最大工数:** 13テンプレートの grep → 過剰指定の精査 → reasoning_extraction 除去（機械作業でなく判断を要する）。

### 3.2 コスト・リソース（cost）— confidence: medium〜low

- Fable 5 は Opus 4.8 の **2倍単価**だが、effort 別最適化で **40〜60% 削減見込み**（軽量タスク=low/medium、Synthesizer/DA=high/xhigh）。prompt caching（cached input 90%減）+ バッチ処理（50%減）で実用域到達可能。
- リトライ上限・Investigator/DA 反復削減で **15〜25% の追加削減ポテンシャル**だが品質トレードオフあり。
- 1バッチ（5タスク以内）の推定コストは **$8〜$20**。10タスク超は $15〜$40 に達し許容外になりうる。
- **重要な留意:** Fable 5 での Forge Harness 実行データは皆無 → 全見積もりは初回実行後に要再較正。

### 3.3 リスク・失敗モード（risk）— confidence: high（3/4問）

| リスク | 水準 | 根拠 |
|--------|------|------|
| 強指示緩和 → 安全ゲート遵守低下（Instruction Drift） | 高 | 学術研究 + 2026-03-04 のファイル拡散事例 |
| effort 誤組込み → run_claude 全クラッシュ | 中 | 共通ラッパー構造（work_dir 追加が全7箇所波及した前例） |
| ループ簡素化 → 実行ハルシネーション見逃し | 高 | 2026-04-12 のファイル未作成「完了」主張、Investigator の実証された検出力 |
| タイムアウト再有限化 → kill ループ再発 | 高 | Synthesizer 600s×3、task_planner 1800s×3、L1 200s ハードコードバグ |

**結論:** 機械ゲートは LLM 不確実性を補完する設計であり、それらを迂回・削減する変更は過去バグの再発経路を開く。

### 3.4 代替案（alternatives）— 「ハイブリッドが実用的」

| 論点 | 推奨 |
|------|------|
| プロンプト再チューニング手法 | 全面書換+スタイル保持 と キャッシュ最適化ヘッダ のハイブリッド |
| effort 管理場所 | **集中管理（config）をベースにエージェント別デフォルトを許容** |
| 残存課題の取捨 | severity/risk ベースの**高優先絞り込み** |
| タイムアウト方針 | エージェント特性で差別化（ハングリスクゼロ系=無制限、外部呼出系=動的） |

### 3.5 経験的検証（empirical_validation）— confidence: high

Fable 5 挙動の**事実確認**（推測排除）：

- **`claude -p`（`--bare` なし）は `.claude/agents/` をロードする**仕様。2026-04-12 の「Total plugin agents: 0」はバージョン依存の可能性が高く、**実機再確認が必須**。
- **字義通り解釈強化** = CONFIRMED（短い指示で制御可）
- **ナレーション増加** = CONFIRMED（高 effort で顕著）。小規模テストで観測可能
- **「ツール保守化」= 不正確で計画から除外すべき**。実際はむしろ**要求外アクションの積極化**（git ブランチ作成・メール草稿等）が懸念。安全フィルター（cybersecurity/biology）によるフォールバックと混同してはならない
- 注意点: Fable 5 は adaptive thinking 専用（temperature/top_p 削除）、Claude Code **v2.1.170 以降**が必要

---

## 4. 視点間の対立と解決

| 対立 | 内容 | 解決 |
|------|------|------|
| **risk ⇔ technical** | technical「grep で特定でき機械ゲートと独立で安全」vs risk「軽微変更でも Instruction Drift で遵守低下」 | 対象が異なり両立。緩和は **reasoning_extraction 誘発記述と純粋に冗長な列挙に限定**。安全ゲートを支える強指示は**対応する機械ゲートの存在を確認した上でのみ**削る |
| **empirical ⇔ technical** | 現行 `-p` は agents ロード（公式）vs 2026-04-12 は「agents: 0」 | バージョン依存。**着手前に実機確認を必須ゲート化** |
| **cost ⇔ risk** | cost「ループ削減で 15-25% 削減」vs risk「ハルシネーション見逃し・kill ループ再発」 | validate モードかつ確証不足 → **risk 優先**。コスト削減は安全機構温存で達成可能なレバー（effort 別最適化・caching）を優先 |

---

## 5. 推奨アクション

### 5.1 Primary（推奨）

**(A) 着手前ゲート（実機確認）** — 最初に必ず実施
- `claude -p` の agents ロード可否・Task ツール可用性
- `--effort` 受理・モデル切替の成立

**(B) プロンプト再チューニング**
- 13テンプレート・12エージェント定義を grep し **reasoning_extraction 誘発記述を最優先除去**、冗長な強指示を短指示化
- 安全ゲートを支える強指示は対応機械ゲートの存在を確認した上でのみ緩和

**(C) effort オプション組込み**
- `run_claude()` に effort 引数を**後方互換追加**
- `development.json` / `research.json` で**エージェント別 effort を集中管理**（軽量=low/medium、SC/Syn/DA/Investigator=high/xhigh）

**(D) タイムアウト effort 連動**
- 既存 L1/L2/L3 timeout_sec 動的化に **effort 連動倍率**を導入。ハングリスクゼロ系は無制限維持

**(E) 残存課題**
- 4件のうち **severity/risk 高のもののみ同梱**

各変更は `run-all-tests.sh` + Fable 5 実機最小回帰で検証。

### 5.2 Fallback（縮小実装）
着手前ゲートで **agents ロードまたは `--effort` 受理が確認できない場合**、(C) effort 組込みを保留し、**(B) 再チューニング + タイムアウト一律延長 + 高優先残存課題のみ**に範囲縮小。

**トリガー:** (a) agents 未ロード、(b) `--effort` 不受理、(c) reasoning_extraction refusal が想定外多発、のいずれか。

### 5.3 Abort（個別見送りのみ）
全面撤退はロック決定により禁止。**ループ簡素化と安全ゲートを支える強指示の緩和は今回バッチから除外し現状維持**。機会損失（15-25% 追加削減）は実機実測後の別バッチで安全に再評価可能。

---

## 6. 実装計画（implementation-criteria より）

### Layer 1（ユニット/lint — 5基準）
| ID | 内容 |
|----|------|
| L1-001 | `run_claude()` に effort 引数を後方互換追加（未指定=従来挙動、不正値=非ゼロ終了） |
| L1-002 | config にエージェント別 effort 設定を追加しロード関数が正しく解決 |
| L1-003 | timeout_sec に effort 連動倍率を導入（整数防御維持、timeout_sec=0 は無制限維持） |
| L1-004 | reasoning_extraction 誘発記述を除去、安全ゲート強指示は温存 |
| L1-005 | 機械ゲート（assertions/l1_criteria_refs/validate_l1_file_refs）がプロンプト変更後も回帰なし |

### Layer 2（着手前ゲート/実機統合 — 4基準）
| ID | 内容 |
|----|------|
| L2-001 | 現行 `claude -p` が `.claude/agents/` をロードし Task ツール利用可能か実機確認 |
| L2-002 | `--effort` フラグ受理 + `-p` 併用でモデル切替成立 |
| L2-003 | research-loop（SC→R→Syn→DA）が effort 設定下で完走 |
| L2-004 | effort 連動 timeout が長時間応答を kill ループせず吸収 |

### Layer 3（構造/品質受入 — 4基準）
| ID | 戦略 | 閾値 |
|----|------|------|
| L3-001 | structural | 全テスト PASS（回帰0） |
| L3-002 | structural | コスト削減率 ≥ 0.40 |
| L3-003 | llm_judge | 品質スコア ≥ 0.80（refusal 不在・トーン一貫・指示遵守） |
| L3-004 | cli_flow | forge-flow 一連フロー completed + タスク生成 ≥1 |

### 開発フェーズ
| Phase | ゴール | criteria |
|-------|--------|----------|
| **mvp** | 着手前ゲート通過 → run_claude に effort 後方互換追加、1エージェントで反映、回帰0 | L1-001, L1-002 |
| **core** | 全エージェントに effort 展開 + timeout 連動 + プロンプト再チューニング、機械ゲート回帰なし | L1-003, L1-004, L1-005 |
| **polish** | end-to-end 安定、kill ループ/refusal/コスト超過エッジで壊れない、高優先残存課題同梱 | L1-001, L1-003 |

---

## 7. 残存ギャップ（実機検証で埋めるべき項目）

- Fable 5 + xhigh effort の**実測応答時間データ**なし → timeout 倍率は実験的調整が必要
- effort=low の**具体的トークン削減率**（公式非公開）
- Forge Harness 各エージェントの**実平均トークン数**（コスト見積もりの再較正に必須）
- **2026-04-12「agents: 0」が現行版で再現するか**の直接確認（最優先・着手前ゲートで遮断）
- `--bare` がデフォルト化される時期と既存ハーネスへの影響
- reasoning_extraction refusal が headless と対話モードで挙動差を持つか
- safety classifiers が investigator/devil's-advocate 等のどのプロンプトをトリガーするか

---

## 8. 結論

ロック決定（全 fable 化）の下、**品質と実用コストの両立は十分可能**。reasoning_extraction 除去・effort 組込み・timeout 連動は公式文書 confidence=high で裏付けられ、機械ゲートと独立に安全実装できる。

最大の前提リスクは **2026-04-12 の agents 未ロード問題の再現可能性**であり、これは**着手前ゲートで必ず遮断**すること。安全機構（ループ・強指示・無制限タイムアウト）は温存し、過去バグの再発経路を開かない方針で進めるのが妥当。
