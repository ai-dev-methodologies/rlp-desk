#!/usr/bin/env zsh
# Provider quota exhaustion must fail FAST, not burn the whole ITER_TIMEOUT.
#
# Dogfood 2026-07-11: with the ❯-glyph fix in place the codex verifier launched,
# accepted the instruction, and then printed
#   ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage
#   to purchase more credits or try again at 3:08 AM.
# and parked at its prompt. detect_api_error() does not match this (no numeric
# code; "usage limit" is not one of the unconditional outage phrases), so the
# poll loop waited the full 600s and the sentinel reported only a generic
# "verifier/infra error before verdict".
#
# Quota exhaustion is NOT a transient outage: backoff cannot help, the operator
# must wait for the reset or buy credits. It gets its own detector, an immediate
# abort, and a reason string that names the cause.
#
# Anchoring matters: the D-17a outage banner contains the literal substring
# "(not your usage limit)", so a bare /usage limit/ match would misclassify a
# transient rate-limit as terminal and skip the backoff that would have
# recovered it. The detector anchors on "hit your usage limit" / "usage limit
# reached" AND requires a remedy/reset hint.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

# rc 0 = quota exhausted (terminal, abort now), rc 1 = not quota exhaustion.
detect() {
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }
    detect_quota_exhausted "$1"
  ' _ "$1"
}
expect_quota(){ detect "$2"; [[ $? -eq 0 ]] && ok "$1" || no "$1 (expected quota rc0)"; }
expect_not(){   detect "$2"; [[ $? -eq 1 ]] && ok "$1" || no "$1 (expected NOT-quota rc1)"; }

print -r -- "-- behavioral: terminal quota exhaustion (must abort immediately)"
expect_quota "codex 0.144 exec ERROR line" \
  "ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:08 AM."
expect_quota "codex TUI capture, wrapped across lines" \
  $'▌ You\'ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try\n  again at 3:08 AM.\n\n❯ '
expect_quota "claude CLI phrasing" \
  "Claude usage limit reached. Your limit will reset at 3am (Asia/Seoul)."

print -r -- "-- behavioral: NOT quota (must stay on the transient-outage/backoff path)"
expect_not "D-17a banner literally contains '(not your usage limit)'" \
  "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"
expect_not "transient overload" \
  "API Error 529: overloaded, retrying..."
expect_not "prose mentioning a usage limit with no remedy/reset hint" \
  "// TODO: document the usage limit for this endpoint"
expect_not "empty pane" ""

print -r -- "-- structural: the codex verifier poll loop aborts on detection"
grep -q 'detect_quota_exhausted' "$RUN" \
  && ok "run_ralph_desk.zsh calls detect_quota_exhausted" \
  || no "run_ralph_desk.zsh never calls detect_quota_exhausted"

# The abort must reach the operator-visible sentinel, not be flattened into the
# generic consensus-failure text.
grep -q 'VERIFIER_ABORT_REASON' "$RUN" \
  && ok "an abort reason is propagated to the caller" \
  || no "no VERIFIER_ABORT_REASON propagation"
grep -q 'write_blocked_sentinel "\${VERIFIER_ABORT_REASON:-' "$RUN" \
  && ok "consensus-failure sentinel prefers the precise abort reason" \
  || no "consensus-failure sentinel still hardcodes the generic reason"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
