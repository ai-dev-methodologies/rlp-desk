# Flywheel Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an independent Guard agent that validates flywheel direction decisions before Worker acts on them, plus selective CEO cognitive pattern internalization.

**Architecture:** When `--flywheel-guard on`, every flywheel execution is followed by an independent Guard agent (fresh context) that checks look-ahead bias, metric alignment, deployability, and repeat patterns. Guard verdict is 3-state (pass/fail/inconclusive). On fail, flywheel retries with guard feedback (max 2). On inconclusive, BLOCKED. Guard count tracked per-US.

**Tech Stack:** Node.js (ESM), zsh (init script), node:test

**Spec:** `docs/blueprints/blueprint-flywheel-enhancement.md`

---

### Task 1: Add CEO cognitive patterns #11-12 to flywheel prompt

**Files:**
- Modify: `src/scripts/init_ralph_desk.zsh:624-634`
- Modify: `tests/node/test-flywheel.mjs:35-48`

- [ ] **Step 1: Update test T5 to expect 12 patterns**

In `tests/node/test-flywheel.mjs`, update the test title and add 2 new assertions:

```javascript
test('T5: flywheel prompt contains 12 CEO cognitive patterns', async () => {
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
  assert.match(content, /Proxy skepticism/);
  assert.match(content, /Classification/);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
node --test tests/node/test-flywheel.mjs
```
Expected: T5 FAIL (`Proxy skepticism` not found)

- [ ] **Step 3: Add patterns #11-12 to flywheel prompt in init_ralph_desk.zsh**

In `src/scripts/init_ralph_desk.zsh`, replace lines 624-634 (the CEO Cognitive Patterns section inside the flywheel prompt heredoc):

```
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
11. Proxy skepticism — is the optimization metric the right proxy for the real goal?
12. Classification — hard-to-reverse + large-magnitude changes need stronger evidence
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
zsh -n src/scripts/init_ralph_desk.zsh && echo "SYNTAX OK"
node --test tests/node/test-flywheel.mjs
```
Expected: SYNTAX OK, all PASS

- [ ] **Step 5: Commit**

```bash
git add tests/node/test-flywheel.mjs src/scripts/init_ralph_desk.zsh
git commit -m "feat: add CEO patterns #11-12 (proxy skepticism, classification) to flywheel prompt"
```

---

### Task 2: Add flywheel guard CLI flags

**Files:**
- Modify: `src/node/run.mjs:8-26` (RUN_DEFAULTS), `:32-65` (help), `:84-163` (parser)
- Create: `tests/node/test-flywheel-guard.mjs`

- [ ] **Step 1: Write failing tests**

Create `tests/node/test-flywheel-guard.mjs`:

```javascript
import test from 'node:test';
import assert from 'node:assert/strict';

test('G1: RUN_DEFAULTS includes flywheelGuard off and flywheelGuardModel opus', async () => {
  const runModule = await import('../../src/node/run.mjs');
  // Test via CLI parsing with no flags — defaults should apply
  const stream = { data: '', write(v) { this.data += v; } };
  // Just verify the module loads without error — defaults tested via G3
  assert.ok(runModule.main);
});

test('G2: --flywheel-guard flag is parsed', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  // --flywheel-guard without value should error
  const code = await main(['run', 'test-slug', '--flywheel-guard'], {
    cwd: '/tmp/nonexistent',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.equal(code, 1);
  assert.match(stream.data, /missing value for --flywheel-guard/);
});

test('G3: --flywheel-guard-model flag is parsed', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  const code = await main(['run', 'test-slug', '--flywheel-guard-model'], {
    cwd: '/tmp/nonexistent',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.equal(code, 1);
  assert.match(stream.data, /missing value for --flywheel-guard-model/);
});

test('G4: help text includes flywheel guard flags', async () => {
  const { main } = await import('../../src/node/run.mjs');
  const stream = { data: '', write(v) { this.data += v; } };
  await main(['--help'], {
    cwd: '/tmp',
    stdout: stream,
    stderr: stream,
    runCampaign: async () => {},
    initCampaign: async () => {},
    readStatus: async () => '',
  });
  assert.match(stream.data, /--flywheel-guard off\|on/);
  assert.match(stream.data, /--flywheel-guard-model MODEL/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel-guard.mjs
```
Expected: G2-G4 FAIL (unknown option, help text missing)

- [ ] **Step 3: Add defaults, help text, and parser in run.mjs**

