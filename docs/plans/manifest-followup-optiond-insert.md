# STAGED INSERT — Option D spec (AC7a–AC7h + 4-case test)

**Status:** ready to apply. **Not yet applied.** The PRD is frozen for the codex critic re-run.
**Target file:** `/Users/plletdata/dev/rlp-desk/.omc/plans/manifest-followup-wave.md`
**Target sha at staging time:** `f274674ab257522c7f59190f206c6e8870cb2a5ee35275c9e3efcbb3ac189310` (569 lines)
**Author of §2–§4 content:** `ralplan-architect`, verbatim. Planner added only the mapping notes in §1 and §5.
**Staged:** 2026-08-10, on team-lead instruction ("stage the surgical insert; do not touch the frozen PRD").

> If the target sha has moved when you apply this, re-check §1's line anchors by content match, not by line number.

---

## 1. What this replaces — exact boundaries

### 1a. The spec block (primary replacement)

**Replace PRD lines 220–243 inclusive**, i.e. the whole section that begins:

```
### Option D — leader registry spec (Critic #3)
```

…and ends with the paragraph beginning `**Race semantics.** A native leader may register between…` (line 241), plus the trailing blank lines through 243. The next surviving line is 244, `### Verification commands`.

Content signature of the block being removed — it opens with this blockquote, which is the "pending architect confirmation" marker the team-lead flagged:

```
> **Status: planner-authored defaults; architect confirmation still outstanding at v4 save time.** …
```

That entire block is **planner-authored placeholder** and is superseded wholesale by §2 below. Do not merge the two — the architect's version supersedes on every point, including the three where mine was silent (`schema_version`, AC7g fail-closed read, AC7h path-agreement caveat).

**Where the two agree** (so a reviewer can confirm nothing regressed): registry path, no-reuse of `RUNNER_LOCKFILE_PATH`, multi-native advisory coexistence, `≥1 foreign live entry` predicate, self-exclusion by PID, `kill -0` read-time liveness, reader-side pruning as mandatory, and no-lock race semantics.
**Where the architect overrode me:** atomicity — I offered `set -C` *or* `atomic_write`; the architect ruled **`atomic_write`, and specifically not `set -C`**, with reasoning (§2, "Atomicity"). Take their version.

### 1b. AC label collision — MUST be resolved when applying

US-002 currently carries `AC1 … AC7`. Inserting `AC7a–AC7h` while a plain `AC7` exists produces two different things both called AC7. Current state:

| Current label | Content | Action when applying |
|---|---|---|
| `AC6 (Option D — was AC7; renumbered into sequence)` | Option D downgrade predicate | **Subsumed** — this is exactly the architect's `AC7e`. Delete it; do not keep both. |
| `AC7 (was AC6)` | Residual (human editor, `--worktree` tmux-only) documented in `failure-modes.md` | **Keep, renumber to `AC6`** — it belongs to Option A's US-002, not to Option D. |

Resulting numbering, which satisfies the critic's non-blocking #5 (sequential) and the team-lead's gate split:

- **US-002 (Option A, gate-free):** `AC1 … AC5` + `AC6` (residual/worktree docs, renumbered from AC7).
- **US-002b (Option D, its own gated commit):** `AC7a … AC7h` verbatim as below.

Keeping the architect's `AC7x` labels rather than renumbering them to `AC1…AC8` is deliberate: their text, the 4-case test, and the team-lead's gate-split note all refer to `AC7a-h` by name. Renumbering would silently break three cross-references for zero gain.

---

## 2. Architect's spec — verbatim

### Registry path
`$DESK/logs/.rlp-desk-leaders-$ROOT_HASH.d/<pid>.json`

Confirmed safe: `.rlp-desk/` is gitignored (`.gitignore:33`, verified via `git check-ignore -v`), so registry entries never become dirty files. That matters more than it sounds — an anti-dirty-file mechanism that creates dirty files would be self-defeating.

**One condition you must add.** `DESK="$ROOT/${RLP_DESK_RUNTIME_DIR:-.rlp-desk}"` (`run_ralph_desk.zsh:513`) is **operator-overridable**. If the two leaders resolve `RLP_DESK_RUNTIME_DIR` differently they write to different registries and never see each other — Option D silently no-ops. That is fail-*open* (status quo auto-commit), so it is acceptable, but it must be documented, and if the operator sets that variable they must set it for both leaders. Keying the directory on `$ROOT_HASH` (`:525`) is right and should stay — it prevents collision if a shared DESK is ever pointed at two roots.

