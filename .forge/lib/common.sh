#!/bin/bash
# common.sh — Forge Harness 共有ユーティリティ関数
# 使い方: source "${PROJECT_ROOT}/.forge/lib/common.sh"
#
# 前提変数（呼び出し元で定義すること）:
#   PROJECT_ROOT    — プロジェクトルートの絶対パス
#   ERRORS_FILE     — errors.jsonl のパス（record_error, validate_json が使用）
#   json_fail_count — JSON検証失敗カウンタ（validate_json が読み書き。0で初期化すること）
#   RESEARCH_DIR    — エラー記録のコンテキスト識別子（未定義時は "unknown" にフォールバック）
#
# 注意: Opus モデルは応答が遅い場合がある（Task Planner で ~9 分以上の事例あり）。
# Claude CLI -p モードは処理完了後に初めて stdout 出力するため、timeout で kill されると
# .pending ファイルが空→削除される。Opus 使用時は development.json の timeout_sec を
# 1800 以上に設定することを推奨。

# ===== カラー定数 =====
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ===== トレースID =====
# FORGE_CALL_ID: run_claude() 呼出ごとにインクリメントされるシーケンス番号
# FORGE_SESSION_ID: forge-flow.sh 起動時に生成される UUID v4 セッション識別子
: "${FORGE_CALL_ID:=0}"

# ===== run_claude 専用 exit code =====
# RC_EXIT_BUDGET_EXCEEDED: per-call 予算超過（--max-budget-usd）。
# claude CLI は exit 1 + stdout "Error: Exceeded USD budget (N)" で終了する（2.1.199 実測）が、
# 予算超過は同一プロンプト・同一予算で再実行しても超過が再発する決定的失敗であり、
# リトライは超過分のコストを毎回積み増すだけ → 専用コードに分類して非リトライ対象にする。
# 124(timeout) / 2(引数エラー) との衝突を避けた値。
: "${RC_EXIT_BUDGET_EXCEEDED:=21}"

# RC_EXIT_QUOTA_EXHAUSTED: サブスクリプションのモデル別クォータ枯渇。
# claude CLI は "You've reached your <Model> limit." を stdout に出して終了する（2026-07-22 実測）。
# 429（一時的なレート超過）と異なりクォータ枯渇は数時間〜リセットまで回復せず、
# リトライもクールダウンも無意味（2026-07-22: 5時間45分・36回の全リトライが同一エラーで失敗）。
# モデル切替か credits 追加という人間の介入が必須のため、非リトライ対象として即座に打ち切る。
: "${RC_EXIT_QUOTA_EXHAUSTED:=22}"

# ===== コストトラッキング用グローバル変数 =====
# run_claude() が extract_cost_from_debug_log() 経由で更新し、
# metrics_record() が参照後にリセットする。
# フォールバック値は 0（ログ解析失敗時）
: "${_LAST_INPUT_TOKENS:=0}"
: "${_LAST_OUTPUT_TOKENS:=0}"
: "${_LAST_COST_USD:=0}"

# ===== ログ出力 =====
# 常にstderrへ出力。stdoutをverdict返却に使う関数と干渉させない。
# LOG_PREFIX が定義されていればタイムスタンプ直後に挿入する。
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')]${LOG_PREFIX:+ $LOG_PREFIX} $1" >&2
}

# ===== タイムスタンプ生成 =====
# ログファイル名用。呼び出し毎に更新。
now_ts() {
  date +%Y%m%d-%H%M%S
}

# ===== セッションID生成 =====
# UUID v4形式 (8-4-4-4-12 hex) を生成。forge-flow.sh 起動時に呼び出す。
# 優先度: python3 → uuidgen → /dev/urandom フォールバック
generate_session_id() {
  if command -v python3 &>/dev/null; then
    local _uuid
    _uuid=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
    if [ -n "$_uuid" ]; then echo "$_uuid"; return; fi
  fi
  if command -v uuidgen &>/dev/null; then
    local _uuid
    _uuid=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -n "$_uuid" ]; then echo "$_uuid"; return; fi
  fi
  # フォールバック: /dev/urandom から 128bit を取得し UUID v4 形式にフォーマット
  local h
  h=$(od -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n\r' | head -c 32)
  local v16
  v16=$(printf '%x' $(( ( 16#${h:16:1} & 3 ) | 8 )))
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "${v16}" "${h:17:3}" "${h:20:12}"
}

# ===== テンプレートレンダリング =====
# {{KEY}} プレースホルダーを値で置換する。
# 使い方: render_template <template_file> <KEY1> <VALUE1> [<KEY2> <VALUE2> ...]
# 注意: bash の ${//pattern/replacement} では & が特殊文字（マッチ全体に展開）。
#       値に & を含む場合（diff/コード等）は \& にエスケープしてから置換する。
render_template() {
  local template_file="$1"
  shift
  local content
  content=$(cat "$template_file")
  while [ $# -ge 2 ]; do
    local key="$1"
    local value="$2"
    shift 2
    # & → \& エスケープ（bash ${//} の replacement で & はマッチ全体に展開されるため）
    local escaped_value="${value//&/\\&}"
    content="${content//\{\{${key}\}\}/$escaped_value}"
  done
  printf '%s\n' "$content"
}

# ===== CRLF-safe jq ラッパー =====
# Windows (Git Bash) 環境で jq -r の出力に付加される \r を除去する。
# 使い方: jq_safe <jq_args...>  — jq の全引数をそのまま渡す
# 例: count=$(jq_safe -r '.count' file.json)
#     jq_safe -r '.phases[].id' file.json | while read -r pid; do ...
jq_safe() {
  jq "$@" | tr -d '\r'
}

# ===== boolean 設定の安全な読取 =====
# jq の `// default` は false を「空」扱いして default に潰す（false が設定できない罠。
# batch#11 監査で 13 箇所を確認: config で false にしても true に化けていた）。
# type 判定で boolean のときだけ実値を返し、それ以外（キー欠落 / null / 非 boolean /
# ファイル不在 / jq エラー）は default。出力は常に 'true' か 'false'。
# 使い方: v=$(cfg_bool <json_file> <jq_path> <default:true|false>)
cfg_bool() {
  local file="$1" path="$2" default="${3:-true}"
  case "$default" in true|false) ;; *) default=true ;; esac
  local v=""
  if [ -n "$file" ] && [ -f "$file" ]; then
    v=$(jq -r "if (${path} | type) == \"boolean\" then ${path} else \"${default}\" end" "$file" 2>/dev/null | tr -d '\r') || v=""
  fi
  case "$v" in true|false) printf '%s' "$v" ;; *) printf '%s' "$default" ;; esac
}

# ===== CRLF-safe jq ラッパー (行ループ用意味的エイリアス) =====
# `jq -r ... | while IFS= read -r x; do ...` パターンで各行末に付く CRLF の \r を除去する
# Windows 互換ヘルパー（Git Bash + jq 1.7.1 の text-mode 出力対策）。
# 意味的には jq_safe と同一（tr -d '\r' 適用）だが、用途を明確化するため別名で提供する:
#   - jq_safe : 単一値取得またはファイル全体処理
#   - jq_lines: 複数行出力を while read でループするとき
# Linux/macOS では jq が \r を付与しないため tr -d '\r' は no-op（冪等）。
# 例: jq_lines -r '.items[]' file.json | while IFS= read -r item; do ...
# 注意: 改行を含む値（例: multiline string）は jq_lines の用途外。その場合は
#       `jq -r '... | @json'` で1行に畳むか、`--arg`/`--argjson` 経由で渡す、
#       または NUL 区切り（`jq -j '...\0'` + `read -d ''`）を検討すること。
jq_lines() {
  jq "$@" | tr -d '\r'
}

# ===== L1 criteria 網羅チェック（共通ユーティリティ） =====
# criteria の全 L1 ID が task-stack の l1_criteria_refs で網羅されているか検証する。
# generate-tasks.sh から移管された純関数。副作用は stdout への missing_ids 出力と log() のみ。
# 使い方: validate_l1_coverage <task_file> <criteria_file>
#   - exit 0: 全 L1 ID がカバー済み
#   - exit 1: 欠落あり。stdout に "L1-001, L1-002" 形式で欠落IDリストを出力
# CRLF 対策: jq_lines でラップして Windows Git Bash の \r 付加を除去する。
validate_l1_coverage() {
  local task_file="$1"
  local criteria_file="$2"

  # criteria から全 L1 ID を抽出
  local all_l1_ids
  all_l1_ids=$(jq_lines -r '[.layer_1_criteria[].id] | sort | .[]' "$criteria_file" 2>/dev/null)
  if [ -z "$all_l1_ids" ]; then
    log "⚠ criteria に layer_1_criteria がありません — L1 網羅チェックをスキップ"
    return 0
  fi

  # タスクから参照されている全 L1 ID を抽出
  local covered_l1_ids
  covered_l1_ids=$(jq_lines -r '[.tasks[].l1_criteria_refs // [] | .[]] | unique | sort | .[]' "$task_file" 2>/dev/null)

  # 差分を計算
  local missing_ids=""
  for l1_id in $all_l1_ids; do
    if ! echo "$covered_l1_ids" | grep -qx "$l1_id"; then
      missing_ids="${missing_ids}${missing_ids:+, }${l1_id}"
    fi
  done

  if [ -n "$missing_ids" ]; then
    log "✗ L1 criteria 網羅チェック失敗: 未カバー = ${missing_ids}"
    echo "$missing_ids"
    return 1
  fi

  local total_l1
  total_l1=$(echo "$all_l1_ids" | wc -l | tr -d ' ')
  log "✓ L1 criteria 網羅チェック通過: ${total_l1} 件全てカバー済み"
  return 0
}

# ===== effort 引数バリデーション/構築（純関数・テスト容易） =====
# Claude CLI の reasoning effort フラグ（--effort low|medium|high|xhigh|max）を構築する。
# -p モードと併用可能な正式フラグ。run_claude から呼び出される単一の真実源。
# 使い方: validate_effort <effort>
#   - 空文字       : 何も出力せず return 0（後方互換: --effort フラグなし）
#   - low|medium|high|xhigh|max : "--effort <value>" を stdout に出力し return 0
#   - それ以外     : stderr にエラー記録、return 1（全エージェント波及クラッシュを防ぐ）
# 注意: 出力は space 区切り文字列。呼び出し側で `read -ra` 等により配列化すること。
validate_effort() {
  local effort="$1"
  case "$effort" in
    "")
      return 0 ;;
    low|medium|high|xhigh|max)
      printf '%s' "--effort ${effort}"
      return 0 ;;
    *)
      log "✗ 不正な effort 値: '${effort}'（許可: low|medium|high|xhigh|max）"
      return 1 ;;
  esac
}

# ===== CLI フラグ実在プローブ（プロセス内1回だけ claude --help を実行しキャッシュ） =====
# 未知フラグを claude CLI に渡すと全 run_claude 呼出が即死するため、
# バージョン依存フラグ（--max-turns 等）は付与前に実在を確認する。
# テストからは _RC_CLI_HELP_CACHE を直接注入して分岐を検証できる。
# 使い方: claude_cli_supports_flag "--max-turns"  → 0=対応, 1=非対応
claude_cli_supports_flag() {
  local flag="$1"
  if [ -z "${_RC_CLI_HELP_CACHE:-}" ]; then
    _RC_CLI_HELP_CACHE=$(claude --help 2>/dev/null || echo "")
    # 空でもキャッシュ済み扱いにする（claude 不在環境で毎回実行しない）
    [ -n "$_RC_CLI_HELP_CACHE" ] || _RC_CLI_HELP_CACHE="(no-help)"
  fi
  printf '%s' "$_RC_CLI_HELP_CACHE" | grep -q -- "$flag"
}

# ===== per-call 予算ガード引数構築（純関数・テスト容易） =====
# circuit-breaker.json の per_call_guards から run_claude 1呼出あたりの上限フラグを構築する。
# 累計コスト breaker（cost_tracking.max_session_cost_usd、タスク間チェック）の内側で
# 単発呼出の暴走を止める第2層。0/不在/非数値 = 無効（後方互換: フラグなし）。
# --max-budget-usd は CLI 2.1.198 で実在確認済み（--print 限定、超過で exit 1）。
# --max-turns は 2.1.198 に存在しないためプローブ通過時のみ付与する。
# 使い方: build_per_call_guard_args [config_file]  → "--max-budget-usd 3.0" 等を stdout へ
build_per_call_guard_args() {
  local cfg="${1:-${PROJECT_ROOT:-.}/.forge/config/circuit-breaker.json}"
  [ -f "$cfg" ] || return 0
  local budget turns out=""
  budget=$(jq_safe -r '.per_call_guards.max_budget_usd // 0' "$cfg" 2>/dev/null)
  turns=$(jq_safe -r '.per_call_guards.max_turns // 0' "$cfg" 2>/dev/null)
  [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] || budget=0
  [[ "$turns" =~ ^[0-9]+$ ]] || turns=0
  if awk "BEGIN{exit !($budget > 0)}"; then
    out="--max-budget-usd ${budget}"
  fi
  if [ "$turns" -gt 0 ] && claude_cli_supports_flag "--max-turns"; then
    out="${out:+$out }--max-turns ${turns}"
  fi
  printf '%s' "$out"
  return 0
}

# ===== run_claude 失敗 exit code 分類（純関数・テスト容易） =====
# claude CLI の失敗出力を検査し、決定的失敗を専用 exit code に変換する。
# 現在の分類対象は予算超過（--max-budget-usd）のみ:
#   exit 1 + stdout "Error: Exceeded USD budget (N)" → RC_EXIT_BUDGET_EXCEEDED(21)
# タイムアウト(124) は分類せず素通し（メッセージ検査自体が不要なため呼び出し側で除外可）。
# 使い方: classify_run_claude_exit <exit_code> <captured_stdout_file> → 分類後の exit code を stdout へ
classify_run_claude_exit() {
  local exit_code="$1"
  local dest_file="$2"
  if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 124 ] && \
     grep -q "Exceeded USD budget" "$dest_file" 2>/dev/null; then
    printf '%s' "$RC_EXIT_BUDGET_EXCEEDED"
    return 0
  fi
  # クォータ枯渇: "You've reached your Fable 5 limit." 等（アポストロフィは ' / ’ 双方を許容）
  if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 124 ] && \
     grep -qiE "reached your .{0,30}limit" "$dest_file" 2>/dev/null; then
    printf '%s' "$RC_EXIT_QUOTA_EXHAUSTED"
    return 0
  fi
  printf '%s' "$exit_code"
  return 0
}

# ===== --agents インライン定義 JSON 構築（純関数・テスト容易） =====
# .claude/agents/*.md（素の markdown、フロントマターなし）を claude -p の --agents 形式
#   {"<name>": {"description": "...", "prompt": "<md 全文>"}}
# に変換する。name = ファイル名 stem、description = 先頭見出し行（# 除去）、見出しなしは name。
# -p モードは .claude/agents/*.md を自動ロードしない（2026-07-02 再検証、CLI 2.1.198/199）ため、
# サブエージェント定義をインライン JSON 化して --agents に渡すのが唯一の -p Task 委譲経路。
# 使い方: build_agents_json <md_file>... → JSON オブジェクトを stdout へ（有効ファイル 0 件なら "{}"）
build_agents_json() {
  local out="{}" f name desc next
  for f in "$@"; do
    if [ ! -f "$f" ]; then
      log "⚠ build_agents_json: ファイル不在 '$f' — skip"
      continue
    fi
    name=$(basename "$f" .md)
    desc=$(grep -m1 -E '^#' "$f" 2>/dev/null | sed -E 's/^#+[[:space:]]*//' | tr -d '\r')
    [ -n "$desc" ] || desc="$name"
    if next=$(jq -c --arg n "$name" --arg d "$desc" --rawfile p "$f" \
      '. + {($n): {description: $d, prompt: $p}}' <<< "$out" 2>/dev/null); then
      out="$next"
    else
      log "⚠ build_agents_json: JSON 構築失敗 '$f' — skip"
    fi
  done
  printf '%s' "$out"
}

# ===== agent_effort 設定リゾルバ（純関数・テスト容易） =====
# config ファイルの .agent_effort.<agent_key> を解決し、effort レベル文字列を stdout に出力する。
# validate_effort と異なり「--effort 」プレフィックスは付けない（レベル名のみ）。
# 呼び出し側は `validate_effort "$(resolve_agent_effort implementer)"` のように合成する。
# 使い方: resolve_agent_effort <agent_key> [config_file]
#   - config_file 省略時は development.json をデフォルト参照
#   - 未定義 / null / 空    : 何も出力せず return 0（デフォルトフォールバック = --effort フラグなし/medium 相当）
#   - low|medium|high|xhigh|max : そのレベル名を stdout に出力し return 0
#   - 上記以外（不正値）    : stderr に警告を記録し、何も出力せず return 0（フォールバック・クラッシュ回避）
# 注意: ここでは不正値でも非ゼロにしない。設定ミスでループ全体を止めず安全側にフォールバックする方針。
resolve_agent_effort() {
  local agent_key="$1"
  local config_file="${2:-}"
  if [ -z "$config_file" ]; then
    config_file="${DEVELOPMENT_JSON:-${PROJECT_ROOT:-.}/.forge/config/development.json}"
  fi
  if [ ! -f "$config_file" ]; then
    log "⚠ agent_effort 解決: config ファイル不在 ('${config_file}') — デフォルトにフォールバック"
    return 0
  fi
  local val
  val=$(jq_safe -r ".agent_effort.\"${agent_key}\" // empty" "$config_file" 2>/dev/null)
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    # 未定義 → デフォルトフォールバック（無指定）
    return 0
  fi
  case "$val" in
    low|medium|high|xhigh|max)
      printf '%s' "$val"
      return 0 ;;
    *)
      log "⚠ 不正な agent_effort 値 ('${val}') for '${agent_key}' — デフォルトにフォールバック"
      return 0 ;;
  esac
}

# ===== effort 連動タイムアウト倍率（純関数・テスト容易） =====
# effort レベル → タイムアウト倍率を返す。
# 高 effort のエージェント出力は大きく/複雑になりがちで検証実行も長くなる傾向のため、
# 縮小方向には適用しない（全レベルで倍率 >= 1.0）。
#   low|medium|空|不明値 : 1.0（後方互換の等倍）
#   high                 : 1.5
#   xhigh                : 2.0
#   max                  : 3.0
effort_timeout_multiplier() {
  case "${1:-}" in
    high)  printf '1.5' ;;
    xhigh) printf '2.0' ;;
    max)   printf '3.0' ;;
    *)     printf '1.0' ;;
  esac
}

