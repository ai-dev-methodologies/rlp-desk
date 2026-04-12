import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const SHELL_COMMANDS = new Set(['zsh', 'bash', 'sh']);
const LAYOUT_FLAGS = {
  horizontal: '-h',
  vertical: '-v',
};

export class TmuxError extends Error {
  constructor(message, options = {}) {
    super(message, options.cause ? { cause: options.cause } : undefined);
    this.name = 'TmuxError';
    this.paneId = options.paneId ?? null;
  }
}

async function runTmux(args, { paneId = null } = {}) {
  try {
    return await execFileAsync('tmux', args);
  } catch (error) {
    const stderr = error.stderr?.trim();
    const detail = stderr || error.message;
    const paneDetail = paneId ? ` for pane ${paneId}` : '';
    throw new TmuxError(`tmux command failed${paneDetail}: ${detail}`, {
      cause: error,
      paneId,
    });
  }
}

async function readTmuxValue(args, options) {
  const { stdout } = await runTmux(args, options);
  return stdout.trim();
}

export async function createPane({ targetPaneId, layout }) {
  const layoutFlag = LAYOUT_FLAGS[layout];
  if (!layoutFlag) {
    throw new TmuxError(`Unsupported tmux layout: ${layout}`);
  }

  return readTmuxValue(
    ['split-window', layoutFlag, '-d', '-P', '-F', '#{pane_id}', '-t', targetPaneId],
    { paneId: targetPaneId },
  );
}

export async function sendKeys(paneId, command) {
  await runTmux(['send-keys', '-t', paneId, '-l', '--', command], { paneId });
  await runTmux(['send-keys', '-t', paneId, 'Enter'], { paneId });
}

export async function waitForProcessExit(
  paneId,
  { pollIntervalMs = 100, timeoutMs = 5000 } = {},
) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() <= deadline) {
    const currentCommand = await readTmuxValue(
      ['display-message', '-p', '-t', paneId, '#{pane_current_command}'],
      { paneId },
    );

    if (SHELL_COMMANDS.has(currentCommand)) {
      return;
    }

    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }

  throw new TmuxError(`Timed out waiting for pane ${paneId} to return to the shell`, {
    paneId,
  });
}
