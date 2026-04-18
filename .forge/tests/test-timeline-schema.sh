#!/bin/bash
# test-timeline-schema.sh — timeline.json (OpenTimelineIO 骨格) バリデータテスト
#
# 使い方: bash .forge/tests/test-timeline-schema.sh
#
# 必須テスト振る舞い:
#   1. 正しい timeline.json（Timeline>Track>Clip 3階層含む）→ 検証通過
#   2. Track 配列が未定義の timeline.json → 検証失敗 + 'tracks' required エラー
#   3. Clip の source_range が開始>終了（負の duration）→ 検証失敗 + range エラー
#   4. MediaReference の target_url が存在しないパス → 検証失敗（file_exists チェック）
#   5. RenderJob.status が ['pending','running','succeeded','failed'] 以外 → enum 違反で失敗
#   6. timeline.json が 10MB 超 → サイズ警告を出力するが検証自体は通過（polish フェーズ対応）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALIDATOR="${PROJECT_ROOT}/.forge/lib/timeline-validator.sh"
SCHEMA="${PROJECT_ROOT}/.forge/schemas/timeline-schema.json"
FIXTURE_DIR="${PROJECT_ROOT}/tests/fixtures/video/timelines"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

# --- helpers -------------------------------------------------------------
_record_pass() {
  echo -e "  ${GREEN}OK${NC} $1"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
}

_record_fail() {
  echo -e "  ${RED}FAIL${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
}

# assert: 正常系（exit 0 期待）
assert_validator_pass() {
  local label="$1" file="$2"
  local out
  out=$(bash "$VALIDATOR" "$file" 2>&1)
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    _record_pass "$label (exit=0)"
  else
    _record_fail "$label" "expected exit 0, got $rc. output: ${out:0:400}"
  fi
}

# assert: 正常系 + 警告パターンが出力に含まれること
assert_validator_pass_with_warn() {
  local label="$1" file="$2" warn_pattern="$3"
  local out
  out=$(bash "$VALIDATOR" "$file" 2>&1)
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    _record_fail "$label" "expected exit 0, got $rc. output: ${out:0:400}"
    return
  fi
  if echo "$out" | grep -qF "$warn_pattern"; then
    _record_pass "$label (exit=0, warn pattern matched)"
  else
    _record_fail "$label" "expected warning '$warn_pattern' not found. output: ${out:0:400}"
  fi
}

# assert: 失敗系（exit 非0 期待）+ 出力にパターンが含まれること
assert_validator_fail() {
  local label="$1" file="$2" expected_pattern="$3"
  local out
  out=$(bash "$VALIDATOR" "$file" 2>&1)
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    _record_fail "$label" "expected non-zero exit, got 0. output: ${out:0:400}"
    return
  fi
  if echo "$out" | grep -qF "$expected_pattern"; then
    _record_pass "$label (exit=$rc, pattern matched)"
  else
    _record_fail "$label" "expected pattern '$expected_pattern' not found. output: ${out:0:500}"
  fi
}

# --- preflight -----------------------------------------------------------
echo ""
echo -e "${BOLD}=== timeline-schema バリデータテスト ===${NC}"
echo ""

if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}"
  exit 2
fi

for required in "$VALIDATOR" "$SCHEMA" \
                "$FIXTURE_DIR/valid.json" \
                "$FIXTURE_DIR/missing-tracks.json" \
                "$FIXTURE_DIR/bad-range.json" \
                "$FIXTURE_DIR/missing-media.json" \
                "$FIXTURE_DIR/bad-status.json" \
                "$FIXTURE_DIR/large.json" \
                "$FIXTURE_DIR/media/sample.mp4"; do
  if [ ! -e "$required" ]; then
    echo -e "${RED}ERROR: required file missing: $required${NC}"
    exit 2
  fi
done

echo -e "${BOLD}[preflight]${NC} validator + schema + fixtures 存在確認 OK"
echo ""

# --- Group 0: Schema 自体の健全性 --------------------------------------
echo -e "${BOLD}[0] Schema 自体の健全性${NC}"
if jq empty "$SCHEMA" >/dev/null 2>&1; then
  _record_pass "schema ファイルが有効な JSON"
else
  _record_fail "schema ファイルが有効な JSON" "jq parse failed"
fi

# required には id, tracks が含まれていること
for fld in id tracks; do
  if jq -e --arg f "$fld" '.required | index($f) != null' "$SCHEMA" >/dev/null 2>&1; then
    _record_pass "schema required に '${fld}' が含まれる"
  else
    _record_fail "schema required に '${fld}'" "not found"
  fi
