# Blueprint: Flywheel Enhancement

> Status: TODO — not yet implemented. Document for future development.
> Codex-reviewed: 2026-04-13 (pre-implementation design review)

## Summary

Three enhancements to the flywheel direction-review step, unified in one blueprint:

1. **Flywheel Guard** — independent verification of flywheel decisions before Worker acts on them
2. **CEO Pattern Internalization** — selective additions from plan-ceo-review framework
3. **tmux Shell Leader Defer** — Node.js campaign-main-loop.mjs only; zsh run script deferred

## Problem

### Flywheel makes bad direction decisions

In the `surge-v3-exit-strategy` campaign, the flywheel ran 3 times. Each time it made a flawed decision that wasted iterations:

| Flywheel | Decision | Failure | Root Cause |
|----------|----------|---------|------------|
| 1st | peak_pct segmentation | look-ahead bias — peak_pct is post-hoc, not available at decision time | No feasibility check on proposed features |
| 2nd | fixed_tp_5pct by median | median ignores large outliers (4.7x PnL difference invisible) | No metric alignment check against PRD intent |
| 3rd | breakeven by mean PnL | Correct — but only after user manually caught both prior errors | 2 iterations wasted |

The flywheel prompt already has premise challenge, forced alternatives, and 10 cognitive patterns. But it lacks:
- **Feasibility validation** — can the proposed direction actually be deployed?
- **Metric scrutiny** — is the optimization metric the right proxy for the real goal?
- **Independent review** — self-audit by the same agent is structurally weak

### tmux leader gap

`campaign-main-loop.mjs` handles flywheel dispatch for both agent and tmux modes via Node.js. `run_ralph_desk.zsh` has no flywheel logic. This is intentional — see §3.

## Design

### 1. Flywheel Guard

#### CLI Flags

```
--flywheel-guard off|on     (default: off)
--flywheel-guard-model MODEL (default: opus)
```

#### Architecture: Single Independent Guard

When `--flywheel-guard on`, every flywheel execution is followed by an independent Guard agent before Worker dispatch. No embedded-only phase — codex review confirmed self-audit is structurally weak for bias detection.

```
Verifier FAIL
  → Flywheel Agent (fresh context)
    Steps 0A-0F: premise challenge, alternatives, scope decision, contract rewrite
  → Guard Agent (fresh context, different from flywheel)
    Reads: flywheel-signal.json, flywheel-review.md, PRD, campaign memory
    Checks: 4 validation items (see below)
    Writes: flywheel-guard-verdict.json
  → verdict:
    pass        → Worker executes flywheel's direction
    fail        → Flywheel re-runs with guard feedback injected (max 2 retries)
    inconclusive → Leader escalates to user (BLOCKED with escalation report)
  → 2 retries exhausted + still fail → BLOCKED
```

#### Guard Validation Checks (4 items)

**Check 1: Look-ahead Bias**
List every data feature the flywheel's proposed direction depends on.
For each feature: is it available at decision time (when the system must act)?
- `available`: feature exists before the event occurs (e.g., entry time, session start price)
- `post-hoc`: feature requires future information (e.g., peak_pct, session_end)
- Any `post-hoc` feature in a deployable direction → FAIL

**Check 2: Metric Alignment**
- State the PRD's optimization metric explicitly
- Does the flywheel's proposed direction optimize the same metric?
- Same metric → pass
- Different metric, not flagged → FAIL (silent metric switch)
- Different metric, flagged with evidence → FAIL (metric mismatch requires PRD update or user approval)
- PRD is ground truth. The guard cannot approve off-PRD metric changes autonomously.

**Check 3: Deployability**
- Can the proposed direction's output be used in production?
- Does it require data, infrastructure, or conditions not available in the deployment environment?
- Non-deployable direction proposed as champion → FAIL
- Direction labeled "upper-bound/reference only" → pass, but Guard MUST include `"analysis_only": true` in verdict so Leader skips Worker dispatch (analysis record only, no implementation)

**Check 4: Repeat Pattern (same-US scoped)**
- Compare current flywheel decision to prior flywheel decisions **for the current US only**
- Same direction category (e.g., same scope decision) with same underlying approach → FAIL
- Different framing of a previously rejected direction → FAIL
- Guard MUST persist rejected flywheel directions to campaign memory's Rejected Directions section before writing verdict file. This ensures cleanup cannot erase the record.

#### Guard Signal Protocol

```json
{
  "verdict": "pass|fail|inconclusive",
  "issues": [
    {
      "check": "look-ahead-bias|metric-alignment|deployability|repeat-pattern",
      "status": "pass|fail|inconclusive",
      "detail": "specific finding",
      "evidence": "file:line or data reference"
    }
  ],
  "analysis_only": false,
  "recommendation": "proceed|retry-flywheel|escalate-to-user",
  "timestamp": "ISO"
}
```

