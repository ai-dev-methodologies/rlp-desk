// US-001 — campaign codex launches must not be captured by the oh-my-codex
// native-hook surface.
//
// Root cause pinned here (F1.19): `~/.codex/hooks.json` registers
// oh-my-codex's native hook on 7 lifecycle events GLOBALLY. Its
// UserPromptSubmit keyword-detector scans the campaign's OWN worker prompt,
// hits seeded prose like "Don't assume.", and auto-activates deep-interview;
// PreToolUse then blocks every write tool for the rest of that codex session.
// This happens INSIDE the campaign's own isolated OMX_STATE_ROOT — it is not
// stale operator state, and `--disable plugins` does not cover native hooks.
//
// Coverage split (do not blur these):
//   * zsh leader  — LIVE. Probe + chokepoint + all 8 launch-assembly sites.
//   * native leader — LIVE. Prose instructions in rlp-desk.md / governance.md.
//   * Node builder — DEAD-CODE PARITY ONLY. `--mode agent` hard-errors in
//     run.mjs, so buildCodexCmd is CLI-unreachable; its assertions below must
//     never be cited as coverage of a shipping path.
//
// TEXT-ONLY over the shell/markdown leaders (they are not importable), plus a
// real unit over the Node builder. No child processes, no network.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildCodexCmd } from '../../src/node/cli/command-builder.mjs';

const selfPath = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(selfPath), '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const runZsh = read('src/scripts/run_ralph_desk.zsh');
const libZsh = read('src/scripts/lib_ralph_desk.zsh');
const builderSrc = read('src/node/cli/command-builder.mjs');
const specMd = read('src/commands/rlp-desk.md');
const govMd = read('src/governance.md');
const fmMd = read('docs/rlp-desk/failure-modes.md');

const runLines = runZsh.split('\n');
const libLines = libZsh.split('\n');

const isCommentLine = (line) => /^\s*#/.test(line);

// The probe FUNCTION BODY only — deliberately excludes the surrounding comment
// block, whose prose ("… is stable across both") would otherwise false-positive
// the "must not parse the state column" guard below.
const probeBody = () => {
  const start = runZsh.indexOf('_probe_codex_hooks_flag() {');
  assert.ok(start > -1, '_probe_codex_hooks_flag must be defined in run_ralph_desk.zsh');
  const end = runZsh.indexOf('\n}\n', start);
  assert.ok(end > start, '_probe_codex_hooks_flag must be a closed function');
  return runZsh.slice(start, end + 3);
};

// Join backslash-continued shell lines so a launch template split across a
// fenced multi-line block is evaluated as the single command it is.
const joinContinuations = (src) => {
  const out = [];
  for (const line of src.split('\n')) {
    if (out.length && /\\\s*$/.test(out[out.length - 1])) {
      out[out.length - 1] = `${out[out.length - 1].replace(/\\\s*$/, '')} ${line.trim()}`;
    } else {
      out.push(line);
    }
  }
  return out;
};

// ---------------------------------------------------------------------------
// AC1a / AC2 — zsh startup probe
// ---------------------------------------------------------------------------

test('AC2 zsh: _CODEX_NO_HOOKS_FLAG is declared with typeset -g and starts empty', () => {
  assert.match(
    runZsh,
    /typeset -g _CODEX_NO_HOOKS_FLAG=""/,
    'run_ralph_desk.zsh must declare _CODEX_NO_HOOKS_FLAG globally (typeset -g) so the runtime fallback can clear it for the rest of the run',
  );
});

test('AC2 zsh: the probe resolves codex via `command -v codex`, not the bare name', () => {
  const probe = probeBody();
  assert.ok(probe.length > 0, '_probe_codex_hooks_flag must be defined near the _CODEX_NO_UPDATE_FLAG block');
  assert.match(
    probe,
    /command -v codex/,
    'the probe must interrogate the absolute path resolved by `command -v codex` — the same binary the pane runs',
  );
});

test('AC2 zsh: probe predicate is NAME PRESENCE in column 1, never the state column', () => {
  const probe = probeBody();
  assert.match(probe, /features list/, 'probe must call `codex features list`');
  assert.match(
    probe,
    /awk '\{print \$1\}'/,
    'probe must project column 1 (the feature NAME) before matching',
  );
  assert.match(
    probe,
    /grep -qx '?hooks'?/,
    'probe must match the whole name `hooks` exactly (-x), not a substring',
  );
  // `apply_patch_freeform` is `removed false` yet `--disable apply_patch_freeform`
  // still exits 0 — a stable/true state parse would wrongly drop the flag on a
  // future CLI. Guard against anyone reintroducing a state predicate.
  assert.doesNotMatch(
    probe,
    /\bstable\b|\$2|\$3/,
    'probe must NOT parse the state/value columns — name presence only',
  );
});

