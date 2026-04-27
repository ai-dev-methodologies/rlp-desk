import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from '../../src/node/runner/campaign-main-loop.mjs';
import { WorkerExitedError } from '../../src/node/polling/signal-poller.mjs';

// v5.7 §4.25 P0 — lying-worker integration test.
// Failure mode: Worker process exits cleanly without writing signal/done-claim
// (haiku/sonnet/codex sometimes skip the protocol's finalize step). Leader
// must detect the exit, write BLOCKED with reason `worker_exited_without_artifacts`,
// and return clean — NEVER silent timeout.
//
// Implementation note: per Architect P0-3, we use the `pollForSignal` injection
// seam (campaign-main-loop.mjs:729) to simulate the failure mode rather than
// spawning a real subprocess. This is deterministic, fast, and CI-stable.

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..');
const TMP_BASE = path.join(projectRoot, '.tmp', 'lying-worker-test');

async function tmpCampaign(name) {
  await fs.mkdir(TMP_BASE, { recursive: true });
  const root = await fs.mkdtemp(path.join(TMP_BASE, `${name}-`));
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'memos'), { recursive: true });
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'logs', 'sum'), { recursive: true });
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'plans'), { recursive: true });
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'context'), { recursive: true });
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'prompts'), { recursive: true });

  const memos = path.join(root, '.claude/ralph-desk/memos');
  const plans = path.join(root, '.claude/ralph-desk/plans');
  const prompts = path.join(root, '.claude/ralph-desk/prompts');
  await fs.writeFile(path.join(memos, 'sum-memory.md'), '# memory\nNext Iteration Contract: define\n');
  await fs.writeFile(path.join(plans, 'prd-sum.md'), '# PRD\n## US-001: simple sum\n### AC1\nfoo\n');
  await fs.writeFile(path.join(plans, 'test-spec-sum.md'), '# Test Spec\n## US-001\nbar\n');
  await fs.writeFile(path.join(prompts, 'sum.worker.prompt.md'), 'worker\n');
  await fs.writeFile(path.join(prompts, 'sum.verifier.prompt.md'), 'verifier\n');
  return root;
}

test('lying worker (Worker exits without signal) → BLOCKED infra_failure/worker_exited_without_artifacts', async () => {
  const root = await tmpCampaign('worker-lies');

  const result = await run('sum', {
    rootDir: root,
    mode: 'tmux',
    maxIterations: 1,
    iterTimeout: 5,
    sendKeys: async () => {},
    createPane: async () => '%fake',
    createSession: async () => ({ sessionName: 'fake', leaderPaneId: '%fake' }),
    pollForSignal: async () => {
      // Simulate Worker pane returned to shell (claude.exe → zsh)
      // without ever writing the signal file.
      throw new WorkerExitedError(
        'Worker pane %fake exited without writing signal — fresh-context contract violated',
        {
          paneId: '%fake',
          category: 'infra_failure',
          reason: 'worker_exited_without_artifacts',
        },
      );
    },
  });

  assert.equal(result.status, 'blocked');
  assert.equal(result.category, 'infra_failure');

  const blockedMd = path.join(root, '.claude/ralph-desk/memos/sum-blocked.md');
  const mdBody = await fs.readFile(blockedMd, 'utf8');
  assert.match(mdBody, /BLOCKED:/);
  assert.match(mdBody, /Category: infra_failure/);

  const blockedJson = path.join(root, '.claude/ralph-desk/memos/sum-blocked.json');
  const jsonBody = JSON.parse(await fs.readFile(blockedJson, 'utf8'));
  assert.equal(jsonBody.reason_category, 'infra_failure');
  assert.equal(jsonBody.failure_category, 'worker_exited_without_artifacts');
  assert.equal(jsonBody.recoverable, false);
});

test('lying verifier (per-US verifier exits without verdict) → BLOCKED', async () => {
  const root = await tmpCampaign('verifier-lies');

  // First call (Worker) returns valid signal; second call (Verifier) throws.
  let callCount = 0;
  const result = await run('sum', {
    rootDir: root,
    mode: 'tmux',
    maxIterations: 1,
    iterTimeout: 5,
    sendKeys: async () => {},
    createPane: async () => '%fake',
    createSession: async () => ({ sessionName: 'fake', leaderPaneId: '%fake' }),
    pollForSignal: async (filePath) => {
      callCount += 1;
      if (filePath.includes('iter-signal')) {
        return { status: 'verify', us_id: 'US-001', iteration: 1, slug: 'sum' };
      }
      // Verifier verdict file
      throw new WorkerExitedError(
        'Verifier pane %fake exited without writing verdict',
        {
          paneId: '%fake',
          category: 'infra_failure',
          reason: 'verifier_exited_without_artifacts',
        },
      );
    },
  });

  assert.equal(result.status, 'blocked');
  assert.equal(result.category, 'infra_failure');
  assert.ok(callCount >= 2, 'both worker and verifier polls were attempted');

  const blockedJson = path.join(root, '.claude/ralph-desk/memos/sum-blocked.json');
  const jsonBody = JSON.parse(await fs.readFile(blockedJson, 'utf8'));
  assert.equal(jsonBody.failure_category, 'verifier_exited_without_artifacts');
});
