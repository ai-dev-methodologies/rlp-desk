import { test } from 'node:test';
import assert from 'node:assert/strict';

// v0.14.1 — Bug Report #3 (BOS 2026-05-04): codex CLI can land the verdict
// atomic-mv inside the last poll interval. Without a last-chance read after
// the deadline elapses, pollForSignal would throw TimeoutError even though
// the verdict is on disk. This file is dedicated to the post-deadline read
// behaviour so the v0.14.1 SV gate can target it without picking up the
// pre-existing timing flakes that live in tests/node/us003-signal-poller.test.mjs.

test('signal-poller last-chance: returns the verdict when the file lands after the polling deadline', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const payload = { verdict: 'pass', us_id: 'US-003', summary: 'late atomic mv' };
  // Wall-clock based readFile mock: throws ENOENT for the entire polling
  // window, then returns the payload once the deadline has elapsed. This
  // models codex landing the atomic-mv between the last in-loop attempt and
  // the deadline check.
  const start = Date.now();
  const TIMEOUT_MS = 80;
  const readFile = async () => {
    if (Date.now() < start + TIMEOUT_MS) {
      const err = new Error('ENOENT');
      err.code = 'ENOENT';
      throw err;
    }
    return JSON.stringify(payload);
  };

  const result = await pollForSignal('/virtual/v0141-last-chance.json', {
    pollIntervalMs: 10,
    timeoutMs: TIMEOUT_MS,
    readFile,
  });

  assert.deepEqual(result, payload);
});

test('signal-poller last-chance: still throws TimeoutError when the verdict never lands', async () => {
  const { pollForSignal, TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');

  await assert.rejects(
    () =>
      pollForSignal('/virtual/v0141-genuine-timeout.json', {
        pollIntervalMs: 5,
        timeoutMs: 30,
        readFile: async () => {
          const err = new Error('ENOENT');
          err.code = 'ENOENT';
          throw err;
        },
      }),
    (error) => {
      assert.ok(error instanceof TimeoutError);
      return true;
    },
  );
});

// v0.14.2 — Bug Report #4 (BOS 2026-05-05): codex sometimes lands the
// verdict at the legacy .claude/ralph-desk/memos/ path. signal-poller's
// last-chance read accepts an optional `legacySignalFile` so the campaign
// loop can recover instead of timing out.

test('signal-poller v0.14.2: falls back to legacySignalFile when canonical never lands', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const canonical = '/virtual/v0142-canonical.json';
  const legacy = '/virtual/v0142-legacy.json';
  const payload = { verdict: 'pass', us_id: 'US-008', summary: 'codex wrote to legacy' };

  const readFile = async (filePath) => {
    if (filePath === legacy) return JSON.stringify(payload);
    const err = new Error('ENOENT');
    err.code = 'ENOENT';
    throw err;
  };

  const result = await pollForSignal(canonical, {
    pollIntervalMs: 5,
    timeoutMs: 30,
    readFile,
    legacySignalFile: legacy,
  });

  assert.deepEqual(result, payload);
});

test('signal-poller v0.14.2: prefers canonical when both paths have the verdict', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const canonical = '/virtual/v0142-canonical-2.json';
  const legacy = '/virtual/v0142-legacy-2.json';
  const canonicalPayload = { verdict: 'pass', us_id: 'US-009', source: 'canonical' };
  const legacyPayload = { verdict: 'fail', us_id: 'US-009', source: 'legacy' };

  // canonical lands after the polling deadline so the loop never sees it
  // in-loop; the last-chance read must observe the canonical file (and not
  // walk through to the legacy fallback).
  const start = Date.now();
  const TIMEOUT_MS = 60;
  const readFile = async (filePath) => {
    if (filePath === canonical) {
      if (Date.now() < start + TIMEOUT_MS) {
        const err = new Error('ENOENT');
        err.code = 'ENOENT';
        throw err;
      }
      return JSON.stringify(canonicalPayload);
    }
    if (filePath === legacy) return JSON.stringify(legacyPayload);
    const err = new Error('ENOENT');
    err.code = 'ENOENT';
    throw err;
  };

  const result = await pollForSignal(canonical, {
    pollIntervalMs: 10,
    timeoutMs: TIMEOUT_MS,
    readFile,
    legacySignalFile: legacy,
  });

  assert.equal(result.source, 'canonical', 'canonical must win over legacy');
});

test('signal-poller v0.14.2: throws TimeoutError when neither canonical nor legacy lands', async () => {
  const { pollForSignal, TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');

  await assert.rejects(
    () =>
      pollForSignal('/virtual/v0142-neither-canonical.json', {
        pollIntervalMs: 5,
        timeoutMs: 30,
        legacySignalFile: '/virtual/v0142-neither-legacy.json',
        readFile: async () => {
          const err = new Error('ENOENT');
          err.code = 'ENOENT';
          throw err;
        },
      }),
    (error) => {
      assert.ok(error instanceof TimeoutError);
      return true;
    },
  );
});
