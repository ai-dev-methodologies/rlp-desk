# tests/structural-archive/

These files were removed from the active shell test harness (`npm run test:zsh`,
which globs `tests/test_*.sh` and does not descend into this directory)
because no assertion in them consumes output of the real product runtime —
no subprocess run of `init_ralph_desk.zsh`, `run_ralph_desk.zsh`,
`lib_ralph_desk.zsh`, or src/node code, no extracted function ever gets
executed, and no inspection of state such a run generated — and none of
their assertions pin a contract of an SV-trigger file (`src/commands/rlp-desk.md`,
`src/governance.md`, or a prompt/template section of
`src/scripts/init_ralph_desk.zsh` — all three, per PRD Principle 4) or the
A5 trigger-file diff oracle. A couple of these files do execute a
hand-copied or hand-simulated reimplementation of the logic under test
(e.g. a shell pipeline retyped as literal text, or OS-level lock probes
standing in for the real locking function) rather than the real product
code — that is exactly why they are archived rather than kept as-is: a
hand-copy can silently diverge from the real implementation it was meant to
mirror, so it provides no durable guarantee about the real runtime's
behavior. See `docs/plans/narrow-v1-test-inventory.md` for the full
classification methodology and per-file rationale (US-002 of the narrow-v1
PRD, `.omc/plans/narrow-v1-prd.md`).

They are kept in git (not deleted) so a future contributor can revive one if
its underlying contract becomes load-bearing again — e.g. if a structural
grep test starts pinning content in a new SV-trigger file, or a maintainer
decides a source-text contract it checks needs enforcement without full
execution coverage. To re-include a file, `git mv` it back into `tests/`
(the `test:zsh` glob will pick it up automatically) and note the reason in
the inventory doc. `test_us007_verifier_anti_rubber_stamp.sh` is a concrete
example of this: originally archived here, then restored on Codex review
because it pins the Verifier Prompt template embedded in
`init_ralph_desk.zsh` — a third SV-trigger file the first classification
pass had overlooked.