# ===== effort 連動タイムアウト適用（純関数・テスト容易） =====
# L1/L2/L3 テストの timeout_sec base 値に effort 連動倍率を適用する。
# 使い方: apply_effort_timeout <base_timeout_sec> [effort]
#   - base=0（無制限）        : 0 を維持する（timeout 0 は GNU coreutils で無制限扱い。
#                               ハングリスクゼロ系を有限化しない）
#   - effort 空/未指定/不明値 : 倍率 1.0（後方互換: base をそのまま返す）
#   - base が非整数（型違い等）: そのまま返す（呼び出し元の整数バリデーション防御に委ねる）
# 出力は常に整数（小数は切り上げ → 結果は必ず base 以上で、timeout コマンドにそのまま渡せる）。
# printf 出力のため CRLF 混入なし（Windows Git Bash 安全）。
apply_effort_timeout() {
  local base="${1:-}"
  local effort="${2:-}"
  # 非整数 base は変換せず素通し（上流の整数防御 [[ =~ ^[0-9]+$ ]] が処理する）
  if ! [[ "$base" =~ ^[0-9]+$ ]]; then
    printf '%s' "$base"
    return 0
  fi
  # 0 = 無制限 → 倍率を適用せず無制限を維持
  if [ "$base" -eq 0 ]; then
    printf '0'
    return 0
  fi
  local mult
  mult=$(effort_timeout_multiplier "$effort")
  # awk で base*mult を計算し切り上げで整数化（結果は必ず base 以上の整数）
  awk -v b="$base" -v m="$mult" 'BEGIN {
    v = b * m
    iv = int(v)
    if (v > iv) iv += 1
    if (iv < b) iv = b
    printf "%d", iv
  }'
}

# ===== フライトシミュレータ（record/replay/fault injection） =====
# RC_RECORD_DIR / RC_REPLAY_DIR / RC_FAULT_PLAN のいずれかが設定された時のみ有効。
# ロジックは simulator.sh に分離。common.sh 単体コピー環境（既存テストの慣行）では
# simulator.sh 不在 → 下の no-op フォールバックで従来挙動と完全一致する。
_forge_sim_dir="$(dirname "${BASH_SOURCE[0]}")"
if [ -f "${_forge_sim_dir}/simulator.sh" ]; then
  # shellcheck source=simulator.sh
  source "${_forge_sim_dir}/simulator.sh"
fi
if [ -f "${_forge_sim_dir}/validation-dsl.sh" ]; then
  # shellcheck source=validation-dsl.sh
  source "${_forge_sim_dir}/validation-dsl.sh"
fi
# ===== パス/パターン照合（batch#11 R05） =====
# fnmatch_to_regex / match_protected_pattern は patterns.sh に分離（PreToolUse hook と共有）。
if [ -f "${_forge_sim_dir}/patterns.sh" ]; then
  # shellcheck source=patterns.sh
  source "${_forge_sim_dir}/patterns.sh"
elif [ -n "${PROJECT_ROOT:-}" ] && [ -f "${PROJECT_ROOT}/.forge/lib/patterns.sh" ]; then
  source "${PROJECT_ROOT}/.forge/lib/patterns.sh"
fi
# 単体コピー環境（patterns.sh 不在）向け: 黙って「不一致」を返さず大声で失敗する stub
declare -f fnmatch_to_regex >/dev/null || fnmatch_to_regex() {
  echo "[ERROR] patterns.sh が見つかりません（fnmatch_to_regex 不能）" >&2; return 2; }
declare -f match_protected_pattern >/dev/null || match_protected_pattern() {
  echo "[ERROR] patterns.sh が見つかりません（match_protected_pattern 不能）" >&2; return 2; }

# 単体コピー環境（validation-dsl.sh 不在）向けフォールバック: legacy 実行意味論を維持
declare -f run_workdir_shell >/dev/null || run_workdir_shell() {
  local _rw_timeout="$1" _rw_wd="$2" _rw_cmd="$3"
  timeout "$_rw_timeout" env PATH="${_rw_wd}/node_modules/.bin:$PATH" bash -c "cd '$_rw_wd' && $_rw_cmd" 2>&1
}
unset _forge_sim_dir
declare -f sim_call_begin >/dev/null || sim_call_begin() { :; }
declare -f sim_claude_exec >/dev/null || sim_claude_exec() {
  # フォールバック実体: run_claude 旧パイプラインの逐語移植（挙動差ゼロ保証）
  local _se_dest="$1" _se_log="$2" _se_timeout="$3" _se_prompt="$4"
  shift 4
  echo "$_se_prompt" | env -u CLAUDECODE timeout "$_se_timeout" "$@" \
    > "$_se_dest" 2>/dev/null
}

# ===== Claude CLI ラッパー =====
# 使い方: run_claude <model> <agent_file> <prompt> <output_file> <log_file> [disallowed_tools] [timeout] [work_dir] [json_schema_file] [effort]
# effort: reasoning effort レベル（low|medium|high|xhigh|max）。省略時は --effort フラグなし（後方互換）。
#         不正値の場合は validate_effort が非ゼロを返し run_claude は即座に非ゼロ終了する。
# デバッグ: FORGE_DRY_RUN=1 を設定すると claude を実行せず、構築した CMD と WORK_DIR を
#           stdout に出力して return 0（コマンド構築のユニットテスト用）。
# agent_file: .claude/agents/*.md のパス。空文字の場合は --system-prompt を省略する。
# work_dir: Claude CLI を実行するカレントディレクトリ。省略時は現在のディレクトリ（通常 PROJECT_ROOT）。
#           WORK_DIR が PROJECT_ROOT と異なる場合（外部プロジェクト作業時）に必ず指定すること。
# json_schema_file: JSON Schema ファイルのパス（.forge/schemas/*.schema.json）。
#                   指定時は --output-format json --json-schema を付与し、
#                   Constrained Decoding で構文的に正しい JSON 出力を保証する。
#                   .pending には structured_output のみを書き出す。
# プロンプトはパイプでstdinから渡す（ARG_MAX制限を回避）
# run_claude の heartbeat フック呼出（batch#11 R07b）: 呼出側ループが forge_heartbeat_hook を
# 定義していれば <stage> <timeout_sec> で呼ぶ。未定義（research-loop / 単体テスト）では何もしない
run_claude_heartbeat() {
  if type forge_heartbeat_hook &>/dev/null; then
    forge_heartbeat_hook "$1" "${2:-}" 2>/dev/null || true
  fi
  return 0
}

