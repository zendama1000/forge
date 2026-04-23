#!/bin/bash
# test-mutation-audit-spaces.sh — mutation-audit.sh 空白パス耐性 回帰テスト
# 検証内容:
#   (a) fixture: mktemp -d + mv で空白を含むディレクトリ（'mut audit test XXX'）を生成
#   (b) ダミー変異ファイル3つ（a.js, b.js, 'c with space.js'）を配置
#   (c) mutation-audit.sh の newer_files 反復経路を直接呼出して全件処理される
#   (d) stderr に 'No such file or directory' が出現しない
#   (e) stdout に 'processed: 3' が含まれる
# 安全性ガード: TEST_DIR 非空チェック / /tmp/ プレフィックス検証 / trap EXIT クリーンアップ
# 使い方: bash .forge/tests/test-mutation-audit-spaces.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo -e "${BOLD}===== test-mutation-audit-spaces.sh — 空白パス耐性 =====${NC}"
echo ""

# ========================================================================
# Fixture: 空白を含むテストディレクトリの作成
# ========================================================================

# mktemp -d で一時ディレクトリを作成
TMP_BASE="$(mktemp -d)"
if [ -z "${TMP_BASE:-}" ] || [ ! -d "$TMP_BASE" ]; then
  echo -e "  ${RED}✗${NC} mktemp -d 失敗"
  exit 1
fi

