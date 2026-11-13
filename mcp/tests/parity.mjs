// Exercises both MCP transports against isolated workspaces; no network or user data.
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync, readdirSync, readFileSync, renameSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import assert from 'node:assert/strict';

for (const [label, command, args] of [['container', 'node', ['mcp/server/server.mjs', '--stdio']], ['native', '.build/debug/Trelune', ['--mcp']]]) {
  const dir = mkdtempSync(join(tmpdir(), 'trelune-mcp-'));
  writeFileSync(join(dir, 'assistant.json'), JSON.stringify({ enabled: true, allowWrite: true, allowSchedule: true, allowDelete: true }));
  const bridgeDir = join(dir, 'assistant-requests'); mkdirSync(bridgeDir);
  const responder = setInterval(() => {
    for (const file of readdirSync(bridgeDir).filter(f => f.endsWith('.request'))) {
      const path = join(bridgeDir, file);
      try { const req = JSON.parse(readFileSync(path, 'utf8')); renameSync(path, path + '.handled'); writeFileSync(join(bridgeDir, file.replace(/\.request$/, '.response')), JSON.stringify({ ok: true, value: { action: req.action, arguments: req.arguments } })); } catch {}
    }
  }, 25);
  const child = spawn(command, args, { env: { ...process.env, DATA_DIR: dir, TRELUNE_DATA_DIR: dir }, stdio: ['pipe', 'pipe', 'inherit'] });
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  let seq = 0;
  async function request(method, params = {}) {
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: ++seq, method, params }) + '\n');
    const line = await lines.next(); assert.equal(line.done, false, `${label}: server exited`);
    const reply = JSON.parse(line.value); assert.equal(reply.id, seq); return reply.result;
  }
  async function call(name, args) { const response = await request('tools/call', { name, arguments: args }); assert.equal(response.isError, false, response.content[0].text); return JSON.parse(response.content[0].text); }
  try {
    const list = await request('tools/list');
    assert(list.tools.some(t => t.name === 'duplicate_publication'));
    assert(!list.tools.some(t => t.name === 'publish_now'));
    assert(!list.tools.some(t => t.name === 'manage_library'));
    assert.equal((await call('get_insights', { days: 7 })).action, 'get_insights');
    const denied = await request('tools/call', { name: 'publish_now', arguments: { id: 'fake' } });
    assert.equal(denied.isError, true);
    writeFileSync(join(dir, 'assistant.json'), JSON.stringify({ enabled: true, allowWrite: true, allowSchedule: true, allowPublish: true, allowManage: true, allowDelete: true }));
    const enabled = await request('tools/list');
    assert(enabled.tools.some(t => t.name === 'publish_now'));
    assert(enabled.tools.some(t => t.name === 'manage_library'));
    assert.equal((await call('manage_library', { operation: 'remove', path: '/tmp/example.png' })).action, 'manage_library');
    const original = await call('create_draft', { title: 'Teste', text: 'texto', platforms: ['TikTok', 'YouTube'], tags: ['tag'], facebook_page_id: '123', stories: false, tiktok_privacy: 'SELF_ONLY', tiktok_allow_comments: true, tiktok_allow_duet: true, tiktok_allow_stitch: true, tiktok_disclose: true, tiktok_your_brand: true, tiktok_branded: false });
    assert.deepEqual(original.tags, ['tag']); assert.equal(original.stories, false); assert.equal(original.tiktok_allow_duet, true); assert.equal(original.facebook_page_id, '123');
    const updated = await call('update_publication', { id: original.id, tiktok_privacy: 'INBOX', tiktok_allow_comments: false, tags: [] });
    assert.equal(updated.tiktok_privacy, 'INBOX'); assert.equal(updated.tiktok_allow_comments, false); assert.deepEqual(updated.tags, []);
    const copy = await call('duplicate_publication', { id: original.id });
    assert.notEqual(copy.id, original.id); assert.equal(copy.status, 'Rascunho'); assert.equal(copy.tiktok_allow_duet, true); assert.equal(copy.cloud, undefined);
    console.log(`${label}: parity checks passed`);
  } finally { clearInterval(responder); child.stdin.end(); child.kill(); rmSync(dir, { recursive: true, force: true }); }
}
