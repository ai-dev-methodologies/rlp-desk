# Changelog

All notable changes to `@ai-dev-methodologies/rlp-desk` are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/).

For pre-v0.15.4 versions, refer to `git log` and individual GitHub release notes.

## [Unreleased]

### Planned (not yet shipped)
- Phase D.1 (handoff documents) + Phase D.2 (per-stage agent role specialization) — both deferred per `docs/plans/v0.15.4-release-runbook.md` §7.6.

### Added
- **Luna-first cost routing.** Workers now default to the cheapest capable
  GPT-5.6 tier (2026-07-30 price cut: luna = 4% of sol) with evidence-gated
  escalation: `luna:high → luna:max → terra:max → sol:xhigh`. Campaigns with
  HIGH-complexity US choose a long-term/cost lane (terra:max quota hop) or a
  speed lane (straight to sol) at brainstorm time. Verifier/consensus models
  are now complexity-tiered (sonnet-5/opus-5 verifiers, luna→sol consensus);
  the final gates are claude-fable-5:max + gpt-5.6-sol:xhigh.
- **Effort-aware iteration timeout.** Worker budgets scale ×1.5 (`:xhigh`) /
  ×2.0 (`:max`) so slow-but-cheap efforts don't convert savings into timeout
  retries. Both leaders.
- **Campaign cost summary.** The campaign report now includes a
  sol-equivalent cost total (sol 1.0 / terra 0.4 / luna 0.04) and per-US
  escalation counts.
- **`environment` failure category.** Harness/tooling/capacity failures and
  verifier safety-classifier refusals no longer climb the model ladder.

### Changed
- **BREAKING (ladder policy):** partial reversal of the v0.22.5 "no max/ultra
  in the ladder" rule (32d181a) — for luna only. Sol/terra keep the xhigh
  ceiling. Existing `~/.claude/rlp-desk-models.json` overrides are unaffected
  (override precedence unchanged).
- `--consensus-model` default `gpt-5.6-terra:medium` → `gpt-5.6-terra:high`;
  `--final-consensus-model` default `gpt-5.6-sol:high` → `gpt-5.6-sol:xhigh`.

## [0.22.23] — 2026-07-22

### Added
- **Run-scoped evidence archive — past verdicts are never lost.** A campaign's
  per-iteration evidence (done-claim, verify-verdict, and now the iter-signal) used
  to be overwritten by a later run (a bare restart resets the iteration counter) or
  deleted outright by `init --mode fresh|improve`. Those artifacts — the durable
  receipts behind the verified ledger — are now **relocated, never deleted**, into
  `logs/<slug>/runs/superseded-<timestamp>/`: the leader moves a prior run's
  `iter-*` aside at startup before writing, and a fresh/improve re-execution moves
  the `iter-*` artifacts, the runtime memos, and `verified.jsonl` there too (the
  live paths still start clean). `ledger-seed --evidence` accepts the archived
  paths, so a past pass verdict can always be re-bound to a revised PRD.

### Fixed
- **Reused-pane redispatch no longer fails to launch the worker.** When a worker
  is redispatched onto a reused tmux pane, rlp-desk now waits for the pane's shell
  to actually reclaim the foreground (process-based readiness) before pasting the
  launch command — instead of treating the previous run's leftover output as
  "ready" and pasting into a process that had not yet exited (which lost the paste
  and produced a spurious "worker failed to start" after three sub-second retries).
  The shell-ready timeout is raised to 8s and the retry interval to 0.8s.

## [0.22.22] — 2026-07-22

### Added
- **The gate-receipt now seals the test-spec too, not just the PRD.** When you seal a
  campaign with `gate-receipt <slug>`, the content hash now covers the test-spec files
  (`test-spec-<slug>.md` and any per-US split) alongside the PRD. Editing a test-spec
  outside the formal re-gate path is surfaced as drift at run start, exactly like a PRD
  edit — so the verification contract can no longer drift silently after sealing.
- **Contract-revision audit chain.** When a sealed PRD or test-spec is found changed at
  run start, rlp-desk appends the change (which file, old→new hash) to an append-only
  `.rlp-desk/logs/<slug>/contract-revisions.jsonl`, giving you a durable history of every
  post-seal contract edit.
