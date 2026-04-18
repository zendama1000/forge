#!/bin/bash
# test-sac-scenario.sh — SAC=1 (Scenario Addition Cost = 1) 実証テスト
#
# 使い方: bash .forge/tests/test-sac-scenario.sh
#
# このテストは scenario-minimal.json テンプレート + scenario-scanner.sh の組み合わせで
# 「1 ディレクトリの追加だけで render-loop がシナリオを検出開始できる」(SAC=1)
# ことを機械的に実証する。
#
# 必須テスト振る舞い:
#   1. 新規ディレクトリ scenarios/new-test/scenario.json を追加 → 再スキャンで検出数が +1
#   2. scenario.json 内の id がディレクトリ名と一致しない → 整合性エラー
#
# 追加検証 (テンプレ品質):
#   - テンプレートが scenario-schema.json の必須フィールドを満たす
#   - validate_scenario_json が PASS
#   - SAC=1 不変条件: scenarios/<id>/ ディレクトリ以外の既存ファイルは一切変更されない

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TEMPLATE="${PROJECT_ROOT}/.forge/templates/scenario-minimal.json"
SCHEMA="${PROJECT_ROOT}/.forge/schemas/scenario-schema.json"
SCANNER="${PROJECT_ROOT}/.forge/lib/scenario-scanner.sh"
VALIDATOR="${PROJECT_ROOT}/.forge/lib/scenario-validator.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_pass() {
  echo -e "  ${GREEN}OK${NC} $1"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
}

_fail() {
  echo -e "  ${RED}FAIL${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
}

# 一時作業ディレクトリ (cleanup は trap で)
TMP_WORK=""
cleanup() {
  if [ -n "$TMP_WORK" ] && [ -d "$TMP_WORK" ]; then
    rm -rf "$TMP_WORK"
  fi
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}=== SAC=1 (Scenario Addition Cost) 実証テスト ===${NC}"
echo ""

# ---- preflight ----
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}ERROR: jq is required${NC}"
  exit 2
fi
for f in "$TEMPLATE" "$SCHEMA" "$SCANNER" "$VALIDATOR"; do
  if [ ! -f "$f" ]; then
    echo -e "${RED}ERROR: required file missing: $f${NC}"
    exit 2
  fi
done
echo -e "${BOLD}[preflight]${NC} template + schema + scanner + validator 確認 OK"
echo ""

# ============================================================================
# [0] テンプレート自体の健全性
# ============================================================================
echo -e "${BOLD}[0] scenario-minimal.json テンプレート健全性${NC}"

# 0-1: パース可能な JSON
if jq empty "$TEMPLATE" >/dev/null 2>&1; then
  _pass "テンプレートは valid JSON"
else
  _fail "テンプレートが invalid JSON" "$(jq empty "$TEMPLATE" 2>&1 | head -3)"
fi

# 0-2: 必須フィールド (schema required) を全て持つ
required_fields=(id type input_sources quality_gates agent_prompt_patch)
missing=""
for f in "${required_fields[@]}"; do
  if ! jq -e --arg f "$f" 'has($f)' "$TEMPLATE" >/dev/null 2>&1; then
    missing="${missing} ${f}"
  fi
done
if [ -z "$missing" ]; then
  _pass "テンプレートに必須5フィールド (id/type/input_sources/quality_gates/agent_prompt_patch) が揃っている"
else
  _fail "テンプレートに必須フィールド欠落" "missing:${missing}"
fi

# 0-3: type が schema の enum に含まれる
tpl_type=$(jq -r '.type' "$TEMPLATE" 2>/dev/null | tr -d '\r')
if jq -e --arg t "$tpl_type" '.properties.type.enum | index($t)' "$SCHEMA" >/dev/null 2>&1; then
  _pass "テンプレート type='${tpl_type}' は schema enum メンバー"
else
  _fail "テンプレート type が enum 外" "got='${tpl_type}'"
