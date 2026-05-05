import { test } from 'node:test';
import assert from 'node:assert/strict';

// v0.14.5 — Bug Report #6 Fix-P (Node parity): the same last-chance read
// pattern that protects the verifier (Bug #3 Fix-A / Bug #4 Fix-D) also
// protects the worker. claude CLI can finish work + atomic-mv the
// iter-signal + park at its idle prompt all within a single poll interval;
// if our previous readFile happened to race with the rename, we would have
// seen ENOENT/SyntaxError. The synchronous last-chance read after the
// deadline (signal-poller.mjs L253-258) lets pollForSignal return the
// parsed worker signal instead of throwing TimeoutError.
//
// This test pins the worker-shape contract specifically so the worker
// callsite at campaign-main-loop.mjs:1420 cannot regress silently if the
// verdict-shape callers diverge from the worker-shape callers in the future.

test('signal-poller worker last-chance: returns the iter-signal when the file lands after the polling deadline', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const payload = {
    slug: 'foo',
    iteration: 3,
    us_id: 'US-010',
    status: 'verify',
    signal_type: 'signal',
    summary: 'late atomic mv on worker side',
  };
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

  const result = await pollForSignal('/virtual/bug6-worker-iter-signal.json', {
    pollIntervalMs: 10,
    timeoutMs: TIMEOUT_MS,
    readFile,
  });

  assert.deepEqual(result, payload);
  assert.equal(result.signal_type, 'signal', 'worker payload preserves signal_type');
  assert.equal(result.status, 'verify', 'worker payload preserves verify status');
  assert.equal(typeof result.iteration, 'number', 'worker payload preserves numeric iteration');
});

test('signal-poller worker last-chance: malformed JSON at last-chance time still throws TimeoutError', async () => {
  const { pollForSignal, TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');

  // Always return malformed JSON: in-loop reads see SyntaxError, last-chance
  // read also sees SyntaxError. Caller (campaign-main-loop._handlePollFailure)
  // is responsible for writing BLOCKED — pollForSignal must not silently pass.
  const readFile = async () => 'not-json';

  await assert.rejects(
    () =>
      pollForSignal('/virtual/bug6-worker-malformed.json', {
        pollIntervalMs: 5,
        timeoutMs: 30,
        readFile,
      }),
    (error) => {
      assert.ok(error instanceof TimeoutError);
      return true;
    },
  );
});

test('signal-poller worker last-chance: verify_partial signal also passes through last-chance', async () => {
  const { pollForSignal } = await import('../../src/node/polling/signal-poller.mjs');
  const payload = {
    slug: 'foo',
    iteration: 4,
    us_id: 'US-019',
    status: 'verify_partial',
    signal_type: 'signal',
    verified_acs: ['AC-1', 'AC-2'],
    summary: 'partial verification',
  };
  const start = Date.now();
  const TIMEOUT_MS = 60;
  const readFile = async () => {
    if (Date.now() < start + TIMEOUT_MS) {
      const err = new Error('ENOENT');
      err.code = 'ENOENT';
      throw err;
    }
    return JSON.stringify(payload);
  };

  const result = await pollForSignal('/virtual/bug6-worker-verify-partial.json', {
    pollIntervalMs: 10,
    timeoutMs: TIMEOUT_MS,
    readFile,
  });

  assert.deepEqual(result, payload);
  assert.ok(Array.isArray(result.verified_acs), 'verified_acs preserved');
});
