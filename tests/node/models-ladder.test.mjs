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
  // Fable 5.1 wave: opus is no longer the claude ceiling — it escalates into
  // claude-fable-5-1:max (see the dedicated "claude ladder reaches fable"
  // test below for the full assertion + rationale).
  assert.equal(ladder.opus, 'claude-fable-5-1:max');
  assert.equal(ladder['gpt-5.6-sol:medium'], 'gpt-5.6-sol:high');
  assert.equal(ladder['gpt-5.6-luna:medium'], 'gpt-5.6-luna:high');
});

// Claude ladder now reaches fable: opus -> claude-fable-5-1:max (terminal
// rung, effort-qualified — mirrors how astra's/sol's terminal codex rungs
// are always effort-qualified, never bare) -> ceiling. `claude --help`
// documents `fable` as a bare alias alongside opus/sonnet; the WORKER-side
// ladder key uses the versioned `claude-fable-5-1` id (matching every other
// fable reference in docs/governance, which is always version-pinned, never
// the floating `fable` alias) paired with `:max` (matching the "top model +
// top effort" role fable already holds everywhere else in this repo).
test('claude ladder reaches fable: opus escalates to claude-fable-5-1:max, which is the real claude ceiling', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder.opus, 'claude-fable-5-1:max');
  assert.equal(ladder['claude-fable-5-1'], CEILING_SENTINEL);
});

// gpt-6-astra: newest codex frontier model. Its own escalation chain
// (low->medium->high->xhigh, ceiling at xhigh) is empirically confirmed by
// live probes — see src/model-upgrade-table.md "GPT-6 — Astra". `minimal` is
// confirmed REJECTED by the server for this model and must never appear as a
// ladder key; `max`/`ultra` are accepted-but-not-auto-escalated-into
// (manual-start dead ends), matching sol's shape.
test('gpt-6-astra: self-escalating ladder mirrors gpt-5.6-sol shape, ceiling at xhigh', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder['gpt-6-astra:low'], 'gpt-6-astra:medium');
  assert.equal(ladder['gpt-6-astra:medium'], 'gpt-6-astra:high');
  assert.equal(ladder['gpt-6-astra:high'], 'gpt-6-astra:xhigh');
  assert.equal(ladder['gpt-6-astra:xhigh'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-6-astra:max'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-6-astra:ultra'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-6-astra:minimal'], undefined, 'minimal is server-rejected for gpt-6-astra and must never be a ladder key');
});

// Owner decision (applied): gpt-6-astra IS the real ceiling of the whole
// ladder now. gpt-5.6-sol:xhigh escalates into gpt-6-astra:high (one rung
// below astra's own ceiling — the same "model step-up enters at :high, never
// a lower effort" rule that sends gpt-5.6-terra:xhigh into gpt-5.6-sol:high).
// INVERTED from the earlier version of this test, which pinned "sol:xhigh
// stays terminal" — that was the pre-owner-decision contract. This assertion
// is the mutation control: it fails if a future edit re-terminates sol:xhigh
// or unwires the astra escalation.
test('gpt-5.6-sol:xhigh escalates into gpt-6-astra:high (astra is the real ceiling)', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder['gpt-5.6-sol:xhigh'], 'gpt-6-astra:high');
  assert.equal(ladder['gpt-6-astra:xhigh'], CEILING_SENTINEL, 'astra:xhigh must be the terminal ceiling of the whole ladder');
  assert.equal(ladder['gpt-5.6-terra:max'], 'gpt-5.6-sol:xhigh', 'terra:max -> sol:xhigh hop is unchanged');
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
  // Fable 5.1 wave: the 4-entry emergency ladder now also reaches fable —
  // opus is no longer its ceiling either.
  assert.equal(ladder.opus, 'claude-fable-5-1:max');
  assert.equal(ladder['claude-fable-5-1'], CEILING_SENTINEL);
  assert.equal(warnings.length, 1, `expected exactly one warning, got ${warnings.length}: ${JSON.stringify(warnings)}`);
});

test('""->BLOCKED ceiling normalization: nextWorkerModel treats a ceiling key as BLOCKED', () => {
  // 3 consecutive failures -> stage 1 upgrade attempt. opus itself is no
  // longer a ceiling (Fable 5.1 wave: it escalates to claude-fable-5-1:max) —
  // claude-fable-5-1 is the real claude ceiling now (JSON "" -> 'BLOCKED').
  assert.equal(nextWorkerModel('opus', 3), 'claude-fable-5-1:max');
  assert.equal(nextWorkerModel('claude-fable-5-1', 3), 'BLOCKED');
  assert.equal(nextWorkerModel('gpt-5.5:xhigh', 3), 'BLOCKED');
  assert.equal(nextWorkerModel('gpt-5.3-codex-spark:xhigh', 3), 'BLOCKED');
});

