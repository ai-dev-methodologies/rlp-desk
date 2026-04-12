import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

function createMissingFileError(filePath) {
  const error = new Error(`ENOENT: no such file or directory, open '${filePath}'`);
  error.code = 'ENOENT';
  return error;
}

function createReadFileStub(values) {
  let index = 0;

  return async () => {
    const value = values[Math.min(index, values.length - 1)];
    index += 1;

    if (value instanceof Error) {
      throw value;
    }

    return value;
  };
}

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'us003-signal-poller-tests');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

test('US-003 AC3.1 happy: pollForSignal waits until a missing signal file appears with valid JSON', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const signalFile = '/virtual/us003-ac31-happy.json';
  const payload = { status: 'verify', us_id: 'US-003' };
  let readCount = 0;
  const readFile = async () => {
    readCount += 1;
    if (readCount < 3) {
      throw createMissingFileError(signalFile);
    }
    return JSON.stringify(payload);
  };

  const result = await pollForSignal(signalFile, {
    pollIntervalMs: 5,
    timeoutMs: 100,
    readFile,
  });

  assert.deepEqual(result, payload);
  assert.equal(readCount, 3);
});

test('US-003 AC3.1 boundary: pollForSignal resolves when a real signal file is written before timeout', async (t) => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const tempDir = await createTempDir(t);
  const signalFile = path.join(tempDir, 'signal.json');
  const payload = { status: 'verify', us_id: 'US-003', summary: 'real file write' };
  setTimeout(() => {
    fs.writeFile(signalFile, JSON.stringify(payload), 'utf8').catch(() => {});
  }, 40);

  const result = await pollForSignal(signalFile, {
    pollIntervalMs: 10,
    timeoutMs: 300,
  });

  assert.deepEqual(result, payload);
});

test('US-003 AC3.1 negative: pollForSignal surfaces non-ENOENT file read failures', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');

  await assert.rejects(
    () =>
      pollForSignal('/virtual/us003-ac31-negative.json', {
        pollIntervalMs: 5,
        timeoutMs: 100,
        readFile: async () => {
          const error = new Error('EACCES: permission denied');
          error.code = 'EACCES';
          throw error;
        },
      }),
    /EACCES/,
  );
});

test('US-003 AC3.2 happy: pollForSignal in codex mode waits for valid JSON and pane exit before resolving', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const payload = { verdict: 'pass', us_id: 'US-003' };
  const paneStates = ['codex', 'codex', 'zsh'];
  const start = Date.now();

  const result = await pollForSignal('/virtual/us003-ac32-happy.json', {
    mode: 'codex',
    paneId: '%42',
    pollIntervalMs: 20,
    timeoutMs: 300,
    readFile: async () => JSON.stringify(payload),
    getPaneCommand: async () => paneStates.shift() ?? 'zsh',
  });

  assert.deepEqual(result, payload);
  assert.ok(Date.now() - start >= 40);
});

test('US-003 AC3.2 boundary: pollForSignal in codex mode resolves immediately when the pane is already back at the shell', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const payload = { verdict: 'pass', us_id: 'US-003' };
  let paneChecks = 0;
  const start = Date.now();

  const result = await pollForSignal('/virtual/us003-ac32-boundary.json', {
    mode: 'codex',
    paneId: '%43',
    pollIntervalMs: 20,
    timeoutMs: 300,
    readFile: async () => JSON.stringify(payload),
    getPaneCommand: async () => {
      paneChecks += 1;
      return 'zsh';
    },
  });

  assert.deepEqual(result, payload);
  assert.equal(paneChecks, 1);
  assert.ok(Date.now() - start < 80);
});

test('US-003 AC3.2 negative: pollForSignal tolerates transient pane-read errors while waiting for codex exit', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const payload = { verdict: 'pass', us_id: 'US-003' };
  const paneStates = [new Error('tmux API unavailable'), 'codex', 'zsh'];

  const result = await pollForSignal('/virtual/us003-ac32-negative.json', {
    mode: 'codex',
    paneId: '%44',
    pollIntervalMs: 10,
    timeoutMs: 300,
    readFile: async () => JSON.stringify(payload),
    getPaneCommand: async () => {
      const next = paneStates.shift() ?? 'zsh';
      if (next instanceof Error) {
        throw next;
      }
      return next;
    },
  });

  assert.deepEqual(result, payload);
});

