// Wave D (ADR-001) trigger-file consistency gate: the --mode agent hard-error is now
// ENFORCED in run.mjs, while the narrative docs (ADR-001 §3 + src/commands/rlp-desk.md)
// retain the full dated schedule. The version numbers in the docs MUST stay identical,
// and run.mjs MUST implement the hard-error + the default flip to tmux. A drift here is
// exactly the "governance/template wording bug propagates to every campaign" failure
// class the self-verification gate exists to prevent.
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

test('Wave D: --mode agent hard-error schedule stays consistent across ADR-001 and rlp-desk.md', () => {
  const adr = read('docs/plans/adr-001-leader-consolidation.md');
  const slash = read('src/commands/rlp-desk.md');

  // The narrative docs RETAIN the full dated schedule table (ADR-001 §3 + the slash
  // command's "Direct Node CLI invocation" section). run.mjs no longer carries the
  // schedule banner — it ENFORCES it (asserted separately below).
  for (const [name, body] of [['ADR-001', adr], ['rlp-desk.md', slash]]) {
    // 0.17.0 must be bound to "hard-error", and 0.18.0 to "remov(e/ed/al)" — not just present.
    assert.ok(near(body, HARD_ERROR, 'hard'), `${name}: ${HARD_ERROR} must be stated as the hard-error version`);
    assert.ok(near(body, REMOVE, 'remov'), `${name}: ${REMOVE} must be stated as the removal version`);
    // The 0.17.0 hard-error must be paired with the Node-CLI default flip to tmux.
    assert.ok(near(body, HARD_ERROR, 'tmux', 120), `${name}: ${HARD_ERROR} must mention the default flip to tmux`);
  }

  // rlp-desk.md must reference ADR-001 as the source of the schedule.
  assert.match(slash, /ADR-001/, 'rlp-desk.md must cite ADR-001 for the deprecation schedule');
});

test('Wave D: run.mjs ENFORCES the hard-error — default flipped to tmux, --mode agent exits 2', () => {
  const runMjs = read('src/node/run.mjs');

  // The Node-CLI default mode is flipped from 'agent' to 'tmux' (Wave D / 0.17.0).
  assert.match(runMjs, /mode:\s*'tmux'/, 'the Node-CLI default mode must be flipped to tmux at Wave D');
  assert.doesNotMatch(runMjs, /mode:\s*'agent'/, 'the deprecated agent default must be gone after the flip');

  // --mode agent now hard-errors (exit 2) with a redirect; the SCHEDULED-REMOVAL
  // banner is replaced by enforcement.
  assert.match(runMjs, /options\.mode === 'agent'/, 'run.mjs must branch on --mode agent to hard-error');
  assert.match(runMjs, /ERROR: --mode agent .* no longer supported/i, 'run.mjs must emit the hard-error redirect');
  assert.doesNotMatch(runMjs, /SCHEDULED REMOVAL/, 'the deprecation banner must be replaced by the hard-error');

  // run.mjs banner must no longer carry the vague "Date TBD" placeholder.
  assert.ok(!/Date TBD/.test(runMjs), 'run.mjs must not carry the vague "Date TBD" placeholder');
});

test('Wave D: slash-command --mode default remains native (separate namespace from the Node-CLI flip)', () => {
  const slash = read('src/commands/rlp-desk.md');
  // CRITIC wording guard: the slash --mode default must stay `native`. The Node-CLI
  // default (run.mjs) is a separate namespace and flips to tmux at Wave D / 0.17.0 —
  // the two must not be conflated. Anchor to the actual option-spec line.
  assert.match(slash, /--mode\s+native\|tmux[^\n]*default:\s*`?native`?/i,
    'the slash --mode option spec must keep default: native');
});