- **3-doc consistency lint (PRD ↔ test-spec ↔ per-US split).** A deterministic structural
  check catches an orphaned per-US split file, a test-spec that references an AC id the PRD
  doesn't declare, and per-US AC-count drift. It runs as a hard REJECT at `init` (the
  campaign hasn't started) and as a loud warning at run start.
- **`init` records the codex/claude CLI versions** to `.rlp-desk/logs/<slug>/init-env.json`
  as a diagnostic breadcrumb for CLI-release incidents (best-effort, never blocking; an
  absent tool is recorded as "not installed"). No version pinning or enforcement.
- **New `external_fact` blocked reason.** A campaign that halts because it needs an
  owner-supplied fact from outside the repo is now classified `external_fact`
  (recoverable=false, suggested action: update the contract and relaunch) instead of a
  generic block — making the halt machine-legible. Halt behavior is unchanged.
- **`verification-type` (검증형) work classification.** A user story whose deliverable is
  *confirming existing behavior* (where a failing-test-first / TDD RED phase is
  structurally impossible) is now recognized at brainstorm/init and automatically routed to
  the doctrine-based `verify_existing` gate, instead of being failed by the TDD-RED mandate.

### Changed
- **Infrastructure blocks now fail fast.** A block caused by an infrastructure failure
  (dead pane, verifier/worker exit, timeout, unverifiable git state) is now marked
  non-recoverable so a supervising wrapper investigates rather than blindly retrying. The
  genuinely-transient cases (API backoff exhaustion, model-capacity stall, tmux lifecycle
  restart) remain auto-recoverable. This aligns the tmux and Node leaders on one
  conservative recovery taxonomy.

## [0.22.21] — 2026-07-22

### Fixed
- **codex update dialog no longer stalls or falsely BLOCKs a campaign.** When a new
  codex-cli release shows its startup "✨ Update available!" dialog, rlp-desk now
  launches codex with the update check turned off (`-c
  check_for_update_on_startup=false`) so the dialog never appears — the durable fix,
  since the dialog's key handling changes between CLI releases. If the dialog does
  appear anyway, a single shared handler dismisses it (selecting Skip), and if it
  still cannot be dismissed the campaign now reports the true cause and remedy
  (**"codex update dialog could not be dismissed — run `codex update`"**) instead of a
  misleading "verifier never started" error.
- **Escape hatch.** Set `RLP_CODEX_UPDATE_CHECK=1` to restore codex's default startup
  update check (the dialog will appear and be dismissed by the shared handler).

## [0.22.20] — 2026-07-22

### Added
- **Leader pane stays visible at a readable width (tmux mode).** The Leader pane is
  a pane-creation anchor, but it is now kept at a readable minimum width
  (`RLP_LEADER_MIN_WIDTH`, default 30) at startup and each iteration, and widened to
  the split width (`RLP_LEADER_SPLIT_WIDTH`, default 110) before creating a Worker or
  Verifier pane. This removes the manual resize-before-relaunch step operators used to
  perform; a too-narrow pane that cannot be widened now reports a clear error instead
  of a raw tmux split failure.
- **Canonical layout is now enforced (tmux mode).** After every pane create/recreate,
  the runner verifies the canonical geometry — Worker/Verifier/Consensus in one right
  column, stacked top-down, in the Leader's own window and session. Layout drift (a new
  pane in a second column, another window, or another session) stops the campaign with
  a clear diagnostic instead of continuing silently. Both canonical forms — the 3-pane
  human-operator layout and the 4-pane AI-operator layout — are documented in the README
  and governance with diagrams.

## [0.22.19] — 2026-07-21

### Fixed
- **P1 regression from 0.22.18: worker/verifier launch could fail on a freshly
  created pane, blocking the campaign.** The launch echo-verification (added in
  0.22.18) inspected only the bottom rows of the pane. A brand-new pane draws its
  prompt at the TOP with blank rows below, so the check saw only blank lines,
  concluded the launch command had not pasted, and — after retries — failed the
  launch (observed as several consecutive restart deaths). The check now ignores
  blank lines so it works regardless of where the prompt is drawn, and a short,
  bounded wait for the shell to be ready was added before the first paste (tunable
  via `RLP_SHELL_READY_TIMEOUT_S`, default 6s; proceeds anyway on timeout).
- **P2: with several terminal windows attached, the campaign could attach its
  panes to the wrong tmux session.** The leader identified its own pane using a
  query that actually reports the *currently focused* pane, which — with multiple
  attached clients — could be a different window in another session, causing
  worker/verifier panes to be created there. The leader now uses its own shell's
  pane identity (immune to which window is focused) and derives the session from
  that pane, so panes are always created in the campaign's own session.

