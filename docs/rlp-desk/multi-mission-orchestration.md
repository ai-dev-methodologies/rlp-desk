# Multi-Mission Orchestration Patterns

rlp-desk runs **one mission per `run_ralph_desk.zsh` invocation**. The runner is
intentionally single-purpose: it loads a slug's PRD, executes the per-US loop,
writes a sentinel (`COMPLETE` or `BLOCKED`), and exits. Anything that needs to
coordinate **multiple missions** in sequence — for example a flywheel that
runs `axis-A → axis-B → measurement → improve` — is the responsibility of a
**wrapper script** owned by the consumer.

This document explains the contract between rlp-desk and a wrapper, with a
small worked example.

## Why no built-in chain

Hard-coding mission sequences inside rlp-desk would couple the runner to a
particular project's idea of "what comes next." Different consumers have
different goals (fixed-length improvement campaigns, indefinite uptime, mission
graphs branching on metrics). A wrapper layer keeps rlp-desk focused on the
single-mission contract while letting each consumer encode its own policy.

## Per-mission outputs the wrapper can read

After every campaign rlp-desk writes the following artifacts under
`<ROOT>/.claude/ralph-desk/`:

| Path | Purpose |
|---|---|
| `memos/<slug>-blocked.md` | Sentinel for a BLOCKED outcome. First line is `BLOCKED: <us_id>`; second line is `Reason: <verdict reason>` (governance §1f BLOCKED Surfacing). |
| `memos/<slug>-complete.md` | Sentinel for a COMPLETE outcome. |
| `memos/<slug>-iter-signal.json` | Last worker signal (status, us_id, summary). |
| `memos/<slug>-memory.md` | Campaign memory accumulated across iterations. |
| `memos/<slug>-flywheel-signal.json` | When flywheel ran, the direction it picked. May contain a `next_mission_candidate` field that the wrapper can use to decide what to launch next. |
| `logs/<slug>/metadata.json` | One-line summary of the campaign config, including `with_self_verification`, `with_self_verification_requested`, and `sv_skipped_reason` (RC-1). |

**Exit-code contract (per entry point — read carefully):**

| Entry point | Exit 0 | Exit 2 | Exit 1 |
|---|---|---|---|
| `src/node/run.mjs` (Node, agent mode) | clean COMPLETE | BLOCKED (verifier or model-upgrade-exhausted), reason on stderr | unhandled error (e.g. unknown flag) |
| `src/scripts/init_ralph_desk.zsh` | scaffold OK | PRD cross-US lint reject (per-us mode), violations on stderr | scaffold incomplete or input error |
| `src/scripts/run_ralph_desk.zsh` (zsh, tmux mode) | clean exit (sentinel decides COMPLETE/BLOCKED) | not used | any failure path; wrappers must inspect the sentinel files to tell COMPLETE from BLOCKED |

The Node entry surfaces the BLOCKED reason on **stderr** with **exit code 2**.
The zsh runner does **not** distinguish exit codes for COMPLETE vs BLOCKED;
inspect the sentinel files (`memos/<slug>-{complete,blocked}.md`) instead.
PRD lint rejection (init exit 2) is the only path that uses exit 2 in the
zsh side.

## Minimal wrapper recipe (zsh)

The recipe below polls a fixed mission list, launches each one, and stops on
the first BLOCKED. It demonstrates the contract without prescribing a policy.

