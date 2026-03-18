#!/bin/bash
# test-l2-wiring.sh — L2 (E2E/統合) テスト配線の検証
# 自己完結型: セットアップ → 関数抽出 → テスト → クリーンアップ
# 使い方: bash test-l2-wiring.sh
#
# テスト対象:
#   1. check_l2_requires() — 構造化 requires の 5 プレフィックス型
#   2. setup_l2_environment() — setup_commands 実行
#   3. create_l2_fix_task() — dev_phase_id / task_type 引き継ぎ
#   4. build_implementer_prompt() — L2 info 拡張
#   5. run_phase3() — サーバーライフサイクル + requires + テスト実行
#   6. generate-tasks.sh — L2 criteria 抽出（変数レベル）

set -uo pipefail

# ===== カラー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ===== テスト集計 =====
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:200}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}✓${NC} ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ===== パス設定 =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RALPH_SH="${SCRIPT_DIR}/.forge/loops/ralph-loop.sh"
GENERATE_SH="${SCRIPT_DIR}/.forge/loops/generate-tasks.sh"
PROJECT_ROOT="/tmp/l2-wiring-test"

# ===== テスト環境セットアップ =====
echo -e "${BOLD}===== テスト環境セットアップ =====${NC}"

rm -rf "$PROJECT_ROOT"

mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/templates"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"
mkdir -p "${PROJECT_ROOT}/.forge/loops"
mkdir -p "${PROJECT_ROOT}/.claude/agents"

# 実ファイルコピー
cp "${SCRIPT_DIR}/.forge/lib/common.sh" "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${SCRIPT_DIR}/.forge/lib/bootstrap.sh" "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"
for libmod in mutation-audit.sh investigation.sh dev-phases.sh phase3.sh evidence-da.sh; do
  [ -f "${SCRIPT_DIR}/.forge/lib/${libmod}" ] && cp "${SCRIPT_DIR}/.forge/lib/${libmod}" "${PROJECT_ROOT}/.forge/lib/${libmod}"
done
cp "${SCRIPT_DIR}/.forge/config/development.json" "${PROJECT_ROOT}/.forge/config/development.json"
cp "${SCRIPT_DIR}/.forge/templates/implementer-prompt.md" "${PROJECT_ROOT}/.forge/templates/implementer-prompt.md"

# mutation audit 関連（build_implementer_prompt が参照する可能性）
if [ -f "${SCRIPT_DIR}/.forge/config/mutation-audit.json" ]; then
  cp "${SCRIPT_DIR}/.forge/config/mutation-audit.json" "${PROJECT_ROOT}/.forge/config/mutation-audit.json"
fi

# L2 テスト用の task-stack.json
cat > "${PROJECT_ROOT}/.forge/state/task-stack.json" << 'TASKSTACK'
{
  "phases": [
    {"id": "mvp", "name": "MVP"},
    {"id": "core", "name": "Core"}
  ],
  "tasks": [
    {
      "task_id": "T-001",
      "task_type": "setup",
      "dev_phase_id": "mvp",
      "description": "初期セットアップ",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok", "timeout_sec": 10}
      }
    },
    {
      "task_id": "T-002",
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "description": "ログインAPI実装",
      "required_behaviors": ["正常ログイン → 200"],
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok", "timeout_sec": 30},
        "layer_2": {
          "command": "echo L2_PASS",
          "requires": ["server"],
          "timeout_sec": 60
        }
      },
      "l2_criteria_refs": ["L2-001"]
    },
    {
      "task_id": "T-003",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "認証ミドルウェア実装",
      "required_behaviors": ["有効トークン → next()"],
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok", "timeout_sec": 30},
        "layer_2": {
          "command": "echo L2_PASS_CORE",
          "requires": ["env:HOME", "cmd:echo"],
          "timeout_sec": 90
        }
      }
    },
    {
      "task_id": "T-004",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "レート制限実装",
      "required_behaviors": ["リクエスト制限 → 429"],
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok", "timeout_sec": 30},
        "layer_2": {
          "command": "echo L2_PASS_RATE",
          "requires": ["env:NONEXISTENT_VAR_12345"],
          "timeout_sec": 60
        }
      }
    },
    {
      "task_id": "T-005",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "ファイル依存テスト",
      "required_behaviors": ["ファイル存在確認"],
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok", "timeout_sec": 30},
        "layer_2": {
          "command": "echo L2_PASS_FILE",
          "requires": ["file:package.json"],
          "timeout_sec": 60
        }
      }
    },
    {
      "task_id": "T-006",
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "description": "L2失敗テスト",
      "required_behaviors": ["テスト失敗検証"],
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok", "timeout_sec": 30},
        "layer_2": {
          "command": "echo FAIL_OUTPUT && exit 1",
          "requires": [],
          "timeout_sec": 30
        }
      }
    },
    {
      "task_id": "T-007",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "後方互換テスト（bare env var）",
      "required_behaviors": ["後方互換確認"],
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok", "timeout_sec": 30},
        "layer_2": {
          "command": "echo L2_PASS_COMPAT",
          "requires": ["HOME"],
          "timeout_sec": 60
        }
      }
    }
  ]
}
TASKSTACK