## [0.22.18] — 2026-07-21

### Fixed
- **P1: a codex "Selected model is at capacity" message could stall a running
  worker or verifier indefinitely.** When the model was already selected and the
  prompt submitted, a capacity notice would freeze the pane with no progress —
  the leader kept polling with no response until the whole iteration budget
  (30 min) ran out. The leader now recognises the capacity stall (banner visible
  and no progress) and automatically injects a resume line to continue, waiting a
  cooldown between attempts; if the capacity wall persists after several resume
  attempts it fails fast with an explicit `model capacity` BLOCKED status instead
  of stalling silently. A true usage-limit (quota) wall still stops immediately —
  it is never resume-injected. The resume text, capacity pattern, cooldown, and
  strike cap are all environment-overridable (`RLP_CAPACITY_RESUME_TEXT`,
  `RLP_CAPACITY_BANNER_RE`, `RLP_CAPACITY_REINJECT_COOLDOWN_S`,
  `RLP_CAPACITY_MAX_STRIKES`).
- **P2: campaign panes could be created in an unrelated tmux session.** When the
  leader was started detached (outside tmux), a worker/verifier pane split could
  land in whatever tmux session happened to be active — contaminating an
  unrelated project's session and later crashing the campaign when its pane
  bookkeeping broke. Every pane split is now pinned to the campaign session: the
  split target is verified before use, and any pane that ends up outside the
  campaign session is removed and reported instead of being used silently.
- **P2: a worker restart could fail to launch with an empty reasoning-effort
  setting.** After an automatic model upgrade, a leader restart could rebuild the
  codex launch command with an empty `model_reasoning_effort`, which codex
  rejects ("reasoning_effort must not be empty") — leaving the worker unable to
  start and the campaign BLOCKED. The original reasoning effort is now preserved
  and restored across restarts, and every codex launch is checked so an empty
  effort fails fast with a clear reason instead of a confusing start-up error.
- **P3: an interactive shell prompt could swallow the first character of a launch
  command.** If a pane's shell showed an interactive prompt (e.g. an oh-my-zsh
  `[Y/n]` update prompt) when the CLI launch command was pasted, the first
  character could be consumed — corrupting the command so the CLI never started.
  Launch commands are now echo-verified before submission: if the command did not
  paste intact, the line is cleared and re-pasted (up to three attempts) before
  giving up with an explicit launch failure.

## [0.22.17] — 2026-07-21

### Added
- **"Layer 1.5" done-claim format lint — a deterministic pre-gate that runs
  before the LLM verifier.** When a build-mode done-claim is submitted, the
  leader now machine-checks that every acceptance criterion it touches has its
  own labeled `write_test → verify_red → implement → verify_green` steps, in
  that order, in `execution_steps`. A comma list (`"AC1,AC2"`) counts for both
  ACs; the bundle label `"all"` does NOT satisfy any AC's four phases. A
  malformed claim is bounced straight back to the worker — with no LLM round
  spent — carrying per-AC coordinates (`idx=[write_test, verify_red, implement,
  verify_green]`, `-1` = a missing phase, non-monotonic = steps out of order) so
  the worker fixes only the claim format, not the deliverable. Confirmation and
  replay claims (no `write_test` step) are exempt, so already-verified work is
  never false-flagged. This closes a structural waste in consensus/cross-verify
  campaigns where a pure format defect on an otherwise all-green claim could
  burn a full 20-25min LLM cross-verification round. The same single definition
  is now stated in the worker prompt (so claims are written correctly up front)
  and honored by the verifier's Worker Process Audit (a claim that passes the
  lint is not re-failed on step-sequence/label-format grounds). Runs on both the
  zsh and Node leaders. Opt out with `RLP_DONECLAIM_LINT=0`.

## [0.22.16] — 2026-07-21