```zsh
#!/usr/bin/env zsh
set -u
set -o pipefail

ROOT="${ROOT:-$PWD}"
DESK="$ROOT/.claude/ralph-desk"
MISSIONS=(
  "axis-1-baseline"
  "axis-2-improve"
  "axis-3-measurement"
)

for SLUG in "${MISSIONS[@]}"; do
  # Skip missions that already finished (idempotent re-runs).
  if [[ -f "$DESK/memos/$SLUG-complete.md" ]]; then
    print "Skipping $SLUG — already COMPLETE"
    continue
  fi
  if [[ -f "$DESK/memos/$SLUG-blocked.md" ]]; then
    print "Stopping chain — $SLUG is BLOCKED:"
    cat "$DESK/memos/$SLUG-blocked.md"
    exit 2
  fi

  print "Launching $SLUG"
  ROOT="$ROOT" \
  WORKER_MODEL="${WORKER_MODEL:-gpt-5.5:medium}" \
  VERIFIER_MODEL="${VERIFIER_MODEL:-opus}" \
  VERIFY_MODE="${VERIFY_MODE:-per-us}" \
  CB_THRESHOLD="${CB_THRESHOLD:-6}" \
    zsh ~/.claude/ralph-desk/run_ralph_desk.zsh "$SLUG"
  rc=$?

  # zsh runner: rc tells you "did the script crash", not COMPLETE vs BLOCKED.
  # Read the sentinel for the actual terminal state.
  if [[ -f "$DESK/memos/$SLUG-complete.md" ]]; then
    print "$SLUG completed cleanly"
  elif [[ -f "$DESK/memos/$SLUG-blocked.md" ]]; then
    print "$SLUG blocked — stopping chain"
    cat "$DESK/memos/$SLUG-blocked.md"
    exit 2
  else
    print "$SLUG ended without sentinel (rc=$rc) — stopping chain"
    exit "${rc:-1}"
  fi
done
```

Three design notes:

- The wrapper checks the **sentinel files first** — both before and after
  invoking the runner. This makes re-runs idempotent (finished missions are
  skipped) and accommodates the zsh runner's lack of a distinct
  COMPLETE-vs-BLOCKED exit code.
- For the **Node runner** (`src/node/run.mjs`, agent mode) the recipe can be
  simpler: switch on `$rc` directly because Node uses exit 2 specifically for
  blocked outcomes. The exit-code table above lists which entry point uses
  which convention.
- `init_ralph_desk.zsh`'s exit 2 (PRD lint reject) is the wrapper's only
  pre-launch fail-fast signal. Treat it the same as a blocked sentinel — the
  campaign will not start until the PRD is fixed.

## Flywheel-driven dynamic chain (optional)

**Emit side (rlp-desk responsibility)**: when a mission runs the flywheel
review (`--flywheel on-fail`), the flywheel agent's signal JSON
(`memos/<slug>-flywheel-signal.json`) MAY include an optional
`next_mission_candidate` field — `null` for "no recommendation" or a slug
string for "consumer should chain this slug next." The Node leader
propagates this field into `status.json` (`status.next_mission_candidate`)
so wrappers can poll either file. The flywheel prompt template
(`init_ralph_desk.zsh` flywheel heredoc) and `governance.md` §7 ⑥½ both
document the field. Field is OPTIONAL and absence is treated as `null` —
backward-compat with prior flywheel signals.

**Consumer side (wrapper responsibility)**: pick the next slug from that
field instead of a fixed list:

```zsh
NEXT_SLUG=$(jq -r '.next_mission_candidate // empty' \
  "$DESK/memos/$SLUG-flywheel-signal.json" 2>/dev/null)
if [[ -n "$NEXT_SLUG" ]]; then
  # Recurse or push onto the queue. Apply your own policy:
  # - de-dupe against an already-launched set,
  # - cap chain length to avoid runaway loops,
  # - require `axis-history.json` distance to avoid revisiting.
fi
```

`next_mission_candidate` is advisory only. Wrapper authors should still apply
guardrails (max chain length, distance-from-history checks, manual approval
gates) before consuming it.

## Non-goals (explicitly)

- A built-in `rlp-desk auto-chain --slug-prefix … --max-missions N` command is
  **not** in scope. It would re-introduce the coupling we are trying to avoid.
  If you want one, build it as a small wrapper and share it with the community.
- rlp-desk does not validate mission ordering or dependency graphs. The wrapper
  owns this policy.