# 空ファイル
touch "${PROJECT_ROOT}/.forge/state/errors.jsonl"
touch "${PROJECT_ROOT}/.forge/state/investigation-log.jsonl"

echo -e "  ${GREEN}✓${NC} テスト環境作成完了"

# ===== グローバル変数設定 =====
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"
WORK_DIR="${PROJECT_ROOT}"
CRITERIA_FILE=""
RESEARCH_DIR="test-session"
json_fail_count=0
L1_DEFAULT_TIMEOUT=60
L2_DEFAULT_TIMEOUT=120
L2_MAX_TIMEOUT=300
L2_AUTO_RUN=true
L2_FAIL_CREATES_TASK=true
IMPLEMENTER_MODEL="sonnet"
IMPLEMENTER_TIMEOUT=600
CLAUDE_TIMEOUT=600
INVESTIGATION_LOG="${PROJECT_ROOT}/.forge/state/investigation-log.jsonl"
CANONICAL_TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
L2_SERVER_PID=""

# common.sh を source
source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== ralph-loop.sh + lib モジュールから関数定義を抽出 =====
FUNCTIONS=(
  check_l2_requires
  setup_l2_environment
  start_l2_server
  stop_l2_server
  run_phase3
  create_l2_fix_task
  build_implementer_prompt
  get_task_json
  sync_task_stack
)

# 検索対象ファイル（ralph-loop.sh + 分割されたモジュール）
SEARCH_FILES=(
  "$RALPH_SH"
  "${SCRIPT_DIR}/.forge/lib/mutation-audit.sh"
  "${SCRIPT_DIR}/.forge/lib/investigation.sh"
  "${SCRIPT_DIR}/.forge/lib/dev-phases.sh"
  "${SCRIPT_DIR}/.forge/lib/phase3.sh"
  "${SCRIPT_DIR}/.forge/lib/evidence-da.sh"
)

# brace depth tracking で関数抽出
extract_function_v2() {
  local func_name="$1"
  local src="$2"
  local start_line
  start_line=$(grep -n "^${func_name}()" "$src" | head -1 | cut -d: -f1)
  if [ -z "$start_line" ]; then
    echo "# function ${func_name} not found" >&2
    return 1
  fi
  local depth=0
  local end_line=""
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [ "$line_num" -lt "$start_line" ]; then continue; fi
    local opens=$(echo "$line" | tr -cd '{' | wc -c)
    local closes=$(echo "$line" | tr -cd '}' | wc -c)
    depth=$((depth + opens - closes))
    if [ "$depth" -le 0 ] && [ "$line_num" -gt "$start_line" ]; then
      end_line="$line_num"
      break
    fi
  done < "$src"
  if [ -n "$end_line" ]; then
    sed -n "${start_line},${end_line}p" "$src"
  fi
}

echo -e "${BOLD}===== ralph-loop.sh 関数抽出 =====${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'; rm -rf '$PROJECT_ROOT'" EXIT

extract_ok=true
for func in "${FUNCTIONS[@]}"; do
  body=""
  for src in "${SEARCH_FILES[@]}"; do
    [ -f "$src" ] || continue
    body=$(extract_function_v2 "$func" "$src" 2>/dev/null) && break
  done
  if [ -n "$body" ]; then
    echo "$body" >> "$EXTRACT_FILE"
    echo "" >> "$EXTRACT_FILE"
    echo -e "  ${GREEN}✓${NC} ${func}()"
  else
    echo -e "  ${RED}✗${NC} ${func}() — 抽出失敗"
    extract_ok=false
  fi
done

