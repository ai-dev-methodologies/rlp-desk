#!/bin/zsh
# Test suite: DEFECT-1 — fix-contract carryover across a Worker `continue` signal.
#
# Root cause (found by adversarial probe, confirmed by reading the code):
# write_worker_trigger() looked up ONLY
#   $LOGS_DIR/iter-$(printf '%03d' $((iter-1))).fix-contract.md
# When the Worker's prior turn signals `continue` (governance.md s7 step 6 —
# a legitimate signal meaning "not done yet, no verify happened this
# iteration"), NO new fix-contract file is written for that iteration. The
# next dispatch's prev_iter lookup then misses entirely, so real unresolved
# verifier feedback from an earlier failed iteration is silently dropped and
# the same already-failed approach gets re-attempted with zero memory of why
# it failed.
#
# Fix: atomic_write() now records the path of every *.fix-contract.md it
# writes into a global per-US map (US_FIX_CONTRACT), keyed by the same
# in-flight-us_id convention (CURRENT_US) used elsewhere (D-11). write_worker_trigger
# falls back to that map when the direct prev-iter file is missing. main()
# clears a US's entry once that US passes (in-repo, exercised by e2e tests;
# this suite is a focused unit/integration test of the write+read path).
#
# This test EXECUTES the real extracted production functions (atomic_write,
# inject_per_us_prd, write_worker_trigger) — never retypes their logic.

set -uo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found: $RUN"; exit 1; }
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL: $1"; }

echo "=== DEFECT-1: fix-contract carryover across a Worker continue signal ==="

# Extract the real production functions under test, from the REAL sources
# (not retyped). $run_src / $lib_src let a mutation-control run swap in an
# edited copy of run_ralph_desk.zsh without touching the tracked file.
extract_harness() { # $1 = run_src  $2 = lib_src  -> prints harness to stdout
  local run_src="$1" lib_src="$2"
  awk '/^atomic_write\(\) \{/,/^}$/' "$lib_src"
  echo ""
  awk '/^inject_per_us_prd\(\) \{/,/^}$/' "$run_src"
  echo ""
  awk '/^write_worker_trigger\(\) \{/,/^}$/' "$run_src"
}

_HARNESS_TEXT="$(extract_harness "$RUN" "$LIB")"
for fn in atomic_write inject_per_us_prd write_worker_trigger; do
  # NOTE: a live pipe into `grep -q` here would SIGPIPE the upstream awk once
  # grep found an early match in this multi-function concatenation (classic
  # pipefail trap) — compare the already-captured string instead.
  [[ "$_HARNESS_TEXT" == *$'\n'"$fn() {"* || "$_HARNESS_TEXT" == "$fn() {"* ]] \
    && ok "extraction sanity: $fn() found in real source" \
    || { no "extraction sanity: $fn() NOT found in real source — test cannot proceed"; exit 1; }
