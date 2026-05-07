# Bug Report Mechanism Overhaul — v0 (RALPLAN-DR Planner Draft)

> **Status**: Planner draft awaiting Architect → Codex Critic.
> **Mode**: deliberate (auto-enabled — touches governance, runner, slash command, test infra).
> **Stop rule**: iterate until codex critic returns 0 P0 + 0 P1. P2 → backlog.
> **Critic instruction**: *approve unless P0 or P1 found.*

---

## 1. Problem statement

10 hand-written 200-line bug reports (`Bug #1`–`Bug #10`, BOS dev `2026-05-01..05-07`) point at one root frustration: **bugs are endless and each one costs 30+ min of operator time to package** before the rlp-desk side can even start triage. Examples:

| Pain | Evidence |
|---|---|
| Manual context capture | Each report re-collects: env, version, command, status snapshot, pane logs, settings, gitignore — all already on disk |
| No similarity search | Bug #6/#7/#8 are all "worker hang variants"; operator re-discovers the cluster each time |
| Recovery is broken | Bug #10 — leader resets `phase=worker` ignoring operator's `phase=verify` manual recovery; operator's iter-signal/done-claim files deleted |
| Reactive only | Bugs surface only after full BLOCKED (~30 min poll timeout); no early warning on heartbeat anomalies |
| No deterministic repro pack | rlp-desk side has to chase BOS for missing context (logs, env, version) → fix latency multiplier |

The blocked-sentinel JSON (`schema_version: 2.0`) already classifies (`reason_category` / `recoverable` / `suggested_action`) but stops at the campaign boundary — it does not become a *bug report*. That gap is the target.

---

## 2. Principles (5)

