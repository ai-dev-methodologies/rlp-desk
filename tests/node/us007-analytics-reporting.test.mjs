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
  return path.join(rootDir, '.claude', 'ralph-desk', ...segments);
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
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    maxIterations: 3,
    now: new Date('2026-04-12T00:00:00Z'),
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  const analyticsFile = deskPath(campaign.rootDir, 'logs', campaign.slug, 'campaign.jsonl');
  const lines = (await readText(analyticsFile)).trim().split('\n').map((line) => JSON.parse(line));

  assert.equal(lines.length, 2);
  assert.deepEqual(Object.keys(lines[0]).sort(), [
    'duration',
    'iter',
    'timestamp',
    'us_id',
    'verdict',
    'worker_engine',
    'worker_model',
  ]);
  assert.equal(lines[0].iter, 1);
  assert.equal(lines[1].iter, 2);
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
