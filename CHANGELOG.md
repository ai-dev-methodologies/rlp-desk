# Changelog

All notable changes to `@ai-dev-methodologies/rlp-desk` are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/).

For pre-v0.15.4 versions, refer to `git log` and individual GitHub release notes.

## [Unreleased]

### Planned (not yet shipped)
- v0.15.5-era candidate: flip `RLP_LIFECYCLE_METRICS=1` default to ON (gated on 3 consecutive nightly real-LLM SV passes per `docs/plans/v0.15.4-release-runbook.md` §7.5.2).
- Later: remove `RLP_LIFECYCLE_METRICS` flag entirely (per plan v3 ADR follow-ups).
- Phase D.1 (handoff documents) + Phase D.2 (per-stage agent role specialization) — both deferred per `docs/plans/v0.15.4-release-runbook.md` §7.6.

## [0.21.0] — 2026-07-10

### Changed
- **Consensus defaults moved to the GPT-5.6 generation**:
  `--consensus-model` default is now `gpt-5.6-terra:medium` (was
  `gpt-5.5:medium`) and `--final-consensus-model` default is
  `gpt-5.6-sol:high` (was `gpt-5.5:high`), in both the zsh and Node leaders.
  Explicit flags and env overrides are unchanged; gpt-5.5 remains a fully
  supported model. Accounts without GPT-5.6 access should pass
  `--consensus-model gpt-5.5:medium --final-consensus-model gpt-5.5:high`
  (or set the env vars) when enabling consensus.
- Init brainstorm presets recommend the 5.6 generation
  (`gpt-5.6-terra:medium` recommended, `gpt-5.6-sol:high --consensus all`
  for critical work); README preset descriptions now mirror the actual init
  output.

## [0.20.0] — 2026-07-10 (Tier-1 dogfood release: git tag only, not published to npm)

GPT-5.6 model-generation support (codex-cli 0.144 catalog).

### Added
- GPT-5.6 family in the shipped model ladder (`src/node/models.json`):
  `gpt-5.6-sol` (frontier) and `gpt-5.6-terra` (balanced) climb
  low → medium → high → xhigh → **max → ultra**; `gpt-5.6-luna`
  (fast/affordable) ceilings at **max** (the catalog gives luna no ultra
  tier). `gpt-5.4` and `gpt-5.4-mini` ladders (low..xhigh) added as
  previous-generation options. Existing gpt-5.5 / spark / claude ladders
  unchanged.
- `sol` / `terra` / `luna` aliases expand to their full slugs in all three
  parse sites (zsh `parse_model_flag`, zsh env-path parser, Node CLI
  `parseModelFlag`) — same convention as the existing `spark` alias.
- `max` and `ultra` accepted by the consensus model validation (D-1c).
- `src/model-upgrade-table.md` now carries the full codex catalog (models,
  positions, supported efforts, catalog defaults) and 5.6 ladder tables.

### Fixed
- Codex idle/ready status-line detection (`is_codex_idle_ui` in the zsh
  leader, `CODEX_IDLE_RE` in the Node prompt-dismisser) now recognizes
  SUFFIXED model slugs (`gpt-5.6-sol`, `gpt-5.3-codex-spark`) and the
  max/ultra efforts. The old pattern (`gpt-X.Y` + low..xhigh only) matched
  neither — spark idle detection had silently depended on the other idle
  markers, and 5.6 campaigns would have too. The pattern is now anchored to
  line start so a status-line shape quoted mid-prose is not misread as idle.

### Changed
- The brainstorm model recommendation table (`/rlp-desk` command) now
  recommends by complexity: `gpt-5.6-luna:medium` (LOW),
  `gpt-5.6-terra:medium` (MEDIUM, default), `gpt-5.6-sol:high` (HIGH),
  `gpt-5.6-sol:xhigh` (CRITICAL) — `:max`/`:ultra` stay reserved as
  upgrade-ladder headroom. gpt-5.5/5.4 remain fully supported.
  Runtime defaults (worker `haiku`, consensus `gpt-5.5:medium/high`) are
  unchanged in this release.

## [0.19.0] — 2026-07-09 (Tier-1 dogfood release: git tag only, not published to npm)

narrow-v1 campaign: single-sourced model ladder, structural-test pruning,
two-tier release process, README repositioning. Consensus-planned
(Architect + codex Critic) and per-US codex-reviewed.

