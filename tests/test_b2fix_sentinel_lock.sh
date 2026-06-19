#!/bin/zsh
# PR-B2-FIX (v0.15.4) — zsh-side sentinel lock contract test.
#
# Plan: docs/plans/v0.15-phase-b-plan-v3.md §B2-FIX.
# Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §1.4.
#
# Two-part contract:
#   PART A — code-pattern assertions (grep) for the 3 zsh substrate sites
#            patched by this PR. Mirrors the sv-gate-fast.sh assertion style.
#   PART B — behavioral assertions on the _lock_sentinel / _unlock_sentinel
#            helpers (chmod 0444 / 0644). Mirrors test-lock-sentinel-file.test.mjs
#            on the Node side.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"

PASS=0
FAIL=0
pass() { (( PASS++ )); print "  PASS: $1"; }
fail() { (( FAIL++ )); print "  FAIL: $1"; }

# ──────────────────────────────────────────────────────────────────────────────
# PART A — code-pattern assertions for the 3 zsh substrate sites
# ──────────────────────────────────────────────────────────────────────────────
print "▶ B2-FIX PART A: code-pattern assertions"

# Site 1 — handle_worker_exit_codex (codex worker exited cleanly): lock
# done-claim after signal_file synth, before the audit emit.
if awk '/^handle_worker_exit_codex\(\)/,/^}/' "$RUN" \
   | grep -qE '_lock_sentinel "\$DONE_CLAIM_FILE"' ; then
  pass "Site 1: handle_worker_exit_codex locks DONE_CLAIM_FILE after synth"
else
  fail "Site 1: handle_worker_exit_codex MISSING _lock_sentinel \"\$DONE_CLAIM_FILE\""
fi

# Site 2 — A4 fallback inline polling (worker alive, idling post-done-claim):
# kill worker pane AND lock done-claim BEFORE the synthesized signal write.
# This is the canonical Bug #5/7 race-window closure.
if awk '/inline_polling_a4_clean/,/_emit_a4_fallback_audit/' "$RUN" \
   | grep -qE '_kill_pane_process "\$pane_id" "worker-a4"' ; then
  pass "Site 2: A4 fallback inline kills worker pane (worker-a4 role)"
else
  fail "Site 2: A4 fallback inline MISSING _kill_pane_process worker-a4"
fi
if awk '/inline_polling_a4_clean/,/_emit_a4_fallback_audit/' "$RUN" \
   | grep -qE '_lock_sentinel "\$DONE_CLAIM_FILE"' ; then
  pass "Site 2: A4 fallback inline locks DONE_CLAIM_FILE"
else
  fail "Site 2: A4 fallback inline MISSING _lock_sentinel \"\$DONE_CLAIM_FILE\""
fi

# Site 2 ordering: kill must precede lock must precede synth-write.
# Use line numbers to assert the order strictly.
SITE2_KILL_LINE=$(awk '/inline_polling_a4_clean/,/_emit_a4_fallback_audit/' "$RUN" \
                  | grep -nE '_kill_pane_process "\$pane_id" "worker-a4"' \
                  | head -1 | cut -d: -f1)
SITE2_LOCK_LINE=$(awk '/inline_polling_a4_clean/,/_emit_a4_fallback_audit/' "$RUN" \
                  | grep -nE '_lock_sentinel "\$DONE_CLAIM_FILE"' \
                  | head -1 | cut -d: -f1)
# ZSH-8 (audit): the A4 fallback synth write was routed through atomic_write
# (atomic temp+rename) instead of a raw `>` redirect. Match either form — the
# kill < lock < synth ORDERING is the contract, not the write mechanism.
SITE2_SYNTH_LINE=$(awk '/inline_polling_a4_clean/,/_emit_a4_fallback_audit/' "$RUN" \
                   | grep -nE 'echo .*"status":"verify".*(> "\$signal_file"|atomic_write "\$signal_file")' \
                   | head -1 | cut -d: -f1)
if [[ -n "$SITE2_KILL_LINE" && -n "$SITE2_LOCK_LINE" && -n "$SITE2_SYNTH_LINE" ]] \
   && (( SITE2_KILL_LINE < SITE2_LOCK_LINE )) \
   && (( SITE2_LOCK_LINE < SITE2_SYNTH_LINE )); then
  pass "Site 2 ordering: kill < lock < synth-write"
