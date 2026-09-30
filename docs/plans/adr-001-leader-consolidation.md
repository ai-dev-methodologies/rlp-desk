# ADR-001: Leader Substrate Consolidation

> Status: **ACCEPTED** (2026-06-17) · Supersedes the ambiguous "3 substrates" status quo.
> Scope: governance/architecture decision. Implementation is staged and gated (see §5).
> Not shipped in the npm tarball (`docs/plans/` is excluded); user-facing parts surface via CHANGELOG + docs.
> **See [Amendment 2026-09-29](#amendment-2026-09-29)**: corrects the §2 claim below that `src/node/**`
> "remain[s] the engine the Native Agent path and tests build on" — the Native Agent() path invokes no
> Node runner module.

## Context

The audit (63 confirmed findings) + a live fresh-context dogfood established that rlp-desk's
single largest structural problem is **leader-substrate parity drift**. One protocol is implemented
in THREE leaders with divergent fidelity:

| Substrate | Invoked by | Maturity | Coverage | Safety net |
|---|---|---|---|---|
| **zsh + tmux** (`run_ralph_desk.zsh` etc.) | `--mode tmux` | **stable / production** | ~80 zsh tests + real-tmux gate | heartbeat, copy-mode guard, prompt-stall timeout, no-progress detection, model-upgrade chain |
| **Node** (`src/node/**`) | `--mode agent` (direct Node CLI) | **deprecated alpha** | 378 node tests | partial; no full watchdog parity (NODE-CB-1/AUTO-1) |
| **Native Agent** (slash prose) | `--mode native` (slash command default) | shipped, **least-tested** | prose validated only by grep (GAP-3) | **none — no iteration watchdog (GAP-4)** |

Confirmed consequences (audit): flagship features are scattered one-per-substrate (ARCH-2 — consensus in
zsh+native, flywheel/SV only in the deprecated Node path); the DEFAULT path (native) has zero behavioral
test coverage and no watchdog; nearly every runtime defect is "works in one leader, no-ops/misbehaves in
another." The dogfood independently hit this: a PRD that ran under zsh hard-failed under the Node leader
(D-5), and the Node leader's blocked-state had no recovery path (D-6, since fixed).

## Decision

1. **`--mode tmux` (zsh leader) is the single CANONICAL production leader.** It is the only substrate with
   the full safety net and real-tmux + real-campaign test coverage. All production / autonomous / long-run
   guidance points here. This honors the single KPI (autonomous start→finish) on the substrate that
   actually meets it today.

2. **`--mode agent` (Node-leader direct CLI) is DEPRECATED on a dated schedule** (§3). It already prints a
   SCHEDULED-REMOVAL banner; this ADR sets concrete versions. The Node `src/node/**` modules are NOT
   deleted — they remain the engine the Native Agent path and tests build on; only the *direct-CLI
   `--mode agent` entry point* is deprecated then removed.

3. **`--mode native` (Native Agent slash) is retained as an explicit SECOND-CLASS, documented companion**
   for short / interactive use — NOT deprecated, NOT promoted to production. It must be honestly labeled
   (no watchdog, no flywheel/SV, no runtime tests). It remains the slash-command default ONLY until the
   docs/UX reconcile (DX-1); the recommended path for any real campaign is `--mode tmux`.

### Rejected alternative: Native-canonical
Consolidating onto the Native Agent leader was steelmanned and rejected: it would require building a
watchdog substitute (re-introducing the lifecycle complexity we want to remove) plus a real-LLM test
harness, trading ~458 existing tests for prose with zero runtime coverage. Higher cost, higher risk,
against the KPI in the near term.

## Deprecation schedule (`--mode agent` direct CLI)

| Version | Action | Breaking? |
|---|---|---|
| 0.15.x | SCHEDULED-REMOVAL banner (already present) + this ADR | no |
| **0.16.0** | `--mode agent` emits a louder deprecation + still runs | no |
| **0.17.0** | `--mode agent` HARD-ERRORS with redirect to `--mode tmux` / `--mode native` | **YES (CLI)** — minor-version per 0.x semver; documented |
| **0.18.0** | remove the `--mode agent` dispatch branch from `run.mjs` (engine modules stay) | cleanup |

Any external wrapper calling `node run.mjs run X --mode agent` must migrate to `--mode tmux` by 0.17.0.
This is a breaking CLI change for that entry point and is called out in CHANGELOG at each step.

## Implementation waves (each gated per CLAUDE.md)

> NONE of this is implemented by this ADR. Each wave needs the review process before commit:
> 3-scenario self-verification (real Worker+Verifier) + ralplan (Planner→Architect→Critic) +
> codex-review-to-0-issues, for anything touching `governance.md` / `src/commands/rlp-desk.md` /
> `init_ralph_desk.zsh`.

- **Wave A (docs, NON-gated, do now):** reconcile user-facing docs to this decision — DX-2 project-local
  `.claude/ralph-desk/` → `.rlp-desk/` path drift; DX-1 README "Agent Mode (default)" factual fix
  (tmux = canonical/stable; native = default-but-second-class; agent = deprecated). README / getting-started
  / architecture only. (rlp-desk.md default-mode wording = GATED → Wave B.)
- **Wave B (GATED):** `src/commands/rlp-desk.md` default-mode wording + the 0.16.0 louder banner; any
  governance.md text declaring the canonical-leader policy. Needs the full gate.
- **Wave C (GATED, feature parity):** decide consensus/flywheel/SV homing — either port the flagship
  features to the canonical zsh leader, or explicitly scope them to native/agent with honest docs (ARCH-2).
- **Wave D (GATED, breaking, 0.17.0):** `--mode agent` hard-error in `run.mjs`. Touches the CLI contract;
  real-LLM E2E + gate required.

## Consequences

- Positive: removes the "every fix exposes a new bug" parity tax over time; gives the production path the
  only safety net; gives users one honest recommendation (`--mode tmux`).
- Negative: a breaking CLI change for `--mode agent` wrapper users (mitigated by the dated schedule +
  CHANGELOG notices); flagship-feature homing (Wave C) is non-trivial and still open.
- The Node engine modules (`src/node/**`) and their 378 tests are retained — only the direct-CLI
  `--mode agent` *entry point* is on the deprecation path.

## Related
- Audit findings: ARCH-1, ARCH-2, DX-1, DX-2, GAP-3, GAP-4, NODE-CB-1, NODE-AUTO-1 (`.tmp/_audit-report-FULL.md`)
- Reviewed plans: `.tmp/_improvement-plans.md` (D1 decision this ADR resolves)
- Prior consensus: `docs/plans/native-agent-revert.md`

## Amendment 2026-09-29

§2 above states: "The Node `src/node/**` modules are NOT deleted — ~~they remain the engine the Native
Agent path and tests build on~~; only the *direct-CLI `--mode agent` entry point* is deprecated then
removed." That middle clause is corrected here; the original sentence is kept verbatim above for history.

- The Native Agent() path (`--mode native`, the slash command) is orchestrated entirely by
  `src/commands/rlp-desk.md` prose and invokes no Node runner module — it dispatches Workers/Verifiers
  directly via `Agent()`/`Bash("codex exec ...")`, never through `src/node/**`.
- `src/node/runner/campaign-main-loop.mjs` is **not** a wholly dormant module: `run.mjs` imports and
  calls several of its other exports in production — `detectLegacyDeskInRunMode()` (~749), `buildPaths()`
  (multiple call sites, incl. ~789), and `resolveAnalyticsPointer()` (~795). Only its exported `run` (the
  campaign loop itself) is dormant — it is reached only via the CLI branch `runRunCommand()`
  → `deps.runCampaign(...)` — a dependency-injected call whose default implementation is `run` (imported
  into `run.mjs` as `runCampaignMain`) — which no `--mode` in `run.mjs` calls; tests call the `run` export
  directly. That export has **no production entry point** and is a **dormant, test-only mirror** of the
  zsh leader's protocol.
- `run.mjs` itself remains production code: `main()` → `runRunCommand()` → `runTmuxViaZsh()` (spawns the
  zsh runner) is the production `--mode tmux` launcher; the same file also holds CLI-flag translation,
  gate-receipt, and status/reporting used along that path. This is a distinct call chain from `run()`
  which is the dormant mirror named above.
- Deleting the dormant campaign loop (option 4A) is an open owner decision, not made by this amendment.
