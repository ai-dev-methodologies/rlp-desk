import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

test('T1: shouldRunFlywheel returns false when flywheel=off', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('off', { consecutive_failures: 3 }), false);
});

test('T2: shouldRunFlywheel returns true when flywheel=on-fail and consecutive_failures > 0', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('on-fail', { consecutive_failures: 1 }), true);
});

test('T3: shouldRunFlywheel returns false when flywheel=on-fail and consecutive_failures=0', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('on-fail', { consecutive_failures: 0 }), false);
});

test('T4: init generates flywheel prompt with 6 review steps', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /Premise Challenge/);
  assert.match(content, /Existing Code Leverage/);
  assert.match(content, /Ideal State Mapping/);
  assert.match(content, /Implementation Alternatives/);
  assert.match(content, /Scope Decision/);
  assert.match(content, /Contract Rewrite/);
});

test('T5: flywheel prompt contains 10 CEO cognitive patterns', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /First-principles/);
  assert.match(content, /10x check/);
  assert.match(content, /Inversion/);
  assert.match(content, /Simplicity bias/);
  assert.match(content, /User-back/);
  assert.match(content, /Time-value/);
  assert.match(content, /Sunk cost immunity/);
  assert.match(content, /Blast radius/);
  assert.match(content, /Reversibility/);
  assert.match(content, /Evidence > opinion/);
});

test('T6: flywheel prompt contains 4 scope decisions', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /HOLD.*current approach/i);
  assert.match(content, /PIVOT.*alternative/i);
  assert.match(content, /REDUCE.*simplif/i);
  assert.match(content, /EXPAND.*missing/i);
});

test('T7: flywheel prompt writes to flywheel-signal.json', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheel-signal\.json/);
});

test('T8: flywheel prompt records rejected directions', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /Rejected Directions/);
});

test('T9: buildPaths includes flywheel paths', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheelPromptFile/);
  assert.match(content, /flywheelSignalFile/);
});

test('T10: flywheel dispatch exists for both tmux and agent modes', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /dispatchFlywheel/);
  assert.match(content, /phase.*flywheel/i);
});

test('T11: flywheel runs BEFORE worker in the loop', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  const flywheelPos = content.indexOf('shouldRunFlywheel');
  const workerPos = content.indexOf('dispatchWorker', flywheelPos);
  assert.ok(flywheelPos < workerPos, 'flywheel check must appear before worker dispatch');
});

test('T12: rlp-desk.md options reference includes flywheel flags', async () => {
  const content = await fs.readFile(path.join(repoRoot, 'src', 'commands', 'rlp-desk.md'), 'utf8');
  assert.match(content, /--flywheel off\|on-fail/);
  assert.match(content, /--flywheel-model MODEL/);
});

test('T13: init presets include flywheel in options reference', async () => {
  const content = await fs.readFile(path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh'), 'utf8');
  assert.match(content, /--flywheel off\|on-fail/);
  assert.match(content, /--flywheel-model MODEL/);
});

test('T14: campaign-main-loop creates flywheel pane in tmux mode', async () => {
  const content = await fs.readFile(path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs'), 'utf8');
  assert.match(content, /flywheel_pane_id/);
});
