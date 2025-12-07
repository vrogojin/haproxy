# Backend Container Configuration for HAProxy Integration

This document provides instructions for configuring Docker containers to work with the HAProxy reverse proxy setup.

## Prerequisites

- HAProxy container is running on the `haproxy-net` Docker network
- Your container handles its own SSL/TLS termination (HAProxy uses SSL passthrough)
- Your container exposes HTTP on port 80 and HTTPS on port 443

## Configuration Steps

### 1. Verify the Docker Network Exists

```bash
docker network ls | grep haproxy-net
```

If it doesn't exist, create it:
```bash
docker network create haproxy-net
```

### 2. Update Your docker-compose.yml

Add the following to your service configuration:

```yaml
services:
  your-service:
    # REQUIRED: Container name must match exactly what's configured in haproxy.cfg
    # Current mappings:
    #   - friendly-miners.dyndns.org → container name: friendly-dashboard
    #   - unicity-ipfs1.dyndns.org → container name: ipfs-kubo
    container_name: <YOUR_CONTAINER_NAME>

    # Your existing configuration...
    image: your-image:tag

    # REQUIRED: Join the haproxy-net network
    networks:
      - haproxy-net
      # Include any other networks your container needs
      - default

    # IMPORTANT: Remove or comment out host port mappings for 80 and 443
    # HAProxy now handles external traffic on these ports
    # ports:
    #   - "80:80"    # Remove this
    #   - "443:443"  # Remove this

    # Keep any other ports your application needs that aren't proxied
    ports:
      - "8080:8080"  # Example: other ports can remain

# REQUIRED: Declare the external network
networks:
  haproxy-net:
    external: true
  default:
    driver: bridge
```

### 3. If Using docker run Instead of Compose

```bash
docker run -d \
  --name <YOUR_CONTAINER_NAME> \
  --network haproxy-net \
  your-image:tag
```

To connect an existing container to the network:
```bash
docker network connect haproxy-net <YOUR_CONTAINER_NAME>
```

### 4. SSL Certificate Configuration

Your container continues to manage its own SSL certificates. HAProxy performs SSL passthrough, meaning:

- TLS handshake happens directly between client and your container
- Your existing certificate configuration remains unchanged
- Certificates do NOT need to be copied to HAProxy

Ensure your container:
- Has valid SSL certificates for its domain
- Listens on port 443 for HTTPS traffic
- Listens on port 80 for HTTP traffic (if needed)

## Verification

### Test Network Connectivity

From inside your container, verify HAProxy is reachable:
```bash
docker exec <YOUR_CONTAINER_NAME> ping haproxy
```

### Test from HAProxy

Verify your container is reachable from HAProxy:
```bash
docker exec haproxy ping <YOUR_CONTAINER_NAME>
```

### Check HAProxy Backend Status

View HAProxy logs for backend health checks:
```bash
docker logs haproxy 2>&1 | grep <YOUR_CONTAINER_NAME>
```

## Requesting a New Domain Mapping

If your domain is not yet configured in HAProxy, provide:

1. **Domain name**: e.g., `example.dyndns.org`
2. **Container name**: The exact name your container will use
3. **Ports**: Confirm your container exposes 80 (HTTP) and 443 (HTTPS)

The HAProxy configuration at `/home/vrogojin/haproxy/haproxy.cfg` will need to be updated with your mapping.

## Current Domain Mappings

| Domain | Container Name | Status |
|--------|---------------|--------|
| friendly-miners.dyndns.org | friendly-dashboard | Active |
| unicity-ipfs1.dyndns.org | ipfs-kubo | Active |

## Troubleshooting

### Container Not Reachable

1. Verify container is on the correct network:
   ```bash
   docker inspect <YOUR_CONTAINER_NAME> | grep -A 20 Networks
   ```

2. Verify container name matches haproxy.cfg exactly (case-sensitive)

3. Check container is running and healthy:
   ```bash
   docker ps | grep <YOUR_CONTAINER_NAME>
   ```

### SSL/TLS Errors

Since HAProxy uses SSL passthrough:
- Certificate errors originate from your container, not HAProxy
- Verify your container's SSL configuration independently
- Test directly: `curl -vk https://localhost:443` from inside your container

### Port Conflicts

If you previously published ports 80/443 to the host:
1. Stop your container
2. Remove the port mappings from your configuration
3. Restart your container
4. HAProxy will handle external traffic on those ports

## Example: Complete docker-compose.yml

```yaml
services:
  friendly-dashboard:
    container_name: friendly-dashboard
    image: my-dashboard:latest
    restart: unless-stopped
    networks:
      - haproxy-net
      - internal
    volumes:
      - ./certs:/etc/ssl/certs:ro
      - ./data:/app/data
    environment:
      - SSL_CERT=/etc/ssl/certs/fullchain.pem
      - SSL_KEY=/etc/ssl/certs/privkey.pem

networks:
  haproxy-net:
    external: true
  internal:
    driver: bridge
```
