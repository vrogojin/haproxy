# PROXY protocol v2 by default: design

Status: implemented on branch `feat/proxy-protocol-v2` (this repo) and `feat/proxy-protocol-v2-default` (unicitynetwork/ssl-manager). Nothing is deployed yet.
Inventory of consumers: [proxy-protocol-v2-inventory.md](proxy-protocol-v2-inventory.md).

## 1. Goal and non-goals

**Goal.** Backends behind the shared haproxy see the real client IP. This covers the HTTP frontend (`:80`), TLS-SNI passthrough (`:443`) and the extra TCP/HTTP ports. Every ssl-manager-based backend gets it by default once rebuilt on the new base image. Nobody gets it implicitly: haproxy sends a header **only** to a backend that registered as able to take one.

**Non-goals.**

- UDP. Raw UDP and libp2p ports (ipfs swarm 4001, game ports) are not routed through haproxy and are not covered.
- PROXY v1.
- `send-proxy-v2-ssl` and other TLV options. haproxy terminates no TLS, so it has no TLS facts to add.
- Making non-ssl-manager apps PROXY-aware. That is per-service work, listed in §7.

## 2. Wire-level choices

- haproxy server line: `send-proxy-v2 check-send-proxy`.
  - `check-send-proxy` is haproxy's default for send-proxy servers. It is written out explicitly so that a later `port`/`addr` on the check cannot silently strip the header from health checks. Health checks therefore reach a listener that *requires* the header correctly.
  - Checks send a v2 **LOCAL** header. Receivers treat LOCAL as "use the TCP peer".
- PROXY servers get their **own backend names** (`…-http-pp`, `…-https[-<port>]-pp`, `…-extra-<listen>-pp`).
  - A domain that sends the header therefore never shares a backend block with one that must not. Without this, two alias domains of the same container could disagree under the first-line-wins rule.
  - kick/drain (`serverIdsForEntry`) mirrors the same naming. The e2e test checks the parity.
- haproxy without TLVs sends 28 bytes (IPv4) or 52 bytes (IPv6). Receivers cap the payload at 1024 bytes (`SSL_PROXY_MAX_HEADER`) and wait at most 5 s for it (`SSL_PROXY_HEADER_TIMEOUT`).

## 3. Registration API (v1.1, backward compatible)

These are new, optional request fields. Omitting all of them is the pre-PROXY behaviour.

| Field | Values | Meaning |
|---|---|---|
| `proxy_protocol` | `"v2"` \| `"none"` (default; also `null`/absent) | Send PROXY v2 on the http and https server lines |
| `http_proxy_port` | int \| null | While `proxy_protocol` is v2, `:80` traffic targets this PROXY-aware port instead of `http_port` |
| `https_proxy_port` | int \| null | While `proxy_protocol` is v2, `:443` SNI traffic targets this PROXY-aware port instead of `https_port` (ssl-manager uses this for its TLS shim, port 8445) |
| `extra_ports[i].proxy_protocol` | `"v2"` \| `"none"` (default) | Send PROXY v2 to that one extra port |

`map_port` (mapdownload) never gets a header.

**Validation (422 `VALIDATION_ERROR`):**

- An unknown mode, including `"v1"`, is rejected.
- `*_proxy_port` without `proxy_protocol: "v2"` is rejected.
- `*_proxy_port` whose base port is null is rejected.
- `*_proxy_port` set to 8000 or 8404 is rejected with `PORT_NOT_ALLOWED`. These are haproxy-internal ports, the same guard that applies to the other port fields.

`*_proxy_port` values are backend **targets**, never bound or published by haproxy. Like `http_port`, they are therefore not checked against `ALLOWED_PORTS`.

**Persistence.** `domains.map` stays the single source of truth. Options are written as tokens after the extras, with a `-` placeholder in the `map_port` column:

```
new.example.com  ctr  80  443  -  extra:50001:50001:tcp  pp=v2  pp-http=8081  pp-https=8445  pp-extra=50001
```

A pre-PROXY `generate-config.sh` logs "Ignoring unrecognized field" for these tokens and a pre-PROXY API skips them. **A rollback of the haproxy image therefore silently stops sending the header and routes to the plain `http_port`/`https_port` again.** That is why `*_proxy_port` exists: the plain ports remain the fallback, and a listener that *requires* the header is never hit without one.

**Other API behaviour:**