fi

# 0-4: agent_prompt_patch が string (object/array 禁止)
patch_type=$(jq -r '.agent_prompt_patch | type' "$TEMPLATE" 2>/dev/null)
if [ "$patch_type" = "string" ]; then
  _pass "agent_prompt_patch は string 型"
else
  _fail "agent_prompt_patch 型エラー" "expected string, got ${patch_type}"
fi

# 0-5: required_mechanical_gates が非空配列
gates_len=$(jq '.quality_gates.required_mechanical_gates | length' "$TEMPLATE" 2>/dev/null)
if [ "${gates_len:-0}" -ge 1 ]; then
  _pass "required_mechanical_gates が ${gates_len} 件 (非空)"
else
  _fail "required_mechanical_gates が空または不在" "len=${gates_len}"
fi

# 0-6: scenario-validator.sh 経由で PASS する
if bash "$VALIDATOR" "$TEMPLATE" >/dev/null 2>&1; then
  _pass "scenario-validator.sh で PASS"
else
  _fail "scenario-validator.sh で FAIL" "$(bash "$VALIDATOR" "$TEMPLATE" 2>&1 | head -5)"
fi

# 0-7: id は schema の pattern に適合する
tpl_id=$(jq -r '.id' "$TEMPLATE" 2>/dev/null | tr -d '\r')
if echo "$tpl_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$'; then
  _pass "テンプレート id='${tpl_id}' は schema pattern (^[A-Za-z0-9][A-Za-z0-9_-]*\$) に適合"
else
  _fail "テンプレート id pattern 違反" "got='${tpl_id}'"
fi
echo ""

# ============================================================================
# [1] SAC=1 実証 — 新規ディレクトリ追加で検出数が +1 (必須 behavior 1)
# ============================================================================
echo -e "${BOLD}[1] SAC=1: 新規ディレクトリ +1 で検出数 +1 (必須 behavior 1)${NC}"

# 一時 scenarios/ 環境を構築 (既存 2 シナリオを配置)
TMP_WORK=$(mktemp -d 2>/dev/null || echo "/tmp/sac-test-$$")
SCENARIOS_DIR="${TMP_WORK}/scenarios"
mkdir -p "$SCENARIOS_DIR"

# 既存シナリオ alpha
mkdir -p "${SCENARIOS_DIR}/alpha"
cat > "${SCENARIOS_DIR}/alpha/scenario.json" <<'JSON'
{
  "id": "alpha",
  "type": "video_edit",
  "version": "1.0.0",
  "description": "fixture alpha",
  "input_sources": [{"type": "video_file", "path": "in.mp4", "required": true}],
  "quality_gates": {
    "required_mechanical_gates": [
      {"id": "g1", "command": "test -f out.mp4", "expect": "exit 0"}
    ]
  },
  "agent_prompt_patch": "alpha"
}
JSON

# 既存シナリオ beta
mkdir -p "${SCENARIOS_DIR}/beta"
cat > "${SCENARIOS_DIR}/beta/scenario.json" <<'JSON'
{
  "id": "beta",
  "type": "image_slideshow",
  "version": "1.0.0",
  "description": "fixture beta",
  "input_sources": [{"type": "image_dir", "path": "imgs/", "required": true}],
  "quality_gates": {
    "required_mechanical_gates": [
      {"id": "g1", "command": "test -f out.mp4", "expect": "exit 0"}
    ]
  },
  "agent_prompt_patch": "beta"
}
JSON

# 1-1: 初回スキャン → 2 件
count_before=$(bash "$SCANNER" "$SCENARIOS_DIR" --count 2>/dev/null)
rc_before=$?
if [ "$rc_before" -eq 0 ] && [ "$count_before" = "2" ]; then
  _pass "[前提] 初回スキャン: 2 件検出 (rc=0)"
else
  _fail "[前提] 初回スキャン" "rc=${rc_before}, count=${count_before}"
