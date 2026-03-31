#!/usr/bin/env node

// HAProxy Dynamic Backend Registration API v1.0
// Single ES module file — zero npm dependencies.
// Uses only Node.js built-in modules.

import { createServer } from 'node:http';
import {
    readFileSync, writeFileSync, renameSync, existsSync, mkdirSync,
    openSync, closeSync, writeSync, unlinkSync, statSync, readdirSync,
    constants as fsConstants
} from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import dns from 'node:dns';

const execFileAsync = promisify(execFile);
const dnsResolve4 = promisify(dns.resolve4);

// ---------------------------------------------------------------------------
// Configuration (from environment)
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.HAPROXY_API_PORT || '8404', 10);
const DOMAINS_MAP = process.env.HAPROXY_DOMAINS_MAP || '/etc/haproxy/domains.map';
const CONF_DIR = process.env.HAPROXY_CONF_DIR || '/etc/haproxy/conf.d';
const MAPS_DIR = process.env.HAPROXY_MAPS_DIR || '/etc/haproxy/maps';
const STATE_DIR = process.env.HAPROXY_STATE_DIR || '/etc/haproxy/state';
const TEMPLATES_DIR = process.env.HAPROXY_TEMPLATES_DIR || '/usr/local/share/haproxy/templates';
const API_KEY = process.env.HAPROXY_API_KEY || '';
const MAX_REGISTRATIONS = parseInt(process.env.MAX_REGISTRATIONS || '100', 10);

const RESERVED_PORTS = new Set([80, 443, 8000, 8404]);
const LOCK_PATH = path.join(STATE_DIR, 'domains.lock');
const REGISTRATIONS_PATH = path.join(STATE_DIR, 'registrations.json');

const DOMAIN_RE = /^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$/;
const CONTAINER_RE = /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/;

const API_START_TIME = Date.now();

// ---------------------------------------------------------------------------
// Global error handler
// ---------------------------------------------------------------------------

process.on('unhandledRejection', (reason) => {
    console.error('[registration-api] Unhandled rejection:', reason);
});

process.on('uncaughtException', (err) => {
    console.error('[registration-api] Uncaught exception:', err);
    process.exit(1);
});

// ---------------------------------------------------------------------------
// Ensure state directory exists
// ---------------------------------------------------------------------------

try { mkdirSync(STATE_DIR, { recursive: true }); } catch {}

// Clean up stale lock file on startup (older than 120s)
try {
    const st = statSync(LOCK_PATH);
    if (Date.now() - st.mtimeMs > 120000) {
        unlinkSync(LOCK_PATH);
        console.log('[registration-api] Removed stale lock file on startup');
    }
} catch {}

// ---------------------------------------------------------------------------
// Helpers: JSON response, body reading
// ---------------------------------------------------------------------------

function sendJson(res, status, data) {
    const body = JSON.stringify(data);
    res.writeHead(status, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)
    });
    res.end(body);
}

function readBody(req, maxBytes = 1048576) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;
        req.on('data', (chunk) => {
            size += chunk.length;
            if (size > maxBytes) {
                reject(new Error('Request body too large'));
                req.destroy();
                return;
            }
            chunks.push(chunk);
        });
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

function checkAuth(req, res) {
    if (!API_KEY) return true;
    const authHeader = req.headers['authorization'] || '';
    if (authHeader === `Bearer ${API_KEY}`) return true;
    sendJson(res, 401, { error: 'Missing or invalid Authorization header', code: 'UNAUTHORIZED' });
    return false;
}

// ---------------------------------------------------------------------------
// File locking
// ---------------------------------------------------------------------------

let lockAcquiredAt = null;

async function acquireLock(deadlineMs = 60000) {
    const deadline = Date.now() + deadlineMs;
    while (true) {
        try {
            const fd = openSync(LOCK_PATH, fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_WRONLY);
            writeSync(fd, String(process.pid));
            closeSync(fd);
            lockAcquiredAt = Date.now();
            return LOCK_PATH;
        } catch (err) {
            if (err.code !== 'EEXIST') throw err;
            if (Date.now() > deadline) throw new Error('Lock acquisition timeout (60s)');
            // Check for stale lock (> 120s old)
            try {
                const st = statSync(LOCK_PATH);
                if (Date.now() - st.mtimeMs > 120000) {
                    unlinkSync(LOCK_PATH);
                    continue;
                }
            } catch {}
            await new Promise(r => setTimeout(r, 200));
        }
    }
}

