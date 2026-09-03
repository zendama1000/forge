#!/bin/bash
# patterns.sh — fnmatch 風パターン照合（純関数・外部プロセス不要）
#
# batch#11 R05 で common.sh から分離。理由: PreToolUse deny hook（.claude/hooks/forge-guard.sh）が
# 事後ゲート（validate_task_changes / validate_test_sanctity）と「同じ意味」で protected_patterns /
# protected_test_patterns を照合する必要があり、2,900 行の common.sh（source 時副作用あり）を
# hook から読み込むわけにはいかないため。common.sh は本ファイルを guarded source する。
#
# 実装は bash 組込みのみ（sed / grep を spawn しない）。hook は全ツール呼出で走り、Windows では
# プロセス生成 1 回 ≈ 30〜50ms なので、パターン 14 本 × 2 spawn = 1 秒/呼出の遅延になる。
#
# 提供関数:
#   fnmatch_to_regex <pattern>               → ERE を stdout へ（旧 API 互換）
#   fnmatch_to_regex_var <pattern> <varname>  → ERE を変数へ（fork なし）
#   match_protected_pattern <path> <pattern> → 0=一致 / 1=不一致
#
# 使い方（単体）: source .forge/lib/patterns.sh

# ===== fnmatch 風パターン → ERE 変換 =====
# ** = 任意階層（/ を跨ぐ）、* = セパレータ以外の任意文字列、他の ERE メタ文字はエスケープ。
# 出力は旧 sed 実装（batch#6 で二重バグ修正済）と同一文字列: ** → ".*"、* → "[^\/]*"。
# 使い方: fnmatch_to_regex_var "node_modules/**" regex  /  regex=$(fnmatch_to_regex "node_modules/**")
fnmatch_to_regex_var() {
  local p="$1" out="" i c
  for (( i=0; i<${#p}; i++ )); do
    c="${p:i:1}"
    case "$c" in
      '*')
        if [ "${p:i+1:1}" = '*' ]; then out+='.*'; i=$((i+1)); else out+='[^\/]*'; fi ;;
      '['|']'|'\'|'.'|'^'|'$'|'('|')'|'+'|'?'|'{'|'}'|'|')
        out+="\\${c}" ;;
      *)
        out+="$c" ;;
    esac
  done
  printf -v "$2" '%s' "$out"
}

fnmatch_to_regex() {
  local _re
  fnmatch_to_regex_var "$1" _re
  printf '%s' "$_re"
}

# ===== 保護パターン照合（batch#10 Stage2 — 意味の一元化） =====
# match_protected_pattern <path> <fnmatch_pattern> → 0=一致 / 1=不一致
# セマンティクス:
#   - パターンに '/' を含む（例: tests/**, node_modules/**）→ リポジトリルート起点で照合
#     （深層も守りたい規約ディレクトリは **/__tests__/** のように設定側で明示する）
#   - パターンに '/' を含まない（例: *.test.*, .env*, *.lock）→ 任意階層のベース名で照合
# 背景: 旧実装は validate_task_changes がルート起点、validate_test_sanctity が
# ^(.*/)?（任意階層プレフィックス）で、同じ設定文字列の意味が2関数で食い違っていた。
# tests/** の任意階層一致は experiment/tests/fixtures/ のフィクスチャ生成器
# （テストではない）まで凍結し、タスクが自分の成果物を直せなくなる実害を起こした。
match_protected_pattern() {
  local path="$1"
  local pattern="$2"
  local regex
  fnmatch_to_regex_var "$pattern" regex
  case "$pattern" in
    */*)
      regex="^${regex}\$"
      ;;
    *)
      regex="(^|/)${regex}\$"
      ;;
  esac
  [[ "$path" =~ $regex ]]
}
