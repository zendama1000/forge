#!/bin/bash
# validation-dsl.sh — 型付き検証 DSL「validation v2」インタープリタ（2026-07 batch#8 Stage3）
#
# 背景: L1/L2/L3 の検証は LLM が書く自由形式シェル文字列で、nested bash -c /
# クォート / CRLF / literal glob という再発バグ群の発生源だった。v2 は検証を
# 小さな型付き check（.validation.checks[]）にし、ハーネスが解釈実行する。
#
# 設計原則:
#   - checks は .validation の内側（fix タスクが .validation を丸ごとコピーする
#     ため自動継承される — phase3.sh create_l2_fix_task/create_l3_fix_task 参照）
#   - layer N に check が1件でもあれば v2 が権威、同 layer の legacy command は無視
#   - 可能な限り argv 配列で実行（シェル文字列の再パースをしない）
#   - raw_shell は脱出ハッチ: 実行毎に weak_validation 債務を記録して可視化
#   - rc 規約: 0=pass / 1=fail / 2=config error（呼出側は 2 も fail 扱い）
#   - requires 語彙は既存の requires_entry_satisfiable（common.sh）を再利用
#
# 依存（common.sh 等、無い環境向けに type ガード）: jq_safe, log,
#   requires_entry_satisfiable, record_quality_debt, execute_l3_agent_flow
#
# verb 一覧: file_exists / grep_ref / run_test / http_check / effect_smoke /
#            agent_flow / raw_shell

type log &>/dev/null || log() { echo "$@" >&2; }

# ===== 実行プリミティブ =====
# run_workdir_cmd <timeout_sec> <work_dir> <argv...>
# argv をシェル再解釈なしで実行（bash -c を使わない = クォートバグのクラス消滅）。
# rc は素通し（124=timeout 維持）。将来、L2/L3 の重複 bash -c サイトの共有 executor。
run_workdir_cmd() {
  local _rw_timeout="$1" _rw_wd="$2"
  shift 2
  ( cd "$_rw_wd" && timeout "$_rw_timeout" env PATH="${_rw_wd}/node_modules/.bin:$PATH" "$@" ) 2>&1
}

# run_workdir_shell <timeout_sec> <work_dir> <command_string>
# legacy 意味論（単一ラップ）の一元化。raw_shell と legacy 実行サイトが使う。
run_workdir_shell() {
  local _rw_timeout="$1" _rw_wd="$2" _rw_cmd="$3"
  timeout "$_rw_timeout" env PATH="${_rw_wd}/node_modules/.bin:$PATH" bash -c "cd '$_rw_wd' && $_rw_cmd" 2>&1
}

# ===== セレクタ（純関数） =====
# v2_checks_for_layer <task_json> <layer> → stdout: compact JSON 配列（無ければ []）
v2_checks_for_layer() {
  echo "$1" | jq -c --argjson layer "$2" \
    '[.validation.checks[]? | select(.layer == $layer)]' 2>/dev/null || echo "[]"
}

# task_layer_is_v2 <task_json> <layer> → rc 0 = その layer に v2 check が存在（= v2 が権威）
task_layer_is_v2() {
  local n
  n=$(echo "$1" | jq -r --argjson layer "$2" \
    '[.validation.checks[]? | select(.layer == $layer)] | length' 2>/dev/null)
  case "$n" in (''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ]
}

# v2_layer_fingerprint <validation_json> <layer>
# fix タスク dedup 用の正準表現（compact JSON 配列）。空 layer は "[]"。
# 比較側は jq --argjson の構造等価（キー順非依存）で行うこと。
v2_layer_fingerprint() {
  echo "$1" | jq -c --argjson layer "$2" \
    '[.checks[]? | select(.layer == $layer)]' 2>/dev/null || echo "[]"
}