if [ "$extract_ok" = "false" ]; then
  echo -e "${RED}関数抽出に失敗しました。テスト中断。${NC}"
  exit 1
fi

source "$EXTRACT_FILE"
echo ""

# ========================================================================
# テスト 1: check_l2_requires — 5 プレフィックス型
# ========================================================================
echo -e "${BOLD}===== テスト1: check_l2_requires (構造化 requires) =====${NC}"

# 1a. 空配列 → OK
skip_reason=""
check_l2_requires '[]'
assert_eq "空 requires → OK" "0" "$?"
assert_eq "空 requires → skip_reason 空" "" "$skip_reason"

# 1b. env:HOME (存在する) → OK
skip_reason=""
check_l2_requires '["env:HOME"]'
assert_eq "env:HOME (存在) → OK" "0" "$?"

# 1c. env:NONEXISTENT_VAR_12345 (不在) → NG
skip_reason=""
check_l2_requires '["env:NONEXISTENT_VAR_12345"]' || true
assert_eq "env:NONEXISTENT_VAR_12345 → skip" "環境変数 NONEXISTENT_VAR_12345 が未設定" "$skip_reason"

# 1d. cmd:echo (存在) → OK
skip_reason=""
check_l2_requires '["cmd:echo"]'
assert_eq "cmd:echo (存在) → OK" "0" "$?"

# 1e. cmd:nonexistent_cmd_xyz (不在) → NG
skip_reason=""
check_l2_requires '["cmd:nonexistent_cmd_xyz"]' || true
assert_eq "cmd:nonexistent_cmd → skip" "コマンド nonexistent_cmd_xyz が見つからない" "$skip_reason"

# 1f. file:存在するファイル → OK
touch "${PROJECT_ROOT}/package.json"
skip_reason=""
check_l2_requires '["file:package.json"]'
assert_eq "file:package.json (存在) → OK" "0" "$?"

# 1g. file:不在のファイル → NG
skip_reason=""
check_l2_requires '["file:nonexistent-file.json"]' || true
assert_eq "file:nonexistent → skip" "ファイル nonexistent-file.json が見つからない" "$skip_reason"

# 1h. bare 環境変数 (後方互換) HOME → OK
skip_reason=""
check_l2_requires '["HOME"]'
assert_eq "bare HOME (後方互換) → OK" "0" "$?"

# 1i. bare 環境変数 不在 → NG
skip_reason=""
check_l2_requires '["NONEXISTENT_VAR_12345"]' || true
assert_eq "bare NONEXISTENT → skip" "環境変数 NONEXISTENT_VAR_12345 が未設定" "$skip_reason"

# 1j. 複合: env:HOME + cmd:echo → OK
skip_reason=""
check_l2_requires '["env:HOME", "cmd:echo"]'
assert_eq "複合 env+cmd → OK" "0" "$?"

# 1k. 複合: env:HOME + env:NONEXISTENT → 最初のNG で停止
skip_reason=""
check_l2_requires '["env:HOME", "env:NONEXISTENT_VAR_12345"]' || true
assert_eq "複合 first NG → skip" "環境変数 NONEXISTENT_VAR_12345 が未設定" "$skip_reason"

echo ""

# ========================================================================
# テスト 2: setup_l2_environment — setup_commands 実行
# ========================================================================
echo -e "${BOLD}===== テスト2: setup_l2_environment =====${NC}"

# 2a. setup_commands が空 → OK
# development.json のデフォルトは空配列
setup_l2_environment
assert_eq "空 setup_commands → OK" "0" "$?"

# 2b. setup_commands に成功コマンド → OK
jq '.layer_2.setup_commands = ["echo setup_ok"]' "$DEV_CONFIG" > "${DEV_CONFIG}.tmp" \
  && mv "${DEV_CONFIG}.tmp" "$DEV_CONFIG"
setup_l2_environment
assert_eq "成功コマンド → OK" "0" "$?"

# 2c. setup_commands に失敗コマンド → NG
jq '.layer_2.setup_commands = ["false"]' "$DEV_CONFIG" > "${DEV_CONFIG}.tmp" \
  && mv "${DEV_CONFIG}.tmp" "$DEV_CONFIG"
local_exit=0
setup_l2_environment 2>/dev/null || local_exit=$?
assert_eq "失敗コマンド → exit 1" "1" "$local_exit"

# 設定を元に戻す
jq '.layer_2.setup_commands = []' "$DEV_CONFIG" > "${DEV_CONFIG}.tmp" \
  && mv "${DEV_CONFIG}.tmp" "$DEV_CONFIG"

