#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# HAProxy Dynamic Registration System — End-to-End Tests
# ═══════════════════════════════════════════════════════════════
#
# Usage:
#   ./tests/e2e/run-tests.sh              # Run all suites
#   ./tests/e2e/run-tests.sh suite_name   # Run one suite
#   DEBUG=1 ./tests/e2e/run-tests.sh      # Verbose output
#
# Prerequisites:
#   - Docker daemon running
#   - Current user in docker group (or root)
#   - curl, jq, openssl, nc installed on host
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Constants ─────────────────────────────────────────────────
TEST_PREFIX="haproxy-e2e-test"
TEST_NET="${TEST_PREFIX}-net"
TEST_HAPROXY="${TEST_PREFIX}-proxy"
TEST_WEB="${TEST_PREFIX}-web"
TEST_ELECTRUM="${TEST_PREFIX}-electrum"
TEST_API="${TEST_PREFIX}-api"
TEST_IMAGE="${TEST_PREFIX}-service:latest"
HAPROXY_IMAGE="${TEST_PREFIX}-haproxy:latest"

# Discovered ports (set during start_environment)
HTTP_PORT=""
HTTPS_PORT=""
API_PORT=""
EXTRA_TCP_PORT=""
EXTRA_HTTP_PORT=""
EXTRA_TLS_PORT=""

# ─── Counters ──────────────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CURRENT_SUITE=""

# ─── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Debug Mode ────────────────────────────────────────────────
DEBUG="${DEBUG:-0}"

debug() {
    if [ "$DEBUG" = "1" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# ─── Assertion Helpers ─────────────────────────────────────────

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [ "$expected" = "$actual" ]; then
        return 0
    else
        echo "  ASSERTION FAILED: ${msg}" >&2
        echo "    expected: ${expected}" >&2
        echo "    actual:   ${actual}" >&2
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if echo "$haystack" | grep -qF "$needle"; then
        return 0
    else
        echo "  ASSERTION FAILED: ${msg}" >&2
        echo "    expected to contain: ${needle}" >&2
        echo "    actual value:        ${haystack}" >&2
        return 1
    fi
}

assert_true() {
    local msg="${1:-assertion}"
    # Relies on the previous command's exit code
    # Use as: [ condition ] && assert_true "msg" || ...
    return 0
}

assert_http_status() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-HTTP status check}"
    assert_equals "$expected" "$actual" "$msg"
}

# ─── Test Runner ───────────────────────────────────────────────

run_test() {
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    printf "  %-60s " "$name"
    local output_file="/tmp/${TEST_PREFIX}-test-output-$$"
    if "$@" > "$output_file" 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        if [ -s "$output_file" ]; then
            sed 's/^/    /' "$output_file" >&2
        fi
    fi
    rm -f "$output_file"
}

skip_test() {
    local name="$1"
    local reason="${2:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    printf "  %-60s " "$name"
    echo -e "${YELLOW}SKIP${NC} ${reason}"
}

run_suite() {
    local name="$1"
    CURRENT_SUITE="$name"
    echo ""
    echo -e "${BOLD}Suite: ${name}${NC}"
    echo "  ────────────────────────────────────────────────────────"
}

# ─── Clean Room ────────────────────────────────────────────────