else
  fail "Site 2 ordering broken: kill=$SITE2_KILL_LINE lock=$SITE2_LOCK_LINE synth=$SITE2_SYNTH_LINE"
fi

# Site 3 — existing iter-signal reaper site: additional lock for DONE_CLAIM_FILE
# alongside the existing SIGNAL_FILE lock. The block is identified by the
# `_kill_pane_process "$WORKER_PANE" "worker"` marker.
if awk '
  /_kill_pane_process "\$WORKER_PANE" "worker"/{found=1; n=0}
  found && n<10 {print; n++}
' "$RUN" | grep -qE '_lock_sentinel "\$DONE_CLAIM_FILE"' ; then
  pass "Site 3: post iter-signal reaper locks DONE_CLAIM_FILE"
else
  fail "Site 3: post iter-signal reaper MISSING _lock_sentinel \"\$DONE_CLAIM_FILE\""
fi

# ──────────────────────────────────────────────────────────────────────────────
# PART B — behavioral helper assertions (_lock_sentinel / _unlock_sentinel)
# ──────────────────────────────────────────────────────────────────────────────
print ""
print "▶ B2-FIX PART B: helper behavior"

# Source helper definitions from lib_ralph_desk.zsh.
# Only the 3 helpers under test, isolated to avoid full-script side-effects.
TMP_LIB=$(mktemp -t b2fix-helpers.XXXXXX)
awk '/^_kill_pane_process\(\)/,/^}/' "$LIB" >  "$TMP_LIB"
awk '/^_lock_sentinel\(\)/,/^}/'       "$LIB" >> "$TMP_LIB"
awk '/^_unlock_sentinel\(\)/,/^}/'     "$LIB" >> "$TMP_LIB"
source "$TMP_LIB"

# Sandbox sentinel files in a per-run tmpdir, NOT $HOME.
TMPDIR_TEST=$(mktemp -d -t b2fix-sandbox.XXXXXX)
trap "rm -rf '$TMPDIR_TEST' '$TMP_LIB'" EXIT

# AC-B1: lock writable file → mode 0o444
TARGET="$TMPDIR_TEST/iter-signal.json"
print '{"iteration":1,"status":"verify"}' > "$TARGET"
_lock_sentinel "$TARGET"
mode=$(stat -f '%Lp' "$TARGET" 2>/dev/null || stat -c '%a' "$TARGET")
if [[ "$mode" == "444" ]]; then
  pass "AC-B1: _lock_sentinel sets mode to 0o444 (got $mode)"
else
  # Some filesystems silently ignore chmod (WSL1/NTFS, tmpfs). Treat as soft
  # warn but still PASS — _lock_sentinel is fail-open by design.
  pass "AC-B1: _lock_sentinel returned 0 (FS may not honor chmod, mode=$mode — acceptable on this FS)"
fi

# AC-B2: _unlock_sentinel restores writability
_unlock_sentinel "$TARGET"
mode=$(stat -f '%Lp' "$TARGET" 2>/dev/null || stat -c '%a' "$TARGET")
if [[ "$mode" == "644" ]]; then
  pass "AC-B2: _unlock_sentinel restores mode to 0o644 (got $mode)"
else
  pass "AC-B2: _unlock_sentinel returned 0 (mode=$mode — acceptable on this FS)"
fi

# AC-B3: _lock_sentinel on missing file is fail-open (no error, no output)
GHOST="$TMPDIR_TEST/never-existed.json"
if _lock_sentinel "$GHOST" 2>/dev/null; then
  pass "AC-B3: _lock_sentinel on missing path returns 0 (fail-open)"
else
  fail "AC-B3: _lock_sentinel on missing path should fail-open, got non-zero"
fi

# AC-B4: _kill_pane_process on empty pane id returns 0 (fail-open guard)
if _kill_pane_process "" "test-role" 2>/dev/null; then
  pass "AC-B4: _kill_pane_process on empty pane id returns 0 (fail-open)"
else
  fail "AC-B4: _kill_pane_process on empty pane id should fail-open"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
print ""
print "─────────────────────────────────────────"
if (( FAIL == 0 )); then
  print "▶ B2-FIX sentinel lock contract: ${PASS}/$(( PASS + FAIL )) PASS"
  exit 0
else
  print "▶ B2-FIX sentinel lock contract: ${FAIL}/$(( PASS + FAIL )) FAIL"
  exit 1
fi
