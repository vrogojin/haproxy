# Dynamic Backend Registration API for HAProxy

**Version:** 1.0
**Date:** 2026-03-30
**Status:** Draft

---

## Table of Contents

1. [Overview](#1-overview)
2. [API Specification](#2-api-specification)
3. [Implementation Architecture](#3-implementation-architecture)
4. [Config Generation Flow](#4-config-generation-flow)
5. [HAProxy Reload Strategy](#5-haproxy-reload-strategy)
6. [Data Model](#6-data-model)
7. [Docker Integration](#7-docker-integration)
8. [Error Handling](#8-error-handling)
9. [Backward Compatibility](#9-backward-compatibility)
10. [Security Considerations](#10-security-considerations)

---

## 1. Overview

### 1.1 Problem

The current HAProxy routing configuration requires SSH access to the host machine to edit `domains.map`, run `generate-config.sh`, and restart the container. This creates operational friction: every backend container addition or removal is a manual, multi-step process that requires host-level access and coordination.

### 1.2 Goals

- Allow backend containers to register and unregister their domain routing via simple HTTP calls to the HAProxy container, with no SSH access to the host required.
- Preserve the existing `domains.map` + `generate-config.sh` workflow as the source of truth.
- Provide idempotent registration so containers can safely re-register on every startup.
- Achieve zero-downtime reconfiguration using HAProxy's graceful reload.
- Keep the solution simple: single container, minimal dependencies, no external databases.

### 1.3 Non-Goals

- TLS termination at the API layer. The API runs on an internal Docker network and does not need its own certificates.
- Mandatory authentication or authorization. The API is accessible only from `haproxy-net`, which is a trusted network. Optional bearer token auth is available via `HAPROXY_API_KEY` for multi-tenant environments (see Section 10.2).
- HAProxy Runtime API integration for live traffic management (stats, drain, etc.). This spec covers registration only.
- Replacing the existing `generate-config.sh` logic. The API wraps it, not replaces it.
- Multi-host or cluster-aware registration. This is single-host, single HAProxy instance.

---

## 2. API Specification

### 2.1 Base URL

```
http://haproxy:8404/v1
```

Port 8404 is the conventional HAProxy stats/admin port. It is bound only on the `haproxy-net` Docker network and is NOT published to the host.

### 2.2 Common Response Format

All responses use `Content-Type: application/json`. Error responses follow this schema:

```json
{
  "error": "Human-readable error message",
  "code": "MACHINE_READABLE_CODE"
}
```

Error codes:

| Code | Meaning |
|---|---|
| `VALIDATION_ERROR` | Request body fails validation |
| `DOMAIN_CONFLICT` | Domain is registered to a different container |
| `NOT_FOUND` | Requested domain registration does not exist |
| `RELOAD_FAILED` | HAProxy config generation or reload failed |
| `UNAUTHORIZED` | Missing or invalid API key (when `HAPROXY_API_KEY` is set) |
| `LIMIT_EXCEEDED` | Maximum registration count reached (`MAX_REGISTRATIONS`) |
| `OWNERSHIP_MISMATCH` | DELETE request source IP does not match registered container |
| `INTERNAL_ERROR` | Unexpected server error |

### 2.3 Endpoints

#### 2.3.1 Register a Backend

```
POST /v1/backends
```

**Request Body:**

```json
{
  "domain": "example.com",
  "container": "my-backend",
  "http_port": 80,
  "https_port": 443,
  "map_port": null
}
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `domain` | string | yes | - | Domain name to route. Must match `^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$`, max 253 characters total, max 63 characters per label (between dots), must contain at least one dot (single-label domains rejected). |
| `container` | string | yes | - | Container name or alias on `haproxy-net`. Must match `[a-zA-Z0-9][a-zA-Z0-9_.-]*`. |
| `http_port` | integer or null | no | `80` | HTTP port on the backend container. Set to `null` to skip HTTP routing. |
| `https_port` | integer or null | no | `443` | HTTPS port on the backend container. Set to `null` to skip HTTPS routing. |
| `map_port` | integer or null | no | `null` | Map download port (routed via HAProxy port 8000). Set to `null` to skip. |

Port values must be in range 1-65535 when specified.

At least one of `http_port` or `https_port` must be non-null.

**Response: 201 Created** (new registration)

```json
{
  "domain": "example.com",
  "container": "my-backend",
  "http_port": 80,
  "https_port": 443,
  "map_port": null,
  "created_at": "2026-03-30T14:22:00Z"
}
```

**Response: 200 OK** (idempotent, domain already registered to the same container with the same ports)

```json
{
  "domain": "example.com",
  "container": "my-backend",
  "http_port": 80,
  "https_port": 443,
  "map_port": null,
  "created_at": "2026-03-30T14:20:00Z",
  "message": "Already registered with identical configuration"
}
```

**Response: 409 Conflict** (domain registered to a different container or different ports)

```json
{
  "error": "Domain 'example.com' is already registered to container 'other-backend' (HTTP:80, HTTPS:443)",
  "code": "DOMAIN_CONFLICT",
  "existing": {
    "domain": "example.com",
    "container": "other-backend",
    "http_port": 80,
    "https_port": 443,
    "map_port": null
  }
}
```

**Response: 422 Unprocessable Entity** (validation failure)

```json
{
  "error": "Field 'domain' is required",
  "code": "VALIDATION_ERROR"
}
```

**Example:**

```bash
# Register a new backend
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{
    "domain": "myapp.example.com",
    "container": "myapp-web",
    "http_port": 8080,
    "https_port": 8443
  }'

# Register with only HTTPS (no HTTP routing)
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{
    "domain": "secure.example.com",
    "container": "secure-app",
    "http_port": null,
    "https_port": 443
  }'

# Register with map download port
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{
    "domain": "maps.example.com",
    "container": "map-server",
    "http_port": 80,
    "https_port": 443,
    "map_port": 9000
  }'

# Idempotent re-registration (returns 200, no config change)
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{
    "domain": "myapp.example.com",
    "container": "myapp-web",
    "http_port": 8080,
    "https_port": 8443
  }'
```

---

#### 2.3.2 List All Backends

```
GET /v1/backends
```

No request body. No query parameters.

**Response: 200 OK**

```json
{
  "backends": [
    {
      "domain": "friendly-miners.dyndns.org",
      "container": "friendly-dashboard",
      "http_port": 80,
      "https_port": 443,
      "map_port": null,
      "created_at": "2026-01-30T20:50:00Z"
    },
    {
      "domain": "busydaddyrust-dev.dyndns.org",
      "container": "lgsm",
      "http_port": 8888,
      "https_port": 8888,
      "map_port": 8000,
      "created_at": "2026-01-30T20:50:00Z"
    }
  ],
  "count": 2
}
```

**Example:**

```bash
curl -s http://haproxy:8404/v1/backends | python3 -m json.tool
```

---

#### 2.3.3 Get a Specific Backend

```
GET /v1/backends/{domain}
```

The `{domain}` path parameter is the domain name, URL-encoded if it contains special characters (though valid domain names generally do not need encoding).

**Response: 200 OK**

```json
{
  "domain": "friendly-miners.dyndns.org",
  "container": "friendly-dashboard",
  "http_port": 80,
  "https_port": 443,
  "map_port": null,
  "created_at": "2026-01-30T20:50:00Z"
}
```

**Response: 404 Not Found**

```json
{
  "error": "No registration found for domain 'unknown.example.com'",
  "code": "NOT_FOUND"
}
```

**Example:**

```bash
curl -s http://haproxy:8404/v1/backends/friendly-miners.dyndns.org
```

---

#### 2.3.4 Unregister a Backend

```
DELETE /v1/backends/{domain}
```

Removes the domain from `domains.map`, regenerates configuration, and triggers a graceful HAProxy reload.

**Response: 204 No Content** (successfully removed)

No response body.

**Response: 404 Not Found** (domain was not registered)

```json
{
  "error": "No registration found for domain 'unknown.example.com'",
  "code": "NOT_FOUND"
}
```

**Example:**

```bash
# Remove a backend
curl -s -X DELETE http://haproxy:8404/v1/backends/myapp.example.com

# Verify it was removed
curl -s http://haproxy:8404/v1/backends/myapp.example.com
# Returns 404
```

#### Container Ownership Verification (when HAPROXY_API_KEY is not set)

When the API runs without authentication, the DELETE endpoint verifies that the
requesting container matches the registered container by comparing the source IP
of the DELETE request against the registered container's Docker DNS resolution:

1. Look up the registered container name in the domain entry.
2. Resolve that container name via Docker DNS.
3. Compare against the source IP of the DELETE request.
4. If they match, allow the DELETE.
5. If they don't match, return 403 Forbidden:
   ```json
   {"error": "Only the registered container can delete this domain", "code": "OWNERSHIP_MISMATCH"}
   ```

When `HAPROXY_API_KEY` is set, this check is skipped (authenticated callers are
trusted to manage any domain).

---

#### 2.3.5 Force Reload

```
POST /v1/reload
```

Regenerates all HAProxy configuration from the current `domains.map` and triggers a graceful reload. Useful after manual edits to `domains.map` or templates.

No request body required.

**Response: 200 OK**

```json
{
  "message": "Configuration regenerated and HAProxy reloaded",
  "backends_count": 4,
  "reload_timestamp": "2026-03-30T14:30:00Z"
}
```

**Response: 500 Internal Server Error** (reload failed)

```json
{
  "error": "HAProxy configuration check failed: [error details]",
  "code": "RELOAD_FAILED"
}
```

**Example:**

```bash
# After manually editing domains.map
curl -s -X POST http://haproxy:8404/v1/reload
```

---

#### 2.3.6 Health Check

```
GET /v1/health
```

Returns the health status of the API and the HAProxy process.

**Response: 200 OK**

```json
{
  "status": "healthy",
  "haproxy_pid": 1,
  "haproxy_uptime_seconds": 86400,
  "api_version": "1.0",
  "backends_count": 4
}
```

**Response: 200 OK** (degraded — file lock held > 30 seconds)

```json
{
  "status": "degraded",
  "haproxy_pid": 1,
  "haproxy_uptime_seconds": 86400,
  "api_version": "1.0",
  "backends_count": 4,
  "warning": "File lock held for 35 seconds, possible stuck operation"
}
```

**Response: 503 Service Unavailable** (HAProxy process not running)

```json
{
  "status": "unhealthy",
  "error": "HAProxy master process not found",
  "api_version": "1.0"
}
```

**Example:**

```bash
curl -s http://haproxy:8404/v1/health
```

---

## 3. Implementation Architecture

### 3.1 Approach: Custom HAProxy Image with Embedded API

The API runs as a lightweight Python 3 HTTP server inside the same container as HAProxy. This is chosen over a sidecar container for simplicity: single container, no PID namespace sharing, no Docker socket mounting, straightforward signal delivery.

### 3.2 Image Layout

```
FROM haproxy:lts

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 procps && \
    rm -rf /var/lib/apt/lists/*

# Config generation
COPY generate-config.sh /usr/local/bin/generate-config.sh
COPY templates/ /usr/local/share/haproxy/templates/

# Registration API
COPY registration-api.py /usr/local/bin/registration-api.py

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/generate-config.sh \
             /usr/local/bin/registration-api.py

# Writable directories for dynamic config
RUN mkdir -p /etc/haproxy/conf.d \
             /etc/haproxy/maps \
             /etc/haproxy/state

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 3.3 File System Layout Inside Container

```
/etc/haproxy/
  domains.map                 # Source of truth (read-write, persisted via volume)
  conf.d/                     # Generated config fragments (read-write)
    00-global.cfg
    10-frontends.cfg
    15-frontend-mapdownload.cfg
    20-backends.cfg
  maps/                       # Generated map files (read-write)
    http-domains.map
    https-domains.map
    mapdownload-domains.map
  state/                      # API state (timestamps, lock files)
    registrations.json         # Metadata not captured in domains.map (created_at timestamps)

/usr/local/share/haproxy/
  templates/                  # Config templates (read-only, baked into image)
    00-global.cfg
    10-frontends.cfg
    15-frontend-mapdownload.cfg

/usr/local/bin/
  generate-config.sh          # Config generation script (baked into image)
  registration-api.py         # The API server (baked into image)
  entrypoint.sh               # Process manager (baked into image)
```

### 3.4 Process Management

The `entrypoint.sh` script manages two processes:

1. **HAProxy master process** (PID 1 via `exec` for the final process, or managed explicitly)
2. **Registration API** (Python HTTP server, background process)

Process management approach: the entrypoint starts the API server in the background, then `exec`s into HAProxy as PID 1. The API server is a child process. If HAProxy exits, the container stops. The API server is non-critical; if it crashes, HAProxy continues to serve traffic.

```bash
#!/bin/bash
set -e

DOMAINS_MAP="/etc/haproxy/domains.map"
CONF_DIR="/etc/haproxy/conf.d"
MAPS_DIR="/etc/haproxy/maps"
TEMPLATES_DIR="/usr/local/share/haproxy/templates"

# Create domains.map if it doesn't exist (first run)
if [ ! -f "$DOMAINS_MAP" ]; then
    cat > "$DOMAINS_MAP" << 'EOF'
# HAProxy Domain Mappings
# Format: domain  container  http_port  https_port  [map_port]
# Managed by Registration API. Manual edits are preserved.
EOF
fi

# Generate initial config from domains.map
export HAPROXY_CONF_DIR="$CONF_DIR"
export HAPROXY_MAPS_DIR="$MAPS_DIR"
export HAPROXY_TEMPLATES_DIR="$TEMPLATES_DIR"
export HAPROXY_DOMAINS_MAP="$DOMAINS_MAP"

/usr/local/bin/generate-config.sh

# Start Registration API with auto-restart and exponential backoff
STATE_DIR="/etc/haproxy/state"
(
    BACKOFF=2
    MAX_BACKOFF=60
    CONSECUTIVE_FAILURES=0
    while true; do
        START_TIME=$(date +%s)
        echo "Starting Registration API on port 8404..."
        python3 /usr/local/bin/registration-api.py \
            --port 8404 \
            --config-dir "$CONF_DIR" \
            --domains-map "$DOMAINS_MAP" \
            --templates-dir "$TEMPLATES_DIR" 2>&1
        EXIT_CODE=$?
        ELAPSED=$(( $(date +%s) - START_TIME ))

        # If the API ran for more than 60 seconds, it was healthy — reset backoff
        if [ $ELAPSED -ge 60 ]; then
            CONSECUTIVE_FAILURES=0
            BACKOFF=2
        else
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        fi

        if [ $CONSECUTIVE_FAILURES -ge 10 ]; then
            echo "ERROR: Registration API crashed 10 times consecutively. Stopping restart loop." >&2
            break
        fi

        echo "Registration API exited (code $EXIT_CODE), restarting in ${BACKOFF}s... (failure $CONSECUTIVE_FAILURES/10)" >&2
        sleep $BACKOFF
        BACKOFF=$((BACKOFF * 2))
        [ $BACKOFF -gt $MAX_BACKOFF ] && BACKOFF=$MAX_BACKOFF
    done
) &
API_LOOP_PID=$!
echo "Registration API restart loop started (PID: $API_LOOP_PID)"

# Trap SIGTERM to clean up API restart loop and its children
trap "kill $API_LOOP_PID 2>/dev/null; wait $API_LOOP_PID 2>/dev/null" TERM INT

# Start HAProxy as PID 1 (master-worker mode for graceful reload)
exec haproxy -W -f "$CONF_DIR" -S /var/run/haproxy-master.sock
```

Key detail: HAProxy is started with `-W` (master-worker mode), which enables graceful reload via `SIGUSR2` to the master process. The master process spawns worker processes and can reload them without dropping connections. The `-S` flag creates a master CLI socket for programmatic control.

### 3.5 Registration API Implementation

The API is implemented as a single Python 3 file using only standard library modules (`http.server`, `json`, `subprocess`, `os`, `signal`, `re`, `datetime`, `threading`, `fcntl`). No pip dependencies.

Key implementation details:

- **Threading**: Uses `ThreadingHTTPServer` for concurrent request handling.
- **File locking**: Uses `fcntl.flock()` with `LOCK_NB` and a 60-second polling deadline on `domains.map` to serialize concurrent writes (see Section 8.3).
- **Config regeneration**: Shells out to `generate-config.sh` after modifying `domains.map` (`subprocess.run` with `timeout=30`).
- **HAProxy reload**: Sends `SIGUSR2` to the HAProxy master process after config regeneration.
- **Reload confirmation**: After `SIGUSR2`, polls for new HAProxy worker PIDs to verify the reload succeeded (10-second timeout; see Section 5.7).
- **Config validation**: Runs `haproxy -c -f /etc/haproxy/conf.d` before reloading (`subprocess.run` with `timeout=30`) to catch config errors before they affect the running instance.
- **Authentication**: Optional bearer token auth via `HAPROXY_API_KEY` environment variable (see Section 10.2).
- **Rate limiting**: `MAX_REGISTRATIONS` env var (default: 100) caps total registered backends (see Section 10.5).
- **Reload debouncing**: Coalesces rapid registrations within a 2-second window into a single reload cycle (see Section 10.5).

### 3.6 Registration API Pseudocode

```python
class RegistrationHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        if self.path == "/v1/backends":
            self.handle_register()
        elif self.path == "/v1/reload":
            self.handle_reload()
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path == "/v1/backends":
            self.handle_list()
        elif self.path.startswith("/v1/backends/"):
            domain = self.path[len("/v1/backends/"):]
            self.handle_get(domain)
        elif self.path == "/v1/health":
            self.handle_health()
        else:
            self.send_error(404)

    def do_DELETE(self):
        if self.path.startswith("/v1/backends/"):
            domain = self.path[len("/v1/backends/"):]
            self.handle_delete(domain)
        else:
            self.send_error(404)

    def handle_register(self):
        body = json.loads(self.rfile.read(content_length))
        # Check HAPROXY_API_KEY auth if configured
        # Validate fields
        # Check MAX_REGISTRATIONS limit
        # Acquire file lock on domains.map (LOCK_NB with 60s polling deadline)
        # Parse existing entries
        # Check for conflicts (same domain, different container/ports -> 409)
        # Check for idempotent match (same domain, same everything -> 200)
        # Append new entry -> 201
        # Schedule debounced reload (2s timer; see Section 10.5)
        # Run generate-config.sh (subprocess timeout=30)
        # Validate config with haproxy -c (subprocess timeout=30)
        # Send SIGUSR2 to HAProxy master
        # Verify reload succeeded (poll for new worker PIDs, 10s timeout; see Section 5.7)
        # Release file lock

    def handle_delete(self, domain):
        # Acquire file lock on domains.map
        # Read all lines, filter out the matching domain
        # Write back filtered lines
        # Run generate-config.sh
        # Validate and reload
        # Release file lock

    def handle_reload(self):
        # Run generate-config.sh
        # Validate config with haproxy -c
        # Send SIGUSR2 to HAProxy master

    def handle_list(self):
        # Parse domains.map, return all entries as JSON

    def handle_get(self, domain):
        # Parse domains.map, find matching domain, return as JSON or 404

    def handle_health(self):
        # Check HAProxy master process is alive
        # Return status
```

---

## 4. Config Generation Flow

### 4.1 Sequence of Operations

When a `POST /v1/backends` or `DELETE /v1/backends/{domain}` request arrives:

```
1. Acquire exclusive file lock on domains.map (fcntl.flock LOCK_NB with 60s polling deadline; see Section 8.3)
2. Read current domains.map content
3. Parse all non-comment, non-empty lines into structured entries
4. Apply the change:
   - POST: validate no conflict, append new line (or return 200/409)
   - DELETE: remove matching line (or return 404)
5. Write updated domains.map atomically (write to temp file, rename)
6. Run generate-config.sh (subprocess.run with timeout=30):
   - Copies templates to conf.d/
   - Generates conf.d/20-backends.cfg from domains.map
   - Generates maps/*.map from domains.map
7. Validate generated config: haproxy -c -f /etc/haproxy/conf.d (subprocess.run with timeout=30)
8. If validation fails: roll back domains.map from backup, return 500
9. If validation succeeds: record current HAProxy worker PIDs, send SIGUSR2 to HAProxy master process
10. Verify reload succeeded: poll for new worker PIDs (200ms interval, 10s timeout; see Section 5.7)
11. If reload not confirmed within timeout: return 500 with RELOAD_FAILED
12. Update state/registrations.json with metadata (created_at timestamps)
13. Release file lock
14. Return success response
```

### 4.2 Atomicity

The file lock ensures that concurrent API requests are serialized. The `domains.map` write is atomic via write-to-temp-then-rename. If the process crashes between writing `domains.map` and regenerating config, the next startup (or next API call to `/v1/reload`) will reconcile.

### 4.3 Config Generation Script Modifications

The existing `generate-config.sh` must be adapted to work inside the container. Changes:

1. Accept directory paths via environment variables instead of hardcoded relative paths:
   - `HAPROXY_CONF_DIR` (default: `./conf.d`)
   - `HAPROXY_MAPS_DIR` (default: `./maps`)
   - `HAPROXY_TEMPLATES_DIR` (default: `./templates`)
   - `HAPROXY_DOMAINS_MAP` (default: `./domains.map`)

2. Use `cd "$(dirname "$0")"` only as fallback when env vars are not set.

3. The script's output (stdout) is captured by the API for logging. The exit code determines success/failure.

The script's core logic (parsing `domains.map`, generating backends and map files) remains identical. The current `generate-config.sh` is already well-structured for this adaptation -- it just needs the hardcoded paths parameterized.

### 4.4 Map File Paths

The templates reference map files at `/usr/local/etc/haproxy/maps/`. Inside the custom image, the generated maps live at `/etc/haproxy/maps/`. The templates must be updated to reference the new paths, OR a symlink can be created:

```bash
ln -sf /etc/haproxy/maps /usr/local/etc/haproxy/maps
ln -sf /etc/haproxy/conf.d /usr/local/etc/haproxy/conf.d
```

The symlink approach is preferred because it avoids forking the templates. The generate-config.sh copies the templates verbatim, and the symlinks ensure the paths resolve correctly.

---

## 5. HAProxy Reload Strategy

### 5.1 Master-Worker Mode

HAProxy is started in master-worker mode (`-W` flag). In this mode:

- The **master process** manages worker lifecycle and handles signals.
- **Worker processes** handle actual traffic.
- On `SIGUSR2`, the master spawns new workers with the new configuration while old workers gracefully drain connections.
- Old workers exit after all connections close (or after a configurable hard-stop timeout).

This provides seamless reload with zero dropped connections.

### 5.2 Reload Signal Flow

```
API receives POST /v1/backends
  -> writes domains.map
  -> schedules debounced reload (2s timer, reset on subsequent writes)
  -> [timer fires]
  -> runs generate-config.sh (generates conf.d/ and maps/, timeout=30s)
  -> runs haproxy -c -f /etc/haproxy/conf.d (validation, timeout=30s)
  -> records current worker PIDs
  -> os.kill(haproxy_master_pid, signal.SIGUSR2)
  -> polls for new worker PIDs (200ms interval, 10s timeout)
  -> confirms reload succeeded (new workers spawned)
  -> returns 201 to client
  -> old workers drain and exit in background
```

### 5.3 Finding the HAProxy Master PID

The API discovers the HAProxy master PID by:

1. Reading `/var/run/haproxy-master.sock` is available (created by `-S` flag), but for signal delivery we need the PID.
2. Parsing `pidof haproxy` or reading `/proc` to find the master process (PPID == 1 or PPID == entrypoint PID).
3. Alternatively, HAProxy can write a PID file: add `pidfile /var/run/haproxy.pid` to the global section, though in master-worker mode the master PID is the one written.

The most reliable approach: the entrypoint script writes the HAProxy master PID to a known file (it knows the PID because `exec` replaces the shell, but in that case we cannot write after exec). Instead, use the master CLI socket:

```bash
echo "show proc" | socat stdio /var/run/haproxy-master.sock
```

Or simply: since HAProxy in master-worker mode with `-W` writes its PID, use `pgrep -x haproxy` to find the master (it is the one whose PPID is 1 or whose command line contains `-W`).

Recommended approach for the API:

```python
def get_haproxy_master_pid():
    """Find HAProxy master PID by looking for the process with PPID 1."""
    for pid_dir in Path("/proc").iterdir():
        if not pid_dir.name.isdigit():
            continue
        try:
            status = (pid_dir / "status").read_text()
            if "haproxy" in (pid_dir / "comm").read_text():
                for line in status.splitlines():
                    if line.startswith("PPid:"):
                        ppid = int(line.split()[1])
                        if ppid == 0 or ppid == 1:
                            return int(pid_dir.name)
        except (FileNotFoundError, PermissionError):
            continue
    return None
```

### 5.4 Master CLI Socket (Optional Enhancement)

Adding `-S /var/run/haproxy-master.sock` to the HAProxy command enables the master CLI socket. This provides an alternative reload mechanism:

```bash
echo "reload" | socat stdio /var/run/haproxy-master.sock
```

This is equivalent to `SIGUSR2` but allows the API to receive a response confirming the reload was accepted.

### 5.5 Stats Socket for Runtime Map Updates (Future Enhancement)

For a future optimization, a stats socket can enable map file updates without any reload:

Add to `00-global.cfg`:
```
stats socket /var/run/haproxy.sock mode 660 level admin
```

This enables commands like:
```bash
echo "add map /etc/haproxy/maps/http-domains.map example.com bk_http_mycontainer" | \
  socat stdio /var/run/haproxy.sock
```

However, runtime map changes are volatile (lost on restart or reload). The full persist-and-reload approach described in this spec is required for durability. A future optimization could do both: update the runtime map for immediate effect AND persist to `domains.map` for durability, avoiding reload for simple additions. This is out of scope for v1.0.

### 5.6 Hard-Stop Timeout

To prevent old workers from lingering indefinitely during reload, add to the global section:

```
hard-stop-after 30s
```

This forces old workers to terminate after 30 seconds even if connections are still open. For the current setup (5s connect, 30s client/server timeouts), 30 seconds is sufficient for all connections to drain naturally.

### 5.7 Reload Confirmation

After sending `SIGUSR2` to the HAProxy master process, the API must verify that the reload succeeded before returning a success response to the client. This prevents a race condition where a client (e.g., `ssl-setup`) receives `201 Created` but HAProxy has not actually loaded the new configuration yet.

The verification method:

1. Before sending `SIGUSR2`, record the current set of HAProxy worker PIDs (by scanning `/proc` for `haproxy` processes whose PPID is the master PID).
2. Send `SIGUSR2` to the master process.
3. Poll (every 200ms) for new worker PIDs to appear. A reload is confirmed when at least one new worker PID exists that was not in the pre-reload set.
4. If no new worker PIDs appear within `reload_timeout` (default: 10 seconds), the reload is considered failed. The API returns `500 Internal Server Error` with `RELOAD_FAILED` code.

Alternatively, if the master CLI socket (`/var/run/haproxy-master.sock`) is available, the API can issue `show proc` and verify that worker processes have been refreshed.

The `reload_timeout` of 10 seconds is generous; in practice, HAProxy reloads complete in under 1 second.

---

## 6. Data Model

### 6.1 domains.map Format

The file format is unchanged from the current implementation:

```
# HAProxy Domain Mappings
# Format: domain  container  http_port  https_port  [map_port]
#
# Fields:
#   domain     - The domain name to route
#   container  - Container alias on haproxy-net
#   http_port  - HTTP port (or - to skip)
#   https_port - HTTPS port (or - to skip)
#   map_port   - Optional: Map download port (port 8000)

friendly-miners.dyndns.org      friendly-dashboard    80    443
dev-aggregator.dyndns.org       dev-aggregator        80    443
busydaddyrust-dev.dyndns.org    lgsm                  8888  8888  8000
```

Rules:
- Lines starting with `#` are comments and are preserved by the API.
- Empty lines are preserved.
- Fields are whitespace-separated.
- `http_port` or `https_port` set to `-` means skip that protocol.
- `map_port` is optional. Omitted means no map download routing.
- The domain field is the primary key (one entry per domain).

### 6.2 API-to-File Field Mapping

| API JSON field | domains.map column | Null handling |
|---|---|---|
| `domain` | Column 1 | Required, never null |
| `container` | Column 2 | Required, never null |
| `http_port` | Column 3 | `null` in JSON becomes `-` in file |
| `https_port` | Column 4 | `null` in JSON becomes `-` in file |
| `map_port` | Column 5 | `null` in JSON means column is omitted |

### 6.3 State File: registrations.json

Since `domains.map` does not capture metadata like `created_at` timestamps, the API maintains a supplementary state file at `/etc/haproxy/state/registrations.json`:

```json
{
  "friendly-miners.dyndns.org": {
    "created_at": "2026-01-30T20:50:00Z",
    "registered_by": "manual"
  },
  "myapp.example.com": {
    "created_at": "2026-03-30T14:22:00Z",
    "registered_by": "api"
  }
}
```

This file is advisory only. The `domains.map` file is always the source of truth for routing. If `registrations.json` is deleted, the API continues to function; `created_at` timestamps will be reported as `null` for entries that predate the state file, and new timestamps will be recorded going forward.

Entries in `registrations.json` that do not have a corresponding `domains.map` entry are ignored (stale metadata is harmless and cleaned up lazily).

### 6.4 Persistence

The `domains.map`, `conf.d/`, `maps/`, and `state/` directories are persisted via Docker volumes. On container restart, the entrypoint reads the existing `domains.map` and regenerates config before starting HAProxy, ensuring consistency.

---

## 7. Docker Integration

### 7.1 Updated docker-compose.yml

```yaml
services:
  haproxy:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: haproxy
    # HAProxy uses `unless-stopped` because it is core routing infrastructure
    # that must be available at all times. This differs from application
    # containers like Fulcrum which use `on-failure:5` to detect persistent
    # configuration errors.
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8000:8000"
      # Port 8404 is NOT published — API is internal only
    volumes:
      - haproxy-data:/etc/haproxy
    networks:
      - haproxy-net

volumes:
  haproxy-data:

networks:
  haproxy-net:
    external: true
```

### 7.2 Key Changes from Current Setup

| Aspect | Current | New |
|---|---|---|
| Image | `haproxy:lts` (stock) | Custom image built from `haproxy:lts` |
| Config source | Host-mounted `./conf.d:ro` and `./maps:ro` | Named volume `haproxy-data` (read-write) |
| domains.map | Host file, manually edited | Inside named volume, managed by API |
| Config generation | Run on host before restart | Run inside container by API |
| Reload | `docker restart haproxy` | `SIGUSR2` to HAProxy master (no downtime) |
| Port 8404 | Not used | Registration API (internal only) |
| HAProxy mode | Default (single process) | Master-worker (`-W` flag) |

### 7.3 Dockerfile

```dockerfile
FROM haproxy:lts

# Install Python 3 (for the API) and procps (for process management)
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 procps && \
    rm -rf /var/lib/apt/lists/*

# Copy config generation tools
COPY generate-config.sh /usr/local/bin/generate-config.sh
COPY templates/ /usr/local/share/haproxy/templates/

# Copy the registration API
COPY registration-api.py /usr/local/bin/registration-api.py

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Set permissions
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/generate-config.sh

# Create writable directories
RUN mkdir -p /etc/haproxy/conf.d \
             /etc/haproxy/maps \
             /etc/haproxy/state

# Create symlinks so templates' map paths resolve correctly
RUN ln -sf /etc/haproxy/maps /usr/local/etc/haproxy/maps && \
    ln -sf /etc/haproxy/conf.d /usr/local/etc/haproxy/conf.d

EXPOSE 80 443 8000 8404

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 7.4 Volume Strategy

A single named volume `haproxy-data` is mounted at `/etc/haproxy`. It contains:

- `domains.map` (persisted across container recreations)
- `conf.d/` (regenerated on every startup from `domains.map`)
- `maps/` (regenerated on every startup from `domains.map`)
- `state/` (API metadata, persisted)

On first run, the volume is empty. The entrypoint creates `domains.map` with a comment header and generates empty config. Backend containers can then register via the API.

### 7.5 Seed Data Migration

For migrating from the current setup, copy the existing `domains.map` into the volume before first start:

```bash
# One-time migration from current host-based setup
docker volume create haproxy-data
docker run --rm -v haproxy-data:/data -v $(pwd):/src alpine \
  cp /src/domains.map /data/domains.map

# Then start with the new compose file
docker compose up -d
```

Alternatively, bind-mount the existing `domains.map` as a seed:

```yaml
volumes:
  - haproxy-data:/etc/haproxy
  - ./domains.map:/etc/haproxy/domains.map.seed:ro
```

And have the entrypoint copy the seed to `domains.map` only if `domains.map` does not already exist.

### 7.6 Network Configuration

Port 8404 is exposed in the Dockerfile (`EXPOSE 8404`) but NOT published in `docker-compose.yml` (`ports` does not include `8404`). This means:

- Containers on `haproxy-net` can reach `http://haproxy:8404/v1/...`
- The host machine and external networks cannot reach the API
- No firewall rules needed

### 7.7 Backend Container Integration Example

A backend container can self-register on startup:

```yaml
# docker-compose.yml for a backend service
services:
  myapp:
    image: myapp:latest
    container_name: myapp-web
    networks:
      - haproxy-net
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        # Register with HAProxy
        for i in 1 2 3 4 5; do
          curl -sf -X POST http://haproxy:8404/v1/backends \
            -H "Content-Type: application/json" \
            -d '{"domain":"myapp.example.com","container":"myapp-web","http_port":8080,"https_port":8443}' \
            && break
          echo "HAProxy not ready, retrying in 5s..."
          sleep 5
        done

        # Start the actual application
        exec /app/start.sh

networks:
  haproxy-net:
    external: true
```

The retry loop handles the case where the backend container starts before HAProxy is ready.

### 7.8 Deregistration on Shutdown

Containers can deregister on shutdown using a pre-stop hook or trap:

```bash
# In the backend container's entrypoint
cleanup() {
  curl -sf -X DELETE http://haproxy:8404/v1/backends/myapp.example.com || true
}
trap cleanup TERM INT

# Start application
exec /app/start.sh
```

Deregistration is optional. If a backend container disappears without deregistering, HAProxy will route traffic to a non-responsive backend. The existing `init-addr last,libc,none` and health check configuration (`check inter 5s fall 3 rise 2` on HTTPS backends) will detect the failure and stop sending traffic. The stale registration remains in `domains.map` until manually removed or removed via API.

---

## 8. Error Handling

### 8.1 Config Validation Failure

If `haproxy -c -f /etc/haproxy/conf.d` fails after config regeneration:

1. The API does NOT send `SIGUSR2` to HAProxy. The running instance continues with the previous valid config.
2. The API rolls back `domains.map` to the pre-change backup (kept in memory during the locked operation).
3. The API re-runs `generate-config.sh` with the rolled-back `domains.map` to restore the config files to a valid state.
4. The API returns HTTP 500 with the `RELOAD_FAILED` error code and includes the `haproxy -c` stderr output in the response.

This ensures that a bad registration can never break a running HAProxy instance.

### 8.2 Container DNS Resolution Failure

When a registered container is not running or not connected to `haproxy-net`, Docker DNS resolution fails. HAProxy handles this gracefully because:

- `init-addr last,libc,none` is set on every server line. The `none` fallback means HAProxy starts even if DNS resolution fails at startup.
- For HTTPS backends, `check inter 5s fall 3 rise 2` detects unresponsive backends.
- For HTTP backends, HAProxy will return a 503 to clients if the backend is unreachable.

The Registration API does NOT validate that a container exists or is reachable during registration. This is by design: containers may register before starting, or may restart independently of HAProxy.

### 8.3 Concurrent API Requests

File locking (`fcntl.flock`) ensures that concurrent `POST` and `DELETE` requests are serialized. The lock is acquired with a non-blocking polling loop and a 60-second deadline to prevent unbounded waits:

```python
deadline = time.time() + 60
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.time() > deadline:
            raise TimeoutError("Lock held too long")
        time.sleep(0.5)
```

The lock acquisition timestamp is tracked. The health check endpoint (Section 2.3.6) reports `"status": "degraded"` if the lock has been held for more than 30 seconds, indicating a potential stuck operation.

Subprocess calls within the critical section are also bounded:

- `generate-config.sh` is called with `subprocess.run(..., timeout=30)`.
- `haproxy -c` (config validation) is called with `subprocess.run(..., timeout=30)`.

If the API process crashes while holding the lock, the OS releases the lock automatically (file locks in Linux are process-scoped).

### 8.4 API Process Crash

If the Python API process crashes:

- HAProxy continues to serve traffic with the last valid configuration.
- The entrypoint's restart loop automatically restarts the API process with exponential backoff (starting at 2 seconds, doubling up to 60 seconds; see Section 3.4). If the API ran for more than 60 seconds before crashing, the backoff and failure counter reset (the crash is considered transient). After 10 consecutive failures (each lasting less than 60 seconds), the restart loop stops to avoid masking a persistent error. The restart loop PID (`API_LOOP_PID`) is tracked and cleaned up via the entrypoint's trap handler on container shutdown.
- The `/v1/health` endpoint becomes temporarily unreachable during the backoff window.
- No manual intervention is required for transient failures. The API will self-heal. For persistent failures (10 consecutive crashes), operator intervention is needed; inspect logs and restart the container.

### 8.5 HAProxy Master Process Crash

If the HAProxy master process crashes or exits:

- The container exits (HAProxy master is PID 1 via `exec`).
- Docker's `restart: unless-stopped` policy restarts the container.
- The entrypoint regenerates config from the persisted `domains.map` and starts fresh.
- All registrations are preserved (they live in the volume).

### 8.6 Corrupt domains.map

If `domains.map` is manually edited into an unparseable state:

- The API's `GET /v1/backends` will return whatever it can parse, skipping invalid lines.
- The API's `POST /v1/backends` will preserve all lines (including invalid ones) and append the new entry.
- `POST /v1/reload` will attempt to regenerate config; if `generate-config.sh` emits warnings for invalid lines but still produces valid HAProxy config, the reload will succeed.

### 8.7 Volume Loss

If the `haproxy-data` volume is destroyed:

- The container starts with an empty `domains.map`.
- No backends are routed until they re-register.
- If backend containers are configured to self-register on startup (per Section 7.7), restarting them will restore all registrations.

---

## 9. Backward Compatibility

### 9.1 Manual Workflow Continues to Work

The `domains.map` file format is unchanged. A human with shell access to the host (or `docker exec` access to the container) can:

1. Edit `domains.map` directly: `docker exec -it haproxy vi /etc/haproxy/domains.map`
2. Trigger a reload via the API: `docker exec haproxy curl -s -X POST http://localhost:8404/v1/reload`
3. Or trigger a reload via signal: `docker kill -s USR2 haproxy`

The API and manual editing coexist because both operate on the same `domains.map` file. The file lock prevents concurrent modification.

### 9.2 generate-config.sh Remains Usable on the Host

The original `generate-config.sh` remains in the repository and can still be used on the host for:

- Local testing without Docker
- Generating config previews
- Validating `domains.map` syntax

### 9.3 Migration Path

The migration from the current setup to the API-based setup is:

1. Build the custom image (`docker compose build`)
2. Seed the volume with the existing `domains.map` (per Section 7.5)
3. `docker compose up -d`
4. Verify with `curl http://haproxy:8404/v1/backends` (from a container on `haproxy-net`)

No changes to backend containers are required. They continue to work as before. The API is an additive capability.

### 9.4 Rollback

To revert to the stock HAProxy image:

1. Export the current registrations: `docker exec haproxy cat /etc/haproxy/domains.map > domains.map`
2. Switch `docker-compose.yml` back to `image: haproxy:lts` with read-only volume mounts
3. Run `./generate-config.sh` on the host
4. `docker compose up -d`

---

## 10. Security Considerations

### 10.1 Network Isolation

The API listens on port 8404, which is NOT published to the host in `docker-compose.yml`. Only containers attached to `haproxy-net` can reach it. This is the primary security boundary.

If port 8404 were accidentally published, any process on the host or network could register arbitrary domains. Ensure the `ports` section of `docker-compose.yml` never includes `8404`.

### 10.2 Optional API Key Authentication

The API supports optional bearer token authentication via the `HAPROXY_API_KEY` environment variable.

**When `HAPROXY_API_KEY` is not set:** The API works without authentication (default). This is appropriate for trusted, operator-controlled Docker networks where only explicitly connected containers can reach the API.

**When `HAPROXY_API_KEY` is set:** All API requests must include an `Authorization: Bearer <key>` header. Requests without a valid authorization header receive `401 Unauthorized`:

```json
{
  "error": "Missing or invalid Authorization header",
  "code": "UNAUTHORIZED"
}
```

The health check endpoint (`GET /v1/health`) is exempt from authentication to allow unauthenticated monitoring.

This is optional but strongly recommended for multi-tenant environments where multiple teams share the same Docker network and could otherwise register arbitrary domains.

### 10.3 Input Validation

All inputs are validated before being written to `domains.map`:

| Field | Validation | Rationale |
|---|---|---|
| `domain` | Must match `^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$`, max 253 chars, labels max 63 chars, must contain at least one dot (single-label domains rejected) | Prevents shell injection via domain names in generated config |
| `container` | Must match `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`, max 128 chars | Prevents injection in HAProxy server lines |
| `http_port` | Integer 1-65535 or null | Port range validation |
| `https_port` | Integer 1-65535 or null | Port range validation |
| `map_port` | Integer 1-65535 or null | Port range validation |

The domain and container validation patterns are restrictive by design. They reject any characters that could be interpreted by the shell (`$`, `` ` ``, `\`, `;`, `|`, `&`, spaces, newlines) or by HAProxy configuration parsing.

### 10.4 Shell Injection Prevention

`generate-config.sh` reads `domains.map` via `read -r` and substitutes values into HAProxy config using heredocs. The input validation in Section 10.3 ensures that no shell-special characters can appear in the fields. Additionally:

- The API writes `domains.map` using Python's file I/O, not shell commands.
- `generate-config.sh` is invoked via `subprocess.run()` with no shell interpolation of user inputs.

### 10.5 Denial of Service

An attacker on `haproxy-net` could:

- **Register thousands of domains**, bloating `domains.map` and HAProxy config. Mitigation: the `MAX_REGISTRATIONS` environment variable (default: `100`) caps the total number of registered backends. When the limit is reached, `POST /v1/backends` returns `429 Too Many Requests`:

  ```json
  {
    "error": "Maximum registration limit (100) reached",
    "code": "LIMIT_EXCEEDED"
  }
  ```

- **Send rapid registration/deletion requests**, causing frequent HAProxy reloads. Mitigation: reload debouncing. After a registration or deletion modifies `domains.map`, the API sets a 2-second debounce timer instead of immediately running `generate-config.sh` and reloading. If another registration arrives within that window, the timer resets. Only when the timer fires (2 seconds of quiet) does the API trigger config generation and reload. This coalesces bursts of registrations into a single reload cycle.

  The debounce mechanism works as follows:
  1. Request arrives, acquires file lock on `domains.map`.
  2. Write changes to `domains.map`.
  3. Release file lock (so other requests are not blocked during the debounce window).
  4. Start/reset a 2-second debounce timer via `threading.Timer(2.0, do_reload)`.
  5. If a subsequent write arrives before the timer fires, the pending timer is cancelled and a new 2-second timer is started.
  6. When the timer fires, re-acquire the file lock, run `generate-config.sh`, validate config with `haproxy -c`, send `SIGUSR2` to HAProxy, then release the lock.
  7. The API tracks the pending reload state so that `POST` requests that triggered a debounced reload can block until the reload completes (see Section 5.7).

  Between steps 3 and 6, `domains.map` may be modified by other requests. This is
  correct: the debounce timer ensures all pending changes are included in the
  single reload at step 6. The `generate-config.sh` at step 6 reads the final
  state of `domains.map`, which includes all changes from all requests in the
  debounce window.

  If a request arrives during step 6 (lock held for regeneration), it waits for
  the lock, writes its change, and starts a new debounce timer.

- **Register domains that shadow legitimate services**. Mitigation: domain ownership is not verified (same as the current manual workflow). The operator must trust containers on `haproxy-net`. Use `HAPROXY_API_KEY` (Section 10.2) for additional protection.

### 10.6 Trust Model Summary

```
Internet
   |
   v
[Host ports 80/443/8000]
   |
   v
[HAProxy container]
   |  ^
   |  | Port 8404 (internal only)
   |  |
   v  |
[haproxy-net Docker network]  <-- trust boundary
   |
   v
[Backend containers]
```

The trust boundary is the `haproxy-net` network. Everything inside it is trusted. The API has no internet exposure.

---

## Appendix A: Complete curl Reference

```bash
# === Registration ===

# Register a backend (basic)
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{"domain":"app.example.com","container":"my-app","http_port":80,"https_port":443}'

# Register with custom ports
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{"domain":"app.example.com","container":"my-app","http_port":8080,"https_port":8443}'

# Register HTTPS-only (no HTTP routing)
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{"domain":"secure.example.com","container":"secure-app","http_port":null,"https_port":443}'

# Register HTTP-only (no HTTPS routing)
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{"domain":"internal.example.com","container":"internal-app","http_port":80,"https_port":null}'

# Register with map download port
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{"domain":"maps.example.com","container":"map-server","http_port":80,"https_port":443,"map_port":9000}'

# Register with defaults (http_port=80, https_port=443)
curl -s -X POST http://haproxy:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{"domain":"simple.example.com","container":"simple-app"}'

# === Queries ===

# List all backends
curl -s http://haproxy:8404/v1/backends

# List all backends (pretty-printed)
curl -s http://haproxy:8404/v1/backends | python3 -m json.tool

# Get a specific backend
curl -s http://haproxy:8404/v1/backends/app.example.com

# === Deletion ===

# Remove a backend
curl -s -X DELETE http://haproxy:8404/v1/backends/app.example.com
# Returns 204 (no body) on success, 404 if not found

# === Operations ===

# Force reload (after manual domains.map edit)
curl -s -X POST http://haproxy:8404/v1/reload

# Health check
curl -s http://haproxy:8404/v1/health

# === From the host (via docker exec) ===

# List backends from host
docker exec haproxy curl -s http://localhost:8404/v1/backends

# Register from host
docker exec haproxy curl -s -X POST http://localhost:8404/v1/backends \
  -H "Content-Type: application/json" \
  -d '{"domain":"new.example.com","container":"new-app"}'

# Health check from host
docker exec haproxy curl -s http://localhost:8404/v1/health
```

---

## Appendix B: Generated Files Example

Given this `domains.map`:

```
friendly-miners.dyndns.org      friendly-dashboard    80    443
busydaddyrust-dev.dyndns.org    lgsm                  8888  8888  8000
myapp.example.com               myapp-web             8080  8443
```

The generated files would be:

**conf.d/20-backends.cfg:**
```
# Auto-generated backends from domains.map

backend friendly-dashboard-http
    mode http
    server friendly-dashboard friendly-dashboard:80 init-addr last,libc,none

backend friendly-dashboard-https
    mode tcp
    server friendly-dashboard friendly-dashboard:443 check inter 5s fall 3 rise 2 init-addr last,libc,none

backend lgsm-http
    mode http
    server lgsm lgsm:8888 init-addr last,libc,none

backend lgsm-https
    mode tcp
    server lgsm lgsm:8888 check inter 5s fall 3 rise 2 init-addr last,libc,none

backend lgsm-mapdownload
    mode http
    timeout server 5m
    server lgsm lgsm:8000 init-addr last,libc,none

backend myapp-web-http
    mode http
    server myapp-web myapp-web:8080 init-addr last,libc,none

backend myapp-web-https
    mode tcp
    server myapp-web myapp-web:8443 check inter 5s fall 3 rise 2 init-addr last,libc,none
```

**maps/http-domains.map:**
```
friendly-miners.dyndns.org    friendly-dashboard-http
busydaddyrust-dev.dyndns.org    lgsm-http
myapp.example.com    myapp-web-http
```

**maps/https-domains.map:**
```
friendly-miners.dyndns.org    friendly-dashboard-https
busydaddyrust-dev.dyndns.org    lgsm-https
myapp.example.com    myapp-web-https
```

**maps/mapdownload-domains.map:**
```
busydaddyrust-dev.dyndns.org    lgsm-mapdownload
```

---

## Appendix C: Future Enhancements (Out of Scope for v1.0)

1. **Runtime map updates via stats socket** -- Update HAProxy maps in-memory for instant effect, then persist to `domains.map` for durability. Avoids reload for simple additions.

2. **Batch registration endpoint** -- `POST /v1/backends/batch` accepting an array of registrations, producing a single reload.

3. **Webhook notifications** -- Notify backend containers when their registration is removed or when HAProxy reloads.

4. **Registration TTL** -- Auto-expire registrations that are not renewed within a configurable time window. Backend containers would need to send periodic heartbeats.

5. **Domain ownership verification** -- Require a TXT record or container label to prove domain ownership before registration is accepted.

6. **Read-only dashboard** -- A simple HTML page served on a separate port showing all current registrations and HAProxy status.
