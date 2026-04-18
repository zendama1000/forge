#!/bin/bash
# test-video-prerequisites.sh — video-prerequisites.sh の Layer 1 テスト
#
# 使い方: bash .forge/tests/test-video-prerequisites.sh
#
# 必須テスト振る舞い（required_behaviors）:
#   1. 全項目満たしたディレクトリ → check_video_prerequisites → exit 0
#   2. .gitignore に 'node_modules/' 未記載 → FAIL + 該当項目を報告
#   3. .gitattributes に '* text=auto eol=lf' 未設定（Windows環境）→ WARN を報告
#   4. OneDrive 配下（パスに 'OneDrive' を含む）→ CRITICAL エラー
#   5. disk 残量 < 5GB → FAIL + 残量値を報告
#   6. development.json server.start_command が 'none' 以外 → WARN（動画ハーネスでは不要）
#
# 設計:
#   - 決定的に動かすため各ケースで mktemp 配下に fixture を展開し git init
#   - disk 残量は VPREREQ_DISK_OVERRIDE_GB で決定的に注入
#   - Windows .gitattributes WARN は VPREREQ_FORCE_WINDOWS=1 でホスト OS 非依存
#   - development.json は VPREREQ_DEV_JSON で本体に影響せずモック
#   - 各ケースで「他のチェックは通る」よう正当な fixture ベースで差分注入

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VP_LIB="${PROJECT_ROOT}/.forge/lib/video-prerequisites.sh"
FIXTURE_DIR="${PROJECT_ROOT}/tests/fixtures/video/prereq"
SAMPLE_GITIGNORE="${FIXTURE_DIR}/valid.gitignore"
SAMPLE_GITATTRIBUTES="${FIXTURE_DIR}/valid.gitattributes"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

_record_pass() {
  echo -e "  ${GREEN}✓${NC} $1"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
}

_record_fail() {
  echo -e "  ${RED}✗${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
}

# --- preflight ------------------------------------------------------------
echo ""
echo -e "${BOLD}=== video-prerequisites テスト ===${NC}"
echo ""

for required in "$VP_LIB" "$SAMPLE_GITIGNORE" "$SAMPLE_GITATTRIBUTES"; do
  if [ ! -f "$required" ]; then
    echo -e "${RED}ERROR: required file missing: $required${NC}"
    exit 2
  fi
done

for tool in git jq awk df grep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: required tool not found: $tool${NC}"
    exit 2
  fi
done

# サンプルが期待内容を実際に含むか検証（壊れた fixture の早期検出）
if ! grep -Eq '^[[:space:]]*/?node_modules/?[[:space:]]*$' "$SAMPLE_GITIGNORE"; then
  echo -e "${RED}ERROR: sample gitignore does not contain 'node_modules/'${NC}"
  exit 2
fi
if ! grep -Eq '^\*[[:space:]]+text=auto[[:space:]]+eol=lf' "$SAMPLE_GITATTRIBUTES"; then
  echo -e "${RED}ERROR: sample gitattributes does not declare '* text=auto eol=lf'${NC}"
  exit 2
fi

# 作業領域
STAGE_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/vp-stage-$$")"
mkdir -p "$STAGE_DIR"

# development.json モック（server.start_command='none'）
MOCK_DEV_OK="${STAGE_DIR}/dev-ok.json"
cat >"$MOCK_DEV_OK" <<'EOF'
{
  "server": {
    "start_command": "none",
    "health_check_url": "http://localhost:3001"
  }
}
EOF

# development.json モック（server.start_command='npm run dev' — 'none' 以外）
MOCK_DEV_BAD="${STAGE_DIR}/dev-bad.json"
cat >"$MOCK_DEV_BAD" <<'EOF'
{
  "server": {
    "start_command": "npm run dev",
    "health_check_url": "http://localhost:3001"
  }
}
EOF

