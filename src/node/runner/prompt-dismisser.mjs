// v5.7 §4.13.b — Mid-execution permission-prompt auto-dismiss (Bug 4 fix).
//
// claude CLI surfaces TUI-layer prompts ("Do you want to create...", "Do you trust...")
// even with --dangerously-skip-permissions on certain Write paths. Without this
// helper, Workers/Verifiers in tmux mode hang until idle-nudge timeout.
//
// Window-bounded match (codex Critic v5.7): require both a prompt phrase AND a
// TUI affordance marker on the SAME, PREVIOUS, or NEXT line. Whole-capture dual
// matching would let unrelated text trigger Enter (R-V5-9 false-positive).
// Per-pane 3-second debounce prevents rapid double-Enter.

// PROMPT_RE / AFFORDANCE_RE mirror src/scripts/run_ralph_desk.zsh `_PROMPT_RE`
// and `_AFFORDANCE_RE` so the Node leader catches the same TUI prompts the zsh
// runner does — including codex CLI variants (`Proceed?`, `Approve this`,
// `Press y to`, `Choose an option`, `Select [`) AND claude v2.x's new trust
// prompt format (Quick safety check / trust this folder / `❯1.Yes`).
// If you change one regex, change the other and the corresponding tests.
const PROMPT_RE =
  /Do you (want to|trust)|Confirm execution|Are you sure|Continue\?|Proceed\?|Allow this|Approve this|Press y to|Choose an option|Select \[|Quick safety check|trust this (folder|directory)|Is this a project you/;
// AFFORDANCE_RE: `(yes/no` (open form) covers prose default-No prompts;
// `❯\s*\d+\.` covers numbered pickers with optional space after cursor (claude
// v2.x narrow-pane wrap renders `❯1.` without space); `Enter to confirm`
// matches the new trust-prompt footer; `1) Yes` / `Y)` / `press y to` cover
// codex CLI selection menus.
const AFFORDANCE_RE =
  /\(y\/n\)|\[Y\/n\]|\[y\/N\]|\(yes\/no|❯\s*\d+\.|(?:^|\s)1\) (Yes|No)|(?:^|\s)[YyNn]\)|press (y|enter) to|Enter to confirm/;
// Text-prompt affordances only: pickers (`❯ N.`, `1) Yes`, `Enter to confirm`) are
// decided by findBottomPromptBlock's selected option, not by wording + marker presence.
const TEXT_AFFORDANCE_RE = /\(y\/n\)|\[Y\/n\]|\[y\/N\]|\(yes\/no|(?:^|\s)[YyNn]\)|press (y|enter) to/;
// v5.7 §4.17 (Node parity): default-No prompts must NOT auto-Enter — that
// CANCELS the operation. Mirror zsh `_DEFAULT_NO_RE`. Bracket form is
// case-sensitive (`[y/N]` only — `[Y/n]` is default-Yes); prose form is
// case-insensitive via explicit char classes so we don't fall back to the `i`
// regex flag (which would also match `[Y/n]`).
const DEFAULT_NO_RE = /\[y\/N\]|\(yes\/no,\s*default\s+no\)|[Dd]efault[: ]+[Nn]o|^\s*N\)/;
// v5.7 §4.18: "active task" markers (omc-team parity, tmux-session.ts:659).
// Used to suppress unknown-prompt fast-fail when the Worker is busy producing
// output that may legitimately contain "(y/n)"-shaped substrings.
const ACTIVE_TASK_RE =
  /esc to interrupt|background terminal running|^\s*[·✻]\s+[A-Za-z]+(\.{3}|…)/m;