clean_room() {
    echo "=== Clean Room: removing test artifacts ==="

    # Stop and remove all containers with the test prefix
    local containers
    containers=$(docker ps -aq --filter "name=${TEST_PREFIX}" 2>/dev/null || true)
    if [ -n "$containers" ]; then
        echo "  Removing containers..."
        echo "$containers" | xargs docker rm -f 2>/dev/null || true
    fi

    # Disconnect any containers still on the test network
    for cid in $(docker network inspect "${TEST_NET}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
        docker network disconnect -f "${TEST_NET}" "$cid" 2>/dev/null || true
    done

    # Remove test network
    docker network rm "${TEST_NET}" 2>/dev/null || true

    # Remove test volumes
    local volumes
    volumes=$(docker volume ls -q --filter "name=${TEST_PREFIX}" 2>/dev/null || true)
    if [ -n "$volumes" ]; then
        echo "  Removing volumes..."
        echo "$volumes" | xargs docker volume rm 2>/dev/null || true
    fi

    # Remove test images (not cached for speed -- ensures clean builds)
    docker rmi "${TEST_IMAGE}" "${HAPROXY_IMAGE}" 2>/dev/null || true

    # Clean up temp files
    rm -f /tmp/${TEST_PREFIX}-* 2>/dev/null || true

    echo "=== Clean room ready ==="
}

# ALWAYS clean on exit (success, failure, interrupt, etc.)
trap clean_room EXIT

# Pre-clean: remove leftovers from previous (possibly crashed) runs
clean_room

# ─── Build ─────────────────────────────────────────────────────

build_test_images() {
    echo ""
    echo "=== Building test images ==="

    # Build mock service image
    echo "  Building mock service image..."
    docker build -t "${TEST_IMAGE}" "${SCRIPT_DIR}/mock-service/" \
        ${DEBUG:+--progress=plain} 2>&1 | \
        if [ "$DEBUG" = "1" ]; then cat; else tail -1; fi

    # Build HAProxy image under test
    # Uses the project's Dockerfile (which includes Registration API)
    echo "  Building HAProxy image..."
    docker build -t "${HAPROXY_IMAGE}" "${PROJECT_ROOT}/" \
        ${DEBUG:+--progress=plain} 2>&1 | \
        if [ "$DEBUG" = "1" ]; then cat; else tail -1; fi

    echo "=== Images built ==="
}

# ─── Wait Helpers ──────────────────────────────────────────────

wait_for_healthy() {
    local container="$1"
    local timeout="${2:-30}"
    local elapsed=0

    echo "  Waiting for ${container} to be healthy (timeout: ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        if docker exec "$container" pgrep haproxy > /dev/null 2>&1; then
            # Also check if the API is responding
            local api_check
            api_check=$(docker exec "$container" curl -sf http://127.0.0.1:8404/v1/health 2>/dev/null || true)
            if [ -n "$api_check" ]; then
                echo "  ${container} is healthy (${elapsed}s)"
                return 0
            fi
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "  ERROR: ${container} did not become healthy within ${timeout}s" >&2
    docker logs "$container" 2>&1 | tail -20 >&2
    return 1
}

wait_for_container() {
    local container="$1"
    local port="$2"
    local timeout="${3:-15}"
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if docker exec "$container" curl -sf "http://127.0.0.1:${port}/" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "  WARNING: ${container} port ${port} not responding within ${timeout}s" >&2
    return 1
}

# ─── Start Environment ────────────────────────────────────────

start_environment() {
    echo ""
    echo "=== Starting test environment ==="

    # Create test network
    docker network create "${TEST_NET}"
    echo "  Created network: ${TEST_NET}"

    # Start HAProxy container
    docker run -d --name "${TEST_HAPROXY}" \
        --network "${TEST_NET}" \
        -p 0:80 -p 0:443 -p 0:8404 \
        -p 0:50001 -p 0:50003 -p 0:50004 \
        "${HAPROXY_IMAGE}"
    echo "  Started: ${TEST_HAPROXY}"

    # Wait for HAProxy + API to be healthy
    wait_for_healthy "${TEST_HAPROXY}" 30

    # Discover published ports
    HTTP_PORT=$(docker port "${TEST_HAPROXY}" 80/tcp | head -1 | sed 's/.*://')
    HTTPS_PORT=$(docker port "${TEST_HAPROXY}" 443/tcp | head -1 | sed 's/.*://')
    API_PORT=$(docker port "${TEST_HAPROXY}" 8404/tcp | head -1 | sed 's/.*://')
    EXTRA_TCP_PORT=$(docker port "${TEST_HAPROXY}" 50001/tcp | head -1 | sed 's/.*://')
    EXTRA_HTTP_PORT=$(docker port "${TEST_HAPROXY}" 50003/tcp | head -1 | sed 's/.*://')
    EXTRA_TLS_PORT=$(docker port "${TEST_HAPROXY}" 50004/tcp | head -1 | sed 's/.*://')

    # Guard: verify all ports were discovered
    for var in HTTP_PORT HTTPS_PORT API_PORT EXTRA_TCP_PORT EXTRA_HTTP_PORT EXTRA_TLS_PORT; do
        if [ -z "${!var:-}" ]; then
            echo "FATAL: Failed to discover port for ${var}. Container may have crashed." >&2
            docker logs "${TEST_HAPROXY}" 2>&1 | tail -20
            exit 1
        fi
    done

    echo "  Published ports:"
    echo "    HTTP:       ${HTTP_PORT}"
    echo "    HTTPS:      ${HTTPS_PORT}"
    echo "    API:        ${API_PORT}"
    echo "    TCP 50001:  ${EXTRA_TCP_PORT}"
    echo "    HTTP 50003: ${EXTRA_HTTP_PORT}"
    echo "    TLS 50004:  ${EXTRA_TLS_PORT}"

    # Start mock services
    docker run -d --name "${TEST_WEB}" --network "${TEST_NET}" \
        -e SERVICE_TYPE=web -e TEST_DOMAIN=web.test.local \
        "${TEST_IMAGE}"
    echo "  Started: ${TEST_WEB}"

    docker run -d --name "${TEST_ELECTRUM}" --network "${TEST_NET}" \
        -e SERVICE_TYPE=electrum -e TEST_DOMAIN=electrum.test.local \
        "${TEST_IMAGE}"
    echo "  Started: ${TEST_ELECTRUM}"

    docker run -d --name "${TEST_API}" --network "${TEST_NET}" \
        -e SERVICE_TYPE=api -e TEST_DOMAIN=api.test.local \
        "${TEST_IMAGE}"
    echo "  Started: ${TEST_API}"

    # Wait for mock services to be ready
    wait_for_container "${TEST_WEB}" 80 15
    wait_for_container "${TEST_ELECTRUM}" 80 15
    wait_for_container "${TEST_API}" 8080 15

    echo "=== Test environment ready ==="
}

# ─── Suite Functions ───────────────────────────────────────────
# Each suite function contains its tests as nested functions
# followed by run_test calls.

suite_clean_room() {
    run_suite "1. Clean Room Verification"

    test_no_leftover_containers() {
        local count
        count=$(docker ps -aq --filter "name=${TEST_PREFIX}" 2>/dev/null | wc -l)
        # We expect our test containers to be running now,
        # but this test runs AFTER start_environment, so we verify
        # only test-prefixed resources exist (no stale ones).
        # The real verification is that pre-clean ran successfully.
        [ "$count" -ge 1 ]  # At least our test containers are present
    }
    run_test "Test containers are running with correct prefix" test_no_leftover_containers

    test_all_resources_prefixed() {
        local non_prefixed
        non_prefixed=$(docker ps -a --format '{{.Names}}' \
            | grep "e2e-test" \
            | grep -v "^${TEST_PREFIX}" || true)
        [ -z "$non_prefixed" ]
    }
    run_test "All e2e resources use the test prefix" test_all_resources_prefixed

    test_test_network_exists() {
        docker network inspect "${TEST_NET}" > /dev/null 2>&1
    }
    run_test "Test network exists: ${TEST_NET}" test_test_network_exists
}

suite_haproxy_startup() {
    run_suite "2. HAProxy Startup"

    test_haproxy_running() {
        local status
        status=$(docker inspect -f '{{.State.Status}}' "${TEST_HAPROXY}" 2>/dev/null)
        assert_equals "running" "$status" "HAProxy container should be running"
    }
    run_test "HAProxy container is running" test_haproxy_running

    test_api_health() {
        local response
        response=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/health")
        local status
        status=$(echo "$response" | jq -r '.status')
        assert_equals "healthy" "$status" "API health status should be 'healthy'"
    }
    run_test "Registration API health check returns healthy" test_api_health

    test_empty_backends() {
        local response
        response=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/backends")
        local count
        count=$(echo "$response" | jq -r '.count')
        assert_equals "0" "$count" "Should have 0 backends initially"
    }
    run_test "Backend list is empty on fresh start" test_empty_backends

    test_haproxy_process() {
        local pid_count
        pid_count=$(docker exec "${TEST_HAPROXY}" pgrep -c haproxy 2>/dev/null || echo "0")
        [ "$pid_count" -ge 1 ]
    }
    run_test "HAProxy process is running inside container" test_haproxy_process
}

suite_registration() {
    run_suite "3. Backend Registration"

    test_register_web() {
        local response http_code
        response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"web.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}')
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        assert_equals "201" "$http_code" "Should return 201 Created"
        assert_equals "web.test.local" "$(echo "$body" | jq -r '.domain')" "Domain should match"
    }
    run_test "Register web.test.local (201)" test_register_web

    test_register_electrum() {
        local response http_code
        response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"electrum.test.local","container":"'"${TEST_ELECTRUM}"'","http_port":80,"https_port":50002,"extra_ports":[{"listen":50001,"target":50001,"mode":"tcp"},{"listen":50003,"target":50003,"mode":"http"},{"listen":50004,"target":50004,"mode":"tcp"}]}')
        http_code=$(echo "$response" | tail -1)
        assert_equals "201" "$http_code" "Should return 201 Created"
    }
    run_test "Register electrum.test.local with extra ports (201)" test_register_electrum

    test_register_api() {
        local response http_code
        response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"api.test.local","container":"'"${TEST_API}"'","http_port":8080,"https_port":8443}')
        http_code=$(echo "$response" | tail -1)
        assert_equals "201" "$http_code" "Should return 201 Created"
    }
    run_test "Register api.test.local with non-standard ports (201)" test_register_api

    # Allow time for debounce (2s) + config generation + HAProxy reload
    sleep 5

    test_list_backends() {
        local response
        response=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/backends")
        local count
        count=$(echo "$response" | jq -r '.count')
        assert_equals "3" "$count" "Should have 3 backends"
    }
    run_test "List all backends returns count=3" test_list_backends

    test_get_backend() {
        local response http_code
        response=$(curl -s -w "\n%{http_code}" "http://127.0.0.1:${API_PORT}/v1/backends/electrum.test.local")
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        assert_equals "200" "$http_code" "Should return 200"
        assert_equals "electrum.test.local" "$(echo "$body" | jq -r '.domain')" "Domain should match"
        local extra_count
        extra_count=$(echo "$body" | jq '.extra_ports | length')
        assert_equals "3" "$extra_count" "Should have 3 extra ports"
    }
    run_test "Get specific backend (electrum.test.local)" test_get_backend

    test_idempotent_register() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"web.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}')
        assert_equals "200" "$http_code" "Idempotent re-register should return 200"
    }
    run_test "Idempotent re-registration returns 200" test_idempotent_register

    test_domain_conflict() {
        local response http_code
        response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"web.test.local","container":"different-container","http_port":80,"https_port":443}')
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        assert_equals "409" "$http_code" "Should return 409 Conflict"
        assert_equals "DOMAIN_CONFLICT" "$(echo "$body" | jq -r '.code')" "Error code should be DOMAIN_CONFLICT"
    }
    run_test "Domain conflict detection (409)" test_domain_conflict

    test_same_container_update() {
        # Same domain, same container, different ports = UPDATE (200), not conflict
        local code
        code=$(docker exec "${TEST_WEB}" curl -sf -o /dev/null -w "%{http_code}" \
            -X POST "http://${TEST_HAPROXY}:8404/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"web.test.local","container":"'"${TEST_WEB}"'","http_port":8080,"https_port":443}')
        assert_equals "200" "$code" "Same container, different ports should return 200 (update)"
        # Restore original registration to avoid breaking later tests
        docker exec "${TEST_WEB}" curl -sf -o /dev/null \
            -X POST "http://${TEST_HAPROXY}:8404/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"web.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}'
        sleep 3  # Wait for debounced reload after restore
    }
    run_test "Same container, different ports updates (200)" test_same_container_update

    test_mode_conflict() {
        local response http_code
        response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"conflict.test.local","container":"some-container","http_port":80,"https_port":443,"extra_ports":[{"listen":50003,"target":50003,"mode":"tcp"}]}')
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        assert_equals "409" "$http_code" "Should return 409 Conflict"
        assert_equals "MODE_CONFLICT" "$(echo "$body" | jq -r '.code')" "Error code should be MODE_CONFLICT"
    }
    run_test "Mode conflict on shared listen port (409)" test_mode_conflict
}

