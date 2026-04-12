import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function tmux(...args) {
  return execFileAsync('tmux', args, { cwd: repoRoot });
}

async function tmuxText(...args) {
  const { stdout } = await tmux(...args);
  return stdout.trim();
}

function getSessionName(testName) {
  const safeName = testName
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');

  return `rlp-us001-${process.pid}-${safeName}`;
}

async function createSession(t) {
  const sessionName = getSessionName(t.name);
  await tmux('new-session', '-d', '-s', sessionName, '-x', '120', '-y', '40', '-c', repoRoot, 'zsh');
  t.after(async () => {
    await tmux('kill-session', '-t', sessionName).catch(() => {});
  });

  const rootPaneId = await tmuxText('display-message', '-p', '-t', `${sessionName}:0.0`, '#{pane_id}');
  return { sessionName, rootPaneId };
}

async function waitForOutput(paneId, expectedText, timeoutMs = 2000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const output = await tmuxText('capture-pane', '-p', '-t', paneId);
    if (output.includes(expectedText)) {
      return output;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  throw new Error(`Timed out waiting for "${expectedText}" in pane ${paneId}`);
}

async function currentCommand(paneId) {
  return tmuxText('display-message', '-p', '-t', paneId, '#{pane_current_command}');
}

async function waitForCurrentCommand(paneId, expectedCommand, timeoutMs = 2000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if ((await currentCommand(paneId)) === expectedCommand) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }

  throw new Error(`Timed out waiting for pane ${paneId} command ${expectedCommand}`);
}

test('US-001 AC1.1 happy: createPane creates a horizontal split and returns a pane id listed by tmux', async (t) => {
  const { createPane } = await import('../../src/node/tmux/pane-manager.mjs');
  const { sessionName, rootPaneId } = await createSession(t);

  const paneId = await createPane({ targetPaneId: rootPaneId, layout: 'horizontal' });
  const paneIds = (await tmuxText('list-panes', '-t', sessionName, '-F', '#{pane_id}')).split('\n');

  assert.match(paneId, /^%/);
  assert.ok(paneIds.includes(paneId));
});

test('US-001 AC1.1 boundary: createPane supports vertical layout splits', async (t) => {
  const { createPane } = await import('../../src/node/tmux/pane-manager.mjs');
  const { sessionName, rootPaneId } = await createSession(t);

  const paneId = await createPane({ targetPaneId: rootPaneId, layout: 'vertical' });
  const paneLayouts = (await tmuxText('list-panes', '-t', sessionName, '-F', '#{pane_id} #{pane_height} #{pane_width}')).split('\n');
  const paneLine = paneLayouts.find((line) => line.startsWith(`${paneId} `));

  assert.ok(paneLine);
});

test('US-001 AC1.1 negative: createPane rejects an invalid layout', async (t) => {
  const { createPane, TmuxError } = await import('../../src/node/tmux/pane-manager.mjs');
  const { rootPaneId } = await createSession(t);

  await assert.rejects(
    () => createPane({ targetPaneId: rootPaneId, layout: 'diagonal' }),
    (error) => error instanceof TmuxError && /Unsupported tmux layout/.test(error.message),
  );
});

test('US-001 AC1.2 happy: sendKeys sends a command that appears in pane output within 2 seconds', async (t) => {
  const { sendKeys } = await import('../../src/node/tmux/pane-manager.mjs');
  const { rootPaneId } = await createSession(t);
  const marker = `us001-happy-${process.pid}`;

  await sendKeys(rootPaneId, `printf '${marker}\\n'`);
  const output = await waitForOutput(rootPaneId, marker, 2000);

  assert.match(output, new RegExp(marker));
});

test('US-001 AC1.2 boundary: sendKeys preserves shell quoting in the pane output', async (t) => {
  const { sendKeys } = await import('../../src/node/tmux/pane-manager.mjs');
  const { rootPaneId } = await createSession(t);
  const marker = `value with spaces ${process.pid}`;

  await sendKeys(rootPaneId, `printf '%s\\n' "${marker}"`);
  const output = await waitForOutput(rootPaneId, marker, 2000);

  assert.match(output, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('US-001 AC1.2 negative: sendKeys rejects an invalid pane id instead of silently failing', async () => {
  const { sendKeys, TmuxError } = await import('../../src/node/tmux/pane-manager.mjs');

  await assert.rejects(
    () => sendKeys('%999999', `printf 'never-runs\\n'`),
    (error) => error instanceof TmuxError && /%999999/.test(error.message),
  );
});

test('US-001 AC1.3 happy: waitForProcessExit resolves after a running process returns to the shell', async (t) => {
  const { sendKeys, waitForProcessExit } = await import('../../src/node/tmux/pane-manager.mjs');
  const { rootPaneId } = await createSession(t);

  await sendKeys(rootPaneId, 'sleep 1');
  await waitForCurrentCommand(rootPaneId, 'sleep', 2000);
  const start = Date.now();
  await waitForProcessExit(rootPaneId, { pollIntervalMs: 100, timeoutMs: 4000 });

  assert.ok(Date.now() - start >= 700);
});

test('US-001 AC1.3 boundary: waitForProcessExit resolves immediately when the pane is already at the shell prompt', async (t) => {
  const { waitForProcessExit } = await import('../../src/node/tmux/pane-manager.mjs');
  const { rootPaneId } = await createSession(t);
  const start = Date.now();

  await waitForProcessExit(rootPaneId, { pollIntervalMs: 100, timeoutMs: 1000 });

  assert.ok(Date.now() - start < 500);
});

test('US-001 AC1.3 negative: waitForProcessExit does not resolve while the pane process is still running', async (t) => {
  const { sendKeys, waitForProcessExit } = await import('../../src/node/tmux/pane-manager.mjs');
  const { rootPaneId } = await createSession(t);

  await sendKeys(rootPaneId, 'sleep 2');
  await waitForCurrentCommand(rootPaneId, 'sleep', 2000);

  const raceResult = await Promise.race([
    waitForProcessExit(rootPaneId, { pollIntervalMs: 100, timeoutMs: 4000 }).then(() => 'resolved'),
    new Promise((resolve) => setTimeout(() => resolve('pending'), 300)),
  ]);

  assert.equal(raceResult, 'pending');
  assert.equal(await currentCommand(rootPaneId), 'sleep');
  await waitForProcessExit(rootPaneId, { pollIntervalMs: 100, timeoutMs: 4000 });
});

test('US-001 AC1.4 happy: sendKeys throws TmuxError for an invalid pane id', async () => {
  const { sendKeys, TmuxError } = await import('../../src/node/tmux/pane-manager.mjs');

  await assert.rejects(
    () => sendKeys('%998001', 'echo unreachable'),
    (error) => error instanceof TmuxError,
  );
});

test('US-001 AC1.4 boundary: sendKeys includes the invalid pane id in the TmuxError message', async () => {
  const { sendKeys, TmuxError } = await import('../../src/node/tmux/pane-manager.mjs');

  await assert.rejects(
    () => sendKeys('%998002', 'echo unreachable'),
    (error) => error instanceof TmuxError && error.message.includes('%998002'),
  );
});

test('US-001 AC1.4 negative: sendKeys surfaces tmux pane lookup failures as rejected promises', async () => {
  const { sendKeys, TmuxError } = await import('../../src/node/tmux/pane-manager.mjs');

  await assert.rejects(
    () => sendKeys('%998003', 'echo unreachable'),
    (error) => error instanceof TmuxError && /can't find pane|can not find pane/i.test(error.message),
  );
});