cleanup() {
  # 強制削除（.git/ 含むため chmod を試みる）
  if [ -d "$STAGE_DIR" ]; then
    chmod -R u+rwX "$STAGE_DIR" 2>/dev/null || true
    rm -rf "$STAGE_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo -e "${BOLD}[preflight]${NC} library + fixtures + tools OK"
echo -e "  stage_dir  : $STAGE_DIR"
echo ""

# fixture をコピーして git init 済みのディレクトリを作る
# $1: scenario name, $2: include_gitignore (1|0), $3: include_gitattributes (1|0)
# $4(optional): subpath (e.g. "OneDrive-sim/work")
make_fixture() {
  local name="$1" with_gi="$2" with_ga="$3" subpath="${4:-}"
  local target
  if [ -n "$subpath" ]; then
    target="${STAGE_DIR}/${subpath}"
  else
    target="${STAGE_DIR}/${name}"
  fi
  mkdir -p "$target"
  if [ "$with_gi" = "1" ]; then
    cp "$SAMPLE_GITIGNORE" "${target}/.gitignore"
  fi
  if [ "$with_ga" = "1" ]; then
    cp "$SAMPLE_GITATTRIBUTES" "${target}/.gitattributes"
  fi
  (cd "$target" && git init -q && git add -A 2>/dev/null \
      && git -c user.email=test@example.com -c user.name=test commit -q -m "init" >/dev/null 2>&1) \
      || true
  echo "$target"
}

# library 関数が source 可能であること
# shellcheck disable=SC1090
source "$VP_LIB"
if ! declare -F check_video_prerequisites >/dev/null; then
  echo -e "${RED}ERROR: check_video_prerequisites not defined after source${NC}"
  exit 2
fi

# -------------------------------------------------------------------------
# Group 1: 全項目満たしたディレクトリ → exit 0
# -------------------------------------------------------------------------
echo -e "${BOLD}[1] 正常系: 全項目 OK${NC}"

OK_DIR="$(make_fixture "ok" "1" "1")"
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=1  # .gitattributes チェックを強制的に走らせる（ok fixture に存在するので WARN は出ない）
  bash "$VP_LIB" "$OK_DIR" 2>&1
)
rc=$?
# behavior: 全項目満たしたディレクトリ → check_video_prerequisites → exit 0
if [ "$rc" -eq 0 ]; then
  _record_pass "behavior: 全項目満たしたディレクトリ → exit 0"
else
  _record_fail "behavior: 全項目満たしたディレクトリ → exit 0" "rc=$rc output: ${out:0:400}"
fi

# [追加] OK 時の出力に CRITICAL/FAIL が含まれない
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE '^CRITICAL:|^FAIL:'; then
  _record_pass "[追加] OK 時: CRITICAL/FAIL ラベルが出力されない"
else
  _record_fail "[追加] OK 時 CRITICAL/FAIL なし" "output: ${out:0:400}"
fi

# [追加] OK 時の出力に PASSED が含まれる
if echo "$out" | grep -qE "prerequisites check PASSED"; then
  _record_pass "[追加] OK 時: 'prerequisites check PASSED' メッセージを含む"
else
  _record_fail "[追加] OK 時 PASSED メッセージ" "output: ${out:0:400}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 2: .gitignore に 'node_modules/' 未記載 → FAIL
# -------------------------------------------------------------------------
echo -e "${BOLD}[2] .gitignore に node_modules/ 未記載${NC}"

# 2a: .gitignore そのものが存在しない
NO_GI_DIR="$(make_fixture "no-gitignore" "0" "1")"
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$NO_GI_DIR" 2>&1
)
rc=$?
# behavior: .gitignore に 'node_modules/' 未記載 → FAIL + 該当項目を報告
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*\.gitignore'; then
  _record_pass "behavior: .gitignore 不在 → FAIL + '.gitignore' を報告"
else
  _record_fail "behavior: .gitignore 不在 FAIL 系" "rc=$rc output: ${out:0:400}"
fi

# [追加] .gitignore 不在メッセージに 'node_modules' が含まれる（推奨エントリ明示）
if echo "$out" | grep -q 'node_modules'; then
  _record_pass "[追加] .gitignore 不在メッセージに 'node_modules' 要件が含まれる"
else
  _record_fail "[追加] .gitignore 不在 node_modules 言及" "output: ${out:0:400}"
fi

# 2b: .gitignore は存在するが node_modules/ エントリを欠く
BAD_GI_DIR="${STAGE_DIR}/bad-gitignore"
mkdir -p "$BAD_GI_DIR"
cat >"${BAD_GI_DIR}/.gitignore" <<'EOF'
# This file lacks the required node_modules line
.env
dist/
EOF
cp "$SAMPLE_GITATTRIBUTES" "${BAD_GI_DIR}/.gitattributes"
(cd "$BAD_GI_DIR" && git init -q && git add -A \
    && git -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1) || true

out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$BAD_GI_DIR" 2>&1
)
rc=$?
# behavior (strict): .gitignore 存在するが内容欠陥 → FAIL
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*node_modules'; then
  _record_pass "behavior: .gitignore 内容欠陥（node_modules/ 未記載）→ FAIL + 'node_modules' を報告"
