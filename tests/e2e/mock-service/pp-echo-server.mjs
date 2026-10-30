// PROXY-v2-aware echo backend for the haproxy e2e suite.
//
//   :80    HTTP  -- PROXY v2 header optional; replies JSON {pp, src, peer, xff}
//   :8445  TCP   -- PROXY v2 header optional, then TLS (self-signed); replies the
//                   same JSON over TLS (models ssl-manager's TLS shim + app)
//   :50005 TCP   -- PROXY v2 header optional, then plain text echo of the JSON
//
// "pp" says whether a PROXY v2 header was received, "src" is the client address
// it carried (or null), "peer" is the TCP peer (haproxy). A header is accepted
// from anyone here: this mock models the *receiving* side only, trust policy is
// tested in ssl-manager.

import net from 'node:net';
import tls from 'node:tls';
import fs from 'node:fs';

const SIG = Buffer.from('0d0a0d0a000d0a515549540a', 'hex');

function parseHeader(buf) {
    // returns {state:'need'|'none'|'pp'|'bad', len, src}
    const n = Math.min(buf.length, 12);
    if (n === 0) return { state: 'need' };
    if (!buf.subarray(0, n).equals(SIG.subarray(0, n))) return { state: 'none' };
    if (buf.length < 16) return { state: 'need' };
    const verCmd = buf[12];
    if (verCmd >> 4 !== 2) return { state: 'bad' };
    const fam = buf[13] >> 4;
    const len = buf.readUInt16BE(14);
    if (buf.length < 16 + len) return { state: 'need' };
    let src = null;
    if ((verCmd & 0xf) === 1 && fam === 1 && len >= 12) {
        src = Array.from(buf.subarray(16, 20)).join('.') + ':' + buf.readUInt16BE(24);
    } else if ((verCmd & 0xf) === 1 && fam === 2 && len >= 36) {
        const p = [];
        for (let i = 0; i < 16; i += 2) p.push(buf.readUInt16BE(16 + i).toString(16));
        src = '[' + p.join(':') + ']:' + buf.readUInt16BE(48);
    }
    return { state: 'pp', len: 16 + len, src, local: (verCmd & 0xf) === 0 };
}

// Read an optional PROXY header, then hand (info, rest) to cb.
function withHeader(sock, cb) {
    let buf = Buffer.alloc(0);
    let done = false;
    const onData = (d) => {
        buf = Buffer.concat([buf, d]);
        const r = parseHeader(buf);
        if (r.state === 'need') return;
        done = true;
        sock.removeListener('data', onData);
        sock.pause();
        if (r.state === 'bad') return sock.destroy();
        if (r.state === 'none') return cb({ pp: false, src: null }, buf);
        // haproxy health checks (check-send-proxy) arrive as LOCAL headers; log them
        // so the e2e can prove the checks really carry the header.
        if (r.local) console.log(`LOCAL-header port=${sock.localPort}`);
        return cb({ pp: true, src: r.src, local: r.local }, buf.subarray(r.len));
    };
    sock.on('data', onData);
    sock.on('error', () => {});
    setTimeout(() => { if (!done) sock.destroy(); }, 5000).unref();
}

const report = (info, peer, extra = {}) => JSON.stringify({ pp: info.pp, local: !!info.local, src: info.src, peer, ...extra });

// :80 HTTP (one request per connection is enough for tests)
net.createServer((sock) => {
    const peer = `${sock.remoteAddress}:${sock.remotePort}`;
    withHeader(sock, (info, rest) => {
        let req = rest;
        const finish = () => {
            const text = req.toString('latin1');
            const m = /\r\nx-forwarded-for:\s*([^\r\n]*)/i.exec(text);
            const body = report(info, peer, { xff: m ? m[1] : null }) + '\n';
            sock.end(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`);
        };
        if (req.includes('\r\n\r\n')) return finish();
        sock.on('data', (d) => { req = Buffer.concat([req, d]); if (req.includes('\r\n\r\n')) finish(); });
        sock.resume();
    });
}).listen(80, () => console.log('pp-echo http :80'));

// :8445 PROXY then TLS. Node cannot reliably start TLS on a socket whose first
// bytes were already read in JS, so the (header-stripped) stream is piped to an
// internal TLS server; the PROXY info travels via a local-port lookup table.
const key = fs.readFileSync('/tmp/key.pem');
const cert = fs.readFileSync('/tmp/cert.pem');
const pending = new Map(); // internal client local port -> {info, peer}
const inner = tls.createServer({ key, cert }, (t) => {
    const meta = pending.get(t.remotePort) || { info: { pp: false, src: null }, peer: null };
    pending.delete(t.remotePort);
    t.on('error', () => {});
    t.once('data', () => {
        const body = report(meta.info, meta.peer, { tls: true }) + '\n';
        t.end(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`);
    });
}).listen(8446, '127.0.0.1');
net.createServer((raw) => {
    const peer = `${raw.remoteAddress}:${raw.remotePort}`;
    withHeader(raw, (info, rest) => {
        const up = net.connect(8446, '127.0.0.1', () => {
            pending.set(up.localPort, { info, peer });
            if (rest.length) up.write(rest);
            raw.pipe(up); up.pipe(raw);
            raw.resume();
        });
        up.on('error', () => raw.destroy());
        raw.on('close', () => up.destroy());
    });
}).listen(8445, () => console.log('pp-echo tls :8445'));

// :50005 PROXY then plain TCP
net.createServer((sock) => {
    const peer = `${sock.remoteAddress}:${sock.remotePort}`;
    withHeader(sock, (info) => { sock.end(report(info, peer) + '\n'); });
}).listen(50005, () => console.log('pp-echo tcp :50005'));