### Fixed
- **P2: a known non-exhaustion codex usage banner could hold a trigger prompt
  unsubmitted for up to 90 seconds per dispatch.** Banners like
  "You have 1 usage limit reset available" / "increased plan usage" /
  weekly-limit steal the submit keystroke: the trigger sits echoed in the
  input box and nothing runs until the 90s submission window re-injects.
  Both poll loops (codex verifier + generic) now detect the blocked state at
  the first poll tick (~5s) — trigger echoed AND no execution-start signal
  AND a known banner visible — and fire ONE early Enter re-inject; if the
  prompt still doesn't start, the existing 90s submit-anchored path takes
  over unchanged. Normal immediate-submit dispatches see zero re-injects
  (progress detection skips the nudge), and true quota exhaustion still
  fast-fails before any nudge. The banner pattern list is env-configurable
  via `RLP_SUBMIT_BANNER_RE` (codex CLI wording changes across versions).
  New failure-modes atlas entry F1.8.

## [0.22.15] — 2026-07-21

### Added
- **Work-type classification at the brainstorm gate (명세형/발굴형).** The
  unattended-completion check now also classifies every US as
  specification-type (contract can be written up-front → loop-eligible) vs
  discovery-type (debt cleanup, unknown-cause investigation, exhaustive
  enumeration — the contract only emerges by digging). Discovery-type US are
  REJECTED at the gate: run prior reconnaissance outside the loop, then
  convert the outcome into a specification-type US and re-inject. Includes
  AC-verb judgment hints and a mid-campaign rule for discovery fragments
  (split to a parallel supervisor investigation; re-inject only confirmed
  contracts). Governance side: new IL-2¾.
- **`ledger-seed` operator command — formal recovery path for stories that
  could never earn a consensus ledger entry** (e.g. an old-version defect
  blocked the pass that story-scoped confirmation needs).
  `node run.mjs ledger-seed <slug> <us_id> --evidence <claude-pass-verdict.json>
  --note "<operator note>" [--commit <sha>]` appends a PRD-hash-bound ledger
  entry after fail-closed validation: evidence must exist, parse as a single
  JSON object, carry a normalized `pass` verdict for exactly that `us_id`;
  the PRD must exist and contain the US; the commit anchor (default HEAD)
  must resolve and be an ancestor of HEAD. Every seed records `seeded:true`
  plus a mandatory `operator_note` for auditability. A seed never grants a
  pass — it routes verification mode only; both verifier legs still run
  their own fresh re-verification. Operator-only; run with the campaign
  stopped.

## [0.22.14] — 2026-07-21

### Fixed
- **P1: multi-US campaigns could never re-verify an already-verified story.**
  Confirmation mode required FULL PRD ledger coverage, so mid-campaign
  re-verification of a green story always ran under the strict build
  contract and failed codex consensus (CB → BLOCKED) even when the work was
  perfect. Per-US dispatches now derive a story-scoped mode: the story's own
  PRD-hash-bound ledger entry with a HEAD-ancestor commit grants
  confirmation for that story alone; every fail-closed check (PRD drift,
  unresolved commit, campaign-era dirt) is retained, and final/ALL
  verification keeps the strict full-coverage semantics unchanged.

## [0.22.13] — 2026-07-21

### Fixed
- **P1: healthy running verifiers were killed by the submission guard.** The
  progress predicate received tmux pane IDs from every polling call site but
  expected snapshot text, so no pane ever registered progress — the guard
  re-injected Enter into running TUIs and declared SUBMISSION failure at the
  timeout (4x field-reproduced claude-verifier kills). The predicate now
  captures %-prefixed pane ids itself; the newly observed "Osmosing"
  spinner verb is recognized.

## [0.22.12] — 2026-07-21

### Added — plan gates (field post-mortem: 6 BLOCKED / 9 manual restarts from an ungated PRD)
- **Unattended-completion mandate (IL-2½).** Campaigns must run with zero
  owner interaction: PRDs gain a REQUIRED "Delegated Decisions" section
  (scaffolded by init), owner-decision-style acceptance criteria are banned
  (legitimate BLOCK reasons are a closed 3-set: irreversible destruction,
  contract change, protected-path violation — stated in the worker prompt),
  and the brainstorm completion gate checks the PRD can complete unattended.
- **Gate-receipt binding.** `gate-receipt <slug>` records a deterministic
  PRD content hash + scorecard when the brainstorm gate passes; init/run
  recompute and compare, so a PRD written outside the gate or edited after
  it (new US, changed AC) is detected and surfaced loudly with a documented
  revise flow. Pre-receipt campaigns get a backward-compatible warning only.
- **`--worktree`**: opt-in campaign isolation in a leader-provisioned git
  worktree (campaign/<slug> branch, scaffold copy); shared-checkout edits can
  no longer contaminate campaign gates. Default path unchanged;
  `clean <slug> --remove-worktree` cleans up.
