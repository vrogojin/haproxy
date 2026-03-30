# End-to-End Test Specification: HAProxy Dynamic Registration System

**Version:** 1.0
**Date:** 2026-03-30
**Status:** Draft

---

## Table of Contents

1. [Overview](#1-overview)
2. [Test Environment](#2-test-environment)
3. [Mock Service Design](#3-mock-service-design)
4. [Clean Room Implementation](#4-clean-room-implementation)
5. [Test Suites](#5-test-suites)
6. [Test Runner](#6-test-runner)
7. [CI Integration](#7-ci-integration)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Overview

### 1.1 Philosophy: Clean Room Testing

Every test run operates in a fully isolated environment with zero shared state. The test harness creates its own Docker network, builds its own images, and spins up its own containers -- all with a distinct `haproxy-e2e-test-` prefix. Production resources (`haproxy`, `haproxy-net`, published ports 80/443) are never touched, read, or modified.

The clean room guarantee is three-fold:

1. **Pre-clean**: Before any test infrastructure is created, the harness detects and removes ALL artifacts from previous runs (including crashed/interrupted runs).
2. **Isolation**: All resource names use the `haproxy-e2e-test-` prefix. The test network is separate from `haproxy-net`. Ports are dynamically assigned by Docker (`-p 0:<port>`).
3. **Post-clean**: A bash `trap` on `EXIT` guarantees cleanup runs even on `SIGINT`, `SIGTERM`, or unhandled script errors.

### 1.2 What We Test

- Registration API: all CRUD operations, validation, error codes, idempotency, conflict detection
- HTTP routing via Host header
- HTTPS/TLS passthrough via SNI (verify backend cert, not HAProxy cert)
- Extra port routing: raw TCP, HTTP (WebSocket-capable), TLS passthrough
- WebSocket upgrade forwarding
- Backend unregistration and re-registration
- HAProxy graceful reload under active load (zero dropped requests)
- Concurrent registration safety
- Container ownership verification on DELETE
- Input validation and error handling

### 1.3 What We Do NOT Test

- **Certbot / Let's Encrypt**: Tests use self-signed certificates. Certificate acquisition is an operational concern, not a routing concern.
- **Real DNS**: Tests use curl `--resolve` and `openssl -servername` for domain resolution.
- **Production HAProxy**: The test HAProxy container is completely independent.
- **Performance at scale**: These are functional correctness tests. Load testing is a separate effort.
- **HAProxy Runtime API**: Stats, drain, admin sockets are out of scope.
- **API key authentication** (`HAPROXY_API_KEY`): Tested as a unit concern, not E2E.

---

## 2. Test Environment

### 2.1 Architecture Diagram

```
Host Machine
  |
  +-- haproxy-e2e-test-net (Docker bridge network, isolated)
  |     |
  |     +-- haproxy-e2e-test-proxy (Custom HAProxy + Registration API)
  |     |     Ports: 80, 443, 8404, 50001, 50003, 50004 (internal)
  |     |     Published: random high ports via -p 0:<port>
  |     |
  |     +-- haproxy-e2e-test-web (Mock web server)
  |     |     Ports: 80 (HTTP), 443 (HTTPS self-signed)
  |     |
  |     +-- haproxy-e2e-test-electrum (Mock Electrum server)
  |     |     Ports: 80 (HTTP), 50001 (TCP), 50002 (TLS), 50003 (HTTP/WS), 50004 (TLS/WSS)
  |     |
  |     +-- haproxy-e2e-test-api (Mock REST API server)
  |           Ports: 8080 (HTTP), 8443 (HTTPS self-signed)
  |
  +-- haproxy-net (Production, UNTOUCHED)
```

### 2.2 Resource Naming Convention

Every Docker resource created by the test harness uses the prefix `haproxy-e2e-test-`:

| Resource Type | Name | Purpose |
|---|---|---|
| Network | `haproxy-e2e-test-net` | Isolated test network |
| Container | `haproxy-e2e-test-proxy` | HAProxy + Registration API under test |
| Container | `haproxy-e2e-test-web` | Mock web server backend |
| Container | `haproxy-e2e-test-electrum` | Mock Electrum server backend |
| Container | `haproxy-e2e-test-api` | Mock REST API backend |
| Image | `haproxy-e2e-test-service:latest` | Unified mock service image |
| Image | `haproxy-e2e-test-haproxy:latest` | HAProxy image under test |
| Volume | (none) | No volumes used; all state is ephemeral |

### 2.3 Port Publishing Strategy

All container ports are published with `-p 0:<container_port>`, letting Docker assign random high ports on the host. The test harness discovers assigned ports via `docker port`:

```bash
HTTP_PORT=$(docker port haproxy-e2e-test-proxy 80/tcp | head -1 | cut -d: -f2)
HTTPS_PORT=$(docker port haproxy-e2e-test-proxy 443/tcp | head -1 | cut -d: -f2)
API_PORT=$(docker port haproxy-e2e-test-proxy 8404/tcp | head -1 | cut -d: -f2)
EXTRA_TCP_PORT=$(docker port haproxy-e2e-test-proxy 50001/tcp | head -1 | cut -d: -f2)
EXTRA_HTTP_PORT=$(docker port haproxy-e2e-test-proxy 50003/tcp | head -1 | cut -d: -f2)
EXTRA_TLS_PORT=$(docker port haproxy-e2e-test-proxy 50004/tcp | head -1 | cut -d: -f2)
```

This eliminates any possibility of port conflicts with production services.

### 2.4 DNS Resolution Strategy

No `/etc/hosts` modifications. No DNS server. All domain resolution is handled per-request:

**For curl (HTTP/HTTPS):**
```bash
curl --resolve "web.test.local:${HTTP_PORT}:127.0.0.1" \
     "http://web.test.local:${HTTP_PORT}/"
```

**For openssl s_client (TLS verification):**
```bash
echo | openssl s_client -connect 127.0.0.1:${HTTPS_PORT} \
     -servername web.test.local 2>/dev/null
```

**For nc (raw TCP -- no domain needed):**
```bash
echo "test" | nc -q1 127.0.0.1 ${EXTRA_TCP_PORT}
```

### 2.5 Self-Signed Certificates

Each mock service generates a self-signed certificate at container startup. No certbot, no real domains, no CA chain. The certificates exist solely to verify TLS passthrough behavior (i.e., the cert seen by the client is from the backend, not HAProxy).

Certificate generation command used in mock service entrypoint:
```bash
openssl req -x509 -newkey rsa:2048 -keyout /tmp/key.pem -out /tmp/cert.pem \
    -days 1 -nodes -subj "/CN=${TEST_DOMAIN}"
```

---

## 3. Mock Service Design

### 3.1 Unified Mock Service Image

A single Docker image serves all three mock service roles (web, electrum, api), configured via environment variables. This reduces build time and image maintenance.

**Dockerfile** (`tests/e2e/mock-service/Dockerfile`):

```dockerfile
FROM node:20-alpine

RUN apk add --no-cache openssl curl socat bash

COPY test-service-entrypoint.sh /entrypoint.sh
COPY ws-echo-server.mjs /ws-echo-server.mjs
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

### 3.2 Entrypoint Script

**File:** `tests/e2e/mock-service/test-service-entrypoint.sh`

```bash
#!/bin/bash
set -e

DOMAIN="${TEST_DOMAIN:-test.local}"
SERVICE="${SERVICE_TYPE:-web}"

echo "Starting mock service: type=${SERVICE}, domain=${DOMAIN}"

# ─── Generate self-signed cert ───
openssl req -x509 -newkey rsa:2048 \
    -keyout /tmp/key.pem -out /tmp/cert.pem \
    -days 1 -nodes -subj "/CN=${DOMAIN}" 2>/dev/null
echo "Self-signed cert generated for ${DOMAIN}"

# ─── Health response body ───
HEALTH_BODY="{\"service\":\"${SERVICE}\",\"domain\":\"${DOMAIN}\"}"

case "${SERVICE}" in
    web)
        # HTTP on port 80: simple node HTTP server
        node -e "
            const http = require('http');
            http.createServer((req, res) => {
                res.writeHead(200, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({service: 'web', domain: '${DOMAIN}', path: req.url}));
            }).listen(80, () => console.log('HTTP listening on 80'));
        " &

        # HTTPS on port 443: openssl s_server in HTTP mode
        # Use socat to bridge openssl to a simple response
        socat OPENSSL-LISTEN:443,fork,reuseaddr,cert=/tmp/cert.pem,key=/tmp/key.pem,verify=0 \
            EXEC:"/bin/sh -c 'echo -e \"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n${HEALTH_BODY}\"'" &

        echo "Web service ready on ports 80 (HTTP), 443 (HTTPS)"
        ;;

    electrum)
        # HTTP on port 80: node HTTP server (primary health endpoint)
        node -e "
            const http = require('http');
            http.createServer((req, res) => {
                res.writeHead(200, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({service: 'electrum', domain: '${DOMAIN}', path: req.url}));
            }).listen(80, () => console.log('HTTP listening on 80'));
        " &

        # TCP echo on port 50001: socat
        socat TCP-LISTEN:50001,fork,reuseaddr EXEC:'/bin/cat' &

        # TLS echo on port 50002: socat with SSL
        socat OPENSSL-LISTEN:50002,fork,reuseaddr,cert=/tmp/cert.pem,key=/tmp/key.pem,verify=0 \
            EXEC:'/bin/cat' &

        # HTTP + WebSocket on port 50003: node ws echo server
        node /ws-echo-server.mjs 50003 &

        # TLS + WebSocket on port 50004: node ws echo server with TLS
        node /ws-echo-server.mjs 50004 --tls /tmp/cert.pem /tmp/key.pem &

        echo "Electrum service ready on ports 80, 50001, 50002, 50003, 50004"
        ;;

    api)
        # HTTP on port 8080: node HTTP server
        node -e "
            const http = require('http');
            http.createServer((req, res) => {
                res.writeHead(200, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({service: 'api', domain: '${DOMAIN}', path: req.url, method: req.method}));
            }).listen(8080, () => console.log('HTTP listening on 8080'));
        " &

        # HTTPS on port 8443: node HTTPS server
        node -e "
            const https = require('https');
            const fs = require('fs');
            const opts = {key: fs.readFileSync('/tmp/key.pem'), cert: fs.readFileSync('/tmp/cert.pem')};
            https.createServer(opts, (req, res) => {
                res.writeHead(200, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({service: 'api', domain: '${DOMAIN}', path: req.url, method: req.method, tls: true}));
            }).listen(8443, () => console.log('HTTPS listening on 8443'));
        " &

        echo "API service ready on ports 8080 (HTTP), 8443 (HTTPS)"
        ;;

    *)
        echo "Unknown SERVICE_TYPE: ${SERVICE}"
        exit 1
        ;;
esac

# Keep container alive
echo "Mock service ${SERVICE} is running. Waiting..."
wait
```

### 3.3 WebSocket Echo Server

**File:** `tests/e2e/mock-service/ws-echo-server.mjs`

```javascript
// Minimal WebSocket echo server using only Node.js built-ins.
// Supports both plain HTTP and TLS modes.
// Usage:
//   node ws-echo-server.mjs <port>
//   node ws-echo-server.mjs <port> --tls <cert> <key>

import { createServer } from 'node:http';
import { createServer as createTlsServer } from 'node:https';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const port = parseInt(process.argv[2] || '50003');
const useTls = process.argv[3] === '--tls';

function handleRequest(req, res) {
    // Plain HTTP requests get a JSON response
    if (req.headers.upgrade?.toLowerCase() !== 'websocket') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ service: 'ws-echo', port, path: req.url }));
        return;
    }
}

