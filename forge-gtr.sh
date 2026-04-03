#!/bin/bash
set -euo pipefail

# ============================================================
# forge-gtr.sh — Forge Harness git-worktree multi-project helper
# ============================================================
#
# Docker 代替。git worktree でプロジェクトごとの分離を実現する。
# git-worktree-runner (gtr) がインストール済みなら使用し、
# なければ raw git worktree コマンドにフォールバックする。
#
# Usage:
#   ./forge-gtr.sh setup                                 Check prerequisites
#   ./forge-gtr.sh new <name> [--from <dir>] [--base <ref>]  Create project worktree
#   ./forge-gtr.sh list                                  List project worktrees
#   ./forge-gtr.sh start <name> <theme> [direction] [forge-flow opts]  Start forge-flow
#   ./forge-gtr.sh ai <name>                             Launch Claude Code
#   ./forge-gtr.sh logs <name> [-f]                      Show forge-flow.log
#   ./forge-gtr.sh dashboard <name>                      Show dashboard
#   ./forge-gtr.sh stop <name>                           Stop forge-flow
#   ./forge-gtr.sh status [name]                         Show progress summary
#   ./forge-gtr.sh rm <name>                             Remove worktree
#   ./forge-gtr.sh clean                                 Remove merged worktrees
#
# Examples:
#   ./forge-gtr.sh new fortune-app
#   ./forge-gtr.sh start fortune-app "占いサービス" "Alpine.js + Hono"
#   ./forge-gtr.sh ai fortune-app
#   ./forge-gtr.sh status
#   ./forge-gtr.sh stop fortune-app
#   ./forge-gtr.sh rm fortune-app

# ===== Constants =====
BRANCH_PREFIX="project/"
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE_NAME=".forge/state/forge-flow.pid"

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ===== Helpers =====

usage() {
    cat <<'USAGE'
Usage:
  ./forge-gtr.sh setup                                 Check prerequisites
  ./forge-gtr.sh new <name> [--from <dir>] [--base <ref>]  Create project worktree
  ./forge-gtr.sh list                                  List project worktrees
  ./forge-gtr.sh start <name> <theme> [direction]      Start forge-flow (daemonize)
  ./forge-gtr.sh ai <name>                             Launch Claude Code
  ./forge-gtr.sh logs <name> [-f]                      Show forge-flow.log
  ./forge-gtr.sh dashboard <name>                      Show dashboard
  ./forge-gtr.sh stop <name>                           Stop forge-flow
  ./forge-gtr.sh status [name]                         Show progress summary
  ./forge-gtr.sh rm <name>                             Remove worktree
  ./forge-gtr.sh clean                                 Remove merged worktrees

Examples:
  ./forge-gtr.sh new fortune-app
  ./forge-gtr.sh start fortune-app "占いサービス" "Alpine.js + Hono"
  ./forge-gtr.sh ai fortune-app
  ./forge-gtr.sh status
  ./forge-gtr.sh stop fortune-app
  ./forge-gtr.sh rm fortune-app
USAGE
    exit 1
}

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

# Check if gtr is available
has_gtr() {
    command -v gtr &>/dev/null || command -v git-gtr &>/dev/null || git gtr --version &>/dev/null 2>&1
}