- BLOCKED sentinels carry a closed-set `cause` field
  (infra|contract_gap|defect) for automatic routing.

## [0.22.11] — 2026-07-21

### Fixed
- **Off-case/synonym verdicts can no longer false-BLOCK a campaign.** The zsh
  leader now normalizes every verdict read (mirroring the shared
  verdict-schema contract) before branching or feeding the
  unrecognized-verdicts circuit breaker; reporting normalizes once at its
  ingestion boundaries so all five report sections agree.
- **`--debug` now works on the production tmux path** (it was parsed but
  never forwarded to the zsh leader; only `DEBUG=1` in the environment
  worked).
- **git snapshot errors are fail-closed.** A failing git read during the t0
  preexisting-dirty capture or F-8 recovery now blocks with a clear
  infra_failure instead of silently passing as "clean tree"; a git error in
  the commit-integrity oracle forces a full verifier round without counting
  toward the oracle failure cap — an error can never corroborate a commit
  claim. Dependency checks run before the snapshot so missing-tool errors
  keep their actionable message.

## [0.22.10] — 2026-07-21

### Fixed
- **Parallel-consensus pane lifecycle parity.** The 4th (consensus) pane is
  now torn down by cleanup() like the worker/verifier panes, and a per-side
  liveness check in the parallel poll classifies a mid-round pane death as an
  infrastructure failure within ~2 poll ticks with correct attribution —
  previously it burned the full submit-anchored timeout window under a
  misattributed reason, and the pane could outlive the campaign.
- **Done-claim sentinel telemetry recorded only the last iteration's sample**
  (per-iteration mark overwrote the pending entry). The lock→close-out
  duration now emits at the archival site each iteration on both leaders;
  failure-modes F3.3 retired.
- us006 tmux test flake (deterministic pane-readiness handshake) and five
  unrunnable legacy audit scripts archived to `tests/legacy-audit-archive/`.

## [0.22.9] — 2026-07-20

### Added — campaign hardening v1 (post-mortem driven)
- **Done-claim commit-integrity oracle.** Done-claim commit steps now record
  the resulting `commit_sha`; before any LLM verification the leader verifies
  the claimed SHA against git (resolves, reachable from HEAD, HEAD advanced
  beyond a per-iteration snapshot) and that the tracked-dirty delta is clean
  (untracked and pre-campaign dirt excluded). A false commit claim
  short-circuits to a machine-generated COMMIT-INTEGRITY fix contract —
  no verifier round is burned. Separate failure counter with a
  force-verifier cap; honest iterations and no-commit modes are no-ops.
- **Fail-closed campaign waivers.** `.rlp-desk/plans/waivers.json` (bound to
  the campaign slug) lets a pre-existing baseline finding be waived ONLY with
  an immutable sha256-pinned baseline artifact containing that finding.
  Operator authorization is out-of-band via `--waivers-sha256 <hash>`;
  rejections are loud (six distinct diagnostics to status.json + logs);
  honored waivers are injected into both prompts and verdicts cite their ids.
  Campaign-introduced regressions are never waivable.
- **Verdict-schema normalizer.** One shared definition absorbs all three
  verdict producer shapes (`id|criterion|criterion_id`,
  `description|summary`); the SV report and fix contracts no longer render
  `undefined`/`unknown`/`unspecified` when the source JSON carries values,
  and reasoning-completeness reflects real categories. zsh fix-contract jq
  sites use equivalent fallback chains (3-producer golden parity fixtures).
- **Always-on launch breadcrumb.** `logs/<slug>/launch-record.json` is
  written synchronously at t0 by both production writers (run.mjs before
  flag parsing, enriched after; the zsh leader at startup) and finalized
  with the exit outcome via an HUP-extended trap — a campaign that dies
  before iteration 1 now always leaves a diagnosable record.

## [0.22.8] — 2026-07-20

### Fixed
- **Resumed campaigns no longer pin to build mode on unrelated resident dirt.**
  `derive_verification_mode`'s working-tree gate now fails only when
  (tracked-dirty MINUS `CAMPAIGN_PREEXISTING_DIRTY`) is non-empty, and the
  preexisting-dirty snapshot is captured BEFORE the resume-finalize mode
  derivation. The SHA anchor is unchanged; new campaign-era edits still force
  build mode. (Field case: codex strict-failed every resumed verification
  while claude passed — the asymmetry was mode misclassification, not a
  prompt-parity gap.)
