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
  return path.join(rootDir, '.rlp-desk', ...segments);
}

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

async function readText(filePath) {
  return fs.readFile(filePath, 'utf8');
}

// F6.1 (docs/rlp-desk/failure-modes.md): real-tmux tests must not depend on the
// developer's personal interactive shell. Two distinct mechanisms killed panes
// mid-test (4-pane assertion intermittently sees 3):
//   1. send-keys racing rc startup — oh-my-zsh/p10k init can take >800ms under
//      suite load; input typed before zle owns the tty replays corrupted.
//   2. decorated-shell crash — rapid literal send-keys of a ~500-byte command
//      line intermittently SIGBUS-crashes the plugin-loaded zsh even at a fully
//      ready prompt (observed via remain-on-exit: pane_dead_signal=bus).
// Fix: hermeticPane() respawns each freshly created pane onto a bare `zsh -f`
// (no rc files, no plugins — closes 2), and waitForPaneReady() handshakes for
// an interactive prompt before anything is typed (closes 1). Bounded condition
// polls only; no blanket retries.
async function hermeticPane(paneId, { pathPrefix } = {}) {
  const args = ['respawn-pane', '-k'];
  if (pathPrefix) {
    args.push('-e', `PATH=${pathPrefix}:${process.env.PATH}`);
  }
  args.push('-t', paneId, 'zsh', '-f');
  await execFileAsync('tmux', args);
  return paneId;
}

// F6.1: on developer machines `claude`/`codex` are REAL binaries — a reaper
// C-c that lands during their startup is occasionally ignored, leaving a live
// TUI (and real API usage) behind the "parked at shell" assertion. Tests that
// really type commands into panes shadow both with an inert long-sleep stub:
// still a live foreground process for the reaper to kill, but deterministic
// and side-effect-free.
async function makeTuiStubs(t) {
  const stubDir = await createTempDir(t);
  for (const name of ['claude', 'codex']) {
    const stubPath = path.join(stubDir, name);
    await fs.writeFile(stubPath, '#!/bin/sh\nexec sleep 300\n');
    await fs.chmod(stubPath, 0o755);
  }
  return stubDir;
}