### Changed
- US-001: the Worker model-upgrade ladder is now single-sourced from
  `src/node/models.json`, read at runtime by both the `--mode tmux` (zsh)
  and Node native-mode leaders instead of two independently hardcoded
  tables. An optional user override can be placed at
  `${RLP_DESK_MODELS_FILE:-~/.claude/rlp-desk-models.json}` (outside the
  postinstall-managed tree); precedence is override → shipped defaults → a
  3-entry emergency inline ladder if both are missing or malformed. See
  `src/model-upgrade-table.md` for the reference view of the shipped table.
- **Node native-mode behavior change**: `gpt-5.5:low` and
  `gpt-5.3-codex-spark:low` now upgrade to their `:medium` tier on repeated
  same-US failure. Previously these two starting tiers were absent from
  Node's hardcoded `MODEL_UPGRADES` table, so a campaign started at `:low`
  in native mode was silently treated as already at the ceiling (immediate
  `BLOCKED`) instead of climbing the ladder. The `--mode tmux` (zsh) leader
  already had the correct `:low → :medium` step; this aligns Node to match.
  Claude `haiku`/`sonnet`/`opus` were also previously absent from Node's
  table entirely (any claude worker in native mode was instantly `BLOCKED`
  on repeated failure) and now resolve correctly too.
- US-002: pruned structural grep tests — no assertion consumes output of
  the real product runtime, and none pins a contract of an SV-trigger file
  — out of the active shell test harness. Some archived files do execute
  hand-copied or hand-simulated shell logic rather than the real product
  code (e.g. a sed/grep/tr pipeline retyped as literal text, or OS-level
  lock probes standing in for the real locking function); that is exactly
  why they are archived rather than kept as-is, since a hand-copy can
  silently diverge from the real implementation it mirrors. Of 69
  `tests/test_*.sh` files, 7 were archived to `tests/structural-archive/`
  (excluded from `npm run test:zsh`'s glob); 49 stay as behavioral (execute
  real runtime code/output) and 13 stay as structural-contract (pin a
  contract of `src/commands/rlp-desk.md`, `src/governance.md`, or a
  prompt/template section of `src/scripts/init_ralph_desk.zsh` — the three
  SV-trigger files, none of which have other enforcement for that text).
  See `docs/plans/narrow-v1-test-inventory.md` for the full per-file
  classification and rationale.

### Docs
- US-003/US-004/US-005: declared the supported platform matrix (macOS primary,
  Ubuntu Linux CI/server, best-effort elsewhere) in the README; restructured
  CLAUDE.md's Release Workflow into two tiers (Tier-1 default dogfood: commit
  → FF merge → `git tag` → local sync + retained §4.5 verification, no
  registry ceremony; Tier-2 on-demand registry release: the existing full
  runbook), with `docs/plans/v0.15.4-release-runbook.md` scoped to Tier-2
  only; and repositioned the README's opening pitch around the durable
  file-based state, independent verifier governance, and cross-family
  (claude x codex) consensus moat, with the fresh-context loop described as
  the mechanism rather than the headline.

## [0.18.8] — 2026-07-09

Consensus reporting and circuit-breaker budget fixes on the `--mode tmux`
(zsh) leader.

### Fixed
- Campaign `metadata.json` now derives its `consensus` field from the unified
  `CONSENSUS_MODE` (off|all|final-only). It previously read the legacy
  `VERIFY_CONSENSUS` flag, so campaigns started with `--consensus all`,
  `--consensus final-only`, or `--final-consensus` were falsely recorded as
  `consensus: 0`. The `consensus_flow` debug line had the same legacy read and
  now fires for every active consensus mode, including the mode name.
- `EFFECTIVE_CB_THRESHOLD` (the consecutive-failure circuit-breaker budget,
  doubled when consensus is active) is now computed after CLI flags are
  parsed. It was previously fixed at module load, so CLI-driven consensus
  modes never received the doubled budget (env-driven activation was
  unaffected). Covered by the new deterministic suite
  `tests/test_consensus_metadata_mode.sh` (10 cases, TDD red→green).

## [0.18.7] — 2026-07-08

Test-harness correctness release. No runtime behavior changes; the shipped
tarball delta is the `test:zsh` script fix in `package.json`.

