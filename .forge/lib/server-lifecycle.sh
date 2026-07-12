#!/bin/bash
# server-lifecycle.sh — 開発サーバーのライフサイクル管理サブシステム
# ralph-loop.sh から dev-phases.sh / phase3.sh より前に source される。単独では実行しない。
#
# 背景: 従来は phase-test スクリプトが `--keep-server` を無視し、誰もサーバーを
# 起動しないまま curl が connection refused → 回帰失敗と誤検知していた
# （z-lang / browser-cockpit で実害）。本モジュールが起動/停止を一元管理する。
#
# 所有権モデル:
#   - health_url が既に応答      → 外部所有（起動も kill もしない）
#   - 自前起動に成功             → 所有（teardown_server で必ず停止）
#   - start_command="none"/空    → 環境不足 rc=2（呼出側が env_blocked として繰延）
#
# 前提変数: DEV_CONFIG, WORK_DIR, DEV_LOG_DIR（任意: PROJECT_ROOT）
# 依存関数（common.sh）: log, now_ts, jq_safe

SERVER_LC_PID=""
SERVER_LC_OWNED=false
SERVER_LC_LAST_CODE=""
SERVER_LC_REASON=""
SERVER_LC_PID_FILE="${SERVER_LC_PID_FILE:-${PROJECT_ROOT:-.}/.forge/state/server.pid}"

# ===== HTTP コード取得 =====
# server_http_code <url> — HTTP ステータスコードを stdout に出す。
# 接続不能/エラーは "000"。常に rc=0（set -e 環境で安全）
server_http_code() {
  local url="$1"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null) || code="000"
  [ -z "$code" ] && code="000"
  printf '%s' "$code"
  return 0
}

# ===== サーバー到達可能性の保証 =====
# ensure_server_running
#   rc=0: 到達可能（外部所有検出 or 自前起動成功）
#   rc=1: 起動試行したが失敗（SERVER_LC_REASON / SERVER_LC_LAST_CODE に診断情報）
#   rc=2: 環境不足（start_command=none/空、health_check_url 空）— 繰延対象
ensure_server_running() {
  SERVER_LC_REASON=""

  local start_cmd health_url max_wait
  start_cmd=$(jq_safe -r '.server.start_command // "none"' "$DEV_CONFIG" 2>/dev/null)
  health_url=$(jq_safe -r '.server.health_check_url // ""' "$DEV_CONFIG" 2>/dev/null)
  max_wait=$(jq_safe -r '.server.startup_timeout_sec // 30' "$DEV_CONFIG" 2>/dev/null)
  case "$max_wait" in (*[!0-9]*|"") max_wait=30 ;; esac

  if [ -z "$health_url" ] || [ "$health_url" = "null" ]; then
    SERVER_LC_REASON="health_check_url 未設定"
    return 2
  fi

  # 冪等: 自前起動済みで生存していれば即 OK
  if [ "$SERVER_LC_OWNED" = "true" ] && [ -n "$SERVER_LC_PID" ] && kill -0 "$SERVER_LC_PID" 2>/dev/null; then
    return 0
  fi

  # 既に応答があるか（外部所有判定 — 起動も停止もしない）
  local code
  code=$(server_http_code "$health_url")
  SERVER_LC_LAST_CODE="$code"
  if [ "$code" != "000" ]; then
    case "$code" in
      2*|3*) log "  Server: 既存サーバーを検出（外部所有・HTTP ${code}）— 起動も停止もしない" ;;
      *)     log "  Server: 既存サーバーが応答するが health が HTTP ${code}（外部所有として扱う — health_check_url 設定を確認）" ;;
    esac
    SERVER_LC_OWNED=false
    return 0
  fi

  if [ -z "$start_cmd" ] || [ "$start_cmd" = "none" ] || [ "$start_cmd" = "null" ]; then
    SERVER_LC_REASON="server.start_command=none（サーバーを必要とするテストは環境不足として繰延）"
    return 2
  fi

  # 自前起動
  local server_log="${DEV_LOG_DIR:-/tmp}/server-lifecycle-$(now_ts).log"
  log "  Server: 起動 — ${start_cmd} (dir: ${WORK_DIR:-.}, health: ${health_url})"
  (cd "${WORK_DIR:-.}" && eval "$start_cmd") > "$server_log" 2>&1 &
  SERVER_LC_PID=$!
  SERVER_LC_OWNED=true
  mkdir -p "$(dirname "$SERVER_LC_PID_FILE")" 2>/dev/null || true
  printf '%s' "$SERVER_LC_PID" > "$SERVER_LC_PID_FILE" 2>/dev/null || true

  local i
  for i in $(seq 1 "$max_wait"); do
    code=$(server_http_code "$health_url")
    SERVER_LC_LAST_CODE="$code"
    case "$code" in
      2*|3*)
        log "  ✓ Server: 起動完了 (${i}秒, PID: ${SERVER_LC_PID}, HTTP ${code})"
        return 0
        ;;
    esac
    # 起動プロセス死亡の早期検出（診断はサーバーログ末尾を転記）
    if ! kill -0 "$SERVER_LC_PID" 2>/dev/null; then
      SERVER_LC_REASON="起動プロセスが早期終了（ログ末尾: $(tail -3 "$server_log" 2>/dev/null | tr '\n\r' '  ' | head -c 300)）"
      log "  ✗ Server: ${SERVER_LC_REASON}"
      SERVER_LC_PID=""
      SERVER_LC_OWNED=false
      rm -f "$SERVER_LC_PID_FILE" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done

  # タイムアウト: HTTP コード別に診断を区別する（従来は全部「起動タイムアウト」で不可視だった）
  case "$code" in
    000) SERVER_LC_REASON="connection refused（${max_wait}秒待機後も接続不能）" ;;
    404) SERVER_LC_REASON="サーバーは listen しているが health URL が HTTP 404 — development.json の health_check_url 設定を確認" ;;
    5*)  SERVER_LC_REASON="サーバーエラー HTTP ${code}" ;;
    *)   SERVER_LC_REASON="health check 失敗 HTTP ${code}" ;;
  esac
  log "  ✗ Server: 起動タイムアウト（${max_wait}秒）— ${SERVER_LC_REASON}"
  kill "$SERVER_LC_PID" 2>/dev/null || true
  wait "$SERVER_LC_PID" 2>/dev/null || true
  SERVER_LC_PID=""
  SERVER_LC_OWNED=false
  rm -f "$SERVER_LC_PID_FILE" 2>/dev/null || true
  return 1
}