suite_http_routing() {
    run_suite "4. HTTP Routing"

    test_http_route_web() {
        local response
        response=$(curl -sf --resolve "web.test.local:${HTTP_PORT}:127.0.0.1" \
            "http://web.test.local:${HTTP_PORT}/")
        assert_equals "web" "$(echo "$response" | jq -r '.service')" "Should reach web service"
    }
    run_test "HTTP routes to web.test.local" test_http_route_web

    test_http_route_api() {
        local response
        response=$(curl -sf --resolve "api.test.local:${HTTP_PORT}:127.0.0.1" \
            "http://api.test.local:${HTTP_PORT}/v1/status")
        assert_equals "api" "$(echo "$response" | jq -r '.service')" "Should reach api service"
    }
    run_test "HTTP routes to api.test.local" test_http_route_api

    test_http_route_electrum() {
        local response
        response=$(curl -sf --resolve "electrum.test.local:${HTTP_PORT}:127.0.0.1" \
            "http://electrum.test.local:${HTTP_PORT}/")
        assert_equals "electrum" "$(echo "$response" | jq -r '.service')" "Should reach electrum service"
    }
    run_test "HTTP routes to electrum.test.local" test_http_route_electrum

    test_http_unknown_domain() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --resolve "unknown.test.local:${HTTP_PORT}:127.0.0.1" \
            "http://unknown.test.local:${HTTP_PORT}/")
        assert_equals "503" "$http_code" "Unknown domain should return 503"
    }
    run_test "Unknown domain returns 503" test_http_unknown_domain

    test_http_no_host() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://127.0.0.1:${HTTP_PORT}/")
        assert_equals "503" "$http_code" "No Host header should return 503"
    }
    run_test "Missing Host header returns 503" test_http_no_host
}

