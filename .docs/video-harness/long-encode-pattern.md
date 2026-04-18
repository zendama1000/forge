# Long Encode Pattern — nohup + Progress File 分離実行

10 分を超える ffmpeg エンコードを、Claude Code の Bash サブプロセス終了に巻き込まれずに
完走させるための標準パターン。`.forge/lib/nohup-encoder.sh` が提供するプリミティブを使う。

---

## 1. 背景: なぜ素の `ffmpeg` 呼び出しでは駄目なのか

### 1.1 Claude Code Bash SIGTERM 伝播バグ（Issue #45717, 2026-04 時点未修正）

Claude Code から `Bash` ツール経由でコマンドを実行すると、**親プロセスがタイムアウトや
ユーザ中断で SIGTERM を受けた瞬間、同じプロセスグループの子孫にも SIGTERM が伝播**する。
ffmpeg の大規模エンコードは 10 分を超えることが珍しくなく、途中で親が落ちると成果物が壊れる。

### 1.2 Bash 背景タスクの 10 分上限

Claude Code の `run_in_background: true` も内部的に 600 秒で切られる。forge-flow 全体を
daemonize するのとは別レイヤで、「1 本の長時間コマンド」を分離する仕組みが要る。

### 1.3 要件

- 親プロセス終了 ≠ 子プロセス終了（HUP/TERM の遮断）
- 進捗・完了は**ファイル経由**で非同期に確認（I/O 分離）
- blocking / non-blocking どちらのポーリングも呼出元で選べる
- ffprobe によるメディア検証と `RenderJob.status` 検証が同契約で使える

---

## 2. 分離の三本柱

`nohup-encoder.sh` は以下 3 つを組み合わせて親子プロセスを切り離す:

| 仕組み | 役割 |
|---|---|
| `nohup` | SIGHUP を無視させる（端末切断に強くする） |
| `</dev/null` | stdin を切って端末依存を断つ |
| `disown` | bash の job table から外し、親シェル終了時の暗黙 SIGHUP 送信も防ぐ |

