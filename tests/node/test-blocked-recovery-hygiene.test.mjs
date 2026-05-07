// PR-E (Phase C1): operator-cleared BLOCKED recovery hygiene.
// AC-BR1..BR5 cover the 4-check validator + branch ordering vs PR-A.
// Reference plan: docs/plans/pr-e-phase-c1-blocked-recovery-hygiene-v0.md.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'pr-e-blocked-recovery-tests');
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
  const slug = options.slug ?? 'pr-e-test';
  const objective = options.objective ?? 'PR-E blocked recovery hygiene';

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

  return { rootDir, slug };
}

function createTmuxFakes() {
  const commands = [];
  const sessions = [];
  const paneIds = ['%flywheel', '%worker', '%verifier'];
  const createdPanes = [];
  const reaped = [];
  const locked = [];

  return {
    commands,
    sessions,
    createdPanes,
    reaped,
    locked,
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
      killPaneProcess: async (paneId) => {
        reaped.push({ paneId });
      },
      lockSentinelFile: async (filePath) => {
        locked.push({ filePath });
      },
      waitForProcessExit: async () => {},
      stampAckField: async () => {},
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

// Pre-populate phase=blocked recovery state.
// `sidecar` controls whether <slug>-blocked.json is present and what
// recoverable flag it carries (per _classifyBlock contract).
async function seedBlockedState(rootDir, slug, {
  phase = 'blocked',
  sentinelPresent = false,
  sidecar = null, // null = no sidecar; { recoverable: bool, reason_category: str }
  consecutiveFailures = 3,
  consecutiveBlocks = 1,
  workerModel = 'gpt-5.5:medium',
  verifierModel = 'gpt-5.5:high',
  finalVerifierModel = 'opus',
  currentUs = 'US-001',
  iteration = 5,
} = {}) {
  const memosDir = deskPath(rootDir, 'memos');
  const runtimeDir = deskPath(rootDir, 'logs', slug, 'runtime');
  await fs.mkdir(memosDir, { recursive: true });
  await fs.mkdir(runtimeDir, { recursive: true });

  if (sentinelPresent) {
    await fs.writeFile(
      path.join(memosDir, `${slug}-blocked.md`),
      'BLOCKED: pre-existing sentinel\n',
      'utf8',
    );
  }

  if (sidecar) {
    await fs.writeFile(
      path.join(memosDir, `${slug}-blocked.json`),
      `${JSON.stringify({
        schema_version: '2.0',
        slug,
        us_id: currentUs,
        blocked_at_iter: iteration,
        blocked_at_utc: new Date().toISOString(),
        reason_category: sidecar.reason_category ?? 'metric_failure',
        reason_detail: sidecar.reason_detail ?? 'fixture',
        failure_category: sidecar.failure_category ?? null,
        recoverable: sidecar.recoverable,
        suggested_action: sidecar.suggested_action ?? 'retry_after_fix',
        meta: { blocked_hygiene_violated: false },
      }, null, 2)}\n`,
      'utf8',
    );
  }

  await fs.writeFile(
    path.join(runtimeDir, 'status.json'),
    `${JSON.stringify({
      phase,
      iteration,
      max_iterations: 100,
      worker_model: workerModel,
      verifier_model: verifierModel,
      final_verifier_model: finalVerifierModel,
      verified_us: [],
      consecutive_failures: consecutiveFailures,
      consecutive_blocks: consecutiveBlocks,
      last_block_reason: '',
      current_us: currentUs,
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

function workerWasDispatched(commands) {
  return commands.some((c) => c.paneId === '%worker');
}

// ────────────────────────────────────────────────────────────────────────
// AC-BR1: phase=blocked + sentinel absent + counters non-zero + sidecar
//          recoverable=true → reset + dispatch worker normally.
// ────────────────────────────────────────────────────────────────────────

test('PR-E AC-BR1: operator-cleared BLOCKED with recoverable sidecar resets counters and dispatches worker', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  await seedBlockedState(rootDir, slug, {
    sentinelPresent: false,
    sidecar: { recoverable: true, reason_category: 'metric_failure' },
    consecutiveFailures: 3,
    consecutiveBlocks: 1,
  });

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 5, status: 'verify', us_id: 'US-001', summary: 'recovered' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  assert.ok(
    workerWasDispatched(tmux.commands),
    'worker must be dispatched when operator cleared blocked sentinel and sidecar is recoverable',
  );

  // Verify the audit-rename of sidecar happened (renamed to .recovered-<iso>).
  const memosDir = deskPath(rootDir, 'memos');
  const memos = await fs.readdir(memosDir);
  const recoveredSidecar = memos.find((f) => f.match(/-blocked\.json\.recovered-/));
  assert.ok(recoveredSidecar, 'sidecar must be renamed for audit (not deleted)');
  assert.equal(
    memos.find((f) => f === `${slug}-blocked.json`),
    undefined,
    'original sidecar must not remain after recovery',
  );
});

// ────────────────────────────────────────────────────────────────────────
// AC-BR2: phase=blocked + sentinel PRESENT → throw "Run clean first"
//          (existing v0.15.x behavior preserved; no auto-recovery).
// ────────────────────────────────────────────────────────────────────────

test('PR-E AC-BR2: phase=blocked with sentinel still present throws (existing behavior preserved)', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  await seedBlockedState(rootDir, slug, {
    sentinelPresent: true,
    sidecar: { recoverable: true, reason_category: 'metric_failure' },
  });

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await assert.rejects(
    run(slug, {
      rootDir,
      mode: 'tmux',
      workerModel: 'gpt-5.5:medium',
      pollForSignal: createPoller([]),
      runIntegrationCheck: async () => ({ exitCode: 0 }),
      ...tmux.deps,
    }),
    /run clean first/i,
    'leader must throw existing "Run clean first" when blocked sentinel is still on disk',
  );
});

// ────────────────────────────────────────────────────────────────────────
// AC-BR3: phase=blocked + sentinel absent + all counters zero → fall through.
// ────────────────────────────────────────────────────────────────────────

test('PR-E AC-BR3: nothing to reset (counters already zero) falls through silently', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  await seedBlockedState(rootDir, slug, {
    sentinelPresent: false,
    sidecar: null,
    consecutiveFailures: 0,
    consecutiveBlocks: 0,
  });

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  // No throw expected; recovery branch falls through (Check 3 fails).
  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 5, status: 'verify', us_id: 'US-001', summary: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  // Worker still dispatches (counters were already clean — phase reset to worker
  // happens at the top of every iteration, so no recovery branch needed).
  assert.ok(
    workerWasDispatched(tmux.commands),
    'worker must dispatch normally when there is nothing to recover',
  );
});

// ────────────────────────────────────────────────────────────────────────
// AC-BR4: phase=verify defers to PR-A's branch (no double-handling).
//          PR-A branch must run BEFORE PR-E branch.
// ────────────────────────────────────────────────────────────────────────

test('PR-E AC-BR4: phase=verify defers to PR-A branch (PR-E must not double-handle)', async (t) => {
  const { rootDir, slug } = await setupCampaign(t, {
    sections: ['## US-001: Only story\nAlpha details.'],
  });

  // Seed with phase=verify (PR-A territory) — PR-E should NOT reset counters
  // even though they're non-zero, because PR-A branch fires first.
  const memosDir = deskPath(rootDir, 'memos');
  const runtimeDir = deskPath(rootDir, 'logs', slug, 'runtime');
  await fs.mkdir(memosDir, { recursive: true });
  await fs.mkdir(runtimeDir, { recursive: true });

  // Create PR-A's required artifacts so its 5 checks pass.
  const campaignLogDir = deskPath(rootDir, 'logs', slug);
  await fs.mkdir(campaignLogDir, { recursive: true });
  const promptFile = path.join(campaignLogDir, `iter-001.worker-prompt.md`);
  await fs.writeFile(promptFile, '# old prompt\n', 'utf8');
  // Bump prompt mtime to past so artifacts are newer.
  const past = new Date(Date.now() - 2000);
  await fs.utimes(promptFile, past, past);

  await fs.writeFile(
    path.join(memosDir, `${slug}-iter-signal.json`),
    `${JSON.stringify({
      iteration: 1,
      status: 'verify',
      us_id: 'US-001',
      iter_signal_quality: 'specific',
      summary: 'manual recovery',
    }, null, 2)}\n`,
    'utf8',
  );
  await fs.writeFile(
    path.join(memosDir, `${slug}-done-claim.json`),
    `${JSON.stringify({
      iteration: 1,
      status: 'verify',
      us_id: 'US-001',
      execution_steps: ['manual'],
    }, null, 2)}\n`,
    'utf8',
  );
  await fs.writeFile(
    path.join(runtimeDir, 'status.json'),
    `${JSON.stringify({
      phase: 'verify',
      iteration: 1,
      max_iterations: 100,
      worker_model: 'gpt-5.5:medium',
      verifier_model: 'gpt-5.5:high',
      final_verifier_model: 'opus',
      verified_us: [],
      consecutive_failures: 0,
      consecutive_blocks: 0,
      last_block_reason: '',
      current_us: 'US-001',
      session_name: null,
      leader_pane_id: null,
      worker_pane_id: null,
      verifier_pane_id: null,
      flywheel_guard_count: {},
      started_at_utc: new Date().toISOString(),
    }, null, 2)}\n`,
    'utf8',
  );

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      // PR-A path: worker dispatch is SKIPPED. Polling picks up the
      // operator-written iter-signal.json directly.
      { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'manual recovery' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  // PR-A path → worker dispatch skipped on iter-1.
  // First worker dispatch (if any) should NOT be iter-001.
  const firstWorkerSend = tmux.commands.find((c) => c.paneId === '%worker');
  if (firstWorkerSend) {
    assert.doesNotMatch(
      firstWorkerSend.command,
      /iter-001\.worker-prompt\.md/,
      'first worker dispatch must NOT be iter-001 — PR-A path must skip it',
    );
  }
});

// ────────────────────────────────────────────────────────────────────────
// AC-BR5: phase=blocked + sentinel absent + sidecar recoverable=false →
//          fall through with audit log, NO auto-recovery.
//          Mirrors _classifyBlock 'mission_abort' / 'repeat_axis' invariant.
// ────────────────────────────────────────────────────────────────────────

test('PR-E AC-BR5: non-recoverable sidecar (recoverable=false) falls through; no auto-recovery', async (t) => {
  const { rootDir, slug } = await setupCampaign(t);
  await seedBlockedState(rootDir, slug, {
    sentinelPresent: false,
    sidecar: {
      recoverable: false,
      reason_category: 'mission_abort',
      reason_detail: 'flywheel inconclusive',
      suggested_action: 'terminal_alert',
    },
    consecutiveFailures: 3,
    consecutiveBlocks: 1,
  });

  const tmux = createTmuxFakes();
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');

  // PR-E branch must FALL THROUGH because sidecar.recoverable=false.
  // The campaign continues with stale counters. CB will trip on first failure.
  // We test by providing a poll queue that simulates 1 fail → pass → complete:
  // if PR-E auto-recovered, counters reset to 0 and CB doesn't trip.
  // If PR-E correctly falls through, counters stay at 3 and the next fail
  // would push them to CB threshold, but here we just verify the sidecar
  // file is NOT renamed (no recovery happened).
  await run(slug, {
    rootDir,
    mode: 'tmux',
    workerModel: 'gpt-5.5:medium',
    pollForSignal: createPoller([
      { iteration: 5, status: 'verify', us_id: 'US-001', summary: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'continue' },
      { verdict: 'pass', recommended_state_transition: 'complete' },
    ]),
    runIntegrationCheck: async () => ({ exitCode: 0 }),
    ...tmux.deps,
  });

  // Sidecar should NOT be renamed (no auto-recovery happened).
  const memosDir = deskPath(rootDir, 'memos');
  const memos = await fs.readdir(memosDir);
  const recoveredSidecar = memos.find((f) => f.match(/-blocked\.json\.recovered-/));
  assert.equal(
    recoveredSidecar,
    undefined,
    'sidecar must NOT be renamed when recoverable=false (no auto-recovery)',
  );
  assert.ok(
    memos.includes(`${slug}-blocked.json`),
    'original sidecar must remain untouched (operator must use clean to remove)',
  );
});
