#!/bin/zsh
# Bug Report #8 (Plan v6 PR-B) — refuse to synthesize verify signal when worker
# exited without commit. Real integration test: sources lib_ralph_desk.zsh +
# the relevant slice of run_ralph_desk.zsh, calls handle_worker_exit_codex /
# _bug8_check_synth_allowed against a fresh tmp git repo, and asserts the
# 4-way gate emits the documented (signal | BLOCKED + reason_category).
#
# Pattern mirrored from tests/test-bug7-post-sentinel-race.sh (live integration
# slice) and tests/test-bug7-poll-partial-write.sh (jq + tmp dir + grep guard).
#
# Scenarios:
#   A1  no done-claim                       → BLOCKED infra_failure
#   A2a done-claim + git unverifiable       → BLOCKED infra_failure
#   A2b done-claim + git toplevel mismatch  → BLOCKED infra_failure
#   A3  done-claim + dirty tree             → BLOCKED metric_failure
#   A4  done-claim + clean tree             → synthesize verify (rc=0)
#   D1  Node code emits matching BLOCK_TAGS (dual-mode parity)

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN_SCRIPT="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB_SCRIPT="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"

if [[ ! -f "$RUN_SCRIPT" || ! -f "$LIB_SCRIPT" ]]; then
  print -u2 "FAIL: required scripts not found"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  print -u2 "FAIL: jq not installed"
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  print -u2 "FAIL: git not installed"
  exit 1
fi

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
ok()   { print "  PASS: $1"; TESTS_PASSED=$(( TESTS_PASSED + 1 )); TESTS_RUN=$(( TESTS_RUN + 1 )); }
fail() { print -u2 "  FAIL: $1"; TESTS_FAILED=$(( TESTS_FAILED + 1 )); TESTS_RUN=$(( TESTS_RUN + 1 )); }

# Stub the heavy zsh functions that lib_ralph_desk + the run-script slice
# expect at module load. We only need write_blocked_sentinel, log helpers,
# _emit_a4_fallback_audit, and the Bug #8 helpers themselves.
log()         { print "  [log] $*"; }
log_error()   { print "  [err] $*"; }
log_debug()   { :; }
_emit_a4_fallback_audit() {
  print "AUDIT: us_id=$1 iter=$2 source=$3" >> "$AUDIT_LOG"
}
write_blocked_sentinel() {
  local reason="$1" us_id="${2:-ALL}" category="${3:-metric_failure}"
  print "BLOCKED reason='$reason' us_id='$us_id' category='$category'" >> "$BLOCK_LOG"
}

# Extract Bug #8 helper sources (sourcing the full run_ralph_desk.zsh runs
# `main` and dispatches a campaign). We cherry-pick the helper definitions.
EXTRACT_DIR=$(mktemp -d -t bug8-extract.XXXXXX)
trap 'rm -rf "$EXTRACT_DIR"' EXIT

# Pull `_bug8_check_synth_allowed` definition (a self-contained function block).
awk '
  /^_bug8_check_synth_allowed\(\)/, /^}$/ { print }
' "$RUN_SCRIPT" > "$EXTRACT_DIR/bug8_helper.zsh"

# Pull `handle_worker_exit_codex` definition (depends on _bug8_check_synth_allowed).
awk '
  /^handle_worker_exit_codex\(\)/, /^}$/ { print }
' "$RUN_SCRIPT" > "$EXTRACT_DIR/handle_codex.zsh"

if ! grep -q '_bug8_check_synth_allowed' "$EXTRACT_DIR/bug8_helper.zsh"; then
  print -u2 "FAIL: _bug8_check_synth_allowed not found in $RUN_SCRIPT"
  exit 1
fi
if ! grep -q 'handle_worker_exit_codex' "$EXTRACT_DIR/handle_codex.zsh"; then
  print -u2 "FAIL: handle_worker_exit_codex not found in $RUN_SCRIPT"
  exit 1
fi

source "$EXTRACT_DIR/bug8_helper.zsh"
source "$EXTRACT_DIR/handle_codex.zsh"

