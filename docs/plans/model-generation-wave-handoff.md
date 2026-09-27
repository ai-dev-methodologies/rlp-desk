# Handoff — audit-remediation + model-generation + SV-gate waves (2026-09-08)

Branch: `fix/reaudit-wave-1`, cut from `main` @ `6d94518` (v0.25.0).
**Status: three waves complete and committed on the branch. NOT merged to main —
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

**Correction to the wave-2 commit message (`5652d94`).** Its body claims
`parse_model_flag` and `_auto_detect_engine` "now call one shared
`_validate_model_level()`." Only the first half is true: `parse_model_flag`
(`lib_ralph_desk.zsh:282`) does call it (`lib_ralph_desk.zsh:304-341`). Every
`_validate_model_level` call site is inside `lib_ralph_desk.zsh`; nothing in
`run_ralph_desk.zsh` calls it, only comments mention it. `_auto_detect_engine`
cannot call it — it runs at `run_ralph_desk.zsh:632-634` (definition: `:477`),
before the lib is sourced at `:695`, so it keeps its own inline `case`
validation for claude effort and codex reasoning levels (including the
`gpt-6-astra` "minimal" rejection, duplicated verbatim). This duplication is
forced by that sourcing order, not an oversight — the same constraint
documented below for the `gpt-*` classification arm — and the two
implementations are pinned together by `test_cli_env_validation_parity`
(`tests/test_us011_worker_model_upgrade.sh:1229`) rather than by shared code.
Git history can't be rewritten, so the correction lives here.

## Wave 3 — SV-gate remediation

Origin: running wave 2's outstanding SV gate (below) surfaced real defects
rather than confirming the tree. This wave closes them. Two fixes came from the
gate's own scenarios; the rest came from adversarial probes run alongside it.

