# Bug Report Overhaul — P2/P3 Backlog

> Companion to `bug-report-overhaul-v1.md` (PR-A/B/C plan).
> User stop-rule: ralplan iterates only until P0+P1 = 0; P2 and below are captured here, NOT blockers.
> Re-prioritize from this file in a future ralplan when the operator-minutes-saved metric from PR-A/B/C lands.

---

## P2 — should fix in a follow-up PR after PR-A/B/C land

### From v0 plan (Option C/D, deferred features)

- **Heartbeat-warning sidecar (Option B from v0)** — emit `<slug>-warning.{md,json}` when heartbeat anomaly crosses 50% of `iter-timeout`. Lets operator pre-empt a BLOCKED before the 30-min wall hits. Decoupled from this PR set because (a) report-quality is the dominant pain (D1), and (b) warning sidecar adds a second sentinel surface that risks false-positive fatigue. Revisit after PR-A/B land and we measure how many BLOCKEDs would have been pre-empted.
- **GitHub Issues integration (Option D from v0)** — POST blocked context to a configured GitHub repo issue. Requires per-repo authn story (token storage, network retry, rate-limits) — violates principle 3 in the current PR set. Re-evaluate after a credible authn proposal exists.
- **Pattern-learning loop** — mine `~/.claude/ralph-desk/analytics/*/bug-reports/` for emerging clusters. Auto-extends `docs/bug-patterns.json` with new candidate signatures for human review.
- **Cross-campaign bug-report dashboard in `/rlp-desk analytics`** — surface patterns across projects.
- **Auto-suggest "this looks like Bug #N — try fix-X" inline in CLI output** — operationalize PR-C's `pattern_match` data with an inline suggestion. Held back so the deterministic Jaccard implementation can be calibrated against real campaign data first.
- **Operator-CLI `/rlp-desk recover <slug> --to verify`** — write the manual recovery artifacts (`iter-signal.json`, `done-claim.json`, `status.json` patch) deterministically. Currently a hand-rolled `jq` pipeline per Bug #10 §7 workaround.

### From Codex Critic Round 2 (BACKLOG)

- **[P2-1]** PR-A `_validateOperatorRecoveryArtifacts` return shape — current pseudo-code mixes `if (valid)` (boolean coercion) with `valid.reason` (object access). Resolve at implementation time to either `{ ok: bool, reason: string }` (object) or pure boolean + separate side-channel for the warning text. Affects the audit log line shape.
- **[P2-2]** PR-A test summary in §5 says "5 ACs (R1–R5)" but §8 added AC-R6 (`_skipNextWorkerDispatch` cleared after one use). Update §5 to "6 ACs (R1–R6)" for consistency before PR-A merges.

### From Codex Critic Round 3 (BACKLOG)

- **[P2-3]** §9 step 5 banner-aware diff command only covers `run_ralph_desk.zsh`. PR-A and PR-B both also touch `lib_ralph_desk.zsh`. Add a matching `diff <(cat src/scripts/lib_ralph_desk.zsh) <(tail -n +N ~/.claude/ralph-desk/scripts/lib_ralph_desk.zsh)` step in the implementation runbook (verify the right `tail -n +N` offset at impl time — `lib_*.zsh` is sourced and may have no shebang). Extend to `init_ralph_desk.zsh` if PR-B touches it.

## P3 — nice-to-have polish

### From Codex Critic Round 2

- **[P3-1]** Option C/D/E rejection rationale in v1 §4 says "Same as v0" — acceptable because v0 is co-located, but inline one-sentence rationale would make the v1 plan self-contained for future readers who do not have the v0 file.

### From Architect Round 1 (residual notes)

- Validate the `bug-patterns.json` Jaccard threshold (0.7) against actual past blocks once we have ≥20 historical reports — current threshold is hand-picked. Likely needs a small calibration script in `scripts/`.
- Consider whether `bug-reports/` should ship in the npm tarball default `.gitignore` of newly initialized projects — currently the schema doc only recommends operators add it themselves.

---

## Promotion criteria (when to re-ralplan one of these)

A backlog item moves back into a planner draft when **any** of these is true:

1. PR-A/B/C lands and we measure ≥3 BLOCKEDs where the deferred item would have moved D1 by ≥10 minutes (e.g. heartbeat warning would have pre-empted a 30-min wait).
2. Operator hand-files ≥2 bug reports about the same backlog gap (signal that the deferral was wrong).
3. The `bug-patterns.json` seed becomes too large for human authoring (≥30 entries) — triggers the pattern-learning loop item.
4. A user explicitly asks for one (e.g. operator-CLI `/rlp-desk recover` once they fatigue of jq pipelines).
