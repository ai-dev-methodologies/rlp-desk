import { test } from 'node:test';
import assert from 'node:assert/strict';
import { autoDismissPrompts, _resetForTesting } from '../../src/node/runner/prompt-dismisser.mjs';

// TRUST-F (Node parity with the zsh leader, commit d38afac + the follow-up that
// binds the decision to the BOTTOM-MOST prompt block): the dismisser must press
// Enter only when the selected option (`❯` cursor line) of that block is an accept
// option. A default-No dialog, stale "Do you want to ..." wording above an unrelated
// dialog, or an unidentifiable selection must never receive Enter.

const FOOTER = ' Enter to confirm · Esc to cancel';

const PERMISSION_YES = [
  '● Write(test.json)',
  '',
  ' Do you want to create test.json?',
  ' ❯ 1. Yes',
  '   2. Yes, allow all edits during this session (shift+tab)',
  '   3. No, and tell Claude what to do differently (esc)',
  '',
  ' Esc to cancel · Tab to amend',
].join('\n');

const PERMISSION_NO = [
  '● Write(test.json)',
  '',
  ' Do you want to create test.json?',
  '   1. Yes',
  '   2. Yes, allow all edits during this session (shift+tab)',
  ' ❯ 3. No, and tell Claude what to do differently (esc)',
  '',
  ' Esc to cancel · Tab to amend',
].join('\n');

function bypassDialog(cursor) {
  const no = cursor === 'no' ? ' ❯ 1. No, exit' : '   1. No, exit';
  const yes = cursor === 'yes' ? ' ❯ 2. Yes, I accept' : '   2. Yes, I accept';
  return [
    ' WARNING: Claude Code running in Bypass Permissions mode',
    '',
    ' In Bypass Permissions mode, Claude Code will not ask for your approval before',
    ' running potentially dangerous commands. This mode should only be used in a',
    ' sandboxed container/VM that has restricted internet access.',
    '',
    ' By proceeding, you accept all responsibility for actions taken.',
    '',
    no,
    yes,
    '',
    FOOTER,
  ].join('\n');
}

const STALE_WORDING = '● The previous permission prompt said: Do you want to create test.json?';

// claude 2.1.296 trust dialog: unnumbered options, cursor DEFAULTS to "No, exit".
function trustDialog(cursor) {
  const no = cursor === 'no' ? ' ❯ No, exit' : '   No, exit';
  const yes = cursor === 'yes' ? ' ❯ Yes, I trust this folder' : '   Yes, I trust this folder';
  return [
    ' Accessing workspace:',
    ' /path/to/proj',
    ' Quick safety check: Is this a project you created or one you trust? (Like your own code, a',
    " well-known open source project, or work from your team). If not, take a moment to review what's in this",
    ' folder first.',
    " Claude Code'll be able to read, edit, and execute files here.",
    ' Security guide',
    no,
    yes,
    FOOTER,
  ].join('\n');
}

function makeDeps(capture, options = {}) {
  const sent = [];
  const logs = [];
  const blocks = [];
  return {
    deps: {
      sendKeys: async (paneId, key) => sent.push({ paneId, key }),
      capturePane: async () => capture,
      log: (entry) => logs.push(entry),
      now: options.now ?? (() => 1000),
      sleep: async () => {},
      onDefaultNoBlock: (info) => blocks.push(info),
    },
    sent,
    logs,
    blocks,
  };
}

// Pane model for the trust dialog: Down moves the cursor No -> Yes, Enter on Yes
// accepts, Enter on No quits claude. `downWorks: false` models a Down that never
// moves the cursor.
function makeTrustPane(initialCursor, { downWorks = true } = {}) {
  const state = { cursor: initialCursor, keys: [], exited: false, accepted: false };
  return {
    state,
    deps: {
      capturePane: async () => (state.exited ? '$ ' : trustDialog(state.cursor)),
      sendKeys: async (_paneId, key) => {
        state.keys.push(key);
        if (key === 'Down' && downWorks && state.cursor === 'no') state.cursor = 'yes';
        if (key === 'Enter') {
          if (state.cursor === 'yes') state.accepted = true;
          else state.exited = true;
        }
      },
      log: () => {},
      now: () => 1000,
      sleep: async () => {},
    },
  };
}

