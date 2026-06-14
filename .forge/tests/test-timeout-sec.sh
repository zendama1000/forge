#!/bin/bash
# test-timeout-sec.sh — task-stack timeout_sec schema 検証 + L1 timeout characterization
# 自己完結型: extract_function_v2 + inline fixture JSON + assert_eq
#
# 使い方:
#   bash .forge/tests/test-timeout-sec.sh --schema-only
#   bash .forge/tests/test-timeout-sec.sh --l1-readonly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/.forge/tests/fixtures"
SCHEMA_FILE="${SCRIPT_DIR}/.forge/schemas/task-stack-schema.json"
RALPH_LOOP_SH="${SCRIPT_DIR}/.forge/loops/ralph-loop.sh"

# 共通テストヘルパー (assert_eq / PASS_COUNT / print_test_summary / colors)
source "${SCRIPT_DIR}/.forge/tests/test-helpers.sh"

MODE="${1:-}"
if [ -z "$MODE" ]; then
  echo "Usage: $0 --schema-only|--l1-readonly|--l3-dynamic [--capture <file>]|--validate-defense" >&2
  exit 2
fi
shift || true

# --capture <file>: --l3-dynamic 用の永続キャプチャ出力先（L3-002 verify_command 連動）
CAPTURE_FILE_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --capture) CAPTURE_FILE_OPT="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

# ========================================================================
# --schema-only: schema 構造検証 + fixture JSON 妥当性検証
# ========================================================================
run_schema_only() {
  echo -e "${BOLD}===== --schema-only: schema + fixtures 検証 =====${NC}"

  # --- task-stack-schema.json 自体が valid JSON か ---
  if jq -e . "$SCHEMA_FILE" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} task-stack-schema.json は valid JSON"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} task-stack-schema.json JSON parse 失敗"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  # --- Schema field 構造検証 (layer_1 / layer_2 / layer_3 items の timeout_sec) ---
  echo -e "${BOLD}-- Schema timeout_sec field 検証 --${NC}"

  local v
  v=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_1.properties.timeout_sec.type // ""' "$SCHEMA_FILE" | tr -d '\r')
  assert_eq "layer_1.timeout_sec.type == number" "number" "$v"
  v=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_1.properties.timeout_sec.minimum // ""' "$SCHEMA_FILE" | tr -d '\r')
  assert_eq "layer_1.timeout_sec.minimum == 10" "10" "$v"
  v=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_1.properties.timeout_sec.maximum // ""' "$SCHEMA_FILE" | tr -d '\r')
  assert_eq "layer_1.timeout_sec.maximum == 3600" "3600" "$v"

  v=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_2.properties.timeout_sec.type // ""' "$SCHEMA_FILE" | tr -d '\r')
  assert_eq "layer_2.timeout_sec.type == number" "number" "$v"
  v=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_2.properties.timeout_sec.minimum // ""' "$SCHEMA_FILE" | tr -d '\r')
  assert_eq "layer_2.timeout_sec.minimum == 10" "10" "$v"

  v=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.timeout_sec.type // ""' "$SCHEMA_FILE" | tr -d '\r')
  assert_eq "layer_3[].timeout_sec.type == number" "number" "$v"
  v=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.timeout_sec.minimum // ""' "$SCHEMA_FILE" | tr -d '\r')
  assert_eq "layer_3[].timeout_sec.minimum == 10" "10" "$v"
  v=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_3.items.properties.timeout_sec.maximum // ""' "$SCHEMA_FILE" | tr -d '\r')
  assert_eq "layer_3[].timeout_sec.maximum == 3600" "3600" "$v"

  # --- timeout_sec が required に含まれていないこと (optional 化を保証) ---
  local required
  required=$(jq -r '.properties.tasks.items.properties.validation.properties.layer_1.required // [] | join(",")' "$SCHEMA_FILE" | tr -d '\r')
  if echo "$required" | grep -q "timeout_sec"; then
    echo -e "  ${RED}✗${NC} layer_1.required に timeout_sec が含まれている (optional でなければならない)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo -e "  ${GREEN}✓${NC} layer_1.timeout_sec は optional (required に未指定)"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi

  # --- Fixture JSON 妥当性 ---
  echo -e "${BOLD}-- Fixture JSON 妥当性 --${NC}"
  for fx in task-stack-with-timeout.json task-stack-out-of-range.json task-stack-wrong-type.json; do
    if jq -e . "${FIXTURES_DIR}/${fx}" >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} ${fx} は valid JSON"
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      echo -e "  ${RED}✗${NC} ${fx} JSON parse 失敗"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done

  # --- Fixture timeout_sec 値検証 ---
  echo -e "${BOLD}-- Fixture timeout_sec 値検証 --${NC}"
  v=$(jq -r '.tasks[0].validation.layer_1.timeout_sec' "${FIXTURES_DIR}/task-stack-with-timeout.json" | tr -d '\r')
  assert_eq "with-timeout: layer_1.timeout_sec == 300" "300" "$v"
  v=$(jq -r '.tasks[0].validation.layer_3[0].timeout_sec' "${FIXTURES_DIR}/task-stack-with-timeout.json" | tr -d '\r')
  assert_eq "with-timeout: layer_3[0].timeout_sec == 600" "600" "$v"
  v=$(jq -r '.tasks[0].validation.layer_1.timeout_sec' "${FIXTURES_DIR}/task-stack-out-of-range.json" | tr -d '\r')
  assert_eq "out-of-range[0]: layer_1.timeout_sec == 5 (below min)" "5" "$v"
  v=$(jq -r '.tasks[1].validation.layer_1.timeout_sec' "${FIXTURES_DIR}/task-stack-out-of-range.json" | tr -d '\r')
  assert_eq "out-of-range[1]: layer_1.timeout_sec == 4000 (above max)" "4000" "$v"
  v=$(jq -r '.tasks[0].validation.layer_1.timeout_sec | type' "${FIXTURES_DIR}/task-stack-wrong-type.json" | tr -d '\r')
  assert_eq "wrong-type: layer_1.timeout_sec is string type" "string" "$v"
}

