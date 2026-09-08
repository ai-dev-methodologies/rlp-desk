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

test('US-008 AC8.2 happy: --mode agent hard-errors (exit 2) and does NOT launch the Node leader (ARCH Wave D)', async () => {
  // ARCH Wave D (ADR-001 §3): the direct Node-CLI --mode agent entry point now
  // hard-errors instead of dispatching to the deprecated Node leader. runCampaign
  // must NOT be reached. Flag-parsing coverage now lives in the --mode tmux
  // env-mapping test below (the canonical production leader).
  const cli = await import('../../src/node/run.mjs');
  let runCampaignInvocations = 0;
  let stderr = '';

  const exitCode = await cli.main(
    ['run', 'test', '--mode', 'agent', '--worker-model', 'gpt-5.5:medium', '--debug'],
    {
      cwd: repoRoot,
      stdout: { write() {} },
      stderr: { write(chunk) { stderr += chunk; } },
      runCampaign: async () => {
        runCampaignInvocations += 1;
        return { status: 'continue' };
      },
    },
  );

  assert.equal(exitCode, 2, '--mode agent must exit 2');
  assert.equal(runCampaignInvocations, 0, 'runCampaign must NOT be invoked for --mode agent');
  assert.match(stderr, /ERROR: --mode agent .* no longer supported/i);
  assert.match(stderr, /--mode tmux/);
  assert.match(stderr, /--mode native/);
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
      '--consensus-parallel',
      '--pre-gate-timeout', '120',
      '--pre-gate-cmd-timeout', '45',
      '--waivers-sha256', 'abc123def456',
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
  assert.equal(spawned.env.RLP_CONSENSUS_PARALLEL, '1', 'Feature 2: --consensus-parallel forwards RLP_CONSENSUS_PARALLEL=1');
  assert.equal(spawned.env.RLP_PREGATE_TIMEOUT, '120', 'Feature 1: --pre-gate-timeout forwards RLP_PREGATE_TIMEOUT');
  assert.equal(spawned.env.RLP_PREGATE_CMD_TIMEOUT, '45', 'Feature 1 L2: --pre-gate-cmd-timeout forwards RLP_PREGATE_CMD_TIMEOUT');
  assert.equal(spawned.env.RLP_WAIVERS_SHA256, 'abc123def456', 'US-002: --waivers-sha256 forwards RLP_WAIVERS_SHA256');
  assert.equal(spawned.env.LOCK_WORKER_MODEL, '1');
  assert.equal(spawned.env.AUTONOMOUS_MODE, '1');
  assert.equal(spawned.env.LANE_MODE, 'strict');
  assert.equal(spawned.env.TEST_DENSITY_MODE, 'strict');
  assert.equal(spawned.env.ROOT, tempCwd);
});

// IMP-03 F3: --debug was a dead flag on the tmux path — parsed into
// options.debug but never mapped in buildZshEnv, so the zsh leader's DEBUG
// only ever came from the operator's own environment via ...parentEnv. It now
// forwards DEBUG=1 to the leader.
test('US-008 IMP-03: --mode tmux --debug forwards DEBUG=1 to the zsh leader', async (t) => {
  const tempCwd = await createTempDir(t);
  const cli = await import('../../src/node/run.mjs');
  let spawned = null;

  const exitCode = await cli.main(
    ['run', 'demo', '--mode', 'tmux', '--debug'],
    {
      cwd: tempCwd,
      stdout: { write() {} },
      stderr: { write() {} },
      runCampaign: async () => ({ status: 'continue' }),
      fileExists: () => true,
      zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
      spawnZsh: async (zshPath, env, cwd) => { spawned = { zshPath, env, cwd }; return 0; },
    },
  );

  assert.equal(exitCode, 0);
  assert.equal(spawned.env.DEBUG, '1', 'IMP-03 F3: --debug forwards DEBUG=1 to the leader');
});

