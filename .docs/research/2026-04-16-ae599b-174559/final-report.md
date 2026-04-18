# uranai-concept 構造的リファクタリング — 最終リサーチレポート

> **リサーチID**: 2026-04-16-ae599b-174559
> **テーマ**: デッドコード削除 + 品質改善 + アーキテクチャ改善 + Bash ベーステスト再構築
> **生成日**: 2026-04-16
> **視点数**: 6（技術的実現性 / コスト / リスク / 代替案 / テスタビリティ / メンテナンス性）

---

## 1. エグゼクティブサマリー

6視点の横断分析により、**3つの重要発見**と**5つの補足発見**が確認された。最優先は post-tool-use-skill.sh の2モードが実質無効化されているバグの修正であり、リファクタリング全体の推定工数は **5〜10時間**。

### 3大発見

| # | 発見 | 深刻度 | 関連視点 |
|---|------|--------|----------|
| 1 | **post-tool-use-skill.sh の schema-validate / hash-record が無効化** — 絶対パス非対応バグ | Critical | technical × testability × risk |
| 2 | **genre-profiles パス不整合** — SKILL.md/phase2-agent が存在しないディレクトリを参照 | High | technical × maintainability × risk |
| 3 | **コスト構造は「調査支配型」** — テスト再構築が最大工数（4-7h）、デッドコード削除が最高ROI | Info | cost × alternatives × testability |

---

## 2. 調査計画（Investigation Plan）

### コアクエスチョン（7問）

1. エビデンスベース（grep参照トレース）で特定可能なデッドコードの完全リスト
2. `src/hooks/` に単独ファイルが存在する構造の妥当性
3. `references/` と `docs/` の役割分担の定義
4. Bash ベーステスト戦略の粒度とフレームワーク選定
5. vol1-tarot の `your-business-plan.html` 欠落の根本原因
6. `docs/fix-instructions.md` 記載6件の問題の未反映残存有無
7. `genres/` ディレクトリに tarot.json のみ存在する理由

### 調査の前提（Assumptions Exposed）

- grep による静的解析で動的パス展開（`{genre}.json`）を網羅できるという前提 → **不完全**（手動列挙が必要）
- Jest テスト90ファイルの知見は完全に失われた → **不正確**（実際は35ファイル、git history から回収可能）
- 3フェーズエージェント構造は安定しており再設計不要 → 暗黙の前提として妥当
- output/ 既存成果物はテストフィクスチャに再利用不可 → 条件付きで可能だが品質に疑義あり

---

## 3. 各視点の調査結果

### 3.1 技術的実現性（Technical）

**信頼度: High**

#### 発見1: post-tool-use-skill.sh の致命的バグ

| モード | 状態 | 原因 |
|--------|------|------|
| atomic-write | **正常動作** | FILE_PATH の末尾マッチ（`=~ state/phase-state\.json$`）は絶対パスでも動作 |
| schema-validate | **無効化** | `^(output|state)/` が絶対パスにマッチしない → 全ファイルが早期 exit 0 |
| hash-record | **無効化** | `^(docs|templates)/` が絶対パスにマッチしない → 全ファイルでハッシュ記録されない |

- Claude Code PostToolUse hook は `tool_input.file_path` を**常に絶対パス**で渡す（公式ドキュメントで確認済み）
- `settings.json` も `$CLAUDE_PROJECT_DIR` を未使用（相対パスで記述）

#### 発見2: genre-profiles パス不整合

```
参照元: SKILL.md L59, phase2-agent.md L44
参照先: references/genre-profiles/{genre}.json  ← 存在しない
実体:   .claude/agents/genres/tarot.json         ← 実際の配置場所
```

#### 発見3: src/ → .claude/hooks/ 移動の影響

- `settings.json` の3行書き換え + `$CLAUDE_PROJECT_DIR` 導入が必要
- git hooks / CI への影響: **なし**（.git/hooks に active hook なし、CI設定ファイルなし）
- `PROJECT_ROOT` 計算: `SCRIPT_DIR/../..` で src/hooks/ でも .claude/hooks/ でも同じ結果 → **変更不要**

#### 発見4: references/docs 再編の影響範囲

