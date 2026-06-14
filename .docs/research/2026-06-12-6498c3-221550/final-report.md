# Forge Harness 品質強化バッチ #5 — 最終リサーチレポート

**テーマ**: 計画ゲート・ループ堅牢化・テスト基盤修復・軽微整合の4領域改修
**リサーチID**: 2026-06-12-6498c3-221550
**判定**: ✅ **GO**（全6視点が high confidence で実現可能性を裏付け）

---

## 1. エグゼクティブサマリー

4領域すべての改修が技術的に実現可能であり、既存コードベースに直接の前例・足場が存在することが確認された。特筆すべきは、調査過程で以下の**行レベルの根本原因特定**に成功した点:

- **テストのサイレント死の機序を完全特定**: run-all-tests.sh は exit code のみで PASS 判定し、テスト側は `set -e` なし + `exit $FAIL_COUNT` のため、source 失敗等でアサーションが1つも実行されなくても exit 0 → PASS 偽装される
- **「L1791 エンコーディングエラー」の正体**: ralph-loop.sh（1465行）に該当行は存在せず、実測バイナリスキャンで NULL 文字は **common.sh L114 の1バイトのみ**（jq_lines() 直前のコメント内 literal NUL）に局在。これが grep/ripgrep の binary 判定を誘発しテストゲートを無機能化していた
- **L2 fix タスクの dedup は現状ゼロ**: 無条件 append のため Phase 3→2 リトライで重複 fix タスクが無制限に累積する
- **run-all-tests.sh が存在しない2ファイル**（test-coverage-gaps.sh, run-playwright.sh）**を黙ってスキップ**している即時発見事項
- **テスト母数は公称15本でなく実態約51本**（コスト見積りの母数が3倍超）

推定コストはバッチ #4 同等〜1.5倍（**7〜12時間**）で許容範囲内。

---

## 2. 調査スコープ

### 中核の問い（investigation-plan より）

| # | 問い | 結論 |
|---|------|------|
| 1 | 計画ゲート3種の静的検証範囲・注入ポイント | jq ベースで2箇所に注入可能（後述） |
| 2 | test-evidence-da / test-research-e2e のサイレント死の根本原因 | 機序特定済み（exit code のみ判定 + set -e なし） |
| 3 | L2 fix タスク dedup のキー設計 | origin_task_id + L2 command フィンガープリント併用 |
| 4 | _RT_TASK_JSON キャッシュ再読込のタイミング | dev_phase 境界での get_task_json 再呼出（状態機械と直交） |
| 5 | L1791 エンコーディングエラーの正体 | common.sh L114 の literal NUL 1バイトに読み替え |
| 6 | ERR trap + 完走検証の共通基盤設計 | 二層構成（opt-in ヘルパー + ランナー側検証） |
| 7 | test-l2-wiring.sh の検証方式 | fixture + 関数 source + サーバースタブ（run_claude モック不使用） |
| 8 | 軽微整合3点の修正箇所 | 相互干渉なし、test-config-integrity に常設 |

### 境界

- 4領域に限定。L3 有効化・research-loop 本体・新規エージェント追加・bash + claude -p 構成の変更は**扱わない**
- ロック済み決定事項は調査対象外（全6ロックと整合することを確認済み）

---

## 3. 視点別の主要知見

### 3.1 技術的実現性（technical）— 全4問とも実現可能・high confidence

- **計画ゲート注入ポイント**: generate-tasks.sh の (A) スキーマ検証後〜phases 上書き前（L520付近）と (B) 上書き直後（L607）。既存の L2/L3 ゲート（L464-511）・L1 カバレッジゲート（L537-593）と同パターンで実装可能
- **ERR trap**: ralph-loop.sh（`set -eEuo pipefail` + 局所 trap + 明示解除）で Git Bash bash 5.2.37 上の**稼働実績あり**。ライブラリは set 行を持たない継承設計のため、局所 trap パターンを守れば非破壊導入可。ただし**ライブラリ内グローバル trap は禁止**（negative test と干渉）
- **_RT_TASK_JSON**: task_prepare()（L768）で一度だけロードされ再読なしのステイル構造を確認。フェーズ境界での再読込は11ステータス状態機械と衝突しない
- **L2 fix dedup**: create_l2_fix_task()（phase3.sh L421-465）は無条件 append。append 前に `l2_fix_for == $orig_id && status == "pending"` の jq 検索で skip/replace すれば Investigator の in-place fix とも直交
- **test-l2-wiring.sh**: FORGE_DRY_RUN（common.sh L275-351）・fixture 注入・関数抽出 source の3手法すべてに既存実証例あり。start_l2_server スタブ + /tmp 隔離 + 無害 layer_2.command（echo）で実経路配線を検証できる

### 3.2 コスト（cost）

