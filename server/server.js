// Pane sync server: accounts + per-record last-write-wins sync. No dependencies, file-backed.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { promisify } from 'node:util';

const scrypt = promisify(crypto.scrypt);
const PORT = Number(process.env.PORT) || 3400;
const HOST = process.env.HOST || '127.0.0.1';
const DATA_DIR = process.env.DATA_DIR || path.resolve('data');
const MAX_USERS = Number(process.env.MAX_USERS) || 50;
const REGISTER_LIMIT = Number(process.env.REGISTER_LIMIT) || 5;  // per IP per hour
const MAX_BODY = 2 * 1024 * 1024;
const MAX_RECORDS_PER_PUSH = 1000;
const MAX_RECORDS_PER_USER = 20000;
const MAX_PAYLOAD = 16 * 1024;
const SESSION_DAYS = 180;
const TYPES = new Set(['bookmark', 'folder', 'settings', 'login', 'vault']);
const SCRYPT = { N: 32768, r: 8, p: 1, maxmem: 128 * 1024 * 1024 };

fs.mkdirSync(path.join(DATA_DIR, 'users'), { recursive: true });
const DB_FILE = path.join(DATA_DIR, 'accounts.json');

// ---- storage -------------------------------------------------------------------------------

function writeAtomic(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, data, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

let db = { users: {}, sessions: {} };
try { db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8')); } catch { /* first run */ }
const saveDb = () => writeAtomic(DB_FILE, JSON.stringify(db));

// Every account gets a member number in the order people joined (older accounts are numbered by sign-up time).
const nextNumber = () => Object.values(db.users).reduce((m, u) => Math.max(m, u.n || 0), 0) + 1;
(() => {
  let changed = false;
  for (const u of Object.values(db.users).filter((u) => !u.n).sort((a, b) => a.created - b.created)) { u.n = nextNumber(); changed = true; }
  if (changed) saveDb();
})();

const userFile = (id) => path.join(DATA_DIR, 'users', `${id}.json`);
const loadUserData = (id) => { try { return JSON.parse(fs.readFileSync(userFile(id), 'utf8')); } catch { return { seq: 0, records: {} }; } };
const saveUserData = (id, d) => writeAtomic(userFile(id), JSON.stringify(d));

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const normEmail = (e) => String(e || '').trim().toLowerCase();
const validEmail = (e) => e.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e);

// ---- rate limiting ---------------------------------------------------------------------------

const hits = new Map();
function limited(key, max, windowMs) {
  const now = Date.now();
  const h = hits.get(key);
  if (!h || h.reset < now) { hits.set(key, { n: 1, reset: now + windowMs }); return false; }
  h.n += 1;
  return h.n > max;
}
setInterval(() => { const now = Date.now(); for (const [k, h] of hits) if (h.reset < now) hits.delete(k); }, 60_000).unref();

// ---- helpers -----------------------------------------------------------------------------------

class HttpError extends Error { constructor(status, message) { super(message); this.status = status; } }

const HEADERS = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
const send = (res, status, body) => { res.writeHead(status, HEADERS); res.end(JSON.stringify(body)); };

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => { size += c.length; if (size > MAX_BODY) { reject(new HttpError(413, 'Request too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch { reject(new HttpError(400, 'Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

const clientIp = (req) => (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();

async function hashPassword(password, salt) { return (await scrypt(password, salt, 64, SCRYPT)).toString('hex'); }

function issueToken(email) {
  const token = crypto.randomBytes(32).toString('base64url');
  db.sessions[sha(token)] = { email, created: Date.now() };
  saveDb();
  return token;
}

function authenticate(req) {
  const m = /^Bearer (.+)$/.exec(req.headers.authorization || '');
  if (!m) throw new HttpError(401, 'Not signed in');
  const key = sha(m[1]);
  const s = db.sessions[key];
  if (!s || Date.now() - s.created > SESSION_DAYS * 86400_000 || !db.users[s.email]) throw new HttpError(401, 'Session expired');
  return { key, email: s.email, user: db.users[s.email] };
}

// ---- routes --------------------------------------------------------------------------------------

async function register(req, res) {
  const ip = clientIp(req);
  if (limited(`reg:${ip}`, REGISTER_LIMIT, 3600_000)) throw new HttpError(429, 'Too many sign-ups from here. Try again later.');
  const { email: raw, password } = await readJson(req);
  const email = normEmail(raw);
  if (!validEmail(email)) throw new HttpError(400, 'Enter a valid email address.');
  if (typeof password !== 'string' || password.length < 8 || password.length > 200) throw new HttpError(400, 'Use a password of at least 8 characters.');
  if (db.users[email]) throw new HttpError(409, 'An account with this email already exists.');
  if (Object.keys(db.users).length >= MAX_USERS) throw new HttpError(403, 'Sign-ups are closed right now.');
  const salt = crypto.randomBytes(16).toString('hex');
  db.users[email] = { id: crypto.randomUUID(), email, salt, hash: await hashPassword(password, salt), created: Date.now(), n: nextNumber() };
  saveDb();
  send(res, 201, { token: issueToken(email), email });
}

const DUMMY_SALT = crypto.randomBytes(16).toString('hex');

async function login(req, res) {
  const ip = clientIp(req);
  const { email: raw, password } = await readJson(req);
  const email = normEmail(raw);
  if (limited(`login:${ip}`, 10, 600_000) || limited(`login-email:${email}`, 8, 600_000)) {
    throw new HttpError(429, 'Too many attempts. Wait a few minutes and try again.');
  }
  const user = db.users[email];
  // Always do the same work, so timing doesn't reveal whether an email exists.
  const hash = await hashPassword(typeof password === 'string' ? password.slice(0, 200) : '', user ? user.salt : DUMMY_SALT);
  const ok = user && crypto.timingSafeEqual(Buffer.from(hash, 'hex'), Buffer.from(user.hash, 'hex'));
  if (!ok) throw new HttpError(401, 'Wrong email or password.');
  send(res, 200, { token: issueToken(email), email });
}

function me(req, res) {
  const { user } = authenticate(req);
  send(res, 200, { email: user.email, number: user.n, since: user.created });
}

function logout(req, res) {
  const { key } = authenticate(req);
  delete db.sessions[key];
  saveDb();
  send(res, 200, { ok: true });
}

async function deleteAccount(req, res) {
  const { email, user } = authenticate(req);
  const { password } = await readJson(req);
  const hash = await hashPassword(typeof password === 'string' ? password.slice(0, 200) : '', user.salt);
  if (!crypto.timingSafeEqual(Buffer.from(hash, 'hex'), Buffer.from(user.hash, 'hex'))) throw new HttpError(401, 'Wrong password.');
  delete db.users[email];
  for (const [k, s] of Object.entries(db.sessions)) if (s.email === email) delete db.sessions[k];
  saveDb();
  try { fs.unlinkSync(userFile(user.id)); } catch { /* nothing synced yet */ }
  send(res, 200, { ok: true });
}

function pull(req, res, url) {
  const { user } = authenticate(req);
  const since = Math.max(0, Number(url.searchParams.get('since')) || 0);
  const data = loadUserData(user.id);
  const records = Object.values(data.records).filter((r) => r.seq > since).sort((a, b) => a.seq - b.seq).slice(0, 5000);
  send(res, 200, { seq: data.seq, records });
}

// Anonymous crash reports (a few function names and version numbers). Kept as small files; the newest 300 survive.
async function crashReport(req, res) {
  const ip = clientIp(req);
  if (limited(`crash:${ip}`, 5, 3600_000)) throw new HttpError(429, 'Too many reports.');
  const b = await readJson(req);
  const clip = (v, n) => String(v ?? '').slice(0, n);
  const report = {
    app: clip(b.app, 40), system: clip(b.system, 40), kind: clip(b.kind, 80), thread: clip(b.thread, 80), when: clip(b.when, 60),
    frames: Array.isArray(b.frames) ? b.frames.slice(0, 40).map((f) => clip(f, 200)) : [],
    received: new Date().toISOString(),
  };
  const dir = path.join(DATA_DIR, 'crashes');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${Date.now()}-${crypto.randomBytes(3).toString('hex')}.json`), JSON.stringify(report, null, 1), { mode: 0o600 });
  const files = fs.readdirSync(dir).sort();
  for (const f of files.slice(0, Math.max(0, files.length - 300))) fs.unlinkSync(path.join(dir, f));
  send(res, 200, { ok: true });
}

async function push(req, res) {
  const { user } = authenticate(req);
  if (limited(`push:${user.id}`, 120, 60_000)) throw new HttpError(429, 'Syncing too fast. Slow down.');
  const { records } = await readJson(req);
  if (!Array.isArray(records) || records.length > MAX_RECORDS_PER_PUSH) throw new HttpError(400, 'Bad records');
  const data = loadUserData(user.id);
  let applied = 0;
  for (const r of records) {
    if (!r || typeof r.id !== 'string' || r.id.length > 64 || !TYPES.has(r.type)) throw new HttpError(400, 'Bad record');
    const deleted = r.deleted === true;
    const payload = deleted ? '' : r.payload;
    if (typeof payload !== 'string' || payload.length > MAX_PAYLOAD) throw new HttpError(400, 'Bad payload');
    const updatedAt = Number(r.updatedAt);
    if (!Number.isFinite(updatedAt) || updatedAt < 0) throw new HttpError(400, 'Bad time');
    const existing = data.records[r.id];
    if (existing && existing.updatedAt > updatedAt) continue;  // the server already has something newer
    if (!existing && Object.keys(data.records).length >= MAX_RECORDS_PER_USER) throw new HttpError(413, 'Too many synced items');
    data.records[r.id] = { id: r.id, type: r.type, payload, updatedAt, deleted, seq: ++data.seq };
    applied += 1;
  }
  if (applied) saveUserData(user.id, data);
  send(res, 200, { seq: data.seq, applied });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (req.method === 'GET' && url.pathname === '/api/health') return send(res, 200, { ok: true });
    if (req.method === 'POST' && url.pathname === '/api/register') return await register(req, res);
    if (req.method === 'POST' && url.pathname === '/api/login') return await login(req, res);
    if (req.method === 'GET' && url.pathname === '/api/me') return me(req, res);
    if (req.method === 'POST' && url.pathname === '/api/crash') return await crashReport(req, res);
    if (req.method === 'POST' && url.pathname === '/api/logout') return logout(req, res);
    if (req.method === 'POST' && url.pathname === '/api/account/delete') return await deleteAccount(req, res);
    if (req.method === 'GET' && url.pathname === '/api/sync') return pull(req, res, url);
    if (req.method === 'POST' && url.pathname === '/api/sync') return await push(req, res);
    send(res, 404, { error: 'Not found' });
  } catch (e) {
    if (e instanceof HttpError) return send(res, e.status, { error: e.message });
    console.error(e);
    send(res, 500, { error: 'Something went wrong on the server.' });
  }
});

if (process.env.NODE_ENV !== 'test-import') {
  server.listen(PORT, HOST, () => console.log(`pane-sync listening on http://${HOST}:${PORT}`));
}
export { server };
