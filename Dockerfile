FROM haproxy:lts

# haproxy:lts sets USER haproxy — switch back to root for package install
USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends nodejs procps curl socat && \
    rm -rf /var/lib/apt/lists/*

# Config generation tools
COPY generate-config.sh /usr/local/bin/generate-config.sh
COPY templates/ /usr/local/share/haproxy/templates/

# Registration API
COPY registration-api.mjs /usr/local/bin/registration-api.mjs

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/generate-config.sh

# Writable directories for dynamic config
RUN mkdir -p /etc/haproxy/conf.d /etc/haproxy/maps /etc/haproxy/state

# Symlinks from stock HAProxy paths to our custom paths
RUN ln -sf /etc/haproxy/maps /usr/local/etc/haproxy/maps && \
    ln -sf /etc/haproxy/conf.d /usr/local/etc/haproxy/conf.d

EXPOSE 80 443 8000 8404
# Extra ports (e.g., 50001-50004 for Electrum) are published at runtime

HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -sf http://localhost:8404/v1/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
