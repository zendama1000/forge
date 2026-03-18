#!/bin/bash
# test-run-task-decomposition.sh — run_task() 5関数分解テスト
# テスト対象: .forge/loops/ralph-loop.sh の
#   task_prepare / task_implement / task_validate_changes / task_run_l1_test / task_finalize
# 使い方: bash .forge/tests/test-run-task-decomposition.sh

set -uo pipefail

# ===== ヘルパー読み込み =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo -e "${BOLD}===== test-run-task-decomposition.sh — run_task() 5関数分解テスト =====${NC}"
echo ""

# ===== パス設定 =====
REAL_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RALPH_SH="${REAL_ROOT}/.forge/loops/ralph-loop.sh"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

# ===== テスト環境セットアップ =====
PROJECT_ROOT="/tmp/test-run-task-decomp"
rm -rf "$PROJECT_ROOT"

mkdir -p "${PROJECT_ROOT}/.forge/lib"
mkdir -p "${PROJECT_ROOT}/.forge/config"
mkdir -p "${PROJECT_ROOT}/.forge/state"
mkdir -p "${PROJECT_ROOT}/.forge/state/checkpoints"
mkdir -p "${PROJECT_ROOT}/.forge/state/notifications"
mkdir -p "${PROJECT_ROOT}/.forge/logs/development"
mkdir -p "${PROJECT_ROOT}/.claude/agents"
mkdir -p "${PROJECT_ROOT}/.forge/templates"

cp "${REAL_ROOT}/.forge/lib/common.sh"     "${PROJECT_ROOT}/.forge/lib/common.sh"
cp "${REAL_ROOT}/.forge/lib/bootstrap.sh"  "${PROJECT_ROOT}/.forge/lib/bootstrap.sh"
cp "${REAL_ROOT}/.forge/config/circuit-breaker.json" "${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
cp "${REAL_ROOT}/.forge/config/development.json"     "${PROJECT_ROOT}/.forge/config/development.json"

touch "${PROJECT_ROOT}/.forge/state/errors.jsonl"
touch "${PROJECT_ROOT}/.forge/state/investigation-log.jsonl"
touch "${PROJECT_ROOT}/.forge/state/task-events.jsonl"
touch "${PROJECT_ROOT}/.forge/state/lessons-learned.jsonl"

# ダミーエージェント・テンプレート
touch "${PROJECT_ROOT}/.claude/agents/implementer.md"
touch "${PROJECT_ROOT}/.claude/agents/fixer.md"
echo "{{TASK_JSON}}" > "${PROJECT_ROOT}/.forge/templates/implementer-prompt.md"

# ===== グローバル変数設定 =====
AGENTS_DIR="${PROJECT_ROOT}/.claude/agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge/templates"
DEV_LOG_DIR="${PROJECT_ROOT}/.forge/logs/development"
ERRORS_FILE="${PROJECT_ROOT}/.forge/state/errors.jsonl"
TASK_STACK="${PROJECT_ROOT}/.forge/state/task-stack.json"
TASK_EVENTS_FILE="${PROJECT_ROOT}/.forge/state/task-events.jsonl"
INVESTIGATION_LOG="${PROJECT_ROOT}/.forge/state/investigation-log.jsonl"
LOOP_SIGNAL_FILE="${PROJECT_ROOT}/.forge/state/loop-signal"
CIRCUIT_BREAKER_CONFIG="${PROJECT_ROOT}/.forge/config/circuit-breaker.json"
DEV_CONFIG="${PROJECT_ROOT}/.forge/config/development.json"
WORK_DIR="$PROJECT_ROOT"
RESEARCH_DIR="test-decomp"
NOTIFY_DIR="${PROJECT_ROOT}/.forge/state/notifications"
PROGRESS_FILE="${PROJECT_ROOT}/.forge/state/progress.json"
VALIDATION_STATS_FILE="${PROJECT_ROOT}/.forge/state/validation-stats.jsonl"
METRICS_FILE="${PROJECT_ROOT}/.forge/state/metrics.jsonl"
CHECKPOINT_DIR="${PROJECT_ROOT}/.forge/state/checkpoints"
RESEARCH_CONFIG=""
json_fail_count=0
CLAUDE_TIMEOUT=600
MAX_TASK_RETRIES=3
SAFETY_MAX_FILES_PER_TASK=5
SAFETY_MAX_FILES_HARD_LIMIT=10
IMPLEMENTER_MODEL="sonnet"
IMPLEMENTER_TIMEOUT=600
L1_DEFAULT_TIMEOUT=60

