# Flywheel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the incomplete pivot step with a proper flywheel direction-review step that internalizes plan-ceo-review's core framework (premise challenge, forced alternatives, scope decisions, CEO cognitive patterns) within the campaign loop.

**Architecture:** On Verifier FAIL, a fresh-context Flywheel agent runs BEFORE the next Worker. It reviews premises, proposes alternatives, decides scope (HOLD/PIVOT/REDUCE/EXPAND), rewrites the iteration contract, and records rejected directions. Worker then executes the updated contract. In tmux mode, Flywheel gets its own pane (leftmost). In agent mode, Leader calls Agent().

**Tech Stack:** Node.js (ESM), zsh (init/run scripts), Claude Code Agent API

**Spec:** `docs/superpowers/specs/2026-04-12-flywheel-redesign.md`

---

### Task 1: Remove existing pivot code

**Files:**
- Modify: `src/node/runner/campaign-main-loop.mjs` (remove pivot functions + wiring)
- Modify: `src/node/run.mjs` (remove --pivot-mode, --pivot-model)
- Modify: `src/scripts/init_ralph_desk.zsh` (remove pivot prompt template + cleanup refs)
- Modify: `src/commands/rlp-desk.md` (remove pivot flags from options reference)
- Delete: `tests/node/test-pivot-step.mjs`

- [ ] **Step 1: Remove pivot functions from campaign-main-loop.mjs**

Remove these functions entirely:
- `shouldRunPivot()` (lines 402-408)
- `buildPivotTriggerCmd()` (lines 410-412)
- `dispatchPivot()` (lines 414-425)

Remove pivot paths from `buildPaths()`:
```javascript
// DELETE these two lines:
pivotPromptFile: path.join(deskRoot, 'prompts', `${slug}.pivot.prompt.md`),
pivotSignalFile: path.join(deskRoot, 'memos', `${slug}-pivot-signal.json`),
```

Remove pivot wiring in the main loop (around line 539):
```javascript
// DELETE this entire block:
if (shouldRunPivot(options.pivotMode ?? 'off', state, lastVerdict)) {
  state.phase = 'pivot';
  // ... through to closing }
}
```

Remove `lastVerdict` variable declaration and assignment (lines 474, 608).

- [ ] **Step 2: Remove pivot flags from run.mjs**

Remove from defaults (lines 24-25):
```javascript
// DELETE:
pivotMode: 'off',
pivotModel: 'opus',
```

Remove from help text (lines 60-61):
```javascript
// DELETE:
'  --pivot-mode off|every|on-fail',
'  --pivot-model MODEL',
```

Remove from flag parser (lines 150-155):
```javascript
// DELETE:
case '--pivot-mode':
  options.pivotMode = consumeValue(args, index, token);
  index += 1;
  break;
case '--pivot-model':
  options.pivotModel = consumeValue(args, index, token);
  index += 1;
  break;
```

- [ ] **Step 3: Remove pivot prompt template from init_ralph_desk.zsh**

Remove the entire pivot prompt section (starts with `# --- Pivot Prompt ---` around line 609, ends with the closing `fi` around line 660).

Remove pivot files from re-execution cleanup (lines 282-283):
```bash
# DELETE these from the cleanup list:
"$DESK/memos/$SLUG-pivot-signal.json" \
"$DESK/memos/$SLUG-pivot-review.md"
```

Remove pivot prompt from prompt cleanup (line 298):
```bash
# DELETE:
"$DESK/prompts/$SLUG.pivot.prompt.md"
```

Remove `--pivot-mode` and `--pivot-model` from `print_run_presets()` options reference.

- [ ] **Step 4: Remove pivot flags from rlp-desk.md options reference**

Remove `--pivot-mode` and `--pivot-model` lines from both codex-installed and codex-not-installed options blocks.

- [ ] **Step 5: Delete test-pivot-step.mjs**

```bash
rm tests/node/test-pivot-step.mjs
```

- [ ] **Step 6: Fix us008 test regression**