// IMP-03 F3 sibling: without --debug the CLI must not set DEBUG (only the
// operator environment could, via ...parentEnv).
test('US-008 IMP-03: --mode tmux without --debug does NOT set DEBUG from the CLI', async (t) => {
  const tempCwd = await createTempDir(t);
  const cli = await import('../../src/node/run.mjs');
  const savedDebug = process.env.DEBUG;
  delete process.env.DEBUG;
  t.after(() => { if (savedDebug !== undefined) process.env.DEBUG = savedDebug; });
  let spawned = null;

  const exitCode = await cli.main(
    ['run', 'demo', '--mode', 'tmux'],
    {
      cwd: tempCwd,
      stdout: { write() {} },
      stderr: { write() {} },
      runCampaign: async () => ({ status: 'continue' }),
      fileExists: () => true,
      zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
      spawnZsh: async (zshPath, env, cwd) => { spawned = { zshPath, env, cwd }; return 0; },
    },
  );

  assert.equal(exitCode, 0);
  assert.equal(spawned.env.DEBUG, undefined, 'no --debug → the CLI must not set DEBUG');
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

test('US-008 AC8.2 boundary: bare `run <slug>` now defaults to --mode tmux and applies documented defaults (ARCH Wave D)', async (t) => {
  // ARCH Wave D (ADR-001 §3): the Node-CLI default mode flipped from 'agent' to
  // 'tmux'. A bare `run <slug>` delegates to the zsh runner (spawnZsh) and does
  // NOT call the Node leader (runCampaign). Fresh tempdir avoids legacy desk
  // detection on the repo's own .rlp-desk/ tree.
  const tempCwd = await createTempDir(t);
  const cli = await import('../../src/node/run.mjs');
  let spawned = null;
  let runCalled = false;

  const exitCode = await cli.main(['run', 'demo'], {
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
  });

  assert.equal(exitCode, 0);
  assert.equal(runCalled, false, 'default mode (tmux) must not call the Node leader');
  assert.equal(spawned.env.LOOP_NAME, 'demo');
  assert.equal(spawned.env.WORKER_MODEL, 'haiku', 'default worker model');
  assert.equal(spawned.env.MAX_ITER, '100', 'default max-iter');
  assert.equal(spawned.env.CB_THRESHOLD, '6', 'default cb-threshold');
  assert.equal(spawned.env.VERIFY_MODE, 'per-us', 'default verify-mode');
  assert.equal(spawned.env.CONSENSUS_MODE, 'off', 'default consensus');
  assert.equal(spawned.env.RLP_CONSENSUS_PARALLEL, '0', 'Feature 2: parallel consensus OFF by default');
  assert.equal(spawned.env.RLP_PREGATE_TIMEOUT, '300', 'Feature 1: default pre-gate timeout 300s');
  assert.equal(spawned.env.RLP_PREGATE_CMD_TIMEOUT, '120', 'Feature 1 L2: default replay per-command timeout 120s');
  assert.equal(spawned.env.RLP_WAIVERS_SHA256, '', 'US-002: no --waivers-sha256 → empty (a present waivers.json is then fully rejected fail-closed)');
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
    '--consensus-parallel',
    '--verify-mode',
    '--cb-threshold',
    '--max-iter',
    '--iter-timeout',
    '--pre-gate-timeout',
    '--pre-gate-cmd-timeout',
    '--waivers-sha256',
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

// ────────────────────────────────────────────────────────────────────────
// P1.b (native-agent-revert plan v7): --mode native + --mode agent deprecation
// ────────────────────────────────────────────────────────────────────────

test('US-008 P1.b: --mode native exits 2 with slash-only error message', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stderrChunks = [];
  const stdoutChunks = [];
  const stderr = { write: (s) => { stderrChunks.push(String(s)); } };
  const stdout = { write: (s) => { stdoutChunks.push(String(s)); } };
  // runCampaign must NOT be called for --mode native (slash-only).
  let runCampaignInvocations = 0;
  const fakeRun = async () => {
    runCampaignInvocations += 1;
    return { status: 'continue' };
  };

  const exitCode = await main(
    ['run', 'demo', '--mode', 'native', '--worker-model', 'sonnet'],
    { runCampaign: fakeRun, stderr, stdout, cwd: process.cwd() },
  );

  assert.equal(exitCode, 2, '--mode native must exit 2');
  assert.equal(runCampaignInvocations, 0, 'runCampaign must NOT be invoked for --mode native');
  const stderrText = stderrChunks.join('');
  assert.match(stderrText, /ERROR: --mode native is slash-command-only/);
  assert.match(stderrText, /\/rlp-desk run .* --mode native/);
});

test('US-008 Wave D: --mode agent hard-errors (exit 2) with a redirect, runCampaign not invoked (ADR-001 §3)', async () => {
  // ARCH Wave D (ADR-001 §3): the 0.16.0 deprecation banner is replaced by the dated
  // breaking change — the direct Node-CLI --mode agent entry point now hard-errors
  // (exit 2) and redirects to --mode tmux (production) / --mode native (slash). The
  // src/node/** engine modules are retained; only this dispatch entry point is gone.
  const { main } = await import('../../src/node/run.mjs');
  const stderrChunks = [];
  const stdout = { write() {} };
  const stderr = { write: (s) => { stderrChunks.push(String(s)); } };
  let runCampaignInvocations = 0;
  const fakeRun = async () => {
    runCampaignInvocations += 1;
    return { status: 'continue' };
  };

  const exitCode = await main(
    ['run', 'demo', '--mode', 'agent', '--worker-model', 'sonnet'],
    { runCampaign: fakeRun, stderr, stdout, cwd: process.cwd() },
  );

  assert.equal(exitCode, 2, '--mode agent must exit 2 (ARCH Wave D / ADR-001)');
  assert.equal(runCampaignInvocations, 0, 'runCampaign must NOT be invoked for --mode agent');
  const stderrText = stderrChunks.join('');
  assert.match(stderrText, /ERROR: --mode agent .* no longer supported/i);
  assert.match(stderrText, /ADR-001/);
  assert.match(stderrText, /--mode tmux/);
  assert.match(stderrText, /\/rlp-desk run .* --mode native/);
  // The old SCHEDULED-REMOVAL / stabilization banner is gone — it is now enforced,
  // not announced.
  assert.doesNotMatch(stderrText, /SCHEDULED REMOVAL/);
});

test('US-008 P1.b: --mode tmux unaffected by P1.b banner changes', async (t) => {
  // Mirror AC8.2 tmux pattern — fresh tempdir to avoid legacy desk detection.
  const tempCwd = await createTempDir(t);
  const { main } = await import('../../src/node/run.mjs');
  const stderrChunks = [];
  const stdoutChunks = [];
  const stderr = { write: (s) => { stderrChunks.push(String(s)); } };
  const stdout = { write: (s) => { stdoutChunks.push(String(s)); } };
  let zshSpawned = false;

  const prevEnv = process.env.NODE_ENV;
  delete process.env.NODE_ENV;
  try {
    await main(
      ['run', 'demo', '--mode', 'tmux', '--worker-model', 'gpt-5.5:high'],
      {
        stderr,
        stdout,
        cwd: tempCwd,
        fileExists: () => true,
        zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
        spawnZsh: async () => { zshSpawned = true; return 0; },
      },
    );
  } finally {
    if (prevEnv !== undefined) process.env.NODE_ENV = prevEnv;
  }

  assert.equal(zshSpawned, true, '--mode tmux still routes to zsh runner');
  assert.doesNotMatch(stderrChunks.join(''), /--mode native is slash-command-only/);
  assert.doesNotMatch(stderrChunks.join(''), /--mode agent .* deprecated/i);
});


// v0.21.0: consensus defaults moved to the GPT-5.6 generation. Pinned here so
// the Node RUN_DEFAULTS cannot drift from the zsh env defaults (test_option_cleanup D5/D6).
// luna-first cost routing: bumped to terra:high / sol:xhigh (2026-08-03).
// Fable 5.1 / Codex 6 Astra wave: finalConsensusModel moved on to
// gpt-6-astra:xhigh (was sol:xhigh) — terminal judgment-heavy role takes the
// most capable model of the generation, same principle as
// finalVerifierModel's opus->claude-fable-5-1 move. Per-US consensusModel is
// UNCHANGED (terra:high) — per-US consensus stays lighter than final.
test('RUN_DEFAULTS: consensus models — per-US stays terra:high, final moves to astra:xhigh', async () => {
  const { RUN_DEFAULTS } = await import('../../src/node/run.mjs');
  assert.equal(RUN_DEFAULTS.consensusModel, 'gpt-5.6-terra:high');
  assert.equal(RUN_DEFAULTS.finalConsensusModel, 'gpt-6-astra:xhigh');
});

// Fable 5.1 / Codex 6 Astra wave: the final-verifier default moved to the
// newest claude generation (was 'opus'), per owner direction to reflect the
// newest models. Pinned so the Node RUN_DEFAULTS cannot drift from the zsh
// FINAL_VERIFIER_MODEL default (mirrored assertion: test_option_cleanup.sh D3).
// worker/verifierModel stay 'haiku'/'sonnet' — only the final-verifier role
// moved, so those are pinned here too as a guard against an over-broad edit.
test('RUN_DEFAULTS: finalVerifierModel is claude-fable-5-1 (worker/verifier unchanged)', async () => {
  const { RUN_DEFAULTS } = await import('../../src/node/run.mjs');
  assert.equal(RUN_DEFAULTS.finalVerifierModel, 'claude-fable-5-1');
  assert.equal(RUN_DEFAULTS.workerModel, 'haiku');
  assert.equal(RUN_DEFAULTS.verifierModel, 'sonnet');
});

// --- --worker-model / --verifier-model / --final-verifier-model validation ---
//
// buildZshEnv (run.mjs) forwards these three flags to the zsh leader as
// WORKER_MODEL/VERIFIER_MODEL/FINAL_VERIFIER_MODEL, where _auto_detect_engine
// in src/scripts/run_ralph_desk.zsh validates the model:level syntax. Before
// this, run.mjs's own parser did zero validation, so a bad value would only
// fail after the zsh leader was already spawned. These tests pin the mirrored
// Node-side validation (parseRunOptions / validateModelFlag).

test('parseRunOptions rejects a --worker-model value crafted to break the model:level split (semicolon injection shape)', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  assert.throws(
    () => parseRunOptions(['--worker-model', 'opus:high;touch x'], '/tmp'),
    /invalid effort 'high;touch x' in --worker-model='opus:high;touch x'/,
  );
});

test('parseRunOptions rejects a --verifier-model value with a stray space in the effort level', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  assert.throws(
    () => parseRunOptions(['--verifier-model', 'opus:high max'], '/tmp'),
    /invalid effort 'high max' in --verifier-model='opus:high max'/,
  );
});

test('parseRunOptions accepts a valid claude model:effort value', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  const options = parseRunOptions(['--final-verifier-model', 'opus:high'], '/tmp');
  assert.equal(options.finalVerifierModel, 'opus:high');
});