test('AC3 zsh: RLP_CODEX_HOOKS=1 escape hatch exists and is documented next to RLP_CODEX_UPDATE_CHECK', () => {
  assert.match(
    runZsh,
    /RLP_CODEX_HOOKS:-0.*==\s*"1"/s,
    'RLP_CODEX_HOOKS=1 must suppress the flag',
  );
  const updateIdx = runZsh.indexOf('RLP_CODEX_UPDATE_CHECK');
  const hooksIdx = runZsh.indexOf('RLP_CODEX_HOOKS');
  assert.ok(updateIdx > -1 && hooksIdx > -1);
  const between = runZsh.slice(Math.min(updateIdx, hooksIdx), Math.max(updateIdx, hooksIdx));
  assert.ok(
    between.split('\n').length < 60,
    'the RLP_CODEX_HOOKS escape hatch must be documented adjacent to RLP_CODEX_UPDATE_CHECK (mirroring _CODEX_NO_UPDATE_FLAG), not scattered elsewhere in the file',
  );
});

// ---------------------------------------------------------------------------
// AC1a / AC7 — the single chokepoint
// ---------------------------------------------------------------------------

test('AC7: _codex_launch_with_hook_fallback is defined exactly once, and in lib_ralph_desk.zsh', () => {
  const libDefs = libLines.filter((l) => /^_codex_launch_with_hook_fallback\(\)/.test(l));
  assert.equal(libDefs.length, 1, 'exactly one definition in lib_ralph_desk.zsh');
  assert.equal(
    runLines.filter((l) => /^_codex_launch_with_hook_fallback\(\)/.test(l)).length,
    0,
    'the chokepoint must NOT be duplicated in run_ralph_desk.zsh',
  );
});

test('AC7: the chokepoint inserts the flag after --disable plugins and can strip it back out', () => {
  const fn = libZsh.slice(libZsh.indexOf('_codex_launch_with_hook_fallback()'));
  const body = fn.slice(0, fn.indexOf('\n}\n') + 3);
  assert.match(
    body,
    /--disable plugins\$\{_CODEX_NO_HOOKS_FLAG\}/,
    'decoration must splice the flag immediately after `--disable plugins` — appending at the end would land after the positional prompt argument at the trigger-script sites',
  );
  assert.match(body, /--disable hooks/, 'the chokepoint must know the strip token');
  assert.match(
    body,
    /Unknown feature flag/,
    'the retry must be gated on the codex hard-error text, so unrelated launch failures are never masked',
  );
  assert.match(
    body,
    /typeset -g _CODEX_NO_HOOKS_FLAG=""/,
    'the fallback must clear the flag GLOBALLY (typeset -g) so the clearing persists past this function for the rest of the run',
  );
});

test('AC7: the real codex launchers publish their failure text for the chokepoint to inspect', () => {
  assert.match(
    runZsh,
    /_CODEX_LAUNCH_FAIL_TEXT/,
    'launch_worker_codex / launch_verifier_codex must publish the final pane capture so the chokepoint can detect "Unknown feature flag"',
  );
  // Both launchers reset it per launch, exactly like _CODEX_LAUNCH_FAIL_REASON.
  const resets = runLines.filter((l) => /_CODEX_LAUNCH_FAIL_TEXT=""/.test(l) && !isCommentLine(l));
  assert.ok(
    resets.length >= 2,
    `both codex launchers must reset _CODEX_LAUNCH_FAIL_TEXT per launch (found ${resets.length} resets)`,
  );
});

// ---------------------------------------------------------------------------
// AC1a — all 8 zsh launch-assembly sites route through the chokepoint
// ---------------------------------------------------------------------------

test('AC1a: exactly 8 codex launch-assembly sites still carry --disable plugins', () => {
  const sites = runLines.filter(
    (l) => /--disable plugins/.test(l) && !isCommentLine(l),
  );
  assert.equal(
    sites.length,
    8,
    `expected the known 8 codex launch-assembly sites, found ${sites.length}. If a site was added or removed, route it through _codex_launch_with_hook_fallback and update this count deliberately.`,
  );
});

