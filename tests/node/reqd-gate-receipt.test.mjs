// request-d ①-b + ② — gate-receipt binding and --worktree env mapping.
// Behavioral tests: the gate-receipt CLI writes a receipt bound to the current
// PRD content hash; verify reports ok/mismatch/missing; the run path warns on
// drift; and --worktree maps to RLP_CAMPAIGN_WORKTREE only when passed (default
// path is byte-identical — no key added to the zsh env).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { main } from '../../src/node/run.mjs';
import {
  writeGateReceipt,
  verifyGateReceipt,
  computePrdContentHash,
  gateReceiptPath,
} from '../../src/node/util/gate-receipt.mjs';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function tmpProject(t) {
  const root = path.join(repoRoot, '.tmp', 'reqd-gate-receipt');
  await fs.mkdir(root, { recursive: true });
  const dir = await fs.mkdtemp(path.join(root, 'case-'));
  await fs.mkdir(path.join(dir, '.rlp-desk', 'plans'), { recursive: true });
  t.after(async () => { await fs.rm(dir, { recursive: true, force: true }); });
  return dir;
}

function capture() {
  const chunks = [];
  return { stream: { write: (s) => { chunks.push(s); return true; } }, text: () => chunks.join('') };
}

async function writePrd(dir, slug, { main: mainBody = 'PRD body\n', us = {} } = {}) {
  const plans = path.join(dir, '.rlp-desk', 'plans');
  await fs.writeFile(path.join(plans, `prd-${slug}.md`), mainBody);
  for (const [id, body] of Object.entries(us)) {
    await fs.writeFile(path.join(plans, `prd-${slug}-US-${id}.md`), body);
  }
  return plans;
}

test('①-b: gate-receipt CLI writes a receipt bound to the current PRD hash', async (t) => {
  const dir = await tmpProject(t);
  const plans = await writePrd(dir, 'demo', { us: { '001': 'us1\n', '002': 'us2\n' } });
  const out = capture();
  const err = capture();
  const code = await main(['gate-receipt', 'demo', '--scorecard', 'PASS:29 WARN:3 REJECT:0'], {
    cwd: dir, stdout: out.stream, stderr: err.stream,
  });
  assert.equal(code, 0, err.text());
  const receipt = JSON.parse(await fs.readFile(gateReceiptPath(plans, 'demo'), 'utf8'));
  assert.equal(receipt.prd_sha256, computePrdContentHash(plans, 'demo'));
  assert.equal(receipt.scorecard, 'PASS:29 WARN:3 REJECT:0');
  assert.deepEqual(receipt.prd_files, ['prd-demo.md', 'prd-demo-US-001.md', 'prd-demo-US-002.md']);
  assert.match(receipt.passed_at, /^\d{4}-\d{2}-\d{2}T/);
});

test('①-b: gate-receipt CLI errors when no PRD exists', async (t) => {
  const dir = await tmpProject(t);
  const err = capture();
  const code = await main(['gate-receipt', 'ghost'], { cwd: dir, stdout: capture().stream, stderr: err.stream });
  assert.equal(code, 1);
  assert.match(err.text(), /no PRD found/);
});

test('①-b: verify reports ok, then mismatch after a PRD edit, then missing without a receipt', async (t) => {
  const dir = await tmpProject(t);
  const plans = await writePrd(dir, 'demo', { us: { '001': 'us1\n' } });
  writeGateReceipt(plans, 'demo', { scorecard: 'PASS:5' });
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'ok');

  // Edit a per-US file — the hash covers ALL PRD files, so this is a mismatch.
  await fs.appendFile(path.join(plans, 'prd-demo-US-001.md'), 'EDIT\n');
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'mismatch');

  // Adding a brand-new US must also register as mismatch.
  writeGateReceipt(plans, 'demo', { scorecard: 'PASS:5' }); // re-seal
  await fs.writeFile(path.join(plans, 'prd-demo-US-002.md'), 'new us\n');
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'mismatch');

  // Remove the receipt → missing.
  await fs.rm(gateReceiptPath(plans, 'demo'));
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'missing');
});

// Drive the run path with an injected spawnZsh so we can (a) assert the drift
// warning is emitted on stderr and (b) inspect the zsh env mapping without
// fork+exec'ing zsh.
async function runWithFakeZsh(dir, argv, t) {
  let capturedEnv = null;
  const err = capture();
  const out = capture();
  const code = await main(['run', ...argv], {
    cwd: dir,
    stdout: out.stream,
    stderr: err.stream,
    fileExists: () => true, // pretend the zsh runner exists
    zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
    spawnZsh: (zshPath, env) => { capturedEnv = env; return 0; },
  });
  return { code, env: capturedEnv, err: err.text(), out: out.text() };
}

test('①-b: run path WARNs loudly on gate-receipt mismatch', async (t) => {
  const dir = await tmpProject(t);
  const plans = await writePrd(dir, 'demo', { us: { '001': 'us1\n' } });
  writeGateReceipt(plans, 'demo', { scorecard: 'PASS:5' });
  await fs.appendFile(path.join(plans, 'prd-demo-US-001.md'), 'DRIFT\n');
  const { err } = await runWithFakeZsh(dir, ['demo'], t);
  assert.match(err, /gate-receipt MISMATCH/);
  assert.match(err, /revise/);
});

test('①-b: run path WARNs (proceeds) when the receipt is missing', async (t) => {
  const dir = await tmpProject(t);
  await writePrd(dir, 'demo', { us: { '001': 'us1\n' } });
  const { err } = await runWithFakeZsh(dir, ['demo'], t);
  assert.match(err, /no gate-receipt for demo/);
});

test('②: --worktree maps to RLP_CAMPAIGN_WORKTREE=1; default omits the key (byte-identical)', async (t) => {
  const dir = await tmpProject(t);
  await writePrd(dir, 'demo');
  writeGateReceipt(path.join(dir, '.rlp-desk', 'plans'), 'demo', {}); // avoid warn noise

  const off = await runWithFakeZsh(dir, ['demo'], t);
  assert.equal(off.code, 0, off.err);
  assert.ok(!('RLP_CAMPAIGN_WORKTREE' in off.env), 'default run must NOT set RLP_CAMPAIGN_WORKTREE');

  const on = await runWithFakeZsh(dir, ['demo', '--worktree'], t);
  assert.equal(on.code, 0, on.err);
  assert.equal(on.env.RLP_CAMPAIGN_WORKTREE, '1');
});

test('②: clean --remove-worktree is accepted and reported (no worktree present = no-op)', async (t) => {
  const dir = await tmpProject(t);
  const out = capture();
  const code = await main(['clean', 'demo', '--remove-worktree'], {
    cwd: dir, stdout: out.stream, stderr: capture().stream,
  });
  assert.equal(code, 0);
  // No worktree existed, so the message should NOT claim one was removed.
  assert.doesNotMatch(out.text(), /campaign worktree/);
});
