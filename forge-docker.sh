#!/bin/bash
set -euo pipefail

# ============================================================
# forge-docker.sh — Forge Harness Docker multi-instance helper
# ============================================================
#
# Usage:
#   ./forge-docker.sh build                  Build the image
#   ./forge-docker.sh start <project-path>   Start a new instance
#   ./forge-docker.sh list                   List running instances
#   ./forge-docker.sh attach <name>          Attach to a running instance
#   ./forge-docker.sh stop <name>            Stop an instance
#   ./forge-docker.sh stopall                Stop all forge instances
#   ./forge-docker.sh logs <name>            Show container logs
#
# Options:
#   --name <name>     Override container name (default: derived from project dir)
#   --detach          Start in background (run harness via --daemonize inside)
#   --github-token    Pass GITHUB_TOKEN for harness push support

IMAGE_NAME="forge-harness"
CONTAINER_PREFIX="forge-"

# --- helpers ---

usage() {
    sed -n '/^# Usage:/,/^# Options:/p' "$0" | head -n -1 | sed 's/^# //'
    sed -n '/^# Options:/,/^$/p' "$0" | sed 's/^# //'
    exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Derive a container name from a project path
derive_name() {
    local path="$1"
    # Get the basename, lowercase, replace non-alphanumeric with dash
    basename "$path" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g; s/^-//; s/-$//'
}

# Convert path for Docker volume mount (handle Git Bash / MSYS path mangling)
docker_path() {
    local path="$1"
    # If running in MSYS/Git Bash, convert to Windows path
    if command -v cygpath &>/dev/null; then
        cygpath -w "$path"
    else
        echo "$path"
    fi
}

# --- commands ---

cmd_build() {
    echo "Building $IMAGE_NAME ..."
    MSYS_NO_PATHCONV=1 docker build -t "$IMAGE_NAME" .
    echo "Done. Image: $IMAGE_NAME"
}

cmd_start() {
    local project_path=""
    local container_name=""
    local detach=false
    local github_token="${GITHUB_TOKEN:-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     container_name="$2"; shift 2 ;;
            --detach)   detach=true; shift ;;
            --github-token) github_token="$2"; shift 2 ;;
            -*)         die "Unknown option: $1" ;;
            *)          project_path="$1"; shift ;;
        esac
    done

    [ -z "$project_path" ] && die "Usage: forge-docker.sh start <project-path> [--name NAME] [--detach]"

    # Resolve to absolute path
    project_path="$(cd "$project_path" 2>/dev/null && pwd)" || die "Directory not found: $project_path"

    # Derive container name
    if [ -z "$container_name" ]; then
        container_name="${CONTAINER_PREFIX}$(derive_name "$project_path")"
    else
        container_name="${CONTAINER_PREFIX}${container_name}"
    fi

    # Check if already running
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Container '$container_name' is already running."
        echo "Use: ./forge-docker.sh attach $container_name"
        return 1
    fi

    # Check if image exists
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "Image '$IMAGE_NAME' not found. Building..."
        cmd_build
    fi

    local docker_args=(
        run --rm
        --name "$container_name"
        -e "INSTANCE_NAME=$container_name"
    )

    # Pass API key if available
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        docker_args+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    fi

    # Pass GitHub token if available
    if [ -n "$github_token" ]; then
        docker_args+=(-e "GITHUB_TOKEN=$github_token")
    fi

    # Volume mount: project directory → /workspace/work
    local mount_path
    mount_path="$(docker_path "$project_path")"
    docker_args+=(-v "$mount_path:/workspace/work")

    if [ "$detach" = true ]; then
        docker_args+=(-d)
        MSYS_NO_PATHCONV=1 docker "${docker_args[@]}" "$IMAGE_NAME" tail -f /dev/null
        echo "Started '$container_name' in background."
        echo "Attach: ./forge-docker.sh attach ${container_name#$CONTAINER_PREFIX}"
        echo "Logs:   ./forge-docker.sh logs ${container_name#$CONTAINER_PREFIX}"
    else
        docker_args+=(-it)
        echo "Starting '$container_name' ..."
        echo "Project: $project_path -> /workspace/work"
        echo ""
        echo "  1) claude login"
        echo "  2) cd /workspace/work"
        echo "  3) bash .forge/loops/forge-flow.sh \"theme\" \"direction\" --daemonize"
        echo ""
        MSYS_NO_PATHCONV=1 docker "${docker_args[@]}" "$IMAGE_NAME" bash
    fi
}

cmd_list() {
    echo "Running forge instances:"
    echo "---"
    local found=false
    while IFS= read -r line; do
        found=true
        echo "$line"
    done < <(docker ps --filter "name=${CONTAINER_PREFIX}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)

    if [ "$found" = false ]; then
        echo "(none)"
    fi
}

cmd_attach() {
    local name="$1"
    [ -z "$name" ] && die "Usage: forge-docker.sh attach <name>"

    # Add prefix if not already present
    [[ "$name" != ${CONTAINER_PREFIX}* ]] && name="${CONTAINER_PREFIX}${name}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        die "Container '$name' is not running. Use: ./forge-docker.sh list"
    fi

    docker exec -it "$name" bash
}

cmd_stop() {
    local name="$1"
    [ -z "$name" ] && die "Usage: forge-docker.sh stop <name>"

    [[ "$name" != ${CONTAINER_PREFIX}* ]] && name="${CONTAINER_PREFIX}${name}"

    if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        echo "Stopping '$name' ..."
        docker stop "$name"
    else
        echo "Container '$name' is not running."
    fi
}

cmd_stopall() {
    local containers
    containers=$(docker ps --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null)

    if [ -z "$containers" ]; then
        echo "No running forge instances."
        return 0
    fi

    echo "Stopping all forge instances:"
    echo "$containers" | while read -r c; do
        echo "  Stopping $c ..."
        docker stop "$c"
    done
    echo "Done."
}

cmd_logs() {
    local name="$1"
    [ -z "$name" ] && die "Usage: forge-docker.sh logs <name>"

    [[ "$name" != ${CONTAINER_PREFIX}* ]] && name="${CONTAINER_PREFIX}${name}"

    docker logs -f "$name"
}

# --- main ---

[ $# -eq 0 ] && usage

command="$1"; shift

case "$command" in
    build)   cmd_build ;;
    start)   cmd_start "$@" ;;
    list)    cmd_list ;;
    attach)  cmd_attach "${1:-}" ;;
    stop)    cmd_stop "${1:-}" ;;
    stopall) cmd_stopall ;;
    logs)    cmd_logs "${1:-}" ;;
    help|-h|--help) usage ;;
    *)       die "Unknown command: $command. Run './forge-docker.sh help'" ;;
esac
