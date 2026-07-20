import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { LifecycleMetricsCollector } from '../../src/node/util/lifecycle-metrics.mjs';

// PR-B4 (v0.15.4) — campaign.jsonl shape contract test.
//
// Plan: docs/plans/v0.15-phase-b-plan-v3.md §B4 (AC4.3, AC4.6, AC4.7).
// Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §3 Table 2.
//
// Asserts the campaign.jsonl per-iter record shape (v0.22.4: the
// RLP_LIFECYCLE_METRICS opt-out is REMOVED — see
// src/node/util/lifecycle-metrics.mjs):
//   - lifecycle_metrics is always an object; the legacy "0" env is ignored.
//   - Shape: an object grouped by metric name; each value is an array of
//                per-record entries with value_ms (number, non-negative
//                integer) + ts.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'b4-campaign-jsonl-shape');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

function deskPath(rootDir, ...segments) {
  return path.join(rootDir, '.rlp-desk', ...segments);
}

function createPoller(queue) {
  return async function pollForSignal(targetPath) {
    if (queue.length === 0) {
      throw new Error(`No queued poll result for ${targetPath}`);
    }
    const next = queue.shift();
    if (next instanceof Error) throw next;
    return next;
  };
}

function createTmuxFakes() {
  const reaped = [];
  const locked = [];
  const events = [];
  const paneIds = ['%flywheel', '%worker', '%verifier'];
  return {
    reaped, locked, events,
    deps: {
      createSession: async ({ sessionName }) => ({ sessionName, leaderPaneId: '%leader' }),
      createPane: async () => paneIds.shift(),
      sendKeys: async (paneId, command) => events.push({ kind: 'send', paneId, command }),
      killPaneProcess: async (paneId) => { reaped.push({ paneId }); events.push({ kind: 'kill', paneId }); },
      lockSentinelFile: async (filePath) => { locked.push({ filePath }); events.push({ kind: 'lock', filePath }); },
      waitForProcessExit: async () => {},
      stampAckField: async () => {},
    },
  };
}

async function setupCampaign(t) {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  const slug = 'b4-shape-test';
  const prdContent = '# PRD: b4-shape-test\n\n## Objective\nB4 shape\n\n## US-001: Story\nA.\n';
  await initCampaign(slug, 'B4 shape', { rootDir, prdContent });
  return { rootDir, slug };
}

async function readJsonl(filePath) {
  const content = await fs.readFile(filePath, 'utf8');
  return content.trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

// ────────────────────────────────────────────────────────────────────────────
// AC4.3 / AC4.7 (v0.22.4) — the flag is gone: the legacy "0" opt-out is
// ignored and metrics always emit.
// ────────────────────────────────────────────────────────────────────────────
test('B4 (v0.22.4): the flag is removed — a collector built with RLP_LIFECYCLE_METRICS=0 still emits', () => {
  const collector = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '0' } });
  collector.record('pane_eof_to_cleanup_ms', 7, { iter: 1 });
  const flushed = collector.flush();
  assert.ok(flushed && flushed.pane_eof_to_cleanup_ms, 'env opt-out no longer exists; metrics always flush');
});

// ────────────────────────────────────────────────────────────────────────────
// AC4.3 / AC4.6 — Flag set: lifecycle_metrics is grouped object with metrics
// ────────────────────────────────────────────────────────────────────────────
test('B4 AC4.3/4.6: lifecycle_metrics is populated grouped object when flag set', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const enabledCollector = new LifecycleMetricsCollector({
    env: { RLP_LIFECYCLE_METRICS: '1' },
  });

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    lifecycleMetrics: enabledCollector,
    ...tmux.deps,
  });

  const jsonlPath = deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign.jsonl');
  const records = await readJsonl(jsonlPath);
  assert.ok(records.length >= 1, 'campaign.jsonl has at least one iter record');
  // First record carries the iter-1 metrics. Subsequent records may have
  // empty lifecycle_metrics (the collector flushes per-iter).
  const firstRecord = records[0];
  assert.ok('lifecycle_metrics' in firstRecord);
  assert.notEqual(firstRecord.lifecycle_metrics, null, 'lifecycle_metrics object present when enabled');
  assert.equal(typeof firstRecord.lifecycle_metrics, 'object');

  // At least pane_eof_to_cleanup_ms should be present (every reap fires it).
  const lm = firstRecord.lifecycle_metrics;
  assert.ok(
    Array.isArray(lm.pane_eof_to_cleanup_ms),
    'pane_eof_to_cleanup_ms is an array',
  );
  assert.ok(
    lm.pane_eof_to_cleanup_ms.length >= 1,
    'at least one pane reap recorded for iter-1',
  );
  for (const entry of lm.pane_eof_to_cleanup_ms) {
    assert.equal(typeof entry.value_ms, 'number');
    assert.ok(entry.value_ms >= 0, 'value_ms is non-negative');
    assert.ok(typeof entry.ts === 'string', 'ts is ISO string');
  }
});