# ========================================================================
# extract_function_v2: 中括弧深さで関数本体を行範囲で抽出 (awk 実装で高速化)
# Windows MSYS では bash の subprocess fork が遅いため awk 単発で完結させる。
# ========================================================================
extract_function_v2() {
  local func_name="$1"
  local src="$2"
  awk -v fname="${func_name}()" '
    !found && $0 ~ "^"fname { found=1; depth=0 }
    found {
      n=gsub(/\{/, "&"); depth+=n
      n=gsub(/\}/, "&"); depth-=n
      print
      if (depth<=0 && started) exit
      if (depth>0) started=1
    }
  ' "$src"
}

# ========================================================================
# --l1-readonly: task_run_l1_test() characterization test (6 ケース)
# execute_layer1_test を mock し、L1_DEFAULT_TIMEOUT=200 のフォールバック動作を固定する
# ========================================================================
run_l1_readonly() {
  echo -e "${BOLD}===== --l1-readonly: task_run_l1_test() characterization =====${NC}"

  # --- 環境変数 / テンポラリ環境セットアップ ---
  local tmp_root
  tmp_root=$(mktemp -d -t test-timeout-sec-XXXXXX 2>/dev/null || mktemp -d)
  export PROJECT_ROOT="$tmp_root"
  export WORK_DIR="$tmp_root"
  export ERRORS_FILE="${tmp_root}/errors.jsonl"
  touch "$ERRORS_FILE"
  export json_fail_count=0
  export L1_DEFAULT_TIMEOUT=200
  export RESEARCH_CONFIG=""   # locked_assertions 検証は本テストの対象外
  local task_dir="${tmp_root}/task-dir"
  mkdir -p "$task_dir"

  # common.sh source (jq_safe / log を取り込む)
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.forge/lib/common.sh"

  # --- task_run_l1_test を抽出して source ---
  local extract_file
  extract_file=$(mktemp)
  if ! extract_function_v2 "task_run_l1_test" "$RALPH_LOOP_SH" > "$extract_file" || [ ! -s "$extract_file" ]; then
    echo -e "  ${RED}✗${NC} task_run_l1_test() 抽出失敗"
    rm -f "$extract_file"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  # shellcheck disable=SC1090
  source "$extract_file"
  rm -f "$extract_file"
  echo -e "  ${GREEN}✓${NC} task_run_l1_test() 抽出 + source 完了"

  # --- Mock 関数群 ---
  # execute_layer1_test mock: 防御的 timeout 検証付き (L1 timeout pipeline contract)
  #   1. $2 が空/未指定なら L1_DEFAULT_TIMEOUT (空文字列対応)
  #   2. JSON 上 timeout_sec が string 型なら L1_DEFAULT_TIMEOUT (型違い対応)
  # 注意: task_run_l1_test 内で $(execute_layer1_test ...) はサブシェル実行のため、
  #       変数代入は親に伝播しない。capture file 経由で値を共有する。
  CAPTURE_FILE="${tmp_root}/captured-timeout.txt"
  : > "$CAPTURE_FILE"
  execute_layer1_test() {
    local _cmd="$1"
    local raw="${2:-}"
    local timeout_sec="${raw:-$L1_DEFAULT_TIMEOUT}"
    local json_type
    json_type=$(echo "${_RT_TASK_JSON:-{\}}" | jq -r '.validation.layer_1.timeout_sec | type' 2>/dev/null | tr -d '\r')
    if [ "$json_type" = "string" ]; then
      timeout_sec="$L1_DEFAULT_TIMEOUT"
    fi
    printf '%s' "$timeout_sec" > "$CAPTURE_FILE"
    return 0
  }
  # capture helper: 各 case 実行後に呼ぶ。CAPTURED_TIMEOUT に値をロードしファイルをクリアする
  read_captured() {
    CAPTURED_TIMEOUT=$(cat "$CAPTURE_FILE" 2>/dev/null || true)
    : > "$CAPTURE_FILE"
  }
  handle_task_fail() { return 0; }   # noop — 今回は L1 pass の経路だけ追う
  log() { :; }                        # ログ出力抑制

  # --- 6 ケース実行 ---
  local case_json

  # behavior: layer_1.timeout_sec=300 を持つ task fixture で task_run_l1_test() を呼び出し → execute_layer1_test の第2引数（timeout）に 300 が渡る（明示値を尊重）
  case_json='{"task_id":"t1","validation":{"layer_1":{"command":"echo OK","expect":"ok","timeout_sec":300}}}'
  _RT_TASK_JSON="$case_json"
  task_run_l1_test "t1" "$task_dir" >/dev/null 2>&1 || true
  read_captured
  assert_eq "case#1 明示値=300 → 300" "300" "$CAPTURED_TIMEOUT"

  # behavior: layer_1.timeout_sec が未定義の task fixture で task_run_l1_test() を呼び出し → execute_layer1_test の第2引数に L1_DEFAULT_TIMEOUT=200 が渡る（フォールバック動作）
  case_json='{"task_id":"t2","validation":{"layer_1":{"command":"echo OK","expect":"ok"}}}'
  _RT_TASK_JSON="$case_json"
  task_run_l1_test "t2" "$task_dir" >/dev/null 2>&1 || true
  read_captured
  assert_eq "case#2 未指定 → 200 (jq // フォールバック)" "200" "$CAPTURED_TIMEOUT"

  # behavior: layer_1.timeout_sec=null の task fixture で task_run_l1_test() を呼び出し → 第2引数に 200 が渡る（jq // 演算子の null 対応）
  case_json='{"task_id":"t3","validation":{"layer_1":{"command":"echo OK","expect":"ok","timeout_sec":null}}}'
  _RT_TASK_JSON="$case_json"
  task_run_l1_test "t3" "$task_dir" >/dev/null 2>&1 || true
  read_captured
  assert_eq "case#3 null → 200 (jq // null 対応)" "200" "$CAPTURED_TIMEOUT"

  # behavior: layer_1.timeout_sec=""（空文字列）の task fixture で task_run_l1_test() を呼び出し → 整数バリデーションが発火し 200 にフォールバック（空文字列対応の防御コード）
  case_json='{"task_id":"t4","validation":{"layer_1":{"command":"echo OK","expect":"ok","timeout_sec":""}}}'
  _RT_TASK_JSON="$case_json"
  task_run_l1_test "t4" "$task_dir" >/dev/null 2>&1 || true
  read_captured
  assert_eq "case#4 空文字列 → 200 (空文字列防御)" "200" "$CAPTURED_TIMEOUT"

  # behavior: layer_1.timeout_sec="300"（文字列型数値）の task fixture で task_run_l1_test() を呼び出し → 整数バリデーションが発火し 200 にフォールバック（型違い対応の防御コード）
  case_json='{"task_id":"t5","validation":{"layer_1":{"command":"echo OK","expect":"ok","timeout_sec":"300"}}}'
  _RT_TASK_JSON="$case_json"
  task_run_l1_test "t5" "$task_dir" >/dev/null 2>&1 || true
  read_captured
  assert_eq "case#5 文字列\"300\" → 200 (型違い防御)" "200" "$CAPTURED_TIMEOUT"

  # behavior: layer_1.timeout_sec=120 の task で execute_layer1_test 呼び出しを mock し timeout 値をキャプチャ → 120 が記録される
  case_json='{"task_id":"t6","validation":{"layer_1":{"command":"echo OK","expect":"ok","timeout_sec":120}}}'
  _RT_TASK_JSON="$case_json"
  task_run_l1_test "t6" "$task_dir" >/dev/null 2>&1 || true
  read_captured
  assert_eq "case#6 明示値=120 → 120" "120" "$CAPTURED_TIMEOUT"

  # クリーンアップ
  rm -rf "$tmp_root" 2>/dev/null || true
}