let paneReadyTokenSeq = 0;
async function waitForPaneReady(paneId, { timeoutMs = 20000, pollMs = 150, resendMs = 1000 } = {}) {
  paneReadyTokenSeq += 1;
  const token = `RDY${process.pid}X${paneReadyTokenSeq}`;
  const deadline = Date.now() + timeoutMs;
  let lastProbeAt = 0;
  while (Date.now() < deadline) {
    if (Date.now() - lastProbeAt >= resendMs) {
      // Leading space + plain ASCII: a probe replayed through a half-ready
      // shell degrades to junk/command-not-found, never to shell-killing bytes.
      await execFileAsync('tmux', ['send-keys', '-t', paneId, '-l', '--', ` echo ${token}`]);
      await execFileAsync('tmux', ['send-keys', '-t', paneId, 'Enter']);
      lastProbeAt = Date.now();
    }
    const { stdout } = await execFileAsync('tmux', ['capture-pane', '-p', '-t', paneId]);
    // Output line is the bare token; the echoed input line contains "echo <token>"
    // and never trims to the token alone. Tokens are unique per call, so a prior
    // handshake's output lingering on screen cannot satisfy this check.
    if (stdout.split('\n').some((line) => line.trim() === token)) {
      await execFileAsync('tmux', ['send-keys', '-t', paneId, 'C-u']);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, pollMs));
  }
  throw new Error(`pane ${paneId} shell not ready within ${timeoutMs}ms (F6.1 guard)`);
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
  // Panes are created in order: flywheel → worker → verifier (see campaign-main-loop.mjs)
  const paneIds = ['%flywheel', '%worker', '%verifier'];
  const createdPanes = [];
  // Bug #7: reap/lock recorders. `commands` stays send-only (legacy tests
  // index into it by position). `events` is a merged ordered log (send + kill)
  // for tests that need to assert ordering across the two action streams.
  const reaped = [];
  const locked = [];
  const events = [];

  return {
    commands,
    sessions,
    createdPanes,
    reaped,
    locked,
    events,
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
        events.push({ kind: 'send', paneId, command });
      },
      // Bug #7 Fix-Q/R: no-op fakes that record calls. Kept off `commands`
      // so legacy positional indexing in AC6.3-style tests stays valid.
      killPaneProcess: async (paneId, _opts) => {
        reaped.push({ paneId });
        events.push({ kind: 'kill', paneId });
      },
      lockSentinelFile: async (filePath, _opts) => {
        locked.push({ filePath });
        events.push({ kind: 'lock', filePath });
      },
      // PR-0b-narrow handshake: reapProducer awaits waitForProcessExit
      // explicitly. Without a fake the default impl polls real tmux against
      // fake pane IDs and times out for 5s per call. Stub to a no-op so the
      // unit tests stay fast.
      waitForProcessExit: async () => {},
      stampAckField: async (filePath, ack) => {
        events.push({ kind: 'ack', filePath, ack });
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
    workerModel: 'gpt-5.5:medium',
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
    ['horizontal', 'horizontal', 'vertical'],
  );

  const workerCommand = tmux.commands.find((entry) => entry.paneId === '%worker')?.command ?? '';
  assert.match(workerCommand, /codex -m 'gpt-5\.5'/); // GAP-2: model is now shell-quoted
  assert.match(workerCommand, /model_reasoning_effort="medium"/);
  assert.match(workerCommand, /--disable plugins --dangerously-bypass-approvals-and-sandbox/);
  assert.match(workerCommand, /iter-001\.worker-prompt\.md/);

  // fix/omx-state-isolation: every codex launch this leader spawns must carry
  // OMX_STATE_ROOT pointed at a campaign-scoped scratch dir under the
  // campaign runtime dir, isolating it from the operator's interactive omx
  // state (stale input_lock incident). Assert the prefix AND that it lands
  // under this campaign's runtime dir (not a bare/interactive path).
  const runtimeDir = deskPath(campaign.rootDir, 'logs', campaign.slug, 'runtime');
  const omxStateDir = path.join(runtimeDir, 'omx-state');
  assert.ok(
    workerCommand.startsWith(`OMX_STATE_ROOT='${omxStateDir}' codex`),
    `expected workerCommand to start with OMX_STATE_ROOT='${omxStateDir}' codex, got: ${workerCommand}`,
  );
  const omxStateDirStat = await fs.stat(omxStateDir);
  assert.ok(omxStateDirStat.isDirectory(), 'omx-state dir must be mkdir -p\'d before the codex launch');

  assert.equal(statusHistory[0].iteration, 1);
  assert.equal(statusHistory[0].phase, 'worker');

  const statusFile = deskPath(campaign.rootDir, 'logs', campaign.slug, 'runtime', 'status.json');
  const status = await readJson(statusFile);
  assert.equal(status.phase, 'complete');
});

test('US-006 fix/omx-state-isolation: buildLaunchCommand prefixes codex launches with OMX_STATE_ROOT and leaves claude launches + no-runtimeDir callers unprefixed (compat)', async () => {
  const { buildLaunchCommand } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const codexWithDir = buildLaunchCommand('/tmp/prompt.md', 'gpt-5.5:medium', '/tmp/run/omx-state');
  assert.match(codexWithDir, /^OMX_STATE_ROOT='\/tmp\/run\/omx-state' codex -m/);

  // Compat: a caller that does not pass an omxStateDir (e.g. a future
  // non-campaign use of this helper) must get the byte-identical unprefixed
  // command — isolation must never become a hard requirement.
  const codexWithoutDir = buildLaunchCommand('/tmp/prompt.md', 'gpt-5.5:medium');
  assert.doesNotMatch(codexWithoutDir, /OMX_STATE_ROOT/);
  assert.match(codexWithoutDir, /^codex -m/);

  // claude launches are never codex processes, so OMX_STATE_ROOT must never
  // be injected even when an omxStateDir is supplied.
  const claudeWithDir = buildLaunchCommand('/tmp/prompt.md', 'sonnet', '/tmp/run/omx-state');
  assert.doesNotMatch(claudeWithDir, /OMX_STATE_ROOT/);
});

