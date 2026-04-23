#!/bin/bash
# test-jq-lines.sh — common.sh の jq_lines() ヘルパー全挙動テスト
# 検証内容:
#   - CRLF 除去（Windows Git Bash 対策）
#   - 冪等性（Linux/macOS 互換）
#   - エラー伝播（pipefail 下）
#   - bootstrap.sh 経由参照可能性
#   - ralph-loop.sh / mutation-audit.sh 起動パスでの解決
#   - 二重 source 耐性
#   - common.sh 未 source 時の 127
# 使い方: bash .forge/tests/test-jq-lines.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo -e "${BOLD}===== test-jq-lines.sh — jq_lines 全挙動テスト =====${NC}"
echo ""

# ===== 共通ユーティリティ: テスト用ラッパースクリプト =====
# 一時ラッパーは .forge/lib/ または .forge/loops/ に配置する必要がある
# （bootstrap.sh が BASH_SOURCE[1] から SCRIPT_DIR を導出するため、
#  実ファイルが正規パスに存在する必要がある）
WRAPPERS=()

cleanup_wrappers() {
  local w
  for w in "${WRAPPERS[@]:-}"; do
    [ -n "$w" ] && [ -f "$w" ] && rm -f "$w"
  done
}
trap cleanup_wrappers EXIT INT TERM

# ===== テスト対象を現在のシェルに読み込む =====
# 注: common.sh は PROJECT_ROOT 等を前提とする関数を含むが、
#     jq_lines 自体は前提変数に依存しない
source "${REAL_ROOT}/.forge/lib/common.sh"

# ========================================================================
# Group 1: 基本的な CRLF 除去
# ========================================================================
echo -e "${BOLD}--- Group 1: 基本的な CRLF 除去 ---${NC}"

# behavior: 正常系: printf '{"a":"x"}\r\n' | jq_lines -r '.a' を実行 → 出力が 'x\n'（\r が除去されている、od -c で確認）
out=$(printf '{"a":"x"}\r\n' | jq_lines -r '.a')
# Check: value is 'x' and no \r remains in output
has_cr=$(printf '%s' "$out" | tr -cd '\r' | wc -c | tr -d ' ')
assert_eq "CRLF 入力 → 'x' + \\r 除去" "x:0" "${out}:${has_cr}"

# behavior: 正常系: echo '["a","b","c"]' | jq_lines -r '.[]' を実行 → 3行が出力され、各行末に \r が含まれない
out_multi=$(echo '["a","b","c"]' | jq_lines -r '.[]')
# Count lines (3 non-empty lines)
line_count=$(printf '%s\n' "$out_multi" | grep -c .)
has_cr_multi=$(printf '%s' "$out_multi" | tr -cd '\r' | wc -c | tr -d ' ')
assert_eq "3要素配列 → 3行 + \\r 含まず" "3:0" "${line_count}:${has_cr_multi}"

echo ""

# ========================================================================
# Group 2: エラー伝播（pipefail 下）
# ========================================================================
echo -e "${BOLD}--- Group 2: エラー伝播 ---${NC}"

# behavior: 異常系: 不正な JSON 入力 echo 'not json' | jq_lines -r '.' → jq のエラーで終了コード非ゼロを返す（エラー伝播されている）
# pipefail 下で jq の非0終了が jq_lines の終了コードになる
set +u  # 一時的に -u を解除（subshell 内で壊れる可能性回避）
(
  set -o pipefail
  echo 'not json' | jq_lines -r '.'
) >/dev/null 2>&1
ret_bad=$?
set -u
if [ "$ret_bad" -ne 0 ]; then
  assert_eq "不正 JSON → 非0終了（エラー伝播）" "nonzero" "nonzero"
else
  assert_eq "不正 JSON → 非0終了（エラー伝播）" "nonzero" "zero(ret=$ret_bad)"
fi

echo ""

# ========================================================================
# Group 3: 冪等性（Linux 擬似環境: \r を付与しない入力）
# ========================================================================
echo -e "${BOLD}--- Group 3: 冪等性（Linux 擬似環境）---${NC}"

