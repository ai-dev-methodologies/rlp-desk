# Changelog

All notable changes to `@ai-dev-methodologies/rlp-desk` are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/).

For pre-v0.15.4 versions, refer to `git log` and individual GitHub release notes.

## [Unreleased]

### Planned (not yet shipped)
- v0.15.5 candidate: flip `RLP_LIFECYCLE_METRICS=1` default to ON (gated on 3 consecutive nightly real-LLM SV passes per `docs/plans/v0.15.4-release-runbook.md` §7.5.2).
- Post-v0.15.6: remove `RLP_LIFECYCLE_METRICS` flag entirely (per plan v3 ADR follow-ups).
- Phase D.1 (handoff documents) + Phase D.2 (per-stage agent role specialization) — both deferred per `docs/plans/v0.15.4-release-runbook.md` §7.6.

## [0.15.5] — 2026-06-17

Patch: fixes surfaced by a fresh-context live dogfood of the tmux and agent run modes, plus packaging hygiene.

### Fixed
- **Curl-install (`install.sh`) produced a Node leader that could not start.** `src/node/MANIFEST.txt` was missing three runtime modules, so a curl-installed `--mode agent` / Node leader threw `ERR_MODULE_NOT_FOUND` at startup. MANIFEST regenerated. (npm installs were unaffected.)
- **Tmux-mode leader could hang at startup.** A bare `> "$COST_LOG"` redirect runs zsh's `$NULLCMD` (`cat`), which blocks reading stdin when launched with an open TTY (interactive shell / tmux pane). Changed to `: > "$COST_LOG"`.
- **Worker sometimes printed the iteration signal instead of writing it.** The per-iteration prompt now explicitly instructs the worker to WRITE the verify signal to the iter-signal file (resolved path in tmux mode).
- **Clearer error for mis-leveled PRD user-story headings.** When user stories use `###` instead of `## US-NNN` (H2), the Node leader now hints at the correct heading level instead of a bare "No user stories found".

### Added
- **`clean <slug> [--kill-session]` for the Node CLI.** Resets a campaign — removes sentinels, signal/claim/verdict files, and runtime state, while preserving the PRD, test-spec, prompts, memory, and reports. Previously unimplemented in the Node rewrite, which left a blocked campaign with no recovery path.

### Changed
- **Smaller published package.** The tarball no longer ships internal research docs, dev planning handoffs, or example runtime state (73 → 53 files, ~364 → ~244 kB).

## [0.15.4] — 2026-05-08

Phase B: tmux/process lifecycle hardening + observability + real-LLM SV strengthening. 4 sequential PRs (B1, B2-FIX, B4, B3) merged to main, plus pre-release audit fix branch addressing 16 findings (3 CRITICAL, 6 HIGH, 5 MEDIUM, 2 LOW).

### Added
- `RLP_LIFECYCLE_METRICS=1` env flag enables structured tmux/process lifecycle telemetry. Five metrics emitted per iteration:
  - `iter_signal_write_to_read_ms` — Worker FS write → leader poll resolve
  - `verdict_write_to_read_ms` — Verifier FS write → leader poll resolve
  - `pane_eof_to_cleanup_ms` — kill-start → `killPaneProcess` return
  - `pane_reap_latency_ms` — done-claim observe → pane shell-idle
  - `sentinel_lock_to_unlock_ms` — per-type, lock vs unlock pair
  - Default OFF; zero overhead when unset.
  - Lands in `debug.log` (LIFECYCLE category) and batched per iter into `campaign.jsonl.lifecycle_metrics`.
- `RLP_DESK_NODE_PATH` env override for SV scenarios. Lets the operator point bug-05 / bug-07 at a source-tree leader (`<repo>/src/node/run.mjs`) for pre-merge AC3.1a sampling.
- `B3_STAGE2_BLOCKING=1` env flag. Promotes B3 Stage 2 lifecycle-band assertions from non-blocking (informational) to release-blocking. Operator opts in after a 3-night PASS streak per release runbook §7.5.2.
- `docs/rlp-desk/failure-modes.md` — FMEA-style consolidated failure modes atlas (origin: omc-team Gotchas pattern). 14 entries across 6 categories.

### Fixed
- Bug #5/7 done-claim race window (PR-B2-FIX). Worker pane is now reaped (`_kill_pane_process`) and `done-claim.json` sentinel locked (`chmod 0o444`) at the moment leader observes done-claim. Previously the pane lingered 30-120s post-write and could revise the artifact.
  - Four substrate sites fixed: `run_ralph_desk.zsh` codex-exit synth path / A4 fallback inline path / post iter-signal reaper, `campaign-main-loop.mjs` Node leader worker reap.
