## リサーチテーマ

{{THEME}}

## リサーチID

{{RESEARCH_ID}}

## サーバーURL

{{SERVER_URL}}

exit_criteria の auto テストで API を検証する際は、上記URLをベースに使用すること。

## 統合分析結果（Synthesizer出力）

{{SYNTHESIS}}

## タスク

上記の統合分析結果から、実装の成功条件を3層に分離して定義してください。

### 3層の分類基準

1. **Layer 1（確定的テスト）**: 自動テストで毎回同じ結果が得られるもの
   - ユニットテスト、型チェック、lint、APIレスポンスコード確認
   - 速度重視（数秒〜数十秒で完了）
   - 決定的であること（同じ入力で毎回同じ結果）

2. **Layer 2（条件付きテスト）**: 実行環境や外部サービスに依存するもの
   - E2Eテスト、実環境API呼び出し、スケジュール実行確認
   - 環境変数やテストアカウントが必要な場合がある
   - 結果が不安定な場合がある

3. **Layer 3（受入テスト）**: ユーザーが実際に目的を達成できるかを自動検証するもの
   - API連鎖フロー（concept→worldview→profileの一連呼出）
   - 出力の構造・制約の機械検証（JSONスキーマ適合、フィールド長、必須項目）
   - LLM品質判定（トーン一貫性、ブランド適合度）
   - CLIフロー模擬（スキル実行→出力ファイル生成確認）
   - コンテキスト注入検証（書込→自動更新確認）
   - 5つの strategy_type から適切なものを選択する:
     - `structural`: 出力の構造・制約を機械検証（JSONスキーマ、フィールド長等）
     - `api_e2e`: API連鎖フローの検証（複数API呼出の一連シーケンス）
     - `llm_judge`: LLMが出力品質をスコアリング（トーン、品質、一貫性等）
     - `cli_flow`: CLIで対話フロー模擬（コマンド実行→出力ファイル確認）
     - `context_injection`: コンテキスト注入の動作検証（書込→反映確認）

### Layer 1 テスト基準の品質ルール（重要）

各 Layer 1 基準は以下を満たすこと:

1. **behaviors（必須・最低3項目）**: テストが検証すべき具体的な振る舞いを列挙する
   - 「操作 → 期待結果」の形式で記述する
   - 最低構成: 正常系1つ + 異常系1つ + エッジケース1つ
   - 例: 「正しいメールとパスワードでサインアップ → 201 + userId返却」
   - 例: 「既存メールでサインアップ → 409 Conflict」
   - 例: 「パスワード8文字未満でサインアップ → 400 Bad Request」

2. **false_positive_scenario（必須）**: このテスト基準が通ってしまうが品質を保証しないケースを1つ記述する
   - 例: 「ファイル存在確認のみで、実際のHTTPレスポンスコードを検証していない場合」
   - 例: 「テストが常にtrueを返すアサーションだけで構成されている場合」

3. **振る舞いの具体性**: behaviorsは実装の詳細を知らなくても書ける範囲で最大限具体的にする
   - NG: 「認証が正しく動く」（何をもって正しいか不明）
   - OK: 「正しい認証情報でログイン → 200 + JWTトークン返却」
   - NG: 「バリデーションが機能する」
   - OK: 「メール形式不正で登録 → 422 + エラーメッセージにフィールド名を含む」

4. **behaviors の粒度ルール**:
   - 1つの L1 基準あたり 3〜8 項目が目安
   - 8項目を超える場合は L1 基準を分割すること
   - 出力後、以下を自己チェックせよ:
     (1) 各 behavior が1つの操作→結果ペアに対応していること
     (2) 正常系・異常系・エッジケースが各1つ以上含まれていること
     (3) 同じ検証を言い換えただけの重複がないこと

5. **test_type別の追加ルール**:
   - `unit_test`: behaviorsに入出力の具体例を含める（型名、ステータスコード等）
   - `lint`: 検出すべきパターンと検出すべきでないパターンの両方を記述する
   - `type_check`: 型エラーを起こすべき具体的なコードパターンを記述する
   - `api_check`: エンドポイント、メソッド、期待ステータスコードを明記する

### 出力ルール

- 各基準にはユニークなIDを付与する（L1-001, L2-001, L3-001 形式）
- Layer 1 には具体的なテストコマンドの提案を含める
- Layer 1 には behaviors と false_positive_scenario を必ず含める
- Layer 2 には必要な環境変数・前提条件を明記する
- Layer 3 には strategy_type, 評価方法、成功の閾値、definition（command 等）、requires（server 依存の場合）を含める
- assumptions にはリサーチで確認した前提条件を列挙する

### dev-phase（開発フェーズ）定義

実装を3段階の開発フェーズ（dev-phase）に分割する。各dev-phaseには、そのフェーズ完了時に満たすべきexit_criteriaを定義する。

