# tests/structural-archive/

These files were removed from the active shell test harness (`npm run test:zsh`,
which globs `tests/test_*.sh` and does not descend into this directory) because
every assertion in them is a string-presence/count grep against source or docs
text with no runtime execution — no subprocess run of `init_ralph_desk.zsh`,
`run_ralph_desk.zsh`, `lib_ralph_desk.zsh`, or src/node code, no extracted
function ever gets executed, and none of their assertions pin the SV-trigger
docs (`src/commands/rlp-desk.md`, `src/governance.md`) or the A5 trigger-file
diff oracle. See `docs/plans/narrow-v1-test-inventory.md` for the full
classification methodology and per-file rationale (US-002 of the narrow-v1
PRD, `.omc/plans/narrow-v1-prd.md`).

They are kept in git (not deleted) so a future contributor can revive one if
its underlying contract becomes load-bearing again — e.g. if a structural
grep test starts pinning content in a new SV-trigger doc, or a maintainer
decides a source-text contract it checks needs enforcement without full
execution coverage. To re-include a file, `git mv` it back into `tests/`
(the `test:zsh` glob will pick it up automatically) and note the reason in
the inventory doc.