# ===== _RT_* 共有状態変数（ralph-loop.sh モジュールレベル変数） =====
_RT_TASK_JSON=""
_RT_PROMPT=""
_RT_OUTPUT=""
_RT_LOG_FILE=""
_RT_AGENT_FILE=""
_RT_AGENT_DISALLOWED=""
_RT_TASK_TYPE=""

source "${PROJECT_ROOT}/.forge/lib/common.sh"

# ===== 関数抽出 =====
echo -e "${BOLD}--- 関数抽出 ---${NC}"
EXTRACT_FILE=$(mktemp)
trap "rm -f '$EXTRACT_FILE'; rm -rf '$PROJECT_ROOT'" EXIT

extract_all_functions_awk "$RALPH_SH" \
  task_prepare task_implement task_validate_changes task_run_l1_test task_finalize \
  get_safety_profile \
  > "$EXTRACT_FILE"

source "$EXTRACT_FILE"
echo -e "  ${GREEN}✓${NC} 5関数抽出完了"
echo ""

# ===== テスト用フィクスチャ =====
write_task_stack() {
  cat > "$TASK_STACK" <<'EOJSON'
{
  "tasks": [
    {
      "task_id": "T-TEST",
      "status": "pending",
      "fail_count": 0,
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "description": "テストタスク",
      "validation": {
        "layer_1": {
          "command": "echo ok",
          "timeout_sec": 10
        }
      },
      "required_behaviors": ["テスト振る舞い"]
    }
  ],
  "updated_at": "2026-01-01T00:00:00Z"
}
EOJSON
}

write_task_stack_no_l1() {
  cat > "$TASK_STACK" <<'EOJSON'
{
  "tasks": [
    {
      "task_id": "T-NOL1",
      "status": "pending",
      "fail_count": 0,
      "task_type": "implementation",
      "dev_phase_id": "mvp",
      "description": "L1なしタスク",
      "required_behaviors": []
    }
  ],
  "updated_at": "2026-01-01T00:00:00Z"
}
EOJSON
}

# ===== モック定義 =====
# 呼出記録用フラグ
HANDLE_PASS_CALLED=false
HANDLE_PASS_ID=""
HANDLE_FAIL_CALLED=false
HANDLE_FAIL_ID=""
VALIDATE_TASK_CHANGES_CALLED=false
VALIDATE_L1_FILE_REFS_CALLED=false
RUN_MUTATION_AUDIT_CALLED=false
RUN_CLAUDE_CALLED=false
TASK_CHECKPOINT_CREATE_CALLED=false
TASK_CHECKPOINT_RESTORE_CALLED=false

handle_task_pass() {
  HANDLE_PASS_CALLED=true
  HANDLE_PASS_ID="${1:-}"
}
handle_task_fail() {
  HANDLE_FAIL_CALLED=true
  HANDLE_FAIL_ID="${1:-}"
}
run_claude() { RUN_CLAUDE_CALLED=true; return 0; }
retry_with_backoff() {
  local max="$1" back="$2"; shift 2
  "$@"
}
metrics_start() { :; }
metrics_record() { :; }
record_error() { :; }
record_task_event() { :; }
update_progress() { :; }
update_task_status() { :; }
sync_task_stack() { :; }
notify_human() { :; }
validate_locked_assertions() { return 0; }
should_run_mutation_audit() { return 1; }  # default: false
run_mutation_audit() { RUN_MUTATION_AUDIT_CALLED=true; }
get_relevant_lessons() { echo ""; }
acquire_lock() { return 0; }
release_lock() { return 0; }

