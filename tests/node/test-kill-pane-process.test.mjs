import { test } from 'node:test';
import assert from 'node:assert/strict';

import { killPaneProcess, TmuxError } from '../../src/node/tmux/pane-manager.mjs';

// Bug #7 Fix-Q: helper unit tests. No real tmux session required — sendRawKey
// and waitForExit are injected. Confirms the C-c → grace → C-c → waitForExit
// sequence and the fail-open behaviour.

test('AC1 happy: C-c, grace, C-c, then waitForExit (in order)', async () => {
  const events = [];
  const sendRawKey = async (paneId, key) => {
    events.push({ kind: 'send', paneId, key, t: Date.now() });
  };
  const waitForExit = async (paneId, opts) => {
    events.push({ kind: 'wait', paneId, opts, t: Date.now() });
  };
  const t0 = Date.now();
  await killPaneProcess('%worker', {
    sendRawKey,
    waitForExit,
    gracePeriodMs: 50,
    exitTimeoutMs: 1234,
  });

  assert.equal(events.length, 3, 'three events recorded');
  assert.deepEqual(
    events.map((e) => ({ kind: e.kind, key: e.key })),
    [
      { kind: 'send', key: 'C-c' },
      { kind: 'send', key: 'C-c' },
      { kind: 'wait', key: undefined },
    ],
  );
  assert.equal(events[0].paneId, '%worker');
  assert.equal(events[2].opts.timeoutMs, 1234);
  // Grace period honored between the two C-c sends.
  const gap = events[1].t - events[0].t;
  assert.ok(gap >= 45, `grace gap >= 45ms (got ${gap})`);
  assert.ok(events[2].t - t0 >= 45, 'waitForExit fires after grace');
});

test('AC2 fail-open: waitForExit throwing TmuxError does not abort', async () => {
  const messages = [];
  const sendRawKey = async () => {};
  const waitForExit = async () => {
    throw new TmuxError('Timed out waiting for pane %worker to return to the shell', {
      paneId: '%worker',
    });
  };
  await killPaneProcess('%worker', {
    sendRawKey,
    waitForExit,
    gracePeriodMs: 5,
    log: (msg) => messages.push(msg),
  });
  assert.equal(messages.length, 1, 'logs one warning on wait failure');
  assert.match(messages[0], /waitForExit failed for %worker/);
});

test('AC3 dead-pane: sendRawKey throwing does not abort', async () => {
  const messages = [];
  const sendRawKey = async () => {
    throw new TmuxError("can't find pane %dead", { paneId: '%dead' });
  };
  // waitForExit should still be invoked so callers retain ordering guarantees.
  let waitInvoked = false;
  const waitForExit = async () => {
    waitInvoked = true;
  };
  await killPaneProcess('%dead', {
    sendRawKey,
    waitForExit,
    gracePeriodMs: 1,
    log: (msg) => messages.push(msg),
  });
  // Two send failures (C-c, C-c) → two log lines.
  assert.equal(messages.length, 2, 'logs once per failed send');
  assert.ok(messages.every((m) => m.includes('sendRawKey C-c failed for %dead')));
  assert.equal(waitInvoked, true, 'waitForExit still invoked after send failures');
});

test('AC4 grace period default: gracePeriodMs default is honored', async () => {
  const sendTimes = [];
  const sendRawKey = async () => {
    sendTimes.push(Date.now());
  };
  const waitForExit = async () => {};
  const t0 = Date.now();
  await killPaneProcess('%worker', {
    sendRawKey,
    waitForExit,
    // omit gracePeriodMs to exercise default (800ms).
    exitTimeoutMs: 1,
  });
  assert.equal(sendTimes.length, 2);
  const gap = sendTimes[1] - sendTimes[0];
  // Default is 800ms; allow 50ms slack for unrelated scheduling.
  assert.ok(gap >= 750, `default grace >= 750ms (got ${gap})`);
  assert.ok(Date.now() - t0 < 5000, 'helper completes in reasonable time');
});
