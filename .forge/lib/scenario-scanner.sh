#!/bin/bash
# scenario-scanner.sh — scenarios/{id}/ ディレクトリスキャン型プラグイン検出
#
# SAC=1 指標の基盤:
#   scenarios/ 配下に新しいディレクトリ+ scenario.json を追加するだけで
#   ハーネスが自動的に新規シナリオを検出できる。ディスパッチテーブルや
#   設定ファイルへのハードコード追加を一切不要にする。
#
# 使い方 (API):
#   source .forge/lib/scenario-scanner.sh
#   scan_scenarios_dir <scenarios_root>      # 検出結果を JSON 配列で stdout へ
#   count_scenarios    <scenarios_root>      # 検出数を stdout へ
#   list_scenario_ids  <scenarios_root>      # 検出 id を改行区切りで stdout へ
#
# 使い方 (CLI):
#   bash .forge/lib/scenario-scanner.sh <scenarios_root> [--json|--count|--ids]
#
# 戻り値:
#   0: 正常（0件以上検出、整合性違反なし）
#   1: scenarios/ ディレクトリ自体が存在しない
#   2: id 不整合あり（ディレクトリ名と scenario.json.id が一致しない）
#   3: 使い方エラー
#
# 警告（スキップ動作）:
#   - scenario.json が欠落したディレクトリ … WARN + スキップ
#   - JSON パース失敗                        … WARN + スキップ
#   - id フィールド欠落                      … WARN + スキップ
#
# エラー（exit 非0）:
#   - scenarios/ ディレクトリ不在            … exit 1
#   - id ↔ ディレクトリ名 不整合             … exit 2（他の検出は継続するが exit は非0）
#
# 依存: jq, find, sort, basename
#
# 設計方針:
#   - ハードコード禁止: dispatch テーブルを使わず find で物理スキャン
#   - 中立出力: stdout は機械処理可能（JSON / count / ids）、stderr にメタ情報
#   - 冪等: 状態を持たない。毎回ファイルシステムを再スキャンする（= 再スキャン=+1 が自然に成立）

set -uo pipefail

# PROJECT_ROOT 推定（source されていない場合のため）
if [ -z "${PROJECT_ROOT:-}" ]; then
  _SS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "${_SS_SCRIPT_DIR}/../.." && pwd)"
fi

# --- stderr ヘルパー ------------------------------------------------------
_ss_err()  { echo "ERROR: $*" >&2; }
_ss_warn() { echo "WARN: $*"  >&2; }
_ss_info() { echo "INFO: $*"  >&2; }