test('parseRunOptions accepts a bare model name with no effort/reasoning suffix', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  const options = parseRunOptions(['--worker-model', 'haiku'], '/tmp');
  assert.equal(options.workerModel, 'haiku');
});

test('parseRunOptions accepts a valid codex model:reasoning value', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  const options = parseRunOptions(['--worker-model', 'gpt-5.5:medium'], '/tmp');
  assert.equal(options.workerModel, 'gpt-5.5:medium');
});

// claude-fable-5-1: isClaudeFamily is a plain startsWith('claude-') check, so
// a versioned id with a SECOND hyphenated numeric segment must validate
// against CLAUDE_EFFORT_VALUES exactly like claude-fable-5 or claude-opus-4-8.
test('parseRunOptions accepts claude-fable-5-1:max as a valid claude model:effort value', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  const options = parseRunOptions(['--final-verifier-model', 'claude-fable-5-1:max'], '/tmp');
  assert.equal(options.finalVerifierModel, 'claude-fable-5-1:max');
});

// gpt-6-astra: brand-new codex model family (no claude- prefix) must validate
// against CODEX_REASONING_VALUES like any other gpt-* model.
test('parseRunOptions accepts gpt-6-astra:xhigh as a valid codex model:reasoning value', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  const options = parseRunOptions(['--worker-model', 'gpt-6-astra:xhigh'], '/tmp');
  assert.equal(options.workerModel, 'gpt-6-astra:xhigh');
});