#### State Tracking

- `flywheel_guard_count`: tracked **per-US** in status.json (not per-campaign)
  - Increments on each guard execution for the current US
  - Resets when US changes or passes verification
  - `ALL` final verification treated as its own bucket
- Guard files in cleanup: `flywheel-guard-verdict.json` added to re-execution cleanup list

#### Boundary Conditions

| Condition | Behavior |
|-----------|----------|
| `--flywheel off` | No flywheel, no guard. Guard flag ignored. |
| `--flywheel on-fail` + `--flywheel-guard off` | Flywheel runs without guard (current behavior). |
| `--flywheel on-fail` + `--flywheel-guard on` | Every flywheel followed by independent guard. |
| Final ALL verification fails | Flywheel + guard runs if `--flywheel on-fail`. ALL treated as separate US bucket. |
| Guard returns `inconclusive` | BLOCKED with escalation report. Leader does NOT retry. |
| Guard model same as flywheel model | Allowed but not recommended. Different model provides better independence. |
| Resume after guard BLOCKED | User must clear blocked sentinel. Guard count resets for that US. |

#### Guard Prompt Template

```markdown
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

{GUARD_FEEDBACK_SECTION}

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
- Labeled as "upper-bound only" or "reference" → pass, but you MUST include `"analysis_only": true` in your verdict so Leader skips Worker dispatch (no implementation, analysis record only)

### Check 4: Repeat Pattern (same-US scoped)
Compare to prior flywheel decisions **for the current US only** in campaign memory's Key Decisions section.
- Same scope decision + same underlying approach as a prior flywheel for this US → FAIL
- Reframing of a previously rejected direction (check Rejected Directions) → FAIL
- Genuinely new approach → pass
Before writing your verdict, you MUST append any rejected flywheel direction to campaign memory's Rejected Directions section. This persists the record before cleanup can erase it.

## Output
Write verdict to: {DESK}/memos/{SLUG}-flywheel-guard-verdict.json

Use this format:
{
  "verdict": "pass|fail|inconclusive",
  "issues": [...],
  "analysis_only": false,
  "recommendation": "proceed|retry-flywheel|escalate-to-user",
  "timestamp": "ISO"
}

Rules:
- If ALL checks pass → verdict: pass, recommendation: proceed
- If ANY check is fail → verdict: fail, recommendation: retry-flywheel
- If ANY check is inconclusive and none are fail → verdict: inconclusive, recommendation: escalate-to-user
- Include specific evidence for every check. No "seems fine" or "probably ok."
```

When guard fails and flywheel retries, the `{GUARD_FEEDBACK_SECTION}` is populated:

```markdown
## Previous Guard Feedback (MUST address these issues)
The previous flywheel decision was rejected by the Guard. Issues found:
{list of guard issues with evidence}

You MUST address each issue above. Do NOT repeat the same direction.
Check Rejected Directions in campaign memory before proposing alternatives.
```

### 2. CEO Pattern Internalization (Selective)

From plan-ceo-review's 16+ cognitive patterns, add **2** to the flywheel prompt's existing 10 patterns:

#### Added

**11. Proxy Skepticism**
> Is the metric you're optimizing actually the right proxy for the real goal? What would change if you used a different metric? Name the proxy, name the goal, check the gap.

Why: Directly prevents the median-vs-mean failure. The flywheel optimized median gap without questioning whether median was the right proxy for total PnL.

Placement: Added to the CEO Cognitive Patterns list (items 1-10 already exist). Also referenced in Step 0D½ context (when applicable).

**12. Classification (reversibility x magnitude)**
> Rate your proposed direction change on two axes: How hard is it to reverse? How large is its impact? Hard-to-reverse + large-magnitude decisions need proportionally stronger evidence.

Why: Prevents casual PIVOT decisions on major scope changes without sufficient evidence. Lightweight — one sentence judgment per direction, not a matrix.

Placement: Added to Step 0E (Scope Decision) as a judgment criterion.

#### Not Added (with rationale)