- **Bug #8 F-8 leader-recovery auto-commit survives gitignored campaign
  artifacts.** Normal `git add`, then a `git add -f` retry strictly scoped to
  the worker-file list (with `--literal-pathspecs` so glob-metachar filenames
  cannot re-expand and sweep the tree), then warn+carryover+continue instead
  of a hard BLOCK. The carryover list feeds the next worker fix contract.
- **Unsubmitted prompts no longer amplify into timeout BLOCKs.** Multi-signal
  submission detection (banner-tolerant; non-exhaustion quota warnings don't
  suppress resubmission), and all polling paths (worker, sequential/final
  verifier, parallel consensus) anchor `ITER_TIMEOUT` at the FIRST progress
  signal. A deadline with no progress signal is classified as a SUBMISSION
  failure with bounded Enter re-injection / re-dispatch
  (`SUBMISSION_TIMEOUT`, default 90s; `SUBMISSION_MAX_REDISPATCH`, default 2).
- Claude worker/verifier launchers gained the lingering-process guard (a
  re-dispatch could previously paste the shell command into an idle claude
  TUI as a chat message).
- BLOCKED terminations now exit non-zero on every path (sentinel-based
  authoritative exit at the entry point); COMPLETE exits 0.

## [0.22.7] — 2026-07-20

### Added
- **Two-layer mechanical pre-gate (verification layering).** Before dispatching
  the expensive LLM verifier, the leader now runs: (Layer 1) an optional
  campaign-static gate script `.rlp-desk/plans/pregate-<slug>.sh` (absent =
  no-op; soft timeout via `--pre-gate-timeout`, default 300s), then (Layer 2)
  a replay gate that re-executes the `verify*` commands the worker recorded in
  done-claim `execution_steps[]` and compares actual vs claimed exit codes
  (equality — a `verify_red` claiming nonzero that replays nonzero matches).
  Only allowlisted test/check commands are replayed (dangerous patterns are
  skipped, never executed); per-command timeout via `--pre-gate-cmd-timeout`
  (default 120s). Any failure skips LLM verification and redispatches the
  worker with the mechanical output as a `PRE-GATE FAILURE` fix contract.
  Pre-gate failures use a separate counter (not CB `consecutive_failures`);
  3 same-US pre-gate failures force a full LLM verifier round. Iron Law
  compatible: the pre-gate only produces early FAILs — it never creates a
  pass, and full LLM verification always runs when it passes.
- **Parallel consensus verification** behind `--consensus-parallel`
  (default OFF; sequential behavior unchanged when off). When on, the claude
  verdict and codex cross-check run simultaneously (dedicated 4th tmux pane),
  with an evidence-isolation lock contract injected into both verifier
  prompts: DB-mutating/E2E evidence reruns serialize on a leader-provisioned
  mutex while static/unit/file checks stay parallel. Verdict merge and
  NO ENGINE PRIORITY semantics are unchanged (single shared finalize path).

## [0.22.6] — 2026-07-20

### Fixed
- **Versioned Claude model ids with reasoning effort no longer misroute to the
  codex engine.** `--verifier-model claude-opus-4-8:high`,
  `--final-verifier-model claude-fable-5:max`, and bracket forms like
  `claude-opus-4-8[1m]:high` now correctly classify as engine=claude in all
  three parse sites (zsh `parse_model_flag`, zsh `_auto_detect_engine` — the
  live `--mode tmux` path — and Node `parseModelFlag`). Previously only the
  short aliases (haiku/sonnet/opus) were recognized in the `model:effort`
  form, so any full `claude-*` id with a colon silently fell through to the
  codex engine (observed live as `engines.verifier: "codex"` in
  `session-config.json`, aborting per-US verification).

### Changed
- Unknown colon-bearing model names still route to codex but now emit a
  stderr warning (known codex slugs/aliases stay silent).
- Recommended run configuration is now fully explicit per role
  (model:effort for every role, no implicit defaults): per-US verifier
  `claude-opus-4-8:high`, final verifier `claude-fable-5:max`, cross-checks
  `gpt-5.6-sol:xhigh`. `--consensus-model`/`--final-consensus-model` remain
  codex-only; the claude leg of consensus follows the (now explicit)
  verifier / final-verifier model+effort.

## [0.22.5] — 2026-07-20

