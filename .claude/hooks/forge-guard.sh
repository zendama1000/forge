#!/bin/bash
# forge-guard.sh — PreToolUse deny hook（batch#11 R05 後半）
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
# /c/… → C:/…（MSYS 形式）、. / .. の解決、比較は小文字。/tmp 等の MSYS 仮想パスのみ cygpath -ml
# （-l で 8.3 短縮名を長い名前へ。%TEMP% は BOSSBO~1 形式で返るため、これが無いと WORK_DIR 内も外扱いになる — 実 CLI スモークで実測）。
# git への問い合わせ（既存テスト判定）だけは大小文字を保った相対パスで行う。
#
# 性能: 全ツール呼出で走るため外部プロセスを最小化（通常経路は jq 1 回 + config 読取 1 回。
# Windows は 1 spawn ≈ 30〜50ms）。パターン照合は bash 組込み（patterns.sh）。
#
# 検査一覧:
#   Write/Edit/MultiEdit/NotebookEdit:
#     harness_protected  ハーネス root 配下の .forge/ .claude/ forge-*.sh CLAUDE.md
#     outside_work_dir   WORK_DIR 外（/dev/* /proc/* nul は除外）
#     protected_pattern  WORK_DIR 相対で circuit-breaker.json の protected_patterns（.forge/** 等）
#     test_sanctity      protected_test_patterns に一致し、かつ BASE_REF に既存のファイル
#   Bash:
#     git_destructive    git reset/checkout/clean/push/rebase/stash/restore/switch
#     git_dir_override   git -C <WORK_DIR 外> / --git-dir / --work-tree
#     rm_*               rm/rmdir/unlink/truncate の対象が WORK_DIR 外・ハーネス配下・.git・WORK_DIR 自身
#     redirect/sed -i/tee/cp/mv/ln/chmod/chown 等の書込先が WORK_DIR 外・ハーネス配下
set -uo pipefail
set -f   # 単語分割時のグロブ展開を止める（rm -rf * 等）

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

# 入力フィールドを jq 1 回で NUL 区切り抽出（command は改行を含み得る）
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
[ -n "$CWD" ] || CWD=$(pwd)

HR="${FORGE_GUARD_HARNESS_ROOT:-}"
WD="${FORGE_GUARD_WORK_DIR:-}"
CB="${FORGE_GUARD_CB_CONFIG:-}"
[ -n "$CB" ] || { [ -n "$HR" ] && CB="${HR}/.forge/config/circuit-breaker.json"; }
BASE_REF="${FORGE_GUARD_BASE_REF:-}"
ALLOW_TEST_EDITS="${FORGE_GUARD_ALLOW_TEST_EDITS:-false}"
LOG="${FORGE_GUARD_LOG:-}"
[ -n "$LOG" ] || { [ -n "$HR" ] && LOG="${HR}/.forge/state/guard-denials.jsonl"; }

# ---- patterns.sh（validate_task_changes / validate_test_sanctity と同じ照合意味論） ----
_g_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _cand in "${_g_dir}/../../.forge/lib/patterns.sh" "${HR:+${HR}/.forge/lib/patterns.sh}"; do
  [ -n "$_cand" ] && [ -f "$_cand" ] && { source "$_cand"; break; }
done
if ! declare -f match_protected_pattern >/dev/null; then
  echo "[forge-guard] warn: patterns.sh が見つかりません — protected_patterns / test_sanctity 検査をスキップ" >&2
  match_protected_pattern() { return 1; }
fi