echo ""

# ========================================================================
# テスト 3: create_l2_fix_task — dev_phase_id / task_type 引き継ぎ
# ========================================================================
echo -e "${BOLD}===== テスト3: create_l2_fix_task (dev_phase_id/task_type) =====${NC}"

# task-stack をバックアップ
cp "$TASK_STACK" "${TASK_STACK}.bak"

# T-002 (mvp) に対して L2 fix タスクを生成
create_l2_fix_task "T-002" "Error: login test failed"

# 新タスクを検証
FIX_TASK=$(jq '.tasks[-1]' "$TASK_STACK")
FIX_ID=$(echo "$FIX_TASK" | jq -r '.task_id')
FIX_TYPE=$(echo "$FIX_TASK" | jq -r '.task_type')
FIX_PHASE=$(echo "$FIX_TASK" | jq -r '.dev_phase_id')
FIX_STATUS=$(echo "$FIX_TASK" | jq -r '.status')
FIX_L2FOR=$(echo "$FIX_TASK" | jq -r '.l2_fix_for')
FIX_INV=$(echo "$FIX_TASK" | jq -r '.investigator_fix')

assert_contains "fix task_id に l2fix を含む" "l2fix" "$FIX_ID"
assert_eq "task_type = implementation" "implementation" "$FIX_TYPE"
assert_eq "dev_phase_id = mvp (元タスクから継承)" "mvp" "$FIX_PHASE"
assert_eq "status = pending" "pending" "$FIX_STATUS"
assert_eq "l2_fix_for = T-002" "T-002" "$FIX_L2FOR"
assert_contains "investigator_fix に失敗出力" "login test failed" "$FIX_INV"

# T-003 (core) に対しても生成して dev_phase_id の継承を確認
create_l2_fix_task "T-003" "Error: auth middleware failed"
FIX_TASK2=$(jq '.tasks[-1]' "$TASK_STACK")
FIX_PHASE2=$(echo "$FIX_TASK2" | jq -r '.dev_phase_id')
FIX_TYPE2=$(echo "$FIX_TASK2" | jq -r '.task_type')
assert_eq "core タスクの fix → dev_phase_id = core" "core" "$FIX_PHASE2"
assert_eq "core タスクの fix → task_type = implementation" "implementation" "$FIX_TYPE2"

# task-stack を復元
cp "${TASK_STACK}.bak" "$TASK_STACK"

echo ""

# ========================================================================
# テスト 4: build_implementer_prompt — L2 info 拡張
# ========================================================================
echo -e "${BOLD}===== テスト4: build_implementer_prompt (L2 info 拡張) =====${NC}"

# T-002 (L2 定義あり) のプロンプト
TASK_JSON_T002=$(get_task_json "T-002")
PROMPT_T002=$(build_implementer_prompt "$TASK_JSON_T002")

assert_contains "L2 コマンドを含む" "echo L2_PASS" "$PROMPT_T002"
assert_contains "requires を含む" "server" "$PROMPT_T002"
assert_contains "タイムアウト情報を含む" "60秒" "$PROMPT_T002"
assert_contains "L2 criteria refs を含む" "L2-001" "$PROMPT_T002"
assert_contains "テスト作成指示を含む" "テストファイルをこのセッション内で作成" "$PROMPT_T002"

# T-001 (L2 定義なし) のプロンプト
TASK_JSON_T001=$(get_task_json "T-001")
PROMPT_T001=$(build_implementer_prompt "$TASK_JSON_T001")
assert_contains "L2 定義なし → デフォルトメッセージ" "Layer 2 テスト定義なし" "$PROMPT_T001"
assert_not_contains "L2 定義なし → 作成指示なし" "テストファイルをこのセッション内で作成" "$PROMPT_T001"

# T-003 (L2: env+cmd requires、l2_criteria_refs なし)
TASK_JSON_T003=$(get_task_json "T-003")
PROMPT_T003=$(build_implementer_prompt "$TASK_JSON_T003")
assert_contains "T-003: env:HOME を含む" "env:HOME" "$PROMPT_T003"
assert_contains "T-003: cmd:echo を含む" "cmd:echo" "$PROMPT_T003"

echo ""

# ========================================================================
# テスト 5: run_phase3 — 統合実行（サーバーなし版）
# ========================================================================
echo -e "${BOLD}===== テスト5: run_phase3 (統合実行) =====${NC}"