### Fixed
- `npm run test:zsh` now dispatches each shell test suite to its declared
  interpreter (shebang-aware). It previously forced zsh onto bash-shebang
  suites, where `BASH_SOURCE` is empty — those suites mis-resolved their
  repo root and failed regardless of product correctness.
- Repaired the 18 shell test suites that drifted while the harness was
  broken: v0.13.0 `.rlp-desk/` runtime-path migration mirrored into test
  fixtures, assertions re-pointed to the current lock/consensus/final-verify
  implementations (with in-test provenance comments), and 3 latent
  test-harness bugs fixed (tmux stub format-argument matching; `grep -c`
  double-zero arithmetic breakage). Full shell suite now green: 68/68 files.

## [0.18.6] — 2026-07-07

Leader hardening, cross-platform correctness, and safety guards on the
`--mode tmux` (zsh) production path, plus documentation accuracy fixes.

### Security
- Campaign slug is now validated (`^[a-z0-9][a-z0-9-]*$`) before any filesystem
  work in both the init and run leaders, and in the `clean`/`run`/`status` CLI
  commands. A slug containing path separators or `..` is refused up front instead
  of being interpolated into `mkdir`/`rm` paths.
- Worker/verifier prompt hand-off no longer writes a predictable world-readable
  temp file under `/tmp`. It pipes through the tmux paste buffer directly, with a
  `0600` fallback that is cleaned up inline.

### Fixed
- Recovery freshness checks now read file modification time correctly on Linux
  (GNU `stat` is tried first), fixing a case where the recovery gate could
  misbehave on GNU/coreutils systems.
- `status` output no longer depends on fields the zsh leader never writes; the
  iteration ceiling and the optional final-verifier segment render from the
  fields that are actually present.
- API-overload detection in the poll loop is now anchored to the tail of the pane
  so an unrelated line mentioning a bare status code is not mistaken for a real
  API error; the retry counter resets when the worker makes progress.
- `--with-self-verification` reads the analytics output the zsh leader actually
  wrote (via a pointer file), with a fallback to the legacy location.

### Changed
- An unknown `--mode` value now fails fast with a clear error instead of silently
  falling through.

### Docs
- README, protocol reference, and signal-protocol docs now state the three run
  modes accurately: `tmux` is the production default (zsh leader), `native` is
  slash-command only, and `agent` hard-errors (ADR-001).

### Internal
- `npm install` upgrade path is hardened against a previously write-locked
  (`0o444`) install tree.

## [0.18.4] — 2026-06-26

Internal leader-hardening and packaging hygiene. No behavior change on the
`--mode tmux` (zsh) production path.

### Fixed
- The published npm package no longer ships a stray ~170 kB local development
  script (`src/scripts/.run_src_verify.zsh`) that had been accidentally bundled
  via the `files` allowlist in 0.18.0–0.18.3.

### Internal
- Node leader (dead code for `--mode tmux`): the verifier dispatch now clears any
  stale verdict (canonical + legacy path) before launching, so a leftover verdict
  cannot be misread for the next user story/iteration — defensive parity with the
  zsh leader's existing guard. Covered by 6 new Node tests (393/393), codex-reviewed.
- Removed a dead consensus retry-loop and a redundant EXIT trap from the zsh leader
  (behavior-neutral cleanup).
- Documented the heartbeat freshness block as inert-by-design (comment-only).

## [0.18.3] — 2026-06-26

Leader correctness fixes from two fresh adversarial-audit passes, each verified
against the actual code paths. All affect the `--mode tmux` (zsh) production leader.

### Fixed
- User-story coverage is now derived consistently from `### US-NNN:` headings
  everywhere. A US id mentioned only in prose/dependencies (e.g. "builds on US-009")
  no longer inflates the story list or the completion-coverage count — which had
  prevented some per-US campaigns from recognizing they were complete.
- Worker/Verifier completion signals are accepted only when they contain valid JSON
  (a worker that exits having written a truncated/empty signal is no longer treated
  as a finished result).
- A Verifier that exits without producing a verdict is now relaunched as a verifier
  (correct model/prompt) instead of being mis-restarted as a worker.
- Dirty-work detection now functions in a brand-new repository with no commits yet
  (previously a Worker that staged but never committed could go undetected).
- The final verification no longer reads a stale verdict from a previous iteration
  on recovery/finalize iterations.

### Internal
- Added deterministic test coverage for the worker model-upgrade ladder and the
  crash-relaunch state-restore field contract.

## [0.18.2] — 2026-06-25