# Sanitize name for directory: slashes → hyphens
sanitize_dir_name() {
    echo "$1" | tr '/' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# Resolve worktree path from project name
resolve_wt() {
    local name="$1"
    local branch="${BRANCH_PREFIX}${name}"
    local path
    path=$(git -C "$HARNESS_ROOT" worktree list | grep "\\[${branch}\\]" | awk '{print $1}')
    if [ -z "$path" ]; then
        die "Worktree not found: ${branch}\nRun: ./forge-gtr.sh list"
    fi
    echo "$path"
}

# Check if forge-flow is running for a worktree, output PID if so
get_flow_pid() {
    local wt_path="$1"
    local pid_file="${wt_path}/${PID_FILE_NAME}"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
        # Stale PID file
        rm -f "$pid_file"
    fi
    return 1
}

# Read a JSON field from a file, return fallback on error
json_field() {
    local file="$1" query="$2" fallback="${3:-}"
    if [ -f "$file" ]; then
        jq -r "$query" "$file" 2>/dev/null || echo "$fallback"
    else
        echo "$fallback"
    fi
}

# ===== Commands =====

cmd_setup() {
    echo -e "${BOLD}Forge Harness — Prerequisites Check${NC}"
    echo ""

    local ok=true

    # git
    if command -v git &>/dev/null; then
        local gv
        gv=$(git --version | awk '{print $3}')
        echo -e "  ${GREEN}✓${NC} git ${gv}"
    else
        echo -e "  ${RED}✗${NC} git — not found"
        ok=false
    fi

    # jq
    if command -v jq &>/dev/null; then
        local jv
        jv=$(jq --version 2>/dev/null || echo "?")
        echo -e "  ${GREEN}✓${NC} jq ${jv}"
    else
        echo -e "  ${RED}✗${NC} jq — not found (required)"
        ok=false
    fi

    # claude CLI
    if command -v claude &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} claude CLI"
    else
        echo -e "  ${YELLOW}△${NC} claude CLI — not found (needed for 'ai' and 'start')"
    fi

    # gtr
    if has_gtr; then
        echo -e "  ${GREEN}✓${NC} git-worktree-runner (gtr)"
    else
        echo -e "  ${YELLOW}△${NC} gtr — not found (optional, using raw git worktree)"
        echo -e "       Install: ${DIM}npm install -g git-worktree-runner${NC}"
    fi

    # gh CLI
    if command -v gh &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} gh CLI (for 'clean --merged')"
    else
        echo -e "  ${DIM}△${NC} gh CLI — not found (optional, for 'clean --merged')"
    fi

    echo ""
    if [ "$ok" = true ]; then
        echo -e "${GREEN}Ready.${NC}"
    else
        echo -e "${RED}Missing required dependencies.${NC}"
        return 1
    fi
}

