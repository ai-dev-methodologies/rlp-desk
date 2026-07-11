# TDD Evidence: consensus metadata mode fix

Branch: `fix/consensus-metadata-mode`
Scope: `src/scripts/run_ralph_desk.zsh` lines ~3449-3466 (metadata.json write) and
~3505-3510 (DEBUG consensus_flow gate).

## Bug

metadata.json's `consensus` field, and the DEBUG `consensus_flow` log line,
both read the legacy `VERIFY_CONSENSUS` env var directly. v0.16+ unified
consensus control into `CONSENSUS_MODE` (`off|all|final-only`), with legacy
`VERIFY_CONSENSUS`/`FINAL_CONSENSUS` only mapped **into** `CONSENSUS_MODE` at
module top (src/scripts/run_ralph_desk.zsh:317-327), not read directly by the
metadata writer or the debug gate. A campaign started with
`--consensus all|final-only` or `--final-consensus` (CLI flags, not the
legacy env vars) therefore had `CONSENSUS_MODE` active while
`VERIFY_CONSENSUS` stayed 0 — metadata.json falsely reported `consensus: 0`,
and the debug `consensus_flow` line never fired for CLI-driven consensus.

## Contract (decided upstream, not redesigned here)

metadata.json `consensus` stays a 0/1 number (no schema change): `1` iff
`CONSENSUS_MODE != "off"`, else `0`. Legacy `VERIFY_CONSENSUS=1` still yields
`1` because it maps into `CONSENSUS_MODE=all` upstream (line 322-323) — the
fix relies on that existing mapping rather than reading the legacy var.

## Journeys covered (tests/test_consensus_metadata_mode.sh)

| Case | Input | Expected `metadata.json.consensus` | Result |
|---|---|---|---|
| (a) happy | `--consensus all` | 1 | RED: 0 -> GREEN: 1 |
| (b) happy | `--final-consensus` (legacy flag -> CONSENSUS_MODE=final-only) | 1 | RED: 0 -> GREEN: 1 |
| (c) negative | no consensus flags | 0 | PASS in RED and GREEN (unaffected path) |
| (d) legacy | env `VERIFY_CONSENSUS=1` | 1 | PASS in RED and GREEN (VERIFY_CONSENSUS was already 1 directly) |
| (e) boundary | `--consensus off` (explicit) | 0 | PASS in RED and GREEN (unaffected path) |
| (f) debug gate | `DEBUG=1` + `--consensus final-only` | debug.log has `consensus_flow` line mentioning `final-only` | RED: missing -> GREEN: present |

## RED output (bash tests/test_consensus_metadata_mode.sh, before fix)

```
=== Consensus metadata.json mode reproducer ===

  FAIL: (a) --consensus all -> metadata.json consensus == 1 (got '0', expected '1')
  FAIL: (b) --final-consensus -> metadata.json consensus == 1 (got '0', expected '1')
  PASS: (c) no consensus flags -> metadata.json consensus == 0
  PASS: (d) VERIFY_CONSENSUS=1 (legacy env) -> metadata.json consensus == 1
  PASS: (e) --consensus off (explicit) -> metadata.json consensus == 0

  FAIL: (f) debug.log missing consensus_flow/final-only line (content: ...
        [OPTION] verify_mode=per-us consensus_mode=final-only max_iter=20 ...
        no consensus_flow line present)

=== RESULTS: 3 passed, 3 failed ===
```

Commit: `904beb1` — `test: add reproducer for metadata consensus misreport (CONSENSUS_MODE)`

## Fix (minimal diff, exactly 2 sites)

```diff
   # --- metadata.json: always write at campaign start (cross-project identification) ---
+  local _metadata_consensus=0
+  [[ "$CONSENSUS_MODE" != "off" ]] && _metadata_consensus=1
   jq -n \
     ...
-    --argjson consensus "${VERIFY_CONSENSUS:-0}" \
+    --argjson consensus "$_metadata_consensus" \
     ...

-    if [[ "${VERIFY_CONSENSUS:-0}" = "1" ]]; then
-      log_debug "[OPTION] consensus_flow=each_verify_runs_claude+codex_both_must_pass"
+    if [[ "$CONSENSUS_MODE" != "off" ]]; then
+      log_debug "[OPTION] consensus_flow=mode=$CONSENSUS_MODE each_verify_runs_claude+codex_both_must_pass"
     fi
```

