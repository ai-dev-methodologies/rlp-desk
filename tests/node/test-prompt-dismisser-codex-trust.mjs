import { test } from 'node:test';
import assert from 'node:assert/strict';
import { autoDismissPrompts, _resetForTesting } from '../../src/node/runner/prompt-dismisser.mjs';

// R2-01: the Node codex 0.162 trust-dialog handling must match the REAL screen (same
// recognition as zsh _codex_dialog_kind). R2-08n: kill the Node mutants N05 (trust
// heading requirement removed), N06 (the "?" check after the heading removed), N11
// (TEXT_AFFORDANCE_RE replaced by AFFORDANCE_RE) and N15 (heading window). Enter is the
// only dangerous key: each negative case asserts that NO Enter was sent.

async function run(capture, { onBlock } = {}) {
  _resetForTesting();
  const sent = [];
  const blocks = [];
  const result = await autoDismissPrompts('%probe', {
    sendKeys: async (_p, key) => sent.push(key),
    capturePane: async () => capture,
    log: () => {},
    now: () => 1000,
    sleep: async () => {},
    onDefaultNoBlock: (info) => (onBlock ?? blocks.push.bind(blocks))(info),
  });
  return { result, keys: sent, blocks };
}

// A pane that renders `render(cursor)`; Up/Down move the cursor between `order` ids;
// Enter on `yes` accepts (the pane then shows a shell prompt), Enter elsewhere quits.
function makeMenuPane(render, order, initial, { moveWorks = true } = {}) {
  const state = { cursor: initial, keys: [], accepted: false, exited: false, blocks: [] };
  return {
    state,
    deps: {
      capturePane: async () => (state.accepted || state.exited ? '$ ' : render(state.cursor)),
      sendKeys: async (_p, key) => {
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
      onDefaultNoBlock: (info) => state.blocks.push(info),
    },
  };
}

// --- R2-01: the real codex 0.162 screens -------------------------------------------
// Form A mirrors the zsh `trust162` fixture; form B carries the full heading sentence
// found in the codex-cli 0.162.1 binary ("... run files here, subject to your permission
// settings."). Footer: "enter continue · esc quit".
const HEADING_A = '  Trust this folder? Codex can read, edit, and run files here.';
const HEADING_B =
  '  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.';

function codex162({ cursor, heading = HEADING_A, footer = '  enter continue · esc quit', title = '  Folder access', echo = true }) {
  return [
    ...(echo ? ['❯ codex-launch-cmd'] : []),
    title,
    heading,
    cursor === 'yes' ? '› 1. Trust and continue' : '  1. Trust and continue',
    cursor === 'no' ? '› 2. Quit' : '  2. Quit',
    footer,
  ].join('\n');
}

for (const [form, heading] of [
  ['zsh trust162 fixture heading', HEADING_A],
  ['codex 0.162.1 binary heading', HEADING_B],
]) {
  test(`R2-01: real codex 0.162 screen (${form}), cursor on Trust and continue → Enter only`, async () => {
    _resetForTesting();
    const pane = makeMenuPane((c) => codex162({ cursor: c, heading }), ['yes', 'no'], 'yes');
    assert.equal(await autoDismissPrompts('%w', pane.deps), true);
    assert.deepEqual(pane.state.keys, ['Enter']);
    assert.equal(pane.state.accepted, true);
  });

  test(`R2-01: real codex 0.162 screen (${form}), cursor on Quit → Up, then Enter on Trust (never Enter on Quit)`, async () => {
    _resetForTesting();
    const pane = makeMenuPane((c) => codex162({ cursor: c, heading }), ['yes', 'no'], 'no');
    assert.equal(await autoDismissPrompts('%w', pane.deps), true);
    assert.deepEqual(pane.state.keys, ['Up', 'Enter']);
    assert.equal(pane.state.exited, false, 'codex must not have been quit');
  });
}

test('R2-01: real codex 0.162 screen without the shell echo / title line is still the trust dialog → Enter', async () => {
  const { result, keys } = await run(codex162({ cursor: 'yes', echo: false, title: '' }));
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('R2-01: real codex 0.162 screen, cursor cannot be moved off Quit → bounded retries, NO Enter, refusal surfaced', async () => {
  _resetForTesting();
  const pane = makeMenuPane((c) => codex162({ cursor: c }), ['yes', 'no'], 'no', { moveWorks: false });
  assert.equal(await autoDismissPrompts('%w', pane.deps), false);
  assert.ok(!pane.state.keys.includes('Enter'), 'Enter on Quit would exit codex');
  assert.equal(pane.state.blocks.length, 1, 'never a silent hang: the refusal must be surfaced');
  assert.equal(pane.state.blocks[0].category, 'infra_failure');
});

test('R2-01: real codex 0.162 screen, cursor not readable (mid-render) → NO Enter, refusal surfaced', async () => {
  const { result, keys, blocks } = await run(codex162({ cursor: 'none' }));
  assert.equal(result, false);
  assert.ok(!keys.includes('Enter'));
  assert.equal(blocks.length, 1);
});

test('R2-01: real codex 0.162 screen WITHOUT its footer line (footer must be last) → NO Enter, refusal surfaced', async () => {
  const { result, keys, blocks } = await run(codex162({ cursor: 'yes', footer: '' }));
  assert.equal(result, false);
  assert.deepEqual(keys, []);
  assert.equal(blocks.length, 1, 'an active-looking dialog that is refused must say so');
});

test('R2-01: real codex 0.162 screen with output after the footer (stale dialog) → NO Enter', async () => {
  const { result, keys } = await run(codex162({ cursor: 'yes' }) + '\n● Working (12s)');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('R2-01: real codex 0.162 heading with a third option → not the trust dialog → NO Enter, refusal surfaced', async () => {
  const capture = [
    '  Folder access',
    HEADING_A,
    '› 1. Trust and continue',
    '  2. Trust this session only',
    '  3. Quit',
    '  enter continue · esc quit',
  ].join('\n');
  const { result, keys, blocks } = await run(capture);
  assert.equal(result, false);
  assert.deepEqual(keys, []);
  assert.equal(blocks.length, 1);
});

test('R2-01: codex options + "Press enter to continue" footer but no trust heading → not a trust dialog → no Enter', async () => {
  const capture = ['  Something else entirely', '› 1. Trust and continue', '  2. Quit', '  Press enter to continue'].join('\n');
  const { result, keys } = await run(capture);
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

// --- R2-08n: mutation survivors -----------------------------------------------------

// N05: the trust heading requirement removed. Two trust options + footer with NO trust
// heading above is not a trust dialog (it has no wording of its own either).
for (const [name, lines] of [
  [
    'codex options',
    ['  Pick one', '› 1. Trust and continue', '  2. Quit', '  enter continue · esc quit'],
  ],
  [
    'claude options',
    ['  Pick one', ' ❯ Yes, I trust this folder', '   No, exit', ' Enter to confirm · Esc to cancel'],
  ],
]) {
  test(`N05: ${name} + footer but NO trust heading → not a trust dialog → no Enter`, async () => {
    const { result, keys, blocks } = await run(lines.join('\n'));
    assert.equal(result, false);
    assert.deepEqual(keys, [], 'without the heading the cursor is never read or moved');
    assert.equal(blocks.length, 1, 'the refusal is surfaced');
  });
}

test('N05: no heading and the cursor on Quit → no Up, no Enter (the trust path must not run)', async () => {
  const { keys } = await run(['  Pick one', '  1. Trust and continue', '› 2. Quit', '  enter continue · esc quit'].join('\n'));
  assert.deepEqual(keys, []);
});

// N06: another question between the trust heading and the options voids the dialog.
for (const [name, headLine, opts, footer] of [
  [
    'codex',
    HEADING_A.trim(),
    (c) => [c === 'yes' ? '› 1. Trust and continue' : '  1. Trust and continue', c === 'no' ? '› 2. Quit' : '  2. Quit'],
    '  enter continue · esc quit',
  ],
  [
    'claude',
    'Quick safety check: Is this a project you created or one you trust?',
    (c) => [c === 'no' ? ' ❯ No, exit' : '   No, exit', c === 'yes' ? ' ❯ Yes, I trust this folder' : '   Yes, I trust this folder'],
    ' Enter to confirm · Esc to cancel',
  ],
]) {
  const render = (c) => [headLine, 'Delete all my files?', ...opts(c), footer].join('\n');
  for (const cursor of ['yes', 'no']) {
    test(`N06: ${name} trust heading followed by an unrelated question ("Delete all my files?"), cursor on ${cursor} → no Enter`, async () => {
      const { result, keys } = await run(render(cursor));
      assert.equal(result, false);
      assert.deepEqual(keys, [], 'the heading no longer belongs to these options');
    });
  }
}

// N11: only TEXT affordances authorize the inline fallback. A footer such as
// "Enter to confirm" (a picker affordance) with wording but no picker block must not.
test('N11: wording + "Enter to confirm" footer but no option block and no text affordance → no Enter, refusal surfaced', async () => {
  const { result, keys, blocks } = await run('Do you want to proceed?\nEnter to confirm');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
  assert.equal(blocks.length, 1);
});

test('N11: wording + a lone "1) Yes" option (not a block) → no Enter', async () => {
  const { result, keys } = await run('Do you want to proceed?\n1) Yes');
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('N11 control: wording + a real text affordance "(y/n)" → Enter', async () => {
  const { result, keys } = await run('Do you want to proceed? (y/n)');
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

// N15: the trust heading is searched in the 40 lines directly above the options (zsh
// _claude_trust_dialog_state: _hn < 40). Pin both edges.
function paneWithHeadingDistance(gap) {
  // `gap` filler lines between the trust heading and the first option.
  return [
    HEADING_A.trim(),
    ...Array.from({ length: gap }, (_, i) => `filler line ${i + 1}`),
    '› 1. Trust and continue',
    '  2. Quit',
    '  enter continue · esc quit',
  ].join('\n');
}

test('N15: trust heading exactly 40 lines above the first option (39 filler lines) → still the trust dialog → Enter', async () => {
  const { result, keys } = await run(paneWithHeadingDistance(39));
  assert.equal(result, true);
  assert.deepEqual(keys, ['Enter']);
});

test('N15: trust heading 41 lines above the first option (40 filler lines) is out of the window → no Enter', async () => {
  const { result, keys } = await run(paneWithHeadingDistance(40));
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

test('N15: trust heading 60 lines above the first option → no Enter', async () => {
  const { result, keys } = await run(paneWithHeadingDistance(59));
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

// The question-wording window for ordinary prompts is the unbroken run of at most 4 lines
// directly above the block; a wider run must not attach.
test('N15b: ordinary question 5 lines above the options (unbroken run) is not attached wording → no Enter', async () => {
  const { result, keys } = await run(
    ['Do you want to', 'create this', 'file inside', 'the current', 'workspace folder?', '❯ 1. Yes', '  2. No', 'Esc to cancel'].join('\n'),
  );
  assert.equal(result, false);
  assert.deepEqual(keys, []);
});

// R3-03: the real heading + both options, but a footer the recognizer does not know, used
// to send no key AND surface nothing (silent stall). It must be refused through
// onDefaultNoBlock, with no key sent, for either cursor position.
for (const footer of ['  enter to continue · esc to quit', '  ↵ continue  esc quit']) {
  for (const cursor of ['yes', 'no']) {
    test(`R3-03: real codex trust screen, unrecognized footer ${JSON.stringify(footer.trim())}, cursor on ${cursor} → no key, refusal surfaced`, async () => {
      const { result, keys, blocks } = await run(codex162({ cursor, footer }));
      assert.equal(result, false);
      assert.deepEqual(keys, [], 'an unrecognized footer must not authorize or move anything');
      assert.equal(blocks.length, 1, 'never a silent stall: the refusal must be surfaced');
      assert.equal(blocks[0].category, 'infra_failure');
      assert.match(blocks[0].reason, /footer/i);
    });
  }
}

test('R3-03 control: an unrecognized footer under a NON-trust heading is not claimed as a trust dialog', async () => {
  const capture = ['  Some other question', '› 1. Trust and continue', '  2. Quit', '  enter to continue · esc to quit'].join('\n');
  const { keys, blocks } = await run(capture);
  assert.deepEqual(keys, []);
  assert.equal(blocks.filter((b) => /trust dialog/i.test(b.reason)).length, 0);
});