cmd_new() {
    local name="" base_ref="" from_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) base_ref="$2"; shift 2 ;;
            --from) from_dir="$2"; shift 2 ;;
            -*)     die "Unknown option: $1" ;;
            *)      name="$1"; shift ;;
        esac
    done

    [ -z "$name" ] && die "Usage: forge-gtr.sh new <name> [--base <ref>] [--from <project-dir>]"

    # Validate --from directory
    if [ -n "$from_dir" ]; then
        from_dir="$(cd "$from_dir" 2>/dev/null && pwd)" || die "Directory not found: $from_dir"
    fi

    local branch="${BRANCH_PREFIX}${name}"

    # Check if branch already exists as a worktree
    if git -C "$HARNESS_ROOT" worktree list | grep -q "\\[${branch}\\]"; then
        die "Worktree for '${branch}' already exists.\nUse: ./forge-gtr.sh ai ${name}"
    fi

    local wt_dir
    wt_dir="$(dirname "$HARNESS_ROOT")/$(basename "$HARNESS_ROOT")-$(sanitize_dir_name "$name")"

    if has_gtr; then
        # Use gtr (handles copy patterns, hooks, etc.)
        (cd "$HARNESS_ROOT" && gtr new "$branch")
    else
        # Fallback: raw git worktree
        if [ -n "$base_ref" ]; then
            git -C "$HARNESS_ROOT" worktree add -b "$branch" "$wt_dir" "$base_ref"
        else
            git -C "$HARNESS_ROOT" worktree add -b "$branch" "$wt_dir"
        fi

        # Manual post-create: copy .env if present
        if [ -f "${HARNESS_ROOT}/.env" ]; then
            cp "${HARNESS_ROOT}/.env" "${wt_dir}/.env"
            echo -e "  ${DIM}Copied .env${NC}"
        fi
    fi

    # Ensure state directories exist
    local resolved_path
    resolved_path=$(resolve_wt "$name")
    mkdir -p "${resolved_path}/.forge/state" "${resolved_path}/.forge/logs"

    # --from: copy existing project files into the worktree
    if [ -n "$from_dir" ]; then
        echo -e "  Copying project files from: ${from_dir}"

        # Copy everything except .git, node_modules, and harness dirs that already exist
        local exclude_args=(
            --exclude='.git'
            --exclude='node_modules'
            --exclude='.forge'
            --exclude='.claude'
        )

        # Use rsync if available, else fall back to cp
        if command -v rsync &>/dev/null; then
            rsync -a "${exclude_args[@]}" "${from_dir}/" "${resolved_path}/"
        else
            # cp fallback: copy non-conflicting files
            (cd "$from_dir" && find . -maxdepth 1 \
                ! -name '.' ! -name '.git' ! -name 'node_modules' \
                ! -name '.forge' ! -name '.claude' \
                -exec cp -r {} "${resolved_path}/" \;)
        fi

        echo -e "  ${GREEN}✓${NC} Project files copied"

        # Auto-detect server start command from package.json
        local pkg_json="${resolved_path}/package.json"
        if [ -f "$pkg_json" ]; then
            local dev_script
            dev_script=$(jq -r '.scripts.dev // .scripts.start // empty' "$pkg_json" 2>/dev/null)
            if [ -n "$dev_script" ]; then
                echo -e "  ${DIM}Detected script: ${dev_script}${NC}"
                echo -e "  ${YELLOW}→ development.json の server.start_command を確認してください${NC}"
            fi
        fi
    fi

    echo ""
    echo -e "${GREEN}✓ Worktree created${NC}"
    echo -e "  Branch: ${CYAN}${branch}${NC}"
    echo -e "  Path:   ${resolved_path}"
    [ -n "$from_dir" ] && echo -e "  From:   ${from_dir}"
    echo ""
    echo -e "  Next steps:"
    echo -e "    ${DIM}# Edit server config for this project${NC}"
    echo -e "    vi ${resolved_path}/.forge/config/development.json"
    echo -e ""
    echo -e "    ${DIM}# Launch Claude Code${NC}"
    echo -e "    ./forge-gtr.sh ai ${name}"
    echo -e ""
    echo -e "    ${DIM}# Or start forge-flow directly${NC}"
    echo -e "    ./forge-gtr.sh start ${name} \"テーマ\" \"方向性\""
}

cmd_list() {
    echo -e "${BOLD}Forge Worktrees${NC}"
    echo -e "────────────────────────────────────────────────────────────────────"

    local found=false

    while IFS= read -r line; do
        local wt_path branch_info
        wt_path=$(echo "$line" | awk '{print $1}')
        branch_info=$(echo "$line" | grep -oP '\[.*?\]' | tr -d '[]')

        # Skip non-project branches
        [[ "$branch_info" != ${BRANCH_PREFIX}* ]] && continue

        found=true
        local name="${branch_info#$BRANCH_PREFIX}"

        # Flow status
        local status_icon status_text pid_info=""
        local flow_pid
        if flow_pid=$(get_flow_pid "$wt_path"); then
            status_icon="${GREEN}●${NC}"
            status_text="RUNNING"
            pid_info=" PID=${flow_pid}"
        else
            status_icon="${DIM}○${NC}"
            status_text="IDLE"
        fi

        # Phase info
        local phase_info=""
        local progress_file="${wt_path}/.forge/state/progress.json"
        if [ -f "$progress_file" ]; then
            local phase stage
            phase=$(json_field "$progress_file" '.phase // ""')
            stage=$(json_field "$progress_file" '.stage // ""')
            if [ -n "$phase" ] && [ "$phase" != "null" ]; then
                phase_info="Phase ${phase}"
                [ -n "$stage" ] && [ "$stage" != "null" ] && phase_info="${phase_info}/${stage}"
            fi
        fi

        # Task info
        local task_info=""
        local task_stack="${wt_path}/.forge/state/task-stack.json"
        if [ -f "$task_stack" ]; then
            local total completed
            total=$(json_field "$task_stack" '.tasks | length' "0")
            completed=$(json_field "$task_stack" '[.tasks[] | select(.status == "completed")] | length' "0")
            if [ "$total" -gt 0 ]; then
                task_info="[${completed}/${total} tasks]"
            fi
        fi

        # Format output
        printf "  ${status_icon} %-20s %-25s %-10s%s\n" \
            "$name" \
            "${phase_info:-$([ "$status_text" = "IDLE" ] && echo "(not started)" || echo "")}" \
            "${task_info}" \
            "${status_text}${pid_info}"

    done < <(git -C "$HARNESS_ROOT" worktree list 2>/dev/null)

    if [ "$found" = false ]; then
        echo -e "  ${DIM}(no project worktrees)${NC}"
        echo ""
        echo -e "  Create one: ./forge-gtr.sh new <name>"
    fi

    echo -e "────────────────────────────────────────────────────────────────────"
}