| ファイル | docs/ 参照 | references/ 参照 |
|----------|-----------|-----------------|
| SKILL.md | 2箇所 | 2箇所 |
| phase2-agent.md | 2箇所 | 3箇所 |
| phase3-agent.md | 3箇所 | 0箇所 |
| templates/ (5ファイル) | 複数 | 5箇所 |
| post-tool-use-skill.sh | 0箇所 | 1箇所 |
| **合計** | **〜14箇所** | **〜11箇所** |

---

### 3.2 コスト・リソース（Cost）

**信頼度: High〜Medium**

#### 工数見積もり

| タスク | 工数 | 支配的コスト | ROI |
|--------|------|-------------|-----|
| デッドコード削除 | 50〜60分 | 参照トレース調査（70-75%） | **最高** |
| ディレクトリ再構成 | 45〜90分 | settings.json更新+検証 | 高 |
| ドキュメント整備 | 30〜45分 | fix-instructions.md + cascade-graph | 中 |
| Bash テスト再構築 | **4〜7時間** | hook stdin モック設計 | 中 |
| git history 知見回収 | 1〜2時間 | 旧テスト35件の読解 | **Marginal** |

#### デッドコード候補の実測結果

| ファイル | grep 結果 | 判定 |
|----------|----------|------|
| `references/scoring-rules.md` | 全参照 **ゼロヒット** | **削除安全** |
| `references/template-variable-mapping.md` | fix-instructions.md内のみ（非アクティブ） | **削除安全** |
| `docs/templates/desire-architecture-template.md` | templates/ と重複 | **削除安全** |
| `docs/legacy/demo-output.md` | レガシー成果物 | **削除安全** |
| `references/platform-specs.md` | templates/guidelines-template.md L28 でアクティブ参照 | **削除不可** |

#### 旧テスト知見の実態

- 事前想定「90ファイル」→ 実測 **35件**（TypeScript 30 + shell integration 5）
- Bash テスト設計に直接転用可能: **10〜15件**（hook-settings.test.ts, template-integrity.test.ts 等）
- ROI: 投資1-2h → 節約約1h（わずかに正）

---

### 3.3 リスク・失敗モード（Risk）

**信頼度: High〜Medium**

#### リスクマトリクス

| リスク | 深刻度 | 発生確率 | 検出容易性 | 対策 |
|--------|--------|----------|-----------|------|
| フック移動後のサイレント無効化 | **Critical** | 中 | **検出困難** | 移動直後に Write ツール実行でフック発火を手動確認 |
| genres プロファイル欠落によるランタイムクラッシュ | **High** | 高（tarot以外使用時） | 低 | 起動時バリデーションまたはデフォルトフォールバック |
| grep ベース削除の見落とし（動的パス） | **High** | 中 | 低 | grep + 動的パス手動列挙の二段構え |
| vol1 再処理時の一貫性破壊 | **Medium** | 低 | 中 | 再処理前にスナップショット取得 |
| テスト導入による潜在バグ顕在化 | **Medium** | 中 | 高 | キャラクタリゼーションテスト手法を適用 |

#### フックのサイレント無効化の実証

- 複数の GitHub Issue で確認済み:
  - exit code 1 は非ブロックエラー（Claude Code は実行継続）
  - Homebrew ツールが制限付き PATH に含まれずサイレント失敗
  - Windows/WSL でパス解決が変わりサイレント失敗
  - settings.local.json の変更が反映されないバグ

---

### 3.4 代替アプローチ比較（Alternatives）

**信頼度: High**

#### ディレクトリ構造

| 案 | 概要 | 評価 |
|----|------|------|
| **(A) .claude/hooks/ に移動** | Claude Code 公式規約の標準配置 | **推奨** — 公式ドキュメントで明確に規定 |
| (B) ルートに配置 | フラットで依存少ない | 規約から外れる |
| (C) src/hooks/ 維持 | 変更なし | 非標準、将来の互換性リスク |

#### テストフレームワーク

| 案 | 初期コスト | 長期メリット | 評価 |
|----|-----------|-------------|------|
| **(A) 純 Bash** | 15分 | 既存 forge テスト15本と一貫性 | **採用** — CI不在、Windows互換性未検証の理由 |
| (B) bats-core | 30分 | TAP出力、setup/teardown | CI統合要件があれば有力 |
| (C) shunit2 | 20分 | POSIX互換 | 機能が少ない |

#### デッドコード削除戦略

