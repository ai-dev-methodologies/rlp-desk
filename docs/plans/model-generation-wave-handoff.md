# Handoff — audit-remediation + model-generation waves (2026-09-08)

Branch: `fix/reaudit-wave-1`, cut from `main` @ `6d94518` (v0.25.0).
**Status: two waves complete and committed on the branch. NOT merged to main —
merge is an explicit owner gate. One verification step is outstanding; see
"Before merge" below.**

This document plus the branch's own commit messages are the complete
cross-machine continuation kit. Nothing is needed from any session scratchpad.

## Wave 1 — audit remediation (commits `0e0810e`..`88869fb`)

Origin: a 137-agent re-audit of v0.25.0 produced 8 HIGH / 24 MEDIUM confirmed
findings (report recorded in `docs/rlp-desk/verification-history.md`, entry
2026-09-07). This wave fixed the top items.

| Commit | Scope |
|---|---|
| `0e0810e` | init: portable sed rendering with escaping and delete-on-failure self-heal; byte-exact objective-masked authored detection; `version_file` instead of bare `rm`; both split functions hardened (shared heading ERE, `ENVIRON` instead of `awk -v`, array `(N)` counts, append-mode `seen[]`, header capture without a tmp file) |
| `10a60fd` | leader: `setopt POSIX_TRAPS` + EXIT-only chain + `_on_signal` for INT/TERM/HUP with `exit 128+n`, armed at the top of `main()`; INTERRUPTED terminal state; `_bug8_autocommit` commits with an explicit pathspec; D-20 gate uses `--literal-pathspecs`; NUL-safe `_git_dirty_names`; engine-aware `check_model_upgrade`; `typeset -g` replaces `eval` in `_auto_detect_engine` |
| `3a198fe` | node: `readAnalytics` derives verdict/duration from the zsh campaign.jsonl schema and skips malformed rows; `--worker-model` family validated against the zsh vocabulary with a parity test |
| `088534b` | docs: `subagent_type` removed from Agent() examples; codex `exec -c model_reasoning_effort=` form; analytics path; SV report writers; INTERRUPTED; §6 layout from the install manifest; verification-history entry |
| `88869fb` | tests: `zsh -f` harness isolation; `test:zsh` accumulates instead of aborting at the first failure; anchors updated for the leader changes |

## Wave 2 — model generation (uncommitted at time of writing → committed as the
next commit on this branch)

Adds Claude Fable 5.1 (`claude-fable-5-1`) and Codex 6 Astra (`gpt-6-astra`).

**Two real bugs, not just registry additions:**
1. The bare alias `fable` was classified as the CODEX engine in all four
   implementations, because the claude alias list was `haiku|sonnet|opus|claude|claude-*`.
   Worse, a bare canonical `gpt-*` id — including `gpt-6-astra` itself, the exact
   string in `models.json` and every doc table — classified as CLAUDE, so
   `--worker-model gpt-6-astra` would have invoked `claude --model gpt-6-astra`.
2. Neither ladder could reach its generation's top model. Claude terminated at
   `opus` while every doc recommended `claude-fable-5-1:max` for final
   verification; codex terminated at `gpt-5.6-sol:xhigh` with astra an
   unreachable island.

**Resulting ladders** (`src/node/models.json`):
- Claude: `haiku → sonnet → opus → claude-fable-5-1:max` (ceiling)
- Codex cost lane: `luna:high → luna:max → terra:max → sol:xhigh → astra:high → astra:xhigh`
- Codex speed lane: `sol:medium → sol:high → sol:xhigh → astra:high → astra:xhigh`

**Defaults** — the role/cost tradeoff is preserved deliberately. Workers are
high-volume so they start cheap; only the terminal judgment roles moved to the
generation top:

| Variable | Value | Rationale |
|---|---|---|
| `WORKER_CODEX_MODEL` | `gpt-5.6-luna` | cheapest current-generation family (cost factor 0.04); the LOW cost-lane start in the doc's own cross-engine table |
| `VERIFIER_CODEX_MODEL` | `gpt-5.6-terra` | mid rung; per-US verification must stay below final verification |
| `FINAL_VERIFIER_CODEX_MODEL` | `gpt-6-astra` | low-volume judgment role |
| `FINAL_VERIFIER_MODEL` | `claude-fable-5-1` | same principle, claude side; the docs already recommended it |
| `FINAL_CONSENSUS_MODEL` | `gpt-6-astra:xhigh` | final cross-verification, same principle |
| `WORKER_MODEL` / `VERIFIER_MODEL` | `haiku` / `sonnet` | unchanged; already cheap/mid within their generation |

An invariant test now derives each engine's ceiling from `models.json` at test
time and asserts the shipped worker default sits at least two rungs below it.
A previous round of this wave put astra in the worker slot, which emptied the
ladder and made `check_model_upgrade` return `already_max` from iteration one;
the invariant exists so that cannot recur on the next generation bump.