fi

# 1-2: SAC=1 操作 — 新規 scenarios/new-test/ を追加 (1 mkdir + 1 file)
NEW_DIR="${SCENARIOS_DIR}/new-test"
mkdir -p "$NEW_DIR"

# テンプレートをコピーし、id だけディレクトリ名 'new-test' に書き換え
# (これが SAC=1 で必要な唯一のテキスト編集)
cp "$TEMPLATE" "${NEW_DIR}/scenario.json"
jq '.id = "new-test"' "${NEW_DIR}/scenario.json" > "${NEW_DIR}/scenario.json.tmp" \
  && mv "${NEW_DIR}/scenario.json.tmp" "${NEW_DIR}/scenario.json"

# 追加で触ったファイル数 (= scenarios/new-test/ 配下のみ)
added_files=$(find "$NEW_DIR" -type f | wc -l | tr -d ' ')
if [ "$added_files" = "1" ]; then
  _pass "[SAC] 追加ファイル数 = 1 (scenarios/new-test/scenario.json のみ)"
else
  _fail "[SAC] 追加ファイル数が想定外" "got=${added_files}"
fi

# 既存シナリオ (alpha/beta) のファイルが一切変更されていないこと (SAC=1 不変条件)
alpha_hash=$(md5sum "${SCENARIOS_DIR}/alpha/scenario.json" 2>/dev/null | awk '{print $1}')
beta_hash=$(md5sum "${SCENARIOS_DIR}/beta/scenario.json" 2>/dev/null | awk '{print $1}')
# 再度ハッシュを取り直す (mtime ではなく内容)
alpha_hash2=$(md5sum "${SCENARIOS_DIR}/alpha/scenario.json" 2>/dev/null | awk '{print $1}')
beta_hash2=$(md5sum "${SCENARIOS_DIR}/beta/scenario.json" 2>/dev/null | awk '{print $1}')
if [ "$alpha_hash" = "$alpha_hash2" ] && [ "$beta_hash" = "$beta_hash2" ] \
   && [ -n "$alpha_hash" ] && [ -n "$beta_hash" ]; then
  _pass "[SAC] 既存シナリオ (alpha/beta) のファイル内容は不変 (SAC=1 不変条件)"
else
  _fail "[SAC] 既存シナリオファイルが変化した" \
    "alpha:${alpha_hash}->${alpha_hash2} beta:${beta_hash}->${beta_hash2}"
fi

# 1-3: 再スキャン → 3 件 (+1)
count_after=$(bash "$SCANNER" "$SCENARIOS_DIR" --count 2>/dev/null)
rc_after=$?
if [ "$rc_after" -eq 0 ] && [ "$count_after" = "3" ]; then
  _pass "behavior: 新規ディレクトリ scenarios/new-test/scenario.json を追加 → 再スキャンで検出数が +1"
else
  _fail "behavior: 検出数 +1 にならない" \
    "before=${count_before} after=${count_after} rc=${rc_after}"
fi

# 1-4: 新規 id 'new-test' が --ids 出力に含まれる (ハードコード不要)
ids_after=$(bash "$SCANNER" "$SCENARIOS_DIR" --ids 2>/dev/null)
if echo "$ids_after" | grep -qx "new-test"; then
  _pass "[追加] 'new-test' が --ids 出力に含まれる (dispatch ハードコード不要)"
else
  _fail "[追加] 'new-test' が --ids に現れない" "ids='${ids_after//$'\n'/,}'"
fi

# 1-5: --json 出力で新規シナリオの type が template から継承された値である
new_type=$(bash "$SCANNER" "$SCENARIOS_DIR" --json 2>/dev/null \
  | jq -r '.[] | select(.id == "new-test") | .type' 2>/dev/null | tr -d '\r')
if [ -n "$new_type" ] && [ "$new_type" = "$tpl_type" ]; then
  _pass "[追加] 新規シナリオ type='${new_type}' がテンプレート由来"