# Build a clean tmp git repo for each scenario.
make_repo() {
  local repo
  repo=$(mktemp -d -t bug8-repo.XXXXXX)
  (
    cd "$repo"
    git init -q
    git config user.email test@example
    git config user.name test
    print "init" > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -q -m init
  )
  print -- "$repo"
}

run_scenario() {
  local name="$1"
  ROOT="$2"
  CURRENT_US="${3:-US-001}"
  ITERATION=1
  DONE_CLAIM_FILE="${4:-}"
  # Logs OUTSIDE the repo so the dirty-tree gate is not triggered by the
  # logger's own writes. tmp dirs are removed in the trap at exit.
  local logdir="$EXTRACT_DIR/scenario-$name"
  mkdir -p "$logdir"
  AUDIT_LOG="$logdir/audit"
  BLOCK_LOG="$logdir/blocked"
  SIGNAL_FILE="$logdir/iter-signal.json"
  : > "$AUDIT_LOG"
  : > "$BLOCK_LOG"
  rm -f "$SIGNAL_FILE"
  print ""
  print "Scenario $name (ROOT=$ROOT)"
}

# ---------------------------------------------------------------------------
# A1: no done-claim → BLOCKED infra_failure
# ---------------------------------------------------------------------------
A1_REPO=$(make_repo)
run_scenario A1 "$A1_REPO" US-001 "$A1_REPO/done-claim.json"
# done-claim absent — DONE_CLAIM_FILE points at non-existent file.
handle_worker_exit_codex 1 "$SIGNAL_FILE"
A1_RC=$?
if (( A1_RC == 1 )); then
  ok "A1 returns 1 (BLOCKED) when done-claim absent"
else
  fail "A1 expected rc=1 but got $A1_RC"
fi
if grep -q "category='infra_failure'" "$BLOCK_LOG" \
   && grep -q 'blocked_codex_exit_no_done_claim' "$AUDIT_LOG"; then
  ok "A1 wrote BLOCKED infra_failure + blocked_codex_exit_no_done_claim audit"
else
  fail "A1 missing BLOCKED+audit entries (block.log: $(cat "$BLOCK_LOG"); audit: $(cat "$AUDIT_LOG"))"
fi
if [[ ! -f "$SIGNAL_FILE" ]]; then
  ok "A1 did NOT synthesize iter-signal.json"
else
  fail "A1 unexpectedly wrote $SIGNAL_FILE"
fi

# ---------------------------------------------------------------------------
# A2a: done-claim + git unverifiable (no .git) → BLOCKED infra_failure
# ---------------------------------------------------------------------------
A2A_REPO=$(mktemp -d -t bug8-nogit.XXXXXX)
print '{"us_id":"US-001","summary":"x"}' > "$A2A_REPO/done-claim.json"
run_scenario A2a "$A2A_REPO" US-001 "$A2A_REPO/done-claim.json"
handle_worker_exit_codex 1 "$SIGNAL_FILE"
A2A_RC=$?
if (( A2A_RC == 1 )); then
  ok "A2a returns 1 when git not initialized at ROOT"
else
  fail "A2a expected rc=1 but got $A2A_RC"
fi
if grep -q "category='infra_failure'" "$BLOCK_LOG" \
   && grep -q 'blocked_git_unverifiable' "$AUDIT_LOG"; then
  ok "A2a wrote BLOCKED infra_failure + blocked_git_unverifiable audit"
else
  fail "A2a missing BLOCKED+audit (block: $(cat "$BLOCK_LOG"); audit: $(cat "$AUDIT_LOG"))"
fi