`tests/node/us008-cli-entrypoint.test.mjs` has a deepEqual check on RUN_DEFAULTS that includes pivotMode/pivotModel. Update to remove them.

- [ ] **Step 7: Verify removal is clean**

```bash
# No pivot references should remain (except blueprint doc):
grep -r "pivot" src/ tests/node/ --include="*.mjs" --include="*.zsh" --include="*.md" -l
# Expected: only docs/blueprints/blueprint-pivot-step.md
```

```bash
zsh -n src/scripts/init_ralph_desk.zsh && echo "SYNTAX OK"
node --test tests/node/us007-analytics-reporting.test.mjs
node --test tests/node/us008-cli-entrypoint.test.mjs
node --test tests/node/test-sv-report.mjs
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: remove incomplete pivot step implementation"
```

---

### Task 2: Add flywheel CLI flags + shouldRunFlywheel logic

**Files:**
- Modify: `src/node/run.mjs`
- Modify: `src/node/runner/campaign-main-loop.mjs`
- Create: `tests/node/test-flywheel.mjs`

- [ ] **Step 1: Write failing tests**

Create `tests/node/test-flywheel.mjs`:

```javascript
import test from 'node:test';
import assert from 'node:assert/strict';

test('T1: shouldRunFlywheel returns false when flywheel=off', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('off', { consecutive_failures: 3 }), false);
});

test('T2: shouldRunFlywheel returns true when flywheel=on-fail and consecutive_failures > 0', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('on-fail', { consecutive_failures: 1 }), true);
});

test('T3: shouldRunFlywheel returns false when flywheel=on-fail and consecutive_failures=0', async () => {
  const { shouldRunFlywheel } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunFlywheel('on-fail', { consecutive_failures: 0 }), false);
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel.mjs
```
Expected: FAIL (shouldRunFlywheel not exported)

- [ ] **Step 3: Implement shouldRunFlywheel + CLI flags**

In `src/node/runner/campaign-main-loop.mjs`, add:
```javascript
export function shouldRunFlywheel(flywheelMode, state) {
  if (flywheelMode === 'off') return false;
  if (flywheelMode === 'on-fail' && (state.consecutive_failures ?? 0) > 0) return true;
  return false;
}
```

In `src/node/run.mjs`, add defaults:
```javascript
flywheel: 'off',
flywheelModel: 'opus',
```

Add to help text:
```javascript
'  --flywheel off|on-fail',
'  --flywheel-model MODEL',
```

Add to flag parser:
```javascript
case '--flywheel':
  options.flywheel = consumeValue(args, index, token);
  index += 1;
  break;
case '--flywheel-model':
  options.flywheelModel = consumeValue(args, index, token);
  index += 1;
  break;
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
node --test tests/node/test-flywheel.mjs
```
Expected: 3 PASS

- [ ] **Step 5: Commit**

```bash
git add src/node/run.mjs src/node/runner/campaign-main-loop.mjs tests/node/test-flywheel.mjs
git commit -m "feat: add --flywheel flag and shouldRunFlywheel logic"
```

---

### Task 3: Flywheel prompt template in init_ralph_desk.zsh

**Files:**
- Modify: `src/scripts/init_ralph_desk.zsh`
- Modify: `tests/node/test-flywheel.mjs` (add prompt tests)

- [ ] **Step 1: Write failing tests**

Add to `tests/node/test-flywheel.mjs`:

```javascript
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

test('T4: init generates flywheel prompt with 6 review steps', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /Premise Challenge/);
  assert.match(content, /Existing Code Leverage/);
  assert.match(content, /Ideal State Mapping/);
  assert.match(content, /Implementation Alternatives/);
  assert.match(content, /Scope Decision/);
  assert.match(content, /Contract Rewrite/);
});

test('T5: flywheel prompt contains 10 CEO cognitive patterns', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /First-principles/);
  assert.match(content, /10x check/);
  assert.match(content, /Inversion/);
  assert.match(content, /Simplicity bias/);
  assert.match(content, /User-back/);
  assert.match(content, /Time-value/);
  assert.match(content, /Sunk cost immunity/);
  assert.match(content, /Blast radius/);
  assert.match(content, /Reversibility/);
  assert.match(content, /Evidence > opinion/);
});

test('T6: flywheel prompt contains 4 scope decisions', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /HOLD.*current approach/i);
  assert.match(content, /PIVOT.*alternative/i);
  assert.match(content, /REDUCE.*simplif/i);
  assert.match(content, /EXPAND.*missing/i);
});

test('T7: flywheel prompt writes to flywheel-signal.json', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheel-signal\.json/);
});

test('T8: flywheel prompt records rejected directions', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /Rejected Directions/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel.mjs
```
Expected: T1-T3 PASS, T4-T8 FAIL

- [ ] **Step 3: Add flywheel prompt template to init_ralph_desk.zsh**

After the Verifier prompt section, add:

```bash
# --- Flywheel Prompt ---
F="$DESK/prompts/$SLUG.flywheel.prompt.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<'FLYWHEEL_EOF'
# Flywheel Direction Review

You are an independent direction reviewer with fresh context. After a Worker iteration failed verification, you decide whether the current approach should continue, pivot, or change scope.

## Context Files
Read these in order:
1. Campaign Memory: {DESK}/memos/{SLUG}-memory.md — especially Next Iteration Contract, Key Decisions, Rejected Directions
2. PRD: {DESK}/plans/prd-{SLUG}.md — acceptance criteria
3. Done Claim: {DESK}/memos/{SLUG}-done-claim.json — what Worker actually did
4. Verify Verdict: {DESK}/memos/{SLUG}-verify-verdict.json — why Verifier failed it
5. Latest Context: {DESK}/context/{SLUG}-latest.md — current state

## CEO Cognitive Patterns (apply throughout your review)
1. First-principles — ignore convention, start from the problem itself
2. 10x check — can 2x effort yield 10x better result?
3. Inversion — what must be true for this approach to fail?
4. Simplicity bias — prefer simple over complex solutions
5. User-back — reason backwards from end-user experience
6. Time-value — does this direction change save 3+ iterations?
7. Sunk cost immunity — ignore what was already invested
8. Blast radius — assess impact scope of direction change
9. Reversibility — prefer easily reversible decisions
10. Evidence > opinion — judge only by this iteration's actual results

## Review Process

### Step 0A: Premise Challenge
List every assumption the current approach depends on.
For each assumption, state whether THIS iteration's evidence supports or contradicts it.
- Supported: "Assumption X — SUPPORTED: [evidence from done-claim/verdict]"
- Contradicted: "Assumption X — BROKEN: [evidence]. This means [implication]."
If any premise is broken, PIVOT or REDUCE is likely the right call.

### Step 0B: Existing Code Leverage
- Did the Worker miss reusable code that already exists in the project?
- Would a different approach align better with existing patterns?
- Check: are there utilities, helpers, or patterns the Worker could have used?

### Step 0C: Ideal State Mapping
Describe what this US looks like when perfectly implemented (2-3 sentences).
How far is the current approach from this ideal? What is the gap?

### Step 0D: Implementation Alternatives (MANDATORY)
Propose at least 2 alternative approaches. For each:
- Summary (1-2 sentences)
- Effort: S (< 1 iteration) / M (1-2 iterations) / L (3+ iterations)
- Risk: low / medium / high
- Key tradeoff vs current approach

Do NOT skip this step. Even if the current approach seems correct, articulate alternatives.

### Step 0E: Scope Decision
Choose ONE. Justify with evidence from this iteration only:
- **HOLD**: Premises valid, approach correct. Refine the contract with specific fixes: "[fix 1], [fix 2]"
- **PIVOT**: Premise [X] broken. Switch to Alternative [A]. Reason: [evidence]
- **REDUCE**: AC [N] too complex at current scope. Split into [parts] or simplify to [simpler version]
- **EXPAND**: Missing prerequisite [Y] discovered. Add to contract: [what to add]

### Step 0F: Contract Rewrite
Based on your decision, update campaign memory:
1. Rewrite "Next Iteration Contract" with the new direction
2. Append your decision and reasoning to "Key Decisions"
3. If rejecting an approach, append to "Rejected Directions" section:
   "DO NOT retry: [approach description]. Reason: [why it failed]. Evidence: [from iteration N]."
   The next Worker MUST read Rejected Directions before starting.

## Output Files

1. Write analysis to: {DESK}/memos/{SLUG}-flywheel-review.md
2. Update campaign memory: {DESK}/memos/{SLUG}-memory.md
3. Write signal: {DESK}/memos/{SLUG}-flywheel-signal.json
   Format: {"iteration": N, "decision": "hold|pivot|reduce|expand", "summary": "one line", "rejected_directions": ["approach X because Y"], "contract_updated": true, "timestamp": "ISO"}
FLYWHEEL_EOF

  # Replace placeholders with actual paths
  sed -i '' "s|{DESK}|$DESK|g; s|{SLUG}|$SLUG|g" "$F"

  echo "  + $F"
else echo "  · $F"; fi
```

