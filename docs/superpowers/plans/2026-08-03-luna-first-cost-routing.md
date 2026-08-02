# Luna-First Cost Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rlp-desk luna-first by default (cheap-model-first worker routing with evidence-gated escalation), add a cost/speed lane decision at brainstorm time, tier the verifier/consensus models by complexity, scale iteration timeouts by reasoning effort, and report per-campaign sol-equivalent cost.

**Architecture:** The model ladder is pure data (`src/node/models.json`) consumed by two schema-unchanged loaders (zsh `get_next_model()`, Node `loadModelLadder()`). Brainstorm-time recommendation and report generation are LLM-interpreted prompt text (`src/commands/rlp-desk.md`); doctrine lives in `src/governance.md`. Only the effort-aware timeout touches executable leader code (both leaders).

**Tech Stack:** JSON ladder data, zsh (tmux leader), Node 16 ESM (`node --test`), markdown prompt/governance files.

**Spec:** `docs/superpowers/specs/2026-08-03-luna-first-cost-routing-design.md` (read it first — §4.1 table and §5 chains are the source of truth for every value below).

## Global Constraints

- Branch: all commits on `feature/luna-first-cost-routing`. NEVER commit to main. NEVER push / publish / merge without explicit owner approval.
- Project CLAUDE.md gates apply: changes to `src/commands/rlp-desk.md` / `src/governance.md` / `src/scripts/*` require the 3-scenario Self-Verification Gate (Task 9) before the branch is declared done.
- Model values (verbatim, from spec §4.1): Worker cost-lane LOW `gpt-5.6-luna:high` / MEDIUM `gpt-5.6-luna:xhigh` / HIGH `gpt-5.6-luna:max` / CRITICAL `gpt-5.6-sol:high`; speed-lane HIGH `gpt-5.6-sol:medium` (others same). Per-US Verifier `claude-sonnet-5:high` / `claude-opus-5:low` / `claude-opus-5:high` / `claude-opus-5:max`. Per-US Consensus `gpt-5.6-luna:max` / `gpt-5.6-terra:high` / `gpt-5.6-sol:medium` / `gpt-5.6-sol:high`. Final Verifier `claude-fable-5:max` (unchanged). Final Consensus `gpt-5.6-sol:xhigh` (raised from `sol:high`).
- Ladder chain (spec §5): `luna:high→luna:max`, `luna:xhigh→luna:max`, `luna:max→terra:max`, `terra:max→sol:xhigh`. Everything else in models.json unchanged.
- Timeout multipliers (spec §6): worker effort `:xhigh` ×1.5, `:max` ×2.0, else ×1.0. Worker role only.
- Cost factors (spec §7): sol 1.0 / terra 0.4 / luna 0.04, codex legs only.
- Test commands: `npm run test:node` (Node), `npm run test:zsh` (shell sweep over `tests/test_*.sh`), `zsh tests/sv-large-campaign/test-model-upgrade-ladder.zsh` (manual ladder harness, NOT in the sweep — run it explicitly).
- `tests/sv-large-campaign/test-model-upgrade-ladder.zsh` sources `lib_ralph_desk.zsh` via a hardcoded `sed -n '128,287p'` range. Any lib edit must NOT shift lines 128-287 (insert new functions AFTER `check_model_upgrade`, i.e. after line ~370).

---

### Task 1: Ladder data — luna-first chain in models.json

**Files:**
- Modify: `src/node/models.json` (lines 36-38 area: luna/terra entries)
- Test: `tests/node/models-ladder.test.mjs`
- Test: `tests/sv-large-campaign/test-model-upgrade-ladder.zsh`

**Interfaces:**
- Consumes: `loadModelLadder({overrideFile, shippedFile})`, `CEILING_SENTINEL` from `src/node/model-ladder.mjs`; `nextWorkerModel(model, fails)` from `src/node/runner/campaign-main-loop.mjs`; zsh `get_next_model <model:effort>` (echoes next or empty).
- Produces: ladder keys consumed by both leaders at runtime; Task 2/3/4 document these exact chains.

- [ ] **Step 1: Update existing Node ladder assertions (RED)**

Open `tests/node/models-ladder.test.mjs`. Find every assertion on `gpt-5.6-luna` and `gpt-5.6-terra:max` keys (the file has a GPT-5.6-family test block referencing the 2026-07-20 xhigh-ceiling policy). Update the old expectations (`luna:high→luna:xhigh`, `luna:xhigh→terra:high`, `luna:max→CEILING`, `terra:max→CEILING`) to the new chain, and add this test block at the end of the GPT-5.6 section:

```js
// 2026-08-03 luna-first policy (docs/superpowers/specs/2026-08-03-luna-first-cost-routing-design.md):
// within luna, effort climbs before the model jumps (high skips xhigh -> max);
// luna:max hops to the quota-first terra:max lane; terra:max escapes to sol:xhigh
// (terra:max quality sits between sol:high and sol:xhigh, so sol:high would be lateral).
// Partial reversal of 32d181a for luna only — sol/terra keep the xhigh ladder ceiling.
test('luna-first ladder: effort-before-model within luna, quota-first terra:max hop', () => {
  const ladder = loadModelLadder({ overrideFile: NONEXISTENT, shippedFile: realShippedFile });
  assert.equal(ladder['gpt-5.6-luna:high'], 'gpt-5.6-luna:max');
  assert.equal(ladder['gpt-5.6-luna:xhigh'], 'gpt-5.6-luna:max');
  assert.equal(ladder['gpt-5.6-luna:max'], 'gpt-5.6-terra:max');
  assert.equal(ladder['gpt-5.6-terra:max'], 'gpt-5.6-sol:xhigh');
  // unchanged guards
  assert.equal(ladder['gpt-5.6-luna:medium'], 'gpt-5.6-luna:high');
  assert.equal(ladder['gpt-5.6-terra:xhigh'], 'gpt-5.6-sol:high');
  assert.equal(ladder['gpt-5.6-sol:xhigh'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-sol:max'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-sol:ultra'], CEILING_SENTINEL);
  assert.equal(ladder['gpt-5.6-terra:ultra'], CEILING_SENTINEL);
});

test('nextWorkerModel walks the cost-lane chain to the sol:xhigh ceiling', () => {
  assert.equal(nextWorkerModel('gpt-5.6-luna:high', 3), 'gpt-5.6-luna:max');
  assert.equal(nextWorkerModel('gpt-5.6-luna:max', 3), 'gpt-5.6-terra:max');
  assert.equal(nextWorkerModel('gpt-5.6-terra:max', 3), 'gpt-5.6-sol:xhigh');
  assert.equal(nextWorkerModel('gpt-5.6-sol:xhigh', 3), 'BLOCKED');
});
```

- [ ] **Step 2: Run Node tests to verify they fail**

Run: `npm run test:node`
Expected: FAIL — new/updated assertions report old ladder values (e.g. `'gpt-5.6-luna:xhigh'` still `'gpt-5.6-terra:high'`).

- [ ] **Step 3: Edit models.json**

In `src/node/models.json` change exactly these four values (keys stay):

```json
    "gpt-5.6-terra:max": "gpt-5.6-sol:xhigh",
```
```json
    "gpt-5.6-luna:high": "gpt-5.6-luna:max",
    "gpt-5.6-luna:xhigh": "gpt-5.6-luna:max",
    "gpt-5.6-luna:max": "gpt-5.6-terra:max"
```

(Old values for reference: `terra:max` was `""`; `luna:high` was `gpt-5.6-luna:xhigh`; `luna:xhigh` was `gpt-5.6-terra:high`; `luna:max` was `""`.) Do NOT touch `terra:ultra`, `sol:max`, `sol:ultra` (stay `""`), nor any sol/terra/spark/5.4/5.5 progression.

- [ ] **Step 4: Run Node tests to verify they pass**

Run: `npm run test:node`
Expected: PASS (all tests, including untouched schema/hermeticity tests).

- [ ] **Step 5: Update the zsh ladder harness assertions**

In `tests/sv-large-campaign/test-model-upgrade-ladder.zsh`, find the GPT-5.6 luna/terra `get_next_model` assertions and replace with:

```zsh
[[ "$(get_next_model gpt-5.6-luna:high)" == gpt-5.6-luna:max \
   && "$(get_next_model gpt-5.6-luna:xhigh)" == gpt-5.6-luna:max \
   && "$(get_next_model gpt-5.6-luna:max)" == gpt-5.6-terra:max \
   && "$(get_next_model gpt-5.6-terra:max)" == gpt-5.6-sol:xhigh ]] \
  && ok "luna-first chain: luna:high→luna:max→terra:max→sol:xhigh" || no "luna-first chain wrong"
[[ "$(get_next_model gpt-5.6-terra:xhigh)" == gpt-5.6-sol:high && -z "$(get_next_model gpt-5.6-sol:xhigh)" ]] \
  && ok "terra:xhigh→sol:high jump and sol:xhigh ceiling unchanged" || no "unchanged entries regressed"
```

If the file asserts the OLD values elsewhere (grep `luna` in the file), update those lines to match; do not delete unrelated assertions.

- [ ] **Step 6: Run the zsh harness**

Run: `zsh tests/sv-large-campaign/test-model-upgrade-ladder.zsh`
Expected: all PASS lines, `FAIL=0`. (This harness is not in `npm run test:zsh` — must be run explicitly.)

- [ ] **Step 7: Run the automated zsh sweep (regression)**

Run: `npm run test:zsh`
Expected: PASS — `tests/test_us011_worker_model_upgrade.sh` is source-pattern based and unaffected by data changes.

- [ ] **Step 8: Commit**

```bash
git add src/node/models.json tests/node/models-ladder.test.mjs tests/sv-large-campaign/test-model-upgrade-ladder.zsh
git commit -m "feat!: luna-first worker ladder — effort-before-model + terra:max quota lane (partial 32d181a reversal, luna only)"
```

---

### Task 2: zsh leader — effort-aware iteration timeout

**Files:**
- Modify: `src/scripts/lib_ralph_desk.zsh` (insert helper AFTER `check_model_upgrade`, i.e. after line ~370 — MUST NOT shift lines 128-287, see Global Constraints)
- Modify: `src/scripts/run_ralph_desk.zsh` (poll function, timeout check at lines ~3494-3511)
- Create: `tests/test_effort_timeout.sh`

**Interfaces:**
- Consumes: globals `ITER_TIMEOUT`, `WORKER_ENGINE`, `WORKER_MODEL`, `WORKER_CODEX_MODEL`, `WORKER_CODEX_REASONING`; existing `get_model_string <engine> <model> <reasoning>` (lib, lines 128-287 region).
- Produces: `_effective_iter_timeout <role>` — echoes integer seconds; consumed only by the shared poll function in this task.

- [ ] **Step 1: Write the failing test**

Create `tests/test_effort_timeout.sh` (bash, matching `test_us011` grep style):