### Changed
- **GPT-5.6 upgrade ladder no longer uses `:max`/`:ultra`** (policy from
  tire-plletdata campaign operations). Effort ceiling is `:xhigh`; past
  `:xhigh` the ladder now jumps models instead of raising effort:
  `luna:xhigh → terra:high`, `terra:xhigh → sol:high`, and
  `gpt-5.6-sol:xhigh` is the final ceiling of the whole ladder. Cross-model
  entry is always `:high` (no effort regression). `:max`/`:ultra` remain
  parseable `--worker-model` starting points but are dead-end ladder keys.
- Cross-engine complexity mapping recommendations updated: HIGH starts at
  `gpt-5.6-sol:medium`, CRITICAL at `gpt-5.6-sol:high` (never at the
  ceiling, preserving upgrade headroom).
- Claude ladder (haiku→sonnet→opus) and previous-generation GPT ladders
  (spark / 5.4 / 5.4-mini / 5.5) are unchanged.

## [0.22.4] — 2026-07-14

### Removed
- The `RLP_LIFECYCLE_METRICS` opt-out flag. Lifecycle telemetry has been
  default-ON since v0.22.0 and two dogfood release cycles (v0.22.2, v0.22.3)
  passed with no opt-out use — per the plan v3 ADR follow-up, the flag and
  every gate site are gone and the five metrics are always emitted on both
  leaders. Setting the old env var is harmless (ignored). `campaign.jsonl`'s
  `lifecycle_metrics` field is now always an object (`{}` when an iteration
  produced no records); `null` indicates a collector failure, not an opt-out.

## [0.22.3] — 2026-07-14

Resume-safe verification + plan preservation. Fixes the 2x-reproduced
deadlock where restarting a campaign over an already-verified deliverable
could never re-reach COMPLETE, and stops `init --mode fresh` from
destroying operator-authored plans. Validated by live dogfood: the exact
previously-deadlocking resume scenario now completes in ~4 minutes with
both claude and codex consensus.

### Added
- **Confirmation-mode verification**: at verify dispatch the leader derives
  `verification_mode` from durable state — the verified ledger (now
  recording the HEAD commit SHA and the PRD content hash on every per-US
  credit, plus a leader-written ALL completion record on the COMPLETE
  path) checked against the current repo (SHA resolves, no tracked change
  since, clean tree). Full coverage + intact anchors → `confirmation`;
  anything missing or mismatched fails CLOSED to `build`. The mode is
  injected into both verifier prompts as the sole authoritative channel;
  in confirmation mode the Worker Process Audit judges on the verifier's
  OWN fresh reruns instead of demanding RED-before-GREEN evidence that
  cannot honestly exist for already-verified code.
- **Resume finalize**: a leader restart whose ledger already proves
  completion skips the worker round-trip entirely (re-arms D-16) — a
  resumed worker with nothing to build previously idled into the
  no-progress guard.
- `--reset-plans` flag for `init`: explicitly wipes the PRD/test-spec with
  a versioned backup (`prd-<slug>-v1.md`, ...).

### Fixed
- `init --mode fresh` preserves operator-AUTHORED plans (exact comparison
  against the pristine scaffold, per file); only untouched templates are
  regenerated. The verified ledger and stale per-US splits are now reset
  with the rest of the runtime state.
- An ALL/consensus failure no longer blanket-forbids repairing previously
  verified stories — the fix contract allows changes tied to the verdict's
  issues (Scope Lock retained).
- Verified-ledger hardening: append-then-lock (0444 between appends),
  checked appends with loud failure (safe build-mode degradation on loss),
  strict newest-line parsing (malformed or JSON+garbage entries fail
  closed).
- Worker done-claim schema: verification steps carry a `ts` timestamp
  (forensic evidence-age record).

## [0.22.2] — 2026-07-11

Codex 0.144 compatibility + fast-fail on provider quota exhaustion. Both
fixes were validated end-to-end in live dogfood campaigns (codex consensus
adjudicated multiple iterations; a fresh batch campaign reached COMPLETE
with gpt-5.6-sol:xhigh cross-verification).

### Fixed
- codex 0.144 renders its TUI input prompt as `❯` (U+276F); the worker and
  verifier launch ready-loops only accepted the 0.141 glyph `›` (U+203A), so
  a healthy codex pane was declared "not ready", the instruction was never
  sent, and the campaign blocked on a verdict timeout. Both launch
  ready-loops now accept either glyph (`tests/test_codex_ready_glyph.sh`).