Also add flywheel files to re-execution cleanup and add `--flywheel` flags to `print_run_presets()` options reference.

- [ ] **Step 4: Run tests to verify they pass**

```bash
zsh -n src/scripts/init_ralph_desk.zsh && echo "SYNTAX OK"
node --test tests/node/test-flywheel.mjs
```
Expected: T1-T8 all PASS, syntax OK

- [ ] **Step 5: Commit**

```bash
git add src/scripts/init_ralph_desk.zsh tests/node/test-flywheel.mjs
git commit -m "feat: add flywheel prompt template with 6-step CEO framework"
```

---

### Task 4: Wire flywheel into campaign-main-loop.mjs

**Files:**
- Modify: `src/node/runner/campaign-main-loop.mjs`
- Modify: `tests/node/test-flywheel.mjs` (add wiring tests)

- [ ] **Step 1: Write failing tests**

Add to `tests/node/test-flywheel.mjs`:

```javascript
test('T9: buildPaths includes flywheel paths', async () => {
  // buildPaths is not exported, so test indirectly via init+run
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheelPromptFile/);
  assert.match(content, /flywheelSignalFile/);
});

test('T10: flywheel dispatch exists for both tmux and agent modes', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /dispatchFlywheel/);
  assert.match(content, /phase.*flywheel/i);
});

test('T11: flywheel runs BEFORE worker in the loop', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  const flywheelPos = content.indexOf('shouldRunFlywheel');
  const workerPos = content.indexOf('dispatchWorker', flywheelPos);
  assert.ok(flywheelPos < workerPos, 'flywheel check must appear before worker dispatch');
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel.mjs
```
Expected: T1-T8 PASS, T9-T11 FAIL

- [ ] **Step 3: Implement flywheel wiring**

In `campaign-main-loop.mjs`:

Add to `buildPaths()`:
```javascript
flywheelPromptFile: path.join(deskRoot, 'prompts', `${slug}.flywheel.prompt.md`),
flywheelSignalFile: path.join(deskRoot, 'memos', `${slug}-flywheel-signal.json`),
```

Add `buildFlywheelTriggerCmd()`:
```javascript
function buildFlywheelTriggerCmd({ flywheelPromptFile, flywheelModel, rootDir }) {
  return `cd ${JSON.stringify(rootDir)} && DISABLE_OMC=1 claude --model ${flywheelModel} --no-mcp -p "$(cat ${JSON.stringify(flywheelPromptFile)})"`;
}
```

Add `dispatchFlywheel()`:
```javascript
async function dispatchFlywheel({ paths, sendKeys, flywheelPaneId, flywheelModel, rootDir }) {
  const triggerCmd = buildFlywheelTriggerCmd({
    flywheelPromptFile: paths.flywheelPromptFile,
    flywheelModel,
    rootDir,
  });
  await sendKeys({ targetPaneId: flywheelPaneId, keys: triggerCmd });
}
```

