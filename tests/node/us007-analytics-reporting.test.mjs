import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'us007-analytics-reporting-tests');
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

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

async function readText(filePath) {
  return fs.readFile(filePath, 'utf8');
}

function createPoller(queue) {
  return async function pollForSignal(targetPath) {
    if (queue.length === 0) {
      throw new Error(`No queued poll result for ${targetPath}`);
    }

    const next = queue.shift();
    if (next instanceof Error) {
      throw next;
    }

    return next;
  };
}

function createTmuxFakes() {
  return {
    deps: {
      createSession: async ({ sessionName }) => ({
        sessionName,
        leaderPaneId: '%leader',
      }),
      createPane: async ({ layout }) => (layout === 'horizontal' ? '%worker' : '%verifier'),
      sendKeys: async () => {},
    },
  };
}

async function setupCampaign(t, options = {}) {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  const objective = options.objective ?? 'Ship the Node rewrite';
  const slug = options.slug ?? 'test-slug';
  const sections = options.sections ?? [
    '## US-001: First story\nAlpha details.',
  ];

  const prdContent = [
    `# PRD: ${slug}`,
    '',
    '## Objective',
    objective,
    '',
    ...sections,
    '',
  ].join('\n');

  await initCampaign(slug, objective, {
    rootDir,
    tmuxEnv: 'tmux-test-session',
    prdContent,
  });

  return { rootDir, slug, objective };
}