// Model-aware exclusion: gpt-6-astra's API rejects 'minimal' with an HTTP 400
// that enumerates the supported set (low/medium/high/xhigh/max) — see
// src/model-upgrade-table.md "GPT-6 — Astra". Both the full slug and the
// `astra` alias must be rejected; every OTHER codex model must still accept
// 'minimal' (mutation control: proves this is model-specific, not a blanket
// narrowing of CODEX_REASONING_VALUES).
test('parseRunOptions rejects gpt-6-astra:minimal (model-specific, server-confirmed unsupported)', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  assert.throws(
    () => parseRunOptions(['--worker-model', 'gpt-6-astra:minimal'], '/tmp'),
    /gpt-6-astra does not support 'minimal'/,
  );
});

test('parseRunOptions rejects astra:minimal (alias form)', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  assert.throws(
    () => parseRunOptions(['--verifier-model', 'astra:minimal'], '/tmp'),
    /gpt-6-astra does not support 'minimal'/,
  );
});

test('parseRunOptions still accepts gpt-5.5:minimal (minimal remains valid for other codex models)', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  const options = parseRunOptions(['--final-verifier-model', 'gpt-5.5:minimal'], '/tmp');
  assert.equal(options.finalVerifierModel, 'gpt-5.5:minimal');
});