| Item | Scope |
|---|---|
| DEFECT-1 | Fix-contract carryover across a bare `continue` signal. `write_worker_trigger` looked up only `iter-(n-1).fix-contract.md`, but a `continue` iteration writes no new contract (governance §7 s7 — legitimate "not done yet, no verify happened"), so real unresolved verifier feedback was silently dropped and the same failed approach was re-attempted with no memory of why it failed. `atomic_write` now records every `*.fix-contract.md` it writes into `US_FIX_CONTRACT[us_id]`; the lookup falls back to that map and `main()` clears the entry when the US passes |
| DEFECT-2a | Circuit breaker no longer blocks on a ceiling model that was never dispatched. `check_model_upgrade` runs before the CB check and upgrades on the SAME failure that trips it whenever `CB_THRESHOLD` lands on a ladder-row boundary (default 6 against the 4-rung claude ladder: opus's 2nd fail both promotes to the ceiling and trips the breaker). The old BLOCKED text claimed "Worker upgraded to ceiling model" as if it had run there. Now deferred one failure while `_SAME_US_FAIL_COUNT < 2`, so the model actually gets its own attempt window *(correction, wave 4: "deferred one failure" undersold the mechanism even at the time — the deferral is the SAME 2-attempt window `_SAME_US_FAIL_COUNT < 2` already grants, not a single extra failure; wave 4's M1 additionally found this window could stay open indefinitely — never actually bounded — when every post-ceiling failure classifies as `environment`/`flaky`, since those categories skip `check_model_upgrade` and never advance `_SAME_US_FAIL_COUNT`. See wave 4, item M1.)* |
| DEFECT-2b | **governance §1f¾ Approach Escalation Enforcement** — new section. A model upgrade alone is not evidence of a changed approach. `_record_us_attempt` keeps a capped (3), newest-first per-US record of "which model attempted this US and why it failed"; `write_worker_trigger` persists it to `iter-NNN.attempt-history.md` and surfaces an APPROACH ESCALATION REQUIRED section. The done-claim must then carry a top-level `approach_summary`. Enforced twice: a MECHANICAL pre-gate on both leaders (§3a Layer 1.5, `reason: approach_summary_missing`, own fix-contract body, shared `PREGATE_FAIL_CAP`, never the CB) and a SEMANTIC Verifier check (`Approach Escalation Audit`, check 10⅝, always `failure_category: implementation` on fail) |
| `criteria_results` load-bearing | The verifier contract's `criteria_results[]` had **no consumer at all** — an adversarial probe showed a top-level `verdict: pass` sailing through while an individual criterion carried `met: false` + `missing_evidence`. New `_verdict_criteria_effective` (lib) returns `absent\|malformed\|empty\|populated` + counts; wired at both the main-loop verdict site and `_final_verify_one_us`. Documented as its own governance subsection |
| SV-gate CRITICAL (fail-open) | The attempt-history persist write was unchecked. On failure the Worker prompt still said "APPROACH ESCALATION REQUIRED" while `run_pregate_doneclaim_lint` had no artifact to check and silently skipped the requirement. Now `write_blocked_sentinel ... infra_failure` + `return 1`, and `main()` reacts to that return. The state is computed in the function's real scope, NOT inside the `{ … } \| atomic_write` pipe — only a pipe's last stage avoids forking in zsh, so a `return` from the first stage is absorbed at the subshell boundary and would merely truncate the prompt |
| SV-gate CRITICAL (malformed ≠ absent) | A present-but-not-an-array `criteria_results` rode through exactly like absent, crediting a US on unverifiable evidence. Absent must stay permissive (legacy verdicts; never manufacture a failure from a missing section); malformed means THIS verifier engaged the deciding field and produced garbage — it now overrides to `fail` unconditionally and is logged under its own name |
| SV-gate MEDIUM (consensus) | `_consensus_finalize` hand-builds a fresh `VERDICT_FILE` in both branches and never carried `criteria_results` through, so the whole control above was **inert** under `CONSENSUS_MODE=all\|final-only` — the merged file is what both consumers actually read. Now merged with no engine priority (a `met:false` from either side survives); a malformed value on either side becomes `"malformed-in-consensus-merge"`, which the rule above then classifies as malformed |
| lib standalone sourcing | `US_FIX_CONTRACT` / `US_ATTEMPT_HISTORY` are declared `typeset -gA` in `lib_ralph_desk.zsh`, next to the functions that populate them — not in `run_ralph_desk.zsh`. A lib function must not depend on a global only the run script declares: a consumer that sources the lib standalone (e.g. `tests/test_doneclaim_lint.sh`) never reaches that file, and a run-side-only declaration broke `atomic_write` for every such caller ("assignment to invalid subscript range"). `run_ralph_desk.zsh` carries a comment at the old site saying so |
| init preset drift | `print_run_presets` advertised `--mode agent\|tmux (default: agent)`; the slash command has said `--mode native\|tmux (default: native; legacy 'agent' redirects to native)` since the native-agent revert (`src/commands/rlp-desk.md:241,284`). Text now matches |

**Verification.** `npm run test:node` 773/773. Full `npm run test:zsh` 108/108
files exit 0 (aggregate PASS=662 FAIL=0, plus 577 passed / 0 failed in the
other reporting style). Six new zsh suites
(`test_reaudit_wave1_gate_findings.sh`, `test_defect1_fix_contract_carryover.sh`,
`test_defect2_ceiling_and_approach_escalation.sh`,
`test_lib_standalone_sourcing.sh`, `test_approach_escalation_pregate.sh`,
`test_criteria_results_load_bearing.zsh`) plus
`tests/node/test-approach-summary-fix-contract.test.mjs` and 6 new
`tests/fixtures/done-claim-lint/escalation-*` triples. Per the "a green suite
proved nothing three separate times" note below, every new suite carries a
mutation control that reverts the fix on a scratch copy and asserts the test
actually goes red, and the oracle-style ones extract and execute real
production functions instead of retyping their logic.

**Reading the git history.** The implementation commit and the test commit are
green only together — the wave's edits to existing suites
(`test_doneclaim_lint.sh`, `test_us006_init_presets.sh`,
`test_us015_sentinel_json_taxonomy.sh`) encode the new behavior, so neither
commit stands alone at a bisect point. Same shape as wave 1's
`0e0810e`..`88869fb` sequence.

