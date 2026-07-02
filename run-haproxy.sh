#!/bin/bash
#
# HAProxy Docker Runner
#
# Reads allowed-ports.conf and starts the HAProxy container with all
# configured ports published. Services can only register ports that
# are in this allowed list — the Registration API enforces this.
#
# Usage:
#   ./run-haproxy.sh                       # Start with default config
#   ./run-haproxy.sh --ports-file /path    # Custom ports file
#   ./run-haproxy.sh --dry-run             # Show docker command without running
#   ./run-haproxy.sh --status              # Show running state
#
# Environment:
#   HAPROXY_IMAGE       Docker image (default: haproxy-api:latest)
#   HAPROXY_CONTAINER   Container name (default: haproxy)
#   HAPROXY_NET         Docker network (default: haproxy-net)
#   HAPROXY_VOLUME      Data volume (default: haproxy-data)
#   HAPROXY_API_KEY     Bearer token for API auth (optional)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Configuration ───────────────────────────────────────────────────────────
HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy-api:latest}"
HAPROXY_CONTAINER="${HAPROXY_CONTAINER:-haproxy}"
HAPROXY_NET="${HAPROXY_NET:-haproxy-net}"
HAPROXY_VOLUME="${HAPROXY_VOLUME:-haproxy-data}"
HAPROXY_API_KEY="${HAPROXY_API_KEY:-}"
PORTS_FILE="${PORTS_FILE:-${SCRIPT_DIR}/allowed-ports.conf}"
DRY_RUN=false

# Base ports always published (HAProxy core)
BASE_PORTS="80 443"
# Internal-only ports (never published to host)
INTERNAL_PORTS="8404"

# ─── Colors ──────────────────────────────────────────────────────────────────
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

# ─── Parse allowed-ports.conf ───────────────────────────────────────────────
parse_ports_file() {
    local file="$1"
    local ports=""

    if [ ! -f "$file" ]; then
        echo "ERROR: Ports file not found: $file" >&2
        exit 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # Strip comments and whitespace
        line="${line%%#*}"
        line="$(echo "$line" | xargs)"
        [ -z "$line" ] && continue

        # Handle ranges (e.g., 50001-50004)
        if [[ "$line" == *-* ]]; then
            local start="${line%-*}"
            local end="${line#*-}"
            if [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]]; then
                local range_size=$(( end - start + 1 ))
                if [ "$range_size" -gt 100 ]; then
                    echo "ERROR: Port range $line spans $range_size ports (max 100)" >&2
                    exit 1
                fi
                for port in $(seq "$start" "$end"); do
                    ports="${ports} ${port}"
                done
            else
                echo "WARNING: Invalid port range: $line" >&2
            fi
        elif [[ "$line" =~ ^[0-9]+$ ]]; then
            ports="${ports} ${line}"
        else
            echo "WARNING: Invalid port entry: $line" >&2
        fi
    done < "$file"

    # Deduplicate and sort
    echo "$ports" | tr ' ' '\n' | sort -un | tr '\n' ' '
}

# ─── Build ALLOWED_PORTS env value (comma-separated for Registration API) ───
build_allowed_ports_env() {
    local all_ports="$1"
    # Include base ports + configured ports (not internal)
    local combined="$BASE_PORTS $all_ports"
    echo "$combined" | xargs | tr ' ' '\n' | sort -un | paste -sd, -
}

# ─── Parse CLI arguments ────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --ports-file)
            PORTS_FILE="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --image)
            HAPROXY_IMAGE="$2"; shift 2 ;;
        --status)
            if docker ps --filter "name=^${HAPROXY_CONTAINER}$" --format '{{.Status}}' 2>/dev/null | grep -q .; then
                printf "${C_GREEN}Running${C_RESET}: "
                docker ps --filter "name=^${HAPROXY_CONTAINER}$" --format '{{.Status}}' 2>/dev/null
                echo ""
                echo "Published ports:"
                docker port "$HAPROXY_CONTAINER" 2>/dev/null | sort -t: -k1 -n
                echo ""
                echo "Allowed ports (from config):"
                parse_ports_file "$PORTS_FILE"
                echo ""
            else
                printf "${C_RED}Not running${C_RESET}\n"
            fi
            exit 0 ;;
        --help|-h)
            cat <<'HELP'
HAProxy Docker Runner

Starts HAProxy with all allowed ports pre-published. The Registration API
validates that services only register ports from this allowed list.