| 案 | ロールバック容易性 | 履歴明瞭さ | 評価 |
|----|------------------|-----------|------|
| (A) 一括削除 | 低（粒度粗い） | 低 | 非推奨 |
| **(B) 段階的削除（カテゴリ別コミット）** | **高** | **高** | **推奨** — 業界ベストプラクティス |
| (C) deprecated/ 移動 | 中 | 中 | git が安全ネットのため過剰 |

#### references/docs 整理方針

| 案 | 概要 | 評価 |
|----|------|------|
| (A) 用途別分離 | エージェント参照 vs 人間向け | 理論的には最良だが境界曖昧 |
| (B) docs/ 統合 | サブディレクトリ分類 | 小規模では有効 |
| **(C) references/ 維持 + デッドファイル削除** | 最小変更 | **採用** — パス不整合修正が先決 |

---

### 3.5 テスタビリティ（Testability）

**信頼度: High〜Low（項目により異なる）**

#### テスト可能な境界の二層構造

```
┌──────────────────────────────────────────┐
│  非決定論的 LLM 層（テスト境界外）        │
│  - エージェント推論品質                    │
│  - L3-judge (閾値0.7) で確率的評価のみ     │
├──────────────────────────────────────────┤
│  決定論的境界層（高テスタビリティ）         │
│  (a) フック I/O: stdin/stdout/exit code   │
│  (b) JSON スキーマバリデーション           │
│  (c) テンプレート変数網羅性               │
│  (d) ファイル構成規約                      │
│  (e) 参照パス整合性                        │
└──────────────────────────────────────────┘
```

#### テストダブル設計（post-tool-use-skill.sh 3モード）

| モード | テストダブル | 検証内容 |
|--------|------------|----------|
| atomic-write | TMPDIR注入 + state/phase-state.json mock | jq で出力一致検証、書込不可パスで exit 1 |
| schema-validate | PATH override で ajv スタブ注入 | exit 0→通過、exit 1→ブロック、不正JSON→exit 2 |
| hash-record | tmp ディレクトリ + 既知ファイルセット | doc-hashes.jsonl エントリ追加を検証 |

#### ゴールデンファイル活用の判定

- **vol1-tarot**: 不適切（your-business-plan.html 欠落）
- **vol2/vol3**: 条件付き（genres プロファイル欠落下で生成 → 品質に疑義）
- **推奨代替**: テンプレート変数は `{{PLACEHOLDER}}` 抽出 → フィールド差分検出で機械化

---

### 3.6 メンテナンス性（Maintainability）

**信頼度: High**

#### 参照グラフの不整合

| 問題 | 影響 |
|------|------|
| genre-profiles パスミス（SKILL.md L59, phase2-agent.md L44） | 新ジャンル追加が事実上機能不全 |
| scoring-rules.md 孤立（全参照ゼロ） | 将来の開発者が不要な調査に時間を消費 |
| cascade-dependency-graph.md 陳腐化（Layer 1 未記載） | phase3-agent.md の実装と乖離 |
| docs/templates/ 重複（templates/ と同一内容） | どちらが正本か不明 |

#### fix-instructions.md の6問題 — 全て解決済み

| # | 問題 | 根拠 |
|---|------|------|
| 1 | phase2 対話フロー | phase2-agent.md に Step 1-7 実装済み |
| 2 | 状態遷移不整合 | SKILL.md の phase-state 例が schema と一致 |
| 3 | 変数マッピング未定義 | references/template-variable-mapping.md 存在 |
| 4 | 旧エージェント残存 | .claude/agents/ に phase1/2/3 のみ |
| 5 | カスケード依存不正確 | SKILL.md の brand-identity 依存修正済み |
| 6 | 旧コード残存 | src/hooks/post-tool-use-skill.sh のみ残存 |

> ただし fix-instructions.md にステータスマーカーは**未付与**。「未解決の問題リスト」として読み取れる状態。

#### 新ジャンル追加ワークフローの問題

- SKILL.md は `references/genre-profiles/{genre}.json` を案内 → **ディレクトリ不在**
- 実ファイルは `.claude/agents/genres/` に配置 → **案内とズレ**
- tarot.json の構造（〜200行）を参考にする作成ガイドが**存在しない**
- README.md / CLAUDE.md も**不在**

---