- B3 Stage 2 jq false-PASS (audit C1). Pre-compute entry count via `jq flatten | length`; SKIP when zero entries instead of falsely matching `max=0` against the band.
- B3 scenarios circular pre-merge gate (audit C2). bug-05 / bug-07 honor `RLP_DESK_NODE_PATH`; pre-merge AC3.1a sample is now achievable.
- A2 dry-run placement (audit C3). Runbook splits into A2 (pre-bump: tolerate EPUBLISHCONFLICT, verify auth + tarball) and A2' (post-bump: strict exit-0 dry-run).
- A5 trigger-file oracle anchor (audit H1). Uses runtime-derived commit SHA of the prior version-bump commit, not a non-existent `vX.Y.Z` git tag.
- markLockStart timestamp inversion (audit H3). Moved BEFORE `lockSentinel` chmod in reapProducer so `sentinel_lock_to_unlock_ms` covers full lock duration including chmod execution.

### Strengthened
- Real-LLM SV scenarios bug-05 (worker-dead-on-reuse) and bug-07 (post-sentinel-race) now run two-stage assertions when invoked with `RLP_LIFECYCLE_METRICS=1`:
  - Stage 1 (presence): `lifecycle_metrics` field non-null in `campaign.jsonl`.
  - Stage 2 (value): observed metrics within tolerance bands. Default NON-BLOCKING; flip to BLOCKING via `B3_STAGE2_BLOCKING=1`.
- bug-06 retains structural-only check ($0 cost; deterministic injection deferred to PR-B5 per ADR follow-ups).
- New unit tests:
  - `tests/node/test-sentinel-reaper-invariant.test.mjs` — 6 invariant cases including B2-FIX primary target (case 5: done-claim ALIVE pane → reap).
  - `tests/node/test-lifecycle-metrics.test.mjs` — 10 LifecycleMetricsCollector cases.
  - `tests/node/test-campaign-jsonl-shape.test.mjs` — 4 shape contract cases (flag-on/off + sentinel context).
  - `tests/node/test-b3-band-revalidation.test.mjs` — 17 cases for revalidation harness pure helpers (audit L2).
  - `tests/node/us006-campaign-main-loop.test.mjs` — Bug-7-C-negative case added (audit M1).
  - `tests/test_b2fix_sentinel_lock.sh` — 9 zsh PART-A code-pattern + PART-B helper-behavior assertions.
- sv-gate-fast: 48 → 71 (+23 guards across B2-FIX, B4, B3, audit fixes).
- Node test suite: 339 → 377 (+38 cases).

### Documentation
- `docs/plans/v0.15-phase-b-lifecycle-audit.md` — B1 lifecycle audit (sentinel write-attribution, B4 metric proposal, ASCII diagrams). §4.5 appended with empirical revalidation update (audit H4).
- `docs/plans/v0.15-phase-b-plan-v3.md` — APPROVED ralplan plan v3 (Planner→Architect→Critic).
- `docs/plans/v0.15-phase-b3-revalidation-findings.md` — pre-merge band revalidation findings (synthetic vs empirical drift, refit table).
- `docs/plans/v0.15.4-pre-release-audit.md` — operator audit found 16 issues + 4 false positives. §9 per-finding fix status added.
- `docs/plans/v0.15.4-release-runbook.md` — release runbook with 7-phase pipeline (4 user gates), nightly schedule (§7.5), deferred follow-ups (§7.6 Phase D), failure-mode summary (§8).

### Internal (packaging)
- npm tarball no longer ships internal planning documents (`docs/plans/`). User-facing reference docs at `docs/rlp-desk/` continue to ship unchanged. `package.json` `files` glob narrowed from `"docs/"` to `"docs/rlp-desk/"`. Saves ~280KB per install.

### Migration notes
- No breaking changes. Existing 0.15.3 installations should upgrade smoothly via `npm install -g @ai-dev-methodologies/rlp-desk@0.15.4`. The postinstall script unlocks 0o444-protected files before overwriting (per CLAUDE.md upgrade-path EACCES guard).
- New `RLP_LIFECYCLE_METRICS` env flag defaults OFF — no behavior change for existing pipelines.
- Real-LLM SV scenarios accept new `RLP_DESK_NODE_PATH` env override but default to installed leader (backwards-compatible).

## [0.15.3] — earlier release

See git log: `git log e0efaba` (chore: bump version to 0.15.3) for the 0.15.3 history.

## Older versions

For changelog-style notes prior to 0.15.4, refer to:
- `git log <version-bump-commit>` for each `chore: bump version to X.Y.Z` commit
- GitHub Releases at https://github.com/ai-dev-methodologies/rlp-desk/releases
- `docs/plans/v0.15-stabilization-plan.md` for v0.15.x stabilization track context

[Unreleased]: https://github.com/ai-dev-methodologies/rlp-desk/compare/v0.15.4...HEAD
[0.15.4]: https://github.com/ai-dev-methodologies/rlp-desk/compare/v0.15.3...v0.15.4