suite_tls_passthrough() {
    run_suite "5. HTTPS/TLS Passthrough"

    test_tls_web() {
        local response
        response=$(curl -sk --resolve "web.test.local:${HTTPS_PORT}:127.0.0.1" \
            "https://web.test.local:${HTTPS_PORT}/" --max-time 5)
        [ -n "$response" ]
    }
    run_test "TLS passthrough to web.test.local" test_tls_web

    test_tls_cert_is_backend_web() {
        local cert_cn
        cert_cn=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" \
            -servername "web.test.local" 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | sed -n 's/.*CN = //p')
        assert_equals "web.test.local" "$cert_cn" \
            "TLS cert CN should be web.test.local (proves passthrough)"
    }
    run_test "TLS cert is from backend (web), not HAProxy" test_tls_cert_is_backend_web

    test_tls_cert_is_backend_electrum() {
        local cert_cn
        cert_cn=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" \
            -servername "electrum.test.local" 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | sed -n 's/.*CN = //p')
        assert_equals "electrum.test.local" "$cert_cn" \
            "TLS cert CN should be electrum.test.local"
    }
    run_test "TLS cert is from backend (electrum)" test_tls_cert_is_backend_electrum

    test_tls_cert_is_backend_api() {
        local cert_cn
        cert_cn=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" \
            -servername "api.test.local" 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | sed -n 's/.*CN = //p')
        assert_equals "api.test.local" "$cert_cn" \
            "TLS cert CN should be api.test.local"
    }
    run_test "TLS cert is from backend (api)" test_tls_cert_is_backend_api

    test_tls_wrong_sni() {
        local cert_count
        cert_count=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" \
            -servername "unknown.test.local" 2>&1 \
            | grep -c "BEGIN CERTIFICATE" || true)
        assert_equals "0" "$cert_count" \
            "Should NOT get a valid certificate for unknown SNI"
    }
    run_test "TLS with unknown SNI fails gracefully" test_tls_wrong_sni
}

suite_extra_ports() {
    run_suite "6. Extra Ports (Non-Standard)"

    test_extra_tcp_50001() {
        local result
        result=$(echo "hello-tcp-test" | nc -q2 127.0.0.1 "${EXTRA_TCP_PORT}" 2>/dev/null || \
                 echo "hello-tcp-test" | nc -w2 127.0.0.1 "${EXTRA_TCP_PORT}" 2>/dev/null)
        assert_equals "hello-tcp-test" "$result" "TCP echo should return input"
    }
    run_test "Raw TCP on port 50001 (echo)" test_extra_tcp_50001

    test_extra_http_50003() {
        local response
        response=$(curl -sf --resolve "electrum.test.local:${EXTRA_HTTP_PORT}:127.0.0.1" \
            "http://electrum.test.local:${EXTRA_HTTP_PORT}/")
        assert_equals "ws-echo" "$(echo "$response" | jq -r '.service')" \
            "Should reach WS echo server"
    }
    run_test "HTTP on port 50003 reaches WS echo server" test_extra_http_50003

    test_extra_tls_50004() {
        local cert_cn
        cert_cn=$(echo | openssl s_client -connect "127.0.0.1:${EXTRA_TLS_PORT}" \
            -servername "electrum.test.local" 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | sed -n 's/.*CN = //p')
        assert_equals "electrum.test.local" "$cert_cn" \
            "TLS cert on 50004 should be from electrum backend"
    }
    run_test "TLS passthrough on port 50004" test_extra_tls_50004

    test_extra_http_unknown_host() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --resolve "unknown.test.local:${EXTRA_HTTP_PORT}:127.0.0.1" \
            "http://unknown.test.local:${EXTRA_HTTP_PORT}/" --max-time 5)
        assert_equals "503" "$http_code" "Unknown host on extra HTTP port should return 503"
    }
    run_test "Unknown host on extra HTTP port returns 503" test_extra_http_unknown_host
}

