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
        # HTTP on port 80: node HTTP server
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