# render_checks_summary <task_json> <layer> → 人間可読 1 行/件（implementer プロンプト等）
render_checks_summary() {
  echo "$1" | jq -r --argjson layer "$2" '
    .validation.checks[]? | select(.layer == $layer) |
    "- [\(.verb)] " + (
      if .verb == "file_exists" then ((.paths // []) | join(", "))
      elif .verb == "grep_ref" then "\(.pattern // "") in \((.paths // []) | join(", "))"
      elif .verb == "run_test" then "\(.runner // "") \((.args // []) | join(" "))"
      elif .verb == "http_check" then "\(.method // "GET") \(.url // .url_path // "") => \(.expect_status // 200)"
      elif .verb == "effect_smoke" then ((.argv // []) | join(" "))
      elif .verb == "raw_shell" then (.shell // "")
      elif .verb == "agent_flow" then "agent flow (\((.definition.steps // []) | length) steps)"
      else "" end)' 2>/dev/null
}

# v2_primary_test_command <task_json>
# mutation-audit 用: 最初の layer-1 run_test を実行可能なコマンドライン文字列で返す（無ければ空）
v2_primary_test_command() {
  echo "$1" | jq -r '
    [.validation.checks[]? | select(.layer == 1 and .verb == "run_test")][0] // empty |
    ({vitest: "npx vitest run", jest: "npx jest", pytest: "python -m pytest",
      playwright: "npx playwright test", "node-test": "node --test",
      "go-test": "go test", "cargo-test": "cargo test",
      tsc: "npx tsc --noEmit", eslint: "npx eslint", biome: "npx biome check"}
     [.runner] // empty) as $base |
    select($base != "") |
    # args[0] が base の末尾トークンと同じ（例: vitest の "run"）なら落とす — Planner/Implementer が
    # 「npx vitest run」を知っていて args にも run を書く二重化（batch#11 R13、4.5f で実測）
    ($base | split(" ") | last) as $last |
    ((.args // []) | if length > 0 and .[0] == $last then .[1:] else . end) as $args |
    $base + (if ($args | length) > 0 then " " + ($args | join(" ")) else "" end)
  ' 2>/dev/null
}

# checks_require_server <task_json> <layer> → rc 0 = 非 deferred check に server 要求あり
# （http_check は暗黙 requires:server）
checks_require_server() {
  local n
  n=$(echo "$1" | jq -r --argjson layer "$2" '
    [.validation.checks[]? | select(.layer == $layer and (.deferred != true))
     | select(.verb == "http_check" or (((.requires // []) | index("server")) != null))] | length' 2>/dev/null)
  case "$n" in (''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ]
}

# ===== verb 実装 =====
# 共通契約: stdout に PASS:/FAIL:/CONFIG: 行、rc 0/1/2

_v2_path_guard() {
  # 相対・非グロブのみ許容（validate 側ゲートと同じ規則の実行時防御）
  case "$1" in
    /*)        echo "CONFIG: 絶対パスは禁止: $1"; return 2 ;;
    *..*)      echo "CONFIG: .. を含むパスは禁止: $1"; return 2 ;;
    *[\*\?\[]*) echo "CONFIG: グロブは使用不可: $1"; return 2 ;;
  esac
  return 0
}

_check_file_exists() {
  local check_json="$1" work_dir="$2"
  local count i=0 p missing="" guard_out
  count=$(echo "$check_json" | jq -r '.paths // [] | length' 2>/dev/null)
  case "$count" in (''|*[!0-9]*) count=0 ;; esac
  [ "$count" -gt 0 ] || { echo "CONFIG: file_exists に paths がない"; return 2; }
  while [ "$i" -lt "$count" ]; do
    p=$(echo "$check_json" | jq -r ".paths[$i]")
    if ! guard_out=$(_v2_path_guard "$p"); then echo "$guard_out"; return 2; fi
    if [ "${p%/}" != "$p" ]; then
      [ -d "${work_dir}/${p%/}" ] || missing="$missing $p"
    else
      [ -f "${work_dir}/${p}" ] || missing="$missing $p"
    fi
    i=$((i + 1))
  done
  if [ -n "$missing" ]; then
    echo "FAIL: 不在:${missing}"
    return 1
  fi
  echo "PASS: ${count} path(s) exist"
  return 0
}

_check_grep_ref() {
  local check_json="$1" work_dir="$2"
  local pattern expect_absent count i=0 p found=0 guard_out
  pattern=$(echo "$check_json" | jq -r '.pattern // ""')
  [ -n "$pattern" ] || { echo "CONFIG: grep_ref に pattern がない"; return 2; }
  expect_absent=$(echo "$check_json" | jq -r '.expect_absent // false')
  count=$(echo "$check_json" | jq -r '.paths // [] | length' 2>/dev/null)
  case "$count" in (''|*[!0-9]*) count=0 ;; esac
  [ "$count" -gt 0 ] || { echo "CONFIG: grep_ref に paths がない"; return 2; }
  while [ "$i" -lt "$count" ]; do
    p=$(echo "$check_json" | jq -r ".paths[$i]")
    if ! guard_out=$(_v2_path_guard "$p"); then echo "$guard_out"; return 2; fi
    if [ -d "${work_dir}/${p%/}" ]; then
      grep -rEq -- "$pattern" "${work_dir}/${p%/}" 2>/dev/null && found=1
    elif [ -f "${work_dir}/${p}" ]; then
      grep -Eq -- "$pattern" "${work_dir}/${p}" 2>/dev/null && found=1
    else
      echo "FAIL: paths に不在: $p"
      return 1
    fi
    i=$((i + 1))
  done
  if [ "$expect_absent" = "true" ]; then
    if [ "$found" -eq 1 ]; then
      echo "FAIL: pattern '${pattern}' が存在する（expect_absent=true）"
      return 1
    fi
    echo "PASS: '${pattern}' 不在を確認"
    return 0
  fi
  if [ "$found" -eq 1 ]; then
    echo "PASS: '${pattern}' found"
    return 0
  fi
  echo "FAIL: pattern '${pattern}' が見つからない"
  return 1
}

_check_run_test() {
  local check_json="$1" work_dir="$2" timeout_sec="$3"
  local runner
  runner=$(echo "$check_json" | jq -r '.runner // ""')
  local -a cmd_argv=()
  case "$runner" in
    vitest)     cmd_argv=(npx vitest run) ;;
    jest)       cmd_argv=(npx jest) ;;
    pytest)     cmd_argv=(python -m pytest) ;;
    playwright) cmd_argv=(npx playwright test) ;;
    node-test)  cmd_argv=(node --test) ;;
    go-test)    cmd_argv=(go test) ;;
    cargo-test) cmd_argv=(cargo test) ;;
    tsc)        cmd_argv=(npx tsc --noEmit) ;;
    eslint)     cmd_argv=(npx eslint) ;;
    biome)      cmd_argv=(npx biome check) ;;
    *) echo "CONFIG: 未知の runner '${runner}'"; return 2 ;;
  esac
  local count i=0 a
  count=$(echo "$check_json" | jq -r '.args // [] | length' 2>/dev/null)
  case "$count" in (''|*[!0-9]*) count=0 ;; esac
  while [ "$i" -lt "$count" ]; do
    a=$(echo "$check_json" | jq -r ".args[$i]")
    # args[0] が base の末尾トークン（vitest の "run" 等）と同じなら二重化なので落とす（batch#11 R13）
    if [ "$i" -eq 0 ] && [ "$a" = "${cmd_argv[${#cmd_argv[@]}-1]}" ]; then
      i=$((i + 1)); continue
    fi
    cmd_argv+=("$a")
    i=$((i + 1))
  done
  local out rc=0
  out=$(run_workdir_cmd "$timeout_sec" "$work_dir" "${cmd_argv[@]}") || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS: ${runner}"
    return 0
  fi
  printf 'FAIL: %s (exit=%d%s)\n%s\n' "$runner" "$rc" "$([ "$rc" -eq 124 ] && echo ' timeout')" "$out"
  return 1
}

_check_http_check() {
  local check_json="$1" work_dir="$2" timeout_sec="$3"
  local url method expect_status body body_jq
  url=$(echo "$check_json" | jq -r '.url // ""')
  if [ -z "$url" ]; then
    local url_path base=""
    url_path=$(echo "$check_json" | jq -r '.url_path // ""')
    [ -n "$url_path" ] || { echo "CONFIG: http_check に url / url_path がない"; return 2; }
    if [ -n "${DEV_CONFIG:-}" ] && [ -f "${DEV_CONFIG}" ]; then
      base=$(jq -r '.server.base_url // empty' "$DEV_CONFIG" 2>/dev/null)
      if [ -z "$base" ]; then
        base=$(jq -r '.server.health_check_url // empty' "$DEV_CONFIG" 2>/dev/null \
          | sed -E 's|^(https?://[^/]+).*|\1|')
      fi
    fi
    [ -n "$base" ] || { echo "CONFIG: base URL を導出できない（server.base_url / health_check_url 未設定）"; return 2; }
    url="${base%/}/${url_path#/}"
  fi
  method=$(echo "$check_json" | jq -r '.method // "GET"')
  expect_status=$(echo "$check_json" | jq -r '.expect_status // 200')
  body=$(echo "$check_json" | jq -r '.body // ""')
  body_jq=$(echo "$check_json" | jq -r '.body_jq // ""')

  local body_tmp status rc=0
  body_tmp=$(mktemp)
  if [ -n "$body" ]; then
    status=$(curl -s -X "$method" --max-time "$timeout_sec" -o "$body_tmp" -w '%{http_code}' \
      -H 'Content-Type: application/json' -d "$body" "$url" 2>/dev/null)
  else
    status=$(curl -s -X "$method" --max-time "$timeout_sec" -o "$body_tmp" -w '%{http_code}' "$url" 2>/dev/null)
  fi
  if [ "$status" != "$expect_status" ]; then
    echo "FAIL: HTTP ${status:-000} (expect ${expect_status}) — ${method} ${url}"
    rc=1
  elif [ -n "$body_jq" ] && ! jq -e "$body_jq" "$body_tmp" >/dev/null 2>&1; then
    echo "FAIL: body_jq '${body_jq}' 不成立 — ${method} ${url}"
    rc=1
  else
    echo "PASS: HTTP ${status} ${method} ${url}"
  fi
  rm -f "$body_tmp" 2>/dev/null
  return "$rc"
}

_check_effect_smoke() {
  local check_json="$1" work_dir="$2" timeout_sec="$3"
  local count i=0 a
  count=$(echo "$check_json" | jq -r '.argv // [] | length' 2>/dev/null)
  case "$count" in (''|*[!0-9]*) count=0 ;; esac
  [ "$count" -gt 0 ] || { echo "CONFIG: effect_smoke に argv がない"; return 2; }
  local -a cmd_argv=()
  while [ "$i" -lt "$count" ]; do
    a=$(echo "$check_json" | jq -r ".argv[$i]")
    cmd_argv+=("$a")
    i=$((i + 1))
  done
  local expect_exit stdout_contains
  expect_exit=$(echo "$check_json" | jq -r '.expect.exit_code // 0')
  stdout_contains=$(echo "$check_json" | jq -r '.expect.stdout_contains // ""')

  local out rc=0
  out=$(run_workdir_cmd "$timeout_sec" "$work_dir" "${cmd_argv[@]}") || rc=$?
  if [ "$rc" != "$expect_exit" ]; then
    printf 'FAIL: exit=%s (expect %s)\n%s\n' "$rc" "$expect_exit" "$out"
    return 1
  fi
  if [ -n "$stdout_contains" ] && ! printf '%s' "$out" | grep -qF -- "$stdout_contains"; then
    printf 'FAIL: stdout に "%s" が含まれない\n%s\n' "$stdout_contains" "$out"
    return 1
  fi
  local cf_count j=0 f
  cf_count=$(echo "$check_json" | jq -r '.expect.creates_files // [] | length' 2>/dev/null)
  case "$cf_count" in (''|*[!0-9]*) cf_count=0 ;; esac
  while [ "$j" -lt "$cf_count" ]; do
    f=$(echo "$check_json" | jq -r ".expect.creates_files[$j]")
    if [ ! -e "${work_dir}/${f}" ]; then
      echo "FAIL: 期待される生成物が存在しない: $f"
      return 1
    fi
    j=$((j + 1))
  done
  echo "PASS: effect_smoke (exit=${rc})"
  return 0
}

_check_agent_flow() {
  local check_json="$1" work_dir="$2" timeout_sec="$3"
  type execute_l3_agent_flow &>/dev/null || { echo "CONFIG: execute_l3_agent_flow が利用不可"; return 2; }
  local synth
  synth=$(echo "$check_json" | jq -c \
    '{id: (.id // "v2-agent-flow"), strategy: "agent_flow",
      definition: (.definition // {}), timeout_sec: .timeout_sec}' 2>/dev/null)
  [ -n "$synth" ] || { echo "CONFIG: agent_flow definition の合成に失敗"; return 2; }
  # 既存 L3 agent_flow 実装へ委譲（rc 素通し。2 は CONFIG 扱いで呼出側が fail 化）
  execute_l3_agent_flow "$synth" "$work_dir" "$timeout_sec"
}

_check_raw_shell() {
  local check_json="$1" work_dir="$2" timeout_sec="$3"
  local shell_cmd reason check_id
  shell_cmd=$(echo "$check_json" | jq -r '.shell // ""')
  [ -n "$shell_cmd" ] || { echo "CONFIG: raw_shell に shell がない"; return 2; }
  reason=$(echo "$check_json" | jq -r '.reason // ""')
  check_id=$(echo "$check_json" | jq -r '.id // "raw"')

  # 脱出ハッチの使用は weak_validation 債務として可視化（同一 task+check は一度だけ）
  if type record_quality_debt &>/dev/null; then
    local _rs_marker="raw_shell:${_V2_TASK_ID:-?}:${check_id}"
    local _rs_ledger="${QUALITY_LEDGER_FILE:-${PROJECT_ROOT:-.}/.forge/state/quality-debts.jsonl}"
    if ! grep -qF "$_rs_marker" "$_rs_ledger" 2>/dev/null; then
      record_quality_debt "weak_validation" "${_V2_TASK_ID:-}" \
        "${_rs_marker} — 型付き verb で表現できない理由: ${reason:-未記載}" \
        "$(jq -n -c --arg s "$shell_cmd" '{shell: $s}')"
    fi
  fi

  local out rc=0
  out=$(run_workdir_shell "$timeout_sec" "$work_dir" "$shell_cmd") || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS: raw_shell"
    return 0
  fi
  printf 'FAIL: raw_shell (exit=%d)\n%s\n' "$rc" "$out"
  return 1
}

# ===== ディスパッチ =====
# execute_check <check_json> <work_dir> [default_timeout_sec]
execute_check() {
  local check_json="$1" work_dir="$2" default_timeout="${3:-120}"
  local verb timeout_sec
  verb=$(echo "$check_json" | jq -r '.verb // ""' 2>/dev/null)
  timeout_sec=$(echo "$check_json" | jq -r '.timeout_sec // empty' 2>/dev/null)
  case "$timeout_sec" in (''|*[!0-9]*) timeout_sec="$default_timeout" ;; esac
  case "$verb" in
    file_exists)  _check_file_exists "$check_json" "$work_dir" ;;
    grep_ref)     _check_grep_ref "$check_json" "$work_dir" ;;
    run_test)     _check_run_test "$check_json" "$work_dir" "$timeout_sec" ;;
    http_check)   _check_http_check "$check_json" "$work_dir" "$timeout_sec" ;;
    effect_smoke) _check_effect_smoke "$check_json" "$work_dir" "$timeout_sec" ;;
    agent_flow)   _check_agent_flow "$check_json" "$work_dir" "$timeout_sec" ;;
    raw_shell)    _check_raw_shell "$check_json" "$work_dir" "$timeout_sec" ;;
    *) echo "CONFIG: 未知の verb '${verb}'"; return 2 ;;
  esac
}

# ===== レイヤー実行オーケストレータ =====
# run_layer_checks <task_json> <layer> <work_dir> [default_timeout] [task_id]
# rc: 0 = 実行された check に fail なし / 1 = 1件以上 fail（CONFIG 含む）
# deferred → deferred_test 債務、L2 の requires 不充足 → SKIP + l2_skip 債務。
# L1 は defer 経路がないため requires 不充足も FAIL（生成ゲートが本来禁止する）。
run_layer_checks() {
  local task_json="$1" layer="$2" work_dir="$3" default_timeout="${4:-120}" task_id="${5:-}"
  local checks count i=0 fails=0 executed=0 deferred=0
  checks=$(v2_checks_for_layer "$task_json" "$layer")
  count=$(echo "$checks" | jq 'length' 2>/dev/null)
  case "$count" in (''|*[!0-9]*) count=0 ;; esac
  _V2_TASK_ID="$task_id"

  while [ "$i" -lt "$count" ]; do
    local check check_id verb
    check=$(echo "$checks" | jq -c ".[$i]")
    check_id=$(echo "$check" | jq -r --argjson i "$i" '.id // ("chk" + ($i | tostring))')
    verb=$(echo "$check" | jq -r '.verb // "?"')
    echo "── check ${check_id} [${verb}] ──"

    # deferred: 実行しないが台帳に必ず残す（黙って劣化しない）
    if [ "$(echo "$check" | jq -r '.deferred // false')" = "true" ]; then
      local dreason
      dreason=$(echo "$check" | jq -r '.deferred_reason // "未記載"')
      echo "DEFER ${check_id}: ${dreason}"
      deferred=$((deferred + 1))
      if type record_quality_debt &>/dev/null; then
        record_quality_debt "deferred_test" "$task_id" \
          "v2 check ${check_id} (${verb}) 繰延: ${dreason}" \
          "$(jq -n -c --arg t "$check_id" '{test_id: $t}')"
      fi
      i=$((i + 1))
      continue
    fi

    # requires 充足（既存 requires_entry_satisfiable を再利用）
    local req_unmet=""
    if type requires_entry_satisfiable &>/dev/null; then
      local reqs_count k=0 req
      reqs_count=$(echo "$check" | jq -r '.requires // [] | length' 2>/dev/null)
      case "$reqs_count" in (''|*[!0-9]*) reqs_count=0 ;; esac
      while [ "$k" -lt "$reqs_count" ]; do
        req=$(echo "$check" | jq -r ".requires[$k]")
        if ! requires_entry_satisfiable "$req"; then
          req_unmet="$req"
          break
        fi
        k=$((k + 1))
      done
    fi
    if [ -n "$req_unmet" ]; then
      if [ "$layer" -eq 1 ]; then
        echo "FAIL ${check_id}: requires '${req_unmet}' 充足不能（L1 に defer 経路なし）"
        fails=$((fails + 1))
      else
        echo "SKIP ${check_id}: requires '${req_unmet}' 充足不能"
        if type record_quality_debt &>/dev/null; then
          record_quality_debt "l2_skip" "$task_id" \
            "v2 check ${check_id} skip: requires ${req_unmet}" \
            "$(jq -n -c --arg t "$check_id" '{test_id: $t}')"
        fi
      fi
      i=$((i + 1))
      continue
    fi

    # 実行
    local out rc=0
    out=$(execute_check "$check" "$work_dir" "$default_timeout") || rc=$?
    executed=$((executed + 1))
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
      fails=$((fails + 1))
    fi
    i=$((i + 1))
  done

  echo "── v2 layer${layer}: executed=${executed} fails=${fails} deferred=${deferred} total=${count} ──"
  [ "$fails" -eq 0 ]
}