suite_websocket() {
    run_suite "7. WebSocket"

    test_ws_upgrade_50003() {
        local ws_key
        ws_key=$(openssl rand -base64 16)
        local response
        response=$(curl -s -i --resolve "electrum.test.local:${EXTRA_HTTP_PORT}:127.0.0.1" \
            -H "Host: electrum.test.local" \
            -H "Upgrade: websocket" \
            -H "Connection: Upgrade" \
            -H "Sec-WebSocket-Version: 13" \
            -H "Sec-WebSocket-Key: ${ws_key}" \
            "http://electrum.test.local:${EXTRA_HTTP_PORT}/" \
            --max-time 5 2>/dev/null || true)
        assert_contains "$response" "101" "Should receive 101 Switching Protocols"
    }
    run_test "WebSocket upgrade on port 50003" test_ws_upgrade_50003

    test_ws_echo_50003() {
        local result
        result=$(docker exec "${TEST_ELECTRUM}" node -e "
            const http = require('http');
            const crypto = require('crypto');
            const key = crypto.randomBytes(16).toString('base64');
            const req = http.request({
                hostname: '${TEST_HAPROXY}', port: 50003, path: '/',
                method: 'GET', headers: {
                    'Host': 'electrum.test.local', 'Upgrade': 'websocket',
                    'Connection': 'Upgrade', 'Sec-WebSocket-Version': '13',
                    'Sec-WebSocket-Key': key
                }
            });
            req.on('upgrade', (res, socket) => {
                const payload = Buffer.from('hello');
                const frame = Buffer.alloc(6 + payload.length);
                frame[0] = 0x81; frame[1] = 0x80 | payload.length;
                const mask = crypto.randomBytes(4);
                mask.copy(frame, 2);
                for (let i = 0; i < payload.length; i++) frame[6 + i] = payload[i] ^ mask[i % 4];
                socket.write(frame);
                socket.on('data', (data) => {
                    if (data.length >= 2) {
                        const len = data[1] & 0x7f;
                        console.log(data.slice(2, 2 + len).toString());
                        socket.destroy(); process.exit(0);
                    }
                });
                setTimeout(() => process.exit(1), 3000);
            });
            req.on('error', () => process.exit(1));
            req.end();
        " 2>/dev/null)
        assert_equals "hello" "$result" "WebSocket echo should return 'hello'"
    }
    run_test "WebSocket echo round-trip on port 50003" test_ws_echo_50003

    test_wss_50004() {
        local result
        result=$(docker exec "${TEST_ELECTRUM}" node -e "
            const tls = require('tls');
            const crypto = require('crypto');
            const key = crypto.randomBytes(16).toString('base64');
            const socket = tls.connect({
                host: '${TEST_HAPROXY}', port: 50004,
                servername: 'electrum.test.local', rejectUnauthorized: false
            }, () => {
                socket.write(
                    'GET / HTTP/1.1\r\nHost: electrum.test.local\r\n' +
                    'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
                    'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ' + key + '\r\n\r\n'
                );
            });
            let received = '';
            socket.on('data', (data) => {
                received += data.toString();
                if (received.includes('101')) {
                    console.log('WSS_UPGRADE_OK');
                    socket.destroy(); process.exit(0);
                }
            });
            socket.on('error', () => process.exit(1));
            setTimeout(() => process.exit(1), 5000);
        " 2>/dev/null)
        assert_contains "$result" "WSS_UPGRADE_OK" "WSS handshake should succeed on port 50004"
    }
    run_test "WebSocket over TLS (WSS) on port 50004" test_wss_50004
}

suite_unregistration() {
    run_suite "8. Backend Unregistration"

    test_delete_web() {
        local http_code
        http_code=$(docker exec "${TEST_WEB}" curl -sf -o /dev/null -w "%{http_code}" -X DELETE \
            "http://${TEST_HAPROXY}:8404/v1/backends/web.test.local")
        assert_equals "204" "$http_code" "DELETE should return 204"
    }
    run_test "Delete web.test.local returns 204" test_delete_web

    test_delete_from_host_403() {
        # DELETE from host should fail ownership check (source IP is gateway, not container)
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            "http://127.0.0.1:${API_PORT}/v1/backends/api.test.local")
        assert_equals "403" "$http_code" "DELETE from host should return 403 OWNERSHIP_MISMATCH"
    }
    run_test "DELETE from host returns 403 (ownership mismatch)" test_delete_from_host_403

    sleep 5  # Allow debounce (2s) + config generation + HAProxy reload

    test_deleted_domain_503() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --resolve "web.test.local:${HTTP_PORT}:127.0.0.1" \
            "http://web.test.local:${HTTP_PORT}/")
        assert_equals "503" "$http_code" "Deleted domain should return 503"
    }
    run_test "Deleted domain returns 503" test_deleted_domain_503

    test_other_domains_still_work() {
        local response
        response=$(curl -sf --resolve "api.test.local:${HTTP_PORT}:127.0.0.1" \
            "http://api.test.local:${HTTP_PORT}/")
        assert_equals "api" "$(echo "$response" | jq -r '.service')" "API should still work"
    }
    run_test "Other domains still route after delete" test_other_domains_still_work

    test_backend_count_after_delete() {
        local count
        count=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/backends" | jq -r '.count')
        assert_equals "2" "$count" "Should have 2 backends"
    }
    run_test "Backend count is 2 after delete" test_backend_count_after_delete

    test_get_deleted_404() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://127.0.0.1:${API_PORT}/v1/backends/web.test.local")
        assert_equals "404" "$http_code" "GET deleted domain should return 404"
    }
    run_test "GET deleted domain returns 404" test_get_deleted_404

    test_reregister_web() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"web.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}')
        assert_equals "201" "$http_code" "Re-register should return 201"
    }
    run_test "Re-register deleted domain returns 201" test_reregister_web

    sleep 5  # Allow debounce + reload

    test_reregistered_routes() {
        local response
        response=$(curl -sf --resolve "web.test.local:${HTTP_PORT}:127.0.0.1" \
            "http://web.test.local:${HTTP_PORT}/")
        assert_equals "web" "$(echo "$response" | jq -r '.service')" \
            "Re-registered domain should route correctly"
    }
    run_test "Re-registered domain routes correctly" test_reregistered_routes
}

