import { test } from 'node:test';
import assert from 'node:assert/strict';
import { autoDismissPrompts, _resetForTesting } from '../../src/node/runner/prompt-dismisser.mjs';

// G12 — v5.7 §4.13.b unit test: line-adjacency prompt auto-dismiss.
// Positive: prompt + affordance on same/prev/next line → Enter.
// Negative (R-V5-9 false-positive guard): prompt without nearby affordance → no Enter.

function makeDeps(captureFixture, options = {}) {
  const sent = [];
  const logs = [];
  return {
    deps: {
      sendKeys: async (paneId, key) => sent.push({ paneId, key }),
      capturePane: async () => captureFixture,
      log: (entry) => logs.push(entry),
      now: options.now ?? (() => 1000),
    },
    sent,
    logs,
  };
}

test('positive: prompt + affordance on same line', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`some output
Do you want to create test.json? (y/n)
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.deepEqual(sent, [{ paneId: '%w', key: 'Enter' }]);
});

test('positive: prompt with affordance on next line', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you want to create test.json?
(y/n)
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('positive: prompt with affordance on previous line', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`(y/n)
Do you want to create test.json?
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('positive: Do you trust + numeric picker', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you trust this directory?
1) Yes
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('negative: non-prompt text containing "Do you want to"', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`User: Do you want to learn more about Rust?
Tutor: Sure, here's the basics...
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
});

test('negative: prompt without affordance marker', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you want to create test.json?
Just plain output text.
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
});

// v5.7 §4.23: line-adjacency strict design replaced with tail-15 normalized
// matching to handle real claude tmux narrow-pane wraps. "Within tail-15" is
// the new closeness contract — both PROMPT and AFFORDANCE present near the
// active prompt area triggers auto-Enter.
test('positive: prompt + affordance both in tail-15 → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you want to create test.json?
some unrelated output
another unrelated line
(y/n)
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('negative: empty capture', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps('');
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
});

test('debounce: second call within 3s suppressed', async () => {
  _resetForTesting();
  let t = 1000;
  const { deps, sent } = makeDeps(
    `Do you want to create test.json? (y/n)
`,
    { now: () => t },
  );
  await autoDismissPrompts('%dbnce', deps);
  assert.equal(sent.length, 1);
  // Second call 1 second later — debounced.
  t = 2000;
  const second = await autoDismissPrompts('%dbnce', deps);
  assert.equal(second, false);
  assert.equal(sent.length, 1);
});

test('debounce: re-enabled after 3s elapsed', async () => {
  _resetForTesting();
  let t = 1000;
  const { deps, sent } = makeDeps(
    `Do you want to create test.json? (y/n)
`,
    { now: () => t },
  );
  await autoDismissPrompts('%dbnce', deps);
  t = 5000; // 4s later
  const second = await autoDismissPrompts('%dbnce', deps);
  assert.equal(second, true);
  assert.equal(sent.length, 2);
});

test('capturePane error swallowed, returns false', async () => {
  _resetForTesting();
  const sent = [];
  const result = await autoDismissPrompts('%w', {
    sendKeys: async (...args) => sent.push(args),
    capturePane: async () => {
      throw new Error('tmux failure');
    },
  });
  assert.equal(result, false);
  assert.equal(sent.length, 0);
});

test('logs structured FLOW entry on dismiss', async () => {
  _resetForTesting();
  const { deps, logs } = makeDeps(`Do you want to create test.json? (y/n)
`);
  await autoDismissPrompts('%w', deps);
  assert.deepEqual(logs, [
    { category: 'FLOW', event: 'permission_prompt_auto_approved', pane_id: '%w' },
  ]);
});

// v5.7 §4.17 (Node parity): default-No prompts must BLOCK, not auto-Enter.
test('default-No: [y/N] returns false, no Enter, BLOCK callback invoked', async () => {
  _resetForTesting();
  const { deps, sent, logs } = makeDeps(
    `Do you want to overwrite test.json? [y/N]
`,
  );
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0, 'no Enter must be sent for default-No');
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].paneId, '%w');
  assert.equal(blocks[0].category, 'infra_failure');
  assert.match(blocks[0].reason, /default-No/i);
  assert.deepEqual(logs, [
    { category: 'FLOW', event: 'permission_prompt_default_no_blocked', pane_id: '%w' },
  ]);
});

test('default-No: explicit "(yes/no, default no)" phrasing also blocks', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Confirm execution? (yes/no, default no)
`);
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 1);
});

test('default-Yes: [Y/n] still auto-dismissed (does not falsely block)', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you want to create x? [Y/n]
`);
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
  assert.equal(blocks.length, 0, 'default-Yes must not trigger BLOCK');
});

test('default-No: callback errors do not propagate', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you want to overwrite x? [y/N]
`);
  deps.onDefaultNoBlock = () => {
    throw new Error('callback boom');
  };
  // Must not throw.
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
});

