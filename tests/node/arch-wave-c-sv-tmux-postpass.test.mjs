// ARCH Wave C-SV: --with-self-verification is honored under --mode tmux via a
// Node pure-fs post-pass that runs AFTER the zsh leader exits. These tests prove
// the wiring end-to-end against the real generateSVReport (no real zsh, no TTY):
// a real campaign log dir with fake iter artifacts produces a real SV report.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

async function tempRoot(t) {
  const base = path.join(repoRoot, '.tmp', 'arch-wave-c-sv');
  await fs.mkdir(base, { recursive: true });
  const dir = await fs.mkdtemp(path.join(base, 'case-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  return dir;
}

const PRD = (slug) => [`# PRD: ${slug}`, '', '## Objective', 'demo', '', '## US-001: Story', 'x.', ''].join('\n');

async function scaffoldWithArtifacts(t) {
  const rootDir = await tempRoot(t);
  const slug = 'svtmux';
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  await initCampaign(slug, 'demo', { rootDir, tmuxEnv: 'sess', prdContent: PRD(slug) });
  // The zsh leader would have written these; we fake them so the pure-fs SV pass has input.
  const logDir = path.join(rootDir, '.rlp-desk', 'logs', slug);
  await fs.mkdir(logDir, { recursive: true });
  await fs.writeFile(path.join(logDir, 'iter-001-done-claim.json'),
    JSON.stringify({ iteration: 1, us_id: 'US-001', execution_steps: [{ action: 'impl' }] }), 'utf8');
  await fs.writeFile(path.join(logDir, 'iter-001-verify-verdict.json'),
    JSON.stringify({ iteration: 1, us_id: 'US-001', verdict: 'pass', reasoning: 'ok' }), 'utf8');
  return { rootDir, slug };
}

test('Wave C-SV: --mode tmux + --with-self-verification runs the post-pass and writes a real SV report', async (t) => {
  const { rootDir, slug } = await scaffoldWithArtifacts(t);
  const { main } = await import('../../src/node/run.mjs');
  let capturedEnv;
  const stderr = [];

  const exit = await main(['run', slug, '--mode', 'tmux', '--with-self-verification', '--worker-model', 'haiku'], {
    cwd: rootDir,
    stdout: { write() {} },
    stderr: { write: (s) => stderr.push(s) },
    fileExists: () => true,
    zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
    spawnZsh: async (_p, env) => { capturedEnv = env; return 0; },
  });

  assert.equal(exit, 0);
  // The post-pass produced a real report over the fake artifacts.
  const report = path.join(rootDir, '.rlp-desk', 'analytics', slug, 'self-verification-report.md');
  const body = await fs.readFile(report, 'utf8');
  assert.match(body, /iteration/i, 'SV report should reflect the iteration artifacts');
  // Env forwarded for traceability.
  assert.equal(capturedEnv.WITH_SELF_VERIFICATION, '1');
  // The unsupported-flags WARNING must NOT list --with-self-verification anymore.
  const warn = stderr.join('');
  assert.ok(!/--with-self-verification/.test(warn), 'SV must not be reported as unsupported under tmux');
});

test('Wave C-SV: --flywheel is still reported unsupported under --mode tmux (deprecated, not ported)', async (t) => {
  const { rootDir, slug } = await scaffoldWithArtifacts(t);
  const { main } = await import('../../src/node/run.mjs');
  const stderr = [];

  await main(['run', slug, '--mode', 'tmux', '--flywheel', 'on-fail', '--worker-model', 'haiku'], {
    cwd: rootDir,
    stdout: { write() {} },
    stderr: { write: (s) => stderr.push(s) },
    fileExists: () => true,
    zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
    spawnZsh: async () => 0,
  });

  const warn = stderr.join('');
  assert.match(warn, /--flywheel/, 'flywheel must still warn as unsupported under tmux');
  assert.match(warn, /deprecated/i, 'the warning should note flywheel is deprecated');
});