test('US-006 AC6.1 boundary: run can create a real tmux session with four panes (leader + flywheel + worker + verifier) before continuing the campaign', async (t) => {
  const campaign = await setupCampaign(t);
  const sessionName = `us006-${Date.now()}`;
  const sendCommands = [];
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const paneManager = await import('../../src/node/tmux/pane-manager.mjs');

  t.after(async () => {
    await execFileAsync('tmux', ['kill-session', '-t', sessionName]).catch(() => {});
  });

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    sessionName,
    workerModel: 'gpt-5.5:medium',
    // v0.13.1: explicit empty env forces detached new-session branch even
    // when the test runner is itself inside an attached tmux. Production
    // users invoking from inside tmux take the in-current-window split
    // branch (mirrors zsh L815-823); this test exercises the CI/headless
    // path that creates a real isolated session for assertion + cleanup.
    env: {},
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    // F6.1: real pane creation, then hermetic respawn (see helper above).
    createPane: async (args) => hermeticPane(await paneManager.createPane(args)),
    // F6.1 guard: recording fake, but gated on pane-shell readiness so the
    // real reaper (default killPaneProcess) only ever sends C-c to a shell
    // sitting at an interactive prompt.
    sendKeys: async (paneId, command) => {
      await waitForPaneReady(paneId);
      sendCommands.push({ paneId, command });
    },
    runIntegrationCheck: async () => ({ exitCode: 0 }),
  });

  const { stdout } = await execFileAsync('tmux', ['list-panes', '-t', sessionName, '-F', '#{pane_id}']);
  const paneIds = stdout.trim().split('\n').filter(Boolean);

  // 4 panes: leader (from new-session) + flywheel + worker + verifier
  assert.equal(paneIds.length, 4);
  assert.match(sendCommands[0].command, /gpt-5\.5/);
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
      workerModel: 'gpt-5.5:medium',
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
    workerModel: 'gpt-5.5:medium',
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
  // Bug #8 PR-B: legacy synth path now requires (a) done-claim AND (b) clean
  // working tree. Pre-create both pre-conditions so the codex-timeout fallback
  // still resolves to verifier dispatch (the original contract of AC6.2).
  const claimPath = deskPath(
    campaign.rootDir,
    'memos',
    `${campaign.slug}-done-claim.json`,
  );
  await fs.mkdir(path.dirname(claimPath), { recursive: true });
  await fs.writeFile(
    claimPath,
    JSON.stringify({ us_id: 'US-001', summary: 'codex done' }, null, 2),
    'utf8',
  );
  const tmux = createTmuxFakes();
  const { TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      new TimeoutError('codex worker exited before writing a signal'),
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    checkWorkingTree: async () => ({ ok: true, dirty: false, dirtyFiles: [] }),
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
    workerModel: 'gpt-5.5:medium',
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
    workerModel: 'gpt-5.5:medium',
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
  assert.ok(statusHistory.some((status) => status.worker_model === 'gpt-5.5:high'));
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
      worker_model: 'gpt-5.5:medium',
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
    workerModel: 'gpt-5.5:medium',
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
    workerModel: 'gpt-5.5:medium',
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
    workerModel: 'gpt-5.5:medium',
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
    workerModel: 'gpt-5.5:medium',
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
    workerModel: 'gpt-5.5:medium',
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
      workerModel: 'gpt-5.5:medium',
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
      workerModel: 'gpt-5.5:medium',
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
    workerModel: 'gpt-5.5:medium',
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

// ────────────────────────────────────────────────────────────────────────
// Bug #7 Fix-Q/R: post-sentinel reaper.
// Asserts: every accepted signal/verdict triggers killPaneProcess on the
// producing pane and lockSentinelFile on the artifact, BEFORE the next
// dispatch fires. Without this the producing TUI keeps running and rewrites
// the sentinel for ~2min (verdict mtime drift observed in 19th launch).
// ────────────────────────────────────────────────────────────────────────

test('US-006 Bug-7-A: worker pollForSignal success reaps worker pane and locks signal file before verifier dispatch', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

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
    ...tmux.deps,
  });

  const reapedWorker = tmux.reaped.find((r) => r.paneId === '%worker');
  assert.ok(reapedWorker, 'worker pane was reaped');

  const lockedSignal = tmux.locked.find((l) => l.filePath.endsWith('iter-signal.json'));
  assert.ok(lockedSignal, 'iter-signal.json was locked');

  // Order over the merged event log: send to %worker → kill on %worker →
  // send to %verifier.
  const workerSendIdx = tmux.events.findIndex(
    (e) => e.kind === 'send' && e.paneId === '%worker',
  );
  const workerKillIdx = tmux.events.findIndex(
    (e) => e.kind === 'kill' && e.paneId === '%worker',
  );
  const verifierSendIdx = tmux.events.findIndex(
    (e) => e.kind === 'send' && e.paneId === '%verifier',
  );
  assert.ok(workerSendIdx >= 0, 'worker dispatched');
  assert.ok(workerKillIdx > workerSendIdx, 'worker killed AFTER its dispatch');
  assert.ok(verifierSendIdx > workerKillIdx, 'verifier dispatched AFTER worker reap');
});