```bash
#!/usr/bin/env bash
# Test suite: effort-aware ITER_TIMEOUT multiplier (luna-first spec §6)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="${LIB:-$REPO_ROOT/src/scripts/lib_ralph_desk.zsh}"
RUN="${RUN:-$REPO_ROOT/src/scripts/run_ralph_desk.zsh}"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

# T1: helper exists in lib
grep -qF '_effective_iter_timeout()' "$LIB" \
  && pass "T1: _effective_iter_timeout() exists in lib" \
  || fail "T1: _effective_iter_timeout() missing"

# T2: max multiplier is x2
grep -q 'ITER_TIMEOUT \* 2' "$LIB" \
  && pass "T2: :max multiplier x2 present" || fail "T2: :max multiplier missing"

# T3: xhigh multiplier is x1.5 (integer math 3/2)
grep -q 'ITER_TIMEOUT \* 3 / 2' "$LIB" \
  && pass "T3: :xhigh multiplier x1.5 present" || fail "T3: :xhigh multiplier missing"

# T4: non-worker role passes base through
awk '/_effective_iter_timeout\(\)/,/^}/' "$LIB" | grep -q 'worker' \
  && pass "T4: helper is role-aware (worker-only scaling)" \
  || fail "T4: helper not role-aware"

# T5: the poll loop consumes the helper (not raw ITER_TIMEOUT) for its budget check
grep -q '_effective_iter_timeout' "$RUN" \
  && pass "T5: run_ralph_desk.zsh consumes _effective_iter_timeout" \
  || fail "T5: poll loop still uses raw ITER_TIMEOUT only"

# T6: functional — helper computes 1200/900/600 from a 600 base
_fn_out=$(zsh -fc '
  ITER_TIMEOUT=600
  get_model_string() { if [[ "$1" == codex ]]; then echo "$2:$3"; else echo "$2"; fi }
  source <(awk "/_effective_iter_timeout\(\)/,/^}/" '"$LIB"')
  WORKER_ENGINE=codex WORKER_CODEX_MODEL=gpt-5.6-luna WORKER_CODEX_REASONING=max WORKER_MODEL=gpt-5.6-luna
  echo -n "$(_effective_iter_timeout worker),"
  WORKER_CODEX_REASONING=xhigh
  echo -n "$(_effective_iter_timeout worker),"
  WORKER_CODEX_REASONING=high
  echo -n "$(_effective_iter_timeout worker),"
  WORKER_CODEX_REASONING=max
  echo -n "$(_effective_iter_timeout verifier)"
' 2>/dev/null)
[[ "$_fn_out" == "1200,900,600,600" ]] \
  && pass "T6: functional 600s -> max=1200 xhigh=900 high=600 verifier=600" \
  || fail "T6: functional output was '$_fn_out' (want 1200,900,600,600)"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_effort_timeout.sh`
Expected: FAIL on T1-T6 (helper does not exist yet).

- [ ] **Step 3: Add the helper to lib_ralph_desk.zsh**

Insert immediately AFTER the closing `}` of `check_model_upgrade()` (starts at line ~317; do not insert anywhere in 128-287):

```zsh
# Effort-aware task budget (2026-08-03 luna-first spec §6). Slow reasoning
# efforts (:xhigh, :max) get a longer per-iteration budget so cheap-but-slow
# models don't convert their savings into timeout-retry costs. Worker role
# only — verifier/consensus keep the base ITER_TIMEOUT. Applies on top of a
# user-supplied ITER_TIMEOUT too (documented in rlp-desk.md flag reference).
# Recomputed per poll from the CURRENT (possibly ladder-escalated) model.
_effective_iter_timeout() {
  local role="$1"
  if [[ "$role" != "worker" ]]; then
    echo "$ITER_TIMEOUT"
    return 0
  fi
  local model_str
  model_str=$(get_model_string "$WORKER_ENGINE" "${WORKER_CODEX_MODEL:-$WORKER_MODEL}" "${WORKER_CODEX_REASONING:-}")
  case "$model_str" in
    *:max)   echo $(( ITER_TIMEOUT * 2 )) ;;
    *:xhigh) echo $(( ITER_TIMEOUT * 3 / 2 )) ;;
    *)       echo "$ITER_TIMEOUT" ;;
  esac
}
```

- [ ] **Step 4: Consume it in the poll loop**

In `src/scripts/run_ralph_desk.zsh`, in the shared poll function (the one containing `_pfs_first_progress_ts`, timeout check at ~line 3507-3511): right after `poll_start=$(date +%s)` add:

```zsh
  local _pfs_iter_timeout
  _pfs_iter_timeout=$(_effective_iter_timeout "$role")
```

and change the budget check + log line from:

```zsh
    if (( _pfs_first_progress_ts > 0 )); then
      if (( now - _pfs_first_progress_ts >= ITER_TIMEOUT )); then
        log_error "$role timed out after ${ITER_TIMEOUT}s of task time (submit-anchored) for iteration $ITERATION"
```

to:

```zsh
    if (( _pfs_first_progress_ts > 0 )); then
      if (( now - _pfs_first_progress_ts >= _pfs_iter_timeout )); then
        log_error "$role timed out after ${_pfs_iter_timeout}s of task time (submit-anchored, effort-aware) for iteration $ITERATION"
```

Scope guard: do NOT touch the codex-verifier path (~4037-4095), the parallel-consensus checks (~4525-4682), the capacity-stall bound (~3681), or the unenforced `HARD_CEILING` (~5225) — those stay on base `ITER_TIMEOUT` by design (spec §6: worker only).

