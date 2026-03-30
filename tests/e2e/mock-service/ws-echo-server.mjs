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
