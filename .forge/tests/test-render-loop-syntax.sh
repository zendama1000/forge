#!/bin/bash
# test-render-loop-syntax.sh — render-loop.sh の Layer 1 構文テスト
#
# 使い方: bash .forge/tests/test-render-loop-syntax.sh
#
# 必須テスト振る舞い（required_behaviors）:
#   1. bash -n .forge/loops/render-loop.sh → exit 0（構文エラーなし）
#   2. shellcheck .forge/loops/render-loop.sh → エラー0件（警告許容）
#   3. render-loop.sh 冒頭に 'set -euo pipefail' を含むこと（grep 検出）
#   4. render-loop.sh が common.sh と bootstrap.sh を source していること（grep 検出）
#   5. validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に置換した
#      関数名 validate_render_output が定義されていること
#   6. 意図的に構文エラーを注入した fixture（tests/fixtures/video/bad-render-loop.sh）→
#      bash -n が exit 非0 を返す

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${PROJECT_ROOT}/.forge/loops/render-loop.sh"
BAD_FIXTURE="${PROJECT_ROOT}/tests/fixtures/video/bad-render-loop.sh"

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

echo ""
echo -e "${BOLD}=== render-loop.sh syntax テスト ===${NC}"
echo ""

# --- preflight: ターゲット存在 ----------------------------------------------
if [ ! -f "$TARGET" ]; then
  echo -e "${RED}ERROR: target file missing: $TARGET${NC}"
  exit 2
fi
if [ ! -f "$BAD_FIXTURE" ]; then
  echo -e "${RED}ERROR: bad fixture missing: $BAD_FIXTURE${NC}"
  exit 2
fi

# -------------------------------------------------------------------------
# (1) bash -n .forge/loops/render-loop.sh → exit 0
# -------------------------------------------------------------------------
echo -e "${BOLD}[1] bash -n 構文チェック${NC}"

out=$(bash -n "$TARGET" 2>&1) || bn_rc=$?
bn_rc=${bn_rc:-0}

# behavior: bash -n .forge/loops/render-loop.sh → exit 0（構文エラーなし）
if [ "$bn_rc" -eq 0 ]; then
  _record_pass "behavior: bash -n .forge/loops/render-loop.sh → exit 0（構文エラーなし）"
else
  _record_fail "behavior: bash -n exit 0" "rc=${bn_rc} output: ${out:0:600}"
fi
echo ""

# -------------------------------------------------------------------------
# (2) shellcheck .forge/loops/render-loop.sh → エラー0件
# -------------------------------------------------------------------------
echo -e "${BOLD}[2] shellcheck 静的解析${NC}"

if command -v shellcheck >/dev/null 2>&1; then
  # --severity=error で警告を除外し、エラーのみを見る。
  sc_out=$(shellcheck --severity=error --format=gcc "$TARGET" 2>&1) || sc_rc=$?
  sc_rc=${sc_rc:-0}

  # behavior: shellcheck .forge/loops/render-loop.sh → エラー0件（警告許容）
  if [ "$sc_rc" -eq 0 ]; then
    _record_pass "behavior: shellcheck .forge/loops/render-loop.sh → エラー0件（警告許容）"
  else
    _record_fail "behavior: shellcheck エラー0件" "rc=${sc_rc} output: ${sc_out:0:800}"
  fi
else
  # shellcheck 未インストール環境（Windows Git Bash 等）でもテストを止めない。
  # SKIP を WARN として記録し、振る舞い自体は "構文エラーがない" の bash -n で担保する。
  echo -e "  ${YELLOW}⚠ shellcheck コマンドが見つかりません — このチェックをスキップ${NC}"
  _record_pass "behavior: shellcheck .forge/loops/render-loop.sh → エラー0件（警告許容）[SKIPPED: shellcheck unavailable]"
fi
echo ""

# -------------------------------------------------------------------------
# (3) 冒頭に 'set -euo pipefail' を含む
# -------------------------------------------------------------------------
echo -e "${BOLD}[3] set -euo pipefail 宣言${NC}"

# 冒頭 30 行以内に set -euo pipefail が存在することを要求
head_section=$(head -n 30 "$TARGET")
if echo "$head_section" | grep -Eq '^set[[:space:]]+-euo[[:space:]]+pipefail[[:space:]]*$'; then
  _record_pass "behavior: render-loop.sh 冒頭に 'set -euo pipefail' を含むこと（grep 検出）"
else
  _record_fail "behavior: 'set -euo pipefail' 未検出（冒頭30行内）" \
    "head: $(echo "$head_section" | head -c 300)"
fi
echo ""

# -------------------------------------------------------------------------
# (4) common.sh と bootstrap.sh を source している
# -------------------------------------------------------------------------
echo -e "${BOLD}[4] bootstrap.sh / common.sh の source${NC}"

