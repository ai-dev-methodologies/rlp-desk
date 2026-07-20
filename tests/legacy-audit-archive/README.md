# tests/legacy-audit-archive/

These five files were never part of the active shell test harness
(`npm run test:zsh`, which globs `tests/test_*.sh` and does not descend into
this directory) at any point `package.json` has looked like this — none of
them start with `test_`, so the glob never matched them. They are archived
here, not deleted, because leaving them loose at the top of `tests/` with no
runner reference and no rationale invites exactly the confusion this
directory resolves: a reviewer finding an unreferenced `.sh` file and
assuming it is either (a) dead weight to delete, or (b) a missed test that
should be wired into the runner. Neither is correct — see the per-file
rationale below.

Unlike `tests/structural-archive/` (whose files may become load-bearing
again if a future contract needs their coverage), **these are dead**:
one-time self-verification / release-gate snapshots for versions that have
shipped and moved on, plus one file with a hardcoded reference to a defunct
developer worktree. There is no revival criterion — restoring one of these
would mean re-checking a contract that either no longer exists in the
product or is already covered live by `test:node` / `test:zsh`.

## Per-file rationale

- **`sv-self-verify-0.14.sh`** — 13 PASS / 2 FAIL (confirmed at archival
  time, 2026-07-20). The 2 failures (scenarios L5.6a/L5.6b) assert that
  `--mode agent` still surfaces an "alpha" warning and that README /
  `rlp-desk.md` label it `tmux=stable, agent=alpha`. Current behavior:
  `--mode agent` was removed outright per ADR-001 — `run.mjs` now prints
  `"ERROR: --mode agent (Node-leader direct-CLI alpha) is no longer
  supported (ADR-001)."` The guarded contract (an alpha mode that
  warns-but-runs) no longer exists in the product. **Do not "fix" this
  file** — the 2 failures are not a regression, they are a dead contract
  correctly reporting itself as dead.
- **`sv-self-verify-0.14.1.sh`** — 9/9 PASS. A one-time v0.14.1 release-gate
  snapshot (per `docs/plans/spicy-booping-galaxy.md`'s own framing). Its
  scenarios re-check things `test:node` / `test:zsh` already cover live.
- **`sv-self-verify-0.14.2.sh`** — 11/11 PASS. Same pattern, for v0.14.2.
- **`sv-self-verify-0.14.5.sh`** — PASS, several scenarios literally shell
  out to `node --test tests/node/*.mjs tests/node/*.test.mjs` and other
  `tests/test_*.sh` files as sub-steps — fully duplicative of `test:node` /
  `test:zsh`, which already run those files directly.
- **`verify-v2-protocol.sh`** — PASS=3 / FAIL=55 / WARN=1 (confirmed at
  archival time). Contains a literal hardcoded path to a defunct
  machine/worktree —
  `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/docs/protocol-reference.md`
  — which does not exist on any current checkout. Its US-007/US-008
  assertions check for `request_info`, `git diff` scope, `Depends on` /
  `Size S|M|L` PRD-template fields, and `quality-spec` mentions — content
  from an early, superseded protocol proposal. Current US-007/US-008 in the
  live suite (`test_us007_brainstorm_recommendation.sh`,
  `test_us007_verifier_anti_rubber_stamp.sh`,
  `test_us008_self_verification_e2e.sh`) cover unrelated content. Zero
  references anywhere in the repo outside itself.

None of these five files are referenced by `tests/sv-gate-fast.sh`,
`tests/sv-gate-full.sh`, `package.json`, or `README.md` — the move is a
complete, self-verifying exclusion; no runner code needed to change.

They are kept in git (not deleted) purely for historical/audit traceability.
If a future contributor believes one of these checks a contract worth
reviving, `git mv` it back into `tests/` (the `test:zsh` glob will pick it
up automatically) — but note that, unlike `structural-archive/`, none of
these five have an open revival criterion; reviving one means re-deriving
its assertions against the current product, not restoring it as-is.

See `docs/plans/narrow-v1-test-inventory.md` for the adjacent classification
of the 69 `tests/test_*.sh` files (a different, glob-matched set this
directory's files were never part of), and
`.omc/plans/improvement-backlog-2026-07-20.md` (`## SPEC: IMP-14`) for the
full investigation and disposition rationale behind this archival.