// v0.14.1 / v0.14.2: codex post-work idle UI markers. NOT a permission prompt
// — the codex CLI has finished its task and is waiting for the next user
// input. Sources: BOS Bug Report #3 (2026-05-04) + #4 (2026-05-05).
// Treat this as "task done, idle awaiting input"; callers should harvest
// the verdict file rather than escalate as `prompt_blocked`.
//
// v0.14.2 relaxation (Bug #4): the v0.14.1 strict "─ Worked for Xm Ys ─"
// regex required the surrounding horizontal rule to match. tmux capture
// truncation occasionally dropped those rules so the pattern missed in
// production. Match on multiple independent markers; ANY one is enough.
//   1. "Worked for Xm Ys"           — duration line, codex-only
//   2. "Context X%left" (no space)  — status bar; tolerate wrap removal
//   3. "gpt-X.Y reasoning · branch" — codex idle status line
//   4. codex default suggestions    — only printed at the idle prompt
export const CODEX_IDLE_RE =
  /Worked for \d+m \d+s|Context \d+%\s*left|(^|\n)[ \t]*gpt-\d+(\.\d+)?(-[a-z0-9-]+)? (low|medium|high|xhigh|max|ultra) ·|Improve documentation in @|Summarize recent commits|Explain (this )?code/;
export function isCodexIdleUi(paneText) {
  if (typeof paneText !== 'string' || paneText.length === 0) return false;
  return CODEX_IDLE_RE.test(paneText);
}

// TRUST-F (Node parity with the zsh leader). Enter confirms whatever the cursor is on, so
// what this module guarantees is deliberately narrow. The pane capture is soft-wrap
// JOINED (tmux `capture-pane -J`, see signal-poller defaultCapturePane): one logical line
// per row, so nothing here joins continuation lines.
//  1. (P1/P2) A selectable block (>= 2 option lines, option = `❯`/`›` cursor and/or "N." /
//     "N)" number, or a bare Yes/No) is decided only from the BOTTOM-MOST block: the
//     options must be the last non-blank content, followed at most by blank / box-border
//     / recognized footer lines. ANY other line after the options means the block is stale
//     (not an active dialog). Enter needs the cursor on exactly ONE accept option AND
//     the question wording (PROMPT_RE, ending in "?" or ":") directly above the block with
//     at most ONE blank line between them (P3). A selected decline / unknown option,
//     several cursors, or a block without wording of its own is refused (and surfaced
//     through onDefaultNoBlock).
//     A single cursor-marked line with no option siblings (`❯ hello`) is an input box, not
//     a picker.
//  2. The claude / codex directory-trust dialogs are recognized only as exactly one trust
//     option and one No/Quit option, a trust heading, and the footer as the LAST non-blank
//     line; the cursor is read and moved onto the trust option before Enter.
//  3. (P4) A text affordance ("(y/n)", "[Y/n]", "press y to ...") plus PROMPT_RE wording inside
//     the last 15 lines authorizes Enter only when NO picker (a cursor-marked option, or a
//     cursor line with aligned option siblings) is in the bottom region and no default-No
//     marker is anywhere on the screen. A picker that fails P1-P3 is REFUSED, never
//     answered through this inline-text path. This text-window
//     rule does NOT prove the wording belongs to the affordance: a stale "... (y/n)"
//     question within those 15 lines can still match.
const FOOTER_RE = /Enter to confirm|Press enter to continue|enter continue.{0,5}esc quit|Esc to cancel|Tab to amend/i;
// The trust dialogs' own footer, which must be the last non-blank line: claude (zsh
// `_claude_trust_dialog_state`) "Enter to confirm" / "Press enter to continue"; codex 0.162
// "enter continue · esc quit" (the footer shown with "Trust this folder?" in the zsh
// `trust162` fixture).
const TRUST_FOOTER_RE = /Enter to confirm|Press enter to continue|enter continue.{0,5}esc quit/;
// R3-03: any last line that merely LOOKS like a key-hint footer (enter / esc / return
// wording, or the ↵ glyph). It is never trusted: it only lets a screen that is otherwise a
// complete trust dialog be recognized and REFUSED instead of silently stalling.
const LOOSE_FOOTER_RE = /\b(enter|esc|escape|return)\b|[↵⏎]/i;
// Blank lines and box-drawing borders (the boxed dialog's bottom edge) carry no content.
const BOX_CHROME_RE = /^[\s─━═╭╮╰╯┌┐└┘│┃]*$/;
const CURSOR_CHARS = '❯›';
const ACCEPT_OPTION_RE = /^(Yes|Trust|Accept|Proceed|Continue|Allow|Approve|OK)\b/i;
const DECLINE_OPTION_RE = /^(No|Exit|Quit|Reject|Cancel|Deny|Decline|Do not|Don't|Not now|Skip)\b/i;
// claude trust dialog (2.1.296+: unnumbered options, cursor DEFAULTS to "No, exit";
// <=2.1.1xx: numbered, default Yes) and the codex directory-trust dialog (0.162: heading
// "Trust this folder? Codex can read, edit, and run files here...", options "Trust and
// continue" / "Quit"; 0.141: heading "Do you trust the contents of this directory?",
// options "Yes, continue" / "No, quit"). Mirrors zsh
// _claude_trust_dialog_state + _codex_dialog_kind. Anchored to the WHOLE (wrap-joined)
// option text, so an unlabeled extra option line that aligns like a wrapped continuation
// ("Remind me later") voids the dialog instead of being swallowed into a trust option.
const TRUST_YES_RE =
  /^(Yes, (I trust this (folder|directory)|proceed|continue)|Trust and continue)(\s*\([^)]*\))?\.?$/;
