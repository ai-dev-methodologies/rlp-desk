import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'us006-campaign-main-loop-tests');
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
    tmuxEnv: options.tmuxEnv ?? 'tmux-test-session',
    prdContent,
  });

  return {
    rootDir,
    slug,
    objective,
  };
}

function createTmuxFakes() {
  const commands = [];
  const sessions = [];
  const paneIds = ['%worker', '%verifier'];
  const createdPanes = [];

  return {
    commands,
    sessions,
    createdPanes,
    deps: {
      createSession: async ({ sessionName, workingDir }) => {
        sessions.push({ sessionName, workingDir });
        return { sessionName, leaderPaneId: '%leader' };
      },
      createPane: async ({ targetPaneId, layout }) => {
        const paneId = paneIds.shift();
        createdPanes.push({ targetPaneId, layout, paneId });
        return paneId;
      },
      sendKeys: async (paneId, command) => {
        commands.push({ paneId, command });
      },
    },
  };
}

test('US-006 AC6.1 happy: run creates the tmux panes, launches the worker with codex flags, and writes worker status', async (t) => {
  const campaign = await setupCampaign(t);
  const statusHistory = [];
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    onStatusChange: (status) => statusHistory.push({ ...status }),
    ...tmux.deps,
  });

  assert.equal(tmux.sessions.length, 1);
  assert.deepEqual(
    tmux.createdPanes.map(({ layout }) => layout),
    ['horizontal', 'vertical'],
  );

  const workerCommand = tmux.commands.find((entry) => entry.paneId === '%worker')?.command ?? '';
  assert.match(workerCommand, /codex -m gpt-5\.4/);
  assert.match(workerCommand, /model_reasoning_effort="medium"/);
  assert.match(workerCommand, /--disable plugins --dangerously-bypass-approvals-and-sandbox/);
  assert.match(workerCommand, /iter-001\.worker-prompt\.md/);

  assert.equal(statusHistory[0].iteration, 1);
  assert.equal(statusHistory[0].phase, 'worker');

  const statusFile = deskPath(campaign.rootDir, 'logs', campaign.slug, 'runtime', 'status.json');
  const status = await readJson(statusFile);
  assert.equal(status.phase, 'complete');
});

test('US-006 AC6.1 boundary: run can create a real tmux session with three panes before continuing the campaign', async (t) => {
  const campaign = await setupCampaign(t);
  const sessionName = `us006-${Date.now()}`;
  const sendCommands = [];
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  t.after(async () => {
    await execFileAsync('tmux', ['kill-session', '-t', sessionName]).catch(() => {});
  });

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    sessionName,
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    sendKeys: async (paneId, command) => {
      sendCommands.push({ paneId, command });
    },
    runIntegrationCheck: async () => ({ exitCode: 0 }),
  });

  const { stdout } = await execFileAsync('tmux', ['list-panes', '-t', sessionName, '-F', '#{pane_id}']);
  const paneIds = stdout.trim().split('\n').filter(Boolean);

  assert.equal(paneIds.length, 3);
  assert.match(sendCommands[0].command, /gpt-5\.4/);
});

test('US-006 AC6.1 negative: run rejects a missing scaffold before it creates tmux state', async (t) => {
  const campaign = await setupCampaign(t);
  const missingPrompt = deskPath(campaign.rootDir, 'prompts', `${campaign.slug}.worker.prompt.md`);
  await fs.rm(missingPrompt);

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await assert.rejects(
    run(campaign.slug, {
      rootDir: campaign.rootDir,
      mode: 'tmux',
      workerModel: 'gpt-5.4:medium',
      pollForSignal: createPoller([]),
      runIntegrationCheck: async () => ({ exitCode: 0 }),
      ...tmux.deps,
    }),
    /missing required scaffold/i,
  );

  assert.equal(tmux.sessions.length, 0);
});

test('US-006 AC6.2 happy: a worker verify signal launches a verifier prompt scoped to the completed US and advances to the next story on pass', async (t) => {
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
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  const firstVerifierPrompt = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'iter-001.verifier-prompt.md'),
  );
  const secondWorkerPrompt = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'iter-002.worker-prompt.md'),
  );
  const status = await readJson(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'runtime', 'status.json'),
  );

  assert.match(firstVerifierPrompt, /Verify ONLY the acceptance criteria for \*\*US-001\*\*/);
  assert.match(secondWorkerPrompt, /You MUST implement ONLY \*\*US-002\*\* in this iteration\./);
  assert.deepEqual(status.verified_us, ['US-001', 'US-002']);
});

