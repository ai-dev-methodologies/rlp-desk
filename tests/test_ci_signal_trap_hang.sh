#!/bin/zsh
# CI hang regression (run 38577918782: the macOS "Behavioral suites" job sat in
# tests/test_signal_trap.sh for ~6 h until GitHub cancelled it).
#
# Root cause (reproduced + sampled, see .omc/artifacts/ci-workflow/): that test
# launched each signal harness as `zsh -f harness &` INSIDE a `$(...)` command
# substitution, so the harness inherited the substitution's stdout pipe. When
# SIGINT/TERM/HUP landed while the harness was inside its `echo ... >> $LOG`
# flush, zsh ran the trap synchronously inside the signal handler (zhandler ->
# dotrap) while that stdio lock was held; the trap's `$(date)` fork then
# deadlocked on the lock in the child (redup -> fileno -> flockfile), the
# harness blocked reading it, the test force-killed the harness after 2 s, and
# the orphaned deadlocked child kept the pipe's write end open forever, so the
# `$(...)` never reached EOF.
#
# Pinned here, deterministically (no reliance on hitting the race):
#   A. run_scenario must return promptly and leave NO orphan even when the
#      harness never exits and a grandchild holds the inherited stdout.
#   B. the `test:zsh` per-file cap must turn a hung file into a FAILING file
#      with a TIMEOUT line, kill its whole process group, and keep going.
#   C. every CI job carries timeout-minutes and every checkout except sv-gate-fast (which reads no git history) is full-depth.
#
# SIGNAL_TRAP_TEST overrides the file under test (used to prove this test
# fails against the pre-fix test_signal_trap.sh).
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
SUT="${SIGNAL_TRAP_TEST:-$ROOT_DIR/tests/test_signal_trap.sh}"
WORKFLOW="$ROOT_DIR/.github/workflows/sv-gate.yml"
PKG="$ROOT_DIR/package.json"
zmodload zsh/datetime

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

TMP=$(mktemp -d)
GC_PIDS=()
trap 'for p in $GC_PIDS; do kill -9 $p 2>/dev/null; done; rm -rf "$TMP"' EXIT

# --- extract a top-level `name() {` ... `}` function from the file under test
_extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn=1 }
    in_fn { print }
    in_fn && /^}/ { exit }
  ' "$2"
}

# =============================================================================
# A. run_scenario: harness that never exits + a grandchild holding its stdout
# =============================================================================
print "A. run_scenario survives a stuck harness whose grandchild holds the pipe"
for fn in run_scenario _wait_exit_within _seed_launch_record _kill_tree _wait_ready; do
  body=$(_extract_fn "$fn" "$SUT")
  if [[ -n "$body" ]]; then eval "$body"; else print "  NOTE $fn not defined in $SUT"; fi
done
typeset -f run_scenario >/dev/null || { print -u2 "FAIL: run_scenario not found in $SUT"; exit 1; }

# Fake harness mimicking the observed failure: on the signal it forks a
# long-lived child (stands in for the deadlocked `$(date)` child, which holds
# the stdout it inherited) and then never exits.
cat > "$TMP/h_stuck.zsh" <<'HARNESS'
#!/bin/zsh
LOG="$1"
trap 'sleep 30 & print -r -- $! > "$LOG.gc"; while true; do sleep 0.2; done' INT
: > "$LOG.ready"
while true; do sleep 0.05; done
HARNESS
chmod +x "$TMP/h_stuck.zsh"

start=$EPOCHREALTIME
result=$(run_scenario "$TMP/h_stuck.zsh" INT INT 130 stuck)
elapsed=$(( EPOCHREALTIME - start ))
IFS='|' read -r exited ec log meta lr <<< "$result"
GC_PIDS+=( $(cat "$TMP/stuck.log.gc" 2>/dev/null) )

[[ "$exited" == "0" ]] \
  && ok "stuck harness is reported as not exited (exited=0)" \
  || no "expected exited=0 for a harness that never exits, got '$exited'"
(( elapsed < 20 )) \
  && ok "run_scenario returned in ${elapsed}s (< 20s; the grandchild sleeps 30s, so a pipe-held \$(...) would block >= 30s)" \
  || no "run_scenario took ${elapsed}s - a grandchild holding the inherited stdout blocked the command substitution"
gc=$(cat "$TMP/stuck.log.gc" 2>/dev/null)
if [[ -n "$gc" ]] && ! kill -0 "$gc" 2>/dev/null; then
  ok "the stuck harness's grandchild (pid $gc) was killed - no orphan left holding the pipe"
else
  no "grandchild '${gc:-<never forked>}' is still alive after run_scenario returned"
fi

