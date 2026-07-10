import test from 'node:test';
import assert from 'node:assert/strict';

import {
  LifecycleMetricsCollector,
  lifecycleMetricsEnabled,
} from '../../src/node/util/lifecycle-metrics.mjs';

// PR-B4 (v0.15.4) — LifecycleMetricsCollector helper unit tests.
//
// Plan: docs/plans/v0.15-phase-b-plan-v3.md §B4.
// Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §3 Table 2.
//
// Two contracts under test:
//   AC4.2 (zero-overhead when explicitly disabled): record() / markLockStart() /
//         markUnlock() / flush() must short-circuit. flush() returns null.
//         v0.22.0 full-wire: the flag defaults ON — "0" is the sole opt-out.
//   AC4.1 (per-event emission): record() accumulates; flush() emits a grouped
//         object; sentinel lock/unlock pair produces sentinel_lock_to_unlock_ms.

test('AC4.2 (v0.22.0 full-wire): collector is ENABLED by default when env flag is unset', () => {
  const c = new LifecycleMetricsCollector({ env: {} });
  assert.equal(c.enabled, true);
  c.record('iter_signal_write_to_read_ms', 1234, { iter: 1 });
  const flushed = c.flush();
  assert.ok(flushed, 'flush returns an object when enabled by default');
  assert.ok(Array.isArray(flushed.iter_signal_write_to_read_ms));
});

test('AC4.2: collector is disabled when env flag is "0" (explicit opt-out)', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '0' } });
  assert.equal(c.enabled, false);
  c.record('pane_reap_latency_ms', 4200, {});
  assert.equal(c.flush(), null);
});

test('AC4.1: collector records when flag is "1" and groups by metric in flush', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  assert.equal(c.enabled, true);
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

test('AC4.1: value_ms is rounded and clamped to non-negative', () => {
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });
  c.record('pane_eof_to_cleanup_ms', -42, {});  // clock skew → clamp to 0
  c.record('iter_signal_write_to_read_ms', 1234.6, {});  // round to 1235
  const flushed = c.flush();
  assert.equal(flushed.pane_eof_to_cleanup_ms[0].value_ms, 0);
  assert.equal(flushed.iter_signal_write_to_read_ms[0].value_ms, 1235);
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

test('AC4.2: debugLog is NOT called when explicitly disabled (zero overhead)', () => {
  const seen = [];
  const debugLog = (cat, fields) => seen.push({ cat, fields });
  const c = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '0' }, debugLog });
  c.record('iter_signal_write_to_read_ms', 500, {});
  assert.equal(seen.length, 0, 'no debugLog calls when disabled');
});

test('lifecycleMetricsEnabled() exact boolean semantics (v0.22.0 full-wire: default ON, "0" opts out)', () => {
  assert.equal(lifecycleMetricsEnabled({}), true, 'unset defaults to enabled');
  assert.equal(lifecycleMetricsEnabled({ RLP_LIFECYCLE_METRICS: '0' }), false, 'explicit "0" opts out');
  assert.equal(lifecycleMetricsEnabled({ RLP_LIFECYCLE_METRICS: '' }), true);
  assert.equal(lifecycleMetricsEnabled({ RLP_LIFECYCLE_METRICS: 'true' }), true);
  assert.equal(lifecycleMetricsEnabled({ RLP_LIFECYCLE_METRICS: '1' }), true);
});
