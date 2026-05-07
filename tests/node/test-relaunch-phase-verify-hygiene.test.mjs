// PR-A (Bug #10): leader honors operator-written `phase=verify` recovery.
// AC-R1..R5 cover the 5 validation checks; AC-R6 covers the one-shot guard.
// Reference plan: docs/plans/bug-report-overhaul-v1.md §5/PR-A.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'pr-a-bug10-tests');
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

async function setupCampaign(t, options = {}) {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  const slug = options.slug ?? 'bug10-test';
  const objective = options.objective ?? 'Validate phase=verify recovery';

  const sections = options.sections ?? [
    '## US-001: First story\nAlpha details.',
    '## US-002: Second story\nBeta details.',
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

  return { rootDir, slug };
}

function createTmuxFakes() {
  const commands = [];
  const sessions = [];
  const paneIds = ['%flywheel', '%worker', '%verifier'];
  const createdPanes = [];
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
      killPaneProcess: async (paneId) => {
        reaped.push({ paneId });
        events.push({ kind: 'kill', paneId });
      },
      lockSentinelFile: async (filePath) => {
        locked.push({ filePath });
        events.push({ kind: 'lock', filePath });
      },
      waitForProcessExit: async () => {},
      stampAckField: async (filePath, ack) => {
        events.push({ kind: 'ack', filePath, ack });
      },
    },
  };
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

// Pre-populate the artifacts the operator would write during a Bug #10
// recovery: status.json with phase=verify + worker prompt that PRE-DATES the
// manual artifacts (mtime invariant) + iter-signal.json + done-claim.json.
async function seedManualRecovery(rootDir, slug, {
  iteration = 1,
  usId = 'US-001',
  signalQuality = 'specific',
  doneClaimPresent = true,
  iterSignalUsId = null,
  iterSignalIteration = null,
  doneClaimUsId = null,
  doneClaimIteration = null,
  artifactsOlderThanWorkerPrompt = false,
  workerModel = 'gpt-5.5:medium',
  verifierModel = 'gpt-5.5:high',
  finalVerifierModel = 'opus',
} = {}) {
  const memosDir = deskPath(rootDir, 'memos');
  const runtimeDir = deskPath(rootDir, 'logs', slug, 'runtime');
  const campaignLogDir = deskPath(rootDir, 'logs', slug);
  await fs.mkdir(memosDir, { recursive: true });
  await fs.mkdir(runtimeDir, { recursive: true });
  await fs.mkdir(campaignLogDir, { recursive: true });

  // 1. Worker prompt for the iteration the operator is recovering FROM.
  //    Per the validator contract, manual artifacts must be NEWER than this.
  const workerPromptFile = path.join(
    campaignLogDir,
    `iter-${String(iteration).padStart(3, '0')}.worker-prompt.md`,
  );
  await fs.writeFile(workerPromptFile, '# old worker prompt\n', 'utf8');

  // 2. Wait so the next-written artifacts have a STRICTLY-LATER mtime
  //    (most filesystems have second-level granularity).
  if (!artifactsOlderThanWorkerPrompt) {
    // Bump worker prompt mtime to now-2s so artifacts written at "now" are newer.
    const past = new Date(Date.now() - 2000);
    await fs.utimes(workerPromptFile, past, past);
  } else {
    // Negative case (AC-R4): make worker prompt NEWER than artifacts.
    const future = new Date(Date.now() + 2000);
    await fs.utimes(workerPromptFile, future, future);
  }

  // 3. Operator-written iter-signal.json
  const iterSignal = {
    iteration: iterSignalIteration ?? iteration,
    status: 'verify',
    us_id: iterSignalUsId ?? usId,
    iter_signal_quality: signalQuality,
    summary: 'manual recovery',
  };
  await fs.writeFile(
    path.join(memosDir, `${slug}-iter-signal.json`),
    `${JSON.stringify(iterSignal, null, 2)}\n`,
    'utf8',
  );

  // 4. Operator-written done-claim.json (optional — AC-R2 omits it)
  if (doneClaimPresent) {
    const doneClaim = {
      iteration: doneClaimIteration ?? iteration,
      us_id: doneClaimUsId ?? usId,
      status: 'verify',
      execution_steps: ['operator manual recovery'],
    };
    await fs.writeFile(
      path.join(memosDir, `${slug}-done-claim.json`),
      `${JSON.stringify(doneClaim, null, 2)}\n`,
      'utf8',
    );
  }

  // 5. status.json with phase=verify
  await fs.writeFile(
    path.join(runtimeDir, 'status.json'),
    `${JSON.stringify({
      phase: 'verify',
      iteration,
      max_iterations: 100,
      worker_model: workerModel,
      verifier_model: verifierModel,
      final_verifier_model: finalVerifierModel,
      verified_us: [],
      consecutive_failures: 0,
      consecutive_blocks: 0,
      last_block_reason: '',
      current_us: usId,
      session_name: null,
      leader_pane_id: null,
      worker_pane_id: null,
      verifier_pane_id: null,
      flywheel_guard_count: {},
      started_at_utc: new Date().toISOString(),
    }, null, 2)}\n`,
    'utf8',
  );
}