> `setsid` は**挟まない**。setsid fork 後に親が exit すると `$!` が無効 PID になり、
> PID 追跡が壊れるため。nohup + stdin 切断 + disown の 3 つで SIGTERM 伝播 (Issue #45717)
> に対して十分な分離になる（実測検証済み）。

```bash
nohup "$@" </dev/null >>"$log_file" 2>&1 &
pid=$!
disown "$pid" 2>/dev/null || true
```

---

## 3. 基本の使い方（API）

`source` 必須。CLI 単独呼び出しではない。

```bash
source .forge/lib/nohup-encoder.sh

start_long_encode <output_file> <progress_file> <log_file> <pid_file> <cmd> [args...]
wait_for_encode   <progress_file> <output_file> <max_wait_sec> [poll_interval_sec]
read_encode_progress <progress_file>        # stdout: "status=<s> percent=<p>"
is_encode_running    <pid_file>             # rc=0 if alive, rc=1 if exited
stop_encode          <pid_file>             # graceful TERM → 3s → KILL
validate_render_output <output_file> <size_threshold> <job_id> [render_jobs_file]
```

### 3.1 成功例（blocking: 完了まで待つ）

```bash
source .forge/lib/nohup-encoder.sh

OUT=scenarios/slideshow/out/output.mp4
STATE=scenarios/slideshow/out/.render
mkdir -p "$STATE"

start_long_encode \
  "$OUT" \
  "$STATE/progress" \
  "$STATE/ffmpeg.log" \
  "$STATE/ffmpeg.pid" \
  ffmpeg -y -f concat -safe 0 -i inputs/images.txt \
         -vf "scale=1920:1080,fps=30" -c:v libx264 -pix_fmt yuv420p \
         -progress "$STATE/progress" \
         "$OUT"

# 最大 1800 秒、2 秒おきに polling
wait_for_encode "$STATE/progress" "$OUT" 1800 2
rc=$?
[ $rc -eq 0 ] || { echo "encode failed: rc=$rc"; exit 1; }

validate_render_output "$OUT" 102400
```

### 3.2 non-blocking（別タスクで進捗確認）

```bash
# タスク A: 起動だけして返す
start_long_encode "$OUT" "$STATE/progress" "$STATE/ffmpeg.log" "$STATE/ffmpeg.pid" \
  ffmpeg -y -i inputs/source.mp4 ... "$OUT"

# タスク B: 別セッションで状態確認
is_encode_running "$STATE/pid" && read_encode_progress "$STATE/progress"
# status=encoding percent=47
```

---

## 4. Progress File プロトコル

`ffmpeg -progress <file>` と互換の KEY=VALUE 改行区切り形式を採用。`read_encode_progress`
は以下を解釈する:

| キー | 意味 | 例 |
|---|---|---|
| `status` | エンコード状態 | `started` / `encoding` / `completed` / `ended` / `success` / `done` / `failed` / `error` |
| `progress` | status の別名（ffmpeg 互換） | `continue` / `end` |
| `percent` | 進捗 % | `0`〜`100` |
| `started_at` | ISO8601 タイムスタンプ | `2026-04-19T12:34:56+09:00` |

**初期書き込み**: `start_long_encode` が `status=started\npercent=0\nstarted_at=...` を
最初に書き込むので、監視側が空ファイルを読むレースは起きない。

**完了判定 (wait_for_encode)**:
1. progress に `status=completed|ended|success|done` が現れれば即 PASS (rc=0)
2. progress に `status=failed|error` が現れれば即 FAIL (rc=4)
3. progress が無くても `output_file` が空でなく、`pid_file` のプロセスが既に exit 済みなら PASS
4. いずれも満たさず `max_wait` 秒経過 → TIMEOUT (rc=4)

---

## 5. 戻り値契約

### 5.1 `start_long_encode`

| rc | 意味 |
|---|---|
| 0 | 起動成功（PID は `pid_file` に書き出し済み） |
| 2 | 引数不足（`output/progress/log/pid + cmd` が揃っていない） |
| 3 | 実行コマンドが PATH に存在しない / PID 取得失敗 |

### 5.2 `wait_for_encode`

| rc | 意味 |
|---|---|
| 0 | 完了（status=completed 等 または output_file + pid exited） |
| 4 | タイムアウト / status=failed |
| 5 | progress file が消失 / 引数不足 |

### 5.3 `is_encode_running`

| rc | 意味 |
|---|---|
| 0 | 生存 |
| 1 | 終了 |
| 2 | pid_file 不正 |

### 5.4 `validate_render_output`

| rc | 意味 |
|---|---|
| 0 | PASS（ffprobe OK + size >= threshold + RenderJob status = completed） |
| 1 | サイズ不足 |
| 2 | ffprobe 失敗（壊れた mp4 等） |
| 3 | ffprobe 不在 (preflight) |
| 4 | RenderJob.status != completed/succeeded |
| 5 | 引数不足 / ファイル不在 |

---

## 6. render-loop との連携

`render-loop.sh` の各フェーズは以下のパターンで使うのが推奨:

```bash
# 1) shot-encode フェーズ
for shot in "${SHOTS[@]}"; do
  start_long_encode \
    "$OUT_DIR/$shot.mp4" \
    "$STATE_DIR/$shot.progress" \
    "$STATE_DIR/$shot.log" \
    "$STATE_DIR/$shot.pid" \
    ffmpeg "${FFMPEG_ARGS[@]}" "$OUT_DIR/$shot.mp4"
done

# 2) 並列 wait（ショット毎 30 分上限）
for shot in "${SHOTS[@]}"; do
  wait_for_encode "$STATE_DIR/$shot.progress" "$OUT_DIR/$shot.mp4" 1800 2 || \
    { stop_encode "$STATE_DIR/$shot.pid"; exit 1; }
done

# 3) 検証 + RenderJob ステータス整合
validate_render_output "$OUT_DIR/final.mp4" 1048576 "$JOB_ID" "$RENDER_JOBS_FILE"
```

---

## 7. トラブルシュート

### 7.1 `start_long_encode` が rc=3 で落ちる

```
✗ start_long_encode: コマンドが PATH に存在しません: ffmpeg
```
- `ffmpeg` / `ffprobe` を PATH に通す（Windows Git Bash は Scoop/MSYS どちらかで統一）
- `docker run` 経由なら `./forge-docker.sh build` が通っているか確認

### 7.2 `wait_for_encode` が rc=4 TIMEOUT

```
✗ wait_for_encode: timeout after 1800s
```
- `max_wait` を拡張する（素材が長尺なら 3600+ に）
- `ffmpeg -progress <file>` オプションを付け忘れていると progress が更新されず、output_file
  の有無でしか完了判定できなくなる。ffmpeg コマンドに `-progress "$progress_file"` を追加する
- 本当に詰まっているなら `stop_encode` で SIGTERM → SIGKILL

### 7.3 プロセスが残留する（zombie）

```bash
ps -ef | grep ffmpeg
# 古い PID が残っていたら
stop_encode "$STATE/ffmpeg.pid"
```
`stop_encode` は graceful TERM → 3 秒待機 → KILL。`pid_file` を消してから再エンコードする。

### 7.4 `validate_render_output` が rc=2 (ffprobe 失敗)

- 出力が途中で切れた mp4（disk full / SIGKILL 最中）→ 再エンコードが必要
- コンテナ非対応コーデック（prores を mp4 に入れた等）→ `-c:v libx264` など標準に
- `NOHUP_ENC_FFPROBE_TIMEOUT` を長尺用に上書き（既定 60 秒）:
  ```bash
  NOHUP_ENC_FFPROBE_TIMEOUT=300 validate_render_output "$OUT" 1048576
  ```

### 7.5 parent shell 終了後に子が生きているか確認

```bash
# 別ターミナルで
cat scenarios/slideshow/out/.render/ffmpeg.pid
kill -0 $(cat scenarios/slideshow/out/.render/ffmpeg.pid) && echo "ALIVE"
```
`ALIVE` が出れば Issue #45717 に対する分離は機能している。

---

## 8. 設計不変条件（触るとき壊れる箇所）

- **`disown` を外さない**: bash の job table に残していると parent exit 時に SIGHUP が飛ぶ
- **`setsid` を足さない**: fork 親が先に exit すると `$!` が無効 PID になり PID 追跡が壊れる
- **progress file の初期書き込みを削らない**: 監視側との空ファイル読みレースを塞いでいる
- **`validate_render_output` の preflight 順（ffprobe 不在 → rc=3）を変えない**: 「ファイルは
  あるが ffprobe で確認できない」状況を黙って PASS にしないため
- `ffprobe` timeout は `NOHUP_ENC_FFPROBE_TIMEOUT` 環境変数で上書き可能にしてある。長尺動画で
  60 秒では足りない場合は環境変数で明示上書きすること（関数シグネチャには入れない）

---

## 9. 関連ドキュメント

- [scenario-authoring-guide.md](scenario-authoring-guide.md) — scenario.json の書き方全般
- [assertions-reference.md](assertions-reference.md) — `ffprobe_exists` / `size_threshold` 等の詳細
- 実装: [`.forge/lib/nohup-encoder.sh`](../../.forge/lib/nohup-encoder.sh)
- テスト: [`.forge/tests/test-long-encode-nohup.sh`](../../.forge/tests/test-long-encode-nohup.sh)