task_checkpoint_create() {
  TASK_CHECKPOINT_CREATE_CALLED=true
  local work_dir="$1" task_id="$2"
  mkdir -p "$CHECKPOINT_DIR"
  echo "patch" > "${CHECKPOINT_DIR}/${task_id}.patch"
  echo ""    > "${CHECKPOINT_DIR}/${task_id}.untracked"
  echo "HEAD" > "${CHECKPOINT_DIR}/${task_id}.ref"
  return 0
}
task_checkpoint_restore() {
  TASK_CHECKPOINT_RESTORE_CALLED=true
  return 0
}

validate_task_changes() {
  VALIDATE_TASK_CHANGES_CALLED=true
  return "${_VTC_RETURN:-0}"
}
validate_l1_file_refs() {
  VALIDATE_L1_FILE_REFS_CALLED=true
  return "${_VL1_RETURN:-0}"
}

build_implementer_prompt() {
  echo "test-prompt-for-${1}"
}
get_task_json() {
  local id="$1"
  jq_safe --arg id "$id" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null
}
now_ts() { echo "20260101-000000"; }

execute_layer1_test() {
  echo "${_EL1_OUTPUT:-test-output}"
  return "${_EL1_RETURN:-0}"
}

# ===== モックリセットヘルパー =====
reset_mocks() {
  HANDLE_PASS_CALLED=false; HANDLE_PASS_ID=""
  HANDLE_FAIL_CALLED=false; HANDLE_FAIL_ID=""
  VALIDATE_TASK_CHANGES_CALLED=false
  VALIDATE_L1_FILE_REFS_CALLED=false
  RUN_MUTATION_AUDIT_CALLED=false
  RUN_CLAUDE_CALLED=false
  TASK_CHECKPOINT_CREATE_CALLED=false
  TASK_CHECKPOINT_RESTORE_CALLED=false
  _VTC_RETURN=0
  _VL1_RETURN=0
  _EL1_RETURN=0
  _EL1_OUTPUT="test-output"
  _RT_TASK_JSON=""
  _RT_PROMPT=""
  _RT_OUTPUT=""
  _RT_LOG_FILE=""
  _RT_AGENT_FILE=""
  _RT_AGENT_DISALLOWED=""
  _RT_TASK_TYPE=""
}

# ========================================================================
# Part A: 5関数 独立呼出テスト
# ========================================================================
echo -e "${BOLD}===== Part A: 5関数 独立呼出テスト =====${NC}"

# --------------------------------------------------------------------
# Group 1: task_prepare()
# behavior: task_prepare()がgitチェックポイント作成 + プロンプト構築を行い、成功時にexit 0を返す（正常系: 前処理分離）
# --------------------------------------------------------------------
echo -e "${BOLD}--- Group 1: task_prepare() ---${NC}"

write_task_stack
task_dir="${DEV_LOG_DIR}/T-TEST"
mkdir -p "$task_dir"

reset_mocks
# WORK_DIR != PROJECT_ROOT にしてチェックポイント呼出を確認
WORK_DIR_SAVE="$WORK_DIR"
WORK_DIR="/tmp/test-decomp-workdir-$$"
mkdir -p "$WORK_DIR"

# behavior: task_prepare()がgitチェックポイント作成 + プロンプト構築を行い、成功時にexit 0を返す（正常系: 前処理分離）
ret=0
task_prepare "T-TEST" "$task_dir" 2>/dev/null || ret=$?
assert_eq "task_prepare: 正常系 exit 0" "0" "$ret"

assert_eq "task_prepare: _RT_TASK_JSON が設定される" \
  "T-TEST" "$(echo "$_RT_TASK_JSON" | jq_safe -r '.task_id' 2>/dev/null)"

assert_contains "task_prepare: _RT_PROMPT が設定される (test-prompt-for-)" \
  "test-prompt-for-" "$_RT_PROMPT"