// Independent-review finding (MED): --consensus-model and --final-consensus-model
// never called validateModelFlag at all, unlike --worker-model/--verifier-model/
// --final-verifier-model — so an invalid value (including gpt-6-astra:minimal,
// which the final-consensus DEFAULT is astra-family) was accepted at parse
// time and would only 400 at the final consensus gate, deep into a campaign.
test('parseRunOptions rejects gpt-6-astra:minimal via --consensus-model', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  assert.throws(
    () => parseRunOptions(['--consensus-model', 'gpt-6-astra:minimal'], '/tmp'),
    /gpt-6-astra does not support 'minimal'/,
  );
});

test('parseRunOptions rejects astra:minimal via --final-consensus-model (the exact scenario the review flagged)', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  assert.throws(
    () => parseRunOptions(['--final-consensus-model', 'astra:minimal'], '/tmp'),
    /gpt-6-astra does not support 'minimal'/,
  );
});

test('parseRunOptions accepts a valid --consensus-model / --final-consensus-model value', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  const options = parseRunOptions(
    ['--consensus-model', 'gpt-5.6-terra:high', '--final-consensus-model', 'gpt-6-astra:xhigh'],
    '/tmp',
  );
  assert.equal(options.consensusModel, 'gpt-5.6-terra:high');
  assert.equal(options.finalConsensusModel, 'gpt-6-astra:xhigh');
});

test('parseRunOptions rejects an invalid codex reasoning level the same way as an invalid claude effort', async () => {
  const { parseRunOptions } = await import('../../src/node/run.mjs');
  assert.throws(
    () => parseRunOptions(['--worker-model', 'gpt-5.5:extreme'], '/tmp'),
    /invalid reasoning 'extreme' in --worker-model='gpt-5.5:extreme'/,
  );
});

