import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pollForSignal, TimeoutError } from '../../src/node/polling/signal-poller.mjs';

// R2-E: the dismisser reads the SAME pane capture the poller takes. The fail-closed prompt
// rule (P2) forbids continuation-line heuristics, so the default capture must be soft-wrap
// joined (`tmux capture-pane -J`), exactly like the zsh leader's `capture-pane -p -J -S -50`.
// A fake `tmux` on PATH records the arguments the poller really passes.

test('R2-E: the default pane capture used for prompt dismissal is soft-wrap joined (capture-pane -J)', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fake-tmux-'));
  const logFile = path.join(dir, 'args.log');
  const script = '#!/bin/sh\necho "$@" >> "$FAKE_TMUX_LOG"\ncase "$1" in display-message) echo claude ;; esac\nexit 0\n';
  await fs.writeFile(path.join(dir, 'tmux'), script, { mode: 0o755 });
  const savedPath = process.env.PATH;
  const savedLog = process.env.FAKE_TMUX_LOG;
  process.env.PATH = `${dir}${path.delimiter}${savedPath}`;
  process.env.FAKE_TMUX_LOG = logFile;
  t.after(async () => {
    process.env.PATH = savedPath;
    if (savedLog === undefined) delete process.env.FAKE_TMUX_LOG;
    else process.env.FAKE_TMUX_LOG = savedLog;
    await fs.rm(dir, { recursive: true, force: true });
  });

  const enoent = () => Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
  await assert.rejects(
    pollForSignal('/virtual/never.json', {
      paneId: '%1',
      pollIntervalMs: 10,
      timeoutMs: 80,
      readFile: async () => {
        throw enoent();
      },
      getPaneCommand: async () => 'claude',
    }),
    TimeoutError,
  );

  const captures = (await fs.readFile(logFile, 'utf8')).split('\n').filter((l) => l.startsWith('capture-pane'));
  assert.ok(captures.length > 0, 'the poller must have captured the pane');
  for (const line of captures) {
    assert.match(line, /(^|\s)-J(\s|$)/, `capture must be soft-wrap joined: ${line}`);
  }
});
