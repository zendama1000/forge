# Repository Unit Tests

## 概要

このディレクトリには、リポジトリレイヤーのユニットテストが含まれています。
インメモリSQLiteを使用してテストを実行します。

## 実装済みテスト

### world-repository.test.ts

World Repository のCRUD操作をテスト:

1. **create + findById**: 新規作成とID検索
   - ✅ 正常な作成と取得
   - ✅ 存在しないID → null

2. **findByUserId + ページネーション**: ユーザーID検索
   - ✅ ユーザーIDで一覧取得
   - ✅ ページネーション (limit/offset)
   - ✅ 別ユーザーのデータ分離

3. **update + バージョン自動作成**: 更新処理
   - ✅ データ更新成功
   - ✅ バージョン履歴の自動作成
   - ✅ 複数回更新でバージョン番号インクリメント
   - ✅ 存在しないID → null

4. **delete + 論理削除**: 削除処理
   - ✅ 物理削除の実行
   - ✅ 削除後のデータ取得不可
   - ✅ 存在しないID → false

5. **エッジケース**:
   - ✅ 特殊文字の処理
   - ✅ 大きなコンテンツの保存
   - ✅ 空のdescription

## テスト実行方法

### 推奨方法（pnpm/npm経由）

```bash
# package.jsonのscriptを使用
pnpm test:unit:repository

# または直接実行
pnpm vitest run tests/unit/repository/
npx vitest run tests/unit/repository/
```

### 直接実行（PATH問題に注意）

`vitest` コマンドが PATH に無い場合、以下のコマンドは失敗します:

```bash
# ❌ これは失敗する可能性がある
vitest run tests/unit/repository/*.test.ts

# ✅ 代わりにこれを使用
npx vitest run tests/unit/repository/
```

### ラッパースクリプト

PATH問題を回避するため、`scripts/vitest-wrapper.sh` を使用できます:

```bash
./scripts/vitest-wrapper.sh run tests/unit/repository/
```

## テスト結果

全13テスト合格（実行時間: ~7秒）

- ✅ create + findById: 2 tests
- ✅ findByUserId + ページネーション: 3 tests
- ✅ update + バージョン自動作成: 3 tests
- ✅ delete: 3 tests
- ✅ エッジケース: 2 tests

## 注意事項

- テストはインメモリSQLiteを使用（外部DB不要）
- テスト間の独立性を保証（beforeEach/afterEachで初期化）
- 決定的なテスト（同じ入力で毎回同じ結果）
- タイムスタンプ関連のテストは1秒待機（setTimeout使用）