# server requires のあるタスク(T-002)を除外した task-stack を作成
# → サーバー起動を回避してテスト実行部分を検証
cat > "$TASK_STACK" << 'TASKSTACK_NOSERVER'
{
  "phases": [{"id": "mvp"}, {"id": "core"}],
  "tasks": [
    {
      "task_id": "T-PASS",
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "description": "L2 成功テスト",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok"},
        "layer_2": {
          "command": "echo L2_PASS_OK",
          "requires": ["env:HOME"],
          "timeout_sec": 30
        }
      }
    },
    {
      "task_id": "T-SKIP",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "L2 スキップテスト",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok"},
        "layer_2": {
          "command": "echo should_not_run",
          "requires": ["env:NONEXISTENT_VAR_12345"],
          "timeout_sec": 30
        }
      }
    },
    {
      "task_id": "T-FAIL",
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "description": "L2 失敗テスト",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok"},
        "layer_2": {
          "command": "echo FAIL_OUTPUT >&2 && exit 1",
          "requires": [],
          "timeout_sec": 30
        }
      }
    },
    {
      "task_id": "T-NOTEST",
      "task_type": "setup",
      "dev_phase_id": "mvp",
      "description": "L2 定義なし",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok"}
      }
    },
    {
      "task_id": "T-CMD-REQ",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "cmd requires テスト",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok"},
        "layer_2": {
          "command": "echo CMD_OK",
          "requires": ["cmd:bash"],
          "timeout_sec": 30
        }
      }
    },
    {
      "task_id": "T-FILE-REQ",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "file requires テスト",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok"},
        "layer_2": {
          "command": "echo FILE_OK",
          "requires": ["file:package.json"],
          "timeout_sec": 30
        }
      }
    },
    {
      "task_id": "T-BARE",
      "task_type": "implementation",
      "dev_phase_id": "core",
      "description": "後方互換 bare requires テスト",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok"},
        "layer_2": {
          "command": "echo BARE_OK",
          "requires": ["HOME"],
          "timeout_sec": 30
        }
      }
    }
  ]
}
TASKSTACK_NOSERVER

# development.json の setup_commands を空に戻す
jq '.layer_2.setup_commands = []' "$DEV_CONFIG" > "${DEV_CONFIG}.tmp" \
  && mv "${DEV_CONFIG}.tmp" "$DEV_CONFIG"

# package.json を置いておく（file: requires 用）
touch "${PROJECT_ROOT}/package.json"

# run_phase3 は相対パス (.forge/state/) に書くので cwd を合わせる
cd "$PROJECT_ROOT"

# run_phase3 実行
PHASE3_LOG=$(run_phase3 2>&1)

# integration-report.json を検証（run_phase3 は相対パスで書く）
REPORT=".forge/state/integration-report.json"
if [ -f "$REPORT" ]; then
  REPORT_STATUS=$(jq -r '.status' "$REPORT")
  REPORT_PASS=$(jq -r '.summary.pass' "$REPORT")
  REPORT_FAIL=$(jq -r '.summary.fail' "$REPORT")
  REPORT_SKIP=$(jq -r '.summary.skip' "$REPORT")

  assert_eq "レポート status = fail (1つ失敗あり)" "fail" "$REPORT_STATUS"
  assert_eq "PASS 数 = 4 (T-PASS,T-CMD-REQ,T-FILE-REQ,T-BARE)" "4" "$REPORT_PASS"
  assert_eq "FAIL 数 = 1 (T-FAIL)" "1" "$REPORT_FAIL"
  assert_eq "SKIP 数 = 1 (T-SKIP: env 不在)" "1" "$REPORT_SKIP"

  # 各タスクの結果を個別検証
  PASS_RESULT=$(jq -r '.results[] | select(.task_id == "T-PASS") | .result' "$REPORT")
  SKIP_RESULT=$(jq -r '.results[] | select(.task_id == "T-SKIP") | .result' "$REPORT")
  FAIL_RESULT=$(jq -r '.results[] | select(.task_id == "T-FAIL") | .result' "$REPORT")
  CMD_RESULT=$(jq -r '.results[] | select(.task_id == "T-CMD-REQ") | .result' "$REPORT")
  FILE_RESULT=$(jq -r '.results[] | select(.task_id == "T-FILE-REQ") | .result' "$REPORT")
  BARE_RESULT=$(jq -r '.results[] | select(.task_id == "T-BARE") | .result' "$REPORT")

  assert_eq "T-PASS → pass" "pass" "$PASS_RESULT"
  assert_eq "T-SKIP → skip" "skip" "$SKIP_RESULT"
  assert_eq "T-FAIL → fail" "fail" "$FAIL_RESULT"
  assert_eq "T-CMD-REQ → pass (cmd:bash)" "pass" "$CMD_RESULT"
  assert_eq "T-FILE-REQ → pass (file:package.json)" "pass" "$FILE_RESULT"
  assert_eq "T-BARE → pass (bare HOME)" "pass" "$BARE_RESULT"

  # T-NOTEST はレポートに含まれない（L2 定義なし）
  NOTEST_RESULT=$(jq -r '.results[] | select(.task_id == "T-NOTEST") | .result' "$REPORT")
  assert_eq "T-NOTEST → レポートに含まれない" "" "$NOTEST_RESULT"

  # skip reason の内容
  SKIP_REASON_REPORT=$(jq -r '.results[] | select(.task_id == "T-SKIP") | .reason' "$REPORT")
  assert_contains "SKIP reason に env 未設定" "NONEXISTENT_VAR_12345" "$SKIP_REASON_REPORT"

  # fail output の内容
  FAIL_OUTPUT_REPORT=$(jq -r '.results[] | select(.task_id == "T-FAIL") | .output' "$REPORT")
  assert_contains "FAIL output に失敗メッセージ" "FAIL_OUTPUT" "$FAIL_OUTPUT_REPORT"