In the main `while` loop, AFTER verdict handling and BEFORE `dispatchWorker`, insert:
```javascript
// Flywheel direction review (runs BEFORE Worker)
if (shouldRunFlywheel(options.flywheel ?? 'off', state)) {
  state.phase = 'flywheel';
  await writeStatus(paths, state, options.onStatusChange, options.now);

  await dispatchFlywheel({
    paths,
    sendKeys,
    flywheelPaneId: state.flywheel_pane_id ?? state.verifier_pane_id,
    flywheelModel: options.flywheelModel ?? 'opus',
    rootDir,
  });

  const flywheelSignal = await pollForSignal(paths.flywheelSignalFile, {
    mode: 'claude',
    paneId: state.flywheel_pane_id ?? state.verifier_pane_id,
  });

  state.last_flywheel_decision = flywheelSignal.decision;
  // Campaign memory already updated by flywheel agent
  // Clean signal file for next iteration
  await fs.unlink(paths.flywheelSignalFile).catch(() => {});
}

state.phase = 'worker';
// ... existing dispatchWorker code
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
node --test tests/node/test-flywheel.mjs
```
Expected: T1-T11 all PASS

- [ ] **Step 5: Run regression tests**

```bash
node --test tests/node/us007-analytics-reporting.test.mjs
node --test tests/node/us008-cli-entrypoint.test.mjs
node --test tests/node/test-sv-report.mjs
```
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add src/node/runner/campaign-main-loop.mjs tests/node/test-flywheel.mjs
git commit -m "feat: wire flywheel into campaign loop (before worker, after verify fail)"
```

---

### Task 5: 3-pane tmux layout + flywheel flags in docs

**Files:**
- Modify: `src/scripts/init_ralph_desk.zsh` (print_run_presets)
- Modify: `src/commands/rlp-desk.md` (options reference + flywheel docs)
- Modify: `src/node/runner/campaign-main-loop.mjs` (3rd pane creation)
- Modify: `tests/node/test-flywheel.mjs` (add docs tests)

- [ ] **Step 1: Write failing tests**

Add to `tests/node/test-flywheel.mjs`:

```javascript
test('T12: rlp-desk.md options reference includes flywheel flags', async () => {
  const content = await fs.readFile(path.join(repoRoot, 'src', 'commands', 'rlp-desk.md'), 'utf8');
  assert.match(content, /--flywheel off\|on-fail/);
  assert.match(content, /--flywheel-model MODEL/);
});