# behavior: エッジケース: Linux 環境（\r を付与しない jq バージョン）でも jq_lines を実行 → 出力が冪等（\r なしのデータに tr -d '\r' が適用されても破壊しない）
# 改行のみの入力 → tr -d '\r' は no-op。出力は破壊されない
out_linux=$(printf '{"a":"x"}\n' | jq_lines -r '.a')
assert_eq "改行のみ入力 → 冪等出力 'x'" "x" "$out_linux"

# 追加: 多要素で冪等性確認（CRLF なしデータでも正しく全行取得）
out_linux_multi=$(printf '["a","b","c"]\n' | jq_lines -r '.[]' | wc -l | tr -d ' ')
assert_eq "改行のみ多要素 → 3行取得" "3" "$out_linux_multi"

echo ""

# ========================================================================
# Group 4: 空入力でハング/crash しない
# ========================================================================
echo -e "${BOLD}--- Group 4: 空入力の安全性 ---${NC}"

# behavior: エッジケース: 空入力 echo '' | jq_lines -r '.' → エラー終了するが segfault やハングは起きない
start_ts=$(date +%s)
echo '' | jq_lines -r '.' >/dev/null 2>&1
ret_empty=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

# 判定:
#   no_hang: 5秒以内に完了
#   no_crash: segfault (139) / abort (134) ではない
no_hang="fail(elapsed=${elapsed})"
[ "$elapsed" -lt 5 ] && no_hang="ok"
no_crash="fail(ret=${ret_empty})"
[ "$ret_empty" -ne 139 ] && [ "$ret_empty" -ne 134 ] && no_crash="ok"
assert_eq "空入力 → hang/segfault/abort なし" "ok:ok" "${no_hang}:${no_crash}"

echo ""

# ========================================================================
# Group 5: 関数定義確認（type jq_lines）
# ========================================================================
echo -e "${BOLD}--- Group 5: 関数定義確認 ---${NC}"

# behavior: 関数定義確認: type jq_lines で 'jq_lines is a function' が表示される
type_out=$(type jq_lines 2>&1)
assert_contains "type jq_lines → 'is a function'" "jq_lines is a function" "$type_out"

echo ""

# ========================================================================
# Group 6: bootstrap.sh 経由でのアクセス
# ========================================================================
echo -e "${BOLD}--- Group 6: bootstrap.sh 経由 ---${NC}"

# behavior: 正常系: bash -c 'source .forge/lib/bootstrap.sh && type jq_lines' → 'jq_lines is a function' が出力される
# bootstrap.sh は BASH_SOURCE[1] から SCRIPT_DIR を導出するため、
# 実在するスクリプトファイルから source する必要がある。
# ここでは .forge/lib/ 内に一時ラッパーを配置して本物の呼出しをシミュレートする。
WRAPPER_LIB="${REAL_ROOT}/.forge/lib/__test_jq_lines_bootstrap.sh"
WRAPPERS+=("$WRAPPER_LIB")
cat > "$WRAPPER_LIB" << 'WRAP_EOF'
#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bootstrap.sh"
type jq_lines
WRAP_EOF
chmod +x "$WRAPPER_LIB"
bs_out=$(bash "$WRAPPER_LIB" 2>&1)
assert_contains "bootstrap 経由 → 関数定義" "jq_lines is a function" "$bs_out"

echo ""

# ========================================================================
# Group 7: ralph-loop.sh 起動パターンでの参照
# ========================================================================
echo -e "${BOLD}--- Group 7: ralph-loop.sh 起動パターン ---${NC}"

