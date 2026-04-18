# Assertions Reference

Video Harness の assertion 型リファレンス。`scenario.json.quality_gates.required_mechanical_gates[]`
や `research-config.json.locked_decisions[].assertions[]` から参照できる、機械的検証ビルディング
ブロックの完全一覧。

- 汎用 assertions: `.forge/lib/common.sh` の `run_assertions()` 経由
- 動画ドメイン拡張: [`.forge/lib/video-assertions.sh`](../../.forge/lib/video-assertions.sh)

---

## 1. 全体像: 2 系統の assertion

| 系統 | 定義元 | 用途 | 評価器 |
|---|---|---|---|
| **汎用 assertions** | locked_decisions 直下の `assertions[]` | 設計原則の機械的強制（「Python 禁止」等） | `run_assertions()` (common.sh) |
| **動画 assertions** | 本ドキュメント対象 | 動画ファイルのメタ検証 | `evaluate_video_assertion()` (video-assertions.sh) |

ゲートコマンドからは両方を呼び出せるが、**動画ドメイン固有の検証には 2 系統目を使う**と、
ffprobe 不在などの環境差を preflight で早期に落とせて保守しやすい。

---

## 2. 汎用 assertion 型（`run_assertions()`）

`research-config.json` の `locked_decisions[].assertions[]` で使える 4 型。実装後に ralph-loop
タスクごと・Phase 3 フェーズテストごとに自動検証される。

### 2.1 `file_exists`

指定ファイルが存在することを強制する。

```json
{
  "type": "file_exists",
  "path": "src/lib/ffmpeg-runner.ts",
  "description": "ffmpeg ランナーの実装が存在すること"
}
```

| フィールド | 必須 | 型 | 説明 |
|---|:---:|---|---|
| `type` | ✅ | string | 固定値 `"file_exists"` |
| `path` | ✅ | string | WORK_DIR 基準の相対パス |
| `description` |   | string | 人間向け説明 |

- PASS: パスが regular file として存在する
- FAIL: 存在しない / ディレクトリ / シンボリックリンク破損

### 2.2 `file_absent`

指定ファイルが**存在しない**ことを強制する（禁則の機械的担保）。

```json
{
  "type": "file_absent",
  "path": "src/**/*.py",
  "description": "Python ファイルが作られていないこと（bash/ffmpeg のみの決定）"
}
```

| フィールド | 必須 | 型 | 説明 |
|---|:---:|---|---|
| `type` | ✅ | string | 固定値 `"file_absent"` |
| `path` | ✅ | string | WORK_DIR 基準の相対パス / glob |
| `description` |   | string | 人間向け説明 |

- PASS: マッチ 0 件
- FAIL: 1 件以上マッチ

### 2.3 `grep_present`

指定パターンがコードベース内に**存在する**ことを強制する。

```json
{
  "type": "grep_present",
  "pattern": "ffprobe",
  "glob": "scripts/*.sh",
  "description": "生成物の検証に ffprobe が使われていること"
}
```

| フィールド | 必須 | 型 | 説明 |
|---|:---:|---|---|
| `type` | ✅ | string | 固定値 `"grep_present"` |
| `pattern` | ✅ | string | 正規表現（ripgrep 互換） |
| `glob` |   | string | 対象ファイルの絞り込み（省略時は全体） |
| `except` |   | array[string] | 除外パス / glob（`["vendor/**", "*.lock"]` 等） |
| `description` |   | string | 人間向け説明 |

### 2.4 `grep_absent`

指定パターンがコードベース内に**存在しない**ことを強制する（禁則の担保）。

```json
{
  "type": "grep_absent",
  "pattern": "fetch\\(|axios",
  "glob": "src/**/*.ts",
  "except": ["src/test/**"],
  "description": "HTTP API 呼び出しを含まないこと（CLI/ffmpeg のみの決定）"
}
```

| フィールド | 必須 | 型 | 説明 |
|---|:---:|---|---|
| `type` | ✅ | string | 固定値 `"grep_absent"` |
| `pattern` | ✅ | string | 正規表現 |
| `glob` |   | string | 対象絞り込み |
| `except` |   | array[string] | 除外 |
| `description` |   | string | 人間向け説明 |

### 2.5 注入ポイント（Point A/B/C）

`locked_decisions` の assertions は以下 3 箇所で自動実行される:

| ポイント | 場所 | タイミング |
|---|---|---|
| A | ralph-loop.sh | タスクごと、L1 テスト通過直後 |
| B | generate-tasks.sh | フェーズテストスクリプトに自動注入 |
| C | implementer prompt | 実装前、制約テキストとして追加 |

無効化: `development.json` の `assertions.enabled = false`。

---

## 3. 動画 assertion 型（`video-assertions.sh`）

動画ファイルの機械検証に特化した 3 型。ffprobe 依存型は preflight で PATH 確認し、不在時は
`rc=3`（Preflight failure）で早期失敗する（黙って誤検出 PASS/FAIL を返さない）。

**戻り値契約**:

| rc | 意味 |
|---|---|
| 0 | PASS |
| 1 | FAIL（評価結果が不合格 / 引数エラー） |
| 2 | TypeError（未知の assertion type） |
| 3 | Preflight failure（ffprobe が PATH 不在等） |

### 3.1 `ffprobe_exists`

