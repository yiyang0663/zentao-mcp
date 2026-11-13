#!/usr/bin/env node
'use strict';

const { spawn } = require('child_process');
const path = require('path');

const serverFile = path.resolve(process.argv[2] || path.join(__dirname, '..', 'server', 'server.cjs'));
const expected = new Set([
  'zentao_my_assigned_bugs',
  'zentao_create_bug',
  'zentao_resolve_bug',
  'zentao_assign_bug',
  'zentao_reopen_bug',
  'zentao_verify_bug_update',
]);

const child = spawn(process.execPath, [serverFile], {
  env: { ...process.env, ZENTAO_URL: 'http://127.0.0.1:9', ZENTAO_ACCOUNT: 'smoke', ZENTAO_PASSWORD: 'smoke' },
  stdio: ['pipe', 'pipe', 'pipe'],
});

let stdout = '';
let response = null;
const timer = setTimeout(() => {
  child.kill();
  console.error('tools/list smoke test timed out');
  process.exit(1);
}, 8000);

child.stdout.on('data', (chunk) => {
  stdout += chunk.toString();
  for (const line of stdout.split(/\r?\n/).slice(0, -1)) {
    try {
      const message = JSON.parse(line);
      if (message.id === 2) response = message;
    } catch {
      // Ignore partial or diagnostic lines; the MCP transport uses JSON lines.
    }
  }
  stdout = stdout.slice(stdout.lastIndexOf('\n') + 1);
  if (response) {
    clearTimeout(timer);
    const names = new Set((response.result?.tools || []).map((tool) => tool.name));
    const missing = [...expected].filter((name) => !names.has(name));
    if (missing.length) {
      console.error(`Missing tools: ${missing.join(', ')}`);
      child.kill();
      process.exit(1);
    }
    console.log(`tools/list ok: ${[...expected].join(', ')}`);
    child.kill();
  }
});

child.on('error', (error) => {
  clearTimeout(timer);
  console.error(error.message);
  process.exit(1);
});

const send = (id, method, params) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
send(1, 'initialize', {
  protocolVersion: '2024-11-05',
  capabilities: {},
  clientInfo: { name: 'windows-smoke', version: '1.0.0' },
});
setTimeout(() => send(2, 'tools/list', {}), 100);
