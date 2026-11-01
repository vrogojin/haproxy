# PROXY protocol v2: inventory of services behind the shared haproxy

Snapshot taken on host m29542, 2026-10-30. The method was read-only: `docker exec haproxy cat /etc/haproxy/domains.map`, `docker network inspect haproxy-net`, and the Dockerfiles, compose files and app sources under `~`. This file contains no secrets.

Read it alongside [PROXY-PROTOCOL-V2-DESIGN.md](PROXY-PROTOCOL-V2-DESIGN.md), which defines the compatibility matrix and the rollout order referred to below.

## Facts that apply to every service

| | Today (master `222290b`, live haproxy 3.2.9) |
|---|---|
| `:80` | HTTP mode, routed by Host header through `http-domains.map`. haproxy adds **no** `X-Forwarded-For` (there is no `option forwardfor`). |
| `:443` | TCP mode, SNI passthrough through `https-domains.map`. The backend's TCP peer is haproxy (`172.20.0.9`). |
| extra ports | Per-port TCP or HTTP frontends (`30-extra-frontends.cfg`): 50001-50004 (fulcrum) and 8000 (mapdownload). |
| PROXY protocol | None anywhere: no `send-proxy`, `accept-proxy` or `forwardfor`. |
| haproxy-net | `172.20.0.0/16` (bridge, IPv4 only, `EnableIPv6=false`). |

The result is that **no backend sees a real client IP on `:443` or on the TCP extra ports.** On `:80`, ssl-manager backends get an `X-Forwarded-For` that `ssl-http-proxy` appends to.

**Spoofing finding (fixed on the ssl-manager branch):** haproxy forwards header names in lower case. ssl-manager's old `ssl-http-proxy` therefore passed a client-supplied `x-forwarded-for` through in addition to its own appended copy. Apps that read the first XFF value, such as concierge `clientIp()`, saw whatever the client sent. The e2e baseline reproduced this (`X-Real-IP`/XFF were `6.6.6.6` as sent by the client).

## Services

"ssl-mgr" means the image is built `FROM ghcr.io/unicitynetwork/ssl-manager`.