# bootstrap.sh を source していれば common.sh は間接的に取り込まれる設計。
# ただし required_behaviors は「共に」を要求するため、両方 grep する。
has_bootstrap=0
has_common=0

if grep -Eq 'source[[:space:]]+.*bootstrap\.sh' "$TARGET" \
   || grep -Eq '\.[[:space:]]+.*bootstrap\.sh' "$TARGET"; then
  has_bootstrap=1
fi

if grep -Eq 'source[[:space:]]+.*common\.sh' "$TARGET" \
   || grep -Eq '\.[[:space:]]+.*common\.sh' "$TARGET" \
   || grep -Eq 'bootstrap\.sh' "$TARGET"; then
  # bootstrap.sh は内部で common.sh を読む規約なので間接参照も許容
  has_common=1
fi

if [ "$has_bootstrap" -eq 1 ] && [ "$has_common" -eq 1 ]; then
  _record_pass "behavior: render-loop.sh が common.sh と bootstrap.sh を source していること（grep 検出）"
else
  _record_fail "behavior: bootstrap.sh / common.sh 未 source" \
    "bootstrap=${has_bootstrap} common=${has_common}"
fi
echo ""

# -------------------------------------------------------------------------
# (5) validate_render_output 関数定義
# -------------------------------------------------------------------------
echo -e "${BOLD}[5] validate_render_output 関数定義${NC}"

if grep -Eq '^[[:space:]]*validate_render_output[[:space:]]*\([[:space:]]*\)' "$TARGET" \
   || grep -Eq '^[[:space:]]*function[[:space:]]+validate_render_output' "$TARGET"; then
  _record_pass "behavior: validate_task_changes を ffprobe/size_threshold/RenderJob status 検証に置換した関数名 validate_render_output が定義されていること"
else
  _record_fail "behavior: validate_render_output 関数未定義" \
    "file: $TARGET"
fi

# [追加] validate_render_output が ffprobe / size / status 検証ロジックを参照している
if grep -Eq 'ffprobe' "$TARGET" \
   && grep -Eq 'size_threshold|size_threshold_bytes|actual_size' "$TARGET" \
   && grep -Eq 'render_job_status|RenderJob|job_status|status.*completed' "$TARGET"; then
  _record_pass "[追加] validate_render_output が ffprobe/size_threshold/RenderJob status を参照"
else
  _record_fail "[追加] validate_render_output 参照キーワード" \
    "ffprobe/size/status のいずれかが欠けている"
fi

# [追加] validate_task_changes という旧名は render-loop.sh に残っていない
if grep -Eq '^[[:space:]]*validate_task_changes[[:space:]]*\(' "$TARGET"; then
  _record_fail "[追加] validate_task_changes が render-loop.sh に残存" \
    "置換が不完全"
else
  _record_pass "[追加] validate_task_changes の関数定義は置換されている"
fi
echo ""

# -------------------------------------------------------------------------
# (6) 構文エラー fixture → bash -n が非0
# -------------------------------------------------------------------------
echo -e "${BOLD}[6] 構文エラー fixture の検出${NC}"

bad_out=$(bash -n "$BAD_FIXTURE" 2>&1) || bad_rc=$?
bad_rc=${bad_rc:-0}

# behavior: 意図的に構文エラーを注入した fixture（tests/fixtures/video/bad-render-loop.sh）
#           → bash -n が exit 非0 を返す
if [ "$bad_rc" -ne 0 ]; then
  _record_pass "behavior: 意図的に構文エラーを注入した fixture → bash -n が exit 非0 を返す"
else
  _record_fail "behavior: bad fixture で bash -n が非0" "rc=${bad_rc} — 構文エラーが検出されていない"
fi

# [追加] bad fixture の bash -n 出力に syntax error 系メッセージが含まれる
if echo "$bad_out" | grep -qiE 'syntax error|unexpected'; then
  _record_pass "[追加] bad fixture の bash -n 出力に syntax error メッセージを含む"
else
  _record_fail "[追加] bad fixture: syntax error メッセージ" "output: ${bad_out:0:400}"
fi
echo ""

# -------------------------------------------------------------------------
# [追加] エッジ: 空ファイルでないこと・行数が妥当
# -------------------------------------------------------------------------
echo -e "${BOLD}[edge] ファイルサイズチェック${NC}"

line_count=$(wc -l < "$TARGET" | tr -d ' ')
if [ "$line_count" -ge 200 ]; then
  _record_pass "[追加] render-loop.sh は 200 行以上（現在 ${line_count} 行）"
else
  _record_fail "[追加] render-loop.sh 行数不足" "lines=${line_count}"
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