function releaseLock() {
    lockAcquiredAt = null;
    try { unlinkSync(LOCK_PATH); } catch {}
}

// ---------------------------------------------------------------------------
// domains.map parsing / writing
// ---------------------------------------------------------------------------

function parseDomainsMap() {
    if (!existsSync(DOMAINS_MAP)) return { lines: [], entries: [] };
    const content = readFileSync(DOMAINS_MAP, 'utf8');
    const lines = content.split('\n');
    const entries = [];

    for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) continue;
        const parts = trimmed.split(/\s+/);
        if (parts.length < 4) continue;

        const domain = parts[0];
        const container = parts[1];
        const httpPort = parts[2] === '-' ? null : parseInt(parts[2], 10);
        const httpsPort = parts[3] === '-' ? null : parseInt(parts[3], 10);
        let mapPort = null;
        let extraPorts = null;

        let extraStartIdx = 4;
        if (parts.length > 4) {
            if (parts[4].startsWith('extra:')) {
                extraStartIdx = 4;
                mapPort = null;
            } else {
                mapPort = parts[4] === '-' ? null : parseInt(parts[4], 10);
                extraStartIdx = 5;
            }
        }

        // Parse extra port fields
        for (let i = extraStartIdx; i < parts.length; i++) {
            const field = parts[i];
            if (!field.startsWith('extra:')) continue;
            const segments = field.split(':');
            if (segments.length !== 4) continue;
            if (!extraPorts) extraPorts = [];
            extraPorts.push({
                listen: parseInt(segments[1], 10),
                target: parseInt(segments[2], 10),
                mode: segments[3]
            });
        }

        entries.push({ domain, container, http_port: httpPort, https_port: httpsPort, map_port: mapPort, extra_ports: extraPorts });
    }

    return { lines, entries };
}

function entryToMapLine(entry) {
    const httpCol = entry.http_port != null ? String(entry.http_port) : '-';
    const httpsCol = entry.https_port != null ? String(entry.https_port) : '-';

    let line = `${entry.domain}\t${entry.container}\t${httpCol}\t${httpsCol}`;

    const hasExtra = entry.extra_ports && entry.extra_ports.length > 0;

    if (entry.map_port != null) {
        line += `\t${entry.map_port}`;
    } else if (hasExtra) {
        // Need positional placeholder for map_port when extras follow
        line += '\t-';
    }

    if (hasExtra) {
        for (const ep of entry.extra_ports) {
            line += `\textra:${ep.listen}:${ep.target}:${ep.mode}`;
        }
    }

    return line;
}

function writeDomainsMap(content) {
    const tmpPath = DOMAINS_MAP + '.tmp.' + process.pid;
    writeFileSync(tmpPath, content, 'utf8');
    renameSync(tmpPath, DOMAINS_MAP);
}

// ---------------------------------------------------------------------------
// registrations.json (metadata)
// ---------------------------------------------------------------------------

function readRegistrations() {
    try {
        if (existsSync(REGISTRATIONS_PATH)) {
            return JSON.parse(readFileSync(REGISTRATIONS_PATH, 'utf8'));
        }
    } catch {}
    return {};
}

function writeRegistrations(data) {
    const tmpPath = REGISTRATIONS_PATH + '.tmp.' + process.pid;
    writeFileSync(tmpPath, JSON.stringify(data, null, 2), 'utf8');
    renameSync(tmpPath, REGISTRATIONS_PATH);
}

// ---------------------------------------------------------------------------
// HAProxy process management
// ---------------------------------------------------------------------------

function findHAProxyMasterPid() {
    let procDirs;
    try {
        procDirs = readdirSync('/proc').filter(d => /^\d+$/.test(d));
    } catch {
        return null;
    }
    for (const pid of procDirs) {
        try {
            const comm = readFileSync(`/proc/${pid}/comm`, 'utf8').trim();
            if (comm !== 'haproxy') continue;
            const status = readFileSync(`/proc/${pid}/status`, 'utf8');
            const ppidLine = status.split('\n').find(l => l.startsWith('PPid:'));
            if (ppidLine) {
                const ppid = parseInt(ppidLine.split(/\s+/)[1], 10);
                if (ppid === 0 || ppid === 1) return parseInt(pid, 10);
            }
        } catch {
            continue;
        }
    }
    return null;
}