test('US-006 AC6.2 boundary: a codex worker timeout falls back to verifying the current US so the loop can continue', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      new TimeoutError('codex worker exited before writing a signal'),
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  const verifierPrompt = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'iter-001.verifier-prompt.md'),
  );
  assert.match(verifierPrompt, /Verify ONLY the acceptance criteria for \*\*US-001\*\*/);
});

test('US-006 AC6.2 negative: a failing verdict writes a fix contract and retries the same US before moving on', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      {
        verdict: 'fail',
        recommended_state_transition: 'continue',
        issues: [
          {
            severity: 'major',
            criterion_id: 'AC-6.2',
            summary: 'Verifier found a regression',
            fix_hint: 'Restore the scoped verifier prompt',
          },
        ],
      },
      { iteration: 2, status: 'verify', us_id: 'US-001', summary: 'fixed' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  const fixContract = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'iter-001.fix-contract.md'),
  );
  const retryPrompt = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'iter-002.worker-prompt.md'),
  );

  assert.match(fixContract, /AC-6\.2/);
  assert.match(fixContract, /Restore the scoped verifier prompt/);
  assert.match(retryPrompt, /Fix Contract from Verifier \(iteration 1\)/);
  assert.match(retryPrompt, /You MUST implement ONLY \*\*US-001\*\* in this iteration\./);
});

test('US-006 AC6.3 happy: three consecutive failures on the same US upgrade the worker model from medium to high', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const statusHistory = [];
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'fail', recommended_state_transition: 'continue', issues: [] },
      { iteration: 2, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'fail', recommended_state_transition: 'continue', issues: [] },
      { iteration: 3, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'fail', recommended_state_transition: 'continue', issues: [] },
      { iteration: 4, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    onStatusChange: (status) => statusHistory.push({ ...status }),
    ...tmux.deps,
  });

  const upgradedCommand = tmux.commands
    .filter((entry) => entry.paneId === '%worker')
    .map((entry) => entry.command)
    .find((command) => /model_reasoning_effort="high"/.test(command));

  assert.ok(upgradedCommand, 'expected a retried worker launch with high reasoning');
  assert.ok(statusHistory.some((status) => status.worker_model === 'gpt-5.4:high'));
});

test('US-006 AC6.3 boundary: resume preserves the failure streak so the next failure upgrades the worker immediately', async (t) => {
  const campaign = await setupCampaign(t);
  const runtimeDir = deskPath(campaign.rootDir, 'logs', campaign.slug, 'runtime');
  await fs.mkdir(runtimeDir, { recursive: true });
  await fs.writeFile(
    path.join(runtimeDir, 'status.json'),
    JSON.stringify({
      slug: campaign.slug,
      iteration: 2,
      phase: 'worker',
      worker_model: 'gpt-5.4:medium',
      verifier_model: 'sonnet',
      final_verifier_model: 'opus',
      verified_us: [],
      consecutive_failures: 2,
      current_us: 'US-001',
    }, null, 2),
    'utf8',
  );

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      { iteration: 3, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'fail', recommended_state_transition: 'continue', issues: [] },
      { iteration: 4, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  const firstRetriedWorkerCommand = tmux.commands
    .filter((entry) => entry.paneId === '%worker')
    .map((entry) => entry.command)[1];
  assert.match(firstRetriedWorkerCommand, /model_reasoning_effort="high"/);
});

test('US-006 AC6.3 negative: after repeated failures through xhigh the campaign is blocked and writes a blocked sentinel', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const failureSequence = [];
  for (let iteration = 1; iteration <= 9; iteration += 1) {
    failureSequence.push({ iteration, status: 'verify', us_id: 'US-001', summary: `fail-${iteration}` });
    failureSequence.push({ verdict: 'fail', recommended_state_transition: 'continue', issues: [] });
  }

  const result = await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller(failureSequence),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  assert.equal(result.status, 'blocked');
  assert.equal(
    await fs.stat(deskPath(campaign.rootDir, 'memos', `${campaign.slug}-blocked.md`)).then(() => true, () => false),
    true,
  );
});