### Schema
```json
{"schema_version":"1.0","pid":12345,"mode":"native"|"tmux","slug":"…","root":"/abs/path","started_at":"…Z"}
```
Add `schema_version`. This repo already versions its JSON (`write_blocked_sentinel` emits `schema_version: "2.0"`), and a registry read by two independently-evolving leaders is exactly where you want a version field before you need it. `root` earns its place as a sanity check against a stale entry from a relocated checkout. Nothing else needed — the downgrade decision only requires "a foreign live entry exists"; `mode` and `slug` are for the log line, which is worth having so an operator can see *which* leader caused a carryover.

### Atomicity — `atomic_write`, NOT `set -C`

`acquire_slug_lock`'s entire apparatus (stale reap, recovery mutex, TOCTOU settle window, re-read under mutex) exists to arbitrate **contention on one shared filename**. A per-PID registry has no contention — each PID owns a unique name — so all of that is dead weight, and worse, it would make registration *fail* on races it should not even have.

What you actually need is the property `set -C` does **not** give you: truncation safety. `atomic_write` (`lib_ralph_desk.zsh:531`) checks both the write and the rename, so a half-written entry (ENOSPC, SIGPIPE) never lands. That matters because under the §Liveness fail-closed rule an unparseable entry downgrades F-8 — so a torn write would cause spurious carryovers.

Also: a pre-existing file at our own `<pid>.json` is **by definition stale** (we are alive holding that PID, so the previous owner is dead). Plain overwrite is correct; `set -C` would only make us refuse to register.

### Multi-native ownership — advisory; predicate is "≥1 foreign live entry"
Two additions:
- **Both leaders register**, not just native. Cheap, makes the registry describe reality, future-proofs if the exclusive runner lock is ever relaxed, and makes the test more realistic.
- Therefore **self-exclusion by PID is mandatory** — the reader skips `$$`. Without it, a registering zsh leader downgrades its own F-8 forever, which would be a spectacular self-own.

### Liveness & pruning — `kill -0` at read time, both sides prune, reader-side is load-bearing
- **Authority: `kill -0` at read time.** Matches `acquire_slug_lock:590` and the codebase's documented invariant that staleness is "PID-based (never age-based, so a slow-but-alive recoverer is never falsely reaped)". Do not add a TTL.
- **Registrant removes its own entry on exit** — in `cleanup()`, right where the runner lock is released (`run_ralph_desk.zsh:3335-3344`). Best-effort.
- **Reader sweeps dead entries** during the same pass it reads them.

**Why reader-side sweep is load-bearing and not belt-and-braces:** the native leader is an LLM. It can hit a context limit, be interrupted, or simply skip an instruction — it is the *least* reliable party at running its own cleanup step, and it is precisely the party this feature exists to detect. Never rely on the native leader to unregister. A dead native entry would otherwise downgrade F-8 forever; reader-side `kill -0` + unlink is the fix, and it is required, not optional.

### Race semantics — no lock
- The failure mode of losing the race is **reverting to today's behavior** (auto-commit) for one iteration. Strictly no worse than status quo, so the race cannot regress anything.
- A lock could not close it anyway — the native leader is not holding any lock while it edits files, so there is nothing to serialize against.
- **Free improvement:** put the registry read immediately before `_bug8_autocommit` (~`:1457`), not at Gate-3 entry (~`:1408`). Same code, window shrinks from "the whole comm/log sequence" to microseconds. Zero cost.

### Fail-closed on read error
If the registry directory cannot be read (permissions, IO error), **downgrade to carryover**. This mirrors the GIT-FC/IMP-09 idiom already in Gate 3, where a git error must not read as "clean". A registry read error must not read as "no foreign leaders". Carryover is graceful, so fail-closed costs nothing.

---

## 3. Acceptance criteria — verbatim, drop in as-is

**AC7a (registry contract).** Given any leader starts a campaign, when it initializes, then it writes `$DESK/logs/.rlp-desk-leaders-$ROOT_HASH.d/<pid>.json` via `atomic_write` containing `{schema_version:"1.0", pid, mode:"native"|"tmux", slug, root, started_at}`. The registry is advisory: registration never fails a campaign, and a write error is logged and ignored. It MUST NOT reuse `RUNNER_LOCKFILE_PATH` — that lock is exclusive and would make registration hard-fail on a busy root.

**AC7b (both leaders register).** Given a `--mode tmux` campaign, when the zsh leader initializes, then it registers. Given a `--mode native` campaign, when the native leader starts, then its instructions direct it to register with the identical path and schema. *(This AC is the SV-gated portion — it edits `src/commands/rlp-desk.md`.)*

**AC7c (unregistration).** Given a leader reaches `cleanup()`, when it releases the runner lock, then it removes its own `<pid>.json` (best-effort; failure logged, never fatal).

**AC7d (liveness + reader-side prune).** Given the registry is read, when an entry's `pid` fails `kill -0`, then that entry is treated as absent AND unlinked in the same pass. Staleness is PID-based only — no TTL, no age heuristic. A leader killed with SIGKILL, or a native leader that never unregisters, MUST NOT downgrade F-8 indefinitely.

