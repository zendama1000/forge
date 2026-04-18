#!/bin/bash
# test-hyperframes-optional.sh — hyperframes-probe.sh の L1/L2 テスト
#
# 使い方: bash .forge/tests/test-hyperframes-optional.sh
#
# 必須テスト振る舞い（タスク定義より）:
#   - development.json server.start_command が 'none' 以外 → WARN（動画ハーネスでは不要）
#
# 追加テスト:
#   - Node.js 22+ と hyperframes CLI 揃い → SELECTED_SCENARIO=hyperframes
#   - Node.js 欠落 → SELECTED_SCENARIO=mock + WARN
#   - Node.js バージョン不足（18.x）→ SELECTED_SCENARIO=mock + WARN
#   - hyperframes CLI 欠落 → SELECTED_SCENARIO=mock + WARN
#   - 両方欠落 → SELECTED_SCENARIO=mock + WARN 2件以上
#   - 常に exit 0（optional 依存のため FAIL しない）
#   - fail-fast しない（全検査を走らせる）
#   - source 後に関数定義確認
#   - hfp_version_ge / hfp_extract_node_version のロジック検証
#   - hfp_resolve_mode の stdout 契約

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HFP_LIB="${PROJECT_ROOT}/.forge/lib/hyperframes-probe.sh"

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
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
}
_fail() {
  echo -e "  ${RED}NG${NC} $1"
  [ $# -ge 2 ] && echo -e "    ${YELLOW}$2${NC}"
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
}

echo ""
echo -e "${BOLD}=== hyperframes-probe テスト ===${NC}"
echo ""

# --- preflight -----------------------------------------------------------
if [ ! -f "$HFP_LIB" ]; then
  echo -e "${RED}ERROR: library missing: $HFP_LIB${NC}"
  exit 2
fi
for tool in bash jq sed; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: required tool missing: $tool${NC}"
    exit 2
  fi
done

STAGE_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/hfp-stage-$$")"
mkdir -p "${STAGE_DIR}/mocks"
cleanup() {
  if [ -d "$STAGE_DIR" ]; then
    chmod -R u+rwX "$STAGE_DIR" 2>/dev/null || true
    rm -rf "$STAGE_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

make_mock_bin() {
  local name="$1" body="$2"
  local p="${STAGE_DIR}/mocks/${name}"
  printf '#!/bin/bash\n%s\n' "$body" >"$p"
  chmod +x "$p"
  echo "$p"
}

OK_NODE22=$(make_mock_bin  "node-22" 'echo "v22.3.0"; exit 0')
OK_NODE24=$(make_mock_bin  "node-24" 'echo "v24.1.0"; exit 0')
EQ_NODE22=$(make_mock_bin  "node-22eq" 'echo "v22.0.0"; exit 0')
OLD_NODE18=$(make_mock_bin "node-18" 'echo "v18.17.0"; exit 0')
OK_HF=$(make_mock_bin      "hyperframes-ok" 'echo "hyperframes 1.4.2"; exit 0')
OK_JQ="$(command -v jq)"

# development.json mocks
DEV_OK="${STAGE_DIR}/dev-ok.json"
cat >"$DEV_OK" <<'EOF'
{
  "server": { "start_command": "none", "health_check_url": "none" }
}
EOF
DEV_BAD="${STAGE_DIR}/dev-bad.json"
cat >"$DEV_BAD" <<'EOF'
{
  "server": { "start_command": "npm run dev", "health_check_url": "http://localhost:3000" }
}
EOF

echo -e "${BOLD}[preflight]${NC} library + mocks OK"
echo -e "  stage_dir: $STAGE_DIR"
echo ""

# source test
# shellcheck disable=SC1090
source "$HFP_LIB"
if ! declare -F probe_hyperframes >/dev/null; then
  echo -e "${RED}ERROR: probe_hyperframes not defined after source${NC}"
  exit 2
fi

# -------------------------------------------------------------------------
# Group 1: 必須 behavior — start_command != 'none' → WARN
# -------------------------------------------------------------------------
echo -e "${BOLD}[1] 必須 behavior: development.json start_command != 'none' → WARN${NC}"

out=$(
  export HFP_NODE_BIN="$OK_NODE22"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_BAD"
  bash "$HFP_LIB" 2>&1
)
rc=$?
# behavior: development.json server.start_command が 'none' 以外 → WARN（動画ハーネスでは不要）
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE "^WARN:.*start_command.*none"; then
  _pass "behavior: development.json server.start_command が 'none' 以外 → WARN（動画ハーネスでは不要）"
else
  _fail "behavior: start_command != 'none' → WARN" "rc=$rc out: ${out:0:500}"
fi

# [追加] start_command='none' のとき start_command WARN が出ない
out=$(
  export HFP_NODE_BIN="$OK_NODE22"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_OK"
  bash "$HFP_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE "^WARN:.*start_command"; then
  _pass "[追加] start_command='none' → start_command WARN 無し"
else
  _fail "[追加] start_command='none' 抑制" "rc=$rc out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 2: 両依存揃い → hyperframes 選択
# -------------------------------------------------------------------------
echo -e "${BOLD}[2] node22 + hyperframes CLI 揃い → SELECTED_SCENARIO=hyperframes${NC}"

out=$(
  export HFP_NODE_BIN="$OK_NODE22"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_OK"
  bash "$HFP_LIB" 2>&1
)
rc=$?
# [追加] 両依存揃い → SELECTED_SCENARIO=hyperframes
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE '^SELECTED_SCENARIO=hyperframes$'; then
  _pass "[追加] node22 + hf CLI 揃い → SELECTED_SCENARIO=hyperframes (stdout)"
else
  _fail "[追加] SELECTED_SCENARIO=hyperframes" "rc=$rc out: ${out:0:500}"
fi

# [追加] WARN/SKIP が出ない（start_command は OK）
if [ "$rc" -eq 0 ] && ! echo "$out" | grep -qE '^(WARN|SKIP):'; then
  _pass "[追加] 両依存揃い時: WARN/SKIP 無し"
else
  _fail "[追加] 両依存揃い時 WARN/SKIP 無し" "out: ${out:0:500}"
fi

# [追加] OK: node ... 行が出る
if echo "$out" | grep -qE '^OK: node 22\.3\.0'; then
  _pass "[追加] 'OK: node 22.3.0' 行が出力される"
else
  _fail "[追加] OK: node 22.3.0 行" "out: ${out:0:500}"
fi

# [追加] OK: hyperframes CLI 行が出る
if echo "$out" | grep -qE '^OK: hyperframes CLI'; then
  _pass "[追加] 'OK: hyperframes CLI' 行が出力される"
else
  _fail "[追加] OK: hyperframes CLI 行" "out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 3: Node.js 欠落 / バージョン不足 → mock フォールバック
# -------------------------------------------------------------------------
echo -e "${BOLD}[3] Node.js 欠落 / 古い版 → mock フォールバック${NC}"

# Node.js 欠落
out=$(
  export HFP_NODE_BIN="/does/not/exist/node-xyz"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_OK"
  bash "$HFP_LIB" 2>&1
)
rc=$?
# [追加] node 欠落 → SELECTED_SCENARIO=mock + WARN + exit 0
if [ "$rc" -eq 0 ] \
   && echo "$out" | grep -qE '^SELECTED_SCENARIO=mock$' \
   && echo "$out" | grep -qE '^WARN:.*node.*not found'; then
  _pass "[追加] node 欠落 → SELECTED_SCENARIO=mock + WARN + exit 0"
else
  _fail "[追加] node 欠落 mock フォールバック" "rc=$rc out: ${out:0:500}"
fi

# Node.js バージョン不足 (18.x)
out=$(
  export HFP_NODE_BIN="$OLD_NODE18"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_OK"
  bash "$HFP_LIB" 2>&1
)
rc=$?
# [追加] node 18.x (< 22.0) → SELECTED_SCENARIO=mock + WARN（バージョン値報告）
if [ "$rc" -eq 0 ] \
   && echo "$out" | grep -qE '^SELECTED_SCENARIO=mock$' \
   && echo "$out" | grep -qE '^WARN:.*node.*18\.17.*22\.0'; then
  _pass "[追加] node 18.x < 22.0 → SELECTED_SCENARIO=mock + 実測値と閾値を両方報告"
else
  _fail "[追加] node 18.x フォールバック" "rc=$rc out: ${out:0:500}"
fi

# 境界: node 22.0.0 → hyperframes 選択
out=$(
  export HFP_NODE_BIN="$EQ_NODE22"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_OK"
  bash "$HFP_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE '^SELECTED_SCENARIO=hyperframes$'; then
  _pass "[追加] node = 22.0 境界 → SELECTED_SCENARIO=hyperframes"
else
  _fail "[追加] node 22.0 境界" "rc=$rc out: ${out:0:500}"
fi

# 閾値上書き: HFP_NODE_MIN=24.0, 実測 22.3 → mock
out=$(
  export HFP_NODE_BIN="$OK_NODE22"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_OK"
  export HFP_NODE_MIN="24.0"
  bash "$HFP_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] \
   && echo "$out" | grep -qE '^SELECTED_SCENARIO=mock$' \
   && echo "$out" | grep -qE '^WARN:.*node.*22\.3.*24\.0'; then
  _pass "[追加] HFP_NODE_MIN=24.0 上書き + 実測 22.3 → mock"
else
  _fail "[追加] NODE_MIN 上書き" "rc=$rc out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 4: hyperframes CLI 欠落 → mock フォールバック
# -------------------------------------------------------------------------
echo -e "${BOLD}[4] hyperframes CLI 欠落 → mock フォールバック${NC}"

out=$(
  export HFP_NODE_BIN="$OK_NODE22"
  export HFP_HYPERFRAMES_BIN="/does/not/exist/hyperframes-xyz"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_OK"
  bash "$HFP_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] \
   && echo "$out" | grep -qE '^SELECTED_SCENARIO=mock$' \
   && echo "$out" | grep -qE '^WARN:.*hyperframes CLI not found'; then
  _pass "[追加] hyperframes CLI 欠落 → SELECTED_SCENARIO=mock + WARN + exit 0"
else
  _fail "[追加] hyperframes CLI 欠落" "rc=$rc out: ${out:0:500}"
fi

# SKIP 行が出る（降格通知）
if echo "$out" | grep -qE '^SKIP:.*hyperframes.*fallback'; then
  _pass "[追加] hyperframes CLI 欠落 → SKIP 行で fallback を通知"
else
  _fail "[追加] SKIP fallback 通知" "out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 5: 両方欠落 → fail-fast しない
# -------------------------------------------------------------------------
echo -e "${BOLD}[5] 両方欠落 → fail-fast しない${NC}"

out=$(
  export HFP_NODE_BIN="/none/node"
  export HFP_HYPERFRAMES_BIN="/none/hyperframes"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="$DEV_OK"
  bash "$HFP_LIB" 2>&1
)
rc=$?
warn_lines=$(echo "$out" | grep -cE '^WARN:' || true)
[ -z "$warn_lines" ] && warn_lines=0
# [追加] 両欠落 → WARN >= 2, mock 選択, exit 0
if [ "$rc" -eq 0 ] \
   && [ "$warn_lines" -ge 2 ] \
   && echo "$out" | grep -qE '^SELECTED_SCENARIO=mock$'; then
  _pass "[追加] 両欠落 → WARN >=2 行 (fail-fast しない) + mock 選択"
else
  _fail "[追加] 両欠落累積" "rc=$rc warns=$warn_lines out: ${out:0:500}"
fi

# [追加] optional 依存は常に exit 0（FAIL しない）
if [ "$rc" -eq 0 ]; then
  _pass "[追加] optional 依存欠落でも exit 0（FAIL しない）"
else
  _fail "[追加] optional 依存 exit 0" "rc=$rc"
fi
echo ""

# -------------------------------------------------------------------------
# Group 6: development.json エッジケース
# -------------------------------------------------------------------------
echo -e "${BOLD}[6] development.json エッジケース${NC}"

# development.json 不在 → WARN（exit 0 維持）
out=$(
  export HFP_NODE_BIN="$OK_NODE22"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  export HFP_JQ_BIN="$OK_JQ"
  export HFP_DEV_JSON="${STAGE_DIR}/nonexistent-dev.json"
  bash "$HFP_LIB" 2>&1
)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qE '^WARN:.*development\.json'; then
  _pass "[追加] development.json 不在 → WARN + exit 0"
else
  _fail "[追加] development.json 不在" "rc=$rc out: ${out:0:500}"
fi
echo ""

# -------------------------------------------------------------------------
# Group 7: source / 関数定義
# -------------------------------------------------------------------------
echo -e "${BOLD}[7] source / 関数定義${NC}"

(
  set +e
  # shellcheck disable=SC1090
  source "$HFP_LIB" 2>/dev/null
  if declare -F probe_hyperframes >/dev/null \
     && declare -F check_hyperframes_optional >/dev/null \
     && declare -F hfp_check_node >/dev/null \
     && declare -F hfp_check_hyperframes_cli >/dev/null \
     && declare -F hfp_check_dev_json_server_none >/dev/null \
     && declare -F hfp_resolve_mode >/dev/null \
     && declare -F hfp_version_ge >/dev/null \
     && declare -F hfp_extract_node_version >/dev/null; then
    exit 0
  fi
  exit 99
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[追加] source 後に必要な関数 (probe_hyperframes, hfp_*) が定義されている"
else
  _fail "[追加] source 後関数定義" "rc=$rc"
fi

# hfp_version_ge の比較論理
(
  source "$HFP_LIB" 2>/dev/null
  hfp_version_ge "22.0" "22.0" \
    && hfp_version_ge "22.3" "22.0" \
    && hfp_version_ge "24.0" "22.5" \
    && hfp_version_ge "v22.3.0" "22.0" \
    && ! hfp_version_ge "21.9" "22.0" \
    && ! hfp_version_ge "18.17" "22.0" \
    && ! hfp_version_ge "22.0" "22.1"
)
rc=$?
if [ "$rc" -eq 0 ]; then
  _pass "[追加] hfp_version_ge: A>=B の true/false 両方向が正しい（v prefix も許容）"
else
  _fail "[追加] hfp_version_ge 比較" "rc=$rc"
fi

# hfp_extract_node_version: 通常版
out=$(
  source "$HFP_LIB" 2>/dev/null
  hfp_extract_node_version "$OK_NODE22"
)
if [ "$out" = "22.3.0" ]; then
  _pass "[追加] hfp_extract_node_version: 'v22.3.0' → '22.3.0' を抽出"
else
  _fail "[追加] hfp_extract_node_version (v22.3.0)" "got: '$out'"
fi

# hfp_extract_node_version: 18.x
out=$(
  source "$HFP_LIB" 2>/dev/null
  hfp_extract_node_version "$OLD_NODE18"
)
if [ "$out" = "18.17.0" ]; then
  _pass "[追加] hfp_extract_node_version: 'v18.17.0' → '18.17.0' を抽出"
else
  _fail "[追加] hfp_extract_node_version (v18.17.0)" "got: '$out'"
fi

# hfp_resolve_mode: stdout 契約（hyperframes）
out=$(
  export HFP_NODE_BIN="$OK_NODE22"
  export HFP_HYPERFRAMES_BIN="$OK_HF"
  source "$HFP_LIB" 2>/dev/null
  hfp_resolve_mode 2>/dev/null
)
if [ "$out" = "hyperframes" ]; then
  _pass "[追加] hfp_resolve_mode: 両揃い → stdout='hyperframes'（診断は stderr）"
else
  _fail "[追加] hfp_resolve_mode hyperframes" "got: '$out'"
fi

# hfp_resolve_mode: stdout 契約（mock）
out=$(
  export HFP_NODE_BIN="/none/node"
  export HFP_HYPERFRAMES_BIN="/none/hyperframes"
  source "$HFP_LIB" 2>/dev/null
  hfp_resolve_mode 2>/dev/null
)
if [ "$out" = "mock" ]; then
  _pass "[追加] hfp_resolve_mode: 両欠落 → stdout='mock'"
else
  _fail "[追加] hfp_resolve_mode mock" "got: '$out'"
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
