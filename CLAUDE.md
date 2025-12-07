# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

HAProxy reverse proxy setup for Docker that routes HTTP/HTTPS traffic to backend containers based on domain names using SSL passthrough mode.

## Architecture

```
Internet → HAProxy (80/443) → Docker Network → Backend Containers
                                              ├── friendly-dashboard (80/443)
                                              └── ipfs-kubo (80/443)
```

- **HTTP (port 80)**: Routed based on `Host` header
- **HTTPS (port 443)**: SSL passthrough using SNI (Server Name Indication) - backends handle their own SSL termination

## Domain Mappings

| Domain | Backend Container |
|--------|------------------|
| friendly-miners.dyndns.org | friendly-dashboard |
| unicity-ipfs1.dyndns.org | ipfs-kubo |

**Note**: The `certs/` directory also contains certificates for `uniquake-dev.dyndns.org` and `sphere-test.dyndns.org` which are not currently routed.

## Commands

```bash
# Create the shared Docker network (one-time setup)
docker network create haproxy-net

# Validate HAProxy configuration
docker run --rm -v $(pwd)/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro haproxy:lts haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg

# Start HAProxy
docker compose up -d

# View logs
docker compose logs -f haproxy

# Reload configuration (after editing haproxy.cfg)
docker kill -s HUP haproxy

# Stop HAProxy
docker compose down
```

## Adding New Domain Mappings

Edit `haproxy.cfg` and add:

1. In `frontend http-in`:
   ```
   acl host_newdomain hdr(host) -i newdomain.example.com
   use_backend newcontainer-http if host_newdomain
   ```

2. In `frontend https-in`:
   ```
   acl sni_newdomain req.ssl_sni -i newdomain.example.com
   use_backend newcontainer-https if sni_newdomain
   ```

3. Add backends (use `init-addr last,libc,none` to handle DNS resolution when backends start after HAProxy):
   ```
   backend newcontainer-http
       mode http
       server newcontainer newcontainer:80 check init-addr last,libc,none

   backend newcontainer-https
       mode tcp
       server newcontainer newcontainer:443 check init-addr last,libc,none
   ```

4. Reload: `docker kill -s HUP haproxy`

## Backend Container Configuration

Backend containers must:

1. **Join the haproxy-net network**:
   ```yaml
   # In backend's docker-compose.yml
   services:
     your-service:
       container_name: friendly-dashboard  # Must match haproxy.cfg
       networks:
         - haproxy-net

   networks:
     haproxy-net:
       external: true
   ```

2. **Use exact container names** as specified in haproxy.cfg (`friendly-dashboard`, `ipfs-kubo`)

3. **Expose ports 80 and 443** internally (no need to publish to host since HAProxy handles external access)

4. **Handle their own SSL** - certificates stay on backend containers

## Key Behaviors

- **Default backends**: Requests to unmatched domains return 503 (HTTP) or connection refused (HTTPS)
- **DNS resilience**: Uses `init-addr last,libc,none` so HAProxy starts even if backends aren't running yet
- **Health checks**: Each backend has `check` enabled for automatic failover

## File Structure

- `haproxy.cfg` - Main HAProxy configuration
- `docker-compose.yml` - HAProxy container definition
- `BACKEND-SETUP.md` - Detailed instructions for configuring backend containers
- `certs/` - SSL certificates managed by Certbot (unused with passthrough mode)

## Certificate Management

Certificates in `certs/` are managed by Certbot. Currently unused since SSL passthrough delegates certificate handling to backend containers. If switching to SSL termination mode, use:
```bash
cat fullchain.pem privkey.pem > haproxy.pem
```