1. **Capture-by-default, not by-request.** When the campaign blocks, the operator should not have to gather anything that already exists on disk.
2. **One canonical schema, two consumers.** A single `bug-report.json` feeds both BOS-side templates and rlp-desk-side triage; no divergent representations.
3. **Surgical diffs over new infra.** Extend the existing `blocked.{md,json}` writer + `/rlp-desk` subcommand surface; do not introduce a new daemon, queue, or service.
4. **Recovery must be idempotent.** Manual recovery of a BLOCKED campaign must not be silently overwritten on relaunch (Bug #10 contract).
5. **Earlier is cheaper.** A heartbeat-anomaly *warning* costs nothing; a 30-min BLOCKED poll-timeout is the most expensive form of feedback.

---

## 3. Decision drivers (top 3)

| # | Driver | Why it dominates |
|---|---|---|
| D1 | **Operator minutes per BLOCKED → first actionable report** | Today: 30+ min hand-writing + log collection. Target: ≤2 min (review + 1-line headline edit). Drives the "auto-bundle" choice below. |
| D2 | **Cluster recognition (avoid duplicate `Bug #N` for same root cause)** | 5 of 10 reports cluster around "worker hang on sentinel" or "verifier post-sentinel race". Without similarity hinting we keep paying triage cost N times. |
| D3 | **Zero regression on `--mode tmux` 19th launch** | Per `docs/plans/native-agent-revert.md`, the production tmux path is mid-flight. Any change must be additive there; default behavior unchanged. |

---

## 4. Viable options

### Option A — **Bundle-first**: `/rlp-desk report <slug>` + auto-emit on BLOCKED *(recommended)*

Add a single subcommand and one auto-trigger. Mechanics:

- **Trigger**: every `_handlePollFailure` / `_emitBlockedSentinel` call already in `campaign-main-loop.mjs` and `write_blocked_sentinel` in `run_ralph_desk.zsh` ALSO writes `bug-reports/<slug>-<UTCISO>.json` + `<...>.md` (template-rendered).
- **Schema**: extends current blocked-sentinel JSON v2.0 with: `repro.command`, `repro.env_snapshot`, `repro.git_head_sha`, `pane_tail.{worker,verifier}` (last 200 lines, redacted), `recent_iter_artifacts[]` (last 3 iterations' done-claim/verdict paths), `pattern_match.{candidate_bug_ids[], score}` (similarity vs known reports).
- **Subcommand**: `/rlp-desk report <slug>` to (a) regenerate from saved campaign state, (b) attach a custom headline, (c) print the markdown to stdout for paste-into-issue-tracker.
- **Pattern match**: deterministic — hashed signature on `{reason_category, failure_category, suggested_action, top-level pane stem}` against a `docs/bug-patterns.json` lookup (seeded with #1–#10).
- **Bug #10 fix**: leader on relaunch honors `status.phase == "verify"` + valid manual artifacts (validated against schema) and skips worker dispatch. Same surgical injection point used by P1-D classifier.

**Pros**: low-surface; reuses `_classifyBlock`, `writeSentinelExclusive`, `~/.claude/ralph-desk/analytics`; produces the same output regardless of whether BLOCKED came from `--mode tmux` or `--mode native`/`--mode agent`. Operator's job collapses to "edit headline".

**Cons**: pattern-match is naive (string-stem); will need iteration. Pane-tail capture risks PII/secret leak — must redact (governance §1f already has redaction precedent).

### Option B — **Heartbeat-first**: pre-BLOCKED early warning channel

Introduce a `<slug>-warning.{md,json}` sidecar emitted whenever a heartbeat anomaly crosses a soft threshold (50% of `iter-timeout`, no progress). Operator can opt into pre-empting the BLOCKED with `/rlp-desk warn <slug>` before the 30-min wall hits.

**Pros**: shortens the perceived "bug is endless" tail by surfacing earlier.

**Cons**: orthogonal to the *report quality* problem. Adds a second sentinel surface; risks false positives that train operators to ignore. Does not solve D1 (hand-writing) or D2 (clusters).

### Option C — **External tracker integration** (GitHub Issues auto-file)

Instead of file artifacts, POST blocked context to a configured GitHub repo issue.

**Pros**: makes rlp-desk-side triage visible without operator handoff.

**Cons**: violates principle 3 (new infra: secrets, network, retry, rate-limits). Couples to an external service. Out-of-scope per ABSOLUTE rule "NEVER push to remote without explicit user approval" — would need a per-campaign auth path. **Invalidated.**

### Option D — **Status-quo + better doc template**

Just publish a clearer template under `docs/rlp-desk/bug-report-template.md` and call it done.

**Pros**: zero code change.

**Cons**: does not move D1 (operator minutes) or D2 (clusters) at all. Bug #10 (Recovery breakage) untouched. **Invalidated.**

### Why A wins (with optional B as future-PR)

A directly addresses D1 (auto-bundle), D2 (pattern_match seeded with #1–#10), and Bug #10 (relaunch hygiene). B is complementary but orthogonal — defer to a separate PR after A lands and we measure operator minutes-saved. C/D fail principle 3 / D1 respectively.

---

## 5. Scope (this PR)

### P0 — must land

1. **`bug-report.json` writer** — extend `_emitBlockedSentinel` (Node, `campaign-main-loop.mjs:923-968`) and `write_blocked_sentinel` (zsh, `lib_ralph_desk.zsh`) to also emit a per-block bug-report under `.rlp-desk/bug-reports/<slug>-<iso>.{json,md}`. Schema documented at `docs/rlp-desk/bug-report-schema.md`.
2. **Bug #10 relaunch hygiene** — in launch-time entry of `campaign-main-loop.mjs` (currently forces `phase=worker`+`iter=1`), branch on `status.phase == 'verify'` and validate operator-written `iter-signal.json` + `done-claim.json` against existing artifact-validators. If valid → skip worker dispatch, enter verifier directly. If invalid → log warning + fall through to current behavior.
3. **Redaction pass** — `pane_tail` and `env_snapshot` go through a deny-list (governance §1f redaction precedent: any `/(api[_-]?key|token|secret|password|bearer|authorization)/i` line replaced with `<REDACTED>`).

### P1 — must land

4. **`/rlp-desk report <slug>` subcommand** — added to `src/commands/rlp-desk.md` per current command-handler patterns; reads the latest blocked-sentinel JSON + most recent `bug-reports/*.json`, prints the markdown render to stdout. Optional `--headline "..."` flag rewrites the title line in-place. No auto-publish to any remote.
5. **`pattern_match` seed** — `docs/bug-patterns.json` shipped with deterministic signatures for Bug #1–#10 (manually authored from BOS reports). Bug-report writer fills `pattern_match.candidate_bug_ids[]` + `score` (Jaccard on `{reason_category, failure_category, top-level pane-tail token bag}`).
6. **Self-Verification gate compliance** — `src/scripts/run_ralph_desk.zsh` is touched → CLAUDE.md mandates 3 self-verification scenarios (LOW + MEDIUM + CRITICAL). Spelled out in §10.

### P2+ → `docs/plans/bug-report-overhaul-backlog.md` (separate file, not this PR)

- Heartbeat-warning sidecar (Option B).
- GitHub Issues integration (Option C, after authn story).
- Pattern-learning loop that mines `~/.claude/ralph-desk/analytics/*/bug-reports/` for emerging clusters.
- Cross-campaign bug-report dashboard in `/rlp-desk analytics`.
- Auto-suggest "this looks like Bug #N — try fix-X" inline in CLI output (today: `pattern_match` is data-only).

---

## 6. Files to modify

| File | Change | Risk |
|---|---|---|
| `src/node/runner/campaign-main-loop.mjs` | Extend `_emitBlockedSentinel` to call new `writeBugReport` helper; add Bug #10 relaunch-phase-honor branch in `_runCampaignBody` entry | MED |
| `src/node/shared/bug-report.mjs` (NEW) | `writeBugReport({slug, classification, reason, paths, env, paneTails, recentArtifacts})` + redaction + pattern-match | LOW (new isolated module) |
| `src/scripts/lib_ralph_desk.zsh` | New `_write_bug_report` helper called from `write_blocked_sentinel` | MED |
| `src/scripts/run_ralph_desk.zsh` | Wire `_write_bug_report` after each `write_blocked_sentinel` site (≈10 sites, all already in one taxonomy) | MED |
| `src/commands/rlp-desk.md` | Add `## report <slug>` section; document `bug-reports/` directory + schema link; add `/rlp-desk report` to help block | LOW |
| `src/governance.md` | Add §1g "Bug Report Capture" — invariant: every BLOCKED writes a bug-report; redaction rules; relaunch hygiene contract (Bug #10) | LOW (additive) |
| `docs/rlp-desk/bug-report-schema.md` (NEW) | JSON schema doc + worked example | LOW |
| `docs/bug-patterns.json` (NEW) | Seed with #1–#10 signatures | LOW |
| `tests/node/test-bug-report-writer.test.mjs` (NEW) | Schema, redaction, pattern-match unit tests | LOW |
| `tests/node/test-relaunch-phase-verify-hygiene.test.mjs` (NEW) | Bug #10 fix unit + integration | MED |
| `tests/test-bug-report-zsh-emit.sh` (NEW) | zsh side bug-report emit verification | MED |

Total: 5 modified + 6 new. No deletions. Single PR — review surface bounded.

---

## 7. Pre-mortem (deliberate mode — 3 scenarios)

### S1 — Pane-tail leaks a secret into a committed bug-report

A worker pane prints `Authorization: Bearer eyJ...` from a vendor SDK debug log. `pane_tail` captures it; operator commits the bug-report markdown without re-reading.

**Mitigation**: redaction deny-list runs on the JSON writer side (not at view-time); deny-list is unit-tested in `test-bug-report-writer.test.mjs` with a fuzz-style fixture (10+ secret-shaped strings). Markdown render reads from JSON post-redaction, so it can never out-leak. Additional belt: `bug-reports/` is added to a sample `.gitignore` snippet in the schema doc; we do not auto-add to user repo `.gitignore`.

**Residual risk**: vendor-specific secret formats not in deny-list. Acceptable: schema doc tells operator to scan before committing, and pattern_match leaves an `unredacted_count` audit field that flags how many lines hit the deny-list (operator can sanity-check).

### S2 — Bug #10 fix accidentally honors a stale `phase=verify` from a CRASHED leader and re-enters verifier on garbage state

If the leader crashed mid-worker after writing `phase=verify` (race), relaunch could enter verifier with an inconsistent on-disk state.

**Mitigation**: validation gate is strict — both `iter-signal.json` AND `done-claim.json` must (a) exist, (b) have `us_id` matching `status.target_us`, (c) have `iteration` matching `status.iteration`, (d) have `iter_signal_quality == 'specific'`, (e) be newer than the most recent `worker-prompt.md` mtime. Failure of ANY check → fall through to current behavior + log "phase=verify ignored: <reason>". This preserves backward compat and matches `_checkBlockedHygiene` precedent.

**Residual risk**: a clever filesystem race can still pass all five checks. We accept this — the existing "every relaunch resets to worker" behavior is itself a bug (#10), and Option C's stricter "operator must pass `--resume-from-verify` flag" is named in P2 backlog as an opt-in escalation if operators report false positives.

### S3 — `pattern_match` false-positive trains operators to dismiss real bugs

Two unrelated `infra_failure` blocks both score ≥0.8 against the same Bug #N signature; operator stops reading.

**Mitigation**: `pattern_match` is **data-only** in P1 — no inline CLI suggestion. Score + candidate IDs are written to JSON; markdown render places them in a "Possible related bugs" footer with explicit "score: 0.83 — review before assuming match". Auto-suggest is deferred to P2 backlog precisely because we have not validated the signature space yet. Also: ship with **deterministic** Jaccard over a small token bag, not ML — failures are inspectable.

**Residual risk**: low — operator opt-in to act on `pattern_match`.

---

## 8. Expanded test plan (deliberate mode)

### Unit (Node)

`tests/node/test-bug-report-writer.test.mjs`:

- AC-W1: schema fields all present + types match `docs/rlp-desk/bug-report-schema.md`.
- AC-W2: redaction — 12 secret-shaped fixtures (Bearer token, AWS key, GH PAT, OpenAI key, generic `password=...`, etc.) all replaced by `<REDACTED>`; `meta.redacted_line_count` reflects count.
- AC-W3: pane-tail truncates at 200 lines; preserves last lines (most recent diagnostic value).
- AC-W4: `pattern_match` against seeded `docs/bug-patterns.json` — synthetic block matching Bug #6 signature returns `score >= 0.7` + correct `candidate_bug_ids`.
- AC-W5: idempotent — second call with same `(slug, classification, iso)` is a no-op (uses `writeSentinelExclusive` semantics).

`tests/node/test-relaunch-phase-verify-hygiene.test.mjs`:

- AC-R1: status.phase=verify + valid artifacts → verifier-only entry (no worker dispatch).
- AC-R2: status.phase=verify + missing `done-claim.json` → fall through to worker, log warning.
- AC-R3: status.phase=verify + `us_id` mismatch → fall through, warning.
- AC-R4: status.phase=verify + `iter-signal.json` older than worker-prompt.md → fall through, warning.
- AC-R5: status.phase=verify + `iter_signal_quality != 'specific'` → fall through, warning.

### Integration (Node)

`tests/node/us006-campaign-main-loop.test.mjs` extension:

- AC-I1: BLOCKED via `flywheel_inconclusive` → bug-report file written to `.rlp-desk/bug-reports/`; JSON parses; `reason_category == 'mission_abort'`.
- AC-I2: BLOCKED via `worker_exited` → bug-report `pattern_match.candidate_bug_ids` includes `Bug-7` (worker pane death lineage).
- AC-I3: relaunch with valid `phase=verify` artifacts → no `iter-002.worker-prompt.md` created; verifier dispatched directly.

### Integration (zsh)

`tests/test-bug-report-zsh-emit.sh` (NEW, mirrors `test-bug7-post-sentinel-race.sh` style):

- Sc-1: stub `dispatch_worker` exits 1 → `write_blocked_sentinel` runs → `<slug>-<iso>.json` exists in `bug-reports/` + parses with `jq`.
- Sc-2: redaction — pre-injected pane log with `Bearer X` → `jq .pane_tail.worker` does not contain `Bearer X`.

### Self-Verification scenarios (CLAUDE.md gate, MANDATORY since `run_ralph_desk.zsh` is touched)

- **LOW**: redaction unit fixture passes; existing zsh + Node regression tests green.
- **MEDIUM**: real campaign with stub worker that fails → bug-report appears; markdown render contains all required sections; operator can `cat` it; `pattern_match` populated.
- **CRITICAL**: 2-iter campaign with deliberate BLOCKED at iter-1, then operator manual recovery (write iter-signal/done-claim by hand, set `phase=verify`), relaunch → verifier-only path runs (no worker iter-2 dispatch); Bug #10 reproduction scenario reversed; verdict accepted; `complete.md` written.

All 3 must PASS before commit. If any FAIL: fix root cause, re-run failing scenario, then re-verify all 3.

---

## 9. Verification end-to-end

1. `node --test 'tests/node/*.test.mjs'` — all green; new tests visible.
2. `bash tests/test-bug-report-zsh-emit.sh` — green.
3. `bash tests/test-bug7-post-sentinel-race.sh` + `bash tests/test-bug7-poll-partial-write.sh` — unchanged green (no Bug #7 regression).
4. CLAUDE.md self-verification gate × 3 (above) — all PASS.
5. Manual: trigger BLOCKED in a sandbox campaign; verify `.rlp-desk/bug-reports/<slug>-<iso>.md` is human-readable + has `Possible related bugs` footer.
6. Banner-aware diff `src/` ⇆ `~/.claude/ralph-desk/` after `node scripts/postinstall.js`.

---

## 10. ADR (preview — final once Critic approves)

- **Decision**: Adopt Option A (bundle-first, auto-emit on BLOCKED) for v0.16.0; defer heartbeat-warning (B) and external-tracker (C) to backlog.
- **Drivers**: D1 operator-minutes, D2 cluster-recognition, D3 zero `--mode tmux` regression.
- **Alternatives considered**: B (orthogonal — does not solve D1/D2), C (violates principle 3, requires authn/network), D (does not move any driver).
- **Why chosen**: A reuses `_classifyBlock` + `writeSentinelExclusive`; surgical-diff principle satisfied; pattern_match seeded from real history.
- **Consequences**: BLOCKED writes additional artifact (`bug-reports/<slug>-<iso>.{json,md}`); operator workflow shifts from "hand-write 200 lines" to "review + edit headline"; `bug-patterns.json` becomes a living artifact maintained alongside reports.
- **Follow-ups**: Backlog file lists P2+ items. Heartbeat warning revisited after we measure operator minutes-saved on first 3 BLOCKED post-land.

---

## 11. Round-by-round resolution log

| Round | Reviewer | Verdict | Findings closed |
|---|---|---|---|
| 0 | — | Planner v0 | initial draft |
| 1 | Architect | _pending_ | _to fill_ |
| 2 | Codex Critic | _pending_ | _to fill_ |
| ... | | | |