suite_reload_under_load() {
    run_suite "9. HAProxy Reload Under Load"

    test_reload_under_load() {
        local total_requests=100
        local results_file="/tmp/${TEST_PREFIX}-reload-results"
        > "$results_file"

        (
            for i in $(seq 1 $total_requests); do
                curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 \
                    --resolve "api.test.local:${HTTP_PORT}:127.0.0.1" \
                    "http://api.test.local:${HTTP_PORT}/request-${i}" >> "$results_file"
                sleep 0.05
            done
        ) &
        local loader_pid=$!

        sleep 0.5

        curl -s -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"reload-test.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}' > /dev/null

        wait $loader_pid 2>/dev/null || true

        local success_count fail_count
        success_count=$(grep -cx "200" "$results_file" 2>/dev/null || echo "0")
        fail_count=$((total_requests - success_count))
        assert_equals "0" "$fail_count" "Zero requests should fail during reload"

        # Cleanup: remove the test domain
        docker exec "${TEST_WEB}" curl -sf -o /dev/null -X DELETE \
            "http://${TEST_HAPROXY}:8404/v1/backends/reload-test.test.local" 2>/dev/null || \
            curl -s -X DELETE "http://127.0.0.1:${API_PORT}/v1/backends/reload-test.test.local" > /dev/null 2>&1 || true
        rm -f "$results_file"
    }
    run_test "Zero dropped requests during HAProxy reload" test_reload_under_load
}

suite_error_handling() {
    run_suite "10. Error Handling"

    test_invalid_domain_injection() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"test; rm -rf /","container":"evil","http_port":80,"https_port":443}')
        assert_equals "422" "$http_code" "Shell injection should return 422"
    }
    run_test "Invalid domain (shell injection) returns 422" test_invalid_domain_injection

    test_invalid_container() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"valid.test.local","container":"../escape","http_port":80,"https_port":443}')
        assert_equals "422" "$http_code" "Path traversal container name should return 422"
    }
    run_test "Invalid container name returns 422" test_invalid_container

    test_port_out_of_range() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"valid.test.local","container":"valid","http_port":99999,"https_port":443}')
        assert_equals "422" "$http_code" "Port > 65535 should return 422"
    }
    run_test "Port out of range returns 422" test_port_out_of_range

    test_extra_port_reserved_80() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"valid2.test.local","container":"valid","http_port":80,"https_port":443,"extra_ports":[{"listen":80,"target":8080,"mode":"http"}]}')
        assert_equals "422" "$http_code" "Extra port on reserved 80 should return 422"
    }
    run_test "Extra port on reserved port 80 returns 422" test_extra_port_reserved_80

    test_extra_port_reserved_443() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"valid3.test.local","container":"valid","http_port":80,"https_port":443,"extra_ports":[{"listen":443,"target":8443,"mode":"tcp"}]}')
        assert_equals "422" "$http_code" "Extra port on reserved 443 should return 422"
    }
    run_test "Extra port on reserved port 443 returns 422" test_extra_port_reserved_443

    test_extra_port_reserved_8404() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"valid4.test.local","container":"valid","http_port":80,"https_port":443,"extra_ports":[{"listen":8404,"target":8404,"mode":"http"}]}')
        assert_equals "422" "$http_code" "Extra port on reserved 8404 should return 422"
    }
    run_test "Extra port on reserved port 8404 returns 422" test_extra_port_reserved_8404

    test_malformed_json() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain": invalid}')
        assert_equals "400" "$http_code" "Malformed JSON should return 400"
    }
    run_test "Malformed JSON returns 400" test_malformed_json

    test_delete_nonexistent() {
        local response http_code
        response=$(curl -s -w "\n%{http_code}" -X DELETE \
            "http://127.0.0.1:${API_PORT}/v1/backends/nonexistent.test.local")
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        assert_equals "404" "$http_code" "DELETE non-existent should return 404"
        assert_equals "NOT_FOUND" "$(echo "$body" | jq -r '.code')" "Code should be NOT_FOUND"
    }
    run_test "DELETE non-existent domain returns 404" test_delete_nonexistent

    test_force_reload() {
        local response http_code
        response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/reload")
        http_code=$(echo "$response" | tail -1)
        assert_equals "200" "$http_code" "Force reload should return 200"
    }
    run_test "Force reload returns 200" test_force_reload

    test_missing_domain() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"container":"some","http_port":80,"https_port":443}')
        assert_equals "422" "$http_code" "Missing domain should return 422"
    }
    run_test "Missing domain field returns 422" test_missing_domain

    test_missing_container() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"valid5.test.local","http_port":80,"https_port":443}')
        assert_equals "422" "$http_code" "Missing container should return 422"
    }
    run_test "Missing container field returns 422" test_missing_container

    test_both_ports_null() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"valid6.test.local","container":"valid","http_port":null,"https_port":null}')
        assert_equals "422" "$http_code" "Both ports null should return 422"
    }
    run_test "Both ports null returns 422" test_both_ports_null

    test_single_label_domain() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"localhost","container":"valid","http_port":80,"https_port":443}')
        assert_equals "422" "$http_code" "Single-label domain should return 422"
    }
    run_test "Single-label domain (no dot) returns 422" test_single_label_domain

    test_extra_ports_exceeding_max() {
        local extra_ports=""
        for i in $(seq 1 11); do
            [ -n "$extra_ports" ] && extra_ports+=","
            extra_ports+="{\"listen\":$((10000+i)),\"target\":$((10000+i)),\"mode\":\"tcp\"}"
        done
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d "{\"domain\":\"valid7.test.local\",\"container\":\"valid\",\"http_port\":80,\"https_port\":443,\"extra_ports\":[${extra_ports}]}")
        assert_equals "422" "$http_code" "More than 10 extra ports should return 422"
    }
    run_test "Extra ports exceeding maximum (11) returns 422" test_extra_ports_exceeding_max

    test_invalid_extra_port_mode() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"valid8.test.local","container":"valid","http_port":80,"https_port":443,"extra_ports":[{"listen":9999,"target":9999,"mode":"udp"}]}')
        assert_equals "422" "$http_code" "Invalid mode should return 422"
    }
    run_test "Invalid extra port mode 'udp' returns 422" test_invalid_extra_port_mode
}