test('AC1a: no assembly site hardcodes --disable hooks (the flag must stay probe-gated)', () => {
  const hardcoded = runLines.filter(
    (l) => /--disable plugins --disable hooks/.test(l) && !isCommentLine(l),
  );
  assert.deepEqual(
    hardcoded,
    [],
    'a hardcoded --disable hooks would hard-error every launch on a codex CLI that does not advertise the feature',
  );
});

test('AC1a: every launch_{worker,verifier}_codex INVOCATION routes through the chokepoint', () => {
  const invocations = runLines
    .map((line, i) => ({ line, n: i + 1 }))
    .filter(
      ({ line }) =>
        /launch_(worker|verifier)_codex\s+"/.test(line) &&
        !isCommentLine(line) &&
        !/^launch_(worker|verifier)_codex\(\)/.test(line.trim()),
    );
  assert.ok(invocations.length >= 10, `expected >=10 codex launcher invocations, found ${invocations.length}`);
  const unrouted = invocations.filter(
    ({ line }) => !line.includes('_codex_launch_with_hook_fallback'),
  );
  assert.deepEqual(
    unrouted.map(({ n, line }) => `${n}: ${line.trim()}`),
    [],
    'every codex launcher invocation must go through the single chokepoint — a bypass reintroduces the total-outage failure mode AC7 exists to prevent',
  );
});

test('AC1a: the three decorate-only sites (restart send-keys + 2 trigger scripts) also route through the chokepoint', () => {
  // Worker restart: safe_send_keys with an inline codex launch string.
  const restart = runLines.filter(
    (l) => /safe_send_keys/.test(l) && /--disable plugins/.test(l) && !isCommentLine(l),
  );
  assert.equal(restart.length, 1, 'expected exactly one codex restart send-keys site');
  assert.match(
    restart[0],
    /_codex_launch_with_hook_fallback/,
    'the restart send-keys site must decorate through the chokepoint',
  );

  // Trigger scripts: `local engine_cmd="OMX_STATE_ROOT=... codex ..."`.
  const engineCmds = runLines.filter(
    (l) => /engine_cmd=/.test(l) && /OMX_STATE_ROOT/.test(l) && !isCommentLine(l),
  );
  assert.equal(engineCmds.length, 2, 'expected exactly two codex trigger-script assembly sites');
  for (const line of engineCmds) {
    assert.match(
      line,
      /_codex_launch_with_hook_fallback/,
      `trigger-script assembly must decorate through the chokepoint: ${line.trim()}`,
    );
  }
});

// ---------------------------------------------------------------------------
// AC1a (Node) — dead-code parity, NOT live coverage
// ---------------------------------------------------------------------------

test('AC1a Node parity: buildCodexCmd emits --disable plugins --disable hooks, in that order', () => {
  const cmd = buildCodexCmd('tui', 'gpt-5.6-luna', { reasoning: 'high' });
  assert.match(cmd, /--disable plugins --disable hooks --dangerously-bypass-approvals-and-sandbox/);
});

test('AC1a Node parity: no Node-side probe (bare CODEX_BIN would interrogate a different binary)', () => {
  assert.doesNotMatch(
    builderSrc,
    /features list/,
    'command-builder.mjs resolves a bare `codex` via PATH in-pane, so a Node probe would interrogate a different binary than the pane runs — the probe belongs to zsh only',
  );
  assert.match(builderSrc, /const CODEX_BIN = 'codex'/, 'the bare-binary caveat this test guards must still hold');
});

test('AC1a Node parity: the builder is annotated as dead-code parity, not live coverage', () => {
  const idx = builderSrc.indexOf("'--disable', 'plugins'");
  assert.ok(idx > -1);
  const preamble = builderSrc.slice(Math.max(0, idx - 1400), idx);
  assert.match(
    preamble,
    /parity/i,
    'the --disable hooks addition must be commented as parity',
  );
  assert.match(
    preamble,
    /ADR-001|--mode agent/,
    'the comment must name why this path is dead (run.mjs hard-errors --mode agent per ADR-001) so it is never cited as live coverage',
  );
});

// ---------------------------------------------------------------------------
// AC1b / AC1c / AC2 / AC4 — native leader
// ---------------------------------------------------------------------------

const nativeCodexLaunchLines = (src) =>
  joinContinuations(src).filter((l) => /codex (exec )?-/.test(l) && /OMX_STATE_ROOT/.test(l));