| Pattern | Why Not |
|---------|---------|
| Wartime awareness | Mechanical (cb_threshold/2) conflicts with governance CB semantics. Flywheel already has time-value pattern (#6). |
| Temporal depth (5-10yr) | Iteration-level direction review, not strategic planning. |
| People-first sequencing | Organizational, not applicable to automated agents. |
| Hierarchy as service | Organizational. |
| Narrative coherence | Relevant for product vision, not iteration pivots. |
| Speed calibration (70% info) | Flywheel already operates on limited info by design. |
| Founder-mode bias | Human leadership pattern. |
| Willfulness as strategy | Human trait. |
| Courage accumulation | Human trait. |
| Leverage obsession | Too abstract for iteration-level use. |
| Focus as subtraction | Already covered by simplicity bias (#4). |
| Paranoid scanning | Already covered by inversion (#3). |
| Design for trust | UX-specific. |
| Edge case paranoia | Already covered by evidence > opinion (#10). |

#### Updated Flywheel Prompt Cognitive Patterns Section

```markdown
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

### 3. tmux Shell Leader Defer

#### Current State

`campaign-main-loop.mjs` manages flywheel for both execution modes:
- **tmux mode**: creates flywheel pane, dispatches via `sendKeys`, polls `flywheel-signal.json`
- **agent mode**: (planned) Leader calls Agent() with flywheel prompt

`run_ralph_desk.zsh` has **no** flywheel logic. It manages Worker + Verifier panes only.

#### Defer Rationale

1. Node.js `campaign-main-loop.mjs` already covers tmux mode's flywheel dispatch via pane management
2. Duplicating the same logic in zsh creates maintenance burden with no functional gain
3. Workstream research is evaluating whether tmux leader should migrate to Node.js entirely

#### Decision Point

| Research Conclusion | Action |
|---------------------|--------|
| Keep zsh leader | Implement flywheel logic in `run_ralph_desk.zsh` — new blueprint |
| Migrate to Node.js | This defer item is closed. `campaign-main-loop.mjs` is the single implementation. |

#### Until Then

- `run_ralph_desk.zsh` continues to operate Worker + Verifier only
- flywheel is available through `node src/node/run.mjs run <slug> --flywheel on-fail --mode tmux`
- The Node.js runner handles all tmux pane management for flywheel

## Implementation Scope

### Files Changed

| File | Change |
|------|--------|
| `src/scripts/init_ralph_desk.zsh` | Flywheel prompt: add patterns #11-12. Guard prompt template (new). Guard files in cleanup list. |
| `src/node/runner/campaign-main-loop.mjs` | Guard dispatch logic, `flywheel_guard_count` per-US in status, guard verdict polling, retry-with-feedback loop, `inconclusive` → BLOCKED path. |
| `src/node/run.mjs` | `--flywheel-guard off|on`, `--flywheel-guard-model MODEL` flags. |
| `src/commands/rlp-desk.md` | Flywheel guard options documentation, guard flow description. |
| `src/governance.md` | §7 Leader Loop: flywheel guard step after flywheel, before Worker. |

### New Files

| File | Content |
|------|---------|
| `tests/node/test-flywheel-guard.mjs` | Guard logic unit tests, verdict parsing, retry loop, per-US count tracking. |

### Init Scaffold Additions

```
.claude/ralph-desk/
├── memos/
│   ├── <slug>-flywheel-guard-verdict.json   (runtime; deleted on re-execution)
```

## Verification

### TDD Tests
- Guard dispatch only when `--flywheel-guard on` AND flywheel ran
- Guard verdict parsing (pass/fail/inconclusive)
- Retry loop: fail → re-run flywheel with feedback → re-guard (max 2)
- inconclusive → BLOCKED (no retry)
- Per-US guard count tracking (increments, resets on US change/pass)
- ALL bucket treated separately
- Guard files in cleanup list

### Self-Verification (5 scenarios)
- **LOW**: `--flywheel-guard off` → flywheel runs without guard (current behavior unchanged)
- **MEDIUM-1**: `--flywheel-guard on` + flywheel decision with look-ahead bias → guard catches it (Check 1 FAIL) → flywheel retries → corrected direction
- **MEDIUM-2**: `--flywheel-guard on` + flywheel silently switches optimization metric → guard catches it (Check 2 FAIL, metric mismatch requires PRD update) → escalation
- **MEDIUM-3**: `--flywheel-guard on` + flywheel proposes direction previously rejected for same US → guard catches it (Check 4 FAIL) → flywheel retries with different approach
- **CRITICAL**: Guard fails 2x → BLOCKED with escalation report including all guard issues from both attempts

## Dependencies

- Requires `--flywheel on-fail` (guard without flywheel is meaningless)
- Works with any flywheel model and guard model combination
- Does not require gstack installation
- Does not require tmux (works in agent mode)

## Priority

Medium — implement after flywheel has been battle-tested in more campaigns. Current workaround is user vigilance (which caught all 3 issues in surge-v3-exit-strategy). Guard formalizes that vigilance into a protocol.
