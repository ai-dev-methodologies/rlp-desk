import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

test('G1: RUN_DEFAULTS includes flywheelGuard off and flywheelGuardModel opus', async () => {
  const { main } = await import('../../src/node/run.mjs');
  assert.ok(main);
});

test('G2: --flywheel-guard flag is parsed', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  const code = await main(['run', 'test-slug', '--flywheel-guard'], {
    cwd: '/tmp/nonexistent',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.equal(code, 1);
  assert.match(stream.data, /missing value for --flywheel-guard/);
});

test('G3: --flywheel-guard-model flag is parsed', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  const code = await main(['run', 'test-slug', '--flywheel-guard-model'], {
    cwd: '/tmp/nonexistent',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.equal(code, 1);
  assert.match(stream.data, /missing value for --flywheel-guard-model/);
});

test('G4: help text includes flywheel guard flags', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  await main(['--help'], {
    cwd: '/tmp',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.match(stream.data, /--flywheel-guard off\|on/);
  assert.match(stream.data, /--flywheel-guard-model MODEL/);
});

test('G5: shouldRunGuard returns false when flywheelGuard=off', async () => {
  const { shouldRunGuard } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunGuard('off', { flywheel_guard_count: {} }), false);
});

test('G6: shouldRunGuard returns true when flywheelGuard=on', async () => {
  const { shouldRunGuard } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunGuard('on', { flywheel_guard_count: {} }, 'US-001'), true);
});

test('G7: shouldRunGuard returns false when guard retries exhausted', async () => {
  const { shouldRunGuard } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunGuard('on', { flywheel_guard_count: { 'US-001': 3 } }, 'US-001'), false);
});

test('G8: init generates guard prompt with 4 validation checks', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /Look-ahead Bias/);
  assert.match(content, /Metric Alignment/);
  assert.match(content, /Deployability/);
  assert.match(content, /Repeat Pattern/);
});

test('G9: guard prompt writes to flywheel-guard-verdict.json', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheel-guard-verdict\.json/);
});

test('G10: guard verdict includes analysis_only field', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /analysis_only/);
});

test('G11: guard prompt references PRD as ground truth', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /PRD is ground truth/);
});

test('G12: cleanup list includes guard verdict file', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  // Check both memo cleanup and prompt cleanup reference guard files
  const memoMatch = content.includes('flywheel-guard-verdict.json');
  const promptMatch = content.includes('flywheel-guard.prompt.md');
  assert.ok(memoMatch, 'guard verdict file should be in memo cleanup');
  assert.ok(promptMatch, 'guard prompt file should be in prompt cleanup');
});