// ────────────────────────────────────────────────────────────────────────────
// IMP-10 (closes v0.15.4 audit H2) — done-claim's sentinel_lock_to_unlock_ms
// now emits at its per-iteration close-out (tagged ctx=archival) instead of
// never. Extends AC4.3/4.6 above: run a real campaign and assert the shape
// distinguishes the done-claim (ctx=archival) entries from the true
// lock->unlock series (signal/verdict, which carry no ctx field).
// ────────────────────────────────────────────────────────────────────────────
test('IMP-10: done-claim sentinel_lock_to_unlock_ms entries carry ctx=archival; signal/verdict entries do not', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const enabledCollector = new LifecycleMetricsCollector({
    env: { RLP_LIFECYCLE_METRICS: '1' },
  });

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    lifecycleMetrics: enabledCollector,
    ...tmux.deps,
  });

  const jsonlPath = deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign.jsonl');
  const records = await readJsonl(jsonlPath);
  const allLockPairs = records
    .flatMap((r) => r.lifecycle_metrics?.sentinel_lock_to_unlock_ms ?? []);

  const doneClaimBasename = `${campaign.slug}-done-claim.json`;
  const doneClaimEntries = allLockPairs.filter((e) => e.sentinel_type === doneClaimBasename);
  assert.ok(doneClaimEntries.length >= 1, 'at least one done-claim sentinel_lock_to_unlock_ms entry emitted (was: never, per F3.3/H2)');
  for (const entry of doneClaimEntries) {
    assert.equal(entry.ctx, 'archival', 'done-claim entries are tagged ctx=archival');
    assert.equal(typeof entry.value_ms, 'number');
    assert.ok(entry.value_ms >= 0);
  }

  // Contrast (best-effort, not required): IF a signal/verdict entry also
  // made it into campaign.jsonl in this run, it must not carry a ctx field —
  // that series stays the true lock->unlock contract. Not asserted as
  // "must be present": in a single-iteration COMPLETING campaign, the
  // loop-top defensive unlock for signal/verdict fires on a second pass
  // that has no subsequent appendIterationAnalytics flush to catch it — a
  // pre-existing flush-ordering gap unrelated to IMP-10 (out of scope here;
  // see the ctx=archival unit coverage above for the mechanism this test
  // pins instead: sentinel_type-based contrast, not "always present").
  const nonDoneClaimEntries = allLockPairs.filter((e) => e.sentinel_type !== doneClaimBasename);
  for (const entry of nonDoneClaimEntries) {
    assert.equal('ctx' in entry, false, `non-done-claim entry (${entry.sentinel_type}) must not carry a ctx field`);
  }
});

// ────────────────────────────────────────────────────────────────────────────
// codex round 2 R2-4 — reapProducer (campaign-main-loop.mjs) computes ONE
// reapMs per reap event and records() it under BOTH pane_eof_to_cleanup_ms
// and pane_reap_latency_ms: same window, not two independent measurements
// (see the corrected README.md metrics table and lifecycle-metrics.mjs's
// own header comment — both previously self-contradicted on where the
// window ends). Only the zsh leader's test suite locked this
// (test_b3_lifecycle_emit.sh case 15); this is the Node-side equality lock.
// waitForProcessExit is overridden with a REAL, measurable delay so the
// equality assertion can't trivially pass on two coincidental zeros (the
// fake dependencies elsewhere in this file resolve instantly).
// ────────────────────────────────────────────────────────────────────────────
test('R2-4: reapProducer records equal value_ms under pane_eof_to_cleanup_ms and pane_reap_latency_ms for the same reap', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  tmux.deps.waitForProcessExit = () => new Promise((resolve) => setTimeout(resolve, 40));
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const enabledCollector = new LifecycleMetricsCollector({
    env: { RLP_LIFECYCLE_METRICS: '1' },
  });

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    lifecycleMetrics: enabledCollector,
    ...tmux.deps,
  });

  const jsonlPath = deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign.jsonl');
  const records = await readJsonl(jsonlPath);
  const firstRecord = records[0];
  const eof = firstRecord.lifecycle_metrics?.pane_eof_to_cleanup_ms;
  const reapLat = firstRecord.lifecycle_metrics?.pane_reap_latency_ms;
  assert.ok(Array.isArray(eof) && eof.length >= 1, 'pane_eof_to_cleanup_ms has at least one entry');
  assert.ok(Array.isArray(reapLat) && reapLat.length >= 1, 'pane_reap_latency_ms has at least one entry');
  assert.equal(
    eof.length,
    reapLat.length,
    'every reap in this fixture is tagged (worker->iter-signal, verifier->verify-verdict), so both arrays are the same length',
  );
  assert.ok(
    eof.some((e) => e.value_ms > 0),
    'at least one reap measured a real non-zero delay (proves the 40ms override actually landed in the measured window, not a trivial 0==0 pass)',
  );
  for (let i = 0; i < eof.length; i++) {
    assert.equal(
      eof[i].value_ms,
      reapLat[i].value_ms,
      `entry ${i}: pane_eof_to_cleanup_ms (${eof[i].value_ms}) must equal pane_reap_latency_ms (${reapLat[i].value_ms}) — same reapMs, same window`,
    );
  }
});

