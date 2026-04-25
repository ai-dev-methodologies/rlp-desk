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

The Node entry point `src/node/run.mjs` also surfaces the BLOCKED reason on
**stderr** with **exit code 2** so wrappers can distinguish blocked outcomes
from generic script failure (exit 1). PRD lint reject is exit 2 too — see
`init_ralph_desk.zsh`.

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

  case "$rc" in
    0) print "$SLUG completed cleanly" ;;
    2) print "$SLUG blocked (lint reject or verifier blocked) — stopping chain"; exit 2 ;;
    *) print "$SLUG exited with $rc — stopping chain"; exit "$rc" ;;
  esac
done
```

Two design notes:

- The wrapper checks the **sentinel files first**. This makes re-runs idempotent
  — if the chain crashed mid-way and you re-launch the wrapper, finished
  missions are skipped without rework.
- The wrapper distinguishes **exit 2** from other non-zero exits because
  rlp-desk uses 2 specifically for "PRD lint rejected" and "verifier blocked".
  An automation system can route those to the operator while still alerting on
  generic errors via exit 1.

## Flywheel-driven dynamic chain (optional)

If a mission's flywheel populates `memos/<slug>-flywheel-signal.json` with a
`next_mission_candidate`, the wrapper can pick the next slug from that field
instead of a fixed list:

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