## 4. 視点間の矛盾と解決

| 矛盾 | 視点 | 解決策 |
|-------|------|--------|
| バグ修正前/後のどちらに対してテスト設計するか | technical × testability | **修正を先行**し、修正後の挙動に対してテストを設計。回帰テストとして絶対パス入力を含める |
| 純Bash vs bats-core の選択 | cost × alternatives | **純Bash を採用**。既存15本の資産活用、CI不在、Windows互換性未検証の3理由。ただし bats-core 移行可能な構造で設計 |
| grep削除の false-negative リスク vs 最小コスト | risk × cost | grep + **動的パス手動列挙**を必須ステップ化（+15-20分）で両立 |
| vol2/vol3 のゴールデン活用可否 | testability × maintainability | **採用しない**。期待ファイルリストは手動定義、テンプレート変数は機械的差分検出で代替 |
| references/docs 再編成の是非 | alternatives × maintainability | **現時点では再編しない**。パス不整合修正が先決。デッドファイル削除のみで最大効果 |

---

## 5. 推奨アクション

### 5.1 推奨プラン（総工数: 5〜10時間）

```
Phase A  クリティカルバグ修正    60-90分   ← 最優先
Phase B  ディレクトリ正規化      30-45分
Phase C  デッドコード削除        70-80分
Phase D  ドキュメント整備        30-45分
Phase E  Bash テスト再構築       4-6時間   ← 最大工数
Phase F  拡張性改善（optional）  30分
```

#### Phase A: クリティカルバグ修正（最優先）

1. **post-tool-use-skill.sh 絶対パス対応**: `^(output|state)/` → `(output|state)/[^/]+\.json$` に変更
2. **settings.json の $CLAUDE_PROJECT_DIR 導入**: `bash src/hooks/...` → `bash "$CLAUDE_PROJECT_DIR/.claude/hooks/..."` に変更
3. **genre-profiles パス修正**: SKILL.md L59 / phase2-agent.md L44 を `.claude/agents/genres/{genre}.json` に更新

#### Phase B: ディレクトリ正規化

4. `src/hooks/post-tool-use-skill.sh` → `.claude/hooks/post-tool-use-skill.sh` に移動
5. settings.json パス更新（Phase A-2 と統合）
6. `src/` ディレクトリ削除
7. フック動作検証

#### Phase C: デッドコード削除（カテゴリ別コミット）

8. 参照トレース実施（grep + 動的パス手動列挙）
9. 確認済み4ファイル削除:
   - `references/scoring-rules.md`
   - `references/template-variable-mapping.md`
   - `docs/templates/desire-architecture-template.md`
   - `docs/legacy/demo-output.md`
10. 削除**不可**: `references/platform-specs.md`（アクティブ参照あり）

#### Phase D: ドキュメント整備

11. fix-instructions.md に RESOLVED マーカー追加
12. cascade-dependency-graph.md に Layer 1 成果物追加
13. README.md 作成（最小限）

#### Phase E: Bash テスト再構築

14. 純 Bash テストフレームワーク（forge 既存パターン流用）
15. テストカテゴリ（推定 42〜73 ケース）:

| カテゴリ | テスト数 | 内容 |
|----------|---------|------|
| hook 3モード | 12-18 | 正常系・異常系・絶対パス入力 |
| JSON スキーマ | 4-8 | phase-state / desire-architecture |
| テンプレート変数 | 24-40 | {{PLACEHOLDER}} 網羅性 |
| 参照パス整合性 | 5-10 | エージェント → 参照ファイル存在確認 |

### 5.2 フォールバックプラン（工数: 2.5〜3.5時間）

Phase A〜C のみ実施し、Phase D/E/F は後続タスクとして切り出す。

- **トリガー**: Phase E が3時間超過、またはセッション時間制約
- **理由**: Phase E が総工数の60-70%を占めるため、分離することで完了確率を大幅向上

### 5.3 中止判断

- **許容理由**: schema-validate / hash-record 無効化は品質ゲート不在だが atomic-write とエージェント本体には影響なし。genre-profiles のフォールバックにより即時障害は発生しない
- **逸失コスト**: リファクタリング実施コスト（5-10h）の **2-3倍の散発的調査・修正時間**が今後6ヶ月間で発生すると推定

---

## 6. 実装基準（Implementation Criteria）