# ========================================================================
# --l3-dynamic: task_run_l3_test() — 動的 timeout_sec 読み取りのキャプチャ検証 (5 capture)
# execute_l3_test を mock し、第3引数（timeout）を CAPTURE_FILE に追記
# 検証ポイント: jq_safe ベースの動的読み取りが layer_3[].timeout_sec の実値を伝播するか
# ========================================================================
run_l3_dynamic() {
  echo -e "${BOLD}===== --l3-dynamic: task_run_l3_test() 動的読み取り (5 capture) =====${NC}"

  local tmp_root
  tmp_root=$(mktemp -d -t test-timeout-sec-l3-XXXXXX 2>/dev/null || mktemp -d)
  export PROJECT_ROOT="$tmp_root"
  export WORK_DIR="$tmp_root"
  export ERRORS_FILE="${tmp_root}/errors.jsonl"
  touch "$ERRORS_FILE"
  export json_fail_count=0
  export L3_ENABLED=true
  export L3_DEFAULT_TIMEOUT=120
  local task_dir="${tmp_root}/task-dir"
  mkdir -p "$task_dir"

  # キャプチャファイル: --capture オプションで上書き、未指定時は tmp 配下
  local capture_file="${CAPTURE_FILE_OPT:-${tmp_root}/captured-timeouts.txt}"
  : > "$capture_file"
  export CAPTURE_FILE="$capture_file"

  # common.sh source (jq_safe / filter_l3_tests / log / record_task_event 等を取り込む)
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.forge/lib/common.sh"

  # task_run_l3_test 抽出 + source
  local extract_file
  extract_file=$(mktemp)
  if ! extract_function_v2 "task_run_l3_test" "$RALPH_LOOP_SH" > "$extract_file" || [ ! -s "$extract_file" ]; then
    echo -e "  ${RED}✗${NC} task_run_l3_test() 抽出失敗"
    rm -f "$extract_file"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  # shellcheck disable=SC1090
  source "$extract_file"
  rm -f "$extract_file"
  echo -e "  ${GREEN}✓${NC} task_run_l3_test() 抽出 + source 完了"

  # Mock 関数群
  execute_l3_test() {
    local _l3_test="$1"
    local _work_dir="$2"
    local timeout="$3"
    printf 'timeout_sec=%s\n' "$timeout" >> "$CAPTURE_FILE"
    return 0
  }
  handle_task_fail() { return 0; }
  log() { :; }
  record_task_event() { :; }

  # ── Case 1: 単一 layer_3 / timeout_sec=600 (number) → 600 が伝播する
  # behavior: layer_3[].timeout_sec=600 を持つ task fixture で task_run_l3_test() を呼び出し → execute_l3_test の timeout 引数に 600 が渡る（修正後の動的読み取り）
  local case_json
  case_json='{"task_id":"t1","validation":{"layer_3":[{"id":"L3-1","strategy":"structural","description":"d","definition":{"command":"echo OK"},"requires":[],"blocking":true,"timeout_sec":600}]}}'
  _RT_TASK_JSON="$case_json"
  task_run_l3_test "t1" "$task_dir" >/dev/null 2>&1 || true
  local cap1
  cap1=$(tail -1 "$CAPTURE_FILE" | tr -d '\r')
  assert_eq "case#1 単一 layer_3.timeout_sec=600 → 600" "timeout_sec=600" "$cap1"

  # ── Case 2: 単一 layer_3 / timeout_sec 未指定 → L3_DEFAULT_TIMEOUT=120 にフォールバック
  # behavior: layer_3[].timeout_sec が未指定の task fixture → execute_l3_test の timeout 引数に L3_DEFAULT_TIMEOUT=120 が渡る（フォールバック）
  case_json='{"task_id":"t2","validation":{"layer_3":[{"id":"L3-2","strategy":"structural","description":"d","definition":{"command":"echo OK"},"requires":[],"blocking":true}]}}'
  _RT_TASK_JSON="$case_json"
  task_run_l3_test "t2" "$task_dir" >/dev/null 2>&1 || true
  local cap2
  cap2=$(tail -1 "$CAPTURE_FILE" | tr -d '\r')
  assert_eq "case#2 timeout_sec 未指定 → 120 (jq // フォールバック)" "timeout_sec=120" "$cap2"

  # ── Case 3: 複数エントリ (3件) [60, 300, 1800] → ループ内で各 entry 個別の timeout
  # behavior: 複数の layer_3 エントリ（3件、それぞれ timeout_sec=60/300/1800）を持つ task fixture → ループ内で各エントリ個別の timeout が反映される（連続呼出での独立性）
  case_json='{"task_id":"t3","validation":{"layer_3":[
    {"id":"L3-3a","strategy":"structural","description":"d","definition":{"command":"echo OK"},"requires":[],"blocking":true,"timeout_sec":60},
    {"id":"L3-3b","strategy":"structural","description":"d","definition":{"command":"echo OK"},"requires":[],"blocking":true,"timeout_sec":300},
    {"id":"L3-3c","strategy":"structural","description":"d","definition":{"command":"echo OK"},"requires":[],"blocking":true,"timeout_sec":1800}
  ]}}'
  _RT_TASK_JSON="$case_json"
  task_run_l3_test "t3" "$task_dir" >/dev/null 2>&1 || true

  # 3エントリ分のキャプチャを末尾3行から抽出
  local cap3a cap3b cap3c
  cap3a=$(tail -3 "$CAPTURE_FILE" | head -1 | tr -d '\r')
  cap3b=$(tail -2 "$CAPTURE_FILE" | head -1 | tr -d '\r')
  cap3c=$(tail -1 "$CAPTURE_FILE" | tr -d '\r')
  assert_eq "case#3a multi-entry [0]=60 → 60" "timeout_sec=60" "$cap3a"
  assert_eq "case#3b multi-entry [1]=300 → 300" "timeout_sec=300" "$cap3b"
  assert_eq "case#3c multi-entry [2]=1800 → 1800" "timeout_sec=1800" "$cap3c"

  # 累計キャプチャ数の検証 (1 + 1 + 3 = 5)
  local total_caps
  total_caps=$(grep -c '^timeout_sec=' "$CAPTURE_FILE" 2>/dev/null || echo 0)
  assert_eq "L3 dynamic 累計キャプチャ数 == 5" "5" "$total_caps"

  rm -rf "$tmp_root" 2>/dev/null || true
}