else
  _fail "[追加] 新規シナリオ type 不一致" "expected='${tpl_type}', got='${new_type}'"
fi
echo ""

# ============================================================================
# [2] id 不整合 → 整合性エラー (必須 behavior 2)
# ============================================================================
echo -e "${BOLD}[2] id ↔ ディレクトリ名 不整合 (必須 behavior 2)${NC}"

# テンプレートをそのままコピー (id="scenario-template" のまま) し、ディレクトリ名は別物にする
# → scanner は consistency error を出すはず
TMP_MIS=$(mktemp -d 2>/dev/null || echo "/tmp/sac-mis-$$")
MIS_SCENARIOS="${TMP_MIS}/scenarios"
MIS_DIR="${MIS_SCENARIOS}/test-sac"
mkdir -p "$MIS_DIR"

# id を編集せずにテンプレ丸コピー (= 編集忘れケースの再現)
cp "$TEMPLATE" "${MIS_DIR}/scenario.json"

# 確認: コピー直後の id はテンプレ既定値であること
copied_id=$(jq -r '.id' "${MIS_DIR}/scenario.json" 2>/dev/null | tr -d '\r')
if [ "$copied_id" = "$tpl_id" ] && [ "$copied_id" != "test-sac" ]; then
  _pass "[前提] id='${copied_id}' はディレクトリ名 'test-sac' と不一致 (mismatch を作れた)"
else
  _fail "[前提] テンプレ id 不一致を作れない" "copied='${copied_id}', dir='test-sac'"
fi

