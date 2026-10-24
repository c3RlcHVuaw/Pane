import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pane-sync-'));
const port = 3490 + Math.floor(Math.random() * 100);
const base = `http://127.0.0.1:${port}`;
let proc;

test.before(async () => {
  proc = spawn('node', ['server.js'], { env: { ...process.env, PORT: String(port), DATA_DIR: dir, MAX_USERS: '3', REGISTER_LIMIT: '100' }, stdio: 'ignore' });
  for (let i = 0; i < 50; i++) { try { await fetch(`${base}/api/health`); return; } catch { await new Promise((r) => setTimeout(r, 100)); } }
});
test.after(() => proc.kill());

const call = async (method, p, body, token) => {
  const r = await fetch(base + p, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, body: await r.json() };
};

test('register, duplicate, validation', async () => {
  assert.equal((await call('POST', '/api/register', { email: 'bad', password: 'longenough' })).status, 400);
  assert.equal((await call('POST', '/api/register', { email: 'a@b.co', password: 'short' })).status, 400);
  const ok = await call('POST', '/api/register', { email: 'A@B.co', password: 'password123' });
  assert.equal(ok.status, 201);
  assert.equal(ok.body.email, 'a@b.co');
  assert.equal((await call('POST', '/api/register', { email: 'a@b.co', password: 'password123' })).status, 409);
});

test('login: wrong password and unknown email look the same', async () => {
  const wrong = await call('POST', '/api/login', { email: 'a@b.co', password: 'nope-nope' });
  const unknown = await call('POST', '/api/login', { email: 'ghost@b.co', password: 'nope-nope' });
  assert.equal(wrong.status, 401);
  assert.deepEqual(wrong.body, unknown.body);
  const ok = await call('POST', '/api/login', { email: 'a@b.co', password: 'password123' });
  assert.equal(ok.status, 200);
  assert.ok(ok.body.token.length > 30);
});

test('sync needs a token and applies last-write-wins', async () => {
  assert.equal((await call('GET', '/api/sync')).status, 401);
  const { body: { token } } = await call('POST', '/api/login', { email: 'a@b.co', password: 'password123' });
  const rec = (id, t, payload, deleted = false) => ({ id, type: 'bookmark', payload, updatedAt: t, deleted });
  let r = await call('POST', '/api/sync', { records: [rec('x', 100, '{"v":1}'), rec('y', 100, '{"v":1}')] }, token);
  assert.equal(r.body.applied, 2);
  r = await call('POST', '/api/sync', { records: [rec('x', 50, '{"v":"old"}')] }, token);
  assert.equal(r.body.applied, 0, 'older edit is ignored');
  r = await call('POST', '/api/sync', { records: [rec('x', 200, '{"v":2}'), rec('y', 300, '', true)] }, token);
  assert.equal(r.body.applied, 2);
  const all = await call('GET', '/api/sync?since=0', null, token);
  const byId = Object.fromEntries(all.body.records.map((x) => [x.id, x]));
  assert.equal(byId.x.payload, '{"v":2}');
  assert.equal(byId.y.deleted, true);
  const delta = await call('GET', `/api/sync?since=${r.body.seq - 2}`, null, token);
  assert.equal(delta.body.records.length, 2, 'cursor returns only newer changes');
});

test('rejects bad records', async () => {
  const { body: { token } } = await call('POST', '/api/login', { email: 'a@b.co', password: 'password123' });
  assert.equal((await call('POST', '/api/sync', { records: [{ id: 'z', type: 'evil', payload: '{}', updatedAt: 1 }] }, token)).status, 400);
  assert.equal((await call('POST', '/api/sync', { records: [{ id: 'z', type: 'bookmark', payload: 'x'.repeat(20000), updatedAt: 1 }] }, token)).status, 400);
});

test('accounts are isolated', async () => {
  const b = await call('POST', '/api/register', { email: 'b@b.co', password: 'password123' });
  const r = await call('GET', '/api/sync?since=0', null, b.body.token);
  assert.equal(r.body.records.length, 0);
});

test('logout invalidates the token; delete needs the password', async () => {
  const { body: { token } } = await call('POST', '/api/login', { email: 'b@b.co', password: 'password123' });
  assert.equal((await call('POST', '/api/logout', {}, token)).status, 200);
  assert.equal((await call('GET', '/api/sync', null, token)).status, 401);
  const { body: { token: t2 } } = await call('POST', '/api/login', { email: 'b@b.co', password: 'password123' });
  assert.equal((await call('POST', '/api/account/delete', { password: 'wrong-wrong' }, t2)).status, 401);
  assert.equal((await call('POST', '/api/account/delete', { password: 'password123' }, t2)).status, 200);
  assert.equal((await call('POST', '/api/login', { email: 'b@b.co', password: 'password123' })).status, 401);
});

test('sign-up cap', async () => {
  await call('POST', '/api/register', { email: 'c@b.co', password: 'password123' });
  await call('POST', '/api/register', { email: 'e@b.co', password: 'password123' });  // a, c, e = the cap of 3
  const d = await call('POST', '/api/register', { email: 'd@b.co', password: 'password123' });
  assert.equal(d.status, 403);
});