run_claude() {
  local model="$1"
  local agent_file="$2"
  local prompt="$3"
  local output_file="$4"
  local log_file="$5"
  local disallowed_tools="${6:-}"
  local stage_timeout="${7:-${CLAUDE_TIMEOUT:-600}}"
  local work_dir="${8:-}"
  local json_schema_file="${9:-}"
  local effort="${10:-}"

  # FORGE_CALL_ID をインクリメント（run_claude 呼出ごとのクロスステージ追跡用シーケンス番号）
  FORGE_CALL_ID=$(( ${FORGE_CALL_ID:-0} + 1 ))
  export FORGE_CALL_ID

  # work_dir 指定時: output_file / log_file が相対パスなら絶対パスへ変換
  # （呼び出し元は PROJECT_ROOT 基準で相対パスを指定するため、cd 後に迷子になる）
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    case "$output_file" in /*) ;; *) output_file="$(pwd)/${output_file}" ;; esac
    case "$log_file" in /*) ;; *) log_file="$(pwd)/${log_file}" ;; esac
    mkdir -p "$(dirname "$output_file")" "$(dirname "$log_file")"
  fi

  # json_schema_file が相対パスなら絶対パスに変換（cd 前に解決）
  if [ -n "$json_schema_file" ]; then
    case "$json_schema_file" in /*) ;; *) json_schema_file="$(pwd)/${json_schema_file}" ;; esac
  fi

  local cmd=(claude --model "$model" -p --dangerously-skip-permissions --debug-file "$log_file")
  # Context Strategy: reset (default) → --no-session-persistence, continuous → omit
  if [ "${_RC_CONTEXT_STRATEGY:-reset}" = "reset" ]; then
    cmd+=(--no-session-persistence)
  fi
  if [ -n "$agent_file" ] && [ -f "$agent_file" ]; then
    cmd+=(--system-prompt "$(cat "$agent_file")")
  fi
  if [ -n "$disallowed_tools" ]; then
    cmd+=(--disallowed-tools "$disallowed_tools")
  fi

  # PreToolUse deny hook（batch#11 R05 後半）: 呼出側が _RC_SETTINGS_FILE（env チャネル）に
  # settings JSON のパスを設定した場合のみ --settings を付与し、hook が読む FORGE_GUARD_* を export する。
  # Implementer / Fixer に Bash を返す（R05 前半）代償として、ハーネス自身・WORK_DIR 外への書込と
  # 破壊的 git を機械的に拒否する（プロンプト上の禁止は --dangerously-skip-permissions 下で無力）。
  # 相対パスは cd "$work_dir" 後に迷子になるため cd 前に絶対化。未知フラグ即死防止でプローブ必須。
  # FORGE_GUARD_DISABLE=1 で無効化（戻し用）。利用者: ralph-loop.sh load_development_config。
  if [ -n "${_RC_SETTINGS_FILE:-}" ] && [ -f "${_RC_SETTINGS_FILE}" ] && [ "${FORGE_GUARD_DISABLE:-0}" != "1" ]; then
    if claude_cli_supports_flag "--settings"; then
      local _rc_settings_file="$_RC_SETTINGS_FILE"
      case "$_rc_settings_file" in /*|[A-Za-z]:*) ;; *) _rc_settings_file="$(pwd)/${_rc_settings_file}" ;; esac
      cmd+=(--settings "$_rc_settings_file")
      # hook は Claude Code から Windows 形式（C:\…）のパスを受け取る。MSYS の /tmp や 8.3 短縮名
      # （BOSSBO~1）と突き合わせると WORK_DIR 内も「外」と判定されるため、渡す側で cygpath -ml
      # （長い名前の Windows 形式）に揃える（2026-09-03 実 CLI スモークで実測）。Linux では素通し
      local _rc_guard_root="${PROJECT_ROOT:-$(pwd)}" _rc_guard_wd=""
      if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        _rc_guard_wd="$(cd "$work_dir" && pwd -P)"
      fi
      if command -v cygpath >/dev/null 2>&1; then
        _rc_guard_root=$(cygpath -ml -- "$_rc_guard_root" 2>/dev/null || printf '%s' "$_rc_guard_root")
        [ -n "$_rc_guard_wd" ] && _rc_guard_wd=$(cygpath -ml -- "$_rc_guard_wd" 2>/dev/null || printf '%s' "$_rc_guard_wd")
      fi
      export FORGE_GUARD_HARNESS_ROOT="$_rc_guard_root"
      export FORGE_GUARD_CB_CONFIG="${FORGE_GUARD_CB_CONFIG:-${PROJECT_ROOT:-$(pwd)}/.forge/config/circuit-breaker.json}"
      export FORGE_GUARD_WORK_DIR="$_rc_guard_wd"
    else
      log "  ⚠ CLI が --settings 非対応 — PreToolUse guard hook をスキップ"
    fi
  fi

  # effort フラグ構築（不正値は即座に非ゼロ終了し全エージェント波及クラッシュを防ぐ）
  local _rc_effort_str
  if ! _rc_effort_str=$(validate_effort "$effort"); then
    return 2
  fi
  if [ -n "$_rc_effort_str" ]; then
    local _rc_effort_arr
    read -ra _rc_effort_arr <<< "$_rc_effort_str"
    cmd+=("${_rc_effort_arr[@]}")
  fi

  # per-call 予算ガード（circuit-breaker.json per_call_guards、0=無効）
  local _rc_guard_str
  _rc_guard_str=$(build_per_call_guard_args)
  if [ -n "$_rc_guard_str" ]; then
    local _rc_guard_arr
    read -ra _rc_guard_arr <<< "$_rc_guard_str"
    cmd+=("${_rc_guard_arr[@]}")
  fi

  # MCP config: 呼出側が _RC_MCP_CONFIG（env チャネル）にパスを設定した場合のみ付与。
  # --strict-mcp-config でハーネス外（ユーザー settings 由来）の MCP 設定混入を遮断する。
  # 利用者: browser-test.sh / ux-judgment.sh（Playwright MCP）。
  # 相対パスは cd "$work_dir" 後に CLI が解決できなくなるため、json_schema_file と
  # 同様に cd 前へ絶対化する（batch#9 監査 A-1 — 呼出元の env は書き換えない）
  if [ -n "${_RC_MCP_CONFIG:-}" ] && [ -f "${_RC_MCP_CONFIG}" ]; then
    local _rc_mcp_config="$_RC_MCP_CONFIG"
    case "$_rc_mcp_config" in /*) ;; *) _rc_mcp_config="$(pwd)/${_rc_mcp_config}" ;; esac
    cmd+=(--mcp-config "$_rc_mcp_config" --strict-mcp-config)
  fi

  # 全呼出を --output-format json（エンベロープ）で受ける（batch#10 Stage1）:
  # usage / total_cost_usd はエンベロープにしか出ない（CLI はデバッグログに usage を
  # 書かない — 2026-08-02 実測。旧 grep 経路は 248 呼出全てで 0 トークンを返し、
  # $10 セッションブレーカーが恒久不発火だった）。
  # 非スキーマ呼出のテキスト本文は後段で .result を抽出して .pending に復元する。
  # JSON Schema 指定時はさらに Constrained Decoding で構文的に正しい JSON を保証。
  local _rc_use_schema=false
  cmd+=(--output-format json)
  if [ -n "$json_schema_file" ] && [ -f "$json_schema_file" ]; then
    cmd+=(--json-schema "$(cat "$json_schema_file")")
    _rc_use_schema=true
  fi

  # --agents インライン定義: 呼出側が _RC_AGENTS_FILE（env チャネル）にパスを設定した場合のみ付与。
  # CLI 2.1.199 の -p モードで Task 委譲が実動作することを確認済み（2026-07-02/03 検証）。
  # .claude/agents/*.md は -p モードで自動ロードされないため、これが agent_flow L3 自動化の配線。
  # 未知フラグは全呼出即死のためプローブ必須（--max-turns と同方針）。不正 JSON は付与しない。
  # 現在の利用者は execute_l3_agent_flow（step.subagent_files）のみ。
  # このブロックは --system-prompt / --json-schema 付与より後ろに置くこと:
  # Windows CreateProcess のコマンドライン上限（~32,767 文字）に対し「合成後の総長」で
  # 超過判定するため（プロンプト本体は stdin 渡しなので対象外）。超過時は静かに壊れる
  # 代わりに --agents を warning 付きでスキップし、後段の検証が失敗を顕在化させる。
  if [ -n "${_RC_AGENTS_FILE:-}" ] && [ -f "${_RC_AGENTS_FILE}" ]; then
    if ! claude_cli_supports_flag "--agents"; then
      log "  ⚠ CLI が --agents 非対応 — サブエージェント定義をスキップ"
    elif ! jq empty "${_RC_AGENTS_FILE}" 2>/dev/null; then
      log "  ⚠ _RC_AGENTS_FILE が不正 JSON — サブエージェント定義をスキップ"
    else
      local _rc_agents_json _rc_joined
      _rc_agents_json=$(cat "$_RC_AGENTS_FILE")
      _rc_joined="${cmd[*]}"
      if [ $(( ${#_rc_joined} + ${#_rc_agents_json} + 16 )) -gt "${RC_CMDLINE_MAX:-30000}" ]; then
        log "  ⚠ コマンドライン総長が上限 ${RC_CMDLINE_MAX:-30000} を超過（agents=${#_rc_agents_json}字 + 既存=${#_rc_joined}字）— --agents をスキップ。subagent_files の数/サイズを減らすこと"
      else
        cmd+=(--agents "$_rc_agents_json")
      fi
    fi
  fi

  # パイプでstdinからプロンプトを渡す（ARG_MAX制限を回避）
  # CLAUDECODE を unset してネストセッション検出を回避（親セッション内からの呼び出し対応）
  # Safe overwrite: .pending に書き出し、validate_json 成功後に本ファイルへ昇格
  # work_dir 指定時はサブシェルで cd してから実行（Claude CLI には --cwd オプションがないため）
  # DRY RUN: claude を実行せず、構築したコマンドと work_dir を出力して返す（ユニットテスト用）
  if [ "${FORGE_DRY_RUN:-0}" = "1" ]; then
    printf 'CMD: %s\nWORK_DIR: %s\n' "${cmd[*]}" "$work_dir"
    return 0
  fi

  local _rc_raw_output="${output_file}.raw-envelope"
  local _rc_target="${output_file}.pending"
  # 全呼出が raw-envelope を経由する（コスト/トークン抽出のため — batch#10 Stage1）。
  # スキーマモードは structured_output を、非スキーマは .result を後段で .pending へ抽出する
  local _rc_dest="$_rc_raw_output"

  # コスト記録用ステージ名（エラーパスでも参照するため実行前に確定）
  local _rc_stage_name
  _rc_stage_name=$(basename "${output_file%.pending}" | sed 's/\.[^.]*$//')

  # heartbeat フック（batch#11 R07b）: 呼出前に timeout 由来の閾値を自己申告し、完了/失敗後に
  # 15 分へ戻す。ralph-loop.sh が forge_heartbeat_hook を定義している時だけ動く（他は no-op）
  run_claude_heartbeat "$_rc_stage_name" "$stage_timeout"

  # シミュレータ判定（Hook A）: 親シェルで状態変異を完結させる
  # （work_dir 分岐はサブシェル実行のため、実行時 Hook B はファイル効果のみ）
  sim_call_begin "$agent_file" "$model" "$effort" "$json_schema_file" \
    "$work_dir" "$output_file" "$stage_timeout"

  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    (
      cd "$work_dir" || return 1
      sim_claude_exec "$_rc_dest" "$log_file" "$stage_timeout" "$prompt" "${cmd[@]}"
    ) || {
      local exit_code=$?
      if [ "$exit_code" -eq 124 ]; then
        log "  タイムアウト（${stage_timeout}秒）"
      fi
      exit_code=$(classify_run_claude_exit "$exit_code" "$_rc_dest")
      if [ "$exit_code" -eq "$RC_EXIT_BUDGET_EXCEEDED" ]; then
        log "  ✗ per-call 予算超過（--max-budget-usd）— 非リトライ対象 (exit=${RC_EXIT_BUDGET_EXCEEDED})"
      fi
      if [ "$exit_code" -eq "$RC_EXIT_QUOTA_EXHAUSTED" ]; then
        log "  ✗ モデルのクォータ枯渇 — 非リトライ対象 (exit=${RC_EXIT_QUOTA_EXHAUSTED})。モデル切替か credits 追加が必要"
      fi
      # 失敗呼出でも消費したコストは記録する（部分出力のエンベロープから best-effort）
      _LAST_INPUT_TOKENS=0; _LAST_OUTPUT_TOKENS=0; _LAST_COST_USD="0"
      extract_cost_from_envelope "$_rc_raw_output" "$_rc_stage_name" "$model" 2>/dev/null || true
      rm -f "$_rc_dest" "$_rc_raw_output"
      run_claude_heartbeat "$_rc_stage_name" ""
      return "$exit_code"
    }
  else
    sim_claude_exec "$_rc_dest" "$log_file" "$stage_timeout" "$prompt" "${cmd[@]}" || {
      local exit_code=$?
      if [ "$exit_code" -eq 124 ]; then
        log "  タイムアウト（${stage_timeout}秒）"
      fi
      exit_code=$(classify_run_claude_exit "$exit_code" "$_rc_dest")
      if [ "$exit_code" -eq "$RC_EXIT_BUDGET_EXCEEDED" ]; then
        log "  ✗ per-call 予算超過（--max-budget-usd）— 非リトライ対象 (exit=${RC_EXIT_BUDGET_EXCEEDED})"
      fi
      if [ "$exit_code" -eq "$RC_EXIT_QUOTA_EXHAUSTED" ]; then
        log "  ✗ モデルのクォータ枯渇 — 非リトライ対象 (exit=${RC_EXIT_QUOTA_EXHAUSTED})。モデル切替か credits 追加が必要"
      fi
      # 失敗呼出でも消費したコストは記録する（部分出力のエンベロープから best-effort）
      _LAST_INPUT_TOKENS=0; _LAST_OUTPUT_TOKENS=0; _LAST_COST_USD="0"
      extract_cost_from_envelope "$_rc_raw_output" "$_rc_stage_name" "$model" 2>/dev/null || true
      rm -f "$_rc_dest" "$_rc_raw_output"
      run_claude_heartbeat "$_rc_stage_name" ""
      return "$exit_code"
    }
  fi

  run_claude_heartbeat "$_rc_stage_name" ""

  # ===== コスト/トークン抽出（エンベロープが唯一の実データ源 — rm より前に読む） =====
  _LAST_INPUT_TOKENS=0
  _LAST_OUTPUT_TOKENS=0
  _LAST_COST_USD="0"
  extract_cost_from_envelope "$_rc_raw_output" "$_rc_stage_name" "$model" 2>/dev/null || true

  # スキーマモード: エンベロープから structured_output を抽出
  if $_rc_use_schema; then
    local _rc_subtype
    _rc_subtype=$(jq -r '.subtype // "unknown"' "$_rc_raw_output" 2>/dev/null)
    if [ "$_rc_subtype" = "success" ]; then
      # structured_output を .pending に書き出す
      # 注意: structured_output が null の場合は jq が "null" を出力し有効JSONとして通過してしまう
      # → jq 'if . == null then error("null") ...' で null を明示的に弾く
      jq 'if .structured_output == null then error("structured_output is null") else .structured_output end' \
        "$_rc_raw_output" > "$_rc_target" 2>/dev/null
      if [ $? -ne 0 ] || [ ! -s "$_rc_target" ] || ! jq empty "$_rc_target" 2>/dev/null; then
        # structured_output 抽出失敗 or null → フォールバック: result フィールドを .pending に書き出す
        log "  ⚠ structured_output 抽出失敗、result フォールバック"
        jq -r '.result // empty' "$_rc_raw_output" > "$_rc_target" 2>/dev/null
      fi
    else
      # スキーマ検証失敗（error_max_structured_output_retries 等）→ result をフォールバック
      log "  ⚠ スキーマ検証失敗 (subtype=${_rc_subtype})、result フォールバック"
      jq -r '.result // empty' "$_rc_raw_output" > "$_rc_target" 2>/dev/null
    fi
    rm -f "$_rc_raw_output"
  else
    # 非スキーマ: エンベロープの .result（最終応答テキスト）を .pending に展開。
    # エンベロープでない場合（旧録画のリプレイ / 旧 CLI / フォールト注入ペイロード等）は
    # 生バイトをそのまま昇格する（後方互換 — 挙動差ゼロの安全弁）
    if jq -e 'has("result")' "$_rc_raw_output" >/dev/null 2>&1; then
      jq -r '.result // empty' "$_rc_raw_output" > "$_rc_target" 2>/dev/null
    else
      cp "$_rc_raw_output" "$_rc_target" 2>/dev/null || : > "$_rc_target"
    fi
    rm -f "$_rc_raw_output"
  fi

  # スキーマモードフラグを公開（validate_json → record_validation_stat に伝達）
  FORGE_SCHEMA_MODE="$_rc_use_schema"
  export FORGE_SCHEMA_MODE

  # フォールバック: エンベロープから取れなかった場合のみ debug ログを解析
  # （シミュレータ・リプレイの合成ログ経路を保持 — simulator.sh sim_emit_replay 参照）
  if [ "${_LAST_INPUT_TOKENS:-0}" -eq 0 ] && [ "${_LAST_OUTPUT_TOKENS:-0}" -eq 0 ]; then
    extract_cost_from_debug_log "$log_file" "$_rc_stage_name" "$model" 2>/dev/null || true
  fi
}

# ===== コスト追跡 =====
COSTS_FILE="${PROJECT_ROOT:-.}/.forge/state/costs.jsonl"

# モデル別単価表 ($/MTok input output)。出典: claude-api reference skill (cache 2026-06-24)
#   fable-5 10.0/50.0 | opus-5/4.x 5.0/25.0 | sonnet-5/4.x 3.0/15.0 | haiku(4.5) 1.0/5.0
# 注: 通常はエンベロープの total_cost_usd（CLI 自身の計算値・キャッシュ込み）が正であり、
#     この表は total_cost_usd が取れない場合の概算フォールバックにのみ使われる。
# 使い方: model_cost_rates <model> → stdout "IN OUT"; rc=1 なら未知モデル(sonnet 単価で概算)
model_cost_rates() {
  case "$1" in
    *fable*)  echo "10.0 50.0" ;;   # claude-fable-5
    *haiku*)  echo "1.0 5.0" ;;     # claude-haiku-4-5
    *sonnet*) echo "3.0 15.0" ;;    # claude-sonnet-5 / 4.x
    *opus*)   echo "5.0 25.0" ;;    # claude-opus-5 / 4.x（同額）
    *)        echo "3.0 15.0"; return 1 ;;
  esac
}

# run_claude の --output-format json エンベロープからコスト/トークンを抽出する。
# エンベロープが唯一の実データ源: CLI は usage をデバッグログに出力しない（2026-08-02 実測。
# 旧 debug ログ grep は 248 呼出全てで 0 を返し、コスト計とセッションブレーカーが死んでいた）。
# total_cost_usd は CLI 自身の計算値（プロンプトキャッシュ含む）を正とし、
# 無い場合のみ model_cost_rates で概算する。
# 成功時: _LAST_* グローバルを更新し costs.jsonl に追記。
# 使い方: extract_cost_from_envelope <envelope_file> <stage> <model>
extract_cost_from_envelope() {
  local env_file="$1"
  local stage="$2"
  local model="$3"

  [ -f "$env_file" ] || return 0
  [ -s "$env_file" ] || return 0

  local _ee_tsv
  _ee_tsv=$(jq -r '[(.usage.input_tokens // 0), (.usage.output_tokens // 0), (.total_cost_usd // 0)] | @tsv' \
    "$env_file" 2>/dev/null) || return 0
  [ -n "$_ee_tsv" ] || return 0

  local input_tokens output_tokens cost_usd
  IFS=$'\t' read -r input_tokens output_tokens cost_usd <<< "$_ee_tsv"
  case "$input_tokens" in (''|*[!0-9]*) input_tokens=0 ;; esac
  case "$output_tokens" in (''|*[!0-9]*) output_tokens=0 ;; esac
  case "$cost_usd" in (''|*[!0-9.]*) cost_usd=0 ;; esac

  # トークンもコストも取れない → エンベロープ経路は不成立（呼出側が debug ログへフォールバック）
  if [ "$input_tokens" -eq 0 ] && [ "$output_tokens" -eq 0 ]; then
    case "$cost_usd" in (0|0.0|0.00) return 0 ;; esac
  fi

  # total_cost_usd 不在（=0）だがトークンはある → 単価表で概算
  case "$cost_usd" in
    (0|0.0|0.00)
      local _ee_rates _ee_in_rate _ee_out_rate
      _ee_rates=$(model_cost_rates "$model") || true
      read -r _ee_in_rate _ee_out_rate <<< "$_ee_rates"
      cost_usd=$(awk "BEGIN { printf \"%.4f\", ($input_tokens * $_ee_in_rate + $output_tokens * $_ee_out_rate) / 1000000 }")
      case "$cost_usd" in (''|*[!0-9.]*) cost_usd=0 ;; esac
      ;;
  esac

  _LAST_INPUT_TOKENS=$input_tokens
  _LAST_OUTPUT_TOKENS=$output_tokens
  _LAST_COST_USD="$cost_usd"

  printf '{"stage":"%s","model":"%s","input_tokens":%d,"output_tokens":%d,"cost_usd":%s,"timestamp":"%s","source":"envelope"}\n' \
    "$stage" "$model" "$input_tokens" "$output_tokens" "$cost_usd" "$(date -Iseconds)" >> "$COSTS_FILE"
  return 0
}

# run_claude の debug ログからコスト情報を抽出
# 使い方: extract_cost_from_debug_log <log_file> <stage> <model>
extract_cost_from_debug_log() {
  local log_file="$1"
  local stage="$2"
  local model="$3"

  [ -f "$log_file" ] || return 0
  [ -s "$log_file" ] || return 0

  # debug ログから usage 情報を抽出（コロン後の空白を許容）
  local input_tokens output_tokens
  input_tokens=$(grep -oE '"input_tokens":[[:space:]]*[0-9]+' "$log_file" | tail -1 | grep -oE '[0-9]+' | tail -1 || echo 0)
  output_tokens=$(grep -oE '"output_tokens":[[:space:]]*[0-9]+' "$log_file" | tail -1 | grep -oE '[0-9]+' | tail -1 || echo 0)

  # トークン数が取得できなければスキップ
  if [ "$input_tokens" -eq 0 ] && [ "$output_tokens" -eq 0 ]; then
    return 0
  fi

  # コスト推定（per million tokens）
  local cost_usd="0" _ec_rates _ec_in_rate _ec_out_rate
  if ! _ec_rates=$(model_cost_rates "$model"); then
    # 未知モデル: sonnet 単価で概算（rc=1 でも fallback 単価は echo 済み）+ モデル毎に一度だけ警告
    case " ${_COST_UNKNOWN_MODEL_WARNED:-} " in
      *" $model "*) ;;
      *)
        echo "[COST] WARNING: unknown model '$model' — sonnet 単価でフォールバック（model_cost_rates に追加を検討）" >&2
        _COST_UNKNOWN_MODEL_WARNED="${_COST_UNKNOWN_MODEL_WARNED:-} $model"
        ;;
    esac
  fi
  read -r _ec_in_rate _ec_out_rate <<< "$_ec_rates"
  cost_usd=$(awk "BEGIN { printf \"%.4f\", ($input_tokens * $_ec_in_rate + $output_tokens * $_ec_out_rate) / 1000000 }")
  # awk 失敗等で数値でなければ 0 に矯正（不正 JSONL の発生機構を根絶）
  case "$cost_usd" in
    ''|*[!0-9.]*) cost_usd=0 ;;
  esac

  # グローバル変数を更新（metrics_record() が参照してメトリクスに記録する）
  _LAST_INPUT_TOKENS=$input_tokens
  _LAST_OUTPUT_TOKENS=$output_tokens
  _LAST_COST_USD="$cost_usd"

  # costs.jsonl に追記
  local entry
  entry=$(printf '{"stage":"%s","model":"%s","input_tokens":%d,"output_tokens":%d,"cost_usd":%s,"timestamp":"%s"}' \
    "$stage" "$model" "$input_tokens" "$output_tokens" "$cost_usd" "$(date -Iseconds)")
  echo "$entry" >> "$COSTS_FILE"
}

# ===== セッションコスト集計 =====
# session_id 別の cost_usd 合計を集計し返す。
# 使い方: aggregate_session_cost [session_id] [metrics_file]
# 出力: {"session_id": "xxx", "total_cost_usd": N.NN} 形式の JSON
aggregate_session_cost() {
  local session_id="${1:-${FORGE_SESSION_ID:-no-session}}"
  local metrics_file="${2:-${METRICS_FILE}}"

  if [ ! -f "$metrics_file" ] || [ ! -s "$metrics_file" ]; then
    jq -n --arg sid "$session_id" '{session_id: $sid, total_cost_usd: 0}'
    return 0
  fi

  tr -d '\r' < "$metrics_file" | jq -s --arg sid "$session_id" '
    map(select(.session_id == $sid)) |
    {
      session_id: $sid,
      total_cost_usd: (map(.cost_usd // 0) | add // 0)
    }
  '
}

# ===== bash -c ラッパー展開（2026-07 batch#8 Fix1） =====
# 実行層は task の validation コマンドを bash -c "cd '$WORK_DIR' && $cmd" で包むため、
# Planner が bash -c "…" で書いたコマンドは二重ラップになり、内側の \"$var\" を
# 外側シェルが先に解釈して壊れる（make-video v2 で 1 タスク 15 連続失敗の実害）。
# 生成時（sanitize_task_commands）と L1 実行ファネル（execute_layer1_test）で
# 同一の jq フィルタを使い unwrap する（定義が一つ = 生成/実行のドリフトなし）。
#
# unwrap 意味論:
#   - 先頭 `bash -c "…"` / `bash -c '…'` の【全文一致】のみ展開（^\s* 許容）
#   - 二重引用符版は内側の \" \\ \$ \` を bash 規則で unescape、単引用符版は逐語
#   - 曖昧なら不変: 後続トークン（bash -c "a" && b / bash -c "a" arg0）、
#     'a'\''b' 連結、非先頭（timeout 5 bash -c …）、閉じ引用符欠落
#   - 再帰展開（bash -c "bash -c \"x\"" → x）。毎回厳密に短くなるため停止する
#   - bash -lc / sh -c は対象外（Planner 規約外のため触らない）
read -r -d '' FORGE_JQ_UNWRAP_BASH_C <<'JQFILTER' || true
def _forge_unescape_dq: gsub("\\\\(?<c>[\"\\\\$`])"; "\(.c)");
def forge_unwrap_bash_c:
  if type != "string" then .
  elif test("^\\s*bash -c \"(?:[^\"\\\\]|\\\\.)*\"\\s*$") then
    (capture("^\\s*bash -c \"(?<inner>(?:[^\"\\\\]|\\\\.)*)\"\\s*$").inner
     | _forge_unescape_dq | forge_unwrap_bash_c)
  elif test("^\\s*bash -c '[^']*'\\s*$") then
    (capture("^\\s*bash -c '(?<inner>[^']*)'\\s*$").inner | forge_unwrap_bash_c)
  else . end;
JQFILTER

# unwrap_bash_c <command_string> — stdout に展開結果（失敗時は原文をそのまま返す）
unwrap_bash_c() {
  jq -nr --arg c "$1" "${FORGE_JQ_UNWRAP_BASH_C} \$c | forge_unwrap_bash_c" 2>/dev/null \
    || printf '%s' "$1"
}

# ===== Write ツール直接書き込みフォールバック =====
# Claude が stdout ではなく Write ツールで直接ファイルに書き込んだ場合の救済。
# run_claude は stdout を .pending にキャプチャするが、Write ツール経由の場合
# stdout にはマークダウンサマリーのみが出力され、validate_json が正しく拒否する。
# しかし実際の JSON は既に final_path に存在しているケースがある。
# 使い方: check_direct_write_fallback <final_path> <stage>
# 戻り値: 0=直接書き込み検出（利用可能）, 1=検出されず
check_direct_write_fallback() {
  local final_path="$1" stage="$2"
  if [ -f "$final_path" ] && [ -s "$final_path" ] && jq empty "$final_path" 2>/dev/null; then
    rm -f "${final_path}.failed" "${final_path}.pending" 2>/dev/null || true
    log "⚠ [fallback] ${stage}: stdout は非JSON だが ${final_path} への直接書き込みを検出"
    return 0
  fi
  return 1
}

# ===== JSON妥当性チェック =====
# Claude出力の自動正規化付き。3層リカバリ:
#   1. CRLF除去
#   2. コードフェンス除去
#   3. 前後の非JSONテキスト除去（最初の { から最後の } まで抽出）
validate_json() {
  local final_path="$1"
  local stage="$2"

  # Safe overwrite: run_claude が .pending に書き出した場合、そちらを検証する。
  # 成功時のみ本ファイルに昇格し、失敗時は既存ファイルを保全する。
  local file="$final_path"
  local _vj_pending=false
  if [ -f "${final_path}.pending" ]; then
    file="${final_path}.pending"
    _vj_pending=true
  fi

  # 成功時: .pending → 本ファイルに昇格
  _vj_promote() { $_vj_pending && mv "$file" "$final_path"; }
  # 失敗時: .pending を削除、既存ファイルはそのまま
  _vj_cleanup() { $_vj_pending && mv "$file" "${final_path}.failed" 2>/dev/null || true; }

  if [ ! -s "$file" ]; then
    record_error "$stage" "出力が空"
    record_validation_stat "$stage" "failed"
    log "✗ ${stage} 出力が空"
    json_fail_count=$((json_fail_count + 1))
    _vj_cleanup
    return 1
  fi

  # CRLF→LF正規化（Windows/Git Bash環境対応）
  tr -d '\r' < "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"

  # 既にJSONとして有効ならそのまま返す（CRLFのみで修復 or 元から正常）
  if jq empty "$file" 2>/dev/null; then
    record_validation_stat "$stage" "crlf"
    _vj_promote
    return 0
  fi

  # コードフェンス行を除去（```json / ```）
  if grep -qm1 '^```' "$file"; then
    grep -v '^```' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    log "  (コードフェンス除去: ${stage})"
  fi

  if jq empty "$file" 2>/dev/null; then
    resolve_errors "$stage" "recovered:fence_removal"
    record_validation_stat "$stage" "fence"
    notify_human "info" "JSON自動修復: ${stage} (コードフェンス除去)" ""
    _vj_promote
    return 0
  fi

  # Layer 3a: 行頭ブレース検出（精密 — 説明文中の { を誤検出しない）
  local first_brace last_brace
  first_brace=$(grep -n '^[[:space:]]*{' "$file" | head -1 | cut -d: -f1)
  last_brace=$(grep -n '^[[:space:]]*}' "$file" | tail -1 | cut -d: -f1)
  if [ -n "$first_brace" ] && [ -n "$last_brace" ] && [ "$first_brace" -le "$last_brace" ]; then
    sed -n "${first_brace},${last_brace}p" "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    log "  (JSON抽出: ${stage} — 行${first_brace}〜${last_brace})"
  fi

  if ! jq empty "$file" 2>/dev/null; then
    # Layer 3b: 任意位置ブレース検出（従来フォールバック）
    first_brace=$(grep -n '{' "$file" | head -1 | cut -d: -f1)
    last_brace=$(grep -n '}' "$file" | tail -1 | cut -d: -f1)
    if [ -n "$first_brace" ] && [ -n "$last_brace" ] && [ "$first_brace" -le "$last_brace" ]; then
      sed -n "${first_brace},${last_brace}p" "$file" > "${file}.tmp"
      mv "${file}.tmp" "$file"
      log "  (JSON抽出フォールバック: ${stage} — 行${first_brace}〜${last_brace})"
    fi
  fi

  if ! jq empty "$file" 2>/dev/null; then
    record_error "$stage" "出力が不正なJSON"
    record_validation_stat "$stage" "failed"
    log "✗ ${stage} 出力が不正なJSON"
    json_fail_count=$((json_fail_count + 1))
    _vj_cleanup
    return 1
  fi

  resolve_errors "$stage" "recovered:json_extraction"
  record_validation_stat "$stage" "extraction"
  notify_human "info" "JSON自動修復: ${stage} (JSON抽出)" ""
  _vj_promote
  return 0
}

# ===== エラー解決記録（B1: resolution 更新） =====
# 同一 stage + research_dir の未解決エラーに resolution を書き込む
resolve_errors() {
  local stage="$1"
  local resolution="$2"
  [ -f "$ERRORS_FILE" ] || return 0
  [ -s "$ERRORS_FILE" ] || return 0
  local research_dir="${RESEARCH_DIR:-unknown}"
  # jq で同一 stage/research_dir かつ resolution==null のエントリを更新
  local tmpfile="${ERRORS_FILE}.resolve.tmp"
  while IFS= read -r line; do
    local line_stage line_dir line_res
    line_stage=$(echo "$line" | jq_safe -r '.stage // ""' 2>/dev/null)
    line_dir=$(echo "$line" | jq_safe -r '.research_dir // ""' 2>/dev/null)
    line_res=$(echo "$line" | jq_safe -r '.resolution // "null"' 2>/dev/null)
    if [ "$line_stage" = "$stage" ] && [ "$line_dir" = "$research_dir" ] && [ "$line_res" = "null" ]; then
      echo "$line" | jq -c --arg r "$resolution" --arg ts "$(date -Iseconds)" \
        '.resolution = $r | .resolved_at = $ts'
    else
      echo "$line"
    fi
  done < "$ERRORS_FILE" > "$tmpfile"
  mv "$tmpfile" "$ERRORS_FILE"
}

# ===== エラーカテゴリ分類 =====
# 終了コード・メッセージパターンに基づき error_category を決定する（決定的ルール）
# 使い方: classify_error_category <message> [exit_code]
# 返値: timeout | rate_limit | invalid_json | empty_output | unknown
classify_error_category() {
  local message="${1:-}"
  local exit_code="${2:-}"

  # 1. timeout — 終了コード 124(timeoutコマンド) もタイムアウトを示す
  if [ -n "$exit_code" ] && [ "$exit_code" = "124" ]; then
    echo "timeout"; return
  fi
  # 1b. 終了コードで確定する分類（batch#11 R07a）。4.5f では kill（143）が "unknown" 4 件として
  #     記録され、失敗の原因が人間の停止だったことが台帳から読めなかった
  case "$exit_code" in
    143|130) echo "interrupted"; return ;;       # SIGTERM / SIGINT（人間の停止・forge-gtr stop）
    21) echo "budget_exceeded"; return ;;        # RC_EXIT_BUDGET_EXCEEDED（per-call 予算）
    22) echo "quota_exhausted"; return ;;        # RC_EXIT_QUOTA_EXHAUSTED
    125|126|127) echo "env_error"; return ;;     # コマンド不在 / 実行不能（timeout/claude/jq の欠落）
  esac
  # run_claude / 各 loop のログ文言は日本語（「タイムアウト（N秒）」）なので和語も拾う（batch#11: E1-2/E1-9 が HEAD で既に赤だった）
  if echo "$message" | grep -qi "timeout\|timed out\|タイムアウト"; then
    echo "timeout"; return
  fi

  # 2. quota_exhausted — モデル別クォータ枯渇（rate_limit より先に判定する）
  # 429 と違いリトライでは回復せず、モデル切替か credits 追加という人間の介入を要する。
  if echo "$message" | grep -qiE "reached your .{0,30}limit|quota.exhausted"; then
    echo "quota_exhausted"; return
  fi

  # 3. rate_limit — 429 / Too Many Requests / rate_limit / overloaded
  if echo "$message" | grep -qi "429\|too many requests\|rate.limit\|overloaded"; then
    echo "rate_limit"; return
  fi

  # 3. invalid_json — 不正なJSON / invalid json
  if echo "$message" | grep -qi "不正なjson\|invalid.json"; then
    echo "invalid_json"; return
  fi

  # 4. empty_output — が空 / empty
  if echo "$message" | grep -qi "が空\|empty"; then
    echo "empty_output"; return
  fi

  # 5. unknown（フォールバック）
  echo "unknown"
}

# ===== エラー記録 =====
# jqで安全にJSON生成。CRLF除去付き。
# 使い方: record_error <stage> <message> [exit_code]
#   exit_code: 省略可。124(timeout)等の終了コードがあれば分類精度が向上する。
record_error() {
  local stage="${1//$'\r'/}"
  local message="${2//$'\r'/}"
  local exit_code="${3:-}"
  local error_category
  error_category=$(classify_error_category "$message" "$exit_code")
  # exit_code は数値なら数値、それ以外は null（batch#11 R07a: 台帳から原因を追えるように）
  local _re_exit_json="null"
  case "$exit_code" in (''|*[!0-9]*) ;; (*) _re_exit_json="$exit_code" ;; esac
  jq -n -c \
    --arg stage "$stage" \
    --arg message "$message" \
    --arg research_dir "${RESEARCH_DIR:-unknown}" \
    --arg timestamp "$(date -Iseconds)" \
    --arg error_category "$error_category" \
    --arg session_id "${FORGE_SESSION_ID:-no-session}" \
    --arg call_id "${FORGE_CALL_ID:-0}" \
    --argjson exit_code "$_re_exit_json" \
    '{stage: $stage, message: $message, research_dir: $research_dir, timestamp: $timestamp, resolution: null, error_category: $error_category, session_id: $session_id, call_id: $call_id, exit_code: $exit_code}' \
    | tr -d '\r' >> "$ERRORS_FILE"
}

# ===== バリデーション統計記録（G2: validation-stats.jsonl） =====
VALIDATION_STATS_FILE="${PROJECT_ROOT:-.}/.forge/state/validation-stats.jsonl"

# リカバリ段階を記録: none(元から正常)/crlf/fence/extraction/failed
# was_schema_mode: run_claude() が --json-schema を使用したか（FORGE_SCHEMA_MODE グローバル変数から取得）
record_validation_stat() {
  local stage="$1"
  local recovery_level="$2"
  local _vsm_bool
  [ "${FORGE_SCHEMA_MODE:-false}" = "true" ] && _vsm_bool="true" || _vsm_bool="false"
  jq -n -c \
    --arg stage "$stage" \
    --arg recovery_level "$recovery_level" \
    --argjson was_schema_mode "$_vsm_bool" \
    --arg research_dir "${RESEARCH_DIR:-unknown}" \
    --arg timestamp "$(date -Iseconds)" \
    --arg session_id "${FORGE_SESSION_ID:-no-session}" \
    --arg call_id "${FORGE_CALL_ID:-0}" \
    '{stage: $stage, recovery_level: $recovery_level, was_schema_mode: $was_schema_mode, research_dir: $research_dir, timestamp: $timestamp, session_id: $session_id, call_id: $call_id}' \
    >> "$VALIDATION_STATS_FILE"
}

# ===== バリデーション統計集計（G2: aggregate_validation_stats） =====
# ステージ別のリカバリレベル集計（failed率を含む）
# 使い方: aggregate_validation_stats [stats_file]
# 出力: [{stage, total, failed, failed_rate}] 形式の JSON 配列
# 空データの場合は [] を返す
aggregate_validation_stats() {
  local stats_file="${1:-${VALIDATION_STATS_FILE}}"

  if [ ! -f "$stats_file" ] || [ ! -s "$stats_file" ]; then
    echo "[]"
    return 0
  fi

  tr -d '\r' < "$stats_file" | jq -s '
    if length == 0 then []
    else
      group_by(.stage) |
      map(
        . as $entries |
        ($entries | length) as $total |
        ($entries | map(select(.recovery_level == "failed")) | length) as $failed |
        {
          stage: $entries[0].stage,
          total: $total,
          failed: $failed,
          failed_rate: (if $total == 0 then 0 else ($failed / $total) end)
        }
      )
    end
  '
}

# ===== Lessons Learned（AnimaWorks Consolidation 概念の適用） =====
# 失敗パターンと解決策を蓄積し、次のタスクの Implementer プロンプトに注入する。
LESSONS_FILE="${PROJECT_ROOT:-.}/.forge/state/lessons-learned.jsonl"

# record_lesson <category> <pattern> <resolution> [source_task_id]
# category: test_framework | path_issue | timeout | hallucination | file_limit |
#           env_mismatch | task_definition | harness | cross_task | dependency | other
# （task_definition = Planner の契約/前提ミス, harness = ハーネス自身の欠陥,
#   cross_task = 真因が他タスク成果物 — batch#10 で自己誤診を分離）
record_lesson() {
  local category="${1:-other}"
  local pattern="${2:-}"
  local resolution="${3:-}"
  local source_task="${4:-}"

  [ -z "$pattern" ] && return 0

  # 重複チェック: 同じ pattern が既に存在するならスキップ
  if [ -f "$LESSONS_FILE" ] && grep -qF "\"pattern\":\"${pattern}\"" "$LESSONS_FILE" 2>/dev/null; then
    return 0
  fi

  jq -n -c \
    --arg cat "$category" \
    --arg pat "$pattern" \
    --arg res "$resolution" \
    --arg src "$source_task" \
    --arg ts "$(date -Iseconds)" \
    '{category: $cat, pattern: $pat, resolution: $res, source_task: $src, created_at: $ts}' \
    | tr -d '\r' >> "$LESSONS_FILE"
}

# get_relevant_lessons <task_json>
# タスクの L1 command と description からキーワードマッチで関連レッスンを抽出。
# 結果を stdout に出力（最大10件）。レッスンがなければ空文字。
get_relevant_lessons() {
  local task_json="$1"
  # Ablation guard
  [ "${ABLATION_LESSONS_ENABLED:-true}" != "true" ] && { echo ""; return 0; }
  [ -f "$LESSONS_FILE" ] || return 0
  [ -s "$LESSONS_FILE" ] || return 0

  local command=""
  command=$(echo "$task_json" | jq -r '.validation.layer_1.command // ""' 2>/dev/null | tr -d '\r')

  local results=""

  # カテゴリベースのフィルタ（L1 command からキーワード検出）
  if echo "$command" | grep -qiE 'vitest|jest|mocha|test'; then
    local fw_lessons=""
    fw_lessons=$(grep '"category":"test_framework"' "$LESSONS_FILE" 2>/dev/null | tail -3)
    [ -n "$fw_lessons" ] && results="${results}${fw_lessons}"$'\n'
  fi

  if echo "$command" | grep -qiE 'path|windows|tmp'; then
    local path_lessons=""
    path_lessons=$(grep '"category":"path_issue"' "$LESSONS_FILE" 2>/dev/null | tail -3)
    [ -n "$path_lessons" ] && results="${results}${path_lessons}"$'\n'
  fi

  # 直近のレッスンを最大5件追加（カテゴリ不問）
  local recent=""
  recent=$(tail -5 "$LESSONS_FILE" 2>/dev/null)
  [ -n "$recent" ] && results="${results}${recent}"$'\n'

  # 重複排除して最大10件に制限、人間可読フォーマットに変換
  echo "$results" | sort -u | head -10 | while IFS= read -r line; do
    [ -z "$line" ] && continue
    local pat="" res=""
    pat=$(echo "$line" | jq -r '.pattern // ""' 2>/dev/null | tr -d '\r')
    res=$(echo "$line" | jq -r '.resolution // ""' 2>/dev/null | tr -d '\r')
    [ -z "$pat" ] && continue
    echo "- ${pat} → ${res}"
  done
}

# ===== タスクイベントソーシング（AnimaWorks event sourcing 概念の適用） =====
# task-stack.json（canonical state）はそのまま維持し、追記専用のイベントログを併設する（write-through）。
TASK_EVENTS_FILE="${PROJECT_ROOT:-.}/.forge/state/task-events.jsonl"

# record_task_event <task_id> <event_type> [detail_json]
# event_type: status_changed | fail_recorded | investigator_invoked |
#             lesson_recorded | checkpoint_created | checkpoint_restored |
#             task_passed | task_started | heartbeat
record_task_event() {
  local task_id="$1"
  local event_type="$2"
  local _empty_obj='{}'
  local detail="${3:-$_empty_obj}"

  # timestamp は UTC 固定（監査 C-7）: task-stack の created_at/updated_at は
  # jq (now|todate) の UTC であり、ローカルオフセット混在だと
  # detect_reworked_tasks の文字列比較が時系列比較として壊れる
  jq -n -c \
    --arg tid "$task_id" \
    --arg evt "$event_type" \
    --argjson det "$detail" \
    --arg ts "$(date -u -Iseconds)" \
    --arg ses "${RESEARCH_DIR:-unknown}" \
    --arg session_id "${FORGE_SESSION_ID:-no-session}" \
    '{task_id: $tid, event: $evt, detail: $det, timestamp: $ts, session: $ses, session_id: $session_id}' \
    | tr -d '\r' >> "$TASK_EVENTS_FILE" 2>/dev/null || true
}

# ===== メトリクス記録（G1: metrics.jsonl） =====
METRICS_FILE="${PROJECT_ROOT:-.}/.forge/state/metrics.jsonl"

# ステージ開始時刻を記録（エポック秒）
metrics_start() {
  _METRICS_START_EPOCH=$(date +%s)
}

# ステージ終了後にメトリクスを追記
# 使い方: metrics_record <stage> <parse_success:true|false> [extra_field_json]
# token/cost フィールドは run_claude() → extract_cost_from_debug_log() が設定した
# グローバル変数 _LAST_INPUT_TOKENS / _LAST_OUTPUT_TOKENS / _LAST_COST_USD から取得する。
# 抽出失敗時は各フィールドが 0 のフォールバック値となる。
metrics_record() {
  local stage="$1"
  local parse_success="${2:-true}"
  local extra="${3:-}"
  local end_epoch
  end_epoch=$(date +%s)
  local duration=$(( end_epoch - ${_METRICS_START_EPOCH:-$end_epoch} ))

  # token/cost 情報（run_claude() → extract_cost_from_debug_log() 経由のグローバル変数から取得）
  local _m_input_tokens="${_LAST_INPUT_TOKENS:-0}"
  local _m_output_tokens="${_LAST_OUTPUT_TOKENS:-0}"
  local _m_cost_usd="${_LAST_COST_USD:-0}"
  # 読み取り後にリセット（次の呼出がゼロフォールバックを持つよう保証）
  _LAST_INPUT_TOKENS=0
  _LAST_OUTPUT_TOKENS=0
  _LAST_COST_USD="0"

  local entry
  entry=$(jq -n -c \
    --arg stage "$stage" \
    --argjson duration "$duration" \
    --argjson parse_success "$parse_success" \
    --arg research_dir "${RESEARCH_DIR:-unknown}" \
    --arg timestamp "$(date -Iseconds)" \
    --arg session_id "${FORGE_SESSION_ID:-no-session}" \
    --arg call_id "${FORGE_CALL_ID:-0}" \
    --arg input_tokens "${_m_input_tokens}" \
    --arg output_tokens "${_m_output_tokens}" \
    --arg cost_usd "${_m_cost_usd}" \
    '{stage: $stage, duration_sec: $duration, parse_success: $parse_success, research_dir: $research_dir, timestamp: $timestamp, session_id: $session_id, call_id: $call_id, input_tokens: ($input_tokens | tonumber), output_tokens: ($output_tokens | tonumber), cost_usd: ($cost_usd | tonumber)}')
  if [ -n "$extra" ]; then
    entry=$(echo "$entry" | jq -c ". + $extra" 2>/dev/null || echo "$entry")
  fi
  echo "$entry" >> "$METRICS_FILE"
}

# ===== コマンド依存チェック =====
# 使い方: check_dependencies claude jq md5sum timeout
check_dependencies() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${RED}[ERROR] $cmd が見つかりません。インストールしてください。${NC}" >&2
      exit 1
    fi
  done
}

# ===== 人間通知 =====
NOTIFY_DIR="${PROJECT_ROOT:-.}/.forge/state/notifications"

notify_human() {
  local level="$1"
  local message="$2"
  local detail="${3:-}"

  mkdir -p "$NOTIFY_DIR"
  local notify_id="n-$(date +%Y%m%d-%H%M%S)"
  local notify_file="${NOTIFY_DIR}/${notify_id}.json"

  jq -n -c \
    --arg id "$notify_id" \
    --arg level "$level" \
    --arg message "$message" \
    --arg detail "$detail" \
    --arg timestamp "$(date -Iseconds)" \
    --arg acknowledged "false" \
    '{id: $id, level: $level, message: $message, detail: $detail, timestamp: $timestamp, acknowledged: $acknowledged}' \
    > "$notify_file"

  case "$level" in
    "critical")
      echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════╗${NC}" >&2
      echo -e "${RED}${BOLD}║ ⚠ CRITICAL: ${message}${NC}" >&2
      echo -e "${RED}${BOLD}╚══════════════════════════════════════════╝${NC}" >&2
      ;;
    "warning")
      echo -e "\n${YELLOW}${BOLD}⚠ WARNING: ${message}${NC}" >&2
      ;;
    "info")
      echo -e "${DIM}[INFO] ${message}${NC}" >&2
      ;;
  esac

  [ -n "$detail" ] && echo -e "  ${detail}" >&2

  # ベル音は critical/warning のみ
  [ "$level" != "info" ] && echo -ne '\a' >&2

  log "通知記録: ${notify_file}"
}

# ===== 対象プロジェクト Git 安全チェック =====
# 作業ディレクトリの git 状態を検証し、未コミット変更による損失を防止する。
# 使い方: safe_work_dir_check <work_dir>
# 戻り値: 0=OK, 1=ERROR（実行を停止すべき）
# ===== 自己書込み判定（batch#11 R20a） =====
# work_dir がハーネス（project_root）自身・その配下・その親なら 0（= 自己書込み、拒否すべき）。
# それ以外・判定不能（不在ディレクトリ）は 1。比較は実パス（pwd -P）+ Windows は cygpath -ml + 小文字。
# 背景: --work-dir 未指定はハーネス自身へ生成する挙動で、checkpoint / ファイル数 / 聖域 / ERR trap /
# auto-revert の 5 経路が `[ "$WORK_DIR" != "$PROJECT_ROOT" ]` で全て無効になる。
work_dir_is_self_write() {
  local wd="${1:-}" root="${2:-}" a b
  [ -n "$wd" ] && [ -n "$root" ] || return 1
  a=$(cd "$wd" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  if command -v cygpath >/dev/null 2>&1; then
    a=$(cygpath -ml -- "$a" 2>/dev/null || printf '%s' "$a")
    b=$(cygpath -ml -- "$b" 2>/dev/null || printf '%s' "$b")
  fi
  a="${a,,}"; b="${b,,}"
  [ "$a" = "$b" ] && return 0
  case "$a" in "$b"/*) return 0 ;; esac
  case "$b" in "$a"/*) return 0 ;; esac
  return 1
}

safe_work_dir_check() {
  local work_dir="$1"

  # 0. ハーネス自身への書込を拒否（batch#11 R20a）
  if work_dir_is_self_write "$work_dir" "${PROJECT_ROOT:-.}"; then
    log "✗ [SAFETY] 作業ディレクトリがハーネス自身（またはその配下/親）です: ${work_dir}"
    notify_human "critical" "作業ディレクトリがハーネス自身" \
      "パス: ${work_dir}\nハーネス外の独立した git リポジトリを --work-dir に指定してください"
    return 1
  fi

  # 1. git リポジトリであることを確認
  if ! git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    log "✗ [SAFETY] ${work_dir} は git リポジトリではありません"
    notify_human "critical" "作業ディレクトリが git リポジトリではない" \
      "パス: ${work_dir}\ngit init するか、正しいディレクトリを指定してください"
    return 1
  fi

  # 2. 未ステージ変更チェック（Modified/Deleted）
  local staged_changes
  staged_changes=$(git -C "$work_dir" status --porcelain 2>/dev/null | grep -E '^[ MADRCU][MD]' || true)
  if [ -n "$staged_changes" ]; then
    local change_count
    change_count=$(echo "$staged_changes" | wc -l | tr -d ' ')
    log "✗ [SAFETY] 未コミットの変更が ${change_count} 件あります"
    notify_human "critical" "未コミット変更を検出 — 先に git commit/stash してください" \
      "変更ファイル数: ${change_count}\nパス: ${work_dir}\n先頭5件:\n$(echo "$staged_changes" | head -5)"
    return 1
  fi

  # 3. 未追跡ファイルチェック
  local untracked
  untracked=$(git -C "$work_dir" status --porcelain 2>/dev/null | grep -E '^\?\?' || true)
  if [ -n "$untracked" ]; then
    local untracked_count
    untracked_count=$(echo "$untracked" | wc -l | tr -d ' ')
    if [ "$untracked_count" -gt 10 ]; then
      log "✗ [SAFETY] 未追跡ファイルが ${untracked_count} 件（上限: 10）"
      notify_human "critical" "大量の未追跡ファイルを検出" \
        "件数: ${untracked_count}\nパス: ${work_dir}\ngit add + commit するか、.gitignore に追加してください"
      return 1
    else
      log "⚠ [SAFETY] 未追跡ファイル ${untracked_count} 件（許容範囲）"
    fi
  fi

  # 4. ブランチ確認（main/master 上なら WARNING）
  local current_branch
  current_branch=$(git -C "$work_dir" branch --show-current 2>/dev/null || echo "")
  if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    log "⚠ [SAFETY] ${current_branch} ブランチ上で作業中（推奨: feature branch）"
    notify_human "warning" "${current_branch} ブランチで実行中" \
      "推奨: feature branch での作業を推奨します"
  fi

  log "✓ [SAFETY] 作業ディレクトリ安全チェック通過: ${work_dir}"
  return 0
}

# ===== タスク単位 Git Checkpoint =====
CHECKPOINT_DIR="${PROJECT_ROOT:-.}/.forge/state/checkpoints"

# タスク実行前のスナップショットを保存する（diff + untracked リスト）
# 使い方: task_checkpoint_create <work_dir> <task_id>
task_checkpoint_create() {
  local work_dir="$1"
  local task_id="$2"
  local first_attempt="${3:-0}"

  mkdir -p "$CHECKPOINT_DIR"

  # git リポジトリでなければスキップ
  if ! git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    log "  [CHECKPOINT] ${work_dir} は git リポジトリではない — スキップ"
    return 0
  fi

  # tracked ファイルの差分を保存
  local patch_file="${CHECKPOINT_DIR}/${task_id}.patch"
  git -C "$work_dir" diff HEAD > "$patch_file" 2>/dev/null || true

  # untracked ファイルのリストを保存
  local untracked_file="${CHECKPOINT_DIR}/${task_id}.untracked"
  git -C "$work_dir" ls-files --others --exclude-standard > "$untracked_file" 2>/dev/null || true

  # HEAD の commit hash を保存（attempt 開始点。毎 attempt 上書き）
  local ref_file="${CHECKPOINT_DIR}/${task_id}.ref"
  git -C "$work_dir" rev-parse HEAD > "$ref_file" 2>/dev/null || true

  # タスク基準 SHA（batch#11 R03/R05）: 初回 attempt（fail_count==0 かつ qa_fail_count==0）でのみ書く。
  # Implementer が Bash で commit できるようになると HEAD 基準の事後ゲート（変更数 / 聖域 / QA diff）は
  # commit 済み変更を見落とすため、タスク開始時点の SHA を累積判定の基準にする。
  if [ "$first_attempt" = "1" ]; then
    git -C "$work_dir" rev-parse HEAD > "${CHECKPOINT_DIR}/${task_id}.base_ref" 2>/dev/null || true
  fi

  log "  [CHECKPOINT] タスク ${task_id} のスナップショット作成完了"
  return 0
}

# タスクの基準 SHA を返す（.base_ref → .ref → HEAD の順。無効な SHA は飛ばす）
# 使い方: base=$(task_base_ref <task_id> <work_dir>)
task_base_ref() {
  local task_id="$1" work_dir="$2" f sha
  for f in "${CHECKPOINT_DIR}/${task_id}.base_ref" "${CHECKPOINT_DIR}/${task_id}.ref"; do
    [ -s "$f" ] || continue
    sha=$(tr -d '\r\n' < "$f")
    if [ -n "$sha" ] && git -C "$work_dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      printf '%s' "$sha"
      return 0
    fi
  done
  printf '%s' "HEAD"
  return 0
}

# タスク失敗・暴走時に対象プロジェクトを「チェックポイント時点」の状態に復帰する
# 使い方: task_checkpoint_restore <work_dir> <task_id> [do_salvage=1]
#
# batch#10 Stage2: 旧実装は checkout -- . で HEAD まで全消しし .patch を一度も読まなかった（死配線）。
#   1. 復帰前に「今回試行の全 diff」を .salvage.patch へ退避（次試行プロンプトに注入）
#   2. 復帰後に .patch を git apply して checkpoint 時点の状態へ正しく戻す
# batch#11 R03（監査 2026-09-02）: 「ハーネスは作業ツリーを消さない」
#   - 4.5f ラン: .untracked が 26/28 で空だったため未追跡削除ブロックが「新規ファイル全削除」として働き、
#     L1 合格済みの成果物 5 件（diff 953〜5,285 行）を破壊。Investigator 3/3 が「ハーネスが消した」と診断。
#   - 未追跡の新規ファイルは削除せず ${CHECKPOINT_DIR}/<task>.quarantine/ へ退避する（git clean は使わない）
#   - attempt 内で Implementer が commit していた場合は .ref（attempt 開始 SHA）へ reset --mixed で巻き戻す
#     （作業ツリーは保持 → その後の checkout/quarantine で checkpoint 時点へ）
# do_salvage=0 は best-of-N の候補間リセット用（候補破棄は損失ではないため退避しない）
task_checkpoint_restore() {
  local work_dir="$1"
  local task_id="$2"
  local do_salvage="${3:-1}"

  # git リポジトリでなければスキップ
  if ! git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    log "  [CHECKPOINT] ${work_dir} は git リポジトリではない — 復帰スキップ"
    return 1
  fi

  local untracked_file="${CHECKPOINT_DIR}/${task_id}.untracked"
  local patch_file="${CHECKPOINT_DIR}/${task_id}.patch"
  local salvage_file="${CHECKPOINT_DIR}/${task_id}.salvage.patch"
  local quarantine_dir="${CHECKPOINT_DIR}/${task_id}.quarantine"

  # attempt 開始時の SHA（.ref）。無効なら HEAD 基準にフォールバック
  local ref_sha=""
  if [ -s "${CHECKPOINT_DIR}/${task_id}.ref" ]; then
    ref_sha=$(tr -d '\r\n' < "${CHECKPOINT_DIR}/${task_id}.ref")
    git -C "$work_dir" cat-file -e "${ref_sha}^{commit}" 2>/dev/null || ref_sha=""
  fi

  # 0. 今回試行の変更を退避（untracked も intent-to-add で diff に載せる。attempt 内 commit も含める）
  if [ "$do_salvage" = "1" ]; then
    git -C "$work_dir" add --intent-to-add -A 2>/dev/null || true
    git -C "$work_dir" diff "${ref_sha:-HEAD}" > "$salvage_file" 2>/dev/null || true
    git -C "$work_dir" reset -q 2>/dev/null || true
    [ -s "$salvage_file" ] || rm -f "$salvage_file" 2>/dev/null || true
  fi

  # 1. attempt 内の commit を巻き戻す（作業ツリーは保持）→ tracked ファイルを attempt 開始点に復帰
  if [ -n "$ref_sha" ]; then
    local head_sha
    head_sha=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null | tr -d '\r\n')
    if [ -n "$head_sha" ] && [ "$head_sha" != "$ref_sha" ]; then
      log "  [CHECKPOINT] attempt 内の commit を巻き戻し（${head_sha:0:7} → ${ref_sha:0:7}）。内容は .salvage.patch と quarantine に残る"
      git -C "$work_dir" reset -q --mixed "$ref_sha" 2>/dev/null || true
    fi
  fi
  git -C "$work_dir" checkout -- . 2>/dev/null || true

  # 2. checkpoint 時に存在しなかった未追跡ファイルは削除せず quarantine へ退避（batch#11 R03）
  local current_untracked moved=0
  current_untracked=$(git -C "$work_dir" ls-files --others --exclude-standard 2>/dev/null || true)
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # checkpoint 時のリストに含まれていれば元から存在した未追跡 → 触らない
    if [ -f "$untracked_file" ] && grep -qxF "$file" "$untracked_file" 2>/dev/null; then
      continue
    fi
    if mkdir -p "${quarantine_dir}/$(dirname "$file")" 2>/dev/null && \
       mv -f "${work_dir}/${file}" "${quarantine_dir}/${file}" 2>/dev/null; then
      moved=$((moved + 1))
    fi
  done <<< "$current_untracked"
  if [ "$moved" -gt 0 ]; then
    log "  [CHECKPOINT] 未追跡ファイル ${moved} 件を削除せず退避: ${quarantine_dir}"
  fi

  # 3. チェックポイント時点の未コミット改変（.patch）を再適用
  #    （HEAD への全消しではなく「タスク開始時点」への復帰にする — 先行改変の保全）
  if [ -s "$patch_file" ]; then
    if git -C "$work_dir" apply --whitespace=nowarn "$patch_file" 2>/dev/null; then
      log "  [CHECKPOINT] チェックポイント時点の先行改変（.patch）を復元"
    else
      log "  ⚠ [CHECKPOINT] .patch の再適用に失敗 — HEAD 状態のまま続行（先行改変が失われた可能性）"
      if type record_quality_debt &>/dev/null; then
        record_quality_debt "checkpoint_patch_apply_failed" "$task_id" \
          "checkpoint .patch の再適用に失敗 — チェックポイント時点の先行改変が復元できなかった"
      fi
    fi
  fi

  # 可視化: 復帰で作業ツリーが空になったのに salvage が非空 = 今回試行の成果は quarantine/salvage にだけ残る
  if [ -s "$salvage_file" ] && [ -z "$(git -C "$work_dir" status --porcelain 2>/dev/null)" ]; then
    log "  [CHECKPOINT] 復帰後の作業ツリーは checkpoint と同一。今回試行の成果は .salvage.patch（次試行に注入）と quarantine に保全"
  fi

  log "  [CHECKPOINT] タスク ${task_id} の状態を復帰しました"
  return 0
}


# ===== fnmatch 風パターン照合 =====
# fnmatch_to_regex / match_protected_pattern は .forge/lib/patterns.sh に移設（batch#11 R05）。
# PreToolUse deny hook（.claude/hooks/forge-guard.sh）が事後ゲートと同じ照合意味論を共有するため。
# common.sh の冒頭（simulator.sh / validation-dsl.sh の直後）で guarded source している。

# ===== 変更ファイル数バリデーション =====
# Implementer 実行後に呼び出し、変更ファイル数がリミットを超えていないか検証する。
# ハードリミット超過時は自動ロールバック（S3 と連携）。
# 使い方: validate_task_changes <work_dir> <task_id> [soft_limit] [hard_limit]
# 戻り値: 0=OK, 1=ハードリミット超過（復帰済み）, 2=ソフトリミット超過（続行）
validate_task_changes() {
  local work_dir="$1"
  local task_id="$2"
  local soft_limit="${3:-5}"
  local hard_limit="${4:-10}"

  # git リポジトリでなければスキップ
  if ! git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    return 0
  fi

  # 変更ファイル数を集計。基準は HEAD ではなくタスク基準 SHA（.base_ref → .ref → HEAD、batch#11 R03/R05）:
  # Implementer が Bash で commit できるようになると HEAD 基準では commit 済み変更が見えなくなる。
  local _vc_base="HEAD"
  if type task_base_ref &>/dev/null; then
    _vc_base=$(task_base_ref "$task_id" "$work_dir")
  fi
  local changed_files
  changed_files=$(git -C "$work_dir" diff --name-only "$_vc_base" 2>/dev/null || true)
  local new_files
  new_files=$(git -C "$work_dir" ls-files --others --exclude-standard 2>/dev/null || true)
  # 同一ファイルの二重計上防止（diff に A で現れた新規ファイルと untracked の和集合）
  new_files=$(printf '%s\n' "$new_files" | grep -vxF -f <(printf '%s\n' "$changed_files") 2>/dev/null || true)

  # checkpoint ベースライン（タスク開始時点で既に存在した未コミット改変/untracked）は
  # このタスクの変更としてカウントしない（batch#10 Stage2）。
  # .patch 再適用復帰の導入で先行改変が試行を跨いで持ち越されるため、旧カウントでは
  # 他タスク由来の改変がリミットを食い潰し「超過→全消し→同一壁」の閉ループになる
  local baseline_files=""
  local _vc_patch="${CHECKPOINT_DIR}/${task_id}.patch"
  local _vc_untracked="${CHECKPOINT_DIR}/${task_id}.untracked"
  [ -s "$_vc_patch" ] && baseline_files=$(grep -E '^diff --git ' "$_vc_patch" 2>/dev/null | sed 's|^diff --git a/||; s| b/.*$||' || true)
  if [ -s "$_vc_untracked" ]; then
    baseline_files="${baseline_files}
$(cat "$_vc_untracked" 2>/dev/null)"
  fi
  baseline_files=$(printf '%s\n' "$baseline_files" | grep -v '^$' || true)
  if [ -n "$baseline_files" ]; then
    changed_files=$(printf '%s\n' "$changed_files" | grep -vxF -f <(printf '%s\n' "$baseline_files") 2>/dev/null || true)
    new_files=$(printf '%s\n' "$new_files" | grep -vxF -f <(printf '%s\n' "$baseline_files") 2>/dev/null || true)
  fi

  local changed_count=0 new_count=0
  [ -n "$changed_files" ] && changed_count=$(echo "$changed_files" | wc -l | tr -d ' ')
  [ -n "$new_files" ] && new_count=$(echo "$new_files" | wc -l | tr -d ' ')
  local total=$((changed_count + new_count))

  # 保護パターンチェック（S6: circuit-breaker.json の protected_patterns）
  local cb_config="${PROJECT_ROOT:-.}/.forge/config/circuit-breaker.json"
  if [ -f "$cb_config" ]; then
    local protected_patterns
    protected_patterns=$(jq_safe -r '.protected_patterns[]? // empty' "$cb_config" 2>/dev/null)
    if [ -n "$protected_patterns" ]; then
      local all_changed
      all_changed=$(printf '%s\n%s' "$changed_files" "$new_files" | grep -v '^$' || true)
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        # 照合は match_protected_pattern に一元化（batch#10 Stage2）:
        # '/' 含み（dir/**）はルート起点、'/' なし（.env* / *.lock）は任意階層ベース名
        # — 後者は旧実装のルート限定より広がり、サブディレクトリの .env/.lock も保護される
        local matched=""
        local _vc_file
        while IFS= read -r _vc_file; do
          [ -z "$_vc_file" ] && continue
          if match_protected_pattern "$_vc_file" "$pattern"; then
            matched="${matched}${matched:+
}${_vc_file}"
          fi
        done <<< "$all_changed"
        if [ -n "$matched" ]; then
          log "✗ [SAFETY] 保護ファイルの変更を検出: ${matched}"
          notify_human "critical" "タスク ${task_id}: 保護ファイルの変更検出" \
            "パターン: ${pattern}\nマッチ:\n${matched}"
          task_checkpoint_restore "$work_dir" "$task_id"
          return 1
        fi
      done <<< "$protected_patterns"
    fi
  fi

  # ハードリミットチェック
  if [ "$total" -gt "$hard_limit" ]; then
    log "✗ [SAFETY] タスク ${task_id} が ${total} ファイルを変更（ハードリミット: ${hard_limit}）"
    notify_human "critical" "タスク ${task_id}: 変更ファイル数上限超過" \
      "変更: ${changed_count} / 新規: ${new_count} / 合計: ${total}（上限: ${hard_limit}）\n自動ロールバック実行"
    task_checkpoint_restore "$work_dir" "$task_id"
    return 1
  fi

  # ソフトリミットチェック
  if [ "$total" -gt "$soft_limit" ]; then
    log "⚠ [SAFETY] タスク ${task_id} が ${total} ファイルを変更（推奨上限: ${soft_limit}）"
    return 2
  fi

  return 0
}

# ===== テスト聖域化（reward hacking 予防層） =====
# 「タスク開始時点で既存」= HEAD に追跡されているテストファイルの改変/削除をブロックする。
# per-task auto-commit により HEAD ≈ タスク初回 attempt 開始時点。同一タスク内で
# 新規作成されたテスト（untracked）は diff HEAD に現れないため自然に許容される
# （Implementer/Fixer の本業を妨げない）。
# task JSON の allows_test_edits=true で個別解除（l2fix/l3fix 等テスト修正が正当なタスク用）。
# パターン照合は match_protected_pattern（batch#10 で protected_patterns と意味統一）:
# '/' なしパターン（*.test.* 等）は任意階層ベース名、'/' 含み（tests/**）はルート起点。
# 深層の規約ディレクトリは設定側で **/__tests__/** と明示する。
# 使い方: validate_test_sanctity <work_dir> <task_id> <task_json>
# 戻り値: 0=OK, 1=違反（呼出側で checkpoint restore + handle_task_fail すること）
validate_test_sanctity() {
  local work_dir="$1"
  local task_id="$2"
  local task_json="${3:-}"

  local cb_config="${PROJECT_ROOT:-.}/.forge/config/circuit-breaker.json"
  [ -f "$cb_config" ] || return 0
  local ts_enabled
  ts_enabled=$(jq_safe -r '.test_sanctity.enabled // false' "$cb_config" 2>/dev/null)
  [ "$ts_enabled" = "true" ] || return 0

  # escape hatch: テスト修正が明示的に許可されたタスク
  local allows
  allows=$(echo "$task_json" | jq_safe -r '.allows_test_edits // false' 2>/dev/null)
  if [ "$allows" = "true" ]; then
    log "  [SANCTITY] タスク ${task_id}: allows_test_edits=true — 既存テスト改変を許可"
    return 0
  fi

  git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1 || return 0

  local patterns
  patterns=$(jq_safe -r '.test_sanctity.protected_test_patterns[]? // empty' "$cb_config" 2>/dev/null)
  [ -n "$patterns" ] || return 0

  # 基準はタスク基準 SHA（.base_ref → .ref → HEAD、batch#11）: attempt 内で commit された既存テストの
  # 改変も検出する。基準時点に存在しなかった新規テスト（untracked / 新規 commit）は自然に許容される
  local _ts_base="HEAD"
  if type task_base_ref &>/dev/null; then
    _ts_base=$(task_base_ref "$task_id" "$work_dir")
  fi
  local changed
  changed=$(git -C "$work_dir" diff --name-only "$_ts_base" 2>/dev/null || true)
  [ -n "$changed" ] || return 0

  local violations=""
  local pattern f
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      # 照合は match_protected_pattern に一元化（batch#10 Stage2 — 旧 ^(.*/)?  の
      # 任意階層プレフィックスは tests/** をフィクスチャ生成器まで誤爆させていた）
      if match_protected_pattern "$f" "$pattern"; then
        # 基準 SHA に存在する（=タスク開始時点で既存）ことを確認
        if git -C "$work_dir" cat-file -e "${_ts_base}:${f}" 2>/dev/null; then
          violations="${violations}${f} (pattern: ${pattern})
