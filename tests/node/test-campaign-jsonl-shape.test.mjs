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
// Asserts the campaign.jsonl per-iter record shape under both flag states
// (v0.15.5 full-wire: RLP_LIFECYCLE_METRICS now defaults ON; "0" is the sole
// opt-out — see src/node/util/lifecycle-metrics.mjs):
//   - Flag "0" (explicit opt-out): lifecycle_metrics field is null. Existing
//                analytics consumers see no breakage.
//   - Flag ON (unset, or any value other than "0"): lifecycle_metrics is an
//                object grouped by metric name; each value is an array of
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
// AC4.3 / AC4.7 — Flag explicitly disabled: lifecycle_metrics is null (no breakage)
// v0.15.5 full-wire: RLP_LIFECYCLE_METRICS now defaults ON, so "flag unset" no
// longer produces the disabled/null shape — an explicit "0" opt-out does.
// ────────────────────────────────────────────────────────────────────────────
test('B4 AC4.3/4.7: lifecycle_metrics is null when explicitly disabled (RLP_LIFECYCLE_METRICS=0)', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  // Inject an explicitly-disabled collector deterministically (the test
  // process's ambient env now defaults to ENABLED, so "env: {}" would no
  // longer simulate the disabled path).
  const disabledCollector = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '0' } });

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
    lifecycleMetrics: disabledCollector,
    ...tmux.deps,
  });

  const jsonlPath = deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign.jsonl');
  const records = await readJsonl(jsonlPath);
  assert.ok(records.length >= 1, 'campaign.jsonl has at least one iter record');
  for (const r of records) {
    assert.ok('lifecycle_metrics' in r, 'each record carries lifecycle_metrics field');
    assert.equal(r.lifecycle_metrics, null, 'lifecycle_metrics is null when collector disabled');
  }
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