else
  echo -e "  ${RED}✗${NC} integration-report.json が生成されていない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo ""

# ========================================================================
# テスト 5b: run_phase3 の失敗時 → create_l2_fix_task 連動
# ========================================================================
echo -e "${BOLD}===== テスト5b: run_phase3 → create_l2_fix_task 連動 =====${NC}"

# T-FAIL に対する l2fix タスクが生成されたか
FIX_TASKS=$(jq '[.tasks[] | select(.l2_fix_for == "T-FAIL")] | length' "$TASK_STACK")
assert_eq "T-FAIL の l2fix タスク数 = 1" "1" "$FIX_TASKS"

FIX_FOR_FAIL=$(jq '.tasks[] | select(.l2_fix_for == "T-FAIL")' "$TASK_STACK")
FIX_FAIL_TYPE=$(echo "$FIX_FOR_FAIL" | jq -r '.task_type')
FIX_FAIL_PHASE=$(echo "$FIX_FOR_FAIL" | jq -r '.dev_phase_id')
FIX_FAIL_STATUS=$(echo "$FIX_FOR_FAIL" | jq -r '.status')
assert_eq "l2fix task_type = implementation" "implementation" "$FIX_FAIL_TYPE"
assert_eq "l2fix dev_phase_id = mvp (元タスク T-FAIL から継承)" "mvp" "$FIX_FAIL_PHASE"
assert_eq "l2fix status = pending" "pending" "$FIX_FAIL_STATUS"

echo ""

# ========================================================================
# テスト 6: run_phase3 — L2 テスト定義なしの場合
# ========================================================================
echo -e "${BOLD}===== テスト6: run_phase3 (L2 テスト定義なし) =====${NC}"

cat > "$TASK_STACK" << 'TASKSTACK_NOLAYER2'
{
  "tasks": [
    {
      "task_id": "T-ONLY-L1",
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "description": "L1 only タスク",
      "status": "completed",
      "fail_count": 0,
      "validation": {
        "layer_1": {"command": "echo ok"}
      }
    }
  ]
}
TASKSTACK_NOLAYER2

run_phase3 2>/dev/null

REPORT_NOLAYER=$(jq -r '.status' "$REPORT")
assert_eq "L2 定義なし → status = no_tests" "no_tests" "$REPORT_NOLAYER"

echo ""

# ========================================================================
# テスト 7: generate-tasks.sh の L2 criteria 抽出ロジック（変数レベル）
# ========================================================================
echo -e "${BOLD}===== テスト7: generate-tasks.sh L2 criteria 抽出 =====${NC}"

# テスト用 criteria ファイル作成（L2 criteria あり）
CRITERIA_WITH_L2=$(mktemp)
cat > "$CRITERIA_WITH_L2" << 'CRITERIA'
{
  "theme": "テストテーマ",
  "layer_2_criteria": [
    {"id": "L2-001", "description": "ログインE2E"},
    {"id": "L2-002", "description": "サインアップE2E"}
  ]
}
CRITERIA