`zsh -n src/scripts/run_ralph_desk.zsh` — syntax OK.

Commit: `cba1ab3` — `fix: derive campaign metadata consensus from unified CONSENSUS_MODE`

## GREEN output (bash tests/test_consensus_metadata_mode.sh, after fix)

```
=== Consensus metadata.json mode reproducer ===

  PASS: (a) --consensus all -> metadata.json consensus == 1
  PASS: (b) --final-consensus -> metadata.json consensus == 1
  PASS: (c) no consensus flags -> metadata.json consensus == 0
  PASS: (d) VERIFY_CONSENSUS=1 (legacy env) -> metadata.json consensus == 1
  PASS: (e) --consensus off (explicit) -> metadata.json consensus == 0

  PASS: (f) DEBUG=1 + --consensus final-only -> debug.log has consensus_flow line mentioning final-only

=== RESULTS: 6 passed, 0 failed ===
```

## Regression suites (all green after fix)

| Suite | Result |
|---|---|
| tests/test_us005_final_consensus.sh | 14 passed, 0 failed |
| tests/test_us008_self_verification_e2e.sh | 33 passed, 0 failed |
| tests/test_us003_campaign_report.sh | 48 passed, 0 failed |

## Guarantee table

| Guarantee | Enforced by |
|---|---|
| metadata.json `consensus` is 1 whenever CONSENSUS_MODE is active, regardless of how it was activated (CLI flag or legacy env var) | test (a), (b), (d) |
| metadata.json `consensus` is 0 when consensus is off (default or explicit `--consensus off`) | test (c), (e) |
| DEBUG consensus_flow log line fires for CLI-driven consensus and names the active mode | test (f) |
| No regression to existing consensus scope/dependency/startup-log behavior (US-005) | tests/test_us005_final_consensus.sh (14/14) |
| No regression to self-verification E2E debug logging, cost-log consensus timing fields, or codex dependency checks (US-008) | tests/test_us008_self_verification_e2e.sh (33/33) |
| No regression to campaign report generation and metadata-adjacent fields (US-003) | tests/test_us003_campaign_report.sh (48/48) |
| Script remains syntactically valid zsh | `zsh -n src/scripts/run_ralph_desk.zsh` |

## Round 2: EFFECTIVE_CB_THRESHOLD ordering bug

Flagged as out-of-scope in round 1, then confirmed in-scope by the team lead:
same consensus surface, and D-22 documented the intended contract (consensus
mode doubles the CB budget via `CB_THRESHOLD*2`, see
`tests/test_us002_consensus_stability.sh` AC4-happy).

### Bug

`EFFECTIVE_CB_THRESHOLD` (src/scripts/run_ralph_desk.zsh:330-335, pre-fix)
was computed from `$CONSENSUS_MODE` at module-parse time, *before* the CLI
arg-parsing loop (`--consensus`, `--final-consensus`, `--verify-consensus`,
~line 4560-4590) reassigns `CONSENSUS_MODE`. Env-var-driven `CONSENSUS_MODE`
(set before the script starts, or via legacy `VERIFY_CONSENSUS`/
`FINAL_CONSENSUS` mapped at module top) already worked, since it's resolved
by the time the early computation runs. CLI-flag-driven consensus never got
the doubling.

### Journeys covered (tests/test_consensus_metadata_mode.sh, cases g-j)

| Case | Input | Expected `effective_cb_threshold` | Result |
|---|---|---|---|
| (g) | CLI `--consensus final-only` | 12 | RED: 6 -> GREEN: 12 |
| (h) | CLI `--consensus all` | 12 | RED: 6 -> GREEN: 12 |
| (i) negative | no consensus flags | 6 | PASS in RED and GREEN (unaffected path) |
| (j) legacy/guard | env `CONSENSUS_MODE=all` (pre-parse path) | 12 | PASS in RED and GREEN (guards against regressing the already-working env path) |

### RED output (before fix)