test('T13: init presets include flywheel in options reference', async () => {
  const content = await fs.readFile(path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh'), 'utf8');
  assert.match(content, /--flywheel off\|on-fail/);
  assert.match(content, /--flywheel-model MODEL/);
});

test('T14: campaign-main-loop creates flywheel pane in tmux mode', async () => {
  const content = await fs.readFile(path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs'), 'utf8');
  assert.match(content, /flywheel_pane_id/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel.mjs
```
Expected: T1-T11 PASS, T12-T14 FAIL

- [ ] **Step 3: Add flywheel flags to options references**

In `src/commands/rlp-desk.md`, add to BOTH codex-installed and codex-not-installed options blocks:
```
#   --flywheel off|on-fail                 direction review on fail (default: off)
#   --flywheel-model MODEL                 flywheel reviewer model (default: opus)
```

In `src/scripts/init_ralph_desk.zsh` `print_run_presets()`, add to the options reference echo block:
```bash
echo "#   --flywheel off|on-fail                 direction review on fail (default: off)"
echo "#   --flywheel-model MODEL                 flywheel reviewer model (default: opus)"
```

- [ ] **Step 4: Add 3rd pane creation in tmux mode**

In `campaign-main-loop.mjs`, in the session creation block (around line 440):
```javascript
state.flywheel_pane_id = await createPane({
  targetPaneId: session.leaderPaneId,
  layout: 'horizontal',
});
state.worker_pane_id = await createPane({
  targetPaneId: session.leaderPaneId,
  layout: 'horizontal',
});
state.verifier_pane_id = await createPane({
  targetPaneId: session.leaderPaneId,
  layout: 'vertical',
});
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
node --test tests/node/test-flywheel.mjs
zsh -n src/scripts/init_ralph_desk.zsh && echo "SYNTAX OK"
```
Expected: T1-T14 all PASS, syntax OK

- [ ] **Step 6: Run full regression**

```bash
node --test tests/node/*.mjs tests/node/*.test.mjs 2>&1 | tail -5
```
Expected: 0 failures

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: flywheel 3-pane tmux layout + flags in docs and presets"
```

---

### Task 6: Self-verification (3 scenarios)

**Files:** none modified — verification only

- [ ] **Step 1: Scenario LOW — flywheel off**

```bash
SV_DIR=$(mktemp -d) && cd "$SV_DIR" && git init -q
mkdir -p .claude/ralph-desk
zsh /path/to/src/scripts/init_ralph_desk.zsh "sv-flywheel-off" "test"
# Verify: flywheel prompt generated but loop unchanged when --flywheel off
grep -q "flywheel" .claude/ralph-desk/prompts/sv-flywheel-off.flywheel.prompt.md && echo "PASS: prompt exists"
# Verify no flywheel pane created when off (Agent mode default)
rm -rf "$SV_DIR"
```

- [ ] **Step 2: Scenario MEDIUM — flywheel on-fail + FAIL triggers flywheel**

Run actual Worker → Verifier → Flywheel → Worker sequence:
1. Init campaign in test project
2. Worker agent implements (intentionally incomplete)
3. Verifier FAIL
4. Flywheel agent runs direction review
5. Verify: flywheel-signal.json written with decision
6. Verify: campaign memory updated with Key Decisions + Rejected Directions
7. Next Worker reads updated contract

- [ ] **Step 3: Scenario CRITICAL — PIVOT decision propagation**

1. Force a PIVOT decision from flywheel
2. Verify: Rejected Directions section in memory has the old approach
3. Verify: Next Iteration Contract is rewritten (not just patched)
4. Verify: Next Worker's done-claim shows a different approach

- [ ] **Step 4: Record results**

All 3 scenarios must PASS. Record in commit message.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: flywheel direction review — verified with 3 self-verification scenarios

Flywheel adds a CEO-framework direction review step that runs after Verifier FAIL
and before the next Worker. Internalizes premise challenge, forced alternatives,
scope decisions (HOLD/PIVOT/REDUCE/EXPAND), and 10 CEO cognitive patterns.

Self-verified: LOW (off mode), MEDIUM (on-fail trigger), CRITICAL (PIVOT propagation)."
```

---

### Task 7: Local sync + docs

**Files:**
- Sync all distributable files to `~/.claude/`

- [ ] **Step 1: Local file sync**

```bash
cp src/commands/rlp-desk.md ~/.claude/commands/rlp-desk.md
cp src/governance.md ~/.claude/ralph-desk/governance.md
cp src/scripts/init_ralph_desk.zsh ~/.claude/ralph-desk/init_ralph_desk.zsh
cp src/scripts/run_ralph_desk.zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
cp src/scripts/lib_ralph_desk.zsh ~/.claude/ralph-desk/lib_ralph_desk.zsh
cp README.md ~/.claude/ralph-desk/README.md
```

- [ ] **Step 2: Verify sync**

```bash
diff -q src/commands/rlp-desk.md ~/.claude/commands/rlp-desk.md
diff -q src/governance.md ~/.claude/ralph-desk/governance.md
diff -q src/scripts/init_ralph_desk.zsh ~/.claude/ralph-desk/init_ralph_desk.zsh
diff -q src/scripts/run_ralph_desk.zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
diff -q src/scripts/lib_ralph_desk.zsh ~/.claude/ralph-desk/lib_ralph_desk.zsh
diff -q README.md ~/.claude/ralph-desk/README.md
```
All must produce no output.