# ========================================================================
# --validate-defense: 整数バリデーション防御コードのキャプチャ検証
# L1/L3 両方で string 型・空文字列・型違いがフォールバックされることを検証
# ========================================================================
run_validate_defense() {
  echo -e "${BOLD}===== --validate-defense: L1/L3 整数バリデーション防御 =====${NC}"

  local tmp_root
  tmp_root=$(mktemp -d -t test-timeout-sec-def-XXXXXX 2>/dev/null || mktemp -d)
  export PROJECT_ROOT="$tmp_root"
  export WORK_DIR="$tmp_root"
  export ERRORS_FILE="${tmp_root}/errors.jsonl"
  touch "$ERRORS_FILE"
  export json_fail_count=0
  export L1_DEFAULT_TIMEOUT=200
  export L3_ENABLED=true
  export L3_DEFAULT_TIMEOUT=120
  export RESEARCH_CONFIG=""
  local task_dir="${tmp_root}/task-dir"
  mkdir -p "$task_dir"

  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.forge/lib/common.sh"

  # task_run_l1_test / task_run_l3_test を抽出 + source
  local extract_file
  extract_file=$(mktemp)
  for fn in task_run_l1_test task_run_l3_test; do
    if ! extract_function_v2 "$fn" "$RALPH_LOOP_SH" > "$extract_file" || [ ! -s "$extract_file" ]; then
      echo -e "  ${RED}✗${NC} $fn 抽出失敗"
      rm -f "$extract_file"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      return 1
    fi
    # shellcheck disable=SC1090
    source "$extract_file"
  done
  rm -f "$extract_file"
  echo -e "  ${GREEN}✓${NC} task_run_l1_test() / task_run_l3_test() 抽出 + source 完了"

  # 共通 capture file (上書き型)
  CAPTURE_FILE="${tmp_root}/captured-defense.txt"
  : > "$CAPTURE_FILE"

  # Mocks
  execute_layer1_test() {
    local _cmd="$1"
    local timeout="$2"
    printf 'L1=%s\n' "$timeout" > "$CAPTURE_FILE"
    return 0
  }
  execute_l3_test() {
    local _l3_test="$1"
    local _work_dir="$2"
    local timeout="$3"
    printf 'L3=%s\n' "$timeout" > "$CAPTURE_FILE"
    return 0
  }
  handle_task_fail() { return 0; }
  log() { :; }
  record_task_event() { :; }

  read_l1() { cat "$CAPTURE_FILE" 2>/dev/null | sed -n 's/^L1=//p' | tr -d '\r'; }
  read_l3() { cat "$CAPTURE_FILE" 2>/dev/null | sed -n 's/^L3=//p' | tr -d '\r'; }

  local case_json

  # ── L1 防御テスト ──

  # behavior: layer_1.timeout_sec="300"（文字列型）の task fixture → 整数バリデーションで 200 にフォールバック（型違い対応）
  case_json='{"task_id":"d1","validation":{"layer_1":{"command":"echo OK","expect":"ok","timeout_sec":"300"}}}'
  _RT_TASK_JSON="$case_json"
  : > "$CAPTURE_FILE"
  task_run_l1_test "d1" "$task_dir" >/dev/null 2>&1 || true
  assert_eq "L1 文字列\"300\" → 200 (型違い防御)" "200" "$(read_l1)"

  # behavior: layer_1.timeout_sec=""（空文字列）の task fixture → 整数バリデーションで 200 にフォールバック（空文字列防御）
  case_json='{"task_id":"d2","validation":{"layer_1":{"command":"echo OK","expect":"ok","timeout_sec":""}}}'
  _RT_TASK_JSON="$case_json"
  : > "$CAPTURE_FILE"
  task_run_l1_test "d2" "$task_dir" >/dev/null 2>&1 || true
  assert_eq "L1 空文字列\"\" → 200 (空文字列防御)" "200" "$(read_l1)"

  # behavior: layer_1.timeout_sec=null の task fixture → jq // フォールバックで 200
  case_json='{"task_id":"d3","validation":{"layer_1":{"command":"echo OK","expect":"ok","timeout_sec":null}}}'
  _RT_TASK_JSON="$case_json"
  : > "$CAPTURE_FILE"
  task_run_l1_test "d3" "$task_dir" >/dev/null 2>&1 || true
  assert_eq "L1 null → 200 (jq // 演算子フォールバック)" "200" "$(read_l1)"

  # ── L3 防御テスト ──

  # behavior: layer_3[].timeout_sec="600"（文字列型）の task fixture → 整数バリデーションで 120 にフォールバック（型違い対応）
  case_json='{"task_id":"d4","validation":{"layer_3":[{"id":"L3-d4","strategy":"structural","description":"d","definition":{"command":"echo OK"},"requires":[],"blocking":true,"timeout_sec":"600"}]}}'
  _RT_TASK_JSON="$case_json"
  : > "$CAPTURE_FILE"
  task_run_l3_test "d4" "$task_dir" >/dev/null 2>&1 || true
  assert_eq "L3 文字列\"600\" → 120 (型違い防御)" "120" "$(read_l3)"

  # behavior: layer_3[].timeout_sec=""（空文字列）の task fixture → 整数バリデーションで 120 にフォールバック
  case_json='{"task_id":"d5","validation":{"layer_3":[{"id":"L3-d5","strategy":"structural","description":"d","definition":{"command":"echo OK"},"requires":[],"blocking":true,"timeout_sec":""}]}}'
  _RT_TASK_JSON="$case_json"
  : > "$CAPTURE_FILE"
  task_run_l3_test "d5" "$task_dir" >/dev/null 2>&1 || true
  assert_eq "L3 空文字列\"\" → 120 (空文字列防御)" "120" "$(read_l3)"

  # behavior: layer_3[].timeout_sec=null の task fixture → jq // フォールバックで 120
  case_json='{"task_id":"d6","validation":{"layer_3":[{"id":"L3-d6","strategy":"structural","description":"d","definition":{"command":"echo OK"},"requires":[],"blocking":true,"timeout_sec":null}]}}'
  _RT_TASK_JSON="$case_json"
  : > "$CAPTURE_FILE"
  task_run_l3_test "d6" "$task_dir" >/dev/null 2>&1 || true
  assert_eq "L3 null → 120 (jq // 演算子フォールバック)" "120" "$(read_l3)"

  # ── ralph-loop.sh ソース上のバリデーション語彙 静的検査 ──
  # behavior: ralph-loop.sh task_run_l1_test() 周辺（L992 付近）に整数バリデーション正規表現が存在 → grep -nE '\[\[ "\$timeout_sec" =~' ralph-loop.sh で L992-L1010 範囲に 1 件以上 hit
  local l1_validation_hits
  l1_validation_hits=$(awk 'NR>=985 && NR<=1010 && /\[\[ "\$timeout_sec" =~/ {c++} END{print c+0}' "$RALPH_LOOP_SH")
  if [ "$l1_validation_hits" -ge 1 ]; then
    echo -e "  ${GREEN}✓${NC} L1 整数バリデーション正規表現 (L985-1010): ${l1_validation_hits} hit"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} L1 整数バリデーション正規表現 (L985-1010): 0 hit"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # behavior: ralph-loop.sh task_run_l3_test() 周辺（L1064 付近）に整数バリデーション正規表現が存在
  local l3_validation_hits
  l3_validation_hits=$(awk 'NR>=1060 && NR<=1085 && /\[\[ "\$timeout_sec" =~/ {c++} END{print c+0}' "$RALPH_LOOP_SH")
  if [ "$l3_validation_hits" -ge 1 ]; then
    echo -e "  ${GREEN}✓${NC} L3 整数バリデーション正規表現 (L1060-1085): ${l3_validation_hits} hit"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} L3 整数バリデーション正規表現 (L1060-1085): 0 hit"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # behavior: バリデーション失敗時の警告ログ（'invalid timeout_sec' 等）が echo される設計
  local invalid_timeout_hits
  invalid_timeout_hits=$(grep -c 'invalid timeout' "$RALPH_LOOP_SH" 2>/dev/null || echo 0)
  if [ "$invalid_timeout_hits" -ge 1 ]; then
    echo -e "  ${GREEN}✓${NC} 'invalid timeout' 警告ログ: ${invalid_timeout_hits} hit"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} 'invalid timeout' 警告ログ: 0 hit"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # behavior: フォールバック値 L1=200 / L3=120 が変数 L1_DEFAULT_TIMEOUT / L3_DEFAULT_TIMEOUT で各 2 件以上
  local l1_var_hits l3_var_hits
  l1_var_hits=$(grep -c 'L1_DEFAULT_TIMEOUT' "$RALPH_LOOP_SH" 2>/dev/null || echo 0)
  l3_var_hits=$(grep -c 'L3_DEFAULT_TIMEOUT' "$RALPH_LOOP_SH" 2>/dev/null || echo 0)
  if [ "$l1_var_hits" -ge 2 ]; then
    echo -e "  ${GREEN}✓${NC} L1_DEFAULT_TIMEOUT 出現数: ${l1_var_hits} (>=2)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} L1_DEFAULT_TIMEOUT 出現数: ${l1_var_hits} (<2)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  if [ "$l3_var_hits" -ge 2 ]; then
    echo -e "  ${GREEN}✓${NC} L3_DEFAULT_TIMEOUT 出現数: ${l3_var_hits} (>=2)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} L3_DEFAULT_TIMEOUT 出現数: ${l3_var_hits} (<2)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # behavior: jq_safe ベースの動的 timeout_sec 読み取りが L3 (L1064 周辺) に存在
  local jq_safe_l3_hits
  jq_safe_l3_hits=$(awk 'NR>=1060 && NR<=1085 && /jq_safe.*timeout_sec/ {c++} END{print c+0}' "$RALPH_LOOP_SH")
  if [ "$jq_safe_l3_hits" -ge 1 ]; then
    echo -e "  ${GREEN}✓${NC} jq_safe.*timeout_sec (L1060-1085): ${jq_safe_l3_hits} hit"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}✗${NC} jq_safe.*timeout_sec (L1060-1085): 0 hit"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # behavior: Windows CRLF 混入なし → file ralph-loop.sh で 'CRLF' 不検出
  if command -v file >/dev/null 2>&1; then
    local file_info
    file_info=$(file "$RALPH_LOOP_SH" 2>/dev/null || echo "")
    if echo "$file_info" | grep -q 'CRLF'; then
      echo -e "  ${RED}✗${NC} ralph-loop.sh に CRLF 混入: ${file_info}"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    else
      echo -e "  ${GREEN}✓${NC} ralph-loop.sh CRLF 不検出"
      PASS_COUNT=$((PASS_COUNT + 1))
    fi
  fi

  rm -rf "$tmp_root" 2>/dev/null || true
}

# ========================================================================
# Mode dispatch
# ========================================================================
case "$MODE" in
  --schema-only) run_schema_only ;;
  --l1-readonly) run_l1_readonly ;;
  --l3-dynamic) run_l3_dynamic ;;
  --validate-defense) run_validate_defense ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Usage: $0 --schema-only|--l1-readonly|--l3-dynamic [--capture <file>]|--validate-defense" >&2
    exit 2
    ;;
esac

print_test_summary