```
  FAIL: (g) CLI --consensus final-only -> effective_cb_threshold doubled to 12 (got '6', expected '12')
  FAIL: (h) CLI --consensus all -> effective_cb_threshold doubled to 12 (got '6', expected '12')
  PASS: (i) no consensus flags -> effective_cb_threshold unchanged at 6
  PASS: (j) env CONSENSUS_MODE=all (pre-parse) -> effective_cb_threshold doubled to 12

=== RESULTS: 8 passed, 2 failed ===
```

Regression at RED: `tests/test_us002_consensus_stability.sh` 25/25 (its
AC4-happy is a static pattern match on `CONSENSUS_MODE" != "off"` followed
by `CB_THRESHOLD * 2` within 2 lines -- unaffected by the runtime ordering
bug since the pattern exists in the file regardless of *when* it executes).

Commit: `e79b014` -- `test: reproducer for EFFECTIVE_CB_THRESHOLD ignoring CLI-driven consensus modes`

### Fix (single authoritative computation site, relocated not duplicated)

```diff
 CB_THRESHOLD="${CB_THRESHOLD:-6}"
 _validate_int_knob CB_THRESHOLD 6 1
-# Effective CB threshold: doubled when consensus mode active
-if [[ "$CONSENSUS_MODE" != "off" ]]; then
-  EFFECTIVE_CB_THRESHOLD=$(( CB_THRESHOLD * 2 ))
-else
-  EFFECTIVE_CB_THRESHOLD=$CB_THRESHOLD
-fi
+# (computation moved below, after CLI arg parsing resolves CONSENSUS_MODE)

 ... [CLI arg-parsing loop: --consensus / --final-consensus / --verify-consensus] ...
 unset _cli_i _cli_parsed _cli_rest
+
+if [[ "$CONSENSUS_MODE" != "off" ]]; then
+  EFFECTIVE_CB_THRESHOLD=$(( CB_THRESHOLD * 2 ))
+else
+  EFFECTIVE_CB_THRESHOLD=$CB_THRESHOLD
+fi

 # Require tmux ...
```

`CB_THRESHOLD` itself is never reassigned by the CLI-parsing loop (there is
no `--cb-threshold` case in run_ralph_desk.zsh's loop, only in the Node
wrapper `src/node/run.mjs`), so its default/validation stayed at module top;
only the `CONSENSUS_MODE`-dependent doubling decision moved.

`zsh -n src/scripts/run_ralph_desk.zsh` -- syntax OK.

Commit: `c8fdf86` -- `fix: compute EFFECTIVE_CB_THRESHOLD after CLI consensus flags are parsed`

### GREEN output (after fix)

```
  PASS: (g) CLI --consensus final-only -> effective_cb_threshold doubled to 12
  PASS: (h) CLI --consensus all -> effective_cb_threshold doubled to 12
  PASS: (i) no consensus flags -> effective_cb_threshold unchanged at 6
  PASS: (j) env CONSENSUS_MODE=all (pre-parse) -> effective_cb_threshold doubled to 12

=== RESULTS: 10 passed, 0 failed ===
```

### Regression suites (all green after round-2 fix)

| Suite | Result |
|---|---|
| tests/test_consensus_metadata_mode.sh (full file, cases a-j) | 10 passed, 0 failed |
| tests/test_us002_consensus_stability.sh | 25 passed, 0 failed |
| tests/test_us005_final_consensus.sh | 14 passed, 0 failed |
| tests/test_us008_self_verification_e2e.sh | 33 passed, 0 failed |
| tests/test_us003_campaign_report.sh | 48 passed, 0 failed |

### Guarantee table additions (round 2)

| Guarantee | Enforced by |
|---|---|
| `EFFECTIVE_CB_THRESHOLD` is doubled whenever `CONSENSUS_MODE` is active, regardless of activation path (CLI flag, legacy CLI flag, or env var) | test (g), (h), (j) |
| `EFFECTIVE_CB_THRESHOLD` stays at base `CB_THRESHOLD` when consensus is off | test (i) |
| Single computation site for the doubling formula (no drift risk between two copies) | code review of the diff -- only one `if/else` block exists post-fix |
| No regression to D-22's consensus round-cap contract or CB session-config fields (US-002) | tests/test_us002_consensus_stability.sh (25/25) |