assert_contains "task_prepare: _RT_OUTPUT が設定される (implementation-output.txt)" \
  "implementation-output.txt" "$_RT_OUTPUT"

assert_contains "task_prepare: _RT_AGENT_FILE が設定される (implementer.md)" \
  "implementer.md" "$_RT_AGENT_FILE"

assert_eq "task_prepare: _RT_TASK_TYPE が設定される" \
  "implementation" "$_RT_TASK_TYPE"

# behavior: task_prepare()がgitチェックポイント作成（WORK_DIR != PROJECT_ROOT 時）
assert_eq "task_prepare: task_checkpoint_create が呼ばれる (WORK_DIR != PROJECT_ROOT)" \
  "true" "$TASK_CHECKPOINT_CREATE_CALLED"

# チェックポイントファイルの存在を確認
cp_patch="${CHECKPOINT_DIR}/T-TEST.patch"
cp_ref="${CHECKPOINT_DIR}/T-TEST.ref"
assert_eq "task_prepare: チェックポイント .patch ファイルが作成される" \
  "yes" "$([ -f "$cp_patch" ] && echo yes || echo no)"
assert_eq "task_prepare: チェックポイント .ref ファイルが作成される" \
  "yes" "$([ -f "$cp_ref" ] && echo yes || echo no)"

# WORK_DIR を元に戻す
WORK_DIR="$WORK_DIR_SAVE"

echo ""

# --------------------------------------------------------------------
# Group 2: task_implement()
# behavior: task_implement()がrun_claude()でImplementer実行を行い、implementation-output.txtを生成する（正常系: 実装分離）
# --------------------------------------------------------------------
echo -e "${BOLD}--- Group 2: task_implement() ---${NC}"

write_task_stack
task_dir="${DEV_LOG_DIR}/T-TEST"
mkdir -p "$task_dir"

reset_mocks
# _RT_* 変数を事前設定（task_prepare が設定する前提）
_RT_AGENT_FILE="${AGENTS_DIR}/implementer.md"
_RT_PROMPT="test prompt"
_RT_OUTPUT="${task_dir}/implementation-output.txt"
_RT_LOG_FILE="${DEV_LOG_DIR}/impl-T-TEST-test.log"
_RT_AGENT_DISALLOWED="WebSearch,WebFetch"
_RT_TASK_TYPE="implementation"

# run_claude がファイルを生成するようオーバーライド
run_claude() {
  RUN_CLAUDE_CALLED=true
  echo "implementation output" > "$4"  # $4 = output file
  return 0
}

# behavior: task_implement()がrun_claude()でImplementer実行を行い、implementation-output.txtを生成する（正常系: 実装分離）
ret=0
task_implement "T-TEST" "$task_dir" 2>/dev/null || ret=$?
assert_eq "task_implement: 正常系 exit 0" "0" "$ret"
assert_eq "task_implement: run_claude が呼ばれる" "true" "$RUN_CLAUDE_CALLED"
assert_eq "task_implement: implementation-output.txt が生成される" \
  "yes" "$([ -f "$_RT_OUTPUT" ] && echo yes || echo no)"

# 失敗系: run_claude が失敗 → handle_task_fail が呼ばれ return 1
reset_mocks
_RT_AGENT_FILE="${AGENTS_DIR}/implementer.md"
_RT_PROMPT="test prompt"
_RT_OUTPUT="${task_dir}/implementation-output.txt"
_RT_LOG_FILE="${DEV_LOG_DIR}/impl-T-TEST-fail.log"
_RT_AGENT_DISALLOWED="WebSearch,WebFetch"
_RT_TASK_TYPE="implementation"

run_claude() { return 1; }

ret=0
task_implement "T-TEST" "$task_dir" 2>/dev/null || ret=$?
assert_eq "task_implement: run_claude 失敗 → return 1" "1" "$ret"
assert_eq "task_implement: run_claude 失敗 → handle_task_fail 呼出" "true" "$HANDLE_FAIL_CALLED"

# run_claude をデフォルトに戻す
run_claude() { RUN_CLAUDE_CALLED=true; return 0; }
echo ""