done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build one isolated campaign fixture (logs dir, memory file, prompt base,
# per-US PRD/test-spec absent so inject_per_us_prd falls back cleanly).
mkfixture() { # $1 = dir
  local d="$1"
  mkdir -p "$d/logs" "$d/plans"
  cat > "$d/memory.md" <<'EOF'
## Stop Status
running

## Next Iteration Contract
Implement US-001.
EOF
  cat > "$d/worker-prompt-base.md" <<'EOF'
# Worker Prompt Base
Read the PRD at __PRD__ and implement it.
EOF
  sed -i '' "s|__PRD__|$d/plans/prd-testslug.md|" "$d/worker-prompt-base.md" 2>/dev/null \
    || sed -i "s|__PRD__|$d/plans/prd-testslug.md|" "$d/worker-prompt-base.md"
  echo "PRD placeholder" > "$d/plans/prd-testslug.md"
}

# Run write_worker_trigger $1=iter against a fixture dir, with the given
# VERIFY_MODE / US_LIST / VERIFIED_US / CURRENT_US(pre-set) / US_FIX_CONTRACT
# state supplied by the caller as already-exported zsh assignments (a string
# of zsh statements, e.g. 'VERIFIED_US="US-001"'). Sources the harness fresh
# each call so global state never leaks between scenarios.
run_dispatch() {
  local run_src="$1" lib_src="$2" d="$3" iter="$4" setup="$5"
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { :; }; log_debug() { :; }
    _lifecycle_clear_lock_mark() { :; }
    build_claude_cmd() { echo 'stub-claude-cmd'; }
    _emit_waiver_contract() { :; }
    _bug8_carryover_file() { echo '/nonexistent/bug8-carry-$RANDOM.md'; }
    typeset -A US_FIX_CONTRACT
    LOGS_DIR='$d/logs'
    MEMORY_FILE='$d/memory.md'
    WORKER_PROMPT_BASE='$d/worker-prompt-base.md'
    DESK='$d'
    SLUG='testslug'
    _PRD_CHANGED=0
    AUTONOMOUS_MODE=0
    WORKER_ENGINE='claude'
    WORKER_MODEL='sonnet'
    WORKER_EFFORT=''
    WORKER_HEARTBEAT='$d/heartbeat.json'
    SIGNAL_FILE='$d/iter-signal.json'
    $(extract_harness "$run_src" "$lib_src")
    $setup
    write_worker_trigger $iter
  " 2>"$d/harness-stderr.log"
}

# --- Scenario A: continue-signal carryover (the defect) -------------------
echo "--- A: fix contract survives an intervening Worker \`continue\` signal ---"
DA="$TMP/a"; mkfixture "$DA"
# iter 3: verifier FAIL wrote a real fix contract for US-001.
mkdir -p "$DA/logs"
cat > "$DA/logs/iter-003.fix-contract.md" <<'EOF'
# Fix Contract (from Verifier iteration 3)
## Issues (from verify-verdict.json)
- [high] AC1: ISSUE-MARKER-DEFECT1 needs a null check
EOF
# Simulate atomic_write() having tracked it (as it now does in production) by
# driving the REAL atomic_write function directly, rather than retyping its
# map-update line. Uses a SEPARATE scratch target (iter-003b) so this probe
# does not clobber the iter-003.fix-contract.md content Scenario A2 checks.
zsh -c "
  _lifecycle_clear_lock_mark() { :; }
  typeset -A US_FIX_CONTRACT
  CURRENT_US='US-001'
  $(awk '/^atomic_write\(\) \{/,/^}$/' "$LIB")
  echo 'tracked-content' | atomic_write '$DA/logs/iter-003b.fix-contract.md'
  print -r -- \"\${US_FIX_CONTRACT[US-001]}\" > '$DA/tracked-path.txt'
"
[[ "$(cat "$DA/tracked-path.txt" 2>/dev/null)" == "$DA/logs/iter-003b.fix-contract.md" ]] \
  && ok "A0: atomic_write() records the fix-contract path under CURRENT_US" \
  || no "A0: atomic_write() did not record the path (got: $(cat "$DA/tracked-path.txt" 2>/dev/null))"

# iter 4: Worker signals `continue` — governance.md s7 step 6 writes NO new
# fix-contract file. (Nothing to do here; iter-004.fix-contract.md must not exist.)
[[ ! -f "$DA/logs/iter-004.fix-contract.md" ]] \
  && ok "A1: iter-004 fix-contract.md correctly absent (continue signal wrote none)" \
  || no "A1: fixture setup bug — iter-004 fix-contract.md should not exist"

# iter 5 dispatch: per-US mode, US-001 still unverified -> next_us=US-001 ->
# CURRENT_US=US-001 -> must recover the iter-003 contract via US_FIX_CONTRACT.
run_dispatch "$RUN" "$LIB" "$DA" 5 '
  VERIFY_MODE="per-us"
  US_LIST="US-001"
  VERIFIED_US=""
  US_FIX_CONTRACT[US-001]="'"$DA"'/logs/iter-003.fix-contract.md"
'
PROMPT5="$DA/logs/iter-005.worker-prompt.md"
if [[ -f "$PROMPT5" ]] && grep -q "ISSUE-MARKER-DEFECT1" "$PROMPT5"; then
  ok "A2: iter-005 worker prompt carries the iter-003 fix contract across the continue gap"
else
  no "A2: iter-005 worker prompt MISSING the carried fix contract (defect reproduces) — stderr: $(cat "$DA/harness-stderr.log" 2>/dev/null | tail -5)"
fi

# --- Scenario B: per-US isolation — a DIFFERENT US must never see it -------
echo "--- B: carried fix contract never crosses a US boundary ---"
DB="$TMP/b"; mkfixture "$DB"
mkdir -p "$DB/logs"
run_dispatch "$RUN" "$LIB" "$DB" 5 '
  VERIFY_MODE="per-us"
  US_LIST="US-001,US-002"
  VERIFIED_US="US-001"
  US_FIX_CONTRACT[US-001]="'"$DA"'/logs/iter-003.fix-contract.md"
'
PROMPTB="$DB/logs/iter-005.worker-prompt.md"
if [[ -f "$PROMPTB" ]] && ! grep -q "ISSUE-MARKER-DEFECT1" "$PROMPTB"; then
  ok "B1: US-002's dispatch does not receive US-001's carried fix contract"
else
  no "B1: cross-US leak — US-002 dispatch saw US-001's fix contract (or prompt missing)"
fi

# --- Scenario C: direct prev-iter file still wins when present (no regression) ---
echo "--- C: an actual prev-iter fix contract is used directly (unchanged behavior) ---"
DC="$TMP/c"; mkfixture "$DC"
mkdir -p "$DC/logs"
cat > "$DC/logs/iter-004.fix-contract.md" <<'EOF'
- [high] AC1: DIRECT-PREV-ITER-MARKER
EOF
run_dispatch "$RUN" "$LIB" "$DC" 5 '
  VERIFY_MODE="per-us"
  US_LIST="US-001"
  VERIFIED_US=""
  US_FIX_CONTRACT[US-001]="/nonexistent/stale-should-not-win.md"
'
PROMPTC="$DC/logs/iter-005.worker-prompt.md"
if [[ -f "$PROMPTC" ]] && grep -q "DIRECT-PREV-ITER-MARKER" "$PROMPTC"; then
  ok "C1: a real prev-iter fix contract is used directly, unaffected by a stale carry entry"
else
  no "C1: direct prev-iter fix contract regressed"
fi

# --- D: mutation control — revert the fix on a scratch copy, prove Scenario A goes RED ---
echo "--- D: mutation control (defect re-injected must fail A2) ---"
MUT_RUN="$TMP/run_mutated.zsh"
cp "$RUN" "$MUT_RUN"
# Strip the fallback block we added (matched by its DEFECT-1 comment marker)
# without touching anything else in the file.
python3 - "$MUT_RUN" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
pattern = re.compile(
    r"\n  # DEFECT-1 fix: the immediately-previous iteration wrote no fresh fix.*?"
    r"\[\[ -n \"\$_carried_fix_contract\" && -f \"\$_carried_fix_contract\" \]\] && fix_contract_file=\"\$_carried_fix_contract\"\n  fi\n",
    re.DOTALL,
)
new_text, n = pattern.subn("\n", text)
assert n == 1, f"expected exactly 1 match, got {n}"
with open(path, "w") as f:
    f.write(new_text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "D0: mutation setup failed (could not strip the fix from the scratch copy)"
else
  ok "D0: mutation setup stripped the DEFECT-1 fallback block from a scratch copy"
  DD="$TMP/d"; mkfixture "$DD"
  mkdir -p "$DD/logs"
  cp "$DA/logs/iter-003.fix-contract.md" "$DD/logs/iter-003.fix-contract.md"
  run_dispatch "$MUT_RUN" "$LIB" "$DD" 5 '
    VERIFY_MODE="per-us"
    US_LIST="US-001"
    VERIFIED_US=""
    US_FIX_CONTRACT[US-001]="'"$DD"'/logs/iter-003.fix-contract.md"
  '
  PROMPTD="$DD/logs/iter-005.worker-prompt.md"
  if [[ -f "$PROMPTD" ]] && grep -q "ISSUE-MARKER-DEFECT1" "$PROMPTD"; then
    no "D1: mutation control INEFFECTIVE — defect re-injected but test A2 still passes (test does not actually exercise the fix)"
  else
    ok "D1: mutation control effective — with the fix stripped, the carried contract is correctly absent (proves A2 tests the real fix)"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
