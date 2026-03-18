#!/bin/bash
# test-preflight-check.sh — preflight_check: server.start_command ↔ package.json 整合性テスト
# 使い方: bash .forge/tests/test-preflight-check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FORGE_FLOW_SH="${REAL_ROOT}/.forge/loops/forge-flow.sh"

source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-preflight-check.sh — server.start_command ↔ package.json 整合性 =====${NC}"
echo ""

# ===== テスト環境セットアップ =====
TMPDIR_ROOT=$(mktemp -d)
trap "rm -rf '${TMPDIR_ROOT}'" EXIT

export ERRORS_FILE="${TMPDIR_ROOT}/errors.jsonl"
export RESEARCH_DIR="test-preflight"
json_fail_count=0
touch "$ERRORS_FILE"

# common.sh source 用の PROJECT_ROOT
export PROJECT_ROOT="${TMPDIR_ROOT}/project"
mkdir -p "${PROJECT_ROOT}/.forge/config"

source "${REAL_ROOT}/.forge/lib/common.sh"

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '${EXTRACT_FILE}'; rm -rf '${TMPDIR_ROOT}'" EXIT

extract_all_functions_awk "$FORGE_FLOW_SH" _check_server_script_compat > "$EXTRACT_FILE"

if [ ! -s "$EXTRACT_FILE" ]; then
  echo -e "  ${RED}✗${NC} _check_server_script_compat の抽出失敗"
  exit 1
fi

source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} 関数抽出完了"
echo ""

# ===== ヘルパー: dev config 書き込み =====
write_dev_config() {
  local start_cmd="$1"
  mkdir -p "${PROJECT_ROOT}/.forge/config"
  printf '{"server":{"start_command":"%s"}}' "$start_cmd" \
    > "${PROJECT_ROOT}/.forge/config/development.json"
}

# ===== ヘルパー: package.json 書き込み =====
write_pkg_json() {
  local dir="$1"
  local scripts_json="$2"  # JSON object literal e.g. '{"dev":"...","build":"..."}'
  mkdir -p "$dir"
  printf '{"scripts":%s}' "$scripts_json" > "${dir}/package.json"
}

# ===== Test 1: 正常系 — npm run dev + dev スクリプト存在 → exit 0 =====
# behavior: development.json server.start_command='npm run dev' + package.json scripts.dev存在 → preflight_check()がexit 0で通過（正常系: 整合一致）
echo -e "${BOLD}[1] 正常系: npm run dev + dev スクリプト存在 → exit 0${NC}"
write_dev_config "npm run dev"
write_pkg_json "${PROJECT_ROOT}" '{"dev":"node server.js","build":"webpack","test":"jest"}'
_WORK_DIR_ARG=""
result=0
_check_server_script_compat || result=$?
assert_eq "npm run dev + dev存在 → exit 0" "0" "$result"
echo ""

# ===== Test 2: 異常系 — npm run ui + ui スクリプト不在 → exit 1 + エラーメッセージ =====
# behavior: development.json server.start_command='npm run ui' + package.json scriptsにui不在 → exit 1 + 'script ui not found in package.json. Available: dev, build, test'のようなエラーメッセージ（異常系: スクリプト不在検出）
echo -e "${BOLD}[2] 異常系: npm run ui + ui スクリプト不在 → exit 1 + エラーメッセージ${NC}"
write_dev_config "npm run ui"
write_pkg_json "${PROJECT_ROOT}" '{"dev":"node server.js","build":"webpack","test":"jest"}'
_WORK_DIR_ARG=""
result=0
err_output=$({ _check_server_script_compat; } 2>&1) || result=$?
assert_eq "npm run ui + ui不在 → exit 1" "1" "$result"
assert_contains "エラーメッセージに 'ui' が含まれる" "'ui'" "$err_output"
assert_contains "エラーメッセージに 'not found' が含まれる" "not found" "$err_output"
assert_contains "利用可能スクリプト一覧に 'dev' が含まれる" "dev" "$err_output"
assert_contains "利用可能スクリプト一覧に 'Available:' が含まれる" "Available:" "$err_output"
echo ""