# --------------------------------------------------------------------
# Group 3: task_validate_changes()
# behavior: task_validate_changes()がvalidate_task_changes() + validate_l1_file_refs()を実行する（正常系: 検証分離）
# --------------------------------------------------------------------
echo -e "${BOLD}--- Group 3: task_validate_changes() ---${NC}"

write_task_stack
task_dir="${DEV_LOG_DIR}/T-TEST"
mkdir -p "$task_dir"

# WORK_DIR != PROJECT_ROOT にして validation を有効化
WORK_DIR_SAVE="$WORK_DIR"
WORK_DIR="/tmp/test-decomp-workdir-$$"

reset_mocks
_RT_TASK_JSON=$(jq_safe --arg id "T-TEST" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null)
_RT_TASK_TYPE="implementation"

# behavior: task_validate_changes()がvalidate_task_changes() + validate_l1_file_refs()を実行する（正常系: 検証分離）
ret=0
task_validate_changes "T-TEST" "$task_dir" 2>/dev/null || ret=$?
assert_eq "task_validate_changes: 正常系 exit 0" "0" "$ret"
assert_eq "task_validate_changes: validate_task_changes が呼ばれる" "true" "$VALIDATE_TASK_CHANGES_CALLED"
assert_eq "task_validate_changes: validate_l1_file_refs が呼ばれる" "true" "$VALIDATE_L1_FILE_REFS_CALLED"

# ハードリミット超過: validate_task_changes が return 1 → handle_task_fail
reset_mocks
_RT_TASK_JSON=$(jq_safe --arg id "T-TEST" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null)
_RT_TASK_TYPE="implementation"
_VTC_RETURN=1  # ハードリミット超過

ret=0
task_validate_changes "T-TEST" "$task_dir" 2>/dev/null || ret=$?
assert_eq "task_validate_changes: ハードリミット超過 → return 1" "1" "$ret"
assert_eq "task_validate_changes: ハードリミット超過 → handle_task_fail 呼出" "true" "$HANDLE_FAIL_CALLED"

# L1 ファイル参照未作成: validate_l1_file_refs が return 1 → handle_task_fail
reset_mocks
_RT_TASK_JSON=$(jq_safe --arg id "T-TEST" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null)
_RT_TASK_TYPE="implementation"
_VTC_RETURN=0
_VL1_RETURN=1  # L1 ファイル未作成

ret=0
task_validate_changes "T-TEST" "$task_dir" 2>/dev/null || ret=$?
assert_eq "task_validate_changes: L1ファイル未作成 → return 1" "1" "$ret"
assert_eq "task_validate_changes: L1ファイル未作成 → handle_task_fail 呼出" "true" "$HANDLE_FAIL_CALLED"

WORK_DIR="$WORK_DIR_SAVE"
echo ""

# --------------------------------------------------------------------
# Group 4: task_run_l1_test()
# behavior: task_run_l1_test()がLayer 1テストコマンドをWORK_DIRで実行し、結果をキャプチャする（正常系: テスト実行分離）
# --------------------------------------------------------------------
echo -e "${BOLD}--- Group 4: task_run_l1_test() ---${NC}"

write_task_stack
task_dir="${DEV_LOG_DIR}/T-TEST"
mkdir -p "$task_dir"

reset_mocks
_RT_TASK_JSON=$(jq_safe --arg id "T-TEST" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null)
_EL1_RETURN=0
_EL1_OUTPUT="ALL PASSED"

# behavior: task_run_l1_test()がLayer 1テストコマンドをWORK_DIRで実行し、結果をキャプチャする（正常系: テスト実行分離）
ret=0
task_run_l1_test "T-TEST" "$task_dir" 2>/dev/null || ret=$?
assert_eq "task_run_l1_test: テストパス → exit 0" "0" "$ret"
assert_eq "task_run_l1_test: test-output.txt に結果が保存される" \
  "yes" "$([ -f "${task_dir}/test-output.txt" ] && echo yes || echo no)"