- Provider quota exhaustion ("You've hit your usage limit") now fails fast:
  a dedicated `detect_quota_exhausted()` detector aborts the codex verifier
  poll loop immediately instead of burning the full `ITER_TIMEOUT`, and the
  BLOCKED sentinel names the cause ("provider usage limit reached — retry
  after the reset", `recoverable: true`) via `VERIFIER_ABORT_REASON`. The
  detector anchors on "hit your usage limit"/"usage limit reached" so the
  transient D-17a banner — which literally contains "(not your usage
  limit)" — stays on the recoverable backoff path
  (`tests/test_codex_quota_fastfail.sh`).
- The consensus hard-failure sentinel no longer claims "failed after max
  rounds" / `repeat_axis` when a verifier died before any verdict: it now
  reports the accurate reason and `infra_failure` category.

## [0.22.1] — 2026-07-10

Hardening sweep on the v0.22.0 lifecycle-observability work: 9 P2 findings
from a gpt-5.6-sol max-effort adversarial review, plus 9 follow-ups from
4 codex re-review rounds. All fixes TDD'd (emitter suite 72→100 cases).

### Fixed
- `pane_reap_latency_ms` contract text corrected: it records the same
  kill-start → process-exit-confirmed window as `pane_eof_to_cleanup_ms` on
  both leaders (the docs previously advertised a wider window the code never
  measured); equality is now regression-locked on both runtimes.
- Post-sentinel race window narrowed: metric capture before a pane reap is
  now fork-free (zsh `EPOCHREALTIME`/`zstat` builtins), all fork-bearing
  emission happens after the reap, and the codex A4-fallback path no longer
  reaps the same pane twice (fail-safe liveness recheck skips only when a
  successful probe shows a bare idle shell).
- Lifecycle lock/unlock metrics are only emitted when the lock/unlock chmod
  actually succeeded; lock marks are cleared only after a successful `rm`;
  pending lock pairs are flushed (with their own iteration attribution) on
  campaign completion instead of being lost.
- Invalid (negative/non-finite) timing values are dropped with a warning on
  BOTH leaders instead of being clamped to 0 (a clamp could false-pass the
  B3 tolerance-band gate).
- `campaign.jsonl` append failures are no longer silent: the writer verifies
  the append, retains unflushed records for retry, and completion-path
  failures retry once then log loudly (never blocking completion).
- `zmodload zsh/stat` is loaded with `-F ... b:zstat` so the external `stat`
  binary is not shadowed process-wide (a full load rebinds `stat` itself and
  breaks every later `stat -f/-c` call in the leader).
- Every `pane_eof_to_cleanup_ms` record now carries its iteration field.

## [0.22.0] — 2026-07-10

### Added
- **Lifecycle observability: full-wire on the zsh leader + default ON.** The 4
  lifecycle metrics that were Node-only (`iter_signal_write_to_read_ms`,
  `verdict_write_to_read_ms`, `pane_reap_latency_ms`, `sentinel_lock_to_unlock_ms`)
  are now wired into `src/scripts/run_ralph_desk.zsh` / `lib_ralph_desk.zsh`,
  matching the zsh leader's existing `pane_eof_to_cleanup_ms` emitter. All 5
  metrics are emitted identically on both the Node (slash-command
  `--mode native`) and zsh (`--mode tmux`) leaders. `RLP_LIFECYCLE_METRICS` now **defaults to ON**;
  set `RLP_LIFECYCLE_METRICS=0` to opt out. See README.md "Lifecycle
  Observability" for the metric table.

### Fixed
- `RLP_LIFECYCLE_METRICS` semantics unified across leaders: any value except
  `0` enables (previously the zsh leader required exactly `1`, so e.g.
  `=true` disabled tmux telemetry while enabling native).
- Lifecycle sentinel lock/unlock pair hygiene: stale lock marks are now
  cleared on every monitored-file mutation — structurally via a clear hook
  inside `atomic_write()` (after a successful replace), explicit clears at
  the 4 `rm` sites, and the quarantine `mv`. Prevents false
  `sentinel_lock_to_unlock_ms` values from cross-instance pairing. One raw
  `>` redirect (codex worker-exit signal synthesis) was converted to
  `atomic_write`, additionally gaining truncated-write protection.

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
