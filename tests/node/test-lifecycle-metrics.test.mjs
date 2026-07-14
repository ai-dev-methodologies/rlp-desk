import test from 'node:test';
import assert from 'node:assert/strict';

import {
  LifecycleMetricsCollector,
} from '../../src/node/util/lifecycle-metrics.mjs';

// PR-B4 (v0.15.4) — LifecycleMetricsCollector helper unit tests.
//
// Plan: docs/plans/v0.15-phase-b-plan-v3.md §B4.
// Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §3 Table 2.
//
// Two contracts under test (v0.22.4: the opt-out flag is REMOVED):
//   AC4.2 (always-on): the collector records/flushes regardless of any env,
//         and the legacy RLP_LIFECYCLE_METRICS value is ignored entirely.
//   AC4.1 (per-event emission): record() accumulates; flush() emits a grouped
//         object; sentinel lock/unlock pair produces sentinel_lock_to_unlock_ms.

test('AC4.2 (v0.22.4): collector always records — no env, no .enabled getter', () => {
  const c = new LifecycleMetricsCollector({ env: {} });
  assert.equal(c.enabled, undefined, 'the enabled getter is gone with the flag');
  c.record('iter_signal_write_to_read_ms', 1234, { iter: 1 });
  const flushed = c.flush();
  assert.ok(flushed, 'flush always returns an object');
  assert.ok(Array.isArray(flushed.iter_signal_write_to_read_ms));
});

test('AC4.2 (v0.22.4): the legacy "0" opt-out is ignored — recording proceeds', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '0' } });
  c.record('pane_reap_latency_ms', 4200, {});
  const flushed = c.flush();
  assert.ok(flushed && flushed.pane_reap_latency_ms, 'legacy opt-out must not silence');
});

test('AC4.1: collector records and groups by metric in flush (env irrelevant)', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  c.record('iter_signal_write_to_read_ms', 2400, { iter: 1, us_id: 'US-001' });
  c.record('verdict_write_to_read_ms', 1800, { iter: 1 });
  c.record('pane_reap_latency_ms', 3500, { iter: 1, sentinel: 'done-claim' });
  const flushed = c.flush();
  assert.ok(flushed, 'flush returns object when enabled');
  assert.ok(Array.isArray(flushed.iter_signal_write_to_read_ms));
  assert.equal(flushed.iter_signal_write_to_read_ms.length, 1);
  assert.equal(flushed.iter_signal_write_to_read_ms[0].value_ms, 2400);
  assert.equal(flushed.iter_signal_write_to_read_ms[0].us_id, 'US-001');
  assert.equal(flushed.verdict_write_to_read_ms[0].value_ms, 1800);
  assert.equal(flushed.pane_reap_latency_ms[0].sentinel, 'done-claim');
});

test('AC4.1: flush resets the accumulator', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  c.record('iter_signal_write_to_read_ms', 100, {});
  const first = c.flush();
  assert.ok(first?.iter_signal_write_to_read_ms);
  const second = c.flush();
  assert.deepEqual(second, {}, 'second flush is empty (records cleared)');
});

test('AC4.1: sentinel lock/unlock pair emits sentinel_lock_to_unlock_ms', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  const t0 = 1_000_000;
  c.markLockStart('iter-signal', t0);
  c.markUnlock('iter-signal', { iter: 1 }, t0 + 350);
  const flushed = c.flush();
  assert.ok(Array.isArray(flushed.sentinel_lock_to_unlock_ms));
  const entry = flushed.sentinel_lock_to_unlock_ms[0];
  assert.equal(entry.value_ms, 350);
  assert.equal(entry.sentinel_type, 'iter-signal');
  assert.equal(entry.iter, 1);
});

test('AC4.1: markUnlock without prior markLockStart is a no-op', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  c.markUnlock('verdict', { iter: 2 });
  const flushed = c.flush();
  // Empty grouped object — no spurious entry for unmatched unlock.
  assert.equal(flushed.sentinel_lock_to_unlock_ms, undefined);
});

// codex-r0 preempt (F7 parity): a negative or non-finite value_ms is now
// DROPPED (not clamped to 0) — clamp-and-keep let a corrupted measurement
// (clock skew, NaN) silently satisfy a "<= band" regression check as a
// false PASS. Mirrors the zsh leader's log_lifecycle_metric fix (P2 sweep
// F7) — SAME semantics both sides now, not the deliberate divergence F7
// originally landed.
test('AC4.1: value_ms is rounded when valid; a genuine positive value rounds correctly', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  c.record('iter_signal_write_to_read_ms', 1234.6, {});  // round to 1235
  const flushed = c.flush();
  assert.equal(flushed.iter_signal_write_to_read_ms[0].value_ms, 1235);
});