"
        fi
      fi
    done <<< "$changed"
  done <<< "$patterns"

  if [ -n "$violations" ]; then
    log "  ✗ [SANCTITY] タスク ${task_id}: 既存テストファイルの改変を検出"
    notify_human "critical" "タスク ${task_id}: 既存テスト改変（reward hacking 疑い）" \
      "以下の既存テストが変更/削除されました（allows_test_edits 未設定）:\n${violations}"
    return 1
  fi
  return 0
}

# ===== dev-phase テストスクリプトのスナップショット/検証 =====
# phase-tests は WORK_DIR 外（ハーネス所有物）のため git checkpoint では保護できない。
# タスク開始時に全 .sh をバックアップし、検証時に cmp 照合・改変検出時は復元する。
# 使い方: snapshot_phase_tests <task_id>（task_prepare から）
snapshot_phase_tests() {
  local task_id="$1"
  [ -n "${CHECKPOINT_DIR:-}" ] || return 0
  local pt_dir="${PROJECT_ROOT:-.}/.forge/state/phase-tests"
  local bk_dir="${CHECKPOINT_DIR}/${task_id}.phasetests"
  rm -rf "$bk_dir"
  ls "${pt_dir}/"*.sh >/dev/null 2>&1 || return 0
  mkdir -p "$bk_dir"
  cp "${pt_dir}/"*.sh "$bk_dir/" 2>/dev/null || true
  return 0
}