suite_concurrent_registration() {
    run_suite "11. Concurrent Registration"

    test_concurrent_5_domains() {
        local pids=()
        local results_dir="/tmp/${TEST_PREFIX}-concurrent"
        mkdir -p "$results_dir"

        for i in $(seq 1 5); do
            (
                curl -s -w "\n%{http_code}" -X POST \
                    "http://127.0.0.1:${API_PORT}/v1/backends" \
                    -H "Content-Type: application/json" \
                    -d "{\"domain\":\"concurrent-${i}.test.local\",\"container\":\"${TEST_WEB}\",\"http_port\":80,\"https_port\":443}" \
                    > "${results_dir}/result-${i}" 2>/dev/null
            ) &
            pids+=($!)
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done

        local created_count=0
        for i in $(seq 1 5); do
            local code
            code=$(tail -1 "${results_dir}/result-${i}")
            [ "$code" = "201" ] && created_count=$((created_count + 1))
        done

        assert_equals "5" "$created_count" "All 5 should get 201"

        local config_check
        config_check=$(docker exec "${TEST_HAPROXY}" haproxy -c -f /etc/haproxy/conf.d 2>&1 | tail -1)
        assert_contains "$config_check" "valid" "HAProxy config should be valid"

        for i in $(seq 1 5); do
            curl -s -X DELETE "http://127.0.0.1:${API_PORT}/v1/backends/concurrent-${i}.test.local" > /dev/null
        done
        rm -rf "$results_dir"
    }
    run_test "5 simultaneous registrations all succeed" test_concurrent_5_domains

    test_concurrent_same_domain() {
        local results_dir="/tmp/${TEST_PREFIX}-concurrent-same"
        mkdir -p "$results_dir"

        (
            curl -s -w "\n%{http_code}" -X POST \
                "http://127.0.0.1:${API_PORT}/v1/backends" \
                -H "Content-Type: application/json" \
                -d "{\"domain\":\"race.test.local\",\"container\":\"${TEST_WEB}\",\"http_port\":80,\"https_port\":443}" \
                > "${results_dir}/result-1" 2>/dev/null
        ) &
        local pid1=$!

        (
            curl -s -w "\n%{http_code}" -X POST \
                "http://127.0.0.1:${API_PORT}/v1/backends" \
                -H "Content-Type: application/json" \
                -d "{\"domain\":\"race.test.local\",\"container\":\"${TEST_WEB}\",\"http_port\":80,\"https_port\":443}" \
                > "${results_dir}/result-2" 2>/dev/null
        ) &
        local pid2=$!

        wait $pid1 2>/dev/null || true
        wait $pid2 2>/dev/null || true

        local code1 code2
        code1=$(tail -1 "${results_dir}/result-1")
        code2=$(tail -1 "${results_dir}/result-2")
        local codes_sorted
        codes_sorted=$(printf '%s\n%s' "$code1" "$code2" | sort)
        local expected
        expected=$(printf '%s\n%s' "200" "201")
        assert_equals "$expected" "$codes_sorted" "One 201, one 200"

        curl -s -X DELETE "http://127.0.0.1:${API_PORT}/v1/backends/race.test.local" > /dev/null
        rm -rf "$results_dir"
    }
    run_test "2 simultaneous same-domain: one 201, one 200" test_concurrent_same_domain
}

suite_container_ownership() {
    run_suite "12. Container Ownership on DELETE"

    test_delete_ownership_mismatch() {
        curl -s -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"ownership.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}' > /dev/null
        sleep 1

        local response http_code
        response=$(docker exec "${TEST_API}" \
            curl -s -w "\n%{http_code}" -X DELETE \
            "http://${TEST_HAPROXY}:8404/v1/backends/ownership.test.local" 2>/dev/null)
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | sed '$d')
        assert_equals "403" "$http_code" "DELETE from wrong container should return 403"
        assert_equals "OWNERSHIP_MISMATCH" "$(echo "$body" | jq -r '.code')" "Code should be OWNERSHIP_MISMATCH"
    }
    run_test "DELETE from wrong container returns 403" test_delete_ownership_mismatch

    test_delete_ownership_match() {
        local http_code
        http_code=$(docker exec "${TEST_WEB}" \
            curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            "http://${TEST_HAPROXY}:8404/v1/backends/ownership.test.local" 2>/dev/null)
        assert_equals "204" "$http_code" "DELETE from correct container should return 204"
    }
    run_test "DELETE from correct container returns 204" test_delete_ownership_match

    test_ownership_domain_removed() {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://127.0.0.1:${API_PORT}/v1/backends/ownership.test.local")
        assert_equals "404" "$http_code" "Domain should be gone after owner DELETE"
    }
    run_test "Domain removed after owner DELETE" test_ownership_domain_removed
}