test('US-007 AC7.1 happy: completing a five-iteration campaign writes campaign-report.md with all eight required sections', async (t) => {
  const campaign = await setupCampaign(t, {
    sections: [
      '## US-001: First story\nAlpha details.',
      '## US-002: Second story\nBeta details.',
      '## US-003: Third story\nGamma details.',
    ],
  });
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    maxIterations: 6,
    now: new Date('2026-04-12T00:00:00Z'),
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'first attempt' },
      { verdict: 'fail', recommended_state_transition: 'continue', issues: [] },
      { iteration: 2, status: 'verify', us_id: 'US-001', summary: 'fixed' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 3, status: 'verify', us_id: 'US-002', summary: 'first attempt' },
      { verdict: 'fail', recommended_state_transition: 'continue', issues: [] },
      { iteration: 4, status: 'verify', us_id: 'US-002', summary: 'fixed' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 5, status: 'verify', us_id: 'US-003', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0, summary: 'all green' }),
    ...tmux.deps,
    sendRawKey: async () => {},
    killPaneProcess: async () => {},
    waitForProcessExit: async () => {},
  });

  const report = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign-report.md'),
  );

  assert.match(report, /## Objective/);
  assert.match(report, /## Execution Summary/);
  assert.match(report, /## US Status/);
  assert.match(report, /## Verification Results/);
  assert.match(report, /## Issues Encountered/);
  assert.match(report, /## Cost & Performance/);
  assert.match(report, /## SV Summary/);
  assert.match(report, /## Files Changed/);
  assert.match(report, /Iterations run: 5/);
});

test('US-007 AC7.1 boundary: generateCampaignReport still writes all eight sections for an empty campaign', async (t) => {
  const rootDir = await createTempDir(t);
  const deskRoot = deskPath(rootDir);
  await fs.mkdir(path.join(deskRoot, 'logs', 'empty-slug', 'runtime'), { recursive: true });
  await fs.mkdir(path.join(deskRoot, 'plans'), { recursive: true });
  const { generateCampaignReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  const prdFile = path.join(deskRoot, 'plans', 'prd-empty-slug.md');
  const statusFile = path.join(deskRoot, 'logs', 'empty-slug', 'runtime', 'status.json');
  await fs.writeFile(prdFile, '# PRD: empty-slug\n\n## Objective\nShip nothing yet.\n', 'utf8');
  await fs.writeFile(statusFile, JSON.stringify({
    slug: 'empty-slug',
    iteration: 0,
    max_iterations: 100,
    phase: 'idle',
    worker_model: 'gpt-5.5:medium',
    verifier_model: 'sonnet',
    final_verifier_model: 'opus',
    verified_us: [],
    consecutive_failures: 0,
    started_at_utc: '2026-04-12T00:00:00.000Z',
    updated_at_utc: '2026-04-12T00:00:00.000Z',
  }, null, 2), 'utf8');

  await generateCampaignReport({
    slug: 'empty-slug',
    reportFile: path.join(deskRoot, 'logs', 'empty-slug', 'campaign-report.md'),
    prdFile,
    statusFile,
    analyticsFile: path.join(deskRoot, 'logs', 'empty-slug', 'campaign.jsonl'),
    now: new Date('2026-04-12T00:00:00Z'),
    gitDiffProvider: async () => '',
  });

  const report = await readText(path.join(deskRoot, 'logs', 'empty-slug', 'campaign-report.md'));
  const sections = (report.match(/^## /gm) ?? []).length;
  assert.equal(sections, 8);
});

test('US-007 AC7.1 negative: generating a new campaign report versions the previous report first', async (t) => {
  const rootDir = await createTempDir(t);
  const deskRoot = deskPath(rootDir);
  await fs.mkdir(path.join(deskRoot, 'logs', 'versioned-slug', 'runtime'), { recursive: true });
  await fs.mkdir(path.join(deskRoot, 'plans'), { recursive: true });
  const { generateCampaignReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  const reportFile = path.join(deskRoot, 'logs', 'versioned-slug', 'campaign-report.md');
  const prdFile = path.join(deskRoot, 'plans', 'prd-versioned-slug.md');
  const statusFile = path.join(deskRoot, 'logs', 'versioned-slug', 'runtime', 'status.json');

  await fs.writeFile(reportFile, 'old report\n', 'utf8');
  await fs.writeFile(prdFile, '# PRD: versioned-slug\n\n## Objective\nShip versioning.\n', 'utf8');
  await fs.writeFile(statusFile, JSON.stringify({
    slug: 'versioned-slug',
    iteration: 1,
    max_iterations: 100,
    phase: 'complete',
    worker_model: 'gpt-5.5:medium',
    verifier_model: 'sonnet',
    final_verifier_model: 'opus',
    verified_us: ['US-001'],
    consecutive_failures: 0,
    started_at_utc: '2026-04-12T00:00:00.000Z',
    updated_at_utc: '2026-04-12T00:00:10.000Z',
  }, null, 2), 'utf8');

  await generateCampaignReport({
    slug: 'versioned-slug',
    reportFile,
    prdFile,
    statusFile,
    analyticsFile: path.join(deskRoot, 'logs', 'versioned-slug', 'campaign.jsonl'),
    now: new Date('2026-04-12T00:00:10Z'),
    gitDiffProvider: async () => '',
  });

  assert.equal(await readText(path.join(deskRoot, 'logs', 'versioned-slug', 'campaign-report-v1.md')), 'old report\n');
});

test('US-007 AC7.2 happy: the runner appends one valid analytics JSON line per completed iteration', async (t) => {
  const campaign = await setupCampaign(t, {
    sections: [
      '## US-001: First story\nAlpha details.',
      '## US-002: Second story\nBeta details.',
    ],
  });
  const tmux = createTmuxFakes();
  const originalDateNow = Date.now;
  let clockNow = 1_000_000;
  let pollIndex = 0;
  const pollQueue = [
    { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
    { verdict: 'pass', recommended_state_transition: 'continue' },
    { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
    { verdict: 'pass', recommended_state_transition: 'continue' },
    { verdict: 'pass', recommended_state_transition: 'continue' },
    { verdict: 'pass', recommended_state_transition: 'complete' },
  ];
  const pollNext = createPoller(pollQueue);
  Date.now = () => clockNow;
  t.after(() => {
    Date.now = originalDateNow;
  });
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    maxIterations: 3,
    now: new Date('2026-04-12T00:00:00Z'),
    pollForSignal: async (targetPath) => {
      // The first four polls are two worker+verifier iterations. Each pair
      // advances the mocked clock by 2.5s + 4.5s = 7s.
      if (pollIndex === 0 || pollIndex === 2) clockNow += 2_500;
      if (pollIndex === 1 || pollIndex === 3) clockNow += 4_500;
      pollIndex += 1;
      return pollNext(targetPath);
    },
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    // v0.22.4: the RLP_LIFECYCLE_METRICS flag is REMOVED — passing the old
    // opt-out here proves the env is ignored (field is an object, never null).
    env: { RLP_LIFECYCLE_METRICS: '0' },
    ...tmux.deps,
    sendRawKey: async () => {},
    killPaneProcess: async () => {},
    waitForProcessExit: async () => {},
  });

  const analyticsFile = deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign.jsonl');
  const lines = (await readText(analyticsFile)).trim().split('\n').map((line) => JSON.parse(line));

  assert.equal(lines.length, 2);
  // v0.15.4 PR-B4 schema, v0.22.4 semantics: lifecycle_metrics is ALWAYS an
  // object ({} when the iteration produced no records) — the opt-out is gone.
  // G1.g/G1.h: estimated_tokens + token_source are now REQUIRED on every row
  // (see appendIterationAnalytics's isWorkerDispatch guard) — these are real
  // worker-dispatch iterations, so token_source is 'estimated'.
  assert.deepEqual(Object.keys(lines[0]).sort(), [
    'duration',
    'estimated_tokens',
    'iter',
    'lifecycle_metrics',
    'timestamp',
    'token_source',
    'us_id',
    'verdict',
    'worker_engine',
    'worker_model',
  ]);
  assert.equal(lines[0].iter, 1);
  assert.equal(lines[1].iter, 2);
  assert.equal(lines[0].duration, 7);
  assert.equal(lines[1].duration, 7);
  assert.equal(lines[0].token_source, 'estimated');
  // v0.22.4: the removed flag cannot null the field any more.
  assert.notEqual(lines[0].lifecycle_metrics, null, 'opt-out env must be ignored');
  assert.equal(typeof lines[0].lifecycle_metrics, 'object');
});

test('g-dogfood US-001 AC2 boundary: sub-second worker+verifier duration remains zero', async (t) => {
  const rootDir = await createTempDir(t);
  const { buildPaths, appendIterationAnalytics } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const paths = buildPaths(rootDir, 'g-dogfood-zero-duration');
  const state = { iteration: 1, worker_model: 'gpt-5.6-luna:high' };

  await appendIterationAnalytics(
    paths,
    state,
    'US-001',
    'pass',
    { now: new Date('2026-08-09T00:00:00Z') },
    null,
    true,
    0,
  );

  const row = JSON.parse((await fs.readFile(paths.analyticsFile, 'utf8')).trim());
  assert.equal(row.duration, 0);
});

test('US-007 AC7.2 boundary: starting a new campaign versions an existing campaign.jsonl before appending fresh analytics', async (t) => {
  const rootDir = await createTempDir(t);
  const deskRoot = deskPath(rootDir);
  await fs.mkdir(path.join(deskRoot, 'logs', 'analytics-slug'), { recursive: true });
  const { prepareCampaignAnalytics } = await import('../../src/node/reporting/campaign-reporting.mjs');

  const analyticsFile = path.join(deskRoot, 'logs', 'analytics-slug', 'campaign.jsonl');
  await fs.writeFile(analyticsFile, '{"iter":99}\n', 'utf8');

  await prepareCampaignAnalytics({
    analyticsFile,
    statusFile: path.join(deskRoot, 'logs', 'analytics-slug', 'runtime', 'status.json'),
  });

  assert.equal(await readText(path.join(deskRoot, 'logs', 'analytics-slug', 'campaign-v1.jsonl')), '{"iter":99}\n');
});

test('US-007 AC7.2 negative: appendCampaignAnalytics rejects records that omit required fields', async (t) => {
  const rootDir = await createTempDir(t);
  const analyticsFile = deskPath(rootDir, 'logs', 'bad-slug', 'campaign.jsonl');
  const { appendCampaignAnalytics } = await import('../../src/node/reporting/campaign-reporting.mjs');

  await assert.rejects(
    appendCampaignAnalytics(analyticsFile, {
      iter: 1,
      us_id: 'US-001',
      verdict: 'pass',
      worker_model: 'gpt-5.5:medium',
      worker_engine: 'codex',
      duration: 2,
    }),
    /timestamp/i,
  );
});

test('US-007 AC7.3 happy: readStatus renders iteration, phase, models, verified_us, consecutive_failures, and elapsed time', async (t) => {
  const rootDir = await createTempDir(t);
  const statusFile = deskPath(rootDir, 'logs', 'status-slug', 'runtime', 'status.json');
  await fs.mkdir(path.dirname(statusFile), { recursive: true });
  await fs.writeFile(statusFile, JSON.stringify({
    slug: 'status-slug',
    iteration: 4,
    max_iterations: 9,
    phase: 'verifier',
    worker_model: 'gpt-5.5:high',
    verifier_model: 'sonnet',
    final_verifier_model: 'opus',
    verified_us: ['US-001', 'US-002'],
    consecutive_failures: 1,
    started_at_utc: '2026-04-12T00:00:00.000Z',
    updated_at_utc: '2026-04-12T00:02:30.000Z',
  }, null, 2), 'utf8');

  const { readStatus } = await import('../../src/node/reporting/campaign-reporting.mjs');
  const output = await readStatus('status-slug', {
    rootDir,
    now: new Date('2026-04-12T00:03:00Z'),
  });

  assert.match(output, /Campaign: status-slug/);
  assert.match(output, /Iteration: 4 \/ 9/);
  assert.match(output, /Phase: verifier/);
  assert.match(output, /Worker Model: gpt-5\.5:high/);
  assert.match(output, /Verified US: US-001, US-002/);
  assert.match(output, /Consecutive Failures: 1/);
  assert.match(output, /elapsed: 30s/);
  // This fixture has no escalation_eligible_failures (the shape the zsh leader
  // writes). The line must be omitted rather than fabricating a 0, which next
  // to a non-zero failure count would read as "every failure was environment".
  assert.doesNotMatch(output, /Escalation-Eligible Failures/);
});

test('US-007 AC7.3: readStatus surfaces escalation-eligible failures when the leader persists them', async (t) => {
  const rootDir = await createTempDir(t);
  const statusFile = deskPath(rootDir, 'logs', 'esc-slug', 'runtime', 'status.json');
  await fs.mkdir(path.dirname(statusFile), { recursive: true });
  await fs.writeFile(statusFile, JSON.stringify({
    slug: 'esc-slug',
    iteration: 7,
    max_iterations: 9,
    phase: 'worker',
    worker_model: 'gpt-5.6-luna:high',
    verifier_model: 'claude-sonnet-5:high',
    verified_us: [],
    // Luna-first §2.5 dual counter: six failures, only one of them eligible —
    // this is exactly the "why hasn't the ladder climbed?" case the line exists
    // to explain.
    consecutive_failures: 6,
    escalation_eligible_failures: 1,
    started_at_utc: '2026-04-12T00:00:00.000Z',
    updated_at_utc: '2026-04-12T00:02:30.000Z',
  }, null, 2), 'utf8');

  const { readStatus } = await import('../../src/node/reporting/campaign-reporting.mjs');
  const output = await readStatus('esc-slug', {
    rootDir,
    now: new Date('2026-04-12T00:03:00Z'),
  });

  assert.match(output, /Consecutive Failures: 6/);
  assert.match(output, /Escalation-Eligible Failures: 1/);
  // Ordering: the two counters must read together, eligible directly below.
  assert.match(output, /Consecutive Failures: 6\nEscalation-Eligible Failures: 1/);
});

test('US-007 AC7.3 boundary: readStatus reports no active campaign when status.json does not exist', async (t) => {
  const rootDir = await createTempDir(t);
  const { readStatus } = await import('../../src/node/reporting/campaign-reporting.mjs');

  const output = await readStatus('missing-slug', { rootDir });
  assert.equal(output, 'No active campaign for missing-slug.');
});

test('US-007 AC7.3 negative: readStatus handles a corrupt status.json without throwing', async (t) => {
  const rootDir = await createTempDir(t);
  const statusFile = deskPath(rootDir, 'logs', 'corrupt-slug', 'runtime', 'status.json');
  await fs.mkdir(path.dirname(statusFile), { recursive: true });
  await fs.writeFile(statusFile, '{bad json', 'utf8');

  const { readStatus } = await import('../../src/node/reporting/campaign-reporting.mjs');
  const output = await readStatus('corrupt-slug', { rootDir });

  assert.match(output, /status\.json is corrupt/i);
});

// =============================================================================
// G1-4: Node-leader sol-equivalent cost summary parity (dogfood-gaps-g1-g4.md
// §G1-4/G1.g-i). appendIterationAnalytics is called directly (exported for
// this purpose) rather than driving a full campaign via run() — cheap and
// targeted, avoids the multi-minute end-to-end harness above.
// =============================================================================

test('g1-node: analytics record carries estimated_tokens and token_source on a real worker-dispatch row', async (t) => {
  const rootDir = await createTempDir(t);
  const { buildPaths, appendIterationAnalytics } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const paths = buildPaths(rootDir, 'g1-slug');
  await fs.mkdir(paths.campaignLogDir, { recursive: true });
  await fs.mkdir(path.dirname(paths.doneClaimFile), { recursive: true });

  // Iteration 1's rendered prompt (8 bytes) + done-claim (4 bytes) + verdict
  // (4 bytes) = 16 bytes / 4 = 4 estimated tokens (C1 basis).
  const promptFile = path.join(paths.campaignLogDir, 'iter-001.worker-prompt.md');
  await fs.writeFile(promptFile, '12345678', 'utf8');
  await fs.writeFile(paths.doneClaimFile, '1234', 'utf8');
  await fs.writeFile(paths.verdictFile, '1234', 'utf8');

  const state = { iteration: 1, worker_model: 'gpt-5.6-luna:high' };
  await appendIterationAnalytics(paths, state, 'US-001', 'pass', { now: new Date('2026-08-09T00:00:00Z') });

  const rows = (await fs.readFile(paths.analyticsFile, 'utf8')).trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(rows.length, 1);
  assert.equal(rows[0].estimated_tokens, 4);
  assert.equal(rows[0].token_source, 'estimated');
});

test('g1-node: zero-byte iteration is accepted (0 is not treated as missing)', async (t) => {
  const rootDir = await createTempDir(t);
  const { buildPaths, appendIterationAnalytics } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const paths = buildPaths(rootDir, 'g1-zero-slug');
  await fs.mkdir(paths.campaignLogDir, { recursive: true });
  // No prompt/done-claim/verdict files written at all -> every artifact
  // contributes 0 bytes -> estimated_tokens: 0. appendCampaignAnalytics's
  // strict undefined/null/'' check must NOT reject a genuine 0.
  const state = { iteration: 1, worker_model: 'gpt-5.6-luna:high' };

  await assert.doesNotReject(
    appendIterationAnalytics(paths, state, 'US-001', 'pass', { now: new Date('2026-08-09T00:00:00Z') }),
  );

  const rows = (await fs.readFile(paths.analyticsFile, 'utf8')).trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(rows[0].estimated_tokens, 0);
  assert.equal(rows[0].token_source, 'estimated');
});

test('g1-node: a non-worker-dispatch row (lane_violation_warning shape) is excluded from token accounting', async (t) => {
  const rootDir = await createTempDir(t);
  const { buildPaths, appendIterationAnalytics } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const paths = buildPaths(rootDir, 'g1-nonworker-slug');
  await fs.mkdir(paths.campaignLogDir, { recursive: true });
  await fs.mkdir(path.dirname(paths.doneClaimFile), { recursive: true });
  // A STALE prior-iteration prompt file with real bytes — if this leaked into
  // the estimate, the C2 exclusion guard would have failed to do its job.
  await fs.writeFile(path.join(paths.campaignLogDir, 'iter-001.worker-prompt.md'), '12345678', 'utf8');

  const state = { iteration: 1, worker_model: 'gpt-5.6-luna:high' };
  await appendIterationAnalytics(
    paths, state, 'ALL', 'lane_violation_warning',
    { now: new Date('2026-08-09T00:00:00Z') }, null, /* isWorkerDispatch */ false,
  );

  const rows = (await fs.readFile(paths.analyticsFile, 'utf8')).trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(rows[0].estimated_tokens, 0, 'must not charge the stale iter-001 prompt bytes to a non-dispatch row');
  assert.equal(rows[0].token_source, 'none');
});

async function writeAnalyticsLines(analyticsFile, records) {
  await fs.mkdir(path.dirname(analyticsFile), { recursive: true });
  await fs.writeFile(analyticsFile, `${records.map((r) => JSON.stringify(r)).join('\n')}\n`, 'utf8');
}

test('g1-node: summarizeCost emits sol-equivalent from campaign.jsonl rows', async (t) => {
  const rootDir = await createTempDir(t);
  const deskRoot = deskPath(rootDir);
  const analyticsFile = path.join(deskRoot, 'logs', 'g1-cost-slug', 'campaign.jsonl');
  const reportFile = path.join(deskRoot, 'logs', 'g1-cost-slug', 'campaign-report.md');
  const prdFile = path.join(deskRoot, 'plans', 'prd-g1-cost-slug.md');
  const statusFile = path.join(deskRoot, 'logs', 'g1-cost-slug', 'runtime', 'status.json');

  // luna 1000 (x0.04=40) + terra 1000 (x0.4=400) + sol 1000 (x1.0=1000) = 1440,
  // same fixture matrix as the zsh g1 "mixed families sum correctly" test.
  await writeAnalyticsLines(analyticsFile, [
    { iter: 1, us_id: 'US-001', worker_model: 'gpt-5.6-luna', worker_engine: 'codex', verdict: 'pass', duration: 1, timestamp: 't1', estimated_tokens: 1000, token_source: 'estimated' },
    { iter: 2, us_id: 'US-001', worker_model: 'gpt-5.6-terra', worker_engine: 'codex', verdict: 'pass', duration: 1, timestamp: 't2', estimated_tokens: 1000, token_source: 'estimated' },
    { iter: 3, us_id: 'US-001', worker_model: 'gpt-5.6-sol', worker_engine: 'codex', verdict: 'pass', duration: 1, timestamp: 't3', estimated_tokens: 1000, token_source: 'estimated' },
  ]);

  const { generateCampaignReport } = await import('../../src/node/reporting/campaign-reporting.mjs');
  await generateCampaignReport({ slug: 'g1-cost-slug', reportFile, prdFile, statusFile, analyticsFile, now: new Date('2026-08-09T00:00:00Z') });

  const report = await fs.readFile(reportFile, 'utf8');
  assert.match(report, /Codex legs sol-equivalent: 1440 tokens/);
});

test('g1-node: summarizeCost emits the unattributed reconciliation line on rows lacking tokens', async (t) => {
  const rootDir = await createTempDir(t);
  const deskRoot = deskPath(rootDir);
  const analyticsFile = path.join(deskRoot, 'logs', 'g1-reconcile-slug', 'campaign.jsonl');
  const reportFile = path.join(deskRoot, 'logs', 'g1-reconcile-slug', 'campaign-report.md');
  const prdFile = path.join(deskRoot, 'plans', 'prd-g1-reconcile-slug.md');
  const statusFile = path.join(deskRoot, 'logs', 'g1-reconcile-slug', 'runtime', 'status.json');

  await writeAnalyticsLines(analyticsFile, [
    // Legacy row: no token_source field at all (written before G1 shipped).
    { iter: 1, us_id: 'US-001', worker_model: 'gpt-5.6-luna', worker_engine: 'codex', verdict: 'pass', duration: 1, timestamp: 't1' },
    { iter: 2, us_id: 'US-001', worker_model: 'gpt-5.6-luna', worker_engine: 'codex', verdict: 'pass', duration: 1, timestamp: 't2', estimated_tokens: 1000, token_source: 'estimated' },
  ]);

  const { generateCampaignReport } = await import('../../src/node/reporting/campaign-reporting.mjs');
  await generateCampaignReport({ slug: 'g1-reconcile-slug', reportFile, prdFile, statusFile, analyticsFile, now: new Date('2026-08-09T00:00:00Z') });

  const report = await fs.readFile(reportFile, 'utf8');
  assert.match(report, /\(1 iteration\(s\) unattributed\)/);
});

test('g1-node: models.json cost_factors has the three families (shared-table pin)', async () => {
  const { loadCostFactors, defaultShippedModelsFile } = await import('../../src/node/model-ladder.mjs');
  // Hermeticity: force a guaranteed-nonexistent override so this pins the
  // real shipped table regardless of ambient RLP_DESK_MODELS_FILE state
  // (same guard pattern as models-ladder.test.mjs).
  const nonexistentOverride = path.join(repoRoot, '.tmp', 'us007-g1-cost-factors-test', 'does-not-exist.json');
  const costFactors = loadCostFactors({ overrideFile: nonexistentOverride, shippedFile: defaultShippedModelsFile() });

  assert.equal(costFactors['gpt-5.6-sol'], 1.0);
  assert.equal(costFactors['gpt-5.6-terra'], 0.4);
  assert.equal(costFactors['gpt-5.6-luna'], 0.04);
});
