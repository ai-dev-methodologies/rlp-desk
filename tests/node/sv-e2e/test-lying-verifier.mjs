// v5.7 §4.25 — Tier A E2E: lying verifier (per-US and final).
// Cross-ref: tests/node/test-lying-worker.mjs covers Worker role.
// This file covers Verifier-per-US and Verifier-final exit paths.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from '../../../src/node/runner/campaign-main-loop.mjs';
import { WorkerExitedError } from '../../../src/node/polling/signal-poller.mjs';

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..', '..');
const TMP_BASE = path.join(projectRoot, '.tmp', 'sv-e2e-lying-verifier');

async function tmpCampaign(name) {
  await fs.mkdir(TMP_BASE, { recursive: true });
  const root = await fs.mkdtemp(path.join(TMP_BASE, `${name}-`));
  const memos = path.join(root, '.rlp-desk/memos');
  const logs = path.join(root, '.rlp-desk/logs/sum');
  const plans = path.join(root, '.rlp-desk/plans');
  const ctx = path.join(root, '.rlp-desk/context');
  const prompts = path.join(root, '.rlp-desk/prompts');
  for (const d of [memos, logs, plans, ctx, prompts]) await fs.mkdir(d, { recursive: true });
  await fs.writeFile(path.join(memos, 'sum-memory.md'), '# memory\n');
  await fs.writeFile(path.join(plans, 'prd-sum.md'), '# PRD\n## US-001: simple sum\n### AC1\nfoo\n');
  await fs.writeFile(path.join(plans, 'test-spec-sum.md'), '# Test Spec\n## US-001\nbar\n');
  await fs.writeFile(path.join(prompts, 'sum.worker.prompt.md'), 'worker\n');
  await fs.writeFile(path.join(prompts, 'sum.verifier.prompt.md'), 'verifier\n');
  return root;
}

test('per-US verifier exits without verdict → BLOCKED verifier_exited_without_artifacts', async () => {
  const root = await tmpCampaign('per-us-verifier');
  const result = await run('sum', {
    rootDir: root,
    mode: 'tmux',
    maxIterations: 1,
    iterTimeout: 5,
    sendKeys: async () => {},
    createPane: async () => '%fake',
    createSession: async () => ({ sessionName: 'fake', leaderPaneId: '%fake' }),
    pollForSignal: async (filePath) => {
      // Worker signal succeeds; verifier verdict throws.
      if (filePath.includes('iter-signal')) {
        return { status: 'verify', us_id: 'US-001', iteration: 1, slug: 'sum' };
      }
      throw new WorkerExitedError(
        'Verifier pane %fake exited without writing verdict',
        { paneId: '%fake', category: 'infra_failure', reason: 'verifier_exited_without_artifacts' },
      );
    },
  });

  assert.equal(result.status, 'blocked');
  assert.equal(result.category, 'infra_failure');
  const blockedJson = path.join(root, '.rlp-desk/memos/sum-blocked.json');
  const json = JSON.parse(await fs.readFile(blockedJson, 'utf8'));
  assert.equal(
    json.failure_category,
    'verifier_exited_without_artifacts',
    'failure_category must distinguish verifier from worker exits',
  );
});

test('final verifier (US-ALL) exits without verdict → BLOCKED final_verifier_exited_without_artifacts', async () => {
  // Need state.current_us to advance to 'ALL' before the final verifier
  // dispatch fires. Simplest: pre-write a prior verified_us state via
  // status.json so the loop's first action is final-verify.
  const root = await tmpCampaign('final-verifier');
  const statusPath = path.join(root, '.rlp-desk/logs/sum/runtime/status.json');
  await fs.mkdir(path.dirname(statusPath), { recursive: true });
  await fs.writeFile(
    statusPath,
    JSON.stringify({
      slug: 'sum',
      iteration: 2,
      max_iterations: 3,
      phase: 'verifier',
      worker_model: 'haiku',
      verifier_model: 'sonnet',
      final_verifier_model: 'opus',
      verified_us: ['US-001'],
      consecutive_failures: 0,
      consecutive_blocks: 0,
      last_block_reason: '',
      current_us: 'ALL',
      session_name: 'rlp-sum',
      leader_pane_id: '%fake',
      worker_pane_id: '%fake',
      verifier_pane_id: '%fake',
      flywheel_pane_id: '%fake',
      flywheel_guard_count: {},
      started_at_utc: new Date().toISOString(),
    }),
  );

  const result = await run('sum', {
    rootDir: root,
    mode: 'tmux',
    maxIterations: 3,
    iterTimeout: 5,
    sendKeys: async () => {},
    createPane: async () => '%fake',
    createSession: async () => ({ sessionName: 'fake', leaderPaneId: '%fake' }),
    pollForSignal: async () => {
      throw new WorkerExitedError(
        'Final verifier pane %fake exited without writing verdict',
        { paneId: '%fake', category: 'infra_failure', reason: 'final_verifier_exited_without_artifacts' },
      );
    },
  });

  assert.equal(result.status, 'blocked');
  assert.equal(result.category, 'infra_failure');
  const blockedJson = path.join(root, '.rlp-desk/memos/sum-blocked.json');
  const json = JSON.parse(await fs.readFile(blockedJson, 'utf8'));
  assert.equal(
    json.failure_category,
    'final_verifier_exited_without_artifacts',
    'failure_category must distinguish final-verifier from per-US verifier',
  );
});