cmd_start() {
    local name="" theme="" direction="" extra_args=()

    # First positional arg is name
    [ $# -ge 1 ] && { name="$1"; shift; }
    # Second positional arg is theme
    [ $# -ge 1 ] && { theme="$1"; shift; }
    # Third positional arg is direction (if not a flag)
    if [ $# -ge 1 ] && [[ "$1" != --* ]]; then
        direction="$1"; shift
    fi
    # Remaining args are passed through to forge-flow.sh
    extra_args=("$@")

    [ -z "$name" ] || [ -z "$theme" ] && \
        die "Usage: forge-gtr.sh start <name> <theme> [direction] [--research-config ...] [--phase-control ...]"

    local wt_path
    wt_path=$(resolve_wt "$name")

    # Check if already running
    local existing_pid
    if existing_pid=$(get_flow_pid "$wt_path"); then
        die "forge-flow already running in '${name}' (PID=${existing_pid}).\nStop first: ./forge-gtr.sh stop ${name}"
    fi

    # Build forge-flow args
    local flow_args=("$theme")
    [ -n "$direction" ] && flow_args+=("$direction")
    flow_args+=(--daemonize)
    flow_args+=("${extra_args[@]}")

    echo -e "${CYAN}Starting forge-flow in: ${name}${NC}"
    echo -e "  Theme: ${theme}"
    [ -n "$direction" ] && echo -e "  Direction: ${direction}"

    # Run forge-flow.sh from the worktree root
    local output
    output=$(cd "$wt_path" && bash .forge/loops/forge-flow.sh "${flow_args[@]}" 2>&1)

    # Extract PID from output
    local daemon_pid
    daemon_pid=$(echo "$output" | grep '^DAEMON_PID=' | head -1 | cut -d= -f2)

    if [ -n "$daemon_pid" ]; then
        # Write PID file
        mkdir -p "${wt_path}/.forge/state"
        echo "$daemon_pid" > "${wt_path}/${PID_FILE_NAME}"

        echo ""
        echo -e "${GREEN}✓ forge-flow started${NC}"
        echo -e "  PID:  ${daemon_pid}"
        echo -e "  Logs: ./forge-gtr.sh logs ${name}"
        echo -e "  Stop: ./forge-gtr.sh stop ${name}"
    else
        echo ""
        echo -e "${YELLOW}forge-flow output:${NC}"
        echo "$output"
    fi
}

cmd_ai() {
    local name="${1:-}"
    [ -z "$name" ] && die "Usage: forge-gtr.sh ai <name>"

    local wt_path
    wt_path=$(resolve_wt "$name")

    echo -e "${CYAN}Launching Claude Code in: ${wt_path}${NC}"

    if has_gtr; then
        (cd "$HARNESS_ROOT" && gtr ai "${BRANCH_PREFIX}${name}")
    else
        (cd "$wt_path" && claude)
    fi
}

cmd_logs() {
    local name="" follow=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow) follow=true; shift ;;
            -*)          die "Unknown option: $1" ;;
            *)           name="$1"; shift ;;
        esac
    done

    [ -z "$name" ] && die "Usage: forge-gtr.sh logs <name> [-f]"

    local wt_path
    wt_path=$(resolve_wt "$name")
    local log_file="${wt_path}/.forge/state/forge-flow.log"

    if [ ! -f "$log_file" ]; then
        die "Log file not found: ${log_file}\nHas forge-flow been started?"
    fi

    if [ "$follow" = true ]; then
        tail -f "$log_file"
    else
        tail -50 "$log_file"
    fi
}