test('AC1b: every native-leader codex launch template carries --disable plugins --disable hooks', () => {
  for (const [name, src] of [['rlp-desk.md', specMd], ['governance.md', govMd]]) {
    const lines = nativeCodexLaunchLines(src);
    assert.ok(lines.length > 0, `${name}: expected at least one native codex launch template`);
    for (const line of lines) {
      assert.match(
        line,
        /--disable plugins --disable hooks/,
        `${name}: native codex launch template missing the flag pair: ${line.trim()}`,
      );
    }
  }
});

test('AC1b closure: NO launch-shaped codex line escapes the flag rule via a missing OMX_STATE_ROOT prefix', () => {
  // SV-gate CRITICAL scenario ANOM-1 (2026-08-10): the AC1b filter keys on
  // OMX_STATE_ROOT, so a launch template that DROPPED that prefix — the exact
  // F1.18 regression — would silently exit AC1b's universe and pass vacuously.
  // Closure: every line that even LOOKS like a codex launch must either carry
  // the full flag pair + the OMX_STATE_ROOT prefix, or be a known non-template
  // (prose/diagram/prohibition) listed here by content. An unexplained line
  // fails — additions to this allowlist are a reviewed decision, not drift.
  const NON_TEMPLATE_ALLOWLIST = [
    /`codex exec \.\.\.`/,                                   // elided prose mention
    /--reasoning-effort <r> --disable plugins --disable hooks <prompt>`$/, // help-block diagram (flag-correct, no env prefix by design)
    /Do NOT add `--dangerously-bypass-approvals-and-sandbox`/, // NON-GOAL prohibition line
    /codex --disable bogus/,                                  // probe hard-error illustration
    /codex features list/,                                    // probe instruction line
  ];
  for (const [name, src] of [['rlp-desk.md', specMd], ['governance.md', govMd]]) {
    const launchShaped = joinContinuations(src).filter((l) => /codex (exec )?-/.test(l));
    const unexplained = launchShaped.filter(
      (l) =>
        !(/OMX_STATE_ROOT/.test(l) && /--disable plugins --disable hooks/.test(l)) &&
        !NON_TEMPLATE_ALLOWLIST.some((re) => re.test(l)),
    );
    assert.deepEqual(
      unexplained.map((l) => l.trim().slice(0, 120)),
      [],
      `${name}: launch-shaped codex line neither a compliant template nor an allow-listed non-template`,
    );
  }
});

test('AC1c: both native docs state the same flag set', () => {
  assert.match(specMd, /--disable plugins --disable hooks/);
  assert.match(govMd, /--disable plugins --disable hooks/);
});

test('NON-GOAL 1: the rlp-desk.md worker/verifier codex exec templates do NOT gain --dangerously-bypass-approvals-and-sandbox', () => {
  const offenders = specMd
    .split('\n')
    .filter((l) => /codex exec /.test(l) && /--dangerously-bypass-approvals-and-sandbox/.test(l));
  assert.deepEqual(
    offenders.map((l) => l.trim()),
    [],
    'adding the bypass flag here is a sandbox-posture change, not a parity fix — explicitly out of scope for US-001 (the sv-oracle-nv campaign proves codex exec works today under the default posture)',
  );
});

test('AC2 native: the probe is instructed once-and-reused, before the first dispatch', () => {
  assert.match(
    specMd,
    /probe/i,
    'rlp-desk.md must instruct the native leader to probe for the hooks feature flag',
  );
  const probeSection = specMd.slice(
    Math.max(0, specMd.toLowerCase().indexOf('codex features list') - 1200),
    specMd.toLowerCase().indexOf('codex features list') + 1600,
  );
  assert.match(probeSection, /codex features list/, 'the native probe must use `codex features list`');
  assert.match(
    probeSection,
    /once/i,
    'the native probe must be stated as "probe once, reuse for the whole campaign" — a per-dispatch probe costs ~40ms on every worker/verifier/consensus leg for no benefit',
  );
});

test('AC7 native: rlp-desk.md states the retry-once-and-omit rule in prose', () => {
  assert.match(
    specMd,
    /Unknown feature flag/,
    'the native leader cannot wrap a shell function, so the strip-and-retry rule must be stated in prose',
  );
});

test('AC4: the native docs state the CORRECT cause (keyword-detector), not stale operator state', () => {
  assert.match(
    specMd,
    /keyword[- ]detector/i,
    'rlp-desk.md must name the UserPromptSubmit keyword-detector as the mechanism',
  );
  assert.match(specMd, /F1\.19/, 'rlp-desk.md must reference the failure-modes entry');
  assert.match(govMd, /F1\.19/, 'governance.md must reference the failure-modes entry');
});

// ---------------------------------------------------------------------------
// AC8 riders (US-003 AC6a / AC6b) — same SV-gated commit
// ---------------------------------------------------------------------------

test('AC6a: the stop= bullets are labelled as the memory.md Stop Status channel', () => {
  const idx = specMd.indexOf('`stop=continue`');
  assert.ok(idx > -1, 'the stop= bullet block must still exist');
  const around = specMd.slice(Math.max(0, idx - 700), idx + 400);
  assert.match(
    around,
    /Stop Status/,
    'the stop= bullets must be explicitly labelled as the memory.md "Stop Status" channel, so a reader cannot carry `stop=` across into iter-signal.json',
  );
  assert.match(
    around,
    /iter-signal/,
    'the label must contrast the Stop Status channel against the iter-signal.json channel that sits directly below it',
  );
});

test('AC6a NON-GOAL 2: no fourth value is added to the stop= bullets', () => {
  const idx = specMd.indexOf('`stop=continue`');
  const block = specMd.slice(idx, idx + 500);
  assert.doesNotMatch(
    block,
    /stop=verify_partial/,
    'Stop Status accepts continue|verify|blocked; adding a fourth value there invents protocol (two independent docs already pin the three-value set)',
  );
});

test('AC6b: step ⑥ iter-signal handling gains a verify_partial branch', () => {
  assert.ok(
    specMd.includes('verify_partial'),
    'the native leader must have a defined response to verify_partial — its own shared worker prompt (init_ralph_desk.zsh) authorizes workers to emit it',
  );
  const idx = specMd.indexOf('verify_partial');
  const around = specMd.slice(Math.max(0, idx - 900), idx + 500);
  assert.match(
    around,
    /iter-signal/,
    'the verify_partial branch must live in the iter-signal handling, not in the Stop Status bullets',
  );
});

// ---------------------------------------------------------------------------
// AC6 — failure-modes atlas
// ---------------------------------------------------------------------------

test('AC6: F1.19 exists with the full Symptom/Root cause/Detection/Recovery/Reference schema', () => {
  assert.match(fmMd, /### F1\.19 —/, 'F1.19 must be added to the atlas');
  const start = fmMd.indexOf('### F1.19');
  const rest = fmMd.slice(start);
  const end = rest.indexOf('\n---');
  const entry = end > -1 ? rest.slice(0, end) : rest;
  for (const field of ['Symptom', 'Root cause', 'Detection', 'Recovery', 'Reference']) {
    assert.match(entry, new RegExp(`\\| ${field} \\|`), `F1.19 missing the ${field} row`);
  }
  assert.match(entry, /keyword[- ]detector/i, 'F1.19 must name the keyword-detector mechanism');
  assert.match(
    entry,
    /--disable hooks/,
    'F1.19 Recovery must name the actual fix',
  );
});

test('AC6: F1.19 root cause is the campaign\'s OWN prompt inside its OWN isolated root', () => {
  const start = fmMd.indexOf('### F1.19');
  const rest = fmMd.slice(start);
  const end = rest.indexOf('\n---');
  const entry = end > -1 ? rest.slice(0, end) : rest;
  assert.match(
    entry,
    /own prompt|its own prompt|campaign's own/i,
    'the corrected root cause is that the campaign trips the hook with its own prompt',
  );
  assert.match(
    entry,
    /OMX_STATE_ROOT/,
    'F1.19 must record that OMX_STATE_ROOT isolation WORKED and did not prevent this',
  );
});

test('AC6: F1.18 no longer implies stale operator state is the deep-interview mechanism', () => {
  const start = fmMd.indexOf('### F1.18');
  const rest = fmMd.slice(start);
  const end = rest.indexOf('\n---');
  const entry = end > -1 ? rest.slice(0, end) : rest;
  assert.match(
    entry,
    /F1\.19/,
    'F1.18 must point at F1.19 so a reader does not attribute the hook-capture failure to stale operator state',
  );
  assert.match(
    entry,
    /keyword[- ]detector|native hook/i,
    'F1.18 must be amended to distinguish its own stale-lock mechanism from the native-hook capture in F1.19',
  );
});
