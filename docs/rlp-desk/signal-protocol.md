# Signal Protocol — current contract + alternatives

**Spec version:** `signal-protocol-v1`
**Source consensus:** ralplan iter 6 — Architect synthesis, Critic codex APPROVED (P0=0, P1=0)
**Audience:** maintainers evaluating whether to adopt mailbox-dir, daemon, or in-process IPC alternatives.

---

## 1. Current Contract

rlp-desk routes Worker → Verifier handoff through a **single sentinel file per role per iteration**. The contract has four invariants:

1. **Sentinel = artifact.** Every transition step (`verify`, `verdict`, `flywheel`, `flywheel-guard`) is encoded as a JSON file at a deterministic path under `.rlp-desk/memos/`. The Leader polls the path with `fs.access` + atomic JSON-parse; any partial write is rejected (`jq -e .` gate, see `tests/test-bug7-poll-partial-write.sh`).
2. **`reapProducer` = lifecycle.** Once the Leader accepts a sentinel (validateArtifact passes), it MUST kill the producing TUI pane and chmod-lock the file. Skipping the reap leaves a self-reviewing claude/codex pane that overwrites the artifact mid-poll (Bug #7).
3. **Strict ordering: detect → reap → wait shell → next dispatch.** The Leader does NOT dispatch the next role (Verifier after Worker, next-iter Worker after Verifier) until the producing pane's `pane_current_command` has returned to `zsh|bash|sh`. AC-H1 of PR-0b-narrow strengthens this with `waitForProcessExit`.
4. **First-writer-wins for terminal sentinels.** `blocked.md` and `complete.md` are written via `O_EXCL` (`writeSentinelExclusive`); concurrent error paths cannot trample the canonical exit reason.

The same contract is implemented twice (`src/node/runner/campaign-main-loop.mjs` for `--mode agent`, `src/scripts/run_ralph_desk.zsh` for `--mode tmux`) with bit-for-bit parity on `(reason_text, reason_category, failure_category)` — verified by `tests/test-bug8-refuse-synthesis.sh` Scenario 4.

---

## 2. omc-teams Comparison (mailbox dir, daemon-backed CLI)

[omc-teams](https://github.com/oh-my-claudecode) delivers multi-agent coordination over a **daemon-backed CLI** (`omc team api ...`). Producers append to a per-team mailbox directory; consumers tail it. The reliability contract is enforced by the daemon process, not by file polling.

**What omc-teams gives you:**

- Crash-safe append-only message log (no truncated JSON window).
- Per-team subscription with backpressure.
- Cross-process delivery guarantees (daemon survives subprocess restart).

**What's load-bearing in the reliability gain — and what's not:**

The reliability gain is the **daemon**, not the mailbox dir. A bare file-mailbox (without daemon) inherits the same partial-write and self-review failure modes that rlp-desk's sentinel path already guards against, plus a new failure mode: a Worker prompt that misbehaves and dumps multiple JSON files into the mailbox (no single-writer invariant). Architect findings recorded in ralplan iter 6:

> Mailbox-dir without a daemon = same polling reliability as the sentinel approach + worker-prompt failure-mode increase. Adopting it as an intermediate step is strictly worse than the current contract.

So if rlp-desk wants the actual omc-teams reliability profile, it must adopt the **daemon**, not just the directory layout. That is the `Track B` work, not a sentinel rewrite.

---

## 3. claude code `/team` Comparison (in-process TeamCreate + SendMessage)

The Claude Code SDK exposes `TeamCreate` + `SendMessage` for in-process subagent coordination. This is fundamentally different:

| Property | rlp-desk sentinel | claude `/team` |
|---|---|---|
| Process model | Standalone tmux runner | Single-process subagent tree |
| IPC channel | Filesystem | In-memory message bus |
| Failure mode | Pane death, partial write | Subagent throw |
| Lifetime | Survives leader exit | Dies with parent |

`/team` is **not applicable** to a standalone tmux runner. rlp-desk explicitly supports the use case where the Leader can crash, the user can detach the tmux session, and a fresh Leader process can resume against the on-disk sentinel state. `/team` cannot be paused, snapshotted, or resumed across processes — by design.

---

## 4. Why rlp-desk does NOT adopt mailbox-dir

Architect/Critic codex consensus iter 6 rejected swapping the sentinel contract for a mailbox-dir for three concrete reasons:

1. **No reliability gain without the daemon.** Section 2 above. The daemon is the load-bearing piece; the directory is a side-effect of the daemon's protocol.
2. **Increased Worker-prompt failure surface.** Today the Worker is held to a single-writer contract: it MUST write `iter-signal.json` exactly once. A mailbox flips this to "append any number of messages and the daemon picks the latest" — a much weaker prompt-side invariant that empirically breaks under the kind of multi-pass self-review failures that Bug #7 was created to fix.
3. **Migration cost without commensurate benefit.** Two implementations (Node + zsh), Self-Verification Gate matrix (LOW/MEDIUM/CRITICAL × `--mode tmux/agent`), backwards compatibility for in-flight campaigns, and downstream wrapper tools (analytics, blueprints, Test Spec) all assume the sentinel contract. Replacing it is a multi-PR migration with no incremental win until the daemon ships.

The bug-fix track (Bug #6 worker-dead, Bug #7 post-sentinel-race, Bug #8 refuse-synthesize) closes the actual reliability gaps inside the sentinel contract and is strictly cheaper than the mailbox migration.

---

## 5. Track B Roadmap — daemon-backed `rlp-desk team api`

When the project is ready to adopt the omc-teams reliability profile, the migration looks like this:

**Track B — Phase 1 (PoC, separate ralplan):**
- New CLI: `rlp-desk team api start|stop|status|send|recv`
- Daemon process (`rlp-desk-teamd`) owns a per-campaign mailbox under `~/.rlp-desk/team/{slug}/`.
- Leader and Workers route through the CLI; no direct file polling.
- File-system fallback retained for the migration window — daemon down ⇒ degrade to sentinel mode.

**Track B — Phase 2 (cutover):**
- Sentinel reads behind a feature flag (`RLP_TEAM_API=1`).
- Self-Verification Gate matrix extended: each scenario runs once per backend (sentinel + team-api).
- Wrapper tools (analytics, blueprints) updated to consume the new event stream.

**Track B — Phase 3 (deprecation):**
- Sentinel path removed from runtime once team-api has burned in for ≥1 release.
- Documentation rolled forward; `signal-protocol-v1` archived.

Dependencies:
- Daemon implementation (~600 LoC Node, drawing on Bun's IPC primitives or plain `node:net`).
- Integration test harness for daemon crash recovery.
- Self-Verification Gate parity matrix (Node × zsh × team-api).

This track is **explicitly out of scope** for the Bug #6/#7/#8 plan v6. It is captured here so future maintainers do not interpret "rlp-desk does not use a mailbox" as an oversight — it is a deliberate architectural decision with a known successor path.
