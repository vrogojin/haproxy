#!/bin/bash
set -e

DOMAINS_MAP="${HAPROXY_DOMAINS_MAP:-/etc/haproxy/domains.map}"
CONF_DIR="${HAPROXY_CONF_DIR:-/etc/haproxy/conf.d}"
MAPS_DIR="${HAPROXY_MAPS_DIR:-/etc/haproxy/maps}"
STATE_DIR="${HAPROXY_STATE_DIR:-/etc/haproxy/state}"
TEMPLATES_DIR="${HAPROXY_TEMPLATES_DIR:-/usr/local/share/haproxy/templates}"

# Create domains.map if it doesn't exist (first run)
if [ ! -f "$DOMAINS_MAP" ]; then
    cat > "$DOMAINS_MAP" << 'MAPEOF'
# HAProxy Domain Mappings
# Format: domain  container  http_port  https_port  [map_port]  [extra:listen:target:mode] ...
# Managed by Registration API. Manual edits are preserved.
MAPEOF
fi

# Ensure directories exist
mkdir -p "$CONF_DIR" "$MAPS_DIR" "$STATE_DIR"

# Export for generate-config.sh
export HAPROXY_CONF_DIR="$CONF_DIR"
export HAPROXY_MAPS_DIR="$MAPS_DIR"
export HAPROXY_TEMPLATES_DIR="$TEMPLATES_DIR"
export HAPROXY_DOMAINS_MAP="$DOMAINS_MAP"
export HAPROXY_STATE_DIR="$STATE_DIR"

# Generate initial config from domains.map
echo "Generating initial HAProxy config..."
/usr/local/bin/generate-config.sh

# Clean stale lock files (>120s old)
find "$STATE_DIR" -name "*.lock" -mmin +2 -delete 2>/dev/null || true

# Start Registration API with auto-restart and exponential backoff
(
    BACKOFF=2
    MAX_BACKOFF=60
    CONSECUTIVE_FAILURES=0
    while true; do
        START_TIME=$(date +%s)
        echo "[api] Starting Registration API on port ${HAPROXY_API_PORT:-8404}..."
        node /usr/local/bin/registration-api.mjs 2>&1
        EXIT_CODE=$?
        ELAPSED=$(( $(date +%s) - START_TIME ))

        # If the API ran for more than 60 seconds, it was healthy -- reset backoff
        if [ $ELAPSED -ge 60 ]; then
            CONSECUTIVE_FAILURES=0
            BACKOFF=2
        else
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        fi

        if [ $CONSECUTIVE_FAILURES -ge 10 ]; then
            echo "[api] ERROR: Registration API crashed 10 times consecutively. Stopping restart loop." >&2
            break
        fi

        echo "[api] API exited (code $EXIT_CODE), restarting in ${BACKOFF}s (failure $CONSECUTIVE_FAILURES/10)..." >&2
        sleep $BACKOFF
        BACKOFF=$((BACKOFF * 2))
        [ $BACKOFF -gt $MAX_BACKOFF ] && BACKOFF=$MAX_BACKOFF
    done
) &
API_LOOP_PID=$!
echo "Registration API restart loop started (PID: $API_LOOP_PID)"

# Trap for clean shutdown
trap "kill $API_LOOP_PID 2>/dev/null; wait $API_LOOP_PID 2>/dev/null" TERM INT

# Start HAProxy in master-worker mode
echo "Starting HAProxy in master-worker mode..."
exec haproxy -W -f "$CONF_DIR" -S /var/run/haproxy-master.sock
