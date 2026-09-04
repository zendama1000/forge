#!/bin/bash
# forge-guard.sh — PreToolUse deny hook（batch#11 R05 後半。敵対レビュー 2026-09-03 の指摘を反映）
#
# 目的: Implementer / Fixer に Bash を返す（R05 前半）代わりに、ハーネス自身と作業ディレクトリ外への
# 書込・破壊的 git 操作・既存テストの改変を「機械的に」拒否する。プロンプト上の禁止文言は
# --dangerously-skip-permissions 下では何も強制しない（2026-09-02 監査）。run_claude が
# `--settings .forge/config/claude-guard-settings.json` で全呼出に注入する。
#
# 入力: stdin に Claude Code の PreToolUse hook JSON（tool_name / tool_input / cwd）
# 出力: 許可 = exit 0
#       拒否 = exit 2 + stderr（モデルに理由が届く）+ guard-denials.jsonl に 1 行
#       不正 JSON / 対象外ツール = exit 0（フェイルオープン。不正 JSON は stderr に警告）
#
# 環境変数（run_claude が export、ralph-loop.sh task_prepare がタスク文脈を上書き）:
#   FORGE_GUARD_WORK_DIR         作業ディレクトリ（空 = WORK_DIR 系の検査をスキップ、ハーネス保護は残る）
#   FORGE_GUARD_HARNESS_ROOT     ハーネスの PROJECT_ROOT（.forge/ .claude/ forge-*.sh CLAUDE.md を保護）
#   FORGE_GUARD_CB_CONFIG        circuit-breaker.json（protected_patterns / test_sanctity）
#   FORGE_GUARD_BASE_REF         タスク基準 SHA（既存テスト判定の基準。空なら HEAD）
#   FORGE_GUARD_ALLOW_TEST_EDITS true でテスト聖域検査を解除（task.allows_test_edits）
#   FORGE_GUARD_LOG              拒否ログ（既定: <HARNESS_ROOT>/.forge/state/guard-denials.jsonl）
#   FORGE_GUARD_TASK_ID          ログ用
#
# パス正規化（怠ると沈黙不発火になる — 監査で実測）: バックスラッシュ→/、相対は cwd 前置、
# /c/… → C:/…（MSYS 形式）、. / .. の解決、比較は小文字。/tmp 等の MSYS 仮想パスは「実在する最長の
# 祖先ディレクトリ」だけ cygpath -ml（長い名前）にかけて残りを連結する（-ml は不在パスに 8.3 短縮名を
# 返し、.. を含むとエラーになるため）。git への問い合わせだけは大小文字を保った相対パスで行う。
#
# Bash は引用符を解釈する字句解析（lex_line）で ; | & ( ) { } ` 改行を区切り、リダイレクト演算子を
# 独立トークンにする。ヒアドキュメント本文は先に落とす。bash -c / eval の文字列は再帰的に走査する。
# `cd` は以後のセグメントの基準ディレクトリを動かす。deny-list である以上、python -c 等の任意コードは
# 完全には塞げない（既知の限界。ハーネス保護対象の絶対パスが出現する書込系動詞は動詞に依らず拒否）。
#
# 性能: 全ツール呼出で走るため外部プロセスを最小化（通常経路は jq 1 回。WORK_DIR 内の書込は config
# 読取 +1、既存テスト判定で git +1〜2。Windows は 1 spawn ≈ 0.3〜0.6 秒）。字句解析は bash 組込み。
#
# 検査一覧:
#   Write/Edit/MultiEdit/NotebookEdit:
#     harness_protected  ハーネス root 配下の .forge/ .claude/ forge-*.sh CLAUDE.md
#     outside_work_dir   WORK_DIR 外（/dev/* /proc/* nul は除外）
#     protected_pattern  WORK_DIR 相対で circuit-breaker.json の protected_patterns（.forge/** 等）
#     test_sanctity      protected_test_patterns に一致し、かつ BASE_REF に既存のファイル（大小文字非依存）
#     guard_settings     WORK_DIR/.claude/settings*.json（disableAllHooks で hook を殺せるため）
#   Bash:
#     git_destructive    reset/checkout/clean/push/rebase/stash(list,show 以外)/restore/switch/update-ref/
#                        read-tree/worktree(list 以外)/symbolic-ref/reflog/gc/filter-branch/prune/branch -D|-d|-M
#     git_dir_override   git -C <WORK_DIR 外> / --git-dir / --work-tree / GIT_DIR= 等
#     rm_*               rm/rmdir/unlink/truncate/shred/find -delete の対象が WORK_DIR 外・ハーネス配下・.git・WORK_DIR 自身
#     書込先             リダイレクト（> >> >| &>）/ sed -i / perl -i / tee / cp・mv・ln・install・rsync の dest /
#                        git rm・mv / mv の source に protected_patterns・test_sanctity・guard_settings を適用
#     guard_var          FORGE_GUARD_* 変数の参照（ハーネス root の間接指定）
set -uo pipefail
set -f   # グロブ展開を止める

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

