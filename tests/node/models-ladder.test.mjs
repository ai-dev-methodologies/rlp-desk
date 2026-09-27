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
  assert.equal(ladder.haiku, 'sonnet:high');
  // sonnet:medium is a legacy on-ramp now, not a spine rung: an explicit
  // `--worker-model sonnet:medium` start still escalates once, straight to
  // the ceiling, instead of becoming a dead start.
  assert.equal(ladder['sonnet:medium'], 'claude-opus-5-5:high');
  // 2026-09-26 CB=4/3-rung wave: claude-opus-5-5:high is the claude ceiling —
  // claude-fable-5-1:max leaves the worker spine (Final Verifier only). The
  // legacy opus:* on-ramps all point directly at the new ceiling (see the
  // dedicated "claude ladder is a 3-rung chain" test below for the full
  // spine walk + rationale). opus:medium matters concretely: bare
  // `--worker-model opus` normalizes to it (BARE_ALIAS_NORMALIZATION).
  assert.equal(ladder['opus:low'], 'claude-opus-5-5:high');
  assert.equal(ladder['opus:medium'], 'claude-opus-5-5:high');
  assert.equal(ladder['opus:high'], 'claude-opus-5-5:high');
  assert.equal(ladder['opus:xhigh'], 'claude-opus-5-5:high');
  assert.equal(ladder['gpt-5.6-sol:medium'], 'gpt-5.6-sol:high');
  assert.equal(ladder['gpt-5.6-luna:medium'], 'gpt-5.6-luna:high');
});

// 2026-09-26 CB=4/3-rung wave: claude-fable-5-1:max leaves the worker
// ceiling — it is Final Verifier only now (owner decision, model-mapping
// refresh handoff §2). The real worker ceiling is claude-opus-5-5:high. The
// legacy opus:* on-ramps (opus:low/medium/high/xhigh) all point directly at
// it, and claude-fable-5-1:max stays a terminal key in models.json (usable
// as an explicit manual start) but is unreachable from the spine.
test('claude worker ceiling is claude-opus-5-5:high, not fable: opus:xhigh escalates there, and fable is unreachable from the spine', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder['opus:xhigh'], 'claude-opus-5-5:high');
  assert.equal(ladder['claude-opus-5-5:high'], CEILING_SENTINEL);
  // fable stays a valid terminal key for explicit manual use...
  assert.equal(ladder['claude-fable-5-1:max'], CEILING_SENTINEL);
  // ...but nothing in the spine hands off to it any more.
  for (const [model, next] of Object.entries(ladder)) {
    if (model === 'claude-fable-5-1:max') continue;
    assert.notEqual(next, 'claude-fable-5-1:max', `'${model}' must not escalate into claude-fable-5-1:max — fable left the worker spine`);
  }
});

// Model-mapping refresh (2026-09-26, CB=4/3-rung wave): the claude spine
// shortened from 7 rungs to 3 (2 hops) so CB_THRESHOLD=4 dispatches every
// rung instead of stranding the budget on a mid-ladder rung (see
// docs/plans/model-mapping-2026-09-25-findings.md Part 2 §3). Complexity
// picks only the starting rung; repeated same-US failure walks it upward.
// haiku alone stays bare — it has no effort concept (BARE_ALIAS_NORMALIZATION
// omits it for the same reason). Pinned as a walk, not as independent
// lookups, so a rung inserted in the middle without rewiring its neighbours
// turns this red.
test('claude ladder is a 3-rung chain: haiku -> sonnet:high -> claude-opus-5-5:high -> ceiling', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  const walked = [];
  let rung = 'haiku';
  for (let hop = 0; hop < 20; hop += 1) {
    walked.push(rung);
    const next = ladder[rung];
    if (next === undefined || next === CEILING_SENTINEL) break;
    rung = next;
  }
  assert.deepEqual(walked, [
    'haiku',
    'sonnet:high',
    'claude-opus-5-5:high',
  ]);
  assert.equal(ladder['claude-opus-5-5:high'], CEILING_SENTINEL, 'the walk must end at a real ceiling key, not a lookup miss');
  assert.ok(!walked.includes('claude-fable-5-1:max'), 'the default claude walk must never reach fable — it is Final Verifier only now');
});