- [ ] **Step 5: Run the new test to verify it passes**

Run: `bash tests/test_effort_timeout.sh`
Expected: PASS ×6, `FAIL=0`.

- [ ] **Step 6: Verify the lib line-range invariant + regressions**

Run: `sed -n '128,287p' src/scripts/lib_ralph_desk.zsh | grep -c 'get_next_model\|check_model_upgrade\|get_model_string\|record_us_failure'`
Expected: same count as on main (the four ladder functions still fully inside 128-287; if not, the helper was inserted too early — move it after `check_model_upgrade`).
Run: `zsh tests/sv-large-campaign/test-model-upgrade-ladder.zsh && npm run test:zsh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/scripts/lib_ralph_desk.zsh src/scripts/run_ralph_desk.zsh tests/test_effort_timeout.sh
git commit -m "feat: effort-aware iteration timeout (x1.5 xhigh / x2 max, worker-only) — zsh leader"
```

---

### Task 3: Node leader — effort-aware iteration timeout

**Files:**
- Modify: `src/node/runner/campaign-main-loop.mjs` (helper near `nextWorkerModel` at line ~478; consumption at the `iterTimeoutMs` computation, lines 1689-1693, and its worker-poll call sites among lines 1420/1979/2022/2167/2445)
- Create: `tests/node/effort-timeout.test.mjs`

**Interfaces:**
- Consumes: `state.worker_model` (campaign state, set at line ~549), `options.iterTimeout`.
- Produces: `export function effectiveIterTimeoutMs(baseMs, workerModel)` — pure function, unit-testable.

- [ ] **Step 1: Write the failing test**

Create `tests/node/effort-timeout.test.mjs`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Hermeticity: campaign-main-loop.mjs loads the model ladder at import time
// from the ambient override path — force a nonexistent override BEFORE the
// dynamic import (same guard as models-ladder.test.mjs).
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
process.env.RLP_DESK_MODELS_FILE = path.join(repoRoot, '.tmp', 'effort-timeout-test', 'no-override.json');
const { effectiveIterTimeoutMs } = await import('../../src/node/runner/campaign-main-loop.mjs');