test('main run command rejects a malicious --worker-model value with exit 1 and does not spawn the zsh leader', async () => {
  const { main } = await import('../../src/node/run.mjs');
  let spawned = false;
  let stderr = '';

  const exitCode = await main(
    ['run', 'demo', '--mode', 'tmux', '--worker-model', 'opus:high;touch x'],
    {
      cwd: repoRoot,
      stdout: { write() {} },
      stderr: { write: (chunk) => { stderr += chunk; } },
      fileExists: () => true,
      zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
      spawnZsh: async () => { spawned = true; return 0; },
    },
  );

  assert.equal(exitCode, 1);
  assert.equal(spawned, false, 'an invalid --worker-model must be rejected before the zsh leader is spawned');
  assert.match(stderr, /invalid effort/);
});

test('main run command forwards accepted --worker-model/--verifier-model/--final-verifier-model values to the zsh env unchanged', async () => {
  const { main } = await import('../../src/node/run.mjs');
  let capturedEnv = null;

  const exitCode = await main(
    [
      'run', 'demo', '--mode', 'tmux',
      '--worker-model', 'gpt-5.5:medium',
      '--verifier-model', 'opus:high',
      '--final-verifier-model', 'haiku',
    ],
    {
      cwd: repoRoot,
      stdout: { write() {} },
      stderr: { write() {} },
      fileExists: () => true,
      zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
      spawnZsh: async (_path, env) => { capturedEnv = env; return 0; },
    },
  );

  assert.equal(exitCode, 0);
  assert.ok(capturedEnv, 'spawnZsh must have been called with an env object');
  assert.equal(capturedEnv.WORKER_MODEL, 'gpt-5.5:medium');
  assert.equal(capturedEnv.VERIFIER_MODEL, 'opus:high');
  assert.equal(capturedEnv.FINAL_VERIFIER_MODEL, 'haiku');
});

// Parity: the Node vocabulary must not silently drift from the zsh source it
// mirrors. Extract the exact `case "$level_part" in ...)` pattern lines from
// src/scripts/run_ralph_desk.zsh and assert the Node lists equal them.
test('CLAUDE_EFFORT_VALUES / CODEX_REASONING_VALUES match the vocabulary encoded in run_ralph_desk.zsh _auto_detect_engine', async () => {
  const { CLAUDE_EFFORT_VALUES, CODEX_REASONING_VALUES } = await import('../../src/node/run.mjs');
  const zshSource = await fs.readFile(path.join(repoRoot, 'src/scripts/run_ralph_desk.zsh'), 'utf8');

  // "            low|medium|high|max|xhigh)" — the claude-effort case pattern,
  // immediately followed (next case arm) by the codex-reasoning one.
  const claudeMatch = zshSource.match(/^\s+(low\|medium\|high\|max\|xhigh)\)$/m);
  assert.ok(claudeMatch, 'could not find the claude effort case-pattern line in run_ralph_desk.zsh — has _auto_detect_engine moved/changed?');
  assert.deepEqual(claudeMatch[1].split('|'), CLAUDE_EFFORT_VALUES);

  const codexMatch = zshSource.match(/^\s+(minimal\|low\|medium\|high\|xhigh\|max\|ultra)\)$/m);
  assert.ok(codexMatch, 'could not find the codex reasoning case-pattern line in run_ralph_desk.zsh — has _auto_detect_engine moved/changed?');
  assert.deepEqual(codexMatch[1].split('|'), CODEX_REASONING_VALUES);
});