Five leader-resilience fixes (per-us, consensus, and config-validation paths), each
validated by a real-LLM dogfood. Consensus is opt-in; default per-us campaigns benefit
from the final-verify and config-validation fixes.

### Fixed
- Final verification is resilient to verifier non-determinism: a user story that already
  passed its per-US check is re-verified (up to a small bound) on a fail verdict, so a
  flaky false-fail must reproduce before it charges a fix-loop failure. A single
  non-deterministic false-fail can no longer block a complete, correct campaign.
- The `claude` rate-limit banner ("API Error: … temporarily limiting requests … · Rate
  limited") is now recognized as a transient API condition and routed to the bounded
  backoff, instead of being misclassified as a frozen-pane deadlock.
- Numeric configuration knobs (e.g. `--max-iter`, `--cb-threshold`, timeouts) are now
  validated: a non-integer or out-of-range value falls back to its default with a warning,
  instead of silently mis-evaluating (a bad `--max-iter` previously could make a campaign
  run zero iterations).
- Leader auto-commit recovery no longer blocks a campaign whose work the worker already
  committed (a commit-timing race previously surfaced as "nothing to commit" → blocked).
- `--consensus final-only` now actually runs at the final verification in the default
  per-us verify mode (it was previously bypassed by the sequential final-verify path, so
  the recommended consensus configuration was a silent no-op in the default mode).

## [0.18.1] — 2026-06-25

### Fixed
- End-of-campaign resilience: when the last user story passes its per-US verify, the
  leader now runs the final verification directly instead of dispatching one more
  worker iteration solely to hand off to the final verify. That extra round-trip was a
  fragile dependency on a healthy worker at the very end of a campaign (a worker stall
  or API rate-limit at that moment could block a campaign whose work was already
  complete and verified). Per-US campaigns now finalize without it.

## [0.18.0] — 2026-06-24

**Leader hardening: campaigns that complete.** The `--mode tmux` leader's decision
gates used to TERMINATE where they should RECOVER, so campaigns could stall at
`--max-iter` or block on a single transient slip. This release resolves that
"never completes" failure class.

### Fixed
- A single transient `blocked` verdict no longer ends the campaign. A fresh-context
  Worker/Verifier mis-emitting `blocked` once now gets grace (soft-fail + retry);
  termination only on a genuine infra failure or a repeated/consecutive block.
- Verifier phrasing variants (`completed`/`done`, lowercase `all`) no longer strand a
  genuinely-complete campaign at the iteration cap — recommendation/us_id normalized at read.
- Mixed-engine dead-pane detection: a dead pane is detected per role when Worker and
  Verifier run different engines (e.g. claude worker + codex verifier).
- No double-credit of a re-submitted User Story on the verify pass-path.
- Final verification now retries a single transient poll failure instead of charging a
  false fail at the end of the campaign.
- Durable sentinels: atomic writes detect truncation (disk-full/SIGPIPE) instead of
  renaming a half-written file into the canonical path.
- Race-safe locks: the runner-lock and per-slug lock close an ABA/empty-owner race that
  could let two leaders run on one project root.
- Done-claim freshness gate: auto-synthesis rejects a stale/wrong-US done-claim, preventing
  the wrong User Story from being credited.
- Model-upgrade state survives relaunch: a resumed campaign keeps the upgraded worker model
  instead of resetting to the CLI default.
- codex 0.141 worker compatibility: the directory-trust prompt is accepted and MCP disabled
  so codex workers don't block on startup.

### Changed
- Stronger final verification: `--final-verifier-model` / `--final-verifier-effort` are now
  actually used for the final ALL-verify pass (previously every verify ran at the per-US
  model). "Final = stricter" now holds.
- Consensus cross-verifier model knobs now take effect: `--consensus-model` (per-US, lighter)
  and `--final-consensus-model` (final, stricter) are wired into the consensus path —
  previously documented but inert.
- Verifier FORMAT meta-gates softened cross-engine while correctness gates stay strict
  (fewer false fails on phrasing, no weakening of substance).

## [0.17.0] — 2026-06-19

**BREAKING (ADR-001): `node run.mjs run <slug> --mode agent` (the deprecated Node-leader direct-CLI alpha) now hard-errors.** Per the schedule announced in 0.16.0, the `--mode agent` entry point exits 2 with a redirect, and the Node-CLI default mode flips from `agent` to `tmux` (the canonical production leader). The `src/node/**` engine modules are retained (they back the Native Agent() path and the test suite); only the direct-CLI `--mode agent` *dispatch entry* was removed. **Migration:** replace `node run.mjs run <slug> --mode agent` with `--mode tmux`. The slash command's `--mode native` default is unaffected.

### Changed
- `node run.mjs run <slug>` (no `--mode`) now defaults to `--mode tmux` and delegates to the zsh leader, instead of the deprecated Node leader.

### Fixed
- Four shipped files referenced `docs/multi-mission-orchestration.md`; corrected to the real shipped path `docs/rlp-desk/multi-mission-orchestration.md` (dead link on fresh installs). Added a docs-link-resolve test.
- `uninstall` now removes the `UNLOCK.md` marker (and unlocks 0o444 files before unlink), so the `ralph-desk/` directory is fully removed.
- The A4 fallback iteration-signal write now goes through the atomic `atomic_write` helper (temp+rename) instead of a raw redirect.

### Changed (packaging)
- The shipped `examples/calculator` scaffold moved from the legacy `.claude/ralph-desk/` path to `.rlp-desk/` (v0.13.0+ convention) and no longer ships generated runtime state.

## [0.16.0] — 2026-06-18

Leader consolidation (ADR-001): `--mode tmux` is now the canonical production leader, self-verification works on it, and the deprecated `--mode agent` Node-CLI path is on a dated removal schedule.

### Added
- **Self-verification now works under `--mode tmux`.** `--with-self-verification` previously required the deprecated `--mode agent` path; the report is now generated by a pure-filesystem post-pass that runs after the zsh leader exits (reading the campaign's done-claim/verdict artifacts), so the canonical production path gets SV reports without the `claude --print` no-TTY hang.

### Deprecated
- **`node run.mjs run <slug> --mode agent` (Node-leader CLI alpha) is on a dated removal schedule** (ADR-001): 0.16.x louder banner → **0.17.0 hard-error** (and the Node-CLI default flips to `tmux`) → 0.18.0 dispatch branch removed. The `src/node/**` engine modules are retained throughout. Migrate direct-CLI wrappers to `--mode tmux` (canonical). This does NOT affect the slash command's `--mode native` default.
- **The flywheel (`--flywheel` / `--flywheel-guard`) is deprecated.** It was only ever implemented in the deprecated `--mode agent` Node path (never in the canonical zsh leader, despite a stale comment that claimed otherwise). Its only output, the advisory `next_mission_candidate` field, has no shipped runnable consumer. It will not be ported to the canonical leader; use a consumer-side wrapper for multi-mission chaining.

## [0.15.6] — 2026-06-18

Patch: CI/test integrity, a codex command-builder security fix, and documentation reconciliation.

### Fixed
- **Codex worker command no longer passes model/reasoning unquoted.** `buildCodexCmd` now shell-quotes the model and reasoning values (parity with the claude path), closing a shell-injection / argument-splitting hazard when operator-supplied flags reach the shell via tmux send-keys.
- **Docs now describe the correct execution modes.** The README "execution modes" section conflated the slash-command default (`--mode native`, `Agent()`-based) with the deprecated `--mode agent` (Node CLI). It is rewritten to the accurate three-mode model: `--mode tmux` is the canonical/recommended path, `--mode native` is the default companion for short/interactive use, `--mode agent` is deprecated.
- **Docs now point to the correct scaffold path.** Getting-started and README referenced the pre-v0.13.0 `.claude/ralph-desk/` project-local path; corrected to `.rlp-desk/` (the global install path `~/.claude/ralph-desk/` is unchanged).

### Changed
- **CI now runs the behavioral test suites.** A new CI job runs `test:node` + `test:zsh` (previously CI ran only the existence-grep fast gate). First rollout is non-blocking to inventory CI-only flakiness before being made blocking.
- **The full SV gate verifies the source tree.** `sv-gate:full`'s real-campaign E2E now targets the in-repo `src/` leader (and the correct `.rlp-desk/` sentinel paths) instead of the installed copy, so the gate validates the code being merged.

### Added
- **ADR-001 (Leader Consolidation).** Records the decision to make `--mode tmux` the canonical production leader, deprecate the `--mode agent` Node-CLI entry point on a dated schedule, and retain `--mode native` as a second-class companion. (Internal; not shipped in the tarball.)

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