else
  _record_fail "behavior: .gitignore 内容欠陥 FAIL 系" "rc=$rc output: ${out:0:400}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 3: .gitattributes 未設定（Windows環境）→ WARN
# -------------------------------------------------------------------------
echo -e "${BOLD}[3] .gitattributes eol=lf 未設定 (Windows) → WARN${NC}"

NO_GA_DIR="$(make_fixture "no-gitattributes" "1" "0")"
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=1   # Windows 扱い強制
  bash "$VP_LIB" "$NO_GA_DIR" 2>&1
)
rc=$?
# behavior: .gitattributes に '* text=auto eol=lf' 未設定（Windows環境）→ WARN を報告
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE '^WARN:.*\.gitattributes'; then
  _record_pass "behavior: .gitattributes 未設定 (Windows) → WARN を報告 + exit 0"
else
  _record_fail "behavior: .gitattributes 未設定 WARN 系" "rc=$rc output: ${out:0:400}"
fi

# [追加] 非 Windows 環境では .gitattributes チェック自体が走らず WARN 出ない
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0   # 非 Windows 扱い
  bash "$VP_LIB" "$NO_GA_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE '^WARN:.*\.gitattributes'; then
  _record_pass "[追加] 非 Windows 環境では .gitattributes の WARN が出ない"
else
  _record_fail "[追加] 非 Windows .gitattributes 抑制" "rc=$rc output: ${out:0:400}"
fi

# [追加] .gitattributes が存在するが内容欠陥（text=auto eol=lf 無し）→ Windows WARN
BAD_GA_DIR="${STAGE_DIR}/bad-gitattributes"
mkdir -p "$BAD_GA_DIR"
cp "$SAMPLE_GITIGNORE" "${BAD_GA_DIR}/.gitignore"
cat >"${BAD_GA_DIR}/.gitattributes" <<'EOF'
*.png binary
EOF
(cd "$BAD_GA_DIR" && git init -q && git add -A \
    && git -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1) || true

out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=1
  bash "$VP_LIB" "$BAD_GA_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE '^WARN:.*\.gitattributes' && echo "$out" | grep -qE 'eol=lf|text=auto'; then
  _record_pass "[追加] .gitattributes 存在するが eol=lf 無し (Windows) → WARN"
else
  _record_fail "[追加] .gitattributes 内容欠陥 WARN" "rc=$rc output: ${out:0:400}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 4: OneDrive 配下 → CRITICAL
# -------------------------------------------------------------------------
echo -e "${BOLD}[4] OneDrive パス混入 → CRITICAL${NC}"

# fixture を $STAGE_DIR/OneDrive-sim/work に展開して abs path に "OneDrive" が入るようにする
OD_DIR="$(make_fixture "onedrive-path" "1" "1" "OneDrive-sim/work")"
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=1
  bash "$VP_LIB" "$OD_DIR" 2>&1
)
rc=$?
# behavior: OneDrive 配下（パスに 'OneDrive' を含む）→ CRITICAL エラー
if [ "$rc" -eq 2 ] && echo "$out" | grep -qE '^CRITICAL:.*OneDrive'; then
  _record_pass "behavior: OneDrive 配下 → CRITICAL + exit 2"
else
  _record_fail "behavior: OneDrive CRITICAL 系" "rc=$rc output: ${out:0:500}"
fi

# [追加] 非 OneDrive パスでは CRITICAL 出ない
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=1
  bash "$VP_LIB" "$OK_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE '^CRITICAL:'; then
  _record_pass "[追加] 非 OneDrive パス → CRITICAL 出現なし"
else
  _record_fail "[追加] 非 OneDrive 誤検出" "rc=$rc output: ${out:0:400}"
fi

# [追加] case-insensitive: 小文字 onedrive も検出
OD_LOWER_DIR="$(make_fixture "onedrive-lower" "1" "1" "onedrive-lower-case/work")"
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=1
  bash "$VP_LIB" "$OD_LOWER_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -qiE '^CRITICAL:.*onedrive'; then
  _record_pass "[追加] 小文字 'onedrive' も case-insensitive で CRITICAL 検出"
else
  _record_fail "[追加] 小文字 onedrive 検出" "rc=$rc output: ${out:0:400}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 5: disk 残量 < 5GB → FAIL
# -------------------------------------------------------------------------
echo -e "${BOLD}[5] disk 残量 < 5GB → FAIL${NC}"