// Parity: the short codex model alias table (sol/terra/luna/astra -> full
// slug) is duplicated in THREE places — _auto_detect_engine's env-var path
// (run_ralph_desk.zsh), parse_model_flag's CLI-flag path (lib_ralph_desk.zsh),
// and CODEX_MODEL_ALIASES (command-builder.mjs, the Node CLI path). Extract
// each source's alias->slug mapping structurally and assert all three agree,
// so a future alias addition/edit in only one or two sites is caught here
// instead of silently drifting (the same failure mode the vocabulary parity
// test above guards against, one level down at the alias-table level).
test('codex model alias table (sol/terra/luna/astra) agrees across _auto_detect_engine, parse_model_flag, and CODEX_MODEL_ALIASES', async () => {
  const runZshSource = await fs.readFile(path.join(repoRoot, 'src/scripts/run_ralph_desk.zsh'), 'utf8');
  const libZshSource = await fs.readFile(path.join(repoRoot, 'src/scripts/lib_ralph_desk.zsh'), 'utf8');
  const commandBuilderSource = await fs.readFile(path.join(repoRoot, 'src/node/cli/command-builder.mjs'), 'utf8');

  // `spark` is deliberately excluded: all three sites handle it via a
  // separate dedicated branch (not this family-alias table), so it is not
  // part of what this test is pinning.
  const FAMILY_ALIAS_NAMES = /^(sol|terra|luna|astra)$/;

  // run_ralph_desk.zsh: `[[ "$model_part" == "sol" ]]   && model_part="gpt-5.6-sol"`
  const autoDetectAliases = {};
  for (const match of runZshSource.matchAll(/\[\[ "\$model_part" == "([a-z]+)" \]\]\s*&& model_part="([\w.-]+)"/g)) {
    if (FAMILY_ALIAS_NAMES.test(match[1])) autoDetectAliases[match[1]] = match[2];
  }

  // lib_ralph_desk.zsh (colon-bearing branch): `sol)\n        model="gpt-5.6-sol"`
  // — the shared `_validate_model_level` refactor (Fable 5.1 / Codex 6 Astra
  // parse_model_flag CLI-flag validation gap fix) reassigns `model` and
  // validates before echoing, instead of echoing the literal alias inline.
  const parseModelFlagAliases = {};
  for (const match of libZshSource.matchAll(/^ {6}([a-z]+)\)\n {8}model="([\w.-]+)"/gm)) {
    if (FAMILY_ALIAS_NAMES.test(match[1])) parseModelFlagAliases[match[1]] = match[2];
  }

  // command-builder.mjs: `['sol', 'gpt-5.6-sol'],` inside CODEX_MODEL_ALIASES.
  const mapSource = commandBuilderSource.match(/CODEX_MODEL_ALIASES = new Map\(\[([\s\S]*?)\]\)/);
  assert.ok(mapSource, 'could not find CODEX_MODEL_ALIASES in command-builder.mjs — has parseModelFlag moved/changed?');
  const nodeAliases = {};
  for (const match of mapSource[1].matchAll(/\['([a-z]+)', '([\w.-]+)'\]/g)) {
    if (FAMILY_ALIAS_NAMES.test(match[1])) nodeAliases[match[1]] = match[2];
  }

  const expectedAliasCount = 4; // sol, terra, luna, astra
  assert.equal(Object.keys(autoDetectAliases).length, expectedAliasCount, `run_ralph_desk.zsh: expected ${expectedAliasCount} aliases, found ${JSON.stringify(autoDetectAliases)}`);
  assert.deepEqual(parseModelFlagAliases, autoDetectAliases, 'lib_ralph_desk.zsh parse_model_flag alias table must match run_ralph_desk.zsh _auto_detect_engine');
  assert.deepEqual(nodeAliases, autoDetectAliases, 'command-builder.mjs CODEX_MODEL_ALIASES must match the zsh alias tables');

  // Pin the actual expected mapping so a coordinated-but-wrong edit across
  // all three sites is still caught.
  assert.deepEqual(autoDetectAliases, {
    sol: 'gpt-5.6-sol',
    terra: 'gpt-5.6-terra',
    luna: 'gpt-5.6-luna',
    astra: 'gpt-6-astra',
  });
});