cmd_dashboard() {
    local name="${1:-}"
    [ -z "$name" ] && die "Usage: forge-gtr.sh dashboard <name>"

    local wt_path
    wt_path=$(resolve_wt "$name")

    (cd "$wt_path" && bash .forge/loops/dashboard.sh)
}

cmd_stop() {
    local name="${1:-}"
    [ -z "$name" ] && die "Usage: forge-gtr.sh stop <name>"

    local wt_path
    wt_path=$(resolve_wt "$name")

    local pid
    if pid=$(get_flow_pid "$wt_path"); then
        echo -e "Stopping forge-flow in '${name}' (PID=${pid}) ..."

        # Kill process group if possible, else just the PID
        kill -TERM "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

        # Wait briefly for clean shutdown
        local wait_count=0
        while kill -0 "$pid" 2>/dev/null && [ $wait_count -lt 10 ]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done

        # Force kill if still alive
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            echo -e "${YELLOW}Force killed PID ${pid}${NC}"
        fi

        rm -f "${wt_path}/${PID_FILE_NAME}"
        echo -e "${GREEN}✓ Stopped${NC}"
    else
        echo -e "forge-flow is not running in '${name}'."
    fi
}

cmd_status() {
    local name="${1:-}"

    if [ -n "$name" ]; then
        # Single project status
        local wt_path
        wt_path=$(resolve_wt "$name")
        _show_project_status "$name" "$wt_path"
    else
        # All projects
        cmd_list
    fi
}

_show_project_status() {
    local name="$1" wt_path="$2"

    echo -e "${BOLD}Project: ${name}${NC}"
    echo -e "  Path: ${wt_path}"
    echo -e "  Branch: ${BRANCH_PREFIX}${name}"

    # Flow status
    local pid
    if pid=$(get_flow_pid "$wt_path"); then
        echo -e "  Flow: ${GREEN}RUNNING${NC} (PID=${pid})"
    else
        echo -e "  Flow: ${DIM}IDLE${NC}"
    fi

    # Progress
    local progress_file="${wt_path}/.forge/state/progress.json"
    if [ -f "$progress_file" ]; then
        local phase stage detail updated
        phase=$(json_field "$progress_file" '.phase // "?"')
        stage=$(json_field "$progress_file" '.stage // "?"')
        detail=$(json_field "$progress_file" '.detail // ""')
        updated=$(json_field "$progress_file" '.updated_at // "?"')
        echo -e "  Phase: ${CYAN}${phase}${NC}  Stage: ${stage}"
        [ -n "$detail" ] && [ "$detail" != "null" ] && echo -e "  Detail: ${detail}"
        echo -e "  Updated: ${DIM}${updated}${NC}"
    fi

    # Tasks
    local task_stack="${wt_path}/.forge/state/task-stack.json"
    if [ -f "$task_stack" ]; then
        local total completed pending failed in_progress blocked
        total=$(json_field "$task_stack" '.tasks | length' "0")
        completed=$(json_field "$task_stack" '[.tasks[] | select(.status == "completed")] | length' "0")
        pending=$(json_field "$task_stack" '[.tasks[] | select(.status == "pending")] | length' "0")
        failed=$(json_field "$task_stack" '[.tasks[] | select(.status == "failed")] | length' "0")
        in_progress=$(json_field "$task_stack" '[.tasks[] | select(.status == "in_progress")] | length' "0")
        blocked=$(json_field "$task_stack" '[.tasks[] | select(.status | startswith("blocked"))] | length' "0")

        if [ "$total" -gt 0 ]; then
            local pct=$((completed * 100 / total))
            echo -e "  Tasks: ${GREEN}${completed}${NC}/${total} (${pct}%)  pending=${pending} running=${CYAN}${in_progress}${NC} failed=${RED}${failed}${NC} blocked=${YELLOW}${blocked}${NC}"
        fi
    fi

    # Recent log
    local log_file="${wt_path}/.forge/state/forge-flow.log"
    if [ -f "$log_file" ]; then
        echo ""
        echo -e "  ${BOLD}Recent log:${NC}"
        tail -5 "$log_file" | sed 's/^/    /'
    fi
}

