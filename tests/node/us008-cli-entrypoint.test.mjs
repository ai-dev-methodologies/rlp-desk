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

test('US-008 AC8.1 happy: postinstall installs the Node runtime AND the zsh tmux runner under ~/.claude/ralph-desk (v0.14.0)', async (t) => {
  // v0.14.0 inversion: the previous contract removed legacy zsh files because
  // the Node leader was meant to be the only --mode tmux backend. That broke
  // BOS-style production tmux flows (no heartbeat / copy-mode guard /
  // prompt-stall in Node), so the zsh runner is now restored as the canonical
  // --mode tmux path. postinstall must therefore SYNC the three zsh files,
  // not delete them.
  const fakeHome = await createTempDir(t);
  const { stdout } = await runNode(['scripts/postinstall.js'], {
    env: {
      HOME: fakeHome,
    },
  });

  const deskDir = path.join(fakeHome, '.claude', 'ralph-desk');
  assert.equal(await exists(path.join(deskDir, 'node', 'run.mjs')), true);
  assert.equal(await exists(path.join(deskDir, 'node', 'runner', 'campaign-main-loop.mjs')), true);
  // init/run scripts ship a shebang and the banner lands on line 2; the
  // library file (lib_ralph_desk.zsh) is sourced and has no shebang, so its
  // banner lives on line 1. Both shapes are acceptable.
  const shebangedZsh = ['init_ralph_desk.zsh', 'run_ralph_desk.zsh'];
  const sourcedZsh = ['lib_ralph_desk.zsh'];
  for (const zshName of shebangedZsh) {
    const zshPath = path.join(deskDir, zshName);
    assert.equal(await exists(zshPath), true, `${zshName} must be installed`);
    const head = (await readText(zshPath)).split('\n').slice(0, 2).join('\n');
    assert.match(head, /^#!\/bin\/zsh/, `${zshName} must keep its zsh shebang on line 1`);
    assert.match(head, /DO NOT EDIT/, `${zshName} must have the install banner on line 2`);
  }
  for (const zshName of sourcedZsh) {
    const zshPath = path.join(deskDir, zshName);
    assert.equal(await exists(zshPath), true, `${zshName} must be installed`);
    const head = (await readText(zshPath)).split('\n')[0];
    assert.match(head, /^# DO NOT EDIT/, `${zshName} must have the install banner on line 1 (sourced library, no shebang)`);
  }
  assert.match(stdout, /RLP Desk v/);
});

test('US-008 AC8.1 boundary: postinstall syncs zsh files from source on reinstall (replaces stale content)', async (t) => {
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

  // v0.14.0: zsh runner is preserved AND replaced from source — stale
  // hand-written content does not survive reinstall.
  assert.equal(await exists(path.join(deskDir, 'run_ralph_desk.zsh')), true);
  const runnerBody = await readText(path.join(deskDir, 'run_ralph_desk.zsh'));
  assert.doesNotMatch(runnerBody, /^echo old$/m, 'reinstall must overwrite the stale stub');
  assert.match(runnerBody, /Ralph Desk Tmux Runner/, 'reinstall must copy the source body');
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

test('US-008 AC8.2 happy: the run command parses agent example flags and launches the campaign with the expected configuration', async () => {
  // v0.14.0: --mode tmux now delegates to the zsh runner (see the zsh routing
  // test below). Flag-parsing coverage moved to --mode agent which still goes
  // through the Node leader (deps.runCampaign).
  const cli = await import('../../src/node/run.mjs');
  let received = null;

  const exitCode = await cli.main(
    ['run', 'test', '--mode', 'agent', '--worker-model', 'gpt-5.5:medium', '--debug'],
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
      mode: 'agent',
      workerModel: 'gpt-5.5:medium',
      verifierModel: 'sonnet',
      finalVerifierModel: 'opus',
      consensusMode: 'off',
      consensusModel: 'gpt-5.5:medium',
      finalConsensusModel: 'gpt-5.5:high',
      verifyMode: 'per-us',
      cbThreshold: 6,
      maxIterations: 100,
      iterTimeout: 600,
      debug: true,
      lockWorkerModel: false,
      autonomous: false,
      laneStrict: false,
      testDensityStrict: false,
      withSelfVerification: false,
      flywheel: 'off',
      flywheelModel: 'opus',
      flywheelGuard: 'off',
      flywheelGuardModel: 'opus',
    },
  });
});

test('US-008 AC8.2 tmux: --mode tmux delegates to the zsh runner with mapped env vars (v0.14.0 routing)', async (t) => {
  // Use a fresh temp dir so detectLegacyDeskInRunMode does not trip on the
  // repo's own .claude/ralph-desk/ tree.
  const tempCwd = await createTempDir(t);
  const cli = await import('../../src/node/run.mjs');
  let spawned = null;
  let runCalled = false;

  const exitCode = await cli.main(
    [
      'run', 'demo',
      '--mode', 'tmux',
      '--worker-model', 'gpt-5.5:high',
      '--verifier-model', 'sonnet',
      '--max-iter', '5',
      '--iter-timeout', '900',
      '--cb-threshold', '4',
      '--consensus', 'final-only',
      '--lock-worker-model',
      '--autonomous',
      '--lane-strict',
      '--test-density-strict',
    ],
    {
      cwd: tempCwd,
      stdout: { write() {} },
      stderr: { write() {} },
      runCampaign: async () => {
        runCalled = true;
        return { status: 'continue' };
      },
      fileExists: () => true,
      zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
      spawnZsh: async (zshPath, env, cwd) => {
        spawned = { zshPath, env, cwd };
        return 0;
      },
    },
  );

  assert.equal(exitCode, 0);
  assert.equal(runCalled, false, 'tmux mode must not call the Node leader');
  assert.equal(spawned.zshPath, '/fake/run_ralph_desk.zsh');
  assert.equal(spawned.cwd, tempCwd);
  assert.equal(spawned.env.LOOP_NAME, 'demo');
  assert.equal(spawned.env.WORKER_MODEL, 'gpt-5.5:high');
  assert.equal(spawned.env.VERIFIER_MODEL, 'sonnet');
  assert.equal(spawned.env.MAX_ITER, '5');
  assert.equal(spawned.env.ITER_TIMEOUT, '900');
  assert.equal(spawned.env.CB_THRESHOLD, '4');
  assert.equal(spawned.env.CONSENSUS_MODE, 'final-only');
  assert.equal(spawned.env.LOCK_WORKER_MODEL, '1');
  assert.equal(spawned.env.AUTONOMOUS_MODE, '1');
  assert.equal(spawned.env.LANE_MODE, 'strict');
  assert.equal(spawned.env.TEST_DENSITY_MODE, 'strict');
  assert.equal(spawned.env.ROOT, tempCwd);
});

test('US-008 AC8.2 tmux missing zsh runner: surfaces actionable error and exits non-zero', async (t) => {
  const tempCwd = await createTempDir(t);
  const cli = await import('../../src/node/run.mjs');
  let stderr = '';

  const exitCode = await cli.main(
    ['run', 'demo', '--mode', 'tmux', '--worker-model', 'gpt-5.5:high'],
    {
      cwd: tempCwd,
      stdout: { write() {} },
      stderr: { write(chunk) { stderr += chunk; } },
      runCampaign: async () => ({ status: 'continue' }),
      fileExists: () => false,
      zshRunnerPath: () => '/missing/run_ralph_desk.zsh',
      spawnZsh: async () => {
        throw new Error('spawn must not be reached when runner is missing');
      },
    },
  );

  assert.equal(exitCode, 1);
  assert.match(stderr, /zsh runner not found/);
  assert.match(stderr, /\/missing\/run_ralph_desk\.zsh/);
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

test('main run command warns when claude worker model used in tmux mode', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stderrChunks = [];
  const stdoutChunks = [];
  const stderr = { write: (s) => { stderrChunks.push(String(s)); } };
  const stdout = { write: (s) => { stdoutChunks.push(String(s)); } };
  const fakeRun = async () => ({ status: 'continue' });

  const prevEnv = process.env.NODE_ENV;
  delete process.env.NODE_ENV;
  try {
    await main(
      ['run', 'demo', '--mode', 'tmux', '--worker-model', 'sonnet'],
      {
        runCampaign: fakeRun,
        stderr,
        stdout,
        cwd: process.cwd(),
        // v0.14.0: prevent the routing from spawning a real zsh process.
        fileExists: () => true,
        zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
        spawnZsh: async () => 0,
      },
    );
  } finally {
    if (prevEnv !== undefined) process.env.NODE_ENV = prevEnv;
  }

  const combined = stderrChunks.join('');
  assert.match(combined, /Claude worker in tmux mode/);
  assert.match(combined, /\.rlp-desk/);
});

test('main run command does not warn when codex worker model used in tmux mode', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stderrChunks = [];
  const stdoutChunks = [];
  const stderr = { write: (s) => { stderrChunks.push(String(s)); } };
  const stdout = { write: (s) => { stdoutChunks.push(String(s)); } };
  const fakeRun = async () => ({ status: 'continue' });

  const prevEnv = process.env.NODE_ENV;
  delete process.env.NODE_ENV;
  try {
    await main(
      ['run', 'demo', '--mode', 'tmux', '--worker-model', 'gpt-5.5:high'],
      {
        runCampaign: fakeRun,
        stderr,
        stdout,
        cwd: process.cwd(),
        // v0.14.0: prevent the routing from spawning a real zsh process.
        fileExists: () => true,
        zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
        spawnZsh: async () => 0,
      },
    );
  } finally {
    if (prevEnv !== undefined) process.env.NODE_ENV = prevEnv;
  }

  assert.doesNotMatch(stderrChunks.join(''), /Claude worker in tmux mode/);
});

test('main run command does not warn when claude worker is used in agent mode', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stderrChunks = [];
  const stdoutChunks = [];
  const stderr = { write: (s) => { stderrChunks.push(String(s)); } };
  const stdout = { write: (s) => { stdoutChunks.push(String(s)); } };
  const fakeRun = async () => ({ status: 'continue' });

  const prevEnv = process.env.NODE_ENV;
  delete process.env.NODE_ENV;
  try {
    await main(
      ['run', 'demo', '--mode', 'agent', '--worker-model', 'sonnet'],
      { runCampaign: fakeRun, stderr, stdout, cwd: process.cwd() },
    );
  } finally {
    if (prevEnv !== undefined) process.env.NODE_ENV = prevEnv;
  }

  assert.doesNotMatch(stderrChunks.join(''), /Claude worker in tmux mode/);
});