function getHAProxyWorkerPids(masterPid) {
    const pids = new Set();
    let procDirs;
    try {
        procDirs = readdirSync('/proc').filter(d => /^\d+$/.test(d));
    } catch {
        return pids;
    }
    for (const pid of procDirs) {
        try {
            const comm = readFileSync(`/proc/${pid}/comm`, 'utf8').trim();
            if (comm !== 'haproxy') continue;
            const status = readFileSync(`/proc/${pid}/status`, 'utf8');
            const ppidLine = status.split('\n').find(l => l.startsWith('PPid:'));
            if (ppidLine) {
                const ppid = parseInt(ppidLine.split(/\s+/)[1], 10);
                if (ppid === masterPid) pids.add(parseInt(pid, 10));
            }
        } catch {
            continue;
        }
    }
    return pids;
}

// ---------------------------------------------------------------------------
// Config regeneration, validation, and HAProxy reload
// ---------------------------------------------------------------------------

async function regenerateConfig() {
    await execFileAsync('/usr/local/bin/generate-config.sh', [], {
        timeout: 30000,
        env: {
            ...process.env,
            HAPROXY_CONF_DIR: CONF_DIR,
            HAPROXY_MAPS_DIR: MAPS_DIR,
            HAPROXY_TEMPLATES_DIR: TEMPLATES_DIR,
            HAPROXY_DOMAINS_MAP: DOMAINS_MAP
        }
    });
}

async function validateConfig() {
    await execFileAsync('haproxy', ['-c', '-f', CONF_DIR], { timeout: 30000 });
}

async function reloadHAProxy() {
    const masterPid = findHAProxyMasterPid();
    if (!masterPid) {
        throw new Error('HAProxy master process not found');
    }

    const oldWorkers = getHAProxyWorkerPids(masterPid);
    process.kill(masterPid, 'SIGUSR2');

    // Poll for new worker PIDs (200ms interval, 10s timeout)
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 200));
        const currentWorkers = getHAProxyWorkerPids(masterPid);
        for (const pid of currentWorkers) {
            if (!oldWorkers.has(pid)) {
                return; // New worker found — reload confirmed
            }
        }
    }

    throw new Error('HAProxy reload not confirmed within 10 seconds');
}

// ---------------------------------------------------------------------------
// Debounced reload
// ---------------------------------------------------------------------------

let debounceTimer = null;
let debounceResolvers = [];
let reloadInProgress = false;
let reloadQueued = false;

function scheduleReload() {
    return new Promise((resolve, reject) => {
        debounceResolvers.push({ resolve, reject });
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => executeReload(), 2000);
    });
}

function scheduleImmediateReload() {
    return new Promise((resolve, reject) => {
        debounceResolvers.push({ resolve, reject });
        // Cancel any pending debounce — we're reloading now
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = null;
        executeReload();
    });
}

async function executeReload() {
    debounceTimer = null;

    // If a reload is already in progress, queue another one for when it finishes
    if (reloadInProgress) {
        reloadQueued = true;
        return;
    }

    reloadInProgress = true;
    const resolvers = debounceResolvers.splice(0);
    try {
        await regenerateConfig();
        await validateConfig();
        await reloadHAProxy();
        resolvers.forEach(r => r.resolve());
    } catch (err) {
        console.error('[registration-api] Debounced reload failed:', err.message);
        resolvers.forEach(r => r.reject(err));
    } finally {
        reloadInProgress = false;
        // If another reload was queued while we were busy, run it now
        if (reloadQueued) {
            reloadQueued = false;
            executeReload();
        }
    }
}

// ---------------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------------