ファイルが存在し、**ffprobe でメディアコンテナとしてパース可能**であることを検証する。

```bash
# CLI
bash .forge/lib/video-assertions.sh ffprobe_exists scenarios/slideshow/out/output.mp4

# scenario.json quality_gate 経由
{
  "id": "output-parseable",
  "command": "bash .forge/lib/video-assertions.sh ffprobe_exists out/output.mp4",
  "expect": "exit 0",
  "blocking": true
}
```

| 引数 | 必須 | 説明 |
|---|:---:|---|
| `path` | ✅ | 検証対象ファイル |

失敗条件:
- ファイルが存在しない
- regular file ではない（ディレクトリ等）
- ffprobe が PATH に無い
- ffprobe がパースできない（壊れた mp4、テキストファイル等）

### 3.2 `duration_check`

ffprobe で動画の duration を取得し、`|actual - expected| <= tolerance` なら PASS。

```bash
# 出力が 30 秒 ± 1.5 秒の範囲であること
bash .forge/lib/video-assertions.sh duration_check out/output.mp4 30 1.5
```

| 引数 | 必須 | 型 | 説明 |
|---|:---:|---|---|
| `path` | ✅ | string | 検証対象ファイル |
| `expected_sec` | ✅ | number (≥0) | 期待する秒数 |
| `tolerance_sec` |   | number (≥0) | 許容誤差。既定 `0`（完全一致） |

失敗条件:
- path 不在 / ffprobe 不在
- `expected` / `tolerance` が負 or 非数値
- `actual` が `N/A` / 非数値
- `|actual - expected|` > `tolerance`

`ffprobe_exists` と組み合わせると、「パース可能かつ尺が正しいか」を段階的に検証できる。

### 3.3 `size_threshold`

ファイルサイズが閾値範囲に収まるかを検証する。**ffprobe 不要**（`stat` / `wc -c` で取得）なので
ffprobe 不在環境でも動く。

```bash
# 100 KiB 以上、50 MiB 以下
bash .forge/lib/video-assertions.sh size_threshold out/output.mp4 102400 52428800
```

| 引数 | 必須 | 型 | 説明 |
|---|:---:|---|---|
| `path` | ✅ | string | 検証対象ファイル |
| `min_bytes` | ✅ | number (≥0) | 最小サイズ（bytes） |
| `max_bytes` |   | number (≥0) | 最大サイズ（bytes）。省略時は上限なし |

失敗条件:
- path 不在
- `min_bytes` / `max_bytes` が負 or 非数値
- `size < min_bytes` / `size > max_bytes`

用途例: 「空ファイルを `touch` して gate 通過を偽装する」ような低コスト回避策を機械的に塞ぐ。

### 3.4 dispatcher: `evaluate_video_assertion`

`source` した後のプログラマ向け API。CLI と同じ dispatch を関数として呼べる。

```bash
source .forge/lib/video-assertions.sh

evaluate_video_assertion ffprobe_exists out/output.mp4
evaluate_video_assertion duration_check out/output.mp4 30 1.5
evaluate_video_assertion size_threshold out/output.mp4 102400
```

未知の type は `rc=2` で拒否される。preflight（ffprobe PATH 確認）は ffprobe 必要型のみ実行。

---

## 4. 型チェッカー: 既知 type 判定

外部スクリプトから assertion type の妥当性を確認したいとき:

```bash
source .forge/lib/video-assertions.sh
if video_assertion_is_known_type "duration_check"; then
  echo "known"
fi
# 一覧: ${VIDEO_ASSERTION_TYPES[*]}  # => ffprobe_exists duration_check size_threshold
```

---

## 5. エラーコード早見表

| rc | 意味 | 上位ハーネスの扱い |
|---|---|---|
| 0 | PASS | gate = green |
| 1 | FAIL | gate = red（blocking なら即停止） |
| 2 | TypeError（scenario.json のタイポ等） | gate = red、開発者修正必須 |
| 3 | Preflight failure（ffprobe 不在等） | gate = red、環境セットアップ問題 |

`rc=3` を通常 FAIL と区別しておくと、CI で「ffmpeg-suite の setup が漏れている」ケースを
即座に切り分けられる。

---

## 6. 推奨レシピ（scenario.json に入れる組み合わせ）

```json
{
  "quality_gates": {
    "required_mechanical_gates": [
      {
        "id": "output-parseable",
        "description": "出力が mp4 としてパース可能",
        "command": "bash .forge/lib/video-assertions.sh ffprobe_exists out/output.mp4",
        "blocking": true
      },
      {
        "id": "duration-in-range",
        "description": "長さが 30±1.5 秒",
        "command": "bash .forge/lib/video-assertions.sh duration_check out/output.mp4 30 1.5",
        "blocking": true
      },
      {
        "id": "size-not-empty",
        "description": "サイズが最低 100KiB",
        "command": "bash .forge/lib/video-assertions.sh size_threshold out/output.mp4 102400",
        "blocking": true
      }
    ]
  }
}
```

この 3 点セットで「ファイル存在 + 構造正しさ + 中身の密度」を機械的に担保できる。

---

## 7. 関連ドキュメント

- [scenario-authoring-guide.md](scenario-authoring-guide.md) — scenario.json スキーマ全体の書き方
- [long-encode-pattern.md](long-encode-pattern.md) — 長時間エンコードでの assertion 遅延評価
