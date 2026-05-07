import test from 'node:test';
import assert from 'node:assert/strict';

import {
  percentile,
  bucketRecords,
  classifyDrift,
} from '../../tests/sv-real-llm/lib/b3-band-revalidation.mjs';

// v0.15.4 audit L2 fix: unit tests for the pure helpers in the B3 band
// revalidation harness. Without these, a bug in percentile() or bucket-
// filling would silently produce wrong empirical bands, which then drive
// release-blocking Stage 2 assertions in B3 scenarios. The harness was
// 272 lines without test coverage; these are the 3 pure functions worth
// testing directly. The async I/O (run5IterCampaign, aggregateMetrics
// with fs.readFile, console.log emissions) is exercised by the harness
// itself when invoked as `node tests/sv-real-llm/lib/b3-band-revalidation.mjs`.

// ────────────────────────────────────────────────────────────────────────
// percentile()
// ────────────────────────────────────────────────────────────────────────
test('percentile: empty array returns null', () => {
  assert.equal(percentile([], 50), null);
  assert.equal(percentile([], 95), null);
});

test('percentile: single sample returns that sample for any p', () => {
  assert.equal(percentile([42], 50), 42);
  assert.equal(percentile([42], 95), 42);
  assert.equal(percentile([42], 99), 42);
});

test('percentile: 100 sorted samples — p50, p95, p99 match expected indexes', () => {
  const sorted = Array.from({ length: 100 }, (_, i) => i + 1); // 1..100
  // p50 → ceil(50/100*100)-1 = 49 → sorted[49] = 50
  assert.equal(percentile(sorted, 50), 50);
  // p95 → ceil(95/100*100)-1 = 94 → sorted[94] = 95
  assert.equal(percentile(sorted, 95), 95);
  // p99 → ceil(99/100*100)-1 = 98 → sorted[98] = 99
  assert.equal(percentile(sorted, 99), 99);
});

test('percentile: 5 sorted samples (revalidation-harness real case)', () => {
  // Real B3 revalidation found p50=848, p95=853 from N=5 sample.
  const sorted = [800, 820, 848, 852, 853];
  // p50 → ceil(50/100*5)-1 = ceil(2.5)-1 = 3-1 = 2 → sorted[2] = 848
  assert.equal(percentile(sorted, 50), 848);
  // p95 → ceil(95/100*5)-1 = ceil(4.75)-1 = 5-1 = 4 → sorted[4] = 853
  assert.equal(percentile(sorted, 95), 853);
});

test('percentile: out-of-range p clamps to first/last index', () => {
  const sorted = [10, 20, 30];
  // p=0 → ceil(0)-1 = -1 → clamped to 0 → sorted[0] = 10
  assert.equal(percentile(sorted, 0), 10);
  // p=100 → ceil(3)-1 = 2 → sorted[2] = 30
  assert.equal(percentile(sorted, 100), 30);
});

// ────────────────────────────────────────────────────────────────────────
// bucketRecords()
// ────────────────────────────────────────────────────────────────────────
test('bucketRecords: empty array → all buckets empty', () => {
  const buckets = bucketRecords([]);
  assert.equal(buckets.iter_signal_write_to_read_ms.length, 0);
  assert.equal(buckets.verdict_write_to_read_ms.length, 0);
  assert.equal(buckets.pane_eof_to_cleanup_ms.length, 0);
  assert.equal(buckets.pane_reap_latency_ms.length, 0);
});

test('bucketRecords: lifecycle_metrics=null records skipped silently', () => {
  const buckets = bucketRecords([
    { iter: 1, lifecycle_metrics: null },
    { iter: 2, lifecycle_metrics: null },
  ]);
  assert.equal(buckets.iter_signal_write_to_read_ms.length, 0);
});

test('bucketRecords: single record with one metric entry', () => {
  const buckets = bucketRecords([
    {
      iter: 1,
      lifecycle_metrics: {
        iter_signal_write_to_read_ms: [{ value_ms: 850, ts: 'x' }],
      },
    },
  ]);
  assert.deepEqual(buckets.iter_signal_write_to_read_ms, [850]);
  assert.equal(buckets.verdict_write_to_read_ms.length, 0);
});

test('bucketRecords: multiple records aggregate per metric', () => {
  const buckets = bucketRecords([
    {
      iter: 1,
      lifecycle_metrics: {
        iter_signal_write_to_read_ms: [{ value_ms: 800 }, { value_ms: 820 }],
        pane_eof_to_cleanup_ms: [{ value_ms: 1500 }],
      },
    },
    {
      iter: 2,
      lifecycle_metrics: {
        iter_signal_write_to_read_ms: [{ value_ms: 850 }],
        pane_eof_to_cleanup_ms: [{ value_ms: 1600 }, { value_ms: 1700 }],
      },
    },
  ]);
  assert.deepEqual(buckets.iter_signal_write_to_read_ms, [800, 820, 850]);
  assert.deepEqual(buckets.pane_eof_to_cleanup_ms, [1500, 1600, 1700]);
});

