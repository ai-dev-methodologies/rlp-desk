# Blueprint: Self-Verification Architecture Rethink (§7¾ escalation)

**Status**: backlog (escalation candidate, not yet planned for implementation)
**Filed by**: RC-1 patch (fix/rc1-tmux-sv-skip-and-rc2-prd-cross-us-lint, 2026-04-25)
**Escalation trigger**: governance §7¾ Architecture Escalation

## Why this is here

RC-1 (tmux SV report 5-min hang) was fixed by **disabling** `generate_sv_report`
in tmux runners and recording the disable on three channels (session-config,
metadata.json, debug log) so traceability is preserved. That patch is honest
but it does not answer the deeper question:

> Should the Self-Verification report be produced by spawning `claude --print`
> at all? And if not, what should replace it?

The current shell implementation (`src/scripts/lib_ralph_desk.zsh:603-668`)
spawns `claude --print` against a tmux pane with no usable TTY/stdin and waits
for a 300-second watchdog. Even in Agent mode the cost surface is large:
synchronous LLM call, no caching, no determinism, and no obvious story for
running SV against historical campaigns offline.

Per governance §7¾ this counts as an **architecture question**, not a patch
target. Open it as a blueprint, gather options, and decide before touching the
shell function again.

## Options to evaluate

1. **Static SV (no LLM call)**.
   - Replace the LLM-generated report with a deterministic Node module that
     reads `iter-*.json`, `cost-log.jsonl`, `verify-verdict.json`, etc., and
     emits the 10-section report from templates + counts.
   - Pros: no spawn, sub-second runtime, runs offline against archived
     campaigns, cacheable.
   - Cons: loses qualitative analysis ("Worker over-engineered" / "Verifier
     rubber-stamped"). The 10 sections are not all reducible to counts.
2. **Hybrid: static skeleton + on-demand LLM section.**
   - Static skeleton always runs at campaign end. The qualitative sections
     ("Worker Process Quality", "Verifier Judgment Quality", "Patterns:
     Strengths & Weaknesses", "Recommendations for Next Cycle", "Blind Spots")
     become an opt-in `rlp-desk sv enrich <slug>` command run from a real TTY
     (Agent mode or interactive shell).
   - Pros: best of both. tmux runner gets a useful baseline report; the user
     can opt into the LLM pass when convenient.
   - Cons: two code paths to maintain.
3. **Move SV out of the runner entirely.**
   - rlp-desk produces only the artifacts (already does). SV becomes a
     dedicated `rlp-desk sv <slug>` command that the user invokes from any
     working session.
   - Pros: cleanest separation. Runner stays small; SV evolves independently.
   - Cons: discoverability — users may forget to run it. Requires a small UX
     for "you should run sv against this slug" hints in the campaign report.
4. **Keep the LLM spawn but fix it for tmux.**
   - Negotiate with claude CLI for a non-interactive, no-TTY mode that streams
     stdout and exits cleanly. Possibly via `--output-format json` plus
     explicit stdin closure.
   - Pros: smallest surface change.
   - Cons: depends on Claude CLI semantics that may shift between releases.
     RC-1 already showed how brittle this is.

## Open questions

- What sections of the current 10-section SV are actually consumed by humans?
  (Metric sections vs qualitative sections vs blind spots — gather telemetry.)
- Is there a way to reuse the verifier model itself (already running per
  iteration) to emit a "campaign-level" verdict at the end, rather than a
  separate spawn?
- Should SV be cross-engine consensus too, or is single-model SV enough?

## Decision pending

Open. The current RC-1 patch is the **interim** answer: SV is disabled in
tmux, traceability is preserved through `with_self_verification_requested` +
`sv_skipped_reason`, and the user gets an honest "requested but skipped"
banner in the Campaign Report. This blueprint will be promoted to a plan when
someone takes ownership of the architecture question above.

## References

- `src/scripts/lib_ralph_desk.zsh:603-668` — current `generate_sv_report` impl.
- `src/scripts/run_ralph_desk.zsh:719-727, 758-768, 2118-2125, 2151` — RC-1 patch.
- `src/node/reporting/campaign-reporting.mjs:412-591` — Node-side SV summary
  builder (already pure file I/O — promising starting point for option 1/2).
- governance §7¾ Architecture Escalation — escalation policy this entry uses.