done

# Track.kind enum
for k in Video Audio Subtitle; do
  if jq -e --arg v "$k" '.properties.tracks.items.properties.kind.enum | index($v) != null' "$SCHEMA" >/dev/null 2>&1; then
    _record_pass "schema tracks.items.kind.enum に '${k}'"
  else
    _record_fail "schema kind enum '${k}'" "not found"
  fi
done

# RenderJob.status enum の4値
for s in pending running succeeded failed; do
  if jq -e --arg v "$s" '.properties.render_jobs.items.properties.status.enum | index($v) != null' "$SCHEMA" >/dev/null 2>&1; then
    _record_pass "schema render_jobs.status.enum に '${s}'"
  else
    _record_fail "schema render_jobs.status.enum '${s}'" "not found"
  fi
done

# Clip 階層が存在することの確認 (.properties.tracks.items.properties.clips.items)
if jq -e '.properties.tracks.items.properties.clips.items.required | index("source_range") != null' "$SCHEMA" >/dev/null 2>&1; then
  _record_pass "schema に Timeline>Track>Clip の3階層 (source_range required) が定義されている"
else
  _record_fail "schema 3階層定義" "clip.required に source_range が見つからない"
fi

if jq -e '.properties.tracks.items.properties.clips.items.properties.media_reference.required | index("target_url") != null' "$SCHEMA" >/dev/null 2>&1; then
  _record_pass "schema の Clip.media_reference に target_url が required"
else
  _record_fail "schema media_reference" "target_url required 未定義"
fi
echo ""

# --- Group 1: 正常系 -----------------------------------------------------
echo -e "${BOLD}[1] 正常系${NC}"

# behavior: 正しい timeline.json（Timeline>Track>Clip 3階層含む）→ 検証通過
assert_validator_pass \
  "valid.json (Timeline>Track>Clip 3階層) → 検証通過" \
  "$FIXTURE_DIR/valid.json"

# valid.json に実際に3階層が含まれているか（fixture 側の健全性）
clip_count=$(jq '[.tracks[].clips[]] | length' "$FIXTURE_DIR/valid.json" 2>/dev/null)
if [ "${clip_count:-0}" -ge 1 ]; then
  _record_pass "[追加] valid.json に最低1つの Clip が含まれる (count=${clip_count})"
else
  _record_fail "[追加] valid.json の Clip 数" "got ${clip_count}"
fi

# Track 3階層の構造検証 (タイムライン→トラック→クリップ→メディア参照)
if jq -e '.tracks[0].clips[0].media_reference.target_url' "$FIXTURE_DIR/valid.json" >/dev/null 2>&1; then
  _record_pass "[追加] valid.json: Timeline>Track>Clip>MediaReference の4階層をトラバース可能"
else
  _record_fail "[追加] valid.json の階層構造" "tracks[0].clips[0].media_reference.target_url が見つからない"
fi
echo ""

# --- Group 2: Track 配列未定義 ------------------------------------------
echo -e "${BOLD}[2] tracks フィールド欠落${NC}"

# behavior: Track 配列が未定義の timeline.json → 検証失敗 + 'tracks' required エラー
assert_validator_fail \
  "missing-tracks.json (tracks 欠落) → 失敗 + 'tracks' required エラー" \
  "$FIXTURE_DIR/missing-tracks.json" \
  "tracks"