# 使い方: verify_phase_tests_integrity <task_id>
# 戻り値: 0=OK（またはスナップショット不在）, 1=改変検出（バックアップから復元済み）
verify_phase_tests_integrity() {
  local task_id="$1"
  [ -n "${CHECKPOINT_DIR:-}" ] || return 0
  local pt_dir="${PROJECT_ROOT:-.}/.forge/state/phase-tests"
  local bk_dir="${CHECKPOINT_DIR}/${task_id}.phasetests"
  [ -d "$bk_dir" ] || return 0
  local tampered=0
  local f base
  for f in "$bk_dir"/*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    if ! cmp -s "$f" "${pt_dir}/${base}" 2>/dev/null; then
      tampered=1
      cp "$f" "${pt_dir}/${base}" 2>/dev/null || true
    fi
  done
  if [ "$tampered" -eq 1 ]; then
    log "  ✗ [SANCTITY] dev-phase テストスクリプトの改変を検出 — バックアップから復元"
    return 1
  fi
  return 0
}

# ===== Implementer 自己定位コンテキスト（純関数・LLM 呼出なし） =====
# フレッシュコンテキスト方式の失敗モード（過剰野心・重複実装・早すぎる完了宣言）対策として、
# 「直近 git log + タスク進捗」をタスク/attempt ごとに fresh 生成してプロンプト注入する。
# priming（起動時1回キャッシュ）に入れると全タスク同一の古い情報になるため、
# 必ず build_implementer_prompt（毎 attempt 実行）から呼ぶこと。
# 使い方: build_orientation_context <work_dir> <task_stack_file>
# 出力: 自己定位ブロック（git 不在かつ task-stack 不正なら空文字 + return 0）
build_orientation_context() {
  local work_dir="$1"
  local task_stack="${2:-}"
  local recent="" done_count="" total="" recent_titles=""

  if git -C "$work_dir" rev-parse --git-dir > /dev/null 2>&1; then
    recent=$(git -C "$work_dir" log --oneline -5 2>/dev/null || true)
  fi
  if [ -n "$task_stack" ] && [ -f "$task_stack" ] && jq empty "$task_stack" 2>/dev/null; then
    done_count=$(jq '[.tasks[]? | select(.status == "completed")] | length' "$task_stack" 2>/dev/null | tr -d '\r')
    total=$(jq '.tasks | length' "$task_stack" 2>/dev/null | tr -d '\r')
    recent_titles=$(jq_safe -r '[.tasks[]? | select(.status == "completed")]
      | sort_by(.updated_at // "") | reverse | .[0:3][]
      | "- \(.task_id): \((.description // "")[0:60])"' "$task_stack" 2>/dev/null || true)
  fi

  if [ -z "$recent" ] && [ -z "$done_count" ]; then
    return 0
  fi

  printf '## 現在地（自動生成 — Orientation）\n進捗: %s/%s タスク完了\n直近完了タスク:\n%s\n\n直近コミット (git log --oneline -5):\n%s\n' \
    "${done_count:-?}" "${total:-?}" "${recent_titles:-（なし）}" "${recent:-（なし）}"
  return 0
}

# ===== Locked Decision Assertions 検証 =====
# research-config.json の assertions を WORK_DIR に対して機械的に検証する。
# 戻り値: 0=全通過 or assertions未定義, 1=違反あり
# stdout: 違反レポート（失敗時）
# 使い方: validate_locked_assertions <config> <work_dir> [task_id]
validate_locked_assertions() {
  local config="$1" work_dir="$2" task_id="${3:-}"

  # ガード: config不在 → return 0
  if [ -z "$config" ] || [ ! -f "$config" ]; then
    return 0
  fi

  # ガード: assertions.enabled=false（development.json で無効化されている場合）
  local dev_cfg="${PROJECT_ROOT:-.}/.forge/config/development.json"
  if [ -f "$dev_cfg" ]; then
    local enabled
    enabled=$(cfg_bool "$dev_cfg" '.assertions.enabled' true)
    if [ "$enabled" = "false" ]; then
      return 0
    fi
  fi

  # assertions を持つ locked_decisions を抽出
  local has_assertions
  has_assertions=$(jq '[.locked_decisions // [] | .[].assertions // [] | length] | add // 0' "$config" 2>/dev/null)
  if [ "${has_assertions:-0}" -eq 0 ]; then
    return 0
  fi

  local violations=0
  local report=""

  # locked_decisions を1件ずつ処理
  local decision_count
  decision_count=$(jq '.locked_decisions | length' "$config" 2>/dev/null || echo 0)

  local i=0
  while [ "$i" -lt "$decision_count" ]; do
    local decision_text
    decision_text=$(jq_safe -r ".locked_decisions[$i].decision // \"\"" "$config" 2>/dev/null)

    local assertion_count
    assertion_count=$(jq ".locked_decisions[$i].assertions // [] | length" "$config" 2>/dev/null || echo 0)

    if [ "$assertion_count" -eq 0 ]; then
      i=$((i + 1))
      continue
    fi

    local j=0
    while [ "$j" -lt "$assertion_count" ]; do
      local atype apath apattern aglob
      atype=$(jq_safe -r ".locked_decisions[$i].assertions[$j].type // \"\"" "$config" 2>/dev/null)
      apath=$(jq_safe -r ".locked_decisions[$i].assertions[$j].path // \"\"" "$config" 2>/dev/null)
      apattern=$(jq_safe -r ".locked_decisions[$i].assertions[$j].pattern // \"\"" "$config" 2>/dev/null)
      aglob=$(jq_safe -r ".locked_decisions[$i].assertions[$j].glob // \"\"" "$config" 2>/dev/null)

      case "$atype" in
        file_exists)
          if [ ! -f "${work_dir}/${apath}" ]; then
            report="${report}VIOLATION [${decision_text}]: file_exists — ${apath} が存在しない\n"
            violations=$((violations + 1))
          fi
          ;;
        file_absent)
          if [ -f "${work_dir}/${apath}" ]; then
            report="${report}VIOLATION [${decision_text}]: file_absent — ${apath} が存在する\n"
            violations=$((violations + 1))
          fi
          ;;
        grep_present)
          if [ -z "$apattern" ] || [ -z "$aglob" ]; then
            j=$((j + 1))
            continue
          fi
          local search_dir search_include
          search_dir=$(_resolve_glob_search_dir "$work_dir" "$aglob")
          search_include=$(_resolve_glob_include "$aglob")
          local hits
          hits=$(grep -rlE "$apattern" $search_include "$search_dir" 2>/dev/null || true)
          if [ -z "$hits" ]; then
            report="${report}VIOLATION [${decision_text}]: grep_present — パターン '${apattern}' が ${aglob} 内で見つからない\n"
            violations=$((violations + 1))
          fi
          ;;
        grep_absent)
          if [ -z "$apattern" ] || [ -z "$aglob" ]; then
            j=$((j + 1))
            continue
          fi
          local search_dir search_include
          search_dir=$(_resolve_glob_search_dir "$work_dir" "$aglob")
          search_include=$(_resolve_glob_include "$aglob")
          local hits
          hits=$(grep -rlE "$apattern" $search_include "$search_dir" 2>/dev/null || true)

          # except 配列で除外
          if [ -n "$hits" ]; then
            local except_json
            except_json=$(jq -c ".locked_decisions[$i].assertions[$j].except // []" "$config" 2>/dev/null || echo "[]")
            local except_count
            except_count=$(echo "$except_json" | jq 'length' 2>/dev/null || echo 0)

            if [ "$except_count" -gt 0 ]; then
              local filtered_hits=""
              while IFS= read -r hit_file; do
                [ -z "$hit_file" ] && continue
                local rel_path="${hit_file#${work_dir}/}"
                local is_excepted=false
                local k=0
                while [ "$k" -lt "$except_count" ]; do
                  local except_path
                  except_path=$(echo "$except_json" | jq_safe -r ".[$k]" 2>/dev/null)
                  if [ "$rel_path" = "$except_path" ]; then
                    is_excepted=true
                    break
                  fi
                  k=$((k + 1))
                done
                if [ "$is_excepted" = "false" ]; then
                  filtered_hits="${filtered_hits}${hit_file}\n"
                fi
              done <<< "$hits"
              hits=$(echo -e "$filtered_hits" | grep -v '^$' || true)
            fi

            if [ -n "$hits" ]; then
              local hit_files
              hit_files=$(echo "$hits" | sed "s|${work_dir}/||g" | head -5 | tr '\n' ', ' | sed 's/,$//')
              report="${report}VIOLATION [${decision_text}]: grep_absent — パターン '${apattern}' が ${aglob} 内でヒット: ${hit_files}\n"
              violations=$((violations + 1))
            fi
          fi
          ;;
      esac
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  if [ "$violations" -gt 0 ]; then
    echo -e "Locked Decision Assertions: ${violations} 件の違反\n${report}"
    return 1
  fi
  return 0
}

# glob パターンから grep の検索ディレクトリを解決する
# 例: "src/app/**/*.ts" → "$work_dir/src/app"
#     "src/**/*.ts"     → "$work_dir/src"
_resolve_glob_search_dir() {
  local work_dir="$1" glob="$2"
  # ** より前のディレクトリ部分を抽出
  local prefix="${glob%%\*\**}"
  prefix="${prefix%/}"
  if [ -n "$prefix" ]; then
    echo "${work_dir}/${prefix}"
  else
    echo "$work_dir"
  fi
}

# glob パターンから grep の --include オプションを解決する
# 例: "src/**/*.ts" → '--include=*.ts'
#     "*.js"        → '--include=*.js'
_resolve_glob_include() {
  local glob="$1"
  # 最後の / 以降のファイルパターンを抽出
  local file_pattern="${glob##*/}"
  if [ -n "$file_pattern" ] && [[ "$file_pattern" == *"."* ]]; then
    echo "--include=${file_pattern}"
  fi
}

# ===== Progress Tracking =====
PROGRESS_FILE="${PROJECT_ROOT:-.}/.forge/state/progress.json"

update_progress() {
  local phase="$1" stage="$2" detail="${3:-}" pct="${4:-}"
  jq -n \
    --arg phase "$phase" \
    --arg stage "$stage" \
    --arg detail "$detail" \
    --arg pct "$pct" \
    --arg updated "$(date -Iseconds)" \
    '{phase: $phase, stage: $stage, detail: $detail,
      progress_pct: (if $pct != "" then ($pct | tonumber) else null end),
      updated_at: $updated}' \
    > "${PROGRESS_FILE}.tmp" && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
}