// Parity: the claude bare-alias set (haiku/sonnet/opus/fable) is duplicated
// in FOUR places — _auto_detect_engine's case pattern (run_ralph_desk.zsh),
// parse_model_flag's case pattern (lib_ralph_desk.zsh), CLAUDE_MODELS
// (command-builder.mjs), and isClaudeFamily (run.mjs). `fable` was missing
// from all four until this wave (a real bug — see the "bare fable" tests
// above and in test_us003_unified_model_format.sh / us002-cli-command-
// builder.test.mjs). Extract each source's alias set structurally and assert
// all four agree, so a future alias addition/edit in only some sites is
// caught here instead of silently drifting.
test('claude bare-alias set (haiku/sonnet/opus/fable) agrees across _auto_detect_engine, parse_model_flag, CLAUDE_MODELS, and isClaudeFamily', async () => {
  const runZshSource = await fs.readFile(path.join(repoRoot, 'src/scripts/run_ralph_desk.zsh'), 'utf8');
  const libZshSource = await fs.readFile(path.join(repoRoot, 'src/scripts/lib_ralph_desk.zsh'), 'utf8');
  const commandBuilderSource = await fs.readFile(path.join(repoRoot, 'src/node/cli/command-builder.mjs'), 'utf8');
  const runSource = await fs.readFile(path.join(repoRoot, 'src/node/run.mjs'), 'utf8');

  // Both zsh sites share the identical case-pattern line shape:
  // `haiku|sonnet|opus|fable|claude|claude-*)` — extract the pipe-separated
  // bare names, dropping the generic `claude`/`claude-*` markers (those cover
  // versioned ids, not short aliases, and have no Node Set/function counterpart).
  const extractZshAliasSet = (source) => {
    const match = source.match(/^\s*(haiku\|sonnet\|opus\|fable\|claude\|claude-\*)\)$/m);
    if (!match) return null;
    return match[1].split('|').filter((name) => name !== 'claude' && name !== 'claude-*').sort();
  };
  const autoDetectAliases = extractZshAliasSet(runZshSource);
  const parseModelFlagAliases = extractZshAliasSet(libZshSource);
  assert.ok(autoDetectAliases, 'could not find the claude alias case-pattern line in run_ralph_desk.zsh — has _auto_detect_engine moved/changed?');
  assert.ok(parseModelFlagAliases, 'could not find the claude alias case-pattern line in lib_ralph_desk.zsh — has parse_model_flag moved/changed?');

  const claudeModelsMatch = commandBuilderSource.match(/CLAUDE_MODELS = new Set\(\[([^\]]*)\]\)/);
  assert.ok(claudeModelsMatch, 'could not find CLAUDE_MODELS in command-builder.mjs — has isClaudeModelName moved/changed?');
  const claudeModelsAliases = [...claudeModelsMatch[1].matchAll(/'([a-z]+)'/g)].map((m) => m[1]).sort();

  const isClaudeFamilyMatch = runSource.match(/function isClaudeFamily\(modelPart\) \{([\s\S]*?)\n\}/);
  assert.ok(isClaudeFamilyMatch, 'could not find isClaudeFamily in run.mjs — has it moved/changed?');
  const isClaudeFamilyAliases = [...isClaudeFamilyMatch[1].matchAll(/modelPart === '([a-z]+)'/g)]
    .map((m) => m[1])
    .filter((name) => name !== 'claude')
    .sort();

  assert.deepEqual(parseModelFlagAliases, autoDetectAliases, 'lib_ralph_desk.zsh parse_model_flag alias set must match run_ralph_desk.zsh _auto_detect_engine');
  assert.deepEqual(claudeModelsAliases, autoDetectAliases, 'command-builder.mjs CLAUDE_MODELS must match the zsh alias sets');
  assert.deepEqual(isClaudeFamilyAliases, autoDetectAliases, 'run.mjs isClaudeFamily must match the zsh alias sets');

  // Pin the actual expected set so a coordinated-but-wrong edit across all
  // four sites is still caught.
  assert.deepEqual(autoDetectAliases, ['fable', 'haiku', 'opus', 'sonnet']);
});
