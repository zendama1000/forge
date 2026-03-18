## 対象タスク

タスクID: {{TASK_ID}}

## 実装コード（行番号付き）

{{IMPL_FILES}}

## テストコード

{{TEST_CODE}}

## 必須テスト振る舞い（criteria 由来）

{{REQUIRED_BEHAVIORS}}

## テスト実行コマンド

{{TEST_COMMAND}}

## タスク

上記の実装コードに対する mutation testing 計画を立案してください。

### 手順

1. **実装コードの分析**: 以下のカテゴリに該当する箇所を特定する（行番号を正確に記録すること）
   - 戻り値（ステータスコード、boolean、オブジェクト、null）
   - 条件分岐（if/else、三項演算子、switch）
   - 例外処理（try/catch、throw）
   - 境界値（比較演算子、長さチェック）
   - 早期リターン（guard clause）
   - 関数呼び出し（バリデーション、ミドルウェア）

2. **mutation 設計**: 各箇所に対して mutation を1つ定義する
   - line_start / line_end: 実装コードの行番号（左端に表示されている番号と正確に一致させる）
   - original_hint: 対象行の内容をコピーする（検証用）
   - mutant: 変更後の文字列
   - rationale: この mutation が検出されるべき理由

3. **behavior カバレッジ確認**: 必須テスト振る舞いの各項目に対応する mutation が最低1つ存在することを確認する

4. **mutation 計画の出力**: JSON 形式で出力する

### 行番号の正確性（最重要）

line_start / line_end は mutation-runner.sh が `sed -n` で対象行を取得するために使用する。実装コードの左端に表示されている行番号と正確に一致させること。

- 実装コードは行番号付きで渡されている。その番号をそのまま使う
- 複数行にまたがる変更は line_start と line_end で範囲を指定する
- original_hint には対象行の内容をコピーする（runner が「意図した行か」を検証する安全弁）

```
NG (行番号がズレている):
  "line_start": 40 （実際は42行目）

OK (行番号が正確):
  "line_start": 42,
  "line_end": 42,
  "original_hint": "    return c.json({ userId: user.id }, 201)"
```

### mutation の多様性ルール

- 同一カテゴリ（例: return_value）の mutation が3つ以上連続しないこと
- 最低3つの異なるカテゴリを使用すること
- 可能な限り実装コードの異なる関数/メソッドに分散させること

## 出力フォーマット

以下の JSON 形式のみを出力してください。

```json
{
  "task_id": "{{TASK_ID}}",
  "source_files": ["実装コードのファイルパス"],
  "mutate_target": "mutation対象のメインファイルパス",
  "test_command": "{{TEST_COMMAND}}",
  "mutants": [
    {
      "id": "M-001",
      "category": "return_value | condition_negate | exception_remove | boundary_change | guard_remove | call_remove",
      "target_behavior": "対応する必須テスト振る舞い（該当しない場合は null）",
      "file": "変更対象のファイルパス",
      "line_start": 42,
      "line_end": 42,
      "original_hint": "対象行の内容（検証用）",
      "mutant": "変更後の文字列",
      "rationale": "この mutation が検出されるべき理由"
    }
  ],
  "behavior_coverage": {
    "振る舞い定義1": ["M-001", "M-003"],
    "振る舞い定義2": ["M-002"]
  }
}
```

## 出力形式（厳守）

有効な JSON のみを出力すること。それ以外は一切含めない。

- コードフェンス（```json）禁止
- JSON の前後に説明テキスト禁止
- レスポンスの最初の文字は `{`、最後の文字は `}` であること