const TRUST_NO_RE = /^(No, (exit|quit)|Quit)(\s*\([^)]*\))?\.?$/;
const TRUST_HEADING_RE =
  /^.*(Is this a project you[^?]*\?|Do you trust the (files|contents) (in|of) this (folder|directory)\?|Trust this folder\?)(.*)$/;
const TRUST_PHRASES = [
  'Quick safety check',
  'Is this a project you',
  'trust this folder',
  'trust this directory',
  'Do you trust',
];
const HEADING_MAX_LINES = 4; // question wording: the unbroken lines directly above the block
const HEADING_MAX_BLANK = 1; // P3: at most ONE blank line between the question and the first option
const TRUST_HEADING_LINES = 40;
const BOTTOM_REGION_LINES = 15; // where an active prompt lives (same window as the text fallback)
const MAX_TRUST_TRIES = 3;
const TRUST_RETRY_DELAY_MS = 300;

function normalizeScreenLine(line) {
  return line
    .replace(/^(\s*)[│┃]/, '$1 ')
    .replace(/[│┃]\s*$/, '')
    .replace(/\s+$/, '');
}

function parseOptionLine(line) {
  const m = /^\s*(?:([❯›])\s*)?(?:(\d+)[.)]\s*)?(\S.*)$/.exec(line);
  if (!m) return null;
  const [, cursor, num, text] = m;
  if (!cursor && !num && !/^(Yes|No)\b/.test(text)) return null;
  return { cursor: Boolean(cursor), numbered: Boolean(num), text: text.trim() };
}

function classifyOption(text) {
  if (ACCEPT_OPTION_RE.test(text)) return 'accept';
  if (DECLINE_OPTION_RE.test(text)) return 'decline';
  return 'other';
}

function indentOf(line) {
  return line.length - line.trimStart().length;
}

// P2: a cursor-marked line is a picker member when it is a real option (numbered, or
// Yes/No-style wording), or when a directly adjacent line sits aligned with its text
// (`❯ Destroy workspace` / `  Open settings`: an unnumbered menu of unknown options). A
// lone cursor line (`❯ hello`: chat / input box) has no siblings and is not a picker.
// Detection only ever REFUSES; it never authorizes Enter.
function isPickerCursorLine(lines, k) {
  const opt = parseOptionLine(lines[k]);
  if (!opt || !opt.cursor) return false;
  if (opt.numbered || classifyOption(opt.text) !== 'other') return true;
  const bodyCol = /^\s*[❯›]\s*/.exec(lines[k])[0].length;
  return [k - 1, k + 1].some((n) => {
    const sib = lines[n];
    return (
      sib !== undefined &&
      !BOX_CHROME_RE.test(sib) &&
      !FOOTER_RE.test(sib) &&
      (indentOf(sib) === bodyCol || parseOptionLine(sib)?.cursor)
    );
  });
}