L2_COUNT=$(jq '.layer_2_criteria // [] | length' "$CRITERIA_WITH_L2" 2>/dev/null || echo 0)
assert_eq "L2 criteria 件数 = 2" "2" "$L2_COUNT"

L2_CONTENT=$(jq -c '.layer_2_criteria' "$CRITERIA_WITH_L2")
assert_contains "L2 criteria に L2-001 を含む" "L2-001" "$L2_CONTENT"
assert_contains "L2 criteria に L2-002 を含む" "L2-002" "$L2_CONTENT"

# テスト用 criteria ファイル（L2 criteria なし）
CRITERIA_NO_L2=$(mktemp)
cat > "$CRITERIA_NO_L2" << 'CRITERIA2'
{
  "theme": "テストテーマ",
  "layer_1_criteria": [{"id": "L1-001"}]
}
CRITERIA2

L2_COUNT_NONE=$(jq '.layer_2_criteria // [] | length' "$CRITERIA_NO_L2" 2>/dev/null || echo 0)
assert_eq "L2 criteria なし → 件数 = 0" "0" "$L2_COUNT_NONE"

rm -f "$CRITERIA_WITH_L2" "$CRITERIA_NO_L2"

echo ""

# ========================================================================
# テスト 8: development.json の L2 設定
# ========================================================================
echo -e "${BOLD}===== テスト8: development.json L2 設定 =====${NC}"

L2_TIMEOUT_CFG=$(jq -r '.layer_2.default_timeout_sec' "$DEV_CONFIG")
L2_MAX_CFG=$(jq -r '.layer_2.max_timeout_sec' "$DEV_CONFIG")
L2_SETUP_CFG=$(jq -r '.layer_2.setup_commands | length' "$DEV_CONFIG")

assert_eq "default_timeout_sec = 120" "120" "$L2_TIMEOUT_CFG"
assert_eq "max_timeout_sec = 300" "300" "$L2_MAX_CFG"
assert_eq "setup_commands = 空配列" "0" "$L2_SETUP_CFG"

echo ""

# ========================================================================
# テスト 9: テンプレート変数の整合性
# ========================================================================
echo -e "${BOLD}===== テスト9: テンプレート変数整合性 =====${NC}"

PLANNING_TEMPLATE="${SCRIPT_DIR}/.forge/templates/task-planning-prompt.md"
IMPL_TEMPLATE="${SCRIPT_DIR}/.forge/templates/implementer-prompt.md"

# task-planning-prompt.md に L2 テンプレート変数があるか
PLANNING_CONTENT=$(cat "$PLANNING_TEMPLATE")
assert_contains "planning テンプレートに {{L2_CRITERIA}}" "{{L2_CRITERIA}}" "$PLANNING_CONTENT"
assert_contains "planning テンプレートに {{L2_DEFAULT_TIMEOUT}}" "{{L2_DEFAULT_TIMEOUT}}" "$PLANNING_CONTENT"
assert_contains "planning テンプレートに L2 マッピング手順" "Layer 2 マッピング" "$PLANNING_CONTENT"
assert_contains "planning テンプレートに l2_criteria_refs" "l2_criteria_refs" "$PLANNING_CONTENT"
assert_contains "planning テンプレートに構造化 requires 説明" "server | env:VAR | cmd:NAME | file:PATH" "$PLANNING_CONTENT"

# implementer-prompt.md に L2 ガイドラインがあるか
IMPL_CONTENT=$(cat "$IMPL_TEMPLATE")
assert_contains "implementer テンプレートに L2 ガイドライン" "Layer 2 テスト作成ガイドライン" "$IMPL_CONTENT"
assert_contains "implementer テンプレートに冪等" "冪等" "$IMPL_CONTENT"
assert_contains "implementer テンプレートに Phase 3 管理" "Phase 3 が管理" "$IMPL_CONTENT"

echo ""

# ========================================================================
# サマリー
# ========================================================================
echo -e "${BOLD}=========================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo -e "テスト結果: ${PASS_COUNT}/${TOTAL} PASSED, ${FAIL_COUNT} FAILED"
echo -e "==========================================${NC}"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "${RED}FAIL${NC}"
  exit 1
else
  echo -e "${GREEN}ALL PASSED${NC}"
  exit 0
fi
