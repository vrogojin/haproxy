#!/bin/bash
# Generates conf.d/ and maps/ from domains.map
# Usage: ./generate-config.sh

set -e
cd "$(dirname "$0")"

echo "Generating HAProxy config from domains.map..."

# Create directories
mkdir -p conf.d maps

# Copy templates to conf.d
cp templates/*.cfg conf.d/

# Initialize generated files
> maps/http-domains.map
> maps/https-domains.map
> conf.d/20-backends.cfg

echo "# Auto-generated backends from domains.map" >> conf.d/20-backends.cfg
echo "# Generated at: $(date)" >> conf.d/20-backends.cfg

# Process domains.map
count=0
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Parse fields
    read -r domain container http_port https_port <<< "$line"

    # Validate we have all fields
    if [[ -z "$domain" || -z "$container" || -z "$http_port" || -z "$https_port" ]]; then
        echo "Warning: Skipping invalid line: $line"
        continue
    fi

    # Generate HTTP map entry and backend
    echo "${domain}    ${container}-http" >> maps/http-domains.map
    cat >> conf.d/20-backends.cfg << EOF

backend ${container}-http
    mode http
    server ${container} ${container}:${http_port} init-addr last,libc,none
EOF

    # Generate HTTPS map entry and backend
    echo "${domain}    ${container}-https" >> maps/https-domains.map
    cat >> conf.d/20-backends.cfg << EOF

backend ${container}-https
    mode tcp
    server ${container} ${container}:${https_port} check inter 5s fall 3 rise 2 init-addr last,libc,none
EOF

    count=$((count + 1))
    echo "  Added: ${domain} -> ${container} (HTTP:${http_port}, HTTPS:${https_port})"

done < domains.map

# Ensure files are readable
chmod 644 conf.d/*.cfg maps/*.map

echo ""
echo "Generated config for ${count} domain(s):"
echo "  - conf.d/00-global.cfg"
echo "  - conf.d/10-frontends.cfg"
echo "  - conf.d/20-backends.cfg"
echo "  - maps/http-domains.map"
echo "  - maps/https-domains.map"
echo ""
echo "Restart HAProxy to apply: docker restart haproxy"