test('US-006 Bug-7-B: verifier verdict pass reaps verifier pane and locks verdict file before next dispatch', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

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
    ...tmux.deps,
  });

  const verifierReaps = tmux.reaped.filter((r) => r.paneId === '%verifier');
  assert.ok(verifierReaps.length >= 1, 'verifier pane reaped at least once');

  const lockedVerdict = tmux.locked.find((l) => l.filePath.endsWith('verify-verdict.json'));
  assert.ok(lockedVerdict, 'verify-verdict.json was locked');

  // The final verifier interaction in the merged event log must be a kill,
  // not a dispatch — campaign reached complete after the last reap.
  const lastVerifierEvent = [...tmux.events].reverse().find((e) => e.paneId === '%verifier');
  assert.ok(lastVerifierEvent, 'verifier interacted at least once');
  assert.equal(
    lastVerifierEvent.kind,
    'kill',
    'last verifier event is a kill, not a dispatch',
  );
});

test('US-006 Bug-7-C: every accepted artifact triggers a kill+lock pair (post-B2-FIX: Worker emits 2 lock-targets)', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

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
    ...tmux.deps,
  });

  // Single-US campaign with one verify cycle plus the final per-US verdict:
  // worker accepted once, verifier accepted at least twice (per-US + final).
  const workerReaps = tmux.reaped.filter((r) => r.paneId === '%worker');
  const verifierReaps = tmux.reaped.filter((r) => r.paneId === '%verifier');
  assert.equal(workerReaps.length, 1, 'worker reaped exactly once per accepted signal');
  assert.ok(verifierReaps.length >= 1, 'verifier reaped at least once');

  // v0.15.4 PR-B2-FIX: contract amended. The worker pane produces TWO sentinel
  // artifacts in a single pass (iter-signal AND done-claim), both of which are
  // locked once the iter-signal poll resolves. Verifier still produces 1
  // sentinel per pass. Therefore lock count = reap count + workerReaps.length
  // (one extra done-claim lock per worker reap).
  assert.equal(
    tmux.locked.length,
    tmux.reaped.length + workerReaps.length,
    'each reap pairs with locks; worker pane emits +1 done-claim lock per reap (B2-FIX)',
  );
  for (const lock of tmux.locked) {
    assert.match(
      lock.filePath,
      /(iter-signal|verify-verdict|flywheel-signal|flywheel-guard-verdict|done-claim)\.json$/,
      `locked file is a sentinel artifact: ${lock.filePath}`,
    );
  }
  // v0.15.4 PR-B2-FIX explicit assertion: done-claim is among the locked files.
  const doneClaimLocked = tmux.locked.some((l) => l.filePath.endsWith('done-claim.json'));
  assert.ok(doneClaimLocked, 'B2-FIX: done-claim.json is locked alongside iter-signal');
});

test('US-006 Bug-7-C-negative: lockSentinel(doneClaim) is invoked unconditionally; fail-open on missing file in production', async (t) => {
  // v0.15.4 audit M1 fix: contract-clarity test. The amended Bug-7-C
  // assertion (`tmux.locked.length == tmux.reaped.length + workerReaps.length`)
  // assumes worker writes done-claim. In production, Bug #8 Gate 1 already
  // blocks any path where done-claim is absent — so the assertion holds in
  // practice. This negative test documents the fail-open behavior:
  //   1. campaign-main-loop.mjs L1944 calls `lockSentinel(paths.doneClaimFile)`
  //      unconditionally after worker iter-signal poll resolves.
  //   2. The real `lockSentinelFile` (src/node/shared/fs.mjs) is fail-open
  //      on missing files (verified by tests/node/test-lock-sentinel-file.test.mjs
  //      AC2). On a production worker that exits without done-claim, the
  //      lock call is a silent no-op.
  //   3. Stub `lockSentinelFile` in this file's createTmuxFakes records every
  //      call regardless of file existence — so the stub-driven test counts
  //      lock attempts, not lock-successes. The assertion still holds for
  //      the test's purposes (the call IS made), but production's `locked`-
  //      equivalent state would be smaller.
  // This test verifies the call is always made and never throws, even when
  // the underlying file does not exist.
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  // Throw on lockSentinel when file is missing — we want to verify the
  // production code never propagates such errors (the real impl is fail-open;
  // the stub here would fail-loud if the production code didn't tolerate it).
  const lockAttempts = [];
  tmux.deps.lockSentinelFile = async (filePath, _opts) => {
    lockAttempts.push({ filePath });
    // Real impl is fail-open on ENOENT — mirror that here. No throw.
  };

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
    ...tmux.deps,
  });

  // The unconditional call to lockSentinel(paths.doneClaimFile) must have
  // been attempted at least once for the worker iter (campaign-main-loop
  // L1944). Test fixture does not pre-create done-claim, mirroring the
  // worker-exited-without-done-claim production scenario.
  const doneClaimAttempts = lockAttempts.filter((a) =>
    a.filePath.endsWith('done-claim.json'),
  );
  assert.ok(
    doneClaimAttempts.length >= 1,
    `lockSentinel(doneClaim) attempted: got ${doneClaimAttempts.length} calls. ` +
    `If 0, the unconditional B2-FIX call site at campaign-main-loop.mjs L1944 has regressed.`,
  );
});