# ===== SERVER_URL 取得 =====
# development.json の health_check_url からベースURL（scheme + host + port）を抽出する。
# servers[] 配列があれば最初のサーバーを使用し、なければ server にフォールバック。
# 使い方: server_url=$(get_server_url [config_file] [server_name])
get_server_url() {
  local config="${1:-${PROJECT_ROOT:-.}/.forge/config/development.json}"
  local server_name="${2:-}"
  local default="http://localhost:3000"
  if [ -f "$config" ]; then
    local health_url=""
    # servers[] 配列を優先チェック
    local servers_count
    servers_count=$(jq '.servers // [] | length' "$config" 2>/dev/null || echo 0)
    if [ "$servers_count" -gt 0 ]; then
      if [ -n "$server_name" ]; then
        health_url=$(jq_safe -r --arg name "$server_name" '.servers[] | select(.name == $name) | .health_check_url // ""' "$config")
      else
        health_url=$(jq_safe -r '.servers[0].health_check_url // ""' "$config")
      fi
    fi
    # servers[] になければ server にフォールバック
    if [ -z "$health_url" ]; then
      health_url=$(jq_safe -r '.server.health_check_url // ""' "$config")
    fi
    if [ -n "$health_url" ]; then
      echo "$health_url" | sed 's|\(https\?://[^/]*\).*|\1|'
      return
    fi
  fi
  echo "$default"
}

# ===== 設定値取得ヘルパー =====
# jq_safe パターンの簡略化ラッパー。
# 使い方: val=$(config_get '.key.subkey' 'default_value' config_file)
config_get() {
  local filter="$1"
  local default="$2"
  local config="$3"
  if [ -n "$config" ] && [ -f "$config" ]; then
    local result
    result=$(jq_safe -r "${filter} // empty" "$config" 2>/dev/null)
    if [ -n "$result" ]; then
      echo "$result"
      return
    fi
  fi
  echo "$default"
}

# ===== L1 テストファイル参照検証 =====
# L1 テストコマンドに含まれるファイルパスが WORK_DIR に存在するか検証。
# Implementer がファイルを作成していない場合を早期検出する。
# 戻り値: 0=全ファイル存在 or パス抽出不可, 1=未作成ファイルあり
# stdout: 未作成ファイル一覧（失敗時）
validate_l1_file_refs() {
  local command="$1" work_dir="$2"

  # テストファイルパスを抽出（.test./.spec./.e2e. + .sh）
  local file_refs=""
  file_refs=$(echo "$command" | grep -oE '[^ ]+\.(test|spec|e2e)\.[jt]sx?' 2>/dev/null || true)
  local sh_refs=""
  sh_refs=$(echo "$command" | grep -oE '[^ ]+\.sh' 2>/dev/null || true)
  [ -n "$sh_refs" ] && file_refs=$(printf '%s\n%s' "$file_refs" "$sh_refs")

  # リテラルグロブ/クォート含むパスは除外（シェル展開前の文字列では存在検証不能）
  # refactor-render-quality-gates で scenarios/.../lib/*.sh を誤検出した harness bug への恒久修正
  file_refs=$(echo "$file_refs" | grep -vE "[*?[]|['\"]" 2>/dev/null || true)

  # パスが抽出できなかった場合は検証スキップ（return 0）
  file_refs=$(echo "$file_refs" | grep -v '^$' || true)
  [ -z "$file_refs" ] && return 0

  local missing=""
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ ! -f "${work_dir}/${ref}" ]; then
      missing="${missing}${ref}\n"
    fi
  done <<< "$file_refs"

  if [ -n "$missing" ]; then
    echo -e "$missing" | grep -v '^$'
    return 1
  fi
  return 0
}

