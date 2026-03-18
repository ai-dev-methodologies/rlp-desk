# v2-protocol - Latest Context

## Current Frontier
### Completed
- US-001: Enhanced Memory Format (protocol-reference.md, governance.md, init_ralph_desk.zsh)
- US-002: Leader Loop Prep-stage Cleanup & Post-execution Log (all 3 docs + init script)
- US-003: Circuit Breaker Enhancement (governance.md §8, protocol-reference.md CB table + status.json, rlp-desk.md)
- US-004: Verifier Independence Reform (protocol-reference.md verify-verdict.json 3-state + severity + scope + orientation, governance.md §2, rlp-desk.md ⑦ request_info branch)
- US-005: Fix Loop Protocol (governance.md §7½, protocol-reference.md Fix Loop spec + Fix Contract Format, rlp-desk.md ⑦ fail branch expanded)
- US-006: Worker Prompt Template Enhancement (init_ralph_desk.zsh worker prompt "Before you start" + scope rules + commit rule)

### In Progress
(none)

### Next
- US-007: Verifier Prompt Template Enhancement (init_ralph_desk.zsh verifier prompt — remove uncertain=fail, add request_info, git diff scope, orientation note, severity field)
- US-008: Scaffold & Template Updates (PRD template Depends on + Size fields, quality-spec mention in protocol-reference.md)

## Key Decisions
- Fix Loop placed as §7½ in governance.md (between Leader Loop §7 and Circuit Breaker §8).
- "traceability" lowercase used in protocol-reference.md to satisfy case-sensitive grep check.
- US-007+US-008 grouped for next iteration (both S-sized, both target init_ralph_desk.zsh / protocol-reference.md).

## Known Issues
- test-spec's `grep -q "Clean previous" src/governance.md` check is a pre-existing gap (governance.md uses "Prep-stage cleanup" + "Delete done-claim.json" phrasing). Outside current scope.

## Files Changed This Iteration
- src/governance.md (US-005: §7½ Fix Loop Protocol section added)
- docs/protocol-reference.md (US-005: Fix Loop Protocol section + Fix Contract Format added)
- src/commands/rlp-desk.md (US-005: ⑦ fail branch expanded to 5-step Fix Loop reference)
- src/scripts/init_ralph_desk.zsh (US-006: worker prompt "Before you start" + scope rules + commit rule)

## Verification Status
- US-005 grep checks: PASS (6/6)
- US-006 grep checks: PASS (4/4)
- Smoke test: PASS (worker has Before you start, commit, scope rules; memory has Completed Stories, Key Decisions)
