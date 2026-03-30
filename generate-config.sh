#!/usr/bin/env bash
# Generates conf.d/ and maps/ from domains.map
#
# Usage:
#   ./generate-config.sh                    # Host mode (relative paths)
#   HAPROXY_CONF_DIR=/etc/haproxy/conf.d \
#   HAPROXY_MAPS_DIR=/etc/haproxy/maps \
#   HAPROXY_TEMPLATES_DIR=/usr/local/share/haproxy/templates \
#   HAPROXY_DOMAINS_MAP=/etc/haproxy/domains.map \
#     generate-config.sh                    # Container mode (absolute paths)
#
# Environment Variables:
#   HAPROXY_CONF_DIR       - Output directory for config fragments (default: ./conf.d)
#   HAPROXY_MAPS_DIR       - Output directory for map files (default: ./maps)
#   HAPROXY_TEMPLATES_DIR  - Directory containing config templates (default: ./templates)
#   HAPROXY_DOMAINS_MAP    - Path to the domains.map file (default: ./domains.map)
#
# Exit Codes:
#   0 - Success
#   1 - General error (missing domains.map, parse error, etc.)

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Path resolution: use environment variables or fall back to relative paths
# ---------------------------------------------------------------------------

# If no env vars are set, fall back to script directory for legacy host usage
if [[ -z "${HAPROXY_CONF_DIR:-}" && -z "${HAPROXY_MAPS_DIR:-}" && \
      -z "${HAPROXY_TEMPLATES_DIR:-}" && -z "${HAPROXY_DOMAINS_MAP:-}" ]]; then
    cd "$(dirname "$0")"
fi

readonly CONF_DIR="${HAPROXY_CONF_DIR:-./conf.d}"
readonly MAPS_DIR="${HAPROXY_MAPS_DIR:-./maps}"
readonly TEMPLATES_DIR="${HAPROXY_TEMPLATES_DIR:-./templates}"
readonly DOMAINS_MAP="${HAPROXY_DOMAINS_MAP:-./domains.map}"
readonly STATE_DIR="${HAPROXY_STATE_DIR:-./state}"

# ---------------------------------------------------------------------------
# File-level lock to prevent concurrent generate-config.sh executions
# ---------------------------------------------------------------------------
LOCK_FILE="${STATE_DIR}/generate-config.lock"
mkdir -p "$STATE_DIR"

exec 9>"$LOCK_FILE"
if ! flock -w 30 9; then
    echo "Error: Could not acquire lock (another generate-config.sh running?)" >&2
    exit 1
fi
# Lock is held for the rest of the script (released automatically on exit)

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

if [[ ! -f "$DOMAINS_MAP" ]]; then
    printf 'Error: domains.map not found at %s\n' "$DOMAINS_MAP" >&2
    exit 1
fi

if [[ ! -d "$TEMPLATES_DIR" ]]; then
    printf 'Error: templates directory not found at %s\n' "$TEMPLATES_DIR" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Determine map file path prefix for generated HAProxy config references
# If HAPROXY_MAPS_DIR is an absolute path, use it directly (container mode).
# Otherwise, fall back to the path used in the templates for backward compat.
# ---------------------------------------------------------------------------