- Idempotency (`entriesMatch`) includes the new fields. Re-registering with a different PROXY mode is an update and triggers a reload.
- GET and list responses gain `proxy_protocol`, `http_proxy_port`, `https_proxy_port` and `extra_ports[].proxy_protocol`.
- `/v1/health` reports `api_version: "1.1"` and `features: ["proxy_protocol_v2"]`.

## 4. ssl-manager side

The new default is `SSL_PROXY_PROTOCOL=v2`. Opt out with `off`. In remote-tunnel mode (`REMOTE_HAPROXY_ID`) the default is `off`.

| Component | Port | PROXY handling |
|---|---|---|
| `ssl-http-proxy` | 80 | Header optional. Honoured only from a trusted peer. When honoured, `X-Forwarded-For` **and** `X-Real-IP` sent to the app are **overwritten** with the real client address. |
| `ssl-pp-proxy` (new TLS/TCP shim) | `SSL_PROXY_HTTPS_PORT` (8445) | Header optional, trusted only. Forwards the untouched TLS byte stream to the app's `SSL_HTTPS_PORT`. |
| app TLS listener | `SSL_HTTPS_PORT` | Unchanged. It still serves direct (no-header) connections and the no-PROXY fallback route. |
| app extras | – | Unchanged (`none`). Opt in per port with `"proxy_protocol":"v2"` in `EXTRA_PORTS` only if that listener reads PROXY v2. |

### `ssl-http-proxy` header rules

- Client-supplied forwarding headers are matched case-insensitively and always replaced. haproxy lower-cases header names, so the old code let a client's `x-forwarded-for` shadow ours. That was a pre-existing spoofing bug.
- Without a header (direct or legacy traffic), the legacy XFF append is kept. `X-Real-IP` is set to the TCP peer.

### Registration flow (`ssl-setup`)

1. Step 2 registers http-only with `proxy_protocol`.
2. Step 6a starts the shim (`ssl-pp-proxy-wrapper`, which restarts it with backoff).
3. Only once the shim is accepting does step 6 register `proxy_protocol:"v2", https_proxy_port:8445`.

If the shim port is busy or the shim does not start, ssl-setup registers **`none`** for the whole entry and logs a warning. It never sends a header towards a listener that cannot take it.

An invalid `SSL_PROXY_PROTOCOL` value, or an `SSL_PROXY_HTTPS_PORT` that collides with 80/8000/8404/8443/8444, `SSL_HTTPS_PORT` or `APP_HTTP_PORT`, also degrades to `off` with a warning. It never stops the container. *Tested (`new3`).*

The registered mode is written to `/tmp/.ssl-proxy-protocol`. `haproxy-register register` re-reads it, so a later re-announce never flips the mode.

### Why a shim and not "make the app accept PROXY"

ssl-manager does not own the TLS listener: it is node in concierge, Qt in fulcrum, nginx in unibro/praxis/voxiverse. nginx can parse PROXY, but only as **mandatory** per `listen`, which breaks direct, hairpin and health traffic on that port. Node `https` and Fulcrum cannot parse it at all.

Terminating TLS in ssl-manager would change ALPN, HTTP/2, websockets, client-cert and performance behaviour for every app. That is too invasive as a default.

A byte-transparent shim on a separate port gives every app the header-carrying route for free and keeps the app port as the direct and fallback route.

**Trade-off: what the app sees on TLS.** The app sees the **shim's address**, not the client. It used to see haproxy's address, so this is no regression, but it is not the real client IP either. The real client IP is:

- in the shim log, with `SSL_PROXY_LOG_CONNECTIONS=true`;
- **delivered to the app** if the app opts in with `SSL_PROXY_HTTPS_UPSTREAM=127.0.0.1:<pp-port>` and `SSL_PROXY_HTTPS_UPSTREAM_PROTOCOL=v2` (or v1). The shim then re-emits a PROXY header to a dedicated PROXY listener of the app. The e2e test proves this path (`pp_src` = client).

**App-side PROXY listener: the only supported nginx pattern.**

```nginx
server {
    listen 127.0.0.1:8446 ssl proxy_protocol;  # NOT 0.0.0.0: reachable only from inside the container
    set_real_ip_from 127.0.0.1/32;              # the shim's source address, and nothing else
    real_ip_header proxy_protocol;
    # use ONLY $remote_addr (logs, limits, X-Forwarded-For/X-Real-IP to the app)
    proxy_set_header X-Real-IP       $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    ...
}
```

The rules behind it:

- **Never use `$proxy_protocol_addr`.** It is the raw value of whatever header arrived. nginx applies no trust check to it.
- **Use `$remote_addr`.** It is rewritten from the header **only** when the TCP peer matches `set_real_ip_from`.
- **The listener must be unreachable for everyone but the shim.** A `proxy_protocol` listen *requires* a header. If it is bound to `0.0.0.0` or the container IP, any peer on haproxy-net or the app network can connect and send a forged header. If it is bound to loopback, only processes inside the container can.
- **Loopback is acceptable on this listener**, unlike the default upstream. On this listener `$remote_addr` becomes the client address carried by the shim's header, so proxied clients never appear as 127.0.0.1.
  - The shim always sends a header here: the real client's address, the direct peer's address for header-less connections, or LOCAL for haproxy's health probes.
- **Non-nginx apps** must apply the same two rules: accept PROXY only from the shim's source address, and bind the listener so that only the shim can reach it. The e2e app (`tests/e2e/proxy-protocol/app.py`) does both. The e2e test asserts that a forged header sent straight to that listener from another container, or from the container's own non-loopback IP, is not adopted.

The default upstream (no app opt-in, `auto:$SSL_HTTPS_PORT`) is the **container's own non-loopback IP**, never 127.0.0.1. On that path the app sees the TCP peer. If the peer were loopback, an app ACL such as `allow 127.0.0.1` or "localhost is admin" would start admitting every internet client. If no non-loopback address can be found, the shim exits with status 2: the wrapper does not restart it, and ssl-setup registers `none`.

**The shim is Python asyncio.** It is fine for the current traffic levels. A high-throughput TLS service can opt out (`SSL_PROXY_PROTOCOL=off`), or a future version can replace the shim with a native one using the same CLI. See risk R4.

### Trust policy (`SSL_PROXY_TRUSTED_CIDRS`)

| Value | Meaning |
|---|---|
| `haproxy` (**default**) | Only the current IP(s) of `HAPROXY_HOST`, resolved via docker DNS |
| `auto` | The directly connected subnet through which `HAPROXY_HOST` is reached, i.e. the whole haproxy-net subnet (172.20.0.0/16 here). Not recommended: every container on haproxy-net could then assert client IPs. |
| `<CIDR>`, `<IP>` lists | Static entries |
| `none` | Trust no one |

`SSL_PROXY_HAPROXY_ADDR=<ip|cidr>[,…]` pins haproxy's address statically. It is trusted in addition to the DNS name.

The policy **fails closed**:

- **TTL.** The resolved set is cached for at most 10 s. Any lookup after that re-resolves, on a hit as well as a miss. A miss also forces a re-resolution, rate-limited to once every 5 s.
- **haproxy restarts with a new IP.** The new IP is trusted on its first connection. The old IP stops being trusted within 10 s, because the old address may now belong to another container.
- **Name stops resolving** (haproxy removed, DNS failure). The dynamic set is **cleared**, never kept from cache. Headers are rejected and the closed connections are logged, until the name resolves again. Pin the address with `SSL_PROXY_HAPROXY_ADDR` if a docker-DNS outage must not turn into rejected traffic.
- **Name resolves to more than one address.** A loud warning is logged on every change of the set: a duplicate or impostor container may be using the name or alias.
- `0.0.0.0/0` and garbage values are refused at startup (fail closed, loudly).
- **Untrusted peer that starts with the v2 signature: the connection is closed** (logged, rate-limited). The header is never stripped-and-continued and never passed to the app.
- Untrusted peer without a header: served normally.
- IPv4-mapped IPv6 is normalised before matching.

## 5. Compatibility matrix

"Header" means haproxy sends PROXY v2 for that backend.