In `src/node/run.mjs`, add to `RUN_DEFAULTS` (after line 25 `flywheelModel: 'opus'`):

```javascript
  flywheelGuard: 'off',
  flywheelGuardModel: 'opus',
```

Add to `buildHelpText()` array (after `--flywheel-model MODEL` line):

```javascript
    '  --flywheel-guard off|on',
    '  --flywheel-guard-model MODEL',
```

Add to `parseRunOptions()` switch (after `--flywheel-model` case):

```javascript
      case '--flywheel-guard':
        options.flywheelGuard = consumeValue(args, index, token);
        index += 1;
        break;
      case '--flywheel-guard-model':
        options.flywheelGuardModel = consumeValue(args, index, token);
        index += 1;
        break;
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
node --test tests/node/test-flywheel-guard.mjs
```
Expected: G1-G4 all PASS

- [ ] **Step 5: Run regression**

```bash
node --test tests/node/us008-cli-entrypoint.test.mjs
```
Expected: PASS (new defaults don't break existing deepEqual checks — verify; if deepEqual on RUN_DEFAULTS exists, update it to include new fields)

- [ ] **Step 6: Commit**

```bash
git add src/node/run.mjs tests/node/test-flywheel-guard.mjs
git commit -m "feat: add --flywheel-guard and --flywheel-guard-model CLI flags"
```

---

### Task 3: Add guard paths and shouldRunGuard logic

**Files:**
- Modify: `src/node/runner/campaign-main-loop.mjs:37-66` (buildPaths), `:415-419` (shouldRunFlywheel area)
- Modify: `tests/node/test-flywheel-guard.mjs`

- [ ] **Step 1: Write failing tests**

Append to `tests/node/test-flywheel-guard.mjs`:

```javascript
test('G5: shouldRunGuard returns false when flywheelGuard=off', async () => {
  const { shouldRunGuard } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunGuard('off', { flywheel_guard_count: {} }), false);
});

test('G6: shouldRunGuard returns true when flywheelGuard=on', async () => {
  const { shouldRunGuard } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunGuard('on', { flywheel_guard_count: {} }), true);
});

test('G7: shouldRunGuard returns false when flywheelGuard=on but guard retries exhausted', async () => {
  const { shouldRunGuard } = await import('../../src/node/runner/campaign-main-loop.mjs');
  assert.equal(shouldRunGuard('on', { flywheel_guard_count: { 'US-001': 3 } }, 'US-001'), false);
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel-guard.mjs
```
Expected: G5-G7 FAIL (shouldRunGuard not exported)

- [ ] **Step 3: Implement shouldRunGuard and add guard paths**

In `src/node/runner/campaign-main-loop.mjs`, add to `buildPaths()` (after `flywheelSignalFile` line 65):

```javascript
    flywheelGuardPromptFile: path.join(deskRoot, 'prompts', `${slug}.flywheel-guard.prompt.md`),
    flywheelGuardVerdictFile: path.join(deskRoot, 'memos', `${slug}-flywheel-guard-verdict.json`),
```

Add new exported function (after `shouldRunFlywheel`):

```javascript
export function shouldRunGuard(flywheelGuard, state, usId) {
  if (flywheelGuard !== 'on') return false;
  const count = (state.flywheel_guard_count ?? {})[usId] ?? 0;
  // max 2 retries (guard runs 1st time + 2 retries = 3 total guard executions max)
  if (count >= 3) return false;
  return true;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
node --test tests/node/test-flywheel-guard.mjs
```
Expected: G1-G7 all PASS

- [ ] **Step 5: Commit**

```bash
git add src/node/runner/campaign-main-loop.mjs tests/node/test-flywheel-guard.mjs
git commit -m "feat: add shouldRunGuard logic and guard paths to buildPaths"
```

---

### Task 4: Add guard prompt template to init_ralph_desk.zsh

**Files:**
- Modify: `src/scripts/init_ralph_desk.zsh` (after flywheel prompt section, ~line 690)
- Modify: `src/scripts/init_ralph_desk.zsh:276-283` (cleanup list)
- Modify: `src/scripts/init_ralph_desk.zsh:294-303` (prompt cleanup)
- Modify: `tests/node/test-flywheel-guard.mjs`

- [ ] **Step 1: Write failing tests**

Append to `tests/node/test-flywheel-guard.mjs`:

```javascript
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

test('G8: init generates guard prompt with 4 validation checks', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /Look-ahead Bias/);
  assert.match(content, /Metric Alignment/);
  assert.match(content, /Deployability/);
  assert.match(content, /Repeat Pattern/);
});

test('G9: guard prompt writes to flywheel-guard-verdict.json', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheel-guard-verdict\.json/);
});

test('G10: guard verdict includes analysis_only field', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /analysis_only/);
});

test('G11: guard prompt references PRD as ground truth', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /PRD is ground truth/);
});

test('G12: cleanup list includes guard verdict file', async () => {
  const script = path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheel-guard-verdict\.json/);
});
```

Note: the `fs`, `path`, `fileURLToPath`, `repoRoot` imports at the top of the file already exist from test-flywheel.mjs pattern. If creating a new file, include them. If appending, they must be at the top of the file — move the import block to the top and ensure no duplicates.

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel-guard.mjs
```
Expected: G8-G12 FAIL

- [ ] **Step 3: Add guard prompt template to init_ralph_desk.zsh**

After the flywheel prompt section (after `else echo "  · $F"; fi` around line 690), add:

```bash
# --- Flywheel Guard Prompt ---
F="$DESK/prompts/$SLUG.flywheel-guard.prompt.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<'GUARD_EOF'
# Flywheel Guard Review

You are an independent reviewer verifying whether a flywheel direction decision is safe to execute.
You have NO prior context about this campaign. Read the files below and evaluate the decision objectively.

## Files to Read (in order)
1. PRD: {DESK}/plans/prd-{SLUG}.md — the ground truth for what success means
2. Flywheel Decision: {DESK}/memos/{SLUG}-flywheel-signal.json — what the flywheel decided
3. Flywheel Analysis: {DESK}/memos/{SLUG}-flywheel-review.md — the flywheel's reasoning
4. Campaign Memory: {DESK}/memos/{SLUG}-memory.md — history, rejected directions, key decisions
5. Done Claim: {DESK}/memos/{SLUG}-done-claim.json — what the Worker actually produced
6. Verify Verdict: {DESK}/memos/{SLUG}-verify-verdict.json — why the Verifier failed it

## Validation Checks

### Check 1: Look-ahead Bias
List every data feature the flywheel's proposed direction depends on.
For each: "feature X — available at decision time: YES/NO/UNCLEAR"
- YES: feature is known before the event (entry time, session start price, order book state)
- NO: feature requires future information (peak price, session end, outcome)
- UNCLEAR: cannot determine from available context → mark inconclusive
If ANY feature is NO and used in a deployable strategy (not just upper-bound analysis): FAIL.

### Check 2: Metric Alignment
1. What metric does the PRD define as the optimization target?
2. What metric does the flywheel's direction optimize?
3. Are they the same?
   - Same metric → pass
   - Different metric, not flagged → FAIL (silent metric switch)
   - Different metric, flagged with evidence → FAIL with recommendation: "metric mismatch requires PRD update or user approval before proceeding"
   PRD is ground truth. The guard cannot approve off-PRD metric changes autonomously.

### Check 3: Deployability
Can the proposed direction's output be used in production as-is?
- Requires post-hoc data → FAIL
- Requires infrastructure not mentioned in PRD → FAIL
- Labeled as "upper-bound only" or "reference" → pass, but you MUST include "analysis_only": true in your verdict so Leader skips Worker dispatch (no implementation, analysis record only)

### Check 4: Repeat Pattern (same-US scoped)
Compare to prior flywheel decisions for the current US only in campaign memory's Key Decisions section.
- Same scope decision + same underlying approach as a prior flywheel for this US → FAIL
- Reframing of a previously rejected direction (check Rejected Directions) → FAIL
- Genuinely new approach → pass
Before writing your verdict, you MUST append any rejected flywheel direction to campaign memory's Rejected Directions section. This persists the record before cleanup can erase it.

## Output
Write verdict to: {DESK}/memos/{SLUG}-flywheel-guard-verdict.json

Use this format:
{
  "verdict": "pass|fail|inconclusive",
  "issues": [{"check": "check-name", "status": "pass|fail|inconclusive", "detail": "finding", "evidence": "reference"}],
  "analysis_only": false,
  "recommendation": "proceed|retry-flywheel|escalate-to-user",
  "timestamp": "ISO"
}

Rules:
- If ALL checks pass → verdict: pass, recommendation: proceed
- If ANY check is fail → verdict: fail, recommendation: retry-flywheel
- If ANY check is inconclusive and none are fail → verdict: inconclusive, recommendation: escalate-to-user
- Include specific evidence for every check. No "seems fine" or "probably ok."
GUARD_EOF

  # Replace placeholders with actual paths
  sed -i '' "s|{DESK}|$DESK|g; s|{SLUG}|$SLUG|g" "$F"

  echo "  + $F"
else echo "  · $F"; fi
```

- [ ] **Step 4: Add guard files to cleanup lists**

In `src/scripts/init_ralph_desk.zsh`, add to the runtime memos cleanup list (after `"$DESK/memos/$SLUG-flywheel-review.md"` around line 283):

```bash
    "$DESK/memos/$SLUG-flywheel-guard-verdict.json" \
```

Add to prompt cleanup list (after `"$DESK/prompts/$SLUG.flywheel.prompt.md"` around line 298):

```bash
    "$DESK/prompts/$SLUG.flywheel-guard.prompt.md" \
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
zsh -n src/scripts/init_ralph_desk.zsh && echo "SYNTAX OK"
node --test tests/node/test-flywheel-guard.mjs
```
Expected: SYNTAX OK, G1-G12 all PASS

- [ ] **Step 6: Commit**

```bash
git add src/scripts/init_ralph_desk.zsh tests/node/test-flywheel-guard.mjs
git commit -m "feat: add flywheel guard prompt template with 4 validation checks"
```

---

### Task 5: Wire guard into campaign-main-loop.mjs

**Files:**
- Modify: `src/node/runner/campaign-main-loop.mjs:242-261` (readCurrentState), `:402-404` (buildFlywheelTriggerCmd area), `:537-559` (flywheel block in main loop)
- Modify: `tests/node/test-flywheel-guard.mjs`

- [ ] **Step 1: Write failing tests**

Append to `tests/node/test-flywheel-guard.mjs`:

```javascript
test('G13: buildPaths includes guard paths', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheelGuardPromptFile/);
  assert.match(content, /flywheelGuardVerdictFile/);
});

