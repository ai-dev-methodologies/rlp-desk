#!/usr/bin/env node
// PR-B3 (v0.15.4) — pre-merge band revalidation harness.
//
// Plan: docs/plans/v0.15-phase-b-plan-v3.md §B3 AC3.5.
// Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §4.2 (synthetic source).
//
// What this does:
//   1. Run 5 iterations of a sandbox campaign with RLP_LIFECYCLE_METRICS=1
//      and real tmux (us006 AC6.1 boundary pattern). pollForSignal is stubbed
//      to return mocked verdicts; sendKeys / killPaneProcess / lockSentinel
//      use the real production helpers so pane_eof_to_cleanup_ms and
//      pane_reap_latency_ms are measured on a real tmux teardown path.
//   2. Read each iter's lifecycle_metrics from campaign.jsonl, aggregate
//      across the 5 iterations, compute p50 / p95 per metric.
//   3. Compare empirical p95 to B1 §4.2 Option-C synthetic p95. If drift
//      exceeds 25%, print a recommended new band value (max(p95×2, floor)).
//
// What this does NOT do:
//   - Real LLM invocation. Worker/verifier panes are launched as plain shells
//     (no claude/codex). The pane process IS real, so killPaneProcess timings
//     are real; only the "produce sentinel" leg is stubbed (mocked poll).
//
// Usage:
//   node tests/sv-real-llm/lib/b3-band-revalidation.mjs
//
// Cost: $0 (no LLM). Wallclock: ~10-30 seconds (real tmux session lifecycle).

import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..', '..');

// B1 §4.2 Option-C synthetic baseline (for comparison).
const SYNTHETIC_P95 = {
  iter_signal_write_to_read_ms: 4750,
  verdict_write_to_read_ms: 4750,
  pane_eof_to_cleanup_ms: 2500,
  pane_reap_latency_ms: 8000,
  // sentinel_lock_to_unlock_ms is per-type and very wide; not refit here.
};

const FIXED_FLOOR_MS = {
  iter_signal_write_to_read_ms: 1000,
  verdict_write_to_read_ms: 1000,
  pane_eof_to_cleanup_ms: 1000,
  pane_reap_latency_ms: 1000,
};

function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, Math.min(idx, sorted.length - 1))];
}

async function makeSandbox() {
  const tempRoot = path.join(REPO_ROOT, '.tmp', 'b3-revalidation');
  await fs.mkdir(tempRoot, { recursive: true });
  const dir = await fs.mkdtemp(path.join(tempRoot, 'run-'));
  return dir;
}