### Layer 1 基準（10項目）

| ID | 検証内容 | テスト種別 |
|----|----------|-----------|
| L1-001 | schema-validate / hash-record が絶対パスで動作すること | unit_test |
| L1-002 | hook が .claude/hooks/ に配置、settings.json が $CLAUDE_PROJECT_DIR 使用 | lint |
| L1-003 | genre-profiles パスが .claude/agents/genres/ を参照 | lint |
| L1-004 | デッドコード4ファイルが削除されていること | lint |
| L1-005 | アクティブ参照ファイルが保全されていること（誤削除防止） | lint |
| L1-006 | fix-instructions.md に RESOLVED マーカー、cascade-graph に Layer 1 記載 | lint |
| L1-007 | hook 3モードの Bash テストスイートが存在し全 PASS | unit_test |
| L1-008 | JSON Schema が構文的に有効で必須フィールドを含む | unit_test |
| L1-009 | テンプレート全 {{PLACEHOLDER}} が解決可能 | unit_test |
| L1-010 | SKILL.md / agent の全参照パスが実在 | lint |

### Layer 2 基準（4項目）

| ID | 検証内容 |
|----|----------|
| L2-001 | Claude Code ランタイムで Write/Edit 時に3モード全て発火 |
| L2-002 | atomic-write が一時ファイル経由リネームでアトミック性保証 |
| L2-003 | $CLAUDE_PROJECT_DIR がプロジェクトルートに正しく解決 |
| L2-004 | デッドコード削除後に output/vol1-3 が影響を受けていない |

### Layer 3 基準（5項目）

| ID | 検証内容 | ブロッキング |
|----|----------|------------|
| L3-001 | ファイル構造が設計仕様に準拠（想定外ファイル=0） | Yes |
| L3-002 | hook 3モードの入出力連鎖が仕様通り動作（CLI flow） | Yes |
| L3-003 | テンプレート変数の全 {{PLACEHOLDER}} がトレース可能 | No |
| L3-004 | settings.json の $CLAUDE_PROJECT_DIR がパス解決に成功 | Yes |
| L3-005 | cascade-dependency-graph の DAG が8ノード・循環なし | No |

### 開発フェーズ

| フェーズ | ゴール | 基準 |
|----------|--------|------|
| **MVP** | hook 正常動作 + ディレクトリ正規化 | L1-001, L1-002, L1-003 |
| **Core** | デッドコード削除 + ドキュメント整備 | L1-004, L1-005, L1-006 |
| **Polish** | Bash テストスイート構築 | L1-007, L1-008, L1-009, L1-010 |

---

## 7. 残存ギャップ（未調査項目）

| # | ギャップ | 影響 |
|---|---------|------|
| 1 | ajv-cli の Windows 環境でのインストール状況未確認 | schema-validate の実動作範囲が不確定 |
| 2 | bats-core の Windows Git Bash 互換性未検証 | テストフレームワーク選定に影響 |
| 3 | templates/your-business-plan-template.md の docs/ 参照箇所の正確カウント未実施 | 影響範囲が過小評価の可能性 |
| 4 | references/desire-architecture-schema.json の参照トレース不完全 | 孤立ファイルの可能性 |
| 5 | post-tool-use-skill.sh を直接読めていない（forge-research-harness-v1 外） | 3モードの実際のインターフェース未確認 |
| 6 | SKILL.md の内容未確認（uranai-concept 側に存在） | 遷移規則の SKILL.md からの抽出可否が未検証 |
| 7 | phase3-agent.md のカスケード検出スコープ不明 | vol1 再処理の影響範囲限定可否が不確定 |

---

## 8. 前提条件一覧

- uranai-concept プロジェクトは forge-research-harness-v1 とは別ディレクトリ
- Claude Code PostToolUse hook は file_path に絶対パスを渡す（公式ドキュメント確認済み）
- `$CLAUDE_PROJECT_DIR` は Claude Code が自動設定する環境変数
- 公式フック配置先は `.claude/hooks/`（公式ドキュメント確認済み）
- HTTP API サーバーを持たない Claude Code スキルプロジェクト
- Windows Git Bash (MSYS) 環境で実行（`/tmp` パスの二重性に注意）
- jq コマンドがインストール済み
- bats-core ではなく純 Bash テストフレームワークを採用
