import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseRunOptions, main } from '../../src/node/run.mjs';

// IMP-02 — unknown --mode must be rejected at parse time.
//
// Before this fix, `run <slug> --mode agnet` (a one-character typo of
// "agent") fell through every tmux/native/agent dispatch guard into
// deps.runCampaign() — the deprecated, CLI-unreachable-by-design Node leader
// (ADR-001) — and started a real campaign under the wrong leader. The mode
// value is a closed set; anything else is an input error, not a dispatch.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

test('IMP-02: parseRunOptions throws on an unknown --mode value', () => {
  assert.throws(
    () => parseRunOptions(['--mode', 'agnet'], '/tmp'),
    /unknown --mode: agnet/,
  );
});

test('IMP-02: parseRunOptions accepts the closed set {tmux, native, agent}', () => {
  for (const mode of ['tmux', 'native', 'agent']) {
    const options = parseRunOptions(['--mode', mode], '/tmp');
    assert.equal(options.mode, mode);
  }
});

test('IMP-02: main() surfaces the parse error (exit 1) instead of dispatching', async (t) => {
  const tempRoot = path.join(repoRoot, '.tmp', 'imp02-mode');
  await fs.mkdir(tempRoot, { recursive: true });
  const cwd = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(cwd, { recursive: true, force: true });
  });

  let stderrText = '';
  let campaignRan = false;
  const code = await main(['run', 'some-slug', '--mode', 'agnet'], {
    cwd,
    stdout: { write: () => {} },
    stderr: { write: (s) => { stderrText += s; } },
    runCampaign: async () => { campaignRan = true; return 0; },
  });

  assert.equal(code, 1);
  assert.match(stderrText, /unknown --mode: agnet/);
  assert.equal(campaignRan, false, 'deprecated Node leader must never be reached on a typo');
});