test('US-006 AC6.4 happy: after all stories pass individually, final sequential verify re-checks each US and runs integration before COMPLETE', async (t) => {
  const campaign = await setupCampaign(t, {
    sections: [
      '## US-001: First story\nAlpha details.',
      '## US-002: Second story\nBeta details.',
    ],
  });
  const tmux = createTmuxFakes();
  const integrationCalls = [];
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
    ]),
    runIntegrationCheck: async () => {
      integrationCalls.push('integration');
      return { exitCode: 0, summary: 'all green' };
    },
    ...tmux.deps,
  });

  const finalVerifyUs1 = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'final-US-001.verifier-prompt.md'),
  );
  const finalVerifyUs2 = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'final-US-002.verifier-prompt.md'),
  );

  assert.match(finalVerifyUs1, /Verify ONLY the acceptance criteria for \*\*US-001\*\*/);
  assert.match(finalVerifyUs2, /Verify ONLY the acceptance criteria for \*\*US-002\*\*/);
  assert.equal(integrationCalls.length, 1);
  assert.equal(
    await fs.stat(deskPath(campaign.rootDir, 'memos', `${campaign.slug}-complete.md`)).then(() => true, () => false),
    true,
  );
});

test('US-006 AC6.4 boundary: a failing final per-US re-verification stops completion and returns the failing US for another fix loop', async (t) => {
  const campaign = await setupCampaign(t, {
    sections: [
      '## US-001: First story\nAlpha details.',
      '## US-002: Second story\nBeta details.',
    ],
  });
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const result = await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    maxIterations: 3,
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'fail', recommended_state_transition: 'continue', issues: [{ criterion_id: 'AC-6.4', severity: 'major', summary: 'US-001 regressed' }] },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  assert.equal(result.status, 'continue');
  assert.equal(result.usId, 'US-001');
  assert.equal(
    await fs.stat(deskPath(campaign.rootDir, 'memos', `${campaign.slug}-complete.md`)).then(() => true, () => false),
    false,
  );
});

test('US-006 AC6.4 negative: integration failure prevents COMPLETE even after all sequential re-verifications pass', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const result = await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    maxIterations: 2,
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 1, summary: 'integration failed' }),
    ...tmux.deps,
  });

  assert.equal(result.status, 'continue');
  assert.equal(result.usId, 'ALL');
  assert.equal(
    await fs.stat(deskPath(campaign.rootDir, 'memos', `${campaign.slug}-complete.md`)).then(() => true, () => false),
    false,
  );
});

test('US-006 AC6.5 happy: an existing blocked sentinel refuses to start and tells the user to run clean first', async (t) => {
  const campaign = await setupCampaign(t);
  await fs.writeFile(
    deskPath(campaign.rootDir, 'memos', `${campaign.slug}-blocked.md`),
    'blocked\n',
    'utf8',
  );

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await assert.rejects(
    run(campaign.slug, {
      rootDir: campaign.rootDir,
      mode: 'tmux',
      workerModel: 'gpt-5.4:medium',
      pollForSignal: createPoller([]),
      runIntegrationCheck: async () => ({ exitCode: 0 }),
      ...tmux.deps,
    }),
    /run clean first/i,
  );
});

test('US-006 AC6.5 boundary: a blocked sentinel short-circuits before any tmux session or status writes are created', async (t) => {
  const campaign = await setupCampaign(t);
  await fs.writeFile(
    deskPath(campaign.rootDir, 'memos', `${campaign.slug}-blocked.md`),
    'blocked\n',
    'utf8',
  );

  const tmux = createTmuxFakes();
  const statusHistory = [];
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await assert.rejects(
    run(campaign.slug, {
      rootDir: campaign.rootDir,
      mode: 'tmux',
      workerModel: 'gpt-5.4:medium',
      pollForSignal: createPoller([]),
      runIntegrationCheck: async () => ({ exitCode: 0 }),
      onStatusChange: (status) => statusHistory.push(status),
      ...tmux.deps,
    }),
    /run clean first/i,
  );

  assert.equal(tmux.sessions.length, 0);
  assert.equal(statusHistory.length, 0);
});

test('US-006 AC6.5 negative: without a blocked sentinel the campaign is allowed to start normally', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const result = await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.4:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  assert.equal(result.status, 'complete');
  assert.equal(tmux.sessions.length, 1);
});