LOW_DISK_DIR="$(make_fixture "low-disk" "1" "1")"
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=3    # 5GB 未満
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$LOW_DISK_DIR" 2>&1
)
rc=$?
# behavior: disk 残量 < 5GB → FAIL + 残量値を報告
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*disk.*3GB'; then
  _record_pass "behavior: disk 残量=3GB < 5GB → FAIL + '3GB' を報告"
else
  _record_fail "behavior: disk < 5GB FAIL 系" "rc=$rc output: ${out:0:500}"
fi

# [追加] 閾値境界: 残量=4 < 5 → FAIL
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=4
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$LOW_DISK_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*disk.*4GB'; then
  _record_pass "[追加] disk=4GB (5GB 境界未満) → FAIL"
else
  _record_fail "[追加] disk=4GB 境界" "rc=$rc output: ${out:0:400}"
fi

# [追加] 閾値境界: 残量=5 >= 5 → PASS（disk FAIL 出ない）
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=5
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$LOW_DISK_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE '^FAIL:.*disk'; then
  _record_pass "[追加] disk=5GB (境界上) → PASS + disk FAIL 出ない"
else
  _record_fail "[追加] disk=5GB 境界" "rc=$rc output: ${out:0:400}"
fi

# [追加] 上書き閾値 VPREREQ_MIN_DISK_GB=10, disk=8 → FAIL
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=8
  export VPREREQ_MIN_DISK_GB=10
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$LOW_DISK_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE '^FAIL:.*disk.*8GB.*10GB'; then
  _record_pass "[追加] 閾値上書き MIN=10, disk=8 → FAIL + '8GB' と '10GB' 両方報告"
else
  _record_fail "[追加] 閾値上書き" "rc=$rc output: ${out:0:400}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 6: development.json server.start_command != 'none' → WARN
# -------------------------------------------------------------------------
echo -e "${BOLD}[6] development.json server != 'none' → WARN${NC}"

OK2_DIR="$(make_fixture "ok2" "1" "1")"
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_BAD"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$OK2_DIR" 2>&1
)
rc=$?
# behavior: development.json server.start_command が 'none' 以外 → WARN（動画ハーネスでは不要）
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE "^WARN:.*start_command.*none"; then
  _record_pass "behavior: server.start_command != 'none' → WARN + exit 0"
else
  _record_fail "behavior: server.start_command != 'none' WARN 系" "rc=$rc output: ${out:0:500}"
fi

# [追加] start_command='none' のときは WARN 出ない
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$OK2_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE "^WARN:.*start_command"; then
  _record_pass "[追加] start_command='none' → WARN 無し"
else
  _record_fail "[追加] start_command='none' 抑制" "rc=$rc output: ${out:0:400}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 7: エッジケース
# -------------------------------------------------------------------------
echo -e "${BOLD}[7] エッジケース${NC}"

# [追加] 存在しないディレクトリ → FAIL
out=$(
  bash "$VP_LIB" "${STAGE_DIR}/does-not-exist-xyz" 2>&1
)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -qE "does not exist"; then
  _record_pass "[追加] 存在しないディレクトリ → exit 非0 + 'does not exist' メッセージ"
else
  _record_fail "[追加] 存在しないディレクトリ" "rc=$rc output: ${out:0:300}"
fi

# [追加] 引数なし → Usage + rc=2
out=$(bash "$VP_LIB" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -qF "Usage:"; then
  _record_pass "[追加] 引数なし → Usage + rc=2"
else
  _record_fail "[追加] 引数なし" "rc=$rc output: ${out:0:300}"
fi

# [追加] git 未初期化 → FAIL
NO_GIT_DIR="${STAGE_DIR}/no-git"
mkdir -p "$NO_GIT_DIR"
cp "$SAMPLE_GITIGNORE" "${NO_GIT_DIR}/.gitignore"
cp "$SAMPLE_GITATTRIBUTES" "${NO_GIT_DIR}/.gitattributes"
# git init しない

out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$NO_GIT_DIR" 2>&1
)
rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qE "^FAIL:.*(git repository|git init)"; then
  _record_pass "[追加] git 未初期化 → FAIL + 'git' キーワード報告"
else
  _record_fail "[追加] git 未初期化" "rc=$rc output: ${out:0:400}"
fi

# [追加] 複数違反が同時に発生 → 全て報告される（fail-fast しない）
MULTI_DIR="${STAGE_DIR}/multi-fail"
mkdir -p "$MULTI_DIR"
# .gitignore なし、git init なし
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$MULTI_DIR" 2>&1
)
rc=$?
# git FAIL + .gitignore FAIL の 2 つが両方ログに出ていること
if [ "$rc" -eq 1 ] \
   && echo "$out" | grep -qE '^FAIL:.*git repository' \
   && echo "$out" | grep -qE '^FAIL:.*\.gitignore'; then
  _record_pass "[追加] 複数違反: git 未初期化 + .gitignore 不在 両方報告"