function validateDomain(domain) {
    if (typeof domain !== 'string' || !domain) {
        return "Field 'domain' is required";
    }
    if (domain.length > 253) {
        return "Field 'domain' exceeds maximum length of 253 characters";
    }
    if (!DOMAIN_RE.test(domain)) {
        return "Field 'domain' contains invalid characters";
    }
    if (!domain.includes('.')) {
        return "Field 'domain' must contain at least one dot (single-label domains rejected)";
    }
    const labels = domain.split('.');
    for (const label of labels) {
        if (label.length > 63) {
            return `Field 'domain' label '${label}' exceeds maximum length of 63 characters`;
        }
        if (label.length === 0) {
            return "Field 'domain' contains empty label";
        }
    }
    return null;
}

function validateContainer(container) {
    if (typeof container !== 'string' || !container) {
        return "Field 'container' is required";
    }
    if (container.length > 128) {
        return "Field 'container' exceeds maximum length of 128 characters";
    }
    if (!CONTAINER_RE.test(container)) {
        return "Field 'container' contains invalid characters";
    }
    return null;
}

function validatePort(value, fieldName) {
    if (value === null || value === undefined) return null;
    if (typeof value !== 'number' || !Number.isInteger(value) || value < 1 || value > 65535) {
        return `Field '${fieldName}' must be an integer between 1 and 65535, or null`;
    }
    return null;
}

function validateExtraPorts(extraPorts, existingEntries) {
    if (extraPorts === null || extraPorts === undefined) return null;
    if (!Array.isArray(extraPorts)) {
        return { error: "Field 'extra_ports' must be an array or null", code: 'VALIDATION_ERROR' };
    }
    if (extraPorts.length > 10) {
        return { error: "Field 'extra_ports' has more than 10 entries", code: 'VALIDATION_ERROR' };
    }
    for (let i = 0; i < extraPorts.length; i++) {
        const ep = extraPorts[i];
        if (!ep || typeof ep !== 'object') {
            return { error: `extra_ports[${i}] must be an object`, code: 'VALIDATION_ERROR' };
        }
        if (typeof ep.listen !== 'number' || !Number.isInteger(ep.listen) || ep.listen < 1 || ep.listen > 65535) {
            return { error: `extra_ports[${i}].listen must be an integer between 1 and 65535`, code: 'VALIDATION_ERROR' };
        }
        if (RESERVED_PORTS.has(ep.listen)) {
            return { error: `extra_ports[${i}].listen port ${ep.listen} is reserved (80, 443, 8000, 8404)`, code: 'VALIDATION_ERROR' };
        }
        if (typeof ep.target !== 'number' || !Number.isInteger(ep.target) || ep.target < 1 || ep.target > 65535) {
            return { error: `extra_ports[${i}].target must be an integer between 1 and 65535`, code: 'VALIDATION_ERROR' };
        }
        if (ep.mode !== 'http' && ep.mode !== 'tcp') {
            return { error: `extra_ports[${i}].mode must be "http" or "tcp"`, code: 'VALIDATION_ERROR' };
        }
    }

    // Check MODE_CONFLICT across all existing registrations
    // Build a map of listen_port -> mode from all existing entries
    const portModes = new Map();
    for (const entry of existingEntries) {
        if (!entry.extra_ports) continue;
        for (const ep of entry.extra_ports) {
            portModes.set(ep.listen, ep.mode);
        }
    }

    for (const ep of extraPorts) {
        const existingMode = portModes.get(ep.listen);
        if (existingMode && existingMode !== ep.mode) {
            return {
                error: `Listen port ${ep.listen} already registered with mode '${existingMode}', cannot register with mode '${ep.mode}'`,
                code: 'MODE_CONFLICT'
            };
        }
    }

    return null;
}

function entriesMatch(a, b) {
    if (a.container !== b.container) return false;
    if (a.http_port !== b.http_port) return false;
    if (a.https_port !== b.https_port) return false;
    if (a.map_port !== b.map_port) return false;

    const aExtra = a.extra_ports || null;
    const bExtra = b.extra_ports || null;

    if (aExtra === null && bExtra === null) return true;
    if (aExtra === null || bExtra === null) return false;
    if (aExtra.length !== bExtra.length) return false;

    for (let i = 0; i < aExtra.length; i++) {
        if (aExtra[i].listen !== bExtra[i].listen) return false;
        if (aExtra[i].target !== bExtra[i].target) return false;
        if (aExtra[i].mode !== bExtra[i].mode) return false;
    }
    return true;
}

