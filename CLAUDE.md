# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

HAProxy reverse proxy setup for Docker that routes HTTP/HTTPS traffic to backend containers based on domain names using SSL passthrough mode.

## Architecture

```
Internet → HAProxy (80/443) → Docker Network → Backend Containers
```

- **HTTP (port 80)**: Routed based on `Host` header using map files
- **HTTPS (port 443)**: SSL passthrough using SNI (Server Name Indication) - backends handle their own SSL termination

## Commands

```bash
# Create the shared Docker network (one-time setup)
docker network create haproxy-net

# Generate config from domains.map
./generate-config.sh

# Validate HAProxy configuration
docker run --rm -v $(pwd)/conf.d:/usr/local/etc/haproxy/conf.d:ro -v $(pwd)/maps:/usr/local/etc/haproxy/maps:ro haproxy:lts haproxy -c -f /usr/local/etc/haproxy/conf.d

# Start HAProxy
docker compose up -d

# View logs
docker compose logs -f haproxy

# Reload configuration (after regenerating config)
docker restart haproxy

# Stop HAProxy
docker compose down
```

## Adding New Domain Mappings

1. Edit `domains.map` and add a line:
   ```
   newdomain.example.com    container-name    80    443
   ```

2. Regenerate config and restart:
   ```bash
   ./generate-config.sh && docker restart haproxy
   ```

## Config Generation

The `generate-config.sh` script reads `domains.map` and generates:
- `conf.d/20-backends.cfg` - Backend definitions
- `maps/http-domains.map` - HTTP routing map
- `maps/https-domains.map` - HTTPS routing map

Template files in `templates/` provide the base configuration:
- `00-global.cfg` - Global settings and defaults
- `10-frontends.cfg` - Frontend definitions with map-based routing

## Backend Container Requirements

Backend containers must:
1. **Join the haproxy-net network** (as external network in their docker-compose.yml)
2. **Use exact container names** as specified in `domains.map`
3. **Handle their own SSL** - HAProxy passes TLS connections through unchanged

See `BACKEND-SETUP.md` for detailed configuration examples.

## Key Behaviors

- **Default backends**: Requests to unmatched domains return 503 (HTTP) or connection refused (HTTPS)
- **DNS resilience**: Uses `init-addr last,libc,none` so HAProxy starts even if backends aren't running yet
- **Health checks**: HTTPS backends have health checks with `inter 5s fall 3 rise 2`

## File Structure

- `domains.map` - Domain to container mappings (host-specific, gitignored)
- `generate-config.sh` - Config generation script
- `templates/` - Base HAProxy config templates
- `conf.d/` - Generated config files (gitignored)
- `maps/` - Generated map files (gitignored)

## Troubleshooting

```bash
# Check if backend containers are on the network
docker network inspect haproxy-net

# Test connectivity from HAProxy to a backend
docker exec haproxy ping <container-name>

# Check HAProxy backend status
docker logs haproxy 2>&1 | grep -i backend
```