if [[ "$MAPS_DIR" == /* ]]; then
    readonly MAP_PATH_PREFIX="$MAPS_DIR"
else
    readonly MAP_PATH_PREFIX="/usr/local/etc/haproxy/maps"
fi

echo "Generating HAProxy config from ${DOMAINS_MAP}..."

# ---------------------------------------------------------------------------
# Create output directories
# ---------------------------------------------------------------------------

mkdir -p "$CONF_DIR" "$MAPS_DIR"

# ---------------------------------------------------------------------------
# Copy templates to conf.d (except mapdownload which is conditional)
# ---------------------------------------------------------------------------

cp "${TEMPLATES_DIR}/00-global.cfg" "${TEMPLATES_DIR}/10-frontends.cfg" "${CONF_DIR}/"

# ---------------------------------------------------------------------------
# Clean stale extra port files from previous runs
# ---------------------------------------------------------------------------

rm -f "${CONF_DIR}/30-extra-frontends.cfg"
rm -f "${MAPS_DIR}"/extra-*-domains.map

# ---------------------------------------------------------------------------
# Initialize generated files
# ---------------------------------------------------------------------------

> "${MAPS_DIR}/http-domains.map"
> "${MAPS_DIR}/https-domains.map"
> "${MAPS_DIR}/mapdownload-domains.map"

{
    echo "# Auto-generated backends from domains.map"
    echo "# Generated at: $(date)"
} > "${CONF_DIR}/20-backends.cfg"

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------

# Track if any map_port entries exist
has_mapdownload=false

# Track extra ports: associative arrays keyed by listen port
declare -A EXTRA_LISTEN_PORTS    # listen_port -> mode (http|tcp)
declare -A EXTRA_MAP_ENTRIES     # listen_port -> "domain backend_name\n..."
declare -A EXTRA_PORT_DOMAIN_COUNT  # listen_port -> number of domains
declare -A EXTRA_SINGLE_BACKEND  # listen_port -> backend name (for single-domain tcp)
declare -A SEEN_DOMAINS          # domain -> 1 (deduplication: last entry wins)
has_extra_ports=false

# ---------------------------------------------------------------------------
# Process domains.map
# ---------------------------------------------------------------------------

count=0
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Parse all fields -- first 5 are positional, rest are extra ports
    # shellcheck disable=SC2086
    read -ra fields <<< "$line"

    domain="${fields[0]:-}"
    container="${fields[1]:-}"
    http_port="${fields[2]:-}"
    https_port="${fields[3]:-}"
    map_port="${fields[4]:-}"

    # Validate we have required fields
    if [[ -z "$domain" || -z "$container" || -z "$http_port" || -z "$https_port" ]]; then
        echo "Warning: Skipping invalid line: $line"
        continue
    fi

    # Deduplicate: if we've already seen this domain, skip (last entry wins via two-pass)
    if [[ -n "${SEEN_DOMAINS[$domain]:-}" ]]; then
        echo "Warning: Duplicate domain '$domain', using first occurrence" >&2
        continue
    fi
    SEEN_DOMAINS["$domain"]=1

    # Validate fields (defense-in-depth — API should have validated already)
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
        echo "Warning: Skipping invalid domain: $domain" >&2
        continue
    fi
    if [[ ! "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "Warning: Skipping invalid container: $container" >&2
        continue
    fi

    # Generate HTTP map entry and backend (skip if port is -)
    if [[ "$http_port" != "-" ]]; then
        printf '%s    %s-http\n' "$domain" "$container" >> "${MAPS_DIR}/http-domains.map"
        cat >> "${CONF_DIR}/20-backends.cfg" << EOF

backend ${container}-http
    mode http
    server ${container} ${container}:${http_port} init-addr last,libc,none
EOF
    fi

    # Generate HTTPS map entry and backend (skip if port is -)
    if [[ "$https_port" != "-" ]]; then
        printf '%s    %s-https\n' "$domain" "$container" >> "${MAPS_DIR}/https-domains.map"
        cat >> "${CONF_DIR}/20-backends.cfg" << EOF

backend ${container}-https
    mode tcp
    server ${container} ${container}:${https_port} check inter 5s fall 3 rise 2 init-addr last,libc,none
EOF
    fi

    # Generate mapdownload backend if 5th field is specified and not -
    if [[ -n "$map_port" && "$map_port" != "-" ]]; then
        has_mapdownload=true
        printf '%s    %s-mapdownload\n' "$domain" "$container" >> "${MAPS_DIR}/mapdownload-domains.map"
        cat >> "${CONF_DIR}/20-backends.cfg" << EOF

backend ${container}-mapdownload
    mode http
    timeout server 5m
    server ${container} ${container}:${map_port} init-addr last,libc,none
EOF
    fi

    # Parse extra port fields (fields 6+, index 5+)
    for (( i=5; i<${#fields[@]}; i++ )); do
        extra_field="${fields[$i]}"

        # Extra port fields must start with "extra:"
        if [[ "$extra_field" != extra:* ]]; then
            echo "Warning: Ignoring unrecognized field: $extra_field"
            continue
        fi

        # Parse extra:listen:target:mode
        IFS=':' read -r _ listen_port target_port extra_mode <<< "$extra_field"

        if [[ -z "$listen_port" || -z "$target_port" || -z "$extra_mode" ]]; then
            echo "Warning: Skipping malformed extra port field: $extra_field"
            continue
        fi

        if [[ "$extra_mode" != "http" && "$extra_mode" != "tcp" ]]; then
            echo "Warning: Skipping extra port with invalid mode '${extra_mode}': $extra_field"
            continue
        fi

        # Check for mode conflict on same listen port
        if [[ -n "${EXTRA_LISTEN_PORTS[$listen_port]:-}" && "${EXTRA_LISTEN_PORTS[$listen_port]}" != "$extra_mode" ]]; then
            printf 'Error: Mode conflict on listen port %s: existing mode=%s, new mode=%s\n' \
                "$listen_port" "${EXTRA_LISTEN_PORTS[$listen_port]}" "$extra_mode" >&2
            exit 1
        fi

        # Register this listen port
        EXTRA_LISTEN_PORTS["$listen_port"]="$extra_mode"
        has_extra_ports=true

        # Backend name format: <container>-extra-<listen>
        local_backend="${container}-extra-${listen_port}"

        # Add map entry for this port
        if [[ -n "${EXTRA_MAP_ENTRIES[$listen_port]:-}" ]]; then
            EXTRA_MAP_ENTRIES["$listen_port"]+=$'\n'"${domain}    ${local_backend}"
        else
            EXTRA_MAP_ENTRIES["$listen_port"]="${domain}    ${local_backend}"
        fi

        # Count domains per listen port
        EXTRA_PORT_DOMAIN_COUNT["$listen_port"]=$(( ${EXTRA_PORT_DOMAIN_COUNT[$listen_port]:-0} + 1 ))
        EXTRA_SINGLE_BACKEND["$listen_port"]="$local_backend"

        # Generate backend block for this extra port
        if [[ "$extra_mode" == "http" ]]; then
            cat >> "${CONF_DIR}/20-backends.cfg" << EOF

backend ${local_backend}
    mode http
    server ${container} ${container}:${target_port} check inter 5s fall 3 rise 2 init-addr last,libc,none
EOF
        else
            cat >> "${CONF_DIR}/20-backends.cfg" << EOF

backend ${local_backend}
    mode tcp
    server ${container} ${container}:${target_port} check inter 5s fall 3 rise 2 init-addr last,libc,none
EOF
        fi
    done

    # Log what we added
    count=$((count + 1))
    msg="  Added: ${domain} -> ${container} (HTTP:${http_port}, HTTPS:${https_port}"
    if [[ -n "$map_port" && "$map_port" != "-" ]]; then
        msg+=", Map:${map_port}"
    fi
    # Count extra ports for this domain
    extra_count=0
    for (( i=5; i<${#fields[@]}; i++ )); do
        if [[ "${fields[$i]}" == extra:* ]]; then
            extra_count=$((extra_count + 1))
        fi
    done
    if (( extra_count > 0 )); then
        msg+=", Extra:${extra_count}"
    fi
    msg+=")"
    echo "$msg"

done < "$DOMAINS_MAP"

# ---------------------------------------------------------------------------
# Only copy mapdownload frontend template if we have map_port entries
# ---------------------------------------------------------------------------

if [[ "$has_mapdownload" == "true" ]]; then
    cp "${TEMPLATES_DIR}/15-frontend-mapdownload.cfg" "${CONF_DIR}/"
    echo ""
    echo "Map download frontend enabled (port 8000)"
fi

# ---------------------------------------------------------------------------
# Generate extra port frontends and map files
# ---------------------------------------------------------------------------

if [[ "$has_extra_ports" == "true" ]]; then
    # Initialize the extra frontends config file
    {
        echo "# Auto-generated extra port frontends"
        echo "# Generated at: $(date)"
    } > "${CONF_DIR}/30-extra-frontends.cfg"

    # Process each unique listen port
    for listen_port in $(printf '%s\n' "${!EXTRA_LISTEN_PORTS[@]}" | sort -n); do
        extra_mode="${EXTRA_LISTEN_PORTS[$listen_port]}"
        domain_count="${EXTRA_PORT_DOMAIN_COUNT[$listen_port]}"
        map_file="${MAPS_DIR}/extra-${listen_port}-domains.map"

        # Write the map file for this port
        printf '%s\n' "${EXTRA_MAP_ENTRIES[$listen_port]}" > "$map_file"

        # Generate frontend block
        if [[ "$extra_mode" == "http" ]]; then
            # HTTP mode: always use host-based map routing
            cat >> "${CONF_DIR}/30-extra-frontends.cfg" << EOF

frontend extra-http-${listen_port}
    mode http
    bind *:${listen_port}
    use_backend %[req.hdr(host),lower,regsub(:.*$,,),map(${MAP_PATH_PREFIX}/extra-${listen_port}-domains.map,no-match)]
EOF
        elif (( domain_count == 1 )); then
            # TCP mode with single domain: use default_backend (no SNI)
            single_backend="${EXTRA_SINGLE_BACKEND[$listen_port]}"
            cat >> "${CONF_DIR}/30-extra-frontends.cfg" << EOF

frontend extra-tcp-${listen_port}
    mode tcp
    bind *:${listen_port}
    default_backend ${single_backend}
EOF
        else
            # TCP mode with multiple domains: use SNI-based map routing
            cat >> "${CONF_DIR}/30-extra-frontends.cfg" << EOF

frontend extra-tcp-${listen_port}
    mode tcp
    bind *:${listen_port}
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    use_backend %[req.ssl_sni,lower,map(${MAP_PATH_PREFIX}/extra-${listen_port}-domains.map,no-match-tcp)]
EOF
        fi
    done

    echo ""
    echo "Extra port frontends generated for ports: $(printf '%s\n' "${!EXTRA_LISTEN_PORTS[@]}" | sort -n | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Ensure files are readable
# ---------------------------------------------------------------------------

chmod 644 "${CONF_DIR}"/*.cfg "${MAPS_DIR}"/*.map

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Generated config for ${count} domain(s):"
echo "  - ${CONF_DIR}/00-global.cfg"
echo "  - ${CONF_DIR}/10-frontends.cfg"
echo "  - ${CONF_DIR}/20-backends.cfg"
echo "  - ${MAPS_DIR}/http-domains.map"
echo "  - ${MAPS_DIR}/https-domains.map"
if [[ "$has_mapdownload" == "true" ]]; then
    echo "  - ${CONF_DIR}/15-frontend-mapdownload.cfg"
    echo "  - ${MAPS_DIR}/mapdownload-domains.map"
fi
if [[ "$has_extra_ports" == "true" ]]; then
    echo "  - ${CONF_DIR}/30-extra-frontends.cfg"
    for listen_port in $(printf '%s\n' "${!EXTRA_LISTEN_PORTS[@]}" | sort -n); do
        echo "  - ${MAPS_DIR}/extra-${listen_port}-domains.map"
    done
fi
echo ""
echo "Restart HAProxy to apply: docker restart haproxy"