test('AC9: :low starts now upgrade to :medium (deliberate Node behavior change)', () => {
  // Before US-001 the codex :low rungs were ABSENT from the hardcoded Node
  // MODEL_UPGRADES table, so nextWorkerModel treated a :low start as an
  // immediate ceiling (BLOCKED) at stage 1. Unifying on the zsh-authoritative
  // union deliberately changed this: they now upgrade. (The original case
  // used gpt-5.5 and gpt-5.3-codex-spark; both were retired by the vendor and
  // removed from the ladder, so the same property is pinned on live families.)
  assert.equal(nextWorkerModel('gpt-5.6-sol:low', 3), 'gpt-5.6-sol:medium');
  assert.equal(nextWorkerModel('gpt-5.6-luna:low', 3), 'gpt-5.6-luna:medium');
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

// codex 0.144 / GPT-5.6 family ladders (2026-07-20 policy: effort ceiling is
// xhigh; past xhigh the ladder jumps models luna -> terra -> sol entering at
// :high; max/ultra are dead ends). Fable 5.1 / Codex 6 Astra wave: sol:xhigh
// is no longer the final ceiling — it escalates one tier further into
// gpt-6-astra:high (astra:xhigh is the new final ceiling; see the dedicated
// "astra is the real ceiling" test above for that assertion).
test('shipped ladder: gpt-5.6-sol:xhigh (no max/ultra climb, escalates into astra)', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT });
  assert.equal(ladder['gpt-5.6-sol:high'], 'gpt-5.6-sol:xhigh');
  assert.equal(ladder['gpt-5.6-sol:xhigh'], 'gpt-6-astra:high');
  assert.equal(ladder['gpt-5.6-sol:max'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-sol:ultra'], CEILING_SENTINEL);
});

test('shipped ladder: gpt-5.6-terra:xhigh jumps model to gpt-5.6-sol:high', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT });
  assert.equal(ladder['gpt-5.6-terra:xhigh'], 'gpt-5.6-sol:high');
  assert.equal(ladder['gpt-5.6-terra:max'], 'gpt-5.6-sol:xhigh');
  assert.equal(ladder['gpt-5.6-terra:ultra'], CEILING_SENTINEL);
});

test('shipped ladder: gpt-5.6-luna:xhigh climbs to gpt-5.6-luna:max before hopping models', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT });
  assert.equal(ladder['gpt-5.6-luna:high'], 'gpt-5.6-luna:max');
  assert.equal(ladder['gpt-5.6-luna:xhigh'], 'gpt-5.6-luna:max');
  assert.equal(ladder['gpt-5.6-luna:max'], 'gpt-5.6-terra:max');
});

// 2026-08-03 luna-first policy (docs/superpowers/specs/2026-08-03-luna-first-cost-routing-design.md):
// within luna, effort climbs before the model jumps (high skips xhigh -> max);
// luna:max hops to the quota-first terra:max lane; terra:max escapes to sol:xhigh
// (terra:max quality sits between sol:high and sol:xhigh, so sol:high would be lateral).
// Partial reversal of 32d181a for luna only — sol/terra keep the xhigh ladder ceiling.
test('luna-first ladder: effort-before-model within luna, quota-first terra:max hop', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder['gpt-5.6-luna:high'], 'gpt-5.6-luna:max');
  assert.equal(ladder['gpt-5.6-luna:xhigh'], 'gpt-5.6-luna:max');
  assert.equal(ladder['gpt-5.6-luna:max'], 'gpt-5.6-terra:max');
  assert.equal(ladder['gpt-5.6-terra:max'], 'gpt-5.6-sol:xhigh');
  // unchanged guards
  assert.equal(ladder['gpt-5.6-luna:medium'], 'gpt-5.6-luna:high');
  assert.equal(ladder['gpt-5.6-terra:xhigh'], 'gpt-5.6-sol:high');
  // sol:xhigh escalates into astra:high as of the Fable 5.1 / Codex 6 Astra
  // wave — not a ceiling any more (was CEILING_SENTINEL before that wave).
  assert.equal(ladder['gpt-5.6-sol:xhigh'], 'gpt-6-astra:high');
  assert.equal(ladder['gpt-5.6-sol:max'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-sol:ultra'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-terra:ultra'], CEILING_SENTINEL);
});