// True when a picker sits anywhere in the bottom region (the last BOTTOM_REGION_LINES
// non-blank lines).
function hasPickerInBottomRegion(rawLines) {
  const lines = rawLines.map(normalizeScreenLine);
  const region = [];
  for (let k = 0; k < lines.length; k += 1) if (lines[k].trim() !== '') region.push(k);
  return region.slice(-BOTTOM_REGION_LINES).some((k) => isPickerCursorLine(lines, k));
}

// The question wording is the unbroken run of lines directly above the block, and the
// LAST question of that run (after any earlier "?") must carry PROMPT_RE wording and the
// run must end in "?" / ":". Trust phrases never count as wording (the trust dialog has
// its own cursor-reading path).
function hasAttachedWording(headingLines) {
  let text = headingLines.join(' ').replace(/\s+/g, ' ').trim();
  for (const phrase of TRUST_PHRASES) text = text.split(phrase).join('');
  text = text.trim();
  if (!/[?:]$/.test(text)) return false;
  const lastQuestion = text.slice(text.slice(0, -1).lastIndexOf('?') + 1);
  return PROMPT_RE.test(lastQuestion);
}

// The bottom-most run of option lines (P2: at least two), or null when the screen does not
// end in one (only blank / box-border / footer lines may follow it — anything else means
// it is stale, P1).
function findBottomPromptBlock(rawLines, { looseFooter = false } = {}) {
  const lines = rawLines.map(normalizeScreenLine);
  let i = lines.length - 1;
  while (i >= 0 && BOX_CHROME_RE.test(lines[i])) i -= 1;
  const trustFooter = i >= 0 && TRUST_FOOTER_RE.test(lines[i]);
  if (looseFooter && i >= 0 && !trustFooter && !FOOTER_RE.test(lines[i]) && LOOSE_FOOTER_RE.test(lines[i])) i -= 1;
  while (i >= 0 && (BOX_CHROME_RE.test(lines[i]) || FOOTER_RE.test(lines[i]))) i -= 1;
  const options = [];
  let first = -1;
  for (; i >= 0; i -= 1) {
    const opt = parseOptionLine(lines[i]);
    if (!opt) break;
    options.unshift(opt);
    first = i;
  }
  if (options.length < 2) return null;
  const kinds = options.map((o) => classifyOption(o.text));
  const above = (n) =>
    lines
      .slice(Math.max(0, first - n), first)
      .join(' ')
      .replace(/\s+/g, ' ')
      .trim();
  // P3: the question sits directly above the first option, with at most ONE blank line
  // between them; the question itself is an unbroken run of non-blank lines.
  const headingLines = [];
  let h = first - 1;
  for (let blanks = 0; h >= 0 && blanks < HEADING_MAX_BLANK && BOX_CHROME_RE.test(lines[h]); blanks += 1) h -= 1;
  for (; h >= 0 && headingLines.length < HEADING_MAX_LINES; h -= 1) {
    if (BOX_CHROME_RE.test(lines[h])) break;
    headingLines.unshift(lines[h].trim());
  }
  return {
    options: options.map((o, k) => ({ ...o, kind: kinds[k] })),
    hasYesNo: kinds.some((k) => k !== 'other'),
    hasCursor: options.some((o) => o.cursor),
    hasNumbered: options.some((o) => o.numbered),
    headingWording: hasAttachedWording(headingLines),
    trustHeadingText: above(TRUST_HEADING_LINES),
    trustFooter,
  };
}

// The trust dialog's shape without its footer: exactly one trust option, one No/Quit
// option and a trust heading.
function hasTrustShape(block) {
  const { options, trustHeadingText } = block;
  if (options.length !== 2) return false;
  const yes = options.filter((o) => TRUST_YES_RE.test(o.text));
  const no = options.filter((o) => TRUST_NO_RE.test(o.text));
  if (yes.length !== 1 || no.length !== 1) return false;
  const m = TRUST_HEADING_RE.exec(trustHeadingText);
  return m !== null && !m[5].includes('?');
}

function isTrustDialog(block) {
  return block.trustFooter && hasTrustShape(block);
}