# 安全ガード 1: TMP_BASE の親ディレクトリが /tmp または $TMPDIR 配下であることを検証
#   （mv 後の TEST_DIR も同じ親配下になるため、ここで一度だけ検証すれば安全）
TMP_PARENT="$(cd "$(dirname "$TMP_BASE")" && pwd)"
safe_parent="no"
case "$TMP_PARENT" in
  /tmp|/tmp/*) safe_parent="yes" ;;
esac
if [ "$safe_parent" != "yes" ] && [ -n "${TMPDIR:-}" ]; then
  _tmpd="${TMPDIR%/}"
  case "$TMP_PARENT" in
    "${_tmpd}"|"${_tmpd}/"*) safe_parent="yes" ;;
  esac
fi
if [ "$safe_parent" != "yes" ]; then
  echo -e "  ${RED}✗${NC} mktemp 親ディレクトリが /tmp または \$TMPDIR ではない: $TMP_PARENT"
  rm -rf "$TMP_BASE"
  exit 1
fi

# 空白を含むディレクトリ名へ mv でリネーム（例: 'mut audit test tmp.XXXXXX'）
TEST_DIR_NAME="mut audit test $(basename "$TMP_BASE")"
TEST_DIR="${TMP_PARENT}/${TEST_DIR_NAME}"
mv "$TMP_BASE" "$TEST_DIR"

# 安全ガード 2: TEST_DIR の非空チェック
if [ -z "${TEST_DIR:-}" ]; then
  echo -e "  ${RED}✗${NC} TEST_DIR が空 — 安全ガードで中断"
  exit 1
fi

# 安全ガード 3: TEST_DIR が /tmp/ または $TMPDIR/ プレフィックスに一致
safe_prefix="no"
case "$TEST_DIR" in
  /tmp/*) safe_prefix="yes" ;;
esac
if [ "$safe_prefix" != "yes" ] && [ -n "${TMPDIR:-}" ]; then
  _tmpd="${TMPDIR%/}"
  case "$TEST_DIR" in
    "${_tmpd}/"*) safe_prefix="yes" ;;
  esac
fi
if [ "$safe_prefix" != "yes" ]; then
  echo -e "  ${RED}✗${NC} TEST_DIR が /tmp/ または \$TMPDIR/ プレフィックスではない: $TEST_DIR"
  rm -rf "$TEST_DIR"
  exit 1
fi

# 安全ガード 4: trap EXIT でクリーンアップ（INT/TERM でも発火）
cleanup() {
  if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
    # 二重チェック: プレフィックス再検証してから削除
    case "$TEST_DIR" in
      /tmp/*) rm -rf "$TEST_DIR" ;;
      *)
        if [ -n "${TMPDIR:-}" ]; then
          case "$TEST_DIR" in
            "${TMPDIR%/}/"*) rm -rf "$TEST_DIR" ;;
          esac
        fi
        ;;
    esac
  fi
}
trap cleanup EXIT INT TERM

echo "TEST_DIR: $TEST_DIR"
echo ""

# ========================================================================
# Group 1: fixture — 空白パス + ダミー変異ファイル配置
# ========================================================================
echo -e "${BOLD}--- Group 1: fixture 配置 ---${NC}"

# behavior: fixture: mktemp -d + mv で空白を含むディレクトリ（例 'mut audit test XXX'）を生成
if echo "$TEST_DIR" | grep -q ' '; then
  assert_eq "TEST_DIR に空白を含むパス生成" "has_space" "has_space"
else
  assert_eq "TEST_DIR に空白を含むパス生成" "has_space" "no_space($TEST_DIR)"
fi

# behavior: ダミー変異ファイル3つ（a.js, b.js, 'c with space.js'）を配置
cat > "${TEST_DIR}/a.js" << 'EOF'
// dummy mutation a
export const a = 1;
EOF
cat > "${TEST_DIR}/b.js" << 'EOF'
// dummy mutation b
export const b = 2;
EOF
cat > "${TEST_DIR}/c with space.js" << 'EOF'
// dummy mutation c (with space in filename)
export const c = 3;
EOF

created_count=$(find "$TEST_DIR" -maxdepth 1 -name '*.js' -type f 2>/dev/null | wc -l | tr -d ' \r')
assert_eq "3ファイル配置完了 (a.js, b.js, 'c with space.js')" "3" "$created_count"

echo ""

# ========================================================================
# Group 2: mutation-audit.sh の newer_files 反復経路を直接呼出
# ========================================================================
echo -e "${BOLD}--- Group 2: newer_files 反復経路 直接呼出 ---${NC}"

# task_dir を TEST_DIR 内に作成し、impl_marker を配置
# find -newer が .js ファイルをヒットさせるため impl_marker のタイムスタンプを古くする
TASK_DIR="${TEST_DIR}/task"
mkdir -p "$TASK_DIR"
IMPL_MARKER="${TASK_DIR}/implementation-output.txt"
echo "marker" > "$IMPL_MARKER"
sleep 1
# .js ファイルを再 touch して impl_marker より新しく (mtime 更新)
touch "${TEST_DIR}/a.js" "${TEST_DIR}/b.js" "${TEST_DIR}/c with space.js"

# common.sh / mutation-audit.sh を source し build_mutation_auditor_prompt を直接呼出
# 前提変数を設定（mutation-audit.sh 内の log/jq_safe/render_template 用）
export PROJECT_ROOT="$REAL_ROOT"
export TEMPLATES_DIR="${REAL_ROOT}/.forge/templates"
export SCHEMAS_DIR="${REAL_ROOT}/.forge/schemas"
export AGENTS_DIR="${REAL_ROOT}/.claude/agents"
export DEV_LOG_DIR="${TEST_DIR}/dev-logs"
mkdir -p "$DEV_LOG_DIR"
export ERRORS_FILE="${TEST_DIR}/errors.jsonl"
: "${json_fail_count:=0}"
export RESEARCH_DIR="unknown"

# 実行ライブラリ読込
# shellcheck source=/dev/null
source "${REAL_ROOT}/.forge/lib/common.sh"
# shellcheck source=/dev/null
source "${REAL_ROOT}/.forge/lib/mutation-audit.sh"

# WORK_DIR を空白含みの TEST_DIR に設定 — これが本テストの肝
export WORK_DIR="$TEST_DIR"

STDOUT_LOG="${TEST_DIR}/stdout.txt"
STDERR_LOG="${TEST_DIR}/stderr.txt"

# task_json は最小限の有効 JSON（required_behaviors と validation.layer_1.command を含む）
TASK_JSON='{"required_behaviors":["dummy behavior"],"validation":{"layer_1":{"command":"echo ok"}}}'

# build_mutation_auditor_prompt を直接呼出して newer_files 反復経路を実行
# この関数内で find "$WORK_DIR" -newer ... | while IFS= read -r f が回り、
# 各ファイルに対し wc -l < "$f" / cat "$f" / head -n ... "$f" が実行される
call_ret=0
build_mutation_auditor_prompt "test-task-id" "$TASK_DIR" "$TASK_JSON" "" \
  >"$STDOUT_LOG" 2>"$STDERR_LOG" || call_ret=$?

stdout_out=$(cat "$STDOUT_LOG" 2>/dev/null || echo "")
stderr_out=$(cat "$STDERR_LOG" 2>/dev/null || echo "")

# behavior: stderr に 'No such file or directory' が0件であることをアサート
assert_not_contains "stderr に 'No such file or directory' なし" "No such file or directory" "$stderr_out"

# behavior: mutation-audit.sh の newer_files 反復経路を呼出し、全3ファイルが処理されることをアサート（'processed: 3' 出力）
# build_mutation_auditor_prompt は各ファイルを '### <rel_path>' ヘッダで埋め込む
# （mutation-audit.sh L105-123 参照）。3つの .js 基名すべてのヘッダ出現を数える。
processed=0
echo "$stdout_out" | grep -qE '^### a\.js$' && processed=$((processed + 1))
echo "$stdout_out" | grep -qE '^### b\.js$' && processed=$((processed + 1))
echo "$stdout_out" | grep -qE '^### c with space\.js$' && processed=$((processed + 1))

# stdout に 'processed: 3' を出力（必須振る舞い: stdout に 'processed: 3' 含む）
echo "processed: ${processed}"

assert_eq "newer_files 反復で全3ファイル処理 (processed: 3)" "3" "$processed"

# 補助アサート: call_ret が 0（関数呼出が正常終了）
assert_eq "build_mutation_auditor_prompt exit 0" "0" "$call_ret"

echo ""

# ===== サマリー =====
print_test_summary
ret=$?

# 全テスト通過時のみ 'PASS' を最終出力して exit 0
if [ "$ret" -eq 0 ]; then
  echo "PASS"
fi
exit "$ret"