test('default-No: missing onDefaultNoBlock callback still blocks (no Enter)', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you want to overwrite x? [y/N]
`);
  // No onDefaultNoBlock provided.
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
});

// Codex CLI prompt-pattern parity (tmux mode + codex engine).
// Codex surfaces different phrasings than claude TUI — Node leader must catch
// them or codex Workers/Verifiers will hang exactly the same way claude did.
test('codex: "Proceed?" with (y/n) → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Send this command to the model?
Proceed? (y/n)
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('codex: "Approve this command?" with [Y/n] → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Approve this command? [Y/n]
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('codex: "Approve this command?" with [y/N] → BLOCK (default-No)', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Approve this command? [y/N]
`);
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 1);
});

test('codex: numeric picker "1) Yes / 2) No" → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Choose an option:
1) Yes
2) No
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('codex: "Press y to continue" affordance → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Continue?
press y to confirm
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('codex: "Allow this action?" with [Y/n] → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Allow this action? [Y/n]
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

// v5.7 §4.20 — claude v2.x trust prompt (E2E real-claude-CLI finding).
// New format does NOT use "Do you trust" — uses "Quick safety check: ... trust?"
// with `❯1.Yes` (no-space) numbered picker and "Enter to confirm" footer.
// Old patterns missed it entirely; Worker hung 5min until iter-timeout.
test('claude v2.x trust prompt: narrow-pane wrap with ❯1.Yes → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Quick safety check: Is this a project you
created or one you trust?
❯1.Yes, I trust this folder
2. No, exit
Enter to confirm
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('claude v2.x trust prompt: with-space ❯ 1. variant → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Is this a project you trust?
❯ 1. Yes, I trust this folder
2. No, exit
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('claude v2.x trust prompt: PROMPT_RE matches "Quick safety check"', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Quick safety check
Enter to confirm
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('claude v2.x trust prompt: "trust this folder" phrase + Enter to confirm', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Will trust this folder
Enter to confirm
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

// v5.7 §4.18 — unknown-prompt fast-fail (omc benchmarking parity).
test('unknown prompt: bare [y/N] affordance with no PROMPT_RE phrasing → BLOCK', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Some weird CLI banner
[y/N]
`);
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0, 'no Enter on unknown phrasing');
  assert.equal(blocks.length, 1);
  assert.match(blocks[0].reason, /default-No/i);
});

test('unknown prompt: bare (y/n) affordance with no PROMPT_RE → BLOCK', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Brand new CLI variant message
(y/n)
`);
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 1);
  assert.match(blocks[0].reason, /unknown|recognized|guess/i);
});

test('active task suppresses unknown-prompt BLOCK (worker producing output)', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Worker output mentioning (y/n) inside body text
· Synthesizing...
esc to interrupt
`);
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 0, 'must NOT BLOCK while worker is active');
});

test('affordance far from cursor (older scrollback, no active task) → BLOCK', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`unknown prompt header
[y/N]
trailing line 1
trailing line 2
trailing line 3
`);
  // tailLines (last 5 non-empty) = ['unknown prompt header','[y/N]','trailing line 1','trailing line 2','trailing line 3']
  // [y/N] within last 5 → BLOCK
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 1);
});

// v5.7 §4.17.b + §4.23: default-No anywhere in capture (full scan, not just
// tail) triggers BLOCK to guard against scrollback contamination — old [y/N]
// in scrollback could tank an active operation if we auto-Entered on the
// "current" prompt. Safety first: BLOCK on any default-No present.
test('default-No anywhere in capture → BLOCK (scrollback safety)', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`old prompt
[y/N]
filler1
filler2
filler3
filler4
filler5
filler6
`);
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 1, 'default-No in scrollback must BLOCK to be safe');
});

// v5.7 §4.17.b — scrollback contamination: scan-all instead of break-on-first.
test('scrollback: old [Y/n] + current [y/N] → MUST BLOCK (no false auto-Enter)', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you want to create file? [Y/n]
done
Do you want to overwrite passwd? [y/N]
`);
  const blocks = [];
  deps.onDefaultNoBlock = (info) => blocks.push(info);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0, 'no Enter must be sent when any visible prompt is default-No');
  assert.equal(blocks.length, 1);
});

test('scrollback: two default-Yes prompts → auto-dismiss safely', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Do you want to create A? [Y/n]
done
Do you want to create B? (y/n)
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});

test('codex: "Select [" picker prompt → auto-dismiss', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Select [an option below]:
1) Yes
2) No
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.equal(sent.length, 1);
});
