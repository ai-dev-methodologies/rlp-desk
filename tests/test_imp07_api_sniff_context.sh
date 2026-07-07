#!/usr/bin/env zsh
# IMP-07 — API-error sniff must anchor bare numeric codes to API-specific context.
#
# The old inline sniff greps the whole pane for `(^|[^digit])500([^digit]|$)`,
# so ordinary worker/app output — `expect(res.status).toBe(500)`,
# `Error: expected status 500` — false-triggers a terminal infra_failure BLOCK
# after _API_MAX_RETRIES ticks (codex B1). `detect_api_error <text>` narrows the
# numeric-code path to API/service/rate-limit-SPECIFIC phrases while keeping the
# unconditional outage phrases (overloaded / too many requests / service
# unavailable / D-17a banner). This test drives detect_api_error directly.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

# rc 0 = API error (backoff), rc 1 = not an API error.
detect() {
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }
    detect_api_error "$1"
  ' _ "$1"
}
expect_api(){ detect "$2"; [[ $? -eq 0 ]] && ok "$1" || no "$1 (expected API-error rc0)"; }
expect_not(){ detect "$2"; [[ $? -eq 1 ]] && ok "$1" || no "$1 (expected NOT-api rc1 — false positive)"; }

# --- True positives (must backoff) ---
expect_api "D-17a banner"      "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"
expect_api "529 overloaded"    "Some output
529 overloaded"
expect_api "service unavailable" "503 service unavailable"
expect_api "too many requests"   "429 too many requests"
expect_api "API Error + code"    "API Error: 500 upstream"

# --- False positives (must NOT backoff) — codex B1 ---
expect_not "test asserts 500"  "Running tests...
Error: expected status 500
  at test.js:42"
expect_not "toBe(429)"         "expect(res.status).toBe(429)"
expect_not "throw 500 string"  "throw new Error('500 internal')"
expect_not "bare 500 no ctx"   "computed checksum 500 bytes written"
expect_not "empty pane"        ""

print ""
if (( FAIL == 0 )); then print "imp07-api-sniff-context: $PASS/$((PASS+FAIL)) PASS"; else print "imp07-api-sniff-context: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
