#!/bin/zsh
# v0.14.1 unit test — Bug Report #3 fixes in run_ralph_desk.zsh.
#
# Validates two helpers:
#   1. is_codex_idle_ui()         — recognizes codex post-work idle banner
#   2. _verifier_pane_has_verdict() — short-circuits no-progress when the
#      verdict file is already on disk (the "frozen verifier" false positive
#      that BOS Bug Report #3 reported).
#
# Mocks tmux + the global state so we can exercise the helpers without a live
# tmux server.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN_SCRIPT="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

# Extract the helpers we need to test. is_codex_idle_ui is small and
# self-contained; _verifier_pane_has_verdict needs jq + the
# VERIFIER_PANE/VERDICT_FILE globals.
TMP_LIB=$(mktemp -t codex-idle-test.XXXXXX)
sed -n '/^is_codex_idle_ui()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"
sed -n '/^_verifier_pane_has_verdict()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"

source "$TMP_LIB"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    print "PASS: $label"
    (( PASS++ ))
  else
    print "FAIL: $label (expected '$expected', got '$actual')"
    (( FAIL++ ))
  fi
}

# ---------------------------------------------------------------------------
# is_codex_idle_ui
# ---------------------------------------------------------------------------

is_codex_idle_ui '─ Worked for 5m 36s ──────────────────'
assert_eq "idle banner with full BOS Bug #3 capture" 0 $?

is_codex_idle_ui 'gpt-5.5 high · main · Context 87% left · 1.85M in'
assert_eq "context status line alone" 0 $?

is_codex_idle_ui '─ Worked for 0m 30s ─'
assert_eq "short-duration variant" 0 $?

is_codex_idle_ui 'I worked through the spec and now ran tests'
assert_eq "false: 'worked' word elsewhere" 1 $?

is_codex_idle_ui ''
assert_eq "false: empty input" 1 $?

is_codex_idle_ui 'Do you want to create file.json? (y/n)'
assert_eq "false: claude permission prompt" 1 $?

# ---------------------------------------------------------------------------
# _verifier_pane_has_verdict
# ---------------------------------------------------------------------------

# Setup: temp verdict file + globals that the helper reads.
TMP_VERDICT=$(mktemp -t codex-verdict.XXXXXX)
print '{"verdict":"pass","us_id":"US-003","iteration":3}' > "$TMP_VERDICT"

VERIFIER_PANE="%v"
FINAL_VERIFIER_PANE="%fv"
VERDICT_FILE="$TMP_VERDICT"

_verifier_pane_has_verdict "%v"
assert_eq "verifier pane + valid verdict → return 0" 0 $?

_verifier_pane_has_verdict "%fv"
assert_eq "final-verifier pane + valid verdict → return 0" 0 $?

_verifier_pane_has_verdict "%w"   # worker pane, not verifier
assert_eq "worker pane → return 1 (no short-circuit)" 1 $?

print 'not-json' > "$TMP_VERDICT"
_verifier_pane_has_verdict "%v"
assert_eq "verifier pane + invalid JSON → return 1" 1 $?

rm -f "$TMP_VERDICT"
_verifier_pane_has_verdict "%v"
assert_eq "verifier pane + missing verdict file → return 1" 1 $?

# Empty VERDICT_FILE var → return 1.
VERDICT_FILE=""
_verifier_pane_has_verdict "%v"
assert_eq "empty VERDICT_FILE → return 1" 1 $?

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print ""
print "=== summary: PASS=$PASS FAIL=$FAIL ==="
rm -f "$TMP_LIB"
[[ "$FAIL" -eq 0 ]]
