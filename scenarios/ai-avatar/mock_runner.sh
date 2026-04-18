#!/bin/bash
# scenarios/ai-avatar/mock_runner.sh — plugin_interface 契約の構造検証用 mock runner
#
# 目的:
#   実 API (heygen / hyperframes) を呼ばずに、plugin_interface が
#   scenario.json 内で適切に宣言されているか（provider / required_env[] /
#   mock_runner の 3 フィールド）を機械的に検証する。credentials 不在時の
#   fallback 経路であり、L3-003 structural テストのエントリポイント。
#
# 使い方:
#   bash scenarios/ai-avatar/mock_runner.sh
#
# 依存: jq
#
# 戻り値: 0=契約 OK / 非0=違反あり

set -uo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_JSON="${SCENARIO_DIR}/scenario.json"

log() { echo "[mock-runner:ai-avatar] $*"; }
err() { echo "[mock-runner:ai-avatar] ERROR: $*" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  err "jq が PATH に存在しません"
  exit 2
fi

if [ ! -f "$SCENARIO_JSON" ]; then
  err "scenario.json が見つかりません: $SCENARIO_JSON"
  exit 1
fi

# ---- plugin_interface セクション検査 -----------------------------------
if ! jq -e '.plugin_interface | type == "object"' "$SCENARIO_JSON" >/dev/null 2>&1; then
  err "plugin_interface が object でない/欠落している"
  exit 1
fi

PROVIDER=$(jq -r '.plugin_interface.provider // empty' "$SCENARIO_JSON" | tr -d '\r')
if [ -z "$PROVIDER" ]; then
  err "plugin_interface.provider が未定義または空"
  exit 1
fi

if ! jq -e '.plugin_interface.required_env | type == "array"' "$SCENARIO_JSON" >/dev/null 2>&1; then
  err "plugin_interface.required_env が配列でない"
  exit 1
fi

REQ_ENV_LEN=$(jq '.plugin_interface.required_env | length' "$SCENARIO_JSON")
if [ "${REQ_ENV_LEN:-0}" -lt 1 ]; then
  err "plugin_interface.required_env は最低 1 件必要（got=${REQ_ENV_LEN}）"
  exit 1
fi

MOCK_RUNNER=$(jq -r '.plugin_interface.mock_runner // empty' "$SCENARIO_JSON" | tr -d '\r')
if [ -z "$MOCK_RUNNER" ]; then
  err "plugin_interface.mock_runner が未定義"
  exit 1
fi

log "provider=${PROVIDER} required_env=${REQ_ENV_LEN}件 mock_runner=${MOCK_RUNNER}"

# ---- credentials 状態の報告（実 API 呼出はしない） ---------------------
missing_env=0
while IFS= read -r var; do
  [ -z "$var" ] && continue
  if [ -z "${!var:-}" ]; then
    log "  env: ${var} = (unset) — mock モードで継続"
    missing_env=$((missing_env + 1))
  else
    log "  env: ${var} = (set)"
  fi
done < <(jq -r '.plugin_interface.required_env[]' "$SCENARIO_JSON")

if [ "$missing_env" -gt 0 ]; then
  log "credentials 不在 (${missing_env}件) — fallback_strategy に従い mock で契約検証のみ実施"
fi

# ---- 契約 OK の痕跡を .tmp/ に書き出す（成果物は実動画ではない） --------
TMP_DIR="${SCENARIO_DIR}/.tmp"
mkdir -p "$TMP_DIR"
STATUS_JSON="${TMP_DIR}/mock_status.json"
jq -n \
  --arg provider "$PROVIDER" \
  --arg runner "$MOCK_RUNNER" \
  --argjson req_env "$(jq -c '.plugin_interface.required_env' "$SCENARIO_JSON")" \
  --argjson missing "$missing_env" \
  '{status:"ok", provider:$provider, mock_runner:$runner, required_env:$req_env, missing_env_count:$missing}' \
  > "$STATUS_JSON"

log "✓ plugin_interface 契約 OK — status=${STATUS_JSON}"
exit 0