// Helper: did any worker prompt land for `iteration` AFTER seedManualRecovery?
// Specifically: did the leader OVERWRITE the seeded prompt (mtime newer than
// when the campaign started)?
async function workerPromptWasRewritten(rootDir, slug, iteration, campaignStartMs) {
  const file = path.join(
    deskPath(rootDir, 'logs', slug),
    `iter-${String(iteration).padStart(3, '0')}.worker-prompt.md`,
  );
  try {
    const stat = await fs.stat(file);
    return stat.mtimeMs >= campaignStartMs;
  } catch {
    return false;
  }
}

// Helper: was a worker dispatch sent to %worker after the campaign started?
function workerWasDispatched(commands) {
  return commands.some((c) => c.paneId === '%worker');
}

// ────────────────────────────────────────────────────────────────────────
// AC-R1: phase=verify + valid manual artifacts → verifier-only entry.
// ────────────────────────────────────────────────────────────────────────

test('PR-A AC-R1: phase=verify + valid manual artifacts skips worker dispatch and runs verifier directly', async (t) => {
  // Use 1-US campaign to keep the polling queue minimal and the assertion
  // narrow to the iter-1 recovery path.
  const { rootDir, slug } = await setupCampaign(t, {
    sections: ['## US-001: Only story\nAlpha details.'],
  });
  await seedManualRecovery(rootDir, slug);

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  const startMs = Date.now();
  const result = await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      // Iter-1 recovery: worker dispatch is SKIPPED. The poll picks up the
      // operator-written iter-signal.json. We deliver the iter-signal payload
      // here so the loop transitions cleanly into the verifier phase.
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'manual recovery' },
      // Verifier verdict for US-001 → continue
      { verdict: 'pass', recommended_state_transition: 'continue' },
      // Final sequential verify for US-001 → complete
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  // Iter-1 worker prompt should NOT be rewritten by the leader (operator's
  // recovery preserved).
  assert.equal(
    await workerPromptWasRewritten(rootDir, slug, 1, startMs),
    false,
    'iter-1 worker prompt must not be rewritten when honoring phase=verify',
  );

  // Iter-1 should NOT have dispatched to %worker. (Iter-2 may.)
  // We assert on the FIRST send to %worker: it should reference iter-002, not iter-001.
  const firstWorkerSend = tmux.commands.find((c) => c.paneId === '%worker');
  if (firstWorkerSend) {
    assert.match(
      firstWorkerSend.command,
      /iter-002\.worker-prompt\.md/,
      'first worker dispatch should be iter-002, never iter-001',
    );
  }

  // Verifier WAS dispatched (operator's recovery completed).
  const verifierSend = tmux.commands.find((c) => c.paneId === '%verifier');
  assert.ok(verifierSend, 'verifier must be dispatched when honoring phase=verify');

  assert.equal(result.status, 'complete');
});

