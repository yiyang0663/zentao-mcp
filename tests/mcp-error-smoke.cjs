#!/usr/bin/env node
'use strict';

const { spawn } = require('child_process');
const path = require('path');

const mode = process.argv[2] || 'unavailable';
const serverFile = path.resolve(process.argv[3] || path.join(__dirname, '..', 'server', 'server.cjs'));
const preload = path.join(__dirname, 'mock-fetch-error.cjs');
const child = spawn(process.execPath, ['-r', preload, serverFile], {
  env: {
    ...process.env,
    ZENTAO_URL: 'http://mock',
    ZENTAO_ACCOUNT: 'smoke',
    ZENTAO_PASSWORD: 'wrong',
    ZENTAO_SMOKE_ERROR_MODE: mode,
  },
  stdio: ['pipe', 'pipe', 'pipe'],
});

let buffer = '';
const timeout = setTimeout(() => {
  child.kill();
  console.error(`${mode} error smoke test timed out`);
  process.exit(1);
}, 8000);

child.stdout.on('data', (chunk) => {
  buffer += chunk.toString();
  const lines = buffer.split(/\r?\n/);
  buffer = lines.pop();
  for (const line of lines) {
    let message;
    try { message = JSON.parse(line); } catch { continue; }
    if (message.id !== 2) continue;
    clearTimeout(timeout);
    if (!message.result?.isError) {
      console.error(`${mode} error was not returned as an MCP error`);
      child.kill();
      process.exit(1);
    }
    console.log(`${mode} error handling ok`);
    child.kill();
  }
});

child.on('error', (error) => {
  clearTimeout(timeout);
  console.error(error.message);
  process.exit(1);
});

const send = (id, method, params) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
send(1, 'initialize', {
  protocolVersion: '2024-11-05',
  capabilities: {},
  clientInfo: { name: 'windows-smoke', version: '1.0.0' },
});
setTimeout(() => send(2, 'tools/call', { name: 'zentao_my_assigned_bugs', arguments: {} }), 100);
