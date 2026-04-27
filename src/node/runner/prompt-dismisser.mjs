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
const DEBOUNCE_MS = 3000;

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

  // v5.7 §4.21 (E2E real-claude-CLI finding): claude v2.x trust prompt is
  // multi-line and wraps narrowly, so line-adjacency PROMPT_RE+AFFORDANCE_RE
  // misses it. Special-case the signature ("Quick safety check ... Enter to
  // confirm" with `❯N.` numbered picker selecting Yes by default).
  // This is a default-Yes prompt — pressing Enter approves trust.
  // §4.21.b: tmux narrow-pane wrap breaks `Quick safety check` across
  // lines (`Quick safety\n check`). Normalize whitespace before matching.
  const normalizedCapture = capture.replace(/\s+/g, ' ');
  if (
    (/Quick safety check/.test(normalizedCapture) ||
      /trust this (folder|directory)/.test(normalizedCapture)) &&
    /Enter to confirm/.test(normalizedCapture) &&
    /❯ ?\d+\. ?Yes/.test(normalizedCapture)
  ) {
    log({
      category: 'FLOW',
      event: 'claude_trust_prompt_auto_approved',
      pane_id: paneId,
    });
    await sendKeys(paneId, 'Enter');
    lastApprovalAt.set(paneId, t);
    return true;
  }
  // Older claude trust prompt format ("Do you trust the contents of this
  // directory?" + "Yes, continue / No, quit" — omc-team parity).
  if (
    /Do you trust the contents of this directory/.test(capture) &&
    /Yes,\s*continue|Press enter to continue/.test(capture)
  ) {
    log({
      category: 'FLOW',
      event: 'claude_trust_prompt_auto_approved',
      pane_id: paneId,
    });
    await sendKeys(paneId, 'Enter');
    lastApprovalAt.set(paneId, t);
    return true;
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

  const promptVisible = PROMPT_RE.test(tailNormalized) && AFFORDANCE_RE.test(tailNormalized);
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
