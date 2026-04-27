import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

import { debugLog, makeDebugLogger } from '../../src/node/util/debug-log.mjs';

test('debugLog: writes [TIMESTAMP] [CATEGORY] key=value line', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-debug-'));
  const logPath = path.join(dir, 'debug.log');
  await debugLog({
    debugLogPath: logPath,
    category: 'OPTION',
    fields: { slug: 'test', cb_threshold: 6 },
  });
  const content = await fs.readFile(logPath, 'utf8');
  assert.match(content, /^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[OPTION\] slug=test cb_threshold=6\n$/);
  await fs.rm(dir, { recursive: true });
});

test('debugLog: rejects unknown category silently', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-debug-'));
  const logPath = path.join(dir, 'debug.log');
  await debugLog({ debugLogPath: logPath, category: 'INVALID', fields: { x: 1 } });
  // Should not have created the file.
  await assert.rejects(fs.access(logPath));
  await fs.rm(dir, { recursive: true });
});

test('debugLog: missing debugLogPath silently returns', async () => {
  await assert.doesNotReject(debugLog({ category: 'GOV', fields: {} }));
});

test('debugLog: appends multiple entries', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-debug-'));
  const logPath = path.join(dir, 'debug.log');
  const log = makeDebugLogger(logPath);
  await log('FLOW', { phase: 'start' });
  await log('FLOW', { phase: 'worker_dispatch', us_id: 'US-001' });
  await log('GOV', { rule: 'CB', count: 3 });
  const content = await fs.readFile(logPath, 'utf8');
  const lines = content.trim().split('\n');
  assert.equal(lines.length, 3);
  assert.match(lines[0], /\[FLOW\] phase=start/);
  assert.match(lines[1], /\[FLOW\] phase=worker_dispatch us_id=US-001/);
  assert.match(lines[2], /\[GOV\] rule=CB count=3/);
  await fs.rm(dir, { recursive: true });
});

test('debugLog: values with spaces or = are JSON-quoted', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-debug-'));
  const logPath = path.join(dir, 'debug.log');
  await debugLog({
    debugLogPath: logPath,
    category: 'DECIDE',
    fields: { reason: 'has spaces here', equation: 'a=b' },
  });
  const content = await fs.readFile(logPath, 'utf8');
  assert.match(content, /reason="has spaces here"/);
  assert.match(content, /equation="a=b"/);
  await fs.rm(dir, { recursive: true });
});

test('debugLog: filesystem error swallowed (best-effort)', async () => {
  // Path includes /dev/null/x which always fails.
  await assert.doesNotReject(debugLog({
    debugLogPath: '/dev/null/cannot/mkdir/here',
    category: 'GOV',
    fields: { x: 1 },
  }));
});
