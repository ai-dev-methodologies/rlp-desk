// Wave B (ADR-001) trigger-file consistency gate: the --mode agent deprecation
// schedule version numbers MUST be identical across the three places that state
// them — ADR-001 §3, src/commands/rlp-desk.md, and the src/node/run.mjs banner.
// A drift here is exactly the "governance/template wording bug propagates to every
// campaign" failure class the self-verification gate exists to prevent.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => fs.readFileSync(path.join(repoRoot, p), 'utf8');

// The canonical schedule (ADR-001 §3): hard-error at 0.17.0, remove at 0.18.0, louder banner at 0.16.x.
const HARD_ERROR = '0.17.0';
const REMOVE = '0.18.0';

// Each schedule statement must bind the version to its MEANING, not merely mention
// the number (codex review: presence-only assertions were too shallow).
const near = (body, version, keyword, window = 80) => {
  const re = new RegExp(`${version.replace(/\./g, '\\.')}[\\s\\S]{0,${window}}?${keyword}|${keyword}[\\s\\S]{0,${window}}?${version.replace(/\./g, '\\.')}`, 'i');
  return re.test(body);
};

test('Wave B: --mode agent deprecation schedule is consistent across ADR-001, rlp-desk.md, run.mjs', () => {
  const adr = read('docs/plans/adr-001-leader-consolidation.md');
  const slash = read('src/commands/rlp-desk.md');
  const runMjs = read('src/node/run.mjs');

  for (const [name, body] of [['ADR-001', adr], ['rlp-desk.md', slash], ['run.mjs', runMjs]]) {
    // 0.17.0 must be bound to "hard-error", and 0.18.0 to "remov(e/ed/al)" — not just present.
    assert.ok(near(body, HARD_ERROR, 'hard'), `${name}: ${HARD_ERROR} must be stated as the hard-error version`);
    assert.ok(near(body, REMOVE, 'remov'), `${name}: ${REMOVE} must be stated as the removal version`);
  }

  // The 0.17.0 hard-error must be paired with the Node-CLI default flip to tmux
  // (the Wave-D landmine the consensus flagged) in both the spec and the banner.
  for (const [name, body] of [['ADR-001', adr], ['rlp-desk.md', slash], ['run.mjs', runMjs]]) {
    assert.ok(near(body, HARD_ERROR, 'tmux', 120), `${name}: ${HARD_ERROR} must mention the default flip to tmux`);
  }

  // run.mjs banner must no longer carry the vague "Date TBD" placeholder.
  assert.ok(!/Date TBD/.test(runMjs), 'run.mjs banner must replace "Date TBD" with the concrete schedule');

  // rlp-desk.md must reference ADR-001 as the source of the schedule.
  assert.match(slash, /ADR-001/, 'rlp-desk.md must cite ADR-001 for the deprecation schedule');
});

test('Wave B: slash-command --mode default remains native (NOT flipped by the schedule wording)', () => {
  const slash = read('src/commands/rlp-desk.md');
  // CRITIC wording guard: the slash --mode default must stay `native`. The Node-CLI
  // default (run.mjs) is a separate namespace and flips to tmux only at 0.17.0 (Wave D).
  // Anchor to the actual option-spec line, not a broad match (codex review).
  assert.match(slash, /--mode\s+native\|tmux[^\n]*default:\s*`?native`?/i,
    'the slash --mode option spec must keep default: native in Wave B');
  // And the Node-CLI default must NOT be flipped yet (that is Wave D / 0.17.0).
  const runMjs = read('src/node/run.mjs');
  assert.match(runMjs, /mode:\s*'agent'/, 'Wave B must NOT flip the Node-CLI default (mode: \'agent\' stays until 0.17.0)');
});