| haproxy | backend image | registers | result |
|---|---|---|---|
| old (master) | old ssl-manager | – | unchanged |
| old | **new** ssl-manager | `proxy_protocol:v2`, `https_proxy_port:8445` (ignored by old API) | **works, no header**. :80 goes to ssl-http-proxy without a header, :443 goes straight to the app port. *Tested (baseline run).* |
| **new** | old ssl-manager / any old client | nothing | **unchanged, no header**. *Tested.* |
| **new** | **new** ssl-manager | v2 + 8445 | **real client IP**: :80 via X-Real-IP/XFF, :443 via the shim (app sees the shim's address; opt-in upstream PROXY gives the app the client). *Tested.* |
| new | new, `SSL_PROXY_PROTOCOL=off` | `none` | no header |
| new → **rolled back to old** | new | tokens ignored | header stops; routes fall back to 80/443; still works. The "re-register without flag" path is *tested*. |
| new | new ssl-manager **rolled back to old image** (same container name) | old image re-registers without the flag | header stops at its step-2 registration. For the few seconds before that, haproxy sends a header to an old `ssl-http-proxy` (400s on :80) and `:443` hits shim port 8445 where nothing listens (connection refused). Mitigation: in `docker stop`, call `haproxy-register unregister`, as the fulcrum entrypoint already does. |
| new | **custom client** sending `proxy_protocol:v2` for a port that cannot parse PROXY | – | **broken connections**. The flag is a promise by the registrant. Never set it on behalf of an app; that is why no default is ever inferred. |

## 6. Failure modes

| # | What happens | Effect | Handling |
|---|---|---|---|
| F1 | Header sent to a non-aware listener | that listener's protocol breaks | Header only on explicit opt-in, plus the separate `*_proxy_port` target, plus image ordering (§7). |
| F2 | Trust set empty or wrong (for example `HAPROXY_HOST` unresolvable, or a DNS outage) | headers rejected, so :80/:443 for that backend fail closed | Re-resolution on a miss (5 s) and TTL 10 s. `describe()` is logged at start. A typo fails at startup. Pin the address with `SSL_PROXY_HAPROXY_ADDR`. |
| F3 | haproxy health checks | – | Checks carry a LOCAL header. Both receivers accept it, and connect-only probes are fine. *Tested: the mock logs a LOCAL header from the checks on :80, :8445 and :50005, and all `-pp` servers are UP.* |
| F4 | Shim up, app down | haproxy shows the https server **UP** (it checks the shim). Clients get an immediate close, as before. | Monitoring that relied on haproxy's view of the app port must probe the app. |
| F10 | Shim (or any PROXY listener) dead | the primary server goes DOWN after 3 failed checks (up to about 30 s) | Every `-pp` backend has a header-less `backup` server `<c>-plain` on the plain port (`http_port`, `https_port` or extra target). haproxy fails over to it, so the app is reached without a header. *Tested: shim killed, https still served via the backup.* |
| F5 | Hairpin and container-to-container traffic (same network, no header) | – | Served unchanged. Via haproxy it carries a header with the hairpin source. *Tested: nonce check via haproxy, direct :80/:443/:8445.* |
| F6 | Slow or partial header | – | 5 s deadline. A partial signature of 12 bytes or more is rejected. A shorter non-signature prefix is treated as plain data. Split-across-segments headers are handled. *Unit-tested.* |
| F7 | Oversized header | – | Payload over 1024 bytes is rejected. *Tested.* |
| F8 | IPv6 clients | – | `bind *:80` is IPv4. IPv6 clients that reach haproxy through docker's userland proxy appear as the docker gateway, both in the header and today. Receivers parse IPv6 headers correctly. *Unit-tested.* |
| F9 | Many connections | – | The shim caps connections (4096) and rejects beyond the cap with a log line. ssl-http-proxy is unchanged (thread per connection). |

## 7. Rollout order

Follow these steps strictly in order.

1. **Ship haproxy first.** Deploy the new haproxy image. It is a no-op until someone registers the flag: all existing lines lack tokens, so the configs are byte-identical apart from backend names for flagged entries. Check that `/v1/health` reports `features:["proxy_protocol_v2"]`.
2. **Publish the new ssl-manager base image** (`:latest` plus a version tag). Consumers are not affected until they rebuild.
3. **Rebuild and redeploy consumers one at a time.** The new container starts its shim and registers v2, and haproxy reloads (2 s debounce). Verify each with:
   - `curl -s https://<domain>/` still works;
   - `GET /v1/backends/<domain>` shows `proxy_protocol: v2`;
   - for :80, the app sees `X-Real-IP` = your IP.
4. Per-service app work (optional; this is what makes the IP reach TLS apps): add a PROXY listener and set `SSL_PROXY_HTTPS_UPSTREAM*`.

The order and work needed for each consumer:

| Order | Service | Action | App sees real IP on :443 after |
|---|---|---|---|
| 1 | unibro-vm-proxy | rebuild on the new base | shim only. For the app, use the §4 nginx pattern (`listen 127.0.0.1:8446 ssl proxy_protocol`, `set_real_ip_from 127.0.0.1/32`, `real_ip_header proxy_protocol`, `$remote_addr`) with `SSL_PROXY_HTTPS_UPSTREAM=127.0.0.1:8446` and `…_PROTOCOL=v2` |
| 2 | praxis ingress (autossl) | bump the pinned ssl-manager digest in `config/ingress/Dockerfile.autossl` and rebuild | the same §4 pattern in `templates/default.conf.template`. Keep `proxy_set_header X-Forwarded-For $remote_addr` (a single value, as the app requires). `$remote_addr` is the client only because of `set_real_ip_from 127.0.0.1/32`. |
| 3 | voxiverse-game | rebuild | as above (`voxiverse.conf.template`) |
| 4 | concierge-backend | rebuild. **:80 rate limits become per-client immediately** (first XFF value is now trustworthy). | Node cannot read PROXY; the app keeps seeing the shim address on HTTPS. Needs a Node PROXY wrapper or an nginx front (escalated). |
| 5 | fulcrum-alpha | rebuild. Only :80 and the :443 SNI route change; the 50001-50004 extras stay `none`. | Per-IP limits stay global until Fulcrum is patched or an extra-port shim is added (escalated). |
| – | linkr-*-tls, agent-crm-prod-edge, ipfs-kubo | not ssl-manager. Change the registration (`lib/haproxy-api.mjs`, the manual map line) to `proxy_protocol:v2` with `http_proxy_port`/`https_proxy_port` pointing at **new** nginx `proxy_protocol` listeners. Deploy nginx before re-registering. Here the PROXY peer is haproxy itself, so: `set_real_ip_from <haproxy IP>/32` (not the subnet), `real_ip_header proxy_protocol`, `$remote_addr` only. Firewall or ACL the PROXY listener to haproxy's address too: an nginx PROXY listen on haproxy-net is reachable by every container there. | yes |
| – | aggregator-gateway, friendly-dashboard, uniquake | no change possible without app code or a front. Leave them `none`. | no |

## 8. Rollback

Choose the scope:

- **One backend:** set `SSL_PROXY_PROTOCOL=off` and restart, or redeploy the previous image. It re-registers `none` and the header stops after the 2 s debounce.
- **Emergency, without touching the backend:** an admin POST of the same registration without the flag. Or edit `domains.map` to drop the `pp*` tokens, then `POST /v1/reload`.
- **haproxy:** redeploy the previous haproxy image. Tokens are ignored, the header stops everywhere, and routes fall back to `http_port`/`https_port`. Nothing has to be re-registered: the shim port stays up but is unused.
- **ssl-manager base:** re-pin consumers to the previous digest.

## 9. Security notes and open risks

- **R1, trust boundary.** The default is `haproxy`: only haproxy's current address, failing closed. The e2e test asserts that a forged header from another haproxy-net container to a default-config backend is rejected with an immediate close.
  - Residual risk 1: anything that can take over haproxy's docker DNS name or alias on haproxy-net is trusted. That is why a multi-address warning is logged.
  - Residual risk 2: `auto` (the whole subnet) remains available as an explicit opt-in, but it lets every container on that shared network assert client IPs.
  - Trade-off: a docker-DNS outage now means rejected PROXY connections, unless `SSL_PROXY_HAPROXY_ADDR` pins the address.
- **R2, the app sees the shim on TLS.** The default rollout gives the *ssl-manager layer* the real IP on :443. Apps get it only after the per-service opt-in (§7). Node and Fulcrum need code. Escalated rather than silently re-scoped.
- **R3, F4 health semantics change** (shim UP while app down).
- **R4, shim performance.** It is a Python asyncio byte pump on every TLS byte. It was not load-tested. Before turning it on for a high-traffic TLS service, measure it, or opt out for that service.
- **R5, rate-limit and abuse behaviour changes.** Apps that keyed limits on one shared address suddenly see many distinct ones. concierge limits become per-client, which is intended but means a larger state footprint.
- **R6, extra TCP ports** (fulcrum) remain without PROXY until Fulcrum can parse it.
- **R7, CDNs and upstream proxies in front of haproxy.** When a header is honoured, ssl-http-proxy *overwrites* XFF. A domain fronted by a CDN (for example Cloudflare's proxied mode) would then report the CDN edge, not the visitor. No such domain was found in the inventory. If one appears, it needs a CDN-CIDR allowlist for XFF, which is not implemented.
- **R8, HTTP connection reuse.** haproxy (2.3+) includes the PROXY source in its server-connection reuse key, so a keep-alive connection to a PROXY server is never shared between clients. ssl-http-proxy closes after each response anyway. This was **not** separately tested against a keep-alive PROXY-native listener (the nginx `http_proxy_port` case). Verify that before relying on it.