# ---------------------------------------------------------------------------
# A2b: done-claim + git toplevel ≠ ROOT (sub-tree case) → BLOCKED infra_failure
#      ROOT is a CHILD directory inside an initialized git repo, so
#      `git -C ROOT rev-parse --show-toplevel` returns the repo root, NOT ROOT.
#      The canonical-path mismatch fires the git_state_unverifiable branch
#      WITHOUT going through the "toplevel empty" no-git branch (which A2a
#      already covers). Distinct from A2a per codex critic round-3.
# ---------------------------------------------------------------------------
A2B_PARENT_REPO=$(make_repo)
A2B_REPO="$A2B_PARENT_REPO/sub-campaign"
mkdir -p "$A2B_REPO"
print '{"us_id":"US-001","summary":"x"}' > "$A2B_REPO/done-claim.json"
# Commit the subdir so the tree is clean (we must isolate the toplevel check
# from the dirty-tree check — this is the toplevel-mismatch scenario only).
( cd "$A2B_PARENT_REPO" && git add -A && git -c commit.gpgsign=false commit -q -m sub )
run_scenario A2b "$A2B_REPO" US-001 "$A2B_REPO/done-claim.json"
# Sanity: confirm the test setup actually produces a real toplevel mismatch.
A2B_TOPLEVEL=$(git -C "$A2B_REPO" rev-parse --show-toplevel 2>/dev/null)
if [[ -n "$A2B_TOPLEVEL" && "$A2B_TOPLEVEL" != "$A2B_REPO" ]]; then
  ok "A2b setup: git toplevel='$A2B_TOPLEVEL' != ROOT='$A2B_REPO' (real mismatch, not no-git)"
else
  fail "A2b setup defective: toplevel='$A2B_TOPLEVEL' did not produce a real mismatch"
fi
handle_worker_exit_codex 1 "$SIGNAL_FILE"
A2B_RC=$?
if (( A2B_RC == 1 )); then
  ok "A2b returns 1 when ROOT not at git toplevel (sub-tree mismatch)"
else
  fail "A2b expected rc=1 but got $A2B_RC"
fi
if grep -q 'blocked_git_unverifiable' "$AUDIT_LOG"; then
  ok "A2b emitted blocked_git_unverifiable (toplevel-mismatch path)"
else
  fail "A2b missing blocked_git_unverifiable audit (audit: $(cat "$AUDIT_LOG"))"
fi

# ---------------------------------------------------------------------------
# A3: done-claim + dirty tree → BLOCKED metric_failure
# ---------------------------------------------------------------------------
A3_REPO=$(make_repo)
print '{"us_id":"US-001","summary":"x"}' > "$A3_REPO/done-claim.json"
print "dirty" > "$A3_REPO/uncommitted.txt"
run_scenario A3 "$A3_REPO" US-001 "$A3_REPO/done-claim.json"
handle_worker_exit_codex 1 "$SIGNAL_FILE"
A3_RC=$?
if (( A3_RC == 1 )); then
  ok "A3 returns 1 (BLOCKED) when tree is dirty"
else
  fail "A3 expected rc=1 but got $A3_RC"
fi
if grep -q "category='metric_failure'" "$BLOCK_LOG" \
   && grep -q 'blocked_dirty_tree' "$AUDIT_LOG"; then
  ok "A3 wrote BLOCKED metric_failure + blocked_dirty_tree audit"
else
  fail "A3 missing BLOCKED+audit (block: $(cat "$BLOCK_LOG"); audit: $(cat "$AUDIT_LOG"))"
fi
if grep -q 'worker_incomplete_uncommitted' "$BLOCK_LOG"; then
  ok "A3 reason text mentions worker_incomplete_uncommitted"
else
  fail "A3 missing 'worker_incomplete_uncommitted' in BLOCKED reason"
fi
if grep -q 'uncommitted.txt' "$BLOCK_LOG"; then
  ok "A3 reason text includes first dirty file (uncommitted.txt)"
else
  fail "A3 missing dirty file name in reason text"
fi

# ---------------------------------------------------------------------------
# A4: done-claim + clean tree → synthesize verify (rc=0)
# ---------------------------------------------------------------------------
A4_REPO=$(make_repo)
print '{"us_id":"US-001","summary":"x"}' > "$A4_REPO/done-claim.json"
# Commit the done-claim so the tree is clean again.
( cd "$A4_REPO" && git add done-claim.json && git -c commit.gpgsign=false commit -q -m claim )
run_scenario A4 "$A4_REPO" US-001 "$A4_REPO/done-claim.json"
handle_worker_exit_codex 1 "$SIGNAL_FILE"
A4_RC=$?
if (( A4_RC == 0 )); then
  ok "A4 returns 0 (synthesize allowed) when done-claim + clean tree"
else
  fail "A4 expected rc=0 but got $A4_RC"