- **規模**: 6〜10タスク、バッチ #4 同等〜1.5倍（7〜12時間）
- **最大リスク**: 横断的タスク（共通基盤系）の粒度過大。過去に 900s タイムアウト8回連続の前例 → **1-2ファイル/300行粒度の明示分割が必須**
- **計画ゲートのコスト増**: 機械検証（jq）に限定し LLM 判定を挟まなければ、最悪でも planner 1回分の再実行に収まる
- **共通基盤の効果**: テスト実態が約51本のため削減効果は当初想定より大。ただしベースライン破損3テストの修復と**配線（被参照）検証**が初期コストに上乗せ

### 3.3 リスク（risk）

主たる脅威は破滅的な無限リトライではなく、**「検証層の偽陽性/偽陰性が静かに通過する」**こと:

1. **計画ゲートの偽陽性**: 既存の有界リトライ設計を踏襲すれば無限リトライは構造的に起きない。リトライ時は検証フィードバックをプロンプトに反映すること（RETRY_SUPPLEMENT 方式は既に実施）
2. **ERR trap × negative test**: bash の古典的落とし穴と一致。`cmd || true` 形式・一時解除関数で回避
3. **chicken-and-egg 再発**（バッチ #3 前例）: dedup/再読込は ralph-loop 実行パス上。verify task 最後尾配置 + タスク単位 auto-commit で緩和
4. **NULL 混入の再発**: 混入源未特定のため、局所修正に加え**全 .sh/.json への NULL 検出ゲートの常設**が必要
5. **生成テストの制約違反**（自己言及的失敗）: allowlist 機械ゲートで緩和、ただしそれ自体が偽陽性リスクを再帰的に持つ

### 3.4 代替案比較（alternatives）

| 論点 | 採用案 | 根拠 |
|------|--------|------|
| dedup キー | origin_task_id + L2 command ハッシュ併用 | 分散システムの定石（ID 単独は誤抑止、ハッシュ単独は偽陰性） |
| サイレント死防止 | ERR trap + 完了マーカーの両輪 | ERR trap には文書化された死角（条件文脈・サブシェル黙殺）があり単独では不十分 |
| ゲート失敗時挙動 | フィードバック付きリトライ→hard fail（機械検証）/ warning 続行（ヒューリスティック） | warning 無条件続行は silent corruption を流すアンチパターン |
| l2-wiring 検証方式 | 単体 source + fixture ミニループの二層 | 「関数は正しいが呼ばれていない」型の配線バグを検出できる唯一の方式 |

### 3.5 Windows/Git Bash 互換性（windows-compat）— 実測ベース

- **NULL 混入は common.sh の1バイトのみに縮退**（offset 5193 / L114）。ralph-loop.sh は NULL 0個・CR 0個でクリーン。「全ハーネスファイルに NULL 混入」という過去記録は現存しない
- jq_lines() は CRLF を吸収するが **NUL は吸収しない**（`tr -d '\r'` のみ）
- trap ERR/errtrace のセマンティクスは Git Bash でも upstream bash と一致と見られる。リスクはネイティブ exe（jq.exe 等）を挟む終了コード経路側
- 完走マーカーは **ASCII 固定 + jq 出力は jq_lines 経由 + git autocrlf 対策**で安全に構成可能

### 3.6 回帰保護・検証戦略（regression-protection）

- 依存グラフは**線形で循環なし**: 「共通基盤 → 2テスト修復 → l2-wiring 新設 → 本体改修」の順序が成立
- サイレント死状態は壊れた最小テストを fixture 固定し、修復後のランナーがそれを FAIL 検出することを**メタテストで機械検証可能**
- Phase 3 完了基準の強化案: skip>0 → completed_with_gaps、'PASSED: N/M' パースで total==0 → FAIL、integration-report.json に assertions_executed フィールド追加

---

## 4. 視点間の矛盾と解決（Synthesizer による調停）

| # | 矛盾 | 解決 |
|---|------|------|
| 1 | ゲート失敗時: hard fail（alternatives）vs warning 続行（cost/risk） | **ゲート種別で分岐**: 機械的検証（allowlist/マッピング）は補強リトライ2回→hard fail、grep ヒューリスティックは1回→critical warning 続行 |
| 2 | NULL 横断問題の再発リスク高（risk）vs 1バイトに局在（windows-compat 実測） | **実測を優先**（Evidence > assumptions）。ただし NULL 検出ゲートを test-config-integrity に常設して再発を機械検出 |
| 3 | ロックの「ralph-loop L1791」が現行コードに対応しない | ロックの意図（エンコーディングエラー修正）を維持しつつ、対象を **common.sh L114 の NUL に読み替え**。元エラーログの出所確認を verify task に含める |
| 4 | ERR trap 適用: ランナー側ラッパー（alternatives）vs 共通基盤 source（ロック） | **二層併用**: test-helpers.sh に opt-in ヘルパー（一時解除関数付き）+ run-all-tests.sh に assert 数/完了マーカー検証 |

---

## 5. 推奨アクション

### Primary: GO — 4領域すべてを実施