# behavior: 正常系: ralph-loop.sh を dry-run モードで起動時、jq_lines が参照できる
# ralph-loop.sh は set -eEuo pipefail 下で bootstrap.sh を source する。
# 同一の source パターンで jq_lines が解決可能か検証する。
# （ralph-loop.sh 自体に dry-run モードはないため、起動初期化段階を再現する）
LOOP_WRAPPER="${REAL_ROOT}/.forge/loops/__test_jq_lines_loop.sh"
WRAPPERS+=("$LOOP_WRAPPER")
cat > "$LOOP_WRAPPER" << 'WRAP_EOF'
#!/bin/bash
set -eEuo pipefail
# ralph-loop.sh と同一の source パターン
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"
type jq_lines
WRAP_EOF
chmod +x "$LOOP_WRAPPER"
loop_out=$(bash "$LOOP_WRAPPER" 2>&1)
assert_contains "ralph-loop 起動パターン → 関数定義" "jq_lines is a function" "$loop_out"

echo ""

# ========================================================================
# Group 8: common.sh 未 source 時の exit 127
# ========================================================================
echo -e "${BOLD}--- Group 8: source なしでの呼出し ---${NC}"

# behavior: 異常系: common.sh を source せずに jq_lines を呼出 → 'command not found' エラーで終了コード127
# クリーン環境で呼び出し → コマンドなし扱いで 127
bash --noprofile --norc -c 'jq_lines -r "." <<< "{}"' >/dev/null 2>&1
no_src_ret=$?
assert_eq "source なし → exit 127" "127" "$no_src_ret"

echo ""

# ========================================================================
# Group 9: bootstrap.sh 二重 source 耐性
# ========================================================================
echo -e "${BOLD}--- Group 9: bootstrap.sh 二重 source ---${NC}"

# behavior: エッジケース: bootstrap.sh が二重 source されても jq_lines の定義が衝突・上書きされない
# 2回 source した後も jq_lines が正常動作することを確認する
DOUBLE_WRAPPER="${REAL_ROOT}/.forge/lib/__test_jq_lines_double.sh"
WRAPPERS+=("$DOUBLE_WRAPPER")
cat > "$DOUBLE_WRAPPER" << 'WRAP_EOF'
#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bootstrap.sh"
# 2回目の source（cd は同じ PROJECT_ROOT に戻るだけで副作用なし）
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bootstrap.sh"
# 二重 source 後も jq_lines が定義されており正常動作するはず
printf '{"a":"x"}\r\n' | jq_lines -r '.a'
WRAP_EOF
chmod +x "$DOUBLE_WRAPPER"
dbl_out=$(bash "$DOUBLE_WRAPPER" 2>&1)
dbl_ret=$?
assert_eq "二重 source → 'x' 出力 + exit 0" "x:0" "${dbl_out}:${dbl_ret}"

echo ""

# ========================================================================
# Group 10: mutation-audit.sh 解決パス
# ========================================================================
echo -e "${BOLD}--- Group 10: mutation-audit.sh 解決 ---${NC}"

# behavior: エッジケース: .forge/loops/mutation-audit.sh が単独起動時も common.sh 経由で jq_lines を解決できる
# mutation-audit.sh は .forge/lib/ 内のライブラリで、ralph-loop.sh から source される。
# mutation-audit.sh 側から jq_lines が参照可能か、bootstrap → common → mutation-audit のチェーンで検証する。
# （mutation-audit.sh は前提変数を多数要求するため type チェックのみ）
MA_WRAPPER="${REAL_ROOT}/.forge/loops/__test_jq_lines_ma.sh"
WRAPPERS+=("$MA_WRAPPER")
cat > "$MA_WRAPPER" << 'WRAP_EOF'
#!/bin/bash
set -eEo pipefail
# ralph-loop.sh と同一のロードチェーン
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bootstrap.sh"
# mutation-audit.sh 単独 source（前提変数なしでも source 自体は失敗しない = 関数定義のみ）
source "${PROJECT_ROOT}/.forge/lib/mutation-audit.sh"
type jq_lines
WRAP_EOF
chmod +x "$MA_WRAPPER"
ma_out=$(bash "$MA_WRAPPER" 2>&1)
assert_contains "mutation-audit 解決パス → 関数定義" "jq_lines is a function" "$ma_out"

echo ""

# ===== サマリー =====
print_test_summary
exit $?