test('bucketRecords: non-number value_ms entries skipped', () => {
  const buckets = bucketRecords([
    {
      lifecycle_metrics: {
        iter_signal_write_to_read_ms: [
          { value_ms: 800 },
          { value_ms: 'invalid' },     // type mismatch
          { value_ms: null },          // null
          {},                          // missing field
          { value_ms: 850 },
        ],
      },
    },
  ]);
  assert.deepEqual(buckets.iter_signal_write_to_read_ms, [800, 850]);
});

test('bucketRecords: unknown metric keys are ignored', () => {
  const buckets = bucketRecords([
    {
      lifecycle_metrics: {
        iter_signal_write_to_read_ms: [{ value_ms: 100 }],
        future_metric_xyz: [{ value_ms: 99999 }],   // not in known set
      },
    },
  ]);
  assert.deepEqual(buckets.iter_signal_write_to_read_ms, [100]);
  // Unknown bucket should NOT appear (would be undefined)
  assert.equal(buckets.future_metric_xyz, undefined);
});

// ────────────────────────────────────────────────────────────────────────
// classifyDrift()
// ────────────────────────────────────────────────────────────────────────
test('classifyDrift: empty samples → null', () => {
  assert.equal(classifyDrift('iter_signal_write_to_read_ms', []), null);
});

test('classifyDrift: real revalidation case — empirical -82% drift triggers breach', () => {
  // Synthetic p95 = 4750ms; empirical sample yields p95 = 853ms.
  const samples = [800, 820, 848, 852, 853]; // p50=848, p95=853
  const r = classifyDrift('iter_signal_write_to_read_ms', samples);
  assert.equal(r.p50, 848);
  assert.equal(r.p95, 853);
  assert.equal(r.synthP95, 4750);
  // drift = (853 - 4750) / 4750 * 100 = -82.04...
  assert.ok(Math.abs(r.drift - (-82.04)) < 0.5, `drift ~ -82%, got ${r.drift}`);
  assert.equal(r.breaches, true, '|drift|=82% > 25% threshold');
  // recommendedBand = max(853 * 2, 1000) = 1706
  assert.equal(r.recommendedBand, 1706);
});

test('classifyDrift: synthetic-aligned case (drift within ±25%) → no breach', () => {
  // Synthetic p95 = 4750ms; empirical p95 = 4500 (drift -5.3%)
  const samples = [4000, 4200, 4400, 4480, 4500];
  const r = classifyDrift('iter_signal_write_to_read_ms', samples);
  assert.equal(r.p95, 4500);
  assert.ok(Math.abs(r.drift - (-5.26)) < 0.5);
  assert.equal(r.breaches, false);
  // recommendedBand = max(4500 * 2, 1000) = 9000 — even non-breaching, the
  // formula still produces a band (caller decides whether to apply it)
  assert.equal(r.recommendedBand, 9000);
});

test('classifyDrift: positive drift (empirical > synthetic) also triggers breach', () => {
  // Synthetic p95 = 4750ms; empirical p95 = 8000 (drift +68%)
  const samples = [6000, 7000, 7500, 7900, 8000];
  const r = classifyDrift('iter_signal_write_to_read_ms', samples);
  assert.equal(r.p95, 8000);
  assert.ok(r.drift > 25);
  assert.equal(r.breaches, true);
});

test('classifyDrift: unknown metric (no synthetic) → drift=null, no breach', () => {
  const r = classifyDrift('unknown_metric', [100, 200, 300, 400, 500]);
  assert.equal(r.p95, 500);
  assert.equal(r.synthP95, undefined);
  assert.equal(r.drift, null);
  assert.equal(r.breaches, false);
  // recommendedBand still computes from p95 * 2 vs floor
  assert.equal(r.recommendedBand, 1000);    // max(500*2, 1000) = 1000
});

test('classifyDrift: floor enforced when 2*p95 is small', () => {
  // Real B3 case: pane_eof_to_cleanup_ms p95=834, 2*p95=1668 < floor (note:
  // FIXED_FLOOR_MS for pane_eof is 1000, so 1668 wins. Use a synthetic
  // metric name override that has a higher floor.
  const customFloor = { tiny_metric: 5000 };
  const customSynth = { tiny_metric: 1000 };
  const samples = [100, 150, 200];     // p95 = 200, 2*p95 = 400
  const r = classifyDrift('tiny_metric', samples, customSynth, customFloor);
  assert.equal(r.p95, 200);
  // recommendedBand = max(400, 5000) = 5000 (floor wins)
  assert.equal(r.recommendedBand, 5000);
});