else
  _record_fail "[追加] 複数違反の累積報告" "rc=$rc output: ${out:0:600}"
fi

# [追加] CRITICAL と FAIL が同時に発生しても rc=2 になる（CRITICAL 優先）
MIXED_DIR="$(make_fixture "mixed" "0" "0" "OneDrive-mix/work")"
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=50
  export VPREREQ_DEV_JSON="$MOCK_DEV_OK"
  export VPREREQ_FORCE_WINDOWS=0
  bash "$VP_LIB" "$MIXED_DIR" 2>&1
)
rc=$?
# .gitignore 不在 (FAIL) + OneDrive 検出 (CRITICAL) 両方発生
if [ "$rc" -eq 2 ] \
   && echo "$out" | grep -qE '^CRITICAL:.*OneDrive' \
   && echo "$out" | grep -qE '^FAIL:.*\.gitignore'; then
  _record_pass "[追加] CRITICAL + FAIL 同時 → rc=2 (CRITICAL 優先) + 両方報告"
else
  _record_fail "[追加] CRITICAL + FAIL 混在" "rc=$rc output: ${out:0:600}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 8: source / 関数定義
# -------------------------------------------------------------------------
echo -e "${BOLD}[8] source / 関数定義${NC}"

(
  set +e
  # shellcheck disable=SC1090
  source "$VP_LIB" 2>/dev/null
  if declare -F check_video_prerequisites >/dev/null \
     && declare -F vp_check_git_init >/dev/null \
     && declare -F vp_check_gitignore_node_modules >/dev/null \
     && declare -F vp_check_gitattributes_eol_lf >/dev/null \
     && declare -F vp_check_not_onedrive >/dev/null \
     && declare -F vp_check_dev_json_server_none >/dev/null \
     && declare -F vp_disk_free_gb >/dev/null \
     && declare -F vp_is_windows >/dev/null; then
    exit 0
  fi
  exit 99
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] source 後に全 8 関数が定義されている"
else
  _record_fail "[追加] source 後関数定義" "rc=$rc"
fi

# [追加] 個別関数: vp_check_not_onedrive は OneDrive を含むパスで非0
(
  source "$VP_LIB" 2>/dev/null
  vp_check_not_onedrive "$OD_DIR"
)
rc=$?
if [ "$rc" -ne 0 ]; then
  _record_pass "[追加] vp_check_not_onedrive: OneDrive パスで非0"
else
  _record_fail "[追加] vp_check_not_onedrive OneDrive" "rc=$rc"
fi

# [追加] 個別関数: vp_check_not_onedrive はクリーンパスで 0
(
  source "$VP_LIB" 2>/dev/null
  vp_check_not_onedrive "$OK_DIR"
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _record_pass "[追加] vp_check_not_onedrive: クリーンパスで 0"
else
  _record_fail "[追加] vp_check_not_onedrive clean" "rc=$rc"
fi

# [追加] 個別関数: vp_disk_free_gb override
out=$(
  export VPREREQ_DISK_OVERRIDE_GB=42
  source "$VP_LIB" 2>/dev/null
  vp_disk_free_gb "$OK_DIR"
)
if [ "$out" = "42" ]; then
  _record_pass "[追加] vp_disk_free_gb: override 値 42 を返す"
else
  _record_fail "[追加] vp_disk_free_gb override" "got: '$out'"
fi

# [追加] 個別関数: vp_is_windows は FORCE=1 で真、FORCE=0 で偽
(
  export VPREREQ_FORCE_WINDOWS=1
  source "$VP_LIB" 2>/dev/null
  vp_is_windows
)
rc1=$?
(
  export VPREREQ_FORCE_WINDOWS=0
  source "$VP_LIB" 2>/dev/null
  vp_is_windows
)
rc2=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -ne 0 ]; then
  _record_pass "[追加] vp_is_windows: FORCE=1→0, FORCE=0→非0"
else
  _record_fail "[追加] vp_is_windows FORCE 上書き" "rc1=$rc1 rc2=$rc2"
fi
echo ""

# -------------------------------------------------------------------------
# サマリー
# -------------------------------------------------------------------------
echo -e "${BOLD}========================================${NC}"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "${BOLD}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