test('selected option Yes on a real permission prompt → Enter', async () => {
  _resetForTesting();
  const { deps, sent, blocks } = makeDeps(PERMISSION_YES);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, true);
  assert.deepEqual(sent, [{ paneId: '%w', key: 'Enter' }]);
  assert.equal(blocks.length, 0);
});

test('selected option Yes with -J joined option text (a long option is one logical line) → Enter', async () => {
  _resetForTesting();
  const joined = [
    ' Do you want to make this edit to prd-sum-fn.md?',
    ' ❯ 1. Yes',
    '   2. Yes, allow all edits during this session (shift+tab)',
    '   3. No, and tell Claude what to do differently (esc)',
    '',
    ' Esc to cancel · Tab to amend',
  ].join('\n');
  const { deps, sent } = makeDeps(joined);
  assert.equal(await autoDismissPrompts('%w', deps), true);
  assert.deepEqual(sent.map((s) => s.key), ['Enter']);
});

test('P2: option text wrapped onto continuation lines (a capture WITHOUT -J) is not trusted → no Enter', async () => {
  _resetForTesting();
  const wrapped = [
    ' Do you want to make this edit to',
    ' prd-sum-fn.md?',
    ' ❯ 1. Yes',
    '   2. Yes, allow all edits during',
    '      this session (shift+tab)',
    '   3. No, and tell Claude what to do',
    '      differently (esc)',
    '',
    ' Esc to cancel · Tab to amend',
  ].join('\n');
  const { deps, sent } = makeDeps(wrapped);
  assert.equal(await autoDismissPrompts('%w', deps), false);
  assert.deepEqual(sent, []);
});

test('selected option No on a permission prompt → no Enter, refusal surfaced', async () => {
  _resetForTesting();
  const { deps, sent, logs, blocks } = makeDeps(PERMISSION_NO);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0, 'Enter on a selected No would reject the operation');
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].paneId, '%w');
  assert.equal(blocks[0].category, 'infra_failure');
  assert.match(blocks[0].reason, /default-No/i);
  assert.deepEqual(logs, [
    { category: 'FLOW', event: 'permission_prompt_default_no_blocked', pane_id: '%w' },
  ]);
});

test('stale "Do you want to" wording above a bypass-permissions default-No dialog → no Enter', async () => {
  _resetForTesting();
  const capture = [STALE_WORDING, '', bypassDialog('no')].join('\n');
  const { deps, sent, blocks } = makeDeps(capture);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0, 'stale wording must not authorize Enter on an unrelated default-No dialog');
  assert.equal(blocks.length, 1, 'the refusal must be visible to the caller');
});

test('stale wording far above an unrelated dialog whose cursor is on Yes → no Enter (not this block\'s prompt)', async () => {
  _resetForTesting();
  const capture = [STALE_WORDING, '', bypassDialog('yes')].join('\n');
  const { deps, sent, blocks } = makeDeps(capture);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 1);
});

test('stale permission prompt in scrollback with later output below it → no Enter', async () => {
  _resetForTesting();
  const capture = [
    PERMISSION_YES,
    '',
    '● Write(test.json) done',
    '  wrote 12 lines',
    '  more worker output',
  ].join('\n');
  const { deps, sent } = makeDeps(capture);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0, 'a block that is no longer at the bottom is not an active prompt');
});

test('numbered picker with no cursor marker (selection unidentifiable) → no Enter, refusal surfaced', async () => {
  _resetForTesting();
  const { deps, sent, blocks } = makeDeps(`Choose an option:
1) Yes
2) No
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 1);
  assert.match(blocks[0].reason, /cannot identify|unidentified|selected option/i);
});

test('cursor on a non Yes/No option of a Yes/No block → no Enter', async () => {
  _resetForTesting();
  const { deps, sent, blocks } = makeDeps(` Do you want to proceed?
   1. Yes
 ❯ 2. Type here to tell Claude what to do differently
   3. No
 Esc to cancel
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 1);
});

