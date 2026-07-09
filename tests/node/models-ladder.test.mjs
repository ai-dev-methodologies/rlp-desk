import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadModelLadder, defaultShippedModelsFile, EMERGENCY_LADDER, CEILING_SENTINEL } from '../../src/node/model-ladder.mjs';
import { nextWorkerModel } from '../../src/node/runner/campaign-main-loop.mjs';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');
const realShippedFile = path.join(repoRoot, 'src', 'node', 'models.json');
const NONEXISTENT = path.join(repoRoot, '.tmp', 'models-ladder-test', 'does-not-exist.json');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'models-ladder-test');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

test('defaultShippedModelsFile() resolves to the real src/node/models.json', () => {
  assert.equal(defaultShippedModelsFile(), realShippedFile);
});

test('override-precedence: a valid override file wins over shipped defaults', async (t) => {
  const dir = await createTempDir(t);
  const overrideFile = path.join(dir, 'override.json');
  await fs.writeFile(overrideFile, JSON.stringify({ upgrades: { haiku: 'custom-next-model' } }));

  const ladder = loadModelLadder({ overrideFile, shippedFile: realShippedFile });
  assert.equal(ladder.haiku, 'custom-next-model');
});

test('shipped-defaults-when-no-override: absent override falls through to shipped defaults', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder.haiku, 'sonnet');
  assert.equal(ladder.sonnet, 'opus');
  assert.equal(ladder.opus, CEILING_SENTINEL); // "" normalized to BLOCKED
  assert.equal(ladder['gpt-5.5:medium'], 'gpt-5.5:high');
  assert.equal(ladder['gpt-5.3-codex-spark:medium'], 'gpt-5.3-codex-spark:high');
});

test('malformed-JSON warn+fallthrough: malformed override falls through to shipped defaults with exactly one warning', async (t) => {
  const dir = await createTempDir(t);
  const overrideFile = path.join(dir, 'override.json');
  await fs.writeFile(overrideFile, 'not valid json {{{');

  const warnings = [];
  const ladder = loadModelLadder({ overrideFile, shippedFile: realShippedFile, warn: (msg) => warnings.push(msg) });

  assert.equal(ladder.haiku, 'sonnet'); // fell through to shipped defaults
  assert.equal(warnings.length, 1, `expected exactly one warning, got ${warnings.length}: ${JSON.stringify(warnings)}`);
  assert.match(warnings[0], /override file .* unreadable or malformed/);
});

test('malformed-JSON warn+fallthrough: shipped missing "upgrades" object also falls through with one warning', async (t) => {
  const dir = await createTempDir(t);
  const shippedFile = path.join(dir, 'models.json');
  await fs.writeFile(shippedFile, JSON.stringify({ notUpgrades: {} }));

  const warnings = [];
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile, warn: (msg) => warnings.push(msg) });

  assert.deepEqual(ladder, { ...EMERGENCY_LADDER });
  assert.equal(warnings.length, 1, `expected exactly one warning, got ${warnings.length}: ${JSON.stringify(warnings)}`);
});

test('emergency-inline-ladder: both override and shipped unreadable falls all the way through', () => {
  const warnings = [];
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: NONEXISTENT, warn: (msg) => warnings.push(msg) });

  assert.deepEqual(ladder, { ...EMERGENCY_LADDER });
  assert.equal(ladder.haiku, 'sonnet');
  assert.equal(ladder.sonnet, 'opus');
  assert.equal(ladder.opus, CEILING_SENTINEL);
  assert.equal(warnings.length, 1, `expected exactly one warning, got ${warnings.length}: ${JSON.stringify(warnings)}`);
});

test('""->BLOCKED ceiling normalization: nextWorkerModel treats a ceiling key as BLOCKED', () => {
  // 3 consecutive failures -> stage 1 upgrade attempt from opus, which has no
  // further upgrade in the shipped ladder (JSON "" -> normalized 'BLOCKED').
  assert.equal(nextWorkerModel('opus', 3), 'BLOCKED');
  assert.equal(nextWorkerModel('gpt-5.5:xhigh', 3), 'BLOCKED');
  assert.equal(nextWorkerModel('gpt-5.3-codex-spark:xhigh', 3), 'BLOCKED');
});

test('AC9: :low starts now upgrade to :medium (deliberate Node behavior change)', () => {
  // Before US-001, gpt-5.5:low and gpt-5.3-codex-spark:low were ABSENT from
  // the hardcoded Node MODEL_UPGRADES table, so nextWorkerModel treated them
  // as an immediate ceiling (BLOCKED) at stage 1. Unifying on the
  // zsh-authoritative union deliberately changes this: they now upgrade.
  assert.equal(nextWorkerModel('gpt-5.5:low', 3), 'gpt-5.5:medium');
  assert.equal(nextWorkerModel('gpt-5.3-codex-spark:low', 3), 'gpt-5.3-codex-spark:medium');
});

test('nextWorkerModel: claude ladder now resolves (previously absent from Node MODEL_UPGRADES)', () => {
  // Before US-001, haiku/sonnet/opus were entirely absent from the Node
  // hardcode, so any claude worker treated as instantly BLOCKED at stage 1.
  assert.equal(nextWorkerModel('haiku', 3), 'sonnet');
  assert.equal(nextWorkerModel('sonnet', 3), 'opus');
});

test('cross-consumer equivalence: every shipped ladder key normalizes the same way as the zsh loader (""<->BLOCKED)', async () => {
  const raw = await fs.readFile(realShippedFile, 'utf8');
  const { upgrades } = JSON.parse(raw);
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });

  for (const [model, next] of Object.entries(upgrades)) {
    const expected = next === '' ? CEILING_SENTINEL : next;
    assert.equal(ladder[model], expected, `ladder[${model}] should normalize to ${expected}`);
  }
});