# =============================================================================
# B. test:zsh per-file cap
# =============================================================================
print "B. test:zsh per-file wall-clock cap"
SCRIPT=$(node -e 'process.stdout.write(require(process.argv[1]).scripts["test:zsh"])' "$PKG")
[[ "$SCRIPT" == *TEST_FILE_TIMEOUT* ]] \
  && ok "package.json test:zsh honours TEST_FILE_TIMEOUT" \
  || no "package.json test:zsh has no per-file cap (TEST_FILE_TIMEOUT not referenced)"

if command -v perl >/dev/null 2>&1 && [[ "$SCRIPT" == *TEST_FILE_TIMEOUT* ]]; then
  SB="$TMP/sandbox"; mkdir -p "$SB/tests"
  cat > "$SB/tests/test_a_hang.sh" <<'EOF'
#!/bin/zsh
sleep 60 &
print -r -- $! > "$GC_FILE"
print "hang-started"
while true; do sleep 1; done
EOF
  cat > "$SB/tests/test_b_ok.sh" <<'EOF'
#!/bin/bash
echo "b-ran"
EOF
  cat > "$SB/tests/test_c_fail.sh" <<'EOF'
#!/bin/bash
echo "c-failing"
exit 1
EOF
  start=$EPOCHREALTIME
  # to a file, not through a pipe: keeps the suite loop's own exit status and cannot be held open by a straggler
  (cd "$SB" && GC_FILE="$SB/gc.pid" TEST_FILE_TIMEOUT=2 sh -c "$SCRIPT" >"$SB/suite.out" 2>&1 </dev/null)
  suite_rc=$?
  elapsed=$(( EPOCHREALTIME - start ))
  out=$(cat "$SB/suite.out")
  print -r -- "$out" | sed 's/^/    | /'
  GC_PIDS+=( $(cat "$SB/gc.pid" 2>/dev/null) )

  (( elapsed < 15 )) && ok "suite finished in ${elapsed}s despite a hung file and a pipe-holding grandchild" \
    || no "suite took ${elapsed}s - the hung file was not capped"
  print -r -- "$out" | grep -q 'TIMEOUT.*tests/test_a_hang.sh' \
    && ok "the hung file is reported with a TIMEOUT line" || no "no TIMEOUT line for the hung file"
  print -r -- "$out" | grep -q 'FAILING FILES:.*tests/test_a_hang.sh' \
    && ok "the hung file is listed under FAILING FILES" || no "hung file missing from FAILING FILES"
  print -r -- "$out" | grep -q '^b-ran$' \
    && ok "files after the hung one still ran" || no "the suite stopped after the hung file"
  (( suite_rc != 0 )) && ok "the suite loop exits non-zero (rc=$suite_rc) when files fail" \
    || no "suite loop exit status was $suite_rc despite a hung and a failing file"
  print -r -- "$out" | grep -q 'FAILING FILES:.*tests/test_c_fail.sh' \
    && ok "a plainly failing (exit 1) file is listed under FAILING FILES" || no "failing file missing from FAILING FILES"
  print -r -- "$out" | grep -q 'TIMEOUT.*tests/test_c_fail.sh' \
    && no "a plain failure was mislabelled as TIMEOUT" || ok "a plain failure is not reported as TIMEOUT"
  gcp=$(cat "$SB/gc.pid" 2>/dev/null)
  if [[ -n "$gcp" ]] && ! kill -0 "$gcp" 2>/dev/null; then ok "the hung file's whole process group was killed (grandchild $gcp gone)"
  else no "grandchild '${gcp:-<none>}' of the hung file survived"; fi
else
  print "  SKIP per-file cap checks (timeout, FAILING FILES, suite exit status, process-group kill): perl not available or test:zsh lacks TEST_FILE_TIMEOUT"
fi

# =============================================================================
# C. workflow guard rails (static; no YAML parser is a project dependency)
# =============================================================================
print "C. sv-gate.yml guard rails"
jobs_n=$(awk '/^jobs:/{j=1;next} j && /^  [A-Za-z0-9_-]+:[ ]*$/{n++} END{print n+0}' "$WORKFLOW")
tmo_n=$(awk '/^jobs:/{j=1;next} j && /^    timeout-minutes: [0-9]+/{n++} END{print n+0}' "$WORKFLOW")
co_n=$(grep -c 'uses: actions/checkout@' "$WORKFLOW")
fd_n=$(grep -c '^          fetch-depth: 0' "$WORKFLOW")
(( jobs_n >= 3 && tmo_n == jobs_n )) \
  && ok "every job ($jobs_n) sets timeout-minutes" || no "jobs=$jobs_n but timeout-minutes lines=$tmo_n"
(( co_n >= 3 && fd_n == co_n - 1 )) \
  && ok "every checkout but sv-gate-fast ($co_n checkouts, $fd_n full-depth) is full-depth" || no "checkouts=$co_n but fetch-depth: 0 lines=$fd_n (expected all but sv-gate-fast)"

print ""
print "=== test_ci_signal_trap_hang.sh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