// The bare claude aliases are NOT ladder keys any more. Every entry point
// normalizes them first (normalizeModelSpec / _normalize_model_spec:
// sonnet -> sonnet:medium, opus -> opus:medium, claude-fable-5-1 ->
// claude-fable-5-1:max), so a bare key here would be dead weight that also
// re-admits the unpinned-effort start this wave exists to remove. Absence is
// the assertion: a well-meaning "compatibility" re-add must turn this red.
test('claude ladder carries no bare alias keys (normalization owns that, not the ladder)', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  for (const bare of ['sonnet', 'opus', 'claude-fable-5-1', 'fable']) {
    assert.equal(ladder[bare], undefined, `bare '${bare}' must not be a ladder key`);
  }
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

// Owner decision (applied, 2026-09-26): gpt-6-astra is judge-only and leaves
// the worker escalation path entirely (model-mapping refresh handoff §2).
// gpt-5.6-sol:xhigh is now its own terminal ceiling instead of escalating
// into astra:high. INVERTED from the earlier version of this test, which
// pinned the astra escalation as the "real ceiling" — that was the
// pre-owner-decision contract this wave reopens. This assertion is the
// mutation control: it fails if a future edit re-wires sol:xhigh into astra.
test('gpt-5.6-sol:xhigh terminates at its own ceiling (astra left the worker escalation path)', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder['gpt-5.6-sol:xhigh'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-6-astra:xhigh'], CEILING_SENTINEL, 'astra keeps its own self-chain ceiling for explicit manual use');
  assert.equal(ladder['gpt-5.6-terra:max'], CEILING_SENTINEL, 'terra:max is now the cost-lane ceiling — the old terra:max -> sol:xhigh hop is gone');
});

test('malformed-JSON warn+fallthrough: malformed override falls through to shipped defaults with exactly one warning', async (t) => {
  const dir = await createTempDir(t);
  const overrideFile = path.join(dir, 'override.json');
  await fs.writeFile(overrideFile, 'not valid json {{{');

  const warnings = [];
  const ladder = loadModelLadder({ overrideFile, shippedFile: realShippedFile, warn: (msg) => warnings.push(msg) });

  assert.equal(ladder.haiku, 'sonnet:high'); // fell through to shipped defaults
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
    assert.equal(ladder.haiku, 'sonnet:high');
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
  // C1 fix: fable is Final-Verifier-only, never a worker target — the
  // 4-entry emergency ladder's terminal is claude-opus-5-5:high (the real
  // claude ceiling), not claude-fable-5-1:max.
  assert.equal(ladder.opus, 'claude-opus-5-5:high');
  assert.equal(ladder['claude-opus-5-5'], CEILING_SENTINEL);
  assert.equal(warnings.length, 1, `expected exactly one warning, got ${warnings.length}: ${JSON.stringify(warnings)}`);
});

test('""->BLOCKED ceiling normalization: nextWorkerModel treats a ceiling key as BLOCKED', () => {
  // 3 consecutive failures -> stage 1 upgrade attempt. opus:xhigh is a legacy
  // on-ramp that escalates to claude-opus-5-5:high, the real claude ceiling
  // (JSON "" -> 'BLOCKED'). claude-fable-5-1:max is unreachable from the
  // spine now but stays a valid ceiling key for an explicit manual start.
  assert.equal(nextWorkerModel('opus:xhigh', 3), 'claude-opus-5-5:high');
  assert.equal(nextWorkerModel('claude-opus-5-5:high', 3), 'BLOCKED');
  assert.equal(nextWorkerModel('claude-fable-5-1:max', 3), 'BLOCKED');
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
  // 2026-09-26 CB=4/3-rung wave: the default spine is haiku -> sonnet:high ->
  // claude-opus-5-5:high. sonnet:medium is a legacy on-ramp, not on the
  // default walk any more — it escalates straight to the ceiling.
  assert.equal(nextWorkerModel('haiku', 3), 'sonnet:high');
  assert.equal(nextWorkerModel('sonnet:high', 3), 'claude-opus-5-5:high');
  assert.equal(nextWorkerModel('sonnet:medium', 3), 'claude-opus-5-5:high');
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
// :high; max/ultra are dead ends). 2026-09-26 CB=4/3-rung wave: gpt-6-astra
// is judge-only and left the worker escalation path (owner decision) — sol:xhigh
// is its own terminal ceiling again, not a hop into astra:high.
test('shipped ladder: gpt-5.6-sol:xhigh (no max/ultra climb, no longer escalates into astra)', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT });
  assert.equal(ladder['gpt-5.6-sol:high'], 'gpt-5.6-sol:xhigh');
  assert.equal(ladder['gpt-5.6-sol:xhigh'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-sol:max'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-sol:ultra'], CEILING_SENTINEL);
});