## Wave 4 — adversarial-review remediation

Origin: an adversarial review of wave 3's diff found 3 HIGH / 5 MEDIUM / 4 LOW
issues before merge (see "Before merge" below, item 1). This wave fixes all
HIGH and MEDIUM findings plus two of the four LOW findings; the remaining LOW
(L3) is recorded under "Deferred, recorded rather than fixed" below rather
than fixed.

| Item | Scope |
|---|---|
| H1 | `criteria_results` override now suppresses `per_us_results` crediting for the SAME round it fires on. Before this fix, a verdict the load-bearing check had just overridden to `fail` (malformed `criteria_results`, or an unmet criterion under a claimed `pass`) could still have its `per_us_results` entries credited by the main loop — granting partial progress on exactly the evidence the check just refused to trust. A genuinely passing US is still credited, just on a later, independently trustworthy round. |
| H2 | `_verdict_criteria_effective` (lib) is fail-closed at the entry level: within a populated `criteria_results` array, a non-object entry AND an object entry whose `met` is missing/null/non-boolean (e.g. `"met":"false"`) both now count as unmet — not just `malformed_entry_count`. Also fixes a silent swallow: the old `select(.met == false)` / `select((.met\|type) != "boolean")` indexed `.met` unconditionally, so ANY non-object entry anywhere in the array aborted jq's whole comprehension with no output, silently dropping a genuine `met:false` sitting next to it. `tests/test_criteria_results_load_bearing.zsh` tests 8/9 were repinned to the new `populated\|1\|1` expectation (lead's call — wave 1 through the first wave-4 pass kept the bad-`met` case malformed-only). |
| H3 | `_consensus_finalize`'s merge and both `VERDICT_FILE` assemblies rebuilt with `jq -n --arg`/`--argjson` throughout, replacing `echo "$a $b" \| jq -s ...` and hand-quoted `echo '...'` JSON construction. zsh's `echo` (unlike bash's) reinterprets backslash escapes by default, so an evidence/description string containing a literal `\n` or `\\` got silently rewritten before jq ever saw it — corrupting the merge input and, separately, producing invalid JSON (e.g. a stray `"criteria_results": ,`) that made the CB treat the round as BLOCKED-worthy garbage. The both-pass branch now validates its own output (`jq empty`) and fails closed with a synthetic `fail` verdict if it's still invalid. |
| M1 | Circuit-breaker ceiling deferral bounded by a new category-independent counter, `_CEILING_DEFERRAL_COUNT` (reset on pass, alongside `_SAME_US_FAIL_COUNT`). `check_model_upgrade` (and therefore `_SAME_US_FAIL_COUNT`) is skipped for `environment`/`flaky` failure categories — if every failure after reaching the ladder ceiling classifies that way, the category-aware counter never advances and the ceiling deferral (DEFECT-2a) would defer forever instead of ever blocking. The new counter counts every ceiling-model failure regardless of category and caps the deferral at the SAME 2-attempt window the category-aware counter already grants on the normal path, so that path is unaffected. |
| M2 | At the pre-gate's `PREGATE_FAIL_CAP`, or when Layer 1's own cap has already forced a verifier round through, the leader now forwards the REAL reason to the verifier — `Done-Claim Format Lint: FAIL (approach_summary_missing)` / `... (fail cap reached: approach_summary_missing)` — instead of the generic, always-empty `violations: []` this sub-check carries by design (approach-escalation violations never populate `{ac,idx}`). Before this fix a cap-forced round told the verifier nothing about why it was forced. |
| M3 | Pre-gate fix-contract writers (`_pregate_register_fail`, `_pregate_register_fail_replay`, `_pregate_register_fail_doneclaim_lint`) now pass a `skip_fix_contract_record` flag to `atomic_write`, which opts that specific write out of the `US_FIX_CONTRACT[us_id]` auto-record DEFECT-1 added in wave 3. Before this fix, ANY `*.fix-contract.md` write — pre-gate or verifier — replaced `US_FIX_CONTRACT` unconditionally, so a later pre-gate fail (e.g. `approach_summary_missing`) could silently overwrite and lose a still-unresolved VERIFIER fix contract from an earlier iteration. |
| M4 | When the H1 criteria_results override fires, `verdict_summary_fail` (and therefore the fix contract and the attempt-history record) is now derived from the override itself — a new "Criteria Results Override" section lists the unmet criteria and their `missing_evidence`/`evidence` — instead of the verifier's own `.summary`, which typically still reads as a pass narrative (the override exists precisely for the case where that narrative cannot be trusted). |
| M5 | `_record_us_attempt` now reads `DONE_CLAIM_FILE`'s own `approach_summary` for the failed attempt and appends it to that attempt's history line (`\| approach: ...`), so governance §1f¾ check 10⅝ can compare a new attempt against what was actually TRIED on each prior attempt, not only the verifier's failure summary. Read directly from the fixed `DONE_CLAIM_FILE` path rather than threading a new argument through the call site, since `run_ralph_desk.zsh` is owned by a different wave-4 agent this iteration. |
| L1 | `_record_us_attempt` collapses embedded newlines in the verifier's `.summary` before building the attempt-history line. `US_ATTEMPT_HISTORY` is capped with `head -n $ATTEMPT_HISTORY_CAP` — a LINE cap, not an entry cap — so an unstripped multi-line summary could by itself exceed the cap and evict every prior attempt; collapsing newlines first makes one recorded attempt always exactly one physical line. |
| L2 | zsh (`run_pregate_doneclaim_lint`, via a jq `gsub`) and Node (`done-claim-lint.mjs`'s new `stripBlank`) now strip the IDENTICAL Unicode whitespace / zero-width / BOM codepoint set when checking `approach_summary` for blankness. zsh's old `${var//[[:space:]]/}` recognizes only single-byte ASCII whitespace under a C locale — a value made entirely of a multi-byte blank (NBSP, U+2007, U+3000, ...) or a zero-width/BOM character (U+200B-U+200D, U+2060, U+FEFF) survived that strip as "present" while Node's `.trim()` disagreed (partially, for the zero-width/BOM set) — the two leaders could reach different verdicts on the same done-claim. |
| L4 | Three independent minor fixes: (a) `write_worker_trigger` now ends with an explicit `return 0` so a stdout write failure on its trailing `log` call (e.g. EPIPE on a closed tmux pane) can no longer make the function itself report failure and fail-closed the whole campaign (`worker_trigger_failed`) even though the trigger/prompt were written successfully; (b) the per-US verdict-dispatch block's repeated `local name1 name2 ...` (no assignment) declarations are now pre-initialized to `""`, suppressing zsh's `typeset -p`-style stdout echo of already-set variables on the loop's 2nd+ pass; (c) a stale `_consensus_finalize` comment claiming `_final_verify_one_us` reads the merged consensus file was corrected — that function never calls consensus at all; it runs its own single-verifier round per US. |

**Verification.** New suites `tests/test_reaudit_wave4_lib.sh`,
`tests/test_reaudit_wave4_run.sh`, `tests/node/test-reaudit-wave4.test.mjs`,
plus edits to `tests/test_criteria_results_load_bearing.zsh` and
`tests/test_reaudit_wave1_gate_findings.sh` for the repinned H2 expectation.
See those files for the mutation-control pattern (wave 3's "Context worth
carrying forward" note below still applies).

## Before merge

1. **SV gate re-run — REQUIRED, NOT DONE.** `src/commands/rlp-desk.md`,
   `src/governance.md` and `src/scripts/init_ralph_desk.zsh` all changed in
   wave 2, so CLAUDE.md's 3-scenario gate applies. Round 1 of that gate ran and
   found 6 issues; an independent review found 6 more; all 12 were fixed. The
   **re-run after those fixes did not complete** — the session ended first. Run
   LOW / MEDIUM / CRITICAL against the committed tree before merging.
   **Wave 3 raised the bar rather than clearing it**: running this gate is what
   produced wave 3 (see that section), and wave 3 itself changed
   `src/governance.md` (§1f¾ is a brand-new governance section) and
   `src/scripts/init_ralph_desk.zsh` (both generated prompts), so the gate now
   has to cover all three waves, and its CRITICAL scenario must exercise the new
   §1f¾ enforcement end to end: a real escalation firing, the artifact landing,
   a done-claim without `approach_summary` being bounced by the mechanical
   pre-gate, and a restated `approach_summary` being caught by the Verifier's
   check 10⅝ rather than passing on presence alone.
   **Wave 3's adversarial review has since run and its findings are fixed**:
   it found 3 HIGH / 5 MEDIUM / 4 LOW issues, and wave 4 (see that section
   above) fixes all HIGH/MEDIUM plus two of the four LOW (L1, L2, L4); L3 is
   deferred (see "Deferred, recorded rather than fixed"). The SV gate re-run
   still has not happened and now has to cover FOUR waves, not three — its
   CRITICAL scenario must exercise §1f¾ end to end (a real escalation firing,
   the artifact landing, a done-claim without `approach_summary` bounced by
   the mechanical pre-gate, a restated `approach_summary` caught by the
   Verifier's check 10⅝) AND wave 4's own fixes need their OWN adversarial
   re-review before merge — a review that fixed 12 findings has not itself
   been re-reviewed. Scenario design that worked for wave 3: LOW = doc/code
   agreement on every model id and default; MEDIUM = real ladder walks from
   every shipped default and documented tier start, alias routing on all four
   implementations, the `WORKER_EFFORT` crash-restart round trip including the
   never-set legacy case; CRITICAL = model-specific vocabulary enforcement on
   both the CLI-flag and env-var paths, injection-shaped values failing
   closed, and init's split and heading paths (init was touched again in
   wave 2).
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

- **L3 (reaudit wave 4, adversarial review)**: escalation state is
  session-local and does not survive a leader restart. `US_ATTEMPT_HISTORY`
  and `US_FIX_CONTRACT` are `typeset -gA` in-memory maps populated during a
  run — a leader restart mid-campaign (crash, manual kill, host reboot) loses
  both, so the next Worker on that US loses its recorded prior-attempt history
  and any still-unresolved verifier fix contract, with no on-disk map to
  reconstruct them from (the persisted `iter-NNN.attempt-history.md` /
  `iter-NNN.fix-contract.md` files themselves survive, but nothing re-derives
  the in-memory index that points `US_ATTEMPT_HISTORY[us_id]` /
  `US_FIX_CONTRACT[us_id]` at the latest one). Separately, `_MODEL_UPGRADED`
  is not reset after a partial-progress credit (H1's per_us_results crediting
  path, when it legitimately fires) — the flag can stay set past the point a
  US was actually credited, so ceiling-deferral bookkeeping (M1) that reads
  `_MODEL_UPGRADED` may still see it "on" against a US whose partial progress
  has already moved past that credit. Not fixed here: both require deciding a
  reconstruction/reset policy, not a mechanical patch, and neither was
  reachable by the mutation-tested suites this wave added.
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
  `run_ralph_desk.zsh:632-634`, before the lib is sourced at `:695`. A helper
  defined in the lib and called from inside it crashes every invocation at
  startup — and because that crash exits non-zero, a rejection test can pass for
  entirely the wrong reason. This is why the `gpt-*` classification arm is
  duplicated across the two zsh sites with a parity test instead of centralized;
  each site carries a comment saying so.
- The role-versus-model separation is the project's quality/cost tradeoff, not
  an accident of history. When a generation moves, the roles keep their position
  on the spectrum and only the model occupying each position changes.

## Wave 4 round 2 (adversarial-review follow-up, fixed on this branch)

Eight findings from a second adversarial pass over wave 4: H1's criteria-override
flag no longer fires on every honest fail (verdict already "fail") with a
well-formed unmet criterion — that case still credits `per_us_results`
partial progress as before. (This is the round-2 starting point; rounds 3 and
the codex-P1 addendum below refine the exact firing rule further — the
condition actually shipped is described precisely in those sections, not
here.) The fix-contract/attempt-
history jq filters for unmet criteria use the same fail-closed, type-checked
predicate as `_verdict_criteria_effective` (a non-object array entry no longer
aborts the whole comprehension); `_consensus_finalize`'s criteria/issues merge
reads directly from the two verdict FILES via `--slurpfile` instead of passing
extracted arrays through `--argjson` argv (macOS/Linux ARG_MAX headroom), with a
fail-closed sentinel — never a bare `[]` — on any merge failure; the post-write
VERDICT_FILE guards now require an actual verdict object (`jq -e 'type=="object"
and has("verdict")'`), not `jq empty`, which passed a 0-byte file; 22 bare
`local NAME` re-declarations inside the main loop got explicit `=""` inits (same
stdout-leak class as wave 4's own L4b); `_CEILING_DEFERRAL_COUNT` is now
persisted/restored across a leader relaunch next to `_SAME_US_FAIL_COUNT`
(status.json `ceiling_deferral_count`, missing → 0); and the M3 opt-out
(`atomic_write`'s `skip_fix_contract_record`) now also covers the commit oracle
and only refuses to record when a real VERIFIER contract already occupies the
slot — a pregate/oracle-only contract still carries when nothing better exists.

**Accepted, not fixed**: on the env/flaky failure-category path, the
`_CEILING_DEFERRAL_COUNT` bound (M1) can still grant up to 2 EXTRA attempts
beyond the nominal window when the ladder ceiling was reached before
`_SAME_US_FAIL_COUNT` itself hit 2 (i.e. the deferral window opens later than
the same-US counter alone would suggest) — bounded, not unbounded, so left as-is.

### Wave 4 round 3 (second adversarial-review follow-up, fixed on this branch)

Three more findings, all on the round-2 code above. (1) The criteria-override
`fired` flag only compared the pre-override verdict against the literal string
`pass`, so any verdict that normalizes to something else non-fail — `pass.`,
`PASS: all ACs met`, `approved`, `success`, `null`, `blocked`, `request_info` —
slipped through: the override still forced `verdict=fail`, but `fired` stayed
0, wrongly crediting `per_us_results` and leaving the untrusted "looks great"
narrative in the attempt history / fix contract. Fixed by comparing the
captured pre-override verdict (`_cr_original_verdict`) against `fail` instead
of `pass`, and by naming the actual claimed verdict in the log/summary/heading
text instead of hardcoding "pass". This does not change the separate,
pre-existing (wave 1) `case $verdict in blocked)` dispatch itself — a blocked
verdict with an unmet criterion is still force-converted to fail here exactly
as before; only the fired-bookkeeping around that existing behavior was
corrected. (2) The malformed-criteria_results branch fires unconditionally by
design (even on an honest pre-existing "fail"), and used to fully REPLACE the
verifier's own summary with generic malformed text and print the heading
"verifier reported pass; overridden to fail" regardless of what the original
verdict actually was. Now it APPENDS a malformed note to the verifier's own
summary instead of replacing it, and the heading only claims an override when
one actually happened (original verdict != fail); an honest fail with
malformed criteria_results gets an honest "partial progress not credited"
heading instead. Partial-progress credit is still suppressed either way — only
the wording changed. (3) `_consensus_finalize`'s issues[] merge combined both
engines in ONE jq expression, so a bare-string issue entry on either side (`. +
{source:...}` on a string is a jq type error) or an entire engine's verdict
file being a non-object (indexing `.issues` on it is a hard error `?` does not
catch when it sits after the index rather than the iterate) aborted the WHOLE
merge — both engines' issues collapsed to the fail-closed sentinel string, even
when the OTHER engine's issues were perfectly valid objects. Fixed by
extracting each engine's issues independently (two separate jq calls, each
reading only its own file, each guarding the `.issues` INDEX itself with `?`
via `(.issues? // [])[]?` rather than `.issues[]?`, and coercing a non-object
array element to a safe placeholder object) before concatenating the two
results through temp files (same ARG_MAX reasoning as the round-2 criteria
merge). A stale test fragility surfaced during this round's own regression
run: `tests/test_reaudit_wave1_gate_findings.sh` embeds an extracted source
snippet directly into a double-quoted `zsh -c "..."` string, so any literal
double-quote characters in that snippet's comments (introduced by finding #1's
fix) broke the outer quoting — fixed by rewording the new comments to avoid
embedded double quotes and backticks; the underlying embedding technique
itself is unchanged (pre-existing style, not owned by this fix).

**Codex round-2 addendum (P1, folded into round 3, fixed on this branch).**
Finding #1 above only handled a TRUE override (verdict claimed non-fail, got
flipped to fail). It missed a second case: an HONEST fail (verdict already
"fail") whose unmet count included a MALFORMED entry — e.g. `"met":"false"`
as a string rather than a boolean, or a non-object array element — which
H2 already folds into `_cr_unmet` alongside a clean `met:false`. That entry
is garbage, not a real verifier judgment, so crediting `per_us_results` off
it is the same partial-credit hole the whole control exists to close, even
though nothing was "overridden." Fixed by splitting the concept in two:
`_criteria_override_fired` now means "evidence untrusted this round" (fires
on top-level-malformed, on an entry-level malformed value even under an
honest fail, OR on a true override) and drives `per_us_results` suppression;
a new `_cr_true_override` means "the verdict was actually flipped from
non-fail to fail" and drives which M4 wording applies (full replace + the
"reported X; overridden to fail" heading) versus an honest fail with
untrusted evidence (append a truthful note to the verifier's own summary +
an honest "partial progress not credited" heading). An honest fail whose
unmet entries are ALL well-formed booleans stays untouched — still credits
other passing US exactly as before. This also simplified the M4 heading
condition: it no longer needs to check `_cr_state` at all, since
`_cr_true_override` alone captures the right distinction regardless of
whether the untrusted evidence was top-level or entry-level.

### Wave 4 round 4 (mostly rendering/doc, fixed on this branch)

Mostly how the untrusted-evidence rounds from rounds 2-3 are RENDERED, plus
one unrelated log-line fix and the governance write-up (§ above, "Verifier:
`criteria_results` is load-bearing") — but NOT purely rendering: item B's
`fail*` prefix match is itself a crediting decision (which verdicts count as
an honest fail vs. a true override), and round 5 below found it was too
permissive (`fail*` is unbounded — see that section). (A) A TRUE override with top-level-malformed criteria_results
used to APPEND its note to the verifier's own summary like the honest-fail
case did — for a long summary, that appended note fell past
`_record_us_attempt`'s 120-character truncation and vanished, letting an
untrusted narrative reach the attempt history with no visible marker. Fixed
by REPLACING the summary on a true override (matching the non-malformed
true-override path) and PREPENDING the note on an honest fail (both
top-level and entry-level) so it survives truncation regardless of summary
length. (B) The pre-override-verdict comparison only recognized the exact
literal `fail` — a verifier phrasing an honest fail as `fail.`, `failed`, or
`FAIL: ...` was wrongly treated as a true override, discarding its real
diagnosis for a fabricated one. Fixed by matching the `fail*` PREFIX instead
of the exact word. Separately, when the whole VERDICT_FILE is not a JSON
object (e.g. a bare top-level array), `.verdict` cannot even be read and the
captured original verdict is empty — the heading used to render an empty
`reported ''`; now it renders `<no top-level verdict>`. (C) The fix-contract
heading now depends ONLY on `_cr_true_override`, never on `_cr_state` — an
untrusted-but-honest round (whether top-level or entry-level malformed) gets
the same plain `## Criteria Results (untrusted — partial progress not
credited)` heading either way, and the accompanying note names the actual
shape of the garbage (`criteria_results is not an array` vs `N malformed
criteria_results entry/entries`). (D) An unrelated log-line gap found during
this round's own regression pass: the Layer 1.5 pre-gate SHORT-CIRCUIT path's
log line printed the bare empty violations list `[]` for
`approach_summary_missing` (the FORCE path had already been fixed for this
in wave 4's M2) — now it names the reason explicitly, matching the FORCE
path's wording.

A repeating test fragility, now fixed structurally: the round-2/3/4 comment
growth inside the criteria-override decision block kept breaking
`tests/test_reaudit_wave1_gate_findings.sh`'s Item-2 mutation control, which
matched an EXACT multi-line string including comments. Replaced with a
regex anchored only on the two structural boundary lines (the malformed
`if` and the `elif (( _cr_unmet > 0 ))`), so a future comment-only addition
inside that span no longer breaks the mutation control.

### Wave 4 round 5 (codex final pass on round 4, fixed on this branch)

Two behavior fixes, both to the criteria-override decision block round 4
introduced, plus doc/test corrections found during the same review.

**P2 — the `fail*` glob was unbounded.** Round 4's `[[ "$_cr_original_verdict"
!= fail* ]]` matched ANY verdict starting with the four letters "fail",
including `failsafe_pass` and `failover` — verdicts that start with "fail"
but mean the opposite (or something unrelated). Those were wrongly treated
as honest fails, letting a genuinely flipped verdict skip the true-override
path and its per_us_results crediting suppression. Fixed with a new lib
helper, `_verdict_is_fail_variant()` (next to `_normalize_verdict`):
`[[ "$1" =~ '^(fail|failed|failure|failing)([^a-z0-9]|$)' ]]` — a BOUNDED
match requiring one of the four fail aliases followed by end-of-string or a
non-alphanumeric separator. `fail.`, `failed`, `failure`, `failing`,
`fail: see issues` still match (honest fail); `failsafe_pass`, `failover` no
longer do (true override). Applied at both comparison sites (the top-level-
malformed branch and the unmet-count branch).

**P3 — `.verdict` alone renders literal `"null"` for a missing key too.**
`jq -r '.verdict'` on either an explicit JSON `null` OR a genuinely missing
`verdict` key both render the STRING `"null"` — non-empty, so round 4's
`${_cr_original_verdict:-<no top-level verdict>}` placeholder fallback never
fired for the missing-key case (only for a hard jq error, e.g. the whole
file being a non-object). Fixed by reading with `.verdict // empty` instead
of bare `.verdict`, so both a missing key and an explicit `null` collapse to
real emptiness and get the honest placeholder; the criteria-override
decision still (correctly) treats an empty/missing verdict as non-fail — the
SAME classification as before this fix, only the rendered TEXT changed.

**Doc/test fixes found during this same review pass:**
- `src/governance.md`'s "Verifier: `criteria_results` is load-bearing"
  section now states the true-override condition using the bounded rule
  (not a fail variant per the P2 regex above) and documents that a
  missing/null verdict is non-fail and renders `<no top-level verdict>`.
- `src/governance.md`'s M2 cap-reached/Layer-1-forced paragraph had the
  wrong layer attribution for what forces a verifier round; corrected to
  match `run_ralph_desk.zsh`'s actual Layer 1 (static gate,
  `PREGATE_FAIL_CAP`) vs. Layer 1.5 (done-claim TDD-sequence lint, its OWN
  `PREGATE_FAIL_CAP`) split.
- `tests/test_reaudit_wave4_run.sh`'s A1 test (round 4 item A) used a
  200-char needle (`grep -q "$LONGX"`) against a 120-char-truncated attempt-
  history line — that needle can NEVER match regardless of whether the code
  is correct, making the assertion vacuous. Replaced with a short marker
  placed at position 0 of the summary, checked for absence (proves full
  replacement), plus a real mutation control that reverts the fix on a
  scratch copy and confirms the marker then survives.
- The same test file's F2R3 harness (used by rounds 3-5's tests) hardcoded
  its own copy of the `.verdict` read instead of extracting the real
  production line — a second copy of the exact bug P3 above just fixed,
  sitting in the test infrastructure itself. Fixed to extract the real
  line by content anchor (same technique as every other harness in this
  file), with a mutation control reverting `// empty` back to bare
  `.verdict` and confirming the missing-verdict test goes red.