**`gpt-6-astra` reasoning levels — measured, not assumed.** `models_cache.json`
does not list the model, so each candidate level was probed live with a
one-token reply in a read-only sandbox. `low|medium|high|xhigh|max` are
confirmed both by successful probe and by the server's own enumeration in its
rejection message. `minimal` is confirmed unsupported (HTTP 400). `ultra` does
not error but is absent from that enumeration, so it is retained in the ladder
and flagged as accepted-but-unconfirmed. The `minimal` rejection is
**model-specific**: `gpt-5.5:minimal` still passes.

## Before merge

1. **SV gate re-run — REQUIRED, NOT DONE.** `src/commands/rlp-desk.md`,
   `src/governance.md` and `src/scripts/init_ralph_desk.zsh` all changed in
   wave 2, so CLAUDE.md's 3-scenario gate applies. Round 1 of that gate ran and
   found 6 issues; an independent review found 6 more; all 12 were fixed. The
   **re-run after those fixes did not complete** — the session ended first. Run
   LOW / MEDIUM / CRITICAL against the committed tree before merging.
   Scenario design that worked for this wave: LOW = doc/code agreement on every
   model id and default; MEDIUM = real ladder walks from every shipped default
   and documented tier start, alias routing on all four implementations, the
   `WORKER_EFFORT` crash-restart round trip including the never-set legacy case;
   CRITICAL = model-specific vocabulary enforcement on both the CLI-flag and
   env-var paths, injection-shaped values failing closed, and init's split and
   heading paths (init was touched again in wave 2).
2. **Local sync after merge** — CLAUDE.md Tier-1: `npm install`, then
   `npm run verify:sync`. Not done yet; the install at `~/.claude/ralph-desk/`
   is still on the pre-wave state by design.

## Owner decisions still open

These need a number that cannot be derived locally; nothing is blocked on them.

1. **`cost_factors` for the new families.** The table is `sol 1.0 / terra 0.4 /
   luna 0.04` and covers codex only — `_resolveCostFactor` and
   `_cost_factor_x100` are both gated on `worker_engine === 'codex'`, so claude
   models never consult it. No entry was invented for `gpt-6-astra`,
   `gpt-5.5`, `gpt-5.4` or `spark`; they fall back to `1.0`, which is already
   the conservative non-downgrading value. The claude family's own price ratio
   is known (haiku:sonnet:opus:fable = 1:2:5:10) but there is no cross-engine
   dollar anchor to place it against sol, so it was documented rather than
   guessed. Deciding this means either supplying sol's per-token price, giving
   claude its own scale, or leaving the fallback.

## Deferred, recorded rather than fixed

- `test_e2e_restore` retypes `WORKER_MODEL="$_ORIGINAL_WORKER_MODEL"` instead of
  executing the shipped line. Pre-existing, and now strictly redundant with the
  fixed `test_claude_worker_effort_upgrade_and_restore`, which executes the real
  block and covers model, effort and the upgrade flag.
- The AC1-AC6 section of `test_us011_worker_model_upgrade.sh` asserts by
  grepping for variable names in source — structural existence only.
- `lib_ralph_desk.zsh` never deletes stale per-US split files when a US is
  removed from the PRD; the orphan keeps matching `_list_contract_files` and so
  stays in the sealed set. Pre-existing at HEAD.
- `docs/rlp-desk/protocol-reference.md` documents `--codex-model`,
  `--worker-engine` and `--codex-reasoning`, none of which exist in the code.
  Left alone deliberately: correcting the values would make a dead interface
  look live.
- `run_ralph_desk.zsh` header doc claims `WORKER_MODEL` defaults to `sonnet` and
  `VERIFIER_MODEL` to `opus`; the real defaults are `haiku` / `sonnet`.
  Pre-existing, unrelated to either wave.
- `tests/sv-large-campaign/test-dbacklog.zsh` has 3 failures whose grep anchors
  reference strings absent at HEAD too — pre-existing, verified not caused by
  either wave.

## Context worth carrying forward

- **A green suite proved nothing three separate times this session.** The claude
  model ladder was dead because every test set up its sandbox without the one
  environment variable that triggered the bug. A restore test retyped the line
  it was meant to verify, so deleting the shipped line left the suite green. A
  gate returned PASS against a scenario set that omitted an existing committed
  contract test, and the wave's own regex unification had already broken it.
  Every new test in these waves therefore carries a mutation control, and the
  oracle-style ones execute extracted source rather than retyped logic.
- **Oracles anchored to `HEAD` expire on commit.** Three tests built their
  pre-fix baseline with `git show HEAD:`; the moment wave 1 was committed, HEAD
  stopped being pre-fix and they failed loudly. They now anchor to a fixed
  commit. Check for this pattern before committing any wave that adds one.
- **The zsh sourcing order is load-bearing.** `_auto_detect_engine` runs at
  `run_ralph_desk.zsh:619-621`, before the lib is sourced at `:682`. A helper
  defined in the lib and called from inside it crashes every invocation at
  startup — and because that crash exits non-zero, a rejection test can pass for
  entirely the wrong reason. This is why the `gpt-*` classification arm is
  duplicated across the two zsh sites with a parity test instead of centralized;
  each site carries a comment saying so.
- The role-versus-model separation is the project's quality/cost tradeoff, not
  an accident of history. When a generation moves, the roles keep their position
  on the spectrum and only the model occupying each position changes.