test('US-003 AC3.3 happy: pollForSignal rejects with TimeoutError when no signal file appears before timeout', async () => {
  const { pollForSignal, TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');

  await assert.rejects(
    () =>
      pollForSignal('/virtual/us003-ac33-happy.json', {
        pollIntervalMs: 5,
        timeoutMs: 30,
        readFile: async () => {
          throw createMissingFileError('/virtual/us003-ac33-happy.json');
        },
      }),
    (error) => error instanceof TimeoutError && /Timed out/i.test(error.message),
  );
});

test('US-003 AC3.3 boundary: pollForSignal times out on invalid JSON without hanging indefinitely', async (t) => {
  const { pollForSignal, TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');
  const tempDir = await createTempDir(t);
  const signalFile = path.join(tempDir, 'signal.json');
  await fs.writeFile(signalFile, '{"status":"ver', 'utf8');
  const start = Date.now();

  await assert.rejects(
    () =>
      pollForSignal(signalFile, {
        pollIntervalMs: 10,
        timeoutMs: 60,
      }),
    (error) => error instanceof TimeoutError,
  );

  const elapsed = Date.now() - start;
  assert.ok(elapsed >= 50);
  assert.ok(elapsed < 250);
});

test('US-003 AC3.3 negative: pollForSignal in codex mode times out when the pane never exits', async () => {
  const { pollForSignal, TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');

  await assert.rejects(
    () =>
      pollForSignal('/virtual/us003-ac33-negative.json', {
        mode: 'codex',
        paneId: '%45',
        pollIntervalMs: 10,
        timeoutMs: 50,
        readFile: async () => JSON.stringify({ verdict: 'pass' }),
        getPaneCommand: async () => 'codex',
      }),
    (error) => error instanceof TimeoutError && /pane %45/i.test(error.message),
  );
});

test('US-003 AC3.4 happy: pollForSignal ignores invalid JSON and resolves once a later poll returns valid JSON', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const payload = { verdict: 'pass', summary: 'recovered from corrupt file' };

  const result = await pollForSignal('/virtual/us003-ac34-happy.json', {
    pollIntervalMs: 5,
    timeoutMs: 100,
    readFile: createReadFileStub(['{"verdict":"pa', '{"verdict":"still-bad"', JSON.stringify(payload)]),
  });

  assert.deepEqual(result, payload);
});

test('US-003 AC3.4 boundary: pollForSignal handles a real partially written file before the final JSON lands', async (t) => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const tempDir = await createTempDir(t);
  const signalFile = path.join(tempDir, 'signal.json');
  const payload = { verdict: 'pass', summary: 'partial write recovered' };

  setTimeout(() => {
    fs.writeFile(signalFile, '{"verdict":"pa', 'utf8').catch(() => {});
  }, 10);
  setTimeout(() => {
    fs.writeFile(signalFile, JSON.stringify(payload), 'utf8').catch(() => {});
  }, 40);

  const result = await pollForSignal(signalFile, {
    pollIntervalMs: 10,
    timeoutMs: 300,
  });

  assert.deepEqual(result, payload);
});

test('US-003 AC3.4 negative: pollForSignal does not start codex exit checks until the signal file contains valid JSON', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const payload = { verdict: 'pass', summary: 'json became valid' };
  let paneChecks = 0;

  const result = await pollForSignal('/virtual/us003-ac34-negative.json', {
    mode: 'codex',
    paneId: '%46',
    pollIntervalMs: 5,
    timeoutMs: 100,
    readFile: createReadFileStub(['{"verdict":"pa', JSON.stringify(payload)]),
    getPaneCommand: async () => {
      paneChecks += 1;
      return 'zsh';
    },
  });

  assert.deepEqual(result, payload);
  assert.equal(paneChecks, 1);
});