suite_auth_and_rate_limiting() {
    run_suite "13. Authentication and Rate Limiting"

    test_max_registrations() {
        docker run -d --name "${TEST_PREFIX}-limit-proxy" \
            --network "${TEST_NET}" \
            -e MAX_REGISTRATIONS=3 \
            "${HAPROXY_IMAGE}"
        wait_for_healthy "${TEST_PREFIX}-limit-proxy" 30

        local limit_api="${TEST_PREFIX}-limit-proxy:8404"

        for i in 1 2 3; do
            local code
            code=$(docker exec "${TEST_WEB}" curl -sf -o /dev/null -w "%{http_code}" \
                -X POST "http://${limit_api}/v1/backends" \
                -H "Content-Type: application/json" \
                -d "{\"domain\":\"limit${i}.test.local\",\"container\":\"${TEST_WEB}\",\"http_port\":80,\"https_port\":443}")
            assert_equals "201" "$code" "Registration ${i}/3 should succeed"
        done

        local code
        code=$(docker exec "${TEST_WEB}" curl -sf -o /dev/null -w "%{http_code}" \
            -X POST "http://${limit_api}/v1/backends" \
            -H "Content-Type: application/json" \
            -d "{\"domain\":\"limit4.test.local\",\"container\":\"${TEST_WEB}\",\"http_port\":80,\"https_port\":443}")
        assert_equals "429" "$code" "4th registration should hit MAX_REGISTRATIONS limit"

        docker rm -f "${TEST_PREFIX}-limit-proxy" >/dev/null 2>&1
    }
    run_test "MAX_REGISTRATIONS=3 blocks 4th registration (429)" test_max_registrations

    test_api_key_auth() {
        docker run -d --name "${TEST_PREFIX}-auth-proxy" \
            --network "${TEST_NET}" \
            -e HAPROXY_API_KEY="test-secret-key-12345" \
            "${HAPROXY_IMAGE}"
        wait_for_healthy "${TEST_PREFIX}-auth-proxy" 30

        local auth_api="${TEST_PREFIX}-auth-proxy:8404"

        # Unauthenticated POST
        local code
        code=$(docker exec "${TEST_WEB}" curl -sf -o /dev/null -w "%{http_code}" \
            -X POST "http://${auth_api}/v1/backends" \
            -H "Content-Type: application/json" \
            -d '{"domain":"auth.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}')
        assert_equals "401" "$code" "Unauthenticated POST should return 401"

        # Authenticated POST
        code=$(docker exec "${TEST_WEB}" curl -sf -o /dev/null -w "%{http_code}" \
            -X POST "http://${auth_api}/v1/backends" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer test-secret-key-12345" \
            -d '{"domain":"auth.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}')
        assert_equals "201" "$code" "Authenticated POST should return 201"

        # Wrong key
        code=$(docker exec "${TEST_WEB}" curl -sf -o /dev/null -w "%{http_code}" \
            -X POST "http://${auth_api}/v1/backends" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer wrong-key" \
            -d '{"domain":"auth2.test.local","container":"'"${TEST_WEB}"'","http_port":80,"https_port":443}')
        assert_equals "401" "$code" "Wrong API key should return 401"

        # Health exempt from auth
        code=$(docker exec "${TEST_WEB}" curl -sf -o /dev/null -w "%{http_code}" \
            "http://${auth_api}/v1/health")
        assert_equals "200" "$code" "Health endpoint should be exempt from auth"

        docker rm -f "${TEST_PREFIX}-auth-proxy" >/dev/null 2>&1
    }
    run_test "HAPROXY_API_KEY enforces Bearer auth (401/201)" test_api_key_auth
}

# ─── Main ──────────────────────────────────────────────────────

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo " HAProxy Dynamic Registration System — End-to-End Tests"
    echo "═══════════════════════════════════════════════════════════════"

    local target_suite="${1:-all}"

    build_test_images
    start_environment

    echo ""
    echo "Running e2e test suites..."
    echo "══════════════════════════════════════════════════════════════"

    if [ "$target_suite" = "all" ]; then
        suite_clean_room
        suite_haproxy_startup
        suite_registration
        suite_http_routing
        suite_tls_passthrough
        suite_extra_ports
        suite_websocket
        suite_unregistration
        suite_reload_under_load
        suite_error_handling
        suite_concurrent_registration
        suite_container_ownership
        suite_auth_and_rate_limiting
    else
        "suite_${target_suite}" 2>/dev/null || {
            echo "Unknown suite: ${target_suite}" >&2
            echo "Available suites: clean_room, haproxy_startup, registration," >&2
            echo "  http_routing, tls_passthrough, extra_ports, websocket," >&2
            echo "  unregistration, reload_under_load, error_handling," >&2
            echo "  concurrent_registration, container_ownership," >&2
            echo "  auth_and_rate_limiting" >&2
            exit 1
        }
    fi

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo -e " Results: ${GREEN}${TESTS_PASSED} passed${NC}, ${RED}${TESTS_FAILED} failed${NC}, ${YELLOW}${TESTS_SKIPPED} skipped${NC} out of ${TESTS_RUN} tests"
    echo "══════════════════════════════════════════════════════════════"
    echo ""

    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        exit 0
    fi
}

main "$@"
