import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from '../../src/node/runner/campaign-main-loop.mjs';

// v5.7 §4.24 §1g — runtime invariant: every terminal exit of run() leaves
// exactly one sentinel on disk. Verify the try/finally backstop catches
// every escape path (mid-loop throw, missing scaffold, broken pollForSignal).

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..');
const TMP_BASE = path.join(projectRoot, '.tmp', 'leader-exit-test');

async function tmpCampaign(name) {
  const root = await fs.mkdtemp(path.join(TMP_BASE, `${name}-`));
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'memos'), { recursive: true });
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'logs', 'sum'), { recursive: true });
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'plans'), { recursive: true });
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'context'), { recursive: true });
  await fs.mkdir(path.join(root, '.claude', 'ralph-desk', 'prompts'), { recursive: true });
  return root;
}

await fs.mkdir(TMP_BASE, { recursive: true });

test('backstop: missing scaffold → run() throws but blocked.md is written', async () => {
  const root = await tmpCampaign('missing-scaffold');
  // No scaffold (no PRD, no prompts) — run() should throw during ensureScaffold.
  let threw = null;
  try {
    await run('sum', { rootDir: root, mode: 'tmux', maxIterations: 1, iterTimeout: 5 });
  } catch (e) {
    threw = e;
  }
  assert.ok(threw, 'run() must throw on missing scaffold');
  const blockedPath = path.join(root, '.claude/ralph-desk/memos/sum-blocked.md');
  const blockedExists = await fs
    .access(blockedPath)
    .then(() => true)
    .catch(() => false);
  assert.ok(blockedExists, `backstop must write ${blockedPath}`);
  const body = await fs.readFile(blockedPath, 'utf8');
  assert.match(body, /BLOCKED: ALL/);
  assert.match(body, /Leader exited unexpectedly|leader_exited_without_terminal_state/i);
});

test('backstop: pollForSignal throws unhandled error → blocked.md written', async () => {
  const root = await tmpCampaign('poll-throws');
  // Set up minimal scaffold so the body advances to dispatchWorker.
  const memos = path.join(root, '.claude/ralph-desk/memos');
  const plans = path.join(root, '.claude/ralph-desk/plans');
  const prompts = path.join(root, '.claude/ralph-desk/prompts');
  await fs.writeFile(path.join(memos, 'sum-memory.md'), '# memory\n');
  await fs.writeFile(path.join(plans, 'prd-sum.md'), '# PRD\n## US-001: simple sum\n### AC1\nfoo\n');
  await fs.writeFile(path.join(plans, 'test-spec-sum.md'), '# Test Spec\n## US-001\nbar\n');
  await fs.writeFile(path.join(prompts, 'sum.worker.prompt.md'), 'worker\n');
  await fs.writeFile(path.join(prompts, 'sum.verifier.prompt.md'), 'verifier\n');

  // v5.7 §4.25: pollForSignal errors are now caught by _handlePollFailure
  // which writes BLOCKED and RETURNS — does not propagate. The blocked.md
  // contract still holds.
  const result = await run('sum', {
    rootDir: root,
    mode: 'tmux',
    maxIterations: 1,
    iterTimeout: 5,
    sendKeys: async () => {},
    createPane: async () => '%fake',
    createSession: async () => ({ sessionName: 'fake', leaderPaneId: '%fake' }),
    pollForSignal: async () => {
      throw new Error('synthetic poll failure for test');
    },
  });
  assert.equal(result.status, 'blocked', 'run() returns blocked, not throws');
  const blockedPath = path.join(root, '.claude/ralph-desk/memos/sum-blocked.md');
  const blockedExists = await fs
    .access(blockedPath)
    .then(() => true)
    .catch(() => false);
  assert.ok(blockedExists, 'blocked.md must be written by _handlePollFailure or backstop');
  const body = await fs.readFile(blockedPath, 'utf8');
  assert.match(body, /BLOCKED: ALL|BLOCKED: US-/);
});

test('backstop: existing blocked.md is NOT overwritten (idempotent)', async () => {
  const root = await tmpCampaign('preexisting');
  const memos = path.join(root, '.claude/ralph-desk/memos');
  const plans = path.join(root, '.claude/ralph-desk/plans');
  const prompts = path.join(root, '.claude/ralph-desk/prompts');
  await fs.writeFile(path.join(memos, 'sum-memory.md'), '# memory\n');
  await fs.writeFile(path.join(plans, 'prd-sum.md'), '# PRD\n## US-001: simple sum\n### AC1\nfoo\n');
  await fs.writeFile(path.join(plans, 'test-spec-sum.md'), '# Test Spec\n## US-001\nbar\n');
  await fs.writeFile(path.join(prompts, 'sum.worker.prompt.md'), 'worker\n');
  await fs.writeFile(path.join(prompts, 'sum.verifier.prompt.md'), 'verifier\n');

  // Pre-write a real BLOCKED so the backstop should be a no-op.
  const blockedPath = path.join(memos, 'sum-blocked.md');
  await fs.writeFile(blockedPath, 'BLOCKED: US-001\nReason: legitimate prior failure\n');

  try {
    await run('sum', {
      rootDir: root,
      mode: 'tmux',
      maxIterations: 1,
      iterTimeout: 5,
      sendKeys: async () => {},
      createPane: async () => '%fake',
      createSession: async () => '%fake',
      pollForSignal: async () => {
        throw new Error('synthetic — should be ignored, sentinel already exists');
      },
    });
  } catch {
    // Run will short-circuit on the pre-existing sentinel before our throw.
  }

  const body = await fs.readFile(blockedPath, 'utf8');
  assert.match(
    body,
    /legitimate prior failure/,
    'pre-existing BLOCKED must not be overwritten by backstop',
  );
});