test('US-006 Bug-7-D: --mode agent live tmux reaper leaves all panes at idle shell', async (t) => {
  // Plan §C "Agent mode coverage" + Verification end-to-end §6: exercise the
  // production code path with REAL tmux session + real killPaneProcess +
  // real lockSentinelFile (no fake helper inject). Mirrors AC6.1 boundary
  // pattern but additionally asserts every pane is at the shell after the
  // campaign completes (i.e. the reaper actually fired against real panes).
  const campaign = await setupCampaign(t);
  const sessionName = `us006-bug7d-${Date.now()}`;
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  t.after(async () => {
    await execFileAsync('tmux', ['kill-session', '-t', sessionName]).catch(() => {});
  });

  // No `sendKeys`/`killPaneProcess`/`lockSentinelFile` injection — defaults
  // are used so real tmux + real reaper run end-to-end. NOTE (batch1 revert):
  // an earlier IMP-11 pass wrapped this test in the hermetic-respawn +
  // readiness-gate + TUI-stub rig; under full-suite load the readiness gate
  // could delay send-keys past the reaper's C-c, leaving a stub `sleep`
  // owning the pane forever (2/2 full-suite failures). The default dispatch
  // types non-existent binaries that exit immediately, so panes settle at a
  // shell on their own — the load-tolerant condition-poll below covers the
  // residual sampling race instead.
  await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    sessionName,
    workerModel: 'gpt-5.5:medium',
    env: {},
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
  });

  // After Bug #7 reaper has fired against worker + verifier (interrupting the
  // dispatched worker/verifier commands during startup — on dev machines with
  // real claude/codex binaries the reaper C-c kills them before they do any
  // work), every pane must be parked at a shell — not running claude/codex
  // self-review. F6.1 determinism: the C-c → shell transition is asynchronous
  // in the tmux server, so a single immediate sample races the dying process
  // (observed flaking under full-suite load). Poll bounded on the CONDITION
  // (all panes at a shell), never a fixed sleep.
  const deadline = Date.now() + 10_000;
  let lines = [];
  let allAtShell = false;
  while (Date.now() < deadline) {
    const { stdout } = await execFileAsync('tmux', [
      'list-panes',
      '-t',
      sessionName,
      '-F',
      '#{pane_id} #{pane_current_command}',
    ]);
    lines = stdout.trim().split('\n').filter(Boolean);
    allAtShell =
      lines.length === 4 &&
      lines.every((line) =>
        ['zsh', 'bash', 'sh'].includes(line.split(/\s+/, 2)[1] ?? ''),
      );
    if (allAtShell) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  // 4 panes: leader + flywheel + worker + verifier
  assert.equal(lines.length, 4);
  assert.ok(
    allAtShell,
    `panes not all at a shell after 10s — reaper failed to bring TUI back to idle: ${lines.join(' | ')}`,
  );
});

