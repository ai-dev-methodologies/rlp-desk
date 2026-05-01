// v5.7 §4.17 §4.25 — Tier A E2E: PromptBlockedError → BLOCKED prompt_blocked.
// Cross-ref: tests/node/test-prompt-dismisser.mjs covers the underlying
// auto-dismiss/default-No detection logic. This file covers the campaign-loop
// integration: PromptBlockedError thrown → _handlePollFailure writes BLOCKED.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from '../../../src/node/runner/campaign-main-loop.mjs';
import { PromptBlockedError } from '../../../src/node/polling/signal-poller.mjs';

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..', '..');
const TMP_BASE = path.join(projectRoot, '.tmp', 'sv-e2e-prompt-blocked');

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

test('default-No prompt detected during worker poll → BLOCKED prompt_blocked', async () => {
  const root = await tmpCampaign('default-no-worker');
  const result = await run('sum', {
    rootDir: root,
    mode: 'tmux',
    maxIterations: 1,
    iterTimeout: 5,
    sendKeys: async () => {},
    createPane: async () => '%fake',
    createSession: async () => ({ sessionName: 'fake', leaderPaneId: '%fake' }),
    pollForSignal: async () => {
      throw new PromptBlockedError(
        'Default-No prompt on pane %fake: Pane shows a default-No / explicit-No-default permission prompt',
        {
          paneId: '%fake',
          category: 'infra_failure',
          reason: 'default-No prompt requires explicit human decision',
        },
      );
    },
  });

  assert.equal(result.status, 'blocked');
  assert.equal(result.category, 'infra_failure');
  const blockedJson = path.join(root, '.rlp-desk/memos/sum-blocked.json');
  const json = JSON.parse(await fs.readFile(blockedJson, 'utf8'));
  assert.equal(json.failure_category, 'prompt_blocked');
  assert.match(json.reason_detail, /default-No|prompt/i);
});

test('default-No prompt detected during verifier poll → BLOCKED prompt_blocked', async () => {
  const root = await tmpCampaign('default-no-verifier');
  const result = await run('sum', {
    rootDir: root,
    mode: 'tmux',
    maxIterations: 1,
    iterTimeout: 5,
    sendKeys: async () => {},
    createPane: async () => '%fake',
    createSession: async () => ({ sessionName: 'fake', leaderPaneId: '%fake' }),
    pollForSignal: async (filePath) => {
      if (filePath.includes('iter-signal')) {
        return { status: 'verify', us_id: 'US-001', iteration: 1, slug: 'sum' };
      }
      throw new PromptBlockedError(
        'Default-No prompt on pane %fake during verifier dispatch',
        {
          paneId: '%fake',
          category: 'infra_failure',
          reason: 'verifier pane stuck on default-No prompt',
        },
      );
    },
  });

  assert.equal(result.status, 'blocked');
  assert.equal(result.category, 'infra_failure');
  const blockedJson = path.join(root, '.rlp-desk/memos/sum-blocked.json');
  const json = JSON.parse(await fs.readFile(blockedJson, 'utf8'));
  assert.equal(json.failure_category, 'prompt_blocked');
});