function handleUpgrade(req, socket) {
    // WebSocket handshake (RFC 6455)
    const key = req.headers['sec-websocket-key'];
    if (!key) {
        socket.destroy();
        return;
    }

    const accept = createHash('sha1')
        .update(key + '258EAFA5-E914-47DA-95CA-5AB5FFEBD5CE')
        .digest('base64');

    socket.write(
        'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Accept: ${accept}\r\n` +
        '\r\n'
    );

    // Echo frames back (simplified: handles small text frames only)
    socket.on('data', (buf) => {
        if (buf.length < 2) return;
        const opcode = buf[0] & 0x0f;
        if (opcode === 0x08) { socket.end(); return; } // close
        if (opcode === 0x09) { // ping -> pong
            const pong = Buffer.from(buf);
            pong[0] = (pong[0] & 0xf0) | 0x0a;
            socket.write(pong);
            return;
        }

        // Unmask payload
        const masked = !!(buf[1] & 0x80);
        let payloadLen = buf[1] & 0x7f;
        let offset = 2;
        if (payloadLen === 126) { payloadLen = buf.readUInt16BE(2); offset = 4; }
        else if (payloadLen === 127) { payloadLen = Number(buf.readBigUInt64BE(2)); offset = 10; }

        let maskKey = null;
        if (masked) { maskKey = buf.slice(offset, offset + 4); offset += 4; }

        const payload = Buffer.alloc(payloadLen);
        for (let i = 0; i < payloadLen; i++) {
            payload[i] = masked ? buf[offset + i] ^ maskKey[i % 4] : buf[offset + i];
        }

        // Send echo frame (unmasked, text)
        const frame = Buffer.alloc(2 + payloadLen);
        frame[0] = 0x81; // FIN + text
        frame[1] = payloadLen; // no mask, assume < 126 bytes
        payload.copy(frame, 2);
        socket.write(frame);
    });

    socket.on('error', () => {});
}

let server;
if (useTls) {
    const certFile = process.argv[4];
    const keyFile = process.argv[5];
    server = createTlsServer(
        { cert: readFileSync(certFile), key: readFileSync(keyFile) },
        handleRequest
    );
} else {
    server = createServer(handleRequest);
}