assert_contains "task_run_l1_test: test-output.txt の内容が正しい" \
  "ALL PASSED" "$(cat "${task_dir}/test-output.txt" 2>/dev/null)"

# テスト失敗: handle_task_fail が呼ばれ return 1
reset_mocks
_RT_TASK_JSON=$(jq_safe --arg id "T-TEST" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null)
_EL1_RETURN=1
_EL1_OUTPUT="FAILED: assertion error"

ret=0
task_run_l1_test "T-TEST" "$task_dir" 2>/dev/null || ret=$?
assert_eq "task_run_l1_test: テスト失敗 → return 1" "1" "$ret"
assert_eq "task_run_l1_test: テスト失敗 → handle_task_fail 呼出" "true" "$HANDLE_FAIL_CALLED"

# Layer 1 コマンド未定義: return 0（テスト完了扱い）
reset_mocks
write_task_stack_no_l1
_RT_TASK_JSON=$(jq_safe --arg id "T-NOL1" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null)
task_dir_nol1="${DEV_LOG_DIR}/T-NOL1"
mkdir -p "$task_dir_nol1"

ret=0
task_run_l1_test "T-NOL1" "$task_dir_nol1" 2>/dev/null || ret=$?
assert_eq "task_run_l1_test: L1コマンド未定義 → exit 0" "0" "$ret"
assert_eq "task_run_l1_test: L1コマンド未定義 → handle_task_fail 未呼出" "false" "$HANDLE_FAIL_CALLED"

write_task_stack  # 元に戻す
echo ""

# --------------------------------------------------------------------
# Group 5: task_finalize()
# behavior: task_finalize()がhandle_task_pass() or handle_task_fail()を呼び出し、タスク状態を更新する（正常系: 後処理分離）
# --------------------------------------------------------------------
echo -e "${BOLD}--- Group 5: task_finalize() ---${NC}"

write_task_stack
task_dir="${DEV_LOG_DIR}/T-TEST"
mkdir -p "$task_dir"

reset_mocks
_RT_TASK_JSON=$(jq_safe --arg id "T-TEST" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null)

# behavior: task_finalize()がhandle_task_pass() or handle_task_fail()を呼び出し、タスク状態を更新する（正常系: 後処理分離）
# mutation audit なし → handle_task_pass
should_run_mutation_audit() { return 1; }  # false = skip mutation audit
task_finalize "T-TEST" "$task_dir" 2>/dev/null
assert_eq "task_finalize: mutation audit なし → handle_task_pass 呼出" "true" "$HANDLE_PASS_CALLED"
assert_eq "task_finalize: handle_task_pass の task_id が正しい" "T-TEST" "$HANDLE_PASS_ID"

# mutation audit あり → run_mutation_audit
reset_mocks
_RT_TASK_JSON=$(jq_safe --arg id "T-TEST" '.tasks[] | select(.task_id == $id)' "$TASK_STACK" 2>/dev/null)
should_run_mutation_audit() { return 0; }  # true = run mutation audit
task_finalize "T-TEST" "$task_dir" 2>/dev/null
assert_eq "task_finalize: mutation audit あり → run_mutation_audit 呼出" "true" "$RUN_MUTATION_AUDIT_CALLED"
assert_eq "task_finalize: mutation audit あり → handle_task_pass 未呼出" "false" "$HANDLE_PASS_CALLED"

# mutation audit をデフォルトに戻す
should_run_mutation_audit() { return 1; }
echo ""

# ========================================================================
# Part B: ERR trap 伝播テスト
# behavior: set -Eが有効な状態で task_implement() 内でエラー発生 → ERR trapが発火し、task_prepare()で作成したチェックポイントからリストアされる（エッジケース: ERR trap伝播）
# ========================================================================
echo -e "${BOLD}===== Part B: ERR trap 伝播テスト =====${NC}"

# B-1: ralph-loop.sh に set -E が含まれることを確認
has_set_E=$(grep -c 'set -eEuo pipefail\|set -E' "$RALPH_SH" 2>/dev/null || echo 0)
assert_eq "ralph-loop.sh: set -E が有効化されている" "yes" \
  "$([ "$has_set_E" -gt 0 ] && echo yes || echo no)"

