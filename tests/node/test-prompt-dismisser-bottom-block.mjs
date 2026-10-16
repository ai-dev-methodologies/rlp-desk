import { test } from 'node:test';
import assert from 'node:assert/strict';
import { autoDismissPrompts, _resetForTesting } from '../../src/node/runner/prompt-dismisser.mjs';

// Review round 1 (ledger-r1) adversarial probes for the bottom-block rule: every
// probe from the codex/reviewer findings is a test case here, plus one test per
// surviving mutation (M3, M5, M10). Enter is the only dangerous key: each negative
// case asserts that NO Enter was sent.

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

async function run(capture) {
  _resetForTesting();
  const ctx = makeDeps(capture);
  const result = await autoDismissPrompts('%probe', ctx.deps);
  return { result, ...ctx, keys: ctx.sent.map((s) => s.key) };
}

// A pane that renders `render(cursor)` and moves the cursor on Up/Down between the
// two option indexes. `cursorOrder` lists the option ids top to bottom; Enter on the
// `yes` id accepts, Enter on anything else quits.
function makeMenuPane(render, order, initial, { moveWorks = true } = {}) {
  const state = { cursor: initial, keys: [], accepted: false, exited: false };
  return {
    state,
    deps: {
      capturePane: async () => (state.accepted || state.exited ? '$ ' : render(state.cursor)),
      sendKeys: async (_paneId, key) => {
        state.keys.push(key);
        const idx = order.indexOf(state.cursor);
        if (moveWorks && key === 'Down' && idx < order.length - 1) state.cursor = order[idx + 1];
        if (moveWorks && key === 'Up' && idx > 0) state.cursor = order[idx - 1];
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

// --- C-RA (P1): a cursor-marked option block forbids the text-affordance fallback ---

test('C-RA probe 1: text prompt above an UNKNOWN selectable block (❯ 1. Destroy workspace) → no Enter, refusal surfaced', async () => {
  const { result, keys, blocks } = await run(
    'Do you want to proceed? (y/n)\n❯ 1. Destroy workspace\n  2. Open settings\nEsc to cancel',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
  assert.equal(blocks.length, 1, 'an unidentifiable selection must be refused loudly, not ignored');
  assert.equal(blocks[0].category, 'infra_failure');
});

test('C-RA probe 2: selected "No, exit" followed by a status line → no Enter', async () => {
  const { result, keys, blocks } = await run(
    'Do you want to proceed? (y/n)\n  1. Yes\n❯ 2. No, exit\nEsc to cancel\nModel: worker',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, [], 'Enter would select the decline option');
  assert.equal(blocks.length, 1);
});

test('C-RA probe 3: unnumbered selected decline option plus a text affordance → no Enter', async () => {
  const { result, keys } = await run('Do you want to proceed? [Y/n]\n❯ No, exit\n  Yes, continue\nsome status');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('C-RA probe 4: blank line splits the cursor option from the rest of the block → no Enter', async () => {
  const { result, keys } = await run('Do you want to create file? (y/n)\n❯ 1. Yes\n\n  2. No\nEsc to cancel');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('C-RA control: a plain text prompt with no cursor-marked option anywhere still auto-approves', async () => {
  const { result, keys } = await run('Do you want to create test.json? (y/n)\n');
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('C-RA control: a worker input line starting with a cursor glyph is not an option block', async () => {
  const { result, keys } = await run('Do you want to create test.json? (y/n)\n❯ hello there\n');
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

// --- C-RB (P1) + R1-04: active dialog boundary, wording bound to the dialog ---

test('C-RB probe 1: stale ❯ 1. Yes block followed by indented output → no Enter', async () => {
  const { result, keys } = await run(
    'Do you want to create old.txt?\n❯ 1. Yes\n  2. No\n    Wrote old.txt successfully\n    Working on next task',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('C-RB probe 2: stale selected-Yes block followed by "Completed file creation" output → no Enter', async () => {
  const { result, keys } = await run(
    'Do you want to create old.txt?\n❯ 1. Yes\n  2. No\n    Completed file creation.\n    Now waiting for another command.',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R1-04 probe 1: "Previous result: Do you want to create old.txt?" above an unknown menu → no Enter', async () => {
  const { result, keys } = await run(
    'Previous result: Do you want to create old.txt?\nSecurity override requested\n❯ Yes, I accept\n  No, exit\nEnter to confirm',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R1-04 probe 2: stale question separated from an unrelated dialog by unrelated output → no Enter', async () => {
  const { result, keys, blocks } = await run(
    'Do you want to create old.txt?\nDone.\nNew unrecognized security dialog\n❯ 1. Yes, I accept\n  2. No, exit\nEnter to confirm',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
  assert.equal(blocks.length, 1, 'a dialog without wording of its own is refused loudly');
});

test('R2-G (P3): ONE blank line between the question and a selected-Yes menu is normal dialog spacing → Enter', async () => {
  const { result, keys } = await run(
    'Do you want to create test.json?\n\n❯ 1. Yes\n  2. No, and tell Claude what to do differently (esc)\nEsc to cancel',
  );
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R2-G (P3): TWO blank lines between the question and the menu detach the wording → no Enter', async () => {
  const { result, keys } = await run(
    'Do you want to create old.txt?\n\n\n❯ 1. Yes\n  2. No, and tell Claude what to do differently (esc)\nEsc to cancel',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R2-G (P3): one blank line does not bridge a stale question across unrelated output → no Enter', async () => {
  const { result, keys } = await run(
    'Do you want to create old.txt?\nDone.\n\n❯ 1. Yes, I accept\n  2. No, exit\nEnter to confirm',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R2-G (P3): the real claude permission prompt shape (question, blank, ❯ 1. Yes / 2. allow all edits / 3. No) → Enter', async () => {
  const { result, keys } = await run(
    [
      '● Write(test.json)',
      '',
      ' Do you want to create test.json?',
      ' ❯ 1. Yes',
      '   2. Yes, allow all edits during this session (shift+tab)',
      '   3. No, and tell Claude what to do differently (esc)',
      '',
      ' Esc to cancel · Tab to amend',
    ].join('\n'),
  );
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R1-04 control: a 3-line wrapped question directly attached to the block → Enter', async () => {
  const { result, keys } = await run(
    ' Do you want to\n make this edit to\n prd-sum-fn.md?\n ❯ 1. Yes\n   2. No, and tell Claude what to do\n Esc to cancel',
  );
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R1-04 control (P2, -J joined): a long option is ONE logical line → Enter', async () => {
  const { result, keys } = await run(
    ' Do you want to create a.json?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently (esc)\n Esc to cancel',
  );
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R2-E (P2): a NON-joined capture (option wrapped onto an aligned continuation line) is not trusted → no Enter', async () => {
  const { result, keys } = await run(
    ' Do you want to create a.json?\n ❯ 1. Yes\n   2. No, and tell Claude what to do\n      differently (esc)\n Esc to cancel',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, [], 'no continuation-line joining heuristics: the trailing line is output after the options');
});

// --- R1-05 mutation killers ---

test('R1-05 M3: two cursor-marked options (first one Yes) → refuse, never Enter', async () => {
  const { result, keys, blocks } = await run(
    ' Do you want to create a.json?\n ❯ 1. Yes\n ❯ 2. No\n Esc to cancel',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
  assert.equal(blocks.length, 1);
});

test('R1-05 M5: more than 3 aligned indented lines below the last option are not a wrapped option → no Enter', async () => {
  const { result, keys } = await run(
    [
      ' Do you want to create a.json?',
      ' ❯ 1. Yes',
      '   2. No',
      '      line one',
      '      line two',
      '      line three',
      '      line four',
    ].join('\n'),
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

function claudeTrust({ cursor, extra = [], wrapped = false }) {
  const yesText = wrapped ? ['Yes, I trust this', '  folder'] : ['Yes, I trust this folder'];
  const mk = (id, text) => (cursor === id ? ` ❯ ${text}` : `   ${text}`);
  return [
    ' Accessing workspace:',
    ' /path/to/proj',
    ' Quick safety check: Is this a project you created or one you trust?',
    ' Security guide',
    mk('no', 'No, exit'),
    mk('yes', yesText[0]),
    ...yesText.slice(1).map((l) => `   ${l}`),
    ...extra,
    ' Enter to confirm · Esc to cancel',
  ].join('\n');
}

test('R1-05 M10: a trust dialog with a THIRD option is not a trust dialog → no Enter', async () => {
  const capture = [
    ' Quick safety check: Is this a project you created or one you trust?',
    '   No, exit',
    ' ❯ Yes, I trust this folder',
    '   Remind me later',
    ' Enter to confirm · Esc to cancel',
  ].join('\n');
  const { result, keys } = await run(capture);
  assert.equal(result, false);
  assert.deepEqual(keys, [], 'the exact two-option contract must hold');
});

test('R1-05 M10: two trust-Yes options and no trust-No option is not a trust dialog → no Enter', async () => {
  const capture = [
    ' Quick safety check: Is this a project you created or one you trust?',
    ' ❯ Yes, I trust this folder',
    '   Yes, proceed',
    ' Enter to confirm · Esc to cancel',
  ].join('\n');
  const { result, keys } = await run(capture);
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

// --- C-RC (P2): wrapped trust option text is joined before matching ---

test('C-RC (-J joined): the Yes option is one logical line, cursor on No → Down then Enter on Yes', async () => {
  _resetForTesting();
  const pane = makeMenuPane((c) => claudeTrust({ cursor: c }), ['no', 'yes'], 'no');
  assert.equal(await autoDismissPrompts('%w', pane.deps), true);
  assert.deepEqual(pane.state.keys, ['Down', 'Enter']);
  assert.equal(pane.state.accepted, true);
});

test('C-RC (P2): a NON-joined capture (Yes option wrapped onto a continuation line) is not an active trust dialog → no keys at all', async () => {
  _resetForTesting();
  const pane = makeMenuPane((c) => claudeTrust({ cursor: c, wrapped: true }), ['no', 'yes'], 'no');
  assert.equal(await autoDismissPrompts('%w', pane.deps), false);
  assert.deepEqual(pane.state.keys, [], 'continuation lines are not joined: nothing is pressed');
  assert.equal(pane.state.exited, false);
});

test('C-RC probe (codex capture, -J joined Yes option) → accepted via Down + Enter', async () => {
  _resetForTesting();
  const render = (c) =>
    [
      'Quick safety check:',
      'Is this a project you created or one you trust?',
      c === 'no' ? '❯ No, exit' : '  No, exit',
      c === 'yes' ? '❯ Yes, I trust this folder' : '  Yes, I trust this folder',
      'Enter to confirm · Esc to cancel',
    ].join('\n');
  const pane = makeMenuPane(render, ['no', 'yes'], 'no');
  assert.equal(await autoDismissPrompts('%w', pane.deps), true);
  assert.deepEqual(pane.state.keys, ['Down', 'Enter']);
});

// --- R1-02 (P2): the trust footer must be the last non-blank line ---

test('R1-02: claude trust dialog WITHOUT its footer is not an active dialog → no Enter, refusal surfaced', async () => {
  const { result, keys, blocks } = await run(
    'Is this a project you trust?\n❯ 1. Yes, I trust this folder\n2. No, exit\n',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
  assert.equal(blocks.length, 1);
});

test('R1-02: output after the trust footer means the dialog is no longer at the bottom → no Enter', async () => {
  const { result, keys } = await run(claudeTrust({ cursor: 'yes' }) + '\n● Welcome back');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R1-02 control: footer as the last non-blank line (trailing blank lines allowed) → Enter', async () => {
  const { result, keys } = await run(claudeTrust({ cursor: 'yes' }) + '\n\n\n');
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

// --- R1-01 (P1): codex trust dialogs are accepted again (parity with _codex_dialog_kind) ---

// R2-01: the REAL codex 0.162 trust screen (mirrors the zsh `trust162` fixture in
// tests/test_codex_ready_requires_codex_process.sh and the strings found in codex-cli
// 0.162.1: "Folder access", "Trust this folder?", "Trust and continue", "Quit"; the footer
// is "enter continue · esc quit"). The earlier fixture here ("Do you trust the contents of
// this directory?" / "Press enter to continue") does not exist in 0.162.1.
function codexTrust162(cursor) {
  return [
    '❯ codex-launch-cmd',
    '  Folder access',
    '  Trust this folder? Codex can read, edit, and run files here.',
    cursor === 'yes' ? '› 1. Trust and continue' : '  1. Trust and continue',
    cursor === 'no' ? '› 2. Quit' : '  2. Quit',
    '  enter continue · esc quit',
  ].join('\n');
}

// codex 0.141 variant (F-16; strings from the zsh _codex_dialog_kind / `trust` fixture:
// "Yes, continue" / "No, quit"). Not verifiable against the installed 0.162.1 binary.
function codexTrust141(cursor) {
  return [
    '> You are running Codex in /path/to/proj',
    '',
    '  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection.',
    '',
    cursor === 'yes' ? '› 1. Yes, continue' : '  1. Yes, continue',
    cursor === 'no' ? '› 2. No, quit' : '  2. No, quit',
    '',
    '  Press enter to continue',
  ].join('\n');
}

for (const [version, render] of [
  ['0.162 (Trust and continue / Quit)', codexTrust162],
  ['0.141 (Yes, continue / No, quit)', codexTrust141],
]) {
  test(`R1-01: codex ${version}, cursor on the trust option → Enter only`, async () => {
    _resetForTesting();
    const pane = makeMenuPane(render, ['yes', 'no'], 'yes');
    assert.equal(await autoDismissPrompts('%w', pane.deps), true);
    assert.deepEqual(pane.state.keys, ['Enter']);
    assert.equal(pane.state.accepted, true);
  });

  test(`R1-01: codex ${version}, cursor on Quit → Up to the trust option, then Enter (never Enter on Quit)`, async () => {
    _resetForTesting();
    const pane = makeMenuPane(render, ['yes', 'no'], 'no');
    assert.equal(await autoDismissPrompts('%w', pane.deps), true);
    assert.deepEqual(pane.state.keys, ['Up', 'Enter']);
    assert.equal(pane.state.accepted, true);
    assert.equal(pane.state.exited, false, 'codex must not have been quit');
  });

  test(`R1-01: codex ${version}, cursor cannot be moved → bounded retries, NO Enter, refusal surfaced`, async () => {
    _resetForTesting();
    const pane = makeMenuPane(render, ['yes', 'no'], 'no', { moveWorks: false });
    const blocks = [];
    const result = await autoDismissPrompts('%w', { ...pane.deps, onDefaultNoBlock: (i) => blocks.push(i) });
    assert.equal(result, false);
    assert.ok(!pane.state.keys.includes('Enter'));
    assert.equal(blocks.length, 1);
  });
}

test('R1-01: a codex dialog that is NOT the trust dialog (Trust and continue + a third option) → no Enter', async () => {
  const capture = [
    '  Folder access',
    '  Trust this folder? Codex can read, edit, and run files here.',
    '› 1. Trust and continue',
    '  2. Trust this session only',
    '  3. Quit',
    '  enter continue · esc quit',
  ].join('\n');
  const { result, keys } = await run(capture);
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R1-05 M10: numbered third option next to the two trust options is not a trust dialog → no Enter', async () => {
  const capture = [
    ' Quick safety check: Is this a project you created or one you trust?',
    ' ❯ 1. Yes, I trust this folder',
    '   2. No, exit',
    '   3. Remind me later',
    ' Enter to confirm · Esc to cancel',
  ].join('\n');
  const { result, keys } = await run(capture);
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R1-04: attached heading that is not a question or a lead-in ("... approved earlier") → no Enter', async () => {
  const { result, keys } = await run(
    ' Do you want to create a.json - approved earlier\n ❯ 1. Yes, I accept\n   2. No, exit\n Esc to cancel',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R1-04: only the LAST question directly above the block counts ("... old.txt?" then an unrelated "...?") → no Enter', async () => {
  const { result, keys } = await run(
    ' Do you want to create old.txt?\n Security override requested?\n ❯ 1. Yes, I accept\n   2. No, exit\n Esc to cancel',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

// --- Round 2 (ledger-r2): fail-closed rule P1-P4, codex probes ---

test('R2-D probe (codex): unnumbered unknown picker under "(y/n)" wording → no Enter, refusal surfaced', async () => {
  const { result, keys, blocks } = await run(
    'Do you want to proceed? (y/n)\n❯ Destroy workspace\n  Open settings\nEsc to cancel',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, [], 'Enter would confirm "Destroy workspace"');
  assert.equal(blocks.length, 1, 'a picker that cannot be identified must be refused loudly');
  assert.equal(blocks[0].category, 'infra_failure');
});

test('R2-D (P2): the unnumbered unknown picker is refused with no footer and with the cursor on either row', async () => {
  for (const cap of [
    'Do you want to proceed? (y/n)\n❯ Destroy workspace\n  Open settings',
    'Do you want to proceed? (y/n)\n  Open settings\n❯ Destroy workspace\nEsc to cancel',
    'Do you want to proceed? [Y/n]\n› Destroy workspace\n  Open settings\n  Quit\nEsc to cancel',
  ]) {
    const { result, keys } = await run(cap);
    assert.equal(result, false, cap);
    assert.deepEqual(keys, [], cap);
  }
});

test('R2-D (P2): a selected unnumbered Yes option with an unknown sibling is a picker, never the text fallback → no Enter', async () => {
  const { result, keys } = await run('Do you want to proceed? (y/n)\n❯ Yes\n  Open settings\nEsc to cancel');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R2-D (P2): a single cursor line with NO option siblings is an input box, not a picker → inline (y/n) still answers', async () => {
  const { result, keys } = await run('Do you want to create test.json? (y/n)\n❯ hello there\n');
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R2-D (P2): an input box whose neighbour is NOT aligned to its text is not a picker → inline (y/n) answers', async () => {
  const { result, keys } = await run('Do you want to create test.json? (y/n)\n❯ hello there\nstatus: idle\n');
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R2-E probe (codex): aligned trailing output after the options block → not an active dialog → no Enter', async () => {
  const { result, keys } = await run(
    [
      'Do you want to create old.txt?',
      '❯ 1. Yes',
      '  2. No',
      '     Completed file creation.',
      '     Now waiting for another command.',
    ].join('\n'),
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R2-E (P1): trailing output at ANY indent after the options is refused (flush, option-column, deeper)', async () => {
  for (const tail of ['Completed file creation.', '  Completed file creation.', '   Completed file creation.', '     Completed file creation.']) {
    const { result, keys } = await run(['Do you want to create old.txt?', '❯ 1. Yes', '  2. No', tail].join('\n'));
    assert.equal(result, false, JSON.stringify(tail));
    assert.deepEqual(keys, [], JSON.stringify(tail));
  }
});

test('R2-E (P1): trailing output after an UNNUMBERED Yes/No menu is refused too', async () => {
  const { result, keys } = await run(
    'Do you want to proceed?\n❯ Yes\n  No\n  Completed file creation.\n',
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R2-E (P1): recognized footer lines after the options keep the dialog active → Enter', async () => {
  const { result, keys } = await run(
    'Do you want to create old.txt?\n❯ 1. Yes\n  2. No\n\n Esc to cancel · Tab to amend\n\n',
  );
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R2 (P4): an unnumbered selected-Yes menu with its own question and nothing after it → Enter', async () => {
  const { result, keys } = await run('Do you want to proceed?\n❯ Yes\n  No\n');
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R2 (P2): a single numbered option is not a block; with wording and a cursor it is still refused, not inline-authorized', async () => {
  const { result, keys } = await run('Do you want to proceed? (y/n)\n❯ 1. Yes\n');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R2-D (P2): two adjacent cursor-marked unknown lines are a (multi-cursor) picker → no Enter', async () => {
  const { result, keys } = await run('Do you want to proceed? (y/n)\n❯ Destroy workspace\n❯ Open settings\nEsc to cancel');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R2-G (P3): a blank line between a wrapped (multi-line) question and the menu is still ONE blank → Enter', async () => {
  const { result, keys } = await run(
    ' Do you want to\n make this edit to\n prd-sum-fn.md?\n\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently (esc)\n Esc to cancel',
  );
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R2 (P2): a block needs at least two option lines — one selected Yes under a question is not a picker block → no Enter', async () => {
  for (const cap of ['Do you want to proceed?\n❯ Yes\n', 'Do you want to create a.json?\n❯ 1. Yes\n Esc to cancel']) {
    const { result, keys } = await run(cap);
    assert.equal(result, false, cap);
    assert.deepEqual(keys, [], cap);
  }
});