# ---- パス正規化（fork なし。MSYS 仮想パスのみ cygpath 1 回） ----
CWD_N=""
# norm_path_var <raw> <outvar>
norm_path_var() {
  # 呼出側の outvar 名と衝突しないよう local は _np_ 接頭辞（bash は動的スコープ）
  local _np_p="$1" _np_drive="" _np_seg _np_out=""
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
        _np_p=$(cygpath -ml -- "$_np_p" 2>/dev/null) || _np_p="$1"   # -l: 8.3 短縮名（BOSSBO~1）を長い名前に展開
      fi ;;
    *) _np_p="${CWD_N:-$CWD}/${_np_p}" ;;
  esac
  if [[ "$_np_p" =~ ^([A-Za-z]:)(.*)$ ]]; then _np_drive="${BASH_REMATCH[1]}"; _np_p="${BASH_REMATCH[2]}"; fi
  local -a _np_parts=() _np_stack=()
  IFS='/' read -r -a _np_parts <<< "$_np_p"
  for _np_seg in "${_np_parts[@]}"; do
    case "$_np_seg" in
      ''|.) ;;
      ..) [ ${#_np_stack[@]} -gt 0 ] && unset '_np_stack[-1]' ;;
      *) _np_stack+=("$_np_seg") ;;
    esac
  done
  _np_out="$_np_drive"
  for _np_seg in "${_np_stack[@]}"; do _np_out+="/${_np_seg}"; done
  [ -n "$_np_out" ] || _np_out="/"
  printf -v "$2" '%s' "$_np_out"
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
    git_*)              echo "[forge-guard] git reset/checkout/clean/push/rebase/stash/restore/switch とハーネス側リポジトリの操作は禁止です。git add / commit / diff / log / status は可" >&2 ;;
    rm_*)               echo "[forge-guard] 作業ディレクトリ外・.git・作業ディレクトリ自身の削除は禁止です" >&2 ;;
  esac
  if [ -n "$LOG" ]; then
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
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

# judge_path <raw> <ctx> — ハーネス保護 + WORK_DIR 外。通過時は正規化パス（大小文字保持）を JP に置く
JP=""
judge_path() {
  local raw="$1" ctx="$2" p pl rel_h
  local raw_lc="${raw//\\//}"; raw_lc="${raw_lc,,}"
  # /dev/null 等は正規化（cygpath）で別パスに化けるため生の形で除外
  case "$raw_lc" in /dev/*|nul|/proc/*) JP="$raw"; return 0 ;; esac
  norm_path_var "$raw" p; pl="${p,,}"; JP="$p"
  if [ -n "$HRL" ] && under "$pl" "$HRL"; then
    rel_h="${pl:$(( ${#HRL} + 1 ))}"
    [ "$pl" = "$HRL" ] && rel_h=""
    case "$rel_h" in
      .forge|.forge/*|.claude|.claude/*|forge-*.sh|claude.md) deny "harness_protected" "${ctx}: ${raw}" ;;
    esac
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

# circuit-breaker.json の protected_patterns / test_sanctity を jq 1 回で読む
CB_PROTECTED=(); CB_TEST=(); CB_TEST_ENABLED=true
load_cb() {
  [ -n "$CB" ] && [ -f "$CB" ] || return 0
  local line kind val
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

check_protected_patterns() {
  local rel="$1" raw="$2" pat
  [ -n "$rel" ] || return 0
  for pat in "${CB_PROTECTED[@]}"; do
    if match_protected_pattern "$rel" "$pat"; then
      deny "protected_pattern(${pat})" "${TOOL}: ${raw}"
    fi
  done
  return 0
}

check_test_sanctity() {
  local rel="$1" raw="$2" pat ref
  [ -n "$rel" ] || return 0
  [ "$ALLOW_TEST_EDITS" = "true" ] && return 0
  [ "$CB_TEST_ENABLED" = "false" ] && return 0
  ref="${BASE_REF:-HEAD}"
  for pat in "${CB_TEST[@]}"; do
    if match_protected_pattern "$rel" "$pat"; then
      # 既存（基準 SHA に存在する）テストのみ拒否。新規テストの追加は可
      if [ -n "$WDN" ] && git -C "$WDN" cat-file -e "${ref}:${rel}" 2>/dev/null; then
        deny "test_sanctity(${pat})" "${TOOL}: ${raw}"
      fi
    fi
  done
  return 0
}

# ===== Write 系 =====
if [ "$TOOL" != "Bash" ]; then
  [ -n "$RAW" ] || exit 0
  judge_path "$RAW" "$TOOL"
  REL=""; rel_in_wd_var "$JP" REL
  if [ -n "$REL" ]; then
    load_cb
    check_protected_patterns "$REL" "$RAW"
    check_test_sanctity "$REL" "$RAW"
  fi
  exit 0
fi

# ===== Bash =====
[ -n "$CMD" ] || exit 0

# 破壊的 git（サブコマンドの前に -C <dir> / --no-pager / -c k=v を挟んでも検出）
RE_GIT_DESTRUCTIVE='(^|[;&|(`]|[[:space:]])git[[:space:]]+((-C[[:space:]]+[^[:space:]]+|--no-pager|-c[[:space:]]+[^[:space:]]+)[[:space:]]+)*(reset|checkout|clean|push|rebase|stash|restore|switch)([[:space:]]|$)'
RE_GIT_DIR='(^|[;&|(`]|[[:space:]])git[[:space:]]+[^;&|]*(--git-dir|--work-tree)'
if [[ "$CMD" =~ $RE_GIT_DESTRUCTIVE ]]; then deny "git_destructive" "Bash: ${CMD}"; fi
if [[ "$CMD" =~ $RE_GIT_DIR ]]; then deny "git_dir_override" "Bash: ${CMD}"; fi

# rm 対象の追加規則: .git / WORK_DIR 自身
judge_rm_target() {
  local raw="$1" rel pl
  judge_path "$raw" "rm"
  pl="${JP,,}"
  if [ -n "$WDL" ]; then
    [ "$pl" = "$WDL" ] && deny "rm_work_dir_root" "Bash: rm ${raw}"
    rel_in_wd_var "$JP" rel
    case "${rel,,}" in .git|.git/*) deny "rm_git_dir" "Bash: rm ${raw}" ;; esac
  fi
}

# トークンが「パスらしい」時だけ判定（相対の単純名は cwd=WORK_DIR 配下なので判定不要）
pathish() {
  case "$1" in
    ''|-*|'&'*|'2>&1') return 1 ;;
    */*|*\\*|.forge|.claude|'~'*|.|..) return 0 ;;
  esac
  return 1
}
strip_q() { local _sq="$1"; _sq="${_sq%\"}"; _sq="${_sq#\"}"; _sq="${_sq%\'}"; _sq="${_sq#\'}"; printf -v "$2" '%s' "$_sq"; }

