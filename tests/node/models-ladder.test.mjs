import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadModelLadder, defaultShippedModelsFile, EMERGENCY_LADDER, CEILING_SENTINEL } from '../../src/node/model-ladder.mjs';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');
const realShippedFile = path.join(repoRoot, 'src', 'node', 'models.json');
const NONEXISTENT = path.join(repoRoot, '.tmp', 'models-ladder-test', 'does-not-exist.json');

// Hermeticity (Codex P2-1): campaign-main-loop.mjs computes its
// module-level MODEL_UPGRADES constant via loadModelLadder() (no explicit
// overrideFile) AT IMPORT TIME, using the ambient
// ${RLP_DESK_MODELS_FILE:-$HOME/.claude/rlp-desk-models.json} default. If a
// real override file exists on the machine running this test (or the env
// var happens to be set), the nextWorkerModel assertions below would
// silently depend on that ambient state instead of the shipped defaults
// they're meant to verify. Force the env var to a guaranteed-nonexistent
// path BEFORE importing the module — a static top-of-file `import` runs
// before any of this code, so this requires a dynamic import.
process.env.RLP_DESK_MODELS_FILE = path.join(repoRoot, '.tmp', 'models-ladder-test', 'hermetic-import-guard-no-override.json');
const { nextWorkerModel } = await import('../../src/node/runner/campaign-main-loop.mjs');

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

// P1 (Codex): a syntactically-valid JSON file whose upgrades VALUES aren't
// all strings must still be treated as a malformed layer — every value type
// jq/JSON can produce besides string and the omitted-key case.
for (const [label, badValue] of [
  ['number', 123],
  ['boolean', true],
  ['null', null],
  ['object', { nested: true }],
  ['array', ['sonnet']],
]) {
  test(`schema validation: a ${label} upgrades value is rejected (falls through, not resolved into junk)`, async (t) => {
    const dir = await createTempDir(t);
    const overrideFile = path.join(dir, 'override.json');
    await fs.writeFile(overrideFile, JSON.stringify({ upgrades: { haiku: badValue } }));

    const warnings = [];
    const ladder = loadModelLadder({ overrideFile, shippedFile: realShippedFile, warn: (msg) => warnings.push(msg) });

    // Falls through to the REAL shipped defaults, not the non-string value.
    assert.equal(ladder.haiku, 'sonnet');
    assert.notEqual(ladder.haiku, badValue);
    assert.equal(warnings.length, 1, `expected exactly one warning, got ${warnings.length}: ${JSON.stringify(warnings)}`);
    assert.match(warnings[0], /override file .* unreadable or malformed/);
  });
}

test('schema validation: an empty-string upgrades value is still accepted as ceiling', async (t) => {
  const dir = await createTempDir(t);
  const overrideFile = path.join(dir, 'override.json');
  await fs.writeFile(overrideFile, JSON.stringify({ upgrades: { haiku: '' } }));

  const ladder = loadModelLadder({ overrideFile, shippedFile: realShippedFile });
  assert.equal(ladder.haiku, CEILING_SENTINEL);
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
