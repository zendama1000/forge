#!/bin/bash
# test-mutation-audit-quoting.sh — mutation-audit.sh の newer_files 反復修正検証
# 検証内容:
#   (a) 旧 `for ... in $newer_files` パターンの消失 (SC2086 原因)
#   (b) 新 `while IFS= read -r` パターンの存在
#   (c) 空配列ガード `[ -n "$newer_files" ]` の while 隣接配置
#   (d) here-string 入力ソースの明示クォート `<<< "$newer_files"`
#   (e) shellcheck -S warning で SC2068/SC2086 が L80-L125 範囲に出ない
# 使い方: bash .forge/tests/test-mutation-audit-quoting.sh
#
# 注: 必須テスト振る舞いテキストはパス `.forge/loops/mutation-audit.sh` を
#     参照するが、実ファイルは `.forge/lib/mutation-audit.sh` に存在する
#     （アーキテクチャ制約の正規パス）。本テストは実ファイルパスで検証する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TARGET="${REAL_ROOT}/.forge/lib/mutation-audit.sh"

echo -e "${BOLD}===== test-mutation-audit-quoting.sh — newer_files 反復クォート修正 =====${NC}"
echo ""

# 事前確認: 対象ファイル存在
if [ ! -f "$TARGET" ]; then
  echo -e "  ${RED}✗${NC} 対象ファイルが見つからない: $TARGET"
  exit 1
fi

# ========================================================================
# Group 1: 旧パターン消失
# ========================================================================
echo -e "${BOLD}--- Group 1: 旧 for ループ消失 ---${NC}"

# behavior: 検出すべきでないパターン: grep -nP 'for\s+\w+\s+in\s+\$newer_files' .forge/loops/mutation-audit.sh で0件
old_count=$(grep -cP 'for\s+\w+\s+in\s+\$newer_files' "$TARGET" 2>/dev/null || true)
old_count="${old_count:-0}"
assert_eq "旧 'for ... in \$newer_files' 0件" "0" "$old_count"

echo ""

# ========================================================================
# Group 2: 新パターン存在
# ========================================================================
echo -e "${BOLD}--- Group 2: 新 while ループ存在 ---${NC}"

# behavior: 検出すべきパターン: grep -n 'while IFS= read -r' .forge/loops/mutation-audit.sh で1件以上
new_count=$(grep -c 'while IFS= read -r' "$TARGET" 2>/dev/null || true)
new_count="${new_count:-0}"
if [ "$new_count" -ge 1 ]; then
  assert_eq "新 'while IFS= read -r' パターン 1件以上" "ge1" "ge1"
else
  assert_eq "新 'while IFS= read -r' パターン 1件以上" "ge1" "count=${new_count}"
fi

echo ""

# ========================================================================
# Group 3: 空配列ガード隣接配置
# ========================================================================
echo -e "${BOLD}--- Group 3: 空配列ガード隣接 ---${NC}"

# behavior: 検出すべきパターン: grep -n 'newer_files' .forge/loops/mutation-audit.sh で [ -n "$newer_files" ] または同等の空文字ガードが隣接行に存在
guard_line=$(grep -n '\[[[:space:]]*-n[[:space:]]*"\$newer_files"[[:space:]]*\]' "$TARGET" | head -1 | cut -d: -f1)
while_line=$(grep -n 'while IFS= read -r' "$TARGET" | head -1 | cut -d: -f1)

guard_adjacent="missing"
if [ -n "${guard_line:-}" ] && [ -n "${while_line:-}" ]; then
  delta=$((while_line - guard_line))
  # guard が while の直前 1〜5 行以内にあれば "隣接" とみなす
  if [ "$delta" -ge 1 ] && [ "$delta" -le 5 ]; then
    guard_adjacent="ok"
  else
    guard_adjacent="non_adjacent(delta=${delta})"
  fi
fi
assert_eq "[ -n \"\$newer_files\" ] が while 直前に存在" "ok" "$guard_adjacent"

echo ""

# ========================================================================
# Group 4: here-string 明示クォート
# ========================================================================
echo -e "${BOLD}--- Group 4: here-string 明示クォート ---${NC}"

# behavior: エッジケース: here-string '<<<' もしくは while ループの入力ソースが明示的にクォートされている
hs_count=$(grep -cE '<<<[[:space:]]+"\$newer_files"' "$TARGET" 2>/dev/null || true)
hs_count="${hs_count:-0}"
if [ "$hs_count" -ge 1 ]; then
  assert_eq "here-string '<<< \"\$newer_files\"' 明示クォート" "ge1" "ge1"
else
  assert_eq "here-string '<<< \"\$newer_files\"' 明示クォート" "ge1" "count=${hs_count}"
fi

echo ""

# ========================================================================
# Group 5: shellcheck SC2068/SC2086 消失（L80-L125 範囲）
# ========================================================================
echo -e "${BOLD}--- Group 5: shellcheck warning 消失 ---${NC}"

# behavior: shellcheck 通過: shellcheck -S warning .forge/loops/mutation-audit.sh で SC2068/SC2086 が L91 周辺で消えている
if command -v shellcheck >/dev/null 2>&1; then
  # -f gcc: <path>:<line>:<col>: <severity>: <msg> [SCxxxx]
  sc_raw=$(shellcheck -f gcc -S warning "$TARGET" 2>/dev/null || true)
  bad_count=0
  if [ -n "$sc_raw" ]; then
    while IFS= read -r scline; do
      [ -z "$scline" ] && continue
      # SC2068/SC2086 以外はスキップ
      case "$scline" in
        *SC2068*|*SC2086*) ;;
        *) continue ;;
      esac
      # 行番号抽出: `.../mutation-audit.sh:<ln>:<col>: ...`
      # Windows 絶対パス `C:/...` が含まれる可能性があるため、`.sh:` 以降を切り出す
      ln=$(echo "$scline" | sed -E 's|.*\.sh:([0-9]+):.*|\1|')
      if [ -n "$ln" ] && [ "$ln" -ge 80 ] 2>/dev/null && [ "$ln" -le 125 ] 2>/dev/null; then
        bad_count=$((bad_count + 1))
        echo "    shellcheck hit (L${ln}): ${scline}"
      fi
    done <<< "$sc_raw"
  fi
  assert_eq "SC2068/SC2086 が L80-L125 範囲で 0件" "0" "$bad_count"
else
  # shellcheck 未インストール環境（Windows 等）: Group 1/4 で代替検証済みのためスキップ
  echo -e "  ${YELLOW}⊘${NC} shellcheck 未インストール — 構文検証は Group 1/4 で代替済"
fi

echo ""

# ===== サマリー =====
print_test_summary
exit $?