Usage:
  ./run-haproxy.sh                Start HAProxy
  ./run-haproxy.sh --dry-run      Show docker command without running
  ./run-haproxy.sh --status       Show running state and ports
  ./run-haproxy.sh --ports-file   Custom allowed-ports.conf path

Files:
  allowed-ports.conf   List of ports to publish (one per line, ranges ok)

Environment:
  HAPROXY_IMAGE        Docker image (default: haproxy-api:latest)
  HAPROXY_CONTAINER    Container name (default: haproxy)
  HAPROXY_NET          Docker network (default: haproxy-net)
  HAPROXY_API_KEY      Bearer token for API auth (optional)
HELP
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ─── Main ────────────────────────────────────────────────────────────────────

printf "\n${C_BOLD}HAProxy Runner${C_RESET}\n"
echo "════════════════════════════════════════"

# Parse ports
CONFIGURED_PORTS=$(parse_ports_file "$PORTS_FILE")
ALLOWED_PORTS_CSV=$(build_allowed_ports_env "$CONFIGURED_PORTS")

port_count=$(echo "$CONFIGURED_PORTS" | wc -w)
echo "  Image:      $HAPROXY_IMAGE"
echo "  Container:  $HAPROXY_CONTAINER"
echo "  Network:    $HAPROXY_NET"
echo "  Ports file: $PORTS_FILE"
echo "  Ports:      $port_count configured + 2 base (80, 443)"
echo "  Allowed:    $ALLOWED_PORTS_CSV"
echo ""

if [ "$DRY_RUN" = false ]; then
    # Ensure network exists
    docker network inspect "$HAPROXY_NET" >/dev/null 2>&1 || {
        echo "Creating network: $HAPROXY_NET"
        docker network create "$HAPROXY_NET"
    }

    # Stop existing container
    if docker ps -aq --filter "name=^${HAPROXY_CONTAINER}$" 2>/dev/null | grep -q .; then
        echo "Stopping existing container '$HAPROXY_CONTAINER'..."
        docker stop "$HAPROXY_CONTAINER" 2>/dev/null || true
        docker rm "$HAPROXY_CONTAINER" 2>/dev/null || true
    fi
fi

# Build docker command as an array (avoids eval injection)
CMD=(docker run -d
    --name "$HAPROXY_CONTAINER"
    --network "$HAPROXY_NET"
    --restart unless-stopped)

# Add port flags
for port in $BASE_PORTS; do
    CMD+=(-p "${port}:${port}")
done
for port in $CONFIGURED_PORTS; do
    skip=false
    for bp in $BASE_PORTS $INTERNAL_PORTS; do
        [ "$port" = "$bp" ] && { skip=true; break; }
    done
    [ "$skip" = true ] && continue
    CMD+=(-p "${port}:${port}")
done

# Add env flags
CMD+=(-e "ALLOWED_PORTS=${ALLOWED_PORTS_CSV}")
[ -n "$HAPROXY_API_KEY" ] && CMD+=(-e "HAPROXY_API_KEY=${HAPROXY_API_KEY}")

# Volume and image
CMD+=(-v "${HAPROXY_VOLUME}:/etc/haproxy" "$HAPROXY_IMAGE")

if [ "$DRY_RUN" = true ]; then
    echo "Dry run — would execute:"
    echo ""
    # Redact secrets in output
    printf '%s \\\n' "${CMD[@]}" | sed 's/HAPROXY_API_KEY=.*/HAPROXY_API_KEY=***REDACTED***/'
    echo ""
    exit 0
fi

# Run
echo "Starting HAProxy..."
"${CMD[@]}"

# Wait for health
echo "Waiting for HAProxy to start..."
for i in $(seq 1 30); do
    if docker exec "$HAPROXY_CONTAINER" curl -sf http://localhost:8404/v1/health >/dev/null 2>&1; then
        printf "\n${C_GREEN}HAProxy started successfully${C_RESET}\n"
        echo ""
        echo "Published ports:"
        docker port "$HAPROXY_CONTAINER" 2>/dev/null | sort -t: -k1 -n
        echo ""
        echo "Commands:"
        echo "  Logs:     docker logs -f $HAPROXY_CONTAINER"
        echo "  Status:   $0 --status"
        echo "  API:      curl http://\$(docker inspect $HAPROXY_CONTAINER --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'):8404/v1/backends"
        echo ""
        exit 0
    fi
    printf "\r  Starting... (%ds)" "$i"
    sleep 1
done

printf "\n${C_RED}HAProxy did not become healthy within 30s${C_RESET}\n"
echo "  Logs: docker logs $HAPROXY_CONTAINER"
exit 1