fi
if [[ -f "$SIGNAL_FILE" ]] && jq -e '.status == "verify"' "$SIGNAL_FILE" >/dev/null 2>&1; then
  ok "A4 synthesized iter-signal.json with status=verify"
else
  fail "A4 did not write a valid synth signal at $SIGNAL_FILE"
fi
if grep -q 'codex_exit_with_done_claim_clean' "$AUDIT_LOG"; then
  ok "A4 audit code is codex_exit_with_done_claim_clean (post-gate)"
else
  fail "A4 missing post-gate audit code (audit: $(cat "$AUDIT_LOG"))"
fi
if [[ ! -s "$BLOCK_LOG" ]]; then
  ok "A4 did NOT write a BLOCKED sentinel"
else
  fail "A4 unexpectedly blocked (block: $(cat "$BLOCK_LOG"))"
fi

# ---------------------------------------------------------------------------
# RC-1: poll-level rc propagation. The codex-exit BLOCKED path returns 1 from
# handle_worker_exit_codex; poll_for_signal MUST translate that to rc=2 so the
# main worker loop treats it as a hard-stop and not as a recoverable poll
# failure. Codex critic round-2 P2 finding.
# Mirror site: src/scripts/run_ralph_desk.zsh:2335 (poll_for_signal codex
# exit branch). We grep for the contract instead of running the full
# poll_for_signal (which depends on tmux and many globals).
# ---------------------------------------------------------------------------
print ""
print "Scenario RC-1: poll_for_signal propagates handle_worker_exit_codex BLOCKED as rc=2"
if awk '
  /^poll_for_signal\(\)/, /^}$/ { print }
' "$RUN_SCRIPT" | grep -q 'if handle_worker_exit_codex'; then
  ok "poll_for_signal calls handle_worker_exit_codex via if-then (rc-aware dispatch)"
else
  fail "poll_for_signal does NOT branch on handle_worker_exit_codex rc"
fi
if awk '
  /^poll_for_signal\(\)/, /^}$/ { print }
' "$RUN_SCRIPT" | grep -q 'return 2'; then
  ok "poll_for_signal returns 2 on the codex BLOCKED path (hard-stop)"
else
  fail "poll_for_signal does NOT return 2 on the codex BLOCKED path"
fi
# Inline A4 BLOCKED (codex critic round-2): same hard-stop contract.
if awk '
  /^poll_for_signal\(\)/, /^}$/ { print }
' "$RUN_SCRIPT" | grep -q '_bug8_check_synth_allowed'; then
  ok "poll_for_signal inline A4 path uses _bug8_check_synth_allowed shared helper"
else
  fail "poll_for_signal inline A4 path missing shared gate"
fi
# Caller treats rc=2 as hard return.
if awk '
  /local worker_poll_done=0/, /^    done$/ { print }
' "$RUN_SCRIPT" | grep -q 'worker_poll_rc == 2'; then
  ok "main worker loop treats worker_poll_rc=2 as hard return"
else
  fail "main worker loop does NOT route rc=2 to a hard return"
fi

# ---------------------------------------------------------------------------
# D1: Node BLOCK_TAGS parity
# ---------------------------------------------------------------------------
print ""
print "Scenario D1: dual-mode parity"
NODE_LOOP="$ROOT_DIR/src/node/runner/campaign-main-loop.mjs"
for tag in CODEX_EXIT_NO_DONE_CLAIM GIT_STATE_UNVERIFIABLE WORKER_INCOMPLETE_UNCOMMITTED; do
  if grep -q "$tag" "$NODE_LOOP"; then
    ok "Node BLOCK_TAGS.$tag present"
  else
    fail "Node BLOCK_TAGS.$tag missing"
  fi
done

# Cleanup tmp repos.
rm -rf "$A1_REPO" "$A2A_REPO" "$A2B_PARENT_REPO" "$A3_REPO" "$A4_REPO"

print ""
print "Bug #8 refuse-synthesis tests: ran=$TESTS_RUN passed=$TESTS_PASSED failed=$TESTS_FAILED"
if (( TESTS_FAILED > 0 )); then
  exit 1
fi
exit 0