// 2026-09-26 CB=4/3-rung wave: terra:max is now the cost-lane ceiling
// itself (the luna:high -> luna:max -> terra:max spine) — the old
// terra:max -> sol:xhigh -> astra hop is gone.
test('shipped ladder: gpt-5.6-terra:xhigh jumps model to gpt-5.6-sol:high, terra:max is the cost-lane ceiling', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT });
  assert.equal(ladder['gpt-5.6-terra:xhigh'], 'gpt-5.6-sol:high');
  assert.equal(ladder['gpt-5.6-terra:max'], CEILING_SENTINEL);
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
// luna:max hops to the quota-first terra:max lane. 2026-09-26 CB=4/3-rung wave
// (docs/plans/model-mapping-2026-09-25-findings.md Part 2 §3): terra:max is now
// the cost-lane's own ceiling — the old terra:max -> sol:xhigh -> astra escape
// hatch is gone, so the whole cost lane is the 3-rung spine
// luna:high -> luna:max -> terra:max.
test('luna-first ladder: effort-before-model within luna, terra:max is the cost-lane ceiling', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder['gpt-5.6-luna:high'], 'gpt-5.6-luna:max');
  assert.equal(ladder['gpt-5.6-luna:xhigh'], 'gpt-5.6-luna:max');
  assert.equal(ladder['gpt-5.6-luna:max'], 'gpt-5.6-terra:max');
  assert.equal(ladder['gpt-5.6-terra:max'], CEILING_SENTINEL);
  // unchanged guards
  assert.equal(ladder['gpt-5.6-luna:medium'], 'gpt-5.6-luna:high');
  assert.equal(ladder['gpt-5.6-terra:xhigh'], 'gpt-5.6-sol:high');
  // sol:xhigh is its own terminal ceiling again — astra left the worker path.
  assert.equal(ladder['gpt-5.6-sol:xhigh'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-sol:max'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-sol:ultra'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-terra:ultra'], CEILING_SENTINEL);
});

test('nextWorkerModel walks the cost-lane chain to its terra:max ceiling (astra no longer reachable)', () => {
  assert.equal(nextWorkerModel('gpt-5.6-luna:high', 3), 'gpt-5.6-luna:max');
  assert.equal(nextWorkerModel('gpt-5.6-luna:max', 3), 'gpt-5.6-terra:max');
  // terra:max is now the cost-lane ceiling — no further hop into sol/astra.
  assert.equal(nextWorkerModel('gpt-5.6-terra:max', 3), 'BLOCKED');
  assert.equal(nextWorkerModel('gpt-5.6-sol:xhigh', 3), 'BLOCKED');
  assert.equal(nextWorkerModel('gpt-6-astra:xhigh', 3), 'BLOCKED');
});

// No codex worker walk reaches gpt-6-astra any more — astra is judge-only
// (FINAL_VERIFIER_CODEX_MODEL / FINAL_CONSENSUS_MODEL), never a worker
// escalation target. Walk every non-astra codex key in the shipped ladder
// and assert the walk never lands on an astra rung.
test('no codex worker walk reaches gpt-6-astra from any non-astra start (astra is judge-only)', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  const nonAstraStarts = Object.keys(ladder).filter((key) => !key.startsWith('gpt-6-astra'));
  for (const start of nonAstraStarts) {
    const seen = new Set();
    let current = start;
    for (let hop = 0; hop < 20; hop += 1) {
      if (seen.has(current)) break; // cycle guard, not this test's concern
      seen.add(current);
      assert.ok(!current.startsWith('gpt-6-astra'), `walk from '${start}' reached astra rung '${current}' — astra must stay judge-only`);
      const next = ladder[current];
      if (next === undefined || next === CEILING_SENTINEL) break;
      current = next;
    }
  }
});

test('shipped ladder: a codex family climbs low..xhigh; astra, sol:xhigh and terra:max are all now terminal', async () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT });
  assert.equal(ladder['gpt-6-astra:low'], 'gpt-6-astra:medium');
  assert.equal(ladder['gpt-6-astra:high'], 'gpt-6-astra:xhigh');
  // astra is judge-only and self-terminates; it is no longer the sole codex
  // termination point now that sol:xhigh and terra:max also ceiling directly
  // (2026-09-26 CB=4/3-rung wave). terra:xhigh still hands off to sol:high —
  // that cross-family handoff is unaffected.
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

// 2026-09-26 CB=4/3-rung wave: every per-complexity worker start brainstorm
// recommends must be a real ladder key, or the campaign reports
// already_max from iteration 1 (docs/plans/model-mapping-2026-09-25-findings.md
// §4 "Dead starts"). Claude recommendations are the new spine
// (haiku/sonnet:high/claude-opus-5-5:high); codex recommendations are
// hardcoded here from the CURRENT cross-engine table in
// src/commands/rlp-desk.md step 7 (~lines 71-116, cost + speed lane Worker
// columns) — that table is out of this wave's scope and still names these
// exact starts.
test('every brainstorm-recommended per-complexity worker start is a ladder key (no dead starts)', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  const claudeStarts = ['haiku', 'sonnet:high', 'claude-opus-5-5:high'];
  const codexStarts = [
    'gpt-5.6-luna:high', // LOW, and MEDIUM/HIGH-cost-lane's predecessor rung
    'gpt-5.6-luna:xhigh', // MEDIUM
    'gpt-5.6-luna:max', // HIGH cost lane
    'gpt-5.6-sol:medium', // HIGH speed lane
    'gpt-5.6-sol:high', // CRITICAL
  ];
  for (const start of [...claudeStarts, ...codexStarts]) {
    assert.notEqual(ladder[start], undefined, `'${start}' is a recommended worker start but not a ladder key — it would report already_max from iteration 1`);
  }
});