実装順序（依存グラフに従う）:

1. **common.sh NUL 除去 + NULL 検出ゲート常設**（テスト無機能化の根を先に断つ）
2. **テスト共通基盤**: test-helpers.sh への opt-in ERR trap ヘルパー + run-all-tests.sh の assert 数/完了マーカー検証 + dead 参照2件の整理
3. **サイレント死2テスト修復**（test-evidence-da / test-research-e2e）
4. **test-l2-wiring.sh 新設**（fixture + phase3.sh 関数 source + サーバースタブ + /tmp 隔離）
5. **本体改修**: L2 fix dedup + _RT_TASK_JSON フェーズ境界再読込
6. **計画ゲート2種を generate-tasks.sh に注入**（L520付近 / L607）
7. **軽微整合**: implementer.md ファイル数の config 整合、Mutation Auditor timeout、フォールバック fable 化

運用原則: 各タスク1-2ファイル/300行粒度、verify task は最後尾、タスク単位 auto-commit。

### Fallback: 基盤修復コアへの縮退

順序1〜4 + 軽微整合のみ完遂し、計画ゲートと L2 dedup/再読込は次バッチへ分離。

**トリガー**: 基盤修復フェーズで予算60%（約4.5〜7時間）超過 / ERR trap による negative test 誤 fail が3本以上 / ralph-loop 改修タスクの blocked_investigation 2回以上。

### Abort: 推奨しない

撤退が正当化されるのは、NUL 除去や共通基盤変更が既存約51テストを広範に破壊しベースライン復旧が予算を食い潰す場合のみ。撤退した場合、PASS 偽装の継続・L2 fix 無制限累積・locked_decision 計画漏れ（バッチ #4 で手動復旧3回）が反復し、1バッチあたり数時間規模の手動復旧コストが続く。

---

## 6. 実装基準（implementation-criteria 要約）

### フェーズ構成

| フェーズ | ゴール | 対象 L1 基準 |
|---------|--------|-------------|
| **mvp** | テスト基盤の信頼性回復（NUL 除去・サイレント死遮断・ランナー完走検証） | L1-001〜004 |
| **core** | 本体堅牢化（l2-wiring 新設・fix dedup・キャッシュ再読込・計画ゲート） | L1-005〜008 |
| **polish** | 軽微整合 + 全体回帰（フルグリーン・自己無撞着確認） | L1-009 |

### Layer 1 基準（9件）

- **L1-001**: common.sh NUL 除去 + NULL 検出ゲート常設（grep が binary 判定しないこと）
- **L1-002**: run-all-tests.sh の 'PASSED: N/M' パース + assert 数0→FAIL + dead 参照整理
- **L1-003**: opt-in ERR trap ヘルパー（失敗行番号表示 + negative test 用一時解除 + **被参照配線の確認**）
- **L1-004**: サイレント死2テストの根本修復（source 破壊時に exit 非0 で即死すること）
- **L1-005**: test-l2-wiring.sh 新設（成功/失敗/スキップの3経路 + /tmp 隔離）
- **L1-006**: L2 fix dedup（同一キーで skip、異なる command は append、completed は dedup 対象外）
- **L1-007**: _RT_TASK_JSON フェーズ境界再読込（不正 JSON 時は旧キャッシュ温存、status 巻き戻しなし）
- **L1-008**: 計画ゲート2種（allowlist 違反/マッピング欠落は2回リトライ→hard fail、ヒューリスティックは warning 続行）
- **L1-009**: 軽微整合3点 + 整合チェックの test-config-integrity 常設

### Layer 2/3（行動検証）

- **L2**: 全スイート一括実行（83 assert 以上維持）/ generate-tasks 実 fixture E2E / ralph-loop ドライラン統合 / Windows 互換回帰 — 計4件
- **L3**（全件 blocking）: サイレント死遮断の故意注入検証 / 計画ゲート実 LLM フロー / L2 wiring 証跡検証 / 改修全体の自己無撞着性（フルグリーン + NUL 0 + dead 参照 0）— 計4件

---

## 7. 残存ギャップ（次バッチ・verify task への引き継ぎ）

- 「L1791」エラーの出所ログの特定（verify task に含める）
- NULL 文字混入の根本原因（混入経路）の未特定 → 検出ゲート常設で機械検出に切り替え
- set -e + ERR trap の条件式コンテキスト抑止が ralph-loop 全呼出経路に及ぼす影響の網羅確認
- jq -r 直呼び（jq_lines 非経由）残存箇所の網羅監査
- skip 多数時の Phase 3 status 決定の細部挙動
- _RT_TASK_JSON 再読込が新規に持ち込む stale-cache 逆方向失敗（旧定義残存）の参照箇所一貫性

---

*生成日: 2026-06-12 / 視点レポート6本（technical, cost, risk, alternatives, windows-compat, regression-protection）+ synthesis + implementation-criteria に基づく*
