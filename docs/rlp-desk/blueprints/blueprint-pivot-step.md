# Blueprint: Pivot Step (⑤½)

> Status: TODO — not yet implemented. Document for future development.

## Summary

Insert a Pivot Review step between Worker(⑤) and Verifier(⑦) in the Leader loop. Internalizes the core thinking framework from gstack's `plan-ceo-review` (premise challenge, forced alternatives, scope decisions) without depending on external skills.

## Problem

When a Worker repeatedly fails on the same US, the fix loop retries the same approach with progressively stronger models. This works for implementation bugs but fails for **wrong approach** problems. The current CB threshold → BLOCKED pattern wastes iterations before admitting the approach is wrong.

## Proposed Solution

### New CLI Flags

```
--pivot-mode off|every|on-fail    (default: off)
--pivot-model MODEL               (default: opus)
```

- `off`: no pivot review (current behavior)
- `every`: pivot review after every Worker iteration
- `on-fail`: pivot review only after Verifier fail verdict

### Leader Loop Change

```
Current:  ① → ② → ③ → ④ → ⑤ worker → ⑥ signal → ⑦ verifier → ⑧ result
Proposed: ① → ② → ③ → ③½ PIVOT → ④ → ⑤ worker → ⑥ signal → ⑦ verifier → ⑧ result
```

Pivot runs BEFORE Worker — it decides direction, then Worker executes that direction.

### Tmux Pane Layout (3 panes)

```
+------------------+------------------+------------------+
| Worker pane      | Pivot pane       | Verifier pane    |
| claude/codex     | claude (opus)    | claude/codex     |
| implements code  | direction review | verifies result  |
+------------------+------------------+------------------+
```

Pivot pane is reused each iteration (not persistent). Leader launches pivot → waits for memory update → launches Worker in Worker pane.

### ③½ Pivot Review Step

**Agent mode:**
```
Agent(
  description="rlp-desk pivot review iter-NNN",
  model=<pivot_model>,
  mode="bypassPermissions",
  prompt=<pivot_prompt>
)
```

**Tmux mode:**
- Dedicated pivot pane (3rd pane)
- `DISABLE_OMC=1 claude --model opus --mcp-config '{"mcpServers":{}}' --strict-mcp-config -p "$(cat pivot-prompt.md)"`
- After pivot completes, verify memory updated → build Worker prompt (④) → launch Worker (⑤)

### Pivot Review Responsibilities

1. **Analyze iteration result** — what did the Worker actually produce?
2. **Premise challenge** — is the current approach correct? What assumptions are we making?
3. **Forced alternatives** — propose minimum 2 alternative approaches
4. **Scope decision** — EXPAND (add scope), HOLD (keep current), REDUCE (simplify)
5. **Update campaign memory** — rewrite Next Iteration Contract if approach changes
6. **Record rejected directions** — prevent future iterations from revisiting dead ends

### Pivot Prompt Template (internalized from plan-ceo-review)

```markdown
# Pivot Review — Iteration {N}

## Context
- Campaign: {slug}
- Current US: {us_id}
- Worker result: {done-claim summary}
- Consecutive failures on this US: {N}
- Previous pivot decisions: {from memory}

## Your Task

### 1. Premise Check
For each premise below, state whether evidence supports or contradicts it:
{list premises from PRD/memory}

### 2. Forced Alternatives
Propose at least 2 alternative approaches to the current US.
For each: summary, effort (S/M/L), risk, key tradeoff.

### 3. Scope Decision
Choose ONE: EXPAND | HOLD | REDUCE
Justify with evidence from this iteration.

### 4. Next Iteration Contract
If HOLD: refine the current contract with specific fixes.
If EXPAND/REDUCE: rewrite the contract for the new approach.

### 5. Rejected Directions
List approaches that should NOT be attempted again, with reason.

## Output
Update campaign memory at: {memory_path}
- Update "Next Iteration Contract" section
- Add to "Key Decisions" section
- Add to "Rejected Directions" section (if any)
```

## Expected Benefits

- **Breaks fix loops** — "same approach, stronger model" → "different approach"
- **Research campaigns** — natural direction pivots without manual intervention
- **Reuses proven framework** — plan-ceo-review's premise challenge + forced alternatives
- **Both modes** — works in tmux and agent mode

## Implementation Notes

- `PIVOT_MODE` variable in `run_ralph_desk.zsh` (pattern: same as `AUTONOMOUS_MODE`)
- CLI parser: `--pivot-mode`, `--pivot-model` (pattern: same as other model flags)
- `write_pivot_prompt()` function in `run_ralph_desk.zsh` (pattern: same as `write_worker_trigger`)
- Pivot review output → campaign memory update (same file, different section)
- Status.json: add `pivot_decisions` array for tracking
- Analytics: `campaign.jsonl` add `pivot_action` field per iteration

## Dependencies

- Requires `--autonomous` mode (pivot review must not stop for questions)
- Works with any Worker engine (Claude or Codex)
- Does not require gstack installation

## Priority

Medium — implement after v1.0 Node.js rewrite is stable. Current CB threshold + model upgrade handles most cases. Pivot step is for research/exploration campaigns where approach flexibility matters.