test('effort-aware timeout: x2 for :max, x1.5 for :xhigh, base otherwise', () => {
  assert.equal(effectiveIterTimeoutMs(600_000, 'gpt-5.6-luna:max'), 1_200_000);
  assert.equal(effectiveIterTimeoutMs(600_000, 'gpt-5.6-terra:max'), 1_200_000);
  assert.equal(effectiveIterTimeoutMs(600_000, 'gpt-5.6-luna:xhigh'), 900_000);
  assert.equal(effectiveIterTimeoutMs(600_000, 'gpt-5.6-sol:high'), 600_000);
  assert.equal(effectiveIterTimeoutMs(600_000, 'haiku'), 600_000);
  assert.equal(effectiveIterTimeoutMs(600_000, undefined), 600_000);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:node`
Expected: FAIL — `effectiveIterTimeoutMs` is not exported.

- [ ] **Step 3: Implement the helper**

In `src/node/runner/campaign-main-loop.mjs`, directly below `nextWorkerModel()` (ends line ~495), add:

```js
// Effort-aware task budget (2026-08-03 luna-first spec §6): slow reasoning
// efforts get a longer per-iteration budget. Worker polls only — verifier
// waits keep the base timeout.
export function effectiveIterTimeoutMs(baseMs, workerModel) {
  const model = workerModel ?? '';
  if (model.endsWith(':max')) return baseMs * 2;
  if (model.endsWith(':xhigh')) return Math.floor(baseMs * 1.5);
  return baseMs;
}
```

- [ ] **Step 4: Apply it at worker-poll call sites**

Inspect the five `timeoutMs: iterTimeoutMs` call sites (lines ~1420, 1979, 2022, 2167, 2445). Classification criterion: a site is a WORKER site iff the poll it configures waits on the worker's done-claim/completion signal (look at the poll target/trigger file name in the surrounding ~15 lines — `done-claim` / worker signal = worker; `verify-verdict` / verifier or consensus signal = verifier). For each worker site, replace `iterTimeoutMs` with `effectiveIterTimeoutMs(iterTimeoutMs, state.worker_model)`; leave verifier/consensus sites untouched. Record which lines were classified as worker sites in the commit message body.

- [ ] **Step 5: Run tests to verify pass + no regression**

Run: `npm run test:node`
Expected: PASS (new test + all existing, incl. the hermeticity-guarded ladder tests).

- [ ] **Step 6: Commit**

```bash
git add src/node/runner/campaign-main-loop.mjs tests/node/effort-timeout.test.mjs
git commit -m "feat: effort-aware iteration timeout — Node leader (worker poll sites: <lines>)"
```

---

### Task 4: zsh leader — environment failures don't climb the ladder

**Files:**
- Modify: `src/scripts/run_ralph_desk.zsh` (the call site(s) of `check_model_upgrade`)
- Modify: `tests/test_effort_timeout.sh` → no; Test: extend `tests/test_us011_worker_model_upgrade.sh`

**Interfaces:**
- Consumes: `check_model_upgrade <us-id>` (lib line ~317); the fail-verdict handling path that invokes it; latest `verify-verdict.json` (contains `failure_category` per governance).
- Produces: escalation guard — `failure_category` ∈ {`environment`} (and existing `flaky`) never counts toward the same-US fail threshold.

- [ ] **Step 1: Locate the call site**

Run: `grep -n 'check_model_upgrade' src/scripts/run_ralph_desk.zsh src/scripts/lib_ralph_desk.zsh`
Expected: the definition (lib ~317) plus 1-2 invocation sites in the fail-verdict path of run_ralph_desk.zsh. Note the invocation line and the variable holding the current verdict file path in that scope (read the surrounding ~30 lines).

- [ ] **Step 2: Write the failing test**

Append to `tests/test_us011_worker_model_upgrade.sh` (before the final summary/exit lines, following its `test_*` function + call convention — register the new function wherever the other `test_ac*` functions are invoked):

```bash
# AC6: environment/flaky failure_category must not feed the upgrade ladder
test_ac6_environment_guard() {
  local ctx
  ctx=$(grep -n -B2 -A6 'check_model_upgrade ' "$RUN" 2>/dev/null | grep -v 'check_model_upgrade()')
  if echo "$ctx" | grep -q 'failure_category'; then
    pass "AC6: check_model_upgrade call is guarded by failure_category"
  else
    fail "AC6: no failure_category guard around check_model_upgrade invocation"
  fi
  if echo "$ctx" | grep -qE 'environment'; then
    pass "AC6b: guard covers 'environment' category"
  else
    fail "AC6b: 'environment' category not handled"
  fi
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/test_us011_worker_model_upgrade.sh`
Expected: AC6/AC6b FAIL, all pre-existing ACs PASS.

- [ ] **Step 4: Implement the guard**

At the invocation site found in Step 1, wrap the call (adapt the verdict-path variable name to the local scope; if the verdict file variable is absent in that scope, derive it the same way the surrounding code reads the verdict):

```zsh
    # Luna-first spec §2.5: environment/harness failures (incl. verifier
    # safety-classifier refusals, capacity stalls) and flaky failures never
    # climb the model ladder — recover the environment, retry the SAME model.
    local _fail_cat=""
    if [[ -f "$verdict_file" ]]; then
      _fail_cat=$(jq -r '(.failure_category // (.checks // [] | map(.failure_category // empty) | first // ""))' "$verdict_file" 2>/dev/null)
    fi
    if [[ "$_fail_cat" == "environment" || "$_fail_cat" == "flaky" ]]; then
      log_debug "[DECIDE] iter=${ITERATION:-0} phase=model_select model_upgrade=false reason=failure_category_${_fail_cat}"
    else
      check_model_upgrade "$current_us"
    fi
```

(If verdict parsing fails or the field is absent, `_fail_cat` is empty → falls through to `check_model_upgrade` — behavior identical to today.)

- [ ] **Step 5: Run tests to verify pass**

Run: `bash tests/test_us011_worker_model_upgrade.sh && npm run test:zsh`
Expected: PASS including AC6/AC6b.

- [ ] **Step 6: Commit**

```bash
git add src/scripts/run_ralph_desk.zsh tests/test_us011_worker_model_upgrade.sh
git commit -m "feat: environment/flaky failure_category bypasses model-ladder escalation (zsh leader)"
```

---

### Task 5: governance.md — doctrine, routing tables, environment category

**Files:**
- Modify: `src/governance.md` — §1c line 160, §4 (lines 587-616), failure_category (lines 260-265), Consensus Model Routing (lines 940-950)

**Interfaces:**
- Consumes: spec §2 (doctrine items 1-5), §4.1/§4.2 (tables).
- Produces: doctrine text that Task 6 (rlp-desk.md) references; the `environment` failure_category consumed by Task 4's guard.

- [ ] **Step 1: Replace the §1c doctrine line**

Replace line 160:

```
- Leader model selection: choose a model that can succeed comfortably, not the minimum viable model.
```

with:

```
- Leader model selection is luna-first: start at the cheapest model:effort the complexity allows and escalate ONLY on observed failure — the ladder supplies the comfort margin, so a conservative start just pays the top-tier premium on every iteration. Exception: CRITICAL US (security/payment/auth/data-loss) never start below sol:high, and judging roles (Verifier/Consensus) never downshift below their complexity tier (§4).
```

- [ ] **Step 2: Rewrite §4 Model Routing**

Replace lines 589-616 (from `### Claude (default engine)` through the `parse_model_flag()` paragraph) with:

```markdown
### Doctrine (2026-08-03 luna-first)

1. **Luna-first start**: workers start at the cheapest model:effort the US
   complexity allows (see mapping in rlp-desk.md Step 7). Escalation requires
   an observed failure — never an assumption of difficulty.
2. **Effort before model (luna only)**: within luna the ladder raises effort
   to `max` before jumping models. Terra/sol keep the `xhigh` ladder ceiling.
3. **Lanes**: campaigns with HIGH US choose at brainstorm time between the
   long-term/cost lane (HIGH starts `gpt-5.6-luna:max`; escalation passes the
   quota-first `terra:max` hop) and the speed lane (HIGH starts
   `gpt-5.6-sol:medium`; no terra hop). CRITICAL rows and all judging roles
   are lane-independent.
4. **Judging roles never downshift below evidence**: verifier/consensus tiers
   scale with complexity (judgment-task benchmarks show large tier gaps,
   unlike coding aggregates) and are campaign-fixed — no progressive upgrade.
5. **Environment failures don't climb the ladder**: `failure_category` of
   `environment` or `flaky` never counts toward model escalation. This
   includes verifier safety-classifier refusals (opus-5/fable-5 cyber
   safeguards can false-positive on benign security US) — a refusal is an
   environment failure, never a verdict.

### Claude (default engine, codex not installed)

| Role | Default Model | Override Criteria |
|------|---------------|-------------------|
| Worker | haiku | Default; auto-upgrades on failure (sonnet → opus) |
| Worker (locked) | haiku | `--lock-worker-model` disables auto-upgrade |
| Verifier (per-US) | sonnet | Lightweight; campaign-fixed (no progressive upgrade) |
| Verifier (final) | opus | Full rigor; independent of per-US model |

**Worker auto-upgrade**: When a Worker fails (failure_category `spec`/`implementation`/`integration`), the Leader upgrades the model for the retry. Worker-only; verifier models are campaign-fixed.

The Leader decides each iteration. Decision criteria:
- Previous iteration failed with an escalation-eligible failure_category → upgrade Worker model (unless `--lock-worker-model`)
- failure_category `environment`/`flaky` → same model, recover environment / retry
- Simple repetitive task → keep current Worker model
- User explicitly specified → use as given

### Codex (recommended worker engine when installed)

Worker ladder chain (data: `src/node/models.json`; reference view:
`src/model-upgrade-table.md`):

```
Cost lane:  luna:high → luna:max → terra:max → sol:xhigh (ceiling)
            (MEDIUM joins at luna:xhigh → luna:max → …)
Speed lane: sol:medium → sol:high → sol:xhigh (ceiling)
```

`--worker-model spark:high` / `gpt-5.6-luna:max` format; `parse_model_flag()`
auto-detects engine: plain names (haiku, sonnet, opus) = claude;
`name:reasoning` = codex unless the name is a claude alias/`claude-*` id.
```

- [ ] **Step 3: Add the `environment` failure_category**

In the failure_category bullet list (lines 260-265), after the `flaky` line, add:

```
  - `environment` — harness/tooling/capacity failure unrelated to model capability: model-capacity stall, terminal/tool error, context-ceiling truncation, or a verifier safety-classifier refusal. NEVER triggers model upgrade — Leader recovers the environment and retries the SAME model.
```

- [ ] **Step 4: Update the Consensus Model Routing table**

Replace lines 942-950 table+notes with:

```markdown
| Scenario | Primary verifier | Cross verifier |
|----------|-----------------|----------------|
| per-US, primary=claude | `--verifier-model` (complexity-tiered: sonnet-5:high / opus-5:low / opus-5:high / opus-5:max) | `--consensus-model` (complexity-tiered: gpt-5.6-luna:max / gpt-5.6-terra:high / gpt-5.6-sol:medium / gpt-5.6-sol:high) |
| per-US, primary=codex | `--verifier-model` | claude opus (fixed) |
| final, primary=claude | `--final-verifier-model` (claude-fable-5:max) | `--final-consensus-model` (gpt-5.6-sol:xhigh) |
| final, primary=codex | `--final-verifier-model` | claude opus (fixed) |

- Both must pass. No engine priority.
- The complexity tier (LOW/MEDIUM/HIGH/CRITICAL) is chosen once at brainstorm
  time (rlp-desk.md Step 7) and baked into the run command flags —
  campaign-fixed thereafter.
- spark is not allowed as a consensus cross verifier (100k output limit).
- Evidence basis for tiering: judgment tasks show large model-tier gaps
  (Internal Research Debugging sol 68.3 / terra 67.8 / luna 50.8; CodeRabbit
  review sol 69.7% vs terra 52.5%) — see the 2026-08-03 spec appendix.
```

- [ ] **Step 5: Sanity check + commit**

Run: `grep -n "succeed comfortably" src/governance.md` → expected: no matches.
Run: `grep -c "environment" src/governance.md` → expected: ≥2.

```bash
git add src/governance.md
git commit -m "docs(governance): luna-first doctrine, lane concept, tiered judging tables, environment failure_category"
```

---

### Task 6: rlp-desk.md — brainstorm mapping, lane question, flags, cost summary

**Files:**
- Modify: `src/commands/rlp-desk.md` — Step 7 tables (lines ~57-95), `③ Decide model` (lines 480-484), flag reference (lines 288-311 PLUS the 3 condensed duplicates at ~221-227, ~260-263, ~847-853), `⑩ Campaign Report` item 6 (line 716)

**Interfaces:**
- Consumes: spec §3 (lane question verbatim), §4.1 table, §7 cost factors; governance doctrine from Task 5.
- Produces: the prompt text the LLM leader executes — no code consumes this.

- [ ] **Step 1: Replace the two model-mapping tables**

Replace the Claude-only table (verifier columns modernized; workers unchanged — already cheapest-first):

```markdown
   **Model mapping — Claude-only** (codex not installed):

   | Complexity | Worker | per-US Verifier | Final Verifier | Consensus |
   |------------|--------|-----------------|----------------|-----------|
   | LOW | haiku | claude-sonnet-5:high | claude-fable-5:max | off |
   | MEDIUM | sonnet | claude-opus-5:low | claude-fable-5:max | off |
   | HIGH | opus | claude-opus-5:high | claude-fable-5:max | off |
   | CRITICAL | opus | claude-opus-5:max | claude-fable-5:max + human | off |
```

Replace the Cross-engine table:

```markdown
   **Model mapping — Cross-engine** (codex installed, recommended; luna-first
   per governance §4 — workers start cheap, ladder escalates on observed
   failure only):

   | Complexity | Worker (cost lane) | Worker (speed lane) | per-US Verifier | Final Verifier | Consensus (per-US leg) |
   |------------|--------------------|---------------------|-----------------|----------------|------------------------|
   | LOW | gpt-5.6-luna:high | gpt-5.6-luna:high | claude-sonnet-5:high | claude-fable-5:max | gpt-5.6-luna:max (final-only) |
   | MEDIUM | gpt-5.6-luna:xhigh | gpt-5.6-luna:xhigh | claude-opus-5:low | claude-fable-5:max | gpt-5.6-terra:high (final-only) |
   | HIGH | gpt-5.6-luna:max | gpt-5.6-sol:medium | claude-opus-5:high | claude-fable-5:max | gpt-5.6-sol:medium (all) |
   | CRITICAL | gpt-5.6-sol:high | gpt-5.6-sol:high | claude-opus-5:max | claude-fable-5:max + human | gpt-5.6-sol:high (all) |

   Final Consensus (all complexities): `gpt-5.6-sol:xhigh`.

   **Lane question** — if any US is HIGH or above, ask the user ONCE (and log
   `[DECIDE] phase=lane lane=<cost|speed> reason=<answer>`); no question when
   all US are LOW/MEDIUM (lanes are identical there), none for CRITICAL rows
   (lane-independent):

   > This campaign contains HIGH-complexity US. Execution profile?
   > - **Long-term / cost lane (recommended for unattended/overnight
   >   campaigns)**: sol-grade quality is absorbed by terra:max; minimizes
   >   Sol usage; iterations may be slower.
   > - **Speed lane**: HIGH US go straight to sol; no terra hop.
```

Then update the worker/verifier selection prose right below (lines ~89-95): replace the "terra:medium is the default recommendation (balanced)" rationale with luna-first rationale (luna:high ≈ old terra:medium quality at 1/10 cost per the 2026-07-30 price cut; escalation is automatic on failure; CRITICAL exempt).

- [ ] **Step 2: Extend `③ Decide model`**

Replace lines 480-484 with:

```markdown
**③ Decide model** (§4 of governance.md — luna-first)
- Previous iteration failed with failure_category spec/implementation/integration → upgrade model
- failure_category environment/flaky (incl. verifier refusal, capacity stall) → SAME model, recover and retry
- Simple task → downgrade
- User specified → use that
- If `--debug`: debug_log `[DECIDE] iter=N phase=model_select worker_model=<model> reason=<reason>`
```

- [ ] **Step 3: Update the flag reference (all 4 locations)**

In the primary block (lines 288-311):
- `--worker-model` (line 290): add to the examples list: `gpt-5.6-luna:max` (cost-lane HIGH start), `gpt-5.6-terra:max` (manual quota-first start — quality ≈ sol:high–xhigh midpoint, slower; escalates to sol:xhigh on failure).
- `--verifier-model` (line 292): change `recommended claude-opus-4-8:high` → `recommended per complexity: claude-sonnet-5:high (LOW) / claude-opus-5:low (MEDIUM) / claude-opus-5:high (HIGH) / claude-opus-5:max (CRITICAL)`.
- `--final-verifier-model` (line 293): keep `claude-fable-5:max` (unchanged).
- `--consensus-model` (line 298): change default text `gpt-5.6-terra:medium` → `gpt-5.6-terra:high`, and append: `Brainstorm recommends per complexity: gpt-5.6-luna:max (LOW) / gpt-5.6-terra:high (MEDIUM) / gpt-5.6-sol:medium (HIGH) / gpt-5.6-sol:high (CRITICAL).`
- `--final-consensus-model` (line 299): change default `gpt-5.6-sol:high` → `gpt-5.6-sol:xhigh`.
- `--iter-timeout` (line 306): append: `Effort-aware: the effective worker budget is ×1.5 for :xhigh and ×2.0 for :max efforts (applies on top of the value you set); verifier/consensus waits use the base value.`

Then grep for the 3 condensed duplicates and apply the same value changes: `sed -n '221,227p;260,263p;847,853p' src/commands/rlp-desk.md` — update any occurrence of `claude-opus-4-8`, `gpt-5.6-terra:medium` (consensus default), `gpt-5.6-sol:high` (final-consensus default) to the new values. Also run `grep -n 'claude-opus-4-8' src/commands/rlp-desk.md` afterwards — expected 0 matches (the `--worker-model` example strings included).

NOTE: if the zsh/Node CLIs hard-code the consensus defaults (`grep -rn 'terra:medium' src/scripts src/node`), update those default constants to `gpt-5.6-terra:high` / `gpt-5.6-sol:xhigh` too, and adjust any test asserting the old defaults.

- [ ] **Step 4: Add the cost summary to ⑩ Campaign Report**

Replace line 716 (`- **Cost & Performance**: Per-iter token/duration data from status.json`) with:

```markdown
   - **Cost & Performance**: Per-iter token/duration data from `status.json`,
     PLUS a sol-equivalent cost summary for codex legs: total = Σ(iteration
     tokens × factor), factors sol 1.0 / terra 0.4 / luna 0.04 (2026-07-30
     API prices). Also report the escalation count (ladder moves) and final
     model reached per US. Claude iterations are listed by count only
     (separate subscription pool — no factor conversion). If per-iter token
     data is missing (tmux estimates), mark the summary "estimated".
```

- [ ] **Step 5: Verify + commit**

Run: `grep -n 'claude-opus-4-8\|terra:medium' src/commands/rlp-desk.md`
Expected: no `claude-opus-4-8`; `terra:medium` only where it legitimately refers to a manual example (expected: 0).

```bash
git add src/commands/rlp-desk.md
git commit -m "docs(command): luna-first mapping tables, lane question, Claude 5 verifier tiers, effort-aware timeout + cost summary"
```

---

### Task 7: model-upgrade-table.md — rewrite reference view

**Files:**
- Modify: `src/model-upgrade-table.md` (policy paragraph lines 49-58; Terra table 73-84; Luna table 86-97)

**Interfaces:**
- Consumes: Task 1's ladder data (this doc must mirror models.json exactly — it documents, never drives).

- [ ] **Step 1: Update the policy paragraph (lines 49-54)**

Replace with:

```markdown
- `max` and `ultra` are effort tiers introduced with the GPT-5.6 family;
  `gpt-5.6-luna` supports `max` but not `ultra`. **Policy 2026-08-03
  (luna-first — partial reversal of the 2026-07-20 xhigh-ceiling policy,
  justified by the 2026-07-30 price cut):** within luna the ladder raises
  effort to `max` before jumping models (`luna:high → luna:max`, skipping
  xhigh in the default chain; `luna:xhigh → luna:max` for manual starts).
  `luna:max` then hops to the quota-first `terra:max` lane, which escalates
  to `sol:xhigh` (terra:max quality sits between sol:high and sol:xhigh —
  sol:high would be lateral). Terra and sol keep the `:xhigh` ladder ceiling;
  `sol:max`/`sol:ultra`/`terra:ultra` remain valid manual starting points but
  are dead-end keys.
```

- [ ] **Step 2: Update the Terra table block (lines 73-84)**

Change the heading to `## GPT-5.6 — Terra (xhigh → Sol:high jump; terra:max → sol:xhigh quota lane)` and append below the existing parenthetical:

```markdown
(`terra:max` is the quota-first lane hop reached from `luna:max`, or a manual
`--worker-model gpt-5.6-terra:max` start; on failure it escalates to
`gpt-5.6-sol:xhigh`.)
```

- [ ] **Step 3: Rewrite the Luna table block (lines 86-97)**

Replace heading + table + parenthetical with:

```markdown
## GPT-5.6 — Luna (effort to max first, then terra:max quota lane)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9+ |
|------------|-----|-----|-----|-----|-----|
| LOW | luna:high | luna:max | terra:max | sol:xhigh | BLOCKED |
| MEDIUM | luna:xhigh | luna:max | terra:max | sol:xhigh | BLOCKED |
| HIGH | luna:max | terra:max | sol:xhigh | sol:xhigh | BLOCKED |
| CRITICAL | sol:high | sol:xhigh | sol:xhigh | sol:xhigh | BLOCKED |

(Cells abbreviate `gpt-5.6-luna` / `gpt-5.6-terra` / `gpt-5.6-sol`. Row =
brainstorm start per complexity (cost lane); columns = consecutive-failure
milestones. Full chain: `luna:high → luna:max → terra:max → sol:xhigh`
(ceiling); manual `luna:low/medium` starts climb `low → medium → high` first;
manual `luna:xhigh` joins at `luna:max`. CRITICAL rows start at `sol:high`
regardless of lane. Speed lane HIGH starts `sol:medium → sol:high →
sol:xhigh`.)
```

- [ ] **Step 4: Cross-check against models.json + commit**

Run: `node -e "const l=require('./src/node/models.json').upgrades; for (const k of ['gpt-5.6-luna:high','gpt-5.6-luna:xhigh','gpt-5.6-luna:max','gpt-5.6-terra:max']) console.log(k,'->',l[k])"`
Expected output matches every chain statement written above.

```bash
git add src/model-upgrade-table.md
git commit -m "docs(ladder): reference tables for luna-first chain + terra:max quota lane"
```

---

### Task 8: CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (under `## [Unreleased]`)

- [ ] **Step 1: Add the entry**

Under `## [Unreleased]` (after the `### Planned` block), add:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for luna-first cost routing"
```

---

### Task 9: Self-Verification Gate (mandatory before declaring done)

Project CLAUDE.md requires 3 self-verification scenarios when
`src/commands/rlp-desk.md` / `src/governance.md` / `src/scripts/*` change.
Run each scenario as a real Worker (with execution_steps) → Verifier (with
reasoning, 5 categories) cycle and record PASS evidence:

- [ ] **Step 1: LOW-risk scenario** — simple function US; L1+L3 only (L2/L4 N/A). Confirm the brainstorm mapping recommends `gpt-5.6-luna:high` worker + `claude-sonnet-5:high` verifier and the campaign completes.
- [ ] **Step 2: MEDIUM-risk scenario** — feature with file I/O; L1+L2+L3 real integration. Confirm `luna:xhigh` start, and force one failure to observe the ladder move `luna:xhigh → luna:max` in the `[DECIDE]` log plus the timeout log showing the ×2.0 budget (1200s) after escalation to `:max`.
- [ ] **Step 3: CRITICAL-risk scenario** — security/crypto US; L1+L2+L3+security, L3 error-path E2E. Confirm `sol:high` start (no lane question effect), `claude-opus-5:max` per-US verifier recommendation, and that a simulated verifier refusal is classified `environment` (no ladder move).
- [ ] **Step 4: Full test suite** — `npm run test:full` → all PASS. Fix-and-rerun on any failure (re-verify all 3 scenarios if a fix touches gated files).
- [ ] **Step 5: Report** — summarize the 3 PASS results + test output in the session; STOP and request owner approval for merge (never merge/push unprompted). After the owner-approved FF merge to main: run `npm install` for local sync and the banner-aware §4.5 verification (Tier-1 ship procedure).
