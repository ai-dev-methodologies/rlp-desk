// US-004 (F3.6 zero-artifact campaign abandonment guardrail, failure-modes.md
// §3): behavioral coverage for the run.mjs production launch breadcrumb.
// AC4.1 — PROVISIONAL breadcrumb written synchronously BEFORE parseRunOptions
// (phase:"parsing"), so a bad-flag parse throw still leaves a post-mortem
// record on disk; enriched/overwritten after a successful parse
// (phase:"launched") before every pre-spawn return in runTmuxViaZsh.
//
// The zsh-leader half of AC4.2 (t0 write + HUP-trap outcome update) is
// covered separately by tests/test_launch_breadcrumb.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

async function createTempDir(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-desk-launch-breadcrumb-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

async function readJson(targetPath) {
  return JSON.parse(await fs.readFile(targetPath, 'utf8'));
}

async function exists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

function launchRecordPath(tempCwd, slug) {
  return path.join(tempCwd, '.rlp-desk', 'logs', slug, 'launch-record.json');
}

test('US-004 AC4.1 happy: a bad-flag parse throw still leaves the PROVISIONAL breadcrumb on disk', async (t) => {
  const tempCwd = await createTempDir(t);
  const cli = await import('../../src/node/run.mjs');
  let stderr = '';

  const exitCode = await cli.main(
    ['run', 'demo', '--totally-not-a-real-flag'],
    {
      cwd: tempCwd,
      stdout: { write() {} },
      stderr: { write(chunk) { stderr += chunk; } },
    },
  );

  assert.equal(exitCode, 1, 'unknown flag must still fail the command');
  assert.match(stderr, /unknown option: --totally-not-a-real-flag/);

  const recordPath = launchRecordPath(tempCwd, 'demo');
  assert.equal(await exists(recordPath), true, 'provisional launch-record.json must survive the parse throw');

  const record = await readJson(recordPath);
  assert.equal(record.phase, 'parsing');
  assert.equal(record.slug, 'demo');
  assert.deepEqual(record.argv, ['demo', '--totally-not-a-real-flag']);
  assert.equal(typeof record.ts, 'string');
  assert.equal(record.pid, undefined, 'provisional record predates options — no pid/leader yet');
});

test('US-004 AC4.1 boundary: missing zsh runner still leaves the ENRICHED breadcrumb (phase:launched) before the pre-spawn return', async (t) => {
  const tempCwd = await createTempDir(t);
  const cli = await import('../../src/node/run.mjs');

  const exitCode = await cli.main(
    ['run', 'demo', '--mode', 'tmux', '--worker-model', 'gpt-5.5:high'],
    {
      cwd: tempCwd,
      stdout: { write() {} },
      stderr: { write() {} },
      fileExists: () => false,
      zshRunnerPath: () => '/missing/run_ralph_desk.zsh',
      spawnZsh: async () => {
        throw new Error('spawn must not be reached when runner is missing');
      },
    },
  );

  assert.equal(exitCode, 1, 'missing-runner path returns non-zero before spawn');

  const recordPath = launchRecordPath(tempCwd, 'demo');
  assert.equal(await exists(recordPath), true, 'enriched launch-record.json must exist after the missing-runner pre-spawn return');

  const record = await readJson(recordPath);
  assert.equal(record.phase, 'launched');
  assert.equal(record.slug, 'demo');
  assert.equal(record.leader, 'tmux');
  assert.equal(typeof record.pid, 'number');
  assert.ok(record.options, 'resolved options snapshot must be present');
  assert.equal(record.options.workerModel, 'gpt-5.5:high');
  assert.equal(typeof record.ts, 'string');
});

test('US-004 AC4.1 boundary: legacy-desk pre-spawn return also leaves the ENRICHED breadcrumb', async (t) => {
  const tempCwd = await createTempDir(t);
  // Trip detectLegacyDeskInRunMode by scaffolding the legacy .claude/ralph-desk/ tree.
  const legacyDeskDir = path.join(tempCwd, '.claude', 'ralph-desk');
  await fs.mkdir(path.join(legacyDeskDir, 'memos'), { recursive: true });
  await fs.writeFile(path.join(legacyDeskDir, 'memos', 'demo-memory.md'), '# demo\n', 'utf8');

  const cli = await import('../../src/node/run.mjs');

  const exitCode = await cli.main(
    ['run', 'demo', '--mode', 'tmux'],
    {
      cwd: tempCwd,
      stdout: { write() {} },
      stderr: { write() {} },
      fileExists: () => true,
      zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
      spawnZsh: async () => {
        throw new Error('spawn must not be reached when a legacy desk is detected');
      },
    },
  );

  assert.equal(exitCode, 1, 'legacy-desk pre-spawn return exits non-zero before spawn');

  const recordPath = launchRecordPath(tempCwd, 'demo');
  assert.equal(await exists(recordPath), true, 'enriched launch-record.json must exist after the legacy-desk pre-spawn return');

  const record = await readJson(recordPath);
  assert.equal(record.phase, 'launched');
  assert.equal(record.leader, 'tmux');
});
