// US-003 — iter-signal canonical status key: tolerant-read legacy `stop`.
//
// Coverage split (do not blur these — mirrors codex-launch-hook-isolation.test.mjs):
//   * zsh leader — LIVE. _resolve_iter_signal_status in lib_ralph_desk.zsh,
//     consumed at run_ralph_desk.zsh's single `signal_status=$(...)` read
//     site. Covered by tests/test_iter_signal_key_tolerance.sh, not here.
//   * native leader — NOT in scope. `rlp-desk.md:557` reads iter-signal.json
//     for `us_id` only; it never reads `status`. Nothing to make tolerant.
//   * Node leader (this file) — DEAD-CODE PARITY ONLY. `--mode agent`
//     hard-errors at run.mjs:891 (ADR-001), so campaign-main-loop.mjs's
//     `run()` — and therefore resolveIterSignalStatus's real call site — is
//     CLI-unreachable. These assertions must never be cited as coverage of a
//     shipping path.
//
// Real unit over the exported, importable function: signals are round-
// tripped through real temp files + JSON.parse (the same path
// readJsonIfExists uses), not just constructed as inline object literals.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { resolveIterSignalStatus } from '../../src/node/runner/campaign-main-loop.mjs';

async function writeSignalFile(obj) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-iter-signal-'));
  const file = path.join(dir, 'iter-signal.json');
  await fs.writeFile(file, JSON.stringify(obj), 'utf8');
  return file;
}

async function readSignal(file) {
  return JSON.parse(await fs.readFile(file, 'utf8'));
}

function captureConsoleError(fn) {
  const calls = [];
  const orig = console.error;
  console.error = (...args) => calls.push(args.join(' '));
  try {
    fn();
  } finally {
    console.error = orig;
  }
  return calls;
}

// ---------------------------------------------------------------------------
// AC1 — status present, no stop → byte-identical (no divergence/deprecation log)
// ---------------------------------------------------------------------------

test('AC1 Node parity: status present, no stop -> resolves to status, no log noise', async () => {
  const file = await writeSignalFile({ status: 'verify', us_id: 'US-003' });
  const signal = await readSignal(file);
  let resolved;
  const calls = captureConsoleError(() => {
    resolved = resolveIterSignalStatus(signal, file);
  });
  assert.equal(resolved, 'verify');
  assert.deepEqual(calls, [], 'no console.error side effects when status alone is present');
});

// ---------------------------------------------------------------------------
// AC2 — legacy stop only, no status -> resolves to stop + one deprecation line naming the file
// ---------------------------------------------------------------------------

test('AC2 Node parity: legacy stop only, no status -> resolves to stop value, deprecation log names the file', async () => {
  const file = await writeSignalFile({ stop: 'verify', us_id: 'US-003' });
  const signal = await readSignal(file);
  let resolved;
  const calls = captureConsoleError(() => {
    resolved = resolveIterSignalStatus(signal, file);
  });
  assert.equal(resolved, 'verify');
  assert.equal(calls.length, 1, 'exactly one deprecation log line');
  assert.match(calls[0], /DEPRECATED/);
  assert.ok(calls[0].includes(file), 'deprecation log must name the file');
});

// ---------------------------------------------------------------------------
// AC3 — both present, different values -> status (canonical) wins, divergence logged
// ---------------------------------------------------------------------------

test('AC3 Node parity: status and stop both present with different values -> status wins, divergence logged', async () => {
  const file = await writeSignalFile({ status: 'verify', stop: 'continue', us_id: 'US-003' });
  const signal = await readSignal(file);
  let resolved;
  const calls = captureConsoleError(() => {
    resolved = resolveIterSignalStatus(signal, file);
  });
  assert.equal(resolved, 'verify', 'canonical status must win');
  assert.equal(calls.length, 1, 'exactly one divergence log line');
  assert.match(calls[0], /divergent values/);
  assert.ok(calls[0].includes('status=verify'));
  assert.ok(calls[0].includes('stop=continue'));
});

test('AC3b Node parity: status and stop both present with the SAME value -> no divergence log', async () => {
  const file = await writeSignalFile({ status: 'verify', stop: 'verify', us_id: 'US-003' });
  const signal = await readSignal(file);
  let resolved;
  const calls = captureConsoleError(() => {
    resolved = resolveIterSignalStatus(signal, file);
  });
  assert.equal(resolved, 'verify');
  assert.deepEqual(calls, [], 'agreeing values must not log a divergence warning');
});

// ---------------------------------------------------------------------------
// AC4 — neither key present -> unchanged (no new silent-accept hole)
// ---------------------------------------------------------------------------

test('AC4 Node parity: neither status nor stop present -> passthrough undefined, no log noise', async () => {
  const file = await writeSignalFile({ us_id: 'US-003', summary: 'no status field' });
  const signal = await readSignal(file);
  let resolved;
  const calls = captureConsoleError(() => {
    resolved = resolveIterSignalStatus(signal, file);
  });
  assert.equal(resolved, undefined);
  assert.deepEqual(calls, [], 'no console.error side effects when neither key is present');
});

// ---------------------------------------------------------------------------
// verify_partial malformed-downgrade call site wiring (parity-only)
// ---------------------------------------------------------------------------

test('parity-only: a legacy stop-keyed verify_partial signal still resolves via resolveIterSignalStatus', async () => {
  const file = await writeSignalFile({ stop: 'verify_partial', us_id: 'US-003', verified_acs: [] });
  const signal = await readSignal(file);
  const resolved = resolveIterSignalStatus(signal, file);
  assert.equal(
    resolved,
    'verify_partial',
    'the malformed-downgrade check in campaign-main-loop.mjs branches on this resolved value, not signal.status directly',
  );
});