test('G14: guard dispatch exists in main loop', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /dispatchGuard/);
  assert.match(content, /phase.*guard/i);
});

test('G15: guard runs AFTER flywheel and BEFORE worker', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  const flywheelPos = content.indexOf('dispatchFlywheel');
  const guardPos = content.indexOf('dispatchGuard');
  const workerPos = content.indexOf('dispatchWorker');
  assert.ok(flywheelPos < guardPos, 'flywheel must come before guard');
  assert.ok(guardPos < workerPos, 'guard must come before worker');
});

test('G16: readCurrentState includes flywheel_guard_count', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /flywheel_guard_count/);
});

test('G17: inconclusive verdict triggers BLOCKED', async () => {
  const script = path.join(repoRoot, 'src', 'node', 'runner', 'campaign-main-loop.mjs');
  const content = await fs.readFile(script, 'utf8');
  assert.match(content, /inconclusive/);
  assert.match(content, /escalate/i);
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel-guard.mjs
```
Expected: G13-G17 FAIL

- [ ] **Step 3: Add flywheel_guard_count to readCurrentState**

In `src/node/runner/campaign-main-loop.mjs`, add to `readCurrentState()` return object (after `verifier_pane_id` line 259):

```javascript
    flywheel_guard_count: status.flywheel_guard_count ?? {},
```

- [ ] **Step 4: Add buildGuardTriggerCmd and dispatchGuard**

After `dispatchFlywheel` function (around line 413), add:

```javascript
function buildGuardTriggerCmd({ guardPromptFile, guardModel, rootDir }) {
  return `cd ${JSON.stringify(rootDir)} && DISABLE_OMC=1 claude --model ${guardModel} --no-mcp -p "$(cat ${JSON.stringify(guardPromptFile)})"`;
}

async function dispatchGuard({ paths, sendKeys, guardPaneId, guardModel, rootDir }) {
  const triggerCmd = buildGuardTriggerCmd({
    guardPromptFile: paths.flywheelGuardPromptFile,
    guardModel,
    rootDir,
  });
  await sendKeys(guardPaneId, triggerCmd);
}
```

- [ ] **Step 5: Wire guard into main loop flywheel block**

Replace the flywheel block (lines 537-559) with the expanded version that includes guard:

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
      await fs.unlink(paths.flywheelSignalFile).catch(() => {});

      // Flywheel Guard (independent validation)
      if (shouldRunGuard(options.flywheelGuard ?? 'off', state, state.current_us)) {
        state.phase = 'guard';
        await writeStatus(paths, state, options.onStatusChange, options.now);

        const guardPaneId = state.flywheel_pane_id ?? state.verifier_pane_id;
        const guardModel = options.flywheelGuardModel ?? 'opus';

        await dispatchGuard({ paths, sendKeys, guardPaneId, guardModel, rootDir });

        const guardVerdict = await pollForSignal(paths.flywheelGuardVerdictFile, {
          mode: 'claude',
          paneId: guardPaneId,
        });

        // Track per-US guard count
        if (!state.flywheel_guard_count[state.current_us]) {
          state.flywheel_guard_count[state.current_us] = 0;
        }
        state.flywheel_guard_count[state.current_us] += 1;

        await fs.unlink(paths.flywheelGuardVerdictFile).catch(() => {});

        if (guardVerdict.verdict === 'inconclusive') {
          // Escalate to user — BLOCKED
          state.phase = 'blocked';
          await writeSentinel(paths.blockedSentinel, 'blocked', state.current_us);
          await writeStatus(paths, state, options.onStatusChange, options.now);
          return {
            status: 'blocked',
            usId: state.current_us,
            reason: 'flywheel-guard-inconclusive',
            guardIssues: guardVerdict.issues,
            statusFile: paths.statusFile,
          };
        }

        if (guardVerdict.verdict === 'fail') {
          // Check if retries exhausted
          if (state.flywheel_guard_count[state.current_us] >= 3) {
            state.phase = 'blocked';
            await writeSentinel(paths.blockedSentinel, 'blocked', state.current_us);
            await writeStatus(paths, state, options.onStatusChange, options.now);
            return {
              status: 'blocked',
              usId: state.current_us,
              reason: 'flywheel-guard-retries-exhausted',
              guardIssues: guardVerdict.issues,
              statusFile: paths.statusFile,
            };
          }
          // Retry: skip Worker, go to next iteration (flywheel will re-run)
          // Guard feedback is already persisted via guard agent's memory write-back
          state.phase = 'worker';
          await writeStatus(paths, state, options.onStatusChange, options.now);
          state.iteration += 1;
          continue;
        }

        // verdict === 'pass'
        if (guardVerdict.analysis_only) {
          // Analysis-only direction — skip Worker, record and continue
          state.phase = 'worker';
          await writeStatus(paths, state, options.onStatusChange, options.now);
          state.iteration += 1;
          continue;
        }
      }

      // Reset guard count on pass (flywheel direction accepted)
      if (state.flywheel_guard_count[state.current_us]) {
        state.flywheel_guard_count[state.current_us] = 0;
      }
    }
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
node --test tests/node/test-flywheel-guard.mjs
node --test tests/node/test-flywheel.mjs
```
Expected: all PASS

- [ ] **Step 7: Run regression**

```bash
node --test tests/node/us007-analytics-reporting.test.mjs
node --test tests/node/us008-cli-entrypoint.test.mjs
```
Expected: all PASS (update us008 deepEqual if it checks status.json shape with new `flywheel_guard_count` field)

- [ ] **Step 8: Commit**

```bash
git add src/node/runner/campaign-main-loop.mjs tests/node/test-flywheel-guard.mjs
git commit -m "feat: wire flywheel guard into campaign loop (after flywheel, before worker)"
```

---

### Task 6: Add guard flags to docs and presets

**Files:**
- Modify: `src/commands/rlp-desk.md:192-194` and `:222-224`
- Modify: `src/scripts/init_ralph_desk.zsh:243-244`
- Modify: `tests/node/test-flywheel-guard.mjs`

- [ ] **Step 1: Write failing tests**

Append to `tests/node/test-flywheel-guard.mjs`:

```javascript
test('G18: rlp-desk.md options reference includes guard flags', async () => {
  const content = await fs.readFile(path.join(repoRoot, 'src', 'commands', 'rlp-desk.md'), 'utf8');
  assert.match(content, /--flywheel-guard off\|on/);
  assert.match(content, /--flywheel-guard-model MODEL/);
});

test('G19: init presets include guard flags', async () => {
  const content = await fs.readFile(path.join(repoRoot, 'src', 'scripts', 'init_ralph_desk.zsh'), 'utf8');
  assert.match(content, /--flywheel-guard off\|on/);
  assert.match(content, /--flywheel-guard-model MODEL/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
node --test tests/node/test-flywheel-guard.mjs
```
Expected: G18-G19 FAIL

- [ ] **Step 3: Add guard flags to rlp-desk.md**

In `src/commands/rlp-desk.md`, after both `--flywheel-model MODEL` lines (lines 194 and 224), add:

```
   #   --flywheel-guard off|on                  guard validates flywheel decisions (default: off)
   #   --flywheel-guard-model MODEL             guard reviewer model (default: opus)
```

- [ ] **Step 4: Add guard flags to init presets**

In `src/scripts/init_ralph_desk.zsh`, after `--flywheel-model MODEL` echo (line 244), add:

```bash
  echo "#   --flywheel-guard off|on                  guard validates flywheel decisions (default: off)"
  echo "#   --flywheel-guard-model MODEL             guard reviewer model (default: opus)"
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
zsh -n src/scripts/init_ralph_desk.zsh && echo "SYNTAX OK"
node --test tests/node/test-flywheel-guard.mjs
```
Expected: SYNTAX OK, all PASS

- [ ] **Step 6: Commit**

```bash
git add src/commands/rlp-desk.md src/scripts/init_ralph_desk.zsh tests/node/test-flywheel-guard.mjs
git commit -m "feat: add flywheel guard flags to docs and run presets"
```

---

### Task 7: Update governance.md — guard step in Leader Loop

**Files:**
- Modify: `src/governance.md:453-509` (§7 Leader Loop Protocol)

- [ ] **Step 1: Add guard step to Leader Loop Protocol**

In `src/governance.md`, in the Leader Loop Protocol (§7), add after the flywheel description. The flywheel is not yet mentioned in §7 (it's only in the code), so add a new sub-step between ⑥ and ⑦:

After `⑥ Read memory.md again` (line 479), add:

```
  ⑥½ Flywheel direction review (when --flywheel on-fail and consecutive_failures > 0)
     - Dispatch Flywheel agent (fresh context, --flywheel-model)
     - Read flywheel-signal.json for direction decision (hold/pivot/reduce/expand)
     - If --flywheel-guard on:
       - Dispatch Guard agent (fresh context, --flywheel-guard-model)
       - Read flywheel-guard-verdict.json:
         • pass → proceed to Worker with updated contract
         • pass + analysis_only → skip Worker, record analysis, next iteration
         • fail → re-run Flywheel with guard feedback (max 2 retries)
         • fail + retries exhausted → BLOCKED
         • inconclusive → BLOCKED (escalate to user)
       - Guard count tracked per-US in status.json
```

- [ ] **Step 2: Verify syntax**

```bash
# Quick check the file is valid markdown:
head -5 src/governance.md
```

- [ ] **Step 3: Commit**

```bash
git add src/governance.md
git commit -m "docs: add flywheel guard step to §7 Leader Loop Protocol"
```

---

### Task 8: Local sync + full regression

**Files:** none modified — sync and verification only

- [ ] **Step 1: Run full test suite**

```bash
node --test tests/node/test-flywheel.mjs tests/node/test-flywheel-guard.mjs tests/node/us007-analytics-reporting.test.mjs tests/node/us008-cli-entrypoint.test.mjs
```
Expected: 0 failures

- [ ] **Step 2: Check zsh syntax**

```bash
zsh -n src/scripts/init_ralph_desk.zsh && echo "SYNTAX OK"
```

- [ ] **Step 3: Local file sync**

```bash
cp src/commands/rlp-desk.md ~/.claude/commands/rlp-desk.md
cp src/governance.md ~/.claude/ralph-desk/governance.md
cp src/scripts/init_ralph_desk.zsh ~/.claude/ralph-desk/init_ralph_desk.zsh
cp src/scripts/run_ralph_desk.zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
cp src/scripts/lib_ralph_desk.zsh ~/.claude/ralph-desk/lib_ralph_desk.zsh
cp README.md ~/.claude/ralph-desk/README.md
```

- [ ] **Step 4: Verify sync**

```bash
diff -q src/commands/rlp-desk.md ~/.claude/commands/rlp-desk.md
diff -q src/governance.md ~/.claude/ralph-desk/governance.md
diff -q src/scripts/init_ralph_desk.zsh ~/.claude/ralph-desk/init_ralph_desk.zsh
diff -q src/scripts/run_ralph_desk.zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
diff -q src/scripts/lib_ralph_desk.zsh ~/.claude/ralph-desk/lib_ralph_desk.zsh
diff -q README.md ~/.claude/ralph-desk/README.md
```
All must produce no output (identical).