# ===== L2 fix タスク重複検出（dedup） =====
# Phase 3 → Phase 2 リトライ時に、同一 L2 失敗で fix タスクが累積するのを防ぐ。
# 「同一 origin_task_id + 同一 L2 command フィンガープリント」を持つ *pending* な fix
# タスクが既に存在するかを判定する。completed/failed 等の非 pending fix は dedup 対象外
# （= 同一失敗が再発した場合は新規 fix を作らせる。pending のみ dedup 対象）。
# 引数:
#   $1 task_stack     — task-stack.json パス
#   $2 origin_id      — 元タスク ID（fix の .l2_fix_for と照合）
#   $3 l2_command     — legacy L2 command フィンガープリント
#   $4 l2_checks_json — (任意) v2 layer-2 checks の正準 JSON 配列（batch#8 Stage3）。
#                       非空配列なら構造等価（キー順非依存）で dedup し legacy 照合は行わない。
#                       v2-only タスクは command が "" になるため、空文字列同士の照合で
#                       同一 origin の異なる失敗が過剰 dedup される問題への対処。
# 戻り値: 0 = 重複 pending fix が既存（呼び出し側は append をスキップすべき）
#         1 = 重複なし（呼び出し側は append すべき）
# stdout: 重複時は既存 pending fix の task_id（最初の1件）
l2_fix_pending_duplicate() {
  local task_stack="$1"
  local origin_id="$2"
  local l2_command="$3"
  local l2_checks_json="${4:-[]}"

  [ -f "$task_stack" ] || return 1
  case "$l2_checks_json" in ('') l2_checks_json='[]' ;; esac
  jq -e . >/dev/null 2>&1 <<< "$l2_checks_json" || l2_checks_json='[]'

  local dup_id
  if [ "$l2_checks_json" != "[]" ]; then
    # v2 構造フィンガープリント照合
    dup_id=$(jq -r --arg orig "$origin_id" --argjson fp "$l2_checks_json" '
      [ .tasks[]?
        | select(.status == "pending")
        | select((.l2_fix_for // "") == $orig)
        | select(([.validation.checks[]? | select(.layer == 2)]) == $fp)
        | .task_id
      ] | first // ""
    ' "$task_stack" 2>/dev/null | tr -d '\r')
  else
    # legacy command 照合。空/空ペアは照合しない（過剰 dedup 防止 — キャップが防波堤）
    [ -z "$l2_command" ] && return 1
    dup_id=$(jq -r --arg orig "$origin_id" --arg cmd "$l2_command" '
      [ .tasks[]?
        | select(.status == "pending")
        | select((.l2_fix_for // "") == $orig)
        | select((.validation.layer_2.command // "") == $cmd)
        | .task_id
      ] | first // ""
    ' "$task_stack" 2>/dev/null | tr -d '\r')
  fi

  if [ -n "$dup_id" ]; then
    echo "$dup_id"
    return 0
  fi
  return 1
}

# ===== L3 fix タスク重複検出（dedup） =====
# l2_fix_pending_duplicate の L3 版。browser-cockpit で dedup 欠如により
# 検証不能な L3 を持つ fix タスクが Phase3 リトライ毎に増殖した実害への対処。
# 引数:
#   $1 task_stack  — task-stack.json パス
#   $2 origin_id   — 元タスク ID（fix の .l3_fix_for と照合）
#   $3 l3_test_id  — L3 テスト ID（fix の .l3_test_id と照合）
# 戻り値: 0 = 重複 pending fix が既存（append をスキップすべき）/ 1 = 重複なし
# stdout: 重複時は既存 pending fix の task_id（最初の1件）
l3_fix_pending_duplicate() {
  local task_stack="$1"
  local origin_id="$2"
  local l3_test_id="$3"

  [ -f "$task_stack" ] || return 1

  local dup_id
  dup_id=$(jq -r --arg orig "$origin_id" --arg tid "$l3_test_id" '
    [ .tasks[]?
      | select(.status == "pending")
      | select((.l3_fix_for // "") == $orig)
      | select((.l3_test_id // "") == $tid)
      | .task_id
    ] | first // ""
  ' "$task_stack" 2>/dev/null | tr -d '\r')

  if [ -n "$dup_id" ]; then
    echo "$dup_id"
    return 0
  fi
  return 1
}

# ===== origin 毎の fix タスク総数 =====
# 同一 origin タスクに対する l2fix + l3fix の総数（全 status）を stdout に出力。
# fix 増殖の上限判定（development_limits.max_fix_tasks_per_origin）に使用する。常に rc=0
fix_tasks_for_origin_count() {
  local task_stack="$1"
  local origin_id="$2"
  local n
  n=$(jq -r --arg orig "$origin_id" '
    [ .tasks[]?
      | select(((.l2_fix_for // "") == $orig) or ((.l3_fix_for // "") == $orig))
    ] | length
  ' "$task_stack" 2>/dev/null | tr -d '\r')
  case "$n" in (*[!0-9]*|"") n=0 ;; esac
  printf '%s' "$n"
  return 0
}

# ===== 環境起因失敗の分類 =====
# is_environmental_failure <output>
# テスト失敗出力が「実装バグ」ではなく「環境不足」由来かを署名マッチで判定する。
# 環境起因なら fix タスクを作らず deferred（台帳記録）に回す — futile ループの根絶。
# 署名は保守的に選定（偽陽性 = 実バグの繰延、が最も危険なため。HTTP コード数値単体は含めない）。
# development.json の env_failure_signatures[] で ERE を追加拡張できる。
# 戻り値: 0 = 環境起因 / 1 = 非環境起因（または空出力）
is_environmental_failure() {
  local output="$1"
  [ -z "$output" ] && return 1

  local sig
  sig='ECONNREFUSED|[Cc]onnection refused|net::ERR_CONNECTION|EADDRINUSE|ENOTFOUND'
  sig="${sig}|Failed to connect|could not connect to server"
  sig="${sig}|Executable doesn.t exist|Failed to launch|browserType\.launch"
  sig="${sig}|cannot open display|Missing X server"
  sig="${sig}|command not found"
  sig="${sig}|ENOENT.*(playwright|chromium|electron|camoufox|firefox)"

  local extra=""
  if [ -n "${DEV_CONFIG:-}" ] && [ -f "${DEV_CONFIG:-/nonexistent}" ]; then
    extra=$(jq_safe -r '(.env_failure_signatures // []) | join("|")' "$DEV_CONFIG" 2>/dev/null)
  fi
  [ -n "$extra" ] && sig="${sig}|${extra}"

  printf '%s' "$output" | grep -qE "$sig"
}

# ===== requires エントリの充足判定 =====
# requires_entry_satisfiable <req>
# 語彙: server | env:VAR | cmd:NAME | file:PATH | browser | network | docker | display
#       | VAR（後方互換: 環境変数）
# 判定順序:
#   1. env-capabilities.json（Phase 1.5 プローブ結果）の capability_tags に一致 → 充足
#   2. フラット語彙（browser/network/docker/display）はプローブ結果が権威 — タグ無し = 不足
#      （server のみ live フォールバック併用: プローブ後の設定変更を救済）
#   3. プローブ結果不在 or 構造化プレフィックス（cmd:/env:/file:）は live 判定
# 戻り値: 0 = 充足 / 1 = 不足
requires_entry_satisfiable() {
  local req="$1"
  local caps_file="${ENV_CAPABILITIES_FILE:-${PROJECT_ROOT:-.}/.forge/state/env-capabilities.json}"

  local caps_present=false
  if [ -f "$caps_file" ]; then
    caps_present=true
    local tag_found
    tag_found=$(jq_safe -r --arg t "$req" '(.capability_tags // []) | map(select(. == $t)) | length' "$caps_file" 2>/dev/null)
    case "$tag_found" in (*[!0-9]*|"") tag_found=0 ;; esac
    if [ "$tag_found" -gt 0 ]; then
      return 0
    fi
  fi

  case "$req" in
    server)
      # live フォールバック: start_command 設定済み or health 応答あり
      local _start_cmd _health_url
      _start_cmd=$(jq_safe -r '.server.start_command // "none"' "${DEV_CONFIG:-/nonexistent}" 2>/dev/null)
      if [ -n "$_start_cmd" ] && [ "$_start_cmd" != "none" ] && [ "$_start_cmd" != "null" ]; then
        return 0
      fi
      _health_url=$(jq_safe -r '.server.health_check_url // ""' "${DEV_CONFIG:-/nonexistent}" 2>/dev/null)
      if [ -n "$_health_url" ] && type server_http_code &>/dev/null; then
        local _hc
        _hc=$(server_http_code "$_health_url")
        [ "$_hc" != "000" ] && return 0
      fi
      return 1
      ;;
    browser|network|docker|display)
      # プローブ結果があれば権威（タグ無し = 不足）
      if [ "$caps_present" = "true" ]; then
        return 1
      fi
      # live フォールバック
      case "$req" in
        browser)
          local _bt
          _bt=$(jq_safe -r '.browser_testing.enabled // false' "${DEV_CONFIG:-/nonexistent}" 2>/dev/null)
          [ "$_bt" = "true" ] && command -v npx > /dev/null 2>&1 && return 0
          return 1
          ;;
        docker)
          command -v docker > /dev/null 2>&1 && return 0
          return 1
          ;;
        network|display)
          # live 判定が安価にできないため楽観（プローブ結果があればそちらが権威）
          return 0
          ;;
      esac
      ;;
    env:*)
      [ -n "$(printenv "${req#env:}" 2>/dev/null)" ] && return 0
      return 1
      ;;
    cmd:*)
      command -v "${req#cmd:}" > /dev/null 2>&1 && return 0
      return 1
      ;;
    file:*)
      [ -f "${WORK_DIR:-.}/${req#file:}" ] && return 0
      return 1
      ;;
    *)
      # 後方互換: プレフィックスなし = 環境変数
      [ -n "$(printenv "$req" 2>/dev/null)" ] && return 0
      return 1
      ;;
  esac
}

# metrics_start / metrics_record / aggregate_session_cost は「コスト集計」「メトリクス記録」
# セクション（本ファイル前半）で定義済み。重複定義は 2026-07 batch#8 で削除
#（旧・後勝ち aggregate_session_cost は CRLF 除去なし + 引数デフォルトなしの劣化版だった）

# ===== 設定ファイルスキーマ検証 =====
# JSON Schema ファイルを使って config ファイルの必須フィールド・型制約を jq で検証する。
# 使い方: validate_config <config_file> <schema_file>
# 戻り値: 0=検証通過, 1=検証失敗（必須フィールド欠落または型エラー）
# 副作用: スキーマ未定義フィールドは警告ログ出力のみ（exit code に影響しない）
# スキーマ形式: JSON Schema Draft-07 の subset（type, required, properties 2段ネストまで）
validate_config() {
  local config_file="$1"
  local schema_file="$2"

  if [ ! -f "$config_file" ]; then
    echo "[CONFIG] ERROR: config file not found: $config_file" >&2
    return 1
  fi
  if [ ! -f "$schema_file" ]; then
    # スキーマファイルが存在しない場合は警告のみで続行（後方互換性）
    echo "[CONFIG] WARNING: schema file not found: $schema_file — validation skipped" >&2
    return 0
  fi

  # jq ベーススキーマ検証:
  # 1. required フィールドの存在確認（top-level + 1段ネスト）
  # 2. properties で定義された型制約（フィールドが存在する場合のみ）
  # 3. スキーマ未定義のトップレベルキー → WARN 出力（失敗にしない）
  local issues
  if ! issues=$(jq -r -n \
    --slurpfile cfg "$config_file" \
    --slurpfile sch "$schema_file" \
    '
    $cfg[0] as $c | $sch[0] as $s |
    if ($c | type) != "object" then
      "ERROR:config is not a JSON object (got " + ($c | type) + ")"
    else
      (
        ($s.properties // {}) | to_entries[] |
        .key as $k | .value as $pdef |
        if ($c | has($k) | not) then
          if (($s.required // []) | index($k)) != null then
            "ERROR:missing required field: ." + $k
          else empty end
        else
          ($pdef.type // null) as $t |
          ($c[$k] | type) as $actual_t |
          if $t != null and $actual_t != $t then
            "ERROR:type mismatch at ." + $k + ": expected " + $t + ", got " + $actual_t
          elif $t == "object" and $actual_t == "object" then
            (
              ($pdef.properties // {}) | to_entries[] |
              .key as $nk | .value as $npdef |
              if ($c[$k] | has($nk) | not) then
                if (($pdef.required // []) | index($nk)) != null then
                  "ERROR:missing required field: ." + $k + "." + $nk
                else empty end
              else
                ($npdef.type // null) as $nt |
                ($c[$k][$nk] | type) as $actual_nt |
                if $nt != null and $actual_nt != $nt then
                  "ERROR:type mismatch at ." + $k + "." + $nk + ": expected " + $nt + ", got " + $actual_nt
                else empty end
              end
            )
          else empty end
        end
      ),
      (
        ($c | keys)[] as $k |
        if (($s.properties // {}) | has($k) | not) then
          "WARN:unknown field: ." + $k
        else empty end
      )
    end
    ' 2>/dev/null | tr -d '\r'); then
    echo "[CONFIG] ERROR: スキーマ検証スクリプト実行失敗: ${config_file}" >&2
    return 1
  fi

  local error_count=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      ERROR:*)
        echo "[CONFIG] ${line}" >&2
        error_count=$((error_count + 1))
        ;;
      WARN:*)
        echo "[CONFIG] WARNING: ${line#WARN:}" >&2
        ;;
    esac
  done <<< "$issues"

  if [ "$error_count" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ===== リトライヘルパー =====
# 非リトライ対象 exit code（決定的失敗 — 再実行しても結果が変わらず、コスト/時間だけ増える）:
#   2  : run_claude 引数エラー（validate_effort 失敗等の設定ミス）
#   21 : per-call 予算超過（RC_EXIT_BUDGET_EXCEEDED — リトライは超過コストの積み増し）
#   22 : モデル別クォータ枯渇（RC_EXIT_QUOTA_EXHAUSTED — 人間の介入まで回復しない）
#   130/143 : SIGINT / SIGTERM（人間の停止 — 再実行は停止の意図に反する。batch#11 R07a）
# スペース区切りで上書き可能（テスト・将来の分類拡張用）。
: "${RETRY_NONRETRYABLE_EXITS:=2 21 22 130 143}"

# exit code がリトライ対象かを判定する（0=リトライ可, 1=非リトライ対象）
# ${VAR:-default} 展開は set -u 環境での関数単体抽出テストを壊さないための防御
is_retryable_exit() {
  local code="$1" c
  for c in ${RETRY_NONRETRYABLE_EXITS:-2 21 22 130 143}; do
    if [ "$code" = "$c" ]; then
      return 1
    fi
  done
  return 0
}

# コマンドを指数バックオフ付きでリトライ実行する。
# 使い方: retry_with_backoff <max_retries> <backoff_sec> <command...>
# バックオフ: backoff_sec * 2^(retry-1) （1→2→4→8秒 with backoff_sec=1）
# max_retries=0 の場合はコマンドを実行せず即座に return 1。
# 非リトライ対象 exit code（RETRY_NONRETRYABLE_EXITS）はリトライせず即座にそのコードで返す。
# 戻り値: 0=成功, 1=全リトライ失敗 or max_retries=0, その他=非リトライ対象の元 exit code
retry_with_backoff() {
  local max_retries="$1"
  local backoff_sec="$2"
  shift 2

  # max_retries=0: コマンドを実行せず即座に失敗
  if [ "$max_retries" -le 0 ]; then
    return 1
  fi

  # 初回試行（スリープなし）
  local rc=0
  "$@" && return 0 || rc=$?
  if ! is_retryable_exit "$rc"; then
    log "⚠ 非リトライ対象エラー (exit=${rc}) — リトライを打ち切り"
    return "$rc"
  fi

  # リトライループ（指数バックオフ: backoff_sec * 2^(retry-1)）
  local retry=0
  while [ "$retry" -lt "$max_retries" ]; do
    retry=$((retry + 1))
    local current_sleep
    current_sleep=$((backoff_sec * (2 ** (retry - 1))))
    log "⚠ リトライ（${retry}/${max_retries}）— ${current_sleep}秒後"
    sleep "$current_sleep"
    rc=0
    "$@" && return 0 || rc=$?
    if ! is_retryable_exit "$rc"; then
      log "⚠ 非リトライ対象エラー (exit=${rc}) — リトライを打ち切り"
      return "$rc"
    fi
  done
  return 1
}

# ===== L3 Acceptance Test 実行インフラ =====

# L3 設定読み込み（development.json から）
load_l3_config() {
  local dev_cfg="${1:-${DEV_CONFIG:-${PROJECT_ROOT:-.}/.forge/config/development.json}}"
  L3_ENABLED=$(jq_safe -r '.layer_3.enabled // false' "$dev_cfg" 2>/dev/null)
  L3_JUDGE_MODEL=$(jq_safe -r '.layer_3.judge_model // "haiku"' "$dev_cfg" 2>/dev/null)
  L3_JUDGE_TIMEOUT=$(jq_safe -r '.layer_3.judge_timeout_sec // 300' "$dev_cfg" 2>/dev/null)
  L3_MAX_JUDGE_CALLS=$(jq_safe -r '.layer_3.max_judge_calls_per_session // 20' "$dev_cfg" 2>/dev/null)
  L3_DEFAULT_TIMEOUT=$(jq_safe -r '.layer_3.default_timeout_sec // 120' "$dev_cfg" 2>/dev/null)
  L3_FAIL_CREATES_TASK=$(cfg_bool "$dev_cfg" '.layer_3.fail_creates_task' true)
  L3_AGENT_FLOW_TIMEOUT=$(jq_safe -r '.layer_3.agent_flow_timeout // 900' "$dev_cfg" 2>/dev/null)
  L3_MAX_AGENT_CALLS=$(jq_safe -r '.layer_3.max_agent_calls // 30' "$dev_cfg" 2>/dev/null)
  L3_JUDGE_MODEL_COHERENCE=$(jq_safe -r '.layer_3.judge_model_coherence // "sonnet"' "$dev_cfg" 2>/dev/null)
  L3_COHERENCE_RETRY_COUNT=$(jq_safe -r '.layer_3.coherence_retry_count // 1' "$dev_cfg" 2>/dev/null)
  L3_JUDGE_CALL_COUNT=0
}

# L3 テスト配列から requires 条件に基づいてフィルタする（3値分類）
# 使い方: filter_l3_tests <task_json> <mode>
#   mode: "immediate" — server 非依存 かつ 全 requires 充足（per-task で即時実行）
#         "server"    — requires に server を含み、他の requires は充足（Phase 3 で実行）
#         "deferred"  — 明示 deferred:true、または server 以外の requires が充足不能
#                       （実行せず品質債務台帳へ — futile ループの根絶）
# stdout: フィルタ済み L3 テスト JSON 配列
# 注: deferred 判定された要素には _deferred_reason フィールドが付与される
filter_l3_tests() {
  local task_json="$1"
  local mode="$2"

  local all count
  all=$(echo "$task_json" | jq -c '.validation.layer_3 // []' 2>/dev/null)
  [ -z "$all" ] && all="[]"
  count=$(echo "$all" | jq 'length' 2>/dev/null | tr -d '\r')
  case "$count" in (*[!0-9]*|"") count=0 ;; esac

  local immediate="[]" server_bucket="[]" deferred="[]"
  local i=0
  while [ "$i" -lt "$count" ]; do
    local entry explicit_deferred has_server
    entry=$(echo "$all" | jq -c ".[$i]")
    explicit_deferred=$(echo "$entry" | jq -r '.deferred // false' 2>/dev/null | tr -d '\r')
    has_server=$(echo "$entry" | jq -r '(.requires // []) | map(select(. == "server")) | length' 2>/dev/null | tr -d '\r')
    case "$has_server" in (*[!0-9]*|"") has_server=0 ;; esac

    # server 以外の requires の充足判定
    local unsat="" req
    for req in $(echo "$entry" | jq -r '(.requires // []) | .[]' 2>/dev/null | tr -d '\r'); do
      [ "$req" = "server" ] && continue
      if ! requires_entry_satisfiable "$req"; then
        unsat="$req"
        break
      fi
    done

    if [ "$explicit_deferred" = "true" ] || [ -n "$unsat" ]; then
      if [ -n "$unsat" ]; then
        entry=$(echo "$entry" | jq -c --arg r "環境能力不足: ${unsat}" '. + {_deferred_reason: (.deferred_reason // $r)}')
      else
        entry=$(echo "$entry" | jq -c '. + {_deferred_reason: (.deferred_reason // "明示的 deferred 指定")}')
      fi
      deferred=$(echo "$deferred" | jq -c --argjson e "$entry" '. + [$e]')
    elif [ "$has_server" -gt 0 ]; then
      server_bucket=$(echo "$server_bucket" | jq -c --argjson e "$entry" '. + [$e]')
    else
      immediate=$(echo "$immediate" | jq -c --argjson e "$entry" '. + [$e]')
    fi
    i=$((i + 1))
  done

  case "$mode" in
    immediate) echo "$immediate" ;;
    deferred)  echo "$deferred" ;;
    *)         echo "$server_bucket" ;;
  esac
}

# L3 structural 戦略: 出力の構造・制約を機械的に検証
# definition.command: データ取得コマンド
# definition.expected_schema: JSON Schema（簡易チェック — 必須フィールドの存在確認）
# definition.verify_command: 追加の検証コマンド（オプション）
execute_l3_structural() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  local command verify_command
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')
  verify_command=$(echo "$l3_test" | jq_safe -r '.definition.verify_command // ""')

  if [ -z "$command" ]; then
    echo "ERROR: structural テストに command が未定義"
    return 1
  fi

  # メインコマンド実行
  local output exit_code=0
  output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: コマンド実行失敗 (exit=$exit_code): $output"
    return 1
  fi

  # JSON 構造検証（出力が JSON の場合）
  if echo "$output" | jq empty 2>/dev/null; then
    local required_fields
    required_fields=$(echo "$l3_test" | jq -r '.definition.expected_schema.required // [] | .[]' 2>/dev/null | tr -d '\r')
    for field in $required_fields; do
      [ -z "$field" ] && continue
      if ! echo "$output" | jq -e ".$field" > /dev/null 2>&1; then
        echo "FAIL: 必須フィールド '$field' が出力に含まれない"
        return 1
      fi
    done
  fi

  # 追加検証コマンド
  if [ -n "$verify_command" ]; then
    local verify_output verify_exit=0
    verify_output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $verify_command" 2>&1) || verify_exit=$?
    if [ "$verify_exit" -ne 0 ]; then
      echo "FAIL: 追加検証失敗 (exit=$verify_exit): $verify_output"
      return 1
    fi
  fi

  echo "PASS: structural テスト合格"
  return 0
}

# L3 api_e2e 戦略: API 連鎖フローの検証
# definition.command: API 呼出シーケンス（シェルスクリプト or curl チェーン）
execute_l3_api_e2e() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  local command
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')

  if [ -z "$command" ]; then
    echo "ERROR: api_e2e テストに command が未定義"
    return 1
  fi

  local output exit_code=0
  output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: API E2E テスト失敗 (exit=$exit_code): $output"
    return 1
  fi

  echo "PASS: api_e2e テスト合格"
  return 0
}

# L3 llm_judge 戦略: LLM が出力品質をスコアリング
# definition.command: 評価対象の出力を取得するコマンド
# definition.judge_criteria: 評価基準の配列
# definition.success_threshold: 合格閾値（0.0〜1.0）
execute_l3_llm_judge() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  # Judge 呼出回数チェック
  if [ "${L3_JUDGE_CALL_COUNT:-0}" -ge "${L3_MAX_JUDGE_CALLS:-20}" ]; then
    echo "SKIP: LLM Judge 呼出上限 (${L3_MAX_JUDGE_CALLS}) に到達"
    return 2
  fi

  local command judge_criteria_json threshold test_id
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')
  judge_criteria_json=$(echo "$l3_test" | jq_safe -c '.definition.judge_criteria // []')
  threshold=$(echo "$l3_test" | jq_safe -r '.definition.success_threshold // 0.7')
  test_id=$(echo "$l3_test" | jq_safe -r '.id // "unknown"')

  if [ -z "$command" ]; then
    echo "ERROR: llm_judge テストに command が未定義"
    return 1
  fi

  # 評価対象の出力を取得
  local target_output target_exit=0
  target_output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || target_exit=$?

  if [ "$target_exit" -ne 0 ]; then
    echo "FAIL: 評価対象コマンド実行失敗 (exit=$target_exit): $target_output"
    return 1
  fi

  # Judge プロンプト構築
  local judge_prompt
  judge_prompt="以下の出力を評価してください。

## 評価対象の出力
${target_output}

## 評価基準
$(echo "$judge_criteria_json" | jq_lines -r '.[]' 2>/dev/null | while read -r criterion; do echo "- ${criterion}"; done)

## 合格閾値
${threshold}

## テストID
${test_id}

各評価基準に対して 0.0〜1.0 のスコアと根拠を出力してください。"

  # Judge 呼出
  local judge_output_file=".forge/state/l3-judge-${test_id}-$(date +%s).json"
  local judge_log_file=".forge/logs/development/l3-judge-${test_id}.log"
  mkdir -p "$(dirname "$judge_output_file")" "$(dirname "$judge_log_file")"

  L3_JUDGE_CALL_COUNT=$(( ${L3_JUDGE_CALL_COUNT:-0} + 1 ))

  local judge_schema="${PROJECT_ROOT:-.}/.forge/schemas/l3-judge.schema.json"
  if ! run_claude "${L3_JUDGE_MODEL:-haiku}" "${PROJECT_ROOT:-.}/.claude/agents/l3-judge.md" \
    "$judge_prompt" "$judge_output_file" "$judge_log_file" \
    "Write,Edit,MultiEdit,Bash,WebSearch,WebFetch" "${L3_JUDGE_TIMEOUT:-300}" "" \
    "$judge_schema"; then
    echo "FAIL: LLM Judge 実行エラー"
    return 1
  fi

  # .pending → 本ファイルに昇格
  if [ -f "${judge_output_file}.pending" ]; then
    mv "${judge_output_file}.pending" "$judge_output_file"
  fi

  if [ ! -f "$judge_output_file" ] || ! jq empty "$judge_output_file" 2>/dev/null; then
    echo "FAIL: LLM Judge 出力が不正"
    return 1
  fi

  # 判定
  local pass overall_score summary
  pass=$(jq_safe -r '.pass // false' "$judge_output_file")
  overall_score=$(jq_safe -r '.overall_score // 0' "$judge_output_file")
  summary=$(jq_safe -r '.summary // "判定不能"' "$judge_output_file")

  if [ "$pass" = "true" ]; then
    echo "PASS: llm_judge テスト合格 (score=${overall_score}, threshold=${threshold}): ${summary}"
    return 0
  else
    echo "FAIL: llm_judge テスト不合格 (score=${overall_score}, threshold=${threshold}): ${summary}"
    return 1
  fi
}

# L3 cli_flow 戦略: claude -p で対話フロー模擬
# definition.command: CLI フロー実行コマンド
# definition.verify_command: 出力ファイル存在確認等
execute_l3_cli_flow() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  local command verify_command
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')
  verify_command=$(echo "$l3_test" | jq_safe -r '.definition.verify_command // ""')

  if [ -z "$command" ]; then
    echo "ERROR: cli_flow テストに command が未定義"
    return 1
  fi

  # CLI フロー実行
  local output exit_code=0
  output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: CLI フロー実行失敗 (exit=$exit_code): $output"
    return 1
  fi

  # 検証コマンド実行（オプション）
  if [ -n "$verify_command" ]; then
    local verify_output verify_exit=0
    verify_output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $verify_command" 2>&1) || verify_exit=$?
    if [ "$verify_exit" -ne 0 ]; then
      echo "FAIL: CLI フロー検証失敗 (exit=$verify_exit): $verify_output"
      return 1
    fi
  fi

  echo "PASS: cli_flow テスト合格"
  return 0
}

# L3 context_injection 戦略: コンテキスト注入の動作検証
# definition.command: コンテキスト書込コマンド
# definition.verify_command: 注入結果の検証コマンド
# definition.context_file: 検証対象ファイル（オプション）
execute_l3_context_injection() {
  local l3_test="$1"
  local work_dir="${2:-$WORK_DIR}"
  local timeout="${3:-$L3_DEFAULT_TIMEOUT}"

  local command verify_command context_file
  command=$(echo "$l3_test" | jq_safe -r '.definition.command // ""')
  verify_command=$(echo "$l3_test" | jq_safe -r '.definition.verify_command // ""')
  context_file=$(echo "$l3_test" | jq_safe -r '.definition.context_file // ""')

  if [ -z "$command" ]; then
    echo "ERROR: context_injection テストに command が未定義"
    return 1
  fi

  # コンテキスト書込実行
  local output exit_code=0
  output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $command" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: コンテキスト注入失敗 (exit=$exit_code): $output"
    return 1
  fi

  # context_file の存在確認
  if [ -n "$context_file" ] && [ ! -f "${work_dir}/${context_file}" ]; then
    echo "FAIL: コンテキストファイル未生成: ${context_file}"
    return 1
  fi

  # 検証コマンド
  if [ -n "$verify_command" ]; then
    local verify_output verify_exit=0
    verify_output=$(timeout "$timeout" env PATH="$work_dir/node_modules/.bin:$PATH" bash -c "cd '$work_dir' && $verify_command" 2>&1) || verify_exit=$?
    if [ "$verify_exit" -ne 0 ]; then
      echo "FAIL: コンテキスト検証失敗 (exit=$verify_exit): $verify_output"
      return 1
    fi
  fi

  echo "PASS: context_injection テスト合格"
  return 0
}

# L3 agent_flow 戦略: Claude エージェント連鎖テスト
# definition.steps[]: ステップ配列（step_id, agent_file, prompt_template, model, context_from_steps, timeout_sec）
# 各ステップを逐次実行し、前ステップ出力を {{prev_output}} で後続に注入
execute_l3_agent_flow() {
  local l3_test="$1"
  local work_dir="${2:-${WORK_DIR:-.}}"
  local timeout="${3:-${L3_DEFAULT_TIMEOUT:-120}}"

  local test_id steps_json step_count
  test_id=$(echo "$l3_test" | jq_safe -r '.id // "unknown"')
  steps_json=$(echo "$l3_test" | jq_safe -c '.definition.steps // []')
  step_count=$(echo "$steps_json" | jq 'length')

  # steps が空配列の場合は即時 return 0（テストなし扱い・エラーログなし）
  if [ "$step_count" -eq 0 ]; then
    return 0
  fi

  local state_dir="${PROJECT_ROOT:-.}/.forge/state/l3-agent-${test_id}"
  mkdir -p "$state_dir"

  # チェーン全体タイムアウト計測開始
  local chain_start
  chain_start=$(date +%s)

  local agent_call_count=0
  local step_idx=0

  while [ "$step_idx" -lt "$step_count" ]; do
    local step step_id agent_file prompt_template model
    local context_from_steps_json step_timeout_sec
    step=$(echo "$steps_json" | jq -c ".[$step_idx]")
    step_id=$(echo "$step" | jq_safe -r '.step_id // "step-'"$step_idx"'"')
    agent_file=$(echo "$step" | jq_safe -r '.agent_file // ""')
    prompt_template=$(echo "$step" | jq_safe -r '.prompt_template // ""')
    model=$(echo "$step" | jq_safe -r '.model // "haiku"')
    context_from_steps_json=$(echo "$step" | jq_safe -c '.context_from_steps // []')
    step_timeout_sec=$(echo "$step" | jq_safe -r '.timeout_sec // '"$timeout"'')

    # L3_MAX_AGENT_CALLS 制限チェック（超過時はスキップ+ログ）
    if [ "$agent_call_count" -ge "${L3_MAX_AGENT_CALLS:-30}" ]; then
      log "L3 agent flow: agent call limit (${L3_MAX_AGENT_CALLS:-30}) reached, skipping step ${step_id}"
      step_idx=$(( step_idx + 1 ))
      continue
    fi

    # チェーン全体タイムアウトチェック（各ステップ実行前）
    local now elapsed remaining
    now=$(date +%s)
    elapsed=$(( now - chain_start ))
    remaining=$(( ${L3_AGENT_FLOW_TIMEOUT:-900} - elapsed ))
    if [ "$remaining" -le 0 ]; then
      log "L3 agent flow: chain timeout exceeded (elapsed=${elapsed}s, limit=${L3_AGENT_FLOW_TIMEOUT:-900}s), skipping step ${step_id}"
      echo "FAIL: agent_flow chain timeout (elapsed=${elapsed}s, limit=${L3_AGENT_FLOW_TIMEOUT:-900}s)" >&2
      return 1
    fi

    # agent_file 存在確認（空文字の場合はスキップ）
    if [ -n "$agent_file" ] && [ ! -f "$agent_file" ]; then
      log "L3 agent flow: agent_file not found: ${agent_file}"
      echo "ERROR: agent_file not found: ${agent_file}" >&2
      return 1
    fi

    # context_from_steps による {{prev_output}} 展開
    local prompt="$prompt_template"
    local ctx_count
    ctx_count=$(echo "$context_from_steps_json" | jq 'length')
    if [ "$ctx_count" -gt 0 ]; then
      local prev_output=""
      local ctx_step_id
      while IFS= read -r ctx_step_id; do
        [ -z "$ctx_step_id" ] && continue
        local ctx_file="${state_dir}/step-${ctx_step_id}.json"
        if [ -f "$ctx_file" ]; then
          local ctx_content
          ctx_content=$(cat "$ctx_file")
          prev_output="${prev_output}${ctx_content}"
        fi
      done < <(echo "$context_from_steps_json" | jq_safe -r '.[]')
      prompt="${prompt//\{\{prev_output\}\}/$prev_output}"
    fi

    # プロンプトログ保存（テスト検証・デバッグ用）
    local prompt_log="${state_dir}/prompt-${step_id}.txt"
    echo "$prompt" > "$prompt_log"

    # subagent_files: --agents インライン定義で -p モードの Task 委譲を有効化する。
    # 各パスは .claude/agents/*.md（PROJECT_ROOT 相対 or 絶対）。
    # ステップ単位で env チャネルを設定し、呼出後に必ず復元する（他エージェント呼出への漏洩防止）。
    local subagent_files_json sub_count
    subagent_files_json=$(echo "$step" | jq_safe -c '.subagent_files // []')
    sub_count=$(echo "$subagent_files_json" | jq 'length' 2>/dev/null)
    [[ "$sub_count" =~ ^[0-9]+$ ]] || sub_count=0
    local _saved_agents_file="${_RC_AGENTS_FILE:-}"
    if [ "$sub_count" -gt 0 ]; then
      local -a _sa_files=()
      local _sa_p
      while IFS= read -r _sa_p; do
        [ -z "$_sa_p" ] && continue
        case "$_sa_p" in
          /* | [A-Za-z]:*) _sa_files+=("$_sa_p") ;;
          *)               _sa_files+=("${PROJECT_ROOT:-.}/${_sa_p}") ;;
        esac
      done < <(echo "$subagent_files_json" | jq_safe -r '.[]')
      build_agents_json "${_sa_files[@]}" > "${state_dir}/agents-${step_id}.json"
      export _RC_AGENTS_FILE="${state_dir}/agents-${step_id}.json"
      log "L3 agent flow: step ${step_id} — subagent ${sub_count} 体を --agents インライン定義で注入"
    fi

    # run_claude() 呼び出し
    local step_output_file="${state_dir}/step-${step_id}.json"
    local step_log_file="${PROJECT_ROOT:-.}/.forge/logs/development/l3-agent-${test_id}-${step_id}.log"
    mkdir -p "$(dirname "$step_log_file")"

    # ステップタイムアウトはチェーン残り時間と step 固有タイムアウトの小さい方
    local effective_timeout="$step_timeout_sec"
    if [ "$remaining" -lt "$effective_timeout" ]; then
      effective_timeout="$remaining"
    fi

    local _step_rc=0
    run_claude "$model" "$agent_file" "$prompt" "$step_output_file" "$step_log_file" \
      "" "$effective_timeout" "$work_dir" || _step_rc=$?

    # env チャネル復元（失敗 return 前に必ず実行）
    if [ -n "$_saved_agents_file" ]; then
      export _RC_AGENTS_FILE="$_saved_agents_file"
    else
      unset _RC_AGENTS_FILE
    fi

    if [ "$_step_rc" -ne 0 ]; then
      log "L3 agent flow: step ${step_id} failed"
      echo "FAIL: agent_flow step ${step_id} 失敗" >&2
      return 1
    fi

    # .pending → 本ファイルへ昇格
    if [ -f "${step_output_file}.pending" ]; then
      mv "${step_output_file}.pending" "$step_output_file"
    fi

    agent_call_count=$(( agent_call_count + 1 ))
    step_idx=$(( step_idx + 1 ))
  done

  echo "PASS: agent_flow テスト合格 (${step_count} ステップ)"
  return 0
}

# L3 テスト実行ディスパッチャ
# 使い方: execute_l3_test <l3_test_json> [work_dir] [timeout]
# 戻り値: 0=PASS, 1=FAIL, 2=SKIP
execute_l3_test() {
  local l3_test="$1"
  local work_dir="${2:-${WORK_DIR:-.}}"
  local timeout="${3:-${L3_DEFAULT_TIMEOUT:-120}}"

  local strategy test_id
  strategy=$(echo "$l3_test" | jq_safe -r '.strategy // ""')
  test_id=$(echo "$l3_test" | jq_safe -r '.id // "unknown"')

  case "$strategy" in
    structural)
      execute_l3_structural "$l3_test" "$work_dir" "$timeout"
      ;;
    api_e2e)
      execute_l3_api_e2e "$l3_test" "$work_dir" "$timeout"
      ;;
    llm_judge)
      execute_l3_llm_judge "$l3_test" "$work_dir" "$timeout"
      ;;
    cli_flow)
      execute_l3_cli_flow "$l3_test" "$work_dir" "$timeout"
      ;;
    context_injection)
      execute_l3_context_injection "$l3_test" "$work_dir" "$timeout"
      ;;
    agent_flow)
      execute_l3_agent_flow "$l3_test" "$work_dir" "$timeout"
      ;;
    browser)
      if [ -f "${PROJECT_ROOT}/.forge/lib/browser-test.sh" ]; then
        source "${PROJECT_ROOT}/.forge/lib/browser-test.sh"
        execute_browser_test "$l3_test" "$work_dir" "$timeout"
      else
        echo "Browser test library not found"
        return 2
      fi
      ;;
    *)
      echo "ERROR: 不明な L3 戦略: ${strategy}"
      return 1
      ;;
  esac
}

# ===== タスク状態排他ロック =====
# mkdirベース排他ロック（Windows Git Bash環境ではflock不可のためmkdirを使用）
#
# acquire_lock <lock_dir> [timeout_sec] [retry_interval_sec]
#   lock_dir        : ロックディレクトリパス
#                     例: "${PROJECT_ROOT}/.forge/state/.lock/task-stack.lock"
#   timeout_sec     : タイムアウト秒数（デフォルト: 10）
#   retry_interval  : リトライ間隔秒数（デフォルト: 0.5）
# 戻り値: 0=取得成功, 1=タイムアウト（stderrに "Lock acquisition timeout" をログ出力）
acquire_lock() {
  local lock_dir="$1"
  local timeout_sec="${2:-10}"
  local retry_interval="${3:-0.5}"
  # 最大リトライ回数 = timeout_sec / retry_interval（整数切り捨て）
  local max_attempts
  max_attempts=$(awk "BEGIN {printf \"%d\", $timeout_sec / $retry_interval}")

  mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || true

  local attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      return 0
    fi

    # staleロック検出: mtime > 60秒 → 自動削除してリトライ（attempt カウントを増加させない）
    if [ -d "$lock_dir" ]; then
      local lock_mtime now age
      lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null || stat -f %m "$lock_dir" 2>/dev/null || echo 0)
      now=$(date +%s)
      age=$(( now - lock_mtime ))
      if [ "$age" -gt 60 ]; then
        log "acquire_lock: stale lock (${age}s) detected, removing: ${lock_dir}"
        rm -rf "$lock_dir" 2>/dev/null || true
        continue  # 即座にリトライ（attempt を増加させない）
      fi
    fi

    attempt=$(( attempt + 1 ))
    sleep "$retry_interval"
  done

  log "Lock acquisition timeout: ${lock_dir}"
  return 1
}

# release_lock <lock_dir>
# ロックディレクトリを削除してロックを解放する。
release_lock() {
  local lock_dir="$1"
  rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
}