// --- claude 2.1.296 trust dialog (default cursor on "No, exit") ---------------

test('2.1.296 trust dialog, default cursor on No → Down then Enter on Yes, never Enter on No', async () => {
  _resetForTesting();
  const pane = makeTrustPane('no');
  const logs = [];
  const result = await autoDismissPrompts('%w', { ...pane.deps, log: (e) => logs.push(e) });
  assert.equal(result, true);
  assert.deepEqual(pane.state.keys, ['Down', 'Enter']);
  assert.equal(pane.state.accepted, true);
  assert.equal(pane.state.exited, false, 'claude must not have been quit via Enter on No');
  assert.ok(logs.some((l) => l.event === 'claude_trust_prompt_auto_approved'));
});

test('2.1.296 trust dialog, cursor already on Yes → Enter only', async () => {
  _resetForTesting();
  const pane = makeTrustPane('yes');
  const result = await autoDismissPrompts('%w', pane.deps);
  assert.equal(result, true);
  assert.deepEqual(pane.state.keys, ['Enter']);
  assert.equal(pane.state.accepted, true);
});

test('2.1.296 trust dialog, Down never reaches Yes → bounded retries, NO Enter, refusal surfaced', async () => {
  _resetForTesting();
  const pane = makeTrustPane('no', { downWorks: false });
  const blocks = [];
  const result = await autoDismissPrompts('%w', {
    ...pane.deps,
    onDefaultNoBlock: (info) => blocks.push(info),
  });
  assert.equal(result, false);
  assert.ok(!pane.state.keys.includes('Enter'), `Enter must never be sent (keys: ${pane.state.keys})`);
  assert.ok(pane.state.keys.length >= 1 && pane.state.keys.length <= 3, 'bounded Down attempts');
  assert.equal(pane.state.exited, false);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].category, 'infra_failure');
});

test('2.1.296 trust dialog, cursor unknown (mid-render) never becomes Enter', async () => {
  _resetForTesting();
  const keys = [];
  const blocks = [];
  const result = await autoDismissPrompts('%w', {
    capturePane: async () => trustDialog('none'),
    sendKeys: async (_p, key) => keys.push(key),
    log: () => {},
    now: () => 1000,
    sleep: async () => {},
    onDefaultNoBlock: (info) => blocks.push(info),
  });
  assert.equal(result, false);
  assert.ok(!keys.includes('Enter'));
  assert.equal(blocks.length, 1);
});

test('trust words in prose without the dialog options never authorize Enter', async () => {
  _resetForTesting();
  const { deps, sent } = makeDeps(`Quick safety check
Enter to confirm
`);
  const result = await autoDismissPrompts('%w', deps);
  assert.equal(result, false);
  assert.equal(sent.length, 0);
});

test('boxed permission prompt (│ borders, bottom edge) with Yes selected → Enter', async () => {
  _resetForTesting();
  const boxed = [
    '╭──────────────────────────────────────╮',
    '│ Do you want to create a.json?        │',
    '│ ❯ 1. Yes                             │',
    '│   2. No, and tell Claude what to do  │',
    '╰──────────────────────────────────────╯',
  ].join('\n');
  const { deps, sent } = makeDeps(boxed);
  assert.equal(await autoDismissPrompts('%w', deps), true);
  assert.deepEqual(sent.map((s) => s.key), ['Enter']);
});

test('worker prose ending in "No ..." after a question is not a prompt block → no Enter, no refusal', async () => {
  _resetForTesting();
  const { deps, sent, blocks } = makeDeps('Do you want to proceed?\nNo issues found.\n');
  assert.equal(await autoDismissPrompts('%w', deps), false);
  assert.equal(sent.length, 0);
  assert.equal(blocks.length, 0);
});