// 'yes' | 'no' | 'unknown' — the cursor on exactly one of the trust options.
function trustCursorState(block) {
  const selected = block.options.filter((o) => o.cursor);
  if (selected.length !== 1) return 'unknown';
  return TRUST_YES_RE.test(selected[0].text) ? 'yes' : 'no';
}

// The key that moves the cursor from the No/Quit option onto the trust option. The order
// differs by dialog (claude 2.1.296: No above Yes; codex: Trust above Quit).
function trustMoveKey(block) {
  const from = block.options.findIndex((o) => o.cursor);
  const to = block.options.findIndex((o) => TRUST_YES_RE.test(o.text));
  return to < from ? 'Up' : 'Down';
}

function parseTrustBlock(capture) {
  const block = capture ? findBottomPromptBlock(capture.split('\n')) : null;
  return block && isTrustDialog(block) ? block : null;
}


// 'accept' | 'decline' | 'unidentified' | 'no-wording'
function decideSelectedOption(block) {
  const selected = block.options.filter((o) => o.cursor);
  if (selected.length !== 1) return 'unidentified';
  const kind = classifyOption(selected[0].text);
  if (kind === 'decline') return 'decline';
  if (kind !== 'accept') return 'unidentified';
  return block.headingWording ? 'accept' : 'no-wording';
}

function refusalReason(decision, block) {
  const shown = block.options
    .map((o) => `${o.cursor ? CURSOR_CHARS[0] : ' '} ${o.text}`)
    .join(' | ')
    .slice(0, 120);
  if (decision === 'decline') {
    return `default-No prompt requires explicit human decision: the selected option is a decline option; refusing to press Enter (options: ${shown})`;
  }
  if (decision === 'no-wording') {
    return `Pane shows a selectable Yes/No prompt whose own wording is not in PROMPT_RE. Refusing to guess auto-Enter. Options: ${shown}`;
  }
  return `Pane shows a Yes/No prompt but the selected option cannot be identified as an accept option; refusing to press Enter (options: ${shown})`;
}

function notifyBlock(onDefaultNoBlock, info) {
  if (typeof onDefaultNoBlock !== 'function') return;
  try {
    onDefaultNoBlock(info);
  } catch {
    // Caller errors must not propagate into the poll loop.
  }
}

// Answer the claude / codex trust dialog deterministically: Enter only with the cursor
// read on the trust option; cursor on No/Quit -> move onto it; unknown cursor -> re-read,
// never Enter. Bounded. (Event names keep their historical "claude_" prefix for both.)
async function acceptTrustDialog(paneId, firstBlock, { sendKeys, capturePane, log, sleep, onDefaultNoBlock }) {
  let block = firstBlock;
  for (let tries = 0; ; tries += 1) {
    const state = trustCursorState(block);
    if (state === 'yes') {
      log({ category: 'FLOW', event: 'claude_trust_prompt_auto_approved', pane_id: paneId });
      await sendKeys(paneId, 'Enter');
      return true;
    }
    if (tries >= MAX_TRUST_TRIES) {
      log({ category: 'FLOW', event: 'claude_trust_prompt_accept_failed', pane_id: paneId, cursor: state });
      notifyBlock(onDefaultNoBlock, {
        paneId,
        reason: `claude trust dialog: cursor still '${state}' after ${tries} attempts; refusing to press Enter (it would select 'No, exit' or an unknown option). Accept the dialog manually.`,
        category: 'infra_failure',
      });
      return false;
    }
    if (state === 'no') await sendKeys(paneId, trustMoveKey(block));
    await sleep(TRUST_RETRY_DELAY_MS);
    try {
      block = parseTrustBlock(await capturePane(paneId));
    } catch {
      return false;
    }
    if (!block) return false; // dialog is gone (answered elsewhere / claude moved on)
  }
}

const DEBOUNCE_MS = 3000;

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const lastApprovalAt = new Map();

export function _resetForTesting() {
  lastApprovalAt.clear();
}