# 厳密: "missing required field" + 'tracks' 両方が含まれる
out=$(bash "$VALIDATOR" "$FIXTURE_DIR/missing-tracks.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "missing required field.*tracks|'tracks'"; then
  _record_pass "[追加] missing-tracks: 'missing required field' 系メッセージに tracks が明記"
else
  _record_fail "[追加] missing-tracks エラーメッセージ厳密性" "output: ${out:0:300}"
fi
echo ""

# --- Group 3: 負の duration (開始>終了) --------------------------------
echo -e "${BOLD}[3] source_range の負 duration（開始>終了）${NC}"

# behavior: Clip の source_range が開始>終了（負の duration）→ 検証失敗 + range エラー
assert_validator_fail \
  "bad-range.json (duration=-3.0) → 失敗 + range エラー" \
  "$FIXTURE_DIR/bad-range.json" \
  "range error"

# 厳密: 'duration' キーワードがエラーに含まれる
out=$(bash "$VALIDATOR" "$FIXTURE_DIR/bad-range.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "duration"; then
  _record_pass "[追加] bad-range: 'duration' がエラーに明記される"
else
  _record_fail "[追加] bad-range duration メッセージ" "output: ${out:0:300}"
fi
echo ""

# --- Group 4: MediaReference.target_url 不在 ----------------------------
echo -e "${BOLD}[4] MediaReference.target_url file_exists チェック${NC}"

# behavior: MediaReference の target_url が存在しないパス → 検証失敗（file_exists チェック）
assert_validator_fail \
  "missing-media.json (target_url 不在) → 失敗 + file_exists エラー" \
  "$FIXTURE_DIR/missing-media.json" \
  "file_exists"

# 厳密: 指定された存在しないパスがエラーに含まれる
out=$(bash "$VALIDATOR" "$FIXTURE_DIR/missing-media.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "this-file-does-not-exist"; then
  _record_pass "[追加] missing-media: 違反 target_url 名がエラーに含まれる"
else
  _record_fail "[追加] missing-media 違反パス名" "output: ${out:0:300}"
fi
echo ""

# --- Group 5: RenderJob.status enum 違反 --------------------------------
echo -e "${BOLD}[5] RenderJob.status enum 違反${NC}"

# behavior: RenderJob.status が ['pending','running','succeeded','failed'] 以外 → enum 違反で失敗
assert_validator_fail \
  "bad-status.json (status='mystery-state') → 失敗 + enum 違反" \
  "$FIXTURE_DIR/bad-status.json" \
  "enum violation"

# 厳密: 違反値 'mystery-state' がエラーに含まれる
out=$(bash "$VALIDATOR" "$FIXTURE_DIR/bad-status.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "mystery-state"; then
  _record_pass "[追加] bad-status: 違反値 'mystery-state' がエラーに含まれる"
else
  _record_fail "[追加] bad-status 違反値" "output: ${out:0:300}"
fi

# 有効 4 値すべてが validator で通ることを確認
# 注意: target_url は valid.json 基準の相対パス ('media/sample.mp4') なので、
# 一時ファイルは FIXTURE_DIR に置かないと相対パス解決が失敗する。
for s in pending running succeeded failed; do
  TMP_RJ="${FIXTURE_DIR}/.tmp-rj-${s}-$$.json"
  jq --arg s "$s" '.render_jobs[0].status = $s' "$FIXTURE_DIR/valid.json" > "$TMP_RJ" 2>/dev/null
  out=$(bash "$VALIDATOR" "$TMP_RJ" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    _record_pass "[追加] render_jobs.status='${s}' → 通過"
  else
    _record_fail "[追加] render_jobs.status='${s}'" "exit=$rc. output: ${out:0:200}"
  fi
  rm -f "$TMP_RJ"
done
echo ""

# --- Group 6: 10MB 超サイズ警告 -----------------------------------------
echo -e "${BOLD}[6] 10MB 超でも検証通過 + WARNING 出力${NC}"

# large.json を基に >10MB の padded コピーを作る
PADDED_LARGE=$(mktemp 2>/dev/null || echo "/tmp/tlv-large-$$.json")
# valid.json と同じ構造（target_url=media/sample.mp4 が解決できるよう同ディレクトリに置く）を使う
# 相対 target_url は timeline.json のあるディレクトリ基準で解決されるため、fixture ディレクトリに一時ファイルを作成する。
PADDED_IN_DIR="${FIXTURE_DIR}/large-padded-runtime.json"

# 10MB 超のパディング文字列を生成 (10,500,000 bytes ≒ 10.02 MB)
# dd + tr で 0x00 を 'A' に変換し効率的に生成
PAD_BYTES=10500000
PAD_FILE=$(mktemp 2>/dev/null || echo "/tmp/tlv-pad-$$.txt")
dd if=/dev/zero bs=1024 count=$((PAD_BYTES / 1024)) status=none 2>/dev/null | tr '\0' 'A' > "$PAD_FILE"

# 安全に JSON に埋め込む: valid.json を読み、padding フィールドを追加
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  PYCMD=$(command -v python3 || command -v python)
  "$PYCMD" - "$FIXTURE_DIR/valid.json" "$PAD_FILE" "$PADDED_IN_DIR" <<'PYEOF'
import json, sys
src, pad, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, 'r', encoding='utf-8') as f:
    data = json.load(f)
with open(pad, 'r', encoding='utf-8') as f:
    data['_large_padding'] = f.read()
with open(out, 'w', encoding='utf-8') as f:
    json.dump(data, f)
PYEOF
else
  # Python が無い場合は jq の --rawfile で埋め込む
  jq --rawfile pad "$PAD_FILE" '. + {_large_padding: $pad}' "$FIXTURE_DIR/valid.json" > "$PADDED_IN_DIR"
fi

# 生成サイズ確認
if [ -f "$PADDED_IN_DIR" ]; then
  actual_sz=$(wc -c <"$PADDED_IN_DIR" | tr -d ' \r')
  if [ "${actual_sz:-0}" -gt 10485760 ] 2>/dev/null; then
    _record_pass "[setup] padded large fixture ${actual_sz} bytes (>10MB) 生成完了"

    # behavior: timeline.json が 10MB 超 → サイズ警告を出力するが検証自体は通過
    assert_validator_pass_with_warn \
      "large(>10MB) → 検証通過 + WARNING 出力" \
      "$PADDED_IN_DIR" \
      "WARNING"

    # 厳密: 'exceeds' や 'threshold' 等のキーワード
    out=$(bash "$VALIDATOR" "$PADDED_IN_DIR" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && echo "$out" | grep -qE "exceeds|threshold|10485760"; then
      _record_pass "[追加] large: 警告メッセージに閾値関連キーワードが含まれる"
    else
      _record_fail "[追加] large 警告内容" "output: ${out:0:400}"
    fi
  else
    _record_fail "[setup] padded large fixture 生成" "size=${actual_sz} (expected >10485760)"
  fi
else
  _record_fail "[setup] padded large fixture 生成" "file not created: $PADDED_IN_DIR"
fi

# 元の fixture (large.json) 自体は小さい（stub）ので検証は通過することを確認
assert_validator_pass \
  "large.json (stub, 小サイズ) → 検証通過（警告なし）" \
  "$FIXTURE_DIR/large.json"

# cleanup
rm -f "$PAD_FILE" "$PADDED_IN_DIR" "$PADDED_LARGE"
echo ""

# --- Group 7: エッジケース ----------------------------------------------
echo -e "${BOLD}[7] エッジケース${NC}"

# 存在しないファイル
out=$(bash "$VALIDATOR" "/nonexistent/path/timeline.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] 存在しないファイル → 失敗 (exit=$rc)"
else
  _record_fail "[追加] 存在しないファイル" "expected non-zero exit"
fi

# 不正 JSON
TMP_BAD_JSON=$(mktemp 2>/dev/null || echo "/tmp/tlv-bad-$$.json")
echo "this is not { valid json" > "$TMP_BAD_JSON"
out=$(bash "$VALIDATOR" "$TMP_BAD_JSON" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "not valid JSON"; then
  _record_pass "[追加] 不正 JSON → 失敗 + 'not valid JSON'"
else
  _record_fail "[追加] 不正 JSON" "output: ${out:0:200}"
fi
rm -f "$TMP_BAD_JSON"

# tracks が空配列 → minItems:1 違反
TMP_EMPTY_TR=$(mktemp 2>/dev/null || echo "/tmp/tlv-empty-tr-$$.json")
echo '{"id":"empty","tracks":[]}' > "$TMP_EMPTY_TR"
out=$(bash "$VALIDATOR" "$TMP_EMPTY_TR" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "empty|minItems"; then
  _record_pass "[追加] tracks 空配列 → 失敗 + empty/minItems"
else
  _record_fail "[追加] tracks 空配列" "output: ${out:0:300}"
fi
rm -f "$TMP_EMPTY_TR"

# Track.kind 未知の値（target_url 相対解決のため FIXTURE_DIR に一時作成）
TMP_BAD_KIND="${FIXTURE_DIR}/.tmp-kind-$$.json"
jq '.tracks[0].kind = "Hologram"' "$FIXTURE_DIR/valid.json" > "$TMP_BAD_KIND" 2>/dev/null
out=$(bash "$VALIDATOR" "$TMP_BAD_KIND" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "enum violation.*kind|kind.*enum"; then
  _record_pass "[追加] Track.kind='Hologram' → enum 違反で失敗"
else
  _record_fail "[追加] Track.kind enum 検証" "output: ${out:0:300}"
fi
rm -f "$TMP_BAD_KIND"
echo ""

# --- Group 8: source 利用 -----------------------------------------------
echo -e "${BOLD}[8] source での利用${NC}"
(
  set +e
  source "$VALIDATOR"
  if declare -F validate_timeline_json >/dev/null; then
    validate_timeline_json "$FIXTURE_DIR/valid.json" >/dev/null 2>&1
    exit $?
  else
    exit 99
  fi
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] source 後に validate_timeline_json を呼び出せる"
else
  _record_fail "[追加] source 後の関数呼び出し" "exit=$rc"
fi
echo ""

# --- サマリー ------------------------------------------------------------
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
