#!/bin/bash
# validation-gates.sh — validation 構造ゲートの共有ライブラリ（batch#10 Stage4）
#
# 由来: generate-tasks.sh に内蔵されていた純 jq ゲート3本を、
# 「Planner 降格 + validation 執筆の Implementer 移管」に伴い切り出した。
#   - 生成時（generate-tasks.sh）: Planner は validation を書かないため、
#     VG_REQUIRE_L1=0 で構造検査のみ（L1 必須は課さない）
#   - 執筆後（ralph-loop.sh task_author_validation）: 単一タスクを {"tasks":[...]} に
#     ラップして同じ関数群を VG_REQUIRE_L1=1 で再利用する
#
# 前提: common.sh が先に source 済み（jq_safe / log を使用）。
# 全関数は LLM を呼ばない（純 jq/grep・決定的・数秒以内）。

# ===== 機械ゲート: implementation タスクの validation コマンド検証 =====
# validate_impl_test_commands <task_file> <_unused>
# - implementation: テストFW（vitest 等）/ 検証コマンド（tsc/eslint/biome 等）/
#   （replaces 非空なら grep 配線検証）のいずれかを L1 に持つこと。test -f/bash -c 単体は違反
# - replaces 非空タスクは L1 に grep 配線検証（旧名残存なし+新名被参照）必須
# - setup / documentation は test -f 許容
# - validation 未執筆（checks も layer_1 も無い）タスクは対象外（執筆後ゲートで検査）
# stdout: 違反詳細 / 戻り値: 0=PASS, 1=違反
validate_impl_test_commands() {
  local task_file="$1"
  local _unused="${2:-}"

  local violations=""

  local weak_impl
  weak_impl=$(jq_safe -r '
    [.tasks[] |
      select(.task_type == "implementation") |
      select(([.validation.checks[]? | select(.layer == 1)] | length) == 0) |
      select(
        ((.validation.layer_1.command // "") | test("(vitest|jest|pytest|playwright|mocha|ava|tap)\\b") | not) and
        ((.validation.layer_1.command // "") | test("(tsc|eslint|biome)\\b|node --test|go test|cargo test") | not) and
        ((((.validation.layer_1.command // "") | test("grep")) and ((.replaces // []) | length > 0)) | not)
      ) |
      select((.validation.layer_1.command // "") | test("test\\s+-[fd]|bash\\s+-c")) |
      .task_id
    ] | join(", ")
  ' "$task_file" 2>/dev/null)
  if [ -n "$weak_impl" ]; then
    violations="implementation タスクの L1 がテストFW/検証コマンドなしの test -f/bash -c 単体: ${weak_impl}（vitest 等のテスト実行、または tsc/eslint/biome 等の検証コマンドを含めること）"
  fi

  # v2 checks 版: 「file_exists 単体は implementation で禁止」の構造検査。
  # run_test / effect_smoke / （replaces 非空なら grep_ref）のいずれかを layer-1 checks に持つこと
  local weak_impl_v2
  weak_impl_v2=$(jq_safe -r '
    [.tasks[] |
      select(.task_type == "implementation") |
      . as $t |
      [.validation.checks[]? | select(.layer == 1)] as $c |
      select(($c | length) > 0) |
      select(([$c[] | select(.verb == "run_test" or .verb == "effect_smoke")] | length) == 0) |
      select(((([$c[] | select(.verb == "grep_ref")] | length) > 0) and (($t.replaces // []) | length > 0)) | not) |
      .task_id
    ] | join(", ")
  ' "$task_file" 2>/dev/null)
  if [ -n "$weak_impl_v2" ]; then
    violations="${violations}${violations:+ | }implementation タスクの v2 checks に実行系 verb がない（file_exists 単体は禁止）: ${weak_impl_v2}（run_test か effect_smoke、replaces 併用時は grep_ref を含めること）"
  fi

  # replaces 配線検証（validation を持つタスクのみ対象 — 未執筆タスクは執筆後に検査）
  local missing_wiring
  missing_wiring=$(jq_safe -r '
    [.tasks[] |
      select((.replaces // []) | length > 0) |
      select((.validation // null) != null) |
      select(((.validation.layer_1.command // "") != "") or (([.validation.checks[]?] | length) > 0)) |
      select(([.validation.checks[]? | select(.layer == 1)] | length) == 0) |
      select((.validation.layer_1.command // "") | test("grep") | not) |
      .task_id
    ] | join(", ")
  ' "$task_file" 2>/dev/null)
  if [ -n "$missing_wiring" ]; then
    violations="${violations}${violations:+ | }replaces 指定タスクに grep 配線検証がない: ${missing_wiring}（旧名残存なし + 新名被参照ありの grep を layer_1.command に含めること）"
  fi

  # v2 版配線検証: replaces 非空 + layer-1 checks に grep_ref がない
  local missing_wiring_v2
  missing_wiring_v2=$(jq_safe -r '
    [.tasks[] |
      select((.replaces // []) | length > 0) |
      select(([.validation.checks[]? | select(.layer == 1)] | length) > 0) |
      select(([.validation.checks[]? | select(.layer == 1 and .verb == "grep_ref")] | length) == 0) |
      .task_id
    ] | join(", ")
  ' "$task_file" 2>/dev/null)
  if [ -n "$missing_wiring_v2" ]; then
    violations="${violations}${violations:+ | }replaces 指定タスク(v2)に grep_ref 配線検証がない: ${missing_wiring_v2}"
  fi

  if [ -n "$violations" ]; then
    printf '%s\n' "$violations"
    return 1
  fi
  return 0
}

# ===== 機械ゲート: requires 充足検証 =====
# validate_requires_satisfiable <task_file> <capabilities_file>
# deferred:true でないのに環境能力で充足できない requires（暗黙タグ含む）を検出する。
# 暗黙タグ: strategy=browser → browser / strategy=api_e2e → server / verb=http_check → server。
# file: は計画時点で対象外（タスクが将来生成するファイルのため）。
# 充足判定は common.sh の requires_entry_satisfiable を再利用する。
# stdout: 違反詳細 / 戻り値: 0=PASS, 1=違反
validate_requires_satisfiable() {
  local task_file="$1"
  local caps_file="${2:-}"

  local entries
  entries=$(jq_safe -r '
    [
      (.tasks[]? | . as $t | select(.validation.layer_2.command != null) | select(.validation.layer_2.deferred != true) |
        (.validation.layer_2.requires // [])[] | "\($t.task_id)|L2|\(.)"),
      (.tasks[]? | . as $t | .validation.layer_3[]? | select(.deferred != true) |
        ((.requires // []) +
         (if .strategy == "browser" then ["browser"] elif .strategy == "api_e2e" then ["server"] else [] end)
        ) | unique | .[] | "\($t.task_id)|L3|\(.)"
      ),
      (.tasks[]? | . as $t | .validation.checks[]? | select(.deferred != true) | . as $c |
        (($c.requires // []) +
         (if $c.verb == "http_check" then ["server"] else [] end)
        ) | unique | .[] | "\($t.task_id)|C\($c.layer)|\(.)"
      )
    ] | unique | .[]
  ' "$task_file" 2>/dev/null)
  [ -z "$entries" ] && return 0

  local _saved_caps="${ENV_CAPABILITIES_FILE:-}"
  ENV_CAPABILITIES_FILE="$caps_file"

  local violations="" tid layer req
  while IFS='|' read -r tid layer req; do
    [ -z "$req" ] && continue
    case "$req" in
      file:*) continue ;;
    esac
    if ! requires_entry_satisfiable "$req"; then
      violations="${violations}${violations:+ | }${tid}(${layer}): 不足能力 ${req}"
    fi
  done <<< "$entries"

  ENV_CAPABILITIES_FILE="$_saved_caps"

  if [ -n "$violations" ]; then
    printf '%s\n' "環境能力で充足できない requires が deferred 指定なしで残存（deferred:true + 代替検証の併設、または strategy 変更が必要）: ${violations}"
    return 1
  fi
  log "✓ requires 充足検証: 問題なし"
  return 0
}

# ===== 機械ゲート: validation v2 checks 構造検証 =====
# validate_v2_checks <task_file> [_unused]
# v2 checks の構造的妥当性を検査する。regex ゲートと違い構造 walk のため
# クォートで騙されない。
# 環境変数 VG_REQUIRE_L1（既定 1）: 1 = 全タスクに L1 検証（legacy command か
# layer-1 check）を要求 / 0 = 要求しない（Planner 降格後の生成時 — validation は
# 実装後に Implementer が執筆するため生成時点では存在しない）
# stdout: 違反詳細 / 戻り値: 0=PASS, 1=違反
validate_v2_checks() {
  local task_file="$1"
  local _unused="${2:-}"

  local violations
  violations=$(jq_safe -r '
    def verbs: ["file_exists","grep_ref","run_test","http_check","effect_smoke","agent_flow","raw_shell"];
    def runners: ["vitest","jest","pytest","playwright","node-test","go-test","cargo-test","tsc","eslint","biome"];
    def badpath: test("^/") or test("\\.\\.") or test("[*?\\[]");
    [ .tasks[]? | . as $t | (.validation.checks // [])[] | . as $c |
      ( if ((verbs | index($c.verb // "")) == null) then "未知 verb \($c.verb // "?")"
        elif (($c.layer // 0) | IN(1,2,3) | not) then "layer が 1/2/3 でない"
        elif ($c.verb == "file_exists" or $c.verb == "grep_ref") and ((($c.paths // []) | length) == 0) then "\($c.verb) に paths がない"
        elif ($c.verb == "grep_ref") and (($c.pattern // "") == "") then "grep_ref に pattern がない"
        elif ($c.verb == "run_test") and ((runners | index($c.runner // "")) == null) then "run_test の runner が不正: \($c.runner // "?")"
        elif ($c.verb == "http_check") and (($c.url // "") == "" and ($c.url_path // "") == "") then "http_check に url/url_path がない"
        elif ($c.verb == "effect_smoke") and ((($c.argv // []) | length) == 0) then "effect_smoke に argv がない"
        elif ($c.verb == "raw_shell") and (($c.shell // "") == "") then "raw_shell に shell がない"
        elif ($c.verb == "raw_shell") and (($c.reason // "") == "") then "raw_shell に reason がない（最終手段の理由必須）"
        elif ($c.verb == "agent_flow") and (($c.definition // null) == null) then "agent_flow に definition がない"
        elif (((($c.paths // []) + ($c.expect.creates_files // [])) | map(select(badpath)) | length) > 0) then "パスに絶対パス/../グロブ"
        elif (([$c | .. | strings | select(test("\\{\\{[A-Z_]+\\}\\}"))] | length) > 0) then "未置換プレースホルダ"
        elif (($c.layer == 1) and ((($c.requires // []) | map(select((startswith("cmd:") or startswith("file:")) | not)) | length) > 0)) then "layer:1 に env 依存 requires（L1 に defer 経路なし — server/env: は L2 以降へ）"
        else empty end
      ) as $v | "\($t.task_id): \($v)"
    ] | unique | join(" | ")
  ' "$task_file" 2>/dev/null)

  # カバレッジ規則: 全タスクは legacy layer_1.command か layer-1 check のどちらかを持つこと。
  # VG_REQUIRE_L1=0 の場合はスキップ（生成時 — validation は実装後に執筆される）
  if [ "${VG_REQUIRE_L1:-1}" = "1" ]; then
    local no_l1
    no_l1=$(jq_safe -r '
      [ .tasks[]? |
        select(((.validation.layer_1.command // "") == "") and
               (([.validation.checks[]? | select(.layer == 1)] | length) == 0)) |
        .task_id ] | join(", ")' "$task_file" 2>/dev/null)
    if [ -n "$no_l1" ]; then
      violations="${violations}${violations:+ | }L1 検証なし（legacy layer_1.command も layer-1 check も無い）: ${no_l1}"
    fi
  fi

  # 併記は warn のみ（実行時は v2 が権威で解決）
  local dual
  dual=$(jq_safe -r '
    [ .tasks[]? |
      select(((.validation.layer_1.command // "") != "") and
             (([.validation.checks[]? | select(.layer == 1)] | length) > 0)) |
      .task_id ] | join(", ")' "$task_file" 2>/dev/null)
  [ -n "$dual" ] && log "⚠ v2 checks と legacy layer_1.command が併記（実行時は v2 が権威・legacy 無視）: ${dual}"

  if [ -n "$violations" ]; then
    printf '%s\n' "$violations"
    return 1
  fi
  log "✓ v2 checks 構造検証: 問題なし"
  return 0
}

# ===== 機械ゲート: L3 criteria 割当検証（生成時 — batch#10 Stage4） =====
# validate_l3_refs_claimed <task_file> <criteria_file>
# 旧「L3 定義必須 exit 1」の置換。Planner はコマンドを書かなくなったため、
# 代わりに「全 layer_3_criteria ID がいずれかのタスクの l3_criteria_refs に
# 割り当てられていること」を機械検証する（実コマンドの充足は執筆後ゲートが担う）。
# stdout: 未割当 ID / 戻り値: 0=PASS（criteria に L3 が無ければスキップ）, 1=違反
validate_l3_refs_claimed() {
  local task_file="$1"
  local criteria_file="${2:-}"

  { [ -n "$criteria_file" ] && [ -f "$criteria_file" ]; } || return 0

  local all_l3
  all_l3=$(jq_safe -r '[.layer_3_criteria[]?.id // empty] | sort | .[]' "$criteria_file" 2>/dev/null)
  [ -z "$all_l3" ] && return 0

  local claimed
  claimed=$(jq_safe -r '
    [(.tasks[]?.l3_criteria_refs // [])[],
     (.tasks[]?.validation.layer_3[]?.id // empty)] | unique | .[]
  ' "$task_file" 2>/dev/null)

  local missing="" id
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! printf '%s\n' "$claimed" | grep -qxF -- "$id"; then
      missing="${missing}${missing:+, }${id}"
    fi
  done <<< "$all_l3"

  if [ -n "$missing" ]; then
    printf '%s\n' "未割当の layer_3_criteria: ${missing}（いずれかのタスクの l3_criteria_refs に割り当てること）"
    return 1
  fi
  log "✓ L3 criteria 割当検証: 全 ID 割当済み"
  return 0
}

# ===== 機械ゲート: phase scope 突合（criteria_refs × dev_phase — batch#10 Stage4） =====
# validate_phase_scope_mapping <task_file> [_unused]
# 各 phase の criteria_refs に列挙された L1 ID が、その phase に属するタスク
# （dev_phase_id 一致）の l1_criteria_refs でカバーされているかを検証する。
# salesletter2 欠陥1（phase scope の項目がタスク化されず対照群が丸ごと欠落）の
# 機械検出部。scope_description の意味的カバーは生成側の LLM 照合が補完する。
# stdout: 違反詳細 / 戻り値: 0=PASS, 1=違反
validate_phase_scope_mapping() {
  local task_file="$1"
  local _unused="${2:-}"

  local violations
  violations=$(jq_safe -r '
    . as $root |
    [ .phases[]? | .id as $pid | (.criteria_refs // [])[] | . as $ref |
      select(
        ([ $root.tasks[]? |
           select((.dev_phase_id // "mvp") == $pid) |
           (.l1_criteria_refs // [])[] |
           select(. == $ref)
         ] | length) == 0
      ) | "\($pid): \($ref)"
    ] | unique | join(", ")
  ' "$task_file" 2>/dev/null)

  if [ -n "$violations" ]; then
    printf '%s\n' "phase の criteria_refs がその phase のタスクでカバーされていない: ${violations}"
    return 1
  fi
  log "✓ phase scope 突合: 問題なし"
  return 0
}

# ===== 執筆後ゲート: 単一タスクの validation 総合検証（ralph-loop から） =====
# validate_authored_validation <task_json> [caps_file]
# Implementer が執筆した validation を、生成時と同じ規則 + L1 必須 + L3 構造で検証する。
# stdout: 違反詳細（複数ゲート分を連結） / 戻り値: 0=PASS, 1=違反
validate_authored_validation() {
  local task_json="$1"
  local caps_file="${2:-${ENV_CAPABILITIES_FILE:-}}"

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/authored-validation.XXXXXX.json")
  printf '{"tasks":[%s]}' "$task_json" > "$tmp"

  local violations="" detail

  if ! detail=$(VG_REQUIRE_L1=1 validate_v2_checks "$tmp" ""); then
    violations="${violations}${violations:+ | }${detail}"
  fi
  if ! detail=$(validate_impl_test_commands "$tmp" ""); then
    violations="${violations}${violations:+ | }${detail}"
  fi
  if [ -n "$caps_file" ] && [ -f "$caps_file" ]; then
    if ! detail=$(validate_requires_satisfiable "$tmp" "$caps_file"); then
      violations="${violations}${violations:+ | }${detail}"
    fi
  fi

  # L3 構造: strategy enum + llm_judge の judge_criteria + l3_criteria_refs の充足
  detail=$(jq_safe -r '
    [ .tasks[0] | . as $t |
      ((.validation.layer_3 // [])[] |
        ( if (.strategy // "" | test("^(structural|api_e2e|llm_judge|cli_flow|context_injection|agent_flow|browser)$") | not)
            then "不正な L3 strategy: \(.id // "?")(\(.strategy // "null"))"
          elif (.strategy == "llm_judge") and ((.definition.judge_criteria // [] | length) == 0)
            then "llm_judge に judge_criteria がない: \(.id // "?")"
          elif ((.definition.command // "") == "") and (.strategy != "browser") and (.deferred != true)
            then "L3 definition.command が空: \(.id // "?")"
          else empty end)),
      ( ($t.l3_criteria_refs // [])[] | . as $ref |
        select(([$t.validation.layer_3[]? | select(.id == $ref)] | length) == 0) |
        "l3_criteria_refs の \($ref) に対応する validation.layer_3 定義がない" )
    ] | unique | join(" | ")
  ' "$tmp" 2>/dev/null)
  [ -n "$detail" ] && violations="${violations}${violations:+ | }${detail}"

  rm -f "$tmp" 2>/dev/null || true

  if [ -n "$violations" ]; then
    printf '%s\n' "$violations"
    return 1
  fi
  return 0
}