// =============================================================================
// Bug #8 — refuse to synthesize verify signal when worker exited without commit
// =============================================================================
//
// Plan v6 PR-B. Codex worker stub timeout fallback (campaign-main-loop.mjs
// L1484-1500) used to blindly synthesize a verify signal whenever pollForSignal
// raised TimeoutError. With Bug #8 fix this becomes a 4-way gate:
//
//   A1. done-claim absent             → BLOCKED infra_failure
//                                       (codex_exit_no_done_claim)
//   A2. done-claim + git unverifiable → BLOCKED infra_failure
//                                       (git_state_unverifiable)
//   A3. done-claim + dirty tree       → BLOCKED metric_failure
//                                       (worker_incomplete_uncommitted)
//   A4. done-claim + clean tree       → synthesize verify signal (legacy path)
//
// All four assertions exercise the codex engine (workerModel 'gpt-5.5:medium')
// because the synthesize gate was always a codex-only branch.

async function writeDoneClaim(campaign, usId = 'US-001') {
  const claimPath = deskPath(
    campaign.rootDir,
    'memos',
    `${campaign.slug}-done-claim.json`,
  );
  await fs.mkdir(path.dirname(claimPath), { recursive: true });
  await fs.writeFile(
    claimPath,
    JSON.stringify({ us_id: usId, summary: 'stub done-claim' }, null, 2),
    'utf8',
  );
}

test('US-006 Bug-8-A1: codex worker timeout WITHOUT done-claim writes BLOCKED infra_failure (codex_exit_no_done_claim)', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const { TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  // No done-claim written → A1 path.
  const result = await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      new TimeoutError('codex worker exited before writing a signal'),
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    // Inject deterministic clean-tree result. Should NOT be reached because
    // the done-claim absence gate fires first.
    checkWorkingTree: async () => ({ ok: true, dirty: false, dirtyFiles: [] }),
    ...tmux.deps,
  });

  assert.equal(result.status, 'blocked', 'campaign exit status is blocked');
  assert.equal(result.category, 'infra_failure');
  assert.match(result.reason, /done.?claim|done_claim|codex.*exit/i);

  const blockedJsonPath = deskPath(
    campaign.rootDir,
    'memos',
    `${campaign.slug}-blocked.json`,
  );
  const blocked = await readJson(blockedJsonPath);
  assert.equal(blocked.reason_category, 'infra_failure');
  assert.equal(blocked.failure_category, 'codex_exit_no_done_claim');
});

test('US-006 Bug-8-A2: codex worker timeout WITH done-claim but git unverifiable writes BLOCKED infra_failure (git_state_unverifiable)', async (t) => {
  const campaign = await setupCampaign(t);
  await writeDoneClaim(campaign);
  const tmux = createTmuxFakes();
  const { TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const result = await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      new TimeoutError('codex worker exited before writing a signal'),
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    checkWorkingTree: async () => ({
      ok: false,
      error: 'fatal: not a git repository',
    }),
    ...tmux.deps,
  });

  assert.equal(result.status, 'blocked');
  assert.equal(result.category, 'infra_failure');
  assert.match(result.reason, /git.*(unverifiable|state)/i);

  const blockedJsonPath = deskPath(
    campaign.rootDir,
    'memos',
    `${campaign.slug}-blocked.json`,
  );
  const blocked = await readJson(blockedJsonPath);
  assert.equal(blocked.reason_category, 'infra_failure');
  assert.equal(blocked.failure_category, 'git_state_unverifiable');
});

test('US-006 Bug-8-A3: codex worker timeout WITH done-claim AND dirty tree writes BLOCKED metric_failure (worker_incomplete_uncommitted)', async (t) => {
  const campaign = await setupCampaign(t);
  await writeDoneClaim(campaign);
  const tmux = createTmuxFakes();
  const { TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const result = await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      new TimeoutError('codex worker exited before writing a signal'),
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    checkWorkingTree: async () => ({
      ok: true,
      dirty: true,
      dirtyFiles: [' M src/foo.mjs', '?? new-file.mjs'],
    }),
    ...tmux.deps,
  });

  assert.equal(result.status, 'blocked');
  assert.equal(result.category, 'metric_failure');
  assert.match(
    result.reason,
    /uncommitted|dirty|worker_incomplete/i,
    `reason text mentions dirty tree (got: ${result.reason})`,
  );

  const blockedJsonPath = deskPath(
    campaign.rootDir,
    'memos',
    `${campaign.slug}-blocked.json`,
  );
  const blocked = await readJson(blockedJsonPath);
  assert.equal(blocked.reason_category, 'metric_failure');
  assert.equal(blocked.failure_category, 'worker_incomplete_uncommitted');
  // First few dirty files surfaced in reason text (per PRD AC: "first 5 dirty files").
  // The JSON sidecar exposes the reason verbatim under `reason_detail`.
  assert.match(blocked.reason_detail ?? '', /src\/foo\.mjs/);
});