# 入力フィールドを jq 1 回で NUL 区切り抽出（command は改行を含み得る）。
# command substitution は NUL を捨てるため、process substitution から read -d '' で受ける
TOOL=""; CWD=""; RAW=""; CMD=""
{
  IFS= read -r -d '' TOOL || true
  IFS= read -r -d '' CWD || true
  IFS= read -r -d '' RAW || true
  IFS= read -r -d '' CMD || true
} < <(printf '%s' "$INPUT" | jq -j '[(.tool_name // ""), (.cwd // ""), (.tool_input.file_path // .tool_input.notebook_path // ""), (.tool_input.command // "")] | map(tostring) | join("\u0000")' 2>/dev/null; printf '\0')
if [ -z "$TOOL" ]; then
  if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
    echo "[forge-guard] warn: hook 入力が不正 JSON — 許可（フェイルオープン）" >&2
  fi
  exit 0
fi

case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit|Bash) ;;
  *) exit 0 ;;
esac
[ -n "$CWD" ] || CWD=$PWD

HR="${FORGE_GUARD_HARNESS_ROOT:-}"
WD="${FORGE_GUARD_WORK_DIR:-}"
CB="${FORGE_GUARD_CB_CONFIG:-}"
[ -n "$CB" ] || { [ -n "$HR" ] && CB="${HR}/.forge/config/circuit-breaker.json"; }
BASE_REF="${FORGE_GUARD_BASE_REF:-}"
ALLOW_TEST_EDITS="${FORGE_GUARD_ALLOW_TEST_EDITS:-false}"
LOG="${FORGE_GUARD_LOG:-}"
[ -n "$LOG" ] || { [ -n "$HR" ] && LOG="${HR}/.forge/state/guard-denials.jsonl"; }

# ---- patterns.sh（validate_task_changes / validate_test_sanctity と同じ照合意味論） ----
_g_dir="${BASH_SOURCE[0]%/*}"
[ "$_g_dir" = "${BASH_SOURCE[0]}" ] && _g_dir="."
for _cand in "${_g_dir}/../../.forge/lib/patterns.sh" "${HR:+${HR}/.forge/lib/patterns.sh}"; do
  [ -n "$_cand" ] && [ -f "$_cand" ] && { source "$_cand"; break; }
done
if ! declare -f match_protected_pattern >/dev/null; then
  echo "[forge-guard] warn: patterns.sh が見つかりません — protected_patterns / test_sanctity 検査をスキップ" >&2
  match_protected_pattern() { return 1; }
fi

