## Implementation Criteria

{{CRITERIA_CONTENT}}

## リサーチテーマ

{{THEME}}

## 前提条件

{{ASSUMPTIONS}}

## 環境能力

{{ENV_PROBE}}

## Layer 2 Criteria（統合テスト定義）

{{L2_CRITERIA}}

## Layer 3 Criteria（受入テスト定義）

{{L3_CRITERIA}}

## タスク

上記の Implementation Criteria を**機能単位の粗いタスクスタック**（task-stack.json）に分解してください。

あなたの仕事は「何を作るか（ゴールと制約）」を定義することです。
**「どう検証するか（テストコマンド・CLI フラグ・検証手順）」は書きません** —
それは実装完了後に Implementer 自身が、実際に作った実物に基づいて執筆します
（実装を見ずに書いた受入コマンドが実装と食い違う事故を構造的に防ぐため）。

### 出力スキーマ

以下の JSON スキーマに厳密に従うこと:

```json
{
  "source_criteria": "{{CRITERIA_PATH}}",
  "generated_at": "(ISO 8601 タイムスタンプ)",
  "phases": "(criteriaのphases配列をそのまま引き継ぐ。criteriaにphasesがない場合は省略可)",
  "tasks": [
    {
      "task_id": "(ケバブケース。例: feat-auth-flow)",
      "description": "(この機能が『ユーザーに何をできるようにするか』のゴール記述 + 実装上の重要な制約。テストコマンドは書かない)",
      "task_type": "(setup | implementation | documentation)",
      "dev_phase_id": "(mvp | core | polish)",
      "depends_on": ["(依存タスクの task_id。なければ空配列)"],
      "status": "pending",
      "fail_count": 0,
      "constraints": ["(任意。locked_decisions 由来の技術制約や、守るべき境界条件)"],
      "l1_criteria_refs": ["(この機能が充足する layer_1_criteria の ID。必須。例: [\"L1-001\", \"L1-003\"])"],
      "l2_criteria_refs": ["(対応する layer_2_criteria の ID。省略可)"],
      "l3_criteria_refs": ["(この機能が担う layer_3_criteria の ID。省略可。ただし全 L3 ID がいずれかのタスクに割り当てられること — 機械チェック対象)"],
      "replaces": ["(このタスクが置換する旧ファイル/シンボル名。置換型タスクのみ)"],
      "required_behaviors": [
        "(criteria の behaviors から引き継いだ振る舞い定義。implementation タスクのみ必須)"
      ]
    }
  ],
  "scope_coverage": {
    "theme_elements": [
      {"element": "テーマから分解された要素", "mapped_tasks": ["task-id"]}
    ],
    "coverage_complete": true
  },
  "excluded_elements": [
    {"element": "除外要素", "reason": "除外理由", "suggested_phase": "future"}
  ]
}
```

### 分解手順

1. **L1 criteria 解析**: 各成功条件（L1-001, ...）を全て列挙する
2. **機能単位に束ねる**: 関連する L1 条件を「1つのユーザー可視能力」= 1機能タスクに束ねる
   - **粒度: プロジェクト全体で 6〜10 タスク**（setup 1-2 + 機能 5-8 + documentation 0-1 が目安）
   - 1機能 = ユーザー/利用者の視点で意味が完結する能力（例:「認証してセッションを維持できる」）
   - 実装とテストは分離しない（機能タスクは実装コード＋テストコードの両方を含む）
   - **全 L1 ID が少なくとも1つのタスクの `l1_criteria_refs` に含まれること（機械チェック対象）**
3. **依存関係**: 基盤（setup）→ 機能 → 統合の順で depends_on を定義。並列可能性を最大化する
4. **behaviors 引き継ぎ**: criteria の behaviors を対応タスクの required_behaviors に完全一致文字列で引き継ぐ（漏れ禁止・改変禁止）
5. **dev-phase 割り当て**: criteria の phases[].criteria_refs から各機能の dev_phase_id を判定する
6. **L2/L3 参照の割り当て**: layer_2_criteria / layer_3_criteria の各 ID を最も関連する機能タスクの l2_criteria_refs / l3_criteria_refs に記録する（**全 L3 ID の割り当てが機械チェック対象**。コマンドは書かない — ID の割り当てのみ）
7. **スコープカバレッジ検証**: phases[].scope_description に列挙された各項目が、いずれかのタスクの description に**実装対象として**現れることを確認する（例:「A腕ランナー」が scope にあるなら、プロンプト資産だけでなくランナーの実行経路を実装するタスクが必要）
8. **除外の明示**: 意図的に除外した要素は excluded_elements に理由とともに記録する
9. **Walking Skeleton 対応**: 各 phase の kind=walking_skeleton exit_criteria（実ユーザーシナリオ E2E）が、そのフェーズのタスク群完了時に成立するよう、シナリオ経路上の全コンポーネントを繋ぐタスクを配置すること。ユニットが揃ってもシナリオが通らない分解は不合格

### task_type の分類

- **setup**: フレームワーク初期化・依存インストール・設定配置。プロジェクト初期化が必要なら最初の setup タスクとして必ず含める
- **implementation**: 機能実装＋テスト。required_behaviors 必須
- **documentation**: README 等。required_behaviors 不要

### description の書き方（重要）

各機能タスクの description には以下を含める:
- **ゴール**: この機能で何ができるようになるか（ユーザー/利用者視点）
- **成果物の置き場所**: 主要なエントリポイント/ディレクトリ（新規ルートはエントリポイント登録先も明記 — Implementer は description 記載外のファイルを変更できない）
- **制約**: locked_decisions 由来の技術制約（あれば constraints 配列にも記載）
- 書かないもの: テストコマンド、CLI フラグ仕様、検証手順（Implementer が実装後に執筆する）

### ルール

- task_id はケバブケースで一意
- depends_on に存在しない task_id を参照しない
- 全タスク status="pending" / fail_count=0
- dev_phase_id 必須（criteria に phases がなければ全て "mvp"）
- タスク順序は mvp → core → polish
- 置換型タスクは `replaces` に旧名を列挙する（配線検証は実装後の執筆ステップで定義される）

## 出力形式（厳守 — 機械パーサー直結）

あなたの出力は **jq コマンドで直接パースされる**。人間が読むものではない。

1. 最初の文字は `{` であること（空白・改行すら不可）
2. 最後の文字は `}` であること
3. コードフェンス（```）を絶対に含めない
4. JSON の前後に説明テキスト・コメントを絶対に含めない
5. JSON 内部のコメントも不可
6. 出力全体が `jq empty` で検証される