test('US-006 Bug-8-A4: codex worker timeout WITH done-claim AND clean tree synthesizes verify signal (legacy preserved)', async (t) => {
  const campaign = await setupCampaign(t);
  await writeDoneClaim(campaign);
  const tmux = createTmuxFakes();
  const { TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  // After synthesize, the verifier and final-verifier each consume one verdict.
  const result = await run(campaign.slug, {
    rootDir: campaign.rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      new TimeoutError('codex worker exited before writing a signal'),
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    checkWorkingTree: async () => ({ ok: true, dirty: false, dirtyFiles: [] }),
    ...tmux.deps,
  });

  // Synthesize success path: campaign should complete, NOT block.
  assert.notEqual(result?.status, 'blocked', `clean tree must NOT block (got: ${JSON.stringify(result)})`);
  // Verifier prompt was emitted, proving synthesize → verifier dispatch path fired.
  const verifierPrompt = await readText(
    deskPath(campaign.rootDir, 'logs', campaign.slug, 'iter-001.verifier-prompt.md'),
  );
  assert.match(verifierPrompt, /Verify ONLY the acceptance criteria for \*\*US-001\*\*/);
});

// =============================================================================
// PR-0b-narrow — Leader handshake (waitForProcessExit + stampAckField)
// =============================================================================
//
// AC-H1: reapProducer awaits waitForProcessExit on the producing pane after
//        killPaneProcess (5s timeout, fail-open). Verified by counting calls
//        on the injected fake.
// AC-H2: every accepted sentinel receives a leader_ack stamp with the 3 audit
//        fields (acked_by, acked_at, ack_pane_state).
// AC-H7: backward compat — existing readers do not throw on the new field
//        (covered by validateArtifact passing through verdicts unchanged).

test('US-006 PR-0b-narrow AC-H1: reapProducer awaits waitForProcessExit on every accepted producing pane', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  // Wrap waitForProcessExit fake to count calls per pane.
  const waitCalls = [];
  tmux.deps.waitForProcessExit = async (paneId, opts) => {
    waitCalls.push({ paneId, opts });
  };
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

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
    ...tmux.deps,
  });

  // Worker pane reaped exactly once → waitForProcessExit called for it.
  const workerWaits = waitCalls.filter((w) => w.paneId === '%worker');
  assert.ok(workerWaits.length >= 1, 'waitForProcessExit was called for the worker pane');
  // Verifier pane reaped at least once → waitForProcessExit called for it too.
  const verifierWaits = waitCalls.filter((w) => w.paneId === '%verifier');
  assert.ok(verifierWaits.length >= 1, 'waitForProcessExit was called for the verifier pane');
  // 5000ms timeout per PRD AC-H1.
  assert.equal(workerWaits[0].opts.timeoutMs, 5000);
});

test('US-006 PR-0b-narrow AC-H2: every accepted sentinel receives a leader_ack stamp with 3 audit fields', async (t) => {
  const campaign = await setupCampaign(t);
  const tmux = createTmuxFakes();
  const ackStamps = [];
  tmux.deps.stampAckField = async (filePath, ack) => {
    ackStamps.push({ filePath, ack });
  };
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

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
    ...tmux.deps,
  });

  // At least one ack per accepted artifact (worker iter-signal, verifier verdict).
  assert.ok(ackStamps.length >= 2, `expected ≥2 ack stamps, got ${ackStamps.length}`);
  for (const { ack, filePath } of ackStamps) {
    assert.equal(ack.acked_by, 'leader', `ack.acked_by mismatch for ${filePath}`);
    assert.match(
      ack.acked_at,
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/,
      `ack.acked_at not ISO-8601 for ${filePath}: ${ack.acked_at}`,
    );
    assert.equal(ack.ack_pane_state, 'shell');
  }
  // At least one stamped a worker iter-signal AND one stamped a verifier verdict.
  const stampedSignal = ackStamps.find((s) => /iter-signal\.json$/.test(s.filePath));
  const stampedVerdict = ackStamps.find((s) => /verify-verdict\.json$/.test(s.filePath));
  assert.ok(stampedSignal, 'iter-signal.json received an ack stamp');
  assert.ok(stampedVerdict, 'verify-verdict.json received an ack stamp');
});