| # | Service (container) | Repo | Base | Registered (http / https / extras) | :80 listener | TLS terminator for :443 | Health check | Client IP today |
|---|---|---|---|---|---|---|---|---|
| 1 | fulcrum-alpha (`d101b79641e1`) | `~/Fulcrum-Alpha` (`docker/Dockerfile`, `docker/docker-entrypoint.sh`, `run-fulcrum.sh`) | ssl-mgr | 80 / **50004** / 50001 tcp, 50002 tcp, 50003 http, 50004 tcp | ssl-http-proxy, `APP_HTTP_PORT=0` | Fulcrum (Qt/C++) natively on 50002 (ssl) and 50004 (wss); 50001 and 50003 are plain | `nc -z localhost 50001` | Qt `peerAddress()` only (`src/SrvMgr.h:81-102` per-IP limits, `src/RPC.cpp:813`). Every client counts as haproxy, so the **per-IP limits are effectively global**. |
| 2 | concierge-backend (`e6291f8a7ad7`) | `~/concierge` (`backend/Dockerfile`, `backend/docker-entrypoint.sh`, `docker-compose.yml`) | ssl-mgr | 80 / 443 / – | ssl-http-proxy, upstream 127.0.0.1:8080 | **Node** `https` on 443, in the same process as HTTP :8080 | `fetch http://127.0.0.1:8080/healthz` | `backend/src/app.ts:775-782` takes the first XFF value, falling back to `socket.remoteAddress`. Used for rate limits (`app.ts:1848`, `3406`). On HTTPS every client shares one bucket. |
| 3 | unibro-vm-proxy (`3cae41bab38a`) | `~/UniBro-VM/proxy` (`Dockerfile`, `nginx.conf.tpl`) | ssl-mgr + nginx | 80 / 443 / – | ssl-http-proxy (ACME only) | nginx `listen ${SSL_HTTPS_PORT} ssl` | none | nginx `$remote_addr` (haproxy) is sent upstream as XFF |
| 4 | voxiverse-game (exited) | `~/voxiverse` (`docker/server/*`, `deploy/docker-compose.yml`) | ssl-mgr + nginx | 80 / 443 / – | nginx on `APP_HTTP_PORT` | nginx `${SSL_HTTPS_PORT}` ssl | `curl -skf https://localhost:443/healthz` | nginx `$remote_addr` becomes X-Real-IP and XFF for the relay |
| 5 | praxis ingress autossl (`praxis-test`, `praxis-staging`, `praxis-u0r`; all exited or stale) | `~/praxis-test`, `~/asc-live-deploy` (`compose.ingress-autossl.yml`, `config/ingress/Dockerfile.autossl`, `templates/default.conf.template`) | ssl-mgr (digest-pinned) + nginx | `-` or 80 / 443 / – | ssl-http-proxy (ACME + `/_ssl/health`) | nginx :443, which proxies to the app's unix socket | `curl /_ssl/health && curl -sk https://127.0.0.1/` | nginx overwrites XFF with `$remote_addr`. The app requires exactly one XFF value (`packages/auth-http/src/server.ts:338-360`). |
| 6 | linkr-deploy-{demo,proto,prod}-tls | `~/linkr-deploy` (`lib/haproxy-api.mjs`, `nginx/nginx.conf`) | nginx:1.27 (custom registration) | – / 443 / – | none | nginx :443 | `wget https://127.0.0.1/.nginx-health` | nginx overwrites XFF and X-Real-IP; the app uses `req.socket.remoteAddress` (`src-reference/server.js:139`) |
| 7 | agent-crm-prod-edge | `~/agent-crm-deploy-prod/app` (`docker-compose.yml`, `edge/nginx.conf`) | nginx:alpine (manual map line) | 80 / 443 / – | nginx :80 (ACME + redirect) | nginx :443, which fronts the web app and supabase | none | nginx `$remote_addr`, `$proxy_add_x_forwarded_for` |
| 8 | ipfs-kubo | `~/ipfs-storage` (`Dockerfile`, `config/nginx.conf.template`) | Debian + nginx (manual line) | 80 / 443 / – | **nothing on :80** (the registration is dead) | nginx :443 http2 | `healthcheck.sh` | nginx `$remote_addr`, `$proxy_add_x_forwarded_for` |
| 9 | aggregator-gateway | `~/aggregators_net` (`Dockerfile`, `server/http_server.js:120`) | node (manual line) | 80 / 443 / – | nothing on :80 | Node `https` | none | not used |
| 10 | uniquake-server | `~/uniquake` | node (manual line) | 80 / 443 / – | not verified | Node | `curl :9000/assets/manifest.json` | `lib/wss-proxy.js:56`, for logging only |
| 11 | friendly-dashboard | `~/friendly-miners`, `~/friendly-dashboard-source` | node (manual line) | 80 / 443 / – | – | Node (Express) https | `wget https://localhost/health` | `src/services/auditLog.ts:54-56` takes the first XFF value |
| 12 | busydaddyrust-lgsm-1 | `~/busydaddyrust` | game server (manual line) | 8888 / 8888 / map 8000 | – | – | `pgrep` | n/a |
| – | stale lines: alphatest-faucet, unicity-swap, cocalc, praxis-* | | | | | | | |

### What the ssl-manager base image owns inside a container (before this change)

| Port | Component | Notes |
|---|---|---|
| 80 | `ssl-http-proxy` (Python `ThreadingHTTPServer`) | ACME, `/_ssl/health`, `/_ssl/nonce`, and a proxy to `127.0.0.1:$APP_HTTP_PORT` |
| 8444 | `ssl-alias-proxy` | Only runs when `SSL_DOMAIN_ALIASES` is set, which no running service does |
| `$SSL_HTTPS_PORT` | **the app** | ssl-manager only obtains the certificate. It never terminates TLS. |
| extras | **the app** | |

### Ability to read PROXY protocol natively

| Group | Services | Native PROXY? |
|---|---|---|
| ssl-mgr + nginx | unibro-vm-proxy, voxiverse, praxis ingress | Yes, via a dedicated loopback-only `listen 127.0.0.1:<port> ssl proxy_protocol;` server block with `set_real_ip_from 127.0.0.1/32` and `$remote_addr` (design §4) |
| ssl-mgr + app TLS | concierge (Node), fulcrum (C++) | No. Use the ssl-manager shim; the app sees the shim's address. |
| custom nginx | linkr, agent-crm-edge, ipfs-kubo, faucet | Yes, with an nginx config change |
| custom Node or app TLS | aggregator-gateway, friendly-dashboard, uniquake | No. These need code, or an nginx/ssl-manager front. |
| raw TCP | fulcrum 50001/50002/50004 extras | No. Needs a Fulcrum patch or a per-port shim. |
| UDP / libp2p | ipfs 4001 swarm, quake game ports (published directly on the host) | **Out of scope.** PROXY protocol here is TCP-only, and these ports do not pass through haproxy. |