# セグメント分割（; && || | 改行）— 純 bash
SEGS="${CMD//'||'/$'\n'}"
SEGS="${SEGS//'&&'/$'\n'}"
SEGS="${SEGS//;/$'\n'}"
SEGS="${SEGS//|/$'\n'}"
RE_REDIRECT='(^|[^&0-9])(>>?|&>)[[:space:]]*([^[:space:]>&|;]+)(.*)$'

while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # リダイレクト先（> >> &> のみ。2>&1 / >&2 は除外）
  rest="$seg"
  while [[ "$rest" =~ $RE_REDIRECT ]]; do
    t="${BASH_REMATCH[3]}"; rest="${BASH_REMATCH[4]}"
    strip_q "$t" t
    pathish "$t" && judge_path "$t" "redirect"
  done
  # 動詞
  set -- $seg
  while [ $# -gt 0 ]; do
    case "$1" in
      sudo|env|command|exec|nohup|time|nice|builtin) shift ;;
      *=*) case "$1" in */*|*\\*) break ;; *) shift ;; esac ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || continue
  verb="$1"; shift
  case "$verb" in
    git)
      # git -C <dir>: dir が WORK_DIR 外ならハーネス側リポジトリ操作とみなす
      while [ $# -gt 0 ]; do
        if [ "$1" = "-C" ] && [ $# -ge 2 ]; then
          strip_q "$2" t; judge_path "$t" "git -C"
          p_lc="${JP,,}"
          if [ -n "$WDL" ] && ! under "$p_lc" "$WDL"; then deny "git_dir_override" "Bash: ${seg}"; fi
          shift 2
        else
          shift
        fi
      done
      ;;
    rm|rmdir|unlink|truncate|shred)
      for t in "$@"; do
        strip_q "$t" t
        case "$t" in -*|'') continue ;; esac
        judge_rm_target "$t"
      done
      ;;
    sed)
      inplace=0
      for t in "$@"; do case "$t" in -i*|--in-place*) inplace=1 ;; esac; done
      if [ "$inplace" = "1" ]; then
        for t in "$@"; do
          strip_q "$t" t
          case "$t" in -*|'') continue ;; esac
          pathish "$t" && judge_path "$t" "sed -i"
        done
      fi
      ;;
    tee|chmod|chown|chattr|touch|mkdir)
      for t in "$@"; do
        strip_q "$t" t
        case "$t" in -*|'') continue ;; esac
        pathish "$t" && judge_path "$t" "$verb"
      done
      ;;
    cp|mv|ln|install|rsync)
      last=""
      for t in "$@"; do case "$t" in -*|'') ;; *) last="$t" ;; esac; done
      if [ -n "$last" ]; then
        strip_q "$last" last
        pathish "$last" && judge_path "$last" "$verb (dest)"
      fi
      ;;
  esac
done <<< "$SEGS"

exit 0
