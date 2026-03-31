#!/usr/bin/env bash
# Test script for generate-config.sh extra_ports support
#
# Usage: ./tests/test-generate-config.sh
#
# Tests:
#   1. Standard 4-field entry (backward compat)
#   2. Standard 5-field entry with map_port
#   3. Entry with extra ports (tcp + http + tcp)
#   4. Multiple domains sharing same listen port (TCP SNI routing)
#   5. Single domain on TCP port (default_backend, no SNI)
#   6. HTTP extra port
#   7. Container mode with env vars (absolute paths)

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
GENERATE_SCRIPT="${REPO_DIR}/generate-config.sh"

# Counters
passed=0
failed=0
total=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup_tmpdir() {
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf -- "$TMPDIR"' EXIT

    mkdir -p "${TMPDIR}/conf.d" "${TMPDIR}/maps" "${TMPDIR}/templates"

    # Copy templates from the repo
    cp "${REPO_DIR}/templates/00-global.cfg" "${TMPDIR}/templates/"
    cp "${REPO_DIR}/templates/10-frontends.cfg" "${TMPDIR}/templates/"
    cp "${REPO_DIR}/templates/15-frontend-mapdownload.cfg" "${TMPDIR}/templates/"
}

run_generate() {
    local domains_map="$1"
    local conf_dir="${TMPDIR}/conf.d"
    local maps_dir="${TMPDIR}/maps"
    local templates_dir="${TMPDIR}/templates"

    # Clean output dirs
    rm -f "${conf_dir}"/*.cfg "${maps_dir}"/*.map 2>/dev/null || true

    HAPROXY_CONF_DIR="$conf_dir" \
    HAPROXY_MAPS_DIR="$maps_dir" \
    HAPROXY_TEMPLATES_DIR="$templates_dir" \
    HAPROXY_DOMAINS_MAP="$domains_map" \
        bash "$GENERATE_SCRIPT" > /dev/null 2>&1
}

assert_file_exists() {
    local file="$1"
    local desc="$2"
    total=$((total + 1))
    if [[ -f "$file" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL: %s — file not found: %s\n' "$desc" "$file"
    fi
}

assert_file_not_exists() {
    local file="$1"
    local desc="$2"
    total=$((total + 1))
    if [[ ! -f "$file" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL: %s — file should not exist: %s\n' "$desc" "$file"
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"
    total=$((total + 1))
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL: %s — pattern not found in %s: %s\n' "$desc" "$file" "$pattern"
    fi
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"
    total=$((total + 1))
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL: %s — pattern should not be in %s: %s\n' "$desc" "$file" "$pattern"
    fi
}

# ---------------------------------------------------------------------------
# Test 1: Standard 4-field entry (backward compatibility)
# ---------------------------------------------------------------------------

test_standard_4field() {
    echo "--- Test 1: Standard 4-field entry ---"
    setup_tmpdir

    local map_file="${TMPDIR}/domains.map"
    cat > "$map_file" << 'EOF'
# Test domains
example.com  my-backend  80  443
EOF

    run_generate "$map_file"

    assert_file_exists "${TMPDIR}/conf.d/20-backends.cfg" "backends file exists"
    assert_file_contains "${TMPDIR}/maps/http-domains.map" "example\\.com.*my-backend-http" "http map entry"
    assert_file_contains "${TMPDIR}/maps/https-domains.map" "example\\.com.*my-backend-https" "https map entry"
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend my-backend-http" "http backend"
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend my-backend-https" "https backend"
    assert_file_not_exists "${TMPDIR}/conf.d/30-extra-frontends.cfg" "no extra frontends without extra ports"
    assert_file_not_exists "${TMPDIR}/conf.d/15-frontend-mapdownload.cfg" "no mapdownload without map_port"
}

# ---------------------------------------------------------------------------
# Test 2: Standard 5-field entry with map_port
# ---------------------------------------------------------------------------

test_standard_5field() {
    echo "--- Test 2: Standard 5-field entry with map_port ---"
    setup_tmpdir

    local map_file="${TMPDIR}/domains.map"
    cat > "$map_file" << 'EOF'
example.com  my-backend  8888  8888  8000
EOF

    run_generate "$map_file"

    assert_file_contains "${TMPDIR}/maps/mapdownload-domains.map" "example\\.com.*my-backend-mapdownload" "mapdownload map entry"
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend my-backend-mapdownload" "mapdownload backend"
    assert_file_exists "${TMPDIR}/conf.d/15-frontend-mapdownload.cfg" "mapdownload frontend copied"
}

# ---------------------------------------------------------------------------
# Test 3: Entry with extra ports
# ---------------------------------------------------------------------------

test_extra_ports() {
    echo "--- Test 3: Entry with extra ports ---"
    setup_tmpdir

    local map_file="${TMPDIR}/domains.map"
    cat > "$map_file" << 'EOF'
electrum.example.com  fulcrum-alpha  80  50002  -  extra:50001:50001:tcp  extra:50003:50003:http  extra:50004:50004:tcp
EOF

    run_generate "$map_file"

    # Check extra frontends file exists
    assert_file_exists "${TMPDIR}/conf.d/30-extra-frontends.cfg" "extra frontends file"

    # Check map files for each extra port
    assert_file_exists "${TMPDIR}/maps/extra-50001-domains.map" "extra-50001 map file"
    assert_file_exists "${TMPDIR}/maps/extra-50003-domains.map" "extra-50003 map file"
    assert_file_exists "${TMPDIR}/maps/extra-50004-domains.map" "extra-50004 map file"

    # Check map file contents
    assert_file_contains "${TMPDIR}/maps/extra-50001-domains.map" "electrum\\.example\\.com.*fulcrum-alpha-extra-50001" "50001 map entry"
    assert_file_contains "${TMPDIR}/maps/extra-50003-domains.map" "electrum\\.example\\.com.*fulcrum-alpha-extra-50003" "50003 map entry"

    # Check backend blocks
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend fulcrum-alpha-extra-50001" "extra 50001 backend"
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend fulcrum-alpha-extra-50003" "extra 50003 backend"
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend fulcrum-alpha-extra-50004" "extra 50004 backend"

    # Check frontend types
    # 50001: single domain TCP -> default_backend
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "frontend extra-tcp-50001" "tcp frontend for 50001"
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "default_backend fulcrum-alpha-extra-50001" "default_backend for single-domain tcp"

    # 50003: single domain HTTP -> map routing
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "frontend extra-http-50003" "http frontend for 50003"
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "req\\.hdr(host)" "host-based routing for http"

    # 50004: single domain TCP -> default_backend
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "frontend extra-tcp-50004" "tcp frontend for 50004"
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "default_backend fulcrum-alpha-extra-50004" "default_backend for 50004"

    # Standard backends still generated
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend fulcrum-alpha-http" "standard http backend"
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend fulcrum-alpha-https" "standard https backend"

    # No mapdownload (map_port is -)
    assert_file_not_exists "${TMPDIR}/conf.d/15-frontend-mapdownload.cfg" "no mapdownload with - map_port"
}

# ---------------------------------------------------------------------------
# Test 4: Multiple domains sharing same listen port (TCP SNI)
# ---------------------------------------------------------------------------

test_shared_tcp_port() {
    echo "--- Test 4: Multiple domains sharing TCP listen port ---"
    setup_tmpdir

    local map_file="${TMPDIR}/domains.map"
    cat > "$map_file" << 'EOF'
alpha.example.com    fulcrum-alpha   80  50002  -  extra:50004:50004:tcp
beta.example.com     fulcrum-beta    80  50002  -  extra:50004:50004:tcp
EOF

    run_generate "$map_file"

    # With 2 domains on port 50004, should get SNI routing (not default_backend)
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "frontend extra-tcp-50004" "shared tcp frontend"
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "tcp-request inspect-delay 5s" "SNI inspect delay"
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "req_ssl_hello_type 1" "SNI hello check"
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "req\\.ssl_sni" "SNI-based map routing"
    assert_file_not_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "default_backend" "no default_backend with multiple domains"

    # Both domains in map file
    assert_file_contains "${TMPDIR}/maps/extra-50004-domains.map" "alpha\\.example\\.com" "first domain in map"
    assert_file_contains "${TMPDIR}/maps/extra-50004-domains.map" "beta\\.example\\.com" "second domain in map"
}

# ---------------------------------------------------------------------------
# Test 5: HTTP extra port always uses host map (even single domain)
# ---------------------------------------------------------------------------

test_http_extra_port() {
    echo "--- Test 5: HTTP extra port uses host-based routing ---"
    setup_tmpdir

    local map_file="${TMPDIR}/domains.map"
    cat > "$map_file" << 'EOF'
ws.example.com  my-ws  80  443  -  extra:50003:50003:http
EOF

    run_generate "$map_file"

    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "frontend extra-http-50003" "http frontend"
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "mode http" "http mode"
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "req\\.hdr(host)" "host-based routing"
    assert_file_not_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "default_backend" "no default_backend for http"
}

# ---------------------------------------------------------------------------
# Test 6: Container mode with absolute paths
# ---------------------------------------------------------------------------

test_container_mode() {
    echo "--- Test 6: Container mode with absolute paths ---"
    setup_tmpdir

    local map_file="${TMPDIR}/domains.map"
    cat > "$map_file" << 'EOF'
example.com  backend  80  443  -  extra:9000:9000:http
EOF

    # Use absolute paths (simulating container)
    HAPROXY_CONF_DIR="${TMPDIR}/conf.d" \
    HAPROXY_MAPS_DIR="${TMPDIR}/maps" \
    HAPROXY_TEMPLATES_DIR="${TMPDIR}/templates" \
    HAPROXY_DOMAINS_MAP="$map_file" \
        bash "$GENERATE_SCRIPT" > /dev/null 2>&1

    # With absolute paths, map references should use the MAPS_DIR directly
    assert_file_contains "${TMPDIR}/conf.d/30-extra-frontends.cfg" "${TMPDIR}/maps/extra-9000-domains.map" "absolute map path in frontend"
}

# ---------------------------------------------------------------------------
# Test 7: Backend mode (http vs tcp) in extra port backends
# ---------------------------------------------------------------------------

test_backend_modes() {
    echo "--- Test 7: Backend modes for extra ports ---"
    setup_tmpdir

    local map_file="${TMPDIR}/domains.map"
    cat > "$map_file" << 'EOF'
example.com  svc  80  443  -  extra:9001:9001:http  extra:9002:9002:tcp
EOF

    run_generate "$map_file"

    # HTTP backend should have mode http and health check
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend svc-extra-9001" "http extra backend exists"
    # TCP backend should have mode tcp and health check
    assert_file_contains "${TMPDIR}/conf.d/20-backends.cfg" "backend svc-extra-9002" "tcp extra backend exists"
}

# ---------------------------------------------------------------------------
# Test 8: Mixed standard and extra port entries
# ---------------------------------------------------------------------------

test_mixed_entries() {
    echo "--- Test 8: Mixed standard and extra port entries ---"
    setup_tmpdir

    local map_file="${TMPDIR}/domains.map"
    cat > "$map_file" << 'EOF'
# Standard web service
web.example.com   web-app   80   443

# Service with map download
maps.example.com  map-svc   80   443  8000

# Electrum server with extras
electrum.example.com  fulcrum  80  50002  -  extra:50001:50001:tcp  extra:50003:50003:http
EOF

    run_generate "$map_file"

    # All 3 domains processed
    assert_file_contains "${TMPDIR}/maps/http-domains.map" "web\\.example\\.com" "web domain in http map"
    assert_file_contains "${TMPDIR}/maps/http-domains.map" "maps\\.example\\.com" "maps domain in http map"
    assert_file_contains "${TMPDIR}/maps/http-domains.map" "electrum\\.example\\.com" "electrum domain in http map"

    # Map download only for maps.example.com
    assert_file_exists "${TMPDIR}/conf.d/15-frontend-mapdownload.cfg" "mapdownload frontend present"
    assert_file_contains "${TMPDIR}/maps/mapdownload-domains.map" "maps\\.example\\.com" "maps domain in mapdownload map"

    # Extra ports only for electrum
    assert_file_exists "${TMPDIR}/conf.d/30-extra-frontends.cfg" "extra frontends present"
    assert_file_exists "${TMPDIR}/maps/extra-50001-domains.map" "50001 map exists"
    assert_file_exists "${TMPDIR}/maps/extra-50003-domains.map" "50003 map exists"

    # No extra port for standard domains
    assert_file_not_contains "${TMPDIR}/maps/extra-50001-domains.map" "web\\.example\\.com" "web not in extra maps"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_standard_4field
test_standard_5field
test_extra_ports
test_shared_tcp_port
test_http_extra_port
test_container_mode
test_backend_modes
test_mixed_entries

echo ""
echo "==========================================="
printf 'Results: %d passed, %d failed, %d total\n' "$passed" "$failed" "$total"
echo "==========================================="

if (( failed > 0 )); then
    exit 1
else
    echo "All tests passed."
    exit 0
fi