test('nextWorkerModel walks the cost-lane chain past sol:xhigh into the astra:xhigh ceiling', () => {
  assert.equal(nextWorkerModel('gpt-5.6-luna:high', 3), 'gpt-5.6-luna:max');
  assert.equal(nextWorkerModel('gpt-5.6-luna:max', 3), 'gpt-5.6-terra:max');
  assert.equal(nextWorkerModel('gpt-5.6-terra:max', 3), 'gpt-5.6-sol:xhigh');
  // sol:xhigh is no longer a dead end — one more stage reaches astra:high.
  assert.equal(nextWorkerModel('gpt-5.6-sol:xhigh', 3), 'gpt-6-astra:high');
  assert.equal(nextWorkerModel('gpt-6-astra:xhigh', 3), 'BLOCKED');
});

test('shipped ladder: a codex family climbs low..xhigh, and only the generation ceiling terminates', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT });
  assert.equal(ladder['gpt-6-astra:low'], 'gpt-6-astra:medium');
  assert.equal(ladder['gpt-6-astra:high'], 'gpt-6-astra:xhigh');
  // astra is the generation ceiling, so its :xhigh is the ONLY codex rung
  // that terminates. Every other family's :xhigh hands off to the next family
  // up, which is what makes this ladder cross-family rather than four
  // independent chains — assert one handoff so a future edit that flattens
  // them back into per-family dead ends fails here.
  assert.equal(ladder['gpt-6-astra:xhigh'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-terra:xhigh'], 'gpt-5.6-sol:high');
});

// Owner correction (Fable 5.1 / Codex 6 Astra wave): the shipped Worker
// default was briefly raised to the ladder ceiling on the codex side
// (gpt-6-astra) — which broke luna-first three ways at once (frontier price
// every iteration, no escalation headroom so check_model_upgrade returns
// already_max from iteration 1, and the circuit breaker loses its
// escalation signal). This test pins the INVARIANT, not the values: the
// shipped Worker default must have at least TWO upgrade hops remaining
// before reaching the ladder ceiling, on both engines. Both the starting
// value AND the "is it the ceiling" check are derived at test time (from
// RUN_DEFAULTS / the zsh source and from the live models.json walk) rather
// than hardcoded — so this test keeps discriminating correctly through a
// future generation bump without needing an update itself.
test('invariant: the shipped Worker default is never the ladder ceiling, on either engine', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });

  function hopsToCeiling(start) {
    const seen = new Set();
    let current = start;
    let hops = 0;
    while (true) {
      if (seen.has(current)) {
        throw new Error(`cycle detected in ladder starting at '${start}' (revisited '${current}')`);
      }
      seen.add(current);
      const next = ladder[current];
      if (!next || next === CEILING_SENTINEL) {
        return { ceiling: current, hops };
      }
      current = next;
      hops += 1;
    }
  }

  // Claude side: derive the shipped Worker default from RUN_DEFAULTS itself
  // (not a hardcoded 'haiku' literal) so a future default change is checked
  // against whatever it actually becomes.
  const { RUN_DEFAULTS } = await import('../../src/node/run.mjs');
  const claudeStart = RUN_DEFAULTS.workerModel;
  const claudeWalk = hopsToCeiling(claudeStart);
  assert.ok(
    claudeWalk.hops >= 2,
    `claude Worker default '${claudeStart}' has only ${claudeWalk.hops} hop(s) of upgrade headroom (need >= 2) before the ladder ceiling ('${claudeWalk.ceiling}')`,
  );

  // Codex side: no RUN_DEFAULTS field exists for this (it's zsh-only, the
  // Node leader doesn't run tmux campaigns itself) — extract the literal
  // WORKER_CODEX_MODEL/WORKER_CODEX_REASONING defaults directly from the
  // zsh source rather than hardcoding them here.
  const zshSource = await fs.readFile(path.join(repoRoot, 'src/scripts/run_ralph_desk.zsh'), 'utf8');
  const modelMatch = zshSource.match(/WORKER_CODEX_MODEL="\$\{WORKER_CODEX_MODEL:-([\w.-]+)\}"/);
  const reasoningMatch = zshSource.match(/WORKER_CODEX_REASONING="\$\{WORKER_CODEX_REASONING:-([\w.-]+)\}"/);
  assert.ok(modelMatch, 'could not find the WORKER_CODEX_MODEL default in run_ralph_desk.zsh — has it moved/changed?');
  assert.ok(reasoningMatch, 'could not find the WORKER_CODEX_REASONING default in run_ralph_desk.zsh — has it moved/changed?');
  const codexStart = `${modelMatch[1]}:${reasoningMatch[1]}`;
  const codexWalk = hopsToCeiling(codexStart);
  assert.ok(
    codexWalk.hops >= 2,
    `codex Worker default '${codexStart}' has only ${codexWalk.hops} hop(s) of upgrade headroom (need >= 2) before the ladder ceiling ('${codexWalk.ceiling}')`,
  );
});
