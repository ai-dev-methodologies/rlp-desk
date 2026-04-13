import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'us008-cli-entrypoint-tests');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

async function exists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

async function readText(targetPath) {
  return fs.readFile(targetPath, 'utf8');
}

async function runNode(args, options = {}) {
  return execFileAsync(process.execPath, args, {
    cwd: repoRoot,
    env: {
      ...process.env,
      ...options.env,
    },
  });
}

test('US-008 AC8.1 happy: postinstall installs the Node runtime under ~/.claude/ralph-desk and removes legacy zsh scripts', async (t) => {
  const fakeHome = await createTempDir(t);
  const { stdout } = await runNode(['scripts/postinstall.js'], {
    env: {
      HOME: fakeHome,
    },
  });

  const deskDir = path.join(fakeHome, '.claude', 'ralph-desk');
  assert.equal(await exists(path.join(deskDir, 'node', 'run.mjs')), true);
  assert.equal(await exists(path.join(deskDir, 'node', 'runner', 'campaign-main-loop.mjs')), true);
  assert.equal(await exists(path.join(deskDir, 'run_ralph_desk.zsh')), false);
  assert.equal(await exists(path.join(deskDir, 'init_ralph_desk.zsh')), false);
  assert.equal(await exists(path.join(deskDir, 'lib_ralph_desk.zsh')), false);
  assert.match(stdout, /RLP Desk v/);
});

test('US-008 AC8.1 boundary: postinstall replaces a mixed installation with the Node runtime on reinstall', async (t) => {
  const fakeHome = await createTempDir(t);
  const deskDir = path.join(fakeHome, '.claude', 'ralph-desk');
  await fs.mkdir(deskDir, { recursive: true });
  await fs.writeFile(path.join(deskDir, 'run_ralph_desk.zsh'), '#!/bin/zsh\necho old\n', 'utf8');
  await fs.mkdir(path.join(deskDir, 'node'), { recursive: true });
  await fs.writeFile(path.join(deskDir, 'node', 'stale.txt'), 'old-node-runtime\n', 'utf8');

  await runNode(['scripts/postinstall.js'], {
    env: {
      HOME: fakeHome,
    },
  });

  assert.equal(await exists(path.join(deskDir, 'run_ralph_desk.zsh')), false);
  assert.equal(await exists(path.join(deskDir, 'node', 'run.mjs')), true);
  assert.equal(await exists(path.join(deskDir, 'node', 'stale.txt')), false);
});

test('US-008 AC8.1 negative: uninstall removes the installed Node runtime files', async (t) => {
  const fakeHome = await createTempDir(t);
  const deskDir = path.join(fakeHome, '.claude', 'ralph-desk');
  await runNode(['scripts/postinstall.js'], {
    env: {
      HOME: fakeHome,
    },
  });

  await runNode(['scripts/uninstall.js'], {
    env: {
      HOME: fakeHome,
    },
  });

  assert.equal(await exists(path.join(fakeHome, '.claude', 'commands', 'rlp-desk.md')), false);
  assert.equal(await exists(path.join(deskDir, 'node', 'run.mjs')), false);
});

test('US-008 AC8.2 happy: the run command parses tmux example flags and launches the campaign with the expected configuration', async () => {
  const cli = await import('../../src/node/run.mjs');
  let received = null;

  const exitCode = await cli.main(
    ['run', 'test', '--mode', 'tmux', '--worker-model', 'gpt-5.4:medium', '--debug'],
    {
      cwd: repoRoot,
      stdout: { write() {} },
      stderr: { write() {} },
      runCampaign: async (slug, options) => {
        received = { slug, options };
        return { status: 'continue' };
      },
    },
  );

  assert.equal(exitCode, 0);
  assert.deepEqual(received, {
    slug: 'test',
    options: {
      rootDir: repoRoot,
      mode: 'tmux',
      workerModel: 'gpt-5.4:medium',
      verifierModel: 'sonnet',
      finalVerifierModel: 'opus',
      consensusMode: 'off',
      consensusModel: 'gpt-5.4:medium',
      finalConsensusModel: 'gpt-5.4:high',
      verifyMode: 'per-us',
      cbThreshold: 6,
      maxIterations: 100,
      iterTimeout: 600,
      debug: true,
      lockWorkerModel: false,
      autonomous: false,
      withSelfVerification: false,
      flywheel: 'off',
      flywheelModel: 'opus',
    },
  });
});

