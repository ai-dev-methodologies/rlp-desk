import test from 'node:test';
import assert from 'node:assert/strict';

test('detectPermissionPrompt fires on classic Claude Code prompt header', async () => {
  const { detectPermissionPrompt } = await import('../../src/node/runner/prompt-detector.mjs');
  assert.equal(detectPermissionPrompt('Do you want to create my-file.json?'), true);
});

test('detectPermissionPrompt fires on the arrow + 1. Yes pattern', async () => {
  const { detectPermissionPrompt } = await import('../../src/node/runner/prompt-detector.mjs');
  assert.equal(detectPermissionPrompt('  \u276F 1. Yes\n     2. Yes, and allow\n'), true);
});

test('detectPermissionPrompt fires on settings self-modify wording', async () => {
  const { detectPermissionPrompt } = await import('../../src/node/runner/prompt-detector.mjs');
  assert.equal(
    detectPermissionPrompt('2. Yes, and allow Claude to edit its own settings for this session'),
    true,
  );
});

test('detectPermissionPrompt does not fire on benign worker output', async () => {
  const { detectPermissionPrompt } = await import('../../src/node/runner/prompt-detector.mjs');
  assert.equal(detectPermissionPrompt('Iteration 5: building scaffold...\n'), false);
  assert.equal(detectPermissionPrompt('All tests pass.'), false);
  assert.equal(detectPermissionPrompt(''), false);
  assert.equal(detectPermissionPrompt(null), false);
  assert.equal(detectPermissionPrompt(undefined), false);
});

test('buildPermissionPromptBlocked produces sentinel object with category=permission_prompt', async () => {
  const { buildPermissionPromptBlocked, PERMISSION_PROMPT_CATEGORY } =
    await import('../../src/node/runner/prompt-detector.mjs');
  const sentinel = buildPermissionPromptBlocked('demo', 3, 'Do you want to create x.json?');
  assert.equal(sentinel.failure_category, PERMISSION_PROMPT_CATEGORY);
  assert.equal(sentinel.reason_category, 'infra_failure');
  assert.equal(sentinel.recoverable, false);
  assert.equal(sentinel.iteration, 3);
  assert.equal(sentinel.slug, 'demo');
  assert.match(sentinel.evidence_snippet, /Do you want to create/);
});

test('buildPermissionPromptBlocked truncates long snippet to first 5 lines', async () => {
  const { buildPermissionPromptBlocked } = await import('../../src/node/runner/prompt-detector.mjs');
  const longSnippet = Array.from({ length: 12 }, (_, i) => `line ${i}`).join('\n');
  const sentinel = buildPermissionPromptBlocked('demo', 0, longSnippet);
  const lines = sentinel.evidence_snippet.split('\n');
  assert.equal(lines.length, 5);
  assert.equal(lines[0], 'line 0');
  assert.equal(lines[4], 'line 4');
});

test('buildPermissionPromptBlocked handles non-string snippet gracefully', async () => {
  const { buildPermissionPromptBlocked } = await import('../../src/node/runner/prompt-detector.mjs');
  const sentinel = buildPermissionPromptBlocked('demo', 0, undefined);
  assert.equal(sentinel.evidence_snippet, '');
});

// v0.13.0 US-004 integration: signal-poller wires detectPermissionPrompt and
// throws PromptBlockedError with category=permission_prompt within one poll.
test('pollForSignal throws PromptBlockedError with permission_prompt category on detect', async () => {
  const { pollForSignal, PromptBlockedError } = await import('../../src/node/polling/signal-poller.mjs');

  let calls = 0;
  const fakeReadFile = async () => {
    const err = new Error('signal not yet'); err.code = 'ENOENT'; throw err;
  };
  const fakeCapturePane = async () => {
    calls += 1;
    return 'Worker output...\nDo you want to create something?\n  ❯ 1. Yes\n     2. No\n';
  };
  const fakeGetPaneCommand = async () => 'claude';
  const fakeSendKeys = async () => {};

  let thrown;
  try {
    await pollForSignal('/tmp/non-existent-signal.json', {
      mode: 'claude',
      paneId: 'test-pane',
      pollIntervalMs: 5,
      timeoutMs: 1000,
      readFile: fakeReadFile,
      capturePane: fakeCapturePane,
      getPaneCommand: fakeGetPaneCommand,
      sendKeys: fakeSendKeys,
    });
  } catch (err) {
    thrown = err;
  }

  assert.ok(thrown instanceof PromptBlockedError, 'expected PromptBlockedError');
  assert.equal(thrown.category, 'permission_prompt');
  assert.ok(calls >= 1, 'capturePane was called');
  assert.match(thrown.message, /Permission prompt detected/);
});

test('pollForSignal does not throw permission_prompt for benign output', async () => {
  const { pollForSignal, TimeoutError } = await import('../../src/node/polling/signal-poller.mjs');

  const fakeReadFile = async () => {
    const err = new Error('not yet'); err.code = 'ENOENT'; throw err;
  };
  const fakeCapturePane = async () => 'Iteration 5 in progress...\nAll tests pass.\n';
  const fakeGetPaneCommand = async () => 'claude';
  const fakeSendKeys = async () => {};

  let thrown;
  try {
    await pollForSignal('/tmp/non-existent-signal.json', {
      mode: 'claude',
      paneId: 'test-pane',
      pollIntervalMs: 5,
      timeoutMs: 50,
      readFile: fakeReadFile,
      capturePane: fakeCapturePane,
      getPaneCommand: fakeGetPaneCommand,
      sendKeys: fakeSendKeys,
    });
  } catch (err) {
    thrown = err;
  }

  // Either timeout or no throw — must not be a permission_prompt block.
  assert.ok(!thrown || thrown instanceof TimeoutError, 'expected timeout or no throw, not PromptBlocked');
});