# ---- パス正規化（fork なし。MSYS 仮想パスのみ cygpath 1 回） ----
CWD_N=""
# collapse_dots_var <path> <outvar> — ドライブ記号を保ったまま . / .. を解決
collapse_dots_var() {
  local _cd_p="$1" _cd_drive="" _cd_seg _cd_out=""
  if [[ "$_cd_p" =~ ^([A-Za-z]:)(.*)$ ]]; then _cd_drive="${BASH_REMATCH[1]}"; _cd_p="${BASH_REMATCH[2]}"; fi
  local -a _cd_parts=() _cd_stack=()
  IFS='/' read -r -a _cd_parts <<< "$_cd_p"
  for _cd_seg in "${_cd_parts[@]}"; do
    case "$_cd_seg" in
      ''|.) ;;
      ..) [ ${#_cd_stack[@]} -gt 0 ] && unset '_cd_stack[-1]' ;;
      *) _cd_stack+=("$_cd_seg") ;;
    esac
  done
  _cd_out="$_cd_drive"
  for _cd_seg in "${_cd_stack[@]}"; do _cd_out+="/${_cd_seg}"; done
  [ -n "$_cd_out" ] || _cd_out="/"
  printf -v "$2" '%s' "$_cd_out"
}
# norm_path_var <raw> <outvar>
norm_path_var() {
  local _np_p="$1"
  _np_p="${_np_p//\\//}"
  case "$_np_p" in
    "~") _np_p="${HOME:-/}" ;;
    "~/"*) _np_p="${HOME:-/}/${_np_p#\~/}" ;;
  esac
  case "$_np_p" in
    [A-Za-z]:*) ;;
    /[A-Za-z]/*) _np_p="${_np_p:1:1}:${_np_p:2}" ;;
    /[A-Za-z]) _np_p="${_np_p:1:1}:" ;;
    /*)
      if command -v cygpath >/dev/null 2>&1; then
        # MSYS 仮想パス（/tmp /home /usr …）: 先に . .. を解決し、実在する最長の祖先だけ変換する
        collapse_dots_var "$_np_p" _np_p
        local _np_anc="$_np_p" _np_rest=""
        while [ -n "$_np_anc" ] && [ "$_np_anc" != "/" ] && [ ! -d "$_np_anc" ]; do
          _np_rest="/${_np_anc##*/}${_np_rest}"
          _np_anc="${_np_anc%/*}"
          [ -n "$_np_anc" ] || _np_anc="/"
        done
        local _np_conv
        _np_conv=$(cygpath -ml -- "$_np_anc" 2>/dev/null) || _np_conv="$_np_anc"
        _np_conv="${_np_conv%/}"
        _np_p="${_np_conv}${_np_rest}"
      fi ;;
    *) _np_p="${CWD_N:-$CWD}/${_np_p}" ;;
  esac
  collapse_dots_var "$_np_p" _np_p
  printf -v "$2" '%s' "$_np_p"
}
norm_path_var "$CWD" CWD_N

