import fs from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';

const execFileAsync = promisify(execFile);
const SHELL_COMMANDS = new Set(['', 'zsh', 'bash', 'sh']);

export class TimeoutError extends Error {
  constructor(message, options = {}) {
    super(message, options.cause ? { cause: options.cause } : undefined);
    this.name = 'TimeoutError';
  }
}

async function defaultReadFile(filePath) {
  return fs.readFile(filePath, 'utf8');
}

async function defaultGetPaneCommand(paneId) {
  const { stdout } = await execFileAsync('tmux', [
    'display-message',
    '-p',
    '-t',
    paneId,
    '#{pane_current_command}',
  ]);

  return stdout.trim();
}

function isMissingFileError(error) {
  return error?.code === 'ENOENT';
}

function isJsonParseError(error) {
  return error instanceof SyntaxError;
}

function deadlineExceeded(deadline) {
  return Date.now() >= deadline;
}

async function waitForPaneExit(paneId, { deadline, pollIntervalMs, getPaneCommand }) {
  while (!deadlineExceeded(deadline)) {
    try {
      const currentCommand = await getPaneCommand(paneId);
      if (SHELL_COMMANDS.has(currentCommand)) {
        return;
      }
    } catch {
      // Transient tmux lookup failures should not end the poll loop early.
    }

    if (deadlineExceeded(deadline)) {
      break;
    }

    await delay(pollIntervalMs);
  }

  throw new TimeoutError(`Timed out waiting for pane ${paneId} to exit after signal detection`);
}

export async function pollForSignal(
  signalFile,
  {
    mode = 'claude',
    paneId = null,
    pollIntervalMs = 100,
    timeoutMs = 5000,
    readFile = defaultReadFile,
    getPaneCommand = defaultGetPaneCommand,
  } = {},
) {
  const deadline = Date.now() + timeoutMs;

  while (!deadlineExceeded(deadline)) {
    try {
      const rawContent = await readFile(signalFile);
      const parsed = JSON.parse(rawContent);

      if (mode === 'codex' && paneId) {
        await waitForPaneExit(paneId, {
          deadline,
          pollIntervalMs,
          getPaneCommand,
        });
      }

      return parsed;
    } catch (error) {
      if (!isMissingFileError(error) && !isJsonParseError(error)) {
        throw error;
      }
    }

    if (deadlineExceeded(deadline)) {
      break;
    }

    await delay(pollIntervalMs);
  }

  throw new TimeoutError(`Timed out waiting for valid JSON signal at ${signalFile}`);
}