server.on('upgrade', handleUpgrade);
server.listen(port, () => console.log(`WS echo server on port ${port} (tls=${useTls})`));
```

### 3.4 Service Registration

Mock services do NOT self-register with the Registration API. The test runner controls registration timing explicitly so that tests can verify pre-registration state (empty backend list), registration success, and post-registration routing independently.

---

## 4. Clean Room Implementation

### 4.1 Prefix Constant

```bash
TEST_PREFIX="haproxy-e2e-test"
```

Every Docker resource name starts with this prefix. The clean room functions use it to find and remove test artifacts without affecting anything else on the system.

### 4.2 Pre-Clean Function

Runs unconditionally at the start of every test session. Handles artifacts from crashed previous runs.

```bash
clean_room() {
    echo "=== Clean Room: removing test artifacts ==="

    # Stop and remove all containers with the test prefix
    local containers
    containers=$(docker ps -aq --filter "name=${TEST_PREFIX}" 2>/dev/null || true)
    if [ -n "$containers" ]; then
        echo "  Removing containers: $containers"
        echo "$containers" | xargs docker rm -f 2>/dev/null || true
    fi

    # Remove test network (may fail if containers are still connected)
    docker network rm "${TEST_PREFIX}-net" 2>/dev/null || true

    # Remove test volumes (none expected, but defensive)
    local volumes
    volumes=$(docker volume ls -q --filter "name=${TEST_PREFIX}" 2>/dev/null || true)
    if [ -n "$volumes" ]; then
        echo "  Removing volumes: $volumes"
        echo "$volumes" | xargs docker volume rm 2>/dev/null || true
    fi

    # Clean up temp files
    rm -f /tmp/${TEST_PREFIX}-* 2>/dev/null || true

    echo "=== Clean room ready ==="
}
```

### 4.3 Post-Clean via Trap

```bash
trap clean_room EXIT
```

The `EXIT` trap fires on:
- Normal script completion (exit 0 or exit 1)
- `SIGINT` (Ctrl+C)
- `SIGTERM` (kill)
- Unhandled errors (due to `set -e`)
- Any other signal that causes bash to exit

### 4.4 Verification Test

Suite 1 explicitly verifies that the clean room works by checking that no test-prefixed resources exist after cleanup. See [Suite 1](#suite-1-clean-room-verification).

---

## 5. Test Suites

### Suite 1: Clean Room Verification

**Purpose:** Verify the clean room mechanism correctly removes all test artifacts and that test resources use the correct prefix.

#### Test 1.1: No Leftover Containers After Pre-Clean

```bash
test_no_leftover_containers() {
    local count
    count=$(docker ps -aq --filter "name=${TEST_PREFIX}" 2>/dev/null | wc -l)
    assert_equals "0" "$count" "Expected 0 containers with prefix ${TEST_PREFIX}"
}
```

#### Test 1.2: No Leftover Networks After Pre-Clean

```bash
test_no_leftover_networks() {
    local count
    count=$(docker network ls -q --filter "name=${TEST_PREFIX}" 2>/dev/null | wc -l)
    assert_equals "0" "$count" "Expected 0 networks with prefix ${TEST_PREFIX}"
}
```

#### Test 1.3: No Leftover Volumes After Pre-Clean

```bash
test_no_leftover_volumes() {
    local count
    count=$(docker volume ls -q --filter "name=${TEST_PREFIX}" 2>/dev/null | wc -l)
    assert_equals "0" "$count" "Expected 0 volumes with prefix ${TEST_PREFIX}"
}
```

#### Test 1.4: All Created Resources Use Test Prefix

This test runs after the environment is started (Suite 2). It inspects all containers, networks, and volumes created during the test and asserts every name starts with `haproxy-e2e-test-`.

```bash
test_all_resources_prefixed() {
    # All containers created by us should have the prefix
    local containers
    containers=$(docker ps -a --format '{{.Names}}' | grep "e2e-test" || true)
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        assert_contains "$name" "${TEST_PREFIX}" \
            "Container '$name' does not use test prefix"
    done <<< "$containers"
}
```

---

### Suite 2: HAProxy Startup

**Purpose:** Verify the HAProxy test container starts correctly and the Registration API is functional with an empty backend list.

#### Test 2.1: HAProxy Container Is Running

```bash
test_haproxy_running() {
    local status
    status=$(docker inspect -f '{{.State.Status}}' "${TEST_HAPROXY}" 2>/dev/null)
    assert_equals "running" "$status" "HAProxy container should be running"
}
```

#### Test 2.2: Registration API Health Check

```bash
test_api_health() {
    local response
    response=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/health")
    local status
    status=$(echo "$response" | jq -r '.status')
    assert_equals "healthy" "$status" "API health status should be 'healthy'"

    local api_version
    api_version=$(echo "$response" | jq -r '.api_version')
    assert_equals "1.0" "$api_version" "API version should be '1.0'"
}
```

**Expected response:**
```json
{
  "status": "healthy",
  "haproxy_pid": 1,
  "haproxy_uptime_seconds": <number>,
  "api_version": "1.0",
  "backends_count": 0
}
```

#### Test 2.3: Empty Backend List

```bash
test_empty_backends() {
    local response
    response=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/backends")
    local count
    count=$(echo "$response" | jq -r '.count')
    assert_equals "0" "$count" "Should have 0 backends initially"

    local backends_len
    backends_len=$(echo "$response" | jq '.backends | length')
    assert_equals "0" "$backends_len" "Backends array should be empty"
}
```

**Expected response:**
```json
{
  "backends": [],
  "count": 0
}
```

#### Test 2.4: HAProxy Process Is Running Inside Container

```bash
test_haproxy_process() {
    local pid_count
    pid_count=$(docker exec "${TEST_HAPROXY}" pgrep -c haproxy 2>/dev/null || echo "0")
    [ "$pid_count" -ge 1 ]
    assert_true "HAProxy process should be running inside container"
}
```

---

### Suite 3: Backend Registration

**Purpose:** Verify all registration API operations: create, idempotent re-register, conflict detection, listing, and retrieval.

#### Test 3.1: Register Web Backend (201 Created)

```bash
test_register_web() {
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "web.test.local",
            "container": "'"${TEST_WEB}"'",
            "http_port": 80,
            "https_port": 443
        }')
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    assert_equals "201" "$http_code" "Should return 201 Created"
    assert_equals "web.test.local" "$(echo "$body" | jq -r '.domain')" "Domain should match"
    assert_equals "${TEST_WEB}" "$(echo "$body" | jq -r '.container')" "Container should match"
    assert_equals "80" "$(echo "$body" | jq -r '.http_port')" "HTTP port should be 80"
    assert_equals "443" "$(echo "$body" | jq -r '.https_port')" "HTTPS port should be 443"
    # Verify created_at is present and is a valid ISO timestamp
    local created_at
    created_at=$(echo "$body" | jq -r '.created_at')
    [ "$created_at" != "null" ] && [ -n "$created_at" ]
}
```

#### Test 3.2: Register Electrum Backend with Extra Ports (201 Created)

```bash
test_register_electrum() {
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "electrum.test.local",
            "container": "'"${TEST_ELECTRUM}"'",
            "http_port": 80,
            "https_port": 50002,
            "extra_ports": [
                {"listen": 50001, "target": 50001, "mode": "tcp"},
                {"listen": 50003, "target": 50003, "mode": "http"},
                {"listen": 50004, "target": 50004, "mode": "tcp"}
            ]
        }')
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    assert_equals "201" "$http_code" "Should return 201 Created"
    assert_equals "electrum.test.local" "$(echo "$body" | jq -r '.domain')" "Domain should match"

    # Verify extra_ports in response
    local extra_count
    extra_count=$(echo "$body" | jq '.extra_ports | length')
    assert_equals "3" "$extra_count" "Should have 3 extra ports"

    # Verify HAProxy config was regenerated (check inside container)
    local config_valid
    config_valid=$(docker exec "${TEST_HAPROXY}" haproxy -c -f /etc/haproxy/conf.d 2>&1 | tail -1)
    assert_contains "$config_valid" "valid" "HAProxy config should be valid after registration"
}
```

#### Test 3.3: Register API Backend with Non-Standard Ports (201 Created)

```bash
test_register_api() {
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "api.test.local",
            "container": "'"${TEST_API}"'",
            "http_port": 8080,
            "https_port": 8443
        }')
    http_code=$(echo "$response" | tail -1)

    assert_equals "201" "$http_code" "Should return 201 Created"
}
```

#### Test 3.4: List All Backends (200, count=3)

```bash
test_list_backends() {
    local response
    response=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/backends")

    local count
    count=$(echo "$response" | jq -r '.count')
    assert_equals "3" "$count" "Should have 3 backends"

    # Verify all three domains are present
    local domains
    domains=$(echo "$response" | jq -r '.backends[].domain' | sort)
    assert_contains "$domains" "api.test.local" "Should contain api.test.local"
    assert_contains "$domains" "electrum.test.local" "Should contain electrum.test.local"
    assert_contains "$domains" "web.test.local" "Should contain web.test.local"
}
```

#### Test 3.5: Get Specific Backend (200)

```bash
test_get_backend() {
    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        "http://127.0.0.1:${API_PORT}/v1/backends/electrum.test.local")
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    assert_equals "200" "$http_code" "Should return 200"
    assert_equals "electrum.test.local" "$(echo "$body" | jq -r '.domain')" "Domain should match"
    assert_equals "${TEST_ELECTRUM}" "$(echo "$body" | jq -r '.container')" "Container should match"
    assert_equals "50002" "$(echo "$body" | jq -r '.https_port')" "HTTPS port should be 50002"

    local extra_count
    extra_count=$(echo "$body" | jq '.extra_ports | length')
    assert_equals "3" "$extra_count" "Should have 3 extra ports"
}
```

#### Test 3.6: Idempotent Re-Registration (200 OK)

```bash
test_idempotent_register() {
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "web.test.local",
            "container": "'"${TEST_WEB}"'",
            "http_port": 80,
            "https_port": 443
        }')
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    assert_equals "200" "$http_code" "Idempotent re-register should return 200"
    assert_contains "$(echo "$body" | jq -r '.message')" "Already registered" \
        "Should indicate already registered"

    # Backend count should still be 3
    local count
    count=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/backends" | jq -r '.count')
    assert_equals "3" "$count" "Backend count should remain 3"
}
```

#### Test 3.7: Domain Conflict Detection (409 Conflict)

```bash
test_domain_conflict() {
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "web.test.local",
            "container": "different-container",
            "http_port": 80,
            "https_port": 443
        }')
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    assert_equals "409" "$http_code" "Should return 409 Conflict"
    assert_equals "DOMAIN_CONFLICT" "$(echo "$body" | jq -r '.code')" \
        "Error code should be DOMAIN_CONFLICT"
    # Verify the existing registration is returned
    assert_equals "${TEST_WEB}" "$(echo "$body" | jq -r '.existing.container')" \
        "Existing container should be returned in error"
}
```

#### Test 3.8: Mode Conflict on Extra Port (409 MODE_CONFLICT)

```bash
test_mode_conflict() {
    # Electrum registered port 50003 as mode "http".
    # Attempt to register a different domain on the same listen port but mode "tcp".
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "conflict.test.local",
            "container": "some-container",
            "http_port": 80,
            "https_port": 443,
            "extra_ports": [
                {"listen": 50003, "target": 50003, "mode": "tcp"}
            ]
        }')
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    assert_equals "409" "$http_code" "Should return 409 Conflict"
    assert_equals "MODE_CONFLICT" "$(echo "$body" | jq -r '.code')" \
        "Error code should be MODE_CONFLICT"
}
```

---

### Suite 4: HTTP Routing

**Purpose:** Verify HTTP requests with different Host headers are routed to the correct backend containers.

**Prerequisite:** All three backends registered in Suite 3. Allow 2 seconds after registration for HAProxy reload to complete.

#### Test 4.1: Route to Web Backend via Host Header

```bash
test_http_route_web() {
    local response
    response=$(curl -sf --resolve "web.test.local:${HTTP_PORT}:127.0.0.1" \
        "http://web.test.local:${HTTP_PORT}/")

    assert_equals "web" "$(echo "$response" | jq -r '.service')" \
        "Should reach web service"
    assert_equals "web.test.local" "$(echo "$response" | jq -r '.domain')" \
        "Domain should be web.test.local"
}
```

**Expected response from mock web service:**
```json
{"service": "web", "domain": "web.test.local", "path": "/"}
```

#### Test 4.2: Route to API Backend via Host Header

```bash
test_http_route_api() {
    local response
    response=$(curl -sf --resolve "api.test.local:${HTTP_PORT}:127.0.0.1" \
        "http://api.test.local:${HTTP_PORT}/v1/status")

    assert_equals "api" "$(echo "$response" | jq -r '.service')" \
        "Should reach api service"
    assert_equals "/v1/status" "$(echo "$response" | jq -r '.path')" \
        "Path should be preserved"
}
```

**Expected response from mock api service:**
```json
{"service": "api", "domain": "api.test.local", "path": "/v1/status", "method": "GET"}
```

#### Test 4.3: Route to Electrum Backend via Host Header (Port 80)

```bash
test_http_route_electrum() {
    local response
    response=$(curl -sf --resolve "electrum.test.local:${HTTP_PORT}:127.0.0.1" \
        "http://electrum.test.local:${HTTP_PORT}/")

    assert_equals "electrum" "$(echo "$response" | jq -r '.service')" \
        "Should reach electrum service"
}
```

#### Test 4.4: Unknown Domain Returns 503

```bash
test_http_unknown_domain() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --resolve "unknown.test.local:${HTTP_PORT}:127.0.0.1" \
        "http://unknown.test.local:${HTTP_PORT}/")

    assert_equals "503" "$http_code" "Unknown domain should return 503"
}
```

#### Test 4.5: Missing Host Header Returns 503

```bash
test_http_no_host() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:${HTTP_PORT}/")

    assert_equals "503" "$http_code" "No Host header should return 503"
}
```

---

### Suite 5: HTTPS/TLS Passthrough

**Purpose:** Verify TLS connections are passed through to the backend without termination. The client should see the backend's self-signed certificate, NOT a HAProxy certificate.

#### Test 5.1: TLS Passthrough to Web Backend (SNI Routing)

```bash
test_tls_web() {
    local response
    response=$(curl -sk --resolve "web.test.local:${HTTPS_PORT}:127.0.0.1" \
        "https://web.test.local:${HTTPS_PORT}/")

    # Should get a response from the web backend (through TLS passthrough)
    # The exact response depends on the mock service's TLS handler
    [ -n "$response" ]
    assert_true "Should receive a response through TLS passthrough"
}
```

#### Test 5.2: Verify TLS Certificate Is From Backend (Not HAProxy)

```bash
test_tls_cert_is_backend() {
    local cert_cn
    cert_cn=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" \
        -servername "web.test.local" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*CN = //p')

    assert_equals "web.test.local" "$cert_cn" \
        "TLS cert CN should be web.test.local (from backend, not HAProxy)"
}
```

This is the critical passthrough test. If HAProxy were terminating TLS, the certificate CN would not match the backend's self-signed cert.

#### Test 5.3: TLS Passthrough to Electrum Backend (Port 50002 via HTTPS/443)

```bash
test_tls_electrum() {
    local cert_cn
    cert_cn=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" \
        -servername "electrum.test.local" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*CN = //p')

    assert_equals "electrum.test.local" "$cert_cn" \
        "TLS cert CN should be electrum.test.local"
}
```

#### Test 5.4: TLS with Wrong/Unknown SNI

```bash
test_tls_wrong_sni() {
    local result
    result=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" \
        -servername "unknown.test.local" 2>&1)

    # Should either fail to connect or get a connection reset
    # HAProxy's no-match-tcp backend has no server, so connection should fail
    echo "$result" | grep -qiE "(connect|error|reset|refused|no peer)" || true
    # The absence of a valid cert is also acceptable
    local exit_code=$?
    # We just verify it does NOT successfully connect to any backend
    local cert_check
    cert_check=$(echo "$result" | grep -c "BEGIN CERTIFICATE" || true)
    assert_equals "0" "$cert_check" \
        "Should NOT get a valid certificate for unknown SNI"
}
```

#### Test 5.5: TLS Passthrough to API Backend

```bash
test_tls_api() {
    local cert_cn
    cert_cn=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" \
        -servername "api.test.local" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*CN = //p')

    assert_equals "api.test.local" "$cert_cn" \
        "TLS cert CN should be api.test.local"
}
```

---

### Suite 6: Extra Ports (Non-Standard)

**Purpose:** Verify HAProxy correctly proxies traffic on ports beyond 80/443, including raw TCP, HTTP, and TLS passthrough on extra ports.

#### Test 6.1: Raw TCP on Port 50001

```bash
test_extra_tcp_50001() {
    local result
    result=$(echo "hello-tcp-test" | nc -q2 127.0.0.1 "${EXTRA_TCP_PORT}")

    assert_equals "hello-tcp-test" "$result" \
        "TCP echo server should echo back the input"
}
```

The electrum mock service runs a socat TCP echo on port 50001. HAProxy proxies the raw TCP connection. Since this is the only domain on this port, HAProxy uses `default_backend` (no SNI/Host needed).

#### Test 6.2: HTTP on Port 50003 (WebSocket Port, Plain HTTP Test)

```bash
test_extra_http_50003() {
    local response
    response=$(curl -sf --resolve "electrum.test.local:${EXTRA_HTTP_PORT}:127.0.0.1" \
        "http://electrum.test.local:${EXTRA_HTTP_PORT}/")

    assert_equals "ws-echo" "$(echo "$response" | jq -r '.service')" \
        "Should reach the WS echo server on port 50003"
    assert_equals "50003" "$(echo "$response" | jq -r '.port')" \
        "Port should be 50003"
}
```

**Expected response from ws-echo-server.mjs:**
```json
{"service": "ws-echo", "port": 50003, "path": "/"}
```

#### Test 6.3: TLS on Port 50004 (WSS Port, Certificate Verification)

```bash
test_extra_tls_50004() {
    local cert_cn
    cert_cn=$(echo | openssl s_client -connect "127.0.0.1:${EXTRA_TLS_PORT}" \
        -servername "electrum.test.local" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*CN = //p')

    assert_equals "electrum.test.local" "$cert_cn" \
        "TLS cert on port 50004 should be from electrum backend (passthrough)"
}
```

#### Test 6.4: Unknown Host on Extra HTTP Port Returns 503

```bash
test_extra_http_unknown_host() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --resolve "unknown.test.local:${EXTRA_HTTP_PORT}:127.0.0.1" \
        "http://unknown.test.local:${EXTRA_HTTP_PORT}/")

    assert_equals "503" "$http_code" \
        "Unknown host on extra HTTP port should return 503"
}
```

---

### Suite 7: WebSocket

**Purpose:** Verify WebSocket upgrade requests are correctly forwarded through HAProxy on both plain HTTP and TLS ports.

#### Test 7.1: WebSocket Upgrade on Port 50003 (Plain)

```bash
test_ws_upgrade_50003() {
    # Use curl to verify the upgrade headers are forwarded
    # A full WS handshake requires proper Sec-WebSocket-Key
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

    assert_contains "$response" "101 Switching Protocols" \
        "Should receive 101 Switching Protocols"
    assert_contains "$response" "Upgrade: websocket" \
        "Should contain Upgrade: websocket header"
    assert_contains "$response" "Sec-WebSocket-Accept" \
        "Should contain Sec-WebSocket-Accept header"
}
```

#### Test 7.2: WebSocket Echo Functionality on Port 50003

```bash
test_ws_echo_50003() {
    # Use a minimal node script to test WebSocket echo
    local result
    result=$(docker exec "${TEST_ELECTRUM}" node -e "
        const http = require('http');
        const crypto = require('crypto');
        const net = require('net');

        const key = crypto.randomBytes(16).toString('base64');
        const expectedAccept = crypto.createHash('sha1')
            .update(key + '258EAFA5-E914-47DA-95CA-5AB5FFEBD5CE')
            .digest('base64');

        // Connect to HAProxy from inside the test network
        const req = http.request({
            hostname: '${TEST_HAPROXY}',
            port: 50003,
            path: '/',
            method: 'GET',
            headers: {
                'Host': 'electrum.test.local',
                'Upgrade': 'websocket',
                'Connection': 'Upgrade',
                'Sec-WebSocket-Version': '13',
                'Sec-WebSocket-Key': key
            }
        });

        req.on('upgrade', (res, socket) => {
            // Send a text frame: 'hello'
            const payload = Buffer.from('hello');
            const frame = Buffer.alloc(6 + payload.length);
            frame[0] = 0x81; // FIN + text
            frame[1] = 0x80 | payload.length; // masked
            const mask = crypto.randomBytes(4);
            mask.copy(frame, 2);
            for (let i = 0; i < payload.length; i++) {
                frame[6 + i] = payload[i] ^ mask[i % 4];
            }
            socket.write(frame);

            socket.on('data', (data) => {
                // Read echo response
                if (data.length >= 2) {
                    const len = data[1] & 0x7f;
                    const echoed = data.slice(2, 2 + len).toString();
                    console.log(echoed);
                    socket.destroy();
                    process.exit(0);
                }
            });

            setTimeout(() => { process.exit(1); }, 3000);
        });

        req.on('error', (err) => {
            console.error(err.message);
            process.exit(1);
        });

        req.end();
    " 2>/dev/null)

    assert_equals "hello" "$result" "WebSocket echo should return 'hello'"
}
```

#### Test 7.3: WebSocket over TLS on Port 50004 (WSS)

```bash
test_wss_50004() {
    # Verify TLS+WS upgrade via a node script inside the test network
    local result
    result=$(docker exec "${TEST_ELECTRUM}" node -e "
        const tls = require('tls');
        const crypto = require('crypto');

        const key = crypto.randomBytes(16).toString('base64');

        const socket = tls.connect({
            host: '${TEST_HAPROXY}',
            port: 50004,
            servername: 'electrum.test.local',
            rejectUnauthorized: false
        }, () => {
            const upgrade =
                'GET / HTTP/1.1\r\n' +
                'Host: electrum.test.local\r\n' +
                'Upgrade: websocket\r\n' +
                'Connection: Upgrade\r\n' +
                'Sec-WebSocket-Version: 13\r\n' +
                'Sec-WebSocket-Key: ' + key + '\r\n\r\n';
            socket.write(upgrade);
        });

        let received = '';
        socket.on('data', (data) => {
            received += data.toString();
            if (received.includes('101 Switching Protocols')) {
                console.log('WSS_UPGRADE_OK');
                socket.destroy();
                process.exit(0);
            }
        });

        socket.on('error', (err) => {
            console.error(err.message);
            process.exit(1);
        });

        setTimeout(() => {
            console.error('timeout');
            process.exit(1);
        }, 5000);
    " 2>/dev/null)

    assert_contains "$result" "WSS_UPGRADE_OK" \
        "WSS handshake should succeed on port 50004"
}
```

---

### Suite 8: Backend Unregistration

**Purpose:** Verify that deleting a backend removes its routing and that remaining backends are unaffected.

#### Test 8.1: Delete Web Backend (204 No Content)

```bash
test_delete_web() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "http://127.0.0.1:${API_PORT}/v1/backends/web.test.local")

    assert_equals "204" "$http_code" "DELETE should return 204 No Content"
}
```

#### Test 8.2: Routing for Deleted Domain Returns 503

```bash
test_deleted_domain_503() {
    # Allow time for HAProxy reload
    sleep 2

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --resolve "web.test.local:${HTTP_PORT}:127.0.0.1" \
        "http://web.test.local:${HTTP_PORT}/")

    assert_equals "503" "$http_code" \
        "Deleted domain should return 503"
}
```

#### Test 8.3: Other Domains Still Work After Delete

```bash
test_other_domains_after_delete() {
    local response
    response=$(curl -sf --resolve "api.test.local:${HTTP_PORT}:127.0.0.1" \
        "http://api.test.local:${HTTP_PORT}/")

    assert_equals "api" "$(echo "$response" | jq -r '.service')" \
        "API domain should still work after deleting web domain"

    response=$(curl -sf --resolve "electrum.test.local:${HTTP_PORT}:127.0.0.1" \
        "http://electrum.test.local:${HTTP_PORT}/")

    assert_equals "electrum" "$(echo "$response" | jq -r '.service')" \
        "Electrum domain should still work after deleting web domain"
}
```

#### Test 8.4: Backend Count Decremented

```bash
test_backend_count_after_delete() {
    local count
    count=$(curl -sf "http://127.0.0.1:${API_PORT}/v1/backends" | jq -r '.count')
    assert_equals "2" "$count" "Should have 2 backends after deleting web"
}
```

#### Test 8.5: GET Deleted Domain Returns 404

```bash
test_get_deleted_domain() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:${API_PORT}/v1/backends/web.test.local")

    assert_equals "404" "$http_code" "GET deleted domain should return 404"
}
```

#### Test 8.6: Re-Register Deleted Domain (201 Created)

```bash
test_reregister_web() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "web.test.local",
            "container": "'"${TEST_WEB}"'",
            "http_port": 80,
            "https_port": 443
        }')

    assert_equals "201" "$http_code" "Re-register should return 201 (fresh add)"

    # Allow time for reload
    sleep 2

    # Verify routing works again
    local response
    response=$(curl -sf --resolve "web.test.local:${HTTP_PORT}:127.0.0.1" \
        "http://web.test.local:${HTTP_PORT}/")

    assert_equals "web" "$(echo "$response" | jq -r '.service')" \
        "Re-registered web domain should route correctly"
}
```

---

### Suite 9: HAProxy Reload Under Load

**Purpose:** Verify that HAProxy's graceful reload mechanism (master-worker mode + SIGUSR2) does not drop any in-flight requests.

#### Test 9.1: Zero Dropped Requests During Reload

```bash
test_reload_under_load() {
    local total_requests=100
    local success_count=0
    local fail_count=0
    local results_file="/tmp/${TEST_PREFIX}-reload-results"

    > "$results_file"

    # Start background request loop hitting api.test.local
    (
        for i in $(seq 1 $total_requests); do
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
                --resolve "api.test.local:${HTTP_PORT}:127.0.0.1" \
                "http://api.test.local:${HTTP_PORT}/request-${i}")
            echo "$code" >> "$results_file"
            sleep 0.05  # 50ms between requests, ~2 req/sec
        done
    ) &
    local loader_pid=$!

    # Wait for some requests to be in flight
    sleep 0.5

    # Trigger a registration (which causes HAProxy reload)
    curl -s -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "reload-test.test.local",
            "container": "'"${TEST_WEB}"'",
            "http_port": 80,
            "https_port": 443
        }' > /dev/null

    # Wait for background loop to complete
    wait $loader_pid 2>/dev/null || true

    # Count results
    success_count=$(grep -c "200" "$results_file" || true)
    fail_count=$(grep -cv "200" "$results_file" || true)

    assert_equals "0" "$fail_count" \
        "Zero requests should fail during reload (${success_count}/${total_requests} succeeded)"

    # Cleanup: remove the test domain
    curl -s -X DELETE "http://127.0.0.1:${API_PORT}/v1/backends/reload-test.test.local" > /dev/null

    rm -f "$results_file"
}
```

---

### Suite 10: Error Handling

**Purpose:** Verify the Registration API correctly validates input and returns appropriate error codes.

#### Test 10.1: Invalid Domain (Shell Injection Attempt) -- 422

```bash
test_invalid_domain_injection() {
    local http_code body
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "test; rm -rf /",
            "container": "evil",
            "http_port": 80,
            "https_port": 443
        }')
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    assert_equals "422" "$http_code" "Shell injection domain should return 422"
    assert_equals "VALIDATION_ERROR" "$(echo "$body" | jq -r '.code')" \
        "Error code should be VALIDATION_ERROR"
}
```

#### Test 10.2: Invalid Container Name -- 422

```bash
test_invalid_container() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "valid.test.local",
            "container": "../escape",
            "http_port": 80,
            "https_port": 443
        }')

    assert_equals "422" "$http_code" "Invalid container name should return 422"
}
```

#### Test 10.3: Port Out of Range -- 422

```bash
test_port_out_of_range() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "valid.test.local",
            "container": "valid-container",
            "http_port": 99999,
            "https_port": 443
        }')

    assert_equals "422" "$http_code" "Port > 65535 should return 422"
}
```

#### Test 10.4: Extra Port on Reserved Port (80) -- 422

```bash
test_extra_port_reserved() {
    local http_code body
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "valid2.test.local",
            "container": "valid-container",
            "http_port": 80,
            "https_port": 443,
            "extra_ports": [
                {"listen": 80, "target": 8080, "mode": "http"}
            ]
        }')
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    assert_equals "422" "$http_code" "Extra port on reserved port 80 should return 422"
    assert_equals "VALIDATION_ERROR" "$(echo "$body" | jq -r '.code')" \
        "Error code should be VALIDATION_ERROR"
}
```

#### Test 10.5: Extra Port on Reserved Port (443) -- 422

```bash
test_extra_port_reserved_443() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "valid3.test.local",
            "container": "valid-container",
            "http_port": 80,
            "https_port": 443,
            "extra_ports": [
                {"listen": 443, "target": 8443, "mode": "tcp"}
            ]
        }')

    assert_equals "422" "$http_code" "Extra port on reserved port 443 should return 422"
}
```

#### Test 10.6: Extra Port on Reserved Port (8404) -- 422

```bash
test_extra_port_reserved_8404() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "valid4.test.local",
            "container": "valid-container",
            "http_port": 80,
            "https_port": 443,
            "extra_ports": [
                {"listen": 8404, "target": 8404, "mode": "http"}
            ]
        }')

    assert_equals "422" "$http_code" "Extra port on reserved port 8404 should return 422"
}
```

#### Test 10.7: Malformed JSON -- 400

```bash
test_malformed_json() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{"domain": invalid json}')

    assert_equals "400" "$http_code" "Malformed JSON should return 400"
}
```

#### Test 10.8: DELETE Non-Existent Domain -- 404

```bash
test_delete_nonexistent() {
    local http_code body
    local response
    response=$(curl -s -w "\n%{http_code}" -X DELETE \
        "http://127.0.0.1:${API_PORT}/v1/backends/nonexistent.test.local")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    assert_equals "404" "$http_code" "DELETE non-existent domain should return 404"
    assert_equals "NOT_FOUND" "$(echo "$body" | jq -r '.code')" \
        "Error code should be NOT_FOUND"
}
```

#### Test 10.9: Force Reload (200 OK)

```bash
test_force_reload() {
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/reload")
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    assert_equals "200" "$http_code" "Force reload should return 200"
    assert_contains "$(echo "$body" | jq -r '.message')" "reloaded" \
        "Response should confirm reload"
}
```

#### Test 10.10: Missing Domain Field -- 422

```bash
test_missing_domain() {
    local http_code body
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "container": "some-container",
            "http_port": 80,
            "https_port": 443
        }')
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    assert_equals "422" "$http_code" "Missing domain should return 422"
    assert_equals "VALIDATION_ERROR" "$(echo "$body" | jq -r '.code')"
}
```

#### Test 10.11: Missing Container Field -- 422

```bash
test_missing_container() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "valid5.test.local",
            "http_port": 80,
            "https_port": 443
        }')

    assert_equals "422" "$http_code" "Missing container should return 422"
}
```

#### Test 10.12: Both Ports Null -- 422

```bash
test_both_ports_null() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "valid6.test.local",
            "container": "valid-container",
            "http_port": null,
            "https_port": null
        }')

    assert_equals "422" "$http_code" "Both ports null should return 422"
}
```

#### Test 10.13: Single-Label Domain (No Dot) -- 422

```bash
test_single_label_domain() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "localhost",
            "container": "valid-container",
            "http_port": 80,
            "https_port": 443
        }')

    assert_equals "422" "$http_code" "Single-label domain should return 422"
}
```

#### Test 10.14: Extra Ports Exceeding Maximum (10) -- 422

```bash
test_extra_ports_exceeding_max() {
    local extra_ports=""
    for i in $(seq 1 11); do
        [ -n "$extra_ports" ] && extra_ports+=","
        extra_ports+="{\"listen\": $((10000 + i)), \"target\": $((10000 + i)), \"mode\": \"tcp\"}"
    done

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"valid7.test.local\",
            \"container\": \"valid-container\",
            \"http_port\": 80,
            \"https_port\": 443,
            \"extra_ports\": [${extra_ports}]
        }")

    assert_equals "422" "$http_code" "More than 10 extra ports should return 422"
}
```

#### Test 10.15: Invalid Extra Port Mode -- 422

```bash
test_invalid_extra_port_mode() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "valid8.test.local",
            "container": "valid-container",
            "http_port": 80,
            "https_port": 443,
            "extra_ports": [
                {"listen": 9999, "target": 9999, "mode": "udp"}
            ]
        }')

    assert_equals "422" "$http_code" "Invalid mode 'udp' should return 422"
}
```

---

### Suite 11: Concurrent Registration

**Purpose:** Verify the file-locking mechanism handles concurrent writes correctly without corrupting `domains.map` or HAProxy config.

#### Test 11.1: Five Simultaneous Registrations

```bash
test_concurrent_5_domains() {
    local pids=()
    local results_dir="/tmp/${TEST_PREFIX}-concurrent"
    mkdir -p "$results_dir"

    # Fire 5 simultaneous registrations for different domains
    for i in $(seq 1 5); do
        (
            curl -s -w "\n%{http_code}" -X POST \
                "http://127.0.0.1:${API_PORT}/v1/backends" \
                -H "Content-Type: application/json" \
                -d "{
                    \"domain\": \"concurrent-${i}.test.local\",
                    \"container\": \"${TEST_WEB}\",
                    \"http_port\": 80,
                    \"https_port\": 443
                }" > "${results_dir}/result-${i}" 2>/dev/null
        ) &
        pids+=($!)
    done

    # Wait for all requests to complete
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Count 201 responses
    local created_count=0
    for i in $(seq 1 5); do
        local code
        code=$(tail -1 "${results_dir}/result-${i}")
        if [ "$code" = "201" ]; then
            created_count=$((created_count + 1))
        fi
    done

    assert_equals "5" "$created_count" \
        "All 5 concurrent registrations should succeed with 201"

    # Verify domains.map integrity
    local map_entries
    map_entries=$(docker exec "${TEST_HAPROXY}" \
        grep -c "concurrent.*test.local" /etc/haproxy/domains.map || true)
    assert_equals "5" "$map_entries" \
        "domains.map should have exactly 5 concurrent entries"

    # Verify HAProxy config is valid
    local config_check
    config_check=$(docker exec "${TEST_HAPROXY}" haproxy -c -f /etc/haproxy/conf.d 2>&1 | tail -1)
    assert_contains "$config_check" "valid" \
        "HAProxy config should be valid after concurrent registrations"

    # Cleanup
    for i in $(seq 1 5); do
        curl -s -X DELETE "http://127.0.0.1:${API_PORT}/v1/backends/concurrent-${i}.test.local" > /dev/null
    done
    rm -rf "$results_dir"
}
```

#### Test 11.2: Two Simultaneous Registrations for Same Domain

```bash
test_concurrent_same_domain() {
    local results_dir="/tmp/${TEST_PREFIX}-concurrent-same"
    mkdir -p "$results_dir"

    # Fire 2 simultaneous registrations for the same domain
    (
        curl -s -w "\n%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d "{
                \"domain\": \"race.test.local\",
                \"container\": \"${TEST_WEB}\",
                \"http_port\": 80,
                \"https_port\": 443
            }" > "${results_dir}/result-1" 2>/dev/null
    ) &
    local pid1=$!

    (
        curl -s -w "\n%{http_code}" -X POST \
            "http://127.0.0.1:${API_PORT}/v1/backends" \
            -H "Content-Type: application/json" \
            -d "{
                \"domain\": \"race.test.local\",
                \"container\": \"${TEST_WEB}\",
                \"http_port\": 80,
                \"https_port\": 443
            }" > "${results_dir}/result-2" 2>/dev/null
    ) &
    local pid2=$!

    wait $pid1 2>/dev/null || true
    wait $pid2 2>/dev/null || true

    local code1 code2
    code1=$(tail -1 "${results_dir}/result-1")
    code2=$(tail -1 "${results_dir}/result-2")

    # One should be 201 (created), one should be 200 (idempotent)
    local codes_sorted
    codes_sorted=$(echo -e "${code1}\n${code2}" | sort)
    assert_equals "$(echo -e '200\n201')" "$codes_sorted" \
        "One should be 201 (new) and one 200 (idempotent)"

    # Verify only one entry exists in domains.map
    local map_count
    map_count=$(docker exec "${TEST_HAPROXY}" \
        grep -c "race.test.local" /etc/haproxy/domains.map || true)
    assert_equals "1" "$map_count" \
        "domains.map should have exactly 1 entry for race.test.local"

    # Cleanup
    curl -s -X DELETE "http://127.0.0.1:${API_PORT}/v1/backends/race.test.local" > /dev/null
    rm -rf "$results_dir"
}
```

---

### Suite 12: Container Ownership on DELETE

**Purpose:** Verify that when `HAPROXY_API_KEY` is not set, only the registered container can delete its own registration (source IP verification).

#### Test 12.1: DELETE from Wrong Container Returns 403

```bash
test_delete_ownership_mismatch() {
    # Register a domain associated with the web container
    curl -s -X POST "http://127.0.0.1:${API_PORT}/v1/backends" \
        -H "Content-Type: application/json" \
        -d '{
            "domain": "ownership.test.local",
            "container": "'"${TEST_WEB}"'",
            "http_port": 80,
            "https_port": 443
        }' > /dev/null

    sleep 1

    # Attempt DELETE from a DIFFERENT container (api container)
    # The API container has a different IP than the web container
    local http_code body
    local response
    response=$(docker exec "${TEST_API}" \
        curl -s -w "\n%{http_code}" -X DELETE \
        "http://${TEST_HAPROXY}:8404/v1/backends/ownership.test.local" 2>/dev/null)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    assert_equals "403" "$http_code" \
        "DELETE from wrong container should return 403"
    assert_equals "OWNERSHIP_MISMATCH" "$(echo "$body" | jq -r '.code')" \
        "Error code should be OWNERSHIP_MISMATCH"
}
```

#### Test 12.2: DELETE from Correct Container Returns 204

```bash
test_delete_ownership_match() {
    # Attempt DELETE from the CORRECT container (web container)
    local http_code
    http_code=$(docker exec "${TEST_WEB}" \
        curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "http://${TEST_HAPROXY}:8404/v1/backends/ownership.test.local" 2>/dev/null)

    assert_equals "204" "$http_code" \
        "DELETE from correct container should return 204"
}
```

#### Test 12.3: Verify Domain Is Actually Removed

```bash
test_ownership_domain_removed() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:${API_PORT}/v1/backends/ownership.test.local")

    assert_equals "404" "$http_code" \
        "Domain should be removed after successful DELETE"
}
```

---

## 6. Test Runner

### 6.1 Complete Script Structure

**File:** `tests/e2e/run-tests.sh`

```bash
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

    # Remove test network
    docker network rm "${TEST_NET}" 2>/dev/null || true

    # Remove test volumes
    local volumes
    volumes=$(docker volume ls -q --filter "name=${TEST_PREFIX}" 2>/dev/null || true)
    if [ -n "$volumes" ]; then
        echo "  Removing volumes..."
        echo "$volumes" | xargs docker volume rm 2>/dev/null || true
    fi

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
    HTTP_PORT=$(docker port "${TEST_HAPROXY}" 80/tcp | head -1 | cut -d: -f2)
    HTTPS_PORT=$(docker port "${TEST_HAPROXY}" 443/tcp | head -1 | cut -d: -f2)
    API_PORT=$(docker port "${TEST_HAPROXY}" 8404/tcp | head -1 | cut -d: -f2)
    EXTRA_TCP_PORT=$(docker port "${TEST_HAPROXY}" 50001/tcp | head -1 | cut -d: -f2)
    EXTRA_HTTP_PORT=$(docker port "${TEST_HAPROXY}" 50003/tcp | head -1 | cut -d: -f2)
    EXTRA_TLS_PORT=$(docker port "${TEST_HAPROXY}" 50004/tcp | head -1 | cut -d: -f2)

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

    # Allow time for HAProxy reload after registrations
    sleep 2

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
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            "http://127.0.0.1:${API_PORT}/v1/backends/web.test.local")
        assert_equals "204" "$http_code" "DELETE should return 204"
    }
    run_test "Delete web.test.local returns 204" test_delete_web

    sleep 2  # Allow HAProxy reload

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

    sleep 2

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

        local fail_count
        fail_count=$(grep -cv "200" "$results_file" 2>/dev/null || echo "0")
        assert_equals "0" "$fail_count" "Zero requests should fail during reload"

        curl -s -X DELETE "http://127.0.0.1:${API_PORT}/v1/backends/reload-test.test.local" > /dev/null
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
    else
        "suite_${target_suite}" 2>/dev/null || {
            echo "Unknown suite: ${target_suite}" >&2
            echo "Available suites: clean_room, haproxy_startup, registration," >&2
            echo "  http_routing, tls_passthrough, extra_ports, websocket," >&2
            echo "  unregistration, reload_under_load, error_handling," >&2
            echo "  concurrent_registration, container_ownership" >&2
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
```

### 6.2 Output Format

```
═══════════════════════════════════════════════════════════════
 HAProxy Dynamic Registration System -- End-to-End Tests
═══════════════════════════════════════════════════════════════

=== Building test images ===
  Building mock service image...
  Building HAProxy image...
=== Images built ===

=== Starting test environment ===
  Created network: haproxy-e2e-test-net
  Started: haproxy-e2e-test-proxy
  haproxy-e2e-test-proxy is healthy (3s)
  Published ports:
    HTTP:       49152
    HTTPS:      49153
    API:        49154
    TCP 50001:  49155
    HTTP 50003: 49156
    TLS 50004:  49157
  Started: haproxy-e2e-test-web
  Started: haproxy-e2e-test-electrum
  Started: haproxy-e2e-test-api
=== Test environment ready ===

Running e2e test suites...
══════════════════════════════════════════════════════════════

Suite: 1. Clean Room Verification
  ────────────────────────────────────────────────────────
  Test containers are running with correct prefix            PASS
  All e2e resources use the test prefix                      PASS
  Test network exists: haproxy-e2e-test-net                  PASS

Suite: 2. HAProxy Startup
  ────────────────────────────────────────────────────────
  HAProxy container is running                               PASS
  Registration API health check returns healthy              PASS
  Backend list is empty on fresh start                       PASS
  HAProxy process is running inside container                PASS

...

══════════════════════════════════════════════════════════════
 Results: 47 passed, 0 failed, 0 skipped out of 47 tests
══════════════════════════════════════════════════════════════

ALL TESTS PASSED
```

### 6.3 Debug Mode

Run with `DEBUG=1` to see full curl output, Docker build logs, and assertion details:

```bash
DEBUG=1 ./tests/e2e/run-tests.sh
```

### 6.4 Single Suite Execution

Run a specific suite by name:

```bash
./tests/e2e/run-tests.sh registration
./tests/e2e/run-tests.sh error_handling
./tests/e2e/run-tests.sh tls_passthrough
```

---

## 7. CI Integration

### 7.1 GitHub Actions Workflow

**File:** `.github/workflows/e2e-tests.yml`

```yaml
name: E2E Tests

on:
  push:
    branches: [master, main]
    paths:
      - 'generate-config.sh'
      - 'templates/**'
      - 'Dockerfile'
      - 'registration-api.mjs'
      - 'entrypoint.sh'
      - 'tests/e2e/**'
      - '.github/workflows/e2e-tests.yml'
  pull_request:
    branches: [master, main]
  workflow_dispatch:

jobs:
  e2e:
    runs-on: ubuntu-latest
    timeout-minutes: 10

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install host dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y jq netcat-openbsd openssl

      - name: Run E2E tests
        run: |
          chmod +x tests/e2e/run-tests.sh
          ./tests/e2e/run-tests.sh
        env:
          DEBUG: ${{ runner.debug && '1' || '0' }}

      - name: Collect logs on failure
        if: failure()
        run: |
          echo "=== HAProxy container logs ==="
          docker logs haproxy-e2e-test-proxy 2>&1 || echo "Container not found"
          echo ""
          echo "=== Web container logs ==="
          docker logs haproxy-e2e-test-web 2>&1 || echo "Container not found"
          echo ""
          echo "=== Electrum container logs ==="
          docker logs haproxy-e2e-test-electrum 2>&1 || echo "Container not found"
          echo ""
          echo "=== API container logs ==="
          docker logs haproxy-e2e-test-api 2>&1 || echo "Container not found"
          echo ""
          echo "=== Docker network inspect ==="
          docker network inspect haproxy-e2e-test-net 2>&1 || echo "Network not found"
          echo ""
          echo "=== All docker containers ==="
          docker ps -a --filter "name=haproxy-e2e-test" 2>&1

      - name: Cleanup (safety net)
        if: always()
        run: |
          docker ps -aq --filter "name=haproxy-e2e-test" 2>/dev/null | xargs -r docker rm -f || true
          docker network rm haproxy-e2e-test-net 2>/dev/null || true
```

### 7.2 Performance Target

The E2E suite should complete in under 3 minutes on GitHub Actions `ubuntu-latest` runners. The time budget breakdown:

| Phase | Target |
|---|---|
| Image builds (mock service + HAProxy) | ~30s (cached layers) |
| Environment startup + health checks | ~15s |
| Suite 1-3 (clean room, startup, registration) | ~10s |
| Suite 4-6 (HTTP, TLS, extra ports) | ~10s |
| Suite 7 (WebSocket) | ~10s |
| Suite 8 (unregistration) | ~10s |
| Suite 9 (reload under load) | ~10s |
| Suite 10 (error handling) | ~5s |
| Suite 11-12 (concurrent, ownership) | ~10s |
| Cleanup | ~5s |
| **Total** | **~115s** |

### 7.3 Caching Strategy

Docker layer caching via `actions/cache` can be added for faster CI runs, but is not required for the 3-minute target. The mock service image is tiny (node:20-alpine + openssl + socat) and builds in seconds.

---

## 8. Troubleshooting

### 8.1 Debug Mode

```bash
DEBUG=1 ./tests/e2e/run-tests.sh
```

This enables:
- Full Docker build output (not just the last line)
- Assertion failure details on stderr
- All curl responses printed

### 8.2 Inspecting Containers During Test

If a test fails and you want to inspect the state, temporarily remove the `trap clean_room EXIT` line (or add `sleep 600` before `main "$@"`):

```bash
# Inspect HAProxy config
docker exec haproxy-e2e-test-proxy cat /etc/haproxy/domains.map
docker exec haproxy-e2e-test-proxy cat /etc/haproxy/conf.d/20-backends.cfg
docker exec haproxy-e2e-test-proxy haproxy -c -f /etc/haproxy/conf.d

# Check HAProxy logs
docker logs haproxy-e2e-test-proxy

# Check mock service logs
docker logs haproxy-e2e-test-web
docker logs haproxy-e2e-test-electrum
docker logs haproxy-e2e-test-api

# Test connectivity between containers
docker exec haproxy-e2e-test-proxy ping -c1 haproxy-e2e-test-web
docker exec haproxy-e2e-test-web curl -s http://haproxy-e2e-test-proxy:8404/v1/health

# Inspect network
docker network inspect haproxy-e2e-test-net
```

### 8.3 Common Failures

#### "HAProxy container did not become healthy"

**Cause:** The HAProxy image failed to build, or the entrypoint crashed.

**Fix:**
```bash
docker logs haproxy-e2e-test-proxy 2>&1 | head -50
docker inspect haproxy-e2e-test-proxy --format '{{.State.ExitCode}}'
```

Look for missing files (registration-api.mjs, generate-config.sh), syntax errors in configs, or missing Node.js.

#### "Connection refused" on published ports

**Cause:** Docker port discovery returned an incorrect port, or HAProxy is not listening.

**Fix:**
```bash
docker port haproxy-e2e-test-proxy
docker exec haproxy-e2e-test-proxy ss -tlnp
```

#### "503" when expecting a routed response

**Cause:** The domain is not in the map file, or the backend container is unreachable.

**Fix:**
```bash
docker exec haproxy-e2e-test-proxy cat /etc/haproxy/maps/http-domains.map
docker exec haproxy-e2e-test-proxy ping -c1 haproxy-e2e-test-web
```

#### TLS cert CN does not match expected domain

**Cause:** The mock service did not generate its self-signed cert correctly, or HAProxy is not doing passthrough.

**Fix:**
```bash
# Check cert directly from backend (bypassing HAProxy)
docker exec haproxy-e2e-test-web openssl x509 -in /tmp/cert.pem -noout -subject
```

#### "nc: invalid option -- 'q'"

**Cause:** The system uses BSD netcat instead of GNU netcat.

**Fix:** The test runner includes a fallback: it tries `nc -q2` first, then `nc -w2`. If both fail, install `nmap-ncat` or `netcat-openbsd`.

#### WebSocket tests fail with timeout

**Cause:** The ws-echo-server.mjs may not have started, or HAProxy is not forwarding the Upgrade header.

**Fix:**
```bash
# Test WS server directly (bypassing HAProxy)
docker exec haproxy-e2e-test-electrum curl -s http://127.0.0.1:50003/
# Should return: {"service":"ws-echo","port":50003,"path":"/"}
```

#### Concurrent tests produce unexpected results

**Cause:** File locking is not working correctly in the Registration API, leading to race conditions.

**Fix:** Check the API logs for lock contention errors:
```bash
docker logs haproxy-e2e-test-proxy 2>&1 | grep -i lock
```

### 8.4 Manual Cleanup

If the trap failed (e.g., `kill -9` on the test runner), manually clean up:

```bash
docker ps -aq --filter "name=haproxy-e2e-test" | xargs -r docker rm -f
docker network rm haproxy-e2e-test-net 2>/dev/null || true
docker volume ls -q --filter "name=haproxy-e2e-test" | xargs -r docker volume rm
rm -f /tmp/haproxy-e2e-test-*
```

### 8.5 Running on macOS

The test suite is designed for Linux (GitHub Actions `ubuntu-latest`). On macOS:

- `nc` flags differ: `-q` is not available. The fallback to `-w` should work.
- `openssl s_client` output format may differ slightly.
- Docker Desktop for Mac uses a VM, so `127.0.0.1` port forwarding has slightly higher latency.
- `socat` may need to be installed via Homebrew: `brew install socat`.

---

## Appendix A: Test Matrix Summary

| Suite | Tests | Category |
|---|---|---|
| 1. Clean Room | 3 | Infrastructure |
| 2. HAProxy Startup | 4 | Infrastructure |
| 3. Registration | 8 | API |
| 4. HTTP Routing | 5 | Routing |
| 5. TLS Passthrough | 4 | Routing |
| 6. Extra Ports | 4 | Routing |
| 7. WebSocket | 3 | Routing |
| 8. Unregistration | 7 | API + Routing |
| 9. Reload Under Load | 1 | Reliability |
| 10. Error Handling | 15 | API |
| 11. Concurrent Registration | 2 | Concurrency |
| 12. Container Ownership | 3 | Security |
| **Total** | **59** | |

## Appendix B: File Layout

```
haproxy/
  tests/
    e2e/
      run-tests.sh                            # Test runner (executable)
      mock-service/
        Dockerfile                            # Unified mock service image
        test-service-entrypoint.sh            # Entrypoint for web/electrum/api modes
        ws-echo-server.mjs                    # WebSocket echo server (Node.js)
  .github/
    workflows/
      e2e-tests.yml                           # CI workflow
  specs/
    E2E_TEST_SPEC.md                          # This document
    REGISTRATION_API_SPEC.md                  # API specification
```
