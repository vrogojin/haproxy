#!/bin/bash
# Generates conf.d/ and maps/ from domains.map
# Usage: ./generate-config.sh

set -e
cd "$(dirname "$0")"

echo "Generating HAProxy config from domains.map..."

# Create directories
mkdir -p conf.d maps

# Copy templates to conf.d (except mapdownload which is conditional)
cp templates/00-global.cfg templates/10-frontends.cfg conf.d/

# Initialize generated files
> maps/http-domains.map
> maps/https-domains.map
> maps/mapdownload-domains.map
> conf.d/20-backends.cfg

echo "# Auto-generated backends from domains.map" >> conf.d/20-backends.cfg
echo "# Generated at: $(date)" >> conf.d/20-backends.cfg

# Track if any map_port entries exist
has_mapdownload=false

# Process domains.map
count=0
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Parse fields (5th field is optional)
    read -r domain container http_port https_port map_port <<< "$line"

    # Validate we have required fields
    if [[ -z "$domain" || -z "$container" || -z "$http_port" || -z "$https_port" ]]; then
        echo "Warning: Skipping invalid line: $line"
        continue
    fi

    # Generate HTTP map entry and backend (skip if port is -)
    if [[ "$http_port" != "-" ]]; then
        echo "${domain}    ${container}-http" >> maps/http-domains.map
        cat >> conf.d/20-backends.cfg << EOF

backend ${container}-http
    mode http
    server ${container} ${container}:${http_port} init-addr last,libc,none
EOF
    fi

    # Generate HTTPS map entry and backend (skip if port is -)
    if [[ "$https_port" != "-" ]]; then
        echo "${domain}    ${container}-https" >> maps/https-domains.map
        cat >> conf.d/20-backends.cfg << EOF

backend ${container}-https
    mode tcp
    server ${container} ${container}:${https_port} check inter 5s fall 3 rise 2 init-addr last,libc,none
EOF
    fi

    # Generate mapdownload backend if 5th field is specified and not -
    if [[ -n "$map_port" && "$map_port" != "-" ]]; then
        has_mapdownload=true
        echo "${domain}    ${container}-mapdownload" >> maps/mapdownload-domains.map
        cat >> conf.d/20-backends.cfg << EOF

backend ${container}-mapdownload
    mode http
    timeout server 5m
    server ${container} ${container}:${map_port} init-addr last,libc,none
EOF
    fi

    count=$((count + 1))
    msg="  Added: ${domain} -> ${container} (HTTP:${http_port}, HTTPS:${https_port}"
    if [[ -n "$map_port" && "$map_port" != "-" ]]; then
        msg+=", Map:${map_port}"
    fi
    msg+=")"
    echo "$msg"

done < domains.map

# Only copy mapdownload frontend template if we have map_port entries
if [[ "$has_mapdownload" == "true" ]]; then
    cp templates/15-frontend-mapdownload.cfg conf.d/
    echo ""
    echo "Map download frontend enabled (port 8000)"
fi

# Ensure files are readable
chmod 644 conf.d/*.cfg maps/*.map

echo ""
echo "Generated config for ${count} domain(s):"
echo "  - conf.d/00-global.cfg"
echo "  - conf.d/10-frontends.cfg"
echo "  - conf.d/20-backends.cfg"
echo "  - maps/http-domains.map"
echo "  - maps/https-domains.map"
if [[ "$has_mapdownload" == "true" ]]; then
    echo "  - conf.d/15-frontend-mapdownload.cfg"
    echo "  - maps/mapdownload-domains.map"
fi
echo ""
echo "Restart HAProxy to apply: docker restart haproxy"