cmd_rm() {
    local name="${1:-}"
    [ -z "$name" ] && die "Usage: forge-gtr.sh rm <name>"

    local wt_path
    wt_path=$(resolve_wt "$name")
    local branch="${BRANCH_PREFIX}${name}"

    # Check if forge-flow is running
    if get_flow_pid "$wt_path" &>/dev/null; then
        die "forge-flow is still running in '${name}'.\nStop first: ./forge-gtr.sh stop ${name}"
    fi

    echo -e "Removing worktree: ${name}"
    echo -e "  Path:   ${wt_path}"
    echo -e "  Branch: ${branch}"

    # Try gtr first, fall back to git worktree remove on failure (Windows Permission denied)
    local removed=false
    if has_gtr; then
        (cd "$HARNESS_ROOT" && gtr rm "$branch") 2>/dev/null && removed=true
    fi

    if [ "$removed" = false ]; then
        git -C "$HARNESS_ROOT" worktree remove "$wt_path" --force 2>/dev/null || \
        git -C "$HARNESS_ROOT" worktree remove "$wt_path" 2>/dev/null || {
            # Windows: force remove directory then prune
            rm -rf "$wt_path"
            git -C "$HARNESS_ROOT" worktree prune
        }
        git -C "$HARNESS_ROOT" branch -d "$branch" 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Removed${NC}"
}

cmd_clean() {
    if has_gtr; then
        echo -e "Cleaning merged worktrees ..."
        (cd "$HARNESS_ROOT" && gtr clean --merged)
    else
        echo -e "${YELLOW}gtr not installed. Manual cleanup:${NC}"
        echo ""
        echo "  List worktrees:"
        echo "    git worktree list"
        echo ""
        echo "  Remove one:"
        echo "    git worktree remove <path>"
        echo "    git branch -d <branch>"
        echo ""
        echo "  Or install gtr:"
        echo "    npm install -g git-worktree-runner"
    fi
}

# ===== Main =====

[ $# -eq 0 ] && usage

command="$1"; shift

case "$command" in
    setup)      cmd_setup ;;
    new)        cmd_new "$@" ;;
    list|ls)    cmd_list ;;
    start)      cmd_start "$@" ;;
    ai)         cmd_ai "${1:-}" ;;
    logs|log)   cmd_logs "$@" ;;
    dashboard)  cmd_dashboard "${1:-}" ;;
    stop)       cmd_stop "${1:-}" ;;
    status|st)  cmd_status "${1:-}" ;;
    rm|remove)  cmd_rm "${1:-}" ;;
    clean)      cmd_clean ;;
    help|-h|--help) usage ;;
    *)          die "Unknown command: ${command}\nRun: ./forge-gtr.sh help" ;;
esac