async function setupCampaign(rootDir, slug) {
  const { initCampaign } = await import('../../../src/node/init/campaign-initializer.mjs');
  const prdContent = [
    `# PRD: ${slug}`,
    '',
    '## Objective',
    'B3 band revalidation harness fixture (5 USs to drive 5 iterations)',
    '',
    '## US-001: Story 1',
    'Trivial.',
    '',
    '## US-002: Story 2',
    'Trivial.',
    '',
    '## US-003: Story 3',
    'Trivial.',
    '',
    '## US-004: Story 4',
    'Trivial.',
    '',
    '## US-005: Story 5',
    'Trivial.',
    '',
  ].join('\n');
  await initCampaign(slug, 'B3 revalidation', { rootDir, prdContent });
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

async function run5IterCampaign() {
  const rootDir = await makeSandbox();
  const slug = `b3reval-${Date.now()}`;
  const sessionName = `b3reval-${Date.now()}`;
  console.log(`[harness] sandbox: ${rootDir}`);
  console.log(`[harness] tmux session: ${sessionName}`);

  await setupCampaign(rootDir, slug);

  // Pre-write sentinels so iter_signal_write_to_read_ms / verdict_write_to_
  // read_ms have valid mtime to stat against.
  const memos = path.join(rootDir, '.rlp-desk', 'memos');
  await fs.mkdir(memos, { recursive: true });
  for (let i = 0; i < 5; i++) {
    await fs.writeFile(
      path.join(memos, `${slug}-iter-signal.json`),
      JSON.stringify({ iteration: i + 1, status: 'verify' }),
    );
    await fs.writeFile(
      path.join(memos, `${slug}-verify-verdict.json`),
      JSON.stringify({ verdict: 'pass' }),
    );
    await fs.writeFile(
      path.join(memos, `${slug}-done-claim.json`),
      JSON.stringify({ us_id: 'US-001', iteration: i + 1 }),
    );
  }

  // Build a poll queue that drives the campaign through 5 iterations
  // (one per US-001..US-005). Each iter: 1 worker poll + 1 verifier poll.
  // After the 5th US passes its per-US verify, the final sequential verifier
  // emits its 'complete' verdict.
  const queue = [];
  for (let iter = 1; iter <= 5; iter++) {
    const usId = `US-00${iter}`;
    queue.push({ iteration: iter, status: 'verify', us_id: usId, summary: 'done' });
    queue.push({ verdict: 'pass', recommended_state_transition: 'continue' });
  }
  // Final sequential verifier — one verdict per US verified.
  for (let i = 0; i < 5; i++) {
    queue.push({ verdict: 'pass', recommended_state_transition: i < 4 ? 'continue' : 'complete' });
  }

  const cleanup = async () => {
    try {
      await execFileAsync('tmux', ['kill-session', '-t', sessionName]);
    } catch {}
  };

  // Explicit collector with flag forced on. campaign-main-loop's options.env
  // shadows process.env when present, so we either pass env={...flag} or
  // inject the collector directly. Direct injection is cleaner.
  const { LifecycleMetricsCollector } = await import('../../../src/node/util/lifecycle-metrics.mjs');
  const collector = new LifecycleMetricsCollector({ env: { RLP_LIFECYCLE_METRICS: '1' } });

  try {
    const { run } = await import('../../../src/node/runner/campaign-main-loop.mjs');
    await run(slug, {
      rootDir,
      mode: 'tmux',
      sessionName,
      workerModel: 'gpt-5.5:medium',
      env: { RLP_LIFECYCLE_METRICS: '1' },
      maxIterations: 6,
      pollForSignal: createPoller(queue),
      runIntegrationCheck: async () => ({ exitCode: 0 }),
      lifecycleMetrics: collector,
    });
  } catch (err) {
    console.error(`[harness] campaign error (may be expected): ${err.message}`);
  } finally {
    await cleanup();
  }

  const jsonlPath = path.join(rootDir, '.rlp-desk', 'logs', slug, 'campaign.jsonl');
  return { jsonlPath, rootDir };
}

async function aggregateMetrics(jsonlPath) {
  const content = await fs.readFile(jsonlPath, 'utf8');
  const records = content.trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
  console.log(`[harness] campaign.jsonl records: ${records.length}`);

  const buckets = {
    iter_signal_write_to_read_ms: [],
    verdict_write_to_read_ms: [],
    pane_eof_to_cleanup_ms: [],
    pane_reap_latency_ms: [],
  };

  for (const r of records) {
    const lm = r.lifecycle_metrics;
    if (!lm || typeof lm !== 'object') continue;
    for (const metric of Object.keys(buckets)) {
      const entries = lm[metric] || [];
      for (const e of entries) {
        if (typeof e?.value_ms === 'number') buckets[metric].push(e.value_ms);
      }
    }
  }
  return buckets;
}

function reportMetric(name, samples) {
  if (samples.length === 0) {
    console.log(`  ${name.padEnd(35)}  no samples`);
    return null;
  }
  const sorted = [...samples].sort((a, b) => a - b);
  const p50 = percentile(sorted, 50);
  const p95 = percentile(sorted, 95);
  const synthP95 = SYNTHETIC_P95[name];
  const drift = synthP95 ? ((p95 - synthP95) / synthP95) * 100 : null;
  const driftStr = drift === null ? 'n/a' : `${drift >= 0 ? '+' : ''}${drift.toFixed(0)}%`;
  const breaches = drift !== null && Math.abs(drift) > 25;
  const recommendedBand = Math.max(p95 * 2, FIXED_FLOOR_MS[name] ?? 1000);

  console.log(
    `  ${name.padEnd(35)}  N=${String(samples.length).padStart(3)} ` +
    `p50=${String(p50).padStart(6)}ms p95=${String(p95).padStart(6)}ms ` +
    `synth_p95=${String(synthP95).padStart(5)} drift=${driftStr.padStart(7)} ` +
    (breaches ? `*BREACH* recommended_band=${Math.round(recommendedBand)}ms` : 'within ±25%'),
  );

  return { name, p50, p95, synthP95, drift, breaches, recommendedBand };
}

async function main() {
  console.log('━━━ B3 pre-merge band revalidation ━━━');
  console.log(`[harness] running 5-iter sandbox campaign with RLP_LIFECYCLE_METRICS=1`);

  const { jsonlPath } = await run5IterCampaign();

  console.log(`\n[harness] reading lifecycle_metrics from ${jsonlPath}`);
  let buckets;
  try {
    buckets = await aggregateMetrics(jsonlPath);
  } catch (err) {
    console.error(`[harness] FAILED to read campaign.jsonl: ${err.message}`);
    console.error(`[harness] campaign likely failed before any iteration completed.`);
    process.exit(1);
  }

  console.log(`\n[harness] empirical vs synthetic (B1 §4.2):`);
  const reports = [];
  for (const name of Object.keys(buckets)) {
    const r = reportMetric(name, buckets[name]);
    if (r) reports.push(r);
  }

  console.log(`\n[harness] summary:`);
  const breaches = reports.filter((r) => r?.breaches);
  if (breaches.length === 0) {
    console.log(`  PASS: all empirical p95 within ±25% of synthetic baseline.`);
    console.log(`  No band update required. B3 ready for merge.`);
  } else {
    console.log(`  DRIFT: ${breaches.length} metric(s) exceed ±25% threshold. Update B3_BAND_*_MS:`);
    for (const r of breaches) {
      console.log(`    ${r.name}: synthetic p95×2=${r.synthP95 * 2}ms → recommended ${r.recommendedBand}ms`);
    }
  }
  process.exit(breaches.length > 0 ? 2 : 0);
}

main().catch((err) => {
  console.error('[harness] fatal:', err);
  process.exit(1);
});