# --- 内部: ディレクトリを物理スキャンし検出結果を JSON 配列で返す --------
# stdout: JSON 配列（例: [{"id":"slideshow","type":"image_slideshow","path":"..."}]）
# stderr: INFO/WARN/ERROR
# 戻り値: 0=OK, 1=dir不在, 2=id不整合あり
_ss_detect_scenarios() {
  local scenarios_dir="$1"

  if [ ! -d "$scenarios_dir" ]; then
    _ss_err "scenarios directory does not exist: $scenarios_dir"
    echo '[]'
    return 1
  fi

  local results='[]'
  local mismatch=0
  local total=0
  local detected=0

  # サブディレクトリを列挙（順序安定のため sort）
  local subdir
  while IFS= read -r subdir; do
    [ -z "$subdir" ] && continue
    [ ! -d "$subdir" ] && continue
    total=$((total + 1))

    local dirname
    dirname=$(basename "$subdir")
    local scenario_file="${subdir}/scenario.json"

    # scenario.json 欠落 → 警告してスキップ（他は検出継続）
    if [ ! -f "$scenario_file" ]; then
      _ss_warn "scenario.json missing in directory: ${dirname}/ (skipped)"
      continue
    fi

    # JSON パース失敗 → 警告してスキップ
    if ! jq empty "$scenario_file" >/dev/null 2>&1; then
      _ss_warn "scenario.json is not valid JSON: ${dirname}/scenario.json (skipped)"
      continue
    fi

    # id 取得
    local scenario_id
    scenario_id=$(jq -r '.id // empty' "$scenario_file" 2>/dev/null | tr -d '\r')
    if [ -z "$scenario_id" ]; then
      _ss_warn "scenario.json has no 'id' field: ${dirname}/scenario.json (skipped)"
      continue
    fi

    # 整合性検査: ディレクトリ名と id が一致するか
    if [ "$scenario_id" != "$dirname" ]; then
      _ss_err "consistency error: directory name '${dirname}' does not match scenario.json id '${scenario_id}'"
      mismatch=1
      continue
    fi

    # type 取得（enum 検証は scenario-validator.sh の責務。ここでは単に抽出）
    local scenario_type
    scenario_type=$(jq -r '.type // "unknown"' "$scenario_file" 2>/dev/null | tr -d '\r')

    # JSON 配列に追加（--arg でインジェクション対策）
    results=$(echo "$results" | jq --arg id "$scenario_id" \
                                    --arg type "$scenario_type" \
                                    --arg path "$scenario_file" \
      '. += [{id: $id, type: $type, path: $path}]')
    detected=$((detected + 1))
  done < <(find "$scenarios_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)

  # 結果 JSON を stdout へ
  echo "$results"
  _ss_info "scanned: ${total} directory/directories, detected: ${detected}"

  if [ "$mismatch" -gt 0 ]; then
    return 2
  fi
  return 0
}

# --- Public API: scan_scenarios_dir --------------------------------------
# stdout: 検出結果 JSON 配列
# 戻り値: _ss_detect_scenarios と同じ
scan_scenarios_dir() {
  if [ "$#" -lt 1 ]; then
    _ss_err "usage: scan_scenarios_dir <scenarios_dir>"
    return 3
  fi
  _ss_detect_scenarios "$1"
}

# --- Public API: count_scenarios -----------------------------------------
# stdout: 検出数（整数）
# 戻り値: 0=OK, 1=dir不在, 2=id不整合
count_scenarios() {
  if [ "$#" -lt 1 ]; then
    _ss_err "usage: count_scenarios <scenarios_dir>"
    return 3
  fi
  local scenarios_dir="$1"
  local output rc
  # stderr はそのまま流す（INFO/WARN/ERROR 可視化のため）
  output=$(_ss_detect_scenarios "$scenarios_dir")
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "0"
    return 1
  fi
  local n
  n=$(echo "$output" | jq 'length' 2>/dev/null)
  echo "${n:-0}"
  return $rc
}

# --- Public API: list_scenario_ids ---------------------------------------
# stdout: 検出 id を改行区切りで
# 戻り値: 0=OK, 1=dir不在, 2=id不整合
list_scenario_ids() {
  if [ "$#" -lt 1 ]; then
    _ss_err "usage: list_scenario_ids <scenarios_dir>"
    return 3
  fi
  local scenarios_dir="$1"
  local output rc
  output=$(_ss_detect_scenarios "$scenarios_dir")
  rc=$?
  if [ "$rc" -eq 1 ]; then
    return 1
  fi
  echo "$output" | jq -r '.[].id' 2>/dev/null
  return $rc
}

# --- CLI エントリポイント ------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: bash $0 <scenarios_dir> [--json|--count|--ids]" >&2
    exit 3
  fi

  _ss_dir="$1"
  _ss_mode="${2:---json}"

  case "$_ss_mode" in
    --json)
      scan_scenarios_dir "$_ss_dir"
      exit $?
      ;;
    --count)
      count_scenarios "$_ss_dir"
      exit $?
      ;;
    --ids)
      list_scenario_ids "$_ss_dir"
      exit $?
      ;;
    *)
      echo "Unknown mode: $_ss_mode (expected --json|--count|--ids)" >&2
      exit 3
      ;;
  esac
fi
