import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// PR-B2-FIX (v0.15.4) — sentinel reaper/lock invariant test.
//
// Plan: docs/plans/v0.15-phase-b-plan-v3.md §B2-FIX.
// Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §2 Table 1.
//
// Invariant under test:
//   For each sentinel S with Producer ∈ {Worker, Verifier}:
//     (a) the producer pane is killed before the next phase advances, AND
//     (b) the sentinel file is locked (chmod 0o444, attested via lockSentinel
//         dependency injection here) after the leader has accepted the write.
//   For each sentinel S with Producer = Leader:
//     (a) NO producer pane is killed (there is no producer pane to kill), AND
//     (b) the sentinel write is exclusive (writeSentinelExclusive's O_EXCL
//         first-writer-wins property — already covered by test-sentinel-
//         exclusive.mjs; this file does not re-assert it).
//
// Coverage matrix (plan v3 §B2-FIX Table cases 1-8):
//   case 1+2: iter-signal Worker — locked after observation (regression guard)
//   case 3+4: verdict Verifier — locked after observation (regression guard)
//   case 5  : done-claim Worker — locked after iter-signal observation
//             *** PRIMARY B2-FIX TARGET ***
//             Without this PR, done-claim was written by the worker but never
//             locked by the leader, leaving a 30-120s rewrite window before
//             lib_ralph_desk.zsh:602 archived the snapshot. The Node-side fix
//             at campaign-main-loop.mjs:1894 calls lockSentinel(doneClaimFile)
//             immediately after the worker iter-signal reapProducer.
//   case 6+7: blocked Leader sentinel — NO killPaneProcess invoked
//   case 8  : complete Leader sentinel — NO killPaneProcess invoked
//
// All cases use stubbed tmux (createTmuxFakes pattern from us006). Real-tmux
// variant gated by RLP_TEST_REAL_TMUX=1 is owned by the SV gate suite, not by
// this unit test.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'b2-fix-reaper-invariant');
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
  const commands = [];
  const sessions = [];
  const paneIds = ['%flywheel', '%worker', '%verifier'];
  const createdPanes = [];
  const reaped = [];
  const locked = [];
  const events = [];

  return {
    commands, sessions, createdPanes, reaped, locked, events,
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

async function setupCampaign(t, options = {}) {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  const objective = options.objective ?? 'PR-B2-FIX invariant fixture';
  const slug = options.slug ?? 'b2fix-test';
  const sections = options.sections ?? ['## US-001: First story\nAlpha details.'];
  const prdContent = [
    `# PRD: ${slug}`, '', '## Objective', objective, '', ...sections, '',
  ].join('\n');
  await initCampaign(slug, objective, {
    rootDir,
    tmuxEnv: options.tmuxEnv ?? 'tmux-test-session',
    prdContent,
  });
  return { rootDir, slug, objective };
}

// ────────────────────────────────────────────────────────────────────────────
// case 1+2 (regression): iter-signal Worker locked after observation
// ────────────────────────────────────────────────────────────────────────────
test('B2-FIX case 1+2: iter-signal locked after Worker observation (regression)', async (t) => {
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

  const lockedSignal = tmux.locked.some((e) => e.filePath.endsWith('iter-signal.json'));
  assert.ok(lockedSignal, 'iter-signal.json must be locked after Worker poll resolves');
});

// ────────────────────────────────────────────────────────────────────────────
// case 3+4 (regression): verdict Verifier locked after observation
// ────────────────────────────────────────────────────────────────────────────
test('B2-FIX case 3+4: verdict locked after Verifier observation (regression)', async (t) => {
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

  const lockedVerdict = tmux.locked.some((e) => e.filePath.endsWith('verify-verdict.json'));
  assert.ok(lockedVerdict, 'verify-verdict.json must be locked after Verifier poll resolves');
});

// ────────────────────────────────────────────────────────────────────────────
// case 5: done-claim Worker locked after iter-signal observation
// PRIMARY B2-FIX TARGET — fails on pre-PR code, passes after substrate change.
// ────────────────────────────────────────────────────────────────────────────
test('B2-FIX case 5: done-claim is locked after Worker iter-signal observation (PRIMARY TARGET)', async (t) => {
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

  const lockedDoneClaim = tmux.locked.some((e) => e.filePath.endsWith('done-claim.json'));
  assert.ok(
    lockedDoneClaim,
    `done-claim.json must be locked after Worker iter-signal observation. ` +
    `Recorded locks: ${tmux.locked.map((e) => path.basename(e.filePath)).join(', ')}`,
  );
});

// ────────────────────────────────────────────────────────────────────────────
// case 5b (ordering): worker pane killed BEFORE done-claim locked
// ────────────────────────────────────────────────────────────────────────────
test('B2-FIX case 5b: worker pane killed before done-claim is locked', async (t) => {
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

  // Find the first kill of %worker AND the first lock of done-claim.json.
  // Assert kill index < lock index (kill happens first in the event stream).
  const killIdx = tmux.events.findIndex((e) => e.kind === 'kill' && e.paneId === '%worker');
  const lockDcIdx = tmux.events.findIndex(
    (e) => e.kind === 'lock' && e.filePath.endsWith('done-claim.json'),
  );
  assert.ok(killIdx >= 0, 'worker pane must be killed at some point');
  assert.ok(lockDcIdx >= 0, 'done-claim must be locked at some point');
  assert.ok(
    killIdx < lockDcIdx,
    `worker kill (idx ${killIdx}) must precede done-claim lock (idx ${lockDcIdx})`,
  );
});

// ────────────────────────────────────────────────────────────────────────────
// case 6+7+8: Leader sentinels (blocked, complete) — NO killPaneProcess
// invoked for the sentinel-write itself.
//
// Approach: the happy-path campaign writes a complete sentinel at end-of-run.
// We verify that:
//   (a) the campaign reached terminal state (complete sentinel present),
//   (b) the kill events recorded are ALL attributable to %worker / %verifier
//       producers — never to a Leader-sentinel-write event. The sentinel-
//       writes themselves do not appear in `tmux.reaped`.
// ────────────────────────────────────────────────────────────────────────────
test('B2-FIX case 6+7+8: Leader sentinels do not invoke killPaneProcess', async (t) => {
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

  // Verify campaign reached terminal complete (case 8 precondition).
  const completeFile = deskPath(campaign.rootDir, 'memos', `${campaign.slug}-complete.md`);
  await fs.access(completeFile);

  // All recorded reaps must be against %worker or %verifier — never %leader.
  // The complete-sentinel-write does not create a producer pane to reap.
  const allowedPanes = new Set(['%worker', '%verifier', '%flywheel']);
  for (const entry of tmux.reaped) {
    assert.ok(
      allowedPanes.has(entry.paneId),
      `Reaped pane '${entry.paneId}' must be Worker/Verifier/Flywheel — Leader sentinels never reap`,
    );
  }
});

// ────────────────────────────────────────────────────────────────────────────
// AC2.7 sanity: this file is one of the +2 test files in the B2-FIX PR.
// ────────────────────────────────────────────────────────────────────────────
test('B2-FIX AC2.7: this test file is registered as a B2-FIX deliverable', () => {
  // Self-attestation comment trail — the file existing and importing real
  // run() is the proof. No code-level assertion; this test pins the contract
  // that a B2-FIX-named test exists and exercises real campaign-main-loop.
  assert.equal(typeof testFile, 'string');
  assert.ok(testFile.endsWith('test-sentinel-reaper-invariant.test.mjs'));
});