function entryToResponse(entry, registrations) {
    const meta = registrations[entry.domain];
    return {
        domain: entry.domain,
        container: entry.container,
        http_port: entry.http_port,
        https_port: entry.https_port,
        map_port: entry.map_port || null,
        extra_ports: entry.extra_ports || null,
        created_at: meta?.created_at || null
    };
}

// ---------------------------------------------------------------------------
// Container ownership verification (for DELETE without API_KEY)
// ---------------------------------------------------------------------------

async function verifyOwnership(req, containerName) {
    if (API_KEY) return true; // Authenticated requests bypass ownership check
    let sourceIp = req.socket.remoteAddress || '';
    sourceIp = sourceIp.replace(/^::ffff:/, '');
    try {
        const addresses = await dnsResolve4(containerName);
        return addresses.includes(sourceIp);
    } catch {
        // DNS resolution failed — the registered container is likely dead/removed.
        // Allow the DELETE so new containers can take over stale domain registrations.
        console.log(`[registration-api] Ownership check: container '${containerName}' not resolvable (dead?) — allowing operation`);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Endpoint handlers
// ---------------------------------------------------------------------------

async function handleRegister(req, res) {
    if (!checkAuth(req, res)) return;

    // Validate Content-Type
    const ct = (req.headers['content-type'] || '').toLowerCase();
    if (!ct.includes('application/json')) {
        return sendJson(res, 400, { error: 'Content-Type must be application/json', code: 'VALIDATION_ERROR' });
    }

    // Read and parse body
    let body;
    try {
        const raw = await readBody(req);
        body = JSON.parse(raw);
    } catch (err) {
        return sendJson(res, 400, { error: 'Invalid JSON in request body', code: 'VALIDATION_ERROR' });
    }

    if (!body || typeof body !== 'object') {
        return sendJson(res, 400, { error: 'Request body must be a JSON object', code: 'VALIDATION_ERROR' });
    }

    // Validate domain
    const domainErr = validateDomain(body.domain);
    if (domainErr) {
        return sendJson(res, 422, { error: domainErr, code: 'VALIDATION_ERROR' });
    }

    // Validate container
    const containerErr = validateContainer(body.container);
    if (containerErr) {
        return sendJson(res, 422, { error: containerErr, code: 'VALIDATION_ERROR' });
    }

    // Apply defaults and validate ports
    const httpPort = body.http_port === undefined ? 80 : body.http_port;
    const httpsPort = body.https_port === undefined ? 443 : body.https_port;
    const mapPort = body.map_port === undefined ? null : body.map_port;
    const extraPorts = body.extra_ports === undefined ? null : body.extra_ports;

    for (const [val, name] of [[httpPort, 'http_port'], [httpsPort, 'https_port'], [mapPort, 'map_port']]) {
        const err = validatePort(val, name);
        if (err) return sendJson(res, 422, { error: err, code: 'VALIDATION_ERROR' });
    }

    if (httpPort === null && httpsPort === null) {
        return sendJson(res, 422, { error: 'At least one of http_port or https_port must be non-null', code: 'VALIDATION_ERROR' });
    }

    const newEntry = {
        domain: body.domain,
        container: body.container,
        http_port: httpPort,
        https_port: httpsPort,
        map_port: mapPort,
        extra_ports: extraPorts
    };

    // Acquire lock and read current state
    let lockHeld = false;
    try {
        await acquireLock();
        lockHeld = true;

        const { entries } = parseDomainsMap();

        // Check MAX_REGISTRATIONS
        const existingIdx = entries.findIndex(e => e.domain === newEntry.domain);
        const currentCount = entries.length;
        if (existingIdx === -1 && currentCount >= MAX_REGISTRATIONS) {
            releaseLock();
            lockHeld = false;
            return sendJson(res, 429, { error: `Maximum registration limit (${MAX_REGISTRATIONS}) reached`, code: 'LIMIT_EXCEEDED' });
        }

        // Validate extra_ports (needs existing entries for MODE_CONFLICT check)
        // Exclude the current domain's entry from conflict checks (allow self-update)
        const otherEntries = entries.filter(e => e.domain !== newEntry.domain);
        const extraErr = validateExtraPorts(extraPorts, otherEntries);
        if (extraErr) {
            releaseLock();
            lockHeld = false;
            const statusCode = extraErr.code === 'MODE_CONFLICT' ? 409 : 422;
            return sendJson(res, statusCode, extraErr);
        }

        // Check for existing entry with same domain
        if (existingIdx !== -1) {
            const existing = entries[existingIdx];
            if (entriesMatch(existing, newEntry)) {
                // Idempotent match — no changes needed
                releaseLock();
                lockHeld = false;
                const registrations = readRegistrations();
                const resp = entryToResponse(existing, registrations);
                resp.message = 'Already registered with identical configuration';
                return sendJson(res, 200, resp);
            }
            if (existing.container === newEntry.container) {
                // Same container, different config — update the registration
                entries[existingIdx] = newEntry;
                const updatedLines = [];
                const rawLines = (existsSync(DOMAINS_MAP) ? readFileSync(DOMAINS_MAP, 'utf8') : '').split('\n');
                for (const rawLine of rawLines) {
                    const trimmed = rawLine.trim();
                    if (!trimmed || trimmed.startsWith('#')) {
                        updatedLines.push(rawLine);
                        continue;
                    }
                    const parts = trimmed.split(/\s+/);
                    if (parts[0] === newEntry.domain) {
                        updatedLines.push(entryToMapLine(newEntry));
                    } else {
                        updatedLines.push(rawLine);
                    }
                }
                writeDomainsMap(updatedLines.join('\n'));

                const registrations = readRegistrations();
                releaseLock();
                lockHeld = false;

                // Schedule debounced reload
                try {
                    await scheduleReload();
                } catch (reloadErr) {
                    console.error('[registration-api] Reload after update failed:', reloadErr.message);
                    return sendJson(res, 500, {
                        error: `HAProxy reload failed: ${reloadErr.message}`,
                        code: 'RELOAD_FAILED'
                    });
                }

                const resp = entryToResponse(newEntry, registrations);
                resp.message = 'Registration updated';
                return sendJson(res, 200, resp);
            }
            // Different container — conflict
            releaseLock();
            lockHeld = false;
            const registrations = readRegistrations();
            return sendJson(res, 409, {
                error: `Domain '${newEntry.domain}' is already registered to container '${existing.container}' (HTTP:${existing.http_port}, HTTPS:${existing.https_port})`,
                code: 'DOMAIN_CONFLICT',
                existing: entryToResponse(existing, registrations)
            });
        }

        // New registration: read raw file, remove any stale entries for this domain,
        // then append the new line. This deduplicates in case of previous bugs or
        // manual edits that left duplicate entries.
        const rawContent = existsSync(DOMAINS_MAP) ? readFileSync(DOMAINS_MAP, 'utf8') : '';
        const backupContent = rawContent;
        const newLine = entryToMapLine(newEntry);
        const dedupedLines = rawContent.split('\n').filter(line => {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith('#')) return true;
            return trimmed.split(/\s+/)[0] !== newEntry.domain;
        });
        const dedupedContent = dedupedLines.join('\n');
        const updatedContent = dedupedContent.endsWith('\n') || dedupedContent === ''
            ? dedupedContent + newLine + '\n'
            : dedupedContent + '\n' + newLine + '\n';

        writeDomainsMap(updatedContent);

        // Update registrations metadata
        const registrations = readRegistrations();
        const now = new Date().toISOString();
        registrations[newEntry.domain] = { created_at: now, registered_by: 'api' };
        writeRegistrations(registrations);

        // Release lock before debounced reload (per spec Section 10.5 step 3)
        releaseLock();
        lockHeld = false;

        // Schedule debounced reload — no per-request rollback after lock release;
        // the debounce handler manages its own recovery.
        try {
            await scheduleReload();
        } catch (reloadErr) {
            console.error('[registration-api] Reload failed:', reloadErr.message);
            return sendJson(res, 500, {
                error: `HAProxy reload failed: ${reloadErr.message}`,
                code: 'RELOAD_FAILED'
            });
        }

        const resp = entryToResponse(newEntry, registrations);
        return sendJson(res, 201, resp);

    } catch (err) {
        if (lockHeld) releaseLock();
        console.error('[registration-api] Register error:', err);
        return sendJson(res, 500, { error: `Internal server error: ${err.message}`, code: 'INTERNAL_ERROR' });
    }
}

async function handleList(req, res) {
    if (!checkAuth(req, res)) return;

    try {
        const { entries } = parseDomainsMap();
        const registrations = readRegistrations();
        const backends = entries.map(e => entryToResponse(e, registrations));
        return sendJson(res, 200, { backends, count: backends.length });
    } catch (err) {
        console.error('[registration-api] List error:', err);
        return sendJson(res, 500, { error: 'Internal server error', code: 'INTERNAL_ERROR' });
    }
}

async function handleGet(req, res, domain) {
    if (!checkAuth(req, res)) return;

    try {
        const { entries } = parseDomainsMap();
        const entry = entries.find(e => e.domain === domain);
        if (!entry) {
            return sendJson(res, 404, { error: `No registration found for domain '${domain}'`, code: 'NOT_FOUND' });
        }
        const registrations = readRegistrations();
        return sendJson(res, 200, entryToResponse(entry, registrations));
    } catch (err) {
        console.error('[registration-api] Get error:', err);
        return sendJson(res, 500, { error: 'Internal server error', code: 'INTERNAL_ERROR' });
    }
}

async function handleDelete(req, res, domain) {
    if (!checkAuth(req, res)) return;

    let lockHeld = false;
    try {
        // Read current state first (before lock) to check existence and ownership
        const { entries } = parseDomainsMap();
        const entry = entries.find(e => e.domain === domain);
        if (!entry) {
            return sendJson(res, 404, { error: `No registration found for domain '${domain}'`, code: 'NOT_FOUND' });
        }

        // Container ownership verification (when API_KEY not set)
        const owned = await verifyOwnership(req, entry.container);
        if (!owned) {
            return sendJson(res, 403, {
                error: 'Only the registered container can delete this domain',
                code: 'OWNERSHIP_MISMATCH'
            });
        }

        await acquireLock();
        lockHeld = true;

        // Re-read under lock
        const rawContent = readFileSync(DOMAINS_MAP, 'utf8');
        const backupContent = rawContent;
        const lines = rawContent.split('\n');
        const filteredLines = [];

        for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith('#')) {
                filteredLines.push(line);
                continue;
            }
            const parts = trimmed.split(/\s+/);
            if (parts[0] === domain) continue; // Remove this entry
            filteredLines.push(line);
        }

        writeDomainsMap(filteredLines.join('\n'));

        // Remove from registrations metadata
        const registrations = readRegistrations();
        delete registrations[domain];
        writeRegistrations(registrations);

        releaseLock();
        lockHeld = false;

        // Schedule debounced reload — no per-request rollback after lock release
        try {
            await scheduleReload();
        } catch (reloadErr) {
            console.error('[registration-api] Reload after delete failed:', reloadErr.message);
            return sendJson(res, 500, {
                error: `HAProxy reload failed: ${reloadErr.message}`,
                code: 'RELOAD_FAILED'
            });
        }

        res.writeHead(204);
        res.end();
    } catch (err) {
        if (lockHeld) releaseLock();
        console.error('[registration-api] Delete error:', err);
        return sendJson(res, 500, { error: `Internal server error: ${err.message}`, code: 'INTERNAL_ERROR' });
    }
}