export async function autoDismissPrompts(paneId, deps) {
  const {
    sendKeys,
    capturePane,
    log = () => {},
    now = Date.now,
    sleep = defaultSleep,
    onDefaultNoBlock,
  } = deps;

  const t = now();
  const prev = lastApprovalAt.get(paneId);
  if (prev !== undefined && t - prev < DEBOUNCE_MS) {
    return false;
  }

  let capture;
  try {
    capture = await capturePane(paneId);
  } catch {
    return false;
  }
  if (!capture) {
    return false;
  }

  // TRUST-F: a prompt block drawn as selectable options (`❯` cursor) is decided
  // from the selected option of the bottom-most block, never from wording elsewhere
  // on the screen. This also covers the claude trust dialog (2.1.296 defaults the
  // cursor to "No, exit": the cursor is read and moved to Yes, Enter never lands on No).
  const block = findBottomPromptBlock(capture.split('\n'));
  if (block && isTrustDialog(block)) {
    lastApprovalAt.set(paneId, t);
    return acceptTrustDialog(paneId, block, { sendKeys, capturePane, log, sleep, onDefaultNoBlock });
  }
  // R3-03: the real trust heading and both options, but a footer none of the recognizers
  // know. Nothing is sent (we cannot tell this is the dialog we were written for), and the
  // refusal is surfaced so the screen does not stall silently.
  if (!block) {
    const loose = findBottomPromptBlock(capture.split('\n'), { looseFooter: true });
    if (loose && hasTrustShape(loose)) {
      lastApprovalAt.set(paneId, t);
      log({ category: 'FLOW', event: 'claude_trust_prompt_footer_unrecognized', pane_id: paneId });
      notifyBlock(onDefaultNoBlock, {
        paneId,
        reason: 'trust dialog with an unrecognized footer; refusing to press Enter or move the cursor. Accept the dialog manually.',
        category: 'infra_failure',
      });
      return false;
    }
  }
  // A cursorless block must at least be numbered (prose such as "No issues found." is not a prompt).
  if (block && block.hasYesNo && (block.hasCursor || (block.hasNumbered && block.headingWording))) {
    const decision = decideSelectedOption(block);
    if (decision === 'accept') {
      log({ category: 'FLOW', event: 'permission_prompt_auto_approved', pane_id: paneId });
      await sendKeys(paneId, 'Enter');
      lastApprovalAt.set(paneId, t);
      return true;
    }
    // A block without recognizable wording of its own is the unknown-prompt case
    // (suppressed while the worker is active); every other outcome refuses.
    if (decision !== 'no-wording' || !ACTIVE_TASK_RE.test(capture)) {
      lastApprovalAt.set(paneId, t);
      log({
        category: 'FLOW',
        event:
          decision === 'decline'
            ? 'permission_prompt_default_no_blocked'
            : 'permission_prompt_selection_unidentified',
        pane_id: paneId,
      });
      notifyBlock(onDefaultNoBlock, {
        paneId,
        reason: refusalReason(decision, block),
        category: 'infra_failure',
      });
    }
    return false;
  }

  // v5.7 §4.23 (E2E real-claude-CLI finding): tmux narrow-pane wrap breaks
  // multi-line prompts ("Do you want to\nmake this edit to\nprd-sum-fn.md?\n
  // ❯ 1. Yes") so line-adjacency PROMPT+AFFORDANCE±1 misses them. Fix:
  // examine the LAST 15 normalized lines (where the active prompt lives)
  // as a single joined+whitespace-collapsed string. PROMPT_RE + AFFORDANCE
  // both present → auto-Enter unless DEFAULT_NO_RE also present (BLOCK).
  // §4.17.b is preserved: scan-all default-No protects against scrollback
  // contamination (older [Y/n] alongside active [y/N]).
  const lines = capture.split('\n');
  const tailLines = lines.slice(-15);
  const tailNormalized = tailLines.join(' ').replace(/\s+/g, ' ');

  // Trust wording alone (prose, a quoted menu, a heading/footer without its options)
  // never authorizes Enter — an ACTIVE trust dialog was handled above with the cursor
  // read. Numbered/cursor pickers are decided by the selected option above, so only
  // the text affordances ((y/n), [Y/n], press y ...) may authorize here — and never
  // while a cursor-marked option is on screen: Enter would confirm that selection, which
  // the block rules above could not identify as an accept option (C-RA).
  const cursorOptionSeen = hasPickerInBottomRegion(lines);
  let tailWithoutTrust = tailNormalized;
  for (const phrase of TRUST_PHRASES) tailWithoutTrust = tailWithoutTrust.split(phrase).join('');
  const promptVisible = PROMPT_RE.test(tailWithoutTrust) && TEXT_AFFORDANCE_RE.test(tailNormalized);
  // Default-No: scan FULL capture (not just tail) so an older default-Yes
  // bracket in scrollback can't override an active default-No. §4.17.b.
  const defaultNoSeen = DEFAULT_NO_RE.test(capture);
  const samplePattern = tailNormalized.slice(0, 120);

  if (defaultNoSeen) {
    log({
      category: 'FLOW',
      event: 'permission_prompt_default_no_blocked',
      pane_id: paneId,
    });
    if (typeof onDefaultNoBlock === 'function') {
      try {
        onDefaultNoBlock({
          paneId,
          reason: `default-No prompt requires explicit human decision (sample: ${samplePattern})`,
          category: 'infra_failure',
        });
      } catch {
        // Caller errors must not propagate into the poll loop.
      }
    }
    lastApprovalAt.set(paneId, t);
    return false;
  }

  if (promptVisible && cursorOptionSeen) {
    // A busy worker's scrollback may hold an old menu: stay silent then (same as the
    // no-wording case); otherwise surface the refusal.
    if (!ACTIVE_TASK_RE.test(capture)) {
      lastApprovalAt.set(paneId, t);
      log({ category: 'FLOW', event: 'permission_prompt_selection_unidentified', pane_id: paneId });
      notifyBlock(onDefaultNoBlock, {
        paneId,
        reason: `Pane shows a text prompt together with a cursor-marked option block whose selection cannot be identified as an accept option; refusing to press Enter (sample: ${samplePattern})`,
        category: 'infra_failure',
      });
    }
    return false;
  }

  if (promptVisible) {
    log({ category: 'FLOW', event: 'permission_prompt_auto_approved', pane_id: paneId });
    await sendKeys(paneId, 'Enter');
    lastApprovalAt.set(paneId, t);
    return true;
  }

  // v5.7 §4.18: unknown-prompt fast-fail (E2E + omc benchmarking).
  // If pane has an affordance bracket but no recognized PROMPT_RE phrasing,
  // refuse to guess auto-Enter (could be wrong default) and BLOCK so the
  // operator can extend PROMPT_RE — instead of waiting 10 min for freeze
  // timeout. Skip if active-task markers are present (Worker is producing
  // output and the affordance text is likely just transcript).
  const captureHasActiveTask = ACTIVE_TASK_RE.test(capture);
  if (captureHasActiveTask) {
    return false;
  }
  // Only inspect the last 5 non-empty lines (where an idle prompt would sit).
  const tail5Lines = lines.filter((l) => l.length > 0).slice(-5);
  let suspectLine = '';
  for (const line of tail5Lines) {
    if (AFFORDANCE_RE.test(line)) {
      suspectLine = line;
      break;
    }
  }
  if (suspectLine) {
    const tailHasDefaultNo = tail5Lines.some((l) => DEFAULT_NO_RE.test(l));
    log({
      category: 'GOV',
      event: 'unknown_prompt_detected',
      pane_id: paneId,
      default_no: tailHasDefaultNo,
    });
    if (typeof onDefaultNoBlock === 'function') {
      try {
        onDefaultNoBlock({
          paneId,
          reason: tailHasDefaultNo
            ? `Pane shows a default-No affordance but the surrounding prompt phrasing is not in PROMPT_RE. Sample: ${suspectLine.slice(0, 120)}`
            : `Pane shows a y/n affordance marker without a recognized prompt phrasing. Refusing to guess auto-Enter. Sample: ${suspectLine.slice(0, 120)}`,
          category: 'infra_failure',
        });
      } catch {
        // Caller errors must not propagate.
      }
    }
    lastApprovalAt.set(paneId, t);
    return false;
  }
  return false;
}
