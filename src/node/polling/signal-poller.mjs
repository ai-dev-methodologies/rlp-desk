import fs from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';

import { autoDismissPrompts } from '../runner/prompt-dismisser.mjs';

const execFileAsync = promisify(execFile);
const SHELL_COMMANDS = new Set(['', 'zsh', 'bash', 'sh']);

export class TimeoutError extends Error {
  constructor(message, options = {}) {
    super(message, options.cause ? { cause: options.cause } : undefined);
    this.name = 'TimeoutError';
  }
}

// v5.7 §4.17 (Node parity): default-No prompt detected while polling. Caller
// must write a BLOCKED `infra_failure` sentinel and abort — never auto-Enter,
// never wait silently for the human.
export class PromptBlockedError extends Error {
  constructor(message, info = {}) {
    super(message);
    this.name = 'PromptBlockedError';
    this.paneId = info.paneId;
    this.category = info.category ?? 'infra_failure';
    this.reason = info.reason ?? message;
  }
}

// v5.7 §4.22 (E2E real-claude-CLI finding): Worker process exited (back to
// shell prompt) but no signal/done-claim file was written. fresh-context +
// file-based architecture is broken — Leader has no way to know what Worker
// did. zsh runner has `handle_worker_exit_claude` for this; Node leader did
// not. Throw a specific error so the campaign loop can write BLOCKED with a
// descriptive reason instead of silent iter-timeout.
export class WorkerExitedError extends Error {
  constructor(message, info = {}) {
    super(message);
    this.name = 'WorkerExitedError';
    this.paneId = info.paneId;
    this.category = info.category ?? 'infra_failure';
    this.reason = info.reason ?? message;
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

async function defaultCapturePane(paneId) {
  // v5.7 §4.21 (E2E real-claude-CLI finding): claude v2.x trust prompt is
  // ~30+ lines tall when the pane wraps narrowly. -S -10 missed the question
  // header ("Quick safety check / Is this a project you trust?") so PROMPT_RE
  // never matched and the unknown-prompt fast-fail BLOCKed instead of
  // auto-dismissing. -50 covers the full prompt with margin for typical
  // pane heights.
  const { stdout } = await execFileAsync('tmux', [
    'capture-pane',
    '-t',
    paneId,
    '-p',
    '-S',
    '-50',
  ]);
  return stdout;
}

async function defaultSendKeys(paneId, key) {
  await execFileAsync('tmux', ['send-keys', '-t', paneId, key]);
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
    capturePane = defaultCapturePane,
    sendKeys = defaultSendKeys,
    log = () => {},
  } = {},
) {
  const deadline = Date.now() + timeoutMs;
  let pendingBlock = null;
  // v5.7 §4.22: track whether the worker process was ever observed running.
  // Used to detect "worker started, did some work, then exited without
  // writing signal/done-claim" — fresh-context architecture violation.
  let seenWorkerRunning = false;

  while (!deadlineExceeded(deadline)) {
    // v5.7 §4.13.b: auto-dismiss mid-execution permission prompts before
    // checking the signal file. Without this, Worker hangs on TUI prompts
    // even with --dangerously-skip-permissions (Bug 4).
    // v5.7 §4.17 (Node parity): default-No prompts must NOT be auto-Entered;
    // they raise a PromptBlockedError so the caller writes BLOCKED and aborts.
    if (paneId) {
      // v0.13.0: detect Claude Code self-modification permission prompts in
      // pane stdout BEFORE attempting auto-dismiss. These cannot be dismissed
      // by --dangerously-skip-permissions and would otherwise hang the worker
      // for the full pollForSignal timeout.
      try {
        const paneContent = await capturePane(paneId);
        const { detectPermissionPrompt } = await import('../runner/prompt-detector.mjs');
        if (detectPermissionPrompt(paneContent)) {
          throw new PromptBlockedError(
            `Permission prompt detected on pane ${paneId} (Claude Code self-modification gate)`,
            { paneId, category: 'permission_prompt', snippet: paneContent.split(/\r?\n/).slice(-10).join('\n') },
          );
        }
      } catch (err) {
        if (err instanceof PromptBlockedError) {
          throw err;
        }
        // capture failure is non-fatal; fall through to auto-dismiss path.
      }

      await autoDismissPrompts(paneId, {
        capturePane,
        sendKeys,
        log,
        onDefaultNoBlock: (info) => {
          pendingBlock = info;
        },
      }).catch(() => {});
      if (pendingBlock) {
        throw new PromptBlockedError(
          `Default-No prompt on pane ${pendingBlock.paneId}: ${pendingBlock.reason}`,
          pendingBlock,
        );
      }
    }

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
    } catch (signalError) {
      if (!isMissingFileError(signalError) && !isJsonParseError(signalError)) {
        throw signalError;
      }
      // Signal file missing OR partial JSON. v5.7 §4.22: parity with zsh
      // `handle_worker_exit_claude` — if Worker pane process is back to
      // shell, the worker exited without writing artifacts. Stop polling
      // immediately and surface a WorkerExitedError so the campaign loop
      // can write BLOCKED with reason `worker_exited_without_artifacts`.
      //
      // IMPORTANT: only run the pane-exit check on ENOENT (signal file
      // entirely missing). A SyntaxError means the file EXISTS but the
      // Worker is mid-write (atomic-rename race) — checking pane state
      // here would race against the imminent successful read. Skip the
      // check; next iteration's read will succeed.
      if (paneId && isMissingFileError(signalError)) {
        try {
          const currentCommand = await getPaneCommand(paneId);
          if (SHELL_COMMANDS.has(currentCommand)) {
            if (seenWorkerRunning) {
              throw new WorkerExitedError(
                `Worker pane ${paneId} exited (now '${currentCommand || 'shell'}') without writing signal at ${signalFile} — fresh-context contract violated`,
                {
                  paneId,
                  category: 'infra_failure',
                  reason: 'worker_exited_without_artifacts',
                },
              );
            }
          } else if (currentCommand) {
            seenWorkerRunning = true;
          }
        } catch (commandError) {
          if (commandError instanceof WorkerExitedError) throw commandError;
          // Other tmux lookup errors: don't end the loop early.
        }
      }
    }

    if (deadlineExceeded(deadline)) {
      break;
    }

    await delay(pollIntervalMs);
  }

  throw new TimeoutError(`Timed out waiting for valid JSON signal at ${signalFile}`);
}