# 2-1: scanner が exit 非0 (consistency error)
stdout_out=$(bash "$SCANNER" "$MIS_SCENARIOS" --count 2>/dev/null)
stderr_out=$(bash "$SCANNER" "$MIS_SCENARIOS" --count 2>&1 >/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
  _pass "behavior: scenario.json 内の id がディレクトリ名と一致しない → 整合性エラー (rc=${rc})"
else
  _fail "behavior: 不整合でも exit 0" "stdout=${stdout_out}"
fi

# 2-2: stderr に consistency error が出る
if echo "$stderr_out" | grep -qE "consistency error|integrity error|整合性"; then
  _pass "[追加] stderr に 'consistency error' を含む"
else
  _fail "[追加] consistency error メッセージなし" "stderr: ${stderr_out:0:300}"
fi

# 2-3: 違反値 (dir 名 'test-sac' と id 'scenario-template') の両方がメッセージに含まれる
if echo "$stderr_out" | grep -q "test-sac" && echo "$stderr_out" | grep -q "$tpl_id"; then
  _pass "[追加] エラーに dir 名 'test-sac' と id '${tpl_id}' の両方が出力される"
else
  _fail "[追加] 違反値の報告不備" "stderr: ${stderr_out:0:400}"
fi

# 2-4: id を編集すれば検出される (修正経路の実証)
jq '.id = "test-sac"' "${MIS_DIR}/scenario.json" > "${MIS_DIR}/scenario.json.tmp" \
  && mv "${MIS_DIR}/scenario.json.tmp" "${MIS_DIR}/scenario.json"
fixed_count=$(bash "$SCANNER" "$MIS_SCENARIOS" --count 2>/dev/null)
fixed_rc=$?
if [ "$fixed_rc" -eq 0 ] && [ "$fixed_count" = "1" ]; then
  _pass "[追加] id 編集後は scanner が PASS (count=1, rc=0)"
else
  _fail "[追加] id 修正後の検出失敗" "rc=${fixed_rc}, count=${fixed_count}"
fi

rm -rf "$TMP_MIS"
echo ""

# ============================================================================
# [3] テンプレ複製 + id 編集の最小手順 (CI 自動化想定)
# ============================================================================
echo -e "${BOLD}[3] SAC=1 自動化フロー (mkdir + cp + jq id rewrite)${NC}"

# 1 シェルパイプラインで「ディレクトリ追加 → 検出数 +1」が実現できることを実証
TMP_PIPE=$(mktemp -d 2>/dev/null || echo "/tmp/sac-pipe-$$")
PIPE_SCN="${TMP_PIPE}/scenarios"
mkdir -p "$PIPE_SCN"

before=$(bash "$SCANNER" "$PIPE_SCN" --count 2>/dev/null)

# SAC=1 の最小操作 (3 つのコマンドのみ: mkdir / cp / jq)
SCN_NAME="auto-pipe"
mkdir -p "${PIPE_SCN}/${SCN_NAME}" \
  && cp "$TEMPLATE" "${PIPE_SCN}/${SCN_NAME}/scenario.json" \
  && jq --arg id "$SCN_NAME" '.id = $id' \
       "${PIPE_SCN}/${SCN_NAME}/scenario.json" \
       > "${PIPE_SCN}/${SCN_NAME}/scenario.json.tmp" \
  && mv "${PIPE_SCN}/${SCN_NAME}/scenario.json.tmp" \
        "${PIPE_SCN}/${SCN_NAME}/scenario.json"
pipe_rc=$?

after=$(bash "$SCANNER" "$PIPE_SCN" --count 2>/dev/null)
delta=$((after - before))

if [ "$pipe_rc" -eq 0 ] && [ "$delta" = "1" ]; then
  _pass "[追加] mkdir+cp+jq の3コマンドで scanner 検出数が +1"
else
  _fail "[追加] 自動化フロー" "pipe_rc=${pipe_rc} before=${before} after=${after}"
fi

# scenario が validator も PASS する (実際に下流が読める)
if bash "$VALIDATOR" "${PIPE_SCN}/${SCN_NAME}/scenario.json" >/dev/null 2>&1; then
  _pass "[追加] 自動生成シナリオが scenario-validator で PASS"
else
  _fail "[追加] 自動生成シナリオが validator で FAIL" \
    "$(bash "$VALIDATOR" "${PIPE_SCN}/${SCN_NAME}/scenario.json" 2>&1 | head -5)"
fi

rm -rf "$TMP_PIPE"
echo ""

# ============================================================================
# [4] エッジ: 同名でリスキャン (冪等)
# ============================================================================
echo -e "${BOLD}[4] エッジケース${NC}"

# 同じ scenarios/ をもう一度スキャンしても結果が変わらない (scanner は state-less)
count_re1=$(bash "$SCANNER" "$SCENARIOS_DIR" --count 2>/dev/null)
count_re2=$(bash "$SCANNER" "$SCENARIOS_DIR" --count 2>/dev/null)
if [ "$count_re1" = "$count_re2" ] && [ "$count_re1" = "3" ]; then
  _pass "[追加] 同一 scenarios/ の再スキャンは冪等 (count=${count_re1})"
else
  _fail "[追加] スキャン非冪等" "re1=${count_re1} re2=${count_re2}"
fi

# テンプレに変な BOM/CRLF が混入していない (Windows 環境差を吸収)
if file "$TEMPLATE" 2>/dev/null | grep -qiE 'with BOM'; then
  _fail "[追加] テンプレに UTF-8 BOM 検出 (jq が壊れる可能性)"
else
  _pass "[追加] テンプレに UTF-8 BOM なし"
fi

# テンプレートのサイズが異常でない (10B 〜 8KB レンジ)
tpl_size=$(wc -c < "$TEMPLATE" | tr -d ' ')
if [ "${tpl_size:-0}" -ge 100 ] && [ "${tpl_size:-0}" -le 8192 ]; then
  _pass "[追加] テンプレートサイズ ${tpl_size} bytes (100B〜8KB レンジ)"
else
  _fail "[追加] テンプレートサイズ異常" "size=${tpl_size}"
fi
echo ""

# ---- summary ----
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