# under <path_lc> <dir_lc> → 0 = dir 自身または配下
under() {
  [ -n "$2" ] || return 1
  [ "$1" = "$2" ] && return 0
  case "$1" in "$2"/*) return 0 ;; esac
  return 1
}

deny() {
  local reason="$1" target="$2"
  echo "[forge-guard] DENY (${reason}): ${target}" >&2
  case "$reason" in
    harness_protected*) echo "[forge-guard] ハーネス自身（.forge/ .claude/ forge-*.sh CLAUDE.md）は変更禁止です。作業ディレクトリ内の成果物だけを編集してください" >&2 ;;
    outside_work_dir*)  echo "[forge-guard] 作業ディレクトリ外への書込は禁止です: ${WD}" >&2 ;;
    protected_pattern*) echo "[forge-guard] 保護パターンに一致するファイルは変更禁止です（circuit-breaker.json protected_patterns）" >&2 ;;
    test_sanctity*)     echo "[forge-guard] 既存のテストファイルは改変禁止です（タスクに allows_test_edits が無い限り）。実装側を直してください。新規テストの追加は可" >&2 ;;
    guard_settings*)    echo "[forge-guard] .claude/settings*.json はハーネスの hook を無効化できるため変更禁止です" >&2 ;;
    guard_var*)         echo "[forge-guard] FORGE_GUARD_* 変数を使ったパス指定は禁止です" >&2 ;;
    git_*)              echo "[forge-guard] git reset/checkout/clean/push/rebase/stash/restore/switch/update-ref/worktree 等とハーネス側リポジトリの操作は禁止です。git add / commit / diff / log / status は可" >&2 ;;
    rm_*)               echo "[forge-guard] 作業ディレクトリ外・.git・作業ディレクトリ自身の削除は禁止です" >&2 ;;
  esac
  if [ -n "$LOG" ]; then
    mkdir -p "${LOG%/*}" 2>/dev/null || true
    jq -cn --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg tool "$TOOL" --arg reason "$reason" \
      --arg target "${target:0:300}" --arg task "${FORGE_GUARD_TASK_ID:-}" \
      --arg wd "${WDN:-}" --arg norm "${JP:-}" \
      '{ts:$ts,tool:$tool,reason:$reason,target:$target,task:$task,wd:$wd,norm:$norm}' >> "$LOG" 2>/dev/null || true
  fi
  exit 2
}

HRL=""; if [ -n "$HR" ]; then norm_path_var "$HR" HRL; HRL="${HRL,,}"; fi
WDN=""; WDL=""
if [ -n "$WD" ]; then norm_path_var "$WD" WDN; WDL="${WDN,,}"; fi

# harness_protected_rel <rel_lc> → 0 = ハーネス保護対象
harness_protected_rel() {
  case "$1" in
    .forge|.forge/*|.claude|.claude/*|forge-*.sh|claude.md) return 0 ;;
  esac
  return 1
}

# judge_path <raw> <ctx> — ハーネス保護 + WORK_DIR 外。通過時は正規化パス（大小文字保持）を JP に置く
JP=""
judge_path() {
  local raw="$1" ctx="$2" p pl rel_h
  local raw_lc="${raw//\\//}"; raw_lc="${raw_lc,,}"
  case "$raw" in *FORGE_GUARD_*) deny "guard_var" "${ctx}: ${raw}" ;; esac
  # /dev/null 等は正規化（cygpath）で別パスに化けるため生の形で除外
  case "$raw_lc" in /dev/*|nul|/proc/*) JP="$raw"; return 0 ;; esac
  norm_path_var "$raw" p; pl="${p,,}"; JP="$p"
  if [ -n "$HRL" ] && under "$pl" "$HRL"; then
    rel_h="${pl:$(( ${#HRL} + 1 ))}"
    [ "$pl" = "$HRL" ] && rel_h=""
    harness_protected_rel "$rel_h" && deny "harness_protected" "${ctx}: ${raw}"
  fi
  if [ -n "$WDL" ] && ! under "$pl" "$WDL"; then
    deny "outside_work_dir" "${ctx}: ${raw}"
  fi
  return 0
}

# rel_in_wd_var <norm_path> <outvar> — WORK_DIR 相対パス（大小文字保持）。WORK_DIR 外/未設定なら空
rel_in_wd_var() {
  local _rw_p="$1" _rw_pl="${1,,}"
  if [ -z "$WDL" ] || [ "$_rw_pl" = "$WDL" ] || ! under "$_rw_pl" "$WDL"; then printf -v "$2" ''; return; fi
  printf -v "$2" '%s' "${_rw_p:$(( ${#WDL} + 1 ))}"
}

# circuit-breaker.json の protected_patterns / test_sanctity を jq 1 回で読む（必要時のみ、1 回だけ）
CB_LOADED=0; CB_PROTECTED=(); CB_TEST=(); CB_TEST_ENABLED=true
load_cb() {
  [ "$CB_LOADED" = "1" ] && return 0
  CB_LOADED=1
  local line kind val
  # run_claude が事前に展開した FORGE_GUARD_PATTERNS（p:/t:/e: 行）があれば jq を spawn しない（性能）
  if [ -n "${FORGE_GUARD_PATTERNS:-}" ]; then
    while IFS= read -r line; do
      kind="${line%%:*}"; val="${line#*:}"
      case "$kind" in
        p) [ -n "$val" ] && CB_PROTECTED+=("$val") ;;
        t) [ -n "$val" ] && CB_TEST+=("$val") ;;
        e) CB_TEST_ENABLED="$val" ;;
      esac
    done <<< "$FORGE_GUARD_PATTERNS"
    return 0
  fi
  [ -n "$CB" ] && [ -f "$CB" ] || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    kind="${line%%:*}"; val="${line#*:}"
    case "$kind" in
      p) [ -n "$val" ] && CB_PROTECTED+=("$val") ;;
      t) [ -n "$val" ] && CB_TEST+=("$val") ;;
      e) CB_TEST_ENABLED="$val" ;;
    esac
  done < <(jq -r '(.protected_patterns[]? | "p:" + .), (.test_sanctity.protected_test_patterns[]? | "t:" + .), ("e:" + (if (.test_sanctity.enabled|type)=="boolean" then (.test_sanctity.enabled|tostring) else "true" end))' "$CB" 2>/dev/null)
}

# git_has_path_ci <ref> <rel> — 基準 SHA にファイルが存在するか（大小文字非依存の FS では ls-tree で再照合）
git_has_path_ci() {
  local ref="$1" rel="$2" f
  git -C "$WDN" cat-file -e "${ref}:${rel}" 2>/dev/null && return 0
  if [ "$(git -C "$WDN" config --get core.ignorecase 2>/dev/null)" = "true" ]; then
    while IFS= read -r f; do
      [ "${f,,}" = "${rel,,}" ] && return 0
    done < <(git -C "$WDN" ls-tree -r --name-only "$ref" 2>/dev/null)
  fi
  return 1
}

# check_write_rel <rel> <raw> — WORK_DIR 相対の書込先に protected_patterns / test_sanctity / guard_settings を適用
check_write_rel() {   # check_write_rel <rel> <raw> [mode]  — mode=rm は node_modules 系の保護を免除（削除は通常運用）
  local rel="$1" raw="$2" mode="${3:-write}" pat ref
  [ -n "$rel" ] || return 0
  case "${rel,,}" in .claude/settings*.json) deny "guard_settings" "${TOOL}: ${raw}" ;; esac
  load_cb
  for pat in "${CB_PROTECTED[@]}"; do
    [ "$mode" = "rm" ] && case "$pat" in *node_modules*) continue ;; esac
    if match_protected_pattern "$rel" "$pat"; then
      deny "protected_pattern(${pat})" "${TOOL}: ${raw}"
    fi
  done
  [ "$ALLOW_TEST_EDITS" = "true" ] && return 0
  [ "$CB_TEST_ENABLED" = "false" ] && return 0
  ref="${BASE_REF:-HEAD}"
  for pat in "${CB_TEST[@]}"; do
    if match_protected_pattern "$rel" "$pat"; then
      # 既存（基準 SHA に存在する）テストのみ拒否。新規テストの追加は可
      if [ -n "$WDN" ] && git_has_path_ci "$ref" "$rel"; then
        deny "test_sanctity(${pat})" "${TOOL}: ${raw}"
      fi
    fi
  done
  return 0
}

# judge_write_target <raw> <ctx> — 書込先の全検査
judge_write_target() {
  local raw="$1" ctx="$2" rel=""
  judge_path "$raw" "$ctx"
  rel_in_wd_var "$JP" rel
  check_write_rel "$rel" "$raw"
}

# ===== Write 系 =====
if [ "$TOOL" != "Bash" ]; then
  [ -n "$RAW" ] || exit 0
  judge_write_target "$RAW" "$TOOL"
  exit 0
fi

# ===== Bash =====
[ -n "$CMD" ] || exit 0

# ---- ヒアドキュメント本文を落とす（行単位。開始行は残す） ----
strip_heredocs_var() {   # strip_heredocs_var <cmd> <outvar>
  local _sh_in="$1" _sh_out="" _sh_line _sh_term="" _sh_trim
  local RE_HD='<<-?[[:space:]]*(["'"'"']?)([A-Za-z_][A-Za-z0-9_]*)\1'
  while IFS= read -r _sh_line || [ -n "$_sh_line" ]; do
    if [ -n "$_sh_term" ]; then
      _sh_trim="${_sh_line#"${_sh_line%%[![:space:]]*}"}"; _sh_trim="${_sh_trim%"${_sh_trim##*[![:space:]]}"}"
      [ "$_sh_trim" = "$_sh_term" ] && _sh_term=""
      continue
    fi
    if [[ "$_sh_line" =~ $RE_HD ]] && [[ "$_sh_line" != *"<<<"* ]]; then
      _sh_term="${BASH_REMATCH[2]}"
    fi
    _sh_out+="${_sh_line}"$'\n'
  done <<< "$_sh_in"
  printf -v "$2" '%s' "$_sh_out"
}

# ---- 字句解析（1 行）: 引用符を解釈し、区切り記号とリダイレクト演算子を独立トークンにする ----
# 出力: 配列 LEX_TOK（語 = そのまま、演算子 = 先頭に \x01）
_q="'"; _dq='"'; _bt='`'; _bs='\'
RE_WS='^[[:space:]]+'
RE_OP='^(\|\||&&|>>|>\||&>|>&|<<<|<<|>|<|;|\||&|\(|\)|\{|\}|`)'
RE_TOK="^(${_dq}([^${_dq}${_bs}]|${_bs}${_bs}.)*${_dq}|${_q}[^${_q}]*${_q}|${_bs}${_bs}.|[^[:space:];|&()<>{}${_bt}${_dq}${_q}${_bs}])+"
unquote_var() {   # unquote_var <token> <outvar> — 引用符とバックスラッシュを解く
  local _uq_in="$1" _uq_out="" _uq_i=0 _uq_c _uq_n=${#1} _uq_q=""
  case "$_uq_in" in *"'"*|*'"'*|*'\'*) ;; *) printf -v "$2" '%s' "$_uq_in"; return ;; esac
  while [ "$_uq_i" -lt "$_uq_n" ]; do
    _uq_c="${_uq_in:$_uq_i:1}"
    if [ -n "$_uq_q" ]; then
      if [ "$_uq_c" = "$_uq_q" ]; then _uq_q=""
      elif [ "$_uq_q" = '"' ] && [ "$_uq_c" = '\' ]; then _uq_i=$((_uq_i + 1)); _uq_out+="${_uq_in:$_uq_i:1}"
      else _uq_out+="$_uq_c"; fi
    else
      case "$_uq_c" in
        "'"|'"') _uq_q="$_uq_c" ;;
        '\') _uq_i=$((_uq_i + 1)); _uq_out+="${_uq_in:$_uq_i:1}" ;;
        *) _uq_out+="$_uq_c" ;;
      esac
    fi
    _uq_i=$((_uq_i + 1))
  done
  printf -v "$2" '%s' "$_uq_out"
}
lex_line() {   # lex_line <line> → LEX_TOK
  local _lx_rest="$1" _lx_t
  LEX_TOK=()
  while [ -n "$_lx_rest" ]; do
    if [[ "$_lx_rest" =~ $RE_WS ]]; then _lx_rest="${_lx_rest:${#BASH_REMATCH[0]}}"; continue; fi
    if [[ "$_lx_rest" =~ $RE_OP ]]; then
      LEX_TOK+=($'\x01'"${BASH_REMATCH[0]}"); _lx_rest="${_lx_rest:${#BASH_REMATCH[0]}}"; continue
    fi
    if [[ "$_lx_rest" =~ $RE_TOK ]]; then
      unquote_var "${BASH_REMATCH[0]}" _lx_t
      LEX_TOK+=("$_lx_t"); _lx_rest="${_lx_rest:${#BASH_REMATCH[0]}}"; continue
    fi
    # 閉じていない引用符など: 残りを 1 トークンとして扱う
    unquote_var "$_lx_rest" _lx_t; LEX_TOK+=("$_lx_t"); _lx_rest=""
  done
}

# ---- 動詞別の判定 ----
pathish() {
  case "$1" in
    ''|-*) return 1 ;;
    */*|*\\*|.forge|.claude|.git|.git*|'~'*|.|..|*FORGE_GUARD*) return 0 ;;
  esac
  return 1
}
judge_rm_target() {
  local raw="$1" rel pl
  judge_path "$raw" "rm"
  pl="${JP,,}"
  if [ -n "$WDL" ]; then
    [ "$pl" = "$WDL" ] && deny "rm_work_dir_root" "Bash: rm ${raw}"
    rel_in_wd_var "$JP" rel
    case "${rel,,}" in .git|.git/*|.git\**) deny "rm_git_dir" "Bash: rm ${raw}" ;; esac
    check_write_rel "$rel" "rm ${raw}" rm
  fi
}
is_writer_verb() {
  case "$1" in python|python3|py|node|perl|ruby|php|find|dd|tar|unzip|7z|zip|curl|wget|patch) return 0 ;; esac
  return 1
}
GIT_DESTRUCTIVE='reset checkout clean push rebase restore switch update-ref read-tree symbolic-ref reflog gc filter-branch prune'

# scan_segment <tokens...>（演算子は \x01 接頭辞）— 1 セグメントを判定
scan_segment() {
  local -a T=("$@")
  local n=${#T[@]} i t nxt
  # 1) リダイレクト先（> >> >| &>。>& / < / << / <<< は対象外）と、演算子を除いた語列 W を作る
  local -a W=()
  i=0
  while [ "$i" -lt "$n" ]; do
    t="${T[$i]}"
    case "$t" in
      $'\x01'">"|$'\x01'">>"|$'\x01'">|"|$'\x01'"&>")
        nxt="${T[$((i+1))]:-}"
        case "$nxt" in ''|$'\x01'*) ;; *) judge_write_target "$nxt" "redirect"; i=$((i + 1)) ;; esac ;;
      $'\x01'">&"|$'\x01'"<"|$'\x01'"<<"|$'\x01'"<<<")
        i=$((i + 1)) ;;   # fd 複製 / 入力: 次の語を読み飛ばす
      $'\x01'*) ;;
      *) W+=("$t") ;;
    esac
    i=$((i + 1))
  done
  [ ${#W[@]} -gt 0 ] || return 0
  set -- "${W[@]}"
  # 2) 先頭のラッパー・キーワード・環境代入を剥がす
  while [ $# -gt 0 ]; do
    case "$1" in
      sudo|env|command|exec|nohup|nice|builtin|xargs|stdbuf|ionice|if|then|else|elif|do|while|until|'!'|time) shift ;;
      timeout)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -s|-k|--signal|--kill-after) shift 2 ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        [ $# -gt 0 ] && [[ "$1" =~ ^[0-9.]+[smhd]?$ ]] && shift ;;
      *=*)
        case "$1" in
          GIT_DIR=*|GIT_WORK_TREE=*|GIT_INDEX_FILE=*|GIT_COMMON_DIR=*|GIT_OBJECT_DIRECTORY=*) deny "git_dir_override" "Bash: $*" ;;
          *FORGE_GUARD_*) deny "guard_var" "Bash: $1" ;;
        esac
        shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  local verb="$1"; shift
  local -a A=("$@")
  # 3) 語のどこかに FORGE_GUARD_* が出たら拒否（ハーネス root の間接指定）
  local w
  for w in "$verb" "${A[@]}"; do
    case "$w" in *FORGE_GUARD_*) deny "guard_var" "Bash: ${verb} ${A[*]}" ;; esac
  done
  case "$verb" in
    cd|pushd)
      # 以後のセグメントの基準ディレクトリを動かす
      t="${A[0]:-}"
      case "$t" in '') CWD_N="${HOME:-$CWD_N}" ;; -*) ;; *) norm_path_var "$t" CWD_N ;; esac
      return 0 ;;
    bash|sh|zsh|dash|ksh)
      i=0
      while [ "$i" -lt "${#A[@]}" ]; do
        if [ "${A[$i]}" = "-c" ] && [ -n "${A[$((i+1))]:-}" ]; then scan_command "${A[$((i+1))]}"; return 0; fi
        i=$((i + 1))
      done
      return 0 ;;
    eval) scan_command "${A[*]}"; return 0 ;;
    git)
      i=0
      while [ "$i" -lt "${#A[@]}" ]; do
        t="${A[$i]}"
        case "$t" in
          --git-dir*|--work-tree*|--namespace*) deny "git_dir_override" "Bash: git ${A[*]}" ;;
          -C)
            nxt="${A[$((i+1))]:-}"
            if [ -n "$nxt" ]; then
              judge_path "$nxt" "git -C"
              if [ -n "$WDL" ] && ! under "${JP,,}" "$WDL"; then deny "git_dir_override" "Bash: git ${A[*]}"; fi
            fi
            i=$((i + 2)); continue ;;
          -c|--exec-path|--super-prefix|--config-env) i=$((i + 2)); continue ;;
          -*) i=$((i + 1)); continue ;;
          *) break ;;
        esac
      done
      local sub="${A[$i]:-}" arg
      [ -n "$sub" ] || return 0
      local rest_i=$((i + 1))
      case " $GIT_DESTRUCTIVE " in *" $sub "*) deny "git_destructive" "Bash: git ${A[*]}" ;; esac
      case "$sub" in
        stash) case "${A[$rest_i]:-}" in list|show) ;; *) deny "git_destructive" "Bash: git ${A[*]}" ;; esac ;;
        worktree) case "${A[$rest_i]:-}" in list) ;; *) deny "git_destructive" "Bash: git ${A[*]}" ;; esac ;;
        branch)
          for arg in "${A[@]:$rest_i}"; do
            case "$arg" in -D|-d|-M|--delete|--force) deny "git_destructive" "Bash: git ${A[*]}" ;; esac
          done ;;
        rm|mv)
          for arg in "${A[@]:$rest_i}"; do
            case "$arg" in -*|'') continue ;; esac
            judge_write_target "$arg" "git ${sub}"
          done ;;
      esac
      return 0 ;;
    rm|rmdir|unlink|truncate|shred)
      for t in "${A[@]}"; do
        case "$t" in -*|'') continue ;; esac
        judge_rm_target "$t"
      done
      return 0 ;;
    find)
      local has_del=0
      for t in "${A[@]}"; do case "$t" in -delete|-exec|-execdir|-ok) has_del=1 ;; esac; done
      if [ "$has_del" = "1" ]; then
        for t in "${A[@]}"; do
          case "$t" in -*) break ;; '') continue ;; esac
          judge_rm_target "$t"
        done
      fi
      return 0 ;;
    sed|perl)
      local inplace=0 skip_script=1
      for t in "${A[@]}"; do
        case "$t" in
          --in-place*|-i*|-[A-Za-z]*i*) inplace=1 ;;   # -i / -i.bak / -Ei / -ri / -ni（glob は i の前に 1 文字要求するので -i* を別に置く）
        esac
        case "$t" in -e|--expression*|-f|--file*) skip_script=0 ;; esac
      done
      [ "$inplace" = "1" ] || return 0
      i=0
      while [ "$i" -lt "${#A[@]}" ]; do
        t="${A[$i]}"
        case "$t" in
          -e|-f|--expression|--file) i=$((i + 2)); continue ;;
          -*) i=$((i + 1)); continue ;;
        esac
        if [ "$skip_script" = "1" ]; then skip_script=0; i=$((i + 1)); continue; fi   # 最初の非オプション語はスクリプト
        judge_write_target "$t" "${verb} -i"
        i=$((i + 1))
      done
      return 0 ;;
    tee)
      for t in "${A[@]}"; do
        case "$t" in -*|'') continue ;; esac
        judge_write_target "$t" "tee"
      done
      return 0 ;;
    chmod|chown|chattr|touch|mkdir)
      for t in "${A[@]}"; do
        case "$t" in -*|'') continue ;; esac
        pathish "$t" && judge_path "$t" "$verb"
      done
      return 0 ;;
    cp|mv|ln|install|rsync)
      local dest="" last=""
      local -a srcs=()
      i=0
      while [ "$i" -lt "${#A[@]}" ]; do
        t="${A[$i]}"
        case "$t" in
          -t|--target-directory) dest="${A[$((i+1))]:-}"; i=$((i + 2)); continue ;;
          --target-directory=*) dest="${t#*=}"; i=$((i + 1)); continue ;;
          -*) i=$((i + 1)); continue ;;
        esac
        srcs+=("$t"); last="$t"; i=$((i + 1))
      done
      if [ -z "$dest" ] && [ -n "$last" ]; then
        dest="$last"; unset 'srcs[-1]'
      fi
      [ -n "$dest" ] && judge_write_target "$dest" "${verb} (dest)"
      if [ "$verb" = "mv" ]; then
        for t in "${srcs[@]}"; do judge_write_target "$t" "mv (source)"; done
      elif [ "$verb" = "ln" ]; then
        for t in "${srcs[@]}"; do pathish "$t" && judge_path "$t" "ln (target)"; done
      fi
      return 0 ;;
  esac
  # 4) 書込系のインタプリタ/ツール: 引数（引用文字列の内側も含む）に現れる絶対・.. 相対・~ のパスが
  #    ハーネス保護配下 or WORK_DIR 外なら拒否（python -c "open('<HR>/.forge/x','w')" 等。URL は除外）
  if is_writer_verb "$verb"; then
    local -a pieces=()
    local piece
    for t in "${A[@]}"; do
      case "$t" in *://*) continue ;; esac
      IFS="'\"(),;= " read -r -a pieces <<< "$t"
      for piece in "${pieces[@]}"; do
        case "$piece" in
          //*|'') continue ;;
          # 正規表現リテラル・メタ文字入りはパスではない（カナリア 2026-09-04: node -e の改行置換の正規表現
          # /(backslash)n/g と /[^x00-x7f]/.test が outside_work_dir で誤拒否された）
          *[\\[\]^\$\*+?\|{}\<\>]*) continue ;;
        esac
        # /pattern/flags 形（スラッシュ 2 本・末尾が JS 正規表現フラグのみ）も除外。/tmp/err は err がフラグでないので判定対象
        if [[ "$piece" =~ ^/[^/]+/[gimsuyd]*$ ]] && [[ ! "$piece" =~ ^/[^/]+/$ ]]; then continue; fi
        case "$piece" in
          /*|[A-Za-z]:/*|../*|..|'~'*|*/..|*/../*) judge_path "$piece" "$verb" ;;
        esac
      done
    done
  fi
  return 0
}

# scan_command <cmd> — ヒアドキュメント除去 → 行 → 字句解析 → セグメント毎に判定（bash -c / eval で再帰）
scan_command() {
  local _sc_cmd="$1" _sc_line _sc_stripped
  strip_heredocs_var "$_sc_cmd" _sc_stripped
  while IFS= read -r _sc_line || [ -n "$_sc_line" ]; do
    [ -n "$_sc_line" ] || continue
    lex_line "$_sc_line"
    local -a _sc_seg=()
    local _sc_t
    for _sc_t in "${LEX_TOK[@]}"; do
      case "$_sc_t" in
        $'\x01'";"|$'\x01'"&&"|$'\x01'"||"|$'\x01'"|"|$'\x01'"&"|$'\x01'"("|$'\x01'")"|$'\x01'"{"|$'\x01'"}"|$'\x01'"\`")
          [ ${#_sc_seg[@]} -gt 0 ] && scan_segment "${_sc_seg[@]}"
          _sc_seg=() ;;
        *) _sc_seg+=("$_sc_t") ;;
      esac
    done
    [ ${#_sc_seg[@]} -gt 0 ] && scan_segment "${_sc_seg[@]}"
  done <<< "$_sc_stripped"
  return 0
}

scan_command "$CMD"
exit 0