**AC7e (downgrade predicate).** Given F-8 is about to auto-commit, when the registry contains ≥1 live entry whose `pid != $$`, then the leader logs which foreign leader (mode + slug + pid) was detected, routes the worker files to `_bug8_record_carryover`, and does NOT stage or commit. Given zero live foreign entries, then F-8 auto-commits exactly as today (byte-identical behavior — no regression of recovery's purpose).

**AC7f (self-exclusion).** Given a leader has registered its own entry, when it reads the registry, then its own `$$` is excluded and its own F-8 is never downgraded by its own registration.

**AC7g (fail-closed read).** Given the registry directory exists but cannot be read, when F-8 evaluates, then the leader downgrades to carryover rather than treating the error as "no foreign leaders" — mirroring the GIT-FC fail-closed idiom in Gate 3.

**AC7h (path-agreement caveat, documented).** `docs/rlp-desk/failure-modes.md` records that `RLP_DESK_RUNTIME_DIR` is operator-overridable and that a mismatch between leaders makes Option D a silent no-op (fail-open to status quo); if the operator sets it, both leaders must use the same value.

---

## 4. Test — 4 cases, not 1

The planner's original single-case sketch was **vacuous**: asserting only that the downgrade fires cannot distinguish a correct implementation from a hardcoded `return`. The backgrounded-`sleep` live-PID approach is right and needs no second campaign, but it needs four cases.

1. **Positive control** — live foreign entry + dirty tracked file → `_bug8_record_carryover` fired, `git log` gained no `leader-recovery` commit.
2. **Negative control** *(the one that proves non-vacuity)* — *no* registry entry, same dirty file → F-8 **does** auto-commit, `git log` gained exactly one `leader-recovery` commit. Without this the suite passes if someone disables F-8 entirely.
3. **Stale entry** — entry whose PID is dead (`kill` the `sleep`, keep the file) → F-8 auto-commits **and** the stale file is unlinked. This is AC7d.
4. **Self-exclusion** — entry whose pid is the test leader's own `$$` → F-8 auto-commits. This is AC7f, and it is the one that would otherwise ship a leader that permanently downgrades itself.

Optionally **5**: unreadable registry dir (`chmod 000`) → carryover (AC7g). Skip if awkward in CI, but note the skip.

### Runnable verification commands

```bash
set -euo pipefail

# AC7a-AC7g — cases 1-4 (+ optional 5)
zsh tests/test_bug8_leader_registry.zsh

# Case 2's invariant is also this existing test's invariant — if it goes red you have
# BROKEN recovery, not scoped it.
zsh tests/sv-large-campaign/test-f8-commit-slip-recovery.zsh

# AC7h — documented caveat
grep -q 'RLP_DESK_RUNTIME_DIR' docs/rlp-desk/failure-modes.md
grep -qi 'no-op\|no op' docs/rlp-desk/failure-modes.md

# AC7b is SV-gated (edits src/commands/rlp-desk.md) — this is gated commit 2's own gate,
# NOT covered by US-001's passing gate.
zsh tests/sv-gate-full.sh
```

---

## 5. Apply checklist

1. Confirm the PRD is unfrozen (team-lead says so explicitly).
2. Delete PRD lines 220–243 (§1a) — match on the `### Option D — leader registry spec (Critic #3)` heading and the `> **Status: planner-authored defaults…` blockquote, not on line numbers alone.
3. Paste §2 + §3 + §4 in its place.
4. Resolve the AC label collision per §1b: delete current `AC6 (Option D …)`, renumber current `AC7 (was AC6)` → `AC6`.
5. Grep for now-stale cross-references to the old block:
   - `grep -n "planner-authored" manifest-followup-wave.md` → must return nothing.
   - `grep -n "pending architect confirmation" manifest-followup-wave.md` → must return nothing.
   - `grep -n "AC6 (Option D" manifest-followup-wave.md` → must return nothing.
   - `grep -n "test_bug8_foreign_leader_downgrade" manifest-followup-wave.md` → replace any hit with `test_bug8_leader_registry.zsh` (the v4 US-002 verification block names the old filename).
6. The US-002 verification block currently inlines a "Harness contract (assert ALL)" comment describing the **one-case** harness. Replace it with §4's four cases, or delete it and point at §4 — do not leave both.
7. Re-report sha + line count.

**Known follow-on, not fixed here:** the v4 US-002 verification block references `zsh tests/test_bug8_foreign_leader_downgrade.sh`. The architect's test is `zsh tests/test_bug8_leader_registry.zsh`. One filename must win; the architect's is authoritative because the 4-case contract is theirs. Step 5's grep catches it.