test('F7 parity: a negative value_ms is dropped entirely, not clamped to 0', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  c.record('pane_eof_to_cleanup_ms', -42, {});  // clock skew — must be dropped
  const flushed = c.flush();
  assert.equal(flushed.pane_eof_to_cleanup_ms, undefined, 'no entry for the dropped metric at all');
});

test('F7 parity: NaN and Infinity value_ms are dropped', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  c.record('pane_eof_to_cleanup_ms', NaN, {});
  c.record('verdict_write_to_read_ms', Infinity, {});
  c.record('iter_signal_write_to_read_ms', -Infinity, {});
  const flushed = c.flush();
  assert.deepEqual(flushed, {}, 'no records survive for any non-finite value_ms');
});

test('F7 parity: a genuine value_ms of 0 (real sub-ms measurement) is kept, not confused with a dropped negative/invalid value', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  c.record('pane_eof_to_cleanup_ms', 0, {});
  const flushed = c.flush();
  assert.equal(flushed.pane_eof_to_cleanup_ms[0].value_ms, 0);
});

test('F7 parity: dropping a record logs via the injected debugLog channel (audit aid, mirrors zsh DEBUG-gated warning)', () => {
  const seen = [];
  const debugLog = (cat, fields) => seen.push({ cat, fields });
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' }, debugLog });
  c.record('pane_eof_to_cleanup_ms', -5, {});
  assert.equal(seen.length, 1);
  assert.equal(seen[0].cat, 'LIFECYCLE');
  assert.equal(seen[0].fields.metric, 'pane_eof_to_cleanup_ms');
  assert.equal(seen[0].fields.dropped, true);
});

test('F7 parity: markUnlock with a negative delta (clock skew: unlock timestamp before lock timestamp) drops silently instead of emitting a negative duration', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  const t0 = 1_000_000;
  c.markLockStart('verdict', t0);
  c.markUnlock('verdict', { iter: 1 }, t0 - 200);  // "unlock" resolves BEFORE lock start — clock skew
  const flushed = c.flush();
  assert.equal(flushed.sentinel_lock_to_unlock_ms, undefined, 'no spurious negative-duration entry');
});

test('AC4.1: debugLog is called per record when injected and enabled', () => {
  const seen = [];
  const debugLog = (cat, fields) => seen.push({ cat, fields });
  const c = new LifecycleMetricsCollector({
    env: { RLP_LIFECYCLE_METRICS: '1' },
    debugLog,
  });
  c.record('iter_signal_write_to_read_ms', 500, { iter: 3 });
  assert.equal(seen.length, 1);
  assert.equal(seen[0].cat, 'LIFECYCLE');
  assert.equal(seen[0].fields.metric, 'iter_signal_write_to_read_ms');
  assert.equal(seen[0].fields.value_ms, 500);
  assert.equal(seen[0].fields.iter, 3);
});

test('AC4.2 (v0.22.4): debugLog fires even when the legacy opt-out is set', () => {
  const calls = [];
  const c = new LifecycleMetricsCollector({
    env: { RLP_LIFECYCLE_METRICS: '0' },
    debugLog: (line) => calls.push(line),
  });
  c.record('pane_eof_to_cleanup_ms', 10, {});
  assert.ok(calls.length >= 1, 'debug log emits regardless of the removed flag');
});

test('the RLP_LIFECYCLE_METRICS flag is REMOVED (v0.22.4): env is ignored, collector always records', () => {
  for (const env of [{}, { RLP_LIFECYCLE_METRICS: '0' }, { RLP_LIFECYCLE_METRICS: '' }, { RLP_LIFECYCLE_METRICS: '1' }]) {
    const c = new LifecycleMetricsCollector({ env });
    c.record('pane_eof_to_cleanup_ms', 5, { iter: 1 });
    const out = c.flush();
    assert.ok(out && Array.isArray(out.pane_eof_to_cleanup_ms) && out.pane_eof_to_cleanup_ms.length === 1,
      `collector must record regardless of env ${JSON.stringify(env)}`);
  }
});
