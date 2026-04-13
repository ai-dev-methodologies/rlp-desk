# Flywheel Redesign Spec

## Problem

rlp-desk's current loop is: Worker → Verify → FAIL → fix contract → Worker (same approach).
When the approach itself is wrong, retrying with fixes wastes iterations.
The loop needs a direction review step that challenges premises and forces alternatives before the next Worker runs.

## Design

### Loop Structure

```
First iteration (no flywheel):
  Worker → Verify → PASS → next US

On FAIL (--flywheel on-fail):
  Verify FAIL
    → Flywheel Agent (fresh context, opus)
      Step 0A: Premise Challenge
      Step 0B: Existing Code Leverage
      Step 0C: Ideal State Mapping
      Step 0D: Implementation Alternatives (min 2)
      Step 0E: Scope Decision (HOLD/PIVOT/REDUCE/EXPAND)
      Step 0F: Contract Rewrite + Rejected Directions
    → Worker (reads updated contract) → Verify
```

Flywheel runs BEFORE Worker. It decides direction, Worker executes.

### Execution Modes

tmux mode (3 panes):
```
┌──────────────┬──────────────┬──────────────┐
│ Flywheel     │ Worker       │ Verifier     │
│ claude opus  │ claude/codex │ claude/codex │
│ direction    │ implements   │ verifies     │
└──────────────┴──────────────┴──────────────┘
```
- Leader dispatches to flywheel pane, polls flywheel-signal.json
- After signal received, dispatches Worker with updated contract

agent mode:
- Leader calls Agent() with flywheel prompt → fresh context automatic
- Agent() returns decision directly (no file signal needed)
- Leader updates memory, then dispatches Worker agent

### CLI Flags

```
--flywheel off|on-fail       (default: off)
--flywheel-model MODEL       (default: opus)
```

### 4 Scope Decisions

| Decision | When | Action |
|----------|------|--------|
| HOLD | Premises valid, approach correct | Refine contract with specific fixes |
| PIVOT | Premise broken, approach wrong | Switch to alternative, record rejected direction |
| REDUCE | US too complex for current scope | Split AC or simplify, defer remainder |
| EXPAND | Missing prerequisite discovered | Add AC or expand contract |

### Flywheel Prompt Template (plan-ceo-review core internalized)

6-step review process:

**0A. Premise Challenge**
List every assumption in the current approach. For each, state whether this iteration's evidence supports or contradicts it. Broken premise → PIVOT or REDUCE.

**0B. Existing Code Leverage**
Check if Worker missed reusable code. Check if a different approach fits existing patterns better.

**0C. Ideal State Mapping**
Describe the ideal completion of this US in 2-3 sentences. How far is the current approach from ideal?

**0D. Implementation Alternatives (MANDATORY)**
Minimum 2 alternatives. Each: summary, effort (S/M/L), risk, tradeoff vs current approach.

**0E. Scope Decision**
Choose HOLD/PIVOT/REDUCE/EXPAND. Justify with evidence from this iteration only.

**0F. Contract Rewrite**
Rewrite Next Iteration Contract in campaign memory.
Record decision in Key Decisions.
Record failed approaches in Rejected Directions (prevents future Workers from repeating).

**CEO Cognitive Patterns (embedded in prompt):**
1. First-principles — ignore convention, start from the problem
2. 10x check — can 2x effort yield 10x better result?
3. Inversion — what must be true for this approach to fail?
4. Simplicity bias — prefer simple over complex solutions
5. User-back — reason backwards from end-user experience
6. Time-value — does this pivot save 3+ iterations?
7. Sunk cost immunity — ignore prior investment
8. Blast radius — assess impact scope of direction change
9. Reversibility — prefer easily reversible decisions
10. Evidence > opinion — judge only by this iteration's actual results

### Signal Protocol

flywheel-signal.json:
```json
{
  "iteration": N,
  "decision": "hold|pivot|reduce|expand",
  "summary": "one line explanation",
  "rejected_directions": ["approach X because Y"],
  "contract_updated": true,
  "timestamp": "ISO"
}
```

### Campaign Memory Updates

Flywheel agent writes directly to campaign memory:
- **Next Iteration Contract**: rewritten based on decision
- **Key Decisions**: flywheel decision + reasoning appended
- **Rejected Directions**: new section, append-only (Worker reads to avoid repeating)

### Files Changed

| File | Change |
|------|--------|
| src/scripts/init_ralph_desk.zsh | Flywheel prompt template, 3rd pane setup, --flywheel flags in presets |
| src/node/runner/campaign-main-loop.mjs | Flywheel dispatch (tmux + agent), shouldRunFlywheel(), pane management |
| src/node/run.mjs | --flywheel, --flywheel-model flag parsing |
| src/commands/rlp-desk.md | Flywheel documentation, options reference |
| src/governance.md | Flywheel step in Leader loop protocol |
| src/scripts/run_ralph_desk.zsh | 3rd pane creation for tmux mode |

### What Stays (from current branch)

- SV Report generation (generateSVReport in campaign-reporting.mjs)
- Brainstorm step 0 SV feedback (rlp-desk.md)
- analyticsDir in buildPaths

### What Gets Removed (from current branch)

- Current pivot implementation (shouldRunPivot, dispatchPivot, buildPivotTriggerCmd)
- Current pivot prompt template in init_ralph_desk.zsh
- Current --pivot-mode, --pivot-model flags
- test-pivot-step.mjs

## Verification

### TDD Tests
- shouldRunFlywheel logic (off/on-fail conditions)
- Flywheel prompt contains all 6 steps + 10 cognitive patterns
- Signal protocol parsing
- Rejected directions persistence across iterations
- 3-pane creation in tmux mode

### Self-Verification (3 scenarios)
- LOW: --flywheel off → normal loop unchanged
- MEDIUM: --flywheel on-fail + FAIL → flywheel fires → memory updated → Worker reflects
- CRITICAL: PIVOT decision → rejected direction recorded → next Worker avoids it

### E2E
- Test project with intentional FAIL → flywheel activates → direction change → success