# ===== サーバー停止 =====
# teardown_server — 自前起動（所有）したサーバーのみ停止。外部所有は触らない。常に rc=0
# 注意: Windows Git Bash では npm→node の孫プロセスが残り得る（既知限界）。
#       外部所有検出により誤 kill は起きない設計。
teardown_server() {
  if [ "$SERVER_LC_OWNED" = "true" ] && [ -n "$SERVER_LC_PID" ]; then
    log "  Server: 停止 (PID: ${SERVER_LC_PID})"
    kill "$SERVER_LC_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$SERVER_LC_PID" 2>/dev/null || true
    wait "$SERVER_LC_PID" 2>/dev/null || true
  fi
  SERVER_LC_PID=""
  SERVER_LC_OWNED=false
  rm -f "$SERVER_LC_PID_FILE" 2>/dev/null || true
  return 0
}

# ===== phase-test スクリプトのサーバー要否判定 =====
# phase_test_requires_server <script>
# stdout: "server" | "none"。常に rc=0
# 判定: 生成側契約マーカー `# forge-requires: server` を優先、
#       不在なら http 系コマンドのヒューリスティック（生成系未更新でも動くフォールバック）
phase_test_requires_server() {
  local script="$1"
  if [ ! -f "$script" ]; then
    echo "none"
    return 0
  fi
  if grep -q '^# forge-requires: server' "$script" 2>/dev/null; then
    echo "server"
    return 0
  fi
  if grep -qEi '(^|[^[:alnum:]_])(curl|wget)([^[:alnum:]_]|$)|https?://localhost|https?://127\.0\.0\.1' "$script" 2>/dev/null; then
    echo "server"
    return 0
  fi
  echo "none"
  return 0
}