test('US-008 AC8.2 boundary: the run command applies the documented defaults when optional flags are omitted', async () => {
  const cli = await import('../../src/node/run.mjs');
  let received = null;

  const exitCode = await cli.main(['run', 'demo'], {
    cwd: repoRoot,
    stdout: { write() {} },
    stderr: { write() {} },
    runCampaign: async (slug, options) => {
      received = { slug, options };
      return { status: 'continue' };
    },
  });

  assert.equal(exitCode, 0);
  assert.equal(received.slug, 'demo');
  assert.equal(received.options.mode, 'agent');
  assert.equal(received.options.workerModel, 'haiku');
  assert.equal(received.options.debug, false);
});

test('US-008 AC8.2 negative: the run command rejects unknown flags instead of launching with a silent parse failure', async () => {
  const cli = await import('../../src/node/run.mjs');
  let launched = false;
  let stderr = '';

  const exitCode = await cli.main(['run', 'demo', '--unknown-flag'], {
    cwd: repoRoot,
    stdout: { write() {} },
    stderr: { write(chunk) { stderr += chunk; } },
    runCampaign: async () => {
      launched = true;
      return { status: 'continue' };
    },
  });

  assert.equal(exitCode, 1);
  assert.equal(launched, false);
  assert.match(stderr, /unknown option/i);
});

test('US-008 AC8.3 happy: node src/node/run.mjs --help lists every top-level command in the current CLI interface', async () => {
  const { stdout } = await runNode(['src/node/run.mjs', '--help']);

  for (const command of ['brainstorm', 'init', 'run', 'status', 'logs', 'clean', 'resume']) {
    assert.match(stdout, new RegExp(`\\b${command}\\b`));
  }
});

test('US-008 AC8.3 boundary: node src/node/run.mjs --help includes every run flag from the current interface with no missing options', async () => {
  const { stdout } = await runNode(['src/node/run.mjs', '--help']);

  for (const option of [
    '--mode',
    '--worker-model',
    '--lock-worker-model',
    '--verifier-model',
    '--final-verifier-model',
    '--consensus',
    '--consensus-model',
    '--final-consensus-model',
    '--verify-mode',
    '--cb-threshold',
    '--max-iter',
    '--iter-timeout',
    '--debug',
    '--autonomous',
    '--with-self-verification',
  ]) {
    assert.match(stdout, new RegExp(option.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});

test('US-008 AC8.3 negative: node src/node/run.mjs rejects an unknown command with a clear help hint', async () => {
  await assert.rejects(
    () => runNode(['src/node/run.mjs', 'unknown']),
    (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stderr, /unknown command/i);
      assert.match(error.stderr, /--help/);
      return true;
    },
  );
});

test('US-008 AC8.4 happy: postinstall falls back gracefully on unsupported Node and preserves an existing zsh installation', async (t) => {
  const fakeHome = await createTempDir(t);
  const deskDir = path.join(fakeHome, '.claude', 'ralph-desk');
  await fs.mkdir(deskDir, { recursive: true });
  await fs.writeFile(path.join(deskDir, 'run_ralph_desk.zsh'), '#!/bin/zsh\necho keep-me\n', 'utf8');

  const { stdout } = await runNode(['scripts/postinstall.js'], {
    env: {
      HOME: fakeHome,
      RLP_DESK_NODE_VERSION_OVERRIDE: 'v14.21.3',
    },
  });

  assert.match(stdout, /requires Node\.js >= 16/i);
  assert.equal(await readText(path.join(deskDir, 'run_ralph_desk.zsh')), '#!/bin/zsh\necho keep-me\n');
  assert.equal(await exists(path.join(deskDir, 'node', 'run.mjs')), false);
});

test('US-008 AC8.4 boundary: postinstall treats Node 16 as supported and installs the Node runtime', async (t) => {
  const fakeHome = await createTempDir(t);

  await runNode(['scripts/postinstall.js'], {
    env: {
      HOME: fakeHome,
      RLP_DESK_NODE_VERSION_OVERRIDE: 'v16.0.0',
    },
  });

  assert.equal(await exists(path.join(fakeHome, '.claude', 'ralph-desk', 'node', 'run.mjs')), true);
});

test('US-008 AC8.4 negative: postinstall treats malformed Node versions as unsupported without corrupting the current installation', async (t) => {
  const fakeHome = await createTempDir(t);
  const deskDir = path.join(fakeHome, '.claude', 'ralph-desk');
  await fs.mkdir(deskDir, { recursive: true });
  await fs.writeFile(path.join(deskDir, 'init_ralph_desk.zsh'), '#!/bin/zsh\necho keep-init\n', 'utf8');

  const { stdout } = await runNode(['scripts/postinstall.js'], {
    env: {
      HOME: fakeHome,
      RLP_DESK_NODE_VERSION_OVERRIDE: 'not-a-version',
    },
  });

  assert.match(stdout, /requires Node\.js >= 16/i);
  assert.equal(await readText(path.join(deskDir, 'init_ralph_desk.zsh')), '#!/bin/zsh\necho keep-init\n');
});