# ===== Test 3: pnpm → スキップ + 警告 =====
# behavior: development.json server.start_command='pnpm --filter api dev' → npm以外のパッケージマネージャは検証スキップ + 警告表示（エッジケース: pnpm/yarn対応）
echo -e "${BOLD}[3] pnpm --filter api dev → スキップ + 警告${NC}"
write_dev_config "pnpm --filter api dev"
# package.json なくても検証スキップであること
rm -f "${PROJECT_ROOT}/package.json"
_WORK_DIR_ARG=""
result=0
warn_output=$({ _check_server_script_compat; } 2>&1) || result=$?
assert_eq "pnpm コマンド → exit 0 (スキップ)" "0" "$result"
assert_contains "pnpm 警告メッセージが表示される" "pnpm" "$warn_output"
echo ""

# ===== Test 4: WORK_DIR 指定時は WORK_DIR 側の package.json を参照 =====
# behavior: WORK_DIR指定時にWORK_DIR側のpackage.jsonを参照する（PROJECT_ROOTのpackage.jsonではない）（コンテキスト依存: 外部プロジェクト）
echo -e "${BOLD}[4] WORK_DIR 指定 → WORK_DIR 側の package.json を参照${NC}"
WORK_DIR_TEST="${TMPDIR_ROOT}/work-project"
mkdir -p "$WORK_DIR_TEST"

# PROJECT_ROOT の package.json には dev スクリプトなし
write_dev_config "npm run dev"
write_pkg_json "${PROJECT_ROOT}" '{"build":"webpack"}'

# WORK_DIR の package.json には dev スクリプトあり
write_pkg_json "${WORK_DIR_TEST}" '{"dev":"npm start","build":"webpack"}'

# WORK_DIR 指定 → WORK_DIR側のpackage.json（devあり）→ exit 0
_WORK_DIR_ARG="$WORK_DIR_TEST"
result=0
_check_server_script_compat || result=$?
assert_eq "WORK_DIR側参照: WORKDIRにdevあり → exit 0" "0" "$result"

# PROJECT_ROOT のみ参照していた場合は失敗するはずを逆確認
# （WORK_DIR指定なしで同じ状態 → PROJECT_ROOTのpackage.jsonはdevなし → exit 1）
_WORK_DIR_ARG=""
result=0
_check_server_script_compat || result=$?
assert_eq "WORK_DIR未指定時はPROJECT_ROOT参照: devなし → exit 1 (逆確認)" "1" "$result"
echo ""

# ===== Test 5: package.json 不在 → 検証スキップ → exit 0 =====
# behavior: package.jsonが存在しない場合 → 検証をスキップしてexit 0で通過（エッジケース: 非Node.jsプロジェクト）
echo -e "${BOLD}[5] package.json 不在 → 検証スキップ → exit 0${NC}"
write_dev_config "npm run dev"
rm -f "${PROJECT_ROOT}/package.json"
_WORK_DIR_ARG=""
result=0
_check_server_script_compat || result=$?
assert_eq "package.json不在 → exit 0 (スキップ)" "0" "$result"
echo ""

# ===== Test 6: エッジケース — development.json 不在 → スキップ =====
# behavior: [追加] development.json が存在しない場合は検証スキップ
echo -e "${BOLD}[6] エッジケース: development.json 不在 → スキップ${NC}"
rm -f "${PROJECT_ROOT}/.forge/config/development.json"
_WORK_DIR_ARG=""
result=0
_check_server_script_compat || result=$?
assert_eq "development.json不在 → exit 0" "0" "$result"
echo ""

# ===== Test 7: エッジケース — start_command="none" → スキップ =====
# behavior: [追加] start_command が "none" の場合は検証スキップ
echo -e "${BOLD}[7] エッジケース: start_command=none → スキップ${NC}"
write_dev_config "none"
_WORK_DIR_ARG=""
result=0
_check_server_script_compat || result=$?
assert_eq "start_command=none → exit 0" "0" "$result"
echo ""

# ===== Test 8: yarn コマンド → スキップ + 警告 =====
# behavior: [追加] yarn も pnpm と同様にスキップ + 警告
echo -e "${BOLD}[8] yarn run dev → スキップ + 警告${NC}"
write_dev_config "yarn run dev"
_WORK_DIR_ARG=""
result=0
warn_output=$({ _check_server_script_compat; } 2>&1) || result=$?
assert_eq "yarn コマンド → exit 0 (スキップ)" "0" "$result"
assert_contains "yarn 警告メッセージが表示される" "yarn" "$warn_output"
echo ""

# ===== サマリー =====
print_test_summary
exit $?