async function handleReload(req, res) {
    if (!checkAuth(req, res)) return;

    try {
        // Use the same debounced reload path as registration/deletion.
        // This ensures no concurrent generate-config.sh executions.
        // Setting timeout to 0 triggers immediate reload (no debounce wait).
        await scheduleImmediateReload();

        const { entries } = parseDomainsMap();

        return sendJson(res, 200, {
            message: 'Configuration regenerated and HAProxy reloaded',
            backends_count: entries.length,
            reload_timestamp: new Date().toISOString()
        });
    } catch (err) {
        console.error('[registration-api] Reload error:', err);
        return sendJson(res, 500, {
            error: `HAProxy configuration check failed: ${err.message}`,
            code: 'RELOAD_FAILED'
        });
    }
}

async function handleHealth(req, res) {
    // Health endpoint is exempt from authentication
    try {
        const masterPid = findHAProxyMasterPid();
        const { entries } = parseDomainsMap();

        if (!masterPid) {
            return sendJson(res, 503, {
                status: 'unhealthy',
                error: 'HAProxy master process not found',
                api_version: '1.0'
            });
        }

        // Calculate uptime
        let haproxyUptime = null;
        try {
            const statContent = readFileSync(`/proc/${masterPid}/stat`, 'utf8');
            const fields = statContent.split(' ');
            // Field 22 (0-indexed: 21) is starttime in clock ticks
            const startTicks = parseInt(fields[21], 10);
            const uptimeContent = readFileSync('/proc/uptime', 'utf8');
            const systemUptime = parseFloat(uptimeContent.split(' ')[0]);
            // Clock ticks per second
            const hz = 100; // Standard on Linux
            const processStartSec = startTicks / hz;
            haproxyUptime = Math.floor(systemUptime - processStartSec);
        } catch {}

        // Check lock status for degraded state
        let status = 'healthy';
        let warning = undefined;
        try {
            const st = statSync(LOCK_PATH);
            const lockAge = Date.now() - st.mtimeMs;
            if (lockAge > 30000) {
                status = 'degraded';
                warning = `File lock held for ${Math.floor(lockAge / 1000)} seconds, possible stuck operation`;
            }
        } catch {
            // No lock file — lock is free, status is healthy
        }

        const resp = {
            status,
            haproxy_pid: masterPid,
            api_version: '1.0',
            backends_count: entries.length
        };

        if (haproxyUptime !== null) {
            resp.haproxy_uptime_seconds = haproxyUptime;
        }

        if (warning) {
            resp.warning = warning;
        }

        return sendJson(res, 200, resp);
    } catch (err) {
        console.error('[registration-api] Health check error:', err);
        return sendJson(res, 500, {
            status: 'unhealthy',
            error: `Health check failed: ${err.message}`,
            api_version: '1.0'
        });
    }
}