// ────────────────────────────────────────────────────────────────────────────
// AC4.6 — pane_reap_latency_ms emitted only when sentinelType passed
// ────────────────────────────────────────────────────────────────────────────
test('B4 AC4.6: pane_reap_latency_ms includes sentinel_type context', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const enabledCollector = new LifecycleMetricsCollector({
    env: { RLP_LIFECYCLE_METRICS: '1' },
  });

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    lifecycleMetrics: enabledCollector,
    ...tmux.deps,
  });

  const jsonlPath = deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign.jsonl');
  const records = await readJsonl(jsonlPath);
  const firstRecord = records[0];
  const reapLat = firstRecord.lifecycle_metrics?.pane_reap_latency_ms;
  assert.ok(Array.isArray(reapLat), 'pane_reap_latency_ms array present');
  assert.ok(reapLat.length >= 1, 'at least one reap-latency record');
  // Each entry should carry sentinel_type context (the new B4 wiring).
  const sentinelTypes = reapLat.map((e) => e.sentinel_type).filter(Boolean);
  assert.ok(
    sentinelTypes.includes('iter-signal') || sentinelTypes.includes('verify-verdict'),
    `expected sentinel_type in {iter-signal, verify-verdict}, got: ${sentinelTypes.join(',')}`,
  );
});

// ────────────────────────────────────────────────────────────────────────────
// AC4.6 — write_to_read_ms metrics carry iter + us_id audit context.
//
// Note: iter_signal_write_to_read_ms / verdict_write_to_read_ms read the
// sentinel mtime via fsSync.statSync. In stub-injected tests pollForSignal
// returns mocked JSON without touching the filesystem, so the stat call
// fails (ENOENT) and the metric is skipped (fail-open). The actual context-
// shape contract is exercised here by manually pre-writing the signal file
// before run(), which forces the stat path to succeed.
// ────────────────────────────────────────────────────────────────────────────
test('B4 AC4.6: iter_signal_write_to_read_ms carries iter + us_id context', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const enabledCollector = new LifecycleMetricsCollector({
    env: { RLP_LIFECYCLE_METRICS: '1' },
  });

  // Pre-create the signal + verdict + done-claim files so the mtime stat
  // succeeds and the write_to_read_ms metrics fire.
  const signalFile = deskPath(campaign.rootDir, 'memos', `${campaign.slug}-iter-signal.json`);
  const verdictFile = deskPath(campaign.rootDir, 'memos', `${campaign.slug}-verify-verdict.json`);
  const doneClaimFile = deskPath(campaign.rootDir, 'memos', `${campaign.slug}-done-claim.json`);
  await fs.writeFile(signalFile, JSON.stringify({ iteration: 1, status: 'verify' }));
  await fs.writeFile(verdictFile, JSON.stringify({ verdict: 'pass' }));
  await fs.writeFile(doneClaimFile, JSON.stringify({ us_id: 'US-001' }));

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    lifecycleMetrics: enabledCollector,
    ...tmux.deps,
  });

  const jsonlPath = deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign.jsonl');
  const records = await readJsonl(jsonlPath);
  const firstRecord = records[0];
  const writeToRead = firstRecord.lifecycle_metrics?.iter_signal_write_to_read_ms;
  assert.ok(Array.isArray(writeToRead), 'iter_signal_write_to_read_ms array present');
  assert.ok(writeToRead.length >= 1, 'at least one write_to_read entry');
  assert.equal(writeToRead[0].iter, 1, 'iter context = 1');
  assert.equal(writeToRead[0].us_id, 'US-001', 'us_id context = US-001');
  assert.ok(writeToRead[0].value_ms >= 0, 'value_ms is non-negative');
});
