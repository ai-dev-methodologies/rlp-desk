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
test('RUN_DEFAULTS: consensus models are the 5.6 generation (terra/sol)', async () => {
  const { RUN_DEFAULTS } = await import('../../src/node/run.mjs');
  assert.equal(RUN_DEFAULTS.consensusModel, 'gpt-5.6-terra:medium');
  assert.equal(RUN_DEFAULTS.finalConsensusModel, 'gpt-5.6-sol:high');
});
