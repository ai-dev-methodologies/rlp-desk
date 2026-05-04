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