// ---------------------------------------------------------------------------
// HTTP server and routing
// ---------------------------------------------------------------------------

const server = createServer(async (req, res) => {
    try {
        const url = new URL(req.url, `http://localhost:${PORT}`);
        const pathname = url.pathname;

        if (req.method === 'POST' && pathname === '/v1/backends') {
            await handleRegister(req, res);
        } else if (req.method === 'GET' && pathname === '/v1/backends') {
            await handleList(req, res);
        } else if (req.method === 'GET' && pathname.startsWith('/v1/backends/')) {
            const domain = decodeURIComponent(pathname.slice('/v1/backends/'.length));
            if (!domain) {
                sendJson(res, 400, { error: 'Domain parameter is required', code: 'VALIDATION_ERROR' });
            } else {
                await handleGet(req, res, domain);
            }
        } else if (req.method === 'DELETE' && pathname.startsWith('/v1/backends/')) {
            const domain = decodeURIComponent(pathname.slice('/v1/backends/'.length));
            if (!domain) {
                sendJson(res, 400, { error: 'Domain parameter is required', code: 'VALIDATION_ERROR' });
            } else {
                await handleDelete(req, res, domain);
            }
        } else if (req.method === 'POST' && pathname === '/v1/reload') {
            await handleReload(req, res);
        } else if (req.method === 'GET' && pathname === '/v1/health') {
            await handleHealth(req, res);
        } else {
            sendJson(res, 404, { error: 'Not found', code: 'NOT_FOUND' });
        }
    } catch (err) {
        console.error('[registration-api] Unhandled request error:', err);
        if (!res.headersSent) {
            sendJson(res, 500, { error: 'Internal server error', code: 'INTERNAL_ERROR' });
        }
    }
});

server.listen(PORT, () => {
    console.log(`[registration-api] Registration API v1.0 listening on port ${PORT}`);
    console.log(`[registration-api] domains.map: ${DOMAINS_MAP}`);
    console.log(`[registration-api] conf.d: ${CONF_DIR}`);
    console.log(`[registration-api] Authentication: ${API_KEY ? 'enabled' : 'disabled'}`);
    console.log(`[registration-api] Max registrations: ${MAX_REGISTRATIONS}`);
});