# B-2: task_prepare がチェックポイントファイルを作成する
write_task_stack
task_dir="${DEV_LOG_DIR}/T-ERRTEST"
mkdir -p "$task_dir"

WORK_DIR_SAVE="$WORK_DIR"
WORK_DIR="/tmp/test-decomp-workdir-$$-errtest"
mkdir -p "$WORK_DIR"

reset_mocks
task_prepare "T-TEST" "$task_dir" 2>/dev/null
assert_eq "ERR trap前提: task_prepare がチェックポイントを作成する" \
  "true" "$TASK_CHECKPOINT_CREATE_CALLED"
assert_eq "ERR trap前提: .ref ファイルが存在する" \
  "yes" "$([ -f "${CHECKPOINT_DIR}/T-TEST.ref" ] && echo yes || echo no)"

WORK_DIR="$WORK_DIR_SAVE"

# B-3: set -E 環境で task_implement 内の未捕捉エラーが ERR trap を発火させる
# metrics_start を故意に失敗させ（|| 保護なし）、set -eE + ERR trap でキャッチ
ERR_FLAG_FILE="${PROJECT_ROOT}/.forge/state/err-trap-fired.tmp"
rm -f "$ERR_FLAG_FILE"

# metrics_start を失敗するオーバーライドとして退避・置換
_metrics_start_original_def=$(declare -f metrics_start 2>/dev/null || echo "metrics_start() { :; }")

metrics_start() { return 1; }  # 故意に失敗（task_implement 内で || 保護なし）

_RT_AGENT_FILE="${AGENTS_DIR}/implementer.md"
_RT_PROMPT="err-trap-test-prompt"
_RT_OUTPUT="${DEV_LOG_DIR}/T-ERRTEST/implementation-output.txt"
_RT_LOG_FILE="${DEV_LOG_DIR}/T-ERRTEST/impl-test.log"
_RT_AGENT_DISALLOWED="WebSearch,WebFetch"

task_dir_err="${DEV_LOG_DIR}/T-ERRTEST"
mkdir -p "$task_dir_err"

# サブシェルで set -eE + ERR trap を設定してから task_implement を呼び出す
# ERR trap は一時ファイルへの書き込みで「発火」を記録
(
  set -eE
  trap "touch '${ERR_FLAG_FILE}'" ERR
  task_implement "T-ERRTEST" "$task_dir_err" 2>/dev/null
) 2>/dev/null || true

# ERR trap は trap 設定前に発火した場合も含め、サブシェル内で実行されるため
# ファイルの有無で判定する
err_fired="$([ -f "$ERR_FLAG_FILE" ] && echo yes || echo no)"
assert_eq "ERR trap伝播: set -E + metrics_start 失敗で ERR trap 発火" "yes" "$err_fired"
rm -f "$ERR_FLAG_FILE" 2>/dev/null || true

# metrics_start を元に戻す
eval "$_metrics_start_original_def" 2>/dev/null || metrics_start() { :; }
echo ""

# ========================================================================
# Part C: 回帰テスト — test-ralph-engine.sh が全パス
# behavior: 分解前のrun_task()のテストケース（test-ralph-engine.sh既存テスト）が分解後も全パスする（回帰検証）
# ========================================================================
echo -e "${BOLD}===== Part C: 回帰テスト =====${NC}"
echo -e "${BOLD}--- test-ralph-engine.sh 実行 ---${NC}"

REGRESSION_RESULT=0
bash "${SCRIPT_DIR}/test-ralph-engine.sh" 2>/dev/null || REGRESSION_RESULT=$?
assert_eq "回帰テスト: test-ralph-engine.sh が全パスする (exit 0)" "0" "$REGRESSION_RESULT"

echo ""

# ===== クリーンアップ =====
# trap EXIT で実行

# ===== サマリー =====
print_test_summary
exit $?
