# staging-tunnel — remote staging backend endpoint

A restricted, tunnel-only OpenSSH server on `haproxy-net` that lets **firewalled hosts**
(dev laptops, no public IP) serve a staging backend through the shared public haproxy.

> The **client** side — a standalone image to tunnel **any** http/https service through
> this endpoint (not just concierge) — lives in [`../tunnel-client`](../tunnel-client).

A laptop opens an **SSH reverse tunnel** here and registers its domain with the shared
haproxy over an SSH `-L` forward to the Registration API:

```
laptop:  ssh -R 0.0.0.0:<rport>:<backend>:443 -L 127.0.0.1:8404:haproxy:8404 tunnel@<host>:2022
         curl -XPOST http://127.0.0.1:8404/v1/backends \
              -d '{"domain":"<feature>.staging.<base>","container":"staging-tunnel","https_port":<rport>}'

result:  user ──HTTPS──► haproxy :443 (SNI) ──► staging-tunnel:<rport> ──ssh -R──► laptop backend:443
```

TLS terminates on the laptop backend (haproxy does SNI/TCP passthrough), so the tunnel
carries encrypted traffic only. The concierge side is `docker/staging-tunnel/` +
`scripts/deploy-staging-tunnel.sh` in the concierge repo.

## Deploy (one-time, on the haproxy host)

1. **Add developer keys.** Copy the example and add each developer's public key, locked to
   tunnel-only + the Registration API:

   ```bash
   cp staging-tunnel/authorized_keys.example staging-tunnel/authorized_keys
   # append lines like:
   # restrict,port-forwarding,permitopen="haproxy:8404" ssh-ed25519 AAAA... alice@laptop
   ```

   `staging-tunnel/authorized_keys` is gitignored — never commit it.

2. **Allow the tunnel ports.** `internal-ports.conf` reserves `21000-21099` (allowed for
   registration, **not** published on the host). Apply the allowlist to the running haproxy:

   ```bash
   ./run-haproxy.sh          # re-reads allowed-ports.conf + internal-ports.conf, restarts haproxy
   ```

   > This restarts the shared haproxy briefly. Registered backends persist (state volume),
   > so existing routes are restored automatically. Do it during a quiet window.

3. **Start the endpoint:**

   ```bash
   docker compose up -d --build staging-tunnel
   docker logs staging-tunnel | grep -A1 fingerprint   # copy the SHA256:... host key pin
   ```

   Give each developer: the host (`213.199.61.236`), ssh port (`2022`), the `SHA256:…`
   fingerprint, their private key, and the wildcard cert dir (`*.staging.<base>`).

## Security model

- **Key-only, no shell, no PTY.** `restrict,port-forwarding` disables everything except the
  forwards we need; `permitopen="haproxy:8404"` limits `-L` to the Registration API only.
- **Fail-closed by default.** Even a key added *without* those per-key options can't get a
  shell or reach other services: `sshd_config` sets `ForceCommand /bin/false` (any exec/shell
  request dies; `-N` tunnels are unaffected) and a global `PermitOpen haproxy:8404` (bounds `-L`
  for all keys). Per-key options remain the belt to this braces.
- **Reverse-tunnel bind ports** are bounded by the haproxy `ALLOWED_PORTS` allowlist
  (`21000-21099`) — a port a client binds that no domain is registered to is inert.
- **Trust boundary.** A key-holder gains `haproxy-net` reach to `:8404` and can register
  domains — the same trust the shared haproxy already grants any on-net container. Issue
  per-developer keys and revoke by removing the line. Future hardening: enable
  `HAPROXY_API_KEY` + domain-scoped ACLs (see the ssl-manager DTNP design).
- **Host keys** persist in the `staging-tunnel-hostkeys` volume so the pinned fingerprint is
  stable across restarts.

## Rotate / revoke

- Revoke a developer: delete their line from `authorized_keys`, `docker compose restart staging-tunnel`.
- Rotate host key: `docker volume rm staging-tunnel-hostkeys` then restart (re-distribute the new pin).