1. **mvp** — 最小限動くもの（E2Eで1フローが動く状態）
   - 最も重要なユーザーフローが1つ動作する状態
   - フロントエンド→API→データストア→表示の一連が繋がること
2. **core** — 機能を一通り揃える
   - 主要なCRUD操作、バリデーション、エラーハンドリングが動作
3. **polish** — エッジケース対応、UI調整
   - エラー画面、レスポンシブ対応、パフォーマンス最適化

各dev-phaseには以下を含める:
- `id`: dev-phase識別子（"mvp" / "core" / "polish"）
- `goal`: そのフェーズの目標（1文）
- `scope_description`: どの機能がこのフェーズに含まれるかの説明
- `criteria_refs`: layer_1_criteria / layer_2_criteria のIDを参照する配列
- `mutation_survival_threshold`: Mutation Auditのsurvival rate閾値（mvp: 0.40, core: 0.30, polish: 0.20）
- `exit_criteria`: フェーズ完了判定条件の配列
  - `type: "auto"` — サーバー起動状態でcurl等で検証可能な条件。`command` と `expect` を含める
  - `type: "human_check"` — 人間の目視確認が必要な条件。`level: "A"`（機能ベースの記述）を含める

## 出力フォーマット

以下のJSON形式のみを出力してください。

```json
{
  "research_id": "{{RESEARCH_ID}}",
  "theme": "{{THEME}}",
  "generated_at": "ISO8601タイムスタンプ",
  "layer_1_criteria": [
    {
      "id": "L1-001",
      "description": "確定的に検証可能な基準の説明",
      "test_type": "unit_test | type_check | lint | api_check",
      "behaviors": [
        "操作1 → 期待結果1（正常系）",
        "操作2 → 期待結果2（異常系）",
        "操作3 → 期待結果3（エッジケース）"
      ],
      "false_positive_scenario": "このテストが通ってしまうが品質を保証しないケース",
      "suggested_command": "テスト実行コマンドの提案"
    }
  ],
  "layer_2_criteria": [
    {
      "id": "L2-001",
      "description": "条件付きで検証可能な基準の説明",
      "test_type": "e2e | integration | schedule",
      "requires": ["必要な環境変数やリソース"],
      "suggested_command": "テスト実行コマンドの提案"
    }
  ],
  "layer_3_criteria": [
    {
      "id": "L3-001",
      "description": "受入テスト基準の説明",
      "strategy_type": "structural | api_e2e | llm_judge | cli_flow | context_injection",
      "evaluation_method": "どのように評価するか",
      "success_threshold": "成功と判断する閾値（llm_judge の場合 0.0〜1.0）",
      "definition": {
        "command": "データ取得・実行コマンド",
        "judge_criteria": ["llm_judge の場合の評価基準"],
        "verify_command": "追加検証コマンド（オプション）",
        "context_file": "context_injection の検証対象ファイル（オプション）"
      },
      "requires": ["server（サーバー依存の場合）"],
      "blocking": true
    }
  ],
  "assumptions": [
    "リサーチで確認・前提とした事項"
  ],
  "phases": [
    {
      "id": "mvp",
      "goal": "最小限のE2Eフローが1つ動く状態",
      "scope_description": "どの機能がMVPに含まれるかの説明",
      "criteria_refs": ["L1-001", "L1-002"],
      "mutation_survival_threshold": 0.40,
      "exit_criteria": [
        {
          "type": "auto",
          "description": "APIがレスポンスを返す",
          "command": "curl -sf {{SERVER_URL}}/api/items",
          "expect": "HTTP 200 + JSON配列"
        },
        {
          "type": "human_check",
          "description": "基本フローがブラウザ上で動作することを確認",
          "level": "A"
        }
      ]
    },
    {
      "id": "core",
      "goal": "主要機能が一通り動作する",
      "scope_description": "主要機能の範囲説明",
      "criteria_refs": ["L1-003", "L1-004"],
      "mutation_survival_threshold": 0.30,
      "exit_criteria": [
        {
          "type": "auto",
          "description": "主要APIが全て動作する",
          "command": "テスト用curlコマンド",
          "expect": "exit code 0"
        },
        {
          "type": "human_check",
          "description": "主要機能の動作確認",
          "level": "A"
        }
      ]
    },
    {
      "id": "polish",
      "goal": "エッジケースで壊れず見た目が整っている",
      "scope_description": "仕上げ範囲の説明",
      "criteria_refs": ["L1-005"],
      "mutation_survival_threshold": 0.20,
      "exit_criteria": [
        {
          "type": "auto",
          "description": "エラーケースで適切なレスポンスを返す",
          "command": "テスト用curlコマンド",
          "expect": "exit code 0"
        },
        {
          "type": "human_check",
          "description": "エッジケース・UI確認",
          "level": "A"
        }
      ]
    }
  ]
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