// ────────────────────────────────────────────────────────────────────────
// AC-R2: missing done-claim.json → fall through to worker dispatch.
// ────────────────────────────────────────────────────────────────────────

test('PR-A AC-R2: phase=verify with missing done-claim.json falls through to worker', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  await seedManualRecovery(rootDir, slug, { doneClaimPresent: false });

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  // Worker WAS dispatched (validation failed → fell through to default).
  assert.ok(
    workerWasDispatched(tmux.commands),
    'worker must be dispatched when done-claim.json is missing (validation fails open to default)',
  );
});

// ────────────────────────────────────────────────────────────────────────
// AC-R3: us_id mismatch → fall through to worker dispatch.
// ────────────────────────────────────────────────────────────────────────

test('PR-A AC-R3: phase=verify with us_id mismatch falls through to worker', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  // status.current_us=US-001 but iter-signal.us_id=US-002
  await seedManualRecovery(rootDir, slug, {
    usId: 'US-001',
    iterSignalUsId: 'US-002',
  });

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  assert.ok(
    workerWasDispatched(tmux.commands),
    'worker must be dispatched when us_id does not match',
  );
});

// ────────────────────────────────────────────────────────────────────────
// AC-R4: iter-signal/done-claim older than worker-prompt.md → fall through.
// ────────────────────────────────────────────────────────────────────────

test('PR-A AC-R4: phase=verify with manual artifacts older than worker-prompt falls through to worker', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  await seedManualRecovery(rootDir, slug, { artifactsOlderThanWorkerPrompt: true });

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  assert.ok(
    workerWasDispatched(tmux.commands),
    'worker must be dispatched when artifacts are older than worker-prompt.md (probably stale)',
  );
});

// ────────────────────────────────────────────────────────────────────────
// AC-R5: iter_signal_quality != 'specific' → fall through.
// ────────────────────────────────────────────────────────────────────────

test('PR-A AC-R5: phase=verify with iter_signal_quality=generic falls through to worker', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  await seedManualRecovery(rootDir, slug, { signalQuality: 'generic' });

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  assert.ok(
    workerWasDispatched(tmux.commands),
    'worker must be dispatched when iter_signal_quality != "specific"',
  );
});

// ────────────────────────────────────────────────────────────────────────
// AC-R6: one-shot guard — iter-2 worker is dispatched normally after iter-1
// recovery skip. Architect S4 mitigation.
// ────────────────────────────────────────────────────────────────────────

test('PR-A AC-R6: skip-next-worker guard is one-shot; iter-2 worker dispatched normally', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  // Three US in this campaign so the loop survives past iter-1.
  await seedManualRecovery(rootDir, slug);

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      // Iter-1: verifier-only (recovery). Verdict passes → US-001 done.
      { verdict: 'pass', recommended_state_transition: 'continue' },
      // Iter-2: worker dispatched normally → verify → continue → final.
      { iteration: 2, status: 'verify', us_id: 'US-002', summary: 'done' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  // Filter worker dispatches to ONLY US-002 (iter-2).
  const us002WorkerSends = tmux.commands.filter(
    (c) => c.paneId === '%worker' && /iter-002\.worker-prompt\.md/.test(c.command),
  );
  assert.ok(
    us002WorkerSends.length >= 1,
    'iter-2 worker must be dispatched normally after iter-1 recovery skip (one-shot guard)',
  );

  // And iter-001 worker should NEVER have been dispatched.
  const us001WorkerSends = tmux.commands.filter(
    (c) => c.paneId === '%worker' && /iter-001\.worker-prompt\.md/.test(c.command),
  );
  assert.equal(
    us001WorkerSends.length,
    0,
    'iter-1 worker must not be dispatched when honoring phase=verify recovery',
  );
});
